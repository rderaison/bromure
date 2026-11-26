import Foundation
import Testing
@testable import bromure_ac

/// Claude Code's /ship and /steward (2.1.330+): the watch read off the
/// transcript in the guest and carried on the tab's status line, the session
/// saying so, the Mac kept awake, the workspace switch (skillOverrides), and
/// the branch's Pull Request action handing over to /ship where it can.
@Suite("Claude Code /ship support", .serialized)
struct ClaudeShipTests {
    private static let python = "/usr/bin/python3"
    private static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    // MARK: Pure parts

    @Test("Claude Code 2.1.330 and later have /ship")
    func versions() {
        #expect(ClaudeShip.supports(versionOutput: "2.1.330 (Claude Code)"))
        #expect(ClaudeShip.supports(versionOutput: "2.1.331 (Claude Code)"))
        #expect(ClaudeShip.supports(versionOutput: "2.2.0 (Claude Code)"))
        #expect(ClaudeShip.supports(versionOutput: "3.0.1"))
        #expect(!ClaudeShip.supports(versionOutput: "2.1.329 (Claude Code)"))
        #expect(!ClaudeShip.supports(versionOutput: "2.1.296 (Claude Code)"))
        #expect(!ClaudeShip.supports(versionOutput: ""))
        #expect(!ClaudeShip.supports(versionOutput: "claude: command not found"))
    }

    @Test("A status report's third line says what the tab watches")
    func statusLine() {
        #expect(ClaudeShip.watch(inStatus: "done\nabc") == nil)
        #expect(ClaudeShip.watch(inStatus: "done") == nil)
        #expect(ClaudeShip.watch(inStatus: "done\nabc\nship") == .some(nil))
        #expect(ClaudeShip.watch(inStatus: "done\n\nship #41") == .some("#41"))
        #expect(ClaudeShip.watch(inStatus: "done\nabc\nship feature/login-fix") == .some("feature/login-fix"))
        // Not ours to show: replaced by "a watch whose target couldn't be read".
        #expect(ClaudeShip.watch(inStatus: "done\nabc\nship <script>") == .some(""))
        #expect(ClaudeShip.watch(inStatus: "done\nabc\nship #0") == .some(""))
        #expect(ClaudeShip.watch(inStatus: "done\nabc\nshipping") == nil)
        #expect(ClaudeShip.label("#41").contains("#41"))
        #expect(ClaudeShip.label("feature/x") == "feature/x")
    }

    @Test("skillOverrides: both skills off, or Bromure's entries gone; the user's kept")
    func overrides() {
        let off = ClaudeShip.skillOverrides(["my-skill": "name-only"], allowed: false, owned: [:])
        #expect(off.overrides?["ship-local"] as? String == "off")
        #expect(off.overrides?["steward"] as? String == "off")
        #expect(off.overrides?["my-skill"] as? String == "name-only")
        #expect(off.owned["ship-local"] is NSNull && off.owned["steward"] is NSNull)
        let on = ClaudeShip.skillOverrides(off.overrides, allowed: true, owned: off.owned)
        #expect(on.overrides?["ship-local"] == nil && on.overrides?["steward"] == nil)
        #expect(on.overrides?["my-skill"] as? String == "name-only")
        #expect(on.owned.isEmpty)
        #expect(ClaudeShip.skillOverrides(nil, allowed: true, owned: [:]).overrides == nil)
        // A user's own setting other than "off" isn't Bromure's to take back,
        // and comes back once the switch is on again.
        let mixed = ClaudeShip.skillOverrides(["steward": "user-invocable-only"], allowed: false, owned: [:])
        #expect(mixed.overrides?["steward"] as? String == "off")
        #expect(ClaudeShip.skillOverrides(mixed.overrides, allowed: true, owned: mixed.owned)
                    .overrides?["steward"] as? String == "user-invocable-only")
    }

    @Test("A skill the user turned off stays off when the switch is on (CWE-693)")
    func userOffKept() {
        // The finding: switch on (the default), the user's own "off" entries
        // were deleted, re-enabling /ship and /steward.
        let user: [String: Any] = ["ship-local": "off", "steward": "off"]
        let on = ClaudeShip.skillOverrides(user, allowed: true, owned: [:])
        #expect(on.overrides?["ship-local"] as? String == "off")
        #expect(on.overrides?["steward"] as? String == "off")
        #expect(on.owned.isEmpty)
        // Switched off then on again: the user's entries were never Bromure's.
        let off = ClaudeShip.skillOverrides(user, allowed: false, owned: [:])
        #expect(off.owned.isEmpty)
        let back = ClaudeShip.skillOverrides(off.overrides, allowed: true, owned: off.owned)
        #expect(back.overrides?["ship-local"] as? String == "off")
        #expect(back.overrides?["steward"] as? String == "off")
        // An entry Bromure wrote that the user changed since is theirs again.
        let changed = ClaudeShip.skillOverrides(["ship-local": "name-only", "steward": "off"], allowed: true,
                                                owned: ["ship-local": NSNull(), "steward": NSNull()])
        #expect(changed.overrides?["ship-local"] as? String == "name-only")
        #expect(changed.overrides?["steward"] == nil)
    }

    @Test("The host's settings writer leaves a user's own \"off\" alone, and takes back only its own")
    func hostWriterKeepsUserOff() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shipoff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDir: root)
        var p = Profile(name: "ws", tool: .claude, authMode: .token)
        let claudeDir = store.homeDirectory(for: p).appendingPathComponent(".claude")
        let settingsURL = claudeDir.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try #"{"skillOverrides": {"ship-local": "off"}}"#.write(to: settingsURL, atomically: true, encoding: .utf8)
        func overrides() -> [String: Any] {
            guard let d = try? Data(contentsOf: settingsURL),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
            return o["skillOverrides"] as? [String: Any] ?? [:]
        }
        try store.prepareHomeDirectory(for: p, terminalDefaults: .fallback)
        #expect(overrides()["ship-local"] as? String == "off")
        #expect(overrides()["steward"] == nil)
        p.claudeShipDisabled = true
        try store.prepareHomeDirectory(for: p, terminalDefaults: .fallback)
        #expect(overrides()["ship-local"] as? String == "off")
        #expect(overrides()["steward"] as? String == "off")
        p.claudeShipDisabled = false
        try store.prepareHomeDirectory(for: p, terminalDefaults: .fallback)
        #expect(overrides()["ship-local"] as? String == "off")
        #expect(overrides()["steward"] == nil)
        #expect(!FileManager.default.fileExists(
            atPath: claudeDir.appendingPathComponent(ClaudeShip.ownedOverridesFile).path))
    }

    @Test("bromure-agentd's twin leaves a user's own \"off\" alone too",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func guestWriterKeepsUserOff() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shipoff-g-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let guestHome = root.appendingPathComponent("guest-home"), seedIn = root.appendingPathComponent("guest-seed")
        let settingsURL = guestHome.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: guestHome.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: seedIn, withIntermediateDirectories: true)
        try #"{"skillOverrides": {"ship-local": "off"}}"#.write(to: settingsURL, atomically: true, encoding: .utf8)
        func seed(ship: Bool) throws -> [String: Any] {
            try #"{"usesClaude": true, "claudeShip": \#(ship)}"#
                .write(to: seedIn.appendingPathComponent("claude-settings.spec.json"), atomically: true, encoding: .utf8)
            let py = Process()
            py.executableURL = URL(fileURLWithPath: Self.python)
            py.arguments = ["-I", "-c", """
                import importlib.util, sys, os
                s = importlib.util.spec_from_file_location('agentd', sys.argv[1])
                m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
                m.SEED_DIR = sys.argv[2]; m.HOME_MOUNT = sys.argv[3]; m.HOME = sys.argv[3]
                m._approve_claude_api_key = lambda *a: None; m._preonboard_claude = lambda *a: None
                m.log = lambda *a: None
                os.chown = lambda *a, **k: None
                m._seed_claude_settings()
                """, Self.repo.appendingPathComponent("Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py").path,
                seedIn.path, guestHome.path]
            py.standardError = FileHandle.nullDevice
            try py.run(); py.waitUntilExit()
            guard let d = try? Data(contentsOf: settingsURL),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
            return o["skillOverrides"] as? [String: Any] ?? [:]
        }
        var o = try seed(ship: true)
        #expect(o["ship-local"] as? String == "off")
        #expect(o["steward"] == nil)
        o = try seed(ship: false)
        #expect(o["ship-local"] as? String == "off" && o["steward"] as? String == "off")
        o = try seed(ship: true)
        #expect(o["ship-local"] as? String == "off")
        #expect(o["steward"] == nil)
    }

    @Test("/ship opens the pull request only on github.com, into the default branch, with a Claude Code that has it")
    func canShip() {
        let f = ClaudeShip.Facts.parse("claude 2.1.331 (Claude Code)\norigin git@github.com:acme/app.git\nhead origin/main\n")
        #expect(f == ClaudeShip.Facts(claudeVersion: "2.1.331 (Claude Code)", origin: "git@github.com:acme/app.git",
                                      defaultBranch: "main"))
        #expect(ClaudeShip.canShip(f, into: "main"))
        #expect(!ClaudeShip.canShip(f, into: "develop"))
        var old = f; old.claudeVersion = "2.1.296 (Claude Code)"
        #expect(!ClaudeShip.canShip(old, into: "main"))
        var none = f; none.claudeVersion = ""
        #expect(!ClaudeShip.canShip(none, into: "main"))
        var ghe = f; ghe.origin = "https://github.acme.corp/acme/app.git"
        #expect(!ClaudeShip.canShip(ghe, into: "main"))
        var lab = f; lab.origin = "https://gitlab.com/acme/app.git"
        #expect(!ClaudeShip.canShip(lab, into: "main"))
        var https = f; https.origin = "https://github.com/acme/app.git"
        #expect(ClaudeShip.canShip(https, into: "main"))
        var noHead = f; noHead.defaultBranch = ""
        #expect(!ClaudeShip.canShip(noHead, into: "main"))
        #expect(ClaudeShip.githubHost("ssh://git@GitHub.com/acme/app.git") == "github.com")
        #expect(ClaudeShip.githubHost("") == nil)
        #expect(ClaudeShip.Facts.parse("claude \norigin \nhead \n") == ClaudeShip.Facts(claudeVersion: "", origin: "", defaultBranch: ""))
    }

    // MARK: The session

    @MainActor
    @Test("The session says what it watches; a stale or unbound watch says nothing and holds nothing")
    func sessionWatch() {
        let store = AgentSessionStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("ship-sessions-\(UUID().uuidString).json"))
        let pid = UUID()
        let s = AgentSession(profileID: pid, tool: .claude, title: "t", cwd: "~/app", windowIndex: 3)
        store.upsert(s)
        let now = Date()
        store.setShipWatch(s.id, "#41", now: now)
        var got = store.session(s.id)!
        #expect(SessionHome.shipWatching(got, now: now) == "#41")
        #expect(store.liveShipWatches(now: now) == 1)
        // Not heard from for longer than a wake-up can wait: gone.
        let later = now.addingTimeInterval(ClaudeShip.staleAfter + 1)
        #expect(SessionHome.shipWatching(got, now: later) == nil)
        #expect(store.liveShipWatches(now: later) == 0)
        // A turn's end with no watch clears it.
        store.setShipWatch(s.id, nil, now: now)
        got = store.session(s.id)!
        #expect(got.shipWatch == nil && got.shipWatchSeen == nil)
        // The tab going away takes it too.
        store.setShipWatch(s.id, "#41", now: now)
        store.mutate(s.id) { $0.windowIndex = nil }
        #expect(store.session(s.id)?.shipWatch == nil)
        #expect(store.liveShipWatches(now: now) == 0)
        // The machine stopping clears every tab of it.
        store.mutate(s.id) { $0.windowIndex = 4 }
        store.setShipWatch(s.id, "feature/x", now: now)
        store.clearShipWatches(profileID: pid)
        #expect(store.session(s.id)?.shipWatch == nil)
    }

    @MainActor
    @Test("The keep-awake follows the live watches")
    func keepAwake() {
        let awake = ShipWatchAwake.shared
        let saved = awake.provider
        defer { awake.provider = saved; awake.refresh() }
        awake.provider = { 1 }
        awake.refresh()
        #expect(awake.isHolding)
        awake.provider = { 0 }
        awake.refresh()
        #expect(!awake.isHolding)
    }

    // MARK: The workspace switch

    private func settings(_ url: URL) -> [String: Any] {
        guard let d = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return o
    }

    @Test("The host's settings writer: allowed by default, off when the workspace says so, the user's overrides kept; the scanner is staged")
    func hostWriter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ship-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(rootDir: root)
        var p = Profile(name: "ws", tool: .claude, authMode: .token)
        let home = store.homeDirectory(for: p)
        let claudeDir = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try #"{"skillOverrides": {"my-skill": "off"}}"#
            .write(to: claudeDir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

        try store.prepareHomeDirectory(for: p, terminalDefaults: .fallback)
        var o = settings(claudeDir.appendingPathComponent("settings.json"))["skillOverrides"] as? [String: Any]
        #expect(o?["ship-local"] == nil && o?["steward"] == nil)
        #expect(o?["my-skill"] as? String == "off")

        p.claudeShipDisabled = true
        try store.prepareHomeDirectory(for: p, terminalDefaults: .fallback)
        o = settings(claudeDir.appendingPathComponent("settings.json"))["skillOverrides"] as? [String: Any]
        #expect(o?["ship-local"] as? String == "off" && o?["steward"] as? String == "off")
        #expect(o?["my-skill"] as? String == "off")

        p.claudeShipDisabled = false
        try store.prepareHomeDirectory(for: p, terminalDefaults: .fallback)
        o = settings(claudeDir.appendingPathComponent("settings.json"))["skillOverrides"] as? [String: Any]
        #expect(o?["ship-local"] == nil && o?["steward"] == nil)

        let scanner = try String(contentsOf: home.appendingPathComponent(".bromure/ship-watch.py"), encoding: .utf8)
        #expect(scanner == ClaudeShip.scannerScript)
        let status = try String(contentsOf: home.appendingPathComponent(".bromure/agent-status.sh"), encoding: .utf8)
        #expect(status.contains("ship-watch.py"))
    }

    @Test("The profile keeps the switch, and only writes it when off")
    func profileCodable() throws {
        var p = Profile(name: "ws", tool: .claude, authMode: .token)
        let on = try JSONEncoder().encode(p)
        #expect(!String(decoding: on, as: UTF8.self).contains("claudeShipDisabled"))
        #expect(try JSONDecoder().decode(Profile.self, from: on).claudeShipDisabled == false)
        p.claudeShipDisabled = true
        let off = try JSONEncoder().encode(p)
        #expect(try JSONDecoder().decode(Profile.self, from: off).claudeShipDisabled == true)
    }

    @Test("bromure-agentd's twin does the same in the guest",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func guestWriter() throws {
        for allowed in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("ship-g-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let guestHome = root.appendingPathComponent("guest-home"), seedIn = root.appendingPathComponent("guest-seed")
            try FileManager.default.createDirectory(at: guestHome.appendingPathComponent(".claude"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: seedIn, withIntermediateDirectories: true)
            try #"{"skillOverrides": {"my-skill": "off", "steward": "off"}}"#
                .write(to: guestHome.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
            try #"{"usesClaude": true, "claudeShip": \#(allowed)}"#
                .write(to: seedIn.appendingPathComponent("claude-settings.spec.json"), atomically: true, encoding: .utf8)
            let agentd = Self.repo.appendingPathComponent("Sources/AgentCoding/Resources/vm-setup/bromure-agentd.py")
            let py = Process()
            py.executableURL = URL(fileURLWithPath: Self.python)
            py.arguments = ["-I", "-c", """
                import importlib.util, sys, os
                s = importlib.util.spec_from_file_location('agentd', sys.argv[1])
                m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
                m.SEED_DIR = sys.argv[2]; m.HOME_MOUNT = sys.argv[3]; m.HOME = sys.argv[3]
                m._approve_claude_api_key = lambda *a: None; m._preonboard_claude = lambda *a: None
                m.log = lambda *a: None
                os.chown = lambda *a, **k: None
                m._seed_claude_settings()
                """, agentd.path, seedIn.path, guestHome.path]
            py.standardError = FileHandle.nullDevice
            try py.run(); py.waitUntilExit()
            #expect(py.terminationStatus == 0)
            let o = settings(guestHome.appendingPathComponent(".claude/settings.json"))["skillOverrides"] as? [String: Any]
            #expect(o?["my-skill"] as? String == "off")
            if allowed {
                // The user's own "off" stays (CWE-693); nothing else is added.
                #expect(o?["ship-local"] == nil && o?["steward"] as? String == "off")
            } else {
                #expect(o?["ship-local"] as? String == "off" && o?["steward"] as? String == "off")
            }
        }
    }

    // MARK: The scanner, on Claude Code's own records

    private func scan(_ records: [[String: Any]]) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ship-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("ship-watch.py")
        try ClaudeShip.scannerScript.write(to: script, atomically: true, encoding: .utf8)
        let transcript = dir.appendingPathComponent("t.jsonl")
        let lines = try records.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        try (lines.joined(separator: "\n") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: Self.python)
        p.arguments = ["-I", script.path, transcript.path]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(errData.isEmpty, "\(String(decoding: errData, as: UTF8.self))")
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func command(_ name: String, _ args: String) -> [String: Any] {
        ["type": "user", "message": ["role": "user", "content":
            "<command-message>\(name.dropFirst())</command-message>\n<command-name>\(name)</command-name>\n<command-args>\(args)</command-args>"]]
    }
    private func skill(_ text: String) -> [String: Any] {
        ["type": "user", "isMeta": true, "message": ["role": "user", "content": [["type": "text", "text": text]]]]
    }
    private func info(_ text: String) -> [String: Any] {
        ["type": "system", "subtype": "informational", "content": text]
    }
    private func reply(_ text: String) -> [String: Any] {
        ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": text]]]]
    }

    /// agent-status.sh as staged, run for one hook event; the tab's status file.
    private func runStatusHook(arg: String, event: String, transcript: URL?, scanner: Bool = true) throws -> String {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ship-hook-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let seed = root.appendingPathComponent("seed")
        try ProfileStore(rootDir: root).writeHomeSeedFiles(for: Profile(name: "ws", tool: .claude, authMode: .token),
                                                           into: seed, terminalDefaults: .fallback)
        let body = try String(contentsOf: seed.appendingPathComponent("files/.bromure/agent-status.sh"), encoding: .utf8)
        let outbox = root.appendingPathComponent("outbox")
        try fm.createDirectory(at: outbox, withIntermediateDirectories: true)
        let installed = try PolicyNoteDeliveryTests.installHook(
            body.replacingOccurrences(of: "d=/mnt/bromure-outbox", with: "d=\(outbox.path)"),
            root: root, meta: root.appendingPathComponent("meta"))
        let bin = root.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try "#!/bin/sh\necho 3\n".write(to: bin.appendingPathComponent("tmux"), atomically: true, encoding: .utf8)
        chmod(bin.appendingPathComponent("tmux").path, 0o755)
        let home = root.appendingPathComponent("home")
        try fm.createDirectory(at: home.appendingPathComponent(".bromure"), withIntermediateDirectories: true)
        if scanner {
            try fm.copyItem(at: seed.appendingPathComponent("files/.bromure/ship-watch.py"),
                            to: home.appendingPathComponent(".bromure/ship-watch.py"))
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [installed.hook.path, arg]
        proc.environment = ["HOME": home.path, "TMUX_PANE": "%1", "PATH": bin.path + ":/usr/bin:/bin"]
        let input = Pipe()
        proc.standardInput = input; proc.standardOutput = Pipe()
        try proc.run()
        let tp = transcript.map { #","transcript_path":"\#($0.path)""# } ?? ""
        input.fileHandleForWriting.write(Data(#"{"hook_event_name":"\#(event)","session_id":"s-1"\#(tp)}"#.utf8))
        try input.fileHandleForWriting.close()
        proc.waitUntilExit()
        return try String(contentsOf: outbox.appendingPathComponent("agent-status-3.txt"), encoding: .utf8)
    }

    @Test("agent-status.sh reports the watch on a turn's end, and only then",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func statusHook() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ship-tp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let watching = dir.appendingPathComponent("w.jsonl"), idle = dir.appendingPathComponent("i.jsonl")
        let line = { (o: [String: Any]) in String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self) }
        try [command("/ship", ""), skill("# /ship-local: watch pull request #41")].map(line).joined(separator: "\n")
            .write(to: watching, atomically: true, encoding: .utf8)
        try [reply("hi")].map(line).joined(separator: "\n").write(to: idle, atomically: true, encoding: .utf8)

        let w = try runStatusHook(arg: "stop", event: "Stop", transcript: watching)
        #expect(w == "done\ns-1\nship #41")
        #expect(ClaudeShip.watch(inStatus: w) == .some("#41"))
        #expect(try runStatusHook(arg: "stop", event: "Stop", transcript: idle) == "done\ns-1\nship")
        // Not a turn's end: nothing said about it (the host keeps what it had).
        #expect(try runStatusHook(arg: "working", event: "PreToolUse", transcript: watching) == "working\ns-1")
        // No scanner (a home staged before this) or no transcript: as before.
        #expect(try runStatusHook(arg: "stop", event: "Stop", transcript: watching, scanner: false) == "done\ns-1")
        #expect(try runStatusHook(arg: "stop", event: "Stop", transcript: nil) == "done\ns-1")
    }

    @Test("The scanner reads the watch Claude Code's own markers show",
          .enabled(if: FileManager.default.isExecutableFile(atPath: python)))
    func scanner() throws {
        let started = [command("/ship", ""), skill("# /ship-local: review pull request #41\n\nReview it, then watch it."),
                       reply("Opened #41.")]
        #expect(try scan(started) == "#41")
        #expect(try scan(started + [command("/steward", "--tend 41"), skill("# /steward: tend"), reply("checks pass")]) == "#41")
        #expect(try scan(started + [info("Stopped watching pull request #41.")]) == "")
        #expect(try scan(started + [command("/ship", "stop")]) == "")
        #expect(try scan(started + [command("/steward", "--tend 41"),
                                    skill("Tell the user this: /steward: the watch of #41 has ended: merged")]) == "")
        #expect(try scan([command("/steward", ""), skill("# /steward: a pass over pull request #7")]) == "")
        #expect(try scan([command("/ship", ""), skill("# /ship-local: watch feature/x, with git alone")]) == "feature/x")
        // A cleared conversation: only the wake-ups are left.
        #expect(try scan([command("/steward", "--tend 52"), reply("nothing new")]) == "#52")
        #expect(try scan([command("/steward", "--tend 9123456789")]) == "?")
        // …which the host takes as a watch it can't name.
        #expect(ClaudeShip.watch(inStatus: "done\ns\nship ?") == .some(""))
        // Stopped, then started again.
        #expect(try scan(started + [command("/ship", "stop"), command("/steward", "41"),
                                    skill("# /steward: watch pull request #41")]) == "#41")
        #expect(try scan([reply("hi"), ["type": "user", "message": ["content": "hello"]]]) == "")
        // A plain message mentioning /ship is not the command.
        #expect(try scan([["type": "user", "message": ["content": "should I /ship this?"]]]) == "")
    }
}
