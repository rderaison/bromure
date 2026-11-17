import Foundation
import Testing
@testable import bromure_ac

/// Hermes sessions: resumed by their own session id, and their chat read
/// from that session's mirrored transcript. Hermes's `-c` takes the newest
/// session in the whole Hermes home (outside a git repo): a relaunched tab
/// picked up a session begun from `/` in another tab, and the chat view —
/// looking in the folder named after the tab's cwd — showed none of the
/// replies.
@Suite("Hermes sessions")
struct HermesSessionTests {
    private let sid = "local-147a006f46b39fbd692517c969fd37fbc8ff2c0c971f28d8cef9931516972193"

    @Test("Hermes session ids: what its hook names transcripts by, and nothing a shell would read")
    func ids() {
        #expect(AgentSessionLocator.isHermesSessionID(sid))
        #expect(AgentSessionLocator.isHermesSessionID("20261117_140352_ab12cd"))
        for bad in ["", "-c", ".hidden", "a b", "a;rm", "a/b", "x..y", "$(id)", "abc", "local-*",
                    String(repeating: "a", count: 129)] {
            #expect(!AgentSessionLocator.isHermesSessionID(bad), "\(bad)")
        }
    }

    @Test("A Hermes session resumes its own session by id")
    @MainActor func resumeByID() {
        var s = AgentSession(profileID: UUID(), tool: .hermes, title: "t")
        #expect(AgentSessionEngine.resumeFlags(for: s) == "-c")
        #expect(AgentSessionEngine.resumeFlags(for: s, sharedFolder: true) == "")
        s.agentTranscriptID = sid
        #expect(AgentSessionEngine.resumeFlags(for: s) == "--resume \(sid)")
        #expect(AgentSessionEngine.resumeFlags(for: s, sharedFolder: true) == "--resume \(sid)")
        s.agentTranscriptID = "-c; rm -rf ~"
        #expect(AgentSessionEngine.resumeFlags(for: s) == "-c")
    }

    @Test("The probe's transcript name is the Hermes tab's session id; other agents keep UUIDs")
    @MainActor func probe() {
        let lines = AgentSessionEngine.parseProbe("1\thermes\t\(sid)\tHello\n2\tclaude\t\(sid)\tx\n")
        #expect(lines.count == 2)
        #expect(lines[0].transcriptID(for: .hermes) == sid)
        #expect(lines[1].transcriptID(for: .claude) == nil)
        #expect(lines[0].transcriptID(for: .claude) == nil)
    }

    @Test("A pinned Hermes session reads its own transcript, in whichever folder")
    func pinnedRead() {
        let pin = TranscriptPin.conversation(tool: "hermes", id: sid)
        #expect(pin.hermesSession == sid)
        let cmd = AgentSessionLocator.locatePrefix(path: "/home/ubuntu", since: 0, agent: "hermes",
                                                   pinnedWindow: 1, pin: pin)
        #expect(cmd.contains("f=$(ls -t \"$HOME/.hermes/bromure-transcripts\"/*/\(sid).jsonl"))
        #expect(cmd.contains("[ -z \"$f\" ] && pe=1; "), "never the folder's newest instead")
        // Unpinned: as before.
        let loose = AgentSessionLocator.locatePrefix(path: "/home/ubuntu", since: 0, agent: "hermes",
                                                     pinnedWindow: 1)
        #expect(!loose.contains("/*/"))
        #expect(TranscriptPin.conversation(tool: "hermes", id: "../x").hermesSession == nil)
    }

    /// A "Hermes's" in a comment inside agent-status.sh's single-quoted
    /// `python3 -c '…'` closed the quote: bash stopped at a syntax error,
    /// so no agent's turn status or transcript record was ever written.
    @Test("the staged hook scripts and .bashrc parse (bash -n)")
    func scriptsParse() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-sh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDir: root)
        let p = Profile(name: "ws", tool: .hermes, authMode: .token)
        let seed = root.appendingPathComponent("seed")
        try store.writeHomeSeedFiles(for: p, into: seed, terminalDefaults: .fallback)
        let files = seed.appendingPathComponent("files")
        var checked = 0
        for rel in [".bromure/agent-status.sh", ".bashrc"] {
            let url = files.appendingPathComponent(rel)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = ["-n", url.path]
            let err = Pipe()
            proc.standardError = err
            try proc.run(); proc.waitUntilExit()
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            #expect(proc.terminationStatus == 0, "\(rel): \(msg)")
            checked += 1
        }
        #expect(checked == 2)
    }
}
