import Foundation
import CoreGraphics

/// Phase 6C (Roadmap) – kontrollierter CMYK-JPEG-Re-Encode: Freischaltung,
/// Grenzwerte und Gate.
///
/// Der Pfad kodiert vierkanalige Druckdaten als YCCK-JPEG über den eigenen
/// mozjpeg-Shim (`pdfcore_jpeg_encode_cmyk`, transform 2, 4:4:4) und ist
/// damit der einzige verlustbehaftete CMYK-Eingriff der Pipeline. Zwei
/// Leitplanken machen ihn kontrolliert:
///
///  1. ER ist EIN KANDIDAT, keine Entscheidung: Der verlustfreie 6b-Repack
///     des Originals läuft zuerst (Executor) und bildet die Größenbarriere –
///     der Re-Encode gewinnt nur, wenn er STRENG kleiner ist. Scheitert er
///     am Gate, bleibt es beim Behalten, und der Repack übernimmt.
///  2. Das Gate rechnet NICHT in CMYK: Kandidat und Referenz werden nach
///     RGB gerendert/dekodiert (CoreGraphics: CMYK→RGB über den generischen
///     CMYK-Umlauf, beide Seiten identisch behandelt) und dort mit den
///     bestehenden QualityGates-Metriken verglichen – ΔE76 auf der
///     gemeinsamen Stichprobe, plus einer Kachel-Obergrenze, damit eine
///     lokale Farbkatatstrophe nicht im Mittelwert untergeht.
///
/// Die Grenzwerte stehen im Matrix-Stil der QualityGatePolicy (Preset ×
/// Pfad) hier und nicht als Zellen in `QualityGateClass`: CMYK ist ein
/// Farbraum-Pfad, keine Bildklasse der Klassifikation, und die exhaustive
/// Grenzwert-Testsuite der Matrix bliebe unangetastet.
enum CMYKReencode {

    // MARK: - Freischaltung (Planner-Ebene)

    /// Darf dieses Bild den kontrollierten CMYK-Re-Encode bestreiten?
    ///
    /// - Preset: nur Quality (SSIM-Zusage 0,95). Das interne Maximum-Preset
    ///   fährt die Bildwerte von Quality und teilt deshalb dessen Zeile.
    ///   Custom folgt der bestehenden Aggressive-Ausnahme: Nur mit
    ///   `aggressiveGraphics` UND nur bei echtem Größenüberhang – derselbe
    ///   „clearlyOversized“-Schutz wie im RGB-Grafikpfad.
    ///   Smart/Klein bleiben verlustfrei (6a/6b-Pfade).
    /// - Farbraum: DeviceCMYK oder ICCBased-4 (genau die, die
    ///   `allowsLossyReplacement` ausschließen).
    /// - Struktur: JPEG-Input ohne Vorfilter – der Race-Gegner ist der
    ///   6b-Repack, der nur an reinen DCT-Streams existiert.
    /// - Kein /Decode, keine Maske: Die bestehende Verweigerungspolitik wird
    ///   für den verlustbehafteten CMYK-Pfad bewusst STRENGER gezogen als
    ///   die Capability (ein verschobener Tonwert trifft bei Druckdaten
    ///   härter als im Seitenbild).
    static func lossyAllowed(resource: PDFImageResource,
                             options: ImageCompressionOptions) -> Bool {
        guard resource.terminalFilter == .dct,
              resource.filters == [.dct],
              resource.unknownFilters.isEmpty,
              !resource.hasSoftMask,
              !resource.hasExplicitMask,
              !resource.hasColorKeyMask,
              !resource.isImageMask,
              !resource.hasDecodeArray,
              resource.colorSpace.allowsLossyReplacement == false
        else { return false }

        let preset = QualityGatePreset(ssimThreshold: options.ssimThreshold)
        switch preset {
        case .quality:
            return true
        case .custom:
            guard options.aggressiveGraphics else { return false }
            let clearlyOversized = resource.maxEdge > options.maxPixelEdge
                || (resource.effectiveDPI ?? 0) > options.targetDPI * 1.5
            return clearlyOversized
        case .small, .smart:
            // Verlustfrei: 6a (Flate-Resample) und 6b (Repack) sind hier die
            // einzigen CMYK-Pfade.
            return false
        }
    }

    // MARK: - Grenzwerte (Matrix-Stil)

    struct Limits {
        /// SSIM-Zellen im Stil der QualityGatePolicy; die ΔE-Zelle trägt die
        /// Mittler-Grenze und wird von `QualityGates.qualityVerdict`
        /// ausgewertet (ΔE76 auf der RGB-Stichprobe).
        let policy: QualityGatePolicy
        /// Kachel-Obergrenze: keine 8×8-Kachel der Stichprobe darf ΔE76
        /// darüber verlieren – der lokale Schutz, den ein Mittelwert nicht
        /// bieten kann.
        let maxTileDeltaE76: Double
    }

    /// Grenzwerte je Preset. Ableitung wie in der bestehenden Matrix: Die
    /// SSIM-Zeile ist die Foto-Zeile des Presets (Druckmaterial ist
    /// Typfoto-Material), die ΔE-Grenze ist BEWUSST strenger als dort –
    /// gemessen liegen reine JPEG-Kandidaten (q0,85) auf CMYK-Fixtures bei
    /// ΔE ≈ 1, also bleibt 2,0 eine echte Sperre mit Abstand. Custom behält
    /// die Katakasten-Floors des Nutzerpfads (keine globale SSIM-Grenze,
    /// ΔE 30 wie in der Custom-Zeile). Small/Smart erreichen den Pfad nicht;
    /// sie erben die Quality-Zeile, damit die Tabelle total bleibt.
    static func limits(preset: QualityGatePreset) -> Limits {
        switch preset {
        case .quality, .small, .smart:
            return Limits(
                policy: QualityGatePolicy(globalSSIM: 0.95, p05TileSSIM: 0.85,
                                          edgeWeightedScore: 0.83,
                                          textRegionScore: nil,
                                          maxDeltaE76: 2.0),
                maxTileDeltaE76: 6.0)
        case .custom:
            return Limits(
                policy: QualityGatePolicy(globalSSIM: nil, p05TileSSIM: 0.45,
                                          edgeWeightedScore: 0.45,
                                          textRegionScore: nil,
                                          maxDeltaE76: 30.0),
                maxTileDeltaE76: 60.0)
        }
    }

    // MARK: - Adobe-APP14

    /// Transform-Byte des Adobe-APP14-Markers (0 = CMYK, 2 = YCCK); nil ohne
    /// Marker. Ohne ihn deuten Leser die vier Platten falsch – ein Kandidat
    /// ohne Marker ist kein Kandidat. APP14 steht vor dem ersten Scan
    /// (Start of Scan), danach folgt Entropiedaten: dort endet der Scan.
    static func adobeTransformByte(_ jpeg: Data) -> Int? {
        let bytes = [UInt8](jpeg)
        var i = 2
        while i + 4 < bytes.count {
            guard bytes[i] == 0xFF else { return nil }
            let marker = Int(bytes[i + 1])
            if marker == 0xFF || marker == 0x01 || (0xD0...0xD7).contains(marker) {
                i += 2
                continue
            }
            let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            if marker == 0xEE, length >= 14,
               jpeg.subdata(in: (i + 4)..<(i + 9)) == Data("Adobe".utf8) {
                return Int(bytes[i + 4 + 11])
            }
            if marker == 0xDA { return nil }   // SOS: danach Entropiedaten
            i += 2 + length
        }
        return nil
    }

    // MARK: - Gate

    /// Prüft einen CMYK-JPEG-Kandidaten gegen die CMYK-Referenz (beide
    /// Seiten gehen durch dieselbe RGB-Render-Stichprobe). `false` heißt:
    /// Kandidat verwerfen, der 6b-Repack des Originals bleibt.
    static func passesGate(reference: CGImage,
                           candidateJPEG: Data,
                           limits: Limits) -> Bool {
        // Marker-Erhalt: transform 2 ist das geschriebene YCCK-Format.
        guard adobeTransformByte(candidateJPEG) == 2 else { return false }
        guard let candidate = ImageResampler.decodeJPEG(candidateJPEG),
              let referenceSample = QualityGates.sample(reference),
              let candidateSample = QualityGates.sample(candidate)
        else { return false }
        guard let measurement = QualityGates.measure(reference: referenceSample,
                                                     candidate: candidateSample)
        else { return false }
        if case .fail = QualityGates.qualityVerdict(policy: limits.policy,
                                                    measurement: measurement) {
            return false
        }
        // Lokale Kachel-Katastrophen abfangen, die der Mittelwert versteckt.
        guard let maxTile = maxTileDeltaE76(reference: referenceSample,
                                            candidate: candidateSample) else {
            return false
        }
        return maxTile <= limits.maxTileDeltaE76
    }

    /// Höchster ΔE76 über die Kacheln der gemeinsamen Stichprobe – dieselbe
    /// Kachelgeometrie wie `QualityGates.tileScores`, aber pro Kachel ein
    /// eigener ΔE-Vergleich auf den RGBA-Bytes.
    static func maxTileDeltaE76(reference: QualityGates.Sample,
                                candidate: QualityGates.Sample) -> Double? {
        guard reference.width == candidate.width,
              reference.height == candidate.height else { return nil }
        let w = reference.width, h = reference.height
        let tileW = max(8, w / QualityGates.tileGrid)
        let tileH = max(8, h / QualityGates.tileGrid)
        var maximum: Double?

        var tileY = 0
        while tileY < h {
            let height = min(tileH, h - tileY)
            var tileX = 0
            while tileX < w {
                let width = min(tileW, w - tileX)
                var referenceRGBA = [UInt8]()
                var candidateRGBA = [UInt8]()
                referenceRGBA.reserveCapacity(width * height * 4)
                candidateRGBA.reserveCapacity(width * height * 4)
                for y in tileY..<(tileY + height) {
                    let start = (y * w + tileX) * 4
                    let end = start + width * 4
                    referenceRGBA.append(contentsOf:
                        reference.rgba[start..<end])
                    candidateRGBA.append(contentsOf:
                        candidate.rgba[start..<end])
                }
                let referenceTile = QualityGates.Sample(
                    width: width, height: height, luma: [],
                    rgba: referenceRGBA, chromaMean: 0)
                let candidateTile = QualityGates.Sample(
                    width: width, height: height, luma: [],
                    rgba: candidateRGBA, chromaMean: 0)
                let delta = QualityGates.meanDeltaE76(reference: referenceTile,
                                                      candidate: candidateTile)
                if delta > (maximum ?? -1) { maximum = delta }
                tileX += width
            }
            tileY += height
        }
        return maximum
    }
}
