import SwiftUI
import AppKit

// MARK: - Focused-Value-Routing für Menü-Befehle (§33)

struct AppToolKey: FocusedValueKey {
    typealias Value = AppTool
}

extension FocusedValues {
    var appTool: AppTool? {
        get { self[AppToolKey.self] }
        set { self[AppToolKey.self] = newValue }
    }
    /// Masterplan F2: Werkzeugwechsel aus dem Menü „Darstellung“.
    var selectTool: ToolSelector? {
        get { self[ToolSelectorKey.self] }
        set { self[ToolSelectorKey.self] = newValue }
    }
}

struct ToolSelector {
    let select: (AppTool) -> Void
    init(_ select: @escaping (AppTool) -> Void) { self.select = select }
}

struct ToolSelectorKey: FocusedValueKey {
    typealias Value = ToolSelector
}

// MergeViewModel wird über `.focusedSceneObject(vm)` registriert und
// per @FocusedObject (typbasiert) konsumiert – inkl. Change-Tracking.

extension PDFToolsApp {

    private var organizeActive: Bool {
        activeTool == .organize && organizeVM != nil
    }

    private var openLabel: String {
        switch activeTool {
        case .organize: return String(localized: "PDFs oder Bilder hinzufügen …")
        case .convert: return String(localized: "PDF oder Bilder öffnen …")
        case .compress: return String(localized: "PDFs öffnen …")
        default: return String(localized: "PDF öffnen …")
        }
    }

    private var hasPages: Bool {
        !(organizeVM?.project.pages.isEmpty ?? true)
    }

    /// F2: Seiten löschen nur im Projektzustand – nicht während eines Laufs
    /// und nicht hinter der Ergebnisansicht.
    private var hasSelection: Bool {
        organizeActive && !(organizeVM?.selectedPageIDs.isEmpty ?? true)
            && !(organizeVM?.isProcessing ?? true) && organizeVM?.outcome == nil
    }

    /// „Sichern …" ist nur aktiv, wenn das aktive Werkzeug ein ungesichertes
    /// Ergebnis hat; Konvertieren sichert über seine eigenen Export-Knöpfe.
    private var canSave: Bool {
        switch activeTool {
        case .compress:
            guard let vm = compressionVM, !vm.isWorking else { return false }
            // F2: Im Stapel sichert ⌘S alle noch nicht gesicherten Ergebnisse.
            if !vm.bulkResultInputs.isEmpty { return !vm.allBulkResultsSaved }
            guard let pending = vm.pendingResult else { return false }
            return !pending.alreadyOptimized
        case .organize:
            guard let vm = organizeVM else { return false }
            return vm.outcome != nil && vm.savedURL == nil && !vm.isProcessing
        case .ocr:
            guard let vm = ocrVM else { return false }
            return vm.canSaveSearchablePDF && vm.savedURL == nil && !vm.isWorking
        default:
            return false
        }
    }

    // MARK: Menüstruktur

    @CommandsBuilder
    var appCommands: some Commands {
        // Hilfe (Masterplan B7): Die README auf GitHub ist die Hilfeseite,
        // die Release-Seite sagt, was neu ist, „Lizenzen“ zeigt die
        // gebündelten Texte.
        CommandGroup(replacing: .help) {
            Button("PDFdownsize-Hilfe") {
                NSWorkspace.shared.open(AppLinks.help)
            }
            Button("Neu in dieser Version") {
                NSWorkspace.shared.open(AppLinks.releaseNotes)
            }
            Divider()
            OpenWindowButton(title: String(localized: "Lizenzen"), windowID: "licenses")
        }

        // App-Menü: Updates über Sparkle. Die Abfrage ist die einzige
        // Netzverbindung der App und hier abschaltbar.
        CommandGroup(after: .appInfo) {
            Button("Nach Updates suchen …") {
                updateChecker.checkForUpdates()
            }
            .disabled(!updateChecker.canCheck)
            Toggle("Automatisch nach Updates suchen",
                   isOn: $updateChecker.checksAutomatically)
        }

        // Ablage: Öffnen und Sichern – mehr nicht (Befund S15). Die
        // Organisieren-Befehle bündelt das Menü „Seite".
        CommandGroup(after: .newItem) {
            // Kontextabhängig benannt (Review §48): je Workspace hinzufügen/öffnen.
            Button(openLabel) {
                switch activeTool {
                case .organize:
                    organizeVM?.wantsImport = true
                case .convert:
                    conversionVM?.wantsFiles = true
                case .ocr:
                    ocrVM?.wantsFiles = true
                default:
                    guard let compressionVM else { break }
                    if let discardGuard {
                        discardGuard.run(ifUnsaved: compressionVM.hasUnsavedResult) {
                            compressionVM.chooseFiles()
                        }
                    } else {
                        compressionVM.chooseFiles()
                    }
                }
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(activeTool == .compress && (compressionVM?.isWorking ?? false))
        }

        // Ein echtes „Sichern … ⌘S" je aktivem Werkzeug; vorher hing ⌘S nur
        // an einem Knopf im Komprimieren-Pult.
        CommandGroup(replacing: .saveItem) {
            Button("Sichern …") {
                switch activeTool {
                case .compress:
                    if let vm = compressionVM, !vm.bulkResultInputs.isEmpty {
                        vm.saveAllBulkWithPanel()
                    } else if let pending = compressionVM?.pendingResult {
                        compressionVM?.savePending(pending)
                    }
                case .organize:
                    if let outcome = organizeVM?.outcome {
                        organizeVM?.saveOutcome(outcome)
                    }
                case .ocr:
                    ocrVM?.saveOutcome()
                default:
                    break
                }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!canSave)
        }

        // Darstellung (Masterplan F2): Werkzeuge per Tastatur.
        CommandGroup(before: .sidebar) {
            ForEach(Array(AppTool.allCases.enumerated()), id: \.element) { index, tool in
                Button(tool.label) { selectTool?.select(tool) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .disabled(selectTool == nil)
            }
            Divider()
        }

        // Rückgängig/Wiederholen (Masterplan F2): im Organisieren auf dem
        // eigenen Projekt-UndoManager, sonst wie gewohnt über das Fenster.
        CommandGroup(replacing: .undoRedo) {
            let projectUndo = organizeActive ? organizeVM?.ownUndoManager : nil
            Button(projectUndo.map { $0.undoMenuItemTitle } ?? String(localized: "Rückgängig")) {
                if let projectUndo { projectUndo.undo() } else {
                    NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                }
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(projectUndo.map { !$0.canUndo || (organizeVM?.isProcessing ?? false) } ?? false)
            Button(projectUndo.map { $0.redoMenuItemTitle } ?? String(localized: "Wiederholen")) {
                if let projectUndo { projectUndo.redo() } else {
                    NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
                }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(projectUndo.map { !$0.canRedo || (organizeVM?.isProcessing ?? false) } ?? false)
        }

        // Bearbeiten
        CommandGroup(after: .undoRedo) {
            Divider()

            // Kein eigenes „Alle Seiten auswählen" (Sichtabnahme 2026-10-12,
            // L4): Es stand doppelt neben dem System-„Alles auswählen" (⌘A),
            // das der Organizer über `.onCommand(selectAll:)` beantwortet.
            // Ebenso hieß dieser Befehl wie das System-„Löschen" darunter.
            Button("Seiten löschen") {
                organizeVM?.deleteSelectedPages()
            }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(!hasSelection)

            Divider()

            Button("Änderungen zurücksetzen") {
                organizeVM?.resetChanges()
            }
            .disabled(!organizeActive || !(organizeVM?.hasChanges ?? false) || (organizeVM?.isProcessing ?? false))
        }

        // Seite
        // Keine willkürlichen [ ]-Shortcuts (Review §20) – Drag + Buttons +
        // Menübefehle reichen für V1; Shortcuts später bewusst festlegen.
        CommandMenu("Seite") {
            Button("PDF erstellen …") {
                organizeVM?.mergeAndPrepare()
            }
            .disabled(!organizeActive || !hasPages || (organizeVM?.isProcessing ?? false))

            // §65 Feature 1: Auswahl als eigene PDF exportieren.
            Button("Auswahl extrahieren …") {
                organizeVM?.extractSelectedPages()
            }
            .disabled(!hasSelection || (organizeVM?.isProcessing ?? false))

            // §65 Feature 2: PDF in mehrere Teile aufteilen.
            Button("PDF aufteilen …") {
                organizeVM?.wantsSplit = true
            }
            .disabled(!organizeActive || !hasPages || (organizeVM?.isProcessing ?? false))

            // §65 Feature 3: Seiten als Bilder exportieren.
            Button("Seiten als Bilder exportieren …") {
                organizeVM?.wantsImages = true
            }
            .disabled(!organizeActive || !hasPages || (organizeVM?.isProcessing ?? false))

            Divider()

            Button("Nach links drehen") {
                organizeVM?.rotateSelectedPages(by: 270)
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(!hasSelection)

            Button("Nach rechts drehen") {
                organizeVM?.rotateSelectedPages(by: 90)
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(!hasSelection)

            Divider()

            Button("Nach links verschieben") {
                organizeVM?.moveSelectionLeft()
            }
            .disabled(!hasSelection || !(organizeVM?.canMoveLeft() ?? false))

            Button("Nach rechts verschieben") {
                organizeVM?.moveSelectionRight()
            }
            .disabled(!hasSelection || !(organizeVM?.canMoveRight() ?? false))
        }
    }
}


/// Feste Ziele des Hilfe-Menüs.
enum AppLinks {
    static let repository = URL(string: "https://github.com/Klabautter/pdfdownsize")!
    static let help = URL(string: "https://github.com/Klabautter/pdfdownsize#readme")!
    /// Release-Seite genau dieser Version.
    static var releaseNotes: URL {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return version.isEmpty
            ? repository.appendingPathComponent("releases")
            : repository.appendingPathComponent("releases/tag/v\(version)")
    }
}

/// `openWindow` gibt es nur in Views; Menübefehle brauchen diese Hülle.
private struct OpenWindowButton: View {
    let title: String
    let windowID: String
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(title) { openWindow(id: windowID) }
    }
}
