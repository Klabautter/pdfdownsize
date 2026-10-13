import Foundation

/// Masterplan Schritt 6 / Finding 12 – EIN Optionsobjekt für die gesamte
/// Compression-Pipeline.
///
/// Vorher wanderten Einzelparameter als Bool-Kette durch fünf Methoden, und
/// mehrere davon (`forceGrayscale`, `aggressiveGraphics`, `stripMetadata`,
/// `linearize`) erreichten den Produktionspfad überhaupt nicht mehr. Ein
/// Optionsobjekt kann nicht teilweise verloren gehen: Planner, Estimator und
/// Executor bekommen dasselbe `CompressionOptions`.

// MARK: - Feature-Flags (Masterplan §25)

/// Interne Integrations-Flags. Kein zweiter Engine-Pfad – es gibt nur EINEN
/// Produktionspfad (Candidate Engine, V2-11-Zertifizierung). Seit dem
/// V2-Cutover sind die Core-Flags Default AN (§25: „V2 Flags default ON,
/// alte V1-Branches entfernen“); die Flags bleiben als Engineering-Schalter
/// für Messungen und Not-Aus erhalten. MRC bleibt als Schalter vorhanden;
/// die Standardmodi aktivieren es nur zusammen mit dem Provision-Budget.
struct MRCProvisionBudget: Equatable, Codable, Sendable {
    /// Maximal teuer untersuchte Scan-Seiten je Dokument.
    var maximumPages: Int
    /// Summe der Rasterpixel aller untersuchten Seiten.
    var maximumPixels: Int64
    /// Weiches Dokumentbudget. Eine bereits laufende Seite wird sauber zu
    /// Ende geprueft; danach startet keine weitere Provision.
    var maximumElapsedSeconds: Double

    static let oneClick = MRCProvisionBudget(
        maximumPages: 8,
        maximumPixels: 200_000_000,
        maximumElapsedSeconds: 60)

    func permitsNextPage(attemptedPages: Int,
                         attemptedPixels: Int64,
                         elapsedSeconds: Double,
                         nextPagePixels: Int64) -> Bool {
        guard maximumPages > 0, maximumPixels > 0,
              maximumElapsedSeconds > 0 else { return false }
        return attemptedPages < maximumPages
            && elapsedSeconds < maximumElapsedSeconds
            && nextPagePixels >= 0
            && attemptedPixels <= maximumPixels - nextPagePixels
    }
}

struct CompressionFeatureFlags: Equatable, Codable, Sendable {
    /// Phase V2-3a – Candidate Engine im Planner (§9, §5.8 Phase A):
    /// CandidateSets erzeugen, lokal wählen, in die bestehenden Aktionen
    /// übersetzen. Seit V2-11 (Zertifizierung) der EINZIGE Produktionspfad.
    var candidateEngine: Bool = true
    /// Phase V2-7 – MRC Scan Engine (§13): Segmentierung + Layer + Seiten-
    /// Rekonstruktion für Scan-Seiten. V2-Advanced (§25: Flag für dauerhaft
    /// experimentelle Features).
    ///
    /// V2-Advanced-Zertifizierung (Korpus-Beleg
    /// `benchmark/mrc-certification/run5-release-final`): Qualität und
    /// Sicherheit sind NACHGEWIESEN sauber – 0 §13.10-Verletzungen (SSIM
    /// 0.9836 ≥ 0.97, p05 0.9555 ≥ 0.95, inkDelta 0.00122 ≤ 0.005 an der
    /// fertigen Ausgabe), OCR-Layer 85/85 unverändert (§13.2), Fallback-
    /// Kette fail-closed (12/12 Dateien ohne MRC inhaltsgleich zur Basis,
    /// 0 verschobene Wahl-Entscheidungen), Farb-/Masken-Render-Verifikation
    /// ohne Befund. Der Größenhebel ist messbar positiv, aber
    /// materialkonzentriert: +24.6 pp gewichtet auf 06_Scans_Color (−51 %
    /// auf der Gewinner-Datei, MRC-Bundle 179 KB vs. JPEG 343 KB), 0 pp auf
    /// 07/08/09 – dort verweigern Klassifikations-/Transform-Gate,
    /// Segmentierung, Byte-Gewinn oder Seiten-QA korrekt (76 1-bit-Seiten
    /// gehören dem verlustfreien Bilevel-Race, §9.7).
    ///
    /// Der historische Grund für Default AUS war die Laufzeit: Die Provision (Segmen-
    /// tierung + JBIG2-Maske + max. zwei Stufen + Scratch-QA-Render je
    /// Seite) kostet gemessen ~4–6 s je geprüfter Scan-Seite (Release) und
    /// ist nicht parallelisiert. Die Standardmodi begrenzen sie deshalb jetzt
    /// mit `MRCProvisionBudget` auf Seiten, Pixel und Dokumentzeit. Offen
    /// bleiben fuer eine spaetere Scope-Erweiterung:
    ///   1. der §13.1-Scope Seiten mit dominierendem Vollbild PLUS
    ///      sekundären kleinen Rastern zulässt (nur der dominante Draw wird
    ///      ersetzt) – sonst bleibt die Buchscan-Klasse (imageCount 2)
    ///      komplett außen vor,
    ///   2. der Korpus mehr 8-bit-Einzelbild-Scans trägt, um den Hebel
    ///      über mehr als eine Materialklasse zu belegen.
    var mrc: Bool = false
    /// Phase V2-8 (§14) – selektives Font-Subsetting als Candidate mit
    /// je-Font-QA (§14.4) und Aktivierungspolitik (§14.3). Seit V2-11
    /// Default ON – es ersetzt den früheren globalen Subset-Pass.
    var selectiveFontSubset: Bool = true
    /// Phase V2-9 (§15.2) – Pixel-Budget-Scheduler: Die Candidate-Erzeugung
    /// (decode/resize/encode/measure) läuft als begrenzte Parallelität unter
    /// Σ estimatedWorkingBytes ≤ Budget. Seit V2-11 Default ON.
    var pixelBudgetScheduler: Bool = true
    /// Phase V2-9 (§15.6) – Single Final Write: Der Executor schreibt mit
    /// finalen Writer-Optionen EINMAL statt images.pdf + qpdf-CLI-Pass.
    /// Greift nur bei FlatePolicy .standard + CompatibilityPolicy .modern;
    /// Zopfli (Maximum) und der Kompatibilitätsmodus bleiben dokumentierte
    /// Zwei-Write-Ausnahmen (§15.7). Seit V2-11 Default ON.
    var singleWrite: Bool = true
}

// MARK: - Klassifikator-Politik (Masterplan §8/§25)

/// Wie Bildinhalte klassifiziert werden. `v2` ist die V2-Feature-Extraktion
/// und -Klassifikation (§8) mit Seiten-/Bild-Verknüpfung (§8.4); die
/// Ableitung auf die photo/graphics-Welt ist Teil derselben Entscheidung,
/// kein zweiter Pfad. `legacy` bleibt als Engineering-Schalter erhalten:
/// Er lässt die abgeleitete V2-Klasse für die ROUTE unbeachtet und
/// klassifiziert die Route nur über den bestehenden ImageClassifier.
enum ClassifierPolicy: String, Codable, Sendable, CaseIterable {
    case legacy
    case v2
}

// MARK: - QA-Rollback-Politik (Masterplan §11.5, V2-5)

/// Wie die Pipeline auf ein scheiterndes QA-Ergebnis reagiert.
///
/// Rollback ist Re-Planning (§11.5): Findings mit severity error/fatal
/// erzeugen DecisionOverrides, das ORIGINAL wird erneut geöffnet und der
/// Plan entlang der Rückstufungsleiter konservativer gefahren – niemals wird
/// am geschriebenen Output herumgedoktert (PDFObjectID-Regel).
enum QARollbackPolicy: String, Codable, Sendable, CaseIterable {
    /// Fail-closed: Validierungs-Fail wirft, der Nutzer erhält das
    /// byte-identische Original (Voreinstellung – die Kette ist nach der
    /// V2-11-Zertifizierung die nächste Aktivierungsstufe).
    case off
    /// Re-Plan-Rollback aktiv (§11.5) – greift im traceVersion-2-Plan.
    case auto
}

// MARK: - Metadaten

enum MetadataPolicy: String, Codable, Sendable, CaseIterable {
    /// Dokumentinformationen bleiben erhalten.
    case preserve
    /// /Info-Felder und XMP werden entfernt; der deterministische Producer
    /// bleibt, damit Ausgaben reproduzierbar bleiben.
    case strip
}

// MARK: - Linearisierung

enum LinearizationPolicy: String, Codable, Sendable, CaseIterable {
    case none
    /// „Fast Web View" – linearisiert für seitenweises Laden.
    case fastWebView
}

// MARK: - Qualitätspolitik

/// Wie die JPEG-Qualität eines Bildes bestimmt wird.
///
/// Zuvor steckten zwei Semantiken in denselben drei Feldern
/// (`jpegQuality`, `qualityLadder`, `ssimThreshold`), und der UI-Pfad
/// erzwang die zweite über einen unerreichbaren Schwellwert: `1.1` bei
/// einstufiger Leiter. Da SSIM höchstens 1.0 erreicht, war die Bedingung nie
/// erfüllt – Custom kodierte KEIN Bild um, die gewählte Qualität wurde nie
/// ausgeführt.
///
/// Die beiden Fälle sind verschiedene Entscheidungen und stehen deshalb
/// getrennt da:
enum JPEGQualityPolicy: Equatable, Codable, Sendable {
    /// Smart: aufsteigend probieren, die erste Stufe nehmen, die `minimumSSIM`
    /// hält. Erreicht keine Stufe die Schwelle, wird das Bild behalten – die
    /// Schwelle ist eine Zusage, kein Richtwert.
    case adaptive(ladder: [Double], minimumSSIM: Double)

    /// Custom: genau diese Qualität ausführen. Der Nutzer hat gewählt; der
    /// Planner stellt die Wahl nicht über ein Qualitätsgate erneut infrage.
    case fixed(quality: Double)

    /// Die Qualität, mit der ein Bild mindestens kodiert wird.
    var nominalQuality: Double {
        switch self {
        case .adaptive(let ladder, _): return ladder.max() ?? 0.9
        case .fixed(let quality): return quality
        }
    }

    /// Hebt die Qualität an, ohne die Art der Entscheidung zu ändern.
    ///
    /// Gebraucht für Grafiken und Screenshots: Sie vertragen weniger
    /// Kompression als Fotos, weil harte Kanten sichtbar leiden. Eine feste
    /// Wahl bleibt fest, eine Leiter bleibt eine Leiter – angehoben wird nur
    /// der Wert. Zuvor lief das über eine direkte Zuweisung an `jpegQuality`,
    /// die an der Politik vorbeiging.
    ///
    /// „Angehoben" heißt nie „abgesenkt": Liegt eine Stufe schon auf oder
    /// über dem Deckel, bleibt sie unverändert. Vorher kappte der Deckel
    /// eine vom Nutzer gewählte Custom-Qualität 0,92 auf 0,82 (Befund A5,
    /// Review 2026-10-09).
    func raised(to minimum: Double, cap: Double) -> JPEGQualityPolicy {
        func lift(_ quality: Double) -> Double {
            quality >= cap ? quality : Swift.min(cap, Swift.max(quality, minimum))
        }
        switch self {
        case .fixed(let quality):
            return .fixed(quality: lift(quality))
        case .adaptive(let ladder, let minimumSSIM):
            let lifted = ladder.map(lift)
            return .adaptive(ladder: Array(Set(lifted)).sorted(),
                             minimumSSIM: minimumSSIM)
        }
    }
}

// MARK: - Bilevel-Politik (Roadmap Phase 2)

/// Wie Bilevel-Bilder – echtes 1-bit oder exakt zweiwertiges 8-bit – behandelt
/// werden. Die Option kennt kein Codec-Vokabular: Sie steuert nur, ob der
/// Bilevel-Pfad überhaupt laufen darf.
enum BilevelPolicy: String, Codable, Sendable, CaseIterable {
    /// Candidate Race KEEP vs. CCITT G4 vs. lossless JBIG2. Gewinnt nur,
    /// was das Bitidentitäts-Gate besteht UND kleiner ist als das Original.
    case auto
    /// Bilevel-Bilder bleiben unangetastet (1-bit war dafür vorher ohnehin
    /// gesperrt; mit `keep` bleibt auch exakt zweiwertiges 8-bit unberührt).
    case keep
}

// MARK: - JPEG-Backend (Roadmap Phase 1)

/// Wer kodiert JPEG? mozjpeg (statisch in der Bridge gelinkt) ist der
/// Standard: Trellis-Quantisierung, progressive Scans mit Scan-Optimierung,
/// optimierte Huffman-Tabellen. ImageIO bleibt als Fallback-Backend – für
/// Farbräume, die der mozjpeg-Shim bewusst nicht annimmt (CMYK), und wenn
/// der Shim Fehler meldet. DEKODIERT wird weiterhin über AppKit/ImageIO.
enum JPEGBackend: String, Codable, Sendable, CaseIterable {
    case mozjpeg
    case imageIO
}

// MARK: - Dedup-Politik (Roadmap Phase 3b)

/// Ob der Content-Hash-Dedup über alle indirekten Objekte laufen darf. Der
/// Pass ist verlustfrei (identische dekomprimierte Bytes, whitelist-gleiche
/// Wörterbücher; siehe pdfcore_deduplicate_document) und kann die Ausgabe
/// nie vergrößern – verwaiste Objekte verwirft der Writer.
enum DedupPolicy: String, Codable, Sendable, CaseIterable {
    /// Dedup läuft nach den Bildtransformationen (Voreinstellung).
    case auto
    /// Dedup bleibt vollständig aus.
    case off
}

// MARK: - Font-Politik (Roadmap Phase 5a)

/// Ob Font-Dedup und Unused-Font-GC laufen dürfen. Der Pass ist verlustfrei:
/// Gemerged werden Font-Dicts nur bei identischem FontFile-Hash UND
/// identischer semantischer Dict-Form (siehe pdfcore_font_audit), die GC
/// trägt nur Einträge aus Resources-Maps, die kein Tf ihres Contents je
/// benutzt. Die Ausgabe kann dadurch nie größer werden.
enum FontPolicy: String, Codable, Sendable, CaseIterable {
    /// Font-Dedup + GC laufen nach dem Bild-/Document-Dedup (Voreinstellung).
    case auto
    /// Fonts bleiben vollständig unangetastet.
    case off
}

// MARK: - Font-Subsetting-Politik (Roadmap Phase 5b, V2-11 umgenutzt)

/// Ob Fontprogramme neu geschrieben werden dürfen. Seit V2-11 steuert die
/// Politik den SELEKTIVEN Pfad (V2-8, §14): `on` erlaubt die
/// Candidate-Entscheidungen des Plans (Aktivierungspolitik §14.3,
/// je-Font-QA §14.4); `off` lässt Fontprogramme byteidentisch. Der frühere
/// globale Snapshot-Rollback-Pass (`.on` vor V2-11) ist entfernt – der
/// selektive Pfad hat ihn ersetzt (§4.18).
enum FontSubsettingPolicy: String, Codable, Sendable, CaseIterable {
    /// Selektives Subsetting hinter der je-Font-QA erlaubt (Default).
    case on
    /// Fontprogramme bleiben byteidentisch.
    case off
}

// MARK: - Resource-GC-Politik (V2-8, Masterplan §14.6)

/// Ob unbenutzte Einträge aus Resource-Maps getragen werden dürfen (XObject,
/// ExtGState, ColorSpace, Pattern, Shading, Properties – Font-Maps bleiben
/// der Phase-5a-GC vorbehalten). Der Pass ist verlustfrei und schützt
/// konservativ: unscanbarer Content schützt seine Map, /AcroForm/DR und
/// Properties unter StructTree/OC bleiben stehen.
enum ResourceGCPolicy: String, Codable, Sendable, CaseIterable {
    /// Keine Resource-GC (Not-Aus für Messungen/Fehlersuche).
    case off
    /// Resource-GC erlaubt – läuft im traceVersion-2-Plan (Candidate
    /// Engine). Seit V2-11 Default: der konservative C-Kern (§14.6) ist
    /// zertifiziert.
    case auto
}

// MARK: - Struktur-Politik (Roadmap Phase 3c)

/// Wie stark der Struktur-Pass (qpdf) Flate-Streams nachpackt.
enum FlatePolicy: String, Codable, Sendable, CaseIterable {
    /// zlib -9 – der Standard ALLER Presets. Sicherheitsnetz: Zopfli läuft
    /// nie, ohne dass ein Preset es ausdrücklich bestellt hat.
    case standard
    /// Zopfli über `QPDF_ZOPFLI=silent` – nur im Maximum-Preset. Misst
    /// rund 3–8 % kleiner als zlib -9, ist aber ~100× langsamer; fällt
    /// still auf zlib zurück, wenn der gebaute qpdf kein Zopfli trägt.
    case maximum
}

/// Wie weit die Ausgabe Rücksicht auf alte PDF-Leser nimmt (Roadmap Phase 9,
/// „Modern/Maximal kompatibel" – hier bereits auf Optionsebene verdrahtet,
/// damit die Politik mit dem Plan zum Executor wandert).
enum CompatibilityPolicy: String, Codable, Sendable, CaseIterable {
    /// Objekt-Streams an (PDF 1.5+), JPEG-Repack darf progressive Scans
    /// schreiben.
    case modern
    /// Maximale Kompatibilität: `--object-streams=disable`, JPEG-Repack
    /// nur mit optimierten Huffman-Tabellen (Baseline, kein Scan-Entwurf),
    /// und kein Zopfli – beides kostet Bytes, nichts an Verträglichkeit.
    case maximum
}

// MARK: - Bildoptionen

struct ImageCompressionOptions: Equatable, Codable, Sendable {
    /// Zielauflösung in DPI, gemessen an der sichtbaren Platzierung.
    var targetDPI: Double
    /// Toleranzfaktor: erst ab `targetDPI * tolerance` wird verkleinert.
    /// Verhindert, dass eine 230-DPI-Grafik wegen 10 DPI neu kodiert wird.
    var tolerance: Double
    /// Harte Obergrenze der Pixelkantenlänge.
    var maxPixelEdge: Int
    /// true = `maxPixelEdge` gilt IMMER, auch wenn die DPI in Ordnung sind.
    var hardPixelCap: Bool
    /// Die Qualitätsentscheidung – die EINZIGE Quelle der Wahrheit.
    ///
    /// `jpegQuality`, `qualityLadder` und `ssimThreshold` sind daraus
    /// abgeleitet. Zuvor standen sie als eigene Felder daneben: Wer einen
    /// davon setzte, änderte die Politik nicht mit, und beide liefen
    /// auseinander – dieselbe Fehlerklasse wie beim Seiten-Mapping und beim
    /// Journal (Masterplan 2.1).
    var qualityPolicy: JPEGQualityPolicy

    /// Nominale Qualität – bei `adaptive` die höchste Stufe.
    var jpegQuality: Double { qualityPolicy.nominalQuality }

    /// Aufsteigend geprüfte Stufen. Bei `fixed` genau eine: die gewählte.
    var qualityLadder: [Double] {
        get {
            switch qualityPolicy {
            case .adaptive(let ladder, _): return ladder
            case .fixed(let quality): return [quality]
            }
        }
        set {
            // Schreibzugriff hält die Politik nach – sonst wäre die
            // Ableitung wieder zweigleisig.
            switch qualityPolicy {
            case .adaptive(_, let minimumSSIM):
                qualityPolicy = newValue.count > 1
                    ? .adaptive(ladder: newValue, minimumSSIM: minimumSSIM)
                    : .fixed(quality: newValue.first ?? jpegQuality)
            case .fixed:
                qualityPolicy = newValue.count > 1
                    ? .adaptive(ladder: newValue, minimumSSIM: 0.98)
                    : .fixed(quality: newValue.first ?? jpegQuality)
            }
        }
    }

    /// Qualitätszusage bei `adaptive`; bei `fixed` bedeutungslos (0).
    var ssimThreshold: Double {
        get {
            switch qualityPolicy {
            case .adaptive(_, let minimumSSIM): return minimumSSIM
            case .fixed: return 0
            }
        }
        set {
            // Eine Schwelle über 1.0 ist unerreichbar und meint „feste
            // Qualität" – so wurde sie im UI-Pfad benutzt.
            if newValue > 1.0 {
                qualityPolicy = .fixed(quality: jpegQuality)
            } else {
                qualityPolicy = .adaptive(ladder: qualityLadder.count > 1
                                            ? qualityLadder : [jpegQuality],
                                          minimumSSIM: newValue)
            }
        }
    }
    /// Farbbilder in Graustufen wandeln.
    var forceGrayscale: Bool
    /// Grafiken/Screenshots aggressiver behandeln (sonst verlustfrei).
    var aggressiveGraphics: Bool
    /// Kodier-Backend für JPEG-Ausgabe; Default mozjpeg, Fallback ImageIO.
    var jpegBackend: JPEGBackend = .mozjpeg

    /// Engineering-only Smart trial: add a 600-DPI rung and let graphics
    /// compete with lossless candidates behind the existing strict gates.
    /// Optional for backward-compatible decoding of saved options.
    var experimentalSmartPhotoCandidates: Bool? = nil

    /// Bilevel-Politik (Phase 2b); Default ist der verlustfreie Race.
    var bilevelPolicy: BilevelPolicy = .auto



    /// Smart – die Voreinstellung für „einfach kleiner machen".
    ///
    /// **220 DPI** (2026-10-09, Nutzerbefund und Messung). Zuvor 150 DPI mit
    /// der Begründung, 100 % auf Retina (144 px/Zoll) sei die normale
    /// Ansicht und eine bildschirmfüllende Seite (≈ 220 px/Zoll) der seltene
    /// Fall. Gemessen ist es umgekehrt: „Seite einpassen" zeigt auf einem
    /// 16"-MacBook ≈ 177 px/Zoll, auf einem 27"-Display ≈ 230, „Breite
    /// einpassen" auf 14" über 300. Ein 150-DPI-Bild wird dort hochgerechnet,
    /// und kleiner Text in Fotos (Folien, Whiteboards, abfotografierte
    /// Dokumente) wird sichtbar weich – schon bei 100 %.
    ///
    /// Folienfoto-Dokument (6 Seiten, 15 Handyfotos, 16,8 MB), Seiten-SSIM
    /// gegen das Original bei 144 ppi, Mittel über die Seiten:
    ///
    ///     150 DPI, q75 (Smart alt)   527 KB  (96,9 %)  SSIM 0,968, p05 0,73
    ///     150 DPI, q92 fest          927 KB  (94,5 %)  SSIM 0,971, p05 0,73
    ///     220 DPI, Smart-Leiter      840 KB  (95,0 %)  SSIM 0,983, p05 0,87
    ///     Qualität (240 DPI)       1,31 MB  (92,2 %)  SSIM 0,986, p05 0,89
    ///
    /// Der Verlust bei 150 DPI kommt aus der Auflösung, nicht aus der JPEG-
    /// Qualität: q92 statt q75 ändert fast nichts, 220 DPI holt das Niveau
    /// von „Qualität" bei 64 % von dessen Größe. Das Produktziel (80–90 %
    /// auf Fotodokumenten) bleibt mit 95 % weit erfüllt. Wer 150 DPI will,
    /// stellt es im Custom-Bereich ein.
    ///
    /// `maxPixelEdge` 3000 ≙ 13,6 Zoll bei 220 DPI (wie 4000 bei 300 für
    /// Qualität); das Kantenlimit greift nur ohne bekannte Platzierung.
    ///
    /// Die SSIM-Schwelle bleibt als Qualitätszusage bestehen: Es wird nur
    /// kodiert, was die Prüfung besteht. Der Smart-Anker (q75 auf dem
    /// Zielraster) folgt dem Ziel automatisch.
    /// Klein – für Mailanhänge und Uploads.
    ///
    /// 110 DPI. Gemessen an einem Dokument mit fünfzehn 12-Megapixel-Fotos
    /// (16,5 MB) liefert diese Stufe rund 0,8 MB, also 95 % Ersparnis. Auf
    /// dem Bildschirm bleibt Text bequem lesbar; zum Drucken taugt es nicht,
    /// und dafuer ist die Stufe auch nicht gedacht.
    ///
    /// Die Qualitaetsschwelle gilt hier genauso: Es wird nur kodiert, was die
    /// Pruefung besteht.
    ///
    /// Qualitätsbereich 0,50–0,90 (2026-09-30): Klein muss mindestens den
    /// Suchraum von Smart abdecken. Mit [0,75 … 0,85] durfte Klein weder so
    /// tief wie Smart (0,60) noch auf die sichere Stufe 0,90 – Kartenkacheln
    /// verletzten bei ≤ 0,85 die Katastrophen-Grenze und blieben dann im
    /// ORIGINAL (USGS Boston: Klein 8,4 MB, Smart 3,6 MB). Die Gates
    /// entscheiden, der Optimierer nimmt den kleinsten zulässigen Kandidaten.
    static let small = ImageCompressionOptions(
        targetDPI: 110, tolerance: 1.15, maxPixelEdge: 1600, hardPixelCap: false,
        jpegQuality: 0.85, qualityLadder: [0.50, 0.75, 0.90], ssimThreshold: 0.86,
        forceGrayscale: false, aggressiveGraphics: false)

    /// Qualitaet – fuer Druck und Weiterverarbeitung.
    ///
    /// 300 DPI, die Druckaufloesung. Hier wird nur eingegriffen, wo ein Bild
    /// WEIT ueber dem Noetigen liegt – ein Handyfoto mit 985 DPI auf einer
    /// Seite ist auch fuer den Druck dreimal zu fein. Am selben Dokument
    /// bleiben rund 4 MB, also 76 % Ersparnis, ohne die Druckfaehigkeit
    /// anzutasten.
    static let quality = ImageCompressionOptions(
        targetDPI: 300, tolerance: 1.15, maxPixelEdge: 4000, hardPixelCap: false,
        jpegQuality: 0.92, qualityLadder: [0.85, 0.90, 0.92], ssimThreshold: 0.95,
        forceGrayscale: false, aggressiveGraphics: false)

    /// Die Schwelle von 0,90 ist gemessen, nicht gegriffen.
    ///
    /// Sie war 0,98 – ein Wert, den JPEG bei starkem Herunterrechnen nicht
    /// erreichen kann. Je stärker verkleinert wird, desto dichter liegen die
    /// Bilddetails je Bildpunkt und desto mehr kostet die Quantisierung.
    /// Die Sperre traf damit ausgerechnet die Fälle mit der grössten
    /// Ersparnis: An einem Dokument mit fünfzehn 12-Megapixel-Fotos blieben
    /// vier Bilder mit zusammen 4,7 MB unangetastet liegen, weil sie 0,98
    /// um ein halbes bis zwei Prozent verfehlten.
    ///
    /// Gemessen liegen echte Fotos nach starkem Herunterrechnen zwischen
    /// 0,92 und 0,99; der schlechteste beobachtete Fall lag bei 0,9229.
    /// Bei 0,90 wird alles davon kodiert, und die Schwelle bleibt trotzdem
    /// eine echte Sperre: Was darunter fällt, ist nicht bloss schlechter,
    /// sondern kaputt.
    ///
    /// Sie bleibt damit das, was sie sein soll – eine Zusage, kein Wunsch.
    static let smart = ImageCompressionOptions(
        targetDPI: 220, tolerance: 1.15, maxPixelEdge: 3000, hardPixelCap: false,
        // Search lower qualities too; measured content gates decide acceptance.
        jpegQuality: 0.90, qualityLadder: [0.60, 0.75, 0.90], ssimThreshold: 0.90,
        forceGrayscale: false, aggressiveGraphics: false)

    /// Referenz-DPI des Schnellschätzers (Zielgrößen-Modell): der Smart-
    /// Anker des Produkts. Vom Preset abgeleitet, damit es nur EINE Stelle
    /// gibt – der Schätzer selbst darf keine Bildentscheidung treffen und
    /// kennt deshalb keine Zielauflösung (`EstimatorArchitectureTests`).
    static let smartReferenceDPI: Double = smart.targetDPI

    /// Initialisierer aus Rohwerten (Zielqualität, Leiter, SSIM-Schwelle).
    ///
    /// Er leitet daraus die Qualitätspolitik ab, statt sie sich sagen zu
    /// lassen. Die Gegenrichtung – ein `legacyConfig`, das die Optionen
    /// wieder in die alte Struktur zurückfaltete – ist entfallen: Nach der
    /// Entfernung des zweiten Pfads gab es niemanden mehr, der sie las.
    init(targetDPI: Double, tolerance: Double, maxPixelEdge: Int,
         hardPixelCap: Bool, jpegQuality: Double, qualityLadder: [Double],
         ssimThreshold: Double, forceGrayscale: Bool, aggressiveGraphics: Bool) {
        self.targetDPI = targetDPI
        self.tolerance = tolerance
        self.maxPixelEdge = maxPixelEdge
        self.hardPixelCap = hardPixelCap
        self.forceGrayscale = forceGrayscale
        self.aggressiveGraphics = aggressiveGraphics

        // Ableitung aus den Rohwerten: Eine Schwelle über 1.0 ist per
        // Konstruktion unerreichbar und war der frühere Weg, eine feste
        // Qualität zu erzwingen. Sie wird als das gelesen, was gemeint war.
        if ssimThreshold > 1.0 || qualityLadder.count <= 1 {
            self.qualityPolicy = .fixed(quality: qualityLadder.first ?? jpegQuality)
        } else {
            self.qualityPolicy = .adaptive(ladder: qualityLadder,
                                           minimumSSIM: ssimThreshold)
        }
    }

    /// Direkter Initialisierer mit expliziter Politik – der Weg, den neue
    /// Aufrufer nehmen sollten.
    init(targetDPI: Double, tolerance: Double, maxPixelEdge: Int,
         hardPixelCap: Bool, forceGrayscale: Bool, aggressiveGraphics: Bool,
         qualityPolicy: JPEGQualityPolicy) {
        self.targetDPI = targetDPI
        self.tolerance = tolerance
        self.maxPixelEdge = maxPixelEdge
        self.hardPixelCap = hardPixelCap
        self.forceGrayscale = forceGrayscale
        self.aggressiveGraphics = aggressiveGraphics
        self.qualityPolicy = qualityPolicy
    }

    init(_ config: ImageEngineConfig) {
        self.init(targetDPI: config.targetDPI,
                  tolerance: config.tolerance,
                  maxPixelEdge: config.maxPixelEdge,
                  hardPixelCap: config.hardPixelCap,
                  jpegQuality: config.jpegQuality,
                  qualityLadder: config.qualityLadder,
                  ssimThreshold: config.ssimThreshold,
                  forceGrayscale: config.forceGrayscale,
                  aggressiveGraphics: config.aggressiveGraphics)
    }
}

// MARK: - Gesamtoptionen

struct CompressionOptions: Equatable, Codable, Sendable {
    var image: ImageCompressionOptions
    var metadataPolicy: MetadataPolicy
    var linearizationPolicy: LinearizationPolicy
    /// Phase 3b – Content-Hash-Dedup nach den Bildtransformationen.
    var dedupPolicy: DedupPolicy
    /// Phase 5a – Font-Dedup + Unused-Font-GC nach dem Document-Dedup.
    var fontPolicy: FontPolicy
    /// Phase 5b/V2-8 – Font-Subsetting-Politik; steuert seit V2-11 den
    /// selektiven Pfad (§14). Default `.on`.
    var fontSubsettingPolicy: FontSubsettingPolicy
    /// V2-8 (§14.6) – Resource-GC-Politik. Default `.auto` (zertifiziert,
    /// V2-11); `.off` ist der Not-Aus.
    var resourceGCPolicy: ResourceGCPolicy = .auto
    /// Phase 3c – Flate-Aufwand des Struktur-Passes.
    var flatePolicy: FlatePolicy
    /// Phase 3c – Kompatibilitätsverhalten der Ausgabe.
    var compatibilityPolicy: CompatibilityPolicy
    /// Masterplan §8/§25 – V2-Klassifikator. Default `.v2` (Aktivierung nach
    /// der §8.6-Reparatur): Die V2-11-Zertifizierung hatte den Schalter auf
    /// `legacy` zurückgestellt, weil die Bild-Klassifikation ohne
    /// Seitenkontext gescanntes Karten-/Scan-Material in die verlustfreie
    /// Graphics-Route drückte (USGS-Karten: −69 pp gewichtete Ersparnis,
    /// Vorablauf 20260902-215250). Reparatur (§8.6): Seiten-/Bild-Verknüpfung
    /// (§8.4) in die Klassifikation, Scan-Regel mit Priorität und
    /// Graustufen-Arm an der Quelle, verrauschte Karten-Kacheln auf
    /// mapTechnical (edge-sensitive Politik, §10.2) – Acceptance und
    /// Smoke-Vergleich im Zertifizierungsrapport der Nachbereitung.
    /// `legacy` bleibt als Engineering-Schalter erhalten.
    var classifierPolicy: ClassifierPolicy = .v2
    /// V2-5 (§11.5) – QA-Rollback-Kette. Default `off` (fail-closed wie
    /// bisher); `.auto` greift im traceVersion-2-Plan. Bewusst NICHT Teil
    /// des V2-11-Flips – die Kette bleibt als nächste Aktivierungsstufe
    /// (dokumentiert im Zertifizierungsrapport).
    var qaRollbackPolicy: QARollbackPolicy = .off
    /// Masterplan §25 – interne Feature-Flags. Default: Core-Flags ON
    /// (V2-11-Zertifizierung), `mrc` AUS (V2-Advanced).
    var featureFlags = CompressionFeatureFlags()
    /// V2-6 (§12.1) – dokumentweites Optimierungsziel. `nil` = Preset-Politik
    /// (Verhalten wie bisher); `.targetBytes(n)` schaltet den globalen
    /// Budget-Optimizer frei (implizit Candidate-Engine, §25) und koppelt an
    /// die Preset-Floors des gewählten Modus – sie werden nie unterschritten
    /// (§12.8). Ein gesetztes Ziel schlägt das Mode-Mapping.
    var goal: CompressionGoal? = nil
    /// Phase V2-9 (§15.2) – Pixel-Budget der Candidate-Parallelität in Bytes.
    /// 0 = Tier-Default 256 MB; überschrieben durch die Umgebungsvariable
    /// PDFTOOLS_PIXEL_BUDGET (Benchmarks ohne Rebuild).
    var pixelBudgetBytes: Int64 = 0
    /// V2-Advanced-Nachbereitung: harte Seiten-/Pixelgrenze plus weiches
    /// Zeitbudget fuer die MRC-Provision. Die eigentlichen Kandidaten bleiben
    /// hinter Segmentierungs-, Seiten-QA-, Never-Grow- und Planner-Gates.
    var mrcProvisionBudget: MRCProvisionBudget = .oneClick

    /// Phase V2-9 – Läuft die Candidate-Engine (Flags oder Ziel, §25)?
    /// Eine Stelle für Pfade, die nur im V2-Zweig greifen dürfen (§4: kein
    /// zweiter Engine-Pfad).
    var candidateEngineActive: Bool {
        featureFlags.candidateEngine || goal?.isTargetSize == true
    }

    init(image: ImageCompressionOptions = .smart,
         metadataPolicy: MetadataPolicy = .preserve,
         linearizationPolicy: LinearizationPolicy = .none,
         dedupPolicy: DedupPolicy = .auto,
         fontPolicy: FontPolicy = .auto,
         fontSubsettingPolicy: FontSubsettingPolicy = .on,
         flatePolicy: FlatePolicy = .standard,
         compatibilityPolicy: CompatibilityPolicy = .modern) {
        self.image = image
        self.metadataPolicy = metadataPolicy
        self.linearizationPolicy = linearizationPolicy
        self.dedupPolicy = dedupPolicy
        self.fontPolicy = fontPolicy
        self.fontSubsettingPolicy = fontSubsettingPolicy
        self.flatePolicy = flatePolicy
        self.compatibilityPolicy = compatibilityPolicy
    }

    static let smart = CompressionOptions()

    /// Phase 3c – „Maximale Kompression" als interne Stufe. Die Oberfläche
    /// bietet sie bewusst NICHT an (Roadmap Phase 9): „Kleinste Datei" meint
    /// die kleinste Datei und fährt deshalb Small-Bildwerte auf zlib -9 –
    /// das interne Maximum folgt `.quality` und gewinnt seinen Zuschlag aus
    /// Font-Subsetting und – seit dem Phase-3-Followup – dem JETZT pro Stream
    /// parallelisierten Zopfli-Repack großer Flate-Streams, der nur hier über
    /// `flatePolicy .maximum` freigeschaltet ist. „Kleinste Datei" bleibt
    /// trotzdem zlib -9: Zopfli ist weiterhin ~100–1000× langsamer und eine
    /// One-Click-Stufe darf das nicht koppeln. Getestet in MaxPresetTests und
    /// ZopfliRepackTests.
    static let maximum = CompressionPresetFactory.maximum()

    /// Baut die Optionen aus den Werten, die die UI anbietet. Genau EINE
    /// Stelle übersetzt Benutzereingaben in Engine-Parameter (Schritt 6).
    /// V2-6: `goal` trägt das Zieldateigrößen-Ziel (§12.1) in dieselben
    /// Optionen – goal schlägt das Mode-Mapping, `nil` verhält sich wie
    /// bisher.
    static func make(mode: CompressionMode,
                     customConfig: ImageEngineConfig?,
                     stripMetadata: Bool,
                     linearize: Bool,
                     goal: CompressionGoal? = nil) -> CompressionOptions {
        let imageOptions: ImageCompressionOptions
        switch mode {
        case .small:
            imageOptions = .small
        case .smart:
            imageOptions = .smart
        case .quality:
            imageOptions = .quality
        case .custom:
            // Ohne Custom-Konfiguration wäre unklar, was der Nutzer wollte –
            // dann gelten bewusst die Smart-Werte statt stiller Nullwerte.
            imageOptions = customConfig.map(ImageCompressionOptions.init) ?? .smart
        }
        var options = CompressionOptions(
            image: imageOptions,
            metadataPolicy: stripMetadata ? .strip : .preserve,
            linearizationPolicy: linearize ? .fastWebView : .none)
        options.goal = goal
        // Die drei gefuehrten Standardmodi nutzen die zertifizierte MRC-
        // Kette jetzt unter einem endlichen Provision-Budget. Custom bleibt
        // unveraendert: feste Nutzerparameter werden nicht umgedeutet.
        if mode != .custom {
            options.featureFlags.mrc = true
        }
        return options
    }
}

// MARK: - Preset-Factory

/// Die EINE Stelle, an der Kompressionseinstellungen entstehen.
///
/// Zuvor bauten UI und CorpusRunner ihre Konfigurationen getrennt: Das
/// ViewModel setzte `ssimThreshold: 1.1` mit einstufiger Leiter, der Runner
/// eigene Werte wie `0.98` mit ebenfalls einstufiger Leiter. Beide Wege
/// führten – über verschiedene Umwege – zu einer festen Qualität, aber ein
/// Korpuslauf konnte damit grün sein, während der echte UI-Pfad anders
/// konfiguriert war.
///
/// Diese Factory gehört bewusst in die Domäne, nicht ins ViewModel: Der
/// CorpusRunner darf keine UI-Abhängigkeit haben (Plan 2.4).
enum CompressionPresetFactory {

    /// Smart – adaptive Qualitätsleiter mit Qualitätszusage.
    ///
    /// Die Werte stehen hier zentral. Sie dürfen nicht in ViewModels
    /// dupliziert werden, sonst driften Anzeige und Ausführung auseinander.
    /// Die benannten Custom-Voreinstellungen.
    ///
    /// Sie stehen hier und nicht im Korpus-Runner, weil inzwischen zwei
    /// Stellen sie messen: der Korpuslauf und das Genauigkeitslabor. Zwei
    /// Kopien derselben Werte wären genau die Falle, die schon einmal
    /// zugeschnappt ist – ein Lauf war grün, während der andere etwas
    /// anderes fuhr.
    ///
    /// Die Werte weichen leicht von den nominellen Zahlen des Plans ab
    /// (dort „300/Q95, 220/Q85, 150/Q70"). Gemessen wird bewusst das, was
    /// das Produkt tatsächlich fährt – eine Genauigkeitsaussage über
    /// Einstellungen, die niemand benutzt, wäre wertlos.
    enum CustomPreset: String, CaseIterable, Sendable {
        case high = "Custom High"
        case balanced = "Custom Balanced"
        case aggressive = "Custom Aggressive"
        case grayscale = "Custom Grayscale"

        var options: CompressionOptions {
            switch self {
            case .high:
                return custom(dpi: 300, quality: 0.92, maxPixelEdge: 3300)
            case .balanced:
                return custom(dpi: 150, quality: 0.85, maxPixelEdge: 2200)
            case .aggressive:
                return custom(dpi: 96, quality: 0.72,
                              aggressiveGraphics: true, maxPixelEdge: 1400)
            case .grayscale:
                return custom(dpi: 200, quality: 0.85, grayscale: true,
                              maxPixelEdge: 2200)
            }
        }
    }

    static func smart(stripMetadata: Bool = false,
                      linearize: Bool = false) -> CompressionOptions {
        CompressionOptions(
            image: .smart,
            metadataPolicy: stripMetadata ? .strip : .preserve,
            linearizationPolicy: linearize ? .fastWebView : .none)
    }

    /// Maximum – „Maximale Kompression" (Roadmap Phase 3).
    ///
    /// Der EINZIGE Preset, der `flatePolicy .maximum` setzt: Der Struktur-
    /// Pass fährt Zopfli (`QPDF_ZOPFLI=silent`), Small/Smart/Quality/Custom
    /// bleiben garantiert bei zlib -9. Kein eigener UI-Modus – Phase 9 hat
    /// entschieden, dass „Kleinste Datei" die Small-Bildwerte fährt (siehe
    /// `CompressionOptions.maximum`); diese Stufe bleibt intern.
    static func maximum(stripMetadata: Bool = false,
                        linearize: Bool = false) -> CompressionOptions {
        CompressionOptions(
            image: .quality,
            metadataPolicy: stripMetadata ? .strip : .preserve,
            linearizationPolicy: linearize ? .fastWebView : .none,
            dedupPolicy: .auto,
            fontPolicy: .auto,
            fontSubsettingPolicy: .on,
            flatePolicy: .maximum,
            compatibilityPolicy: .modern)
    }

    /// Custom – der Nutzer hat gewählt, die Wahl wird ausgeführt.
    ///
    /// Kein Qualitätsgate: Eine feste Qualität erneut über eine SSIM-Schwelle
    /// zu prüfen hiesse, die Entscheidung des Nutzers zu überstimmen.
    static func custom(dpi: Double,
                       quality: Double,
                       grayscale: Bool = false,
                       aggressiveGraphics: Bool = false,
                       maxPixelEdge: Int? = nil,
                       hardPixelCap: Bool = false,
                       stripMetadata: Bool = false,
                       linearize: Bool = false) -> CompressionOptions {
        let image = ImageCompressionOptions(
            targetDPI: dpi,
            tolerance: 1.15,
            maxPixelEdge: maxPixelEdge ?? 4000,
            hardPixelCap: hardPixelCap,
            forceGrayscale: grayscale,
            aggressiveGraphics: aggressiveGraphics,
            qualityPolicy: .fixed(quality: quality))
        return CompressionOptions(
            image: image,
            metadataPolicy: stripMetadata ? .strip : .preserve,
            linearizationPolicy: linearize ? .fastWebView : .none)
    }
}
