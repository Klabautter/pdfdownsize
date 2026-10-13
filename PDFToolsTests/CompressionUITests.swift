import Testing
import Foundation
@testable import PDFTools

/// Phase 9-Features, deren Struktur blieb, nach Rücknahme der Preset-
/// Umbenennung (Nutzerwunsch: die Modus-Titel Smart/Klein/Qualität/Custom
/// sind die Primärwahl). Logik-Tests, keine Snapshot-Tests: Geprüft wird
/// die Kette Oberflächenwahl → `CompressionOptions`.
@Suite struct CompressionUITests {

    // MARK: - Modus-Titel (Rücknahme der Umbenennung)

    // MARK: - Bereichs-Schätzer

    /// Gleiche Einheit wird nur einmal genannt („Voraussichtlich 8–11 MB").
    @Test func bereichsformatierungKollabiertGemeinsameEinheit() {
        let text = CompressionViewModel.estimateRangeText(low: 8_000_000,
                                                          high: 11_000_000)
        #expect(text.hasPrefix("Voraussichtlich "))
        #expect(text.contains("–"))
        // „MB" (bzw. die locale-Einheit) steht genau einmal im Text.
        let lo = CompressionResult.format(8_000_000)
        let unit = String(lo.suffix(3))
        #expect(text.components(separatedBy: unit).count - 1 == 1,
                "Einheit „\(unit)“ steht mehrfach im Text: \(text)")
        #expect(text.hasSuffix(unit))
        // collapsed: vor dem Strich steht keine Einheit mehr.
        let beforeDash = text.split(separator: "–").first ?? ""
        #expect(!beforeDash.contains(unit))
    }

    /// Abweichende Einheiten bleiben beide genannt – „812 Bytes–1,9 MB"
    /// darf nicht zu einer irreführenden Zahl kollabieren.
    @Test func bereichsformatierungMischteEinheiten() {
        let text = CompressionViewModel.estimateRangeText(low: 812, high: 1_900_000)
        let lo = CompressionResult.format(812)
        let hi = CompressionResult.format(1_900_000)
        #expect(text == "Voraussichtlich \(lo)–\(hi)")
    }

    /// Degenerate Bereiche entarten nicht zu „X–X“.
    @Test func bereichsformatierungEinzelwert() {
        let text = CompressionViewModel.estimateRangeText(low: 4096, high: 4096)
        #expect(text == "Voraussichtlich \(CompressionResult.format(4096))")
    }

    /// Das Band ist konsistent zur Punktschätzung – die Anzeige kann sich
    /// also auf low/high verlassen, ohne den Punktwert zu zeigen.
    @Test(.hangGuard) func bandUmfasstPunktwert() throws {
        let url = try PDFFixtures.photoHeavyPDF(pixels: 1400)
        defer { try? FileManager.default.removeItem(at: url) }
        let estimate = try #require(
            CompressionEstimator.estimate(url: url, options: .smart))
        #expect(estimate.lowBytes <= estimate.pointBytes)
        #expect(estimate.highBytes >= estimate.pointBytes)
        let text = CompressionViewModel.estimateRangeText(low: estimate.lowBytes,
                                                          high: estimate.highBytes)
        #expect(text.contains("–") || estimate.lowBytes == estimate.highBytes)
    }

    // MARK: - Linearize-Schalter

    /// Der eigene Schalter steuert die bestehende Politik; der Struktur-Pass
    /// setzt daraus `--linearize` (Compressor, getestet in MaxPresetTests).
    @Test(.hangGuard) @MainActor
    func linearizeSchalterErreichtDieOptionen() {
        let viewModel = CompressionViewModel(defaults: .isolatedForTest())
        defer {
            viewModel.linearizeForWeb = false
        }

        #expect(!viewModel.linearizeForWeb, "Vorgabe: nicht linearisiert")
        #expect(viewModel.currentOptions.linearizationPolicy == .none)

        viewModel.linearizeForWeb = true
        #expect(viewModel.currentOptions.linearizationPolicy == .fastWebView)

        // Getrennt vom Modus: Der Schalter ändert die Bildpolitik nicht.
        #expect(viewModel.currentOptions.image == .smart)
    }

    // MARK: - Zielgrößen-Feld (Phase V2-10, §17)

    /// Die MB-Eingabe wird zu `CompressionGoal.targetBytes` – EIN Weg über
    /// `currentOptions`, keine zweite Übersetzung.
    @Test(.hangGuard) @MainActor
    func zielgroessenFeldMapptAufGoal() {
        let viewModel = CompressionViewModel(defaults: .isolatedForTest())
        defer {
            viewModel.targetSizeText = ""
        }

        // Leer = aus: Preset-Politik wie bisher.
        viewModel.targetSizeText = ""
        #expect(viewModel.goalBytes == nil)
        #expect(viewModel.currentOptions.goal == nil)

        // „10" → 10 MB (Dezimalstil, wie die Anzeige formatiert).
        viewModel.targetSizeText = "10"
        #expect(viewModel.goalBytes == 10_000_000)
        #expect(viewModel.currentOptions.goal == CompressionGoal.targetBytes(10_000_000))

        // Deutsch-tolerant: Komma als Dezimaltrenner.
        viewModel.targetSizeText = "10,5"
        #expect(viewModel.goalBytes == 10_500_000)
        viewModel.targetSizeText = "12.4"
        #expect(viewModel.goalBytes == 12_400_000)

        // Unsinn = aus (kein stiller Ersatzwert).
        viewModel.targetSizeText = "abc"
        #expect(viewModel.goalBytes == nil)
        viewModel.targetSizeText = "0"
        #expect(viewModel.goalBytes == nil)
        viewModel.targetSizeText = "-3"
        #expect(viewModel.goalBytes == nil)
    }

    /// Die Zielgröße ist KEIN neuer Modus: Sie liegt über jedem Preset und
    /// ändert weder die Picker-Titel noch die Fabrik-Bildwerte (Nutzerwunsch:
    /// Smart/Klein/Qualität/Custom bleiben; §17 kommt als Ergänzung).
    @Test(.hangGuard) @MainActor
    func zielgroesseIstKeinNeuerModus() {
        let viewModel = CompressionViewModel(defaults: .isolatedForTest())
        defer {
            viewModel.targetSizeText = ""
        }
        viewModel.targetSizeText = "10"
        #expect(viewModel.currentOptions.image == .smart)
        #expect(viewModel.currentOptions.goal == CompressionGoal.targetBytes(10_000_000))
        // Und die Candidate-Engine ist über das Ziel aktiv (§25) – ohne dass
        // ein Modus oder Flag in der Oberfläche auftaucht.
        #expect(viewModel.currentOptions.candidateEngineActive)
    }

    /// Ergebnis-Anzeige (§17): erreichte Größe gegen das Ziel. Keine
    /// ✓/✗-Glyphen im Text – das Symbol trägt das Label in der Oberfläche
    /// (Befund M4, Review 2026-10-09: sonst zwei Häkchen nebeneinander).
    @Test func zielErgebnisDarstellung() {
        let getroffen = CompressionViewModel.targetResultText(
            requested: 10_000_000, achieved: 9_400_000, met: true)
        #expect(!getroffen.contains("✓") && !getroffen.contains("✗"))
        #expect(getroffen.contains("erreicht"))
        #expect(getroffen.contains(CompressionResult.format(9_400_000)))
        #expect(getroffen.contains(CompressionResult.format(10_000_000)))

        let verfehlt = CompressionViewModel.targetResultText(
            requested: 10_000_000, achieved: 12_400_000, met: false)
        #expect(!verfehlt.contains("✓") && !verfehlt.contains("✗"))
        #expect(verfehlt.contains("verfehlt"))
        #expect(verfehlt.contains(CompressionResult.format(12_400_000)))
    }

    /// Der Hinweis auf QA-Nachläufe ist EIN Satz in Nutzersprache
    /// (Befund M5: kein „Qualitätssicherung: 1 Nachlauf, Fallback"); ohne
    /// Meldungen erscheint nichts.
    @Test func warnuebersichtDarstellung() {
        #expect(CompressionViewModel.qualityHintText(qaReplanCount: 0,
                                                     fallbackCount: 0) == nil)
        let hinweis = CompressionViewModel.qualityHintText(qaReplanCount: 2,
                                                           fallbackCount: 0)
        #expect(hinweis?.contains("2") == true)
        #expect(hinweis?.contains("Qualität geprüft") == true)
        let fallback = CompressionViewModel.qualityHintText(qaReplanCount: 1,
                                                            fallbackCount: 1)
        #expect(fallback?.contains("verlustfrei") == true)
        #expect(fallback?.contains("Fallback") == false)
    }

    /// Schätzer-Zeile bei gesetztem Ziel (§16.3/§17): nicht sicher
    /// erreichbare Ziele nennen die sicher erreichbare Größe – das
    /// Actual-Size-Feedback-Muster vor dem Lauf.
    @Test func zielReachabilityDarstellung() {
        let target = Int64(10_000_000)
        let safe = Int64(12_400_000)
        let typical = Int64(9_000_000)

        let unerreichbar = CompressionViewModel.targetEstimateText(
            .init(reachability: .notSafelyReachable, targetBytes: target,
                  safelyReachableBytes: safe, typicalBytes: typical))
        #expect(unerreichbar.contains("sicher erreichbar ca. "
                + CompressionResult.format(safe)))
        #expect(unerreichbar.contains(CompressionResult.format(target)))

        let unsicher = CompressionViewModel.targetEstimateText(
            .init(reachability: .uncertain, targetBytes: target,
                  safelyReachableBytes: safe, typicalBytes: typical))
        #expect(unsicher.contains("unsicher"))

        let erreichbar = CompressionViewModel.targetEstimateText(
            .init(reachability: .likelyReachable, targetBytes: target,
                  safelyReachableBytes: safe, typicalBytes: typical))
        #expect(erreichbar.contains("voraussichtlich erreichbar"))
    }

    // MARK: - Große Dateien und laufende Arbeit

    @Test func grosseDateienWerdenNachGroesseOderSeitenzahlErkannt() {
        #expect(!CompressionViewModel.isLargeDocument(
            bytes: 24_999_999, pageCount: 99))
        #expect(CompressionViewModel.isLargeDocument(
            bytes: 25_000_000, pageCount: 1))
        #expect(CompressionViewModel.isLargeDocument(
            bytes: 1_000_000, pageCount: 100))
    }

    @Test func aktiveLaufzeitBleibtAuchBeiLangemJobLesbar() {
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(CompressionViewModel.elapsedTimeText(
            startedAt: start, now: start.addingTimeInterval(7)) == "0:07")
        #expect(CompressionViewModel.elapsedTimeText(
            startedAt: start, now: start.addingTimeInterval(125)) == "2:05")
        #expect(CompressionViewModel.elapsedTimeText(
            startedAt: start, now: start.addingTimeInterval(3_723)) == "1:02:03")
    }

    // MARK: - Advanced-Panel-Bindings

    /// Jede Advanced-Politik erreicht die Custom-Optionen – dieselbe Kette
    /// wie in `PresetFactoryContractTests`, für die neuen Felder.
    @Test(.hangGuard) @MainActor
    func advancedPolitikenErreichenDieOptionen() {
        let viewModel = CompressionViewModel(defaults: .isolatedForTest())
        defer {
            viewModel.customBilevelPolicy = .auto
            viewModel.customCompatibility = .modern
            viewModel.customJPEGBackend = .mozjpeg
        }

        viewModel.customBilevelPolicy = .keep
        viewModel.customCompatibility = .maximum
        viewModel.customJPEGBackend = .imageIO

        let options = viewModel.customOptions
        #expect(options.image.bilevelPolicy == .keep)
        #expect(options.compatibilityPolicy == .maximum)
        #expect(options.image.jpegBackend == .imageIO)

        // Und der Produktionspfad (currentOptions im Custom-Modus) trägt
        // dieselben Politiken – hier wirkt das Panel wirklich.
        viewModel.mode = .custom
        let production = viewModel.currentOptions
        #expect(production.image.bilevelPolicy == .keep)
        #expect(production.compatibilityPolicy == .maximum)
        #expect(production.image.jpegBackend == .imageIO)
    }

    /// Befunde B6/B8 (Review 2026-10-09): Die Bildwerte des Custom-Reiters
    /// waren nur über den ungenutzten Pfad `customOptions` getestet. Hier
    /// der Produktionspfad `currentOptions` im Modus „Eigene".
    ///
    /// Vorher aufgeschriebene Fehlermöglichkeiten:
    ///  1. DPI/Qualität/Grau/Grafik erreichen die Engine nicht oder als
    ///     adaptive Leiter statt fester Qualität.
    ///  2. „Bildkante begrenzen" AUS: der versteckte Slider-Wert begrenzt
    ///     weiter (2200) – muss ein Limit sein, das nie greift.
    ///  3. „Bildkante begrenzen" AN: Slider-Wert und harter Deckel kommen an.
    ///  4. Metadaten entfernen erreicht die Dokumentpolitik.
    @Test(.hangGuard) @MainActor
    func bildwerteDesCustomReitersErreichenDieProduktionsoptionen() {
        let viewModel = CompressionViewModel(defaults: .isolatedForTest())
        viewModel.mode = .custom
        viewModel.customDPI = 120
        viewModel.customQuality = 0.6
        viewModel.customForceGray = true
        viewModel.customGraphicsJPEG = true
        viewModel.customStripMetadata = true
        viewModel.customCapEnabled = false
        viewModel.customMaxPixels = 1500

        var o = viewModel.currentOptions
        #expect(o.image.targetDPI == 120)
        #expect(o.image.qualityPolicy == .fixed(quality: 0.6))
        #expect(o.image.forceGrayscale)
        #expect(o.image.aggressiveGraphics)
        #expect(o.metadataPolicy == .strip)
        #expect(!o.image.hardPixelCap)
        #expect(o.image.maxPixelEdge >= CompressionViewModel.unlimitedPixelEdge,
                "Kante aus, aber Limit \(o.image.maxPixelEdge) wirkt weiter")
        #expect(!o.featureFlags.mrc, "MRC bleibt in Eigene aus")

        viewModel.customCapEnabled = true
        o = viewModel.currentOptions
        #expect(o.image.hardPixelCap)
        #expect(o.image.maxPixelEdge == 1500)
    }

    /// Die Preset-Modi behalten ihre Fabrik-Vorgaben, auch wenn das
    /// Advanced-Panel etwas anderes gespeichert hat: Die Politiken gelten
    /// bewusst nur im Custom-Modus.
    @Test(.hangGuard) @MainActor
    func advancedPolitikenBleibenAufCustomBegrenzt() {
        let viewModel = CompressionViewModel(defaults: .isolatedForTest())
        defer {
            viewModel.customBilevelPolicy = .auto
            viewModel.customCompatibility = .modern
            viewModel.customJPEGBackend = .mozjpeg
        }
        viewModel.customBilevelPolicy = .keep
        viewModel.customCompatibility = .maximum
        viewModel.customJPEGBackend = .imageIO

        viewModel.mode = .smart
        #expect(viewModel.currentOptions.image.bilevelPolicy == .auto)
        #expect(viewModel.currentOptions.compatibilityPolicy == .modern)
        #expect(viewModel.currentOptions.image.jpegBackend == .mozjpeg)
    }

    /// Der Plan trägt das Backend – der Executor-Fallback kodiert sonst
    /// andere Kandidaten als die Planung (Parität Finding 11).
    @Test(.hangGuard) func planTraegtBackend() throws {
        let url = try PDFFixtures.photoHeavyPDF(pixels: 800)
        defer { try? FileManager.default.removeItem(at: url) }

        var options = CompressionOptions.smart
        let defaultPlan = try CompressionPipeline.plan(inputURL: url,
                                                       options: options)
        #expect(defaultPlan.plan.jpegBackend == .mozjpeg)

        options.image.jpegBackend = .imageIO
        let imageIOPlan = try CompressionPipeline.plan(inputURL: url,
                                                       options: options)
        #expect(imageIOPlan.plan.jpegBackend == .imageIO)
    }
}
