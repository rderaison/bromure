import Foundation
import Testing
import ACLinux

/// The bromure-ac daemon and CLI, end to end: a real daemon process with
/// passt and a KVM guest, driven by the CLI binary over control.sock.
enum DaemonEnv {
    static let bin = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".build/\(buildDir)/bromure-ac").path
    /// The CLI of the configuration these tests were built in (ci.sh: release).
    #if DEBUG
    static let buildDir = "debug"
    #else
    static let buildDir = "release"
    #endif
    static var ready: Bool { NetEnv.passtReady && FileManager.default.isExecutableFile(atPath: bin) }
}

@Suite("bromure-ac daemon + CLI", .serialized, .enabled(if: DaemonEnv.ready))
struct DaemonTests {
    /// A private XDG world for one daemon.
    struct World {
        let root: String
        /// Set for one test's daemon and CLI (e.g. BROMURE_AC_HOME_GB).
        var extraEnv: [String: String] = [:]
        var env: [String: String] {
            var e = ProcessInfo.processInfo.environment
            e["XDG_RUNTIME_DIR"] = root + "/run"
            e["XDG_STATE_HOME"] = root + "/state"
            // Its own data home: never the user's subscription logins,
            // model settings, engine key or secrets vault.
            e["XDG_DATA_HOME"] = root + "/data"
            // Its own defaults (the workspace subnet's choice): never this
            // user's ~/.config/bromure-ac.plist.
            e["XDG_CONFIG_HOME"] = root + "/config"
            e["BROMURE_AC_IMAGE"] = Env.image
            e["BROMURE_AGENTD"] = Env.agentd
            // Sentry modules from a dead local port, never the published CDN.
            e["BROMURE_SENTRY_CATALOG_BASE"] = "http://127.0.0.1:9/"
            e.removeValue(forKey: "NOTIFY_SOCKET")
            e.merge(extraEnv) { _, new in new }
            return e
        }
        var socket: String { root + "/run/bromure-ac/control.sock" }

        /// The world gone: first every process of ours still running in it
        /// (a daemon that crashed or wasn't stopped leaves its VMs -- they
        /// outlive it by design -- holding their deleted disks open), then
        /// its directory.
        func destroy() {
            let mine = getuid(), mark = root + "/"
            for _ in 0..<2 {
                for entry in (try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? [] {
                    guard let pid = Int32(entry), pid != getpid() else { continue }
                    var st = stat()
                    guard stat("/proc/\(entry)", &st) == 0, st.st_uid == mine else { continue }
                    // Plain reads: a /proc file can change or go while read.
                    let fd = open("/proc/\(entry)/cmdline", O_RDONLY | O_CLOEXEC)
                    guard fd >= 0 else { continue }
                    var buf = [UInt8](repeating: 0, count: 8192)
                    let n = read(fd, &buf, buf.count)
                    close(fd)
                    guard n > 0, String(decoding: buf[0..<n].map { $0 == 0 ? 0x20 : $0 }, as: UTF8.self).contains(mark) else { continue }
                    kill(pid, SIGKILL)
                }
                usleep(200_000)
            }
            try? FileManager.default.removeItem(atPath: root)
        }

        init() throws {
            // BROMURE_TEST_WORLD_DIR: somewhere other than /tmp (a VM's disks
            // are GBs; /tmp may be a small tmpfs with a user quota).
            let base = ProcessInfo.processInfo.environment["BROMURE_TEST_WORLD_DIR"] ?? "/tmp"
            root = base + "/acl-dm-\(UUID().uuidString.prefix(6))"
            try FileManager.default.createDirectory(atPath: root + "/run", withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }

        func startDaemon() async throws -> Process {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: DaemonEnv.bin)
            p.arguments = ["daemon"]
            p.environment = env
            FileManager.default.createFile(atPath: root + "/daemon.log", contents: nil)
            let log = FileHandle(forWritingAtPath: root + "/daemon.log")
            p.standardOutput = log
            p.standardError = log
            try p.run()
            let c = ControlClient(socketPath: socket)
            for _ in 0..<200 where !c.isAgentRunning() { try await Task.sleep(for: .milliseconds(25)) }
            #expect(c.isAgentRunning(), "daemon didn't come up: \((try? String(contentsOfFile: root + "/daemon.log", encoding: .utf8)) ?? "")")
            return p
        }

        /// Runs the CLI; returns (exit status, stdout, stderr).
        @discardableResult
        func cli(_ args: String...) throws -> (Int32, String, String) { try cli(args, input: nil) }

        func cli(_ args: [String], input: String?) throws -> (Int32, String, String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: DaemonEnv.bin)
            p.arguments = args
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            let inp = Pipe()
            if input != nil { p.standardInput = inp }
            try p.run()
            if let input {
                inp.fileHandleForWriting.write(Data(input.utf8))
                try inp.fileHandleForWriting.close()
            }
            let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
        }

        func vm(_ name: String) throws -> JSONValue? {
            let (_, out, _) = try cli("vm", "ls", "--json")
            guard let j = try? JSONDecoder().decode(JSONValue.self, from: Data(out.utf8)),
                  case .array(let vms) = j["vms"] ?? .null else { return nil }
            return vms.first { $0["name"]?.stringValue == name }
        }

        func state(of name: String) throws -> String? { try vm(name)?["state"]?.stringValue }
    }

    /// The direct children of `pid`: pid and command name.
    static func children(of pid: Int32) -> [(Int32, String)] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/proc")) ?? []).compactMap { d in
            guard let p = Int32(d), let st = try? String(contentsOfFile: "/proc/\(d)/stat", encoding: .utf8),
                  let open = st.firstIndex(of: "("), let close = st.lastIndex(of: ")") else { return nil }
            let rest = st[st.index(after: close)...].split(separator: " ")
            guard rest.count > 1, Int32(rest[1]) == pid, rest[0] != "Z" else { return nil }
            return (p, String(st[st.index(after: open)..<close]))
        }
    }

    static func alive(_ pid: Int32) -> Bool {
        guard let st = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
              let close = st.lastIndex(of: ")") else { return false }
        return st[st.index(after: close)...].split(separator: " ").first != "Z"
    }

    @Test("run, ls, exec, exec -i, suspend/resume, kill; a SIGKILLed daemon's Firecracker is ended by the next one (no fd store outside systemd); SIGTERM ends everything")
    func lifecycle() async throws {
        let w = try World()
        defer { w.destroy() }
        var daemon = try await w.startDaemon()

        let (rc, id, err) = try w.cli("vm", "run", "--name", "dm1")
        #expect(rc == 0, "run: \(err)")
        #expect(id.trimmingCharacters(in: .whitespacesAndNewlines).count == 36)
        #expect(try w.state(of: "dm1") == "running")
        let t0 = ContinuousClock.now
        let (rc2, uname, err2) = try w.cli("vm", "exec", "dm1", "--", "uname", "-a")
        print("TIMING [daemon] first exec (boot included) \(ms(ContinuousClock.now - t0)): \(uname.prefix(60))")
        #expect(rc2 == 0 && uname.hasPrefix("Linux "), "exec: \(uname) \(err2)")   // the hostname (dm1) is checked in homeImage()
        #expect(try w.cli("vm", "exec", "dm1", "--", "sh", "-c", "exit 7").0 == 7, "exit status propagates")
        // A fresh install's workspaces are on its private 172.16/12 /24 (as
        // macOS AC's): the guest's lease and its default route say so.
        let net = try w.cli("vm", "exec", "dm1", "--", "sh", "-c", "ip -4 -o addr show scope global; ip route show default").1
        let addr = net.range(of: #"inet (172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+)\.[0-9]+/24"#, options: .regularExpression).map { String(net[$0]) }
        #expect(addr != nil, "a 172.16/12 lease: \(net)")
        if let a = addr, let prefix = a.split(separator: " ").last?.split(separator: ".").prefix(3).joined(separator: ".") {
            #expect(net.contains("default via \(prefix).1"), "routed through the subnet's .1: \(net)")
        }
        // exec -i without a terminal: stdin is framed to the guest pty, EOF
        // reaches it as an EOF frame, the exit status comes back.
        let t3 = ContinuousClock.now
        let (irc, iout, ierr) = try w.cli(["vm", "exec", "-i", "dm1", "--", "bash", "--norc", "--noprofile"],
                                          input: "tty; stty size; echo in-$((6*7))\nexit 5\n")
        print("TIMING [daemon] exec -i \(ms(ContinuousClock.now - t3)): \(iout.split(separator: "\n").prefix(4))")
        #expect(irc == 5, "exec -i exit status: \(irc) \(ierr)")
        #expect(iout.contains("/dev/pts/") && iout.contains("24 80") && iout.contains("in-42"), "exec -i: \(iout)")
        let (lsrc, ls, _) = try w.cli("vm", "ls")
        #expect(lsrc == 0 && ls.contains("dm1") && ls.contains("running"))
        // Suspend and resume (a snapshot, the shares' virtiofsd state in it):
        // a process started before runs on after, and the shares still work.
        #expect(try w.cli("vm", "exec", "dm1", "--", "sh", "-c",
                          "nohup sh -c 'while true; do date +%s > /tmp/tick; sleep 1; done' >/dev/null 2>&1 & "
                          + "echo before > /mnt/bromure-outbox/snap.txt").0 == 0)
        let t4 = ContinuousClock.now
        let (src, _, serr) = try w.cli("vm", "suspend", "dm1")
        print("TIMING [daemon] suspend \(ms(ContinuousClock.now - t4))")
        #expect(src == 0, "suspend: \(serr)")
        #expect(try w.state(of: "dm1") == "suspended")
        let t5 = ContinuousClock.now
        let (rrc, _, rerr) = try w.cli("vm", "resume", "dm1")
        print("TIMING [daemon] resume \(ms(ContinuousClock.now - t5))")
        #expect(rrc == 0, "resume: \(rerr)")
        #expect(try w.state(of: "dm1") == "running")
        var after = ""
        for _ in 0..<20 {
            let r = try w.cli("vm", "exec", "dm1", "--", "sh", "-c",
                              "a=$(cat /tmp/tick); sleep 2; b=$(cat /tmp/tick); [ \"$b\" -gt \"$a\" ] && cat /mnt/bromure-outbox/snap.txt")
            after = r.1
            if r.0 == 0 { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        #expect(after.contains("before"), "after resume: the ticker runs and the outbox reads (\(after))")
        #expect(try w.cli("vm", "kill", "--force", "dm1").0 == 0)
        #expect(try w.state(of: "dm1") == "stopped")
        // QEMU machine types are gone.
        #expect(try w.cli("vm", "run", "--name", "q", "--machine", "microvm").0 != 0)

        // Unknown routes: 404 with a JSON error; foreign uid is covered by
        // SO_PEERCRED (not testable as the same user).
        let r = try ControlClient(socketPath: w.socket).request("GET", "/no/such/route")
        #expect(r.status == 404 && r.json["error"]?.stringValue == "Not found")

        // A running VM, then SIGKILL the daemon: passt goes with it (its
        // socket hits EOF), Firecracker doesn't. Outside systemd there is no
        // fd store to keep the VM's network end, so the next daemon can't
        // re-adopt it: it ends that Firecracker (still ours: start time and
        // --id) and records the VM stopped. Under systemd it is re-adopted
        // (systemd/test-unit-kvm.sh, test-crash-upload.sh).
        #expect(try w.cli("vm", "run", "--name", "dm2").0 == 0)
        #expect(try w.cli("vm", "exec", "dm2", "--", "true").0 == 0)
        let kids = Self.children(of: daemon.processIdentifier)
        let names = Set(kids.map { $0.1 })
        #expect(names.contains("firecracker") && names.contains { $0.hasPrefix("passt") },
                "expected Firecracker and passt under the daemon, saw \(names)")
        defer { for k in kids where k.1 == "firecracker" && Self.alive(k.0) { kill(k.0, SIGKILL) } }
        kill(daemon.processIdentifier, SIGKILL)
        daemon.waitUntilExit()
        try await Task.sleep(for: .seconds(1))
        let fcLeft = kids.filter { $0.1 == "firecracker" && Self.alive($0.0) }
        #expect(fcLeft.count == 1, "the VM outlives the daemon")
        #expect(kids.filter { $0.1.hasPrefix("passt") && Self.alive($0.0) }.isEmpty, "passt ends with the daemon's socket")
        daemon = try await w.startDaemon()
        #expect(try w.state(of: "dm2") == "stopped", "not re-adoptable without the fd store")
        try await Task.sleep(for: .milliseconds(500))
        #expect(fcLeft.filter { Self.alive($0.0) }.isEmpty, "its Firecracker was ended, not left holding the disks")
        #expect(try w.cli("vm", "start", "dm2").0 == 0, "and it starts again")
        #expect(try w.cli("vm", "exec", "dm2", "--", "true").0 == 0)

        // SIGTERM (the systemctl stop path, with signals unblocked even though
        // Foundation's Process spawned the daemon with them blocked) kills the
        // running VMs, closes passt and unlinks control.sock.
        let termKids = Self.children(of: daemon.processIdentifier)
        kill(daemon.processIdentifier, SIGTERM)
        let tTerm = ContinuousClock.now
        daemon.waitUntilExit()
        print("TIMING [daemon] SIGTERM -> exit \(ms(ContinuousClock.now - tTerm)), status \(daemon.terminationStatus)")
        #expect(daemon.terminationReason == .exit && daemon.terminationStatus == 0, "graceful exit")
        #expect(!FileManager.default.fileExists(atPath: w.socket), "control.sock unlinked")
        try await Task.sleep(for: .milliseconds(500))
        #expect(termKids.filter { Self.alive($0.0) }.isEmpty, "children left after SIGTERM: \(termKids)")

        daemon = try await w.startDaemon()
        #expect(try w.state(of: "dm2") == "stopped")
        // A name that's another VM's id or short id is refused.
        let short = try #require(try w.vm("dm2")?["shortId"]?.stringValue)
        #expect(try w.cli("vm", "run", "--name", short).0 != 0)
        kill(daemon.processIdentifier, SIGTERM)
        daemon.waitUntilExit()
    }

    @Test("the home image: ext4 on vdb at /home/ubuntu; kept across kill/start; grows; gone with rm")
    func homeImage() async throws {
        // The daemon's setting pins a new home's size: without it, a new
        // home is scaled to the free space where the VMs live (8/12/16 GB,
        // HomeSizingTests), which depends on this host.
        var w = try World()
        w.extraEnv["BROMURE_AC_HOME_GB"] = "16"
        defer { w.destroy() }
        let daemon = try await w.startDaemon()
        defer { kill(daemon.processIdentifier, SIGTERM); daemon.waitUntilExit() }

        #expect(try w.cli("vm", "run", "--name", "h1").0 == 0)
        let id = try #require(try w.vm("h1")?["id"]?.stringValue)
        let dir = w.root + "/state/bromure-ac/vms/" + id
        var st = stat()
        #expect(stat(dir + "/home.img", &st) == 0 && st.st_size == 16 << 30 && st.st_blocks < 1024,
                "a sparse 16 GiB home.img")
        // agentd formats and mounts it as it boots (task_home_setup), after the
        // shell may already answer: wait for the mount.
        func homeMount() throws -> String {
            try w.cli("vm", "exec", "h1", "--", "findmnt", "-no", "FSTYPE,SOURCE,LABEL", "/home/ubuntu").1
        }
        var mount = ""
        for _ in 0..<60 {
            mount = try homeMount()
            if mount.contains("ext4") { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        print("HOME [daemon] /home/ubuntu: \(mount.split(separator: "\n").last ?? "")")
        #expect(mount.contains("ext4") && mount.contains("/dev/vdb") && mount.contains("bromure-home"), "home: \(mount)")
        #expect(try w.cli("vm", "exec", "h1", "--", "sh", "-c", "echo kept > /home/ubuntu/marker && sync").0 == 0)
        // The seed landed in the ext4 home, and the outbox is world-writable as on macOS.
        #expect(try w.cli("vm", "exec", "h1", "--", "head", "-1", "/home/ubuntu/.bashrc").1
                    .contains("Managed by Bromure Agentic Coding"), "the seeded .bashrc")
        #expect(try w.cli("vm", "exec", "h1", "--", "stat", "-c", "%a", "/mnt/bromure-outbox").1
                    .trimmingCharacters(in: .whitespacesAndNewlines) == "777")

        // Stop and start: same overlay, same home.
        #expect(try w.cli("vm", "kill", "h1").0 == 0)
        #expect(try w.state(of: "h1") == "stopped")
        #expect(try w.cli("vm", "start", "h1").0 == 0)
        var marker = ""
        for _ in 0..<60 {
            marker = try w.cli("vm", "exec", "h1", "--", "cat", "/home/ubuntu/marker").1
            if marker.contains("kept") { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        #expect(marker.contains("kept"), "the home survived kill/start: \(marker)")
        // The guest hostname is the VM's name (meta/hostname.txt, applied by agentd).
        var host = ""
        for _ in 0..<20 {
            host = try w.cli("vm", "exec", "h1", "--", "hostname").1.trimmingCharacters(in: .whitespacesAndNewlines)
            if host == "h1" { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        #expect(host == "h1", "hostname: \(host)")

        // A bigger home at a cold boot: home.img grows (sparse) and agentd's
        // resize2fs grows the mounted ext4. A smaller one is refused.
        #expect(try w.cli("vm", "kill", "h1").0 == 0)
        #expect(try w.cli("vm", "start", "h1", "--home-gb", "8").0 != 0, "home images don't shrink")
        #expect(try w.cli("vm", "start", "h1", "--home-gb", "20").0 == 0)
        #expect(stat(dir + "/home.img", &st) == 0 && st.st_size == 20 << 30, "home.img grown to 20 GiB")
        var fsMiB = 0
        for _ in 0..<60 {
            fsMiB = Int(try w.cli("vm", "exec", "h1", "--", "sh", "-c",
                                  "findmnt -no FSTYPE /home/ubuntu | grep -q ext4 && df -B1M --output=size /home/ubuntu | tail -1")
                            .1.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            if fsMiB > 19_000 { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        print("HOME [daemon] after --home-gb 20: the ext4 is \(fsMiB) MiB")
        #expect(fsMiB > 19_000, "resize2fs grew the home: \(fsMiB) MiB")
        #expect(try w.cli("vm", "exec", "h1", "--", "cat", "/home/ubuntu/marker").1.contains("kept"), "the marker survived the grow")
        #expect(try w.vm("h1")?["homeGB"]?.numberValue == 20)

        #expect(try w.cli("vm", "kill", "h1").0 == 0)
        // rm: only when not running; then the VM and its files are gone.
        #expect(try w.cli("vm", "rm", "h1").0 == 0)
        #expect(try w.vm("h1") == nil)
        #expect(!FileManager.default.fileExists(atPath: dir), "the VM's directory is deleted")
        #expect(try w.cli("vm", "run", "--name", "h2").0 == 0)
        #expect(try w.cli("vm", "rm", "h2").0 != 0, "a running VM is not removed")
        #expect(try w.cli("vm", "kill", "--force", "h2").0 == 0)
        #expect(try w.cli("vm", "rm", "h2").0 == 0)
    }

    @Test("each VM has its own machine-id, not the base image's, and keeps it across kill/start")
    func machineID() async throws {
        let w = try World()
        defer { w.destroy() }
        let daemon = try await w.startDaemon()
        defer { kill(daemon.processIdentifier, SIGTERM); daemon.waitUntilExit() }

        func machineID(_ vm: String) throws -> String {
            try w.cli("vm", "exec", vm, "--", "cat", "/etc/machine-id").1.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let debugfs = Process(), pipe = Pipe()
        debugfs.executableURL = URL(fileURLWithPath: "/usr/sbin/debugfs")
        debugfs.arguments = ["-R", "cat /etc/machine-id",
                             Env.image + "/base.img?offset=\(try GuestDisk.rootPartitionOffset(Env.image + "/base.img"))"]
        debugfs.standardOutput = pipe
        debugfs.standardError = FileHandle.nullDevice
        try debugfs.run()
        let baseID = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        debugfs.waitUntilExit()
        #expect(baseID.count == 32, "the base image's machine-id: \(baseID)")
        #expect(try w.cli("vm", "run", "--name", "m1").0 == 0)
        #expect(try w.cli("vm", "run", "--name", "m2").0 == 0)
        let a = try machineID("m1"), b = try machineID("m2")
        #expect(a.count == 32 && a.allSatisfy(\.isHexDigit), "m1's machine-id: \(a)")
        #expect(a != b, "two VMs, two machine-ids")
        #expect(a != baseID && b != baseID, "not the base image's (\(baseID))")
        #expect(try w.cli("vm", "exec", "m1", "--", "cat", "/var/lib/dbus/machine-id").1
                    .trimmingCharacters(in: .whitespacesAndNewlines) == a, "D-Bus's copy agrees")
        #expect(try w.cli("vm", "kill", "m1").0 == 0)
        #expect(try w.cli("vm", "start", "m1").0 == 0)
        var again = ""
        for _ in 0..<60 { again = (try? machineID("m1")) ?? ""; if !again.isEmpty { break }; try await Task.sleep(for: .milliseconds(500)) }
        #expect(again == a, "kept across kill/start")
        for v in ["m1", "m2"] { _ = try w.cli("vm", "kill", "--force", v) }
    }

    @Test("a workspace set to boot at login starts with the daemon; one that isn't stays off")
    func bootAtStartup() async throws {
        let w = try World()
        defer { w.destroy() }
        var daemon = try await w.startDaemon()
        let api = FirecrackerAPI(socketPath: w.socket)
        #expect(try await api.request("POST", "/profiles", ["name": "atboot", "bootAtStartup": true]).status == 201)
        #expect(try await api.request("POST", "/profiles", ["name": "notboot"]).status == 201)
        kill(daemon.processIdentifier, SIGTERM); daemon.waitUntilExit()
        // Once per login (the runtime dir's marker): this start was in the
        // same login, so a new one is had by clearing it.
        let marker = w.root + "/run/bromure-ac/booted-at-login"
        #expect(FileManager.default.fileExists(atPath: marker), "the first start marked the login")
        try? FileManager.default.removeItem(atPath: marker)
        daemon = try await w.startDaemon()
        defer { kill(daemon.processIdentifier, SIGTERM); daemon.waitUntilExit() }
        var state = ""
        for _ in 0..<120 {
            state = try w.vm("atboot")?["state"]?.stringValue ?? ""
            if state == "running" { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        #expect(state == "running", "booted with the daemon")
        #expect(try w.vm("notboot")?["state"]?.stringValue == "stopped", "the other one left off")
        _ = try? w.cli("vm", "kill", "--force", "atboot")
        // The daemon restarting in the same login doesn't boot it again.
        kill(daemon.processIdentifier, SIGTERM); daemon.waitUntilExit()
        daemon = try await w.startDaemon()
        try await Task.sleep(for: .seconds(5))
        #expect(try w.vm("atboot")?["state"]?.stringValue == "stopped", "a restart in the same login leaves it off")
    }

    @Test("a guest that reboots itself boots again: its reboot intent, then Firecracker's exit, then a cold boot")
    func guestReboot() async throws {
        let w = try World()
        defer { w.destroy() }
        let daemon = try await w.startDaemon()
        defer { kill(daemon.processIdentifier, SIGTERM); daemon.waitUntilExit() }
        #expect(try w.cli("vm", "run", "--name", "rb").0 == 0)
        func bootID() -> String {
            ((try? w.cli("vm", "exec", "rb", "--", "cat", "/proc/sys/kernel/random/boot_id"))?.1 ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var first = ""
        for _ in 0..<120 { first = bootID(); if first.count >= 32 { break }; try await Task.sleep(for: .milliseconds(500)) }
        #expect(first.count >= 32, "the first boot answers: \(first)")
        _ = try? w.cli("vm", "exec", "rb", "--", "sudo", "systemctl", "reboot")
        var second = ""
        for _ in 0..<360 {
            try await Task.sleep(for: .milliseconds(500))
            let b = bootID()
            if b.count >= 32, b != first { second = b; break }
        }
        let log = (try? String(contentsOfFile: w.root + "/daemon.log", encoding: .utf8)) ?? ""
        #expect(!second.isEmpty, "booted again after the guest's reboot (first boot \(first)); daemon log:\n\(log.suffix(3000))")
        #expect(try w.cli("vm", "ls").1.contains("running"), "running again")
        // A guest poweroff, though, leaves it off (the kernel says "Power down").
        _ = try? w.cli("vm", "exec", "rb", "--", "sudo", "systemctl", "poweroff")
        var state = ""
        for _ in 0..<120 {
            try await Task.sleep(for: .milliseconds(500))
            state = try w.cli("vm", "ls").1
            if state.contains("stopped") { break }
        }
        #expect(state.contains("stopped"), "off after the guest's poweroff: \(state)")
        try await Task.sleep(for: .seconds(10))
        #expect(try w.cli("vm", "ls").1.contains("stopped"), "and not booted again")
        // A user's stop that lands while a guest's reboot is stopping or
        // relaunching the VM: the stop wins, it stays off.
        #expect(try w.cli("vm", "start", "rb").0 == 0)
        var third = ""
        for _ in 0..<240 { third = bootID(); if third.count >= 32 { break }; try await Task.sleep(for: .milliseconds(500)) }
        #expect(third.count >= 32, "booted again for the race")
        let daemonLog = { (try? String(contentsOfFile: w.root + "/daemon.log", encoding: .utf8)) ?? "" }
        let seen = daemonLog().components(separatedBy: "stopped as its guest rebooted").count
        _ = try? w.cli("vm", "exec", "rb", "--", "sudo", "systemctl", "reboot")
        var rebooting = false
        for _ in 0..<1200 where !rebooting {   // 60 s
            rebooting = daemonLog().components(separatedBy: "stopped as its guest rebooted").count > seen
            if !rebooting { try await Task.sleep(for: .milliseconds(50)) }
        }
        #expect(rebooting, "the guest's reboot was seen")
        let (rc, _, err) = try w.cli("vm", "kill", "rb")
        #expect(rc == 0, "the stop is taken in that window: \(err)")
        try await Task.sleep(for: .seconds(15))
        #expect(try w.vm("rb")?["state"]?.stringValue == "stopped", "the user's stop won; daemon log:\n\(daemonLog().suffix(2000))")
        _ = try? w.cli("vm", "kill", "--force", "rb")
    }

    @Test("a stop sent while the reboot route shuts the VM down wins: it stays off")
    func aStopDuringARebootWins() async throws {
        let w = try World()
        defer { w.destroy() }
        let daemon = try await w.startDaemon()
        defer { kill(daemon.processIdentifier, SIGTERM); daemon.waitUntilExit() }
        #expect(try w.cli("vm", "run", "--name", "rr").0 == 0)
        var up = false
        for _ in 0..<240 where !up {
            up = (try? w.cli("vm", "exec", "rr", "--", "true"))?.0 == 0
            if !up { try await Task.sleep(for: .milliseconds(500)) }
        }
        #expect(up, "booted")
        let id = try #require(w.vm("rr")?["id"]?.stringValue)
        // A unit whose stop takes 15 s: the guest's shutdown lasts that long.
        let slow = try w.cli("vm", "exec", "rr", "--", "sudo", "systemd-run", "--unit=slowstop", "-p", "ExecStop=/bin/sleep 15", "/bin/sleep", "infinity")
        #expect(slow.0 == 0, "\(slow.2)")
        let socket = w.socket
        // The reboot (its guest shutdown first), and a stop sent while it
        // shuts down.
        let reboot = Task { try await FirecrackerAPI(socketPath: socket).request("POST", "/vms/\(id)/reboot", ["mode": "soft"], timeout: .seconds(120)) }
        try await Task.sleep(for: .seconds(2))
        let (rc, _, err) = try w.cli("vm", "kill", "rr")
        #expect(rc == 0, "the stop is taken: \(err)")
        let r = try await reboot.value
        #expect(r.status == 409, "the reboot says it was stopped: \(String(describing: r.body))")
        try await Task.sleep(for: .seconds(5))
        let log = (try? String(contentsOfFile: w.root + "/daemon.log", encoding: .utf8)) ?? ""
        #expect(try w.vm("rr")?["state"]?.stringValue == "stopped", "it stays off; daemon log:\n\(log.suffix(2000))")
        _ = try? w.cli("vm", "kill", "--force", "rr")
    }

    @Test("a boot that dies on a filesystem error is offered Repair, then Reset once a repair didn't help; Reset boots it clean")
    func bootFailureRemedy() async throws {
        let w = try World()
        defer { w.destroy() }
        let daemon = try await w.startDaemon()
        defer { kill(daemon.processIdentifier, SIGTERM); daemon.waitUntilExit() }
        let ran = try w.cli("vm", "run", "--name", "bf")
        #expect(ran.0 == 0, "vm run: \(ran.2); daemon log:\n\(((try? String(contentsOfFile: w.root + "/daemon.log", encoding: .utf8)) ?? "").prefix(6000))")
        var up = false
        for _ in 0..<240 where !up {
            up = (try? w.cli("vm", "exec", "bf", "--", "true"))?.0 == 0
            if !up { try await Task.sleep(for: .milliseconds(500)) }
        }
        #expect(up, "the first boot answers")
        // A boot that ends in emergency mode (as one whose fsck fails does):
        // its console line ("You are in emergency mode", or sulogin's locked
        // root account) is one the daemon watches for. Set on the system
        // disk only, so a repair doesn't help and a reset does.
        #expect(try w.cli("vm", "exec", "bf", "--", "sudo", "sh", "-c", "systemctl set-default emergency.target && sync").0 == 0)
        _ = try? w.cli("vm", "exec", "bf", "--", "sudo", "systemctl", "reboot")
        let id = try #require(w.vm("bf")?["id"]?.stringValue)
        /// /state as the fat client polls it (a connected client: prompts are offered).
        func state() -> JSONValue? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            p.arguments = ["-sS", "--max-time", "5", "--unix-socket", w.socket, "-H", "x-bromure-console-idle-ms: 0", "http://localhost/state"]
            let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let d = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return try? JSONDecoder().decode(JSONValue.self, from: d)
        }
        func row(_ st: JSONValue?) -> JSONValue? {
            guard case .array(let rows)? = st?["workspaces"] else { return nil }
            return rows.first { $0["id"]?.stringValue?.lowercased() == id.lowercased() }
        }
        /// The boot-failure prompt offering `button`, answered with it.
        func answer(_ button: String) async throws -> Bool {
            for _ in 0..<480 {
                let st = state()
                if case .array(let prompts)? = st?["pendingPrompts"],
                   let p = prompts.first(where: { $0["title"]?.stringValue?.contains("can't boot") == true }),
                   case .array(let buttons)? = p["buttons"], buttons.first?.stringValue == button,
                   let pid = p["id"]?.stringValue {
                    #expect(row(st)?["bootFailure"]?.stringValue?.isEmpty == false, "the row says it too")
                    let api = FirecrackerAPI(socketPath: w.socket)
                    return try await api.request("POST", "/prompts/\(pid)/answer", ["choice": 0]).status == 200
                }
                try await Task.sleep(for: .milliseconds(500))
            }
            return false
        }
        let log = { (try? String(contentsOfFile: w.root + "/daemon.log", encoding: .utf8)) ?? "" }
        #expect(try await answer("Repair Disk"), "offered a repair; daemon log:\n\(log().suffix(3000))")
        // A user's start while the remedy has the disk (stopping it, then
        // fsck) is refused: none boots it before the repair has run.
        var startedEarly = false
        for _ in 0..<60 where !log().contains("native fsck on") {
            if (try? w.cli("vm", "start", "bf"))?.0 == 0, !log().contains("native fsck on") { startedEarly = true }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(!startedEarly, "a start landed before the repair; daemon log:\n\(log().suffix(3000))")
        // A repair (the disk is clean) doesn't change that: the next boot fails the same way.
        #expect(try await answer("Reset System Disk"), "then a reset; daemon log:\n\(log().suffix(3000))")
        // The reset re-clones the system disk: the boot is clean, the failure gone.
        var clean = false
        for _ in 0..<480 where !clean {
            let out = (try? w.cli("vm", "exec", "bf", "--", "systemctl", "get-default"))?.1 ?? ""
            clean = !out.isEmpty && !out.contains("emergency")
            if !clean { try await Task.sleep(for: .milliseconds(500)) }
        }
        #expect(clean, "booted on a fresh system disk; daemon log:\n\(log().suffix(3000))")
        var cleared = false
        for _ in 0..<40 where !cleared {
            cleared = row(state())?["bootFailure"] == nil
            if !cleared { try await Task.sleep(for: .milliseconds(500)) }
        }
        #expect(cleared, "the row's failure is gone")
        #expect(log().contains("native fsck on") && log().contains("reset to base after boot failure"))
        _ = try? w.cli("vm", "kill", "--force", "bf")
    }

    @Test("workspaces are Profiles: POST /profiles makes one from the template with its VM registered (stopped); GET lists it")
    func profiles() async throws {
        let w = try World()
        defer { w.destroy() }
        let daemon = try await w.startDaemon()
        defer { kill(daemon.processIdentifier, SIGTERM); daemon.waitUntilExit() }
        let api = FirecrackerAPI(socketPath: w.socket)

        let made = try await api.request("POST", "/profiles", ["name": "p1", "tool": "codex", "color": "blue"])
        #expect(made.status == 201, "\(String(describing: made.body))")
        let id = try #require(made.body?["id"]?.stringValue)
        #expect(UUID(uuidString: id) != nil)
        #expect(FileManager.default.fileExists(atPath: w.root + "/state/bromure-ac/profiles/" + id + "/profile.json"),
                "saved through ProfileStore in the state dir")
        #expect(try w.vm("p1")?["state"]?.stringValue == "stopped", "its VM is registered, not booted")
        #expect(try w.vm("p1")?["id"]?.stringValue == id.lowercased(), "with the profile's id")

        let list = try await api.request("GET", "/profiles")
        guard case .array(let rows)? = list.body?["profiles"] else { Issue.record("no profiles array"); return }
        let row = try #require(rows.first { $0["id"]?.stringValue == id })
        #expect(row["name"]?.stringValue == "p1")
        #expect(row["tool"]?.stringValue == "codex", "the document's fields over the template's")
        #expect(row["color"]?.stringValue == "blue")
        #expect(row["state"]?.stringValue == "off")

        #expect(try await api.request("POST", "/profiles", ["name": "p1"]).status == 409, "names are unique")
        #expect(try await api.request("POST", "/profiles", ["tool": "claude"]).status == 400, "a name is required")
        #expect(try await api.request("POST", "/profiles", ["name": "p2", "tool": "no-such-tool"]).status == 400,
                "a bad field is refused (ProfileDocument)")

        // Decision prompts: /state lists them (none here); an unknown one can't
        // be answered. The session model's lists ride along, as on macOS.
        let st = try await api.request("GET", "/state").body
        for key in ["pendingPrompts", "agentSessions", "delegations", "agentRooms"] {
            guard case .array? = st?[key] else { Issue.record("no \(key) array in /state"); return }
        }
        #expect(FileManager.default.fileExists(atPath: w.root + "/state/bromure-ac/sessions.json")
                    || st?["agentSessions"] == .array([]), "the session store is the state dir's")
        #expect(try await api.request("POST", "/prompts/\(UUID().uuidString)/answer", ["choice": 1]).status == 404)
    }

    @Test("vm run -v: the host folder is ~/<basename> in the guest, both ways; --rm deletes the workspace when it stops; a workspace runs again by name")
    func runMountsAndRm() async throws {
        let w = try World()
        defer { w.destroy() }
        let daemon = try await w.startDaemon()
        defer { kill(daemon.processIdentifier, SIGTERM); daemon.waitUntilExit() }
        let proj = w.root + "/host/proj"
        try FileManager.default.createDirectory(atPath: proj, withIntermediateDirectories: true)
        try "from-host\n".write(toFile: proj + "/host.txt", atomically: true, encoding: .utf8)

        let (rc, _, err) = try w.cli("vm", "run", "--name", "mnt1", "--tool", "claude", "-v", proj, "--rm")
        #expect(rc == 0, "run: \(err)")
        // agentd links the share in once the session is up.
        var seen = ""
        for _ in 0..<60 {
            seen = (try? w.cli("vm", "exec", "mnt1", "--", "sh", "-c", "cat ~/proj/host.txt 2>/dev/null").1) ?? ""
            if seen.contains("from-host") { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        #expect(seen.contains("from-host"), "the host folder at ~/proj: \(seen)")
        #expect(try w.cli("vm", "exec", "mnt1", "--", "sh", "-c", "echo from-guest > ~/proj/guest.txt").0 == 0)
        #expect((try? String(contentsOfFile: proj + "/guest.txt", encoding: .utf8)) == "from-guest\n", "written back to the host")
        #expect(try w.cli("vm", "kill", "mnt1").0 == 0)
        var gone = false
        for _ in 0..<40 where !gone {
            gone = try w.vm("mnt1") == nil
            if !gone { try await Task.sleep(for: .milliseconds(250)) }
        }
        #expect(gone, "--rm: its VM went with it")
        let profiles = (try? FileManager.default.contentsOfDirectory(atPath: w.root + "/state/bromure-ac/profiles")) ?? []
        #expect(!profiles.contains { (try? String(contentsOfFile: w.root + "/state/bromure-ac/profiles/\($0)/profile.json", encoding: .utf8))?.contains("\"mnt1\"") == true },
                "--rm: its workspace went too")
        #expect(FileManager.default.fileExists(atPath: proj + "/host.txt"), "the host folder is the user's: kept")

        // A suspend ends a --rm workspace too (macOS: its session's end).
        #expect(try w.cli("vm", "run", "--name", "eph2", "--tool", "claude", "--rm").0 == 0)
        #expect(try w.cli("vm", "suspend", "eph2").0 == 0)
        var suspendedGone = false
        for _ in 0..<40 where !suspendedGone {
            suspendedGone = try w.vm("eph2") == nil
            if !suspendedGone { try await Task.sleep(for: .milliseconds(250)) }
        }
        #expect(suspendedGone, "--rm: a suspended one goes")

        // A kept workspace runs again by name (its own VM, not a new one).
        #expect(try w.cli("vm", "run", "--name", "keep1").0 == 0)
        let id = try w.vm("keep1")?["id"]?.stringValue
        #expect(try w.cli("vm", "kill", "keep1").0 == 0)
        for _ in 0..<40 where try w.state(of: "keep1") != "stopped" { try await Task.sleep(for: .milliseconds(250)) }
        let (rc2, again, err2) = try w.cli("vm", "run", "keep1")
        #expect(rc2 == 0, "run by name: \(err2)")
        #expect(again.trimmingCharacters(in: .whitespacesAndNewlines) == id, "the same workspace")
        #expect(try w.state(of: "keep1") == "running")
        #expect(try w.cli("vm", "run").0 != 0, "neither a workspace nor --name/--tool")
        _ = try w.cli("vm", "kill", "--force", "keep1")
    }

    @Test("ssh-key import: a passphrase-protected key file is the guest's to sign with (its agent lists it), the passphrase in the vault")
    func importedSSHKey() async throws {
        var w = try World()
        // A vault of the test's own, its key in a file there (never sealed
        // with the user's systemd credentials).
        w.extraEnv["BROMURE_VAULT_KEY_SOURCE"] = "file"
        defer { w.destroy() }
        let daemon = try await w.startDaemon()
        defer { kill(daemon.processIdentifier, SIGTERM); daemon.waitUntilExit() }
        let keyDir = w.root + "/keys"
        try FileManager.default.createDirectory(atPath: keyDir, withIntermediateDirectories: true)
        let keygen = Process()
        keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        keygen.arguments = ["-q", "-t", "ed25519", "-N", "fixture-pass", "-C", "e2e-imported", "-f", keyDir + "/id_e2e"]
        try keygen.run()
        keygen.waitUntilExit()
        let pub = try String(contentsOfFile: keyDir + "/id_e2e.pub", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(try w.cli("vm", "run", "--name", "sk1", "--tool", "claude").0 == 0)
        #expect(try w.cli("vm", "kill", "sk1").0 == 0)
        for _ in 0..<40 where try w.state(of: "sk1") != "stopped" { try await Task.sleep(for: .milliseconds(250)) }
        let (irc, iout, ierr) = try w.cli(["ssh-key", "import", "sk1", keyDir + "/id_e2e", "--label", "e2e", "--passphrase-stdin"],
                                          input: "fixture-pass\n")
        #expect(irc == 0, "import: \(ierr)")
        #expect(iout.contains("e2e") && iout.contains("passphrase in the vault"), "\(iout)")
        let secrets = try FileManager.default.subpathsOfDirectory(atPath: w.root + "/data")
        #expect(secrets.contains { $0.contains("ssh-key-passphrases") }, "a vault item")
        for f in secrets where !f.hasSuffix(".img") {
            if let d = FileManager.default.contents(atPath: w.root + "/data/" + f) {
                #expect(d.range(of: Data("fixture-pass".utf8)) == nil, "never in the clear: \(f)")
            }
        }

        #expect(try w.cli("vm", "start", "sk1").0 == 0)
        var listed = ""
        for _ in 0..<60 {
            listed = (try? w.cli("vm", "exec", "sk1", "--", "sh", "-c", "SSH_AUTH_SOCK=/tmp/bromure-agent.sock ssh-add -L 2>&1").1) ?? ""
            if listed.contains(pub.split(separator: " ")[1]) { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        #expect(listed.contains(pub.split(separator: " ")[1]), "the guest's agent lists the imported key: \(listed)")
        _ = try w.cli("vm", "kill", "--force", "sk1")
    }

    @Test("POST /sessions/<workspace>/tab: agentd opens and closes the tab (tmux windows, read back from tabs.txt)")
    func tabs() async throws {
        let w = try World()
        defer { w.destroy() }
        let daemon = try await w.startDaemon()
        defer { kill(daemon.processIdentifier, SIGTERM); daemon.waitUntilExit() }
        let api = FirecrackerAPI(socketPath: w.socket)
        #expect(try w.cli("vm", "run", "--name", "t1").0 == 0)
        func tabCount() throws -> Int {
            guard case .array(let tabs)? = try w.vm("t1")?["tabs"] else { return -1 }
            return tabs.count
        }
        var before = -1
        for _ in 0..<120 { before = try tabCount(); if before > 0 { break }; try await Task.sleep(for: .milliseconds(500)) }
        #expect(before > 0, "agentd reported its tmux windows")
        #expect(try await api.request("POST", "/sessions/t1/tab", ["action": "new"]).status == 200)
        var after = before
        for _ in 0..<40 { after = try tabCount(); if after == before + 1 { break }; try await Task.sleep(for: .milliseconds(500)) }
        #expect(after == before + 1, "a new tab (\(before) -> \(after))")
        #expect(try await api.request("POST", "/sessions/t1/tab", ["action": "close", "index": .number(Double(after - 1))]).status == 200)
        var closed = after
        for _ in 0..<40 { closed = try tabCount(); if closed == before { break }; try await Task.sleep(for: .milliseconds(500)) }
        #expect(closed == before, "the tab closed again (\(after) -> \(closed))")
        #expect(try await api.request("POST", "/sessions/t1/tab", ["action": "rename"]).status == 400)
        #expect(try await api.request("POST", "/sessions/nope/tab", ["action": "new"]).status == 400)
        _ = try w.cli("vm", "kill", "--force", "t1")
    }
}

