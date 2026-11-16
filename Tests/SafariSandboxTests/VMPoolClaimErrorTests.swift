import Foundation
import Testing
@testable import SandboxEngine

/// claim() boots each browser VM on demand; when that boot fails the app
/// must learn why (not assume "too many sessions"), and network failures
/// must be recognisable so they can be retried on a host network change.
@Suite("VMPool claim errors")
struct VMPoolClaimErrorTests {
    @MainActor
    @Test("A failed on-demand boot records its cause")
    func failedBootRecordsCause() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmpool-claim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let pool = VMPool(config: VMConfig(), storageDir: dir, automaticallyReplenishes: false)
        let result = await pool.claimResult(config: VMConfig())
        #expect(result.vm == nil)
        let error = try #require(result.error as? SandboxError)
        guard case .baseImageNotFound = error else {
            Issue.record("expected baseImageNotFound, got \(error)")
            return
        }
        #expect(!SandboxError.isNetworkFailure(error))
    }

    @MainActor
    @Test("A later claim can't clear or replace an earlier claim's error")
    func laterClaimKeepsEarlierError() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmpool-claim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // The window launch whose boot failed reads its cause only after
        // another launch's claim has run (here one cut short by shutdown,
        // which has no error). A pool-wide "last error" would read nil.
        let pool = VMPool(config: VMConfig(), storageDir: dir, automaticallyReplenishes: false)
        let failed = await pool.claimResult(config: VMConfig())
        await pool.shutdown()
        let cutShort = await pool.claimResult(config: VMConfig())
        #expect(cutShort.vm == nil && cutShort.error == nil)
        #expect(failed.vm == nil)
        let error = try #require(failed.error as? SandboxError)
        guard case .baseImageNotFound = error else {
            Issue.record("expected baseImageNotFound, got \(error)")
            return
        }
    }

    @Test("Only network setup failures count as network failures")
    func networkFailureClassification() {
        #expect(SandboxError.isNetworkFailure(SandboxError.networkFilterFailed))
        #expect(!SandboxError.isNetworkFailure(SandboxError.macPoolExhausted))
        #expect(!SandboxError.isNetworkFailure(SandboxError.vmStartFailed("x")))
        #expect(!SandboxError.isNetworkFailure(nil))
    }
}
