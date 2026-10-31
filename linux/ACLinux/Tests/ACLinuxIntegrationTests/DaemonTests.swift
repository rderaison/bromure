import Foundation
import Testing
import ACLinux

/// The bromure-ac daemon and CLI, end to end: a real daemon process with
/// passt and a KVM guest, driven by the CLI binary over control.sock.
enum DaemonEnv {
    static let bin = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".build/debug/bromure-ac").path
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
        func cli(_ args: String...) throws -> (Int32, String, String) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: DaemonEnv.bin)
            p.arguments = args
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            try p.run()
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

    @Test("run, ls, exec, suspend, resume, exec, kill; SIGKILLed daemon leaves no QEMU/passt; restart shows it stopped")
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
        #expect(rc2 == 0 && uname.hasPrefix("Linux bromure-ac"), "exec: \(uname) \(err2)")
        #expect(try w.cli("vm", "exec", "dm1", "--", "sh", "-c", "exit 7").0 == 7, "exit status propagates")
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

        // A running VM, then SIGKILL the daemon: nothing of it may survive.
        #expect(try w.cli("vm", "run", "--name", "dm2").0 == 0)
        #expect(try w.cli("vm", "exec", "dm2", "--", "true").0 == 0)
        let kids = Self.children(of: daemon.processIdentifier)
        let names = Set(kids.map { $0.1 })
        #expect(names.contains { $0.hasPrefix("qemu-system") } && names.contains { $0.hasPrefix("passt") },
                "expected QEMU and passt under the daemon, saw \(names)")
        kill(daemon.processIdentifier, SIGKILL)
        daemon.waitUntilExit()
        var left = kids.filter { Self.alive($0.0) }
        for _ in 0..<50 where !left.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
            left = kids.filter { Self.alive($0.0) }
        }
        #expect(left.isEmpty, "survived the daemon: \(left)")
        print("ORPHANS [daemon] children before SIGKILL: \(kids.map { $0.1 }.sorted()); alive after: \(left.count)")

        // Restart: the registry says stopped, not phantom-running.
        daemon = try await w.startDaemon()
        #expect(try w.state(of: "dm2") == "stopped")
        #expect(try w.cli("vm", "exec", "dm2", "--", "true").0 != 0)

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
