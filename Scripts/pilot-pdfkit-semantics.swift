import Foundation
import PDFKit
// All-page text and UTF-16 character geometry; no rendering or text normalization.
guard CommandLine.arguments.count == 3,
      let source = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1])),
      let candidate = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[2])) else {
    fputs("Cannot open pair\n", stderr); exit(2)
}
let tolerancePoints = 0.000001 // Far below one render pixel; handles PDF floating point serialization.
func delta(_ a: CGRect, _ b: CGRect) -> Double {
    let values = [abs(a.origin.x-b.origin.x), abs(a.origin.y-b.origin.y), abs(a.width-b.width), abs(a.height-b.height)]
    return values.allSatisfy { $0.isFinite } ? Double(values.max()!) : Double.greatestFiniteMagnitude
}
var pages: [[String: Any]] = []
if source.pageCount == candidate.pageCount {
    for i in 0..<source.pageCount {
        guard let a = source.page(at: i), let b = candidate.page(at: i) else { exit(2) }
        let textEqual = a.string == b.string
        var differences = 0
        var maximumCharacterDelta = 0.0
        var examples: [[String: Any]] = []
        if a.numberOfCharacters == b.numberOfCharacters {
            for j in 0..<a.numberOfCharacters {
                maximumCharacterDelta = max(maximumCharacterDelta, delta(a.characterBounds(at: j), b.characterBounds(at: j)))
                if a.characterBounds(at: j) != b.characterBounds(at: j) {
                    differences += 1
                    if examples.count < 4 { examples.append(["index": j, "source": NSStringFromRect(a.characterBounds(at: j)), "candidate": NSStringFromRect(b.characterBounds(at: j))]) }
                }
            }
        } else { differences = max(a.numberOfCharacters, b.numberOfCharacters); maximumCharacterDelta = Double.greatestFiniteMagnitude }
        pages.append(["page": i+1, "text_equal": textEqual,
                      "maximum_character_delta_points": maximumCharacterDelta,
                      "media_box_delta_points": delta(a.bounds(for: .mediaBox), b.bounds(for: .mediaBox)),
                      "crop_box_delta_points": delta(a.bounds(for: .cropBox), b.bounds(for: .cropBox)),
                      "characters": a.numberOfCharacters, "bounds_examples": examples,
                      "source_media_box": NSStringFromRect(a.bounds(for: .mediaBox)),
                      "candidate_media_box": NSStringFromRect(b.bounds(for: .mediaBox)),
                      "source_crop_box": NSStringFromRect(a.bounds(for: .cropBox)),
                      "candidate_crop_box": NSStringFromRect(b.bounds(for: .cropBox)), "character_bounds_differences": differences,
                      "media_box_equal": a.bounds(for: .mediaBox) == b.bounds(for: .mediaBox),
                      "crop_box_equal": a.bounds(for: .cropBox) == b.bounds(for: .cropBox),
                      "rotation_equal": a.rotation == b.rotation])
    }
}
let pass = source.pageCount == candidate.pageCount && pages.allSatisfy {
    ($0["text_equal"] as! Bool) && ($0["maximum_character_delta_points"] as! Double) <= tolerancePoints &&
    ($0["media_box_delta_points"] as! Double) <= tolerancePoints && ($0["crop_box_delta_points"] as! Double) <= tolerancePoints && ($0["rotation_equal"] as! Bool)
}
let result: [String: Any] = ["pass": pass, "geometry_tolerance_points": tolerancePoints, "source_pages": source.pageCount,
                             "candidate_pages": candidate.pageCount, "pages": pages]
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print(String(data: data, encoding: .utf8)!)
exit(pass ? 0 : 1)
