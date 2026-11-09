import ArgumentParser
import Foundation
import SandboxEngine

// The macOS CLI's `workspaces` and `trace` commands (CLICommands.swift), on
// this daemon's control socket through RemoteMenuClient (macOS's
// ControlClient interface). `vm run`/`kill`/`exec` are the Linux CLI's own
// (already ports); the groups are assembled in the bromure-ac target from
// CLICommandsEntry.

// @port pad(_: String, _: Int) h=f69d4b180737d55d @dd6d27ed
private func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

// @port formatUptime(_: Int) h=4dc0dedd7caa5d1c @dd6d27ed
private func formatUptime(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    let m = seconds / 60
    if m < 60 { return "\(m)m" }
    let h = m / 60
    return "\(h)h\(m % 60)m"
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

    // @port VMAttach.run() h=d48a181e8c9bb31d @dd6d27ed
    func run() throws {
        let client = RemoteMenuClient()
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

        // Terminal attach to the one tmux session. The GUI surfaces and this CLI
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

/// Hidden plumbing for native terminal views (libghostty surfaces): the
/// surface spawns `bromure-ac __attach-window <vm> <idx>` as its command and
/// this process becomes the transparent byte pump between the surface's pty
/// and a guest tmux client. Unlike `vm attach`, every invocation gets its own
/// tmux *view session* grouped with `bromure` (shared windows, independent
/// current-window), so N surfaces can show N different windows at once.

// @port isSafeContainerRef(_: String) h=8c086c818da78c98 @dd6d27ed
private func isSafeContainerRef(_ s: String) -> Bool {
    !s.isEmpty && s.allSatisfy { $0.isLetter || $0.isNumber || "_.-".contains($0) }
}

/// Running containers in a VM (via `docker ps`), for `ls` / `describe`.
// @port runningContainers(_: ControlClient, vmID: String) h=fe0716be52947ae1 @dd6d27ed
private func runningContainers(_ client: RemoteMenuClient, vmID: String)
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
// @port matchesVM(_: [String:Any], _: String) h=a006896e13736a35 @dd6d27ed
private func matchesVM(_ vm: [String: Any], _ key: String) -> Bool {
    let k = key.replacingOccurrences(of: "-", with: "").lowercased()
    if let name = vm["name"] as? String, name.lowercased() == key.lowercased() { return true }
    if let sid = vm["shortId"] as? String, sid.lowercased().hasPrefix(k) { return true }
    if let id = vm["id"] as? String,
       id.replacingOccurrences(of: "-", with: "").lowercased().hasPrefix(k) { return true }
    return false
}

struct VMCheckpointsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "checkpoints",
        abstract: "List a workspace's rollback points (newest first) — system disk and ext4 home. One of each is taken on every successful boot.")

    @Argument(help: "Workspace id or name.")
    var vm: String

    // @port VMCheckpoints.run() h=a5694953dd3eb29b @dd6d27ed
    func run() throws {
        let client = RemoteMenuClient()
        guard client.isAgentRunning() else { print("No bromure-ac agent running."); return }
        let resp = try client.request("GET", "/vms/\(ControlClient.encodeSegment(vm))/checkpoints")
        guard resp.status == 200 else {
            throw ValidationError(resp.json["error"] as? String ?? "Couldn't list checkpoints.")
        }
        let list = resp.json["checkpoints"] as? [[String: Any]] ?? []
        if list.isEmpty { print("No checkpoints for \(vm) yet — one is taken on each successful boot."); return }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        print("CHECKPOINT    TARGET  CREATED               SIZE")
        for c in list {
            let id = (c["id"] as? String ?? "?").padding(toLength: 12, withPad: " ", startingAt: 0)
            let target = ((c["target"] as? String) ?? "disk").padding(toLength: 6, withPad: " ", startingAt: 0)
            let ts = c["createdAt"] as? Int ?? 0
            let date = fmt.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
            let mb = String(format: "%.0f MB", Double(c["allocatedBytes"] as? Int ?? 0) / 1_000_000)
            print("\(id)  \(target)  \(date)   \(mb)")
        }
        print("\nRevert with:  vm revert \(vm) <CHECKPOINT> [--home]   (stop the workspace first)")
    }
}

struct VMRevert: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "revert",
        abstract: "Roll a workspace back to a checkpoint — the system disk by default, the ext4 home with --home. Stop the workspace first.")

    @Argument(help: "Workspace id or name.")
    var vm: String
    @Argument(help: "Checkpoint id (from `vm checkpoints`).")
    var checkpoint: String
    @Flag(help: "Revert the ext4 home image instead of the system disk.")
    var home = false

    // @port VMRevert.run() h=b88186fe27a97133 @dd6d27ed
    func run() throws {
        let client = RemoteMenuClient()
        guard client.isAgentRunning() else { print("No bromure-ac agent running."); return }
        let resp = try client.request("POST", "/vms/\(ControlClient.encodeSegment(vm))/revert",
                                      body: ["checkpoint": checkpoint,
                                             "target": home ? "home" : "disk"])
        guard resp.status == 200 else {
            throw ValidationError(resp.json["error"] as? String ?? "Revert failed.")
        }
        print("Reverted \(vm)'s \(home ? "home" : "disk") to checkpoint \(checkpoint). Boot it with `vm run \(vm)`.")
    }
}

struct WorkspacesList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List all workspaces and their live state (off / suspended / running).")

    // @port WorkspacesList.run() h=72b6b4feb97755fc @dd6d27ed
    func run() throws {
        let client = RemoteMenuClient()
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

/// Check / repair a workspace's ext4 images from the host, with no VM and no
/// e2fsprogs (Ext4Fsck is native). The GUI offers the same repair when a boot
/// strands on filesystem errors; this is the scriptable, headless twin — and
/// the way to fix a workspace that won't boot far enough to show the overlay.
struct WorkspacesFsck: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fsck",
        abstract: "Check (and with --repair, fix) a workspace's disk images.")

    @Argument(help: "Workspace id or name.")
    var workspace: String

    @Flag(name: .long, help: "Repair: replay the journal and clear a stale error flag.")
    var repair = false

    @Flag(name: .long, help: "Check the home image instead of the system disk.")
    var home = false

    // partial: the images are this daemon's (<state>/vms/<id>/disk.raw, home.img)
    // @port WorkspacesFsck.run() h=d94c41ff455c0338 @dd6d27ed
    func run() throws {
        // This daemon's workspaces (the daemon sets the same root at start).
        let store = ProfileStore(rootDir: URL(fileURLWithPath: DaemonConfig.fromEnvironment().stateDir + "/profiles", isDirectory: true))
        let needle = workspace.lowercased()
        guard let profile = store.loadAll().first(where: {
            $0.name.lowercased() == needle || $0.id.uuidString.lowercased() == needle
                || $0.id.uuidString.lowercased().hasPrefix(needle)
        }) else {
            throw ValidationError("No workspace named or id'd '\(workspace)'.")
        }
        // Never touch an image a live VM has open — that corrupts it.
        let client = RemoteMenuClient()
        if client.isAgentRunning(),
           let resp = try? client.request("GET", "/profiles/\(ControlClient.encodeSegment(profile.id.uuidString))"),
           resp.json["running"] as? Bool == true {
            throw ValidationError("'\(profile.name)' is running — stop it first (`vm kill \(profile.name)`).")
        }
        // This daemon's layout: <state>/vms/<id>/disk.raw and home.img.
        let vmDir = DaemonConfig.fromEnvironment().stateDir + "/vms/" + profile.id.uuidString.lowercased()
        let url = URL(fileURLWithPath: vmDir + (home ? "/home.img" : "/disk.raw"))
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ValidationError("No \(home ? "home" : "system disk") image at \(url.path)")
        }
        print("\(repair ? "Repairing" : "Checking") \(home ? "home" : "system disk") of '\(profile.name)' …")
        let result = try Ext4Fsck.check(imagePath: url.path, autoFix: repair)
        print(result.output)
        print(result.summary)
        if !repair && result.status != 0 {
            print("\nRe-run with --repair to fix what can be fixed here.")
        }
        if result.status == 4 { throw ExitCode(4) }
    }
}

struct ProfilesDescribe: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "describe", abstract: "Show a workspace's settings.")

    @Argument(help: "Workspace id or name.")
    var workspace: String

    // @port ProfilesDescribe.run() h=f95618e827425341 @dd6d27ed
    func run() throws {
        let client = RemoteMenuClient()
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

    // @port ProfilesRemove.run() h=4276dfa1310ca04b @dd6d27ed
    func run() throws {
        let client = RemoteMenuClient()
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
    @Option(name: .long, help: "Primary tool: claude | codex | grok | kimi | omp.")
    var tool: String?
    @Option(name: .long, help: "Auth mode: token | subscription | bedrock | local.")
    var auth: String?
    @Option(name: .long, help: "API key (for --auth token); '-' reads it from stdin. Default: $BROMURE_AC_API_KEY. On the command line, other users of this server can see it.")
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

    // partial: --api-key also from stdin (-) or $BROMURE_AC_API_KEY, with a warning when on the command line (a shared server)
    // @port WorkspacesCreate.run() h=880a2ac8163f579a @dd6d27ed
    func run() throws {
        let client = RemoteMenuClient()
        try client.ensureAgentRunning()
        var body: [String: Any] = [:]
        if let fromJson { body = try loadJSONDocument(fromJson) }
        if let name { body["name"] = name }
        if let tool = try validatedCLIChoice(tool, Profile.Tool.self, option: "--tool") {
            body["tool"] = tool
        }
        if let auth = try validatedCLIChoice(auth, Profile.AuthMode.self, option: "--auth") {
            body["authMode"] = auth
        }
        // A key on the command line is in /proc/<pid>/cmdline, which other
        // users of a shared server can read: '-' takes it from stdin, and
        // $BROMURE_AC_API_KEY is read when the flag is absent (as `vm run`).
        let key = VMRunAPIKey.resolve(flag: apiKey, environment: ProcessInfo.processInfo.environment) {
            String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)
        }
        if key.onCommandLine { FileHandle.standardError.write(Data((VMRunAPIKey.argvWarning + "\n").utf8)) }
        if let k = key.key { body["apiKey"] = k }
        if let memory { body["memoryGB"] = memory }
        if let color { body["color"] = color }
        if !folder.isEmpty {
            body["folderPaths"] = folder.map(absoluteHostPath)
        }
        if generateSsh { body["generateSSH"] = true }
        guard (body["name"] as? String)?.isEmpty == false else {
            throw ValidationError("A workspace name is required (--name, or a \"name\" in --from-json).")
        }
        let resp = try client.request("POST", "/profiles", body: body)
        guard resp.status == 201, (resp.json["ok"] as? Bool) == true else {
            FileHandle.standardError.write(Data("Error: \(resp.json["error"] as? String ?? "Couldn't create the workspace (HTTP \(resp.status)).")\n".utf8))
            throw ExitCode(1)
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

    // @port WorkspacesSSHKeygen.run() h=4439e914f7c25f0b @dd6d27ed
    func run() throws {
        let client = RemoteMenuClient()
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
        opens it in $EDITOR (or vi), and saves your changes back; deleting a key
        clears that field. Secrets are shown blank: leave one blank to keep the
        stored value, or type a new value to change it. Pass --from-json to apply a document non-interactively; it may
        be partial (only the fields to change — the rest keep their values, and
        an explicit null clears an optional field).
        """)

    @Argument(help: "Workspace id or name.")
    var workspace: String
    @Option(name: .long, help: "Apply a (full or partial) profile JSON document non-interactively: a file path, or - for stdin.")
    var fromJson: String?

    // @port WorkspacesEdit.run() h=2389ab8df711d6f9 @dd6d27ed
    func run() throws {
        let client = RemoteMenuClient()
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
            // The editor held the WHOLE document: a key deleted there is a
            // field cleared, not one left alone (--from-json stays partial).
            body = ProfileDocument.editedDocument(fetched: cur.json, edited: edited)
        }
        let resp = try client.request("PUT", "/profiles/\(seg)", body: body)
        guard resp.status == 200, (resp.json["ok"] as? Bool) == true else {
            // The server's message names the field; the usage text a
            // ValidationError adds would bury it.
            FileHandle.standardError.write(Data("Error: \(resp.json["error"] as? String ?? "Couldn't save (HTTP \(resp.status)).")\n".utf8))
            throw ExitCode(1)
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

    // @port WorkspacesReboot.run() h=a06f1e45d705f1a6 @dd6d27ed
    func run() throws {
        let client = RemoteMenuClient()
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

    // @port WorkspacePorts.run() h=7e81e6bfefc947e6 @dd6d27ed
    func run() throws {
        guard let workspace, workspace.lowercased() != "help" else {
            // Bare `vm` (and `vm help`) land here because ports is the group's
            // default subcommand: keep the pre-existing behavior — show help.
            throw CleanExit.helpRequest(CLICommandsEntry.workspacesGroup)
        }
        let client = RemoteMenuClient()
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
        let rows = GuestOutboxReports.listeningPorts(resp.json["stdout"] as? String ?? "")
        guard !rows.isEmpty else { print("No listening ports."); return }
        print(pad("PORT", 7) + pad("PROTO", 7) + pad("ADDRESS", 22) + "PROCESS")
        for r in rows {
            let scope = r.isLoopback ? "  (loopback-only)" : ""
            print(pad("\(r.port)", 7) + pad(r.proto, 7) + pad(r.addr, 22) + r.process + scope)
        }
    }
}

/// Absolute form of a user-typed host path: `~` expanded, and a relative
/// path (`./`, `src`) resolved against the CLI's cwd. Resolution must happen
/// here — the app receives the path over the control socket and its own cwd
/// is `/`, so `-v ./` sent verbatim would come back as the root directory.
/// Reject an unknown --tool / --auth up front: the server would otherwise fall
/// back to the template's value without a word.

// @port validatedCLIChoice(_: String?, _: E.Type, option: String) h=29846ce46367174f @f127f8ab
public func validatedCLIChoice<E: RawRepresentable & CaseIterable>(
    _ raw: String?, _ type: E.Type, option: String
) throws -> String? where E.RawValue == String {
    guard let raw else { return nil }
    guard E(rawValue: raw) != nil else {
        let valid = E.allCases.map(\.rawValue).joined(separator: " | ")
        throw ValidationError("Invalid \(option) “\(raw)” — expected one of: \(valid).")
    }
    return raw
}

// @port absoluteHostPath(_: String) h=a1469f3e4a0ba7df @f127f8ab
public func absoluteHostPath(_ raw: String) -> String {
    let expanded = (raw as NSString).expandingTildeInPath
    let absolute = expanded.hasPrefix("/")
        ? expanded
        : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
    return (absolute as NSString).standardizingPath
}

/// Load a JSON object from a file path, or from stdin when `spec == "-"`.
// @port loadJSONDocument(_: String) h=f1359e6c241f46a3 @dd6d27ed
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

struct VMFusion: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fusion",
        abstract: "Enable or disable Fusion (multi-model synthesis) for a running VM.")

    @Argument(help: "enable | disable")
    var action: String

    @Argument(help: "VM id or workspace name.")
    var vm: String

    // @port VMFusion.run() h=d1e93e3b1ea216ed @dd6d27ed
    func run() throws {
        let engaged: Bool
        switch action.lowercased() {
        case "enable", "on", "engage":    engaged = true
        case "disable", "off", "disengage": engaged = false
        default: throw ValidationError("Action must be 'enable' or 'disable'.")
        }
        let client = RemoteMenuClient()
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


// @port traceRecords(_: ControlClient, profile: String?) h=d4ad9568ba6d8192 @dd6d27ed
private func traceRecords(_ client: RemoteMenuClient, profile: String?) throws -> [[String: Any]] {
    var path = "/trace"
    if let profile, !profile.isEmpty { path += "?profile=\(ControlClient.encodeSegment(profile))" }
    return (try client.request("GET", path).json["trace"] as? [[String: Any]]) ?? []
}

/// "2026-06-26T15:30:05Z" → "15:30:05".
// @port hms(_: String) h=e59a8f4819e027f7 @dd6d27ed
private func hms(_ iso: String) -> String {
    if let t = iso.split(separator: "T").last { return String(t.prefix(8)) }
    return iso
}

// @port kb(_: Int) h=06ebec6d1dd8e228 @dd6d27ed
private func kb(_ bytes: Int) -> String {
    if bytes < 1024 { return "\(bytes)B" }
    let k = Double(bytes) / 1024
    return k < 1024 ? String(format: "%.1fK", k) : String(format: "%.1fM", k / 1024)
}

// @port leakCount(_: [String:Any]) h=cddf2002179fd0c7 @dd6d27ed
private func leakCount(_ r: [String: Any]) -> Int { (r["leaks"] as? [[String: Any]])?.count ?? 0 }

struct TraceList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List recent traced requests (newest first).")
    @Argument(help: "Filter to one VM/workspace (id or name).") var workspace: String?
    @Option(name: .long, help: "Max rows (default 50).") var limit: Int = 50

    // @port TraceList.run() h=14cd745880b173bc @dd6d27ed
    func run() throws {
        let client = RemoteMenuClient()
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

    // @port TraceSummary.run() h=d2490fb193996835 @dd6d27ed
    func run() throws {
        let client = RemoteMenuClient()
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

    // @port TraceHostnames.run() h=3bd31745dd1eb56b @dd6d27ed
    func run() throws {
        let client = RemoteMenuClient()
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

    // @port TraceLeaks.run() h=5e99d0cec4a461c8 @dd6d27ed
    func run() throws {
        let client = RemoteMenuClient()
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

    // @port TraceClear.run() h=bebebc6c6a67f610 @dd6d27ed
    func run() throws {
        let client = RemoteMenuClient()
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


/// The ported commands, for the bromure-ac target's `workspaces` and
/// `trace` groups (its own `vm run`/`kill`/`exec` join them there).
// @port-skip linux-only: macOS's groups list these structs directly
public enum CLICommandsEntry {
    /// The `workspaces` group, for `ports`' bare-group help (set by the
    /// executable before parsing).
    public nonisolated(unsafe) static var workspacesGroup: ParsableCommand.Type?
    // @port-skip linux-only: see CLICommandsEntry
    public static var workspaces: (list: ParsableCommand.Type, create: ParsableCommand.Type, edit: ParsableCommand.Type,
                                   reboot: ParsableCommand.Type, attach: ParsableCommand.Type, describe: ParsableCommand.Type,
                                   remove: ParsableCommand.Type, sshKeygen: ParsableCommand.Type, ports: ParsableCommand.Type,
                                   fusion: ParsableCommand.Type, fsck: ParsableCommand.Type) {
        (WorkspacesList.self, WorkspacesCreate.self, WorkspacesEdit.self, WorkspacesReboot.self, VMAttach.self,
         ProfilesDescribe.self, ProfilesRemove.self, WorkspacesSSHKeygen.self, WorkspacePorts.self, VMFusion.self,
         WorkspacesFsck.self)
    }
    // @port-skip linux-only: see CLICommandsEntry
    public static var trace: [ParsableCommand.Type] {
        [TraceList.self, TraceSummary.self, TraceHostnames.self, TraceLeaks.self, TraceClear.self]
    }
}

/// macOS's status lines; on Linux "password" is the one-time codes, plus the
/// account password only when allowed.
// partial: says what "password" accepts here (one-time codes; the account password only with allowAccountPassword)
// @port printRemoteStatus(_: [String:Any]) h=ad292b4ae5693692 @dd6d27ed
public func printRemoteStatus(_ s: [String: Any]) {
    let enabled = s["enabled"] as? Bool ?? false
    let running = s["running"] as? Bool ?? false
    print("Remote access: \(enabled ? "ENABLED" : "disabled")\(enabled ? (running ? " (sshd running)" : " (sshd not running)") : "")")
    print("  Bind:     \(s["bindAddress"] as? String ?? "?"):\(s["port"] as? Int ?? 0)")
    let pw = (s["passwordAuth"] as? Bool ?? false) ? "password" : nil
    let pk = (s["pubkeyAuth"] as? Bool ?? false) ? "public-key" : nil
    print("  Auth:     \([pw, pk].compactMap { $0 }.joined(separator: " + ").ifEmpty("none"))")
    if pw != nil {
        print("  Password: one-time codes (`remote code`)\((s["allowAccountPassword"] as? Bool ?? false) ? " or the account password" : "")")
    }
    if let fp = s["fingerprint"] as? String { print("  Host key: \(fp)") }
    if let user = s["user"] as? String, let connect = s["connect"] as? String {
        print("  Login as: \(user)")
        print("  Connect:  \(connect)")
    }
    let keys = s["authorizedKeys"] as? [[String: Any]] ?? []
    print("  Keys:     \(keys.count) authorized")
    if let problem = s["authorizedKeysProblem"] as? String, !problem.isEmpty { print("  Warning:  \(problem)") }
    for (i, k) in keys.enumerated() {
        let c = (k["comment"] as? String ?? "")
        print("    [\(i + 1)] \(k["fingerprint"] as? String ?? "?") \(c)")
    }
}

private extension String {
    // @port String.ifEmpty(_: String) h=28933b6db49c38e8 @dd6d27ed
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

// @port-skip linux-only: macOS's RemoteKey group, joined to this CLI's `remote` (RemoteKeyEntry)
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
    // @port RemoteKeyAdd.run() h=ac80f760d1c4369f @dd6d27ed
    func run() throws {
        // Accept a file path or the raw key string.
        var material = key
        if FileManager.default.fileExists(atPath: (key as NSString).expandingTildeInPath),
           let body = try? String(contentsOfFile: (key as NSString).expandingTildeInPath, encoding: .utf8) {
            material = body
        }
        let client = RemoteMenuClient()
        try client.ensureAgentRunning()
        let resp = try client.request("POST", "/remote/keys", body: ["key": material])
        guard resp.status == 200 else { throw ValidationError(resp.json["error"] as? String ?? "couldn't add key") }
        print("Added key: \(resp.json["fingerprint"] as? String ?? "ok")")
    }
}

struct RemoteKeyList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List authorized public keys.")
    // @port RemoteKeyList.run() h=3e7c629b01a94db9 @dd6d27ed
    func run() throws {
        let client = RemoteMenuClient()
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
    // @port RemoteKeyRemove.run() h=80dc5a6a7c117256 @dd6d27ed
    func run() throws {
        let client = RemoteMenuClient()
        guard client.isAgentRunning() else { print("No bromure-ac agent running."); return }
        let resp = try client.request("DELETE", "/remote/keys/\(ControlClient.encodeSegment(selector))")
        guard resp.status == 200 else { throw ValidationError(resp.json["error"] as? String ?? "couldn't remove key") }
        print("Removed.")
    }
}


/// `remote key add|ls|rm` (macOS's group) for the bromure-ac target's `remote`.
// @port-skip linux-only: see RemoteKey
public enum RemoteKeyEntry {
    // @port-skip linux-only: see RemoteKey
    public static var command: ParsableCommand.Type { RemoteKey.self }
}
