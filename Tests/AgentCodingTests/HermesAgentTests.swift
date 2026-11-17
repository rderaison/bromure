import Foundation
import Testing
@testable import bromure_ac

/// Hermes Agent (Nous Research, the `hermes` CLI) as a coding agent: the
/// guest `.bashrc` installs, configures and launches it; its provider key
/// reaches it only as a stand-in the proxy swaps on that provider's host, in
/// a variable no sibling agent shares; the settings it runs on (provider,
/// model, MCP servers, no borrowed logins) are applied with its own
/// `hermes config`; and its integrations' keys are ready-made credentials.
@Suite("Hermes Agent support")
struct HermesAgentTests {

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hermes-agent-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func renderBashrc(tool: Profile.Tool = .hermes) throws -> String {
        let root = try tempDir()
        let store = ProfileStore(rootDir: root)
        let p = Profile(name: "ws", tool: tool, authMode: .token)
        let seedDir = root.appendingPathComponent("seed")
        try store.writeHomeSeedFiles(for: p, into: seedDir, terminalDefaults: .fallback)
        return try String(contentsOf: seedDir.appendingPathComponent("files/.bashrc"), encoding: .utf8)
    }

    @discardableResult
    private func run(_ exe: String, _ args: [String], env: [String: String] = [:]) throws -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        var e = ProcessInfo.processInfo.environment
        for (k, v) in env { e[k] = v }
        proc.environment = e
        let err = Pipe(); proc.standardError = err
        try proc.run(); proc.waitUntilExit()
        return (proc.terminationStatus, String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    // MARK: - Guest script

    @Test("the generated .bashrc is valid shell and carries Hermes's install, wrapper and launch")
    func bashrc() throws {
        let rc = try renderBashrc()
        let url = try tempDir().appendingPathComponent("bashrc")
        try rc.write(to: url, atomically: true, encoding: .utf8)
        let (status, diag) = try run("/bin/bash", ["-n", url.path])
        #expect(status == 0, "bash -n rejected .bashrc:\n\(diag)")
        // Installed per user, on first use, without the setup wizard.
        #expect(rc.contains("https://hermes-agent.nousresearch.com/install.sh"))
        #expect(rc.contains("--non-interactive --skip-browser --skip-computer-use"))
        // The wrapper: settings applied, other providers' keys unset, its own
        // key handed over under its provider's variable.
        #expect(rc.contains("hermes() {"))
        #expect(rc.contains("if ! type -P hermes >/dev/null 2>&1; then"))
        #expect(rc.contains("/mnt/bromure-meta/hermes-env-unset"))
        #expect(rc.contains("\"$_k=$BROMURE_HERMES_API_KEY\" hermes \"$@\""))
        // A task's opening message: `chat --query=`, flags before the subcommand.
        #expect(rc.contains("\"$_wt_tool\" $_wt_flags chat --query=\"$_wt_prompt\""))
    }

    /// The settings step the wrapper runs, lifted out of the .bashrc and run
    /// against a stand-in `hermes` that logs each `hermes config …` call.
    private func runApply(settings: [String: Any], servers: [String: Any],
                          home: URL, failing: Bool = false) throws -> [String] {
        let rc = try renderBashrc()
        let lines = rc.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex { $0.contains("<<'BROMURE_HERMES_APPLY'") })
        let end = try #require(lines[(start + 1)...].firstIndex { $0 == "BROMURE_HERMES_APPLY" })
        let script = lines[(start + 1)..<end].joined(separator: "\n")
        let dir = try tempDir()
        let meta = dir.appendingPathComponent("meta")
        try FileManager.default.createDirectory(at: meta.appendingPathComponent("mcp"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: settings).write(to: meta.appendingPathComponent("hermes-settings.json"))
        try JSONSerialization.data(withJSONObject: ["mcpServers": servers])
            .write(to: meta.appendingPathComponent("mcp/claude.json"))
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("calls.log")
        let fake = bin.appendingPathComponent("hermes")
        // `config unset` of an absent key fails as Hermes's does.
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(log.path)'
        \(failing ? "exit 1" : "")
        if [ "$2" = unset ]; then echo "Config key not set: $3" >&2; exit 1; fi
        exit 0
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        let (status, diag) = try run("/usr/bin/python3", ["-c", script, "HASH"], env: [
            "HOME": home.path, "BROMURE_META_DIR": meta.path,
            "PATH": bin.path + ":/usr/bin:/bin",
        ])
        #expect(status == 0, Comment(rawValue: diag))
        return ((try? String(contentsOf: log, encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init)
    }

    @Test("the settings step sets the provider, turns off borrowed logins, mirrors the MCP servers, drops stale ones")
    func applySettings() throws {
        let home = try tempDir()
        let calls = try runApply(
            settings: ["model": ["provider": "custom", "base_url": "https://llm.example/v1",
                                 "key_env": "OPENAI_API_KEY", "default": "big"],
                       "adopt_external_logins": false, "key_var": "OPENAI_API_KEY"],
            servers: ["browser": ["command": "python3", "args": ["/mnt/bromure-meta/bromure-browser-mcp.py"]],
                      "docs.v2": ["type": "http", "url": "https://mcp.example/x", "headers": ["X-K": "${K}"]]],
            home: home)
        #expect(calls.first == "config set model.provider custom")
        #expect(calls.contains("config set model.base_url https://llm.example/v1"))
        #expect(calls.contains("config set model.key_env OPENAI_API_KEY"))
        #expect(calls.contains("config set model.default big"))
        #expect(calls.contains("config set auth.adopt_external_logins false"))
        #expect(calls.contains { $0.hasPrefix("config set mcp_servers.browser {") && $0.contains("bromure-browser-mcp.py") })
        // A dotted server name is escaped for Hermes's dotted paths.
        #expect(calls.contains { $0.hasPrefix("config set mcp_servers.docs\\.v2 {\"url\": \"https://mcp.example/x\"") })
        let marker = home.appendingPathComponent(".hermes/.bromure-applied")
        #expect((try? String(contentsOf: marker, encoding: .utf8)) == "HASH")

        // Next time: a cloud provider (no base URL any more), one server gone.
        try FileManager.default.removeItem(at: marker)
        let again = try runApply(settings: ["model": ["provider": "anthropic"], "key_var": "ANTHROPIC_API_KEY"],
                                 servers: ["browser": ["command": "python3", "args": ["x"]]], home: home)
        #expect(again.contains("config set model.provider anthropic"))
        #expect(again.contains("config unset model.base_url"))
        #expect(again.contains("config unset model.key_env"))
        #expect(!again.contains { $0.hasPrefix("config set model.default") })
        #expect(again.contains("config unset mcp_servers.docs\\.v2"))
        #expect(!again.contains("config unset mcp_servers.browser"))
        // Unsetting what was never set doesn't hold the settings back.
        #expect((try? String(contentsOf: marker, encoding: .utf8)) == "HASH")
    }

    @Test("a failed `hermes config` leaves the settings to be applied again")
    func applyFailureRetries() throws {
        let home = try tempDir()
        _ = try runApply(settings: ["model": ["provider": "xai"]], servers: [:], home: home, failing: true)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".hermes/.bromure-applied").path))
    }

    // MARK: - Host side

    @Test("the staged settings follow the provider Hermes is switched to")
    func settings() throws {
        var p = Profile(name: "ws", tool: .hermes, authMode: .token, apiKey: "k")
        var s = try #require(SessionDisk.hermesSettings(profile: p))
        #expect((s["model"] as? [String: String]) == ["provider": "anthropic"])
        #expect(s["adopt_external_logins"] as? Bool == false)
        #expect(s["key_var"] as? String == "ANTHROPIC_API_KEY")

        p.ompProvider = .openai
        p.ompModel = "gpt-5.5"
        s = try #require(SessionDisk.hermesSettings(profile: p))
        #expect((s["model"] as? [String: String]) == ["provider": "openai-api", "default": "gpt-5.5"])
        #expect(s["key_var"] as? String == "OPENAI_API_KEY")

        p.ompProvider = .custom
        p.ompBaseURL = "https://llm.example/v1"
        s = try #require(SessionDisk.hermesSettings(profile: p))
        #expect((s["model"] as? [String: String])?["base_url"] == "https://llm.example/v1")
        #expect((s["model"] as? [String: String])?["key_env"] == "OPENAI_API_KEY")
        // Custom with no base URL: nothing Hermes could run on.
        p.ompBaseURL = nil
        #expect(SessionDisk.hermesSettings(profile: p) == nil)

        var local = Profile(name: "l", tool: .claude, authMode: .token)
        local.additionalTools = [Profile.ToolSpec(tool: .hermes, authMode: .local, localModelID: "qwen")]
        let ls = try #require(SessionDisk.hermesSettings(profile: local))
        let m = try #require(ls["model"] as? [String: String])
        #expect(m["provider"] == "custom" && m["key_env"] == "OPENAI_API_KEY")
        #expect(m["base_url"] == "https://\(InferenceService.localMitmHost)/v1")
        #expect(SessionDisk.hermesSettings(profile: Profile(name: "c", tool: .claude, authMode: .token)) == nil)
    }

    @Test("Hermes's key is a stand-in, swapped only on its provider's host")
    func tokenPlan() throws {
        let salt = Data("salt".utf8)
        var p = Profile(name: "ws", tool: .claude, authMode: .token, apiKey: "sk-ant-api03-claude")
        var h = Profile.ToolSpec(tool: .hermes, authMode: .token, apiKey: "sk-openai-real")
        h.ompProvider = .openai
        p.additionalTools = [h]
        let plan = p.makeTokenPlan(salt: salt)
        let fake = try #require(plan.fakeForHermes())
        #expect(fake != "sk-openai-real" && fake.hasPrefix("sk-brm-"))
        let entry = try #require(plan.entries.first { $0.fakeValue == fake })
        guard case .hermesAPIKey(let host) = entry.purpose else {
            Issue.record("not a Hermes purpose: \(entry.purpose)"); return
        }
        #expect(host == "api.openai.com")
        #expect(plan.credentialHostScopes.contains("api.openai.com"))
        // Claude's own key keeps its own stand-in.
        #expect(plan.fakeForAnthropic() != nil && plan.fakeForAnthropic() != fake)
        // An Anthropic-switched Hermes gets an Anthropic-shaped stand-in:
        // Hermes sends `sk-ant-api…` keys as x-api-key.
        var a = Profile(name: "a", tool: .hermes, authMode: .token, apiKey: "sk-ant-api03-real")
        a.ompProvider = .anthropic
        #expect(a.makeTokenPlan(salt: salt).fakeForHermes()?.hasPrefix("sk-ant-api03-brm-") == true)
    }

    @Test("every other provider's key is hidden from Hermes; its own variable and integration keys aren't")
    func hiddenKeys() {
        var p = Profile(name: "ws", tool: .hermes, authMode: .token, apiKey: "k")
        p.ompProvider = .xai
        let hidden = SessionDisk.hermesHiddenKeyEnvVars(profile: p)
        #expect(!hidden.contains("XAI_API_KEY"))
        for v in ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "ZAI_API_KEY", "MOONSHOT_API_KEY",
                  "OPENROUTER_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_AUTH_TOKEN"] {
            #expect(hidden.contains(v), "\(v) not hidden")
        }
        #expect(!hidden.contains("FIRECRAWL_API_KEY") && !hidden.contains("FAL_KEY"))
        #expect(SessionDisk.hermesHiddenKeyEnvVars(profile: Profile(name: "c", tool: .claude, authMode: .token)).isEmpty)
    }

    @Test("Hermes isn't a Fusion leg, has no subscription, and switches provider like omp")
    func agentTraits() {
        let p = Profile(name: "ws", tool: .hermes, authMode: .token, apiKey: "k")
        #expect(!p.hasUsableCredential(for: .hermes))
        #expect(Profile.Tool.hermes.switchesProvider && Profile.Tool.omp.switchesProvider)
        #expect(!Profile.Tool.claude.switchesProvider)
        #expect(ModelAgent.from(.hermes) == .hermes && ModelAgent.hermes.nativeCloudProvider == nil)
        #expect(ModelProvider.zai.canRoute(.hermes, native: .anthropic))
        #expect(BromureIcons.agentKind(forLabel: "Fix the build (hermes)") == "hermes")
    }

    @Test("integration presets: unique variables, scoped hosts, a usable credential once the key is pasted")
    func integrationPresets() {
        let presets = ManualToken.hermesIntegrationPresets
        #expect(Set(presets.map(\.envVarName)).count == presets.count)
        for p in presets {
            #expect(!p.hosts.isEmpty && p.hosts.allSatisfy { !$0.contains("/") && $0.contains(".") })
        }
        var firecrawl = try! #require(presets.first { $0.envVarName == "FIRECRAWL_API_KEY" }).token
        #expect(firecrawl.hostFilters == ["firecrawl.dev"] && !firecrawl.isUsable)
        firecrawl.realValue = "fc-real"
        var ws = Profile(name: "ws", tool: .hermes, authMode: .token)
        ws.manualTokens = [firecrawl]
        let plan = ws.makeTokenPlan(salt: Data("s".utf8))
        let export = plan.manualEnvExports.first { $0.0 == "FIRECRAWL_API_KEY" }
        #expect(export != nil && export?.1 != "fc-real")
        #expect(plan.credentialHostScopes.contains("firecrawl.dev"))
    }

    @Test("agentd: Hermes auto-approves with --yolo, resumes with -c, and names its tab")
    func agentd() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py"), encoding: .utf8)
        #expect(src.contains("\"hermes\": \"--yolo\","))
        #expect(src.contains("\"hermes\": \"-c\","))
        #expect(src.contains("\"omp\", \"hermes\","))
        #expect(src.contains("if \"hermes_bootstrap\" in _foreground_args(tty):"))
    }

    @Test("config import carries Hermes's persona and skills, never its keys or session store")
    func configScan() throws {
        let src = try #require(AgentConfigScan.sources.first { $0.tool == .hermes })
        #expect(src.dir == ".hermes")
        for d in [".env", "auth.json", "config.yaml", "state.db", "mcp-tokens", "hermes-agent", "profiles"] {
            #expect(src.deny.contains(d), "\(d) not denied")
        }
    }
}
