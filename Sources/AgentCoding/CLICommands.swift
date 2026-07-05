import ArgumentParser
import Foundation
import SandboxEngine

// MARK: - Control-socket client

/// Synchronous HTTP-over-Unix-socket client for the agent's control socket —
/// the `bromure-ac` CLI's transport. Mirrors how `docker` talks to
/// /var/run/docker.sock: plain HTTP/1.1 over an AF_UNIX stream.
struct ControlClient {
    let socketPath: String

    init(socketPath: String? = nil) {
        self.socketPath = socketPath ?? ProfileStore().controlSocketURL.path
    }

    struct Response { let status: Int; let json: [String: Any] }

    enum ClientError: LocalizedError {
        case agentNotRunning
        case transport(String)
        var errorDescription: String? {
            switch self {
            case .agentNotRunning:  return "The bromure-ac agent isn't running."
            case .transport(let m): return m
            }
        }
    }

    // MARK: Request

    @discardableResult
    func request(_ method: String, _ path: String, body: [String: Any]? = nil) throws -> Response {
        guard let fd = Self.connect(to: socketPath) else { throw ClientError.agentNotRunning }
        defer { Darwin.close(fd) }

        let bodyData = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        var head = "\(method) \(path) HTTP/1.1\r\n"
        head += "Host: localhost\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(bodyData.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8); out.append(bodyData)
        _ = out.withUnsafeBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return 0 }
            return Darwin.write(fd, base, out.count)
        }

        var resp = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if n <= 0 { break }
            resp.append(contentsOf: buf[0..<n])
        }
        guard let str = String(data: resp, encoding: .utf8),
              let sep = str.range(of: "\r\n\r\n") else {
            throw ClientError.transport("Invalid HTTP response from agent")
        }
        // NB: "\r\n" is a single grapheme cluster in Swift, so
        // `firstIndex(of: "\r")` finds nothing — split on the substring instead.
        let firstLine = str.components(separatedBy: "\r\n").first ?? ""
        let status = firstLine.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        let json = (try? JSONSerialization.jsonObject(
            with: Data(str[sep.upperBound...].utf8)) as? [String: Any]) ?? [:]
        return Response(status: status, json: json)
    }

    /// Open a streaming connection: send the request, consume the response
    /// header, and hand back the raw fd for bidirectional streaming. The caller
    /// owns the fd and must close it. Throws on non-200.
    func openStream(_ method: String, _ path: String, body: [String: Any]) throws -> Int32 {
        guard let fd = Self.connect(to: socketPath) else { throw ClientError.agentNotRunning }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8); out.append(bodyData)
        _ = out.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, out.count) }

        // Read exactly up to the end of the response header (\r\n\r\n) one byte
        // at a time, so we don't swallow any stream bytes that follow it.
        var header = [UInt8]()
        var one = [UInt8](repeating: 0, count: 1)
        while true {
            let r = Darwin.read(fd, &one, 1)
            if r <= 0 { Darwin.close(fd); throw ClientError.transport("Agent closed during handshake") }
            header.append(one[0])
            let c = header.count
            if c >= 4, header[c-4] == 13, header[c-3] == 10, header[c-2] == 13, header[c-1] == 10 { break }
            if c > 16384 { Darwin.close(fd); throw ClientError.transport("Oversized response header") }
        }
        let headStr = String(decoding: header, as: UTF8.self)
        let firstLine = headStr.components(separatedBy: "\r\n").first ?? ""
        let status = firstLine.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        if status != 200 {
            var rest = Data(); var b = [UInt8](repeating: 0, count: 4096)
            while true { let r = Darwin.read(fd, &b, b.count); if r <= 0 { break }; rest.append(contentsOf: b[0..<r]) }
            Darwin.close(fd)
            let msg = ((try? JSONSerialization.jsonObject(with: rest)) as? [String: Any])?["error"] as? String
                ?? "request failed (HTTP \(status))"
            throw ClientError.transport(msg)
        }
        return fd
    }

    /// True if the agent answers a health probe on the control socket.
    func isAgentRunning() -> Bool {
        ((try? request("GET", "/health"))?.status ?? 0) == 200
    }

    /// Ensure the agent is up — autostart `bromure-ac run --headless` if not,
    /// then poll the control socket until it answers (or `timeout` elapses).
    func ensureAgentRunning(timeout: TimeInterval = 40) throws {
        if isAgentRunning() { return }

        let exe = Bundle.main.executableURL?.path ?? CommandLine.arguments[0]
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = ["run", "--headless"]
        // Detach from this CLI's stdio so the agent survives us exiting.
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() }
        catch { throw ClientError.transport("Couldn't start the agent: \(error.localizedDescription)") }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isAgentRunning() { return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        throw ClientError.transport("Agent didn't come up within \(Int(timeout))s.")
    }

    /// Percent-encode an id/name as a single path segment so values with
    /// spaces (e.g. a profile named "Default profile") survive the HTTP request
    /// line. The agent decodes it before resolving.
    static func encodeSegment(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: Socket

    private static let cliDebug = ProcessInfo.processInfo.environment["BROMURE_CLI_DEBUG"] != nil

    private static func connect(to path: String) -> Int32? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            if cliDebug { FileHandle.standardError.write(Data("[cli] socket() failed: \(String(cString: strerror(errno)))\n".utf8)) }
            return nil
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < cap else {
            if cliDebug { FileHandle.standardError.write(Data("[cli] path too long (\(bytes.count) >= \(cap)): \(path)\n".utf8)) }
            Darwin.close(fd); return nil
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: cap) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = b }
                dst[bytes.count] = 0
            }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            if cliDebug { FileHandle.standardError.write(Data("[cli] connect() failed: \(String(cString: strerror(errno))) path=\(path)\n".utf8)) }
            Darwin.close(fd); return nil
        }
        return fd
    }
}

// MARK: - Formatting helpers

private func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

private func formatUptime(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    let m = seconds / 60
    if m < 60 { return "\(m)m" }
    let h = m / 60
    return "\(h)h\(m % 60)m"
}

// MARK: - workspace / VM lifecycle subcommands
//
// These live under the unified `workspaces` command (aliased `vm`). The old
// separate `vm` group and its `ls`/`describe` were folded in: `WorkspacesList`
// replaces both list commands, and `ProfilesDescribe` is the single `describe`.

struct VMRun: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Start a workspace's VM — or create a throwaway one (docker-style) with --name/--tool.")

    @Argument(help: "Workspace to start — id or name (see `vm ls`). Omit only to create a throwaway VM with --name/--tool.")
    var workspace: String?

    @Option(name: [.customShort("v"), .long],
            help: "Mount a host folder into the VM at ~/<basename>. Repeatable (max 8). e.g. -v ~/project")
    var volume: [String] = []

    @Option(name: .long, help: "Name for an on-the-fly workspace (default: cli-XXXX).")
    var name: String?

    @Option(name: .long, help: "Tool for an on-the-fly workspace: claude | codex | grok.")
    var tool: String?

    @Option(name: .long, help: "Auth mode for an on-the-fly workspace: token | subscription | bedrock.")
    var auth: String?

    @Option(name: .long, help: "API key (for --auth token).")
    var apiKey: String?

    @Option(name: .long, help: "VM RAM in GB.")
    var memory: Int?

    @Flag(name: [.customShort("d"), .long],
          help: "Detached: boot and return without attaching your terminal (docker-style).")
    var detach = false

    @Flag(name: .long, help: "Delete the workspace + disk when the VM stops (ephemeral).")
    var rm = false

    func run() throws {
        let client = ControlClient()
        try client.ensureAgentRunning()
        // CLI-created sessions always boot window-less — the terminal is the UI.
        // The GUI is opt-in afterwards via `vm attach --window`.
        var spec: [String: Any] = ["detach": true, "rm": rm]
        if let workspace {
            spec["profile"] = workspace                        // start an existing workspace
        } else if name != nil || tool != nil || auth != nil {  // create a throwaway on-the-fly
            if let name { spec["name"] = name }
            if let tool { spec["tool"] = tool }
            if let auth { spec["auth"] = auth }
            if let apiKey { spec["apiKey"] = apiKey }
        } else {
            throw ValidationError(
                "Specify a workspace to start (e.g. `vm run iptest2` — see `vm ls`), "
                + "or pass --name/--tool to create a throwaway one.")
        }
        if let memory { spec["memoryGB"] = memory }
        if !volume.isEmpty {
            spec["mounts"] = volume.map { ($0 as NSString).expandingTildeInPath }
        }
        let resp = try client.request("POST", "/vms", body: spec)
        guard resp.status == 201 else {
            throw ValidationError(resp.json["error"] as? String ?? "vm run failed (HTTP \(resp.status))")
        }
        let id = resp.json["shortId"] as? String ?? String((resp.json["id"] as? String ?? "?").prefix(12))
        let fullID = (resp.json["id"] as? String) ?? id
        let nm = resp.json["name"] as? String ?? "?"

        // -d, or no terminal to hand over (piped/scripted) → boot-and-return.
        if detach || isatty(STDIN_FILENO) == 0 {
            print("Started VM \(nm) (\(id))\(detach ? " [detached]" : "").")
            return
        }

        // Default (docker-style): hand the terminal to the VM's tmux session.
        // Wait for the guest agent to bring `bromure` up first — on a fresh boot
        // the session doesn't exist the instant the VM registers.
        FileHandle.standardError.write(Data(
            "Started VM \(nm) (\(id)). Attaching… (Ctrl-b d to detach, leaves it running)\n".utf8))
        Self.waitForTmux(client: client, vm: fullID)
        try InteractiveExec.run(client: client, vm: fullID, command: "tmux attach -t bromure")
    }

    /// Poll the guest until its `bromure` tmux session exists (or we give up).
    /// `tmux attach` to a missing session exits immediately, so without this the
    /// attach would race the agent's session setup on a cold boot.
    private static func waitForTmux(client: ControlClient, vm: String) {
        for _ in 0..<100 {   // up to ~20s
            let resp = try? client.request(
                "POST", "/vms/\(ControlClient.encodeSegment(vm))/exec",
                body: ["command": "tmux has-session -t bromure", "timeout": 5])
            if resp?.status == 200, (resp?.json["exitCode"] as? Int ?? 1) == 0 { return }
            usleep(200_000)
        }
    }
}

struct VMKill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kill", abstract: "Stop a VM (shut down, or suspend with --suspend).")

    @Argument(help: "VM id or workspace name.")
    var vm: String

    @Flag(name: .long, help: "Suspend (save RAM to disk) instead of powering off.")
    var suspend = false

    func run() throws {
        let client = ControlClient()
        guard client.isAgentRunning() else { print("No bromure-ac agent running."); return }
        let action = suspend ? "suspend" : "shutdown"
        let resp = try client.request("DELETE", "/vms/\(ControlClient.encodeSegment(vm))", body: ["action": action])
        guard resp.status == 200 else {
            throw ValidationError(resp.json["error"] as? String ?? "Couldn't stop \(vm).")
        }
        print("\(suspend ? "Suspended" : "Stopped") \(vm).")
    }
}

struct VMAttach: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "attach",
        abstract: "Attach your terminal to a VM's tmux session, a tab, or a docker container.",
        discussion: """
        Examples:
          vm attach my-workspace                      # current tmux tab
          vm attach my-workspace 2                     # jump to tab 2
          vm attach my-workspace containers:web -- bash  # docker exec -it into a container
        """)

    @Argument(help: "VM id or workspace name.")
    var vm: String

    @Argument(help: "Tab index, or `containers:<name>` for a running container. Omit for the current tab.")
    var target: String?

    @Argument(parsing: .postTerminator,
              help: "Shell/command for a container target, after `--` (default: bash).")
    var command: [String] = []

    @Flag(name: .shortAndLong, help: "Open a GUI window instead of attaching your terminal.")
    var window = false

    func run() throws {
        let client = ControlClient()
        try client.ensureAgentRunning()

        // --window: open / reattach a GUI window onto the VM.
        if window {
            let resp = try client.request("POST", "/vms/\(ControlClient.encodeSegment(vm))/attach")
            guard resp.status == 200 else {
                throw ValidationError(resp.json["error"] as? String ?? "Couldn't attach to \(vm).")
            }
            print("Attached \(vm).")
            return
        }

        let vms = (try client.request("GET", "/vms").json["vms"] as? [[String: Any]]) ?? []
        guard let vmObj = vms.first(where: { matchesVM($0, vm) }) else {
            throw ValidationError("VM not found: \(vm)")
        }
        let vmID = (vmObj["id"] as? String) ?? vm

        // containers:<name> → docker exec -it into that container.
        if let target, target.hasPrefix("containers:") {
            let name = String(target.dropFirst("containers:".count))
            guard isSafeContainerRef(name) else {
                throw ValidationError("Invalid container name: \(name)")
            }
            let shell = command.isEmpty ? "bash" : command.joined(separator: " ")
            try InteractiveExec.run(client: client, vm: vmID,
                                    command: "docker exec -it \(name) \(shell)")
            return
        }

        // Terminal attach to the one tmux session. The GUI kitty and this CLI
        // client share it (lockstep), so a tab switch on either side moves both.
        // With a tab index, jump to that tmux window first.
        var cmd = "tmux attach -t bromure"
        if let target {
            guard let idx = Int(target) else {
                throw ValidationError("Tab must be a number or `containers:<name>`: \(target)")
            }
            cmd += " \\; select-window -t bromure:\(idx)"
        }
        try InteractiveExec.run(client: client, vm: vmID, command: cmd)
    }
}

/// Conservative validation for a docker container name/id used in a shell line.
private func isSafeContainerRef(_ s: String) -> Bool {
    !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || "_.-".contains($0) }
}

/// Running containers in a VM (via `docker ps`), for `ls` / `describe`.
private func runningContainers(_ client: ControlClient, vmID: String)
    -> [(name: String, image: String, status: String)]
{
    guard let r = try? client.request(
        "POST", "/vms/\(ControlClient.encodeSegment(vmID))/exec",
        body: ["command": "docker ps --format '{{.Names}}\\t{{.Image}}\\t{{.Status}}' 2>/dev/null",
               "timeout": 5]),
        r.status == 200, let out = r.json["stdout"] as? String else { return [] }
    return out.split(whereSeparator: \.isNewline).compactMap { line in
        let c = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard c.count >= 2 else { return nil }
        return (name: String(c[0]), image: String(c[1]),
                status: c.count >= 3 ? String(c[2]) : "")
    }
}

/// Match a `vm ls` entry against a user-supplied id / short-id-prefix / name.
private func matchesVM(_ vm: [String: Any], _ key: String) -> Bool {
    let k = key.replacingOccurrences(of: "-", with: "").lowercased()
    if let name = vm["name"] as? String, name.lowercased() == key.lowercased() { return true }
    if let sid = vm["shortId"] as? String, sid.lowercased().hasPrefix(k) { return true }
    if let id = vm["id"] as? String,
       id.replacingOccurrences(of: "-", with: "").lowercased().hasPrefix(k) { return true }
    return false
}

// MARK: - `exec`

// MARK: - `profiles` subcommand group

struct VMCheckpoints: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "checkpoints",
        abstract: "List a workspace's disk rollback points (newest first). One is taken on each successful boot.")

    @Argument(help: "Workspace id or name.")
    var vm: String

    func run() throws {
        let client = ControlClient()
        guard client.isAgentRunning() else { print("No bromure-ac agent running."); return }
        let resp = try client.request("GET", "/vms/\(ControlClient.encodeSegment(vm))/checkpoints")
        guard resp.status == 200 else {
            throw ValidationError(resp.json["error"] as? String ?? "Couldn't list checkpoints.")
        }
        let list = resp.json["checkpoints"] as? [[String: Any]] ?? []
        if list.isEmpty { print("No checkpoints for \(vm) yet — one is taken on each successful boot."); return }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        print("CHECKPOINT    CREATED               SIZE")
        for c in list {
            let id = (c["id"] as? String ?? "?").padding(toLength: 12, withPad: " ", startingAt: 0)
            let ts = c["createdAt"] as? Int ?? 0
            let date = fmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
            let mb = String(format: "%.0f MB", Double(c["allocatedBytes"] as? Int ?? 0) / 1_000_000)
            print("\(id)  \(date)   \(mb)")
        }
        print("\nRevert with:  vm revert \(vm) <CHECKPOINT>   (stop the workspace first)")
    }
}

struct VMRevert: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "revert",
        abstract: "Roll a workspace's disk back to a checkpoint. Stop the workspace first; your home dir + project folder are untouched.")

    @Argument(help: "Workspace id or name.")
    var vm: String
    @Argument(help: "Checkpoint id (from `vm checkpoints`).")
    var checkpoint: String

    func run() throws {
        let client = ControlClient()
        guard client.isAgentRunning() else { print("No bromure-ac agent running."); return }
        let resp = try client.request("POST", "/vms/\(ControlClient.encodeSegment(vm))/revert",
                                      body: ["checkpoint": checkpoint])
        guard resp.status == 200 else {
            throw ValidationError(resp.json["error"] as? String ?? "Revert failed.")
        }
        print("Reverted \(vm) to checkpoint \(checkpoint). Boot it with `vm run \(vm)`.")
    }
}

struct Profiles: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "workspaces",
        abstract: "Manage workspaces — list (live + off), boot, exec, and lifecycle. Also available as `vm`.",
        // NOTE: disk checkpoints run silently (a snapshot per boot, kept to 5),
        // but VMCheckpoints/VMRevert are intentionally NOT registered yet — the
        // list/revert surface stays unexposed until we decide to ship it. The
        // structs + control routes remain so re-exposing is a one-line change.
        subcommands: [WorkspacesList.self, WorkspacesCreate.self, WorkspacesEdit.self,
                      VMRun.self, VMKill.self, WorkspacesReboot.self, Exec.self,
                      VMAttach.self, ProfilesDescribe.self, ProfilesRemove.self,
                      WorkspacesSSHKeygen.self, WorkspacePorts.self,
                      VMFusion.self, VMRouting.self, VMHybrid.self],
        // Default subcommand so `vm <workspace> -L` works docker-style: an
        // unrecognized first token falls through to `ports` as its argument.
        // Bare `vm` still shows the group help (ports with no workspace
        // re-raises the help request).
        defaultSubcommand: WorkspacePorts.self,
        aliases: ["vm"])
}

/// Unified listing: every workspace and its live state — off, suspended,
/// booting, or running — mirroring the app's unified window. Running ones also
/// show uptime, whether a window is attached, and their tmux tabs.
struct WorkspacesList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List all workspaces and their live state (off / suspended / running).")

    func run() throws {
        let client = ControlClient()
        guard client.isAgentRunning() else { print("No bromure-ac agent running."); return }
        let workspaces = (try client.request("GET", "/profiles").json["profiles"] as? [[String: Any]]) ?? []
        if workspaces.isEmpty { print("No workspaces. Create one in the bromure-ac app first."); return }
        // Running details (uptime, window, tabs) keyed by full id.
        let vms = (try? client.request("GET", "/vms").json["vms"] as? [[String: Any]]) ?? []
        var running: [String: [String: Any]] = [:]
        for vm in vms { if let id = vm["id"] as? String { running[id] = vm } }

        print(pad("WORKSPACE ID", 14) + pad("NAME", 22) + pad("TOOL", 9)
              + pad("AUTH", 14) + pad("STATE", 11) + pad("UP", 8) + "WINDOW")
        for w in workspaces.sorted(by: { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }) {
            let id = w["id"] as? String ?? ""
            let short = w["shortId"] as? String
                ?? String(id.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
            let name = w["name"] as? String ?? ""
            let tool = w["tool"] as? String ?? ""
            let auth = w["authMode"] as? String ?? ""
            let state = w["state"] as? String ?? "off"
            let vm = running[id]
            let live = (state == "running" || state == "booting")
            let up  = live ? formatUptime(vm?["uptimeSeconds"] as? Int ?? 0) : "-"
            let win = live ? ((vm?["attached"] as? Bool ?? false) ? "attached" : "detached") : "-"
            print(pad(short, 14) + pad(name, 22) + pad(tool, 9) + pad(auth, 14)
                  + pad(state, 11) + pad(up, 8) + win)
            // tmux tabs as a tree for running workspaces; `*` marks the active one.
            for t in (vm?["tabs"] as? [[String: Any]] ?? []) {
                let idx = t["index"] as? Int ?? 0
                let title = t["title"] as? String ?? "shell"
                let active = (t["active"] as? Bool ?? false) ? " *" : ""
                print("    └─ \(title) (\(idx))\(active)")
            }
            // Running docker containers, if any (attach with `vm attach <id> containers:<name>`).
            if live {
                for c in runningContainers(client, vmID: id) {
                    print("    🐳 \(c.name)  \(c.image)  \(c.status)")
                }
            }
        }
    }
}

struct ProfilesDescribe: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "describe", abstract: "Show a workspace's settings.")

    @Argument(help: "Workspace id or name.")
    var workspace: String

    func run() throws {
        let client = ControlClient()
        guard client.isAgentRunning() else { print("No bromure-ac agent running."); return }
        let resp = try client.request("GET", "/profiles/\(ControlClient.encodeSegment(workspace))")
        guard resp.status == 200 else {
            throw ValidationError(resp.json["error"] as? String ?? "Workspace not found: \(workspace)")
        }
        let v = resp.json
        func row(_ k: String, _ s: String?) {
            guard let s, !s.isEmpty else { return }
            print("  " + pad(k, 16) + s)
        }
        print("\(v["name"] as? String ?? "?")  (\(v["shortId"] as? String ?? ""))")
        row("id", v["id"] as? String)
        row("tool", v["tool"] as? String)
        row("auth", v["authMode"] as? String)
        row("api key", (v["apiKeySet"] as? Bool ?? false) ? "set" : "not set")
        row("memory", (v["memoryGB"] as? Int).map { "\($0) GB" })
        row("network", v["networkMode"] as? String)
        row("mac", v["macAddress"] as? String)
        row("close action", v["closeAction"] as? String)
        if v["bootAtStartup"] as? Bool == true { row("boot at login", "yes") }
        row("color", v["color"] as? String)
        row("ssh key", (v["sshKeySet"] as? Bool ?? false) ? "set" : "not set")
        if let n = v["importedSSHKeys"] as? Int, n > 0 { row("imported keys", String(n)) }
        row("running", (v["running"] as? Bool ?? false) ? "yes" : "no")
        row("created", v["createdAt"] as? String)
        row("last used", v["lastUsedAt"] as? String)
        if let folders = v["folderPaths"] as? [String], !folders.isEmpty {
            print("  shared folders:")
            for f in folders { print("    - \(f)") }
        }
        if let mcp = v["mcpServers"] as? [String], !mcp.isEmpty {
            print("  mcp servers:")
            for m in mcp { print("    - \(m)") }
        }
        if let c = v["comments"] as? String, !c.isEmpty { print("  comments:        \(c)") }

        // When the workspace is running, append its live runtime details (what
        // the old `vm describe` showed) — pulled from the running-VM listing.
        if v["running"] as? Bool == true {
            let vms = (try? client.request("GET", "/vms").json["vms"] as? [[String: Any]]) ?? []
            if let vm = vms.first(where: { ($0["id"] as? String) == (v["id"] as? String) }) {
                print("  ── runtime ──")
                row("state", vm["state"] as? String)
                row("window", (vm["attached"] as? Bool ?? false) ? "attached" : "detached")
                row("uptime", formatUptime(vm["uptimeSeconds"] as? Int ?? 0))
                row("ip", (vm["ip"] as? String).flatMap { $0.isEmpty ? nil : $0 })
                row("vCPUs", (vm["cpuCount"] as? Int).map(String.init))
                let fc = vm["fusionConfigurable"] as? Bool ?? false
                let fe = vm["fusionEngaged"] as? Bool ?? false
                row("fusion", fc ? (fe ? "engaged" : "available (off)")
                                 : "not configurable (needs ≥2 models)")
                row("base image", vm["baseImageVersion"] as? String)
                if let usedKB = vm["diskUsedKB"] as? Int,
                   let totalKB = vm["diskTotalKB"] as? Int, totalKB > 0 {
                    // Guest df numbers (FS truth) — preferred over the host-side
                    // CoW clone allocation, which overstates real usage.
                    let used = ByteCountFormatter.string(fromByteCount: Int64(usedKB) * 1024, countStyle: .file)
                    let total = ByteCountFormatter.string(fromByteCount: Int64(totalKB) * 1024, countStyle: .file)
                    row("disk", "\(used) used of \(total)")
                } else if let bytes = vm["diskAllocatedBytes"] as? Int {
                    let sz = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                    row("disk", "\(sz) allocated on host")
                }
                if let tabs = vm["tabs"] as? [[String: Any]], !tabs.isEmpty {
                    print("  tabs:")
                    for t in tabs { print("    \(t["index"] as? Int ?? 0). \(t["title"] as? String ?? "shell")") }
                }
                let containers = runningContainers(client, vmID: vm["id"] as? String ?? workspace)
                if !containers.isEmpty {
                    print("  containers:")
                    for c in containers {
                        print("    🐳 \(c.name)  \(c.image)  \(c.status)   (attach: vm attach \(v["shortId"] as? String ?? "") containers:\(c.name) -- bash)")
                    }
                }
                let target = vm["id"] as? String ?? workspace
                if let r = try? client.request(
                    "POST", "/vms/\(ControlClient.encodeSegment(target))/exec",
                    body: ["command": "free -m | awk 'NR==2{print $3\"/\"$2\" MB\"}'", "timeout": 4]),
                   r.status == 200,
                   let out = (r.json["stdout"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !out.isEmpty {
                    row("memory (in use)", out)
                }
            }
        }
    }
}

struct ProfilesRemove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm", abstract: "Delete a workspace and all its data (disk + home).")

    @Argument(help: "Workspace id or name.")
    var workspace: String

    @Flag(name: [.customShort("f"), .long], help: "Skip the confirmation prompt.")
    var force = false

    func run() throws {
        let client = ControlClient()
        guard client.isAgentRunning() else { print("No bromure-ac agent running."); return }
        if !force {
            FileHandle.standardError.write(Data(
                "Delete workspace '\(workspace)' and ALL its data (disk + home)? [y/N] ".utf8))
            let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard answer == "y" || answer == "yes" else { print("Aborted."); return }
        }
        let resp = try client.request("DELETE", "/profiles/\(ControlClient.encodeSegment(workspace))")
        guard resp.status == 200, (resp.json["ok"] as? Bool) == true else {
            throw ValidationError(resp.json["error"] as? String ?? "Couldn't delete \(workspace).")
        }
        print("Deleted workspace \(resp.json["name"] as? String ?? workspace).")
    }
}

// MARK: - `workspaces create` / `edit` / `reboot`

struct WorkspacesCreate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a workspace (the CLI counterpart of the app's New Workspace editor).",
        discussion: """
        Set common fields with flags, or pass a full profile JSON document with
        --from-json (a file path, or - for stdin — same shape as `workspaces edit`).
        Flags override any matching field in the JSON document.

        Examples:
          workspaces create --name web --tool claude --auth token --api-key sk-… --memory 8
          workspaces create --from-json ./ws.json
        """)

    @Option(name: .long, help: "Workspace name (required unless --from-json supplies one).")
    var name: String?
    @Option(name: .long, help: "Primary tool: claude | codex | grok.")
    var tool: String?
    @Option(name: .long, help: "Auth mode: token | subscription | bedrock | local.")
    var auth: String?
    @Option(name: .long, help: "API key (for --auth token).")
    var apiKey: String?
    @Option(name: .long, help: "VM RAM in GB.")
    var memory: Int?
    @Option(name: .long, help: "Accent color: blue|red|green|orange|purple|pink|teal|gray.")
    var color: String?
    @Option(name: [.customShort("v"), .long],
            help: "Shared host folder mounted at ~/<basename>. Repeatable.")
    var folder: [String] = []
    @Flag(name: .long, help: "Generate a fresh SSH key (host-side; the public key is printed).")
    var generateSsh = false
    @Option(name: .long, help: "Full profile JSON document: a file path, or - for stdin.")
    var fromJson: String?

    func run() throws {
        let client = ControlClient()
        try client.ensureAgentRunning()
        var body: [String: Any] = [:]
        if let fromJson { body = try loadJSONDocument(fromJson) }
        if let name { body["name"] = name }
        if let tool { body["tool"] = tool }
        if let auth { body["authMode"] = auth }
        if let apiKey { body["apiKey"] = apiKey }
        if let memory { body["memoryGB"] = memory }
        if let color { body["color"] = color }
        if !folder.isEmpty {
            body["folderPaths"] = folder.map { ($0 as NSString).expandingTildeInPath }
        }
        if generateSsh { body["generateSSH"] = true }
        guard (body["name"] as? String)?.isEmpty == false else {
            throw ValidationError("A workspace name is required (--name, or a \"name\" in --from-json).")
        }
        let resp = try client.request("POST", "/profiles", body: body)
        guard resp.status == 201, (resp.json["ok"] as? Bool) == true else {
            throw ValidationError(resp.json["error"] as? String
                ?? "Couldn't create the workspace (HTTP \(resp.status)).")
        }
        let sid = resp.json["shortId"] as? String ?? ""
        let nm = resp.json["name"] as? String ?? (body["name"] as? String ?? "?")
        print("Created workspace \(nm)\(sid.isEmpty ? "" : " (\(sid))").")
        if let pub = resp.json["sshPublicKey"] as? String, !pub.isEmpty {
            print("\nSSH public key (add to your Git host):\n\(pub)")
        }
    }
}

struct WorkspacesSSHKeygen: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ssh-keygen",
        abstract: "Generate a fresh SSH key for a workspace (host-side; prints the public key).")

    @Argument(help: "Workspace id or name.")
    var workspace: String

    func run() throws {
        let client = ControlClient()
        try client.ensureAgentRunning()
        let seg = ControlClient.encodeSegment(workspace)
        let cur = try client.request("GET", "/profiles/\(seg)?full=1")
        guard cur.status == 200 else {
            throw ValidationError(cur.json["error"] as? String ?? "Workspace not found: \(workspace)")
        }
        var doc = cur.json
        doc["generateSSH"] = true
        let resp = try client.request("PUT", "/profiles/\(seg)", body: doc)
        guard resp.status == 200, (resp.json["ok"] as? Bool) == true else {
            throw ValidationError(resp.json["error"] as? String ?? "Couldn't generate a key (HTTP \(resp.status)).")
        }
        if let pub = resp.json["sshPublicKey"] as? String, !pub.isEmpty {
            print(pub)
        } else {
            print("Generated a new SSH key for \(workspace).")
        }
    }
}

struct WorkspacesEdit: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "edit",
        abstract: "Edit a workspace's full settings — opens its JSON in $EDITOR (kubectl-style).",
        discussion: """
        With no --from-json this fetches the workspace's entire configuration,
        opens it in $EDITOR (or vi), and saves your changes back. Secrets are shown
        blank: leave one blank to keep the stored value, or type a new value to
        change it. Pass --from-json to apply a document non-interactively.
        """)

    @Argument(help: "Workspace id or name.")
    var workspace: String
    @Option(name: .long, help: "Apply a full profile JSON document non-interactively: a file path, or - for stdin.")
    var fromJson: String?

    func run() throws {
        let client = ControlClient()
        try client.ensureAgentRunning()
        let seg = ControlClient.encodeSegment(workspace)
        let body: [String: Any]
        if let fromJson {
            body = try loadJSONDocument(fromJson)
        } else {
            let cur = try client.request("GET", "/profiles/\(seg)?full=1")
            guard cur.status == 200 else {
                throw ValidationError(cur.json["error"] as? String ?? "Workspace not found: \(workspace)")
            }
            guard let edited = try editJSONInEditor(cur.json) else {
                print("No changes."); return
            }
            body = edited
        }
        let resp = try client.request("PUT", "/profiles/\(seg)", body: body)
        guard resp.status == 200, (resp.json["ok"] as? Bool) == true else {
            throw ValidationError(resp.json["error"] as? String ?? "Couldn't save (HTTP \(resp.status)).")
        }
        print("Saved workspace \(resp.json["name"] as? String ?? workspace).")
    }
}

struct WorkspacesReboot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reboot",
        abstract: "Reboot a running workspace (graceful by default; --hard tears it down immediately).")

    @Argument(help: "Workspace id or name.")
    var workspace: String
    @Flag(name: .long, help: "Hard reboot: stop the VM immediately instead of a graceful halt.")
    var hard = false

    func run() throws {
        let client = ControlClient()
        try client.ensureAgentRunning()
        FileHandle.standardError.write(Data("Rebooting \(workspace) (\(hard ? "hard" : "soft"))…\n".utf8))
        let resp = try client.request("POST", "/vms/\(ControlClient.encodeSegment(workspace))/reboot",
                                      body: ["mode": hard ? "hard" : "soft"])
        guard resp.status == 200, (resp.json["ok"] as? Bool) == true else {
            throw ValidationError(resp.json["error"] as? String ?? "Couldn't reboot \(workspace).")
        }
        print("Rebooted \(resp.json["workspace"] as? String ?? workspace).")
    }
}

struct WorkspacePorts: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ports",
        abstract: "Show a running workspace's listening ports (also `vm <workspace> -L`).",
        discussion: """
        Queries the guest live with `ss` (root, so process names resolve for every
        service — netstat/lsof aren't in default Ubuntu). Loopback-bound ports are
        listed too and marked; the app dashboard shows only the externally
        reachable ones.
        """)

    @Argument(help: "Workspace id or name.")
    var workspace: String?

    @Flag(name: [.customShort("L"), .long],
          help: "List listening ports (the only mode; lets `vm <workspace> -L` read naturally).")
    var listening = false

    func run() throws {
        guard let workspace, workspace.lowercased() != "help" else {
            // Bare `vm` (and `vm help`) land here because ports is the group's
            // default subcommand: keep the pre-existing behavior — show help.
            throw CleanExit.helpRequest(Profiles.self)
        }
        let client = ControlClient()
        guard client.isAgentRunning() else { print("No bromure-ac agent running."); return }
        // Resolve BEFORE exec'ing: a typo'd subcommand falls through to here as
        // a "workspace", and the exec route would sit in its 10s
        // shell-connection wait before erroring. Describe 404s instantly.
        let seg = ControlClient.encodeSegment(workspace)
        let probe = try client.request("GET", "/profiles/\(seg)")
        guard probe.status == 200 else {
            throw ValidationError(
                "Unknown workspace (or subcommand) '\(workspace)'. See `vm ls` or `vm --help`.")
        }
        guard (probe.json["running"] as? Bool) == true else {
            throw ValidationError(
                "Workspace '\(workspace)' isn't running — start it with `vm run \(workspace)`.")
        }
        let resp = try client.request(
            "POST", "/vms/\(seg)/exec",
            body: ["command": "sudo -n ss -tulnpH 2>/dev/null || ss -tulnH", "timeout": 10])
        guard resp.status == 200 else {
            throw ValidationError(resp.json["error"] as? String
                ?? "Couldn't query '\(workspace)' (HTTP \(resp.status)).")
        }
        let rows = UbuntuSandboxVM.parseListeningPorts(resp.json["stdout"] as? String ?? "")
        guard !rows.isEmpty else { print("No listening ports."); return }
        print(pad("PORT", 7) + pad("PROTO", 7) + pad("ADDRESS", 22) + "PROCESS")
        for r in rows {
            let scope = r.isLoopback ? "  (loopback-only)" : ""
            print(pad("\(r.port)", 7) + pad(r.proto, 7) + pad(r.addr, 22) + r.process + scope)
        }
    }
}

/// Load a JSON object from a file path, or from stdin when `spec == "-"`.
func loadJSONDocument(_ spec: String) throws -> [String: Any] {
    let data: Data
    if spec == "-" {
        data = FileHandle.standardInput.readDataToEndOfFile()
    } else {
        data = try Data(contentsOf: URL(fileURLWithPath: (spec as NSString).expandingTildeInPath))
    }
    guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ValidationError("Expected a JSON object in \(spec == "-" ? "stdin" : spec).")
    }
    return obj
}

/// Write `doc` to a temp file, open $EDITOR (or vi) on it, and return the
/// parsed result — or nil if the user saved no change. Throws on an invalid
/// edit so we never PUT malformed JSON.
func editJSONInEditor(_ doc: [String: Any]) throws -> [String: Any]? {
    let pretty = try JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted, .sortedKeys])
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("bromure-workspace-\(UUID().uuidString).json")
    try pretty.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let before = try Data(contentsOf: file)

    let editor = ProcessInfo.processInfo.environment["VISUAL"]
        ?? ProcessInfo.processInfo.environment["EDITOR"] ?? "vi"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    // Pass the path as $1 so spaces/quotes in the temp path can't break the line.
    p.arguments = ["-c", "\(editor) \"$1\"", "sh", file.path]
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
        throw ValidationError("Editor exited with status \(p.terminationStatus) — not saving.")
    }
    let after = try Data(contentsOf: file)
    if after == before { return nil }
    guard let obj = try JSONSerialization.jsonObject(with: after) as? [String: Any] else {
        throw ValidationError("The edited file isn't valid JSON — not saving.")
    }
    return obj
}

// MARK: - `vm fusion`

struct VMFusion: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fusion",
        abstract: "Enable or disable Fusion (multi-model synthesis) for a running VM.")

    @Argument(help: "enable | disable")
    var action: String

    @Argument(help: "VM id or workspace name.")
    var vm: String

    func run() throws {
        let engaged: Bool
        switch action.lowercased() {
        case "enable", "on", "engage":    engaged = true
        case "disable", "off", "disengage": engaged = false
        default: throw ValidationError("Action must be 'enable' or 'disable'.")
        }
        let client = ControlClient()
        try client.ensureAgentRunning()
        let resp = try client.request("POST", "/vms/\(ControlClient.encodeSegment(vm))/fusion",
                                      body: ["engaged": engaged])
        guard resp.status == 200, (resp.json["ok"] as? Bool) == true else {
            throw ValidationError(resp.json["error"] as? String ?? "Couldn't set fusion for \(vm).")
        }
        print("Fusion \(engaged ? "enabled" : "disabled") for \(vm).")
    }
}

// MARK: - `trace` subcommand group

struct Trace: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trace",
        abstract: "Inspect the MITM session traces (requests, token swaps, leaks).",
        subcommands: [TraceList.self, TraceSummary.self, TraceHostnames.self,
                      TraceLeaks.self, TraceClear.self])
}

private func traceRecords(_ client: ControlClient, profile: String?) throws -> [[String: Any]] {
    var path = "/trace"
    if let profile, !profile.isEmpty { path += "?profile=\(ControlClient.encodeSegment(profile))" }
    return (try client.request("GET", path).json["trace"] as? [[String: Any]]) ?? []
}

/// "2026-06-26T15:30:05Z" → "15:30:05".
private func hms(_ iso: String) -> String {
    if let t = iso.split(separator: "T").last { return String(t.prefix(8)) }
    return iso
}

private func kb(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes)B" }
    let k = Double(bytes) / 1024
    return k < 1024 ? String(format: "%.1fK", k) : String(format: "%.1fM", k / 1024)
}

private func leakCount(_ r: [String: Any]) -> Int { (r["leaks"] as? [[String: Any]])?.count ?? 0 }

struct TraceList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List recent traced requests (newest first).")
    @Argument(help: "Filter to one VM/workspace (id or name).") var workspace: String?
    @Option(name: .long, help: "Max rows (default 50).") var limit: Int = 50

    func run() throws {
        let client = ControlClient()
        guard client.isAgentRunning() else { print("No bromure-ac agent running."); return }
        let recs = try traceRecords(client, profile: workspace)
        guard !recs.isEmpty else {
            print("No trace records. (Tracing is per-workspace — enable it in the workspace's settings.)")
            return
        }
        print(pad("TIME", 10) + pad("HOST", 30) + pad("METHOD", 8) + pad("STATUS", 7)
              + pad("REQ", 8) + pad("RESP", 8) + pad("LAT", 8) + "FLAGS")
        for r in recs.prefix(limit) {
            var flags: [String] = []
            let swaps = r["swaps"] as? Int ?? 0
            if swaps > 0 { flags.append("swap×\(swaps)") }
            let leaks = leakCount(r)
            if leaks > 0 { flags.append("LEAK×\(leaks)") }
            if r["conversation"] as? Bool ?? false { flags.append("conv") }
            print(pad(hms(r["time"] as? String ?? ""), 10)
                  + pad(String((r["host"] as? String ?? "").prefix(28)), 30)
                  + pad(r["method"] as? String ?? "", 8)
                  + pad(String(r["status"] as? Int ?? 0), 7)
                  + pad(kb(r["requestBytes"] as? Int ?? 0), 8)
                  + pad(kb(r["responseBytes"] as? Int ?? 0), 8)
                  + pad("\(Int(r["latencyMs"] as? Double ?? 0))ms", 8)
                  + flags.joined(separator: " "))
        }
        if recs.count > limit { print("… \(recs.count - limit) more (use --limit).") }
    }
}

struct TraceSummary: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "summary", abstract: "Summarize traced traffic (hosts, status, swaps, leaks).")
    @Argument(help: "Filter to one VM/workspace (id or name).") var workspace: String?

    func run() throws {
        let client = ControlClient()
        guard client.isAgentRunning() else { print("No bromure-ac agent running."); return }
        let recs = try traceRecords(client, profile: workspace)
        guard !recs.isEmpty else { print("No trace records."); return }
        var byHost: [String: Int] = [:], byStatus: [Int: Int] = [:]
        var swapReqs = 0, leakReqs = 0, convs = 0, up = 0, down = 0
        for r in recs {
            byHost[r["host"] as? String ?? "?", default: 0] += 1
            byStatus[(r["status"] as? Int ?? 0) / 100, default: 0] += 1
            if (r["swaps"] as? Int ?? 0) > 0 { swapReqs += 1 }
            if leakCount(r) > 0 { leakReqs += 1 }
            if r["conversation"] as? Bool ?? false { convs += 1 }
            up += r["requestBytes"] as? Int ?? 0
            down += r["responseBytes"] as? Int ?? 0
        }
        print("\(recs.count) requests across \(byHost.count) hosts  (\(kb(up)) up / \(kb(down)) down)")
        let status = byStatus.sorted { $0.key < $1.key }.map { "\($0.key)xx×\($0.value)" }.joined(separator: "  ")
        print("  status:  \(status)")
        print("  swaps:   \(swapReqs) req     leaks: \(leakReqs) req\(leakReqs > 0 ? "  ⚠️" : "")     conversations: \(convs)")
        print("  top hosts:")
        for (h, c) in byHost.sorted(by: { $0.value > $1.value }).prefix(10) {
            print("    " + pad(String(c), 6) + h)
        }
    }
}

struct TraceHostnames: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hostnames", abstract: "List distinct hosts contacted (with request counts).")
    @Argument(help: "Filter to one VM/workspace (id or name).") var workspace: String?

    func run() throws {
        let client = ControlClient()
        guard client.isAgentRunning() else { print("No bromure-ac agent running."); return }
        let recs = try traceRecords(client, profile: workspace)
        var byHost: [String: Int] = [:]
        for r in recs { byHost[r["host"] as? String ?? "?", default: 0] += 1 }
        guard !byHost.isEmpty else { print("No trace records."); return }
        for (h, c) in byHost.sorted(by: { $0.key < $1.key }) { print(pad(String(c), 7) + h) }
    }
}

struct TraceLeaks: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "leaks", abstract: "Show requests with potential credential leaks.")
    @Argument(help: "Filter to one VM/workspace (id or name).") var workspace: String?

    func run() throws {
        let client = ControlClient()
        guard client.isAgentRunning() else { print("No bromure-ac agent running."); return }
        let leaky = try traceRecords(client, profile: workspace).filter { leakCount($0) > 0 }
        guard !leaky.isEmpty else { print("No leaks detected. ✓"); return }
        print("\(leaky.count) request(s) with potential credential leaks:")
        for r in leaky {
            let host = r["host"] as? String ?? "?"
            let path = String((r["path"] as? String ?? "").prefix(48))
            print("  \(hms(r["time"] as? String ?? ""))  \(r["method"] as? String ?? "") \(host)\(path)")
            for l in (r["leaks"] as? [[String: Any]]) ?? [] {
                print("      ⚠️  \(l["header"] as? String ?? "?"): \(l["preview"] as? String ?? "") [\(l["suspicion"] as? String ?? "")]")
            }
        }
    }
}

struct TraceClear: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear", abstract: "Clear all trace history (in-memory + on disk).")
    @Flag(name: [.customShort("f"), .long], help: "Skip the confirmation prompt.") var force = false

    func run() throws {
        let client = ControlClient()
        guard client.isAgentRunning() else { print("No bromure-ac agent running."); return }
        if !force {
            FileHandle.standardError.write(Data("Clear ALL trace history? [y/N] ".utf8))
            let a = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard a == "y" || a == "yes" else { print("Aborted."); return }
        }
        let resp = try client.request("DELETE", "/trace")
        print("Cleared \(resp.json["cleared"] as? Int ?? 0) trace record(s).")
    }
}

struct Exec: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a command inside a VM, after `--` (kubectl-style). Use -it for an interactive shell.",
        discussion: """
        Examples:
          vm exec my-workspace -- ls -la
          vm exec my-workspace -it -- bash
        """)

    @Flag(name: [.customShort("i"), .long], help: "Interactive: keep stdin open.")
    var interactive = false

    @Flag(name: [.customShort("t"), .long], help: "Allocate a pseudo-tty.")
    var tty = false

    @Option(name: .long, help: "Timeout in seconds (non-interactive only). Default 600.")
    var timeout: Int = 600

    @Argument(help: "VM id or workspace name.")
    var vm: String

    @Argument(parsing: .postTerminator,
              help: "Command and args after `--`. Omit (with -it) for an interactive shell.")
    var command: [String] = []

    func run() throws {
        let client = ControlClient()
        try client.ensureAgentRunning()
        let cmd = command.joined(separator: " ")

        // -i and/or -t → interactive pty session (a raw bidirectional stream).
        if interactive || tty {
            try InteractiveExec.run(client: client, vm: vm, command: cmd)
            return
        }

        guard !cmd.isEmpty else {
            throw ValidationError("No command given (use -it for an interactive shell).")
        }
        let resp = try client.request("POST", "/vms/\(ControlClient.encodeSegment(vm))/exec",
                                      body: ["command": cmd, "timeout": timeout])
        guard resp.status == 200 else {
            let msg = resp.json["error"] as? String ?? "exec failed (HTTP \(resp.status))"
            FileHandle.standardError.write(Data((msg + "\n").utf8))
            throw ExitCode(1)
        }
        if let out = resp.json["stdout"] as? String { FileHandle.standardOutput.write(Data(out.utf8)) }
        if let err = resp.json["stderr"] as? String, !err.isEmpty {
            FileHandle.standardError.write(Data(err.utf8))
        }
        let code = Int32(resp.json["exitCode"] as? Int ?? 0)
        if code != 0 { throw ExitCode(code) }
    }
}

// MARK: - Interactive pty session

/// Set by the SIGWINCH handler; drained in the poll loop to forward a resize.
private nonisolated(unsafe) var gWinchPending: Int32 = 0

/// Drives an interactive pty `exec`: opens a raw stream to the agent, puts the
/// local terminal in raw mode, and pumps the framed pty protocol (data / resize
/// / exit) until the remote command exits.
enum InteractiveExec {
    /// `overlayTrigger` is a single byte (e.g. Ctrl-] = 0x1D) that, when pressed
    /// alone, is intercepted host-side — it never reaches the guest — and calls
    /// `onOverlay` (the controller draws its workspace overlay). `onOverlay`
    /// returns bytes to forward to the guest when it closes: `[]` just repaints
    /// and resumes; a non-empty return is written to the guest pty (e.g. Ctrl-b
    /// d = `[0x02, 0x64]` to detach, ending the attach). Double-tapping the
    /// trigger in one read forwards a single literal byte. Both nil (the
    /// default) disables interception, leaving a plain transparent pump.
    static func run(client: ControlClient, vm: String, command: String,
                    overlayTrigger: UInt8? = nil, onOverlay: (() -> [UInt8])? = nil) throws {
        var ws = winsize()
        _ = ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws)
        let cols0 = ws.ws_col == 0 ? 80 : Int(ws.ws_col)
        let rows0 = ws.ws_row == 0 ? 24 : Int(ws.ws_row)

        let fd = try client.openStream(
            "POST", "/vms/\(ControlClient.encodeSegment(vm))/exec",
            body: ["command": command, "interactive": true, "cols": cols0, "rows": rows0])
        defer { Darwin.close(fd) }

        // Raw terminal mode (restored on exit) so keystrokes go straight to the
        // guest pty and the guest controls echo/line editing.
        let haveTTY = isatty(STDIN_FILENO) != 0
        var orig = termios()
        if haveTTY {
            tcgetattr(STDIN_FILENO, &orig)
            var raw = orig
            cfmakeraw(&raw)
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        }
        defer { if haveTTY { var o = orig; tcsetattr(STDIN_FILENO, TCSANOW, &o) } }

        gWinchPending = 0
        signal(SIGWINCH) { _ in gWinchPending = 1 }
        defer { signal(SIGWINCH, SIG_DFL) }

        var stdinFD: Int32 = STDIN_FILENO
        var inbuf = [UInt8](); inbuf.reserveCapacity(1 << 16)
        var rbuf = [UInt8](repeating: 0, count: 1 << 16)
        var exitCode: Int32 = 0
        let pollIn = Int16(POLLIN)
        let pollBad = Int16(POLLHUP | POLLERR | POLLNVAL)

        loop: while true {
            if gWinchPending != 0 {
                gWinchPending = 0
                var w = winsize(); _ = ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &w)
                sendFrame(fd, 1, resizePayload(cols: Int(w.ws_col), rows: Int(w.ws_row)))
            }
            var fds = [pollfd(fd: stdinFD, events: pollIn, revents: 0),
                       pollfd(fd: fd, events: pollIn, revents: 0)]
            let n = poll(&fds, 2, -1)
            if n < 0 { if errno == EINTR { continue }; break }

            if fds[0].revents & pollIn != 0 {
                let r = Darwin.read(stdinFD, &rbuf, rbuf.count)
                if r > 0 {
                    // Controller keychord: a lone trigger byte is caught here —
                    // before it's framed to the guest — and hands control to the
                    // host overlay. tmux (in the guest) never sees it, so there's
                    // no prefix collision. Double-tap in one read = one literal.
                    if let trigger = overlayTrigger, let onOverlay {
                        if r == 1, rbuf[0] == trigger {
                            let forward = onOverlay()
                            if forward.isEmpty {
                                // Repaint the guest after the host-side overlay by
                                // re-sending the window size (tmux redraws on resize).
                                var w = winsize(); _ = ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &w)
                                sendFrame(fd, 1, resizePayload(cols: Int(w.ws_col), rows: Int(w.ws_row)))
                            } else {
                                // The overlay asked to forward bytes to the guest
                                // (e.g. Ctrl-b d to detach) — tmux acts on them and
                                // the attach command exits on its own.
                                sendFrame(fd, 0, forward)
                            }
                            continue
                        }
                        if r == 2, rbuf[0] == trigger, rbuf[1] == trigger {
                            sendFrame(fd, 0, [trigger]); continue
                        }
                    }
                    sendFrame(fd, 0, Array(rbuf[0..<r]))
                }
                else { sendFrame(fd, 3, []); stdinFD = -1 }   // EOF: stop polling stdin
            }
            if fds[1].revents & pollIn != 0 {
                let r = Darwin.read(fd, &rbuf, rbuf.count)
                if r <= 0 { break }
                inbuf.append(contentsOf: rbuf[0..<r])
                while inbuf.count >= 5 {
                    let ftype = inbuf[0]
                    let flen = (Int(inbuf[1]) << 24) | (Int(inbuf[2]) << 16)
                             | (Int(inbuf[3]) << 8) | Int(inbuf[4])
                    if inbuf.count < 5 + flen { break }
                    let payload = Array(inbuf[5 ..< 5 + flen])
                    inbuf.removeFirst(5 + flen)
                    if ftype == 0, !payload.isEmpty {
                        payload.withUnsafeBytes { _ = Darwin.write(STDOUT_FILENO, $0.baseAddress, payload.count) }
                    } else if ftype == 2 {
                        if payload.count >= 4 {
                            exitCode = Int32(bitPattern:
                                (UInt32(payload[0]) << 24) | (UInt32(payload[1]) << 16)
                                | (UInt32(payload[2]) << 8) | UInt32(payload[3]))
                        }
                        break loop
                    }
                }
            }
            if (fds[1].revents & pollBad) != 0 && (fds[1].revents & pollIn) == 0 { break }
        }
        if exitCode != 0 { throw ExitCode(exitCode) }
    }

    private static func sendFrame(_ fd: Int32, _ type: UInt8, _ payload: [UInt8]) {
        var out: [UInt8] = [type]
        let len = UInt32(payload.count)
        out.append(UInt8((len >> 24) & 0xff)); out.append(UInt8((len >> 16) & 0xff))
        out.append(UInt8((len >> 8) & 0xff));  out.append(UInt8(len & 0xff))
        out.append(contentsOf: payload)
        out.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, out.count) }
    }

    private static func resizePayload(cols: Int, rows: Int) -> [UInt8] {
        let c = UInt16(clamping: cols), r = UInt16(clamping: rows)
        return [UInt8(c >> 8), UInt8(c & 0xff), UInt8(r >> 8), UInt8(r & 0xff)]
    }
}

// MARK: - Remote access (optional SSH front door)

/// `bromure-ac remote …` — manage the optional SSH remote-access front door.
/// Disabled by default. All operations go through the running app over the
/// owner-only control socket, so the app stays the single source of truth.
struct Remote: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remote",
        abstract: "Optional remote access to bromure-ac over SSH (disabled by default).",
        subcommands: [RemoteStatus.self, RemoteEnable.self, RemoteDisable.self, RemoteKey.self],
        defaultSubcommand: RemoteStatus.self)
}

private func printRemoteStatus(_ s: [String: Any]) {
    let enabled = s["enabled"] as? Bool ?? false
    let running = s["running"] as? Bool ?? false
    print("Remote access: \(enabled ? "ENABLED" : "disabled")\(enabled ? (running ? " (sshd running)" : " (sshd not running)") : "")")
    print("  Bind:     \(s["bindAddress"] as? String ?? "?"):\(s["port"] as? Int ?? 0)")
    let pw = (s["passwordAuth"] as? Bool ?? false) ? "password" : nil
    let pk = (s["pubkeyAuth"] as? Bool ?? false) ? "public-key" : nil
    print("  Auth:     \([pw, pk].compactMap { $0 }.joined(separator: " + ").ifEmpty("none"))")
    if let fp = s["fingerprint"] as? String { print("  Host key: \(fp)") }
    if let user = s["user"] as? String, let connect = s["connect"] as? String {
        print("  Login as: \(user)")
        print("  Connect:  \(connect)")
    }
    let keys = s["authorizedKeys"] as? [[String: Any]] ?? []
    print("  Keys:     \(keys.count) authorized")
    for (i, k) in keys.enumerated() {
        let c = (k["comment"] as? String ?? "")
        print("    [\(i + 1)] \(k["fingerprint"] as? String ?? "?") \(c)")
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

struct RemoteStatus: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Show remote-access status and connection details.")
    func run() throws {
        let client = ControlClient()
        guard client.isAgentRunning() else { print("No bromure-ac agent running."); return }
        let resp = try client.request("GET", "/remote")
        guard resp.status == 200 else { throw ValidationError(resp.json["error"] as? String ?? "couldn't read status") }
        printRemoteStatus(resp.json)
    }
}

struct RemoteEnable: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable", abstract: "Enable remote SSH access.")

    @Option(name: .long, help: "TCP port to listen on (default 2222).")
    var port: Int?
    @Option(name: .long, help: "IP to bind (default 0.0.0.0 = all interfaces).")
    var bind: String?
    @Flag(name: .customLong("password"), inversion: .prefixedNo,
          help: "Accept the macOS account password (PAM).")
    var password = true
    @Flag(name: .customLong("pubkey"), inversion: .prefixedNo,
          help: "Accept enrolled public keys.")
    var pubkey = true

    func run() throws {
        guard password || pubkey else {
            throw ValidationError("Enable at least one of --password / --pubkey.")
        }
        let client = ControlClient()
        try client.ensureAgentRunning()
        var spec: [String: Any] = ["enabled": true, "passwordAuth": password, "pubkeyAuth": pubkey]
        if let port { spec["port"] = port }
        if let bind { spec["bindAddress"] = bind }
        let resp = try client.request("POST", "/remote", body: spec)
        guard resp.status == 200 else { throw ValidationError(resp.json["error"] as? String ?? "couldn't enable") }
        printRemoteStatus(resp.json)
    }
}

struct RemoteDisable: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable", abstract: "Disable remote SSH access.")
    func run() throws {
        let client = ControlClient()
        guard client.isAgentRunning() else { print("No bromure-ac agent running (already off)."); return }
        let resp = try client.request("POST", "/remote", body: ["enabled": false])
        guard resp.status == 200 else { throw ValidationError(resp.json["error"] as? String ?? "couldn't disable") }
        print("Remote access disabled.")
    }
}

struct RemoteKey: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "key", abstract: "Manage authorized public keys.",
        subcommands: [RemoteKeyAdd.self, RemoteKeyList.self, RemoteKeyRemove.self],
        defaultSubcommand: RemoteKeyList.self)
}

struct RemoteKeyAdd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add", abstract: "Enroll a public key (path to a .pub file or the key text).")
    @Argument(help: "Path to a public-key file, or the key text itself.")
    var key: String
    func run() throws {
        // Accept a file path or the raw key string.
        var material = key
        if FileManager.default.fileExists(atPath: (key as NSString).expandingTildeInPath),
           let body = try? String(contentsOfFile: (key as NSString).expandingTildeInPath, encoding: .utf8) {
            material = body
        }
        let client = ControlClient()
        try client.ensureAgentRunning()
        let resp = try client.request("POST", "/remote/keys", body: ["key": material])
        guard resp.status == 200 else { throw ValidationError(resp.json["error"] as? String ?? "couldn't add key") }
        print("Added key: \(resp.json["fingerprint"] as? String ?? "ok")")
    }
}

struct RemoteKeyList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List authorized public keys.")
    func run() throws {
        let client = ControlClient()
        guard client.isAgentRunning() else { print("No bromure-ac agent running."); return }
        let resp = try client.request("GET", "/remote")
        let keys = resp.json["authorizedKeys"] as? [[String: Any]] ?? []
        if keys.isEmpty { print("No authorized keys."); return }
        for (i, k) in keys.enumerated() {
            print("[\(i + 1)] \(k["fingerprint"] as? String ?? "?") \(k["comment"] as? String ?? "")")
        }
    }
}

struct RemoteKeyRemove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm", abstract: "Remove an authorized key by index (from `key ls`) or fingerprint.")
    @Argument(help: "1-based index or fingerprint.")
    var selector: String
    func run() throws {
        let client = ControlClient()
        guard client.isAgentRunning() else { print("No bromure-ac agent running."); return }
        let resp = try client.request("DELETE", "/remote/keys/\(ControlClient.encodeSegment(selector))")
        guard resp.status == 200 else { throw ValidationError(resp.json["error"] as? String ?? "couldn't remove key") }
        print("Removed.")
    }
}
