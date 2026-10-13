import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// Gemeinsames Arbeitslayout aller Werkzeuge: links die Fläche mit dem
/// Dokument, rechts das schwebende Glas-Pult. Komprimieren hat es zuerst
/// bekommen; Konvertieren, OCR und das Ergebnis in Organisieren nutzen
/// dasselbe Muster, damit die App aus einem Guss ist.
struct ToolWorkspace<Canvas: View, Panel: View, Footer: View>: View {
    var panelWidth: CGFloat = 330
    private static var panelInset: CGFloat { 16 }
    @ViewBuilder let canvas: () -> Canvas
    @ViewBuilder let panel: () -> Panel
    /// Bleibt unter dem Pultinhalt stehen, auch wenn der scrollt – die
    /// Hauptaktion darf nie unter den Fensterrand rutschen
    /// (Sichtabnahme 2026-10-12, M7).
    @ViewBuilder let footer: () -> Footer

    @State private var panelHeight: CGFloat = 0

    @State private var moreBelow = false
    @State private var footerHeight: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let canvasWidth = max(geo.size.width - panelWidth - Self.panelInset, 200)
            // Höhe, die dem scrollenden Teil bleibt: Fläche minus Außenabstand,
            // Glas-Innenabstand und Fuß.
            let room = geo.size.height - 2 * Self.panelInset - 2 * Theme.panelPadding - footerHeight
            ZStack(alignment: .topLeading) {
                Theme.canvas
                canvas()
                    .frame(width: canvasWidth, height: geo.size.height)
                // Die Karte ist so hoch wie ihr Inhalt; erst wenn der nicht
                // mehr passt, scrollt der Inhalt IN der Karte. Keine
                // Scroll-View um das Glas: Ihr Rand schnitt den Glasschatten
                // zu einem Rechteck ab (heller Modus, Sichtabnahme 2026-10-12).
                VStack(alignment: .leading, spacing: 0) {
                    ScrollView {
                        panel()
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { panelHeight = $0 }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    // Kein sichtbarer Rollbalken im Glas-Pult (störte in
                    // „Eigene"; der Inhalt bleibt rollbar).
                    .scrollIndicators(.never)
                    // Ohne Rollbalken zeigt ein weicher Rand, dass darunter
                    // noch Inhalt folgt; am Ende der Liste verschwindet er.
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        geometry.contentSize.height - geometry.contentOffset.y
                            - geometry.containerSize.height > 4
                    } action: { _, more in
                        moreBelow = more
                    }
                    .mask {
                        VStack(spacing: 0) {
                            Color.black
                            LinearGradient(colors: [.black, .clear],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(height: moreBelow ? 32 : 0)
                        }
                    }
                    .frame(height: panelHeight > 0 ? min(panelHeight, max(room, 120)) : nil)
                    footer()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { footerHeight = $0 }
                }
                .frame(width: panelWidth - 2 * Theme.panelPadding)
                .glassPanel()
                .padding(Self.panelInset)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topTrailing)
            }
        }
    }
}

extension ToolWorkspace where Footer == EmptyView {
    init(panelWidth: CGFloat = 330,
         @ViewBuilder canvas: @escaping () -> Canvas,
         @ViewBuilder panel: @escaping () -> Panel) {
        self.init(panelWidth: panelWidth, canvas: canvas, panel: panel, footer: { EmptyView() })
    }
}

/// Kopf eines Pults: Datei-Symbol, Name, Kennzahlen, Schließen.
struct PanelHeader: View {
    let title: String
    let subtitle: String
    var icon: NSImage = NSWorkspace.shared.icon(for: .pdf)
    var closeDisabled = false
    var onClose: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
            if let onClose {
                // Innerhalb der Glasfläche ein Standard-Control (Befund S14):
                // das System-„Schließen" als randloser Knopf.
                Button(action: onClose) {
                    Label("Schließen", systemImage: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .imageScale(.large)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(closeDisabled)
                .help("Schließen")
            }
        }
    }
}

// MARK: - Gemeinsame Bausteine (Befunde S3, S4, S6)

/// Laufende Arbeit: Fortschritt, Stufe, verstrichene Zeit und EIN
/// Abbrechen-Knopf mit Esc. Nach dem Klick steht „Wird abgebrochen …" und
/// der Knopf ist gesperrt – in allen Werkzeugen und Sheets gleich.
///
/// Werkzeuge ohne eigenen `isCancelling`-Zustand (Konvertieren, OCR,
/// Organisieren) lassen `isCancelling` weg; die Leiste merkt sich den Klick
/// selbst. Sie liegt in einem `if isWorking`-Zweig, verschwindet also mit dem
/// Lauf und beginnt beim nächsten frisch.
struct WorkProgressBar: View {
    let progress: Double
    var label: String = ""
    var startedAt: Date? = nil
    var isCancelling: Bool? = nil
    /// Kompakt: eine Zeile (Leiste · Text · Zeit · Knopf) für Fußleisten.
    var compact = false
    let onCancel: () -> Void

    @State private var requested = false

    private var cancelling: Bool { isCancelling ?? requested }

    private var text: String {
        if cancelling { return String(localized: "Wird abgebrochen …") }
        let mapped = ProgressText.userFacing(label)
        return mapped.isEmpty ? String(localized: "Wird verarbeitet …") : mapped
    }

    var body: some View {
        if compact {
            HStack(spacing: 12) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 260)
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .monospacedDigit()
                Spacer()
                elapsed
                cancelButton
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .animation(.easeOut(duration: 0.35), value: progress)
                HStack {
                    Text(text)
                        .lineLimit(1)
                        .monospacedDigit()
                    Spacer()
                    elapsed
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                cancelButton
                    .controlSize(.large)
            }
        }
    }

    @ViewBuilder
    private var elapsed: some View {
        if let startedAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(CompressionViewModel.elapsedTimeText(startedAt: startedAt, now: context.date))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var cancelButton: some View {
        Button {
            requested = true
            onCancel()
        } label: {
            Text("Abbrechen").frame(maxWidth: compact ? nil : .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(cancelling)
        .keyboardShortcut(.cancelAction)
    }
}

/// Ergebnis nach dem Sichern: „Gesichert" in der Erfolgsfarbe, „Im Finder
/// zeigen" und optional eine Folgeaktion (z. B. „Weitere PDF öffnen …").
struct SavedResultBlock: View {
    var title = String(localized: "Gesichert")
    var detail: String? = nil
    let urls: [URL]
    var followUp: (label: String, action: () -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(Theme.savings)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            HStack(spacing: 8) {
                Button("Im Finder zeigen") {
                    NSWorkspace.shared.activateFileViewerSelecting(urls)
                }
                .buttonStyle(.bordered)
                .disabled(urls.isEmpty)
                if let followUp {
                    Button {
                        followUp.action()
                    } label: {
                        Text(followUp.label).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.large)
        }
    }
}

/// Zustandshinweis („Bitte nur PDF-Dateien ablegen", Sichern gescheitert):
/// ein Label mit Warnsymbol in Sekundärfarbe – nicht rot, kein eigener
/// Kasten. Eine Darstellung für alle Werkzeuge.
struct InlineNotice: View {
    let message: String
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let onDismiss {
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Label("Hinweis schließen", systemImage: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Hinweis schließen")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Akzentrahmen, solange Dateien über der Fläche schweben – in allen
    /// Einstiegen und geladenen Zuständen derselbe (Befund S1).
    func dropTargetOverlay(_ isTargeted: Bool, inset: CGFloat = 8) -> some View {
        overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous))
                    .padding(inset)
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isTargeted)
    }
}

/// Eine Stelle, die Stufen-Texte der Pipeline in Nutzer-Deutsch bringt
/// (Befund S7): Passiv, „Seite 3 von 10", keine Diagnosesprache.
enum ProgressText {
    static func userFacing(_ raw: String) -> String {
        let label = raw.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty else { return "" }
        switch label {
        case "Vorbereiten …": return String(localized: "Wird vorbereitet …")
        case "Analysiere …", "Analysiere Dokument …": return String(localized: "Dokument wird analysiert …")
        case "Optimiere Bilder …": return String(localized: "Bilder werden optimiert …")
        case "Optimiere Struktur …": return String(localized: "Struktur wird optimiert …")
        case "Validiere Ergebnis …": return String(localized: "Ergebnis wird geprüft …")
        case "Erstelle PDF …": return String(localized: "PDF wird erstellt …")
        case "Smart komprimieren …": return String(localized: "Wird mit Smart komprimiert …")
        default: break
        }
        if label.hasPrefix("Qualitätsprüfung") || label.hasPrefix("Optimiere Bilder (") {
            if label.contains("Ziel") { return String(localized: "Zielgröße wird angepasst …") }
            return String(localized: "Qualität wird geprüft – Bilder werden erneut optimiert …")
        }
        if label.hasPrefix("Zielgröße") { return String(localized: "Zielgröße wird angepasst …") }
        // „Seite 3 / 10 …" → „Seite 3 von 10 …"
        let parts = label.components(separatedBy: " / ")
        if parts.count == 2, parts[0].hasPrefix("Seite "),
           let done = Int(parts[0].dropFirst(6)),
           let total = Int(parts[1].prefix(while: \.isNumber)) {
            return String(localized: "Seite \(done) von \(total)")
                + parts[1].drop(while: \.isNumber)
        }
        return label.replacingOccurrences(of: " / ", with: " von ")
    }
}

/// Eigenständige Dokumentvorschau in der nativen Ansicht (zoombar), mit
/// Stichproben-Seitenleiste. Öffnet das Dokument EINMAL; Seitenwechsel
/// blättern nur.
struct DocumentPreview: View {
    let url: URL
    var scanning = false
    /// Von außen gesteuerte Seite (z. B. Sprung zu einem Suchtreffer);
    /// ohne Bindung verwaltet die Vorschau die Seite selbst.
    var page: Binding<Int>? = nil
    /// Suchbegriff, dessen Fundstellen markiert werden.
    var highlight: String = ""
    /// Seiten, deren Text dezent markiert wird (erkannter OCR-Text).
    var markedPages: Set<Int> = []
    var caption: ((Int, Int) -> String)? = nil

    @State private var document: PDFDocument?
    @State private var ownSelected = 0
    private var selected: Int {
        get { page?.wrappedValue ?? ownSelected }
        nonmutating set {
            if let page { page.wrappedValue = newValue } else { ownSelected = newValue }
        }
    }
    @State private var thumbs: [Int: NSImage] = [:]
    @State private var fraction = 0.5

    private var pageCount: Int { document?.pageCount ?? 0 }

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                if let document {
                    DocumentStage(original: document, compressed: nil,
                                  pageIndex: selected, scanning: scanning,
                                  fraction: $fraction,
                                  highlight: highlight,
                                  markedPages: markedPages,
                                  onPageChange: { selected = $0 })
                } else {
                    PaperSheet(image: nil, scanning: scanning)
                }
            }
            .padding(.top, 28)
            .padding(.horizontal, 32)
            .padding(.bottom, pageCount > 1 ? 112 : 28)
            if pageCount > 1 {
                PageStrip(thumbs: thumbs,
                          sampleCount: min(pageCount, CompressionViewModel.samplePageCount),
                          pageCount: pageCount,
                          selected: selected,
                          caption: caption?(selected, pageCount)
                              ?? String(localized: "Seite \(selected + 1) von \(pageCount)"),
                          onSelect: { selected = min(max($0, 0), pageCount - 1) })
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
            }
        }
        .task(id: url) { await loadDocument() }
    }

    private func loadDocument() async {
        ownSelected = 0   // eine gebundene Seite behält ihren Stand (z. B. Quelle → Ergebnis)
        thumbs = [:]
        document = PDFDocument(url: url)
        let target = url
        let samples = CompressionViewModel.samplePageCount
        thumbs = await Task.detached(priority: .utility) { () -> [Int: NSImage] in
            guard let doc = PDFDocument(url: target) else { return [:] }
            var out: [Int: NSImage] = [:]
            for index in 0..<min(doc.pageCount, samples) {
                if let page = doc.page(at: index) {
                    out[index] = page.thumbnail(of: CGSize(width: 80, height: 100), for: .cropBox)
                }
            }
            return out
        }.value
    }
}
