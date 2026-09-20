import Foundation
import Testing
@testable import bromure_ac

// The engine asks each running workspace whether its live sessions' folders
// carry changes — git's word inside a repository, a file newer than the
// session's start elsewhere — and the windows pop the Files pane on the
// first dirty verdict. The probe is one shell round-trip per workspace,
// keyed by session id; the parser turns its lines back into verdicts.

@Suite("Session changes probe")
@MainActor
struct SessionChangesProbeTests {

    @Test("the probe asks git inside a repository and mtimes elsewhere")
    func commandShape() {
        let since = Date(timeIntervalSince1970: 1_758_300_000)
        let cmd = AgentSessionEngine.changesProbeCommand([
            (key: "A", path: "/home/ubuntu/proj", since: since),
            (key: "B", path: "/home/ubuntu/it's here", since: since),
        ])
        // Inside a repository: status of the folder's subtree, untracked
        // included (porcelain), ignored files left out.
        #expect(cmd.contains("git -C \"$p\" rev-parse --is-inside-work-tree"))
        #expect(cmd.contains("git -C \"$p\" status --porcelain -- ."))
        // Elsewhere: the first file written since the session began, hidden
        // folders and node_modules pruned, capped so a huge tree can't hang
        // the probe.
        #expect(cmd.contains("-newermt '@1758300000'"))
        #expect(cmd.contains("-name '.*' -o -name node_modules"))
        #expect(cmd.contains("timeout 8 find"))
        #expect(cmd.contains("-print -quit"))
        // Each target answers on its own line under its key.
        #expect(cmd.contains("printf '%s\\t%s\\n' 'A'"))
        #expect(cmd.contains("printf '%s\\t%s\\n' 'B'"))
        // A quote in the path can't break out of the shell string.
        #expect(cmd.contains("p='/home/ubuntu/it'\\''s here'"))
    }

    @Test("verdicts: 1 is dirty, an empty answer is clean, junk is ignored")
    func parse() {
        let out = "A\t1\nB\t\nnoise\nC\t1\n\n"
        let verdicts = AgentSessionEngine.parseChangesProbe(out)
        #expect(verdicts["A"] == true)
        #expect(verdicts["B"] == false)
        #expect(verdicts["C"] == true)
        // A line without a verdict column is a clean verdict for that key,
        // never a dirty one.
        #expect(verdicts["noise"] == false)
        #expect(verdicts.count == 4)
    }

    @Test("changesSeenAt rides the session record through JSON")
    func codable() throws {
        var s = AgentSession(profileID: UUID(), tool: .claude, title: "Login flow",
                             cwd: "~/proj", windowIndex: 1)
        s.changesSeenAt = Date(timeIntervalSince1970: 1_758_300_000)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(AgentSession.self, from: enc.encode(s))
        #expect(back.changesSeenAt == s.changesSeenAt)
        // An older record (no field) still reads: nothing to pop for.
        let legacy = try dec.decode(AgentSession.self, from: Data("""
        {"id":"\(UUID().uuidString)","profileID":"\(UUID().uuidString)","tool":"claude",
         "title":"Old","cwd":"~","createdAt":"2026-09-19T10:00:00Z"}
        """.utf8))
        #expect(legacy.changesSeenAt == nil)
    }
}
