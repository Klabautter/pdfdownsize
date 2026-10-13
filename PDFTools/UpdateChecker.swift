import Combine
import Sparkle
import SwiftUI

/// Updates über Sparkle (2026-10-13).
///
/// Sparkle fragt höchstens einmal am Tag die Update-Liste (`appcast.xml` im
/// Repository) ab, lädt eine neuere Version, prüft ihre EdDSA-Signatur gegen
/// den in der App hinterlegten öffentlichen Schlüssel (`SUPublicEDKey`),
/// ersetzt die App und startet sie neu. Das ist die EINZIGE Netzverbindung
/// der App; abschaltbar im App-Menü.
@MainActor
final class UpdateChecker: ObservableObject {
    private let controller: SPUStandardUpdaterController
    private var observation: AnyCancellable?

    /// Spiegelt Sparkles eigene Einstellung (`SUEnableAutomaticChecks`).
    @Published var checksAutomatically: Bool {
        didSet {
            guard controller.updater.automaticallyChecksForUpdates != checksAutomatically else { return }
            controller.updater.automaticallyChecksForUpdates = checksAutomatically
        }
    }
    @Published private(set) var canCheck = false

    init() {
        // Im Testlauf startet der Updater nicht: Tests greifen nie ins Netz.
        let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        controller = SPUStandardUpdaterController(startingUpdater: !underTest,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        checksAutomatically = controller.updater.automaticallyChecksForUpdates
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheck = $0 }
    }

    /// „Nach Updates suchen …" – Sparkle zeigt Ergebnis und Ablauf selbst.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
