import Foundation
import Testing
@testable import bromure_ac

@Suite("NativeTerminal")
struct NativeTerminalTests {

    // MARK: Frame codec

    @Test("Resize payload is big-endian cols then rows")
    func resizePayload() {
        #expect(InteractiveExec.resizePayload(cols: 120, rows: 40) == [0, 120, 0, 40])
        #expect(InteractiveExec.resizePayload(cols: 300, rows: 75) == [1, 44, 0, 75])
        // Clamps instead of trapping on absurd values.
        #expect(InteractiveExec.resizePayload(cols: 70000, rows: -1) == [255, 255, 0, 0])
    }

    // MARK: Attach command (surface child)

    @Test("Surface attach command quotes the executable and targets the window")
    @MainActor
    func attachCommand() {
        let cmd = TerminalSessionController.attachCommand(vmID: "ABC-123", window: 4)
        #expect(cmd.contains("__attach-window"))
        #expect(cmd.contains("'ABC-123'"))
        #expect(cmd.hasSuffix(" 4"))
        // The exe path is single-quoted (the bundle path contains spaces).
        #expect(cmd.hasPrefix("'"))
    }

    // MARK: Profile toggle

    @Test("nativeTerminal round-trips and defaults to false for old JSON")
    func profileRoundTrip() throws {
        var p = Profile(name: "t", tool: .claude, authMode: .subscription)
        // Phase 3: native is the default for NEW workspaces…
        #expect(p.nativeTerminal)
        p.nativeTerminal = true
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Profile.self, from: data)
        #expect(back.nativeTerminal)

        // Old profiles (no key) decode to false — the framebuffer default.
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "nativeTerminal")
        let old = try JSONDecoder().decode(
            Profile.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!old.nativeTerminal)
    }

    // MARK: Guest view-attach command builder (shell-agent.py)

    /// Run a python snippet against the real guest agent source and return
    /// stdout. The agent is plain python3 with no third-party deps, so the
    /// host interpreter exercises the exact code the guest runs.
    private func runAgentSnippet(_ snippet: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AgentCodingTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let agent = root.appendingPathComponent(
            "Sources/AgentCoding/Resources/vm-setup/shell-agent.py").path
        let program = """
        import importlib.util
        spec = importlib.util.spec_from_file_location("sa", "\(agent)")
        sa = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(sa)
        \(snippet)
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-c", program]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("View attach builds a grouped session and selects the window")
    func viewAttachCommand() throws {
        let cmd = try runAgentSnippet(
            #"print(sa._view_attach_command("Deadbeef-1", 7))"#)
        #expect(cmd.contains("new-session -t bromure -s view-Deadbeef-1"))
        #expect(cmd.contains("destroy-unattached on"))
        #expect(cmd.contains("status off"))
        #expect(cmd.contains("aggressive-resize on"))
        #expect(cmd.contains("allow-passthrough on"))
        #expect(cmd.contains("mouse off"))
        #expect(cmd.contains("set-clipboard on"))
        #expect(cmd.contains("select-window -t :7"))
        // Bootstraps the bromure session if it isn't up yet (boot race).
        #expect(cmd.contains("has-session -t bromure"))
    }

    @Test("View attach sanitizes hostile ids and survives a missing window")
    func viewAttachSanitizes() throws {
        let cmd = try runAgentSnippet(
            #"print(sa._view_attach_command("x; rm -rf /;", None))"#)
        // Shell metacharacters are stripped from the session name…
        #expect(cmd.contains("-s view-xrm-rf"))
        #expect(!cmd.contains("rm -rf /"))
        // …and no select-window without an index.
        #expect(!cmd.contains("select-window"))
    }

    @Test("Empty view id falls back to a random session name")
    func viewAttachEmptyID() throws {
        let cmd = try runAgentSnippet(
            #"print(sa._view_attach_command("!!!", None))"#)
        #expect(cmd.contains("-s view-"))
        // The fallback name has content after "view-".
        let name = try #require(cmd.components(separatedBy: "-s view-").last?
            .components(separatedBy: " ").first)
        #expect(!name.isEmpty)
    }
}
