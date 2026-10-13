import Testing
import Foundation
import CoreGraphics
@testable import PDFTools

/// Phase 7 (Roadmap) – SSIM-Multi-Gate statt globaler SSIM.
///
/// Der globale SSIM-Mittelwert hat die dokumentierte Katastrophe übersehen:
/// SSIM 0,497 bei 45,9 % veränderter Fläche (IPCC-Bericht, Corpuslauf
/// 29.08.2026, AggressivePresetPolicyTests). Diese Suite hält fest, dass das
/// Multi-Gate solche Fälle über p05-Kachel-, Kanten- und Text-Score abfängt,
/// leichte JPEG-Artefakte auf Fotos aber weiterhin durchlässt.
@Suite struct QualityGatesTests {

    // MARK: - Synthetische Bilder

    /// Text-artiges Muster: weiße Fläche, „Wörter“ aus dünnen schwarzen
    /// Strichen. Tintedichte wie Fließtext (rund 2 %) – genau das Profil, bei
    /// dem der globale SSIM-Mittelwert freundlich bleibt, während die
    /// Textkacheln kollabieren.
    static func textPattern(width: Int = 800, height: Int = 600) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 0, alpha: 1)

        var seed: UInt64 = 20260831
        func next(_ modulo: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(modulo))
        }

        var y = 30
        while y < height - 28 {
            var x = 20
            while x < width - 60 {
                let strokeH = 14 + next(7)
                let lineWidth = 2 + next(2)
                // Wort: Striche mit 10–14 px Abstand, dann Wortlücke.
                let wordLength = 40 + next(50)
                let wordEnd = min(width - 60, x + wordLength)
                while x < wordEnd {
                    ctx.fill(CGRect(x: x, y: y, width: lineWidth, height: strokeH))
                    x += 10 + next(5)
                }
                x += 80 + next(70)
            }
            y += 144
        }
        return ctx.makeImage()
    }

    /// Stark verwaschene, leicht verwackelte Variante: um `reduce` herun-
    /// tergerechnet und versetzt zurückskaliert. Weiße Fläche bleibt, Text-
    /// kanten sterben – das konstruierte 0,497-Szenario.
    static func washedVariant(_ image: CGImage, reduce: Int = 3,
                              shift: CGFloat = 1.5) -> CGImage? {
        let w = image.width, h = image.height
        guard let small = CGContext(data: nil, width: max(1, w / reduce), height: max(1, h / reduce),
                                    bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let out = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        small.interpolationQuality = .high
        small.draw(image, in: CGRect(x: 0, y: 0,
                                     width: CGFloat(small.width), height: CGFloat(small.height)))
        guard let smallImage = small.makeImage() else { return nil }
        out.interpolationQuality = .medium
        out.draw(smallImage, in: CGRect(x: shift, y: shift,
                                        width: CGFloat(w), height: CGFloat(h)))
        return out.makeImage()
    }

    /// Reiner Downsample (ohne Rückskalierung) – emuliert die DPI-Verkleine-
    /// rung der aggressiven Einstellung, bevor der Kandidat kodiert wird.
    static func downsampled(_ image: CGImage, factor: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: max(1, image.width / factor),
                                  height: max(1, image.height / factor),
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0,
                                   width: CGFloat(ctx.width), height: CGFloat(ctx.height)))
        return ctx.makeImage()
    }

    /// Foto-artiges Bild: weicher Verlauf plus sanfte Sinus-Textur und
    /// deterministische Körnung. Keine bimodalen Kacheln.
    static func photoImage(width: Int = 1200, height: Int = 900) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let buf = ctx.data else { return nil }
        let px = buf.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var seed: UInt64 = 4242
        func noise() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double((seed >> 33) % 21) - 10.0   // ±10 Körnung
        }
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let base = Double(x) / Double(width)
                let ripple = 14.0 * sin(Double(x) * 0.021) * sin(Double(y) * 0.017)
                px[o]     = UInt8(max(0, min(255, 40 + base * 160 + ripple + noise())))
                px[o + 1] = UInt8(max(0, min(255, 70 + base * 120 + 0.6 * ripple + noise())))
                px[o + 2] = UInt8(max(0, min(255, 110 + base * 90 - 0.4 * ripple + noise())))
                px[o + 3] = 255
            }
        }
        return ctx.makeImage()
    }

    /// Chromafreie Graustufenfassung des Foto-Verlaufs.
    static func grayPhotoImage(width: Int = 1200, height: Int = 900) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let buf = ctx.data else { return nil }
        let px = buf.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                let ripple = 14.0 * sin(Double(x) * 0.021) * sin(Double(y) * 0.017)
                let v = UInt8(max(0, min(255, 60 + Double(x) / Double(width) * 150 + ripple)))
                px[o] = v; px[o + 1] = v; px[o + 2] = v; px[o + 3] = 255
            }
        }
        return ctx.makeImage()
    }

    /// Kanalversatz bei (fast) gleicher Luminanz: +40 R, −20 G, −20 B. Die
    /// Luminanzgewichte heben sich weitgehend auf, der Farbfehler bleibt.
    static func chromaShifted(_ image: CGImage) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width),
                                   height: CGFloat(image.height)))
        guard let buf = ctx.data else { return nil }
        let px = buf.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
        for i in 0..<(image.width * image.height) {
            let o = i * 4
            px[o]     = UInt8(clamping: Int(px[o]) + 40)
            px[o + 1] = UInt8(clamping: Int(px[o + 1]) - 20)
            px[o + 2] = UInt8(clamping: Int(px[o + 2]) - 20)
            px[o + 3] = 255
        }
        return ctx.makeImage()
    }

    /// JPEG-Rundlauf über das Produktions-Backend (mozjpeg, Fallback ImageIO).
    static func jpegVariant(_ image: CGImage, quality: Double) -> CGImage? {
        guard let data = ImageResampler.encodeJPEG(image, quality: quality) else {
            return nil
        }
        return ImageResampler.decodeJPEG(data)
    }

    // MARK: - 1) Konstruierte Katastrophe (das 0,497-Szenario)

    /// Verwaschener/verwackelter Text: der globale SSIM bleibt über der
    /// smart-Grenze (gemessen 0.894 ≥ 0.88), p05-Kachel- und Text-Score
    /// kollabieren (gemessen 0.695 / 0.576). Genau dieser blinde Fleck des
    /// globalen Mittelwerts wird jetzt abgefangen.
    @Test(.hangGuard) func katastrophenSzenarioWirdDurchKachelMetrikenErkannt() throws {
        let text = try #require(Self.textPattern())
        let washed = try #require(Self.washedVariant(text))
        let measurement = try #require(
            QualityGates.measure(reference: text, candidate: washed),
            "Messung an der Katastrophe fehlgeschlagen")

        let policy = QualityGatePolicy.policy(preset: .smart, imageClass: .graphics)
        // Der blinde Fleck: Der GLOBALE Wert sieht akzeptabel aus …
        #expect(measurement.globalSSIM >= policy.globalSSIM!,
                """
                Szenario soll den blinden Fleck zeigen: global \
                \(measurement.globalSSIM) sollte über \(policy.globalSSIM!) liegen
                """)
        // … während die Kachel-Metriken katastrophal reißen.
        #expect(measurement.p05TileSSIM < policy.p05TileSSIM,
                "p05 \(measurement.p05TileSSIM) müsste unter \(policy.p05TileSSIM) liegen")
        #expect((measurement.textRegionScore ?? 0) < (policy.textRegionScore ?? 0),
                """
                Text-Score \(String(describing: measurement.textRegionScore)) \
                sollte unter \(String(describing: policy.textRegionScore)) liegen
                """)

        let verdict = QualityGates.qualityVerdict(policy: policy, measurement: measurement)
        guard case .fail(let violated) = verdict else {
            Issue.record("Katastrophe wurde durchgelassen: \(measurement)")
            return
        }
        #expect(violated.contains(.p05TileSSIM) || violated.contains(.edgeWeightedScore)
                || violated.contains(.textRegionScore),
                "Falsche Begründung: \(violated)")
        #expect(measurement.qualityScore < 0.72,
                "Q = min(...) sollte tief sein, war \(measurement.qualityScore)")

        // Dieselbe Katastrophe reißt auch die engere und die weitere Stufe mit.
        for preset in [QualityGatePreset.small, .quality] {
            guard case .fail = QualityGates.qualityVerdict(
                preset: preset, imageClass: .graphics, measurement: measurement) else {
                Issue.record("Katastrophe bestand \(preset.rawValue)/graphics")
                return
            }
        }
    }

    // MARK: - 2) Leichte JPEG-Artefakte am Foto

    /// Ein Foto mit q0.75-Körnung muss das Smart-Gate bestehen, q0.85 sogar
    /// das Quality-Gate (gemessen: global 0.986/0.991, p05 0.985/0.990,
    /// ΔE 1.4/1.3) – das Multi-Gate wird für Fotos NICHT strenger als die
    /// bisherige Zusage.
    @Test(.hangGuard) func leichteJPEGArtefakteAmFotoBestehenDasGate() throws {
        let photo = try #require(Self.photoImage())

        let q75 = try #require(Self.jpegVariant(photo, quality: 0.75))
        let m75 = try #require(QualityGates.measure(reference: photo, candidate: q75))
        #expect(QualityGates.qualityVerdict(preset: .smart, imageClass: .photo,
                                            measurement: m75) == .pass,
                "q0.75 fiel am Smart-Gate durch: \(m75)")

        let q85 = try #require(Self.jpegVariant(photo, quality: 0.85))
        let m85 = try #require(QualityGates.measure(reference: photo, candidate: q85))
        #expect(QualityGates.qualityVerdict(preset: .quality, imageClass: .photo,
                                            measurement: m85) == .pass,
                "q0.85 fiel am Quality-Gate durch: \(m85)")
    }

    // MARK: - 3) ΔE-Farbfehler-Gate

    /// Farbverschiebung auf Farbdokument: ΔE 23 (gemessen) reißt das Gate,
    /// während die strukturellen Metriken unbeeindruckt bleiben.
    @Test func farbverschiebungFaelltDurchsDeltaEGate() throws {
        let photo = try #require(Self.photoImage())
        let shifted = try #require(Self.chromaShifted(photo))
        let measurement = try #require(
            QualityGates.measure(reference: photo, candidate: shifted))

        #expect(measurement.isColor)
        guard let deltaE = measurement.meanDeltaE76 else {
            Issue.record("Farbbild ohne ΔE-Messung"); return
        }
        #expect(deltaE > 15, "Kanalversatz sollte einen deutlichen ΔE ergeben: \(deltaE)")

        guard case .fail(let violated) = QualityGates.qualityVerdict(
            preset: .smart, imageClass: .photo, measurement: measurement) else {
            Issue.record("Farbverschiebung wurde durchgelassen: \(measurement)")
            return
        }
        #expect(violated == [.deltaE76],
                "Nur ΔE sollte verletzt sein: \(violated)")
    }

    /// Graustufen ignorieren ΔE: kein Chroma, keine ΔE-Messung, kein Gate.
    @Test(.hangGuard) func graustufenIgnorierenDeltaE() throws {
        let gray = try #require(Self.grayPhotoImage())
        let candidate = try #require(Self.jpegVariant(gray, quality: 0.75))
        let measurement = try #require(
            QualityGates.measure(reference: gray, candidate: candidate))

        #expect(!measurement.isColor)
        #expect(measurement.meanDeltaE76 == nil,
                "Graustufenbild durfte kein ΔE tragen")
        #expect(QualityGates.qualityVerdict(preset: .small, imageClass: .photo,
                                            measurement: measurement) == .pass,
                "Graustufen-Kandidat fiel am Gate durch: \(measurement)")
    }

    // MARK: - 4) Grenzwert-Tabelle (Preset × Klasse, eine Zelle pro Test)

    @Test("Grenzwert-Tabelle vollständig und geordnet",
          arguments: Array(QualityGatePreset.allCases), Array(QualityGateClass.allCases))
    func grenzwertZelle(preset: QualityGatePreset, imageClass: QualityGateClass) throws {
        let policy = QualityGatePolicy.policy(preset: preset, imageClass: imageClass)

        if preset == .custom {
            // Nutzerpfad: keine globale SSIM-Grenze, nur Katakasten-Floors.
            #expect(policy.globalSSIM == nil,
                    "Custom darf keine globale SSIM-Grenze haben (Nutzerwahl)")
            #expect(policy.p05TileSSIM >= 0.45 && policy.p05TileSSIM <= 0.90,
                    "Custom-Floor ist kein Katakasten-Floor: \(policy.p05TileSSIM)")
        } else {
            let global = try #require(policy.globalSSIM, "Preset ohne globale Grenze")
            #expect(global > 0 && global <= 1.0)
            #expect(policy.p05TileSSIM <= global,
                    "p05-Grenze \(policy.p05TileSSIM) über der globalen \(global)")
            #expect(policy.edgeWeightedScore <= global,
                    "Kantengrenze über der globalen Grenze")
            if let text = policy.textRegionScore {
                #expect(text <= global, "Textgrenze über der globalen Grenze")
            }
        }

        switch imageClass {
        case .photo:
            #expect(policy.textRegionScore == nil,
                    "Fotos dürfen keinen Text-Kachel-Gate haben (falsche Fehlalarme)")
            #expect(policy.maxDeltaE76 != nil, "Foto ohne Farbfehler-Gate")
        case .scan:
            #expect(policy.textRegionScore != nil,
                    "Scans brauchen eine eigene Textkachel-Grenze")
            #expect(policy.maxDeltaE76 != nil, "Farbscans brauchen ein Farbgate")
        case .bilevel:
            #expect(policy.maxDeltaE76 == nil, "Bilevel ist farbfrei")
            if let global = policy.globalSSIM {
                #expect(global >= 0.99, "Bilevel ist verlustfrei: \(global) zu lasch")
            }
        case .graphics, .screenshot:
            #expect(policy.maxDeltaE76 != nil)
            #expect(policy.textRegionScore != nil,
                    "Grafiken/Screenshots brauchen eine Textkachel-Grenze")
        }
    }

    @Test func scanInhalteNutzenDieDedizierteGateZelle() {
        #expect(QualityGateClass(contentClass: .scanContinuous) == .scan)
        #expect(QualityGateClass(contentClass: .scanBilevel) == .scan)
        #expect(QualityGateClass(contentClass: .photo) == .photo)

        let scan = QualityGatePolicy.policy(preset: .smart, imageClass: .scan)
        let photo = QualityGatePolicy.policy(preset: .smart, imageClass: .photo)
        #expect(scan.textRegionScore != nil)
        #expect(photo.textRegionScore == nil)
        #expect(scan.edgeWeightedScore > photo.edgeWeightedScore)
    }

    /// Innerhalb einer Klasse steigen die Grenzen mit dem Preset – eine
    /// strengere Einstellung darf keine laschere Zelle haben.
    @Test("Grenzwerte steigen mit dem Preset", arguments: Array(QualityGateClass.allCases))
    func grenzwerteSteigenMitPreset(imageClass: QualityGateClass) {
        let small = QualityGatePolicy.policy(preset: .small, imageClass: imageClass)
        let smart = QualityGatePolicy.policy(preset: .smart, imageClass: imageClass)
        let quality = QualityGatePolicy.policy(preset: .quality, imageClass: imageClass)

        #expect((small.globalSSIM ?? 0) <= (smart.globalSSIM ?? 1))
        #expect((smart.globalSSIM ?? 0) <= (quality.globalSSIM ?? 1))
        #expect(small.p05TileSSIM <= smart.p05TileSSIM)
        #expect(smart.p05TileSSIM <= quality.p05TileSSIM)
        #expect(small.edgeWeightedScore <= smart.edgeWeightedScore)
        #expect(smart.edgeWeightedScore <= quality.edgeWeightedScore)
        #expect((small.textRegionScore ?? 0) <= (smart.textRegionScore ?? 1))
        #expect((smart.textRegionScore ?? 0) <= (quality.textRegionScore ?? 1))
        #expect((small.maxDeltaE76 ?? 0) >= (smart.maxDeltaE76 ?? 0))
        #expect((smart.maxDeltaE76 ?? 0) >= (quality.maxDeltaE76 ?? 0))
    }

    /// Die Politikableitung aus der bestehenden Engine-Schwelle: bekannte
    /// Zusage-Werte mappen auf ihr Preset, feste Qualität bleibt gate-frei.
    @Test func politikAbleitungAusSchwellwert() throws {
        let photo = QualityGateClass.photo
        #expect(QualityGatePolicy.policy(matching: 0.86, imageClass: photo)
                == .policy(preset: .small, imageClass: photo))
        #expect(QualityGatePolicy.policy(matching: 0.90, imageClass: photo)
                == .policy(preset: .smart, imageClass: photo))
        #expect(QualityGatePolicy.policy(matching: 0.95, imageClass: photo)
                == .policy(preset: .quality, imageClass: photo))

        // Feste Qualität (Custom): 0 und > 1.0 → keine globale Grenze.
        #expect(QualityGatePolicy.policy(matching: 0.0, imageClass: photo).globalSSIM == nil)
        #expect(QualityGatePolicy.policy(matching: 1.1, imageClass: photo).globalSSIM == nil)

        // Fremder Wert in (0, 1]: wird als globale Grenze übernommen.
        let fremd = QualityGatePolicy.policy(matching: 0.75, imageClass: photo)
        #expect(fremd.globalSSIM == 0.75)
        #expect(fremd.p05TileSSIM == 0.45, "Katakasten-Floors bleiben bestehen")
    }

    // MARK: - 5) Performance-Sanity

    /// Das Multi-Gate darf nicht deutlich teurer sein als der bisherige
    /// globale SSIM-Vergleich pro Kandidat. Gemessen wird der volle
    /// Kandidaten-Durchlauf (Encode + Decode + Metrik) über dieselbe
    /// dreistufige Leiter, Minimum über drei Wiederholungen.
    @Test(.hangGuard) func multiGateBleibtInnerhalbDesDoppeltenSSIMAufwands() throws {
        let photo = try #require(Self.photoImage(width: 1000, height: 750))
        let ladder = [0.75, 0.80, 0.85]
        let evaluator = QualityGates.Evaluator(reference: photo)

        func runOldPath() throws -> Duration {
            let clock = ContinuousClock()
            let start = clock.now
            for q in ladder {
                guard let decoded = ImageResampler.encodeJPEG(photo, quality: q)
                    .flatMap(ImageResampler.decodeJPEG) else { continue }
                _ = QualityMetrics.ssim(original: photo, candidate: decoded)
            }
            return clock.now - start
        }

        func runNewPath() throws -> Duration {
            let clock = ContinuousClock()
            let start = clock.now
            for q in ladder {
                guard let decoded = ImageResampler.encodeJPEG(photo, quality: q)
                    .flatMap(ImageResampler.decodeJPEG) else { continue }
                _ = evaluator.measure(candidate: decoded)
            }
            return clock.now - start
        }

        // Warmlauf: erster Lauf enthält Einmalkosten (Framework, Caches).
        _ = try runOldPath()
        _ = try runNewPath()

        var oldBest: Duration?
        var newBest: Duration?
        for _ in 0..<3 {
            let oldRun = try runOldPath()
            let newRun = try runNewPath()
            if oldBest == nil || oldRun < oldBest! { oldBest = oldRun }
            if newBest == nil || newRun < newBest! { newBest = newRun }
        }
        let oldDuration = try #require(oldBest)
        let newDuration = try #require(newBest)
        let oldMs = Double(oldDuration.components.seconds) * 1000
            + Double(oldDuration.components.attoseconds) / 1e15
        let newMs = Double(newDuration.components.seconds) * 1000
            + Double(newDuration.components.attoseconds) / 1e15

        #expect(newMs <= 2.0 * oldMs,
                "Multi-Gate \(newMs) ms vs. bisheriger SSIM-Weg \(oldMs) ms")
    }

    // MARK: - Einbindung: Qualitätssteuerung der Candidate Engine

    /// V2-11 – die frühere planJPEG-/adaptiveJPEG-Leiter ist entfernt (§4.18);
    /// die Qualitätssteuerung der Produktion ist die Bracketed Search (§9.3)
    /// über dieselben Multi-Gates. Der Test stellt denselben Befund am
    /// Produktionsweg nach: Eine kachelkatastrophale Stufe wird NICHT
    /// geliefert, obwohl der globale SSIM sie durchgelassen hätte. Gemessen:
    /// JPEG q0.05 auf Text-Grafik nach 3fachem Downsample hat global 0.945
    /// (über der Schwelle), aber p05 0.779 – das Gate muss die Stufe fällen.
    @Test(.hangGuard) func leiterSpringtBeiKachelKatastropheZurNaechstenStufe() throws {
        let text = try #require(Self.textPattern())
        let shrunk = try #require(Self.downsampled(text, factor: 3))

        // Der blinde Fleck des früheren Gates, direkt nachgemessen:
        let low = try #require(Self.jpegVariant(shrunk, quality: 0.05))
        let oldScore = QualityMetrics.ssim(original: shrunk, candidate: low)
        #expect(oldScore >= 0.90,
                "Annahme kaputt: globales SSIM \(oldScore) wäre schon früher gefallen")

        let rungs = BracketedJPEGSearch.run(
            reference: shrunk, grayscale: false, backend: .mozjpeg,
            policy: .bracketed(
                qLow: 0.05, qHigh: 0.9,
                gate: QualityGatePolicy.policy(matching: 0.90,
                                               imageClass: .graphics),
                imageClass: .graphics, minimumSSIM: 0.90))
        let lowRung = try #require(rungs.first { abs($0.quality - 0.05) < 0.001 })
        #expect(!lowRung.passed,
                "Die Katastrophen-Stufe 0.05 hielt das Multi-Gate – Gate kaputt")
        let winner = try #require(BracketedJPEGSearch.winner(in: rungs))
        // §9.3 – die FINALE Wahl ist der kleinste gemessene PASS-Rung
        // (Qualitätsmetriken sind nicht monoton); die Katastrophen-Stufe
        // darf niemals gewinnen. Mit den Graphics-Gates ist hier bereits
        // eine mittlere Bisektionsstufe passierbar – der Kernbefund
        // (globales SSIM hätte die Katastrophe durchgelassen) bleibt
        // über lowRung.gefallen festgenagelt.
        #expect(winner.quality > lowRung.quality,
                "Gewinner war die Katastrophen-Stufe \(winner.quality)")
    }

    /// Feste Nutzerqualität (Custom) bleibt gate-frei: genau diese Stufe,
    /// keine strenge Behandlung (Katastrophen-Floor prüft der Planner über
    /// die Preset-Floors, §10.3).
    @Test(.hangGuard) func festeQualitaetWirdNichtStrengerBehandeltAlsHeute() throws {
        let photo = try #require(Self.photoImage(width: 600, height: 400))
        let rungs = BracketedJPEGSearch.run(
            reference: photo, grayscale: false, backend: .mozjpeg,
            policy: .ungated(quality: 0.75))
        let rung = try #require(rungs.first)
        #expect(abs(rung.quality - 0.75) < 0.001,
                "Feste Qualität wurde verändert: \(rung.quality)")
        #expect(rung.passed)
        let decoded = try #require(ImageResampler.decodeJPEG(rung.data))
        #expect(QualityMetrics.ssim(original: photo, candidate: decoded) > 0.95)
    }

    // MARK: - Mess-Eigenschaften

    /// Identische Bilder: alle strukturellen Metriken neutral.
    @Test func identischeBilderSindNeutral() throws {
        let photo = try #require(Self.photoImage(width: 500, height: 400))
        let measurement = try #require(
            QualityGates.measure(reference: photo, candidate: photo))

        #expect(measurement.globalSSIM == 1.0)
        #expect(measurement.p05TileSSIM == 1.0)
        #expect(measurement.edgeWeightedScore == 1.0)
        #expect(measurement.textRegionScore == nil)
        #expect(measurement.psnr == 96.0)
        #expect(measurement.tileSSIMs.count == QualityGates.tileGrid * QualityGates.tileGrid)
        if let deltaE = measurement.meanDeltaE76 {
            #expect(deltaE < 0.5, "Identische Farben dürfen kein ΔE haben: \(deltaE)")
        }
        #expect(QualityGates.qualityVerdict(preset: .quality, imageClass: .photo,
                                            measurement: measurement) == .pass)
        #expect(QualityGates.qualityVerdict(preset: .quality, imageClass: .graphics,
                                            measurement: measurement) == .pass)
    }

    /// Evaluator hält die Referenz-Stichprobe: zwei Kandidaten gegen dieselbe
    /// Referenz liefern dieselben Werte wie je eine Frischmessung.
    @Test func evaluatorWiederverwendungIstKonsistent() throws {
        let photo = try #require(Self.photoImage(width: 700, height: 500))
        let a = try #require(Self.jpegVariant(photo, quality: 0.7))
        let b = try #require(Self.jpegVariant(photo, quality: 0.9))

        let evaluator = QualityGates.Evaluator(reference: photo)
        let ma1 = try #require(evaluator.measure(candidate: a))
        let ma2 = try #require(evaluator.measure(candidate: a))
        let mb = try #require(evaluator.measure(candidate: b))
        let freshA = try #require(QualityGates.measure(reference: photo, candidate: a))

        #expect(ma1 == ma2, "Wiederholte Messung driftet")
        #expect(ma1.globalSSIM == freshA.globalSSIM)
        #expect(mb.p05TileSSIM > ma1.p05TileSSIM,
                "Höhere Qualität sollte ein besseres p05 haben")
        _ = mb
    }

    /// 5.-Perzentil als nearest rank.
    @Test func p05Perzentil() {
        let values = (1...64).map { Double($0) / 64.0 }
        // 64 Werte: Index ceil(0.05·64) − 1 = 3 → der viertkleinste Wert.
        #expect(QualityGates.percentile05(of: values) == 4.0 / 64.0)
        #expect(QualityGates.percentile05(of: [0.3]) == 0.3)
        #expect(QualityGates.percentile05(of: []) == 1.0)
        #expect(QualityGates.percentile05(of: [1.0, 0.2, 0.5]) == 0.2)
    }

    /// Text-Kacheln werden erkannt, Foto-Kacheln nicht – Grundlage dafür,
    /// dass der Text-Score nur greift, wo er aussagekräftig ist.
    @Test(.hangGuard) func textKachelnNurBeimTextmuster() throws {
        let text = try #require(Self.textPattern())
        let textMeasurement = try #require(
            QualityGates.measure(reference: text, candidate: text))
        #expect(textMeasurement.textRegionScore != nil,
                "Textmuster ohne erkannte Text-Kacheln")

        let photo = try #require(Self.photoImage())
        let photoMeasurement = try #require(
            QualityGates.measure(reference: photo, candidate: photo))
        #expect(photoMeasurement.textRegionScore == nil,
                "Foto-Kacheln wurden als Text erkannt")
    }

    /// Die RenderDifferential-Erweiterung (Phase 7) liefert dieselben
    /// Multi-Gate-Metriken für gerenderte Seitenbilder.
    @Test func renderDifferentialMultiGateErweiterung() throws {
        let text = try #require(Self.textPattern())
        let washed = try #require(Self.washedVariant(text))
        let measurement = try #require(
            RenderDifferential.multiGateMetrics(source: text, output: washed))
        guard case .fail(let violated) = QualityGates.qualityVerdict(
            preset: .smart, imageClass: .graphics, measurement: measurement) else {
            Issue.record("Seiten-Katastrophe nicht erkannt: \(measurement)")
            return
        }
        #expect(!violated.isEmpty)
    }
}
