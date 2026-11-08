import ACLinux
import ArgumentParser
import CACLinuxShims
import Foundation

// bromure-ac on Linux: the headless daemon and the CLI that talks to it over
// $XDG_RUNTIME_DIR/bromure-ac/control.sock (macOS: the app + its control.sock).

// @port-skip linux-only: Linux CLI root (macOS: BromureAC's ParsableCommand)
@main
struct BromureAC: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bromure-ac", abstract: "Bromure Agentic Coding, headless Linux host.",
        subcommands: [Daemon.self, VM.self, Image.self, Remote.self, Account.self, Cloud.self, Gateway.self, LANHelperCommand.self, Admin.self, SSHKey.self, StopPost.self])
}

// @port-skip linux-only: the daemon entry point (macOS runs as an app)
struct Daemon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the daemon (systemd: bromure-ac.service).")

    // @port-skip linux-only: daemon main
    func run() async throws {
        // Before anything spawns threads that inherit the mask.
        _ = acl_unblock_term_signals()
        let config = DaemonConfig.fromEnvironment()
        // Multi-user: systemd's socket unit made the control socket (owner,
        // group and mode its own) and passes it as "control".
        let inherited = FDStore.take()["control"]?.first
        // A peer that closes mid-relay must end that relay, not the daemon:
        // every write to a socket whose peer is gone would SIGPIPE (macOS
        // sets SO_NOSIGPIPE per socket; Linux has no such option).
        signal(SIGPIPE, SIG_IGN)
        let daemon = try await ACLinux.Daemon.start(config)
        let server = try await ControlServer.start(path: config.controlSocketPath, inherited: inherited,
                                                   peers: config.controlPeers) { req in await daemon.handle(req) }
        FileHandle.standardError.write(Data("bromure-ac daemon: \(config.controlSocketPath)\n".utf8))
        _ = acl_sd_notify("READY=1\nSTATUS=serving \(config.controlSocketPath)")
        // SIGTERM (systemctl stop) / SIGINT: stop the VMs and passt, then exit.
        // (A parent that spawned us with signals blocked still gets SIGKILL;
        // passt follows us then via the socketpair; the VMs wait for a next
        // daemon under systemd, or are ended by stop-post.)
        let stop = AsyncStream<Int32> { cont in
            for sig in [SIGTERM, SIGINT] {
                signal(sig, SIG_IGN)
                let src = DispatchSource.makeSignalSource(signal: sig)
                src.setEventHandler { cont.yield(sig) }
                src.resume()
                Signals.keep(src)
            }
        }
        var it = stop.makeAsyncIterator()
        _ = await it.next()
        _ = acl_sd_notify("STOPPING=1")
        await server.close()
        await daemon.shutdown()
    }
}

/// The unit's ExecStopPost= (see ACLinux.StopPost).
// @port-skip linux-only: systemd stop-post entry
struct StopPost: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop-post", abstract: "systemd ExecStopPost= helper.",
                                                    shouldDisplay: false)
    // @port-skip linux-only: systemd stop-post entry
    func run() async throws {
        FileHandle.standardError.write(Data((await ACLinux.StopPost.run() + "\n").utf8))
    }
}

// @port-skip linux-only: keeps signal sources alive
enum Signals {
    nonisolated(unsafe) static var sources: [any DispatchSourceSignal] = []
    // @port-skip linux-only: keeps signal sources alive
    static func keep(_ s: any DispatchSourceSignal) { sources.append(s) }
}

// @port-skip linux-only: Linux CLI group (macOS: `workspaces`, alias `vm`)
struct VM: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage VMs.", subcommands: [Run.self, Ls.self, Exec.self, Kill.self, Suspend.self, Resume.self,
                                                 Start.self, Rm.self])
}

// @port-skip linux-only: CLI plumbing
func client() throws -> ControlClient {
    let c = ControlClient(socketPath: DaemonConfig.fromEnvironment().controlSocketPath)
    guard c.isAgentRunning() else {
        throw ValidationError("No bromure-ac daemon running (start it: systemctl --user start bromure-ac, or bromure-ac daemon).")
    }
    return c
}

// @port-skip linux-only: CLI plumbing
func check(_ r: ControlClient.Response, _ what: String) throws {
    guard (200..<300).contains(r.status) else { throw ValidationError(r.json["error"]?.stringValue ?? "\(what) failed (\(r.status)).") }
}

extension VM {
    // @port-skip linux-only: the command's options (macOS: VMRun's, plus the Linux VM knobs --machine, --cpus, --home-gb)
    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Start a workspace's VM — or create a throwaway one (docker-style) with --name/--tool (detached).")

        @Argument(help: "Workspace to start — id or name (see `vm ls`). Omit only to create a throwaway VM with --name/--tool.")
        var workspace: String?
        @Option(name: [.customShort("v"), .long],
                help: "Mount a host folder into the VM at ~/<basename>. Repeatable (max 8). e.g. -v ~/project")
        var volume: [String] = []
        @Option(help: "Name for an on-the-fly workspace (default: cli-XXXX).") var name: String?
        @Option(help: "Tool for an on-the-fly workspace: claude | codex | grok | kimi | omp.") var tool: String?
        @Option(help: "Auth mode for an on-the-fly workspace: token | subscription | bedrock | local.") var auth: String?
        @Option(name: .customLong("api-key"),
                help: "API key (for --auth token); '-' reads it from stdin. Default: $BROMURE_AC_API_KEY. On the command line, other users of this server can see it.")
        var apiKey: String?
        @Flag(help: "Delete the workspace + disk when the VM stops (ephemeral).") var rm = false
        @Option(help: "firecracker (the only backend; linux/firecracker/build.sh).") var machine = "firecracker"
        @Option(name: .customLong("memory-gb"), help: "RAM in GiB.") var memoryGB: Double?
        @Option(help: "vCPUs.") var cpus = 2
        @Option(name: .customLong("home-gb"), help: "Home image size in GiB (8-1024; default: the daemon's).") var homeGB: Int?

        // partial: always detached (no terminal handed over); --memory-gb may be fractional
        // @port VMRun.run() h=b33df8507728b8d7 @f127f8ab
        func run() async throws {
            var body: [String: JSONValue] = ["machine": .string(machine), "cpus": .number(Double(cpus)),
                                             "detach": true, "rm": .bool(rm)]
            if let workspace {
                body["profile"] = .string(workspace)                  // start an existing workspace
            } else if name != nil || tool != nil || auth != nil {    // create a throwaway on-the-fly
                if let name { body["name"] = .string(name) }
                if let tool = try Self.choice(tool, Profile.Tool.self, option: "--tool") { body["tool"] = .string(tool) }
                if let auth = try Self.choice(auth, Profile.AuthMode.self, option: "--auth") { body["auth"] = .string(auth) }
                let key = VMRunAPIKey.resolve(flag: apiKey, environment: ProcessInfo.processInfo.environment) {
                    String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)
                }
                if key.onCommandLine { FileHandle.standardError.write(Data((VMRunAPIKey.argvWarning + "\n").utf8)) }
                if let k = key.key { body["apiKey"] = .string(k) }
            } else {
                throw ValidationError("Specify a workspace to start (e.g. `vm run iptest2` — see `vm ls`), "
                                      + "or pass --name/--tool to create a throwaway one.")
            }
            if let memoryGB { body["memoryGB"] = .number(memoryGB) }
            if let homeGB { body["homeGB"] = .number(Double(homeGB)) }
            if !volume.isEmpty { body["mounts"] = .array(volume.map { .string(Self.absoluteHostPath($0)) }) }
            let r = try client().request("POST", "/vms", body: .object(body))
            try check(r, "run")
            print(r.json["id"]?.stringValue ?? "")
        }

        /// An option's value checked against the enum's raw values.
        // @port validatedCLIChoice(_: String?, _: E.Type, option: String) h=29846ce46367174f @f127f8ab
        static func choice<E: RawRepresentable & CaseIterable>(_ raw: String?, _ type: E.Type, option: String) throws -> String?
            where E.RawValue == String {
            guard let raw else { return nil }
            guard E(rawValue: raw) != nil else {
                let valid = E.allCases.map(\.rawValue).joined(separator: " | ")
                throw ValidationError("Invalid \(option) “\(raw)” — expected one of: \(valid).")
            }
            return raw
        }

        /// A host path as the daemon takes it: `~` expanded, relative to the cwd, standardized.
        // @port absoluteHostPath(_: String) h=a1469f3e4a0ba7df @f127f8ab
        static func absoluteHostPath(_ raw: String) -> String {
            let expanded = (raw as NSString).expandingTildeInPath
            let absolute = expanded.hasPrefix("/")
                ? expanded
                : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
            return (absolute as NSString).standardizingPath
        }
    }

    // @port-skip linux-only: lists /vms (macOS's `ls` lists workspaces + VMs; no workspaces on Linux yet)
    struct Ls: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List VMs.")
        @Flag(help: "JSON output.") var json = false

        // @port-skip linux-only: lists /vms
        func run() async throws {
            let r = try client().request("GET", "/vms")
            try check(r, "ls")
            if json {
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try enc.encode(r.json), as: UTF8.self))
                return
            }
            print("ID        NAME                 STATE      MACHINE  IP")
            if case .array(let vms) = r.json["vms"] ?? .null {
                for v in vms {
                    func s(_ k: String) -> String { v[k]?.stringValue ?? "-" }
                    print(s("shortId").padding(toLength: 10, withPad: " ", startingAt: 0)
                          + s("name").padding(toLength: 21, withPad: " ", startingAt: 0)
                          + s("state").padding(toLength: 11, withPad: " ", startingAt: 0)
                          + s("machine").padding(toLength: 9, withPad: " ", startingAt: 0) + s("ip"))
                }
            }
        }
    }

    // @port-skip linux-only: the type; run() carries the @port
    struct Exec: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run a command in a VM, after `--`. Use -it for an interactive shell.",
            discussion: """
            Examples:
              vm exec my-vm -- ls -la
              vm exec my-vm -it -- bash
            """)
        @Flag(name: [.customShort("i"), .long], help: "Interactive: keep stdin open.") var interactive = false
        @Flag(name: [.customShort("t"), .long], help: "Allocate a pseudo-tty.") var tty = false
        @Option(help: "Timeout in seconds (non-interactive only). Default 600.") var timeout = 600
        @Argument(help: "VM id or name.") var vm: String
        @Argument(parsing: .postTerminator, help: "Command and arguments. Omit (with -it) for an interactive shell.")
        var command: [String] = []

        /// Non-interactive: stdout/stderr echoed, exit status propagated.
        /// -i and/or -t: a pty session in the guest (InteractiveExec).
        // @port Exec.run() h=78c76b556399f4ba @94eb37f3
        func run() async throws {
            let c = try client()
            if interactive || tty {
                try InteractiveExec.run(client: c, vm: vm, command: command.joined(separator: " "))
                return
            }
            guard !command.isEmpty else { throw ValidationError("No command given (use -it for an interactive shell).") }
            let body: JSONValue = .object(["command": .string(command.joined(separator: " ")),
                                           "argv": .array(command.map { .string($0) }),
                                           "timeout": .number(Double(timeout))])
            let r = try c.request("POST", "/vms/\(ControlClient.encodeSegment(vm))/exec", body: body)
            try check(r, "exec")
            FileHandle.standardOutput.write(Data((r.json["stdout"]?.stringValue ?? "").utf8))
            FileHandle.standardError.write(Data((r.json["stderr"]?.stringValue ?? "").utf8))
            let code = Int32(r.json["exitCode"]?.numberValue ?? 0)
            if code != 0 { throw ExitCode(code) }
        }
    }

    // @port-skip linux-only: the type; run() carries the @port
    struct Kill: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop a VM (shut down, suspend with --suspend, or --force).")
        @Argument(help: "VM id or name.") var vm: String
        @Flag(help: "Suspend (save RAM to disk) instead of powering off.") var suspend = false
        @Flag(help: "Kill Firecracker at once instead of a guest shutdown (Linux).") var force = false

        // @port VMKill.run() h=f36d4145132d9df1 @94eb37f3
        func run() async throws {
            let action = suspend ? "suspend" : (force ? "kill" : "shutdown")
            let r = try client().request("DELETE", "/vms/\(ControlClient.encodeSegment(vm))",
                                         body: ["action": .string(action)])
            try check(r, "kill")
            print("\(suspend ? "Suspended" : "Stopped") \(vm).")
        }
    }

    // @port-skip linux-only: shorthand for `kill --suspend`
    struct Suspend: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Suspend a VM (save its RAM to disk; not available yet with Firecracker).")
        @Argument(help: "VM id or name.") var vm: String
        // @port-skip linux-only: shorthand for `kill --suspend`
        func run() async throws {
            let r = try client().request("DELETE", "/vms/\(ControlClient.encodeSegment(vm))", body: ["action": "suspend"])
            try check(r, "suspend")
            print("Suspended \(vm).")
        }
    }

    // @port-skip linux-only: explicit resume (macOS restores when the workspace starts again)
    struct Resume: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Resume a suspended VM.")
        @Argument(help: "VM id or name.") var vm: String
        // @port-skip linux-only: explicit resume
        func run() async throws {
            let r = try client().request("POST", "/vms/\(ControlClient.encodeSegment(vm))/resume")
            try check(r, "resume")
            print("Resumed \(vm).")
        }
    }

    // @port-skip linux-only: start a stopped VM (macOS starts the workspace)
    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start a stopped VM again (its disk and home are kept).")
        @Argument(help: "VM id or name.") var vm: String
        @Option(name: .customLong("home-gb"), help: "Grow the home image to this size in GiB first (it never shrinks).")
        var homeGB: Int?
        // @port-skip linux-only: start a stopped VM
        func run() async throws {
            let body: JSONValue = .object(homeGB.map { ["homeGB": .number(Double($0))] } ?? [:])
            let r = try client().request("POST", "/vms/\(ControlClient.encodeSegment(vm))/start", body: body)
            try check(r, "start")
            print("Started \(vm).")
        }
    }

    // @port-skip linux-only: remove a VM and its disks (macOS deletes the workspace)
    struct Rm: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a stopped or suspended VM with its disk, home and state.")
        @Argument(help: "VM id or name.") var vm: String
        // @port-skip linux-only: remove a VM
        func run() async throws {
            let r = try client().request("POST", "/vms/\(ControlClient.encodeSegment(vm))/remove")
            try check(r, "rm")
            print("Removed \(vm).")
        }
    }
}


// @port-skip linux-only: Linux CLI group for the guest image (macOS: the app's Rebuild Base Image)
struct Image: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Manage the guest image.", subcommands: [Bake.self])

    // @port-skip linux-only: interim image bake CLI
    struct Bake: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Bake the amd64 guest image under Firecracker/KVM from vm-setup (needs /dev/kvm and network).")
        @Option(help: "Output directory. Default: the daemon's image directory.") var out: String?
        @Option(name: .customLong("vm-setup"), help: "vm-setup directory (setup.sh and the agents).")
        var vmSetup = "Sources/AgentCoding/Resources/vm-setup"
        @Option(name: .customLong("image-version"), help: "Stamp for base.version. Default: UbuntuImageManager.imageVersion from the repo.")
        var imageVersion: String?
        @Option(help: "Download cache.") var cache: String?
        @Option(help: "Installer vCPUs.") var cpus = 4
        @Option(help: "Installer NIC MTU.") var mtu = 1500
        @Option(name: .customLong("ubuntu-mirror"), help: "Ubuntu mirror. Default: setup.sh's for the arch.") var ubuntuMirror: String?
        @Flag(name: .customLong("no-agent-clis"), help: "Leave out the image catalog's postinstall steps (Claude Code, Codex, Grok…).")
        var noAgentCLIs = false
        @Option(name: .customLong("alpine-releases"), help: "Alpine netboot releases URL (HTTPS). Default: dl-cdn's.")
        var alpineReleases: String?
        @Flag(help: "Echo the installer's serial console.") var verbose = false

        // @port-skip linux-only: interim image bake CLI
        func run() async throws {
            _ = acl_unblock_term_signals()
            let env = ProcessInfo.processInfo.environment
            let home = env["HOME"] ?? NSHomeDirectory()
            let setup = (vmSetup as NSString).standardizingPath
            guard FileManager.default.fileExists(atPath: setup + "/setup.sh") else {
                throw ValidationError("no setup.sh in \(setup) (run from the repository root, or pass --vm-setup)")
            }
            var version = imageVersion
            if version == nil {
                // vm-setup lives in Sources/AgentCoding/Resources/; the stamp in Sources/AgentCoding/.
                let manager = ((setup as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
                    + "/UbuntuImageManager.swift"
                let src = (try? String(contentsOfFile: manager, encoding: .utf8)) ?? ""
                if let r = src.range(of: #"imageVersion = "[^"]+""#, options: .regularExpression) {
                    version = String(src[r].split(separator: "\"")[1])
                }
            }
            guard let version else { throw ValidationError("no --image-version and no UbuntuImageManager.swift next to vm-setup") }
            var o = InterimBake.Options(outputDir: out ?? DaemonConfig.fromEnvironment().imageDir,
                                        cacheDir: cache ?? (env["XDG_CACHE_HOME"] ?? home + "/.cache") + "/bromure-ac/bake",
                                        vmSetupDir: setup, imageVersion: version)
            o.cpus = cpus
            o.mtu = mtu
            o.ubuntuMirror = ubuntuMirror
            // The catalog beside vm-setup (Resources/img-catalog.json).
            if !noAgentCLIs { o.catalogPath = ((setup as NSString).deletingLastPathComponent as NSString).appendingPathComponent("img-catalog.json") }
            if let alpineReleases { o.alpineReleasesBase = alpineReleases }
            let verbose = verbose
            let r = try await InterimBake.bake(o, progress: { FileHandle.standardError.write(Data("[bake] \($0)\n".utf8)) },
                                               output: { if verbose { FileHandle.standardError.write($0) } })
            func mib(_ b: UInt64) -> String { String(format: "%.0f MiB", Double(b) / 1_048_576) }
            func secs(_ d: Duration) -> String { String(format: "%.0f s", Double(d.components.seconds)) }
            print("baked \(o.outputDir): kernel \(r.kernelRelease), setup.sh \(secs(r.setup)), total \(secs(r.total)); "
                  + "base.img \(mib(r.imageBytes)) apparent, \(mib(r.imageAllocatedBytes)) allocated")
        }
    }
}

/// The SIGWINCH self-pipe's write end: the handler may run on any thread,
/// so it wakes the poll loop through a pipe rather than a flag.
nonisolated(unsafe) var gWinchPipe: Int32 = -1

/// Drives an interactive exec: a raw stream to agentd's pty, the terminal in
/// raw mode (restored on exit), SIGWINCH forwarded as resize frames.
// @port-skip linux-only: the namespace; run carries the @port line
enum InteractiveExec {
    // partial: no overlay trigger, view/window, guiConsent or sizePassive (no host terminal views on Linux); a stream that ends without an exit frame is an error (exit 1) rather than a silent 0
    // @port InteractiveExec.static run(client: ControlClient, vm: String, command: String, view: String?, window: Int?, guiConsent: Bool, sizePassive: Bool, overlayTrigger: UInt8?, onOverlay: (()->[UInt8])?) h=817622aa69512a47 @94eb37f3
    static func run(client: ControlClient, vm: String, command: String) throws {
        func size() -> (Int, Int) {
            var ws = winsize()
            _ = ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws)
            return (ws.ws_col == 0 ? 80 : Int(ws.ws_col), ws.ws_row == 0 ? 24 : Int(ws.ws_row))
        }
        let (cols, rows) = size()
        let body: JSONValue = .object(["command": .string(command), "interactive": .bool(true),
                                       "cols": .number(Double(cols)), "rows": .number(Double(rows))])
        let fd: Int32
        do { fd = try client.openStream("POST", "/vms/\(ControlClient.encodeSegment(vm))/exec", body: body) }
        catch let e as ControlClient.ClientError { throw ValidationError(e.description) }
        defer { close(fd) }

        let haveTTY = isatty(STDIN_FILENO) != 0
        var orig = termios()
        if haveTTY {
            tcgetattr(STDIN_FILENO, &orig)
            var raw = orig
            cfmakeraw(&raw)
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        }
        defer { if haveTTY { tcsetattr(STDIN_FILENO, TCSANOW, &orig) } }

        var p: [Int32] = [-1, -1]
        guard pipe(&p) == 0 else { throw ValidationError("pipe: \(String(cString: strerror(errno)))") }
        for e in p { _ = fcntl(e, F_SETFL, O_NONBLOCK); _ = fcntl(e, F_SETFD, FD_CLOEXEC) }
        defer { signal(SIGWINCH, SIG_DFL); gWinchPipe = -1; close(p[0]); close(p[1]) }
        gWinchPipe = p[1]
        signal(SIGWINCH) { _ in
            var one: UInt8 = 1
            _ = write(gWinchPipe, &one, 1)
        }

        var stdinFD: Int32 = STDIN_FILENO
        var inbuf: [UInt8] = []
        var rbuf = [UInt8](repeating: 0, count: 1 << 16)
        var exitCode: Int32?
        loop: while true {
            var fds = [pollfd(fd: stdinFD, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: p[0], events: Int16(POLLIN), revents: 0)]
            if poll(&fds, 3, -1) < 0 { if errno == EINTR { continue }; break }
            if fds[2].revents != 0 {
                while read(p[0], &rbuf, rbuf.count) > 0 {}
                let (c, r) = size()
                PTYFrame.send(fd, PTYFrame.resize, PTYFrame.resizePayload(cols: c, rows: r))
            }
            if fds[0].revents != 0 {
                let r = read(stdinFD, &rbuf, rbuf.count)
                if r > 0 { PTYFrame.send(fd, PTYFrame.data, Array(rbuf[0..<r])) }
                else if !(r < 0 && errno == EINTR) { PTYFrame.send(fd, PTYFrame.eof, []); stdinFD = -1 }
            }
            if fds[1].revents != 0 {
                let r = read(fd, &rbuf, rbuf.count)
                if r < 0 && errno == EINTR { continue }
                if r <= 0 { break }
                inbuf.append(contentsOf: rbuf[0..<r])
                for (type, payload) in PTYFrame.take(&inbuf) {
                    if type == PTYFrame.data, !payload.isEmpty {
                        _ = ControlClientIO.writeAll(STDOUT_FILENO, payload)
                    } else if type == PTYFrame.exit {
                        exitCode = payload.count >= 4
                            ? Int32(bitPattern: UInt32(payload[0]) << 24 | UInt32(payload[1]) << 16 | UInt32(payload[2]) << 8 | UInt32(payload[3]))
                            : 0
                        break loop
                    }
                }
            }
        }
        guard let exitCode else {
            if haveTTY { tcsetattr(STDIN_FILENO, TCSANOW, &orig) }
            FileHandle.standardError.write(Data("\r\nbromure-ac: the session ended without an exit status\n".utf8))
            throw ExitCode(1)
        }
        if exitCode != 0 { throw ExitCode(exitCode) }
    }
}

/// Short-write-safe write of raw bytes to a blocking fd.
// @port-skip linux-only: helper
enum ControlClientIO {
    // @port-skip linux-only: blocking write helper for stdout
    static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var off = 0
        while off < bytes.count {
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + off, bytes.count - off) }
            if n < 0 { if errno == EINTR { continue }; return false }
            off += n
        }
        return true
    }
}

/// `bromure-ac remote`: the embedded SSH server fat clients (the macOS and
/// iOS apps) connect to.
// partial: no Preferences pane; status, enable/disable, keys, and Linux's one-time enrollment code
// @port-skip linux-only: macOS has the same verbs under `bromure-ac remote` driving UserDefaults
struct Account: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "This server's bromure.io account: your other devices' SSH keys, kept in authorized_keys.",
        subcommands: [Status.self, SignIn.self, SignOut.self, Sync.self],
        defaultSubcommand: Status.self)

    // @port-skip linux-only: CLI plumbing
    static func show(_ j: JSONValue) {
        guard j["signedIn"] == .bool(true) else {
            print("Not signed in. `bromure-ac account sign-in` with a code from bromure.io.")
            return
        }
        print("signed in: \(j["org"]?.stringValue ?? "bromure.io")   device: \(j["deviceId"]?.stringValue ?? "?")   api: \(j["apiBase"]?.stringValue ?? "?")")
        if let s = j["lastSync"] {
            let n = { (k: String) in s[k].flatMap { if case .number(let v) = $0 { return Int(v) } else { return nil } } ?? 0 }
            if let e = s["error"]?.stringValue {
                print("last sync: \(s["at"]?.stringValue ?? "?") failed: \(e) (keeping \(n("keys")) keys)")
            } else {
                print("last sync: \(s["at"]?.stringValue ?? "?"): \(n("keys")) keys (\(n("machineKeys")) for attached machines only)")
            }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show whether this server is signed in, and the last key sync.")
        @Flag(help: "JSON output.") var json = false
        // @port-skip linux-only: CLI
        func run() async throws {
            let r = try client().request("GET", "/account")
            try check(r, "status")
            if json { print(r.json) } else { Account.show(r.json) }
        }
    }

    struct SignIn: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "sign-in",
            abstract: "Sign this server in with the enrollment code bromure.io shows (a bromure://enroll link works too).",
            discussion: "The code is read from the terminal without echo (or from stdin), so it stays out of your shell history.")
        // @port-skip linux-only: CLI
        func run() async throws {
            let tty = isatty(STDIN_FILENO) == 1
            if tty { FileHandle.standardError.write(Data("Enrollment code from bromure.io: ".utf8)) }
            guard let link = Account.readSecretLine(echo: !tty), !link.isEmpty else { throw ValidationError("No code given.") }
            if tty { FileHandle.standardError.write(Data("\n".utf8)) }
            let r = try client().request("POST", "/account/sign-in", body: ["link": .string(link)])
            try check(r, "sign-in")
            print("Signed in\(r.json["org"]?.stringValue.map { " to \($0)" } ?? ""). Your devices' keys sync now and every 3 minutes.")
        }
    }

    struct SignOut: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "sign-out", abstract: "Forget this server's account here (the keys it brought in stay).")
        // @port-skip linux-only: CLI
        func run() async throws {
            let r = try client().request("POST", "/account/sign-out")
            try check(r, "sign-out")
            print("Signed out. The keys it brought in stay; remove one with `remote rm-key`.")
        }
    }

    struct Sync: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Pull your devices' keys now.")
        // @port-skip linux-only: CLI
        func run() async throws {
            let r = try client().request("POST", "/account/sync")
            try check(r, "sync")
            Account.show(r.json)
        }
    }

    /// One line from stdin; on a terminal, without echo.
    // @port-skip linux-only: CLI plumbing
    static func readSecretLine(echo: Bool) -> String? {
        var orig = termios()
        let quiet = !echo && tcgetattr(STDIN_FILENO, &orig) == 0
        if quiet {
            var raw = orig
            raw.c_lflag &= ~tcflag_t(ECHO)
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        }
        defer { if quiet { tcsetattr(STDIN_FILENO, TCSANOW, &orig) } }
        return readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces)
    }
}

/// `bromure-ac cloud`: this install's enrollment in a bromure.io workspace
/// (the events and traces it uploads, over its mTLS leaf).
// @port-skip linux-only: macOS has the same verbs as `bromure-ac enroll`, `unenroll`, `enrollment-status`
struct Cloud: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "This install's enrollment in a bromure.io workspace (uploads over mTLS).",
        subcommands: [Status.self, Enroll.self, Unenroll.self],
        defaultSubcommand: Status.self)

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the enrollment state.")
        @Flag(help: "JSON output.") var json = false
        // @port-skip linux-only: CLI
        func run() async throws {
            let r = try client().request("GET", "/cloud")
            try check(r, "status")
            if json { print(r.json); return }
            if r.json["vault"]?.stringValue == "file-fallback" {
                FileHandle.standardError.write(Data("note: secrets are in the vault's file fallback (its key sits beside them; no systemd-creds sealing)\n".utf8))
            }
            guard r.json["enrolled"] == .bool(true) else { print("not enrolled"); return }
            let f = { (k: String) in r.json[k]?.stringValue ?? "?" }
            print("""
            Enrolled
              workspace:  \(f("workspace"))
              user:       \(f("user"))
              install id: \(f("installId"))
              device:     \(f("device"))
              server:     \(f("server"))
              enrolled:   \(f("enrolledAt"))
              bearer:     \(f("bearer"))
              leaf cert:  \(f("leafCert"))
            """)
        }
    }

    struct Enroll: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Enroll this install with a bromure.io workspace using an admin's 6-word code.",
            discussion: "The code is read from the terminal without echo (or from stdin), so it stays out of your shell history.")
        @Option(name: .long, help: "bromure.io API base URL. Defaults to BROMURE_MANAGED_URL or https://bromure.io/api.")
        var serverURL: String?
        @Option(name: .long, help: "Device name shown to admins. Defaults to the host name.")
        var deviceName: String?
        // @port-skip linux-only: CLI
        func run() async throws {
            let tty = isatty(STDIN_FILENO) == 1
            if tty { FileHandle.standardError.write(Data("Enrollment code (6 dashed words): ".utf8)) }
            guard let code = Account.readSecretLine(echo: !tty), !code.isEmpty else { throw ValidationError("No code given.") }
            if tty { FileHandle.standardError.write(Data("\n".utf8)) }
            var body: [String: JSONValue] = ["code": .string(code)]
            if let serverURL { body["serverURL"] = .string(serverURL) }
            if let deviceName { body["deviceName"] = .string(deviceName) }
            let r = try client().request("POST", "/cloud/enroll", body: .object(body))
            try check(r, "enroll")
            let f = { (k: String) in r.json[k]?.stringValue ?? "?" }
            print("""
            Enrolled \(f("user")) at \(f("workspace"))
            Install ID: \(f("installId"))
            Server:     \(f("server"))
            Device:     \(f("device"))
            Leaf cert:  \(f("leafCert"))
            """)
        }
    }

    struct Unenroll: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Sign this install out of its bromure.io workspace.")
        @Flag(name: .long, help: "Skip the confirmation prompt.") var force = false
        // @port-skip linux-only: CLI
        func run() async throws {
            let c = try client()
            let st = try c.request("GET", "/cloud")
            guard st.json["enrolled"] == .bool(true) else {
                FileHandle.standardError.write(Data("not enrolled — nothing to do\n".utf8)); return
            }
            if !force {
                print("Sign out of \(st.json["workspace"]?.stringValue ?? "?") (\(st.json["user"]?.stringValue ?? "?"))? [y/N]: ", terminator: "")
                let line = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                guard line == "y" || line == "yes" else { throw ValidationError("aborted") }
            }
            let r = try c.request("POST", "/cloud/unenroll")
            try check(r, "unenroll")
            print("signed out")
        }
    }
}

struct Remote: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remote access for the Bromure apps (an SSH server, port 2222 by default).",
        subcommands: [Status.self, Enable.self, Disable.self, Code.self, AddKey.self, RmKey.self],
        defaultSubcommand: Status.self)

    // @port-skip linux-only: CLI plumbing
    static func show(_ j: JSONValue) {
        func s(_ k: String) -> String {
            switch j[k] { case .bool(let b)?: return b ? "yes" : "no"
                          case .number(let n)?: return String(Int(n))
                          default: return j[k]?.stringValue ?? "-" }
        }
        print("enabled: \(s("enabled"))   running: \(s("running"))   port: \(s("port"))   bind: \(s("bindAddress"))")
        print("password auth: \(s("passwordAuth")) (account password: \(s("allowAccountPassword")), else one-time codes)   public-key auth: \(s("pubkeyAuth"))")
        print("host key: \(s("fingerprint"))")
        print("connect: \(s("connect"))")
        // authorized_keys couldn't be read (macOS's CLI: the same warning).
        if let problem = j["authorizedKeysProblem"]?.stringValue, !problem.isEmpty { print("warning: \(problem)") }
        if case .array(let keys)? = j["authorizedKeys"], !keys.isEmpty {
            print("authorized keys:")
            for k in keys { print("  \(k["fingerprint"]?.stringValue ?? "?")  \(k["comment"]?.stringValue ?? "")") }
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the server's state, host key and enrolled keys.")
        @Flag(help: "JSON output.") var json = false
        // @port-skip linux-only: CLI
        func run() async throws {
            let r = try client().request("GET", "/remote")
            try check(r, "status")
            if json { print(r.json) } else { Remote.show(r.json) }
        }
    }

    struct Enable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start the SSH server (and at every daemon start).")
        @Option(help: "TCP port (1024-65535).") var port: Int?
        @Option(help: "Address to listen on (default 0.0.0.0).") var bind: String?
        @Flag(help: "Refuse password (and enrollment-code) logins.") var noPassword = false
        @Flag(help: "Refuse public-key logins.") var noPubkey = false
        @Flag(help: "Also accept this account's password (PAM) for password logins; by default only one-time codes (`remote code`).")
        var allowAccountPassword = false
        // @port-skip linux-only: CLI
        func run() async throws {
            var body: [String: JSONValue] = ["enabled": true, "passwordAuth": .bool(!noPassword), "pubkeyAuth": .bool(!noPubkey),
                                             "allowAccountPassword": .bool(allowAccountPassword)]
            if let port { body["port"] = .number(Double(port)) }
            if let bind { body["bindAddress"] = .string(bind) }
            let r = try client().request("POST", "/remote", body: .object(body))
            try check(r, "enable")
            Remote.show(r.json)
        }
    }

    struct Disable: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop the SSH server.")
        // @port-skip linux-only: CLI
        func run() async throws {
            let r = try client().request("POST", "/remote", body: ["enabled": false])
            try check(r, "disable")
            print("Remote access disabled.")
        }
    }

    struct Code: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "A one-time code to type as the password when adding this server in a Bromure app.")
        @Option(help: "Minutes it stays valid (1-60).") var minutes = 10
        // @port-skip linux-only: CLI
        func run() async throws {
            let r = try client().request("POST", "/remote/code", body: ["minutes": .number(Double(minutes))])
            try check(r, "code")
            print("Enrollment code (one use, \(minutes) min): \(r.json["code"]?.stringValue ?? "?")")
            print("In the app, add this server with user \(r.json["user"]?.stringValue ?? "?") and type the code as the password.")
        }
    }

    struct AddKey: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "add-key", abstract: "Authorize an OpenSSH public key.")
        @Argument(help: "The public key line (ssh-ed25519 AAAA… comment).") var key: String
        // @port-skip linux-only: CLI
        func run() async throws {
            let r = try client().request("POST", "/remote/keys", body: ["key": .string(key)])
            try check(r, "add-key")
            print("Authorized \(r.json["fingerprint"]?.stringValue ?? "key").")
        }
    }

    struct RmKey: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rm-key", abstract: "Revoke a key (by fingerprint or comment).")
        @Argument(help: "SHA256:… fingerprint, or the key's comment.") var key: String
        // @port-skip linux-only: CLI
        func run() async throws {
            let r = try client().request("DELETE", "/remote/keys/\(ControlClient.encodeSegment(key))")
            try check(r, "rm-key")
            print("Revoked \(key).")
        }
    }
}

/// `bromure-ac gateway`: the multi-user server's SSH front door (systemd:
/// bromure-gw.service, as the gateway account). Settings in
/// $STATE_DIRECTORY/gateway.json (else ~/.local/state/bromure-gw), host key
/// beside it in remote/.
// @port-skip linux-only: multi-user Linux server
struct Gateway: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the multi-user SSH gateway (bromure-gw.service).")

    // @port-skip linux-only: gateway main
    func run() async throws {
        _ = acl_unblock_term_signals()
        let env = ProcessInfo.processInfo.environment
        let state = env["STATE_DIRECTORY"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (env["XDG_STATE_HOME"] ?? NSHomeDirectory() + "/.local/state") + "/bromure-gw"
        let line = try await MainActor.run { try GatewayMain.start(stateDir: state) }
        FileHandle.standardError.write(Data("bromure-ac gateway: \(line)\n".utf8))
        _ = acl_sd_notify("READY=1")
        let stop = AsyncStream<Int32> { cont in
            for sig in [SIGTERM, SIGINT] {
                signal(sig, SIG_IGN)
                let src = DispatchSource.makeSignalSource(signal: sig)
                src.setEventHandler { cont.yield(sig) }
                src.resume()
                Signals.keep(src)
            }
        }
        var it = stop.makeAsyncIterator()
        _ = await it.next()
        await MainActor.run { GatewayMain.stop() }
    }
}

/// `bromure-ac lan-helper` (bromure-lan.service): the multi-user server's
/// LAN address pools (LANHelper).
// @port-skip linux-only: multi-user LAN pools
struct LANHelperCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lan-helper",
        abstract: "Run the LAN address helper (bromure-lan.service: CAP_NET_ADMIN, CAP_NET_BIND_SERVICE).")
    // @port-skip linux-only: multi-user LAN pools
    func run() throws {
        signal(SIGPIPE, SIG_IGN)
        try LANHelper().run()
    }
}

/// `bromure-ac admin` (root): the multi-user server's users.
// @port-skip linux-only: multi-user Linux server administration
struct Admin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Multi-user server: add, remove and list Bromure users (root).",
        subcommands: [Add.self, Remove.self, List.self, Code.self, Pool.self])

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add a Bromure user (a system account unless --existing).")
        @Argument(help: "Account name.") var name: String
        @Flag(help: "Use this existing login account instead of creating a system account.") var existing = false
        // @port-skip linux-only: admin CLI
        func run() async throws { print(try await MultiUserAdmin.add(name, existing: existing)) }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop and disable a user's daemon (and its VMs).")
        @Argument(help: "Account name.") var name: String
        @Flag(help: "Also delete the user's state (VMs, disks, keys).") var purge = false
        @Flag(help: "Also delete the Unix account.") var deleteAccount = false
        // @port-skip linux-only: admin CLI
        func run() async throws { print(try await MultiUserAdmin.remove(name, purge: purge, deleteAccount: deleteAccount)) }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "The Bromure users, their daemons and VMs.")
        // @port-skip linux-only: admin CLI
        func run() async throws {
            for u in MultiUserAdmin.users() {
                let vms: String
                if case .array(let a)? = (try? MultiUserAdmin.request(u, "GET", "/vms"))?.flatMap({ $0["vms"] }) {
                    vms = "\(a.count) VM(s), \(a.filter { $0["state"]?.stringValue == "running" }.count) running"
                } else { vms = "daemon not answering" }
                print(u.padding(toLength: 20, withPad: " ", startingAt: 0) + vms)
            }
        }
    }

    /// The users' LAN address pools for their clusters' load balancers.
    struct Pool: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "LAN address pools: where each user's cluster load balancers may be published (root).",
            discussion: """
            A granted address becomes one of this server's own addresses while a Service is published on it:             anything on the server listening on 0.0.0.0 (sshd, the gateway…) answers there too, as it already             does on the server's own LAN address.
            """,
            subcommands: [PoolAdd.self, PoolRemove.self, PoolList.self])
    }

    struct PoolAdd: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "add", abstract: "Grant a user a range (a.b.c.d-a.b.c.e, a CIDR, or addresses).")
        @Argument(help: "Account name.") var user: String
        @Argument(help: "The range.") var range: String
        @Option(help: "The LAN interface for every pool (default: the default route's).") var interface: String?
        @Flag(name: .customLong("single-user"),
              help: "The account runs its own single-user daemon (not a Bromure user of this server): its clusters' LAN pools go through the same helper.")
        var singleUser = false
        // @port-skip linux-only: admin CLI
        func run() async throws {
            guard geteuid() == 0 else { throw ValidationError("admin pool needs root") }
            if singleUser {
                guard getpwnam(user) != nil else { throw ValidationError("there's no account \(user)") }
            } else {
                guard MultiUserAdmin.users().contains(user) else {
                    throw ValidationError("\(user) isn't a Bromure user (bromure-ac admin add; --single-user for an account running its own daemon)")
                }
            }
            var file = try LANPoolsFile.load(requireInterface: interface == nil)
            if let interface {
                guard LANRoute.validInterfaceName(interface) else { throw ValidationError("'\(interface)' isn't an interface name") }
                guard LANRoute.exists(interface) else { throw ValidationError("there's no interface \(interface)") }
                file.interface = interface
            }
            guard let iface = file.resolvedInterface() else { throw ValidationError("no LAN interface (no default route; give --interface)") }
            let gw = LANRoute.defaultRoute().flatMap { $0.interface == iface ? $0.gateway : nil }
            let out = try LANPoolsAdmin.adding(range, for: user, to: file, hostAddresses: HostAddresses.read(),
                                               gateway: gw, subnets: LANRoute.subnets(of: iface))
            try LANPoolsAdmin.write(out)
            print("\(user): \(out.grants[user]?.joined(separator: ", ") ?? "") on \(iface)")
        }
    }

    struct PoolRemove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "remove", abstract: "Take a range (or, without one, every range) back from a user.")
        @Argument(help: "Account name.") var user: String
        @Argument(help: "The range, as granted.") var range: String?
        // @port-skip linux-only: admin CLI
        func run() async throws {
            guard geteuid() == 0 else { throw ValidationError("admin pool needs root") }
            var file = try LANPoolsFile.load(requireInterface: false)
            if let range {
                guard file.grants[user]?.contains(range) == true else { throw ValidationError("\(user) has no range '\(range)'") }
                file.grants[user]?.removeAll { $0 == range }
                if file.grants[user]?.isEmpty == true { file.grants[user] = nil }
            } else {
                file.grants[user] = nil
            }
            try LANPoolsAdmin.write(file)
            print("\(user): \(file.grants[user]?.joined(separator: ", ") ?? "no pool")")
        }
    }

    struct PoolList: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "Every user's pool.")
        // @port-skip linux-only: admin CLI
        func run() async throws {
            let file = try LANPoolsFile.load(requireInterface: false)
            print("interface: \(file.resolvedInterface() ?? "?")\(file.interface == nil ? " (default route)" : "")")
            for (u, r) in file.grants.sorted(by: { $0.key < $1.key }) { print(u.padding(toLength: 20, withPad: " ", startingAt: 0) + r.joined(separator: ", ")) }
        }
    }

    struct Code: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "A one-time enrollment code for a user's first login from an app.")
        @Argument(help: "Account name.") var name: String
        @Option(help: "Minutes it stays valid (1-60).") var minutes = 30
        // @port-skip linux-only: admin CLI
        func run() async throws {
            let r = try MultiUserAdmin.request(name, "POST", "/remote/code", ["minutes": .number(Double(minutes))])
            print("Enrollment code for \(name) (one use, \(minutes) min): \(r?["code"]?.stringValue ?? "?")")
        }
    }
}
