import Foundation
import CoreGraphics

// MARK: - Phase 7 (Roadmap) – SSIM-Multi-Gate statt globaler SSIM
//
// Q = min(global_SSIM, p05_tile_SSIM, edge_weighted_score, text_region_score)
//
// Der globale SSIM-Mittelwert versteckt lokale Katastrophen: Ein Bericht voller
// Text- und Diagrammflächen kann durch die überwiegend weißen Flächen einen
// akzeptablen Mittelwert melden, während die Text- und Kantenkacheln längst
// verwaschen sind – dokumentiert als SSIM 0,497 bei 45,9 % veränderter Fläche
// (Corpuslauf 29.08.2026, IPCC-Bericht, aggressive Custom-Einstellung). Das
// Multi-Gate prüft deshalb zusätzlich das 5-%-Perzentil der Kachel-SSIMs, die
// kantengewichtete Bewertung und das Minimum über Text-Kacheln.
//
// PSNR bleibt Debug-Metrik; Farbfehler (Mean ΔE76) wird nur für Farbdokumente
// geprüft. Alle Metriken teilen sich EINE Downsample-Stichprobe (gleiche
// Kante wie `QualityMetrics.sampleEdge`), die Referenz wird pro Bild EINMAL
// gesampelt und für alle Qualitätsstufen der Leiter wiederverwendet.

/// Bildklasse der Grenzwerttabelle. Die Namen folgen dem bestehenden Modell:
/// `ImageClass` kennt photo/graphics; bilevel und screenshot sind die im
/// Planner und in den Fixtures etablierten Bezeichnungen
/// (`BilevelDetection`, `screenshotLikePDF`).
enum QualityGateClass: String, CaseIterable, Sendable {
    case photo
    /// Kontinuierliche Farb-/Graustufen-Scans: Text und Kanten werden anders
    /// gewichtet als bei Fotos, Farbtreue bleibt aber relevant.
    case scan
    case graphics
    case bilevel
    case screenshot

    /// Ableitung aus der bestehenden Klassifikation.
    init(_ imageClass: ImageClass) {
        switch imageClass {
        case .photo: self = .photo
        case .graphics: self = .graphics
        }
    }
}

/// Preset-Achse der Grenzwerttabelle. small/smart/quality entsprechen den
/// benannten `ImageCompressionOptions` (SSIM-Zusage 0.86/0.90/0.95); das
/// Maximum-Preset fährt die Bildwerte von `quality` und teilt daher dessen
/// Zeile. `custom` ist der Nutzerpfad mit fester Qualität – dort gilt heute
/// bewusst KEIN Qualitätsgate (CompressionPresetFactory.custom); das Multi-
/// Gate bleibt auch dort nur Katakasten-Schutz, nicht Geschmacksrichter.
enum QualityGatePreset: String, CaseIterable, Sendable {
    case small
    case smart
    case quality
    case custom

    /// Preset zu einer SSIM-Schwelle der bestehenden Konfiguration.
    init(ssimThreshold: Double) {
        switch ssimThreshold {
        case ImageCompressionOptions.small.ssimThreshold: self = .small
        case ImageCompressionOptions.smart.ssimThreshold: self = .smart
        case ImageCompressionOptions.quality.ssimThreshold: self = .quality
        default: self = .custom
        }
    }
}

/// Geprüfte Metriken – für die Begründung eines Fehlentscheids.
enum QualityGateMetric: String, Equatable, Sendable {
    case globalSSIM
    case p05TileSSIM
    case edgeWeightedScore
    case textRegionScore
    case deltaE76
}

/// Grenzwerte einer Preset/Klasse-Zelle. `nil` heißt: Diese Metrik wird in
/// der Zelle nicht geprüft (z. B. Text-Score auf Fotos, ΔE auf Bilevel).
struct QualityGatePolicy: Equatable, Sendable {
    var globalSSIM: Double?
    var p05TileSSIM: Double
    var edgeWeightedScore: Double
    var textRegionScore: Double?
    var maxDeltaE76: Double?

    /// Die Grenzwerttabelle (Preset × Klasse).
    ///
    /// Ableitung (gemessen an synthetischen Fixtures, siehe
    /// QualityGatesTests): Die globale SSIM-Grenze für Fotos IST die
    /// bestehende Zusage des Presets (0.86/0.90/0.95) – der bisherige
    /// Entscheid wird damit NICHT strenger. Die übrigen Grenzen liegen
    /// darunter und greifen erst, wo einzelne Kacheln katastrophal abreißen,
    /// während der Mittelwert noch freundlich aussieht. Verankerung:
    /// Leichte JPEG-Artefakte (q0.75) messen global 0.986 / p05 0.985 /
    /// ΔE 1.4 – weit über allen Foto-Grenzen. Die konstruierte Text-
    /// Katastrophe (verwaschen/verwackelt) misst global 0.894 – über der
    /// smart-Grenze – aber p05 0.695 und Text-Score 0.576: genau der
    /// dokumentierte blinde Fleck (SSIM 0,497), den p05/Text-Score jetzt
    /// abfangen. JPEG q0.05 auf Text-Grafik (global 0.945, p05 0.779) fällt
    /// ebenfalls durch die Kachelgrenzen.
    static func policy(preset: QualityGatePreset,
                       imageClass: QualityGateClass) -> QualityGatePolicy {
        switch (preset, imageClass) {
        case (.small, .photo):
            return .init(globalSSIM: 0.86, p05TileSSIM: 0.76, edgeWeightedScore: 0.74,
                         textRegionScore: nil, maxDeltaE76: 8.0)
        case (.smart, .photo):
            return .init(globalSSIM: 0.90, p05TileSSIM: 0.80, edgeWeightedScore: 0.78,
                         textRegionScore: nil, maxDeltaE76: 6.0)
        case (.quality, .photo):
            return .init(globalSSIM: 0.95, p05TileSSIM: 0.85, edgeWeightedScore: 0.83,
                         textRegionScore: nil, maxDeltaE76: 4.0)
        case (.custom, .photo):
            return .init(globalSSIM: nil, p05TileSSIM: 0.45, edgeWeightedScore: 0.45,
                         textRegionScore: nil, maxDeltaE76: 30.0)

        // Scan-Zelle: etwas mehr Flaechenkompression als die Foto-Zelle,
        // dafuer explizite Text-/Kantenschranken. Das erlaubt niedrigere
        // JPEG-Stufen nur dann, wenn Schrift und Rasterkanten stabil bleiben.
        case (.small, .scan):
            return .init(globalSSIM: 0.84, p05TileSSIM: 0.74, edgeWeightedScore: 0.78,
                         textRegionScore: 0.80, maxDeltaE76: 10.0)
        case (.smart, .scan):
            return .init(globalSSIM: 0.89, p05TileSSIM: 0.82, edgeWeightedScore: 0.84,
                         textRegionScore: 0.86, maxDeltaE76: 8.0)
        case (.quality, .scan):
            return .init(globalSSIM: 0.95, p05TileSSIM: 0.90, edgeWeightedScore: 0.90,
                         textRegionScore: 0.92, maxDeltaE76: 5.0)
        case (.custom, .scan):
            return .init(globalSSIM: nil, p05TileSSIM: 0.50, edgeWeightedScore: 0.55,
                         textRegionScore: 0.55, maxDeltaE76: 30.0)

        case (.small, .graphics):
            return .init(globalSSIM: 0.84, p05TileSSIM: 0.80, edgeWeightedScore: 0.80,
                         textRegionScore: 0.78, maxDeltaE76: 8.0)
        case (.smart, .graphics):
            return .init(globalSSIM: 0.88, p05TileSSIM: 0.86, edgeWeightedScore: 0.86,
                         textRegionScore: 0.86, maxDeltaE76: 6.0)
        case (.quality, .graphics):
            return .init(globalSSIM: 0.93, p05TileSSIM: 0.90, edgeWeightedScore: 0.90,
                         textRegionScore: 0.88, maxDeltaE76: 4.0)
        case (.custom, .graphics):
            return .init(globalSSIM: nil, p05TileSSIM: 0.50, edgeWeightedScore: 0.50,
                         textRegionScore: 0.40, maxDeltaE76: 30.0)

        case (.small, .bilevel), (.smart, .bilevel), (.quality, .bilevel):
            return .init(globalSSIM: 0.995, p05TileSSIM: 0.99, edgeWeightedScore: 0.985,
                         textRegionScore: 0.98, maxDeltaE76: nil)
        case (.custom, .bilevel):
            return .init(globalSSIM: nil, p05TileSSIM: 0.90, edgeWeightedScore: 0.90,
                         textRegionScore: 0.85, maxDeltaE76: nil)

        case (.small, .screenshot):
            return .init(globalSSIM: 0.86, p05TileSSIM: 0.82, edgeWeightedScore: 0.82,
                         textRegionScore: 0.80, maxDeltaE76: 8.0)
        case (.smart, .screenshot):
            return .init(globalSSIM: 0.90, p05TileSSIM: 0.86, edgeWeightedScore: 0.86,
                         textRegionScore: 0.84, maxDeltaE76: 6.0)
        case (.quality, .screenshot):
            return .init(globalSSIM: 0.95, p05TileSSIM: 0.91, edgeWeightedScore: 0.91,
                         textRegionScore: 0.89, maxDeltaE76: 4.0)
        case (.custom, .screenshot):
            return .init(globalSSIM: nil, p05TileSSIM: 0.50, edgeWeightedScore: 0.50,
                         textRegionScore: 0.40, maxDeltaE76: 30.0)
        }
    }

    /// Politik zu einer bestehenden SSIM-Schwelle der Engine-Konfiguration.
    /// Bekannte Zusage-Werte mappen auf ihr Preset; ein fremder Wert in
    /// (0, 1] wird als globale Grenze übernommen, ohne die Katakasten-Floors
    /// aufzugeben. 0 und > 1 (feste Qualität) bleiben ohne globale Grenze.
    /// Smart-Anker (Vertrag 2026-09-29): Smart ist bei normaler Ansicht
    /// mindestens so gut wie JPEG q75 auf dem Zielraster (Smart-Ziel-DPI).
    ///
    /// Die festen Foto-Grenzen (global 0,90) liegen weit unter dem, was q75
    /// misst (≈ 0,97–0,99). Nutzerbefund 2026-10-05: Smart nahm deshalb
    /// 127 DPI mit der niedrigsten Qualitätsstufe – Schrift auf Fotos wurde
    /// sichtbar weich (Bild-SSIM bei 144 DPI 0,93 statt 0,97 des Ankers).
    static let smartAnchorQuality = 0.75
    /// Erlaubt nicht-monotone Messungen benachbarter Qualitätsstufen; ein
    /// sichtbarer Unterschied liegt um eine Größenordnung darüber.
    static let anchorTolerance = 0.002

    static func policy(matching ssimThreshold: Double,
                       imageClass: QualityGateClass) -> QualityGatePolicy {
        let preset = QualityGatePreset(ssimThreshold: ssimThreshold)
        var policy = QualityGatePolicy.policy(preset: preset, imageClass: imageClass)
        if preset == .custom, ssimThreshold > 0, ssimThreshold <= 1.0 {
            policy.globalSSIM = ssimThreshold
        }
        return policy
    }

    // MARK: Masterplan §10.3 – Catastrophic Floor (V2-4, unverhandelbar)

    /// Der KATASTROPHEN-FLOOR – die Mindest-Matrix, die JEDER verlustbehaftete
    /// Kandidat halten muss, ÜBER allen Presets, auch hinter `custom`/fixed
    /// („User preference + Catastrophic safety floor“). Das ist keine
    /// Überstimmung einer ästhetischen Präferenz, sondern Produktsicherheit
    /// (§4: „Unknown Content konservativ“, „Jede lossy Entscheidung besitzt
    /// eine explizite Qualitätsbegründung“).
    ///
    /// Ableitung (dokumentiert): Die Preset-Floors beginnen bei p05 0.76
    /// (small/photo) bzw. global 0.84/0.88/0.90; die dokumentierte Katastrophe
    /// (SSIM 0,497 bei 45,9 % veränderter Fläche, IPCC-Bericht, Corpuslauf
    /// 29.08.2026; an der Multi-Gate-Referenz p05 0.740 / Text 0.576) liegt
    /// weit darunter. Der Floor sitzt dazwischen – deutlich unter den
    /// Preset-Grenzen, klar über der Katastrophe:
    ///
    ///   global 0.70 – Presets beginnen bei 0.84; die 0,497-Katastrophe wird
    ///                 damit niemals ausgeliefert.
    ///   p05    0.60 – unter der kleinsten Preset-Kachelgrenze (0.76), fängt
    ///                 aber den Kollaps einzelner Kacheln ab.
    ///   edge   0.50/0.55 – halb zerstörtes Kantengewebe ist Katastrophe.
    ///   text   0.50     – massiver Textabsturz (zerstörte Textkacheln messen
    ///                 0.3–0.5; leichte Artefakte liegen weit darüber).
    ///   ΔE    KEIN Floor – Farbfehler ist Preset-Sache (Ästhetik), nicht
    ///                 Struktur; §10.3 verbietet das Überstimmen von
    ///                 Farbpräferenzen explizit nicht, verlangt aber nur
    ///                 Katastrophenschutz.
    ///   Bilevel bewusst streng: Es gibt keine lossy-Bilevel-Kandidaten; die
    ///                 Zelle ist ein Sicherheitsnetz, falls je einer entsteht.
    static func catastrophicFloors(for imageClass: QualityGateClass) -> QualityGatePolicy {
        switch imageClass {
        case .photo:
            return .init(globalSSIM: 0.70, p05TileSSIM: 0.60, edgeWeightedScore: 0.50,
                         textRegionScore: nil, maxDeltaE76: nil)
        case .scan:
            return .init(globalSSIM: 0.70, p05TileSSIM: 0.60, edgeWeightedScore: 0.55,
                         textRegionScore: 0.50, maxDeltaE76: nil)
        case .graphics, .screenshot:
            return .init(globalSSIM: 0.70, p05TileSSIM: 0.60, edgeWeightedScore: 0.55,
                         textRegionScore: 0.50, maxDeltaE76: nil)
        case .bilevel:
            return .init(globalSSIM: 0.95, p05TileSSIM: 0.92, edgeWeightedScore: 0.92,
                         textRegionScore: 0.90, maxDeltaE76: nil)
        }
    }

    /// Globale Katastrophen-Grenze für Wege ohne Multi-Gate-Messung
    /// (degeneriertes Sampling): derselbe Wert wie `catastrophicFloors`.
    static let catastrophicGlobalFloor = 0.70
}

/// Messergebnis eines Kandidaten gegen eine Referenz.
struct QualityGateMeasurement: Equatable, Sendable {
    let globalSSIM: Double
    let p05TileSSIM: Double
    let edgeWeightedScore: Double
    /// nil = keine Text-Kacheln im Referenzmuster erkannt.
    let textRegionScore: Double?
    /// nil = Graustufen-/Bilevel-Bild: ΔE wird nicht angewendet.
    let meanDeltaE76: Double?
    /// Debug-Metrik (Luminanz, Stichprobe).
    let psnr: Double
    let tileSSIMs: [Double]
    let tileGrid: Int
    let isColor: Bool

    /// Q = min über die geprüften strukturellen Metriken (ohne ΔE/PSNR).
    var qualityScore: Double {
        var values = [globalSSIM, p05TileSSIM, edgeWeightedScore]
        if let text = textRegionScore { values.append(text) }
        return values.min() ?? globalSSIM
    }
}

// MARK: - Perzeptueller Score (SSIMULACRA-ideen, ohne Fremd-Deps)
//
// Warum kein vendortes SSIMULACRA: v2 hängt an libjxl-Headern
// (`lib/jxl/image_bundle.h`), v1 an OpenCV (`cv::Mat`) – beides zieht
// Abhängigkeiten in die statische Bridge, die dort nichts zu suchen haben.
// Stattdessen bündelt `PerceptualScore` die VORHANDENEN Messungen (SSIM,
// p05-Kacheln, ΔE-Farbe) mit dem einen NEUEN Signal (Kanten-Einführung:
// Kanten, die das Original nicht hat – Ringing/Halos – sieht der
// SSIM-Mittelwert nicht, wenn sich Mittelwerte ausgleichen).
//
// Semantik: 0 = identisch, größer = schlechter (DSSIM-ähnlich,
// unbeschränkt). Fehlende Dimensionen werden ausgeschlossen und die
// Gewichte renormalisiert; ohne jede Messung gilt 0.
enum PerceptualScore {

    /// Gewichtete Poolung über die Messdimensionen. Die Gewichte folgen der
    /// Kaufkraft je Dimension: globale Struktur trägt fast die Hälfte,
    /// lokale Katastrophen (p05) und eingeführte Kanten je ein Viertel bis
    /// Fünftel, Farbe (ΔE, nur Farbbilder) den Rest.
    static func score(measurement: QualityGateMeasurement,
                      edgeIntroduction: Double?) -> Double {
        var terms: [(value: Double, weight: Double)] = [
            (1 - measurement.globalSSIM, 0.45),
            (1 - measurement.p05TileSSIM, 0.25),
        ]
        if let edgeIntroduction {
            terms.append((max(0, edgeIntroduction) * 2.0, 0.20))
        }
        if let deltaE = measurement.meanDeltaE76, measurement.isColor {
            terms.append((min(1, deltaE / 10.0), 0.10))
        }
        var sum = 0.0
        var total = 0.0
        for term in terms {
            sum += term.value * term.weight
            total += term.weight
        }
        guard total > 0 else { return 0 }
        return sum / total
    }

    /// Unverhandelbare Obergrenze (§10.3-Familie, auch hinter Custom/fixed):
    /// Darüber gilt ein Kandidat als Katastrophe, egal was die Preset-Matrix
    /// sagt. Kalibrierung (QualityGatesTests-Anker, vermessen in
    /// `PerceptualScoreTests`): identisch = 0, leichte JPEG-Artefakte
    /// (q0.75 Foto < 0.035) weit darunter, q0.05-Textgrafik (0.0897) und
    /// Text-Katastrophe klar darüber. Faktor ~2 Abstand zu beiden Seiten;
    /// Korpus-Telemetrie (`perceptualScore` im Trace) schärft nach.
    static let catastrophicLimit = 0.07
}

enum QualityGateVerdict: Equatable, Sendable {
    case pass
    /// Die verletzten Metriken, in fester Reihenfolge der Gate-Formel.
    case fail([QualityGateMetric])
}

// MARK: - Gate

enum QualityGates {

    /// Kachelraster (Kacheln pro Kante). 8×8 Kacheln auf der gemeinsamen
    /// Stichprobe; eine Kachel umfasst bei 320 px Kantenlänge 40 × 40 px.
    static let tileGrid = 8
    /// Kantendichte, ab der eine Kachel in `edge_weighted_score` eingeht.
    static let minimumEdgeDensity = 0.02
    /// Sobel-Schwelle (normalisiert auf 0–255) für „Kanten-Pixel“.
    static let edgeMagnitudeThreshold: Float = 32.0

    // MARK: Gemeinsame Stichprobe

    /// Eine Downsample-Stichprobe: EIN Zeichenvorgang, daraus stammen SSIM,
    /// Sobel-Kanten, Text-Erkennung, ΔE und PSNR.
    struct Sample {
        let width: Int
        let height: Int
        /// Luminanz (Rec. 601) als Float, Zeile für Zeile.
        let luma: [Float]
        /// RGBA-Bytes (4 pro Pixel) für das ΔE-Farbfehlermaß.
        let rgba: [UInt8]
        /// Mittlerer Chroma-Abstand (max−min je Pixel) – Schwellwert wie
        /// `ImageClassifier` (isGrayscale < 1.5).
        let chromaMean: Double

        var isColor: Bool { chromaMean >= 1.5 }
    }

    /// Pixelgröße der Stichprobe (am 8er-Fenster ausgerichtet) – geteilt,
    /// damit eine vorab auf dieselbe Größe gerechnete Referenz exakt passt.
    static func sampleSize(width: Int, height: Int,
                           maxEdge: Int = QualityMetrics.sampleEdge) -> PixelSize? {
        let window = 8
        // Kein festes 320-px-Limit mehr: Der Smart-Anker misst bewusst auf
        // einem feineren Raster; alle Gates übergeben ihr Raster ausdrücklich
        // (Standard bleibt `QualityMetrics.sampleEdge`).
        let edge = max(window, maxEdge)
        var w = min(edge, max(window, width))
        let rawH = Int((Double(w) / max(0.0001,
            Double(width) / Double(max(1, height)))).rounded())
        var h = min(edge, max(window, rawH))
        w -= w % window
        h -= h % window
        guard w >= window, h >= window else { return nil }
        return PixelSize(width: w, height: h)
    }

    /// Zeichnet das Bild EINMAL in eine RGBA-Stichprobe (gleiche Kantenlogik
    /// wie `QualityMetrics.luma`: max 320 px, am 8er-Fenster ausgerichtet).
    ///
    /// `maxEdge` begrenzt das Messraster (P0.1): Für eine Verkleinerung, die
    /// die DPI-Politik erlaubt, wird auf der Zielauflösung gemessen – feiner
    /// kann das Ergebnis per Definition nicht sein. Standard bleibt 320 px.
    static func sample(_ image: CGImage,
                       maxEdge: Int = QualityMetrics.sampleEdge) -> Sample? {
        let window = 8
        guard let size = sampleSize(width: image.width, height: image.height,
                                    maxEdge: maxEdge) else { return nil }
        let w = size.width, h = size.height
        _ = window

        guard let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }

        let pixelCount = w * h
        let px = data.bindMemory(to: UInt8.self, capacity: pixelCount * 4)
        let rgba = Array(UnsafeBufferPointer(start: px, count: pixelCount * 4))

        var luma = [Float](repeating: 0, count: pixelCount)
        var chromaSum = 0
        for i in 0..<pixelCount {
            let o = i * 4
            let r = Int(rgba[o]), g = Int(rgba[o + 1]), b = Int(rgba[o + 2])
            luma[i] = Float((299 * r + 587 * g + 114 * b) / 1000)
            chromaSum += max(r, g, b) - min(r, g, b)
        }

        return Sample(width: w, height: h, luma: luma, rgba: rgba,
                      chromaMean: Double(chromaSum) / Double(pixelCount))
    }

    // MARK: SSIM-Kern

    /// Per-Fenster-SSIM über nicht überlappende 8×8-Fenster – dieselbe
    /// Mathematik und dieselben Konstanten wie `QualityMetrics.ssim`, aber
    /// mit Einzelergebnissen, damit Kacheln daraus aggregiert werden können.
    static func windowSSIMs(_ a: [Float], _ b: [Float],
                            width: Int, height: Int) -> [Float] {
        let c1: Float = 6.5025    // (0.01 * 255)^2
        let c2: Float = 58.5225   // (0.03 * 255)^2
        let window = 8
        var scores: [Float] = []

        var by = 0
        while by + window <= height {
            var bx = 0
            while bx + window <= width {
                var sumA: Float = 0, sumB: Float = 0
                for y in by..<(by + window) {
                    let row = y * width + bx
                    for i in 0..<window {
                        sumA += a[row + i]
                        sumB += b[row + i]
                    }
                }
                let n = Float(window * window)
                let muA = sumA / n
                let muB = sumB / n

                var varA: Float = 0, varB: Float = 0, cov: Float = 0
                for y in by..<(by + window) {
                    let row = y * width + bx
                    for i in 0..<window {
                        let da = a[row + i] - muA
                        let db = b[row + i] - muB
                        varA += da * da
                        varB += db * db
                        cov += da * db
                    }
                }
                varA /= n - 1
                varB /= n - 1
                cov /= n - 1

                let num = (2 * muA * muB + c1) * (2 * cov + c2)
                let den = (muA * muA + muB * muB + c1) * (varA + varB + c2)
                scores.append(num / den)
                bx += window
            }
            by += window
        }
        return scores
    }

    // MARK: Referenz-Cache

    /// Hält die Referenz-Stichprobe für alle Qualitätsstufen einer Leiter.
    /// Bisher wurde die Referenz PRO Stufe neu gezeichnet; mit dem Multi-Gate
    /// kostet ein weiterer Kandidat nur noch seine eigene Stichprobe.
    struct Evaluator {
        let reference: Sample

        init(reference: CGImage) {
            self.reference = QualityGates.sample(reference) ?? Sample(
                width: 0, height: 0, luma: [], rgba: [], chromaMean: 0)
        }

        init(reference sample: Sample) {
            self.reference = sample
        }

        var isUsable: Bool { reference.width >= 8 && reference.height >= 8 }

        /// Kandidaten auf dem Raster der Referenz abtasten – auch wenn die
        /// Referenz feiner als 320 px ist (Klein, 2026-10-22). Für Raster
        /// ≤ 320 px dieselbe Stichprobe wie zuvor.
        private var edge: Int {
            max(QualityMetrics.sampleEdge, reference.width, reference.height)
        }

        func measure(candidate: CGImage) -> QualityGateMeasurement? {
            guard isUsable, let candidateSample = QualityGates.sample(candidate, maxEdge: edge) else {
                return nil
            }
            return measure(candidate: candidateSample)
        }

        func measure(candidate sample: Sample) -> QualityGateMeasurement? {
            QualityGates.measure(reference: reference, candidate: sample)
        }

        /// Kanten-Einführung gegen einen Kandidaten (für `PerceptualScore`).
        /// Teilt sich die Referenz-Stichprobe; der Kandidat wird einmal
        /// gesampelt – dieselben Kosten wie `measure(candidate:)`.
        func edgeIntroduction(candidate: CGImage) -> Double? {
            guard isUsable, let candidateSample = QualityGates.sample(candidate, maxEdge: edge) else {
                return nil
            }
            return QualityGates.edgeIntroduction(reference: reference,
                                                 candidate: candidateSample)
        }
    }

    static func measure(reference: CGImage, candidate: CGImage) -> QualityGateMeasurement? {
        guard let ref = sample(reference) else { return nil }
        return Evaluator(reference: ref).measure(candidate: candidate)
    }

    static func measure(reference: Sample, candidate: Sample) -> QualityGateMeasurement? {
        guard reference.width == candidate.width,
              reference.height == candidate.height,
              reference.width >= 8, reference.height >= 8 else { return nil }

        let windows = windowSSIMs(reference.luma, candidate.luma,
                                  width: reference.width, height: reference.height)
        guard !windows.isEmpty else { return nil }
        let global = windows.reduce(Float(0), +) / Float(windows.count)

        let tiles = tileScores(windows: windows, width: reference.width,
                               height: reference.height)
        let tileScoresAsDouble = tiles.map { Double($0.score) }
        let p05 = Self.percentile05(of: tileScoresAsDouble)

        let edge = edgeWeightedScore(reference: reference, tiles: tiles,
                                     global: Double(global))
        let text = textRegionScore(reference: reference, tiles: tiles)

        let deltaE: Double? = reference.isColor
            ? meanDeltaE76(reference: reference, candidate: candidate)
            : nil

        return QualityGateMeasurement(
            globalSSIM: Double(global),
            p05TileSSIM: p05,
            edgeWeightedScore: edge,
            textRegionScore: text,
            meanDeltaE76: deltaE,
            psnr: psnr(reference: reference.luma, candidate: candidate.luma),
            tileSSIMs: tileScoresAsDouble,
            tileGrid: tileGrid,
            isColor: reference.isColor)
    }

    // MARK: Kacheln

    /// 5.-Perzentil (nearest rank) der Kachel-SSIMs.
    static func percentile05(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 1.0 }
        let sorted = values.sorted()
        let index = max(0, Int((0.05 * Double(sorted.count)).rounded(.up)) - 1)
        return sorted[index]
    }

    // MARK: Kanten

    /// Sobel-Gradientmagnitude der Referenz (normalisiert auf 0…255).
    /// Internal für die perzeptuelle Metrik (Kanten-Einführung braucht die
    /// Magnituden beider Seiten).
    static func sobelMagnitudes(_ luma: [Float], width: Int, height: Int)
        -> [Float] {
        var magnitudes = [Float](repeating: 0, count: width * height)
        guard width >= 3, height >= 3 else { return magnitudes }
        for y in 1..<(height - 1) {
            let row = y * width
            for x in 1..<(width - 1) {
                let tl = luma[row - width + x - 1]
                let t  = luma[row - width + x]
                let tr = luma[row - width + x + 1]
                let l  = luma[row + x - 1]
                let r  = luma[row + x + 1]
                let bl = luma[row + width + x - 1]
                let b  = luma[row + width + x]
                let br = luma[row + width + x + 1]
                let gx = (tr + 2 * r + br) - (tl + 2 * l + bl)
                let gy = (bl + 2 * b + br) - (tl + 2 * t + tr)
                magnitudes[row + x] = sqrt(gx * gx + gy * gy) / 4
            }
        }
        return magnitudes
    }

    /// Kantengewichtete Bewertung: Gewichtungssumme der Kachel-SSIMs über
    /// Kacheln mit Kantendichte über `minimumEdgeDensity`. Ohne solche
    /// Kacheln (Fläche ohne Struktur) gilt der globale Mittelwert.
    private static func edgeWeightedScore(reference: Sample,
                                          tiles: [Tile],
                                          global: Double) -> Double {
        edgeWeightedScore(tiles: tiles,
                          densities: edgeDensities(reference: reference, tiles: tiles),
                          global: global)
    }

    /// Kantendichte je Kachel – hängt nur von der Referenz ab.
    private static func edgeDensities(reference: Sample, tiles: [Tile]) -> [Double] {
        let magnitudes = sobelMagnitudes(reference.luma,
                                         width: reference.width,
                                         height: reference.height)
        return tiles.map { tile in
            var edgePixels = 0
            var totalPixels = 0
            for y in tile.y..<(tile.y + tile.height) {
                let row = y * reference.width
                for x in tile.x..<(tile.x + tile.width) {
                    totalPixels += 1
                    if magnitudes[row + x] >= edgeMagnitudeThreshold {
                        edgePixels += 1
                    }
                }
            }
            return Double(edgePixels) / Double(max(1, totalPixels))
        }
    }

    private static func edgeWeightedScore(tiles: [Tile], densities: [Double],
                                          global: Double) -> Double {
        var weightedSum = 0.0
        var weightTotal = 0.0
        for (tile, density) in zip(tiles, densities) where density >= minimumEdgeDensity {
            weightedSum += density * Double(tile.score)
            weightTotal += density
        }
        guard weightTotal > 0 else { return global }
        return weightedSum / weightTotal
    }

    // MARK: Strukturelle Maße (Smart-Anker)

    /// Referenz für wiederholte Strukturmessungen auf einem feinen Raster.
    /// Die Kantendichte je Kachel hängt nur von der Referenz ab und wird
    /// EINMAL bestimmt; ΔE, Text-Score und PSNR braucht der Anker nicht.
    struct StructuralReference {
        let sample: Sample
        fileprivate let densities: [Double]

        init(_ sample: Sample) {
            self.sample = sample
            // Die Kachelaufteilung hängt nur von der Rastergröße ab.
            let windows = [Float](repeating: 0, count: (sample.width / 8) * (sample.height / 8))
            let layout = QualityGates.tileScores(windows: windows, width: sample.width,
                                                 height: sample.height)
            densities = QualityGates.edgeDensities(reference: sample, tiles: layout)
        }
    }

    struct StructuralScores: Equatable, Sendable {
        let globalSSIM: Double
        let p05TileSSIM: Double
        let edgeWeightedScore: Double
    }

    /// Dieselben Definitionen wie `measure` – global, p05, kantengewichtet.
    static func structuralScores(reference: StructuralReference,
                                 candidate: Sample) -> StructuralScores? {
        let ref = reference.sample
        guard ref.width == candidate.width, ref.height == candidate.height,
              ref.width >= 8, ref.height >= 8 else { return nil }
        let windows = windowSSIMs(ref.luma, candidate.luma, width: ref.width, height: ref.height)
        guard !windows.isEmpty else { return nil }
        let global = Double(windows.reduce(Float(0), +) / Float(windows.count))
        let tiles = tileScores(windows: windows, width: ref.width, height: ref.height)
        return StructuralScores(
            globalSSIM: global,
            p05TileSSIM: percentile05(of: tiles.map { Double($0.score) }),
            edgeWeightedScore: edgeWeightedScore(tiles: tiles, densities: reference.densities,
                                                 global: global))
    }

    // MARK: Kanten-Einführung (Ringing/Halos)

    /// Mittlere POSITIVE Kantendifferenz Kandidat − Referenz, normiert auf
    /// 0…1: Kanten, die das Original nicht hat (Ringing, Halos, Mosquito
    /// Noise, Blockiness). Der SSIM-Mittelwert sieht sie nicht, wenn sich
    /// Mittelwerte ausgleichen – genau der dokumentierte blinde Fleck neben
    /// p05/Text-Score. Quelle für `PerceptualScore`.
    static func edgeIntroduction(reference: Sample, candidate: Sample) -> Double? {
        guard reference.width == candidate.width,
              reference.height == candidate.height,
              reference.width >= 3, reference.height >= 3 else { return nil }
        let refMag = sobelMagnitudes(reference.luma,
                                     width: reference.width,
                                     height: reference.height)
        let candMag = sobelMagnitudes(candidate.luma,
                                      width: candidate.width,
                                      height: candidate.height)
        guard refMag.count == candMag.count, !refMag.isEmpty else { return nil }
        var sum = 0.0
        for i in 0..<refMag.count {
            let introduced = Double(candMag[i]) - Double(refMag[i])
            if introduced > 0 { sum += introduced }
        }
        return sum / Double(refMag.count) / 255.0
    }

    // MARK: Text-Kacheln

    /// Kacheln mit hohem Schwarz-Weiß-Wechsel und Bimodalität sind Text-
    /// Kacheln. `text_region_score` ist das Minimum ihrer Kachel-SSIMs –
    /// dort darf eine Komprimierung am wenigsten verlieren.
    private static func textRegionScore(reference: Sample,
                                        tiles: [Tile]) -> Double? {
        let inkThreshold: Float = 128
        var minimum: Double?
        for tile in tiles {
            var dark = 0
            var transitions = 0
            var minV: Float = 255, maxV: Float = 0
            let w = reference.width
            for y in tile.y..<(tile.y + tile.height) {
                let row = y * w
                for x in tile.x..<(tile.x + tile.width) {
                    let v = reference.luma[row + x]
                    if v < inkThreshold { dark += 1 }
                    if v < minV { minV = v }
                    if v > maxV { maxV = v }
                    if x + 1 < tile.x + tile.width {
                        let right = reference.luma[row + x + 1]
                        if (v < inkThreshold) != (right < inkThreshold) {
                            transitions += 1
                        }
                    }
                    if y + 1 < tile.y + tile.height {
                        let below = reference.luma[row + w + x]
                        if (v < inkThreshold) != (below < inkThreshold) {
                            transitions += 1
                        }
                    }
                }
            }
            let n = tile.width * tile.height
            let darkFraction = Double(dark) / Double(n)
            let transitionDensity = Double(transitions) / Double(2 * n)
            let contrast = maxV - minV

            let isTextTile = darkFraction >= 0.01 && darkFraction <= 0.92
                && transitionDensity >= 0.02 && contrast >= 64
            if isTextTile {
                let score = Double(tile.score)
                if minimum == nil || score < minimum! { minimum = score }
            }
        }
        return minimum
    }

    // MARK: ΔE76 und PSNR

    /// Mittlerer ΔE76-Farbfehler auf der Stichprobe (jeder zweite Pixel in
    /// jeder zweiten Zeile – die Stichprobe IST bereits die Verkleinerung).
    /// sRGB → Lab (D65), CIE76-Distanz.
    static func meanDeltaE76(reference: Sample, candidate: Sample) -> Double {
        let rgbaA = reference.rgba
        let rgbaB = candidate.rgba
        let w = reference.width
        let h = reference.height
        var sum = 0.0
        var count = 0
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let o = (y * w + x) * 4
                let labA = lab(r: rgbaA[o], g: rgbaA[o + 1], b: rgbaA[o + 2])
                let labB = lab(r: rgbaB[o], g: rgbaB[o + 1], b: rgbaB[o + 2])
                let dl = labA.0 - labB.0
                let da = labA.1 - labB.1
                let db = labA.2 - labB.2
                sum += sqrt(dl * dl + da * da + db * db)
                count += 1
                x += 2
            }
            y += 2
        }
        guard count > 0 else { return 0 }
        return sum / Double(count)
    }

    /// sRGB-Byte-Tripel → CIELAB (D65, 2°).
    private static func lab(r: UInt8, g: UInt8, b: UInt8) -> (Double, Double, Double) {
        func linear(_ v: UInt8) -> Double {
            let c = Double(v) / 255.0
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let rl = linear(r), gl = linear(g), bl = linear(b)
        var x = (0.4124564 * rl + 0.3575761 * gl + 0.1804375 * bl) / 0.95047
        var y = 0.2126729 * rl + 0.7151522 * gl + 0.0721750 * bl
        var z = (0.0193339 * rl + 0.1191920 * gl + 0.9503041 * bl) / 1.08883

        x = labF(x); y = labF(y); z = labF(z)
        return (116 * y - 16, 500 * (x - y), 200 * (y - z))
    }

    private static func labF(_ t: Double) -> Double {
        // Epsilon/Kappa der CIE-Definition.
        t > 0.008856 ? pow(t, 1.0 / 3.0) : (7.787 * t) + (16.0 / 116.0)
    }

    /// PSNR auf der Luminanz-Stichprobe (Debug-Metrik). Identische Bilder
    /// werden bei 96 dB gekappt.
    static func psnr(reference a: [Float], candidate b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var mse = 0.0
        for i in 0..<a.count {
            let d = Double(a[i] - b[i])
            mse += d * d
        }
        mse /= Double(a.count)
        guard mse > 0 else { return 96.0 }
        return min(96.0, 10 * log10(255 * 255 / mse))
    }

    // MARK: Urteil

    /// Wendet die Grenzwerte an. Jede Metrik wird gegen ihre eigene Grenze
    /// geprüft (äquivalent zu Q = min(...) gegen die Zellgrenzen, aber mit
    /// Begründung, WELCHE Metrik gerissen ist). ΔE wird außer bei gesetzter
    /// Grenze zusätzlich nur auf Farbbildern angewendet.
    static func qualityVerdict(policy: QualityGatePolicy,
                               measurement: QualityGateMeasurement) -> QualityGateVerdict {
        var violated: [QualityGateMetric] = []
        if let limit = policy.globalSSIM, measurement.globalSSIM < limit {
            violated.append(.globalSSIM)
        }
        if measurement.p05TileSSIM < policy.p05TileSSIM {
            violated.append(.p05TileSSIM)
        }
        if measurement.edgeWeightedScore < policy.edgeWeightedScore {
            violated.append(.edgeWeightedScore)
        }
        if let limit = policy.textRegionScore,
           let text = measurement.textRegionScore, text < limit {
            violated.append(.textRegionScore)
        }
        if let limit = policy.maxDeltaE76,
           measurement.isColor, let deltaE = measurement.meanDeltaE76,
           deltaE > limit {
            violated.append(.deltaE76)
        }
        return violated.isEmpty ? .pass : .fail(violated)
    }

    static func qualityVerdict(preset: QualityGatePreset,
                               imageClass: QualityGateClass,
                               measurement: QualityGateMeasurement) -> QualityGateVerdict {
        qualityVerdict(policy: .policy(preset: preset, imageClass: imageClass),
                       measurement: measurement)
    }
}

// MARK: - Kachel-Layout

extension QualityGates {

    /// Eine Kachel der Stichprobe: Ausschnitt plus aggregierter SSIM-Score.
    struct Tile {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        let score: Float
    }

    /// Kacheln mit Position – die kantengewichtete und die Text-Bewertung
    /// brauchen den Ausschnitt, nicht nur den Score.
    private static func tileScores(windows: [Float], width: Int, height: Int)
        -> [Tile] {
        let window = 8
        let windowsX = width / window
        let tileW = max(window, width / tileGrid)
        let tileH = max(window, height / tileGrid)
        var tiles: [Tile] = []

        var tileY = 0
        while tileY < height {
            let clipH = min(tileH, height - tileY)
            var tileX = 0
            while tileX < width {
                let clipW = min(tileW, width - tileX)
                var sum: Float = 0
                var count = 0
                var wy = tileY
                while wy + window <= tileY + clipH {
                    var wx = tileX
                    while wx + window <= tileX + clipW {
                        let index = (wy / window) * windowsX + (wx / window)
                        if index >= 0, index < windows.count {
                            sum += windows[index]
                            count += 1
                        }
                        wx += window
                    }
                    wy += window
                }
                if count > 0 {
                    tiles.append(Tile(x: tileX, y: tileY, width: clipW,
                                      height: clipH, score: sum / Float(count)))
                }
                tileX += clipW
            }
            tileY += clipH
        }
        return tiles
    }
}
