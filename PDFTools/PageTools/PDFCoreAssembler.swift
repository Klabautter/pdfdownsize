import Foundation
import pdfcore

/// Epic Phase 9 – Swift-Zugriff auf den libqpdf Page-Copy-Prototype.
enum PDFCoreAssemblerError: Error, Equatable {
    case emptyPlan
    case invalidPageIndex
    case openFailed(code: UInt32)
    case internalError
}

enum PDFCoreAssembler {

    static var prototypeAvailable: Bool {
        pdfcore_prototype_available() == 0
    }

    /// Führt einen Plan mit der libqpdf-Engine aus.
    ///
    /// `onPage` wird gerufen, NACHDEM eine Seite kopiert wurde – nicht vorher.
    /// Ohne diese Rückmeldung sprang der Fortschritt von 0 auf 1, und der
    /// Aufrufer sah bei einem tausendseitigen Dokument minutenlang nichts.
    /// Den Fortschritt vor dem Aufruf zu melden wäre eine Attrappe gewesen.
    ///
    /// `shouldContinue` (Befund B11, Review 2026-10-09) wird von der Bridge
    /// VOR jeder Seite und während des Schreibens gefragt. Liefert es
    /// `false`, bricht die Bridge ab, räumt ihre Temp-Datei weg, lässt den
    /// Zielpfad unangetastet – und dieser Aufruf wirft `CancellationError`.
    /// Vorher lief der C-Aufruf synchron bis zum Ende; „Abbrechen" in der
    /// Oberfläche verwarf nur das fertige Ergebnis.
    static func write(plan: PageAssemblyPlan, to outputURL: URL,
                      removeDanglingLinks: Bool = true,
                      onPage: ((Int, Int) -> Void)? = nil,
                      shouldContinue: (() -> Bool)? = nil) throws {
        guard !plan.pages.isEmpty else { throw PDFCoreAssemblerError.emptyPlan }

        let box = CallbackBox(onPage: onPage, shouldContinue: shouldContinue)

        // CStrings stabil halten; Freigabe nach dem Call.
        let cPaths: [UnsafeMutablePointer<CChar>?] = plan.pages.map { strdup($0.sourceURL.path) }
        defer { for p in cPaths where p != nil { free(p) } }

        let indices = plan.pages.map { Int32($0.sourcePageIndex) }
        let rotations = plan.pages.map { Int32($0.rotation) }

        let status: Int32 = cPaths.withUnsafeBufferPointer { pathsBuf in
            indices.withUnsafeBufferPointer { idxBuf in
                rotations.withUnsafeBufferPointer { rotBuf in
                    // const char *const * → konstante Sicht auf das char*-Array.
                    let pathsPtr = UnsafeRawPointer(pathsBuf.baseAddress!)
                        .assumingMemoryBound(to: UnsafePointer<CChar>?.self)
                    return pdfcore_write_pages_cancellable(
                        pathsPtr,
                        UnsafeMutablePointer(mutating: idxBuf.baseAddress),
                        UnsafeMutablePointer(mutating: rotBuf.baseAddress),
                        Int32(plan.pages.count),
                        outputURL.path,
                        removeDanglingLinks ? 1 : 0,
                        // C-Callbacks: `box` hält die Swift-Closures am Leben,
                        // solange der Aufruf läuft. Ein Closure-Kontext kann
                        // nicht direkt als void* übergeben werden.
                        { context, done, total in
                            guard let context else { return }
                            let box = Unmanaged<CallbackBox>
                                .fromOpaque(context).takeUnretainedValue()
                            box.report(Int(done), Int(total))
                        },
                        { context in
                            guard let context else { return 1 }
                            let box = Unmanaged<CallbackBox>
                                .fromOpaque(context).takeUnretainedValue()
                            return box.wantsToContinue() ? 1 : 0
                        },
                        Unmanaged.passUnretained(box).toOpaque())
                }
            }
        }

        switch UInt32(bitPattern: status) {
        case PDFCORE_OK.rawValue: return
        case PDFCORE_ERR_CANCELLED.rawValue: throw CancellationError()
        case PDFCORE_ERR_CHECK_FAILED.rawValue: throw PDFCoreAssemblerError.invalidPageIndex
        case PDFCORE_ERR_OPEN.rawValue:
            throw PDFCoreAssemblerError.openFailed(code: UInt32(bitPattern: status))
        default: throw PDFCoreAssemblerError.internalError
        }
    }

    /// Hält Fortschritts- und Abbruch-Closure für die Dauer des C-Aufrufs.
    private final class CallbackBox {
        private let onPage: ((Int, Int) -> Void)?
        private let shouldContinue: (() -> Bool)?
        init(onPage: ((Int, Int) -> Void)?, shouldContinue: (() -> Bool)?) {
            self.onPage = onPage
            self.shouldContinue = shouldContinue
        }
        func report(_ done: Int, _ total: Int) { onPage?(done, total) }
        func wantsToContinue() -> Bool { shouldContinue?() ?? true }
    }
}
