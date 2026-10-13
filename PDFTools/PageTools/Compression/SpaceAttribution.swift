import Foundation
import pdfcore

/// Masterplan §7.5 – Native Byte-Attribution: „Wo liegen die Bytes?"
///
/// Swift-Sicht auf `pdfcore_space_inventory`. Die Definitionen stehen im
/// Header-Kommentar von `pdfcore_space_inventory` und sind die verbindliche
/// Referenz:
///
///   - Grundlage sind alle indirekten Objekte; Streambytes sind immer die
///     KODIERTEN (rohen) Bytes.
///   - Bilder über /Subtype /Image, Klasse nach letztem bekannten Filter
///     (DCTDecode→jpeg, JPXDecode→jpx, CCITTFaxDecode→ccitt,
///     JBIG2Decode→jbig2, FlateDecode→flate_image, sonst other_image).
///   - Fonts über /Type FontFile* oder vorhandenes /Length1.
///   - Content über /Subtype /Form und die /Contents-Streams der Seiten.
///   - /ObjStm eigene Kategorie; alles Übrige inkl. Nicht-Stream-Syntax
///     (xref, Objektköpfe, Wörterbücher) zählt als unattributed:
///     `unattributedBytes = documentBytes − Σ(Kategorien)` (auf 0 geklemmt).
///
/// `documentBytes` liefert der Aufrufer (Dateigröße der Eingabe); die
/// Messung ist deterministisch und mit derselben Definition vor/nach jedem
/// Pass anwendbar – genau das ist der Sinn der Kategorie.
///
/// Abweichungen gegenüber `Scripts/byte-attribution.py` (das als
/// unabhängige Referenz bestehen bleibt, gemessen an
/// `Benchmarks/adhoc/PDF-Dokument.pdf` und statab_2012):
///   - Das Skript rechnet /ObjStm- und unklassifizierte Streams implizit in
///     seine `structure_estimate`. Hier ist /ObjStm eine eigene Kategorie,
///     unklassifizierte Streams zählen in `unattributedBytes`. Es gilt
///     `unattributedBytes(hier) = structure_estimate(Skript)
///     − objectStreamBytes`.
///   - Das Skript liest die Streamlänge aus der /Length-Auflösung des JSON-
///     Exports; hier zählt `getRawStreamData()` – dieselbe Ebene, aber bei
///     kaputten /Length-Angaben kann die Restbilanz minimal abweichen.
struct DocumentSpaceInventory: Equatable, Sendable, Codable {
    let documentBytes: Int64
    let jpegBytes: Int64
    let jpxBytes: Int64
    let ccittBytes: Int64
    let jbig2Bytes: Int64
    let flateImageBytes: Int64
    let otherImageBytes: Int64
    let fontProgramBytes: Int64
    let contentStreamBytes: Int64
    let metadataBytes: Int64
    let embeddedFileBytes: Int64
    let objectStreamBytes: Int64
    let unattributedBytes: Int64

    var imageBytesTotal: Int64 {
        jpegBytes + jpxBytes + ccittBytes + jbig2Bytes
            + flateImageBytes + otherImageBytes
    }

    /// Summe der explizit attribuierten Kategorien (ohne unattributed).
    var attributedBytes: Int64 {
        imageBytesTotal + fontProgramBytes + contentStreamBytes
            + metadataBytes + embeddedFileBytes + objectStreamBytes
    }

    func value(forKey key: CategoryKey) -> Int64 {
        switch key {
        case .jpeg: return jpegBytes
        case .jpx: return jpxBytes
        case .ccitt: return ccittBytes
        case .jbig2: return jbig2Bytes
        case .flateImage: return flateImageBytes
        case .otherImage: return otherImageBytes
        case .fontProgram: return fontProgramBytes
        case .contentStream: return contentStreamBytes
        case .metadata: return metadataBytes
        case .embeddedFile: return embeddedFileBytes
        case .objectStream: return objectStreamBytes
        case .unattributed: return unattributedBytes
        }
    }

    enum CategoryKey: String, CaseIterable, Sendable {
        case jpeg, jpx, ccitt, jbig2, flateImage, otherImage
        case fontProgram, contentStream, metadata, embeddedFile
        case objectStream, unattributed
    }
}
