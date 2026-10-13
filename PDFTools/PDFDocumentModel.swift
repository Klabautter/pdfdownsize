import Foundation
import Compression

enum PDFObject {
    case dict([String: PDFObject])
    case array([PDFObject])
    case name(String)
    case number(Double)
    case boolean(Bool)
    case reference(Int)
    case null
    case raw(Data)
}

struct PDFStreamObj {
    var dict: [String: PDFObject]
    var data: Data
}

enum PDFEntry {
    case object(PDFObject)
    case stream(PDFStreamObj)
    case source(Data)
}

enum PDFError: LocalizedError {
    case encrypted
    case malformed

    var errorDescription: String? {
        switch self {
        case .encrypted:
            return String(localized: "Verschlüsselte PDFs werden noch nicht unterstützt.")
        case .malformed:
            return String(localized: "Das PDF hat eine Struktur, die noch nicht unterstützt wird.")
        }
    }
}

final class PDFDocumentFile {

    private(set) var objects: [Int: PDFEntry] = [:]
    private(set) var rootRef: Int?
    let originalSize: Int

    private var data: Data
    private var position = 0
    private var topLevelNumbers: Set<Int> = []

    init(data: Data) throws {
        self.data = data
        self.originalSize = data.count
        scanObjects()
        expandObjectStreams()
        try resolveEncryption()
        resolveRoot()
    }

    convenience init(url: URL) throws {
        // Phase 8 – file-backed statt Ganzdatei: `mappedIfSafe` legt die
        // Bytes als Datei-seitiges (cleanes) Mapping hinter `data`, statt
        // die Datei als anonymen Speicher zu halten. Der Peak-RSS skaliert
        // damit nicht mehr mit der Dateigröße – untouched Seiten kosten
        // nichts, gelesene sind vom System verwerfbar.
        //
        // Semantisch sicher, weil der Parser den Puffer NUR liest: Slices
        // (`PDFStreamObj.data`, `.source`, Strings) referenzieren die
        // gemappte Region, `serialize()` kopiert beim Schreiben heraus.
        // Es gibt keine Schreibzugriffe auf `self.data`.
        try self.init(data: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    // MARK: - Top-level scan

    private func scanObjects() {
        while position < data.count {
            skipWhitespaceAndComments()
            guard position < data.count else { break }

            let save = position
            guard let num = readPlainInt() else {
                position = save + 1
                continue
            }
            skipWhitespace()
            let saveAfterNum = position
            guard readPlainInt() != nil else {
                position = save + 1
                continue
            }
            _ = saveAfterNum
            skipWhitespace()
            guard matchKeyword("obj") else {
                position = save + 1
                continue
            }

            parseBody(objectNumber: num)
            topLevelNumbers.insert(num)
        }
    }

    private func parseBody(objectNumber n: Int) {
        skipWhitespaceAndComments()
        let bodyStart = position
        guard bodyStart < data.count else {
            objects[n] = .object(.null)
            return
        }

        if data[data.startIndex + bodyStart] == 0x3C,
           bodyStart + 1 < data.count,
           data[data.startIndex + bodyStart + 1] == 0x3C {

            if let parsed = parseDictionary(), case .dict(let dict) = parsed {
                skipWhitespaceAndComments()
                if matchKeyword("stream") {
                    parseStream(dict: dict, objectNumber: n, bodyStart: bodyStart)
                    return
                } else {
                    objects[n] = .object(.dict(dict))
                    finishObject()
                    return
                }
            }
            recoverRaw(objectNumber: n, from: bodyStart)
            return
        }

        if let obj = parseObject() {
            objects[n] = .object(obj)
            finishObject()
        } else {
            recoverRaw(objectNumber: n, from: bodyStart)
        }
    }

    private func parseStream(dict: [String: PDFObject], objectNumber n: Int, bodyStart: Int) {
        skipStreamEOL()
        let dataStart = position

        var dataEnd: Int?
        if let len = directLength(in: dict),
           dataStart + len <= data.count,
           looksLikeEndStream(at: dataStart + len) {
            dataEnd = dataStart + len
        } else if let marker = findEndStream(from: dataStart) {
            var end = marker
            while end > dataStart {
                let b = data[data.startIndex + end - 1]
                if b == 0x0A || b == 0x0D || b == 0x20 { end -= 1 } else { break }
            }
            dataEnd = end
        }

        guard let de = dataEnd else {
            recoverRaw(objectNumber: n, from: bodyStart)
            return
        }

        var finalDict = dict
        finalDict["Length"] = .number(Double(de - dataStart))
        objects[n] = .stream(PDFStreamObj(
            dict: finalDict,
            data: data[(data.startIndex + dataStart)..<(data.startIndex + de)]
        ))

        position = de
        skipWhitespace()
        _ = matchKeyword("endstream")
        finishObject()
    }

    private func recoverRaw(objectNumber n: Int, from start: Int) {
        if let marker = findKeyword("endobj", from: start) {
            var rawEnd = marker
            while rawEnd > start {
                let b = data[data.startIndex + rawEnd - 1]
                if b == 0x0A || b == 0x0D || b == 0x20 { rawEnd -= 1 } else { break }
            }
            objects[n] = .source(data[(data.startIndex + start)..<(data.startIndex + rawEnd)])
            position = marker + 6
        } else {
            objects[n] = .object(.null)
            position = data.count
        }
    }

    private func finishObject() {
        skipWhitespaceAndComments()
        _ = matchKeyword("endobj")
    }

    // MARK: - Stream helpers

    private func directLength(in dict: [String: PDFObject]) -> Int? {
        guard case .number(let v)? = dict["Length"], v >= 0, v < 1_099_511_627_776 else { return nil }
        return Int(v)
    }

    private func looksLikeEndStream(at offset: Int) -> Bool {
        var i = offset
        if i < data.count && data[data.startIndex + i] == 0x0D { i += 1 }
        if i < data.count && data[data.startIndex + i] == 0x0A { i += 1 }
        guard i + 9 <= data.count else { return false }
        return data[(data.startIndex + i)..<(data.startIndex + i + 9)] == Data("endstream".utf8)
    }

    private func findEndStream(from start: Int) -> Int? {
        findKeyword("endstream", from: max(0, start))
    }

    private func findKeyword(_ keyword: String, from start: Int) -> Int? {
        guard start < data.count else { return nil }
        let sliceStart = data.startIndex + start
        let r = data[sliceStart...].range(of: Data(keyword.utf8))
        guard let r else { return nil }
        return data.distance(from: data.startIndex, to: r.lowerBound)
    }

    // MARK: - Tokenizing

    private func skipWhitespaceAndComments() {
        while position < data.count {
            let b = data[data.startIndex + position]
            if b == 0x25 {
                while position < data.count {
                    let c = data[data.startIndex + position]
                    position += 1
                    if c == 0x0A || c == 0x0D { break }
                }
            } else if isWhitespace(b) {
                position += 1
            } else {
                break
            }
        }
    }

    private func skipWhitespace() {
        while position < data.count, isWhitespace(data[data.startIndex + position]) {
            position += 1
        }
    }

    private func isWhitespace(_ b: UInt8) -> Bool {
        switch b {
        case 0x20, 0x0A, 0x0D, 0x09, 0x00, 0x0C: return true
        default: return false
        }
    }

    private func isDelimiterOrSpace(_ b: UInt8) -> Bool {
        switch b {
        case 0x20, 0x0A, 0x0D, 0x09, 0x00, 0x0C,
             0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25:
            return true
        default:
            return false
        }
    }

    private func skipStreamEOL() {
        if position < data.count, data[data.startIndex + position] == 0x0D { position += 1 }
        if position < data.count, data[data.startIndex + position] == 0x0A { position += 1 }
    }

    private func readPlainInt() -> Int? {
        var value = 0
        var digits = 0
        while position < data.count {
            let b = data[data.startIndex + position]
            guard b >= 0x30 && b <= 0x39 else { break }
            value = value &* 10 &+ Int(b - 0x30)
            digits += 1
            position += 1
        }
        guard digits > 0, digits <= 11 else { return nil }
        return value
    }

    private func matchKeyword(_ keyword: String) -> Bool {
        let bytes = Array(keyword.utf8)
        guard position + bytes.count <= data.count else { return false }
        for (i, b) in bytes.enumerated() {
            if data[data.startIndex + position + i] != b { return false }
        }
        let next = position + bytes.count
        if next < data.count, !isDelimiterOrSpace(data[data.startIndex + next]) {
            return false
        }
        position = next
        return true
    }

    // MARK: - Object parsing

    private func parseObject() -> PDFObject? {
        skipWhitespace()
        guard position < data.count else { return nil }
        let b = data[data.startIndex + position]

        switch b {
        case 0x3C:
            if position + 1 < data.count, data[data.startIndex + position + 1] == 0x3C {
                return parseDictionary()
            }
            return parseHexString()
        case 0x5B:
            return parseArray()
        case 0x2F:
            return parseName()
        case 0x28:
            return parseLiteralString()
        case 0x74 where matchKeyword("true"):
            return .boolean(true)
        case 0x66 where matchKeyword("false"):
            return .boolean(false)
        case 0x6E where matchKeyword("null"):
            return .null
        default:
            return parseNumberOrReference()
        }
    }

    private func parseDictionary() -> PDFObject? {
        guard position + 1 < data.count,
              data[data.startIndex + position] == 0x3C,
              data[data.startIndex + position + 1] == 0x3C else { return nil }
        position += 2
        var dict: [String: PDFObject] = [:]

        while true {
            skipWhitespaceAndComments()
            guard position + 1 < data.count else { return nil }
            if data[data.startIndex + position] == 0x3E &&
               data[data.startIndex + position + 1] == 0x3E {
                position += 2
                return .dict(dict)
            }
            guard data[data.startIndex + position] == 0x2F,
                  let keyObj = parseName(), case .name(let key) = keyObj else {
                if position < data.count, data[data.startIndex + position] != 0x3E {
                    _ = parseObject()
                } else if position < data.count {
                    position += 1
                }
                continue
            }
            guard let value = parseObject() else { return nil }
            dict[key] = value
        }
    }

    private func parseArray() -> PDFObject {
        position += 1
        var items: [PDFObject] = []
        while true {
            skipWhitespace()
            guard position < data.count else { break }
            if data[data.startIndex + position] == 0x5D {
                position += 1
                break
            }
            guard let item = parseObject() else { break }
            items.append(item)
        }
        return .array(items)
    }

    private func parseName() -> PDFObject? {
        position += 1
        var bytes: [UInt8] = []
        while position < data.count {
            let b = data[data.startIndex + position]
            if isDelimiterOrSpace(b) { break }
            if b == 0x23, position + 2 < data.count,
               let h1 = hexVal(data[data.startIndex + position + 1]),
               let h2 = hexVal(data[data.startIndex + position + 2]) {
                bytes.append(h1 << 4 | h2)
                position += 3
            } else {
                bytes.append(b)
                position += 1
            }
        }
        guard !bytes.isEmpty else { return nil }
        return .name(String(decoding: bytes, as: UTF8.self))
    }

    private func hexVal(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x41 + 10
        case 0x61...0x66: return b - 0x61 + 10
        default: return nil
        }
    }

    private func parseLiteralString() -> PDFObject {
        let start = position
        position += 1
        var depth = 1
        while position < data.count {
            let b = data[data.startIndex + position]
            if b == 0x5C {
                position += 2
                continue
            }
            if b == 0x28 { depth += 1 }
            if b == 0x29 {
                depth -= 1
                position += 1
                if depth == 0 { break }
            } else {
                position += 1
            }
        }
        return .raw(data[(data.startIndex + start)..<(data.startIndex + min(position, data.count))])
    }

    private func parseHexString() -> PDFObject {
        let start = position
        position += 1
        while position < data.count {
            let b = data[data.startIndex + position]
            position += 1
            if b == 0x3E { break }
        }
        return .raw(data[(data.startIndex + start)..<(data.startIndex + min(position, data.count))])
    }

    private func parseNumberOrReference() -> PDFObject? {
        skipWhitespace()
        guard position < data.count else { return nil }

        var idx = data.startIndex + position
        let tokenStart = idx
        var seenDigit = false
        var seenDot = false

        while idx < data.endIndex {
            let b = data[idx]
            if b >= 0x30 && b <= 0x39 { seenDigit = true }
            else if b == 0x2E {
                if seenDot { break }
                seenDot = true
            }
            else if b == 0x2D || b == 0x2B {
                if seenDigit || idx > tokenStart { break }
            }
            else { break }
            idx = data.index(after: idx)
        }
        guard seenDigit else {
            position += 1
            return .raw(data[idx..<(data.startIndex + min(position, data.count))])
        }

        let text = String(decoding: data[tokenStart..<idx], as: UTF8.self)
        position += data.distance(from: tokenStart, to: idx)

        guard let firstNumber = Double(text) else { return .null }

        let save = position
        skipWhitespace()
        if readPlainInt() != nil {
            skipWhitespace()
            if matchKeyword("R") {
                return .reference(Int(firstNumber))
            }
        }
        position = save
        return .number(firstNumber)
    }

    // MARK: - Object streams

    private func expandObjectStreams() {
        let containerNumbers = objects.compactMap { (num, entry) -> Int? in
            guard case .stream(let s) = entry,
                  case .name("ObjStm")? = s.dict["Type"] else { return nil }
            return num
        }

        for container in containerNumbers {
            guard case .stream(let s)? = objects[container],
                  let count = intValue(s.dict["N"]),
                  let firstOffset = intValue(s.dict["First"]),
                  let inflated = Self.inflate(s.data) else { continue }

            let bytes = Array(inflated)
            var pairs: [(num: Int, offset: Int)] = []
            var cursor = 0

            for _ in 0..<count {
                var num = 0
                var digits = 0
                while cursor < bytes.count, bytes[cursor] >= 48 && bytes[cursor] <= 57 {
                    num = num * 10 + Int(bytes[cursor] - 48)
                    digits += 1
                    cursor += 1
                }
                guard digits > 0 else { break }
                while cursor < bytes.count, isWhitespace(bytes[cursor]) { cursor += 1 }

                var rel = 0
                digits = 0
                while cursor < bytes.count, bytes[cursor] >= 48 && bytes[cursor] <= 57 {
                    rel = rel * 10 + Int(bytes[cursor] - 48)
                    digits += 1
                    cursor += 1
                }
                guard digits > 0 else { break }
                pairs.append((num, rel))
            }

            for (i, pair) in pairs.enumerated() {
                let start = firstOffset + pair.offset
                let end = i + 1 < pairs.count ? firstOffset + pairs[i + 1].offset : inflated.count
                guard start <= end, end <= inflated.count else { continue }
                let chunk = inflated.subdata(in: start..<end)

                if topLevelNumbers.contains(pair.num) { continue }

                let sub = PDFDocumentFile(standaloneData: chunk)
                sub.skipWhitespace()
                if let obj = sub.parseObject() {
                    objects[pair.num] = .object(obj)
                }
            }
        }
    }

    private func intValue(_ obj: PDFObject?) -> Int? {
        guard case .number(let v)? = obj, v >= 0 else { return nil }
        return Int(v)
    }

    // MARK: - Trailer / encryption

    private func resolveEncryption() throws {
        for entry in objects.values {
            if case .stream(let s) = entry,
               case .name("XRef")? = s.dict["Type"],
               s.dict["Encrypt"] != nil {
                throw PDFError.encrypted
            }
        }
    }

    private func resolveRoot() {
        var searchFrom = data.count
        while searchFrom > 0 {
            let windowStart = max(0, searchFrom - 8192)
            guard windowStart < searchFrom else { break }
            let slice = data.subdata(in: windowStart..<searchFrom)
            if let r = slice.range(of: Data("/Root".utf8)) {
                let afterAbs = windowStart + slice.distance(from: slice.startIndex, to: r.upperBound)
                let sub = PDFDocumentFile(standaloneData: data.subdata(
                    in: afterAbs..<min(afterAbs + 512, data.count)))
                sub.skipWhitespace()
                if let obj = sub.parseObject(), case .reference(let ref) = obj {
                    rootRef = ref
                    return
                }
            }
            searchFrom = windowStart
        }
    }

    // MARK: - Writing

    func serialize() -> Data {
        var out = Data("%PDF-1.6\n".utf8)
        out.append(contentsOf: [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A])

        var offsets: [Int: Int] = [:]
        let numbers = objects.keys.sorted()

        for num in numbers {
            offsets[num] = out.count
            append(objectNumber: num, to: &out)
        }

        let xrefOffset = out.count
        let size = (numbers.max() ?? 0) + 1
        out.append(Data("xref\n0 \(size)\n".utf8))
        out.append(Data("0000000000 65535 f \n".utf8))
        for num in 1..<size {
            if let off = offsets[num] {
                out.append(Data(String(format: "%010d 00000 n \n", off).utf8))
            } else {
                out.append(Data("0000000000 65535 f \n".utf8))
            }
        }

        var trailer = "<< /Size \(size)"
        if let rootRef {
            trailer += " /Root \(rootRef) 0 R"
        }
        trailer += " >>"
        out.append(Data("trailer\n".utf8))
        out.append(Data(trailer.utf8))
        out.append(Data("\nstartxref\n\(xrefOffset)\n%%EOF\n".utf8))
        return out
    }

    private func append(objectNumber n: Int, to out: inout Data) {
        out.append(Data("\(n) 0 obj\n".utf8))

        switch objects[n] {
        case .object(let obj):
            out.append(Self.serialize(obj))
        case .stream(let s):
            out.append(Self.serializeDict(s.dict))
            out.append(Data("\nstream\n".utf8))
            out.append(s.data)
            out.append(Data("\nendstream".utf8))
        case .source(let raw):
            out.append(raw)
        case .none:
            out.append(Data("null".utf8))
        }

        out.append(Data("\nendobj\n".utf8))
    }

    static func serializeDict(_ dict: [String: PDFObject]) -> Data {
        var out = Data("<<".utf8)
        for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
            out.append(Data(" /\(escapeName(key)) ".utf8))
            out.append(serialize(value))
        }
        out.append(Data(" >>".utf8))
        return out
    }

    static func serialize(_ obj: PDFObject) -> Data {
        switch obj {
        case .dict(let d):
            return serializeDict(d)
        case .array(let items):
            var out = Data("[".utf8)
            for item in items {
                out.append(serialize(item))
                out.append(Data(" ".utf8))
            }
            out.append(Data("]".utf8))
            return out
        case .name(let n):
            return Data("/\(escapeName(n))".utf8)
        case .number(let v):
            if v.rounded() == v && abs(v) < 1e15 {
                return Data("\(Int(v))".utf8)
            }
            return Data("\(v)".utf8)
        case .boolean(let b):
            return Data((b ? "true" : "false").utf8)
        case .reference(let r):
            return Data("\(r) 0 R".utf8)
        case .null:
            return Data("null".utf8)
        case .raw(let d):
            return d
        }
    }

    static func escapeName(_ name: String) -> String {
        var out = ""
        for b in name.utf8 {
            if b < 33 || b > 126 || b == 0x2F || b == 0x23 {
                out += String(format: "#%02X", b)
            } else {
                out.append(Character(UnicodeScalar(b)))
            }
        }
        return out
    }

    // MARK: - Inflate (FlateDecode)

    static func inflate(_ input: Data) -> Data? {
        guard input.count > 2 else { return nil }

        if let result = decodeBuffer(input, skipHeader: true) {
            return result
        }
        return decodeBuffer(input, skipHeader: false)
    }

    private static func decodeBuffer(_ input: Data, skipHeader: Bool) -> Data? {
        let payload = skipHeader ? input.subdata(in: (input.startIndex + 2)..<input.endIndex) : input
        guard !payload.isEmpty else { return nil }

        let capacity = max(64, payload.count * 20)
        var dst = Data(count: capacity)

        let written = dst.withUnsafeMutableBytes { dstPtr -> Int in
            payload.withUnsafeBytes { srcPtr -> Int in
                guard let src = srcPtr.bindMemory(to: UInt8.self).baseAddress,
                      let dstBase = dstPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dstBase, capacity, src, payload.count, nil, COMPRESSION_ZLIB)
            }
        }

        guard written > 0 else { return nil }
        return dst.prefix(written)
    }

    // MARK: - Standalone parsing helper

    private convenience init(standaloneData: Data) {
        self.init(empty: ())
        self.data = standaloneData
    }

    private init(empty: Void) {
        self.data = Data()
        self.originalSize = 0
    }

    // MARK: - Mutation API

    func replaceStream(number n: Int, dict: [String: PDFObject], data newData: Data) {
        objects[n] = .stream(PDFStreamObj(dict: dict, data: newData))
    }

    func streamEntry(number n: Int) -> PDFStreamObj? {
        guard case .stream(let s)? = objects[n] else { return nil }
        return s
    }

    func imageObjectNumbers() -> [Int] {
        objects.compactMap { (num, entry) in
            guard case .stream(let s) = entry,
                  case .name("Image")? = s.dict["Subtype"] else { return nil }
            return num
        }.sorted()
    }
}
