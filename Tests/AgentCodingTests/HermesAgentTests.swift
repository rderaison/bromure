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
        // A task's opening message: `chat --query=`, flags after the
        // subcommand (`-c chat` reads `chat` as -c's session name).
        #expect(rc.contains("\"$_wt_tool\" chat --query=\"$_wt_prompt\" $_wt_flags"))
    }

    /// The settings step the wrapper runs, lifted out of the .bashrc and run
    /// against a stand-in `hermes` that logs each `hermes config …` call.
    private func runApply(settings: [String: Any], servers: [String: Any],
                          home: URL, failing: Bool = false, hidden: [String] = [],
                          hooks: Any? = nil, env extra: [String: String] = [:],
                          meta metaOut: ((URL) -> Void)? = nil,
                          status expected: Int32 = 0) throws -> [String] {
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
        try hidden.map { $0 + "\n" }.joined().write(to: meta.appendingPathComponent("hermes-env-unset"),
                                                     atomically: true, encoding: .utf8)
        try "".write(to: meta.appendingPathComponent("bromure-task-mcp.py"), atomically: true, encoding: .utf8)
        metaOut?(meta)
        let hooksFile = dir.appendingPathComponent("hooks.json")
        if let hooks {
            try JSONSerialization.data(withJSONObject: hooks).write(to: hooksFile)
        }
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("calls.log")
        let fake = bin.appendingPathComponent("hermes")
        // `config unset` of an absent key fails as Hermes's does; `config get
        // hooks` answers with `hooks` (absent: "Config key not set").
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(log.path)'
        \(failing ? "exit 1" : "")
        if [ "$2" = unset ]; then echo "Config key not set: $3" >&2; exit 1; fi
        if [ "$2" = get ]; then
            [ -f '\(hooksFile.path)' ] || { echo "Config key not set: $3" >&2; exit 1; }
            cat '\(hooksFile.path)'
        fi
        exit 0
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        var env = ["HOME": home.path, "BROMURE_META_DIR": meta.path,
                   "PATH": bin.path + ":/usr/bin:/bin", "HERMES_HOME": "", "BROMURE_HERMES_TASK": ""]
        for (k, v) in extra { env[k] = v }
        let (status, diag) = try run("/usr/bin/python3", ["-c", script], env: env)
        #expect(status == expected, Comment(rawValue: diag))
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
        // Next time: a cloud provider (no base URL any more), one server gone.
        let again = try runApply(settings: ["model": ["provider": "anthropic"], "key_var": "ANTHROPIC_API_KEY"],
                                 servers: ["browser": ["command": "python3", "args": ["x"]]], home: home)
        #expect(again.contains("config set model.provider anthropic"))
        #expect(again.contains("config unset model.base_url"))
        #expect(again.contains("config unset model.key_env"))
        #expect(again.contains("config unset model.api_key"))
        #expect(!again.contains { $0.hasPrefix("config set model.default") })
        // No model chosen any more: the previous one goes, not left for the
        // new provider to be asked for.
        #expect(again.contains("config unset model.default"))
        #expect(again.contains("config unset mcp_servers.docs\\.v2"))
        #expect(!again.contains("config unset mcp_servers.browser"))
        // (Unsetting what was never set didn't fail the run: status 0.)
    }

    /// "storage_unavailable": a Nous workspace with no model chosen left
    /// Hermes's model.default unset; its gateway then saved every session
    /// with no model and refused to reopen it ("invalid policy"). The
    /// catalog's labeled default -- what Hermes runs a turn on anyway -- is
    /// written out instead (`_bromure_hermes_catalog_default`).
    @Test("Nous with no model chosen gets Hermes's own catalog default written out")
    func applyNousDefault() throws {
        let home = try tempDir()
        let nous = ["BROMURE_HERMES_NOUS_DEFAULT": "z-ai/glm-5.3"]
        let calls = try runApply(settings: ["model": ["provider": "nous"], "key_var": ""], servers: [:],
                                 home: home, env: nous)
        #expect(calls.contains("config set model.default z-ai/glm-5.3"))
        #expect(!calls.contains("config unset model.default"))
        // A model the workspace chose wins.
        let chosen = try runApply(settings: ["model": ["provider": "nous", "default": "openai/gpt-5.5"], "key_var": ""],
                                  servers: [:], home: home, env: nous)
        #expect(chosen.contains("config set model.default openai/gpt-5.5"))
        #expect(!chosen.contains("config set model.default z-ai/glm-5.3"))
        // Another provider without a model: still its own default, unset.
        let other = try runApply(settings: ["model": ["provider": "anthropic"], "key_var": "ANTHROPIC_API_KEY"],
                                 servers: [:], home: home, env: nous)
        #expect(other.contains("config unset model.default"))
        // No default known, or one that isn't a model id: unset, as before.
        for bad in ["", "x y; rm"] {
            let r = try runApply(settings: ["model": ["provider": "nous"], "key_var": ""], servers: [:],
                                 home: home, env: ["BROMURE_HERMES_NOUS_DEFAULT": bad])
            #expect(r.contains("config unset model.default"))
        }
    }

    /// The stamp's run of `_bromure_hermes_catalog_default`, from the
    /// rendered .bashrc, against a settings file and a Hermes cache.
    private func catalogDefault(settings: [String: Any], catalog: [String: Any]?) throws -> String {
        let rc = try renderBashrc()
        let lines = rc.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex { $0.hasPrefix("_bromure_hermes_catalog_default() {") })
        let close = try #require(lines[(start + 1)...].firstIndex { $0 == "BROMURE_HERMES_CATALOG" })
        let end = try #require(lines[(close + 1)...].firstIndex { $0 == "}" })
        let fn = lines[start...end].joined(separator: "\n")
        let dir = try tempDir()
        let meta = dir.appendingPathComponent("meta")
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: settings).write(to: meta.appendingPathComponent("hermes-settings.json"))
        let cache = dir.appendingPathComponent(".hermes/cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        if let catalog {
            try JSONSerialization.data(withJSONObject: catalog).write(to: cache.appendingPathComponent("model_catalog.json"))
        }
        let out = Pipe()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", fn + "\n_bromure_hermes_catalog_default"]
        p.environment = ["HOME": dir.path, "HERMES_HOME": "", "BROMURE_META_DIR": meta.path, "PATH": "/usr/bin:/bin"]
        p.standardOutput = out
        try p.run(); p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Finding "Hermes stays pinned to a stale Nous default after catalog
    /// refresh": the default was read inside the apply only, and the stamp
    /// didn't carry it -- a default Hermes's catalog rotated to, or one that
    /// appeared after a first apply with no catalog, was never applied.
    @Test("the stamp carries the catalog's Nous default, so a new one is applied again")
    func catalogDefaultInStamp() throws {
        let nous: [String: Any] = ["model": ["provider": "nous"]]
        let cat = { (id: String) -> [String: Any] in
            ["providers": ["nous": ["models": [["id": "anthropic/claude-fable-5.2"], ["id": id, "default": true]]]]]
        }
        #expect(try catalogDefault(settings: nous, catalog: cat("z-ai/glm-5.3")) == "z-ai/glm-5.3")
        #expect(try catalogDefault(settings: nous, catalog: cat("z-ai/glm-6")) == "z-ai/glm-6")
        #expect(try catalogDefault(settings: nous, catalog: nil) == "")
        #expect(try catalogDefault(settings: nous, catalog: cat("x y; rm")) == "")
        // Not on Nous: nothing read, nothing in the stamp to change.
        #expect(try catalogDefault(settings: ["model": ["provider": "anthropic"]], catalog: cat("z-ai/glm-5.3")) == "")
        let rc = try renderBashrc()
        let stamp = try #require(rc.range(of: "_bromure_hermes_stamp() {"))
        let stampEnd = try #require(rc.range(of: "_bromure_hermes_apply() {", range: stamp.upperBound..<rc.endIndex))
        let body = String(rc[stamp.upperBound..<stampEnd.lowerBound])
        #expect(body.contains("_bromure_hermes_catalog_default | sha256sum"))
        #expect(body.contains("printf 'apply-4 '"))
        #expect(rc.contains("BROMURE_HERMES_NOUS_DEFAULT=\"$(_bromure_hermes_catalog_default)\""))
    }

    @Test("a failed `hermes config` fails the step, so the wrapper doesn't stamp it done")
    func applyFailureRetries() throws {
        let home = try tempDir()
        _ = try runApply(settings: ["model": ["provider": "xai"]], servers: [:], home: home,
                         failing: true, status: 3)
        let rc = try renderBashrc()
        // Only a successful step is stamped -- with config.yaml and .env as
        // it left them, so an edit to either re-applies the settings.
        #expect(rc.contains("python3 - <<'BROMURE_HERMES_APPLY' || return 0"))
        #expect(rc.contains("local _h=\"${HERMES_HOME:-$HOME/.hermes}\""))
        #expect(rc.contains("_bromure_hermes_stamp > \"$_h/.bromure-applied\""))
        #expect(rc.contains("cat \"$_h/config.yaml\" 2>/dev/null | sha256sum"))
        #expect(rc.contains("cat \"$_h/shell-hooks-allowlist.json\" 2>/dev/null | sha256sum"))
        #expect(rc.contains("cat \"$_h/.env\" 2>/dev/null | sha256sum"))
        // The step's own `hermes config` runs see no other provider's key.
        #expect(rc.contains("_bromure_hermes_apply \"${_u[@]}\""))
        #expect(rc.contains("command env \"$@\" -u BROMURE_HERMES_API_KEY \\\n"))
    }

    @Test("a stand-in for a hidden key left in Hermes's .env is dropped; the user's own keys stay")
    func envScrub() throws {
        let home = try tempDir()
        let hermes = home.appendingPathComponent(".hermes")
        try FileManager.default.createDirectory(at: hermes, withIntermediateDirectories: true)
        let env = hermes.appendingPathComponent(".env")
        try """
        ANTHROPIC_API_KEY=sk-ant-api03-brm-AbC123
        export OPENAI_API_KEY="sk-brm-xyz"
        OPENROUTER_API_KEY=sk-or-v1-users-own
        CLAUDE_CODE_OAUTH_TOKEN=eyJhbGciOiJ.eyJzdWIiOiJ4In0.brm-cdX-sigAbC
        ANTHROPIC_TOKEN=sk-ant-oat01-brmCLA-xyz
        FIRECRAWL_API_KEY=brm_fake
        TELEGRAM_BOT_TOKEN=123:abc

        """.write(to: env, atomically: true, encoding: .utf8)
        _ = try runApply(settings: ["model": ["provider": "xai"]], servers: [:], home: home,
                         hidden: ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY",
                                  "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_TOKEN"])
        let after = try String(contentsOf: env, encoding: .utf8)
        #expect(!after.contains("ANTHROPIC_API_KEY") && !after.contains("OPENAI_API_KEY"))
        #expect(!after.contains("CLAUDE_CODE_OAUTH_TOKEN"))   // an OAuth stand-in (JWT) too
        #expect(!after.contains("ANTHROPIC_TOKEN"))           // Claude's subscription stand-in
        #expect(after.contains("OPENROUTER_API_KEY=sk-or-v1-users-own"))
        #expect(after.contains("FIRECRAWL_API_KEY=brm_fake"))   // not a hidden variable
        #expect(after.contains("TELEGRAM_BOT_TOKEN=123:abc"))
        let mode = try FileManager.default.attributesOfItem(atPath: env.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test("the settings step registers the status hook on every event, after the user's own hooks, and approves it")
    func applyHooks() throws {
        let home = try tempDir()
        let hook = Profile.hermesHookGuestPath
        let settings: [String: Any] = ["model": ["provider": "xai"],
                                       "hooks": ["command": hook, "events": ["pre_llm_call", "on_session_end"]]]
        // The user's own hook on one event, and ours left on an event we no
        // longer report.
        let mine: [String: Any] = ["command": "/home/u/fmt.sh", "matcher": "write_file"]
        let calls = try runApply(settings: settings, servers: [:], home: home, hooks: [
            "pre_llm_call": [mine],
            "post_curator_run": [["command": hook, "timeout": 20]],
            "outbound": [["url": "https://example.test"]],
        ])
        let preLLM = try #require(calls.first { $0.hasPrefix("config set hooks.pre_llm_call ") })
        let list = try #require(try JSONSerialization.jsonObject(
            with: Data(preLLM.dropFirst("config set hooks.pre_llm_call ".count).utf8)) as? [[String: Any]])
        #expect(list.count == 2)
        #expect(list.first?["command"] as? String == "/home/u/fmt.sh")
        #expect(list.last?["command"] as? String == hook && list.last?["timeout"] as? Int == 20)
        #expect(calls.contains { $0.hasPrefix("config set hooks.on_session_end [{\"command\": \"\(hook)\"") })
        #expect(calls.contains("config unset hooks.post_curator_run"))
        #expect(!calls.contains { $0.contains("hooks.outbound") })
        // Approved the way Hermes records an accepted hook: (event, exact command).
        let allowURL = home.appendingPathComponent(".hermes/shell-hooks-allowlist.json")
        let allow = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: allowURL)) as? [String: Any])
        let approvals = try #require(allow["approvals"] as? [[String: Any]])
        #expect(Set(approvals.compactMap { $0["event"] as? String }) == ["pre_llm_call", "on_session_end"])
        #expect(approvals.allSatisfy { $0["command"] as? String == hook && $0["approved_at"] is String })
        let mode = try FileManager.default.attributesOfItem(atPath: allowURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // Already in place: nothing rewritten, no approval doubled.
        let again = try runApply(settings: settings, servers: [:], home: home, hooks: [
            "pre_llm_call": [mine, ["command": hook, "timeout": 20]],
            "on_session_end": [["command": hook, "timeout": 20]],
        ])
        #expect(!again.contains { $0.hasPrefix("config set hooks.") || $0.hasPrefix("config unset hooks.") })
        let allow2 = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: allowURL)) as? [String: Any])
        #expect((allow2["approvals"] as? [Any])?.count == 2)
    }

    // MARK: - One Hermes home per tab (delegation identity)

    /// "This agent isn't running in a Bromure session tab, so it has no
    /// identity here": Hermes starts its MCP servers from the home's shared
    /// gateway, with a filtered environment -- the delegation shim never saw
    /// its tab's tmux pane.
    @Test("the delegation server runs in its Hermes mode (its window from the home); other servers don't")
    func applyDelegationEnv() throws {
        let calls = try runApply(
            settings: ["model": ["provider": "nous"], "key_var": ""],
            servers: ["delegation": ["command": "python3", "args": ["/mnt/bromure-meta/bromure-delegation-mcp.py"]],
                      "browser": ["command": "python3", "args": ["/mnt/bromure-meta/bromure-browser-mcp.py"],
                                  "env": ["A": "1"]]],
            home: try tempDir())
        let deleg = try #require(calls.first { $0.hasPrefix("config set mcp_servers.delegation ") })
        let json = try #require(deleg.split(separator: " ", maxSplits: 3).last.map(String.init))
        let v = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(v["args"] as? [String] == ["/mnt/bromure-meta/bromure-delegation-mcp.py", "--hermes"])
        let browser = try #require(calls.first { $0.hasPrefix("config set mcp_servers.browser ") })
        #expect(!browser.contains("--hermes"))
    }

    private func bashFunctions(_ names: [String]) throws -> String {
        let lines = try renderBashrc().components(separatedBy: "\n")
        return try names.map { name in
            let start = try #require(lines.firstIndex { $0.hasSuffix(name + "() {") })
            let end = try #require(lines[start...].firstIndex { $0 == "}" })
            return lines[start...end].joined(separator: "\n")
        }.joined(separator: "\n")
    }

    private func bash(_ script: String, env: [String: String]) throws -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", script]
        proc.environment = env
        let out = Pipe(); proc.standardOutput = out
        proc.standardError = Pipe()
        try proc.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (proc.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test("only a chat goes to the tab's home: subcommands and a chosen profile stay the user's; a resume names its id")
    func tabChatAndResume() throws {
        let fns = try bashFunctions(["_bromure_hermes_is_chat", "_bromure_hermes_resume_id"])
        func isChat(_ args: String) throws -> Bool {
            try bash(fns + "\n_bromure_hermes_is_chat \(args)", env: ["PATH": "/usr/bin:/bin"]).0 == 0
        }
        #expect(try isChat(""))
        #expect(try isChat("chat --query=hi"))
        #expect(try isChat("--resume local-ab12 --yolo"))
        #expect(try isChat("-c"))
        #expect(try !isChat("auth add nous --type oauth"))
        #expect(try !isChat("config set x y"))
        #expect(try !isChat("sessions list"))
        #expect(try !isChat("-p work"))
        #expect(try !isChat("chat --profile=work"))
        func resumeID(_ args: String) throws -> String {
            try bash(fns + "\n_bromure_hermes_resume_id \(args)", env: ["PATH": "/usr/bin:/bin"]).1
        }
        #expect(try resumeID("--resume local-ab12 --yolo") == "local-ab12")
        #expect(try resumeID("-r 20261117_140352_ab12cd") == "20261117_140352_ab12cd")
        #expect(try resumeID("--resume=local-x.1") == "local-x.1")
        #expect(try resumeID("-c") == "")
        #expect(try resumeID("--resume ../etc") == "", "never a path")
        #expect(try resumeID("--resume 'a;rm'") == "")
    }

    @Test("a resumed session goes back to the home holding it: the user's, or a profile's")
    func sessionHome() throws {
        let fns = try bashFunctions(["_bromure_hermes_session_home"])
        let home = try tempDir()
        func db(_ dir: String, _ ids: [String]) throws {
            let d = home.appendingPathComponent(dir)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            let sql = "CREATE TABLE sessions (id TEXT PRIMARY KEY);"
                + ids.map { "INSERT INTO sessions VALUES ('\($0)');" }.joined()
            try run("/usr/bin/sqlite3", [d.appendingPathComponent("state.db").path, sql])
        }
        try db(".hermes", ["local-root"])
        try db(".hermes/profiles/tab-3", ["local-three"])
        try db(".hermes/profiles/bt-x", ["local-task"])
        func find(_ sid: String) throws -> String {
            try bash(fns + "\n_bromure_hermes_session_home '\(sid)'", env: ["HOME": home.path, "PATH": "/usr/bin:/bin"]).1
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #expect(try find("local-root") == home.path + "/.hermes")
        #expect(try find("local-three") == home.path + "/.hermes/profiles/tab-3")
        #expect(try find("local-task") == home.path + "/.hermes/profiles/bt-x")
        #expect(try find("local-none") == "")
    }

    @Test("a tab's chat runs in tab-<window>, cloned once with the user's applied settings; a resume returns to its own home")
    func tabHome() throws {
        let fns = try bashFunctions(["_bromure_hermes_tab_home"])
        let dir = try tempDir()
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("calls.log")
        for (name, body) in [
            ("hermes", "printf 'hermes %s\\n' \"$*\" >> '\(log.path)'\n"
                + "[ \"$1 $2\" = \"profile create\" ] && mkdir -p \"$HOME/.hermes/profiles/$3\" "
                + "&& cp \"$HOME/.hermes/config.yaml\" \"$HOME/.hermes/profiles/$3/\"\nexit 0"),
            ("tmux", "[ \"$4\" = '%7' ] && echo 4 && exit 0\nexit 1"),
        ] {
            let url = bin.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let root = dir.appendingPathComponent(".hermes")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "model: {}\n".write(to: root.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        try "stamp\n".write(to: root.appendingPathComponent(".bromure-applied"), atomically: true, encoding: .utf8)
        let stubs = """
        _bromure_hermes_apply() { printf 'apply %s\\n' "${HERMES_HOME:-root}" >> '\(log.path)'; }
        _bromure_hermes_claim() { printf 'claim %s\\n' "$1" >> '\(log.path)'; [ "$1" != "$BUSY" ]; }
        _bromure_hermes_session_home() { [ "$1" = local-old ] && printf '%s' "$HOME/.hermes"; }
        """
        func tabHome(_ sid: String, pane: String = "%7", busy: String = "") throws -> (Int32, String) {
            try bash(fns + "\n" + stubs + "\n_bromure_hermes_tab_home '\(sid)' -u OPENAI_API_KEY",
                     env: ["HOME": dir.path, "PATH": bin.path + ":/usr/bin:/bin", "TMUX_PANE": pane, "BUSY": busy])
        }
        func calls() -> [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        let tab = root.path + "/profiles/tab-4"
        #expect(try tabHome("") == (0, tab))
        #expect(calls() == ["apply root", "hermes profile create tab-4 --clone", "claim " + tab])
        // Its window is written as soon as the home exists (Hermes starts
        // its MCP servers then).
        #expect((try? String(contentsOf: URL(fileURLWithPath: tab + "/bromure-window"), encoding: .utf8)) == "w4\n")
        // The clone carries the applied settings' stamp: no second apply.
        #expect((try? String(contentsOf: URL(fileURLWithPath: tab + "/.bromure-applied"), encoding: .utf8)) == "stamp\n")
        #expect(try tabHome("") == (0, tab))
        #expect(calls().filter { $0.hasPrefix("hermes profile create") }.count == 1, "cloned once")
        // A resume goes back to the home holding the session, if it's free...
        #expect(try tabHome("local-old") == (0, root.path))
        // ...else this tab's own (Hermes then says the session isn't there).
        #expect(try tabHome("local-old", busy: root.path) == (0, tab))
        // Not in tmux, or a pane tmux doesn't know: no home of its own.
        #expect(try tabHome("", pane: "").0 != 0)
        #expect(try tabHome("", pane: "%9").0 != 0)
    }

    /// The claim's /proc scan, against a fake /proc (macOS has none).
    @Test("a home is one window's: another window's chat (by argv or Hermes's registry) keeps it; gateways don't count")
    func claimHome() throws {
        let dir = try tempDir()
        let proc = dir.appendingPathComponent("proc")
        let home = dir.appendingPathComponent("home")
        let fns = try bashFunctions(["_bromure_hermes_claim"])
            .replacingOccurrences(of: "\"/proc\"", with: "'\(proc.path)'")
            .replacingOccurrences(of: "\"/proc/%", with: "'\(proc.path)/%")
            .replacingOccurrences(of: "%d\" % pid)", with: "%d' % pid)")
            .replacingOccurrences(of: "%s/cmdline\" % d", with: "%s/cmdline' % d")
            .replacingOccurrences(of: "%s/comm\" % d", with: "%s/comm' % d")
            .replacingOccurrences(of: "%d/environ\" % pid", with: "%d/environ' % pid")
        #expect(!fns.contains("\"/proc"))
        #expect(!fns.contains("os.kill"), "nothing is stopped: one gateway serves every home")
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        // Panes %1 and %2 are in window 1 (a split), %5 in window 5; %9 is gone.
        try """
        #!/bin/sh
        case "$4" in %1|%2) echo 1 ;; %5) echo 5 ;; *) exit 1 ;; esac
        """.write(to: bin.appendingPathComponent("tmux"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("tmux").path)
        func process(_ pid: Int, comm: String, argv: [String], env: [String: String]) throws {
            let d = proc.appendingPathComponent(String(pid))
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try Data((argv.joined(separator: "\0") + "\0").utf8).write(to: d.appendingPathComponent("cmdline"))
            try Data((comm + "\n").utf8).write(to: d.appendingPathComponent("comm"))
            try Data(env.map { "\($0)=\($1)\0" }.joined().utf8).write(to: d.appendingPathComponent("environ"))
        }
        func claim(_ h: String, pane: String = "%1") throws -> Int32 {
            try bash(fns + "\n_bromure_hermes_claim '\(h)'",
                     env: ["HOME": home.path, "PATH": bin.path + ":/usr/bin:/bin", "TMUX_PANE": pane]).0
        }
        let root = home.path + "/.hermes"
        let tab = root + "/profiles/tab-1"
        // The gateway (started from window 5, serving every home): no claim on any.
        try process(100, comm: "python3", argv: ["python3", "-m", "hermes_cli.main", "--profile", "default",
                                                 "gateway", "run", "--idle-exit"], env: ["TMUX_PANE": "%5"])
        #expect(try claim(tab) == 0)
        #expect(try claim(root) == 0)
        // This window's own chat (another pane of it): still this window's.
        try process(101, comm: "python3", argv: ["python3", "-I", "/usr/local/bin/hermes", "chat"],
                    env: ["HERMES_HOME": tab, "TMUX_PANE": "%2"])
        #expect(try claim(tab) == 0)
        // Window 5's chat on the user's home, run as `-m hermes_cli.main`.
        try process(102, comm: "python3", argv: ["python3", "-m", "hermes_cli.main", "chat"], env: ["TMUX_PANE": "%5"])
        #expect(try claim(root) == 1)
        #expect(try claim(root, pane: "%5") == 0, "window 5 itself may")
        // One only Hermes's own registry names.
        let listed = root + "/profiles/tab-7"
        try FileManager.default.createDirectory(atPath: listed + "/runtime", withIntermediateDirectories: true)
        try #"{"entries": [{"pid": 401, "session_id": "local-x"}]}"#
            .write(toFile: listed + "/runtime/active_sessions.json", atomically: true, encoding: .utf8)
        try process(401, comm: "node", argv: ["node", "ui-tui"], env: ["TMUX_PANE": "%5"])
        #expect(try claim(listed) == 1)
        // Outside tmux, or a pane that's gone: never.
        #expect(try claim(tab, pane: "") == 1)
        #expect(try claim(tab, pane: "%9") == 1)
        // The wrapper never falls back to the shared home in a tab, and
        // tells the home which window it's in.
        let rc = try renderBashrc()
        #expect(rc.contains("couldn't give this tab its own Hermes home"))
        #expect(rc.contains("this task's Hermes is running in another tab"))
        #expect(rc.contains("printf 'w%s\\n' \"$_win\" > \"$HERMES_HOME/bromure-window.tmp\""))
    }

    /// The wrapper itself, its helpers stubbed: a home the user exported is
    /// claimed like a tab home before it's told this tab's window, and
    /// only a chat that claimed its home rewrites that window.
    @Test("an exported HERMES_HOME is claimed before its window is written; a non-chat never rewrites it")
    func explicitHomeClaimed() throws {
        let dir = try tempDir()
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        for (name, body) in [("tmux", "echo 4"),
                             ("hermes", "echo ran \"$@\" > \"$RAN\"; [ -e /dev/fd/197 ] && echo leased >> \"$RAN\"; true")] {
            let f = bin.appendingPathComponent(name)
            try "#!/bin/sh\n\(body)\n".write(to: f, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        }
        let lines = try renderBashrc().components(separatedBy: "\n")
        let start = try #require(lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "hermes() {" })
        let end = try #require(lines[start...].firstIndex { $0 == "}" })
        let wrapper = lines[start...end].joined(separator: "\n")
        let stubs = """
        _bromure_hermes_opt_ready() { :; }
        _bromure_hermes_sync_auth() { :; }
        _bromure_hermes_apply() { :; }
        _bromure_hermes_resume_model() { return 1; }
        _bromure_hermes_tab_home() { echo "$TABHOME"; }
        _bromure_hermes_claim() { echo "$1" >> "$CLAIMS"; [ "$CLAIM" = ok ]; }
        """
        let fns = try bashFunctions(["_bromure_hermes_is_chat", "_bromure_hermes_resume_id", "_bromure_hermes_lease"])
        let home = dir.appendingPathComponent("chosen")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let window = home.appendingPathComponent("bromure-window")
        let ran = dir.appendingPathComponent("ran"), claims = dir.appendingPathComponent("claims")
        func run(_ args: String, claim: String) throws -> Int32 {
            try? FileManager.default.removeItem(at: ran)
            try? FileManager.default.removeItem(at: claims)
            return try bash(fns + "\n" + wrapper + "\n" + stubs + "\nhermes " + args, env: [
                "PATH": bin.path + ":/usr/bin:/bin", "HOME": dir.path, "TMUX_PANE": "%4",
                "HERMES_HOME": home.path, "TABHOME": dir.appendingPathComponent("tab").path,
                "CLAIM": claim, "RAN": ran.path, "CLAIMS": claims.path]).0
        }
        func written() -> String? { try? String(contentsOf: window, encoding: .utf8) }
        let fm = FileManager.default
        // Another tab holds the home: refused, its window left alone, Hermes not run.
        try "w2\n".write(to: window, atomically: true, encoding: .utf8)
        #expect(try run("", claim: "no") == 1)
        #expect(written() == "w2\n")
        #expect(!fm.fileExists(atPath: ran.path))
        #expect((try? String(contentsOf: claims, encoding: .utf8)) == home.path + "\n",
                "the exported home itself is claimed, not a tab home")
        #expect(try run("chat", claim: "no") == 1)
        #expect(written() == "w2\n")
        // Not a chat (a subcommand, a chosen profile): never claimed, never rewritten.
        #expect(try run("config set x y", claim: "no") == 0)
        #expect(written() == "w2\n")
        #expect(fm.fileExists(atPath: ran.path))
        #expect(!fm.fileExists(atPath: claims.path))
        #expect(try run("-p work", claim: "no") == 0)
        #expect(written() == "w2\n")
        // This tab claims it: told its window, then Hermes runs.
        #expect(try run("", claim: "ok") == 0)
        #expect(written() == "w4\n")
        #expect((try? String(contentsOf: ran, encoding: .utf8)) == "ran\n", "Hermes never inherits the lease")
        #expect((try? String(contentsOf: home.appendingPathComponent(".bromure-lease"), encoding: .utf8)) == "",
                "let go once the chat ends")
    }

    /// The claim only sees chats already running: the lease is what keeps
    /// two tabs opening one home at once (two resumes of one session) apart.
    /// Every chat holds its own: one let in beside the holder (another pane
    /// of its window) without one was unguarded once the holder exited.
    @Test("a home's lease: one chat holds it until it lets go; any other is refused, another pane of its window too")
    func leaseHome() throws {
        let dir = try tempDir()
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tmux = bin.appendingPathComponent("tmux")
        try "#!/bin/sh\necho \"$WIN\"\n".write(to: tmux, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmux.path)
        let home = dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let fns = try bashFunctions(["_bromure_hermes_lease"])
        // Window 1 takes it. Window 5, and another pane of window 1 (each
        // its own shell, as another tab or pane is), are refused while it's
        // held; once window 1 lets go, window 5 gets it and holds it.
        let script = fns + #"""

        other() { WIN=$1 bash -c "$(declare -f _bromure_hermes_lease)"'
            _lease=""; _bromure_hermes_lease "$0" && echo "w$WIN:${_lease:-unleased}" || echo "w$WIN:refused"' "$H" 197>&-; }
        _lease=""
        WIN=1 _bromure_hermes_lease "$H" && echo "w1:${_lease}"
        other 5; other 1
        exec 197>&-
        other 5
        _lease=""; WIN=1 _bromure_hermes_lease "" || echo "nohome:refused"
        """#
        let (rc, out) = try bash(script, env: ["PATH": bin.path + ":/usr/bin:/bin", "TMUX_PANE": "%1", "H": home.path])
        #expect(rc == 0)
        #expect(out == "w1:1\nw5:refused\nw1:refused\nw5:1\nnohome:refused\n")
        // No way in without the lease: a refusal is the only other outcome.
        let fn = try bashFunctions(["_bromure_hermes_lease"])
        #expect(fn.components(separatedBy: "return 0").count == 2)
        // The wrapper takes it before writing the window, and never hands it to Hermes.
        let rc2 = try renderBashrc()
        let lease = try #require(rc2.range(of: "_bromure_hermes_lease \"$HERMES_HOME\""))
        let write = try #require(rc2.range(of: "> \"$HERMES_HOME/bromure-window.tmp\""))
        #expect(lease.lowerBound < write.lowerBound)
        #expect(rc2.contains("BROMURE_HERMES_API_KEY hermes \"$@\" 197>&-"))
    }

    /// The delegation shim in Hermes mode, run against a fake host: it names
    /// the window its home says, and redials when another tab takes the
    /// home over.
    @Test("the delegation shim's Hermes mode names the home's window, and follows it when it changes")
    func delegationShimHermesMode() throws {
        let script = SessionDisk.delegationMCPShimScript
        #expect(script.contains("HERMES = len(sys.argv) > 1 and sys.argv[1] == \"--hermes\""))
        #expect(script.components(separatedBy: "refresh_hello()").count == 3, "defined, and called at each dial")
        #expect(script.components(separatedBy: "redial_if_moved()").count == 3, "defined, and called per request")
        // Its hello, from the home: run the hello block alone.
        let lines = script.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex { $0.hasPrefix("HERMES = ") })
        let end = try #require(lines.firstIndex { $0 == "HELLO = _hello()" })
        let block = "import os, subprocess, sys\n" + lines[start...end].joined(separator: "\n") + "\nprint(HELLO)\n"
        let home = try tempDir()
        func hello(_ content: String?, argv: [String] = ["--hermes"]) throws -> String {
            let f = home.appendingPathComponent("bromure-window")
            try? FileManager.default.removeItem(at: f)
            if let content { try content.write(to: f, atomically: true, encoding: .utf8) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = ["-c", block] + argv
            p.environment = ["HERMES_HOME": home.path, "PATH": "/usr/bin:/bin"]
            let out = Pipe(); p.standardOutput = out
            try p.run(); p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #expect(try hello("w3\n") == "w3")
        #expect(try hello(nil) == "")
        #expect(try hello("w3; rm") == "", "only w<digits>")
        #expect(try hello("w12", argv: ["w4"]) == "w4", "an explicit hello (tests) is still that")
    }

    /// End to end, through a fake host (agentd's relay path, AF_VSOCK
    /// refused): the first dial waits for the window the wrapper writes a
    /// moment after Hermes starts the shim; a new window redials, and the
    /// answer to the call that noticed it still comes back (it hung once:
    /// a closed socket didn't wake the reader blocked on it).
    @Test("the Hermes-mode shim waits for its window, and follows a change without losing the call")
    func delegationShimRedial() throws {
        let dir = try tempDir()
        let shim = dir.appendingPathComponent("shim.py")
        try SessionDisk.delegationMCPShimScript.write(to: shim, atomically: true, encoding: .utf8)
        let harness = #"""
        import json, os, socket, subprocess, sys, tempfile, threading, time
        d = sys.argv[1]; shim = sys.argv[2]
        # A unix socket path must be short (104 bytes on macOS).
        relay = tempfile.mktemp(prefix="bhr", dir="/tmp"); home = os.path.join(d, "home"); os.makedirs(home)
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); srv.bind(relay); srv.listen(8)
        hellos = []
        def serve(c):
            f = c.makefile("rb")
            f.readline(); c.sendall(b"ok\n")
            hello = f.readline().decode().strip().replace("bromure-hello ", "", 1)
            hellos.append(hello)
            for line in f:
                msg = json.loads(line)
                c.sendall((json.dumps({"jsonrpc": "2.0", "id": msg.get("id"), "result": {"hello": hello}}) + "\n").encode())
        def accept():
            while True:
                c, _ = srv.accept()
                threading.Thread(target=serve, args=(c,), daemon=True).start()
        threading.Thread(target=accept, daemon=True).start()
        seccomp = ("import errno, runpy, socket, sys\n"
                   "real = socket.socket\n"
                   "def refused(family=-1, *a, **k):\n"
                   "    if family == 40:\n"
                   "        raise PermissionError(errno.EPERM, 'Operation not permitted')\n"
                   "    return real(family, *a, **k)\n"
                   "socket.socket = refused\n"
                   "sys.argv = sys.argv[1:]\n"
                   "runpy.run_path(sys.argv[0], run_name='__main__')\n")
        env = {"PATH": "/usr/bin:/bin", "HERMES_HOME": home, "BROMURE_VSOCK_RELAY": relay}
        p = subprocess.Popen([sys.executable, "-I", "-c", seccomp, shim, "--hermes"], env=env,
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        def window(w):
            with open(os.path.join(home, "bromure-window"), "w") as f:
                f.write(w + "\n")
        out = {}
        def call(i):
            p.stdin.write((json.dumps({"jsonrpc": "2.0", "id": i, "method": "tools/call"}) + "\n").encode())
            p.stdin.flush()
            box = []
            t = threading.Thread(target=lambda: box.append(p.stdout.readline()), daemon=True)
            t.start(); t.join(8)
            return json.loads(box[0])["result"]["hello"] if box and box[0] else "TIMEOUT"
        time.sleep(0.6); window("w3")
        out["first"] = call(1)
        window("w7")
        out["moved"] = call(2)
        out["again"] = call(3)
        out["hellos"] = hellos
        p.kill()
        os.unlink(relay)
        print(json.dumps(out))
        """#
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-c", harness, dir.path, shim.path]
        let out = Pipe(); p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let r = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any],
                             Comment(rawValue: String(decoding: data, as: UTF8.self)))
        #expect(r["first"] as? String == "w3", "the first dial waited for the window")
        #expect(r["moved"] as? String == "w7", "the call that noticed the move is answered, as the new window")
        #expect(r["again"] as? String == "w7")
        #expect(r["hellos"] as? [String] == ["w3", "w7"])
    }

    @Test("a board task's Hermes home gets the board server; a malformed task name gets nothing")
    func applyTaskBoard() throws {
        let home = try tempDir()
        let taskHome = home.appendingPathComponent(".hermes/profiles/bt-fix-x")
        var metaDir: URL?
        let calls = try runApply(settings: ["model": ["provider": "xai"],
                                            "hooks": ["command": Profile.hermesHookGuestPath, "events": ["pre_llm_call"]]],
                                 servers: [:], home: home,
                                 env: ["HERMES_HOME": taskHome.path, "BROMURE_HERMES_TASK": "wt/fix-x"],
                                 meta: { metaDir = $0 })
        let meta = try #require(metaDir)
        #expect(calls.contains("config set mcp_servers.bromure-board {\"command\": \"python3\", \"args\": "
                               + "[\"\(meta.path)/bromure-task-mcp.py\", \"wt/fix-x\"]}"))
        // Everything lands in the task's own home, not the user's.
        #expect(FileManager.default.fileExists(atPath: taskHome.appendingPathComponent("shell-hooks-allowlist.json").path))
        #expect(FileManager.default.fileExists(atPath: taskHome.appendingPathComponent(".bromure-mcp.json").path))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".hermes/.bromure-mcp.json").path))
        for bad in ["wt/../x", "wt/Fix", "main", "wt/x y"] {
            let c = try runApply(settings: ["model": ["provider": "xai"]], servers: [:], home: try tempDir(),
                                 env: ["BROMURE_HERMES_TASK": bad])
            #expect(!c.contains { $0.contains("bromure-board") }, "\(bad)")
        }
    }

    @Test("a board task runs in its own Hermes profile: bt-<slug>, at most 64 characters, cloned once")
    func taskHome() throws {
        let rc = try renderBashrc()
        let lines = rc.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex { $0.hasSuffix("_bromure_hermes_task_home() {") })
        let end = try #require(lines[start...].firstIndex { $0 == "}" })
        #expect(rc.contains("hermes) _bromure_nous_signin ;;"), "the sign-in machine's auto-launch")
        let fn = lines[start...end].joined(separator: "\n")
        let dir = try tempDir()
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("calls.log")
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(log.path)'
        [ "$1 $2" = "profile create" ] && mkdir -p "$HOME/.hermes/profiles/$3"
        exit 0
        """.write(to: bin.appendingPathComponent("hermes"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("hermes").path)
        func home(_ branch: String) throws -> String {
            let script = fn + "\n_bromure_hermes_task_home '\(branch)' -u OPENAI_API_KEY\n"
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = ["-c", script]
            proc.environment = ["HOME": dir.path, "PATH": bin.path + ":/usr/bin:/bin:/sbin"]
            let out = Pipe(); proc.standardOutput = out
            try proc.run(); proc.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        #expect(try home("wt/fix-x") == dir.path + "/.hermes/profiles/bt-fix-x")
        #expect(try home("wt/fix-x") == dir.path + "/.hermes/profiles/bt-fix-x")
        let calls = ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n")
        #expect(calls == ["profile create bt-fix-x --clone"], "cloned once")
        let long = "wt/" + String(repeating: "a", count: 70)
        let path = try home(long)
        let name = (path as NSString).lastPathComponent
        #expect(name.count <= 64 && name.hasPrefix("bt-" + String(repeating: "a", count: 52) + "-"))
        #expect(name.range(of: "^[a-z0-9][a-z0-9_-]{0,63}$", options: .regularExpression) != nil)
        #expect(try home("wt/" + String(repeating: "a", count: 69) + "b") != path, "no collision on a shared prefix")
        // The wrapper reads the flag, keeps it from Hermes, and runs the task there.
        #expect(rc.contains("--bromure-task=wt/*) _t=\"${_v#--bromure-task=}\" ;;"))
        #expect(rc.contains("local -x HERMES_HOME BROMURE_HERMES_TASK=\"$_t\""))
        // Only wt/<slug>: no other slash, nothing outside [a-z0-9-].
        let wrapper = try #require(rc.range(of: "--bromure-task=wt/*) _t=").map { String(rc[$0.lowerBound...].prefix(600)) })
        #expect(wrapper.contains("case \"${_t#wt/}\" in *[!a-z0-9-]*) _t=\"\" ;; esac"))
    }

    // MARK: - Hermes in the base image (/opt/hermes)

    @Test("the base image installs Hermes into /opt as root, best effort, keeping root's data private")
    func imageStep() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentCoding/Resources/img-catalog.json")
        struct Step: Decodable { var uuid: String; var description: String; var command: String }
        struct Catalog: Decodable { var postinstall: [Step] }
        let cat = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        let uuids = cat.postinstall.map(\.uuid)
        #expect(Set(uuids).count == uuids.count)
        let step = try #require(cat.postinstall.first { $0.description.contains("Hermes") })
        let cmd = step.command
        #expect(cmd.contains("--non-interactive --skip-browser --skip-computer-use"))
        #expect(cmd.contains("--dir /opt/hermes/hermes-agent --hermes-home /opt/hermes"))
        #expect(cmd.contains("ln -sf /opt/hermes/hermes-agent/.hermes/bin/hermes /usr/local/bin/hermes"))
        // Never the whole data root: root's .env must stay 0600.
        #expect(!cmd.contains("chmod -R a+rX /opt/hermes\n"))
        #expect(!cmd.contains("chmod -R a+rX /opt/hermes "))
        #expect(cmd.contains("for d in /opt/hermes/hermes-agent /opt/hermes/tools /opt/hermes/installs; do"))
        #expect(cmd.contains("if [ -d \"$d\" ]; then chmod -R a+rX \"$d\"; fi"))
        // A failed install leaves nothing, so hermes falls back to installing itself.
        #expect(cmd.contains("rm -rf /opt/hermes /usr/local/bin/hermes"))
        let url2 = try tempDir().appendingPathComponent("step.sh")
        try cmd.write(to: url2, atomically: true, encoding: .utf8)
        let (status, diag) = try run("/bin/bash", ["-n", url2.path])
        #expect(status == 0, Comment(rawValue: diag))
    }

    @Test("an /opt Hermes gets `hermes pm repair` once per data root, again for another image's Hermes")
    func optReady() throws {
        let rc = try renderBashrc()
        let lines = rc.components(separatedBy: "\n")
        func fn(_ name: String) throws -> String {
            let start = try #require(lines.firstIndex { $0.hasSuffix(name + "() {") })
            let end = try #require(lines[start...].firstIndex { $0 == "}" })
            return lines[start...end].joined(separator: "\n")
        }
        // Resolved: readlink -f spells macOS's /var as /private/var.
        let dir = URL(fileURLWithPath: try #require(realpath(try tempDir().path, nil).map {
            defer { free($0) }; return String(cString: $0) }), isDirectory: true)
        let opt = dir.appendingPathComponent("opt/hermes")
        let fns = (try fn("_bromure_hermes_opt") + "\n" + fn("_bromure_hermes_opt_ready"))
            .replacingOccurrences(of: "/opt/hermes", with: opt.path)
        let launcherDir = opt.appendingPathComponent("hermes-agent/.hermes/bin")
        try FileManager.default.createDirectory(at: launcherDir, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("calls.log")
        let failFlag = dir.appendingPathComponent("fail")
        let launcher = launcherDir.appendingPathComponent("hermes")
        try """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(log.path)'
        [ -e '\(failFlag.path)' ] && exit 1
        exit 0
        """.write(to: launcher, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        let stamp = opt.appendingPathComponent("hermes-agent/install-stamp.json")
        try #"{"commit": "a"}"#.write(to: stamp, atomically: true, encoding: .utf8)
        try "model: {}\n".write(to: opt.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        let bin = dir.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: bin.appendingPathComponent("hermes").path,
                                                   withDestinationPath: launcher.path)
        let home = dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        func ready(_ extra: [String: String] = [:]) throws -> Int32 {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = ["-c", fns + "\n_bromure_hermes_opt_ready\n"]
            var env = ["HOME": home.path, "PATH": bin.path + ":/usr/bin:/bin:/sbin"]
            for (k, v) in extra { env[k] = v }
            proc.environment = env
            proc.standardOutput = Pipe()
            try proc.run(); proc.waitUntilExit()
            return proc.terminationStatus
        }
        func calls() -> [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
        // A failed repair fails the wrapper and leaves no marker: retried next time.
        FileManager.default.createFile(atPath: failFlag.path, contents: nil)
        #expect(try ready() == 1)
        try FileManager.default.removeItem(at: failFlag)
        #expect(try ready() == 0)
        #expect(try ready() == 0)
        // The failed try was tried twice (one retry for a network hiccup).
        #expect(calls() == ["pm repair", "pm repair", "pm repair"], "once after the failed try")
        let cfg = home.appendingPathComponent(".hermes/config.yaml")
        #expect((try? String(contentsOf: cfg, encoding: .utf8)) == "model: {}\n")
        let mode = try FileManager.default.attributesOfItem(atPath: cfg.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        // The image brings another Hermes: repaired again; a user's config stays.
        try "user: 1\n".write(to: cfg, atomically: true, encoding: .utf8)
        try #"{"commit": "b"}"#.write(to: stamp, atomically: true, encoding: .utf8)
        #expect(try ready() == 0)
        #expect(calls().count == 4)
        #expect((try? String(contentsOf: cfg, encoding: .utf8)) == "user: 1\n")
        // Another data root is a root of its own.
        #expect(try ready(["HERMES_HOME": dir.appendingPathComponent("other").path]) == 0)
        #expect(calls().count == 5)
        // A per-user install (not under /opt) is left alone.
        try FileManager.default.removeItem(at: bin.appendingPathComponent("hermes"))
        try FileManager.default.copyItem(at: launcher, to: bin.appendingPathComponent("hermes"))
        try #"{"commit": "c"}"#.write(to: stamp, atomically: true, encoding: .utf8)
        #expect(try ready() == 0)
        #expect(calls().count == 5)
        // The wrapper readies /opt's Hermes before any call, and sends
        // `hermes update` to a per-user install instead.
        let wrapper = try fn("hermes")
        let update = try #require(wrapper.range(of: "update|upgrade)"))
        let readyCall = try #require(wrapper.range(of: "_bromure_hermes_opt_ready || return 1"))
        #expect(update.lowerBound < readyCall.lowerBound)
        let flat = wrapper.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(flat.contains("update|upgrade) # /opt's") && flat.contains("if _bromure_hermes_opt; then _bromure_install_tool hermes; return fi ;;"))
        #expect(readyCall.lowerBound < (try #require(wrapper.range(of: "_bromure_hermes_apply"))).lowerBound)
    }

    // MARK: - Status hook + transcript mirror

    /// The hook script with its entry point stripped, its paths pointed at
    /// `dir`, then `body` run against it (python3, stdout returned).
    private func runHook(_ body: String, dir: URL) throws -> String {
        let script = Profile.hermesHookScript
            .replacingOccurrences(of: "try:\n    main()\nexcept Exception:\n    pass\nprint(\"{}\")", with: "")
        #expect(script != Profile.hermesHookScript, "entry point not found")
        let full = script + "\nMIRROR = \(String(reflecting: dir.appendingPathComponent("mirror").path))\n" + body
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = ["-c", full]
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out; proc.standardError = err
        try proc.run(); proc.waitUntilExit()
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(proc.terminationStatus == 0, Comment(rawValue: e))
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private static let fakeStateDB = #"""
    import sqlite3, json, os
    home = os.path.join(DIR, "home"); os.makedirs(home, exist_ok=True)
    con = sqlite3.connect(os.path.join(home, "state.db"))
    con.execute("create table if not exists sessions(id text primary key, cwd text, parent_session_id text)")
    con.execute("create table if not exists messages(id integer primary key autoincrement, session_id text, role text, content text, tool_call_id text, tool_calls text, timestamp real, reasoning_content text, display_kind text)")
    SID, CHILD = "20261116_120000_abcd1234", "20261116_120005_c0ffee00"
    con.execute("insert or ignore into sessions values(?,?,?)", (SID, "/home/ubuntu/wt/fix-x", None))
    con.execute("insert or ignore into sessions values(?,?,?)", (CHILD, "/home/ubuntu/wt/fix-x", SID))
    def add(sid, role, content, call=None, calls=None, thought=None, kind=None):
        con.execute("insert into messages(session_id, role, content, tool_call_id, tool_calls, timestamp, reasoning_content, display_kind) values(?,?,?,?,?,?,?,?)",
                    (sid, role, content, call, calls, 1763294400.25, thought, kind))
        con.commit()
    """#

    @Test("the hook mirrors a Hermes session into Claude-shaped JSONL, append-only, skipping system and hidden turns")
    func hookMirror() throws {
        let dir = try tempDir()
        let out = try runHook("DIR = \(String(reflecting: dir.path))\n" + Self.fakeStateDB + "\n" + #"""
        add(SID, "system", "You are Hermes")
        add(SID, "user", "list files")
        add(SID, "assistant", "", calls=json.dumps([{"id": "call_1", "type": "function", "function": {"name": "terminal", "arguments": json.dumps({"command": "ls"})}}]), thought="look first")
        add(SID, "tool", "a.txt", call="call_1")
        add(SID, "assistant", "\x00json:" + json.dumps([{"type": "text", "text": "One file."}]))
        add(SID, "user", "keep going", kind="auto_continue")
        c = open_db(home)
        cwd, parent = session_row(c, SID)
        path = mirror(c, SID, cwd, None)
        mirror(c, SID, cwd, None)
        add(SID, "user", "thanks")
        mirror(c, SID, cwd, None)
        print(path)
        print(open(path).read(), end="")
        """#, dir: dir)
        let lines = out.split(separator: "\n").map(String.init)
        #expect(lines.first == dir.path + "/mirror/-home-ubuntu-wt-fix-x/20261116_120000_abcd1234.jsonl")
        let body = lines.dropFirst().joined(separator: "\n")
        #expect(lines.count == 1 + 5, "user, assistant(tool call), tool result, assistant, the later user turn")
        #expect(!body.contains("You are Hermes") && !body.contains("keep going"))
        let items = AgentTranscript.parse(Data(body.utf8), agent: "hermes")
        let kinds = items.map { "\($0.kind)" }
        #expect(kinds.contains { $0.contains("userText") && $0.contains("list files") })
        #expect(kinds.contains { $0.contains("thinking") && $0.contains("look first") })
        #expect(kinds.contains { $0.contains("toolUse") && $0.contains("terminal") && $0.contains("ls") })
        #expect(kinds.contains { $0.contains("assistantText") && $0.contains("One file.") })
        #expect(kinds.last.map { $0.contains("thanks") } == true)
        #expect(items.allSatisfy { $0.timestamp != nil })
    }

    /// A session leased to a Hermes CLI with no tab (a one-shot
    /// `hermes chat -Q`) fell through to "the one Hermes in a tab": its
    /// transcript was reported to that tab, which then pinned -- and resumed
    /// -- a conversation that wasn't its own.
    @Test("a session leased to a CLI without a tab belongs to no tab; only an unleased one is guessed")
    func hookFindTab() throws {
        let dir = try tempDir()
        let out = try runHook("DIR = \(String(reflecting: dir.path))\n" + #"""
        import json, os
        home = os.path.join(DIR, "home"); os.makedirs(os.path.join(home, "runtime"), exist_ok=True)
        TAB = {"pid": 11, "TMUX": "/tmp/tmux-1000/default,1,0", "TMUX_PANE": "%2"}
        pane_of = lambda pid: TAB if pid == 11 else None
        json.dump({"entries": [
            {"session_id": "s-tab", "pid": 11},
            {"session_id": "s-oneshot", "pid": 22},
            {"session_id": "other", "pid": 33, "metadata": {"live_session_id": "s-live"}},
        ]}, open(os.path.join(home, "runtime", "active_sessions.json"), "w"))
        listdir = os.listdir
        os.listdir = lambda p: [] if p == "/proc" else listdir(p)
        for sid in ("s-tab", "s-oneshot", "s-live", "s-unknown"):
            tab, leased = find_tab(home, sid)
            print(sid, tab["TMUX_PANE"] if tab else None, leased)
        """#, dir: dir)
        #expect(out.split(separator: "\n").map(String.init) == [
            "s-tab %2 True", "s-oneshot None True", "s-live None True", "s-unknown None False"])
    }

    @Test("the hook reports the tab's state from the session's own CLI; a subagent's session reports nothing")
    func hookStatus() throws {
        let dir = try tempDir()
        let out = try runHook("DIR = \(String(reflecting: dir.path))\n" + Self.fakeStateDB + "\n" + #"""
        import io, sys
        add(SID, "user", "hi")
        os.environ["HERMES_HOME"] = home
        TAB = {"pid": 4242, "TMUX": "/tmp/tmux-1000/default,1,0", "TMUX_PANE": "%7"}
        reports = []
        def report(signal, tab, payload):
            reports.append((signal, tab["TMUX_PANE"], payload))
        def run(event, leased=True):
            global find_tab
            find_tab = lambda h, s: (TAB, leased) if s == SID or leased else (TAB, False)
            sys.stdin = io.StringIO(json.dumps(event))
            main()
        run({"hook_event_name": "pre_llm_call", "session_id": SID})
        run({"hook_event_name": "pre_tool_call", "session_id": SID, "tool_name": "terminal",
             "tool_input": {"command": "ls"}, "extra": {"tool_call_id": "call_9"}})
        run({"hook_event_name": "post_tool_call", "session_id": SID})
        run({"hook_event_name": "on_human_input_request", "session_id": SID})
        run({"hook_event_name": "on_session_end", "session_id": SID, "extra": {"completed": True}})
        run({"hook_event_name": "on_session_end", "session_id": CHILD}, leased=False)
        run({"hook_event_name": "pre_llm_call", "session_id": "../../etc"})
        for r in reports:
            print(json.dumps(r))
        print("child-mirrored" if any("c0ffee00" in f for _, _, fs in os.walk(MIRROR) for f in fs) else "child-skipped")
        """#, dir: dir)
        let rows = out.split(separator: "\n").map(String.init)
        let reports = rows.dropLast().compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [Any]
        }
        #expect(reports.map { $0[0] as? String } == ["working", "working", "needsInput", "done"])
        try #require(reports.count == 4)
        #expect(reports.allSatisfy { $0[1] as? String == "%7" })
        let tool = try #require(reports[1][2] as? [String: Any])
        #expect(tool["hook_event_name"] as? String == "PreToolUse")
        #expect(tool["tool_name"] as? String == "terminal" && tool["tool_use_id"] as? String == "call_9")
        #expect((tool["tool_input"] as? [String: String]) == ["command": "ls"])
        let first = try #require(reports[0][2] as? [String: Any])
        #expect((first["transcript_path"] as? String)?.hasSuffix("/-home-ubuntu-wt-fix-x/20261116_120000_abcd1234.jsonl") == true)
        #expect(first["session_id"] as? String == "20261116_120000_abcd1234")
        #expect(rows.last == "child-skipped")
        // Registered for every reported event, and staged executable.
        for e in ["pre_llm_call", "pre_tool_call", "on_session_end", "on_human_input_request", "post_tool_call"] {
            #expect(Profile.hermesHookEvents.contains(e))
        }
        #expect(Profile.hermesHookScript.hasPrefix("#!/usr/bin/python3 -I\n"))
        #expect(ACAppDelegate.hookDrivenAgents.contains("hermes"))
    }

    @Test("the chat finds Hermes's mirror by the tab's folder, the task's slug, or its age")
    func transcriptLookup() throws {
        let cmd = try #require(CodingTaskEngine.taskTranscriptCommand(branch: "wt/fix-x", agent: .hermes))
        #expect(cmd.contains("$HOME/.hermes/bromure-transcripts"))
        #expect(cmd.contains("/*-fix-x"))
        #expect(CodingTaskEngine.transcriptAgeCommand(slug: "fix-x", agent: .hermes) != nil)
        let live = AgentSessionLocator.locateBlock(path: "/home/ubuntu/wt/fix-x", since: 0, agent: "hermes")
        #expect(live.contains(".hermes/bromure-transcripts/$h1"))
        let any = AgentSessionLocator.locateBlock(path: "/home/ubuntu/wt/fix-x", since: 0, agent: nil)
        #expect(any.contains("\"$th\""))
        // The folder rule is Claude's: every non-alphanumeric of the cwd as '-'.
        #expect(live.contains("h1=$(printf %s \"$d\" | tr -c 'a-zA-Z0-9' '-')"))
        #expect(live.contains("-maxdepth 1 -name '*.jsonl'"))
    }

    // MARK: - Host side

    @Test("the staged settings follow the provider Hermes is switched to")
    func settings() throws {
        var p = Profile(name: "ws", tool: .hermes, authMode: .token, apiKey: "k")
        var s = try #require(SessionDisk.hermesSettings(profile: p))
        #expect((s["model"] as? [String: String]) == ["provider": "anthropic"])
        #expect(s["adopt_external_logins"] as? Bool == false)
        #expect(s["key_var"] as? String == "ANTHROPIC_API_KEY")
        let hooks = try #require(s["hooks"] as? [String: Any])
        #expect(hooks["command"] as? String == "/home/ubuntu/.bromure/hermes-hook.py")
        #expect(hooks["events"] as? [String] == Profile.hermesHookEvents)

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
        // A board task: its own Hermes home, by the wrapper's flag.
        #expect(src.contains("if tool == \"hermes\":\n        return \" --bromure-task=\" + branch"))
    }

    @Test("config import carries Hermes's persona and skills, never its keys or session store")
    func configScan() throws {
        let src = try #require(AgentConfigScan.sources.first { $0.tool == .hermes })
        #expect(src.dir == ".hermes")
        for d in [".env", "auth.json", "config.yaml", "state.db", "mcp-tokens", "hermes-agent", "profiles"] {
            #expect(src.deny.contains(d), "\(d) not denied")
        }
    }

    @Test("the Nous sign-in: a sign-in machine's data root on local disk, its login copied where the Mac reads it")
    func nousSignin() throws {
        let rc = try renderBashrc()
        let lines = rc.components(separatedBy: "\n")
        let start = try #require(lines.firstIndex { $0.hasSuffix("_bromure_nous_signin() {") })
        let end = try #require(lines[start...].firstIndex { $0 == "}" })
        let dir = try tempDir()
        let local = dir.appendingPathComponent("local-root")
        let home = dir.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".hermes/shared"),
                                                withIntermediateDirectories: true)
        let fn = lines[start...end].joined(separator: "\n")
            .replacingOccurrences(of: "/var/tmp/bromure-hermes-signin", with: local.path)
        // Stubs: /opt's Hermes, whose login writes auth.json in its data root.
        let stubs = """
        _bromure_hermes_opt() { return 0; }
        hermes() {
            printf '%s|%s\\n' "${HERMES_HOME:-unset}" "$*" > "$HOME/call"
            [ -n "${HERMES_HOME:-}" ] && printf '{"providers":{"nous":{}}}' > "$HERMES_HOME/auth.json"
            return 0
        }
        """
        func run(register: Bool) throws -> Int32 {
            FileManager.default.createFile(atPath: home.appendingPathComponent(".hermes/shared/nous_auth.json").path,
                                           contents: Data("x".utf8))
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = ["-c", stubs + "\n" + fn + "\n_bromure_nous_signin\n"]
            var env = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            if register { env["BROMURE_AC_REGISTER"] = "1" }
            proc.environment = env
            proc.standardOutput = Pipe(); proc.standardError = Pipe()
            try proc.run(); proc.waitUntilExit()
            return proc.terminationStatus
        }
        func call() -> String { (try? String(contentsOf: home.appendingPathComponent("call"), encoding: .utf8)) ?? "" }
        let shared = home.appendingPathComponent(".hermes/shared/nous_auth.json").path
        let landed = home.appendingPathComponent(".hermes/auth.json")

        // In a workspace: Hermes's own data root, nothing copied.
        #expect(try run(register: false) == 0)
        #expect(call() == "unset|auth add nous --type oauth\n")
        #expect(!FileManager.default.fileExists(atPath: shared))
        #expect(!FileManager.default.fileExists(atPath: landed.path))

        // In a sign-in machine: the local data root; the login lands in ~/.hermes.
        #expect(try run(register: true) == 0)
        #expect(call() == "\(local.path)|auth add nous --type oauth\n")
        #expect(!FileManager.default.fileExists(atPath: shared))
        #expect((try? String(contentsOf: landed, encoding: .utf8)) == #"{"providers":{"nous":{}}}"#)
        let mode = try FileManager.default.attributesOfItem(atPath: landed.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }
}
