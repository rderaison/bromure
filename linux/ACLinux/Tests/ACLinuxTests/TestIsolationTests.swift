import Foundation
import Testing
@testable import ACLinux

/// A test run never touches the user's own files: the proxy's subscription
/// stores live beside a test's CA, and the shared stores that write the
/// support folder (the Security Timeline, ...) know they're under test.
@Suite("Test isolation")
struct TestIsolationTests {
    @Test func aTestRunIsRecognized() {
        #expect(isTestRun())
    }

    /// A test's proxy keeps its logins beside its CA: the user's real
    /// `claude-subscription.enc` is never read with a test's vault key (each
    /// such read left an `.unreadable-…` copy beside it) nor written.
    @Test func aTestProxysLoginsStayBesideItsCA() throws {
        let dir = try shortTempDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BromureAC/claude-subscription.enc")
        let before = try? FileManager.default.attributesOfItem(atPath: real.path)[.modificationDate] as? Date
        try SecretsVault.withInstance(directory: dir + "/secrets") {
            let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
            try proxy.claudeStore.setShared(ClaudeSubscriptionRecord(
                accessToken: "sk-ant-oat01-test-only", refreshToken: "sk-ant-ort01-test-only",
                expiresAt: Date().addingTimeInterval(3600), savedAt: Date()))
            #expect(proxy.claudeStore.record(for: nil)?.accessToken == "sk-ant-oat01-test-only")
        }
        #expect(FileManager.default.fileExists(atPath: dir + "/mitm/subscriptions/claude-subscription.enc"))
        let after = try? FileManager.default.attributesOfItem(atPath: real.path)[.modificationDate] as? Date
        #expect(before == after, "the user's own store untouched")
    }
}
