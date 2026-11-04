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

    /// The guest side, on a fake /proc: a tmux server, its tabs' shells, agents
    /// and their helpers, and everything that must be left alone.
    @Test("an OOM reaches agents and their helpers first, never a tab's shell, tmux or the supervisor",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func sacrificeOrder() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/AgentCoding/Resources/vm-setup")
        let script = #"""
        import importlib.util, os, sys, tempfile
        s = importlib.util.spec_from_file_location("agentd", "bromure-agentd.py")
        m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
        root = tempfile.mkdtemp()
        procs = {1: ("systemd", 0), 334: ("python3", 1), 3546: ("tmux: server", 1), 3600: ("bash", 3546),
                 4399: ("claude (odd) name", 3600), 4500: ("python3", 4399), 4501: ("node", 4500),
                 3601: ("zsh", 3546), 3602: ("tmux: client", 3601), 1365: ("dockerd", 1)}
        for pid, (comm, ppid) in procs.items():
            d = os.path.join(root, str(pid)); os.mkdir(d)
            open(os.path.join(d, "stat"), "w").write("%d (%s) S %d 0 0\n" % (pid, comm, ppid))
            open(os.path.join(d, "oom_score_adj"), "w").write("0")
        os.mkdir(os.path.join(root, "self"))
        seen = m.oom_sacrifice_pass(set(), root)
        print("targets", sorted(seen))
        print("marked", sorted(p for p in procs if open(os.path.join(root, str(p), "oom_score_adj")).read() == "300"))
        open(os.path.join(root, "4399", "oom_score_adj"), "w").write("7")
        m.oom_sacrifice_pass(seen, root)
        print("rewritten", open(os.path.join(root, "4399", "oom_score_adj")).read() != "7")
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
        #expect(out.contains("targets [4399, 4500, 4501]"), Comment(rawValue: out))
        #expect(out.contains("marked [4399, 4500, 4501]"), Comment(rawValue: out))
        #expect(out.contains("rewritten False"), Comment(rawValue: out))
        #expect(out.contains("psi ('12.50', '3.25') ('0', '0')"), Comment(rawValue: out))
    }
}
