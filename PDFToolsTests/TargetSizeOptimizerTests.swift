import Testing
import Foundation
@testable import PDFTools

/// Masterplan §12 (V2-6) – Target File Size / Global Budget Optimizer.
///
/// Festgenagelt:
///   • §12.3 Fixed Bytes: Dokumentgröße − optimierbare KEEP-Bytes, mal dem
///     Struktur-Faktor; Nachkalibrierung aus der GEMESSENEN Größe.
///   • §12.4 Lagrangian Search: score = d + λ·b, Bisektion bis in Zielnähe
///     (Planziel = Ziel − 2 %), Feinkorrektur über marginale Verzerrung je
///     Byte in die Frontier-Nachbarn.
///   • Monotonie: totalBytes(λ) ist non-increasing – die Eigenschaft, auf
///     der die Bisektion korrekt ist.
///   • Gates zuerst (§12.2): Der Optimizer sieht nur den V2-4-Pool; die
///     Floors des Presets sind die Untergrenze (§12.8).
@Suite struct TargetSizeOptimizerTests {

    // MARK: Helfer

    /// Synthetischer Kandidat (wie RateDistortionOptimizerTests) – die
    /// Metriken stehen für gemessene Werte, keine Encodes.
    static func candidate(id: String, bytes: Int,
                          global: Double? = nil, p05: Double? = nil,
                          edge: Double? = nil, deltaE: Double? = nil,
                          lossless: Bool = false, kind: CandidateKind? = nil)
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
                edgeScore: edge, textScore: nil,
                deltaE76: deltaE, psnr: nil,
                expectedRuntimeMs: 10, expectedPeakWorkingBytes: 0,
                compatibilityRisk: 0, semanticRisk: 0),
            isLossless: lossless,
            pages: [0],
            reason: "Test")
    }

    /// Set mit KEEP@0 (§9.1). `quality`-Tripel halten das smart/photo-Gate,
    /// sofern nicht anders angegeben.
    static func set(_ id: String, keepBytes: Int,
                    transforms: [CompressionCandidate]) -> CandidateSet {
        let keep = Self.candidate(id: "keep-\(id)", bytes: keepBytes,
                             lossless: true, kind: .keep)
        return CandidateSet(resourceID: id, candidates: [keep] + transforms)
    }

    /// Passender JPEG-Kandidat (smart/photo-Gate: global ≥ 0.90, p05 ≥ 0.80,
    /// edge ≥ 0.78). Nur die GLOBAL-Dimension ist gemessen (ΔE nil = Grau-
    /// stufen-Semantik, Farbdimension entfällt) – damit gilt EXAKT
    /// d = 1 − global, ohne Mischrechnung im Test.
    static func jpeg(_ id: String, bytes: Int, distortion: Double) -> CompressionCandidate {
        return Self.candidate(id: id, bytes: bytes, global: 1.0 - distortion,
                              p05: 0.99, edge: 0.99, deltaE: nil)
    }

    /// Drei Ressourcen mit gestaffelten Leitern (KEEP / Qualität / klein);
    /// alle Verzerrungen ≤ 0.08, damit alles das smart/photo-Gate hält.
    static func mixedSets() -> [CandidateGroup] {
        [
            .single(Self.set("10 0", keepBytes: 4000, transforms: [
                Self.jpeg("10-jpeg-b", bytes: 1000, distortion: 0.04),
                Self.jpeg("10-jpeg-s", bytes: 500, distortion: 0.08),
            ])),
            .single(Self.set("11 0", keepBytes: 4000, transforms: [
                Self.jpeg("11-jpeg-b", bytes: 1000, distortion: 0.02),
                Self.jpeg("11-jpeg-s", bytes: 500, distortion: 0.06),
            ])),
            .single(Self.set("12 0", keepBytes: 4000, transforms: [
                Self.jpeg("12-jpeg-b", bytes: 1000, distortion: 0.03),
                Self.jpeg("12-jpeg-s", bytes: 500, distortion: 0.08),
            ])),
        ]
    }

    static func pools(_ groups: [CandidateGroup],
                      classes: [ContentClass] = [.photo, .photo, .photo])
        -> [TargetSizeOptimizer.ResourcePool] {
        var out: [TargetSizeOptimizer.ResourcePool] = []
        for (index, group) in groups.enumerated() {
            for set in group.sets {
                out.append(TargetSizeOptimizer.ResourcePool(
                    set: set, contentClass: classes[min(index, classes.count - 1)],
                    preset: .smart))
            }
        }
        return out
    }

    // MARK: §12.3 – Fixed Bytes

    @Test func fixedBytesModell() {
        // 50_000 Dokument − 30_000 optimierbare Bilder = 20_000 Struktur,
        // mal 0.93 (V2-1-Messwert).
        #expect(TargetSizeOptimizer.fixedBytes(documentBytes: 50_000,
                                               optimizableBytes: 30_000)
                == 18_600)
        // Nicht-negativ, auch bei absurdem Input.
        #expect(TargetSizeOptimizer.fixedBytes(documentBytes: 100,
                                               optimizableBytes: 5_000) == 0)
    }

    /// §12.6 – die Nachkalibrierung blame't die GESAMTE Drift auf den
    /// festen Anteil: Die Kandidaten-Bytes sind gemessen (Payloads).
    @Test func nachkalibrierungAusGemessenerGroesse() {
        let fixed = TargetSizeOptimizer.recalibratedFixedBytes(
            actualTotalBytes: 12_345, selectedCandidateBytes: 10_000)
        #expect(fixed == 2_345)
        // Negativ (Kandidaten größer als die Datei – unmöglich, aber
        // defensiv): auf 0 geklemmt.
        #expect(TargetSizeOptimizer.recalibratedFixedBytes(
            actualTotalBytes: 1_000, selectedCandidateBytes: 2_000) == 0)
    }

    // MARK: §12.4 – Lagrangian Search

    /// Die Bisektion trifft das Planziel (Ziel − 2 %) und wählt die
    /// verzerrungsminimale Konfiguration unter der Schranke.
    @Test func bisektionTrifftZielInnerhalbToleranz() {
        let optimization = TargetSizeOptimizer.optimize(
            sources: Self.mixedSets().map { TargetSizeOptimizer.Source(
                group: $0, contentClass: .photo) },
            targetBytes: 3_800,       // Planziel 3_724
            fixedBytes: 500,
            preset: .smart)

        #expect(optimization.reachable)
        #expect(optimization.expectedBytes <= 3_724,
                "geplant wird ≤ Ziel − 2 %, ist aber \(optimization.expectedBytes)")
        #expect(optimization.expectedBytes > optimization.minimumSafeBytes,
                "das Restbudget kauft die beste erreichbare Qualität")
        #expect(optimization.expectedBytes == 3_500,
                "λ-Suche wählt die verzerrungsminimale Kombination (b,b,b)")
    }

    /// Bei großzügigem Ziel gewinnt die BESTE Qualität (KEEP) – λ → 0.
    @Test func grosszuegigesZielWaehltBesteQualitaet() {
        let sources = Self.mixedSets().map { TargetSizeOptimizer.Source(
            group: $0, contentClass: .photo) }
        let optimization = TargetSizeOptimizer.optimize(
            sources: sources, targetBytes: 500_000, fixedBytes: 0,
            preset: .smart)
        #expect(optimization.reachable)
        #expect(optimization.expectedBytes == 12_000,
                "KEEP gesamt (3 × 4_000) bei weitgestecktem Ziel")
        #expect(optimization.lambda == 0)
    }

    /// Monotonie von totalBytes(λ) – die Grundlage der Bisektion (§12.4).
    @Test func totalBytesIstMonotonFallendInLambda() {
        let pools = Self.pools(Self.mixedSets())
        var previous = Int64.max
        var lambda = 0.0
        for _ in 0..<40 {
            let total = TargetSizeOptimizer.totalBytes(lambda: lambda, pools: pools)
            #expect(total <= previous,
                    "totalBytes(λ=\(lambda)) = \(total) > vorher \(previous)")
            previous = total
            lambda = lambda == 0 ? 1e-7 : lambda * 4
        }
        // An der Sättigung: die kleinste zulässige Wahl.
        #expect(previous == 1_500)
    }

    /// §12.4 Feinkorrektur – das Restbudget kauft Qualität über die
    /// Frontier-Nachbarn (marginal Δd/Δbytes), strikt unter dem Planziel,
    /// ohne neue Encodes.
    @Test func feinkorrekturKauftQualitaetImBudget() {
        let pool = TargetSizeOptimizer.ResourcePool(
            set: Self.set("20 0", keepBytes: 1_000, transforms: [
                Self.jpeg("20-jpeg-b", bytes: 700, distortion: 0.03),
                Self.jpeg("20-jpeg-s", bytes: 500, distortion: 0.08),
            ]),
            contentClass: .photo, preset: .smart)
        // Ranked ist bytes-AUFSTEIGEND: 0 = kleinster (500, d 0.08), 1 =
        // 700 (d 0.03), 2 = KEEP (1_000, d 0). Budget 250 erlaubt genau
        // EINEN Schritt: 500→700 (Kosten 200, Δd 0.05); der zweite Schritt
        // (700→1000, Kosten 300) passt nicht mehr.
        let result = TargetSizeOptimizer.fineCorrect(pools: [pool],
                                                     indices: [0], budget: 250)
        #expect(result.changed)
        #expect(result.indices == [1],
                "Feinkorrektur steigt zum Frontier-Nachbarn auf")
        // Zu wenig Budget: keine Wahl, kein Fake-Fortschritt.
        let blocked = TargetSizeOptimizer.fineCorrect(pools: [pool],
                                                      indices: [0], budget: 100)
        #expect(!blocked.changed)
        #expect(blocked.indices == [0])
    }

    /// Feinkorrektur in der Gesamtoptimierung: Die λ-Wahl springt bei
    /// GLEICHEN Ressourcen diskret (beide Stufen zugleich); das Restbudget
    /// füllt die Lücke mit EINEM Aufstieg – ohne das Planziel zu reißen.
    @Test func feinkorrekturBleibtUnterPlanziel() {
        // Zwei identische Ressourcen: KEEP 5_000 (d 0), b 1_000 (d 0.04),
        // s 500 (d 0.08). Bildbudget 1_664: (b,b) = 2_000 passt nicht,
        // (s,s) = 1_000 → λ-Wahl fällt auf (s,s). Restbudget 764 kauft
        // EINEN Aufstieg s→b (Kosten 500): (b,s) = 1_500.
        func source(_ id: String) -> TargetSizeOptimizer.Source {
            .init(group: .single(Self.set(id, keepBytes: 5_000, transforms: [
                Self.jpeg("\(id)-jpeg-b", bytes: 1_000, distortion: 0.04),
                Self.jpeg("\(id)-jpeg-s", bytes: 500, distortion: 0.08),
            ])), contentClass: .photo)
        }
        let optimization = TargetSizeOptimizer.optimize(
            sources: [source("31 0"), source("32 0")],
            targetBytes: 1_800,   // Planziel 1_764, Bildbudget 1_764
            fixedBytes: 0, preset: .smart)
        #expect(optimization.reachable)
        #expect(optimization.expectedBytes <= 1_764,
                "Feinkorrektur bleibt strikt unter dem Planziel")
        #expect(optimization.fineTuned,
                "Restbudget (Planziel − λ-Wahl) kauft Qualität")
        #expect(optimization.expectedBytes == 1_500,
                "(b,s): ein Aufstieg 500 → 1_000, der zweite passt nicht")
    }

    // MARK: §12.8 – Floor-Kopplung an das Preset

    /// Kandidaten unter dem Preset-Floor sind dem Optimizer unsichtbar –
    /// das Ziel verschärft per Budget, NIE unter den Preset-Floor (§12.8).
    @Test func zielOeffnetKeineFloors() {
        // Ein aggressiver Kandidat, der das smart/photo-Gate reißt
        // (global 0.80 < 0.90) – er darf in KEINER Wahl erscheinen, auch
        // nicht bei absurdem Zieldruck.
        // illegal hat WENIGER Bytes, aber SCHLECHTERE Qualität als legal –
        // keiner dominiert den anderen (§10.5), beide erreichen die Gates;
        // dort fliegt der illegale raus (global 0.80 < smart/photo 0.90).
        let illegal = Self.candidate(id: "40-jpeg-illegal", bytes: 100,
                                global: 0.80, p05: 0.75, edge: 0.79)
        let legal = Self.jpeg("40-jpeg-legal", bytes: 800, distortion: 0.05)
        let sources: [TargetSizeOptimizer.Source] = [
            .init(group: .single(Self.set("40 0", keepBytes: 10_000,
                                     transforms: [illegal, legal])),
                  contentClass: .photo),
        ]
        let optimization = TargetSizeOptimizer.optimize(
            sources: sources, targetBytes: 500, fixedBytes: 0,
            preset: .smart)
        #expect(!optimization.reachable, "Minimum (800) liegt über Ziel 500")
        for selection in optimization.selections {
            #expect(selection.candidate.id != illegal.id,
                    "Floor-verletzender Kandidat wurde gewählt")
        }
        #expect(optimization.expectedBytes == 800)
    }

    // MARK: §12.1 – TargetSizeResult-Form (API-Kontrakt)

    @Test func ergebnisformIstVollstaendig() {
        let optimization = TargetSizeOptimizer.optimize(
            sources: Self.mixedSets().map { TargetSizeOptimizer.Source(
                group: $0, contentClass: .photo) },
            targetBytes: 3_800, fixedBytes: 500, preset: .smart)
        #expect(optimization.requestedBytes == 3_800)
        #expect(optimization.expectedBytes >= optimization.minimumSafeBytes)
        #expect(!optimization.selections.isEmpty)
        for selection in optimization.selections {
            #expect(!selection.reason.isEmpty)
            #expect(!selection.candidateIDsBySafety.isEmpty)
            // KEEP ist immer die letzte Stufe der Leiter (§5.7).
            #expect(selection.candidateIDsBySafety.last?
                .rawValue.hasPrefix("keep") == true)
        }
    }
}
