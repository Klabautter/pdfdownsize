import Foundation

/// Erkennt, ob ein Content-Stream SICHTBAREN Text zeichnet.
///
/// Signal der Schnellschätzung für Scan-Seiten: Eine Scan-Seite trägt ihren
/// Inhalt im Bild und höchstens unsichtbaren OCR-Text (Render-Modus 3 bzw.
/// 7 = nur Clip). Eine Vollseiten-Fotoseite in einem Paper hat dagegen fast
/// immer eigene Beschriftung. Bewusst minimal: Strings, Hex-Strings, Namen,
/// Kommentare und Inline-Bilder werden übersprungen, damit „Tj“ in Daten
/// keinen Text vortäuscht. Der Render-Modus gehört zum Grafikzustand und
/// folgt q/Q.
enum VisibleTextScanner {

    static func hasVisibleText(_ bytes: [UInt8]) -> Bool {
        let n = bytes.count
        var i = 0
        var renderMode = 0.0
        var stack: [Double] = []
        var lastNumber: Double?

        func isWhitespace(_ c: UInt8) -> Bool {
            c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C || c == 0x00
        }
        func isDelimiter(_ c: UInt8) -> Bool {
            switch c {
            case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "<"), UInt8(ascii: ">"),
                 UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: "{"), UInt8(ascii: "}"),
                 UInt8(ascii: "/"), UInt8(ascii: "%"):
                return true
            default:
                return false
            }
        }

        while i < n {
            let c = bytes[i]
            if isWhitespace(c) { i += 1; continue }
            switch c {
            case UInt8(ascii: "%"):
                while i < n, bytes[i] != 0x0A, bytes[i] != 0x0D { i += 1 }
                continue
            case UInt8(ascii: "("):
                // Literal-String mit Escapes und verschachtelten Klammern.
                var depth = 0
                while i < n {
                    let s = bytes[i]
                    if s == UInt8(ascii: "\\") { i += 2; continue }
                    if s == UInt8(ascii: "(") { depth += 1 }
                    if s == UInt8(ascii: ")") { depth -= 1; if depth == 0 { i += 1; break } }
                    i += 1
                }
                continue
            case UInt8(ascii: "<"):
                if i + 1 < n, bytes[i + 1] == UInt8(ascii: "<") { i += 2; continue }
                while i < n, bytes[i] != UInt8(ascii: ">") { i += 1 }
                i += 1
                continue
            case UInt8(ascii: ">"), UInt8(ascii: "["), UInt8(ascii: "]"),
                 UInt8(ascii: "{"), UInt8(ascii: "}"):
                i += 1
                continue
            case UInt8(ascii: "/"):
                i += 1
                while i < n, !isWhitespace(bytes[i]), !isDelimiter(bytes[i]) { i += 1 }
                continue
            default:
                break
            }

            let start = i
            while i < n, !isWhitespace(bytes[i]), !isDelimiter(bytes[i]) { i += 1 }
            let token = String(decoding: bytes[start..<i], as: UTF8.self)
            if let number = Double(token) {
                lastNumber = number
                continue
            }
            switch token {
            case "q":
                stack.append(renderMode)
            case "Q":
                if let saved = stack.popLast() { renderMode = saved }
            case "Tr":
                if let value = lastNumber { renderMode = value }
            case "Tj", "TJ", "'", "\"":
                if renderMode != 3, renderMode != 7 { return true }
            case "BI":
                // Inline-Bild: Binärdaten zwischen ID und EI überspringen.
                while i < n {
                    if bytes[i] == UInt8(ascii: "I"), i > 0, bytes[i - 1] == UInt8(ascii: "D"),
                       i + 1 < n, isWhitespace(bytes[i + 1]) {
                        i += 2
                        break
                    }
                    i += 1
                }
                while i + 1 < n {
                    if isWhitespace(bytes[i]), bytes[i + 1] == UInt8(ascii: "E"),
                       i + 2 < n, bytes[i + 2] == UInt8(ascii: "I"),
                       i + 3 >= n || isWhitespace(bytes[i + 3]) {
                        i += 3
                        break
                    }
                    i += 1
                }
            default:
                break
            }
            lastNumber = nil
        }
        return false
    }
}
