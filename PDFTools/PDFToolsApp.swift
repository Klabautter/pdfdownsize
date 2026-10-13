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

    func application(_ application: NSApplication, open urls: [URL]) {
        NotificationCenter.default.post(name: Self.didReceiveFiles, object: urls)
    }
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
    }
}
