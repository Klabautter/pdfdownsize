//
//  PDFToolsApp.swift
//  PDFTools
//

import SwiftUI

/// „Öffnen mit"/Dock mit mehreren Dateien: `onOpenURL` meldet davon nur die
/// erste. Der App-Delegate bekommt die ganze Liste und reicht sie an das
/// Fenster weiter (Sichtabnahme 2026-10-13).
final class OpenFilesDelegate: NSObject, NSApplicationDelegate {
    static let didReceiveFiles = Notification.Name("PDFdownsize.didReceiveFiles")

    /// Die Instanz, die `NSApplicationDelegateAdaptor` anlegt. `NSApp.delegate`
    /// ist unter SwiftUI ein interner Wrapper und lässt sich nicht casten.
    nonisolated(unsafe) static weak var current: OpenFilesDelegate?

    override init() {
        super.init()
        Self.current = self
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        NotificationCenter.default.post(name: Self.didReceiveFiles, object: urls)
    }

    // MARK: Beenden (Masterplan B3)
    //
    // Vorher gab es kein `applicationShouldTerminate`: ⌘Q verwarf ein
    // ungesichertes Ergebnis und einen laufenden Lauf ohne Rückfrage, und
    // `willTerminate` löschte den Sitzungsordner gleich mit.

    /// Von RootView gesetzt: sammelt ungesicherte Ergebnisse und Läufe der
    /// vier Werkzeuge.
    var pendingWork: (@MainActor () -> PendingWork)?
    /// Von RootView gesetzt: zeigt den Verwerfen-Dialog und meldet die Antwort.
    var confirmQuit: (@MainActor (PendingWork, @escaping (Bool) -> Void) -> Void)?

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let work = pendingWork?(), work.needsConfirmation,
              let confirmQuit else { return .terminateNow }
        confirmQuit(work) { sender.reply(toApplicationShouldTerminate: $0) }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Was beim Beenden oder Fensterschließen verloren ginge.
struct PendingWork: Equatable {
    var unsavedResult = false
    var running = false
    var needsConfirmation: Bool { unsavedResult || running }
}

@main
struct PDFToolsApp: App {
    @NSApplicationDelegateAdaptor(OpenFilesDelegate.self) private var openFilesDelegate
    // intern (nicht private): Commands.swift-Erweiterung greift darauf zu.
    @FocusedValue(\.appTool) var activeTool: AppTool?
    @FocusedObject var organizeVM: MergeViewModel?
    @FocusedObject var compressionVM: CompressionViewModel?
    @FocusedObject var conversionVM: ConversionViewModel?
    @FocusedObject var ocrVM: OCRViewModel?
    @FocusedObject var discardGuard: DiscardGuard?
    // intern: Commands.swift (App-Menü) greift darauf zu.
    @StateObject var updateChecker = UpdateChecker()

    init() {
        // Messlauf ohne Oberfläche (`--bench …`): beendet den Prozess selbst.
        BenchmarkMode.runIfRequested()
        // Temp-Bild-PDFs früherer Sessions wegwerfen (Review P0.4);
        // Dateien der laufenden Session entstehen erst nach diesem Punkt.
        ImageImporter.cleanupStaleImports()
        // Nicht gesicherte Ergebnisse: Reste beendeter Sitzungen weg, die
        // eigenen verschwinden beim Beenden.
        SessionScratch.cleanupAbandoned()
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            SessionScratch.removeOwnDirectory()
        }
    }

    var body: some Scene {
        // Single-Window-Tool-App: Dokument-Events (Open With/Finder) routen in das
        // bestehende Fenster, statt ein zweites zu öffnen (WindowGroup würde duplizieren).
        Window("PDFdownsize", id: "main") {
            RootView()
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            appCommands
        }

        Window("Lizenzen", id: "licenses") {
            LicensesView()
        }
        .defaultSize(width: 820, height: 560)
    }
}
