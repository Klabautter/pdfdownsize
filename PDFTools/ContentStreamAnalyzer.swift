import Foundation

struct Matrix {
    var a: Double, b: Double, c: Double, d: Double, e: Double, f: Double

    static let identity = Matrix(a: 1, b: 0, c: 0, d: 1, e: 0, f: 0)

    func multiplied(by m: Matrix) -> Matrix {
        Matrix(
            a: a * m.a + b * m.c,
            b: a * m.b + b * m.d,
            c: c * m.a + d * m.c,
            d: c * m.b + d * m.d,
            e: e * m.a + f * m.c + m.e,
            f: e * m.b + f * m.d + m.f
        )
    }

    var scaleX: Double { (a * a + b * b).squareRoot() }
    var scaleY: Double { (c * c + d * d).squareRoot() }
}

enum ContentStreamAnalyzer {

    static let maxRecursionDepth = 16
    static let maxTotalBytes = 512 << 20

    /// Liefert pro Bild-XObject (Objektnummer) die maximale Effective DPI
    /// über alle Platzierungen im Dokument.
    static func effectiveDPIs(in doc: PDFDocumentFile) -> [Int: Double] {
        var dpiMap: [Int: Double] = [:]
        var budget = maxTotalBytes

        let pages = doc.objects.compactMap { (num, entry) -> [String: PDFObject]? in
            guard case .stream(let s) = entry,
                  case .name("Page")? = s.dict["Type"] else {
                if case .object(.dict(let d)) = entry,
                   case .name("Page")? = d["Type"] {
                    return d
                }
                return nil
            }
            return s.dict
        }

        for pageDict in pages {
            scanPage(pageDict, doc: doc, dpiMap: &dpiMap, budget: &budget)
        }
        return dpiMap
    }

    // MARK: - Seiten

    private static func scanPage(_ page: [String: PDFObject],
                                 doc: PDFDocumentFile,
                                 dpiMap: inout [Int: Double],
                                 budget: inout Int) {
        guard let resources = pageResources(from: page, doc: doc),
              let xobjects = subDict(resources["XObject"], doc: doc) else { return }

        var parts: [Data] = []
        switch page["Contents"] {
        case .reference(let ref):
            appendContent(ref, doc: doc, into: &parts, budget: &budget)
        case .array(let items):
            for item in items {
                if case .reference(let ref) = item {
                    appendContent(ref, doc: doc, into: &parts, budget: &budget)
                }
            }
        default:
            break
        }
        guard !parts.isEmpty else { return }

        let joined = parts.reduce(Data(), +)
        scan(joined, doc: doc, scope: xobjects, ctm: .identity,
             dpiMap: &dpiMap, depth: 0, budget: &budget)
    }

    /// Löst /Resources auf – inkl. Vererbung über die /Pages-Elternkette (Spezifikation §37/§38).
    private static func pageResources(from page: [String: PDFObject],
                                      doc: PDFDocumentFile) -> [String: PDFObject]? {
        var node: [String: PDFObject]? = page
        for _ in 0..<64 {
            guard let n = node else { break }
            if let res = resolve(doc[object: n["Resources"]], doc: doc) {
                return res
            }
            guard case .reference(let parentRef)? = n["Parent"] else { break }
            switch doc.objects[parentRef] {
            case .object(.dict(let d)):
                node = d
            case .stream(let s):
                node = s.dict
            default:
                node = nil
            }
        }
        return nil
    }

    private static func appendContent(_ ref: Int, doc: PDFDocumentFile,
                                      into parts: inout [Data], budget: inout Int) {
        guard let stream = doc.streamEntry(number: ref),
              canDecodeContent(stream.dict),
              budget > 0 else { return }

        if let inflated = PDFDocumentFile.inflate(stream.data) {
            budget -= inflated.count
            parts.append(inflated)
        }
    }

    private static func canDecodeContent(_ dict: [String: PDFObject]) -> Bool {
        switch dict["Filter"] {
        case .name("FlateDecode"), .none:
            return true
        case .array(let items):
            if items.count == 1, case .name("FlateDecode") = items[0] { return true }
            return false
        default:
            return false
        }
    }

    // MARK: - Operator-Scan

    private static func scan(_ bytes: Data,
                             doc: PDFDocumentFile,
                             scope: [String: PDFObject],
                             ctm: Matrix,
                             dpiMap: inout [Int: Double],
                             depth: Int,
                             budget: inout Int) {
        guard depth < maxRecursionDepth, budget > 0 else { return }

        let b = Array(bytes)
        var pos = 0
        var matrix = ctm
        var stack: [Matrix] = []
        var numbers: [Double] = []
        var lastName: String?
        var currentScope = scope

        func clearOperands() {
            numbers.removeAll()
            lastName = nil
        }

        while pos < b.count {
            let ch = b[pos]

            if isWhitespaceByte(ch) {
                pos += 1
                continue
            }

            switch ch {
            case 0x25:
                while pos < b.count, b[pos] != 0x0A && b[pos] != 0x0D { pos += 1 }

            case 0x28:
                pos = skipLiteralString(b, from: pos)
                clearOperands()

            case 0x3C where pos + 1 < b.count && b[pos + 1] == 0x3C:
                pos = skipDictionary(b, from: pos)
                clearOperands()

            case 0x3C:
                pos = skipHexString(b, from: pos)
                clearOperands()

            case 0x5B, 0x5D:
                pos += 1

            case 0x2F:
                let (name, next) = readName(b, from: pos + 1)
                lastName = name
                pos = next

            case 0x30...0x39, 0x2B, 0x2D, 0x2E:
                let (value, next) = readNumber(b, from: pos)
                if let value {
                    numbers.append(value)
                    if numbers.count > 8 { numbers.removeFirst(numbers.count - 8) }
                }
                pos = next

            default:
                if isLetter(ch) {
                    let start = pos
                    while pos < b.count, isLetter(b[pos]) || (b[pos] >= 0x30 && b[pos] <= 0x39) || b[pos] == 0x2A {
                        pos += 1
                    }
                    let op = String(decoding: b[start..<pos], as: UTF8.self)

                    switch op {
                    case "q":
                        stack.append(matrix)
                        clearOperands()
                    case "Q":
                        if let last = stack.popLast() { matrix = last }
                        clearOperands()
                    case "cm" where numbers.count >= 6:
                        let n = numbers.suffix(6)
                        let m = Matrix(a: n[0], b: n[1], c: n[2], d: n[3], e: n[4], f: n[5])
                        matrix = m.multiplied(by: matrix)
                        clearOperands()
                    case "BI":
                        pos = skipInlineImage(b, from: pos)
                        clearOperands()
                    case "Do":
                        if let name = lastName {
                            handleDo(name, scope: currentScope, matrix: matrix,
                                     doc: doc, dpiMap: &dpiMap, depth: depth,
                                     budget: &budget, currentScope: &currentScope)
                        }
                        clearOperands()
                    default:
                        clearOperands()
                    }
                } else {
                    pos += 1
                }
            }
        }
    }

    private static func handleDo(_ name: String,
                                 scope: [String: PDFObject],
                                 matrix: Matrix,
                                 doc: PDFDocumentFile,
                                 dpiMap: inout [Int: Double],
                                 depth: Int,
                                 budget: inout Int,
                                 currentScope: inout [String: PDFObject]) {
        guard case .reference(let ref)? = scope[name],
              let entry = doc.objects[ref] else { return }

        switch entry {
        case .stream(let s) where isNamed(s.dict["Subtype"], "Image"):
            let w = doubleOf(s.dict["Width"]) ?? 0
            let h = doubleOf(s.dict["Height"]) ?? 0
            guard w > 0, h > 0 else { return }

            let sx = matrix.scaleX
            let sy = matrix.scaleY
            guard sx > 1e-9, sy > 1e-9 else { return }

            let dpiH = w * 72 / sx
            let dpiV = h * 72 / sy
            let dpi = max(dpiH, dpiV)

            if let existing = dpiMap[ref] {
                dpiMap[ref] = min(existing, dpi)
            } else {
                dpiMap[ref] = dpi
            }

        case .stream(let s) where isNamed(s.dict["Subtype"], "Form"):
            guard budget > 0 else { return }
            var formMatrix = Matrix.identity
            if case .array(let items)? = s.dict["Matrix"], items.count == 6 {
                let vals = items.compactMap(doubleOf)
                if vals.count == 6 {
                    formMatrix = Matrix(a: vals[0], b: vals[1], c: vals[2],
                                        d: vals[3], e: vals[4], f: vals[5])
                }
            }

            let childScope: [String: PDFObject]
            if let res = resolve(doc[object: s.dict["Resources"]], doc: doc),
               let xo = subDict(res["XObject"], doc: doc) {
                childScope = xo
            } else {
                childScope = scope
            }

            guard canDecodeContent(s.dict),
                  let inflated = PDFDocumentFile.inflate(s.data) else { return }
            budget -= inflated.count

            scan(inflated, doc: doc, scope: childScope,
                 ctm: matrix.multiplied(by: formMatrix),
                 dpiMap: &dpiMap, depth: depth + 1, budget: &budget)
            currentScope = scope

        default:
            break
        }
    }

    // MARK: - Tokenizer-Helfer

    private static func isWhitespaceByte(_ b: UInt8) -> Bool {
        switch b {
        case 0x20, 0x0A, 0x0D, 0x09, 0x00, 0x0C: return true
        default: return false
        }
    }

    private static func isLetter(_ b: UInt8) -> Bool {
        (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A)
    }

    private static func isDelimiter(_ b: UInt8) -> Bool {
        switch b {
        case 0x20, 0x0A, 0x0D, 0x09, 0x00, 0x0C,
             0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25:
            return true
        default:
            return false
        }
    }

    private static func skipLiteralString(_ b: [UInt8], from start: Int) -> Int {
        var pos = start + 1
        var depth = 1
        while pos < b.count {
            let c = b[pos]
            if c == 0x5C { pos += 2; continue }
            if c == 0x28 { depth += 1 }
            if c == 0x29 {
                depth -= 1
                pos += 1
                if depth == 0 { break }
                continue
            }
            pos += 1
        }
        return min(pos, b.count)
    }

    private static func skipHexString(_ b: [UInt8], from start: Int) -> Int {
        var pos = start + 1
        while pos < b.count {
            let c = b[pos]
            pos += 1
            if c == 0x3E { break }
        }
        return pos
    }

    private static func skipDictionary(_ b: [UInt8], from start: Int) -> Int {
        var pos = start + 2
        var depth = 1
        while pos < b.count && depth > 0 {
            let c = b[pos]
            if c == 0x3C && pos + 1 < b.count && b[pos + 1] == 0x3C {
                depth += 1
                pos += 2
                continue
            }
            if c == 0x3E && pos + 1 < b.count && b[pos + 1] == 0x3E {
                depth -= 1
                pos += 2
                continue
            }
            if c == 0x3C { pos = skipHexString(b, from: pos); continue }
            if c == 0x28 { pos = skipLiteralString(b, from: pos); continue }
            pos += 1
        }
        return min(pos, b.count)
    }

    private static func skipInlineImage(_ b: [UInt8], from start: Int) -> Int {
        var pos = start + 2
        var seenID = false
        while pos < b.count {
            if !seenID {
                if b[pos] == 0x49 && pos + 1 < b.count && b[pos + 1] == 0x44 &&
                   pos >= 1 && isWhitespaceByte(b[pos - 1]) {
                    seenID = true
                    pos += 2
                    if pos < b.count && isWhitespaceByte(b[pos]) { pos += 1 }
                    continue
                }
                pos += 1
            } else {
                if b[pos] == 0x45 && pos + 1 < b.count && b[pos + 1] == 0x49 &&
                   pos >= 1 && isWhitespaceByte(b[pos - 1]) &&
                   (pos + 2 >= b.count || isDelimiter(b[pos + 2])) {
                    return pos + 2
                }
                pos += 1
            }
        }
        return b.count
    }

    private static func readName(_ b: [UInt8], from start: Int) -> (String?, Int) {
        var pos = start
        var bytes: [UInt8] = []
        while pos < b.count, !isDelimiter(b[pos]) {
            bytes.append(b[pos])
            pos += 1
        }
        guard !bytes.isEmpty else { return (nil, pos) }
        return (String(decoding: bytes, as: UTF8.self), pos)
    }

    private static func readNumber(_ b: [UInt8], from start: Int) -> (Double?, Int) {
        var pos = start
        var seenDot = false
        while pos < b.count {
            let c = b[pos]
            if c >= 0x30 && c <= 0x39 { pos += 1 }
            else if c == 0x2E && !seenDot { seenDot = true; pos += 1 }
            else if (c == 0x2B || c == 0x2D) && pos == start { pos += 1 }
            else { break }
        }
        guard pos > start else { return (nil, start + 1) }
        let text = String(decoding: b[start..<pos], as: UTF8.self)
        return (Double(text), pos)
    }

    // MARK: - Objekt-Auflösung


    private static func isNamed(_ obj: PDFObject?, _ expected: String) -> Bool {
        if case .name(expected)? = obj { return true }
        return false
    }

    private static func doubleOf(_ obj: PDFObject?) -> Double? {
        guard case .number(let v)? = obj else { return nil }
        return v
    }

    private static func resolve(_ obj: PDFObject?, doc: PDFDocumentFile) -> [String: PDFObject]? {
        let current: PDFObject? = obj
        for _ in 0..<8 {
            switch current {
            case .reference(let ref):
                switch doc.objects[ref] {
                case .object(.dict(let d)): return d
                case .stream(let s): return s.dict
                default: return nil
                }
            case .dict(let d):
                return d
            default:
                return nil
            }
        }
        return nil
    }

    private static func subDict(_ obj: PDFObject?, doc: PDFDocumentFile) -> [String: PDFObject]? {
        guard let dict = resolve(obj, doc: doc) else { return nil }
        var result: [String: PDFObject] = [:]
        for (key, value) in dict {
            if case .reference(let ref) = value {
                result[key] = .reference(ref)
            } else if case .number = value {
                result[key] = value
            }
        }
        return result.isEmpty ? nil : result
    }
}

extension PDFDocumentFile {
    subscript(object obj: PDFObject?) -> PDFObject? {
        guard case .reference(let ref)? = obj else { return obj }
        switch objects[ref] {
        case .object(let o): return o
        case .stream(let s): return .dict(s.dict)
        case .source: return nil
        case .none: return nil
        }
    }
}
