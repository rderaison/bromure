import Foundation
import Testing
@testable import bromure_ac

/// Oh My Pi (`omp`) as a first-class agent: the generated guest `.bashrc`
/// must stay valid shell and carry omp's launch/install wiring; the
/// provider-agnostic plumbing (per-provider env var + swap host + fake-key
/// mint, model resolution) must behave; and its JSONL session format must
/// parse into transcript items.
@Suite("Oh My Pi (omp) agent support")
struct OmpAgentTests {

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("omp-agent-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func renderBashrc(tool: Profile.Tool) throws -> String {
        let root = try tempDir()
        let store = ProfileStore(rootDir: root)
        let p = Profile(name: "ws", tool: tool, authMode: .token)
        let seedDir = root.appendingPathComponent("seed")
        try store.writeHomeSeedFiles(for: p, into: seedDir, terminalDefaults: .fallback)
        return try String(
            contentsOf: seedDir.appendingPathComponent("files/.bashrc"), encoding: .utf8)
    }

    // MARK: - Guest script

    @Test("Generated .bashrc (omp primary) is valid shell")
    func bashrcParses() throws {
        let rc = try renderBashrc(tool: .omp)
        let url = try tempDir().appendingPathComponent("bashrc")
        try rc.write(to: url, atomically: true, encoding: .utf8)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-n", url.path]
        let err = Pipe(); proc.standardError = err
        try proc.run()
        let diag = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        proc.waitUntilExit()
        #expect(proc.terminationStatus == 0, "bash -n rejected .bashrc:\n\(diag)")
    }

    @Test("bashrc carries omp launch, install, PATH and models.yml wiring")
    func bashrcHasOmpWiring() throws {
        let rc = try renderBashrc(tool: .omp)
        // Launch: omp branch passes --model from the staged meta file.
        #expect(rc.contains("elif [ \"$_wt_tool\" = \"omp\" ]; then"))
        #expect(rc.contains("/mnt/bromure-meta/omp-model"))
        #expect(rc.contains("--model \"$_omp_model\""))
        // bun must be on PATH (omp's runtime) and installable via the fallback.
        #expect(rc.contains("$HOME/.bun/bin"))
        #expect(rc.contains("@oh-my-pi/pi-coding-agent"))
        #expect(rc.contains("https://bun.sh/install"))
        // models.yml copy for custom / local providers.
        #expect(rc.contains("/mnt/bromure-meta/omp-models.yml"))
        #expect(rc.contains("$HOME/.omp/agent/models.yml"))
    }

    @Test("bashrc merges the browser/user MCP into omp's user config folder")
    func bashrcWiresBrowserMCP() throws {
        // omp reads user-scope MCP from ~/.omp/agent/mcp.json (NOT ~/.claude.json),
        // so the built-in `browser` server (staged in mcp/claude.json) must be
        // merged there — otherwise omp launches without the embedded-browser MCP.
        let rc = try renderBashrc(tool: .omp)
        #expect(rc.contains("/mnt/bromure-meta/mcp/claude.json"))
        #expect(rc.contains(".omp/agent/mcp.json"))
    }

    @Test("Status reporter ships for omp too")
    func statusScriptSeeded() throws {
        let root = try tempDir()
        let store = ProfileStore(rootDir: root)
        let p = Profile(name: "ws", tool: .omp, authMode: .token)
        let seedDir = root.appendingPathComponent("seed")
        try store.writeHomeSeedFiles(for: p, into: seedDir, terminalDefaults: .fallback)
        #expect(FileManager.default.fileExists(
            atPath: seedDir.appendingPathComponent("files/.bromure/agent-status.sh").path))
    }

    // MARK: - Provider plumbing

    @Test("Each provider maps to its env var and API host")
    func providerMapping() {
        #expect(Profile.OmpProvider.anthropic.apiKeyEnvVar == "ANTHROPIC_API_KEY")
        #expect(Profile.OmpProvider.anthropic.apiHost == "api.anthropic.com")
        #expect(Profile.OmpProvider.openai.apiKeyEnvVar == "OPENAI_API_KEY")
        #expect(Profile.OmpProvider.openai.apiHost == "api.openai.com")
        #expect(Profile.OmpProvider.xai.apiKeyEnvVar == "XAI_API_KEY")
        #expect(Profile.OmpProvider.xai.apiHost == "api.x.ai")
        #expect(Profile.OmpProvider.zai.apiKeyEnvVar == "ZAI_API_KEY")
        #expect(Profile.OmpProvider.custom.apiKeyEnvVar == "OPENAI_API_KEY")
        #expect(Profile.OmpProvider.custom.apiHost == "")  // derived from base URL
    }

    @Test("omp has no OAuth subscription; a new omp profile defaults to API key")
    func noSubscription() throws {
        // A new omp profile from the template is coerced to .token (omp has no
        // OAuth subscription, so the template's subscription default is wrong).
        let store = ProfileStore(rootDir: try tempDir())
        let p = store.newProfileFromTemplate(name: "x", tool: .omp)
        #expect(p.authMode == .token)
    }

    @Test("resolvedOmpModel: provider default, explicit override, local sentinel")
    func modelResolution() {
        let anth = Profile.ToolSpec(tool: .omp, authMode: .token, apiKey: "k")
        #expect(anth.resolvedOmpModel(localSentinel: "L") == "sonnet")
        let oai = Profile.ToolSpec(tool: .omp, authMode: .token, apiKey: "k",
                                   ompProvider: .openai)
        #expect(oai.resolvedOmpModel(localSentinel: "L") == "gpt-5.2")
        let override = Profile.ToolSpec(tool: .omp, authMode: .token, apiKey: "k",
                                        ompModel: "opus")
        #expect(override.resolvedOmpModel(localSentinel: "L") == "opus")
        let local = Profile.ToolSpec(tool: .omp, authMode: .local, localModelID: "")
        #expect(local.resolvedOmpModel(localSentinel: "L") == "L")
    }

    @Test("Token plan mints an omp fake shaped for the selected provider")
    func fakeKeyMint() {
        let salt = Data("salt".utf8)
        // Default (Anthropic): sk-ant-api03-brm- shape.
        var p = Profile(name: "ws", tool: .omp, authMode: .token)
        p.apiKey = "sk-ant-api03-realkey"
        let anthFake = p.makeTokenPlan(salt: salt).fakeForOmp()
        #expect(anthFake?.hasPrefix("sk-ant-api03-brm-") == true)
        // Switched to xAI: xai-brm- shape.
        p.ompProvider = .xai
        p.apiKey = "xai-realkey"
        let xaiFake = p.makeTokenPlan(salt: salt).fakeForOmp()
        #expect(xaiFake?.hasPrefix("xai-brm-") == true)
    }

    // MARK: - Transcript

    @Test("OmpTranscriptParser reads omp's JSONL session format")
    func transcriptParse() {
        let jsonl = """
        {"type":"title","v":1,"title":"t","updatedAt":"2026-08-25T02:09:14.000Z"}
        {"type":"session","version":3,"id":"abc","timestamp":"2026-08-25T02:09:14.000Z","cwd":"/tmp"}
        {"type":"model_change","id":"m1","timestamp":"2026-08-25T02:09:14.024Z","model":"anthropic/claude-sonnet-4-0"}
        {"type":"message","id":"u1","timestamp":"2026-08-25T02:09:14.046Z","message":{"role":"user","content":[{"type":"text","text":"list files"}]}}
        {"type":"message","id":"a1","timestamp":"2026-08-25T02:09:15.046Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"let me look"},{"type":"text","text":"Running ls"},{"type":"tool_use","id":"t1","name":"bash","input":{"command":"ls -la"}}]}}
        {"type":"message","id":"u2","timestamp":"2026-08-25T02:09:16.046Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"file.txt","is_error":false}]}}
        {"type":"custom","customType":"session_exit","data":{"reason":"dispose"},"id":"c1","timestamp":"2026-08-25T02:09:17.046Z"}
        """
        let items = AgentTranscript.parse(Data(jsonl.utf8), agent: "omp")
        // user text, thinking, assistant text, tool_use, tool_result = 5.
        #expect(items.count == 5)
        if case .userText(let s) = items[0].kind { #expect(s == "list files") }
        else { Issue.record("item0 not userText: \(items[0].kind)") }
        if case .thinking = items[1].kind {} else { Issue.record("item1 not thinking") }
        if case .assistantText(let s) = items[2].kind { #expect(s == "Running ls") }
        else { Issue.record("item2 not assistantText") }
        if case .toolUse(let name, let summary, _) = items[3].kind {
            #expect(name == "bash"); #expect(summary == "ls -la")
        } else { Issue.record("item3 not toolUse") }
        if case .toolResult(let tool, let content, let isErr) = items[4].kind {
            #expect(tool == "bash"); #expect(content == "file.txt"); #expect(isErr == false)
        } else { Issue.record("item4 not toolResult") }
    }

    @Test("sniff() recognizes omp session files without an explicit agent")
    func sniffOmp() {
        let jsonl = """
        {"type":"session","version":3,"id":"abc","timestamp":"2026-08-25T02:09:14.000Z","cwd":"/tmp"}
        {"type":"message","id":"u1","timestamp":"2026-08-25T02:09:14.046Z","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}
        """
        #expect(AgentTranscript.sniff(Data(jsonl.utf8)) == "omp")
    }

    // MARK: - Install catalog

}
