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
        subcommands: [Daemon.self, VM.self, Image.self, StopPost.self])
}

// @port-skip linux-only: the daemon entry point (macOS runs as an app)
struct Daemon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run the daemon (systemd: bromure-ac.service).")

    // @port-skip linux-only: daemon main
    func run() async throws {
        // Before anything spawns threads that inherit the mask.
        _ = acl_unblock_term_signals()
        let config = DaemonConfig.fromEnvironment()
        let daemon = try await ACLinux.Daemon.start(config)
        let server = try await ControlServer.start(path: config.controlSocketPath) { req in await daemon.handle(req) }
        FileHandle.standardError.write(Data("bromure-ac daemon: \(config.controlSocketPath)\n".utf8))
        _ = acl_sd_notify("READY=1\nSTATUS=serving \(config.controlSocketPath)")
        // SIGTERM (systemctl stop) / SIGINT: stop the VMs and passt, then exit.
        // (A parent that spawned us with signals blocked still gets SIGKILL;
        // QEMU and passt follow us then via PDEATHSIG and the socketpair.)
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
    // @port-skip linux-only: detached run (macOS's VMRun also attaches a terminal; no terminals on Linux yet)
    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create and start a VM (detached).")
        @Option(help: "VM name.") var name: String?
        @Option(help: "q35 or microvm.") var machine = "microvm"
        @Option(name: .customLong("memory-gb"), help: "RAM in GiB.") var memoryGB = 2.0
        @Option(help: "vCPUs.") var cpus = 2

        // @port-skip linux-only: detached run
        func run() async throws {
            var body: [String: JSONValue] = ["machine": .string(machine), "memoryGB": .number(memoryGB),
                                             "cpus": .number(Double(cpus)), "detach": true]
            if let name { body["name"] = .string(name) }
            let r = try client().request("POST", "/vms", body: .object(body))
            try check(r, "run")
            print(r.json["id"]?.stringValue ?? "")
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
        @Flag(help: "Kill QEMU at once instead of an ACPI shutdown (Linux).") var force = false

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
        static let configuration = CommandConfiguration(abstract: "Suspend a VM (save its RAM to disk).")
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
        // @port-skip linux-only: start a stopped VM
        func run() async throws {
            let r = try client().request("POST", "/vms/\(ControlClient.encodeSegment(vm))/start")
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
            abstract: "Bake the amd64 guest image under QEMU/KVM from vm-setup (needs /dev/kvm and network).")
        @Option(help: "Output directory. Default: the daemon's image directory.") var out: String?
        @Option(name: .customLong("vm-setup"), help: "vm-setup directory (setup.sh and the agents).")
        var vmSetup = "Sources/AgentCoding/Resources/vm-setup"
        @Option(name: .customLong("image-version"), help: "Stamp for base.version. Default: UbuntuImageManager.imageVersion from the repo.")
        var imageVersion: String?
        @Option(help: "Download cache.") var cache: String?
        @Option(help: "Installer vCPUs.") var cpus = 4
        @Option(help: "Installer NIC MTU.") var mtu = 1500
        @Option(name: .customLong("ubuntu-mirror"), help: "Ubuntu mirror. Default: setup.sh's for the arch.") var ubuntuMirror: String?
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
