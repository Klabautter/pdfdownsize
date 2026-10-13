import SwiftUI
import AppKit

/// Bildexport-Dialog (Review §65, Feature 3): Umfang/Format/Auflösung wählen,
/// Zielordner wählen, Seiten als PNG/JPEG schreiben. Organizer-State bleibt unberührt.
/// Zuständigkeit: Projekt-Export (alle Seiten oder Auswahl, ggf. aus mehreren
/// Quellen). Für den schnellen Einzel-Export → Konvertieren (Cross-Link unten).
struct ImageExportSheet: View {
    @ObservedObject var vm: MergeViewModel
    @Environment(\.dismiss) private var dismiss
    /// Cross-Link nach Konvertieren (RootView verdrahtet Tab-Wechsel).
    var onOpenConvert: (() -> Void)? = nil

    private enum Scope: Hashable {
        case allPages, selectionOnly
    }

    @State private var scope: Scope = .allPages
    /// Geteilt mit Convert (Single Source of Truth, siehe `PageImageExporter.Settings`).
    @State private var settings = PageImageExporter.Settings()
    @State private var isWriting = false
    @State private var written: [URL]?
    @State private var errorText: String?
    @State private var writeTask: Task<Void, Never>?

    private var pages: [PageItem] {
        scope == .selectionOnly ? vm.orderedSelection : vm.project.pages
    }

    private var exportAllowed: Bool {
        !isWriting && !pages.isEmpty && !vm.isProcessing
            && !(scope == .selectionOnly && vm.selectedPageIDs.isEmpty)
    }

    var body: some View {
        // Natives Sheet (Befunde M8/G6): Titel als Überschrift ohne Symbol,
        // Inhalt als gruppierte Form, Standard-Controls, Esc/Enter.
        VStack(alignment: .leading, spacing: 0) {
            Text("Seiten als Bilder exportieren")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 6)

            Form {
                Section {
                    Picker("Umfang", selection: $scope) {
                        Text("Alle Seiten (\(vm.project.totalPages))").tag(Scope.allPages)
                        Text("Nur Auswahl (\(vm.selectedPageIDs.count))").tag(Scope.selectionOnly)
                            .disabled(vm.selectedPageIDs.isEmpty)
                    }
                    .pickerStyle(.radioGroup)

                    Picker("Format", selection: $settings.usePNG) {
                        Text("PNG (verlustfrei)").tag(true)
                        Text("JPEG (kleiner)").tag(false)
                    }
                    .pickerStyle(.radioGroup)

                    if !settings.usePNG {
                        LabeledContent("Qualität") {
                            HStack(spacing: 8) {
                                Slider(value: $settings.quality, in: 0.4...1, step: 0.05)
                                Text("\(Int(settings.quality * 100)) %")
                                    .monospacedDigit()
                                    .frame(width: 44, alignment: .trailing)
                            }
                        }
                    }

                    Picker("Auflösung", selection: $settings.dpi) {
                        Text("72 dpi · Bildschirm").tag(72)
                        Text("150 dpi · Standard").tag(150)
                        Text("300 dpi · Druck").tag(300)
                    }
                    .pickerStyle(.radioGroup)
                } footer: {
                    Text(pages.isEmpty
                         ? "Keine Seiten zum Exportieren."
                         : "Es entstehen \(pages.count) \(settings.usePNG ? "PNG" : "JPEG")-Dateien.")
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
        .frame(width: 460)
    }

    @ViewBuilder
    private var footer: some View {
        if let written {
            SavedResultBlock(title: String(localized: "\(written.count) Bilder exportiert"),
                             detail: written[0].deletingLastPathComponent().path,
                             urls: [written[0]],
                             followUp: (String(localized: "Fertig"), { dismiss() }))
        } else if isWriting {
            WorkProgressBar(progress: vm.progress,
                            label: vm.processingLabel,
                            onCancel: { writeTask?.cancel() })
        } else {
            VStack(alignment: .leading, spacing: 10) {
                // Cross-Link statt Doppel-UI: Einzel-PDF gehört nach Konvertieren.
                if onOpenConvert != nil {
                    Button("Nur eine PDF? Schneller in Konvertieren …") {
                        dismiss()
                        onOpenConvert?()
                    }
                    .buttonStyle(.link)
                    .font(.callout)
                }
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
    }

    private func chooseFolderAndWrite() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Diesen Ordner verwenden")
        panel.message = String(localized: "Ordner für die exportierten Bilder wählen")
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let folderName = vm.project.documents.count == 1
            ? (vm.project.documents.first?.fileName ?? String(localized: "Seiten"))
            : String(localized: "Seiten")
        let folder: URL
        do {
            folder = try PageImageExporter.makeExportFolder(in: parent, named: folderName)
        } catch {
            errorText = error.localizedDescription
            return
        }

        let pendingPages = pages
        let options = settings.options
        isWriting = true
        errorText = nil
        writeTask = Task { @MainActor in
            do {
                written = try await vm.exportImages(pendingPages,
                                                    options: options,
                                                    to: folder)
            } catch is CancellationError {
                // nichts tun – Dateien wurden vom Exporter geräumt
            } catch {
                errorText = error.localizedDescription
            }
            isWriting = false
        }
    }
}
