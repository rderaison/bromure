import Foundation
import Testing
@testable import bromure_ac

@Suite("OpenShell policy revision history")
struct PolicyHistoryTests {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("policy-history-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("An identical save keeps the version; a change adds one; history lists both")
    func roundTrip() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = PolicyHistory.shared
        let a = "version: 1\nnetwork_policies: {}\n"
        let b = "version: 1\nnetwork_policies:\n  web:\n    endpoints: [{ host: example.com, port: 443 }]\n"
        let v1 = h.record(policy: a, source: "user", in: dir)
        let same = h.record(policy: a, source: "api", in: dir)
        #expect(v1.version == 1 && same.version == 1 && same.hash == v1.hash)
        let v2 = h.record(policy: b, source: "advisor", in: dir)
        #expect(v2.version == 2 && v2.hash != v1.hash && v2.source == "advisor")
        #expect(h.revisions(in: dir).map(\.version) == [1, 2])
        // Going back to an earlier text is a new version, not a rewind.
        #expect(h.record(policy: a, source: "restore", in: dir).version == 3)
    }

    @Test("History is capped; version numbers keep counting")
    func cap() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<(PolicyHistory.cap + 5) {
            PolicyHistory.shared.record(policy: "version: 1\n# \(i)\n", source: "user", in: dir)
        }
        let all = PolicyHistory.shared.revisions(in: dir)
        #expect(all.count == PolicyHistory.cap)
        #expect(all.last?.version == PolicyHistory.cap + 5)
    }

    @Test("Control-socket route: list newest first without text; one revision with its policy")
    func route() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        PolicyHistory.shared.record(policy: "version: 1\n# a\n", source: "user", in: dir)
        PolicyHistory.shared.record(policy: "version: 1\n# b\n", source: "api", in: dir)
        let (s, list) = ACAppDelegate.policyRevisionsRoute(directory: dir, method: "GET", sub: ["policy", "revisions"])
        let revs = try #require(list["revisions"] as? [[String: Any]])
        #expect(s == 200 && list["current"] as? Int == 2)
        #expect(revs.map { $0["version"] as? Int } == [2, 1] && revs[0]["policy"] == nil)
        let (s1, one) = ACAppDelegate.policyRevisionsRoute(directory: dir, method: "GET", sub: ["policy", "revisions", "1"])
        #expect(s1 == 200 && one["policy"] as? String == "version: 1\n# a\n")
        #expect(ACAppDelegate.policyRevisionsRoute(directory: dir, method: "GET", sub: ["policy", "revisions", "9"]).status == 404)
    }
}
