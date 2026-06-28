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

// MARK: - `vm` subcommand group

struct VM: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vm",
        abstract: "Manage bromure-ac VMs (like `docker` for containers).",
        subcommands: [VMList.self, VMRun.self, VMKill.self, Exec.self,
                      VMFusion.self, VMRouting.self, VMHybrid.self,
                      VMAttach.self, VMDescribe.self])
}

struct VMRun: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Create and boot a VM, optionally from an on-the-fly profile (like `docker run`).")

    @Option(name: [.customShort("v"), .long],
            help: "Mount a host folder into the VM at ~/<basename>. Repeatable (max 8). e.g. -v ~/project")
    var volume: [String] = []

    @Option(name: .long, help: "Use an existing profile (name or id) instead of creating one.")
    var profile: String?

    @Option(name: .long, help: "Name for an on-the-fly profile (default: cli-XXXX).")
    var name: String?

    @Option(name: .long, help: "Tool for an on-the-fly profile: claude | codex | grok.")
    var tool: String?

    @Option(name: .long, help: "Auth mode for an on-the-fly profile: token | subscription | bedrock.")
    var auth: String?

    @Option(name: .long, help: "API key (for --auth token).")
    var apiKey: String?

    @Option(name: .long, help: "VM RAM in GB.")
    var memory: Int?

    @Flag(name: [.customShort("d"), .long],
          help: "Detached: boot and return without attaching your terminal (docker-style).")
    var detach = false

    @Flag(name: .long, help: "Delete the profile + disk when the VM stops (ephemeral).")
    var rm = false

    func run() throws {
        let client = ControlClient()
        try client.ensureAgentRunning()
        // CLI-created sessions always boot window-less — the terminal is the UI.
        // The GUI is opt-in afterwards via `vm attach --window`.
        var spec: [String: Any] = ["detach": true, "rm": rm]
        if let profile { spec["profile"] = profile }
        if let name { spec["name"] = name }
        if let tool { spec["tool"] = tool }
        if let auth { spec["auth"] = auth }
        if let apiKey { spec["apiKey"] = apiKey }
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

struct VMList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List running VMs (attached or detached).")

    func run() throws {
        let client = ControlClient()
        guard client.isAgentRunning() else {
            print("No bromure-ac agent running.")
            return
        }
        let vms = (try client.request("GET", "/vms").json["vms"] as? [[String: Any]]) ?? []
        if vms.isEmpty { print("No running VMs."); return }
        print(pad("VM ID", 14) + pad("NAME", 22) + pad("TOOL", 9)
              + pad("STATE", 11) + pad("UP", 8) + "WINDOW")
        for vm in vms.sorted(by: { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }) {
            let id = vm["shortId"] as? String ?? String((vm["id"] as? String ?? "").prefix(12))
            let name = vm["name"] as? String ?? ""
            let tool = vm["tool"] as? String ?? ""
            let state = vm["state"] as? String ?? ""
            let up = formatUptime(vm["uptimeSeconds"] as? Int ?? 0)
            let win = (vm["attached"] as? Bool ?? false) ? "attached" : "detached"
            print(pad(id, 14) + pad(name, 22) + pad(tool, 9) + pad(state, 11) + pad(up, 8) + win)
            // Tabs (tmux windows) as a tree; jump with `vm attach <id> <index>`.
            // `*` marks the active window. The index is the tmux window index.
            let tabs = vm["tabs"] as? [[String: Any]] ?? []
            for t in tabs {
                let idx = t["index"] as? Int ?? 0
                let title = t["title"] as? String ?? "shell"
                let active = (t["active"] as? Bool ?? false) ? " *" : ""
                print("    └─ \(title) (\(idx))\(active)")
            }
        }
    }
}

struct VMKill: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kill", abstract: "Stop a VM (shut down, or suspend with --suspend).")

    @Argument(help: "VM id or profile name.")
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
        abstract: "Attach your terminal to a VM's tmux session (tmux-style). Same tabs as the GUI.")

    @Argument(help: "VM id or profile name.")
    var vm: String

    @Argument(help: "Tab index from `vm ls` to jump to. Omit to attach to the current tab.")
    var tab: Int?

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

        // Terminal attach to the one tmux session. The GUI kitty and this CLI
        // client share it (lockstep), so a tab switch on either side moves both.
        // With a tab index, jump to that tmux window first.
        let vms = (try client.request("GET", "/vms").json["vms"] as? [[String: Any]]) ?? []
        guard let vmObj = vms.first(where: { matchesVM($0, vm) }) else {
            throw ValidationError("VM not found: \(vm)")
        }
        let target = (vmObj["id"] as? String) ?? vm
        var cmd = "tmux attach -t bromure"
        if let tab {
            cmd += " \\; select-window -t bromure:\(tab)"
        }
        try InteractiveExec.run(client: client, vm: target, command: cmd)
    }
}

struct VMDescribe: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "describe",
        abstract: "Show detailed information about a running VM.")

    @Argument(help: "VM id or profile name.")
    var vm: String

    func run() throws {
        let client = ControlClient()
        guard client.isAgentRunning() else { print("No bromure-ac agent running."); return }
        let vms = (try client.request("GET", "/vms").json["vms"] as? [[String: Any]]) ?? []
        guard let v = vms.first(where: { matchesVM($0, vm) }) else {
            throw ValidationError("VM not found: \(vm)")
        }
        func row(_ k: String, _ val: String?) {
            guard let val, !val.isEmpty else { return }
            print("  " + pad(k, 16) + val)
        }
        print("\(v["name"] as? String ?? "?")  (\(v["shortId"] as? String ?? ""))")
        row("id", v["id"] as? String)
        row("tool", v["tool"] as? String)
        row("state", v["state"] as? String)
        row("window", (v["attached"] as? Bool ?? false) ? "attached" : "detached")
        row("uptime", formatUptime(v["uptimeSeconds"] as? Int ?? 0))
        row("ip", (v["ip"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        row("vCPUs", (v["cpuCount"] as? Int).map(String.init))
        row("memory", (v["memoryGB"] as? Int).map { "\($0) GB allocated" })
        row("network", v["networkMode"] as? String)
        row("mac", v["macAddress"] as? String)
        let fusionConfigurable = v["fusionConfigurable"] as? Bool ?? false
        let fusionEngaged = v["fusionEngaged"] as? Bool ?? false
        row("fusion", fusionConfigurable
            ? (fusionEngaged ? "engaged" : "available (off)")
            : "not configurable (needs ≥2 models)")
        row("base image", v["baseImageVersion"] as? String)
        if let bytes = v["diskAllocatedBytes"] as? Int {
            let sz = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            row("disk", "\(sz) used   \(v["diskPath"] as? String ?? "")")
        }
        if let mounts = v["mounts"] as? [String], !mounts.isEmpty {
            print("  mounts:")
            for m in mounts { print("    - \(m)") }
        }
        if let tabs = v["tabs"] as? [[String: Any]], !tabs.isEmpty {
            print("  tabs:")
            for t in tabs {
                print("    \(t["index"] as? Int ?? 0). \(t["title"] as? String ?? "shell")")
            }
        }
        // Best-effort in-guest memory usage (skips quietly if the shell agent
        // isn't reachable yet).
        let target = v["id"] as? String ?? vm
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

struct Profiles: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profiles",
        abstract: "Manage profiles (the templates VMs boot from).",
        subcommands: [ProfilesList.self, ProfilesDescribe.self, ProfilesRemove.self])
}

struct ProfilesList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List profiles.")

    func run() throws {
        let client = ControlClient()
        guard client.isAgentRunning() else { print("No bromure-ac agent running."); return }
        let profs = (try client.request("GET", "/profiles").json["profiles"] as? [[String: Any]]) ?? []
        if profs.isEmpty { print("No profiles."); return }
        let running = Set(((try? client.request("GET", "/vms").json["vms"] as? [[String: Any]]) ?? [])
            .compactMap { $0["id"] as? String })
        print(pad("PROFILE ID", 14) + pad("NAME", 24) + pad("TOOL", 9)
              + pad("AUTH", 14) + pad("MCP", 5) + "STATE")
        for p in profs.sorted(by: { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }) {
            let id = p["id"] as? String ?? ""
            let short = String(id.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
            let name = p["name"] as? String ?? ""
            let tool = p["tool"] as? String ?? ""
            let auth = p["authMode"] as? String ?? ""
            let mcp = String(p["mcpServerCount"] as? Int ?? 0)
            let state = running.contains(id) ? "running" : "-"
            print(pad(short, 14) + pad(name, 24) + pad(tool, 9) + pad(auth, 14) + pad(mcp, 5) + state)
        }
    }
}

struct ProfilesDescribe: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "describe", abstract: "Show a profile's settings.")

    @Argument(help: "Profile id or name.")
    var profile: String

    func run() throws {
        let client = ControlClient()
        guard client.isAgentRunning() else { print("No bromure-ac agent running."); return }
        let resp = try client.request("GET", "/profiles/\(ControlClient.encodeSegment(profile))")
        guard resp.status == 200 else {
            throw ValidationError(resp.json["error"] as? String ?? "Profile not found: \(profile)")
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
        if v["startInBackground"] as? Bool == true { row("start in bg", "yes") }
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
    }
}

struct ProfilesRemove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm", abstract: "Delete a profile and all its data (disk + home).")

    @Argument(help: "Profile id or name.")
    var profile: String

    @Flag(name: [.customShort("f"), .long], help: "Skip the confirmation prompt.")
    var force = false

    func run() throws {
        let client = ControlClient()
        guard client.isAgentRunning() else { print("No bromure-ac agent running."); return }
        if !force {
            FileHandle.standardError.write(Data(
                "Delete profile '\(profile)' and ALL its data (disk + home)? [y/N] ".utf8))
            let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            guard answer == "y" || answer == "yes" else { print("Aborted."); return }
        }
        let resp = try client.request("DELETE", "/profiles/\(ControlClient.encodeSegment(profile))")
        guard resp.status == 200, (resp.json["ok"] as? Bool) == true else {
            throw ValidationError(resp.json["error"] as? String ?? "Couldn't delete \(profile).")
        }
        print("Deleted profile \(resp.json["name"] as? String ?? profile).")
    }
}

// MARK: - `vm fusion`

struct VMFusion: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fusion",
        abstract: "Enable or disable Fusion (multi-model synthesis) for a running VM.")

    @Argument(help: "enable | disable")
    var action: String

    @Argument(help: "VM id or profile name.")
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
    @Argument(help: "Filter to one VM/profile (id or name).") var profile: String?
    @Option(name: .long, help: "Max rows (default 50).") var limit: Int = 50

    func run() throws {
        let client = ControlClient()
        guard client.isAgentRunning() else { print("No bromure-ac agent running."); return }
        let recs = try traceRecords(client, profile: profile)
        guard !recs.isEmpty else {
            print("No trace records. (Tracing is per-profile — enable it in the profile's settings.)")
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
    @Argument(help: "Filter to one VM/profile (id or name).") var profile: String?

    func run() throws {
        let client = ControlClient()
        guard client.isAgentRunning() else { print("No bromure-ac agent running."); return }
        let recs = try traceRecords(client, profile: profile)
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
    @Argument(help: "Filter to one VM/profile (id or name).") var profile: String?

    func run() throws {
        let client = ControlClient()
        guard client.isAgentRunning() else { print("No bromure-ac agent running."); return }
        let recs = try traceRecords(client, profile: profile)
        var byHost: [String: Int] = [:]
        for r in recs { byHost[r["host"] as? String ?? "?", default: 0] += 1 }
        guard !byHost.isEmpty else { print("No trace records."); return }
        for (h, c) in byHost.sorted(by: { $0.key < $1.key }) { print(pad(String(c), 7) + h) }
    }
}

struct TraceLeaks: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "leaks", abstract: "Show requests with potential credential leaks.")
    @Argument(help: "Filter to one VM/profile (id or name).") var profile: String?

    func run() throws {
        let client = ControlClient()
        guard client.isAgentRunning() else { print("No bromure-ac agent running."); return }
        let leaky = try traceRecords(client, profile: profile).filter { leakCount($0) > 0 }
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
        abstract: "Run a command inside a VM (like `docker exec`). Use -it for an interactive shell.")

    @Flag(name: [.customShort("i"), .long], help: "Interactive: keep stdin open.")
    var interactive = false

    @Flag(name: [.customShort("t"), .long], help: "Allocate a pseudo-tty.")
    var tty = false

    @Option(name: .long, help: "Timeout in seconds (non-interactive only). Default 600.")
    var timeout: Int = 600

    @Argument(help: "VM id or profile name.")
    var vm: String

    @Argument(parsing: .captureForPassthrough,
              help: "Command and args. Omit (with -it) for an interactive shell.")
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
    static func run(client: ControlClient, vm: String, command: String) throws {
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
                if r > 0 { sendFrame(fd, 0, Array(rbuf[0..<r])) }
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
