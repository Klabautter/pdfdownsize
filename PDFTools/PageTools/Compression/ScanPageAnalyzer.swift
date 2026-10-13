import Foundation

// MARK: - Masterplan §8.4 – Page Classifier

/// Analysiert Seiten auf Scan-Charakter (Masterplan §8.4) und liefert je Seite
/// eine `PageAnalysis` (§5.4).
///
/// Grundlage: die bestehende Mechanik – Platzierungen aus
/// `PDFCoreDocument.inspectImages()` (cm/Do-Scan der Bridge) und die
/// dekodierten Content-Bytes via `pageContentBytes(pageIndex:)`, gescannt mit
/// einem kompakten Operator-Zähler in der Art des `ContentStreamAnalyzer`.
///
/// WICHTIG (§8.4): `nativeTextOperatorCount > 0` schließt eine Scan-Seite
/// NICHT automatisch aus – gescannte PDFs tragen häufig ein OCR-Overlay.
/// Unterschieden wird deshalb best-effort:
///
///   • Render-Mode 3 (`3 Tr`) bzw. 7: unsichtbarer Text – starkes OCR-Signal.
///   • Weiße Textfarbe (`1 g`, `1 1 1 rg`, `0 0 0 1 k`) über Vollbild-Raster:
///     vermutlich unsichtbar – schwaches Signal (der eigentliche Hintergrund
///     ist erst im Raster sichtbar, hier nicht renderbar).
///   • Sichtbarer Text über ≥ 90-%-Raster: konservativ `mixed` – die
///     Grenze OCR-Text-über-Scan vs. echt born-digitaler Stempel lässt sich
///     ohne Rendering nicht sicher entscheiden.
///
/// Bekannte Grenzen der Heuristik (dokumentiert): Text-in-Formen wird nur
/// erfasst, wenn die Form im Seiten-Content liegt; die Farbhintergrund-
/// Prüfung ist eine Näherung ohne Rendering; `/ActualText`- und
/// Tagging-Signale werden nicht ausgewertet.
enum PageScanAnalyzer {

    // MARK: Öffentliche API

    /// Analysiert alle Seiten des Dokuments. Platzierungsgeometrie kommt aus
    /// `imageResources()` – dieselbe Quelle, die auch die DPI-Politik nutzt
    /// (cm/Do-Scan der Content-Bytes, inkl. Form-XObjects).
    static func analyze(document: PDFCoreDocument) throws -> [PageAnalysis] {
        try analyze(document: document, resources: try document.imageResources())
    }

    /// Wie `analyze(document:)`, aber mit VORAB inventarisierten
    /// Platzierungen: Pipeline und Estimator reichen dieselben
    /// `imageResources()` weiter, die auch der Planner erhält – kein zweiter
    /// Inventory-Durchlauf, identischer Analyerstand.
    static func analyze(document: PDFCoreDocument,
                        resources: [PDFImageResource]) throws -> [PageAnalysis] {
        var placementsByPage: [Int: [(resource: PDFImageResource,
                                      placement: PDFImagePlacement)]] = [:]
        for resource in resources {
            for placement in resource.placements {
                placementsByPage[placement.pageIndex, default: []]
                    .append((resource, placement))
            }
        }
        return try (0..<document.pageCount).map { pageIndex in
            try analyzePage(document: document, pageIndex: pageIndex,
                            placements: placementsByPage[pageIndex] ?? [])
        }
    }

    /// Analysiert eine einzelne Seite. `placements` sind die zur Seite
    /// gehörenden (Ressource, Platzierung)-Paare aus `imageResources()`.
    static func analyzePage(document: PDFCoreDocument,
                            pageIndex: Int,
                            placements: [(resource: PDFImageResource,
                                          placement: PDFImagePlacement)]) throws -> PageAnalysis {
        let info = try document.pageInfo(at: pageIndex)
        let media = info.mediaBox
        let pageArea: Double = media.count >= 4
            ? abs((media[2] - media[0]) * (media[3] - media[1])) : 0.0

        // Deckungsgrade aus den Platzierungen; ohne bekannte Geometrie
        // (placedWidthPoints == 0) zählt die Platzierung nur zur Bildanzahl.
        var coverage = 0.0
        var largest = 0.0
        var largestDPI = 0.0
        for entry in placements {
            let placed = entry.placement
            guard placed.placedWidthPoints > 0, placed.placedHeightPoints > 0,
                  pageArea > 0 else { continue }
            let ratio = min(1.0, max(0.0,
                placed.placedWidthPoints * placed.placedHeightPoints / pageArea))
            coverage += ratio
            if ratio > largest {
                largest = ratio
                largestDPI = Double(entry.resource.width)
                    / placed.placedWidthPoints * 72.0
            }
        }
        coverage = min(1.0, coverage)

        let content = try document.pageContentBytes(pageIndex: pageIndex)
        let text = ContentOperatorScanner(bytes: content).scan()

        let scanDPI: Double? = largest >= 0.5 && largestDPI >= 100 ? largestDPI : nil
        let (classification, confidence) = classify(
            largestCoverage: largest, coverage: coverage,
            visibleChars: text.visibleCharacters, invisibleChars: text.invisibleCharacters,
            vectorOperators: text.vectorOperators)

        return PageAnalysis(
            pageIndex: pageIndex,
            pageArea: pageArea,
            imageCoverageRatio: coverage,
            largestImageCoverageRatio: largest,
            nativeTextOperatorCount: text.showOperators,
            textCharacterEstimate: text.visibleCharacters + text.invisibleCharacters,
            imageCount: placements.count,
            vectorOperatorEstimate: text.vectorOperators,
            likelyOCRTextLayer: text.invisibleCharacters >= 16 && largest >= 0.5,
            scanDPI: scanDPI,
            classification: classification,
            confidence: confidence)
    }

    // MARK: §8.3/§8.4 – Klassifikationskontext für Bildressourcen

    /// Mindestfläche (pt²) einer Dokumentenseite. Ein ≥ 90-%-Einzelraster
    /// ist nur auf einer physisch plausiblen Seite ein Scan-Kandidat
    /// (§8.4 „large raster covers page“); auf Miniaturseiten (Stempel,
    /// eingebettete 32×24-pt-Kacheln) ist die Deckung strukturell bedeutungs-
    /// los. 20 000 pt² ≈ 141×141 pt ≈ 2×2 Zoll – Visitenkarten bleiben
    /// Scan-Kandidaten, Miniaturseiten nicht (Suitenfund: JPX-Balkenmuster
    /// auf Miniaturseite fälschlich scanContinuous).
    static let minimumDocumentPageArea: Double = 20_000

    /// Der Kontext, mit dem `ContentClassifier` EINE Bildressource liest:
    /// Scan-Kandidat aus der Platzierungsdeckung der Host-Seite (nur auf
    /// dokumentgroßen Seiten) plus terminale Quellkodierung. Eine Stelle –
    /// Produktion (CandidateGenerator), Benchmark und Diagnose spiegeln
    /// dieselbe Semantik.
    static func classificationContext(for page: PageAnalysis?,
                                      resource: PDFImageResource?)
        -> ContentClassifier.ClassificationContext {
        var context = ContentClassifier.ClassificationContext()
        if let page {
            context.pageLooksScanned = page.pageArea >= Self.minimumDocumentPageArea
                && page.largestImageCoverageRatio >= 0.90
            context.largestImageCoverageRatio = page.largestImageCoverageRatio
            context.scanDPI = page.scanDPI
        }
        switch resource?.terminalFilter {
        case .dct, .jpx: context.sourceIsLossy = true
        case .flate, .lzw, .ccitt, .jbig2, .runLength: context.sourceIsLossy = false
        case .ascii85, .asciiHex, .crypt, nil: context.sourceIsLossy = nil
        }
        return context
    }

    // MARK: Seitenregeln

    /// Deterministische Seitenregeln. Kernidee §8.4: Ein ≥ 90-%-Einzelraster
    /// ist ein Scan-Kandidat; Text widerspricht dem NICHT automatisch, sondern
    /// wird über Sichtbarkeit bewertet.
    private static func classify(largestCoverage: Double,
                                 coverage: Double,
                                 visibleChars: Int,
                                 invisibleChars: Int,
                                 vectorOperators: Int)
        -> (PageContentClass, Double) {

        if largestCoverage >= 0.90 {
            // Klassisches OCR-Overlay: nur (oder fast nur) unsichtbarer Text.
            if invisibleChars >= 16 && visibleChars < 16 {
                return (.rasterScanWithOCR, 0.80)
            }
            // Sichtbarer Text über Vollbild-Raster: nicht sicher trennbar
            // (OCR mit sichtbarem Text? born-digitaler Stempel?) → konservativ.
            if visibleChars >= 32 {
                return (.mixed, 0.60)
            }
            return (.rasterScan, largestCoverage >= 0.97 && visibleChars == 0 ? 0.90 : 0.75)
        }

        if coverage >= 0.30 {
            // Mehrere große Bilder, kein dominantes Einzelbild.
            return (visibleChars >= 8 || vectorOperators >= 8)
                ? (.mixed, 0.60) : (.unknown, 0.30)
        }

        if visibleChars >= 8 || vectorOperators >= 8 {
            let strong = visibleChars >= 32 || vectorOperators >= 32
            return (.bornDigital, strong ? 0.85 : 0.60)
        }

        // Kleine Bilder/leere Seite ohne Text – nicht sicher einzuordnen.
        return (.unknown, 0.30)
    }
}

// MARK: - Operator-Zähler

/// Kompakter Content-Stream-Zähler für Text/Vektor-Signale. Bewusst KEIN
/// zweiter vollständiger Analyzer: Es werden nur Operatoren gezählt, die die
/// Seitenregeln brauchen; die Tokenisierung folgt derselben Semantik wie
/// `ContentStreamAnalyzer` (Strings, Namen, Zahlen, Inline-Images überspringen).
struct ContentOperatorScanner {

    struct Stats: Equatable, Sendable {
        var showOperators = 0
        var visibleCharacters = 0
        var invisibleCharacters = 0
        var vectorOperators = 0
    }

    private let bytes: [UInt8]
    private var pos = 0
    private var stats = Stats()

    /// Operanden-Stack (Zahlen und String-Byteanzahlen), wie im
    /// ContentStreamAnalyzer auf 8 Einträge gekappt.
    private enum Operand {
        case number(Double)
        case stringBytes(Int)
    }
    private var operands: [Operand] = []
    private var arrayStringBytes = 0
    private var arrayDepth = 0
    private var textDepth = 0
    /// Text-Render-Mode (Operand des letzten `Tr`).
    private var renderMode = 0
    /// Aktuelle Füllfarbe als „ist weiß“-Flag (1 g / 1 1 1 rg / 0 0 0 1 k).
    private var fillIsWhite = false

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    func scan() -> Stats {
        var scanner = self
        scanner.run()
        return scanner.stats
    }

    private mutating func run() {
        while pos < bytes.count {
            let ch = bytes[pos]
            if Self.isWhitespace(ch) { pos += 1; continue }
            if ch == 0x25 { skipComment(); continue }

            switch ch {
            case 0x28: // ( – Literalstring
                let content = readLiteralString()
                recordString(content)
            case 0x3C where pos + 1 < bytes.count && bytes[pos + 1] == 0x3C:
                skipDictionary()
            case 0x3C: // < – Hexstring
                let content = readHexString()
                recordString(content)
            case 0x5B: // [
                arrayDepth += 1
                pos += 1
            case 0x5D: // ]
                arrayDepth = max(0, arrayDepth - 1)
                if arrayDepth == 0, arrayStringBytes > 0 {
                    operands.append(.stringBytes(arrayStringBytes))
                    arrayStringBytes = 0
                } else if arrayDepth == 0 {
                    operands.append(.stringBytes(0))
                }
                pos += 1
            case 0x2F: // / – Name
                _ = readName()
            case 0x30...0x39, 0x2B, 0x2D, 0x2E:
                if let value = readNumber() {
                    appendOperand(.number(value))
                }
            default:
                if Self.isLetter(ch) {
                    let op = readOperator()
                    apply(op)
                } else {
                    pos += 1
                }
            }
        }
    }

    private mutating func apply(_ op: String) {
        switch op {
        case "BT":
            textDepth += 1
        case "ET":
            textDepth = max(0, textDepth - 1)
        case "Tr":
            renderMode = numericOperand()
            operands.removeAll()
        case "Tj", "'":
            if textDepth > 0 {
                show(bytes: stringOperand())
            }
            operands.removeAll()
        case "\"":
            if textDepth > 0 {
                show(bytes: stringOperand())
            }
            operands.removeAll()
        case "TJ":
            if textDepth > 0 {
                show(bytes: arrayStringOperand())
            }
            operands.removeAll()
        case "Tf":
            operands.removeAll()
        case "g":
            if let v = lastNumber() { fillIsWhite = v >= 0.99 }
            operands.removeAll()
        case "rg":
            let values = lastNumbers(3)
            fillIsWhite = values.count == 3 && values.allSatisfy { $0 >= 0.99 }
            operands.removeAll()
        case "k":
            let values = lastNumbers(4)
            fillIsWhite = values.count == 4
                && values[0...2].allSatisfy { $0 <= 0.01 } && values[3] >= 0.99
            operands.removeAll()
        case "sc", "scn":
            fillIsWhite = false
            operands.removeAll()
        case "m", "l", "c", "v", "y", "re", "h",
             "S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "W", "W*":
            stats.vectorOperators += 1
            operands.removeAll()
        case "q", "Q", "cm", "gs", "Do":
            operands.removeAll()
        case "BI":
            // Inline-Image überspringen – sein Binärmaterial wäre sonst
            // „Operatoren“, die nichts bedeuten (wie im ContentStreamAnalyzer).
            skipInlineImage()
            operands.removeAll()
        default:
            operands.removeAll()
        }
    }

    private mutating func show(bytes count: Int) {
        stats.showOperators += 1
        let invisible = renderMode == 3 || renderMode == 7 || fillIsWhite
        if invisible {
            stats.invisibleCharacters += count
        } else {
            stats.visibleCharacters += count
        }
    }

    // MARK: Operanden

    private mutating func appendOperand(_ operand: Operand) {
        operands.append(operand)
        if operands.count > 8 { operands.removeFirst(operands.count - 8) }
    }

    private func lastNumber() -> Double? {
        for operand in operands.reversed() {
            if case .number(let v) = operand { return v }
        }
        return nil
    }

    private func lastNumbers(_ count: Int) -> [Double] {
        let numbers = operands.compactMap { operand -> Double? in
            if case .number(let v) = operand { return v }
            return nil
        }
        guard numbers.count >= count else { return [] }
        return Array(numbers.suffix(count))
    }

    private func numericOperand() -> Int {
        Int(lastNumber() ?? 0)
    }

    /// Byteanzahl des letzten String-Operanden.
    private func stringOperand() -> Int {
        for operand in operands.reversed() {
            if case .stringBytes(let n) = operand { return n }
        }
        return 0
    }

    private func arrayStringOperand() -> Int {
        stringOperand()
    }

    private mutating func recordString(_ content: [UInt8]) {
        if arrayDepth > 0 {
            arrayStringBytes += content.count
        } else {
            appendOperand(.stringBytes(content.count))
        }
    }

    // MARK: Tokenizer-Helfer (Semantik wie ContentStreamAnalyzer)

    static func isWhitespace(_ b: UInt8) -> Bool {
        switch b {
        case 0x20, 0x0A, 0x0D, 0x09, 0x00, 0x0C: return true
        default: return false
        }
    }

    static func isLetter(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    }

    static func isDelimiter(_ b: UInt8) -> Bool {
        switch b {
        case 0x20, 0x0A, 0x0D, 0x09, 0x00, 0x0C,
             0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25:
            return true
        default:
            return false
        }
    }

    private mutating func skipComment() {
        while pos < bytes.count, bytes[pos] != 0x0A && bytes[pos] != 0x0D { pos += 1 }
    }

    /// Springt über `BI … ID <Daten> EI` (gleiche Semantik wie im
    /// ContentStreamAnalyzer).
    private mutating func skipInlineImage() {
        var seenID = false
        while pos < bytes.count {
            if !seenID {
                if bytes[pos] == 0x49 && pos + 1 < bytes.count && bytes[pos + 1] == 0x44
                    && pos >= 1 && Self.isWhitespace(bytes[pos - 1]) {
                    seenID = true
                    pos += 2
                    if pos < bytes.count && Self.isWhitespace(bytes[pos]) { pos += 1 }
                    continue
                }
                pos += 1
            } else {
                if bytes[pos] == 0x45 && pos + 1 < bytes.count && bytes[pos + 1] == 0x49
                    && pos >= 1 && Self.isWhitespace(bytes[pos - 1])
                    && (pos + 2 >= bytes.count || Self.isDelimiter(bytes[pos + 2])) {
                    pos += 2
                    return
                }
                pos += 1
            }
        }
    }

    private mutating func readLiteralString() -> [UInt8] {
        var content: [UInt8] = []
        pos += 1
        var depth = 1
        while pos < bytes.count {
            let c = bytes[pos]
            if c == 0x5C {
                pos += 2
                continue
            }
            if c == 0x28 { depth += 1 }
            if c == 0x29 {
                depth -= 1
                pos += 1
                if depth == 0 { break }
                continue
            }
            content.append(c)
            pos += 1
        }
        return content
    }

    private mutating func readHexString() -> [UInt8] {
        var content: [UInt8] = []
        pos += 1
        while pos < bytes.count {
            let c = bytes[pos]
            pos += 1
            if c == 0x3E { break }
            content.append(c)
        }
        return content
    }

    private mutating func skipDictionary() {
        pos += 2
        var depth = 1
        while pos < bytes.count && depth > 0 {
            let c = bytes[pos]
            if c == 0x3C && pos + 1 < bytes.count && bytes[pos + 1] == 0x3C {
                depth += 1
                pos += 2
                continue
            }
            if c == 0x3E && pos + 1 < bytes.count && bytes[pos + 1] == 0x3E {
                depth -= 1
                pos += 2
                continue
            }
            pos += 1
        }
    }

    private mutating func readName() -> String {
        pos += 1
        var bytes: [UInt8] = []
        while pos < self.bytes.count, !Self.isDelimiter(self.bytes[pos]) {
            bytes.append(self.bytes[pos])
            pos += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private mutating func readNumber() -> Double? {
        let start = pos
        var seenDot = false
        while pos < bytes.count {
            let c = bytes[pos]
            if c >= 0x30 && c <= 0x39 { pos += 1 }
            else if c == 0x2E && !seenDot { seenDot = true; pos += 1 }
            else if (c == 0x2B || c == 0x2D) && pos == start { pos += 1 }
            else { break }
        }
        guard pos > start else { pos += 1; return nil }
        return Double(String(decoding: bytes[start..<pos], as: UTF8.self))
    }

    private mutating func readOperator() -> String {
        let start = pos
        while pos < bytes.count {
            let c = bytes[pos]
            guard Self.isLetter(c) || (c >= 0x30 && c <= 0x39) || c == 0x2A else { break }
            pos += 1
        }
        return String(decoding: bytes[start..<pos], as: UTF8.self)
    }
}
