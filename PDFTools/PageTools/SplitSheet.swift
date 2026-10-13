import SwiftUI
import AppKit

/// Split-Dialog (Review §65, Feature 2): Modus wählen → Zielordner wählen →
/// Teile schreiben. Ergebnis bleibt im Sheet; der Organizer-State bleibt unberührt.
struct SplitSheet: View {
    @ObservedObject var vm: MergeViewModel
    @Environment(\.dismiss) private var dismiss

    private enum Mode: Hashable {
        case everyN, perPage, atSelection
    }

    @State private var mode: Mode = .everyN
    @State private var chunkSize = 2
    @State private var isWriting = false
    @State private var written: [URL]?
    @State private var errorText: String?
    @State private var writeTask: Task<Void, Never>?

    private var baseName: String {
        (vm.project.documents.first?.fileName as NSString?)?.deletingPathExtension ?? String(localized: "Seiten")
    }

    private var chunks: [[PageItem]] {
        switch mode {
        case .everyN: PageSplitter.chunks(from: vm.project.pages, mode: .everyN(chunkSize))
        case .perPage: PageSplitter.chunks(from: vm.project.pages, mode: .perPage)
        case .atSelection:
            PageSplitter.chunks(from: vm.project.pages,
                                mode: .atSelection,
                                selection: vm.selectedPageIDs)
        }
    }

    /// Aufteilen in genau einen Teil wäre kein Split.
    private var exportAllowed: Bool { !isWriting && chunks.count > 1 && !vm.isProcessing }

    var body: some View {
        // Natives Sheet (Befunde M8/G6): Titel als Überschrift ohne Symbol,
        // Inhalt als gruppierte Form, Standard-Controls, Esc/Enter.
        VStack(alignment: .leading, spacing: 0) {
            Text("PDF aufteilen")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 6)

            Form {
                Section {
                    Picker("Aufteilen", selection: $mode) {
                        Text("Alle \(chunkSize) Seiten").tag(Mode.everyN)
                        Text("Jede Seite einzeln").tag(Mode.perPage)
                        Text("An der Auswahl teilen").tag(Mode.atSelection)
                    }
                    .pickerStyle(.radioGroup)
                    if mode == .everyN {
                        Stepper("Teilgröße: \(chunkSize) Seiten",
                                value: $chunkSize, in: 2...100)
                    }
                    if mode == .atSelection {
                        Text(vm.selectedPageIDs.isEmpty
                             ? "Keine Auswahl – zuerst Seiten auswählen."
                             : "\(vm.selectedPageIDs.count) ausgewählt")
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text(chunks.count > 1
                         ? "Es entstehen \(chunks.count) PDFs."
                         : "Es entsteht nur ein Teil – bitte Modus anpassen.")
                        .foregroundStyle(.secondary)
                }
                .disabled(isWriting || written != nil)

                if let errorText {
                    Section {
                        InlineNotice(message: errorText)
                    }
                }
            }
            // Spaltenform: passt sich dem Inhalt an (kein List-Scrollbereich
            // ohne eigene Höhe im Sheet).
            .formStyle(.columns)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            footer
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
        }
        .frame(width: 440)
    }

    @ViewBuilder
    private var footer: some View {
        if let written {
            SavedResultBlock(title: String(localized: "\(written.count) Teile gesichert"),
                             detail: written[0].deletingLastPathComponent().path,
                             urls: [written[0]],
                             followUp: (String(localized: "Fertig"), { dismiss() }))
        } else if isWriting {
            WorkProgressBar(progress: vm.progress,
                            label: vm.processingLabel,
                            onCancel: { writeTask?.cancel() })
        } else {
            HStack {
                Button("Abbrechen") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Exportieren …") { chooseFolderAndWrite() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!exportAllowed)
            }
            .controlSize(.large)
        }
    }

    private func chooseFolderAndWrite() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Diesen Ordner verwenden")
        panel.message = String(localized: "Ordner für die aufgeteilten PDFs wählen")
        guard panel.runModal() == .OK, let folder = panel.url else { return }

        let pendingChunks = chunks
        isWriting = true
        errorText = nil
        writeTask = Task { @MainActor in
            do {
                written = try await vm.writeChunks(pendingChunks,
                                                   to: folder,
                                                   baseName: baseName)
            } catch is CancellationError {
                // nichts tun – Teile wurden vom VM geräumt
            } catch {
                errorText = error.localizedDescription
            }
            isWriting = false
        }
    }
}
