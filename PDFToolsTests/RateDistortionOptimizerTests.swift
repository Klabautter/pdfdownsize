import Testing
import Foundation
import CoreGraphics
@testable import PDFTools

/// Masterplan §10 (V2-4) – Local Rate-Distortion Optimizer.
///
/// Festgenagelt:
///   • §10.6 Preset-Auswahl: kleinster Candidate, der das Preset-Gate hält –
///     für Kandidaten, die die Generator-Gates bereits passiert haben,
///     ÄQUIVALENT zur bisherigen planViaCandidates-Wahl (kleinster insgesamt).
///   • §10.3 Katastrophen-Floor ÜBER allen Presets: Auch ein Custom-/fixed-
///     Kandidat unter der Mindest-Matrix wird nicht ausgeliefert (KEEP +
///     `catastrophicFloorFailed`), ein harmloser bleibt zugelassen – der
///     Floor ist Katastrophenschutz, kein Geschmacksrichter.
///   • §10.1 harte Gates (never grow, Risiko-Caps) vor der Optimierung.
///   • Verlorene Kandidaten erscheinen NICHT in der Rückstufungsleiter.
///   • §10.2 Skalarisierung folgt den Klassengewichten.
@Suite struct RateDistortionOptimizerTests {

    // MARK: Helfer

    /// Synthetischer Kandidat – die Metriken stehen für gemessene Werte;
    /// keine Encodes, vollständig deterministisch.
    static func candidate(id: String, bytes: Int,
                           global: Double? = nil, p05: Double? = nil,
                           edge: Double? = nil, text: Double? = nil,
                           deltaE: Double? = nil, runtime: Double = 10,
                           lossless: Bool = false, kind: CandidateKind? = nil,
                           compat: Double = 0, semantic: Double = 0,
                           perceptual: Double? = nil)
        -> CompressionCandidate {
        CompressionCandidate(
            id: CandidateID(id),
            objectID: nil,
            kind: kind ?? (lossless ? .keep
                : .jpeg(target: PixelSize(width: 100, height: 100), quality: 0.85,
                        backend: .mozjpeg, grayscale: false)),
            metrics: CandidateMetrics(
                encodedBytes: bytes,
                globalSSIM: global, p05TileSSIM: p05,
                edgeScore: edge, textScore: text,
                deltaE76: deltaE, psnr: nil,
                expectedRuntimeMs: runtime, expectedPeakWorkingBytes: 0,
                compatibilityRisk: compat, semanticRisk: semantic,
                perceptualScore: perceptual),
            isLossless: lossless,
            pages: [0],
            reason: "Test")
    }

    /// Set mit KEEP@0 (§9.1) plus den gegebenen Transform-Kandidaten.
    static func set(_ candidates: [CompressionCandidate], originalBytes: Int = 100_000)
        -> CandidateSet {
        let keep = candidate(id: "keep", bytes: originalBytes, runtime: 0,
                             lossless: true, kind: .keep)
        return CandidateSet(resourceID: "1 0", candidates: [keep] + candidates)
    }

    // MARK: §10.6 – Preset-Wahl-Äquivalenz zu planViaCandidates

    /// Reale Foto-Sonde, Objekt 80: 600 DPI halten die Smart-Grafikmatrix,
    /// werden aber am zusätzlichen perzeptuellen Gate zurückgewiesen.
    /// Ein Generator-Pass ist deshalb noch keine Produktionszulassung.
    @Test func photoIntermediateMatrixPassIsNotFinalAcceptance() {
        for sample in [
            (bytes: 102701, global: 0.9233183860778809,
             tile: 0.8908010721206665, edge: 0.9233582592264427,
             text: 0.8739400506019592, perceptual: 0.07345051611139347),
            (bytes: 37074, global: 0.9135763645172119,
             tile: 0.8773351907730103, edge: 0.9173667260845427,
             text: 0.8661004900932312, perceptual: 0.0821392325423521)
        ] {
            let candidate = Self.candidate(id: "photo-600dpi", bytes: sample.bytes,
                global: sample.global, p05: sample.tile, edge: sample.edge,
                text: sample.text, perceptual: sample.perceptual)
            let measurement = candidate.metrics.gateMeasurement!
            #expect(QualityGates.qualityVerdict(
                policy: .policy(preset: .smart, imageClass: .graphics),
                measurement: measurement) == .pass)
            let selection = RateDistortionOptimizer.select(
                from: Self.set([candidate], originalBytes: 2_408_356),
                contentClass: .lineArt, preset: .smart)
            #expect(selection.candidate.id == CandidateID("keep"))
            #expect(selection.catastrophicRejection)
            #expect(selection.rejections.contains {
                $0.candidateID == candidate.id
                    && $0.reason.contains("perzeptueller Katastrophen-Gate")
            })
        }
    }

    /// Alle Kandidaten halten das Preset-Gate (Generator-Semantik) → der
    /// Optimizer wählt denselben kleinsten Candidate wie die bisherige
    /// planViaCandidates-Regel (min Bytes, Gleichstand → Position).
    /// Core-235-Befund 2026-09-30 (USGS-Karte, Klein): Ein UNSICHERER
    /// Kandidat (kleiner, nominell bessere SSIM, aber über dem perzeptuellen
    /// Katastrophen-Gate) dominierte im Pareto-Pruning den sicheren und
    /// entfernte ihn – danach fiel der unsichere am Gate, und das ORIGINAL
    /// gewann (59 Kacheln in voller Größe). Fehlermöglichkeiten des Fixes:
    /// (1) der sichere Kandidat fehlt weiter, (2) der unsichere gewinnt,
    /// (3) die Ablehnung verliert ihre Begründung.
    @Test func paretoEntferntKeineSicherenKandidatenZugunstenUnsicherer() {
        let unsafe = Self.candidate(id: "jpeg-unsafe", bytes: 8_000, global: 0.99, p05: 0.97,
                                    edge: 0.99, text: 0.99, perceptual: 0.11)
        let safe = Self.candidate(id: "jpeg-safe", bytes: 11_000, global: 0.98, p05: 0.96,
                                  edge: 0.98, text: 0.98, perceptual: 0.03)
        let set = Self.set([unsafe, safe], originalBytes: 83_000)
        let selection = RateDistortionOptimizer.select(from: set, contentClass: .mapTechnical,
                                                       preset: .small)
        #expect(selection.candidate.id == safe.id, "gewählt: \(selection.candidate.id)")
        #expect(selection.rejections.contains { $0.candidateID == unsafe.id
            && $0.reason.contains("Katastrophen") })
    }

    @Test func presetWahlIstAequivalentZurKleinstenWahl() {
        let a = Self.candidate(id: "jpeg-a", bytes: 950, global: 0.93, p05: 0.88,
                               edge: 0.90, deltaE: 2.0)
        let b = Self.candidate(id: "jpeg-b", bytes: 900, global: 0.92, p05: 0.85,
                               edge: 0.85, deltaE: 2.5)
        let c = Self.candidate(id: "jpeg-c", bytes: 920, global: 0.91, p05: 0.84,
                               edge: 0.84, deltaE: 3.0)
        let set = Self.set([a, b, c])

        let selection = RateDistortionOptimizer.select(from: set,
                                                       contentClass: .photo,
                                                       preset: .smart)
        #expect(selection.candidate.id == b.id)
        #expect(selection.rejections.isEmpty)
        #expect(!selection.catastrophicRejection)
        // Äquivalenz zur bisherigen Regel (kleinster Candidate im Set).
        #expect(selection.candidate.id == set.candidates
            .min(by: { $0.metrics.encodedBytes < $1.metrics.encodedBytes })?.id)
        #expect(selection.reason.contains("kleinster Candidate"))
        #expect(selection.reason.contains("smart/photo"))
    }

    /// Gleichstand bei Bytes: zunächst entscheidet die QUALITÄT (der
    /// messtechnisch bessere Kandidat dominiert und prunt den anderen,
    /// deterministisch – die Laufzeit ist aus der Dominanz entfernt, sie
    /// ist lastabhängig); bleibt ein echter Gleichstand (Bytes UND
    /// Qualität), gewinnt der früher erzeugte Kandidat.
    @Test func gleichstandGehtAnDerQualitaetDannAnDerReihenfolge() {
        // a/b: gleiche Bytes, b messbar besser → b prunt a (Laufzeit kippt
        // die Entscheidung bewusst nicht).
        let a = Self.candidate(id: "jpeg-a", bytes: 900, global: 0.93, p05: 0.88,
                               edge: 0.90, runtime: 5)
        let b = Self.candidate(id: "jpeg-b", bytes: 900, global: 0.95, p05: 0.90,
                               edge: 0.92, runtime: 10)
        let set = Self.set([a, b])
        let selection = RateDistortionOptimizer.select(from: set,
                                                       contentClass: .photo,
                                                       preset: .smart)
        #expect(selection.candidate.id == b.id,
                "Byte-Gleichstand mit Qualitätsunterschied geht an die bessere Messung")

        // Echter Gleichstand (Bytes UND Qualität identisch): Generator-
        // reihenfolge; die 400× gemessene Laufzeitdifferenz bleibt ohne
        // Einfluss.
        let c = Self.candidate(id: "jpeg-c", bytes: 900, global: 0.95, p05: 0.90,
                               edge: 0.92, runtime: 5)
        let d = Self.candidate(id: "jpeg-d", bytes: 900, global: 0.95, p05: 0.90,
                               edge: 0.92, runtime: 2000)
        let tiedSet = Self.set([c, d])
        let tiedSelection = RateDistortionOptimizer.select(from: tiedSet,
                                                           contentClass: .photo,
                                                           preset: .smart)
        #expect(tiedSelection.candidate.id == c.id,
                "Echter Gleichstand geht an die Generatorreihenfolge, nicht an die Laufzeit")
    }

    // MARK: §10.6 – Preset-Floor-Verwerfung (Custom-/ungated-Kandidaten)

    /// Ein fester (ungated erzeugter) Kandidat unter dem Preset-Floor, aber
    /// über dem Katastrophen-Floor: verworfen MIT Begründung, der nächste
    /// zulässige gewinnt.
    @Test func presetFloorVerwirftMitBegruendung() {
        let schlecht = Self.candidate(id: "jpeg-schlecht", bytes: 700,
                                      global: 0.80, p05: 0.70, edge: 0.78)
        let gut = Self.candidate(id: "jpeg-gut", bytes: 900, global: 0.93,
                                 p05: 0.88, edge: 0.90, deltaE: 2.0)
        let set = Self.set([schlecht, gut])

        // smart/photo: global 0.90, p05 0.80 – 0.80/0.70 reißt beides; der
        // Katastrophen-Floor (0.70/0.60/0.50) hält der Kandidat.
        let selection = RateDistortionOptimizer.select(from: set,
                                                       contentClass: .photo,
                                                       preset: .smart)
        #expect(selection.candidate.id == gut.id)
        #expect(!selection.catastrophicRejection)
        #expect(selection.rejections.count == 1)
        let reason = selection.rejections.first?.reason ?? ""
        #expect(reason.contains("p05TileSSIM 0.7000<0.80"),
                "Begründung soll Metrik, Wert und Grenze nennen: \(reason)")
        #expect(selection.reason.contains("verworfen"))
        // Verworfene sind nicht in der Leiter.
        #expect(!selection.candidateIDsBySafety.contains(schlecht.id))
    }

    // MARK: §10.3 – Katastrophen-Floor (unverhandelbar, auch Custom)

    /// Custom-Preset, Kandidat unter der Katastrophen-Matrix: wird NICHT
    /// ausgeliefert – KEEP als Rückfall, katastrophen begründet.
    @Test func katastrophenFloorVerwirftAuchHinterCustom() {
        // p05 0.40 und Text 0.30: massiver Kachel-/Textabsturz (unter den
        // Floors 0.60/0.50, dokumentierte Ableitung in QualityGates).
        let katastrophe = Self.candidate(id: "jpeg-katastrophe", bytes: 500,
                                         global: 0.75, p05: 0.40, edge: 0.62,
                                         text: 0.30)
        let set = Self.set([katastrophe])

        let selection = RateDistortionOptimizer.select(from: set,
                                                       contentClass: .screenshot,
                                                       preset: .custom)
        #expect(selection.candidate.kind.isKeep)
        #expect(selection.catastrophicRejection)
        #expect(selection.reason.contains("Katastrophen-Floor"))
        #expect(selection.reason.contains("§10.3"))
        #expect(selection.rejections.first?.reason.contains("textRegionScore 0.3000<0.50")
                == true || selection.rejections.first?.reason.contains("p05TileSSIM 0.4000<0.60")
                == true)
        // Leiter: nur noch KEEP (V2-5 rollt nicht in die Katastrophe zurück).
        #expect(selection.candidateIDsBySafety == [selection.candidate.id])
    }

    /// Custom darf Q0.60 wählen – ein harmloser Kandidat bleibt zugelassen:
    /// der Floor ist NICHT überstreng (nur Katastrophen).
    @Test func katastrophenFloorLaesstHarmlosenCustomKandidatZU() {
        let harmlos = Self.candidate(id: "jpeg-q60", bytes: 800,
                                     global: 0.85, p05: 0.75, edge: 0.75,
                                     deltaE: 3.0)
        let set = Self.set([harmlos])

        let selection = RateDistortionOptimizer.select(from: set,
                                                       contentClass: .photo,
                                                       preset: .custom)
        #expect(selection.candidate.id == harmlos.id)
        #expect(selection.rejections.isEmpty)
        #expect(!selection.catastrophicRejection)
    }

    /// Verlustfreie Kandidaten ohne Messung (Flate, indexed, G4, JBIG2)
    /// passieren die Qualitätsgates konstruktiv.
    @Test func verlustfreieKandidatenOhneMessungBleibenZulaessig() {
        let flate = Self.candidate(id: "flate", bytes: 900, lossless: true,
                                   kind: .flate(target: PixelSize(width: 100, height: 100),
                                                grayscale: false, predictor: true))
        let set = Self.set([flate])
        for preset in [QualityGatePreset.small, .smart, .quality, .custom] {
            let selection = RateDistortionOptimizer.select(from: set,
                                                           contentClass: .screenshot,
                                                           preset: preset)
            #expect(selection.candidate.id == flate.id, "\(preset): verlustfrei verworfen")
            #expect(selection.rejections.isEmpty)
        }
    }

    /// Verlustbehaftet OHNE strukturelle Messung (CMYK-YCCK): das Codec-
    /// eigene ΔE-Gate ist die Schranke; der Optimizer verwirft nicht.
    @Test func cmykKandidatOhneStrukturmessungBleibtZulaessig() {
        let cmyk = Self.candidate(id: "cmyk-q85", bytes: 800, lossless: false,
                                  kind: .cmykJPEG(target: PixelSize(width: 100, height: 100),
                                                  quality: 0.85))
        let set = Self.set([cmyk])
        let selection = RateDistortionOptimizer.select(from: set,
                                                       contentClass: .photo,
                                                       preset: .quality)
        #expect(selection.candidate.id == cmyk.id)
        #expect(selection.rejections.isEmpty)
    }

    // MARK: §10.1 – Harte Gates

    @Test func neverGrowVerwirftKandidatenAbOriginalgroesse() {
        // Der never-grow-Gate ist das Sicherheitsnetz (§10.1) HINTER dem
        // Pareto-Pruning: Ein verlustbehafteter Kandidat ab Originalgröße
        // wäre von KEEP (Qualität 1.0, Laufzeit 0) stets dominiert und
        // bereits entfernt. Die Gate-Stelle ist für den Randfall
        // Qualitätsgleichstand (verlustfrei, gleiche Bytes, keine schnelle
        // Stufe) da – genau den prüft dieser Test.
        let gleich = Self.candidate(id: "flate-gleich", bytes: 100_000,
                                    runtime: 0, lossless: true,
                                    kind: .flate(target: PixelSize(width: 100, height: 100),
                                                 grayscale: false, predictor: true))
        let set = Self.set([gleich])
        let selection = RateDistortionOptimizer.select(from: set,
                                                       contentClass: .photo,
                                                       preset: .smart)
        #expect(selection.candidate.kind.isKeep)
        #expect(selection.rejections.count == 1)
        #expect(selection.rejections.first?.reason.contains("never grow") == true)
        #expect(selection.rejections.first?.candidateID == gleich.id)
    }

    @Test func risikoCapsVerwerfenStrukturellBedenklicheKandidaten() {
        // Der riskante Kandidat ist größenmäßig besser (sonst ohne Spannung),
        // scheitert aber am Kompatibilitäts-Cap; der zulässige ist bewusst
        // KLEINER, damit keine Pareto-Dominanz ihn vorher aus dem Raum nimmt.
        let riskant = Self.candidate(id: "jpeg-riskant", bytes: 500,
                                     global: 0.95, p05: 0.95, edge: 0.95,
                                     compat: 0.9)
        let ok = Self.candidate(id: "jpeg-ok", bytes: 300, global: 0.96,
                                p05: 0.92, edge: 0.93, deltaE: 1.5)
        let set = Self.set([riskant, ok])
        let selection = RateDistortionOptimizer.select(from: set,
                                                       contentClass: .photo,
                                                       preset: .smart)
        #expect(selection.candidate.id == ok.id)
        #expect(selection.rejections.first?.reason.contains("compatibility risk") == true)
        #expect(!selection.candidateIDsBySafety.contains(riskant.id))
    }

    // MARK: §5.7 – Rückstufungsleiter

    /// Die Leiter ist aufsteigend konservativ: verlustbehaftet nach Bytes
    /// aufsteigend, dann verlustfrei, KEEP als letzte Stufe – und verworfene
    /// Kandidaten fehlen vollständig.
    @Test func leiterIstAufsteigendKonservativUndEnthaeltKeineVerworfenen() {
        let aggressiv = Self.candidate(id: "jpeg-aggressiv", bytes: 700,
                                       global: 0.91, p05: 0.84, edge: 0.85)
        let milder = Self.candidate(id: "jpeg-mild", bytes: 900, global: 0.95,
                                    p05: 0.92, edge: 0.92)
        let katastrophe = Self.candidate(id: "jpeg-katastrophe", bytes: 500,
                                         global: 0.75, p05: 0.40, edge: 0.62,
                                         text: 0.30)
        let flate = Self.candidate(id: "flate", bytes: 1_200, lossless: true,
                                   kind: .flate(target: PixelSize(width: 100, height: 100),
                                                grayscale: false, predictor: true))
        let set = Self.set([aggressiv, milder, katastrophe, flate])

        let selection = RateDistortionOptimizer.select(from: set,
                                                       contentClass: .photo,
                                                       preset: .smart)
        // kleinster zulässiger: aggressiv (700) – die Katastrophe (500) ist raus.
        #expect(selection.candidate.id == aggressiv.id)
        #expect(selection.candidateIDsBySafety ==
                [aggressiv.id, milder.id, flate.id, set.keepCandidate!.id],
                "Leiter: lossy aufsteigend, dann lossless, KEEP zuletzt – ohne Katastrophe")
    }

    // MARK: §10.2 – Skalarisierung je Klasse

    @Test func skalarisierungFolgtDenKlassengewichten() {
        let metrics = Self.candidate(id: "m", bytes: 100, global: 0.90, p05: 0.70,
                                     edge: 0.80, text: 0.60, deltaE: 4.0).metrics
        // Photo (global + color): 0.6·0.90 + 0.4·(1−4/8=0.5) = 0.74
        #expect(abs(metrics.quality(for: .photo) - 0.74) < 1e-9)
        // Screenshot (edge + text + localWorst): 0.4·0.80 + 0.3·0.60 + 0.3·0.70 = 0.71
        #expect(abs(metrics.quality(for: .screenshot) - 0.71) < 1e-9)
        // Map (edge + localWorst): 0.5·0.80 + 0.5·0.70 = 0.75
        #expect(abs(metrics.quality(for: .mapTechnical) - 0.75) < 1e-9)
        // Scan (text + edge + localWorst): 0.4·0.60 + 0.3·0.80 + 0.3·0.70 = 0.69
        #expect(abs(metrics.quality(for: .scanContinuous) - 0.69) < 1e-9)
    }

    @Test func skalarisierungRenormalisiertFehlendeDimensionen() {
        // Graustufen: kein ΔE → colorLoss nil → Photo-Gewichte renormalisieren
        // auf global (0.60/0.40 entfällt → Faktor 1/0.6).
        let grau = Self.candidate(id: "grau", bytes: 100, global: 0.90, p05: 0.70,
                                  edge: 0.80).metrics
        #expect(abs(grau.quality(for: .photo) - 0.90) < 1e-9)
        // Kein Text im Bild: textLoss nil → Screenshot renormalisiert.
        let ohneText = Self.candidate(id: "ohneText", bytes: 100, global: 0.90,
                                      p05: 0.70, edge: 0.80).metrics
        // (0.4·0.80 + 0.3·0.70) / 0.7 = 0.757142…
        #expect(abs(ohneText.quality(for: .screenshot) - (0.53 / 0.7)) < 1e-9)
        // KEEP/verlustfrei ohne Messung: Qualität 1.0 in jeder Klasse.
        let keep = Self.candidate(id: "keep", bytes: 100, lossless: true,
                                  kind: .keep).metrics
        for klasse in ContentClass.allCases {
            #expect(keep.quality(for: klasse) == 1.0)
        }
    }

    // MARK: Planner-Niveau – Äquivalenz am echten Fixture

    /// Am Produktionspfad: Alle generierten Kandidaten haben die Generator-
    /// Gates passiert → die Optimizer-Wahl IST die bisherige kleinste-Wahl.
    @Test(.hangGuard) func plannerWahlBleibtKleinsterKandidatAmFixture() throws {
        let url = try PDFFixtures.photoAtWidth(2400)
        defer { try? FileManager.default.removeItem(at: url) }
        var options = CompressionOptions.smart
        options.featureFlags.candidateEngine = true
        let planned = try CompressionPipeline.plan(inputURL: url, options: options)

        let decision = try #require(planned.plan.decisions.first)
        let set = try #require(planned.plan.candidateSets.first)
        #expect(decision.selectedCandidateID == set.candidates
            .min(by: { $0.metrics.encodedBytes < $1.metrics.encodedBytes })?.id)
        #expect(decision.candidateIDsBySafety.last == set.keepCandidate?.id)
        #expect(!decision.reason.isEmpty)
        // Die Leiter ist eine Teilmenge des Sets und endet bei KEEP.
        let setIDs = Set(set.candidates.map(\.id))
        #expect(decision.candidateIDsBySafety.allSatisfy { setIDs.contains($0) })
    }
}
