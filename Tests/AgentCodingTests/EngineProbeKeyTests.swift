import Foundation
import Testing
@testable import bromure_ac

/// A fat client's "Test Connection" sends its redacted copy of the key; the
/// host substitutes the key it stores — only for that exact server, so a
/// client can't send a stored key to a URL of its choosing.
@Suite("custom-server probe key lookup")
struct EngineProbeKeyTests {
    private func base(_ s: String) -> URL { Profile.normalizedEngineBase(s)! }

    @Test("the stored key for the same server, however its URL is spelled")
    func sameServer() {
        let c: [(url: String?, key: String?)] = [("http://10.0.0.5:8000/v1/", "sk-real")]
        #expect(ACAppDelegate.engineKey(for: base("10.0.0.5:8000"), among: c) == "sk-real")
        #expect(ACAppDelegate.engineKey(for: base("http://10.0.0.5:8000/v1"), among: c) == "sk-real")
    }

    @Test("never a key stored for another server")
    func otherServer() {
        let c: [(url: String?, key: String?)] = [("http://10.0.0.5:8000", "sk-real")]
        #expect(ACAppDelegate.engineKey(for: base("http://evil.example:8000"), among: c) == nil)
        #expect(ACAppDelegate.engineKey(for: base("http://10.0.0.5:8001"), among: c) == nil)
    }

    @Test("blank or redacted stored keys are skipped")
    func skipsBlank() {
        let c: [(url: String?, key: String?)] = [("http://h:1", nil), ("http://h:1", ""),
                                                  ("http://h:1", ModelSettings.redactedSecret), ("http://h:1", "sk-2")]
        #expect(ACAppDelegate.engineKey(for: base("http://h:1"), among: c) == "sk-2")
    }
}
