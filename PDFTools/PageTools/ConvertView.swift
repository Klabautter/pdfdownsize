import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO

/// Konvertieren-Workspace: schneller Formatwechsel für einzelne Dateien.
/// Zuständigkeit: Express-Modus (1 PDF ↔ Bilder, 2 Klicks, keine Seitenliste).
/// Für Mischen/Sortieren/Aufteilen mehrerer Quellen → Organisieren.
struct ConvertView: View {
    @ObservedObject var vm: ConversionViewModel
    /// Cross-Link nach Organisieren (RootView verdrahtet: import + Tab-Wechsel).
    var onOpenInOrganize: (([URL]) -> Void)? = nil
    @State private var showImporter = false
    @State private var isTargeted = false
    /// Review P1.1 (Variante A): Knopf bestimmt die Richtung des Importers.
    @State private var importerTypes: [UTType] = ImageImporter.allowedTypes

    var body: some View {
        Group {
            switch vm.stage {
            case .choose:
                chooseState
            case .ready, .working, .done:
                workingState
            }
        }
        .frame(minWidth: 700, minHeight: 520)
        // Für Menü-Befehle (§33-Pattern): VM im Fokus-Environment melden.
        .focusedSceneObject(vm)
        .dropDestination(for: URL.self) { urls, _ in
            vm.accept(urls)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .toolbar {
            // Dasselbe Muster wie Komprimieren (Befund S2): mit geladener
            // Datei ein Öffnen-Item rechts; der Startbildschirm hat die
            // Knöpfe in der Mitte.
            ToolbarItemGroup(placement: .primaryAction) {
                if vm.stage != .choose {
                    Button {
                        vm.wantsFiles = true
                    } label: {
                        Label("Andere Dateien öffnen …", systemImage: "plus")
                    }
                    .disabled(vm.isWorking)
                }
            }
        }
        .onChange(of: vm.wantsFiles) { _, wants in
            if wants {
                vm.wantsFiles = false
                importerTypes = ImageImporter.allowedTypes
                showImporter = true
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: importerTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                vm.accept(urls)
            }
        }
    }

    // MARK: - Auswahl

    private var chooseState: some View {
        WorkspaceWelcome(icon: "arrow.left.arrow.right",
                         title: String(localized: "Dateien konvertieren"),
                         subtitle: String(localized: "PDF-Seiten als Bilder oder Bilder als PDF – die Richtung erkennt die App beim Ablegen."),
                         dropHint: String(localized: "Dateien auch hierher ziehen"),
                         isTargeted: isTargeted) {
            // Zwei Standard-Knöpfe statt eigener Glaskacheln (Befund G4).
            // Nebeneinander, wenn beide ganz passen – sonst untereinander.
            // Im schmalen Fenster wurde „PDF als Bilder sicher…" abgeschnitten
            // (Sichtabnahme 2026-10-12, L11).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { directionButtons }
                VStack(spacing: 10) { directionButtons }
            }

            if let error = vm.errorMessage {
                InlineNotice(message: error)
                    .frame(maxWidth: 420)
            }
        }
    }

    @ViewBuilder
    private var directionButtons: some View {
        Button {
            importerTypes = vm.openImporter(forDirection: .pdfToImages)
            showImporter = true
        } label: {
            Label("PDF als Bilder sichern …", systemImage: "photo.on.rectangle")
        }
        .buttonStyle(.borderedProminent)
        .fixedSize()

        Button {
            importerTypes = vm.openImporter(forDirection: .imagesToPdf)
            showImporter = true
        } label: {
            Label("Bilder als PDF sichern …", systemImage: "doc.richtext")
        }
        .buttonStyle(.bordered)
        .fixedSize()
    }

    // MARK: - Quelle gesetzt

    private var workingState: some View {
        ToolWorkspace {
            if vm.direction == .pdfToImages, let url = vm.pdfURL {
                DocumentPreview(url: url, scanning: vm.isWorking)
            } else {
                ImageSheetGrid(urls: vm.imageURLs)
            }
        } panel: {
            VStack(alignment: .leading, spacing: 20) {
                PanelHeader(title: headerTitle, subtitle: headerSubtitle,
                            icon: headerIcon,
                            closeDisabled: vm.isWorking,
                            onClose: { vm.reset() })
                Divider()
                if vm.direction == .pdfToImages {
                    pdfToImagesControls
                } else {
                    imagesToPdfControls
                }
                statusSection
            }
        }
        .dropTargetOverlay(isTargeted)
    }

    private var headerTitle: String {
        if let url = vm.pdfURL { return url.lastPathComponent }
        return Counted.images(vm.imageURLs.count)
    }

    private var headerSubtitle: String {
        vm.direction == .pdfToImages ? String(localized: "Seiten als Bilder exportieren") : String(localized: "Zu einer PDF zusammenfassen")
    }

    private var headerIcon: NSImage {
        vm.direction == .pdfToImages
            ? NSWorkspace.shared.icon(for: .pdf)
            : NSWorkspace.shared.icon(for: .image)
    }

    private var pdfToImagesControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Format").font(.subheadline.weight(.semibold))
                Picker("Format", selection: $vm.exportSettings.usePNG) {
                    Text("PNG").tag(true)
                    Text("JPEG").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(vm.exportSettings.usePNG ? "Verlustfrei, größere Dateien." : "Kleinere Dateien, leichte Verluste.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !vm.exportSettings.usePNG {
                LabeledContent("Qualität") {
                    Text("\(Int(vm.exportSettings.quality * 100)) %").monospacedDigit()
                }
                Slider(value: $vm.exportSettings.quality, in: 0.4...1, step: 0.05)
                    .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Auflösung").font(.subheadline.weight(.semibold))
                Picker("Auflösung", selection: $vm.exportSettings.dpi) {
                    Text("72 dpi").tag(72)
                    Text("150 dpi").tag(150)
                    Text("300 dpi").tag(300)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(vm.exportSettings.dpi == 72 ? "Bildschirm" : vm.exportSettings.dpi == 150 ? "Standard" : "Druck")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !vm.isWorking {
                // Nach dem Export bleibt der Knopf – Auflösung ändern und
                // erneut exportieren (Befund S4).
                if vm.stage == .done {
                    Button { chooseFolderAndExport() } label: {
                        Text("Erneut exportieren …").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                } else {
                    Button { chooseFolderAndExport() } label: {
                        Text("Exportieren …").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.extraLarge)
                    .disabled(!vm.hasSource)
                }
            }
        }
        .disabled(vm.isWorking)
    }

    private var imagesToPdfControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reihenfolge wie ausgewählt. Zum Sortieren, Drehen oder Mischen mit PDFs gibt es Organisieren.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !vm.isWorking && vm.stage != .done {
                Button { vm.saveImagesAsPdf() } label: {
                    Text("Als PDF sichern …").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.extraLarge)
                .disabled(!vm.hasSource)
                if onOpenInOrganize != nil {
                    Button { onOpenInOrganize?(vm.imageURLs) } label: {
                        Text("In Organisieren öffnen").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(!vm.hasSource)
                }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if vm.isWorking {
            WorkProgressBar(progress: vm.progress,
                            label: vm.statusLabel,
                            isCancelling: vm.isCancelling,
                            onCancel: { vm.cancelWork() })
        }
        if vm.stage == .done {
            if let folder = vm.resultFolder {
                SavedResultBlock(title: vm.statusLabel.isEmpty ? String(localized: "Exportiert") : vm.statusLabel,
                                 detail: folder.path,
                                 urls: [folder])
            } else if let pdf = vm.savedPDF {
                SavedResultBlock(urls: [pdf])
            }
        }
        if let error = vm.errorMessage {
            InlineNotice(message: error)
        }
    }

    private func chooseFolderAndExport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Diesen Ordner verwenden")
        panel.message = String(localized: "Ordner für die exportierten Bilder wählen")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        vm.exportPdfToImages(to: folder)
    }
}

/// Bilder in Reihenfolge als nummerierte Blätter auf der Fläche.
private struct ImageSheetGrid: View {
    let urls: [URL]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 20)], spacing: 24) {
                ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                    VStack(spacing: 8) {
                        ImageThumb(url: url)
                            .frame(height: 170)
                        Text("\(index + 1) · \(url.lastPathComponent)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
            .padding(32)
        }
    }
}

private struct ImageThumb: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            let target = url
            image = await Task.detached(priority: .utility) { () -> NSImage? in
                guard let source = CGImageSourceCreateWithURL(target as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceThumbnailMaxPixelSize: 400,
                          kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
                else { return nil }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }.value
        }
    }
}
