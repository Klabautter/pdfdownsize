import Combine
import SwiftUI

/// Hinweis auf eine neuere Version (2026-10-13).
///
/// Die App aktualisiert sich nicht selbst; sie fragt nur bei GitHub nach der
/// Versionsnummer des neuesten Releases und zeigt einen Hinweis mit Link zur
/// Download-Seite. Das ist die EINZIGE Netzverbindung der App: Es wird nichts
/// hochgeladen, keine Datei und keine Kennung – übertragen wird eine
/// gewöhnliche Abfrage an `api.github.com`. Abschaltbar im App-Menü.
@MainActor
final class UpdateChecker: ObservableObject {
    struct Release: Equatable {
        let version: String
        let page: URL
    }

    enum CheckResult: Equatable {
        case upToDate
        case available(Release)
        case failed
    }

    static let latestReleaseURL = URL(string: "https://api.github.com/repos/Klabautter/pdfdownsize/releases/latest")!
    static let automaticKey = "checkForUpdatesAutomatically"
    static let lastCheckKey = "lastUpdateCheck"
    static let dismissedKey = "dismissedUpdateVersion"
    /// Höchstens eine automatische Abfrage am Tag.
    static let minimumInterval: TimeInterval = 24 * 60 * 60

    /// Neuere Version, auf die der Hinweis in der Seitenleiste zeigt.
    @Published private(set) var available: Release?
    @Published var checksAutomatically: Bool {
        didSet { defaults.set(checksAutomatically, forKey: Self.automaticKey) }
    }
    /// Ergebnis einer von Hand ausgelösten Suche – für die Rückmeldung.
    @Published var manualResult: CheckResult?

    private let defaults: UserDefaults
    private let currentVersion: String
    private let fetch: @Sendable () async -> Data?

    init(defaults: UserDefaults = .standard,
         currentVersion: String = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
         fetch: (@Sendable () async -> Data?)? = nil) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.fetch = fetch ?? Self.fetchLatestRelease
        // Voreinstellung: eingeschaltet.
        self.checksAutomatically = defaults.object(forKey: Self.automaticKey) as? Bool ?? true
    }

    /// Beim Start: nur wenn eingeschaltet und die letzte Abfrage alt genug ist.
    func checkOnLaunch(now: Date = Date()) async {
        guard checksAutomatically else { return }
        if let last = defaults.object(forKey: Self.lastCheckKey) as? Date,
           now.timeIntervalSince(last) < Self.minimumInterval { return }
        if case .available(let release) = await check(now: now),
           defaults.string(forKey: Self.dismissedKey) != release.version {
            available = release
        }
    }

    /// „Nach Updates suchen …" – fragt immer und meldet das Ergebnis.
    func checkManually() async {
        let result = await check(now: Date())
        if case .available(let release) = result { available = release }
        manualResult = result
    }

    /// Hinweis schließen; dieselbe Version meldet sich nicht erneut von allein.
    func dismiss() {
        if let version = available?.version {
            defaults.set(version, forKey: Self.dismissedKey)
        }
        available = nil
    }

    private func check(now: Date) async -> CheckResult {
        guard let data = await fetch(),
              let release = Self.parse(data) else { return .failed }
        defaults.set(now, forKey: Self.lastCheckKey)
        return Self.isNewer(release.version, than: currentVersion)
            ? .available(release) : .upToDate
    }

    // MARK: Reine Funktionen (getestet)

    /// Liest `tag_name` („v1.0.2") und `html_url` aus der GitHub-Antwort.
    nonisolated static func parse(_ data: Data) -> Release? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let link = object["html_url"] as? String,
              let page = URL(string: link),
              page.scheme == "https", page.host == "github.com" else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !components(version).isEmpty else { return nil }
        return Release(version: version, page: page)
    }

    /// Zahlenweise verglichen: 1.0.10 ist neuer als 1.0.9, 1.1 neuer als 1.0.5.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate), b = components(current)
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    nonisolated private static func components(_ version: String) -> [Int] {
        let parts = version.split(separator: ".").map { Int($0) }
        return parts.contains(nil) ? [] : parts.compactMap { $0 }
    }

    nonisolated private static func fetchLatestRelease() async -> Data? {
        var request = URLRequest(url: latestReleaseURL, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Keine Cookies, kein Cache – eine einzelne, zustandslose Abfrage.
        let session = URLSession(configuration: .ephemeral)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}

/// Hinweis am unteren Rand der Seitenleiste.
struct UpdateNotice: View {
    @ObservedObject var checker: UpdateChecker

    var body: some View {
        if let release = checker.available {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Version \(release.version) verfügbar")
                        .font(.callout.weight(.medium))
                    Spacer(minLength: 4)
                    Button {
                        checker.dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Hinweis schließen")
                    .accessibilityLabel("Hinweis schließen")
                }
                Link("Zur Download-Seite", destination: release.page)
                    .font(.callout)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
            .padding(10)
        }
    }
}
