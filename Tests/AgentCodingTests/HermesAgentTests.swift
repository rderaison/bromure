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
        #expect(again.contains("config unset mcp_servers.docs\\.v2"))
        #expect(!again.contains("config unset mcp_servers.browser"))
        // (Unsetting what was never set didn't fail the run: status 0.)
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
        #expect(rc.contains("command env \"$@\" -u BROMURE_HERMES_API_KEY python3 -"))
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
        #expect(calls() == ["pm repair", "pm repair"], "once after the failed try")
        let cfg = home.appendingPathComponent(".hermes/config.yaml")
        #expect((try? String(contentsOf: cfg, encoding: .utf8)) == "model: {}\n")
        let mode = try FileManager.default.attributesOfItem(atPath: cfg.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        // The image brings another Hermes: repaired again; a user's config stays.
        try "user: 1\n".write(to: cfg, atomically: true, encoding: .utf8)
        try #"{"commit": "b"}"#.write(to: stamp, atomically: true, encoding: .utf8)
        #expect(try ready() == 0)
        #expect(calls().count == 3)
        #expect((try? String(contentsOf: cfg, encoding: .utf8)) == "user: 1\n")
        // Another data root is a root of its own.
        #expect(try ready(["HERMES_HOME": dir.appendingPathComponent("other").path]) == 0)
        #expect(calls().count == 4)
        // A per-user install (not under /opt) is left alone.
        try FileManager.default.removeItem(at: bin.appendingPathComponent("hermes"))
        try FileManager.default.copyItem(at: launcher, to: bin.appendingPathComponent("hermes"))
        try #"{"commit": "c"}"#.write(to: stamp, atomically: true, encoding: .utf8)
        #expect(try ready() == 0)
        #expect(calls().count == 4)
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
