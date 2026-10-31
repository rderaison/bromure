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
        var env: [String: String] {
            var e = ProcessInfo.processInfo.environment
            e["XDG_RUNTIME_DIR"] = root + "/run"
            e["XDG_STATE_HOME"] = root + "/state"
            e["BROMURE_AC_IMAGE"] = Env.image
            e["BROMURE_AGENTD"] = Env.agentd
            e.removeValue(forKey: "NOTIFY_SOCKET")
            return e
        }
        var socket: String { root + "/run/bromure-ac/control.sock" }

        init() throws {
            root = "/tmp/acl-dm-\(UUID().uuidString.prefix(6))"
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

    @Test("run, ls, exec, suspend, resume, exec, kill; a SIGKILLed daemon's VM is re-adopted by the next one (exec works; flows through the old passt break)")
    func lifecycle() async throws {
        let w = try World()
        defer { try? FileManager.default.removeItem(atPath: w.root) }
        // Earlier suites in this process hold host vsock port 5800; the daemon needs it.
        await VsockListener.closeShared(port: agentPort)
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

        let t1 = ContinuousClock.now
        #expect(try w.cli("vm", "suspend", "dm1").0 == 0)
        print("TIMING [daemon] suspend \(ms(ContinuousClock.now - t1))")
        #expect(try w.state(of: "dm1") == "suspended")
        #expect(try w.cli("vm", "exec", "dm1", "--", "true").0 != 0, "exec on a suspended VM is refused (409)")
        let t2 = ContinuousClock.now
        #expect(try w.cli("vm", "resume", "dm1").0 == 0)
        let (rc3, up, err3) = try w.cli("vm", "exec", "dm1", "--", "cat", "/proc/uptime")
        print("TIMING [daemon] resume + exec \(ms(ContinuousClock.now - t2)): uptime \(up.prefix(20))")
        #expect(rc3 == 0, "exec after resume: \(err3)")
        #expect(try w.cli("vm", "kill", "--force", "dm1").0 == 0)
        #expect(try w.state(of: "dm1") == "stopped")

        // Unknown routes: 404 with a JSON error; foreign uid is covered by
        // SO_PEERCRED (not testable as the same user).
        let r = try ControlClient(socketPath: w.socket).request("GET", "/no/such/route")
        #expect(r.status == 404 && r.json["error"]?.stringValue == "Not found")

        // A running VM, then SIGKILL the daemon: passt goes with it (its
        // socket hits EOF), the VM doesn't (no exit-with-parent), and the next
        // daemon re-adopts it.
        let lan = try #require(hostLANAddress())
        let base = 47_000 + Int.random(in: 0..<400) * 8
        let svc = try await startServices(ip: lan, base: base)
        defer { stopHelper(svc) }
        #expect(try w.cli("vm", "run", "--name", "dm2").0 == 0)
        #expect(try w.cli("vm", "exec", "dm2", "--", "true").0 == 0)
        // A TCP flow through passt that outlives the restart: one echo a second,
        // each reply's time in /tmp/flow.log.
        #expect(try w.cli("vm", "exec", "dm2", "--", "sh", "-c", """
            nohup python3 -c "
            import socket, time
            s = socket.create_connection(('\(lan)', \(base + 1)), timeout=5); s.settimeout(5)
            while True:
                try:
                    s.sendall(b'x'); s.recv(1)
                    open('/tmp/flow.log', 'a').write('ok %.1f\\n' % time.time())
                except Exception as e:
                    open('/tmp/flow.log', 'a').write('err %s %.1f\\n' % (type(e).__name__, time.time()))
                time.sleep(1)
            " >/dev/null 2>&1 &
            sleep 2; tail -1 /tmp/flow.log
            """).1.contains("ok"), "the flow runs before the restart")
        let kids = Self.children(of: daemon.processIdentifier)
        let names = Set(kids.map { $0.1 })
        #expect(names.contains { $0.hasPrefix("qemu-system") } && names.contains { $0.hasPrefix("passt") },
                "expected QEMU and passt under the daemon, saw \(names)")
        // QEMU outlives a SIGKILLed daemon by design; if the test stops before
        // `vm kill dm2`, nothing else would end it.
        defer { for k in kids where k.1.hasPrefix("qemu-system") && Self.alive(k.0) { kill(k.0, SIGKILL) } }
        kill(daemon.processIdentifier, SIGKILL)
        daemon.waitUntilExit()
        let tKill = Date().timeIntervalSince1970
        try await Task.sleep(for: .seconds(1))
        let qemuLeft = kids.filter { $0.1.hasPrefix("qemu-system") && Self.alive($0.0) }
        let passtLeft = kids.filter { $0.1.hasPrefix("passt") && Self.alive($0.0) }
        #expect(qemuLeft.count == 1, "the VM outlives the daemon")
        #expect(passtLeft.isEmpty, "passt ends with the daemon's socket")
        print("ADOPT [daemon] after SIGKILL: QEMU alive \(qemuLeft.count), passt alive \(passtLeft.count)")

        // Restart: dm2 is re-adopted, not phantom-stopped.
        let tRestart = ContinuousClock.now
        daemon = try await w.startDaemon()
        #expect(try w.state(of: "dm2") == "running", "re-adopted")
        var execRC = -1
        for _ in 0..<30 where execRC != 0 {
            execRC = Int(try w.cli("vm", "exec", "dm2", "--", "true").0)
            if execRC != 0 { try await Task.sleep(for: .milliseconds(500)) }
        }
        #expect(execRC == 0, "exec after re-adoption")
        print("ADOPT [daemon] restart -> exec works: \(ms(ContinuousClock.now - tRestart))")
        // New connections work through the new passt; the old flow is measured.
        let fresh = try w.cli("vm", "exec", "dm2", "--", "python3", "-c",
                              "import socket; print(socket.create_connection(('\(lan)', \(base + 2)), timeout=5).recv(64).decode().strip())").1
        #expect(fresh.contains("hello from"), "a new connection after the restart: \(fresh)")
        try await Task.sleep(for: .seconds(6))
        let flow = try w.cli("vm", "exec", "dm2", "--", "cat", "/tmp/flow.log").1
        let after = flow.split(separator: "\n").filter { l in
            l.split(separator: " ").last.flatMap { Double($0) }.map { $0 > tKill + 2 } ?? false
        }
        print("ADOPT [daemon] the flow opened before the kill, after the restart: \(after.prefix(3)) (\(after.count) lines)")
        // Expected: dead (passt is a new process with none of the old flow's
        // state). Recorded, not asserted, so a change in that shows up as data.
        #expect(try w.cli("vm", "kill", "--force", "dm2").0 == 0)

        // A suspended VM keeps its CID across a graceful restart: SIGTERM
        // (the systemctl stop path, with signals unblocked even though
        // Foundation's Process spawned the daemon with them blocked) kills the
        // running VMs, closes passt and unlinks control.sock.
        #expect(try w.cli("vm", "run", "--name", "dm3").0 == 0)
        #expect(try w.cli("vm", "exec", "dm3", "--", "true").0 == 0)
        #expect(try w.cli("vm", "suspend", "dm3").0 == 0)
        let dm3cid = try w.vm("dm3")?["cid"]?.numberValue
        #expect(try w.cli("vm", "run", "--name", "dm4").0 == 0)
        #expect(try w.cli("vm", "exec", "dm4", "--", "true").0 == 0)
        let termKids = Self.children(of: daemon.processIdentifier)
        kill(daemon.processIdentifier, SIGTERM)
        let tTerm = ContinuousClock.now
        daemon.waitUntilExit()
        print("TIMING [daemon] SIGTERM -> exit \(ms(ContinuousClock.now - tTerm)), status \(daemon.terminationStatus)")
        #expect(daemon.terminationReason == .exit && daemon.terminationStatus == 0, "graceful exit")
        #expect(!FileManager.default.fileExists(atPath: w.socket), "control.sock unlinked")
        #expect(termKids.filter { Self.alive($0.0) }.isEmpty, "children left after SIGTERM: \(termKids)")

        daemon = try await w.startDaemon()
        #expect(try w.state(of: "dm3") == "suspended")
        #expect(try w.state(of: "dm4") == "stopped")
        #expect(try w.cli("vm", "run", "--name", "dm5").0 == 0)       // must not take dm3's CID
        #expect(try w.vm("dm5")?["cid"]?.numberValue != dm3cid)
        #expect(try w.cli("vm", "resume", "dm3").0 == 0)
        #expect(try w.cli("vm", "exec", "dm3", "--", "true").0 == 0)
        #expect(try w.vm("dm3")?["cid"]?.numberValue == dm3cid, "dm3 resumed under its own CID")

        // A name that's another VM's id or short id is refused.
        let dm5short = try #require(try w.vm("dm5")?["shortId"]?.stringValue)
        #expect(try w.cli("vm", "run", "--name", dm5short).0 != 0)

        kill(daemon.processIdentifier, SIGTERM)
        daemon.waitUntilExit()
    }

    @Test("the home image: ext4 on vdb at /home/ubuntu; kept across kill/start and suspend/resume; gone with rm")
    func homeImage() async throws {
        let w = try World()
        defer { try? FileManager.default.removeItem(atPath: w.root) }
        await VsockListener.closeShared(port: agentPort)
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

        // Suspend and resume: the home is part of the snapshot.
        #expect(try w.cli("vm", "suspend", "h1").0 == 0)
        #expect(FileManager.default.fileExists(atPath: dir + "/vm.state.identity.disk0.json"), "home identity saved")
        #expect(try w.cli("vm", "resume", "h1").0 == 0)
        #expect(try w.cli("vm", "exec", "h1", "--", "cat", "/home/ubuntu/marker").1.contains("kept"))
        #expect(try w.cli("vm", "exec", "h1", "--", "sh", "-c", "echo again >> /home/ubuntu/marker && sync").0 == 0)

        // A home changed while suspended is refused at resume.
        #expect(try w.cli("vm", "suspend", "h1").0 == 0)
        let fh = try #require(FileHandle(forWritingAtPath: dir + "/home.img"))
        try fh.seek(toOffset: 8 << 30)
        try fh.write(contentsOf: Data("x".utf8))
        try fh.close()
        #expect(try w.cli("vm", "resume", "h1").0 != 0, "resume refuses a home changed since the save")

        // rm: only when not running; then the VM and its files are gone.
        #expect(try w.cli("vm", "rm", "h1").0 == 0)
        #expect(try w.vm("h1") == nil)
        #expect(!FileManager.default.fileExists(atPath: dir), "the VM's directory is deleted")
        #expect(try w.cli("vm", "run", "--name", "h2").0 == 0)
        #expect(try w.cli("vm", "rm", "h2").0 != 0, "a running VM is not removed")
        #expect(try w.cli("vm", "kill", "--force", "h2").0 == 0)
        #expect(try w.cli("vm", "rm", "h2").0 == 0)
    }
}
