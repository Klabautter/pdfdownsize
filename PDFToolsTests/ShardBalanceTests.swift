import Testing
import Foundation
@testable import PDFTools

/// Die Chargen müssen ähnlich viel Arbeit bekommen.
///
/// Ein Korpuslauf ist so schnell wie seine langsamste Charge. Bei
/// gleichmässiger Verteilung nach ANZAHL schwankt die Last enorm, weil der
/// Aufwand je Dokument um Größenordnungen auseinanderliegt: 404 MB beim
/// IPCC-Bericht, 0,2 MB im Median. Gemessen an einem Lauf mit sechs
/// Chargen waren vier nach 40 Minuten fertig, zwei rechneten 20 Minuten
/// allein weiter.
@Suite(.serialized)
@MainActor
struct ShardBalanceTests {

    static func shardBytes(_ index: Int, of count: Int) -> Int64 {
        let base = CorpusRunnerCore.Config.resolveEnvironment()
        let config = CorpusRunnerCore.Config(
            corpusRoot: base.root, corpusRootSource: base.source,
            suite: .full, operationFilter: nil, seed: 42,
            keepOutputs: false, corpusID: "balance",
            shard: (index: index, count: count))
        return CorpusRunnerCore.fixtures(for: .full, config: config)
            .reduce(Int64(0)) { $0 + Compressor.fileSize(of: $1) }
    }

    /// Die schwerste Charge bleibt nahe an der theoretischen Untergrenze.
    ///
    /// Gleich grosse Chargen sind NICHT das Ziel und wären hier auch gar
    /// nicht erreichbar: Ein einzelnes Dokument lässt sich nicht aufteilen,
    /// der IPCC-Bericht allein bringt 403 MB mit. Kein Lauf kann schneller
    /// sein als sein grösstes Dokument – und keiner schneller als die
    /// Gesamtlast geteilt durch die Zahl der Chargen. Das Maximum aus
    /// beidem ist die Untergrenze, und daran wird gemessen.
    @Test(.hangGuard) func heaviestShardStaysNearLowerBound() throws {
        let count = 6
        let loads = (1...count).map { Self.shardBytes($0, of: count) }
        guard loads.allSatisfy({ $0 > 0 }) else {
            print("Korpus nicht verfügbar – Test übersprungen")
            return
        }
        let total = loads.reduce(0, +)
        let largestSingle = loads.max() ?? 1   // ≥ grösstes Einzeldokument
        let bound = max(total / Int64(count), Self.largestDocumentBytes())
        let heaviest = largestSingle
        let excess = Double(heaviest) / Double(max(bound, 1))
        let mb = loads.map { $0 / 1048576 }
        // Das gewählte Verfahren garantiert höchstens 4/3 der Untergrenze.
        #expect(excess <= 1.34, """
            Die schwerste Charge liegt \(String(format: "%.2f", excess))× über \
            der Untergrenze von \(bound / 1048576) MB: \(mb) MB je Charge.
            """)
    }

    static func largestDocumentBytes() -> Int64 {
        let base = CorpusRunnerCore.Config.resolveEnvironment()
        let config = CorpusRunnerCore.Config(
            corpusRoot: base.root, corpusRootSource: base.source,
            suite: .full, operationFilter: nil, seed: 42,
            keepOutputs: false, corpusID: "balance", shard: nil)
        return CorpusRunnerCore.fixtures(for: .full, config: config)
            .map { Compressor.fileSize(of: $0) }
            .max() ?? 0
    }

    /// Jedes Dokument liegt in GENAU EINER Charge – sonst fehlt etwas oder
    /// wird doppelt geprüft.
    @Test(.hangGuard) func everyDocumentAppearsExactlyOnce() throws {
        let base = CorpusRunnerCore.Config.resolveEnvironment()
        func config(_ shard: (index: Int, count: Int)?) -> CorpusRunnerCore.Config {
            CorpusRunnerCore.Config(
                corpusRoot: base.root, corpusRootSource: base.source,
                suite: .full, operationFilter: nil, seed: 42,
                keepOutputs: false, corpusID: "balance", shard: shard)
        }
        let all = CorpusRunnerCore.fixtures(for: .full, config: config(nil))
        guard !all.isEmpty else {
            print("Korpus nicht verfügbar – Test übersprungen")
            return
        }
        var seen: [String: Int] = [:]
        for i in 1...6 {
            for url in CorpusRunnerCore.fixtures(
                for: .full, config: config((index: i, count: 6))) {
                seen[url.path, default: 0] += 1
            }
        }
        #expect(seen.count == all.count, """
            \(seen.count) verteilte Dokumente gegenüber \(all.count) im Korpus.
            """)
        let duplicates = seen.filter { $0.value > 1 }
        #expect(duplicates.isEmpty, """
            \(duplicates.count) Dokumente liegen in mehreren Chargen.
            """)
    }
}
