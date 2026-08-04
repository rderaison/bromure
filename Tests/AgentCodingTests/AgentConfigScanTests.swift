import Foundation
import Testing
@testable import bromure_ac

// The agent CLIs' own configuration. The denylist is the whole safety story
// here — a transcript directory or an auth.json slipping through would put
// someone's session history, or a live token, into a VM.
@Suite("Agent config scan")
struct AgentConfigScanTests {

    /// A fake home with one agent's config dir laid out under it.
    private func fixture(_ files: [String: String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentcfg-\(UUID().uuidString)", isDirectory: true)
        for (rel, body) in files {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    private var claude: AgentConfigScan.Source {
        AgentConfigScan.sources.first { $0.tool == .claude }!
    }

    @Test("carries settings, memory, commands and subagents")
    func carriesConfig() throws {
        let home = try fixture([
            ".claude/settings.json": #"{"model":"claude-opus-5","effortLevel":"high"}"#,
            ".claude/CLAUDE.md": "# My rules\nAlways write tests.\n",
            ".claude/commands/ship.md": "Ship it\n",
            ".claude/agents/reviewer.md": "You review code\n",
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let r = try #require(AgentConfigScan.scan(claude, home: home))
        let paths = Set(r.files.map(\.path))
        #expect(paths.contains(".claude/settings.json"))
        #expect(paths.contains(".claude/CLAUDE.md"))
        #expect(paths.contains(".claude/commands/ship.md"))
        #expect(paths.contains(".claude/agents/reviewer.md"))
        #expect(r.files.first { $0.path.hasSuffix("CLAUDE.md") }!
            .contents.contains("Always write tests"))
    }

    @Test("never carries credentials, history or transcripts")
    func deniesSecretsAndState() throws {
        let home = try fixture([
            ".claude/settings.json": #"{"model":"x"}"#,
            ".claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"sk-ant-LEAK"}}"#,
            ".claude/projects/work/session.jsonl": "{\"text\":\"private transcript\"}\n",
            ".claude/history.jsonl": "{\"display\":\"what I typed\"}\n",
            ".claude/shell-snapshots/snap.sh": "export SECRET=1\n",
            ".claude/todos/list.json": #"{"a":1}"#,
            ".claude/plugins/big/index.json": #"{"b":2}"#,
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let r = try #require(AgentConfigScan.scan(claude, home: home))
        let all = r.files.map(\.path).joined(separator: " ")
        #expect(!all.contains("credentials"))
        #expect(!all.contains("projects"))
        #expect(!all.contains("history"))
        #expect(!all.contains("shell-snapshots"))
        #expect(!all.contains("todos"))
        #expect(!all.contains("plugins"))
        // And nothing leaked into any carried body.
        #expect(!r.files.contains { $0.contents.contains("sk-ant-LEAK") })
        #expect(!r.files.contains { $0.contents.contains("private transcript") })
    }

    @Test("an API key inside settings.json never survives")
    func redactsSettingsKeys() throws {
        let home = try fixture([
            ".claude/settings.json": """
            {"model":"claude-opus-5",
             "env":{"ANTHROPIC_API_KEY":"sk-ant-LEAKME","EDITOR":"vim"}}
            """,
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let r = try #require(AgentConfigScan.scan(claude, home: home))
        let body = r.files[0].contents
        #expect(!body.contains("sk-ant-LEAKME"))
        #expect(body.contains("claude-opus-5"))
        // The whole `env` block goes, not just the key: it is also where
        // ANTHROPIC_BASE_URL lives, and a host value there would point the
        // agent past the proxy (see AgentRoutingTests). Losing EDITOR with it
        // is the accepted cost — the API key still arrives via the typed path.
        #expect(!body.contains("vim"))
        #expect(!body.contains("env"))
        #expect(r.files[0].disabled.contains("env"))
        // Still valid JSON — the agent has to be able to read it.
        #expect((try? JSONSerialization.jsonObject(with: Data(body.utf8))) != nil)
    }

    @Test("a token pasted into a Markdown memory file is dropped")
    func redactsProseToken() throws {
        let home = try fixture([
            ".claude/CLAUDE.md": """
            # Rules
            Use the token ghp_LEAKTHISVALUE when pushing.
            Always write tests.
            """,
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let r = try #require(AgentConfigScan.scan(claude, home: home))
        #expect(!r.files[0].contents.contains("ghp_LEAKTHISVALUE"))
        // The rest of the document is intact — prose is filtered by token
        // shape, not by the word "token".
        #expect(r.files[0].contents.contains("Always write tests"))
        #expect(r.files[0].contents.contains("# Rules"))
    }

    @Test("binaries and oversized files are skipped, not truncated")
    func skipsNonText() throws {
        let home = try fixture([
            ".claude/settings.json": #"{"a":1}"#,
            ".claude/bin/helper": "#!/bin/sh\necho hi\n",
            ".claude/huge.md": String(repeating: "x", count: 70 * 1024),
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let r = try #require(AgentConfigScan.scan(claude, home: home))
        #expect(!r.files.contains { $0.path.hasSuffix("helper") })
        #expect(!r.files.contains { $0.path.hasSuffix("huge.md") })
        #expect(r.skipped >= 1)
    }

    @Test("no config dir means no row at all")
    func absentAgent() throws {
        let home = try fixture([".claude/settings.json": "{}"])
        defer { try? FileManager.default.removeItem(at: home) }
        let codex = AgentConfigScan.sources.first { $0.tool == .codex }!
        #expect(AgentConfigScan.scan(codex, home: home) == nil)
    }

    @Test("every agent has a source, and each denies its own credential file")
    func allAgentsCovered() {
        #expect(Set(AgentConfigScan.sources.map(\.tool)) == Set(Profile.Tool.allCases))
        for s in AgentConfigScan.sources {
            let denies = s.deny.contains("auth.json") || s.deny.contains("credentials")
                || s.deny.contains(".credentials.json")
            #expect(denies, "\(s.tool) must deny its credential store")
        }
    }

    @Test("scanning this Mac's real ~/.claude carries no secret")
    func realHomeIsClean() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let r = AgentConfigScan.scan(claude, home: home) else { return }
        for f in r.files {
            #expect(!SecretRedact.looksLikeToken(f.contents),
                    "token-shaped value survived in \(f.path)")
            #expect(!f.path.contains("projects"))
            #expect(!f.path.contains("history"))
        }
    }
}

// ~/.claude/settings.json is the one imported file with a managed counterpart:
// Bromure read-modify-writes it to default Claude Code to `auto` permissions.
// The import has to land BEFORE that merge, or one of the two silently wins.
@Suite("Imported Claude settings meet the managed merge")
struct ImportedClaudeSettingsTests {

    @Test("imported settings survive, Bromure's defaults are added around them")
    func mergesRatherThanClobbers() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bromure-claude-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDir: root)

        var p = Profile(name: "ws", tool: .claude, authMode: .token)
        p.importedConfigFiles = [ImportedConfigFile(
            path: ".claude/settings.json",
            contents: #"{"model":"claude-opus-5","effortLevel":"xhigh"}"#)]
        try store.prepareHomeDirectory(for: p, terminalDefaults: TerminalAppDefaults.load())

        let data = try Data(contentsOf: store.homeDirectory(for: p)
            .appendingPathComponent(".claude/settings.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // The user's choices came across…
        #expect(json["model"] as? String == "claude-opus-5")
        #expect(json["effortLevel"] as? String == "xhigh")
        // …and Bromure's autonomous-VM default was merged in, not lost.
        let perms = json["permissions"] as? [String: Any]
        #expect(perms?["defaultMode"] as? String == "auto")
    }

    @Test("an imported permission mode is respected, not overridden")
    func respectsExplicitMode() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bromure-claude2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDir: root)

        var p = Profile(name: "ws", tool: .claude, authMode: .token)
        p.importedConfigFiles = [ImportedConfigFile(
            path: ".claude/settings.json",
            contents: #"{"permissions":{"defaultMode":"plan"}}"#)]
        try store.prepareHomeDirectory(for: p, terminalDefaults: TerminalAppDefaults.load())

        let data = try Data(contentsOf: store.homeDirectory(for: p)
            .appendingPathComponent(".claude/settings.json"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let perms = json["permissions"] as? [String: Any]
        #expect(perms?["defaultMode"] as? String == "plan")
    }
}

// Every agent is aimed at the local MITM engine by a base-URL / provider
// setting (ANTHROPIC_BASE_URL, a codex model_provider, GROK_MODELS_BASE_URL,
// KIMI_MODEL_*). A config copied off the host carries that same surface
// pointed at the vendor instead — importing it as-is sends the guest's dummy
// key to the real endpoint, which 401s and looks like a Bromure bug.
@Suite("Imported agent config can't reroute the agent")
struct AgentRoutingTests {

    private func fixture(_ files: [String: String]) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("routing-\(UUID().uuidString)", isDirectory: true)
        for (rel, body) in files {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }
    private func source(_ t: Profile.Tool) -> AgentConfigScan.Source {
        AgentConfigScan.sources.first { $0.tool == t }!
    }

    @Test("Claude: the env block goes, the preferences stay")
    func claudeEnv() throws {
        let home = try fixture([".claude/settings.json": """
        {"model":"claude-opus-5","effortLevel":"xhigh","theme":"dark",
         "env":{"ANTHROPIC_BASE_URL":"https://api.anthropic.com",
                "ANTHROPIC_AUTH_TOKEN":"sk-ant-LEAK"}}
        """])
        defer { try? FileManager.default.removeItem(at: home) }

        let r = try #require(AgentConfigScan.scan(source(.claude), home: home))
        let body = r.files[0].contents
        #expect(!body.contains("api.anthropic.com"))
        #expect(!body.contains("sk-ant-LEAK"))
        #expect(body.contains("claude-opus-5"))
        #expect(body.contains("xhigh"))
        #expect(body.contains("dark"))
        #expect(r.files[0].disabled.contains("env"))
    }

    @Test("Codex: a model_provider section is dropped, prompts survive")
    func codexProvider() throws {
        let home = try fixture([
            ".codex/config.toml": """
            model = "gpt-5-codex"
            approval_policy = "on-failure"

            [model_providers.openai]
            base_url = "https://api.openai.com/v1"
            env_key = "OPENAI_API_KEY"
            wire_api = "responses"
            """,
            ".codex/AGENTS.md": "# House rules\nBe terse.\n",
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let r = try #require(AgentConfigScan.scan(source(.codex), home: home))
        let cfg = try #require(r.files.first { $0.path.hasSuffix("config.toml") }).contents
        #expect(!cfg.contains("api.openai.com"))
        #expect(!cfg.contains("env_key"))
        #expect(cfg.contains("gpt-5-codex"))            // model preference kept
        #expect(cfg.contains("approval_policy"))
        #expect(r.files.contains { $0.path.hasSuffix("AGENTS.md") })
    }

    @Test("Grok: models_base_url can't come across")
    func grokBaseURL() throws {
        let home = try fixture([
            ".grok/config.toml": """
            [cli]
            theme = "dark"
            models_base_url = "https://api.x.ai/v1"
            """,
            ".grok/settings.json": #"{"ui":{"compact":true},"baseUrl":"https://api.x.ai"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let r = try #require(AgentConfigScan.scan(source(.grok), home: home))
        let all = r.files.map(\.contents).joined()
        #expect(!all.contains("api.x.ai"))
        #expect(all.contains("dark"))
        #expect(all.contains("compact"))
    }

    @Test("Kimi: a [models] provider block and mcp.json servers are left out")
    func kimiModels() throws {
        let home = try fixture([
            ".kimi-code/config.toml": """
            default_model = "kimi-k2"

            [models.mine]
            base_url = "https://api.moonshot.cn/v1"
            api_key = "sk-LEAKME"
            """,
            ".kimi-code/mcp.json": """
            {"mcpServers":{"fs":{"command":"/opt/homebrew/bin/uvx","args":["x"]}}}
            """,
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let r = try #require(AgentConfigScan.scan(source(.kimi), home: home))
        let all = r.files.map(\.contents).joined()
        #expect(!all.contains("api.moonshot.cn"))
        #expect(!all.contains("sk-LEAKME"))
        // MCP entries name host binaries that don't exist in the guest, and the
        // profile has a typed MCP list that the launcher merges in properly.
        #expect(!all.contains("/opt/homebrew/bin/uvx"))
        #expect(all.contains("kimi-k2"))       // the model choice is a preference
    }

    @Test("Grok's shipped binaries are never walked")
    func grokBin() throws {
        let home = try fixture([
            ".grok/config.toml": "[cli]\ntheme = \"dark\"\n",
            ".grok/bin/manifest.json": #"{"version":"1"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        let r = try #require(AgentConfigScan.scan(source(.grok), home: home))
        #expect(!r.files.contains { $0.path.contains("/bin/") })
    }

    @Test("no agent's credential store is ever reachable")
    func credentialStores() throws {
        let home = try fixture([
            ".codex/auth.json": #"{"tokens":{"access_token":"LEAK1"}}"#,
            ".codex/config.toml": "model = \"x\"\n",
            ".grok/auth.json": #"{"s":{"key":"LEAK2","refresh_token":"r"}}"#,
            ".grok/config.toml": "[cli]\ntheme = \"dark\"\n",
            ".kimi-code/credentials/kimi-code.json": #"{"access_token":"LEAK3"}"#,
            ".kimi-code/config.toml": "default_model = \"k\"\n",
        ])
        defer { try? FileManager.default.removeItem(at: home) }

        for tool in [Profile.Tool.codex, .grok, .kimi] {
            let r = try #require(AgentConfigScan.scan(source(tool), home: home))
            let all = r.files.map(\.contents).joined()
            for leak in ["LEAK1", "LEAK2", "LEAK3"] { #expect(!all.contains(leak)) }
            #expect(!r.files.contains { $0.path.contains("auth.json") })
            #expect(!r.files.contains { $0.path.contains("credentials") })
        }
    }
}
