import Foundation
import Testing
import SandboxEngine
@testable import bromure_ac

@Suite("Kernel sentry (host side) + guest sandbox spec")
struct KernelSentryTests {
    // MARK: helpers

    static func S(_ v: AnyJSON?) -> String? { if case .string(let x)? = v { return x }; return nil }
    static func I(_ v: AnyJSON?) -> Int? { if case .int(let x)? = v { return x }; return nil }

    final class Tap: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(String, [String: AnyJSON])] = []
        func add(_ t: String, _ d: [String: AnyJSON]) { lock.lock(); items.append((t, d)); lock.unlock() }
        var all: [(String, [String: AnyJSON])] { lock.lock(); defer { lock.unlock() }; return items }
        func alarms(_ kind: String? = nil) -> [[String: AnyJSON]] {
            all.filter { $0.0 == "sentry.alarm" && (kind == nil || KernelSentryTests.S($0.1["kind"]) == kind) }.map(\.1)
        }
        func events() -> [[String: AnyJSON]] { all.filter { $0.0 == "sentry.event" }.map(\.1) }
        func waitFor(_ pred: () -> Bool) { for _ in 0..<200 where !pred() { usleep(10_000) } }
    }

    static let secret = String(repeating: "ab", count: 32)

    func frame(_ obj: [String: Any]) -> Data {
        let body = try! JSONSerialization.data(withJSONObject: obj)
        var d = Data([UInt8(body.count >> 24 & 0xff), UInt8(body.count >> 16 & 0xff),
                      UInt8(body.count >> 8 & 0xff), UInt8(body.count & 0xff)])
        d.append(body)
        return d
    }

    func hello(_ secret: String = secret) -> Data {
        frame(["type": "hello", "v": 1, "secret": secret, "boot_id": "b", "kernel": "6.8.0-139-generic", "module": "1"])
    }

    /// A bridge serving one end of a socket pair; returns (bridge, guest fd, tap).
    func connect(_ bridge: SentryBridge? = nil, _ first: Data) -> (SentryBridge, Int32, Tap) {
        let b = bridge ?? SentryBridge(profileID: UUID(), requirement: .bestEffort, restoring: false)
        let tap = Tap()
        if b.tap == nil { b.tap = { tap.add($0, $1) } }
        var fds: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        Thread.detachNewThread { b.serve(fds[0]) }
        send(fds[1], first)
        return (b, fds[1], tap)
    }

    func send(_ fd: Int32, _ d: Data) {
        _ = d.withUnsafeBytes { write(fd, $0.baseAddress!, d.count) }
    }

    // MARK: spec

    @Test("Spec: only the three sections, verbatim; inactive without them")
    func spec() throws {
        let yaml = """
        version: 1
        filesystem_policy:
          include_workdir: true
          read_only: [/usr, /lib]
          read_write: [/tmp]
        landlock: { compatibility: hard_requirement }
        network_policies: {}
        """
        let s = OpenShellSandboxSpec(policyYAML: yaml, workdirs: ["/home/ubuntu/app"], strictSandbox: true, sentry: "hard")
        #expect(s.isActive)
        let obj = try #require(try JSONSerialization.jsonObject(with: s.jsonData()) as? [String: Any])
        let fs = try #require(obj["filesystem_policy"] as? [String: Any])
        #expect(fs["read_only"] as? [String] == ["/usr", "/lib"])
        #expect(fs["include_workdir"] as? Bool == true)
        #expect((obj["landlock"] as? [String: Any])?["compatibility"] as? String == "hard_requirement")
        #expect(obj["process"] is NSNull)
        #expect(obj["workdirs"] as? [String] == ["/home/ubuntu/app"])
        #expect(obj["network_policies"] as? [String] == [])    // `{}`: a definite "no rules"
        let withRules = OpenShellSandboxSpec(policyYAML: yaml.replacingOccurrences(of: "network_policies: {}", with: "network_policies:\n  web:\n    endpoints: []\n"),
                                             workdirs: [], strictSandbox: false, sentry: "off")
        #expect(withRules.networkPolicyNames == ["web"])
        let sentry = try #require(obj["sentry"] as? [String: Any])
        #expect(sentry["enabled"] as? Bool == true && sentry["requirement"] as? String == "hard" && sentry["vsock_port"] as? Int == 5841)

        let plain = OpenShellSandboxSpec(policyYAML: "version: 1\nnetwork_policies: {}\n", workdirs: [], strictSandbox: false, sentry: "off")
        #expect(!plain.isActive)
        #expect(OpenShellSandboxSpec(policyYAML: "", workdirs: [], strictSandbox: false, sentry: "best_effort").isActive)
        // Only the sandbox sections count as a restart-worthy change.
        #expect(OpenShellSandboxSpec.sectionsFingerprint(yaml: yaml)
                == OpenShellSandboxSpec.sectionsFingerprint(yaml: yaml + "\n# comment\n"))
        #expect(OpenShellSandboxSpec.sectionsFingerprint(yaml: yaml)
                != OpenShellSandboxSpec.sectionsFingerprint(yaml: yaml.replacingOccurrences(of: "/tmp", with: "/var/tmp")))
    }

    @Test("A process section requires the strict sandbox (seccomp would otherwise be skipped)")
    func processForcesStrict() {
        var p = Profile(name: "ws", tool: .claude, authMode: .token)
        p.networkPolicy = "version: 1\nfilesystem_policy:\n  read_write: [/tmp]\n"
        #expect(!p.effectiveStrictSandbox)
        p.networkPolicy += "process:\n  run_as_user: ubuntu\n"
        #expect(p.policyHasProcessSection && p.effectiveStrictSandbox)
        p.networkPolicy = "version: 1\nprocess: null\n  # process: nested\n"
        #expect(!p.effectiveStrictSandbox)
    }

    // MARK: channel

    @Test("Hello pins the sentry; heartbeats in sequence raise nothing")
    func pinning() {
        let (b, g, tap) = connect(nil, hello())
        send(g, frame(["type": "heartbeat", "seq": 1, "t": 1]))
        send(g, frame(["type": "heartbeat", "seq": 2, "t": 2]))
        tap.waitFor { b.snapshot().lastFrameAt != nil && b.snapshot().connected }
        usleep(50_000)
        #expect(b.snapshot().connected)
        #expect(b.snapshot().kernel == "6.8.0-139-generic")
        #expect(tap.alarms().isEmpty)
        close(g)
    }

    @Test("A sequence gap is tampering; dropped events are an overflow warning")
    func gaps() {
        let (b, g, tap) = connect(nil, hello())
        send(g, frame(["type": "heartbeat", "seq": 10, "t": 1]))
        send(g, frame(["type": "heartbeat", "seq": 13, "t": 2, "dropped": 3, "rate_limited": 1]))
        tap.waitFor { tap.alarms().count >= 2 }
        #expect(tap.alarms("tampering").first.flatMap { KernelSentryTests.I($0["weight"]) } == 20)
        #expect(tap.alarms("sentry_overflow").count == 1)
        #expect(b.snapshot().dropped == 4)
        close(g)
    }

    @Test("A second sentry or a wrong secret is refused and raised")
    func impostors() {
        let (b, g, tap) = connect(nil, hello())
        tap.waitFor { b.snapshot().connected }
        let (_, g2, _) = connect(b, hello())                                 // same secret, channel taken
        tap.waitFor { !tap.alarms("tampering").isEmpty }
        #expect(tap.alarms("tampering").first.flatMap { KernelSentryTests.S($0["reason"]) }?.contains("second") == true)
        close(g); close(g2)
        tap.waitFor { !b.snapshot().connected }
        let (_, g3, _) = connect(b, hello(String(repeating: "cd", count: 32)))  // different secret after the pin
        tap.waitFor { tap.alarms("tampering").count >= 2 }
        #expect(tap.alarms("tampering").count >= 2)
        close(g3)
    }

    @Test("Reconnect: a proof, never the secret; replay, reuse and wrong proofs are refused")
    func reconnectProof() {
        let pin = FileManager.default.temporaryDirectory.appendingPathComponent("sentry-\(UUID()).pin")
        defer { try? FileManager.default.removeItem(at: pin) }
        let id = UUID()
        let b = SentryBridge(profileID: id, requirement: .hard, restoring: false, pinFile: pin)
        func reconnect(_ extra: [String: Any]) -> Data {
            frame(["type": "hello", "v": 1, "boot_id": "b", "kernel": "k", "module": "1"].merging(extra) { $1 })
        }
        let proof = { (n: Int) in SentryBridge.reconnectProof(secret: Self.secret, bootID: "b", conn: n) }
        let (_, g0, tap) = connect(b, hello())
        tap.waitFor { b.snapshot().connected }
        close(g0); tap.waitFor { !b.snapshot().connected }
        // Replaying the first hello (the secret, read from memory) is refused.
        let (_, g1, _) = connect(b, hello())
        tap.waitFor { tap.alarms("tampering").count >= 1 }
        #expect(tap.alarms("tampering").last.flatMap { KernelSentryTests.S($0["reason"]) }?.contains("replayed") == true)
        close(g1)
        // A wrong proof is refused; the right one is accepted.
        let (_, g2, _) = connect(b, reconnect(["conn": 1, "proof": String(repeating: "0", count: 64)]))
        tap.waitFor { tap.alarms("tampering").count >= 2 }
        close(g2)
        let (_, g3, _) = connect(b, reconnect(["conn": 1, "proof": proof(1)]))
        tap.waitFor { b.snapshot().connected }
        #expect(b.snapshot().connected && tap.alarms("tampering").count == 2)
        close(g3); tap.waitFor { !b.snapshot().connected }
        // Reusing an index, or carrying the secret on a reconnect, is refused.
        let (_, g4, _) = connect(b, reconnect(["conn": 1, "proof": proof(1)]))
        tap.waitFor { tap.alarms("tampering").count >= 3 }
        close(g4)
        let (_, g5, _) = connect(b, reconnect(["conn": 2, "proof": proof(2), "secret": Self.secret]))
        tap.waitFor { tap.alarms("tampering").count >= 4 }
        close(g5)
        #expect(tap.alarms("tampering").count == 4)
        // The pin survives a host restart for a restored VM, and not for a fresh boot.
        let restored = SentryBridge(profileID: id, requirement: .hard, restoring: true, pinFile: pin)
        let (_, g6, tap6) = connect(restored, reconnect(["conn": 2, "proof": proof(2)]))
        tap6.waitFor { restored.snapshot().connected }
        #expect(restored.snapshot().connected && tap6.alarms().isEmpty)
        close(g6)
        _ = SentryBridge(profileID: id, requirement: .hard, restoring: false, pinFile: pin)
        #expect(!FileManager.default.fileExists(atPath: pin.path))
    }

    @Test("Garbage on the port is refused and raised")
    func garbage() {
        let (b, g, tap) = connect(nil, frame(["type": "heartbeat", "seq": 1]))
        tap.waitFor { !tap.alarms().isEmpty }
        #expect(!b.snapshot().connected)
        #expect(tap.alarms("tampering").first.flatMap { KernelSentryTests.I($0["weight"]) } == 10)
        close(g)
    }

    @Test("Disarmed probes are tampering (once per episode)")
    func probes() {
        let (_, g, tap) = connect(nil, hello())
        send(g, frame(["type": "heartbeat", "seq": 1, "probes": ["armed": 9, "total": 9, "missed": 0]]))
        send(g, frame(["type": "heartbeat", "seq": 2, "probes": ["armed": 7, "total": 9, "missed": 0]]))
        send(g, frame(["type": "heartbeat", "seq": 3, "probes": ["armed": 7, "total": 9, "missed": 0]]))
        tap.waitFor { !tap.alarms("tampering").isEmpty }
        usleep(50_000)
        #expect(tap.alarms("tampering").count == 1)
        close(g)
    }

    @Test("Security-relevant events reach the timeline; exec / connect are only counted")
    func events() {
        let (b, g, tap) = connect(nil, hello())
        send(g, frame(["type": "event", "seq": 1, "t": 1, "kind": "exec", "pid": 10, "exe": "/usr/bin/ls"]))
        send(g, frame(["type": "event", "seq": 2, "t": 2, "kind": "module_load", "pid": 11, "detail": "evil.ko"]))
        send(g, frame(["type": "event", "seq": 3, "t": 3, "kind": "landlock_denied", "pid": 12, "path": "/etc/shadow", "access": "read_file"]))
        tap.waitFor { tap.events().count >= 2 }
        let ev = tap.events()
        #expect(ev.count == 2)
        #expect(ev.first { KernelSentryTests.S($0["kind"]) == "module_load" }.flatMap { KernelSentryTests.I($0["weight"]) } == 10)
        #expect(ev.first { KernelSentryTests.S($0["kind"]) == "landlock_denied" }.flatMap { KernelSentryTests.S($0["path"]) } == "/etc/shadow")
        tap.waitFor { b.snapshot().countedOnly["exec"] == 1 }
        #expect(b.snapshot().countedOnly["exec"] == 1)
        close(g)
    }

    @Test("Silence: warning, then tampering — but never while the VM isn't running")
    func silence() {
        let (b, g, tap) = connect(nil, hello())
        send(g, frame(["type": "heartbeat", "seq": 1, "t": 1]))
        tap.waitFor { b.snapshot().lastFrameAt != nil }
        let t0 = b.snapshot().lastFrameAt!
        b.checkLiveness(now: t0.addingTimeInterval(30), running: false)            // paused: resets the clock
        #expect(tap.alarms().isEmpty)
        let t1 = t0.addingTimeInterval(30)
        b.checkLiveness(now: t1.addingTimeInterval(6), running: true)
        #expect(tap.alarms("sentry_silent").count == 1)
        b.checkLiveness(now: t1.addingTimeInterval(16), running: true)
        #expect(tap.alarms("tampering").count == 1)
        b.checkLiveness(now: t1.addingTimeInterval(40), running: true)             // once per episode
        #expect(tap.alarms("tampering").count == 1)
        close(g)
    }

    @Test("A sentry that never connects: required → tampering, best effort → warning")
    func absent() {
        for (req, kind, weight) in [(KernelSentryMode.hard, "tampering", 20), (.bestEffort, "sentry_unavailable", 0)] {
            let b = SentryBridge(profileID: UUID(), requirement: req, restoring: false)
            let tap = Tap(); b.tap = { tap.add($0, $1) }
            b.checkLiveness(now: Date().addingTimeInterval(KernelSentryService.bootBudget + 1), running: true)
            #expect(tap.alarms(kind).first.flatMap { KernelSentryTests.I($0["weight"]) } == weight)
        }
    }

    @Test("Required but reported unavailable by the guest: a warning with the reason, not tampering")
    func unavailableWithReason() {
        let id = UUID()
        GuestSandboxStatusStore.shared.update(profileID: id, report: [
            "event": "sandbox_status", "filesystem": "off", "sentry": "unavailable",
            "sentry_reason": "no module for 6.8.0-142-generic",
        ])
        defer { GuestSandboxStatusStore.shared.reset(profileID: id) }
        let b = SentryBridge(profileID: id, requirement: .hard, restoring: false)
        let tap = Tap(); b.tap = { tap.add($0, $1) }
        b.checkLiveness(now: Date().addingTimeInterval(KernelSentryService.bootBudget + 1), running: true)
        #expect(tap.alarms("tampering").isEmpty)
        let a = tap.alarms("sentry_unavailable").first
        #expect(a.flatMap { KernelSentryTests.I($0["weight"]) } == 0)
        #expect(a.flatMap { KernelSentryTests.S($0["reason"]) }?.contains("6.8.0-142-generic") == true)
    }

    @Test("Cross-check with the attestor's digest and status catches an impostor")
    func crossCheck() {
        let (b, g, tap) = connect(nil, hello())
        tap.waitFor { b.snapshot().connected }
        b.crossCheck(guestSentry: "running", digest: SentryBridge.sha256Hex(Self.secret))
        #expect(tap.alarms().isEmpty)
        b.crossCheck(guestSentry: "running", digest: String(repeating: "0", count: 64))
        #expect(tap.alarms("tampering").count == 1)
        b.crossCheck(guestSentry: "unavailable", digest: nil)
        #expect(tap.alarms("tampering").count == 2)
        close(g)
    }

    @Test("phase: boot is honoured only within the boot budget")
    func bootPhaseBudget() {
        let (b, g, tap) = connect(nil, hello())
        send(g, frame(["type": "event", "seq": 1, "kind": "module_load", "signed": false, "phase": "boot"]))
        tap.waitFor { b.snapshot().eventsSeen >= 1 }
        usleep(50_000)
        #expect(tap.events().isEmpty)
        b.backdateAttach(by: KernelSentryService.bootBudget + 10)
        send(g, frame(["type": "event", "seq": 2, "kind": "module_load", "signed": false, "phase": "boot"]))
        tap.waitFor { !tap.events().isEmpty }
        #expect(tap.events().first.flatMap { KernelSentryTests.I($0["weight"]) } == 10)
        #expect(tap.alarms("sentry_boot_phase").count == 1)
        close(g)
    }

    @Test("phase: shutdown is honoured only briefly")
    func shutdownPhaseBudget() {
        let (b, g, tap) = connect(nil, hello())
        send(g, frame(["type": "event", "seq": 1, "kind": "mount", "pid": 900, "phase": "shutdown"]))
        tap.waitFor { b.snapshot().eventsSeen >= 1 }
        usleep(50_000)
        #expect(tap.events().isEmpty)
        b.backdateShutdown(by: KernelSentryService.shutdownBudget + 5)
        send(g, frame(["type": "event", "seq": 2, "kind": "mount", "pid": 900, "phase": "shutdown"]))
        tap.waitFor { !tap.events().isEmpty }
        #expect(tap.events().first.flatMap { KernelSentryTests.I($0["weight"]) } == 2)
        #expect(tap.alarms("sentry_shutdown_phase").count == 1)
        close(g)
    }

    @Test("A pending guest status is neither recorded nor cross-checked")
    func pendingStatus() {
        let (b, g, tap) = connect(nil, hello())
        tap.waitFor { b.snapshot().connected }
        b.crossCheck(guestSentry: "pending", digest: nil)
        #expect(tap.alarms().isEmpty)
        let id = UUID()
        GuestSandboxStatusStore.shared.update(profileID: id, report: ["event": "sandbox_status", "filesystem": "pending", "sentry": "pending"])
        #expect(GuestSandboxStatusStore.shared.status(for: id) == nil)
        close(g)
    }

    @Test("Event classification: meaning and mode, not raw syscalls")
    func classification() {
        typealias K = KernelSentryService
        #expect(K.classify("bpf_load")?.weight == 10)
        #expect(K.classify("ptrace")?.category == "privilege")
        #expect(K.classify("unshare")?.weight == 2)
        #expect(K.classify("file_open_denied")?.category == "sandbox_denial")
        #expect(K.classify("exec") == nil && K.classify("connect") == nil)
        // Raw credential calls fire for every privilege drop: counted only.
        #expect(K.classify("setuid") == nil && K.classify("setgid") == nil && K.classify("capset") == nil)
        // A real gain: visible without strict (sudo is allowed), tampering under strict.
        #expect(K.classify("cred_gain", [:], strict: false)?.weight == 0)
        #expect(K.classify("cred_gain", [:], strict: true)?.weight == 20)
        // Signed modules are routine (docker); an unsigned attempt is not.
        #expect(K.classify("module_load", ["signed": true]) == nil)
        #expect(K.classify("module_load", ["signed": false])?.weight == 10)
        // Lockdown only rises: the loader's own raise is quiet, lowering is not.
        #expect(K.classify("lockdown_change_attempt", ["lowering": false, "result": 0]) == nil)
        #expect(K.classify("lockdown_change_attempt", ["lowering": true])?.weight == 10)
        #expect(K.classify("lockdown_change_attempt", ["result": -1])?.weight == 10)
        // Bromure's own boot-time helpers and the poweroff never raise anything.
        #expect(K.classify("module_load", ["phase": "boot", "signed": false]) == nil)
        #expect(K.classify("mount", ["phase": "shutdown"]) == nil)
        // Under strict, only a gain inside the sandbox is tampering.
        #expect(K.classify("cred_gain", ["sandboxed": false], strict: true)?.weight == 0)
        #expect(K.classify("cred_gain", ["sandboxed": true], strict: true)?.weight == 20)
        // systemd (pid 1) loads unit BPF and mounts routinely.
        #expect(K.classify("bpf_load", ["pid": 1]) == nil && K.classify("bpf_load", ["pid": 900])?.weight == 10)
        #expect(K.classify("mount", ["pid": 1]) == nil && K.classify("mount", ["pid": 900])?.weight == 2)
    }

    @Test("Sandbox denials: each one is a row; a burst from one program is probing")
    func sandboxDenials() {
        #expect(KernelSentryService.classify("sandbox_denied")?.category == "sandbox_denial")
        #expect(KernelSentryService.classify("seccomp_denied")?.weight == 3)
        let (b, g, tap) = connect(nil, hello())
        send(g, frame(["type": "event", "seq": 1, "kind": "sandbox_denied", "op": "create", "path": "/etc/x",
                       "exe": "/usr/bin/python3", "pid": 42, "sandboxed": true]))
        tap.waitFor { tap.events().count >= 1 }
        #expect(tap.events().first.flatMap { KernelSentryTests.S($0["path"]) } == "/etc/x")
        #expect(tap.alarms("sandbox_probing").isEmpty)
        // 25 more from the same program within the window (one deduped frame of 25).
        send(g, frame(["type": "event", "seq": 2, "kind": "sandbox_denied", "op": "open_read", "path": "/root/.ssh/id_rsa",
                       "exe": "/usr/bin/python3", "pid": 42, "count": 25, "sandboxed": true]))
        tap.waitFor { !tap.alarms("sandbox_probing").isEmpty }
        #expect(tap.alarms("sandbox_probing").first.flatMap { KernelSentryTests.I($0["weight"]) } == 10)
        _ = b
        close(g)
    }

    @Test("Identical denials from new processes fold into one row, summed when the window closes")
    func denialRepeatsFold() throws {
        let b = SentryBridge(profileID: UUID(), requirement: .bestEffort, restoring: false)
        let tap = Tap(); b.tap = { tap.add($0, $1) }
        let t0 = Date()
        func rows() -> [[String: AnyJSON]] { tap.all.filter { $0.0 == "sentry.event" }.map(\.1) }
        // A shell loop: 30 `head` processes reading the same denied file.
        for i in 0..<30 {
            b._testDenial(["kind": "sandbox_denied", "op": "open_read", "path": "/var/lib/dpkg/status",
                           "comm": "head", "pid": 100 + i], now: t0 + Double(i) * 0.1)
        }
        // A different target from the same program is its own row.
        b._testDenial(["kind": "sandbox_denied", "op": "open_read", "path": "/opt", "comm": "head", "pid": 200], now: t0 + 4)
        #expect(rows().count == 2)
        // The probing alarm still counted every one of them.
        #expect(!tap.alarms("sandbox_probing").isEmpty)
        b._testFlush(now: t0 + 30)
        #expect(rows().count == 2)                                   // window still open
        b._testFlush(now: t0 + 61)
        let folded = try #require(rows().last)
        if case .bool(true)? = folded["repeat"] {} else { Issue.record("not marked as a repeat") }
        #expect(KernelSentryTests.I(folded["count"]) == 29 && KernelSentryTests.I(folded["processes"]) == 29)
        let row = try #require(SecurityTimeline.map(profileID: UUID(), eventType: "sentry.event", eventData: folded, now: Date()))
        #expect(row.condition == "head — open_read /var/lib/dpkg/status — ×29 more in the last minute, from 29 processes")
        // A lone denial leaves no summary behind.
        b._testFlush(now: t0 + 200)
        #expect(rows().count == 3)
        // After the window, the same denial shows again at once.
        b._testDenial(["kind": "sandbox_denied", "op": "open_read", "path": "/var/lib/dpkg/status", "comm": "head", "pid": 999],
                      now: t0 + 201)
        #expect(rows().count == 4 && KernelSentryTests.I(rows().last?["pid"]) == 999)
    }

    @Test("Sandbox tallies reach the timeline every few minutes, sooner when denials grow")
    func sandboxTallies() {
        let b = SentryBridge(profileID: UUID(), requirement: .bestEffort, restoring: false)
        let tap = Tap(); b.tap = { tap.add($0, $1) }
        let t0 = Date()
        b._testTallies(["allowed_file_ops": 100, "denied_file_ops": 0, "denied_syscalls": 0], now: t0)
        #expect(tap.all.filter { $0.0 == "sandbox.activity" }.count == 1)
        b._testTallies(["allowed_file_ops": 200, "denied_file_ops": 0, "denied_syscalls": 0], now: t0 + 60)
        #expect(tap.all.filter { $0.0 == "sandbox.activity" }.count == 1)          // not due yet
        b._testTallies(["allowed_file_ops": 210, "denied_file_ops": 2, "denied_syscalls": 0], now: t0 + 70)
        #expect(tap.all.filter { $0.0 == "sandbox.activity" }.count == 2)          // denials grew
        b._testTallies(["allowed_file_ops": 900, "denied_file_ops": 2, "denied_syscalls": 0], now: t0 + 400)
        #expect(tap.all.filter { $0.0 == "sandbox.activity" }.count == 3)          // interval elapsed
    }
}
