import Foundation

/// Masterplan Schritt 1 – Domänenmodell für Bild-XObjects.
///
/// Kernpunkt: Ein Bild wird über seine PDF-Objektidentität adressiert, nicht
/// über einen Resource-Namen. `/Im0` auf Seite 1 und `/Im0` auf Seite 2 können
/// verschiedene Objekte sein; ein namensbasierter Zugriff verwechselt sie und
/// überschreibt Foto B mit Foto A (Masterplan Finding 13, P0).

// MARK: - Objektidentität

/// WICHTIG: Eine Objektidentität gilt für die Lebensdauer EINES geöffneten
/// Dokuments. Beim Schreiben vergibt der qpdf-Writer neue Objektnummern –
/// eine über einen `save()` hinweg aufbewahrte `PDFObjectID` zeigt danach
/// auf etwas anderes. Pläne sind deshalb immer dokumentgebunden.
struct PDFObjectID: Hashable, Codable, Sendable, CustomStringConvertible {
    let objectNumber: Int
    let generation: Int

    init(objectNumber: Int, generation: Int) {
        self.objectNumber = objectNumber
        self.generation = generation
    }

    var description: String { "\(objectNumber) \(generation) R" }
}

// MARK: - Platzierung

/// Ein Vorkommen eines Bildobjekts auf einer Seite. Ein geteiltes XObject hat
/// EINE Objektidentität und MEHRERE Platzierungen.
struct PDFImagePlacement: Hashable, Codable, Sendable {
    let pageIndex: Int
    /// Der Resource-Name an dieser Stelle – nur für Diagnose und den
    /// Content-Stream-Scan, nie als Identität.
    let resourceName: String
    /// Sichtbare Größe in PDF-Punkten (aus dem cm/Do-Scan); 0 = unbekannt.
    let placedWidthPoints: Double
    let placedHeightPoints: Double
    /// CTM beim Zeichnen [a b c d e f] (Einheitsquadrat → Seite); nil, wenn
    /// unbekannt (z. B. Bilder in Formen). Nur für die Lage auf der Seite.
    var transform: [Double]? = nil
}

// MARK: - Farbraum

enum PDFColorSpaceDescriptor: Hashable, Codable, Sendable {
    case deviceGray
    case deviceRGB
    case deviceCMYK
    case calGray
    case calRGB
    case lab
    case iccBased(components: Int)
    case indexed
    case separation
    case deviceN
    case pattern
    case none
    case unknown(String)

    init(rawName: String) {
        switch rawName {
        case "DeviceGray", "G": self = .deviceGray
        case "CalGray": self = .calGray
        case "DeviceRGB", "RGB": self = .deviceRGB
        case "DeviceCMYK", "CMYK": self = .deviceCMYK
        case "CalRGB": self = .calRGB
        case "Lab": self = .lab
        // „ICCBased:3" – die Zahl kommt aus dem Profil (/N). Ohne sie
        // liesse sich das Bild nicht aufbauen, deshalb war ICCBased früher
        // pauschal ausgeschlossen.
        case let s where s.hasPrefix("ICCBased"):
            let parts = s.split(separator: ":")
            self = .iccBased(components: parts.count > 1
                             ? Int(parts[1]) ?? 0 : 0)
        case "ICCBased": self = .iccBased(components: 0)
        case "Indexed", "I": self = .indexed
        case "Separation": self = .separation
        case "DeviceN": self = .deviceN
        case "Pattern": self = .pattern
        case "None", "": self = .none
        default: self = .unknown(rawName)
        }
    }

    /// Anzahl Komponenten, soweit ohne Auflösung des ICC-Streams bestimmbar.
    var componentCount: Int? {
        switch self {
        case .deviceGray, .calGray, .indexed, .separation: return 1
        case .deviceRGB, .calRGB, .lab: return 3
        case .deviceCMYK: return 4
        // ICCBased: die Komponentenzahl steht im Profil.
        case .iccBased(let n): return n > 0 ? n : nil
        case .deviceN, .pattern, .none, .unknown: return nil
        }
    }

    /// Farbräume, aus deren dekodierten Bytes sich direkt ein Bitmap bauen
    /// lässt. Alles andere braucht eine Palettenauflösung oder ein ICC-Profil
    /// und wird deshalb nicht angefasst.
    var isDirectlyRenderable: Bool {
        switch self {
        case .deviceGray, .calGray, .deviceRGB, .calRGB: return true
        // CMYK lässt sich aus seinen Bytes ebenso direkt aufbauen – vier
        // Komponenten je Bildpunkt. Es war nur ausgeschlossen, weil der
        // Ersatzweg früher lediglich grau und RGB kannte.
        case .deviceCMYK: return true
        // ICCBased mit bekannter Komponentenzahl lässt sich ebenso aufbauen.
        // Das Profil bleibt beim Ersetzen erhalten – die Bridge übernimmt
        // den ursprünglichen /ColorSpace-Eintrag unverändert.
        case .iccBased(let n): return n == 1 || n == 3 || n == 4
        default: return false
        }
    }

    /// Darf dieses Bild verlustbehaftet (als JPEG) ersetzt werden?
    ///
    /// Für CMYK ausdrücklich NICHT. Ein CMYK-JPEG müsste die Adobe-Konvention
    /// mit invertierten Werten treffen, und ein Fehler darin verfälscht
    /// Druckfarben. Verkleinern im eigenen Farbraum bringt fast dieselbe
    /// Ersparnis – sie kommt aus der Auflösung, nicht aus der Quantisierung –
    /// und ändert keine einzige Farbe.
    /// Darf dieses Bild verlustbehaftet (als JPEG) ersetzt werden?
    ///
    /// Für CMYK nicht: Ein CMYK-JPEG müsste die Adobe-Konvention mit
    /// invertierten Werten treffen, und ein Fehler darin verfälscht
    /// Druckfarben.
    ///
    /// Für ICC-Profile SCHON – anders als eine frühere Fassung annahm.
    ///
    /// Das Argument war: Ein JPEG käme in sRGB heraus, während das
    /// Wörterbuch weiter das Profil nennt, also würden die Werte falsch
    /// gedeutet. Der Denkfehler steckt im zweiten Halbsatz. Beim Dekodieren
    /// WIRD das Profil angewendet; die Pixel liegen danach in sRGB. Sie dann
    /// als DeviceRGB zu deklarieren ist keine Farbveränderung, sondern die
    /// zutreffende Beschreibung. Das Profil wegzulassen, nachdem man es
    /// angewendet hat, ist richtig.
    ///
    /// Die falsche Fassung war teuer: Kamerafotos sind fast immer JPEG mit
    /// ICC-Profil. Sie auf verlustfreies Flate zu zwingen ergibt eine
    /// grössere Datei als das Original – die Kompression tat bei ihnen
    /// nichts mehr.
    ///
    /// Nur ein ICC-Profil mit VIER Komponenten bleibt aussen vor: Das ist
    /// ein CMYK-Profil und damit Druckmaterial.
    var allowsLossyReplacement: Bool {
        switch self {
        case .deviceCMYK: return false
        case .iccBased(let n): return n != 4
        default: return true
        }
    }
}

// MARK: - Filter

enum PDFImageFilter: String, Codable, Sendable {
    case dct = "DCTDecode"
    case flate = "FlateDecode"
    case lzw = "LZWDecode"
    case jpx = "JPXDecode"
    case ccitt = "CCITTFaxDecode"
    case jbig2 = "JBIG2Decode"
    case runLength = "RunLengthDecode"
    case ascii85 = "ASCII85Decode"
    case asciiHex = "ASCIIHexDecode"
    case crypt = "Crypt"

    init?(rawName: String) {
        let normalized = rawName.hasPrefix("/") ? String(rawName.dropFirst()) : rawName
        self.init(rawValue: normalized)
    }
}

// MARK: - Ressource

struct PDFImageResource: Hashable, Codable, Sendable {
    let objectID: PDFObjectID
    let width: Int
    let height: Int
    let bitsPerComponent: Int
    let colorSpace: PDFColorSpaceDescriptor
    /// Filterkette in Dokumentreihenfolge. Ein nicht erkannter Filtername
    /// erscheint in `unknownFilters` – er wird nicht stillschweigend ignoriert.
    let filters: [PDFImageFilter]
    let unknownFilters: [String]
    let hasSoftMask: Bool
    let hasExplicitMask: Bool
    /// `/Mask` als ARRAY – Farbschlüssel-Maskierung.
    ///
    /// Anders als eine Schablone benennt sie Farbbereiche im Farbraum des
    /// Basisbildes. Eine verlustbehaftete Neukodierung verschiebt genau
    /// diese Werte, die Maskierung träfe danach andere Bildpunkte.
    var hasColorKeyMask: Bool = false
    let isImageMask: Bool
    /// Werte des `/Decode`-Arrays; leer, wenn keins vorhanden.
    ///
    /// Es bildet die Abtastwerte auf den Farbbereich ab – `[1 0 1 0 1 0]`
    /// kehrt ein RGB-Bild um. Beim Dekodieren angewendet und danach
    /// weggelassen, ist es kein Hindernis mehr.
    var decodeArray: [Double] = []
    var hasDecodeArray: Bool { !decodeArray.isEmpty }

    /// Die VORGABE für dieses Bild nach ISO 32000-1, Tabelle 89.
    ///
    /// `nil`, wenn sie sich nicht bilden lässt – etwa weil die
    /// Komponentenzahl des Farbraums unbekannt ist (DeviceN, Pattern, ein
    /// ICC-Profil ohne gelesenes `/N`). Dann bleibt jedes Array unbekannt
    /// und damit sperrend; das ist die sichere Richtung.
    var defaultDecodeArray: [Double]? {
        // Eine Schablone hat genau einen Kanal, unabhängig vom Farbraum.
        if isImageMask { return [0, 1] }
        // Indexed bildet nicht auf [0 1] ab, sondern auf die Spanne der
        // Palettenplätze: [0, 2^BitsPerComponent − 1].
        if case .indexed = colorSpace {
            guard bitsPerComponent > 0, bitsPerComponent <= 16 else { return nil }
            return [0, Double((1 << bitsPerComponent) - 1)]
        }
        guard let n = colorSpace.componentCount, n > 0 else { return nil }
        return (0..<n).flatMap { _ in [0.0, 1.0] }
    }

    /// Trägt das Bild ein Array, das TATSÄCHLICH etwas verändert?
    ///
    /// Sehr viele Erzeuger schreiben die Vorgabe aus, obwohl sie nichts
    /// bewirkt. Im IPCC-Bericht sind das 37 130 Bilder mit zusammen 40,8 MB
    /// – gemessen, siehe `DefaultDecodeArrayTests`. Sie deswegen von jeder
    /// Bearbeitung auszuschliessen, war die teuerste Vorsicht im ganzen
    /// Kompressionspfad.
    ///
    /// Die Prüfung ist bewusst streng: falsche Länge, unbekannte
    /// Komponentenzahl oder abweichende Werte gelten als wirksam. Nur die
    /// exakte Vorgabe zählt als wirkungslos.
    var hasEffectiveDecodeArray: Bool {
        guard !decodeArray.isEmpty else { return false }
        guard let expected = defaultDecodeArray,
              expected.count == decodeArray.count else { return true }
        // Die Werte stehen als Realzahlen im Dokument; ein exakter Vergleich
        // ginge an "0.0" gegen "0" nicht schief, an gerundeten Werten aber
        // schon.
        for (a, b) in zip(decodeArray, expected) where abs(a - b) > 1e-6 {
            return true
        }
        return false
    }
    /// Länge des kodierten Streams in Bytes; -1 wenn unbekannt.
    let encodedByteCount: Int
    let placements: [PDFImagePlacement]

    var pixelCount: Int { width * height }
    var maxEdge: Int { max(width, height) }
    var isShared: Bool { placements.count > 1 }

    /// Der terminale (äußerste) Bildfilter bestimmt das Datenformat.
    var terminalFilter: PDFImageFilter? {
        // ASCII-Vorfilter sind reine Transportkodierung und zählen nicht.
        filters.last { $0 != .ascii85 && $0 != .asciiHex }
    }

    /// Höchste effektive Auflösung über alle Platzierungen.
    /// Ein Bild, das einmal klein und einmal groß platziert ist, darf nur so
    /// weit verkleinert werden, wie es die GRÖSSTE Platzierung erlaubt.
    var effectiveDPI: Double? {
        let values = placements.compactMap { placement -> Double? in
            guard placement.placedWidthPoints > 1 else { return nil }
            return Double(width) / placement.placedWidthPoints * 72.0
        }
        return values.min()
    }
}

// MARK: - Capability

/// Masterplan Schritt 1.4/3/4 – explizite Fähigkeitspolitik.
///
/// Es gibt bewusst keinen „Notfallpfad", der ein unbekanntes Bild irgendwie
/// doch ersetzt (früher: die ganze Seite rendern). Was nicht sicher
/// transformierbar ist, wird deterministisch übersprungen.
enum ImageTransformCapability: Hashable, Codable, Sendable {
    case safe
    case maskedUnsupported
    case unsupportedColorSpace(String)
    case unsupportedFilter(String)
    case unsupportedBitDepth(Int)
    case decodeArrayUnsupported

    var isSafe: Bool { self == .safe }

    var reason: String {
        switch self {
        case .safe: return "transformierbar"
        case .maskedUnsupported:
            return "Maske/Transparenz (SMask, Mask oder ImageMask) – "
                + "Bild und Maske müssten gemeinsam transformiert werden"
        case .unsupportedColorSpace(let name):
            return "Farbraum nicht sicher rekonstruierbar: \(name)"
        case .unsupportedFilter(let name):
            return "Filter ohne echten XObject-Decoder: \(name)"
        case .unsupportedBitDepth(let bits):
            return "Bittiefe \(bits) statt 8"
        case .decodeArrayUnsupported:
            return "/Decode-Array – Ersatz würde die Tonwertabbildung verlieren"
        }
    }
}

extension PDFImageResource {

    /// Entscheidet AUSSCHLIESSLICH anhand der Bildeigenschaften, ob eine
    /// Transformation überhaupt zulässig ist. Größen- und DPI-Politik trifft
    /// der Planner – „darf man?" und „lohnt es sich?" bleiben getrennt.
    var transformCapability: ImageTransformCapability {
        // Ein Bild, das SELBST eine 1-Bit-Schablone ist, kann JPEG nicht
        // darstellen – das bleibt tabu.
        if isImageMask {
            return .maskedUnsupported
        }

        // Eine Maskenbeziehung ist dagegen KEIN Hindernis mehr.
        //
        // Die frühere Annahme war, Bild und Maske müssten gemeinsam
        // umgerechnet werden. Die Norm verlangt das nicht: Nach
        // PDF 32000-1 §8.9.6.4 muss eine weiche Maske nicht dieselben Masse
        // haben wie ihr Basisbild, sie wird darauf skaliert. Die Bridge
        // übernimmt /SMask und /Mask unverändert ins neue Wörterbuch.
        //
        // Die Annahme kostete 143,5 MB im Korpus – 40 % aller Bilddaten,
        // der grösste Posten, den wir gar nicht angefasst haben.
        //
        // Farbschlüssel-Maskierung (/Mask als Array) bleibt ausgeschlossen;
        // sie benennt Farbwerte im Original, die eine verlustbehaftete
        // Neukodierung verschiebt. Die Bridge weist das zusätzlich ab.
        if hasColorKeyMask {
            return .maskedUnsupported
        }
        // Ein /Decode-Array ist KEIN Hindernis mehr: Es wird beim
        // Dekodieren angewendet (CoreGraphics kann das) und im neuen
        // Wörterbuch weggelassen. Über den Korpus gemessen betrifft das
        // 38 300 Bilder mit zusammen 55,7 MB.
        //
        // Für JPEG-Quellen bleibt es gesperrt: Dort dekodiert ImageIO, und
        // die Abbildung liesse sich nicht sauber dazwischenschieben.
        //
        // ABER nur, wenn das Array überhaupt etwas bewirkt. Ein
        // ausgeschriebenes Vorgabe-Array bildet jeden Wert auf sich selbst
        // ab – es zu berücksichtigen heisst, nichts zu tun. Diese
        // Unterscheidung fehlte, und sie kostete allein im IPCC-Bericht
        // 36 510 Bilder mit 38,7 MB.
        if hasEffectiveDecodeArray, terminalFilter == .dct {
            return .decodeArrayUnsupported
        }
        if let unknown = unknownFilters.first {
            return .unsupportedFilter(unknown)
        }
        guard let terminal = terminalFilter else {
            // Kein Filter = unkomprimierte Rohdaten; das ist dekodierbar.
            return baselineCapability
        }
        switch terminal {
        case .dct:
            // JPEG-Passthrough: ImageIO liefert das Bild verlässlich.
            return .safe
        case .flate, .lzw, .runLength:
            return baselineCapability
        case .jpx:
            // Phase 4b – JPX-INPUT ist dekodierbar (OpenJPEG-Shim über
            // `JPXDecoder`); decodierte Pixel laufen wie Flate-Pixel durch
            // die bestehende Engine (Effective-DPI, Downsample, JPEG-Race
            // bzw. verlustfreier Grafikpfad). Das ist Input-Coverage, kein
            // Output: Der Executor schreibt ausschließlich DCTDecode/
            // FlateDecode/CCITTFaxDecode/JBIG2Decode – /JPXDecode wird nie
            // geschrieben, unsere eigenen Outputs können JPX also nicht
            // enthalten und im Zweitlauf nicht re-transformieren.
            //
            // Bittiefe/Bittiefe-Fehler: /BitsPerComponent ist laut Norm 8;
            // eine höhere Codestream-Präzision schiebt der Shim auf 8-bit
            // herunter. Scheitert die Dekodierung (etwa verpackte
            // Vorfilter, prec > 16, korrupte Bytes), meldet die Quelle nil
            // und das Bild bleibt per KeepReason.decodeFailed.
            return baselineCapability
        case .ccitt:
            // V2-3c (§9.10): CCITT-EINGÄNGE sind als trueBilevel dekodierbar
            // und nehmen am Bilevel-Race teil (KEEP / G4 / JBIG2 lossless).
            // Dieser Weg greift in Schritt 0 der Planung, VOR dieser
            // Capability – deshalb bleibt die Sperre für die REGULÄREN
            // Pfade bestehen: 1-bit-Bilder werden nie resampelt (Bilevel-
            // Politik), und mit BilevelPolicy .keep bleiben S/W-Bilder
            // vollständig unangetastet. Der Decode selbst läuft über den
            // eigenen Fax-Shim; nicht vollständig abgedeckte DecodeParms
            // scheitern dort deterministisch (decodeFailed → KEEP).
            return .unsupportedFilter("CCITTFaxDecode")
        case .jbig2:
            // Sperre für Eingang UND Ausgang (siehe .ccitt). TODO(Phase 4):
            // oversized JBIG2-Inputs dekodieren und über die Phase-2-Kandidaten
            // neu kodieren – bis dahin bleiben sie unberührt.
            return .unsupportedFilter("JBIG2Decode")
        case .ascii85, .asciiHex, .crypt:
            return .unsupportedFilter(terminal.rawValue)
        }
    }

    /// Prüfungen, die für alle selbst zu dekodierenden Formate gelten.
    private var baselineCapability: ImageTransformCapability {
        guard bitsPerComponent == 8 else {
            return .unsupportedBitDepth(bitsPerComponent)
        }
        guard colorSpace.isDirectlyRenderable else {
            return .unsupportedColorSpace("\(colorSpace)")
        }
        return .safe
    }
}
