import Foundation
import Testing
@testable import bromure_ac

@Suite("A guest that stops proving it can run a process is reported")
struct GuestLivenessTests {
    /// `#expect` can't take a mutating call.
    final class Watch {
        var liveness = GuestLiveness()
        func see(_ beat: String?, running: Bool, now: TimeInterval) -> Bool {
            liveness.observe(beat, running: running, now: now)
        }
    }

    @Test("silent only once the beat has stopped changing for the whole patience")
    func silence() {
        let l = Watch()
        #expect(!l.see("1 1 5", running: true, now: 0))
        #expect(!l.see("1 1 5", running: true, now: GuestLiveness.patience - 1))
        #expect(l.see("1 1 5", running: true, now: GuestLiveness.patience))
    }

    @Test("each new beat restarts the wait, and one brings a silent guest back")
    func recovery() {
        let l = Watch()
        _ = l.see("1 1 5", running: true, now: 0)
        #expect(!l.see("1 2 5", running: true, now: 100))
        #expect(!l.see("1 2 5", running: true, now: 100 + GuestLiveness.patience - 1))
        #expect(l.see("1 2 5", running: true, now: 100 + GuestLiveness.patience))
        #expect(!l.see("1 3 5", running: true, now: 1000))
    }

    @Test("a guest that never beat, like an older agentd, is never silent")
    func neverBeat() {
        let l = Watch()
        #expect(!l.see(nil, running: true, now: 0))
        #expect(!l.see(nil, running: true, now: 100_000))
        #expect(!l.see("", running: true, now: 200_000))
    }

    @Test("a beat that goes missing doesn't restart the wait")
    func fileGone() {
        let l = Watch()
        _ = l.see("1 1 5", running: true, now: 0)
        #expect(l.see(nil, running: true, now: GuestLiveness.patience))
    }

    @Test("a paused VM owes no beat, and gets the whole patience when it resumes")
    func paused() {
        let l = Watch()
        _ = l.see("1 1 5", running: true, now: 0)
        #expect(!l.see("1 1 5", running: false, now: 10_000))
        #expect(!l.see("1 1 5", running: true, now: 10_000 + GuestLiveness.patience - 1))
        #expect(l.see("1 1 5", running: true, now: 10_000 + GuestLiveness.patience))
    }

    @MainActor @Test("the store keeps the latest way to reboot, and clearing forgets the workspace")
    func store() {
        let s = GuestLivenessStore()
        let id = UUID()
        var used = ""
        s.mark(id, unresponsive: true) { used = "first" }
        s.mark(id, unresponsive: true) { used = "second" }
        #expect(s.isUnresponsive(id))
        s.forceReboot(of: id)?()
        #expect(used == "second")
        s.mark(id, unresponsive: false) {}
        #expect(!s.isUnresponsive(id))
        #expect(s.forceReboot(of: id) == nil)
    }

    @MainActor @Test("a fat client's report follows the server, and leaves with the controller")
    func fatClient() {
        let c = RemoteHostController(host: RemoteHost(name: "t", address: "127.0.0.1", port: 1, user: "nobody"))
        let store = GuestLivenessStore.shared
        let a = UUID(), b = UUID()
        c.noteUnresponsive([a, b])
        #expect(store.isUnresponsive(a) && store.isUnresponsive(b))
        c.noteUnresponsive([b])          // recovered
        #expect(!store.isUnresponsive(a) && store.isUnresponsive(b))
        c.stop()                         // the window closes while b is flagged
        #expect(!store.isUnresponsive(b))
    }

    @Test("what iOS shares doesn't need the store it doesn't compile")
    func iosBuilds() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["AgentSessions.swift", "FatClientController.swift"] {
            let source = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/\(file)"), encoding: .utf8)
            var depth = 0, macOS = [Bool]()
            for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("#if ") { macOS.append(t.contains("os(macOS)")); depth += 1 }
                else if t.hasPrefix("#endif") { macOS.removeLast(); depth -= 1 }
                else if t.contains("GuestLivenessStore") { #expect(macOS.contains(true), Comment(rawValue: "\(file): \(t)")) }
            }
            #expect(depth == 0)
        }
    }

    @Test("agentd beats only when a process ran, and each beat differs from the last")
    func agentdBeat() async throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let setup = top.appendingPathComponent("Sources/AgentCoding/Resources/vm-setup").path
        let outbox = FileManager.default.temporaryDirectory.appendingPathComponent("beat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outbox) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-c", """
            import importlib.util, os, sys
            s = importlib.util.spec_from_file_location("agentd", "bromure-agentd.py")
            m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
            m.OUTBOX = sys.argv[1]
            beat = os.path.join(m.OUTBOX, "liveness.txt")
            print("missing binary:", m.liveness_probe(("/nonexistent/x",)) is None)
            print("failing binary:", m.liveness_probe(("/usr/bin/false",)) is None)
            print("no beat:", m.liveness_beat(1, probe=lambda: None) is False, os.path.exists(beat))
            print("beat 1:", m.liveness_beat(1)); a = open(beat).read()
            print("beat 2:", m.liveness_beat(2)); b = open(beat).read()
            print("changed:", a != b, len(b.split()))
            print("tmp left:", [n for n in os.listdir(m.OUTBOX) if n != "liveness.txt"])
            print("service listed:", "liveness_service" in open("bromure-agentd.py").read().split("services = [")[1])
            """, outbox.path]
        p.currentDirectoryURL = URL(fileURLWithPath: setup)
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(decoding: data, as: UTF8.self)
        for line in ["missing binary: True", "failing binary: True", "no beat: True False", "beat 1: True",
                     "beat 2: True", "changed: True 3", "tmp left: []", "service listed: True"] {
            #expect(out.contains(line), Comment(rawValue: out))
        }
    }
}
