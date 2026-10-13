import SwiftUI

// MARK: - Focused-Value-Routing für Menü-Befehle (§33)

struct AppToolKey: FocusedValueKey {
    typealias Value = AppTool
}

extension FocusedValues {
    var appTool: AppTool? {
        get { self[AppToolKey.self] }
        set { self[AppToolKey.self] = newValue }
    }
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

    private var hasSelection: Bool {
        organizeActive && !(organizeVM?.selectedPageIDs.isEmpty ?? true)
    }

    /// „Sichern …" ist nur aktiv, wenn das aktive Werkzeug ein ungesichertes
    /// Ergebnis hat; Konvertieren sichert über seine eigenen Export-Knöpfe.
    private var canSave: Bool {
        switch activeTool {
        case .compress:
            guard let vm = compressionVM, let pending = vm.pendingResult else { return false }
            return !pending.alreadyOptimized && !vm.isWorking
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
        // Kein leeres Hilfe-Menü (Befund A6, Review 2026-10-09): Es gibt
        // keine Hilfeseite; der Eintrag „PDFTools-Hilfe" führte ins Leere.
        CommandGroup(replacing: .help) { }

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
                    if let pending = compressionVM?.pendingResult {
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

        // Bearbeiten (zusätzlich zu Rückgängig/Wiederholen des Systems)
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
