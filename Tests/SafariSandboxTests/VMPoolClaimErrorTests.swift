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
        let warm = await pool.claim(config: VMConfig())
        #expect(warm == nil)
        let error = try #require(pool.lastClaimError as? SandboxError)
        guard case .baseImageNotFound = error else {
            Issue.record("expected baseImageNotFound, got \(error)")
            return
        }
        #expect(!SandboxError.isNetworkFailure(error))
    }

    @Test("Only network setup failures count as network failures")
    func networkFailureClassification() {
        #expect(SandboxError.isNetworkFailure(SandboxError.networkFilterFailed))
        #expect(!SandboxError.isNetworkFailure(SandboxError.macPoolExhausted))
        #expect(!SandboxError.isNetworkFailure(SandboxError.vmStartFailed("x")))
        #expect(!SandboxError.isNetworkFailure(nil))
    }
}
