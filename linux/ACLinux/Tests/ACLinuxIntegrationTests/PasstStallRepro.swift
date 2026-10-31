import Foundation
import Testing
@testable import ACLinux

/// The passt stall through our switch (linux/PASST_STALL_REPORT.md), opt-in
/// (BROMURE_PASST_REPRO=<runs>, default 30): one microvm at MTU 1500 uploads
/// 256 MiB per run to the host's LAN address; a run whose send makes no
/// progress for 10 s is a stall. It was 5/30 before the dedicated reader.
@Suite("passt stall repro", .serialized,
       .enabled(if: NetEnv.passtReady && ProcessInfo.processInfo.environment["BROMURE_PASST_REPRO"] != nil))
struct PasstStallRepro {
    @Test func uploads() async throws {
        let n = Int(ProcessInfo.processInfo.environment["BROMURE_PASST_REPRO"] ?? "") ?? 30
        let lan = try #require(hostLANAddress())
        let base = 46_000 + Int.random(in: 0..<400) * 8
        let svc = try await startServices(ip: lan, base: base)
        defer { stopHelper(svc) }
        let passt = try await PasstUplink.start(PasstUplink.Config(logPath: "/dev/null"))
        let sw = TestSwitch(uplink: passt, gateway: "192.168.64.1", dns: "192.168.64.1", mtu: { _ in 1500 })
        let listener = try await VsockListener.shared(port: agentPort)
        let a = try await SwitchedVM.make(.microvm, mac: "52:54:00:e1:00:01", on: sw, listener: listener, tag: "repro", mtu: 1500)
        _ = try await a.boot()
        var stalls = 0, mbps: [Double] = []
        for _ in 0..<n {
            let r = try await shell(a.conns, """
                python3 - <<'PY'
                import socket, time
                s = socket.create_connection(("\(lan)", \(base)), timeout=10); buf = bytes(1 << 20); t = time.time()
                try:
                    for _ in range(256): s.sendall(buf)
                    s.shutdown(socket.SHUT_WR); got = int(s.recv(64)); print("OK %.0f" % (got / (time.time() - t) / 1e6))
                except socket.timeout: print("STALL")
                PY
                """, timeout: 60)
            if let v = r.output.split(separator: " ").last.flatMap({ Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }),
               r.output.contains("OK") { mbps.append(v) } else { stalls += 1 }
        }
        let med = mbps.sorted().isEmpty ? 0 : mbps.sorted()[mbps.count / 2]
        let w = passt.routeBacklogPeak
        print("REPRO passt stall: \(stalls)/\(n) stalled; median \(Int(med)) MB/s; passt pauses \(passt.stats.inboundPauses), "
              + "route waits \(passt.routeWaits), backlog peak \(w.frames) frames / \(w.bytes) bytes; port dropped \(a.port.dropped)")
        #expect(stalls == 0)
        await a.tearDown(listener)
        sw.stop()
        await passt.close()
    }
}
