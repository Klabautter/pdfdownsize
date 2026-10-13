import Foundation

/// Masterplan Finding 7 – EINDEUTIGER Zustand der Compression-Engine.
///
/// Ausgangslage war ein Widerspruch: Der libqpdf-Pfad war bereits
/// Produktionsdefault, während Kommentare und Statusdokumente ihn als
/// Opt-in-Prototype beschrieben. Ein Leser konnte nicht entscheiden, was
/// tatsächlich ausgeliefert wird.
///
/// Auflösung (bewusst KEINE Rückkehr zum unvollständigen Legacy-Release-Pfad –
/// dort ist die Bildoptimierung `#if DEBUG`-only und damit im Release
/// wirkungslos):
///
///  1. Der libqpdf-Pfad bleibt der einzige Produktionspfad.
///  2. Sein Zertifizierungsstand steht hier – an genau einer Stelle.
///  3. Solange er nicht zertifiziert ist, blockiert `Scripts/release-check.sh`
///     jeden Release-Build. Es kann keine unzertifizierte Engine ausgeliefert
///     werden.
///  4. Legacy bleibt ausschließlich Differential-/Debug-Backend.
///  5. Der Name verliert die Prototype-Bezeichnung erst mit der Zertifizierung
///     (Masterplan Schritt 11).
///
/// WICHTIG: `Scripts/release-check.sh` liest die Zeile mit
/// `compressionCoreCertified` aus dieser Datei. Format nicht ändern, ohne das
/// Skript anzupassen.
enum CompressionEngineState {

    /// Core Final Gate bestanden (Masterplan Kapitel 12).
    ///
    /// Belege, jeweils nach der Legacy-Entfernung neu erhoben:
    ///  - Standardsuite 532 Tests, 0 Fehlschläge
    ///  - Speicherlauf 12 Tests, 0 Fehlschläge (`Scripts/memory-check.sh`,
    ///    Phase 8: + large-document compression, + parallele
    ///    Mehr-Dokument-Läufe)
    ///  - Full Corpus 3135 Operationen, 0 Fehlschläge, alle vier
    ///    Fixture-Klassen 100 % (`2026-08-28_1520…_full_merged`)
    ///  - Stress 18 Operationen, 0 Fehlschläge
    ///  - Release Build erfolgreich
    ///  - Accuracy Lab 280 Messungen (`COMPRESSION_ACCURACY_LAB.md`)
    ///
    /// Bekannter Schwachpunkt, dokumentiert statt verschwiegen: Die
    /// Byte-Vorhersage des Estimators ist bei 168 von 280 Messungen zu
    /// optimistisch, bei 50 davon um mehr als 20 %. Die Entscheidung selbst –
    /// der `CompressionPlan`, den Estimator und Executor teilen – ist davon
    /// nicht betroffen (Finding 11).
    static let compressionCoreCertified = true

    /// Begründung, die release-check.sh und Statusberichte ausgeben.
    ///
    /// Erledigt und deshalb hier gestrichen – jeweils mit dem Beleg, der sie
    /// schliesst:
    ///  - Schritt 1–4 (Object-Identity / Mask / Filter): `ImageIdentitySafetyTests`
    ///    und `CompressionPlannerGateTests`, 64 Prüfungen grün.
    ///  - Schritt 5–7 (gemeinsame Decision Engine): ebenda; Estimator und
    ///    Executor lesen denselben Plan.
    ///  - Schritt 8 (PDFValidator auf allen Compression-Outputs): 1425
    ///    Kompressionsoperationen im Korpuslauf, 0 Fehlschläge.
    ///  - Schritt 9–10 (Corpus-Gates): Golden 100 %, 3135 Operationen,
    ///    0 blockierende Fehlschläge (`2026-08-28_124805_full_merged`).
    ///
    /// Was bleibt, ist der letzte Punkt des Core Final Gate.
    static let certificationBlockers: [String] = []

    /// Der Produktionspfad – seit Masterplan Schritt 11 der einzige.
    ///
    /// Die Prototype-Bezeichnung ist mit der Entfernung des Legacy-Pfads
    /// gefallen: Sie sollte nie mehr versprechen, als der Gate-Stand hergibt,
    /// und der Stand ist jetzt belegt (3135 Korpusoperationen, 0 Fehlschläge,
    /// alle vier Fixture-Klassen 100 %).
    static var production: CompressionEngine { .libqpdf }
}
