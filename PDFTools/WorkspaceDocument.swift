import Foundation

/// Aktiver Dokumentstand über Werkzeuggrenzen hinweg (v1.2).
///
/// Sobald Komprimieren, OCR, Organisieren oder Konvertieren ein Ergebnis
/// erzeugt (auch noch ungesichert), wird dieser neue Stand zum aktiven
/// Dokument. Ein Wechsel per Seitenleiste oder „Weiter in …“ arbeitet dann
/// auf dem aktuellen Ergebnis statt still auf dem alten Original.
struct WorkspaceDocument: Equatable, Sendable {
    /// Identifiziert dieselbe Dokument-Abstammung über mehrere Schritte.
    let lineageID: UUID
    /// Aktuelle PDF-Datei auf der Platte (Original, gesichert oder Sitzungskopie).
    let url: URL
    /// Passwort im Speicher für geschützte PDFs (nie persistiert, Masterplan N10).
    let password: String?
    /// Werkzeuge, die auf diesem Stand bereits gelaufen sind.
    let completedTools: Set<AppTool>

    init(lineageID: UUID = UUID(),
         url: URL,
         password: String? = nil,
         completedTools: Set<AppTool> = []) {
        self.lineageID = lineageID
        self.url = url
        self.password = password
        self.completedTools = completedTools
    }

    /// Neues Dokument derselben Abstammung nach einem abgeschlossenen Schritt.
    func advancing(to handoff: ToolHandoff, completed tool: AppTool) -> WorkspaceDocument {
        WorkspaceDocument(lineageID: lineageID,
                          url: handoff.url,
                          password: handoff.password ?? password,
                          completedTools: completedTools.union([tool]))
    }

    var isCompressed: Bool { completedTools.contains(.compress) }

    /// Kurzer, ruhiger Stand-Hinweis im Kopf des Zielwerkzeugs (nil bei frischem Original).
    var statusBadge: String? {
        let relevant: [AppTool] = [.compress, .ocr, .organize].filter { completedTools.contains($0) }
        guard !relevant.isEmpty else { return nil }
        if relevant.count == 1, let only = relevant.first {
            switch only {
            case .compress: return String(localized: "Komprimierter Stand")
            case .ocr: return String(localized: "Durchsuchbar (OCR)")
            case .organize: return String(localized: "Bearbeiteter Stand")
            case .convert: return nil
            }
        }
        return relevant.map { tool in
            switch tool {
            case .compress: return String(localized: "Komprimiert")
            case .ocr: return "OCR"
            case .organize: return String(localized: "Bearbeitet")
            case .convert: return ""
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: " · ")
    }
}

/// Sichere Übergabe einer Ergebnis-PDF zwischen zwei Werkzeugen.
///
/// Ein noch ungesichertes Ergebnis wird in einen eigenen Sitzungsordner kopiert
/// (und bei entsperrten Quellen neu verschlüsselt), damit das Quellwerkzeug
/// seine Temp-Datei später löschen oder verschieben darf, ohne dem Empfänger
/// die Grundlage wegzuziehen.
struct ToolHandoff: Equatable, Sendable {
    let url: URL
    let password: String?

    /// Erstellt eine unabhängige Sitzungskopie mit sprechendem Dateinamen.
    nonisolated static func makeCopy(from source: URL,
                                     suggestedFileName: String,
                                     reencryptWith unlocked: UnlockedDocument? = nil) throws -> ToolHandoff {
        let base = (suggestedFileName as NSString).deletingPathExtension
        let safeBase = base.isEmpty ? "Dokument" : base
        let dest = SessionScratch.directory
            .appendingPathComponent("handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let file = dest.appendingPathComponent(safeBase).appendingPathExtension("pdf")
        if let unlocked {
            try unlocked.reencrypt(source, to: file)
            return ToolHandoff(url: file, password: unlocked.password)
        }
        try FileManager.default.copyItem(at: source, to: file)
        return ToolHandoff(url: file, password: nil)
    }
}
