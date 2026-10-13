import Testing
import Foundation
import PDFKit
@testable import PDFTools

/// Final Core Hardening, Phase 6 – Zählungen beweisen nichts.
///
/// „20 Lesezeichen vorher, 20 nachher" sagt nicht, dass sie noch dorthin
/// zeigen, wo sie hingehören. Genau das war der Zustand: Ziele, Beschriftungen,
/// Tiefen, Label-Bereiche, Feldtypen und Anhanggrößen wurden ERFASST, aber nie
/// verglichen. Der Vergleich sah nur, ob die Anzahl gesunken ist.
///
/// Diese Suite prüft für jede Struktur denselben Fall: Anzahl gleich, Inhalt
/// falsch.
///
/// Die Kennungen sind bewusst fein: `outlineStructure` meint Reihenfolge,
/// Verschachtelung oder Beschriftung, `outline` das Sprungziel eines
/// Eintrags. Wer nur „irgendwas am Outline stimmt nicht" meldet, zwingt den
/// Leser des Berichts, selbst nachzusehen.
@Suite struct ExactSemanticsTests {

    /// Ein Paar aus einem echten Dokument, bei dem `mutate` das „Nachher"
    /// verfälscht – die Anzahl bleibt dabei immer gleich.
    static func pair(_ mutate: (inout PDFSemanticSnapshot) -> Void) throws
        -> (PDFSemanticSnapshot, PDFSemanticSnapshot) {
        let url = try PDFFixtures.outlineLinkPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        var before = try PDFSemanticSnapshot.capture(url)

        // Vorbedingung: Das „Vorher" muss die Struktur tragen, sonst prüft
        // der Test nichts.
        if before.navigation.outline.isEmpty {
            before.navigation.outline = [
                .init(depth: 0, label: "Kapitel 1", targetPage: 0),
                .init(depth: 1, label: "Abschnitt 1.1", targetPage: 1),
            ]
        }
        if before.navigation.namedDestinations.isEmpty {
            before.navigation.namedDestinations = [
                .init(name: "einleitung", targetPage: 0),
                .init(name: "schluss", targetPage: 1),
            ]
        }
        before.document.hasPageLabels = true
        before.document.pageLabelRanges = ["0|roman|Vorwort |1", "2|decimal||1"]
        if before.form.fields.isEmpty {
            before.form.fields = [
                .init(name: "name", type: "/Tx", value: "Muster", flags: 0),
                .init(name: "zustimmung", type: "/Btn", value: "/Off", flags: 0),
            ]
        }
        if before.attachments.isEmpty {
            before.attachments = [.init(name: "anhang.txt", byteCount: 4096)]
        }

        var after = before
        mutate(&after)
        return (before, after)
    }

    static func mustReport(_ kind: PDFSemanticSnapshot.Kind,
                           _ before: PDFSemanticSnapshot,
                           _ after: PDFSemanticSnapshot,
                           _ what: String) {
        let diffs = PDFSemanticSnapshot.differences(before, after)
        let hit = diffs.filter { $0.kind == kind }
        #expect(!hit.isEmpty, """
            \(what) wird nicht bemerkt – die Anzahl stimmt, der Inhalt nicht. \
            Gemeldet wurde: \
            \(diffs.isEmpty ? "gar nichts" : diffs.map(\.message).joined(separator: "; "))
            """)
        for d in hit {
            #expect(d.severity <= .high, "\(what) ist nur \(d.severity.rawValue)")
        }
    }

    // MARK: - 6.1 Outline

    @Test(.hangGuard) func outlineTargetChangeIsReported() throws {
        let (b, a) = try Self.pair { $0.navigation.outline[0].targetPage += 1 }
        Self.mustReport(.outline, b, a, "Ein Lesezeichen zeigt auf eine andere Seite")
    }

    @Test(.hangGuard) func outlineLabelChangeIsReported() throws {
        let (b, a) = try Self.pair { $0.navigation.outline[0].label = "Etwas anderes" }
        Self.mustReport(.outlineStructure, b, a, "Ein Lesezeichen heißt anders")
    }

    @Test(.hangGuard) func outlineStructureChangeIsReported() throws {
        let (b, a) = try Self.pair {
            // Gleiche Einträge, andere Verschachtelung. Die Tiefe wird
            // umgeschaltet statt auf 0 gesetzt – die Fixture hat zwei
            // Einträge auf derselben Ebene, „auf 0 setzen" wäre dort
            // wirkungslos und der Test prüfte nichts.
            guard $0.navigation.outline.count > 1 else { return }
            $0.navigation.outline[1].depth =
                $0.navigation.outline[1].depth == 0 ? 1 : 0
        }
        #expect(b.navigation.outline.count > 1,
                "Fixture hat zu wenige Outline-Einträge für diesen Test")
        Self.mustReport(.outlineStructure, b, a,
                        "Der Lesezeichenbaum ist anders verschachtelt")
    }

    @Test(.hangGuard) func outlineOrderChangeIsReported() throws {
        let (b, a) = try Self.pair {
            if $0.navigation.outline.count > 1 { $0.navigation.outline.reverse() }
        }
        Self.mustReport(.outlineStructure, b, a,
                        "Die Lesezeichen stehen in anderer Reihenfolge")
    }

    // MARK: - 6.2 Named Destinations

    @Test(.hangGuard) func namedDestinationRetargetIsReported() throws {
        let (b, a) = try Self.pair { $0.navigation.namedDestinations[0].targetPage += 1 }
        Self.mustReport(.namedDestinationTarget, b, a,
                        "Ein benanntes Ziel zeigt auf eine andere Seite")
    }

    @Test(.hangGuard) func namedDestinationRenameIsReported() throws {
        let (b, a) = try Self.pair { $0.navigation.namedDestinations[0].name = "anders" }
        Self.mustReport(.namedDestinations, b, a, "Ein benanntes Ziel heißt anders")
    }

    // MARK: - 6.4 Page Labels

    @Test(.hangGuard) func pageLabelRangeChangeIsReported() throws {
        let (b, a) = try Self.pair {
            $0.document.pageLabelRanges = ["0|decimal||1"]
        }
        Self.mustReport(.pageLabels, b, a,
                        "Die Seitennummerierung ist eine andere (römisch → arabisch)")
    }

    @Test(.hangGuard) func pageLabelPrefixChangeIsReported() throws {
        let (b, a) = try Self.pair {
            $0.document.pageLabelRanges[0] = "0|roman|Anhang |1"
        }
        Self.mustReport(.pageLabels, b, a, "Das Präfix der Seitenbezeichnung ist anders")
    }

    // MARK: - 6.5 Forms

    @Test(.hangGuard) func fieldTypeChangeIsReported() throws {
        let (b, a) = try Self.pair { $0.form.fields[0].type = "/Btn" }
        Self.mustReport(.fieldType, b, a,
                        "Aus einem Textfeld ist ein Knopf geworden")
    }

    @Test(.hangGuard) func fieldFlagsChangeIsReported() throws {
        let (b, a) = try Self.pair {
            $0.form.fields[0].flags = 1  // ReadOnly
        }
        Self.mustReport(.fieldFlags, b, a,
                        "Ein Feld ist plötzlich schreibgeschützt")
    }

    // MARK: - 6.3 Interne Links

    /// Ein Link, der von derselben Stelle woandershin führt, fällt einer
    /// reinen Zählung nicht auf: Die Zahl der kaputten Links bleibt gleich.
    @Test(.hangGuard) func linkRetargetIsReported() throws {
        let url = try PDFFixtures.outlineLinkPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        var before = try PDFSemanticSnapshot.capture(url)
        if before.navigation.links.isEmpty {
            before.navigation.links = [
                .init(sourcePage: 0, destinationType: "explicit", targetPage: 1,
                      namedDestination: "", bounds: "72.00,700.00,200.00,720.00"),
            ]
            before.navigation.internalLinkTargets = [1]
        }
        var after = before
        after.navigation.links[0].targetPage = 0
        after.navigation.internalLinkTargets = [0]

        Self.mustReport(.internalLinks, before, after,
                        "Ein Link führt von derselben Stelle woandershin")
    }

    /// Auch die Zielart zählt: Aus einem benannten Ziel ein festes zu machen
    /// bricht Verweise aus anderen Dokumenten, ohne dass die Seite sich ändert.
    @Test(.hangGuard) func linkDestinationTypeChangeIsReported() throws {
        let url = try PDFFixtures.outlineLinkPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        var before = try PDFSemanticSnapshot.capture(url)
        before.navigation.links = [
            .init(sourcePage: 0, destinationType: "named", targetPage: 1,
                  namedDestination: "kapitel2", bounds: "72.00,700.00,200.00,720.00"),
        ]
        var after = before
        after.navigation.links[0].destinationType = "explicit"
        after.navigation.links[0].namedDestination = ""

        Self.mustReport(.internalLinks, before, after,
                        "Aus einem benannten Ziel wurde ein festes")
    }

    // MARK: - 6.7 Operationsbewusster Vergleich

    /// Nach einer Umkehrung zeigt ein Lesezeichen richtigerweise auf eine
    /// ANDERE Seitennummer. Ohne Seitenzuordnung wäre das ein Fehlalarm –
    /// mit ihr wird geprüft, ob es auf die richtige zeigt.
    @Test(.hangGuard) func remappedTargetsAreNotFalseAlarms() throws {
        let (before, _) = try Self.pair { _ in }
        var reordered = before
        // Seite 0 ↔ Seite 1 getauscht: Das Ziel wandert mit.
        for i in reordered.navigation.outline.indices {
            reordered.navigation.outline[i].targetPage =
                before.navigation.outline[i].targetPage == 0 ? 1 : 0
        }
        for i in reordered.navigation.namedDestinations.indices {
            reordered.navigation.namedDestinations[i].targetPage =
                before.navigation.namedDestinations[i].targetPage == 0 ? 1 : 0
        }

        let mapping = [0: 1, 1: 0]
        let withMapping = PDFSemanticSnapshot.differences(
            before, reordered, pageMapping: mapping)
        let navIssues = withMapping.filter {
            [.outline, .namedDestinationTarget].contains($0.kind)
        }
        #expect(navIssues.isEmpty, """
            Korrekt umgehängte Ziele werden als Fehler gemeldet:             \(navIssues.map(\.message).joined(separator: "; "))
            """)

        // Gegenprobe: OHNE Zuordnung muss derselbe Vergleich anschlagen –
        // sonst prüft die Zuordnung nichts, sondern verdeckt nur.
        let without = PDFSemanticSnapshot.differences(before, reordered)
            .filter { [.outline, .namedDestinationTarget].contains($0.kind) }
        #expect(!without.isEmpty, """
            Ohne Seitenzuordnung fällt die Zielverschiebung gar nicht auf –             dann sagt der Vergleich mit Zuordnung auch nichts aus.
            """)
    }

    /// Und ein FALSCH umgehängtes Ziel wird auch mit Zuordnung erkannt.
    @Test(.hangGuard) func wrongRemappingIsStillCaught() throws {
        let (before, _) = try Self.pair { _ in }
        let reordered = before
        // Die Zuordnung sagt 0→1, das Lesezeichen bleibt aber auf 0 stehen.
        #expect(reordered.navigation.outline.first?.targetPage == 0)

        let mapping = [0: 1, 1: 0]
        let diffs = PDFSemanticSnapshot.differences(
            before, reordered, pageMapping: mapping)
        #expect(diffs.contains { $0.kind == .outline }, """
            Ein Lesezeichen, das nach der Umordnung auf der alten Seitennummer             stehen bleibt, wird nicht erkannt.
            """)
    }

    // MARK: - 6.6 Attachments

    @Test(.hangGuard) func attachmentSizeChangeIsReported() throws {
        let (b, a) = try Self.pair { $0.attachments[0].byteCount = 12 }
        Self.mustReport(.attachmentContent, b, a,
                        "Der Anhang hat denselben Namen, aber eine andere Größe")
    }
}

/// Gate 6 an echten Dateien – nicht an von Hand verbogenen Schnappschüssen.
///
/// Die Suite oben prüft die Vergleichslogik. Diese hier prüft, ob sie an
/// gelesenen Dokumenten dasselbe leistet: Erkennt sie ein falsches Ziel, und
/// meldet sie umgekehrt bei einer korrekten Bearbeitung nichts?
@Suite(.serialized) struct GoldenNavigationTests {

    /// Die Fixture trägt überhaupt, was geprüft werden soll. Ohne diese
    /// Vorbedingung sagen die folgenden Tests nichts.
    @Test(.hangGuard) func goldenFixtureCarriesNavigation() throws {
        let url = try PDFFixtures.navigationGoldenPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let snap = try PDFSemanticSnapshot.capture(url)

        #expect(snap.pageCount == 3)
        #expect(snap.navigation.outline.count == 3,
                "Outline: \(snap.navigation.outline)")
        #expect(snap.navigation.namedDestinations.count == 3,
                "Ziele: \(snap.navigation.namedDestinations)")
        // Und sie zeigen dorthin, wo sie hingehören.
        #expect(snap.navigation.outline.map(\.targetPage) == [0, 1, 2],
                "Ziele stimmen nicht: \(snap.navigation.outline.map(\.targetPage))")
    }

    /// Der Kern von Gate 6: Zählungen identisch, Ziele falsch.
    @Test(.hangGuard) func misdirectedTargetsAreDetected() throws {
        let good = try PDFFixtures.navigationGoldenPDF()
        let bad = try PDFFixtures.navigationGoldenPDF(misdirected: true,
                                                      name: "nav-bad")
        defer {
            try? FileManager.default.removeItem(at: good)
            try? FileManager.default.removeItem(at: bad)
        }
        let before = try PDFSemanticSnapshot.capture(good)
        let after = try PDFSemanticSnapshot.capture(bad)

        // Vorbedingung: Alle Zählungen sind gleich – sonst würde schon der
        // alte, zählende Vergleich anschlagen und der Test bewiese nichts.
        #expect(before.navigation.outline.count == after.navigation.outline.count)
        #expect(before.navigation.namedDestinations.count
                == after.navigation.namedDestinations.count)
        #expect(before.pageCount == after.pageCount)

        let diffs = PDFSemanticSnapshot.differences(before, after)
        let outlineTargets = diffs.filter { $0.kind == .outline }
        let destTargets = diffs.filter { $0.kind == .namedDestinationTarget }

        #expect(!outlineTargets.isEmpty, """
            Verdrehte Lesezeichen-Ziele werden nicht erkannt – bei gleicher \
            Anzahl. Gemeldet: \
            \(diffs.isEmpty ? "nichts" : diffs.map(\.message).joined(separator: "; "))
            """)
        #expect(!destTargets.isEmpty, "Verdrehte benannte Ziele werden nicht erkannt")
        for d in outlineTargets + destTargets {
            #expect(d.severity <= .high, "\(d.field) ist nur \(d.severity.rawValue)")
        }
    }

    /// Gegenprobe: Eine echte Kompression derselben Datei darf NICHTS melden.
    /// Ohne diesen Test wäre der obige auch mit einem Vergleich zufrieden,
    /// der immer meckert.
    @Test(.hangGuard) func compressionOfGoldenFixtureIsClean() throws {
        let url = try PDFFixtures.navigationGoldenPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try PDFSemanticSnapshot.capture(url)

        let result = try Compressor().compress(inputURL: url, mode: .smart)
        defer { try? FileManager.default.removeItem(at: result.outputURL) }
        let after = try PDFSemanticSnapshot.capture(result.outputURL)

        let blocking = PDFSemanticSnapshot.differences(before, after)
            .filter { $0.severity <= .high }
        #expect(blocking.isEmpty, """
            Kompression eines einwandfreien Navigationsdokuments meldet: \
            \(blocking.map(\.message).joined(separator: " | "))
            """)
    }

    /// Und dasselbe für eine Umordnung – dort müssen die Ziele MITWANDERN,
    /// und mit Seitenzuordnung darf der Vergleich schweigen.
    @Test(.hangGuard) func reorderRemapsTargetsCorrectly() async throws {
        let url = try PDFFixtures.navigationGoldenPDF()
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try PDFSemanticSnapshot.capture(url)
        let source = SourceDocument(url: url, pageCount: 3)

        // Umkehrung: 0→2, 1→1, 2→0
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("nav-rev-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }
        try await PageAssemblyService.assemble(
            plan: PageAssemblyPlan(pages: [2, 1, 0].map {
                PageItem(source: source, pageIndex: $0).assemblyItem
            }),
            to: out, progress: { _ in })

        let after = try PDFSemanticSnapshot.capture(out)
        let mapping = [0: 2, 1: 1, 2: 0]
        let targetIssues = PDFSemanticSnapshot.differences(
            before, after, pageMapping: mapping)
            .filter { [.outline, .namedDestinationTarget].contains($0.kind) }

        #expect(targetIssues.isEmpty, """
            Nach der Umkehrung zeigen Ziele nicht dorthin, wo ihre Seite \
            gelandet ist: \(targetIssues.map(\.message).joined(separator: " | "))
            """)
    }
}
