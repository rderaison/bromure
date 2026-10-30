import ArgumentParser
import Darwin
import Foundation

// MARK: - `bromure-ac instance …`
//
// Run a build on a state, and talk to the instance that results
// (BUILD_INSTRUCTIONS.md, "Builds and instances"). The state's control socket is the only
// channel: /health says who serves the state, POST /app/quit is the menu's
// drain without the dialog. Nothing here signals a process.

struct InstanceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "instance",
        abstract: "Run a build on a state and talk to the instance: start, stop, restart, ls, cli, health, bin-path.",
        discussion: """
            A state is served by one instance at a time (`<state>/instance.lock`); the build serving it is \
            whatever `start` was given (`--build`, default `stable`). `start` launches through `open -n`, so \
            the app is a LaunchServices child like a Dock launch and outlives this terminal; `--direct` spawns \
            the binary instead. The default state, "work", starts with a window; any other state starts \
            `--hidden` (no Dock icon, never takes focus) unless told otherwise.
            """,
        subcommands: [InstanceStart.self, InstanceStop.self, InstanceRestart.self, InstanceList.self,
                      InstanceCli.self, InstanceHealth.self, InstanceBinPath.self],
        defaultSubcommand: InstanceList.self)
}

/// What the `instance` verbs share: resolving a state, reaching its socket,
/// starting and stopping the app on it.
enum Instances {
    enum Mode: String, EnumerableFlag {
        case gui, hidden, headless

        static func help(for value: Mode) -> ArgumentHelp? {
            switch value {
            case .gui: return "A window and a Dock icon (the default for work)."
            case .hidden: return "Windows may open but never come forward: no Dock icon, no activation (the default elsewhere)."
            case .headless: return "The agent only, no window."
            }
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    /// "work" (whether or not its folder exists yet: `run` creates it) or an
    /// existing named state.
    static func state(_ raw: String) throws -> StateStore.Entry {
        if raw == ACSupportDir.defaultStateName || raw == ACSupportDir.name {
            return StateStore.entry(name: ACSupportDir.defaultStateName, url: ACSupportDir.defaultStateURL, isDefault: true)
        }
        do { return try StateStore.existing(raw) }
        catch let e as StateStore.Failure { throw Failure("\(e) (bromure-ac state create \(raw) …)") }
    }

    static func socketPath(_ e: StateStore.Entry) -> String {
        e.url.appendingPathComponent("control.sock").path
    }

    /// `GET /health` on the state's socket; nil when nothing answers.
    static func health(_ e: StateStore.Entry) -> [String: Any]? {
        guard let r = try? ControlClient(socketPath: socketPath(e)).request("GET", "/health", recvTimeoutSeconds: 3),
              r.status == 200 else { return nil }
        return r.json
    }

    /// The CLI of the build serving (or, when stopped, the last to serve) the
    /// state, from `instance.json`; nil when there is none or it is gone.
    static func servingBinary(_ e: StateStore.Entry) -> URL? {
        guard let info = ACInstance.read(stateURL: e.url) else { return nil }
        let bin = URL(fileURLWithPath: info.bundlePath).appendingPathComponent("Contents/MacOS/bromure-ac")
        return FileManager.default.isExecutableFile(atPath: bin.path) ? bin : nil
    }

    /// The serving build's CLI, else stable's.
    static func binary(for e: StateStore.Entry) throws -> URL {
        if let b = servingBinary(e) { return b }
        guard let s = BuildStore.stable else { throw BuildStore.Failure.noStable }
        return s.binaryURL
    }

    static func defaultMode(for e: StateStore.Entry) -> Mode { e.isDefault ? .gui : .hidden }

    // MARK: Start

    /// Launch `build` on `state` and wait for its /health (60 s). Through
    /// `open -n` (a new instance despite the shared bundle ID; launchd is the
    /// parent, stdout/err go to `<logs>/instance.log`), or `direct`ly as a
    /// child of this process with the same log.
    @discardableResult
    static func start(state e: StateStore.Entry, build: BuildStore.Build, mode: Mode,
                      extraEnv: [String], direct: Bool) throws -> [String: Any] {
        if let h = health(e) {
            throw Failure("state '\(e.name)' is already running: pid \(h["pid"] ?? "?"), build \(h["build"] ?? "?")")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: e.logsURL, withIntermediateDirectories: true)
        let log = e.logsURL.appendingPathComponent("instance.log")
        if !fm.fileExists(atPath: log.path) { fm.createFile(atPath: log.path, contents: nil) }

        var env: [String: String] = ["BROMURE_STATE": e.name]
        if !e.isDefault {
            // An agent's instance: scriptable out of the box (an ephemeral
            // automation port, the debug routes for /debug/ui-shot).
            env["BROMURE_AC_AUTOMATION_PORT"] = "0"
            env["BROMURE_DEBUG_CLAUDE"] = "1"
        }
        for kv in extraEnv {
            guard let eq = kv.firstIndex(of: "=") else { throw Failure("--env takes KEY=VALUE, not '\(kv)'") }
            env[String(kv[..<eq])] = String(kv[kv.index(after: eq)...])
        }
        var args = ["run"]
        switch mode {
        case .gui: break
        case .hidden: args.append("--hidden")
        case .headless: args.append("--headless")
        }

        var child: Process?
        if direct {
            let p = Process()
            p.executableURL = build.binaryURL
            p.arguments = args
            p.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
            let fh = try FileHandle(forWritingTo: log)
            fh.seekToEndOfFile()
            p.standardInput = FileHandle.nullDevice
            p.standardOutput = fh
            p.standardError = fh
            do { try p.run() } catch { throw Failure("can't start \(build.binaryURL.path): \(error.localizedDescription)") }
            child = p
        } else {
            var oargs = ["-n"]
            if mode != .gui { oargs.append("-g") }   // don't bring it forward
            oargs += ["--stdout", log.path, "--stderr", log.path]
            for (k, v) in env.sorted(by: { $0.key < $1.key }) { oargs += ["--env", "\(k)=\(v)"] }
            oargs += [build.appURL.path, "--args"] + args
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = oargs
            do { try p.run() } catch { throw Failure("can't run /usr/bin/open: \(error.localizedDescription)") }
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw Failure("open exited \(p.terminationStatus) launching \(build.appURL.path)") }
        }

        for _ in 0..<120 {
            if let h = health(e) { return h }
            if let child, !child.isRunning {
                throw Failure("instance exited early (status \(child.terminationStatus)); \(log.path):\n\(tail(log))")
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw Failure("no /health from '\(e.name)' after 60s; \(log.path):\n\(tail(log))")
    }

    private static func tail(_ log: URL, lines: Int = 5) -> String {
        guard let s = try? String(contentsOf: log, encoding: .utf8) else { return "" }
        return s.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }

    // MARK: Stop

    /// `POST /app/quit` and wait (3 min) for the pid to go. `vms` overrides
    /// every workspace's close action ("suspend" | "shutdown"); nil keeps each
    /// one's own. False when nothing was running.
    @discardableResult
    static func stop(state e: StateStore.Entry, vms: String?) throws -> Bool {
        guard let h = health(e), let pid = h["pid"] as? Int else { return false }
        let body: [String: Any] = vms.map { ["vms": $0] } ?? [:]
        let r = try ControlClient(socketPath: socketPath(e)).request("POST", "/app/quit", body: body)
        guard r.status == 202 else {
            throw Failure("'\(e.name)' refused to quit: \(r.json["error"] as? String ?? "HTTP \(r.status)")")
        }
        for _ in 0..<360 {
            if kill(pid_t(pid), 0) != 0 && errno == ESRCH { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw Failure("pid \(pid) still running after 3 minutes (a VM that won't stop? see \(e.logsURL.path))")
    }
}

// MARK: Verbs

struct InstanceStart: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start", abstract: "Run a build on a state (default: stable on work) and wait for it.")

    @Argument(help: "State name.")
    var state: String = ACSupportDir.defaultStateName

    @Option(name: [.customShort("b"), .long], help: "Build: a name under the builds folder, stable, stable.prev, or a path to an .app.")
    var build: String = BuildStore.stableLink

    @Flag(exclusivity: .exclusive, help: "How the app starts. Default: --gui for work, --hidden for any other state.")
    var mode: Instances.Mode?

    @Option(name: .long, help: "An extra KEY=VALUE for the app's environment (repeatable).")
    var env: [String] = []

    @Flag(name: .long, help: "Spawn the binary from this process instead of launching through `open -n`.")
    var direct = false

    func run() throws {
        do {
            let e = try Instances.state(state)
            let b = try BuildStore.build(named: build)
            let m = mode ?? Instances.defaultMode(for: e)
            print("==> \(b.name) on '\(e.name)' (\(m.rawValue)\(direct ? ", direct" : "")): \(b.binaryURL.path)")
            let h = try Instances.start(state: e, build: b, mode: m, extraEnv: env, direct: direct)
            print("pid \(h["pid"] ?? "?") · build \(h["build"] ?? "?") · state \(h["state"] ?? "?") · automation port \(h["automationPort"] ?? "-")")
            print("socket: \(Instances.socketPath(e))")
        } catch let e as Instances.Failure { throw ValidationError(e.description) }
        catch let e as BuildStore.Failure { throw ValidationError(e.description) }
    }
}

struct InstanceStop: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop", abstract: "Quit the instance on a state over its socket: the menu's drain, no dialog.")

    @Argument(help: "State name.")
    var state: String = ACSupportDir.defaultStateName

    @Flag(name: .long, help: "Suspend every workspace (RAM to disk) instead of its own close action.")
    var suspend = false

    @Flag(name: .long, help: "Shut every workspace down instead of its own close action.")
    var shutdown = false

    func validate() throws {
        if suspend, shutdown { throw ValidationError("--suspend and --shutdown are exclusive.") }
    }

    func run() throws {
        do {
            let e = try Instances.state(state)
            let vms = suspend ? "suspend" : shutdown ? "shutdown" : nil
            guard let h = Instances.health(e) else { print("'\(e.name)' isn't running."); return }
            print("==> quitting '\(e.name)' (pid \(h["pid"] ?? "?")\(vms.map { ", VMs: \($0)" } ?? ""))")
            try Instances.stop(state: e, vms: vms)
            print("quit.")
        } catch let e as Instances.Failure { throw ValidationError(e.description) }
    }
}

struct InstanceRestart: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart", abstract: "Stop the instance on a state, then start a build on it (default: stable).")

    @Argument(help: "State name.")
    var state: String = ACSupportDir.defaultStateName

    @Option(name: [.customShort("b"), .long], help: "Build to start (see `instance start`).")
    var build: String = BuildStore.stableLink

    @Flag(exclusivity: .exclusive, help: "How the app starts. Default: --gui for work, --hidden for any other state.")
    var mode: Instances.Mode?

    @Option(name: .long, help: "An extra KEY=VALUE for the app's environment (repeatable).")
    var env: [String] = []

    @Flag(name: .long, help: "Spawn the binary from this process instead of launching through `open -n`.")
    var direct = false

    @Flag(name: .long, help: "Suspend every workspace on the way down instead of its own close action.")
    var suspend = false

    @Flag(name: .long, help: "Shut every workspace down on the way down instead of its own close action.")
    var shutdown = false

    func validate() throws {
        if suspend, shutdown { throw ValidationError("--suspend and --shutdown are exclusive.") }
    }

    func run() throws {
        do {
            let e = try Instances.state(state)
            let b = try BuildStore.build(named: build)
            let vms = suspend ? "suspend" : shutdown ? "shutdown" : nil
            if let h = Instances.health(e) {
                print("==> quitting '\(e.name)' (pid \(h["pid"] ?? "?")\(vms.map { ", VMs: \($0)" } ?? ""))")
                try Instances.stop(state: e, vms: vms)
            }
            let m = mode ?? Instances.defaultMode(for: e)
            print("==> \(b.name) on '\(e.name)' (\(m.rawValue)\(direct ? ", direct" : "")): \(b.binaryURL.path)")
            let h = try Instances.start(state: e, build: b, mode: m, extraEnv: env, direct: direct)
            print("pid \(h["pid"] ?? "?") · build \(h["build"] ?? "?") · state \(h["state"] ?? "?") · automation port \(h["automationPort"] ?? "-")")
        } catch let e as Instances.Failure { throw ValidationError(e.description) }
        catch let e as BuildStore.Failure { throw ValidationError(e.description) }
    }
}

struct InstanceList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "Every state and the instance on it: pid, build, mode, automation port.")

    @Flag(name: .long, help: "Machine-readable JSON.")
    var json = false

    func run() throws {
        let states = StateStore.list()
        if json {
            var rows: [[String: Any]] = []
            for e in states {
                var row: [String: Any] = ["state": e.name, "path": e.url.path, "running": false]
                if let h = Instances.health(e) {
                    row["running"] = true
                    for k in ["pid", "build", "version", "commit", "automationPort"] where h[k] != nil { row[k] = h[k] }
                    if let i = ACInstance.read(stateURL: e.url) { row["mode"] = i.mode }
                } else if ACInstance.read(stateURL: e.url) != nil {
                    row["stale"] = true
                }
                rows.append(row)
            }
            print(String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
            return
        }
        print(Self.row("STATE", "PID", "BUILD", "MODE", "PORT", "PATH"))
        for e in states {
            if let h = Instances.health(e) {
                let mode = ACInstance.read(stateURL: e.url)?.mode ?? "?"
                print(Self.row(e.name, "\(h["pid"] ?? "?")", "\(h["build"] ?? "?")", mode,
                               "\(h["automationPort"] ?? "-")", e.url.path))
            } else if ACInstance.read(stateURL: e.url) != nil {
                print(Self.row(e.name, "stale", "-", "-", "-", e.url.path))
            } else {
                print(Self.row(e.name, "-", "-", "-", "-", e.url.path))
            }
        }
    }

    static func row(_ a: String, _ b: String, _ c: String, _ d: String, _ e: String, _ f: String) -> String {
        "\(StateList.pad(a, 16)) \(StateList.pad(b, 8)) \(StateList.pad(c, 14)) \(StateList.pad(d, 9)) \(StateList.pad(e, 6)) \(f)"
    }
}

struct InstanceCli: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cli",
        abstract: "Run the CLI of the build serving a state against it: `instance cli [<state>] -- vm ls`.",
        discussion: "The serving build's own CLI, so the wire contract matches its version; stable's when the state has never run.")

    @Argument(parsing: .captureForPassthrough, help: "[<state>] -- <bromure-ac arguments>")
    var args: [String] = []

    func run() throws {
        var rest = args
        var state = ACSupportDir.defaultStateName
        if let first = rest.first, first != "--" { state = first; rest.removeFirst() }
        if rest.first == "--" { rest.removeFirst() }
        do {
            let e = try Instances.state(state)
            let bin = try Instances.binary(for: e)
            let argv = [bin.path, "--state", e.name] + rest
            var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
            cargs.append(nil)
            execv(bin.path, cargs)
            throw ValidationError("can't exec \(bin.path): \(String(cString: strerror(errno)))")
        } catch let e as Instances.Failure { throw ValidationError(e.description) }
        catch let e as BuildStore.Failure { throw ValidationError(e.description) }
    }
}

struct InstanceHealth: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "health", abstract: "The instance's /health, as JSON; exit 1 when nothing answers.")

    @Argument(help: "State name.")
    var state: String = ACSupportDir.defaultStateName

    func run() throws {
        do {
            let e = try Instances.state(state)
            guard let h = Instances.health(e) else { throw ValidationError("'\(e.name)' isn't running") }
            print(String(decoding: try JSONSerialization.data(withJSONObject: h, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        } catch let e as Instances.Failure { throw ValidationError(e.description) }
    }
}

struct InstanceBinPath: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bin-path", abstract: "Print the bromure-ac path of the build serving a state (the last one to, else stable's).")

    @Argument(help: "State name.")
    var state: String = ACSupportDir.defaultStateName

    func run() throws {
        do {
            print(try Instances.binary(for: try Instances.state(state)).path)
        } catch let e as Instances.Failure { throw ValidationError(e.description) }
        catch let e as BuildStore.Failure { throw ValidationError(e.description) }
    }
}
