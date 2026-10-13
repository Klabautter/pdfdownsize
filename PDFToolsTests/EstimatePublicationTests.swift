import Foundation
import Testing
@testable import PDFTools

@MainActor
struct EstimatePublicationTests {
    nonisolated private static func result(_ bytes: Int64) -> CompressionEstimate {
        CompressionEstimate(pageCount: 1, imageCount: 1, oversizedCount: 1,
                            maxEffectiveDPI: 300, lowBytes: bytes, pointBytes: bytes,
                            highBytes: bytes, originalBytes: 1000, potential: .high)
    }

    /// Die Gates warten ohne eigenes Timeout: Ein 10-s-Timeout löste unter
    /// Volllast der Testsuite aus und veröffentlichte das neuere Ergebnis
    /// VOR den Prüfungen (gemessen: 259 s Testdauer, Fehlschlag). Gegen
    /// echte Hänger schützt das Zeitlimit des Tests.
    @Test(.timeLimit(.minutes(5))) func olderCompletionCannotStopNewerSpinnerOrPublish() async throws {
        let vm = CompressionViewModel(defaults: .isolatedForTest())
        vm.inputURL = URL(fileURLWithPath: "/tmp/estimate.pdf")
        let oldGate = DispatchSemaphore(value: 0)
        let newGate = DispatchSemaphore(value: 0)
        vm.estimateProvider = { _, _ in
            _ = oldGate.wait()
            return Self.result(100)
        }
        let oldTask = try #require(vm.refreshEstimate())
        vm.estimateProvider = { _, _ in
            _ = newGate.wait()
            return Self.result(200)
        }
        let newTask = try #require(vm.refreshEstimate())
        oldGate.signal()
        await oldTask.value
        #expect(vm.estimateRefreshing)
        #expect(vm.estimate == nil)
        newGate.signal()
        await newTask.value
        #expect(!vm.estimateRefreshing)
        #expect(vm.estimate?.pointBytes == 200)
    }

    @Test(.timeLimit(.minutes(5))) func changedOptionsInvalidateInFlightEstimate() async throws {
        let vm = CompressionViewModel(defaults: .isolatedForTest())
        let previous = vm.linearizeForWeb
        defer { vm.linearizeForWeb = previous }
        vm.inputURL = URL(fileURLWithPath: "/tmp/estimate-options.pdf")
        let gate = DispatchSemaphore(value: 0)
        vm.estimateProvider = { _, _ in
            _ = gate.wait()
            return Self.result(100)
        }
        let task = try #require(vm.refreshEstimate())
        vm.linearizeForWeb.toggle()
        gate.signal()
        await task.value
        #expect(vm.estimate == nil)
        #expect(!vm.estimateRefreshing)
    }
}
