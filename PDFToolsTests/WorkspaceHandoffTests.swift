import Testing
import Foundation
import PDFKit
import AppKit
@testable import PDFTools

/// v1.2: Tests für den werkzeugübergreifenden Dokumentfluss (`WorkspaceDocument`,
/// `ToolHandoff`, Passwort-Erhalt und `completedTools`-Abstammung).
@Suite struct WorkspaceHandoffTests {

    private func makePDF(in dir: URL, name: String, pages: Int = 2) throws -> URL {
        let doc = PDFDocument()
        for i in 0..<pages {
            let page = PDFPage()
            let ann = PDFAnnotation(bounds: CGRect(x: 72, y: 600, width: 320, height: 40),
                                    forType: .freeText, withProperties: nil)
            ann.contents = "Seite \(i + 1)"
            page.addAnnotation(ann)
            doc.insert(page, at: i)
        }
        let url = dir.appendingPathComponent(name)
        #expect(doc.write(to: url))
        return url
    }

    private func makeLockedPDF(in dir: URL, name: String, password: String) throws -> URL {
        let plain = try makePDF(in: dir, name: "plain-\(name)", pages: 2)
        let doc = try #require(PDFDocument(url: plain))
        let locked = dir.appendingPathComponent(name)
        #expect(doc.write(to: locked, withOptions: [.userPasswordOption: password,
                                                    .ownerPasswordOption: "owner-\(password)"]))
        try? FileManager.default.removeItem(at: plain)
        return locked
    }

    @Test func workspaceDocumentVerfolgtAbstammungUndBadges() {
        let orig = WorkspaceDocument(url: URL(fileURLWithPath: "/tmp/vertrag.pdf"))
        #expect(!orig.isCompressed)
        #expect(orig.statusBadge == nil)

        let compressed = orig.advancing(
            to: ToolHandoff(url: URL(fileURLWithPath: "/tmp/vertrag_smart.pdf"), password: "pw"),
            completed: .compress)
        #expect(compressed.lineageID == orig.lineageID)
        #expect(compressed.isCompressed)
        #expect(compressed.password == "pw")
        #expect(compressed.statusBadge != nil)

        let edited = compressed.advancing(
            to: ToolHandoff(url: URL(fileURLWithPath: "/tmp/vertrag_smart_bearbeitet.pdf"), password: nil),
            completed: .organize)
        #expect(edited.lineageID == orig.lineageID)
        #expect(edited.isCompressed)
        #expect(edited.completedTools == [.compress, .organize])
        // Passwort bleibt über Schritte ohne eigenes Passwort erhalten.
        #expect(edited.password == "pw")
        #expect(edited.statusBadge?.contains("·") == true)
    }

    @Test func toolHandoffKopiertUndVerschluesseltSicher() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let plain = try makePDF(in: dir, name: "original.pdf")
        let copy = try ToolHandoff.makeCopy(from: plain, suggestedFileName: "original_smart.pdf")
        defer { try? FileManager.default.removeItem(at: copy.url.deletingLastPathComponent()) }
        #expect(copy.url != plain)
        #expect(copy.url.lastPathComponent == "original_smart.pdf")
        #expect(copy.password == nil)
        #expect(PDFDocument(url: copy.url)?.pageCount == 2)

        let locked = try makeLockedPDF(in: dir, name: "geheim.pdf", password: "abc")
        let unlocked = try UnlockedDocument.unlock(locked, password: "abc")
        defer { unlocked.discard() }

        let lockedCopy = try ToolHandoff.makeCopy(from: unlocked.workingCopy,
                                                  suggestedFileName: "geheim_durchsuchbar.pdf",
                                                  reencryptWith: unlocked)
        defer { try? FileManager.default.removeItem(at: lockedCopy.url.deletingLastPathComponent()) }
        #expect(lockedCopy.password == "abc")
        let reopened = try #require(PDFDocument(url: lockedCopy.url))
        #expect(reopened.isLocked)
        #expect(reopened.unlock(withPassword: "abc"))
        #expect(reopened.pageCount == 2)
    }

    @Test @MainActor func mergeViewModelErsetztUndEntsperrtBeiUebergabe() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("merge-handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let first = try makePDF(in: dir, name: "alt.pdf", pages: 1)
        let second = try makeLockedPDF(in: dir, name: "neu_smart.pdf", password: "geheim")

        let vm = MergeViewModel()
        vm.importDocuments([first])
        for _ in 0..<50 where vm.project.documents.isEmpty {
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(vm.project.documents.count == 1)
        #expect(vm.containsSource(first))

        vm.replaceDocuments(with: second, password: "geheim")
        for _ in 0..<80 where vm.project.documents.first?.fileName != "neu_smart.pdf" {
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(vm.project.documents.count == 1)
        #expect(vm.project.documents.first?.fileName == "neu_smart.pdf")
        #expect(vm.project.totalPages == 2)
        #expect(vm.containsSource(second))
        #expect(vm.lockedPending.isEmpty)
        vm.removeAllDocuments()
    }

    @Test @MainActor func ocrViewModelEntsperrtBeiUebergabeMitPasswort() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ocr-handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let locked = try makeLockedPDF(in: dir, name: "scan_smart.pdf", password: "topsecret")
        let vm = OCRViewModel()
        vm.accept([locked], password: "topsecret")
        for _ in 0..<80 where vm.unlocked == nil {
            try await Task.sleep(for: .milliseconds(30))
        }
        #expect(vm.stage == .ready)
        #expect(vm.unlocked != nil)
        #expect(vm.pageCount == 2)
        vm.reset()
    }
}
