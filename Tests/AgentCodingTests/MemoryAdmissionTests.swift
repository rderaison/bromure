import Foundation
import Testing
@testable import bromure_ac

@Suite("Memory admission")
struct MemoryAdmissionTests {
    private let gb = 1_048_576
    private func memory(free: Double, total: Int = 8, some: Double = 0, full: Double = 0) -> GuestMemorySnapshot {
        GuestMemorySnapshot(availableKB: Int(free * 1_048_576), totalKB: total * 1_048_576,
                            pressureSome: some, pressureFull: full)
    }

    @Test("an agent is let in while it fits, and refused once it doesn't")
    func fits() {
        #expect(MemoryAdmission.decide(memory(free: 4), otherAgents: 3, launchingNow: 0) == .admit)
        if case .tooLittleMemory = MemoryAdmission.decide(memory(free: 1), otherAgents: 3, launchingNow: 0) {} else {
            Issue.record("1 GB free of 8 should be refused")
        }
    }

    @Test("agents still starting count against what's free, so a burst can't all read the same number")
    func burst() {
        #expect(MemoryAdmission.decide(memory(free: 2.5), otherAgents: 1, launchingNow: 0) == .admit)
        #expect(MemoryAdmission.decide(memory(free: 2.5), otherAgents: 3, launchingNow: 2) != .admit)
    }

    @Test("pressure refuses even with memory nominally free")
    func pressure() {
        #expect(MemoryAdmission.decide(memory(free: 4, full: 6), otherAgents: 1, launchingNow: 0) == .underPressure)
        #expect(MemoryAdmission.decide(memory(free: 4, some: 35), otherAgents: 1, launchingNow: 0) == .underPressure)
        #expect(MemoryAdmission.decide(memory(free: 4, some: 5, full: 1), otherAgents: 1, launchingNow: 0) == .admit)
    }

    @Test("the only agent on a machine is never refused: nothing could be closed to make room")
    func onlyAgent() {
        #expect(MemoryAdmission.decide(memory(free: 0.2, total: 2, full: 50), otherAgents: 0, launchingNow: 0) == .admit)
    }

    @Test("no report from the guest refuses nothing")
    func unknown() {
        #expect(MemoryAdmission.decide(nil, otherAgents: 5, launchingNow: 0) == .admit)
        #expect(MemoryAdmission.decide(GuestMemorySnapshot(availableKB: 0, totalKB: 0, pressureSome: 0, pressureFull: 0),
                                       otherAgents: 5, launchingNow: 0) == .admit)
    }

    @Test("a big machine keeps a proportional reserve")
    func reserve() {
        #expect(MemoryAdmission.decide(memory(free: 2.5, total: 32), otherAgents: 1, launchingNow: 0) == .admit)
        #expect(MemoryAdmission.decide(memory(free: 2.0, total: 32), otherAgents: 1, launchingNow: 0) != .admit)
    }

    @Test("a refusal says what happened and what to do; an admission says nothing")
    func wording() throws {
        #expect(MemoryAdmission.refusal(.admit) == nil)
        let text = try #require(MemoryAdmission.refusal(.tooLittleMemory(availableKB: 1_572_864, totalKB: 8 * gb)))
        #expect(text.contains("1.5 GB") && text.contains("8 GB") && text.contains("End another session"))
    }

    /// The guest side, on a fake /proc: agentd, a tmux server, what runs under
    /// them, and what must be left to the killer's usual judgement.
    @Test("an OOM spares agentd and tmux, and everything else is left to size",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func oomOrder() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AgentCoding/Resources/vm-setup")
        let script = #"""
        import importlib.util, os, tempfile
        s = importlib.util.spec_from_file_location("agentd", "bromure-agentd.py")
        m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
        root = tempfile.mkdtemp()
        # Started after protection: all of it inherited -500.
        below = {3600: ("bash", 3546), 4399: ("claude (odd) name", 3600), 4500: ("python3", 4399),
                 3601: ("zsh", 3546), 3602: ("tmux: client", 3601), 3700: ("claude", 3546),
                 335: ("ssh-bridge", 334)}
        others = {1: ("systemd", 0), 2634: ("clickhouse-server", 2609), 2609: ("containerd-shim", 1),
                  7000: ("detached", 1)}
        roots = {334: ("python3", 1), 3546: ("tmux: server", 1)}
        adj = lambda p: open(os.path.join(root, str(p), "oom_score_adj")).read().strip()
        def put(p, v): open(os.path.join(root, str(p), "oom_score_adj"), "w").write(str(v))
        for table, value in ((below, -500), (others, 0), (roots, 0)):
            for pid, (comm, ppid) in table.items():
                d = os.path.join(root, str(pid)); os.mkdir(d)
                open(os.path.join(d, "stat"), "w").write("%d (%s) S %d 0 0\n" % (pid, comm, ppid))
                put(pid, value)
        open(os.path.join(root, "3546", "cmdline"), "w").write("tmux\0new-session\0-d\0-s\0bromure\0")
        # Started under a tab: a server of the agent's own, and a chosen score.
        for pid, comm, ppid, value in ((8000, "tmux: server", 1, 0), (8001, "rootless-shim", 3600, -900)):
            d = os.path.join(root, str(pid)); os.mkdir(d)
            open(os.path.join(d, "stat"), "w").write("%d (%s) S %d 0 0\n" % (pid, comm, ppid))
            open(os.path.join(d, "cmdline"), "w").write("tmux\0new-session\0-s\0mine\0")
            put(pid, value)
        os.mkdir(os.path.join(root, "self"))
        calls = []
        def protect(pid):
            calls.append(pid); put(pid, m.OOM_PROTECT_ADJ); return True
        print("kept", m.oom_order_pass(334, True, protect, root))
        print("protected", sorted(calls), adj(334), adj(3546))
        print("below", sorted({adj(p) for p in below}))
        print("others", sorted({adj(p) for p in others}))
        print("own server", adj(8000), "chosen", adj(8001))
        calls.clear(); m.oom_order_pass(334, True, protect, root)
        print("again", calls)
        # No privilege: asks once, stops asking, and still neutralises.
        put(334, 0); put(3546, 0); put(4399, -500); calls.clear()
        def refuse(pid):
            calls.append(pid); return False
        kept = m.oom_order_pass(334, True, refuse, root)
        print("refused", kept, len(calls), adj(4399))
        calls.clear(); print("stopped", m.oom_order_pass(334, False, refuse, root), calls)
        psi = os.path.join(root, "psi")
        open(psi, "w").write("some avg10=12.50 avg60=0.00 avg300=0.00 total=1\nfull avg10=3.25 avg60=0.00 avg300=0.00 total=1\n")
        print("psi", m.memory_pressure(psi), m.memory_pressure(os.path.join(root, "absent")))
        """#
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.currentDirectoryURL = src
        p.arguments = ["-c", script]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(out.contains("kept True"), Comment(rawValue: out))
        #expect(out.contains("protected [334, 3546] -500 -500"), Comment(rawValue: out))
        #expect(out.contains("below ['0']"), Comment(rawValue: out))
        #expect(out.contains("others ['0']"), Comment(rawValue: out))
        #expect(out.contains("own server 0 chosen -900"), Comment(rawValue: out))
        #expect(out.contains("again []"), Comment(rawValue: out))
        #expect(out.contains("refused False 1 0"), Comment(rawValue: out))
        #expect(out.contains("stopped False []"), Comment(rawValue: out))
        #expect(out.contains("psi ('12.50', '3.25') ('0', '0')"), Comment(rawValue: out))
    }
}
