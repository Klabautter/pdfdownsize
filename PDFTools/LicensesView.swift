import SwiftUI

/// Masterplan B7/G6: „Lizenzen“ im Hilfe-Menü zeigt die gebündelten Texte
/// (Contents/Resources/ReleaseEvidence) – dieselben Dateien, die der Build
/// einbettet und release-check.sh prüft.
struct LicensesView: View {
    struct Entry: Identifiable, Hashable {
        let url: URL
        var id: URL { url }
        var title: String { url.deletingPathExtension().lastPathComponent }
    }

    @State private var selection: Entry?

    private var entries: [Entry] {
        guard let dir = Bundle.main.resourceURL?
            .appendingPathComponent("ReleaseEvidence", isDirectory: true),
              let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { return [] }
        return files
            .filter { ["md", "txt"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map(Entry.init)
    }

    var body: some View {
        NavigationSplitView {
            List(entries, selection: $selection) { entry in
                Text(entry.title).tag(entry)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let selection,
               let text = try? String(contentsOf: selection.url, encoding: .utf8) {
                ScrollView {
                    Text(text)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
            } else {
                ContentUnavailableView("Lizenz auswählen", systemImage: "doc.text")
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear { if selection == nil { selection = entries.first } }
    }
}
