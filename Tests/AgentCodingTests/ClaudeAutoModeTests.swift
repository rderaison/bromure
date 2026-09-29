import Foundation
import Testing
@testable import bromure_ac

@Suite("Claude auto-mode environment")
struct ClaudeAutoModeTests {

    @Test("Bromure's entries, then one per line of the user's description, all tagged")
    func entries() {
        let env = ClaudeAutoMode.environment(userText: "Organization: Acme\n\n  Source control: github.com/acme  \n")
        #expect(env.count == 4)
        #expect(env[0].hasPrefix("Host containment:"))
        #expect(env[2] == "Organization: Acme \(ClaudeAutoMode.tag)")
        #expect(env[3] == "Source control: github.com/acme \(ClaudeAutoMode.tag)")
        #expect(env.allSatisfy { $0.hasSuffix(ClaudeAutoMode.tag) })
    }

    @Test("merge: a fresh list keeps the defaults; ours are replaced, the user's kept")
    func merge() {
        let managed = ClaudeAutoMode.environment(userText: "")
        let fresh = ClaudeAutoMode.merged(nil, managed: managed)
        #expect(fresh.first as? String == "$defaults")
        #expect(fresh.count == 1 + managed.count)

        // A later launch with a different description: the old managed
        // entries go, the user's hand-written one and their $defaults choice stay.
        let existing: [Any] = ["Trusted cloud buckets: s3://acme", "Old line \(ClaudeAutoMode.tag)"] + managed
        let next = ClaudeAutoMode.merged(existing, managed: ClaudeAutoMode.environment(userText: "New line"))
        let strings = next.compactMap { $0 as? String }
        #expect(strings.first == "Trusted cloud buckets: s3://acme")
        #expect(!strings.contains("$defaults"))
        #expect(!strings.contains("Old line \(ClaudeAutoMode.tag)"))
        #expect(strings.last == "New line \(ClaudeAutoMode.tag)")
        #expect(strings.filter { $0.hasPrefix("Host containment:") }.count == 1)
    }

    @Test("settings from before the field decode with an empty environment")
    func tolerantDecode() throws {
        let old = "{}"   // every key missing, as before the field existed
        let s = try JSONDecoder().decode(ModelSettings.self, from: Data(old.utf8))
        #expect(s.agentEnvironment == "")
        var t = s
        t.agentEnvironment = "Organization: Acme"
        let round = try JSONDecoder().decode(ModelSettings.self, from: JSONEncoder().encode(t))
        #expect(round.agentEnvironment == "Organization: Acme")
    }
}
