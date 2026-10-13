import Foundation
import Testing
@testable import PDFTools

/// Update-Hinweis (2026-10-13). Fehlermöglichkeiten:
/// (1) Versionsvergleich als Text: „1.0.10" gälte als älter als „1.0.9".
/// (2) Dieselbe oder eine ältere Version wird als Update gemeldet.
/// (3) Eine kaputte oder fremde Antwort führt zu einem Hinweis mit beliebigem Link.
/// (4) Trotz ausgeschaltetem Schalter wird abgefragt.
/// (5) Bei jedem Start wird abgefragt statt höchstens einmal am Tag.
/// (6) Ein geschlossener Hinweis kommt beim nächsten Start wieder.
@MainActor @Suite struct UpdateCheckerTests {
    nonisolated private static func defaults() -> UserDefaults {
        let name = "update-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    nonisolated private static func payload(_ tag: String,
                                url: String = "https://github.com/Klabautter/pdfdownsize/releases/tag/x") -> Data {
        Data(#"{"tag_name":"\#(tag)","html_url":"\#(url)"}"#.utf8)
    }

    @Test func versionsvergleichIstZahlenweise() {
        #expect(UpdateChecker.isNewer("1.0.10", than: "1.0.9"))
        #expect(UpdateChecker.isNewer("1.1", than: "1.0.5"))
        #expect(UpdateChecker.isNewer("2.0", than: "1.9.9"))
        #expect(!UpdateChecker.isNewer("1.0.1", than: "1.0.1"))
        #expect(!UpdateChecker.isNewer("1.0", than: "1.0.0"))
        #expect(!UpdateChecker.isNewer("1.0.0", than: "1.0.1"))
    }

    @Test func antwortWirdStrengGelesen() {
        #expect(UpdateChecker.parse(Self.payload("v1.0.2"))?.version == "1.0.2")
        #expect(UpdateChecker.parse(Self.payload("1.2"))?.version == "1.2")
        #expect(UpdateChecker.parse(Self.payload("neu")) == nil)
        #expect(UpdateChecker.parse(Self.payload("v1.0.2", url: "https://example.com/x")) == nil)
        #expect(UpdateChecker.parse(Self.payload("v1.0.2", url: "http://github.com/x")) == nil)
        #expect(UpdateChecker.parse(Data("kein json".utf8)) == nil)
    }

    @Test func neuereVersionWirdGemeldetGleicheNicht() async {
        let newer = UpdateChecker(defaults: Self.defaults(), currentVersion: "1.0.1",
                                  fetch: { Self.payload("v1.0.2") })
        await newer.checkOnLaunch()
        #expect(newer.available?.version == "1.0.2")

        let same = UpdateChecker(defaults: Self.defaults(), currentVersion: "1.0.2",
                                 fetch: { Self.payload("v1.0.2") })
        await same.checkOnLaunch()
        #expect(same.available == nil)
    }

    @Test func ausgeschaltetFragtNicht() async {
        let d = Self.defaults()
        d.set(false, forKey: UpdateChecker.automaticKey)
        let counter = Counter()
        let checker = UpdateChecker(defaults: d, currentVersion: "1.0",
                                    fetch: { await counter.hit(); return Self.payload("v9.0") })
        await checker.checkOnLaunch()
        #expect(await counter.value == 0)
        #expect(checker.available == nil)
    }

    @Test func hoechstensEinmalAmTagUndSchliessenBleibt() async {
        let d = Self.defaults()
        let counter = Counter()
        let fetch: @Sendable () async -> Data? = { await counter.hit(); return Self.payload("v1.0.2") }
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        let first = UpdateChecker(defaults: d, currentVersion: "1.0.1", fetch: fetch)
        await first.checkOnLaunch(now: start)
        #expect(first.available != nil)
        first.dismiss()
        #expect(first.available == nil)

        let sameDay = UpdateChecker(defaults: d, currentVersion: "1.0.1", fetch: fetch)
        await sameDay.checkOnLaunch(now: start.addingTimeInterval(3600))
        #expect(await counter.value == 1, "zweite Abfrage am selben Tag")

        let nextDay = UpdateChecker(defaults: d, currentVersion: "1.0.1", fetch: fetch)
        await nextDay.checkOnLaunch(now: start.addingTimeInterval(25 * 3600))
        #expect(await counter.value == 2)
        #expect(nextDay.available == nil, "geschlossener Hinweis kam wieder")

        // Von Hand gesucht zeigt die Version trotzdem.
        await nextDay.checkManually()
        #expect(nextDay.manualResult == .available(.init(
            version: "1.0.2",
            page: URL(string: "https://github.com/Klabautter/pdfdownsize/releases/tag/x")!)))
    }

    @Test func fehlendeAntwortIstKeinUpdate() async {
        let checker = UpdateChecker(defaults: Self.defaults(), currentVersion: "1.0",
                                    fetch: { nil })
        await checker.checkManually()
        #expect(checker.manualResult == .failed)
        #expect(checker.available == nil)
    }
}

private actor Counter {
    private(set) var value = 0
    func hit() { value += 1 }
}
