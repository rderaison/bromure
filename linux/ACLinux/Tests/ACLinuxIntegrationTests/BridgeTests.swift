import Foundation
import NIOCore
import Testing
import ACLinux

enum NetEnv {
    static let env = ProcessInfo.processInfo.environment
    /// linux/test-network.sh runs the tap suite inside its namespaces.
    static var tapReady: Bool { Env.ready && env["BROMURE_NET_TEST"] == "1" }
    /// passt needs no setup: it runs wherever the KVM tests do (but not in
    /// test-network.sh's namespaces, which have no real LAN).
    static var passtReady: Bool {
        Env.ready && env["BROMURE_NET_TEST"] == nil && FileManager.default.isExecutableFile(atPath: "/usr/bin/passt")
    }
    static var tap: String { env["BROMURE_TAP"] ?? "bromure0" }
    static var dns: String { env["BROMURE_TEST_DNS"] ?? "192.168.64.1" }
    static var wanLog: String? { env["BROMURE_WAN_LOG"] }
    /// test-network.sh pings `<name>.target`'s IP from the wan side and
    /// writes `<name>.result`: whether a LAN machine can open a flow to a VM.
    static var probeDir: String? { env["BROMURE_PROBE_DIR"] }
    /// ip:base of net-test-services.py beyond the uplink.
    static var services: (String, Int)? {
        guard let s = env["BROMURE_SERVICES"], let c = s.lastIndex(of: ":"),
              let b = Int(s[s.index(after: c)...]) else { return nil }
        return (String(s[..<c]), b)
    }
}

/// One VM on a TestSwitch port: workspace, stream port, VM, its 5800 stream.
struct SwitchedVM {
    var ws: BootTests.Workspace
    let mac: String
    let port: StreamPort
    let vm: QEMUMachine
    let conns: ConnQueue
    let label: String

    /// `mtu`: what the host tells agentd to set on the guest NIC
    /// (/mnt/bromure-meta/mtu; agentd's default is macOS's 1280 VPN clamp).
    /// The daemon's rule (PasstUplink.Config.mtu): 65520 behind passt, except
    /// VPN profiles, which keep the macOS value; UDP isn't re-segmented.
    static func make(_ machine: QEMUMachineConfig.MachineType, mac: String, on sw: TestSwitch,
                     listener: VsockListener, tag: String, mtu: Int? = nil,
                     queueFrames: Int = FramePortCore.defaultQueueFrames) async throws -> SwitchedVM {
        var ws = try BootTests.Workspace(machine: machine)
        if let mtu { try "\(mtu)\n".write(toFile: ws.dir + "/meta/mtu", atomically: true, encoding: .utf8) }
        let sock = ws.dir + "/run/net.sock"
        ws.config.network = .stream(socketPath: sock)
        ws.config.macAddress = mac
        let port = try await StreamPort.listen(path: sock, queueFrames: queueFrames)
        sw.attach(port, mac: mac)
        let conns = ConnQueue(await listener.connections(from: ws.cid))
        return SwitchedVM(ws: ws, mac: mac, port: port, vm: QEMUMachine(config: ws.config), conns: conns,
                          label: "[\(tag) \(machine.rawValue) cid \(ws.cid)]")
    }

    /// Starts the VM; returns the time to agentd's first dial.
    func boot() async throws -> Duration {
        let t0 = ContinuousClock.now
        try await vm.start()
        let first = await next(conns, timeout: .seconds(150))
        if first == nil {
            func tail(_ p: String) -> String {
                ((try? String(contentsOfFile: p, encoding: .utf8)) ?? "(none)").split(separator: "\n").suffix(15).joined(separator: "\n")
            }
            print("DIAG \(label) serial:\n\(tail(ws.dir + "/run/serial.log"))\nDIAG agentd.log:\n\(tail(ws.dir + "/outbox/agentd.log"))"
                  + "\nDIAG qemu.log:\n\(tail(ws.dir + "/run/qemu.log"))\nDIAG stream port connects=\(port.connects)")
        }
        try #require(first != nil, "\(label) agentd never dialed")
        await first?.close()
        return ContinuousClock.now - t0
    }

    func tearDown(_ listener: VsockListener) async {
        await vm.stop(timeout: .seconds(20))
        await port.close()
        await listener.forget(cid: ws.cid)
        ws.cleanUp()
    }
}

@Suite("Network bridge over a tap (in test-network.sh's netns)", .serialized, .enabled(if: NetEnv.tapReady))
struct TapBridgeTests {
    @Test("lease over the stream port, ping from the host side, masqueraded egress, throughput",
          arguments: [QEMUMachineConfig.MachineType.q35, .microvm])
    func bridge(machine: QEMUMachineConfig.MachineType) async throws {
        let tap = try TapUplink.open(name: NetEnv.tap)
        let sw = TestSwitch(uplink: tap, gateway: "192.168.64.1", dns: NetEnv.dns)
        let listener = try await VsockListener.shared(port: agentPort)
        // q35 at the tap's MTU (test-network.sh makes it 65520), microvm at 1500.
        let mtu = machine == .q35 ? tap.mtu : 1500
        let v = try await SwitchedVM.make(machine, mac: "52:54:00:b0:00:01", on: sw, listener: listener, tag: "tap",
                                          mtu: mtu)
        let wanBefore = NetEnv.wanLog.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }?.count ?? 0

        let t0 = ContinuousClock.now
        let tDial = try await v.boot()
        let mac = macBytes(v.mac)
        let acked = try #require(sw.dhcp.ackedAt(mac), "\(v.label) no DHCPREQUEST answered")
        print("TIMING \(v.label) DHCP ACK at \(ms(acked - t0)), agentd dial on :\(agentPort) at \(ms(tDial))")
        #expect(tDial < .seconds(30), "\(v.label) the network-online stall is back")
        let guestIP = ipString(sw.dhcp.lease(for: mac))

        // Host side -> guest.
        let ping = Process()
        ping.executableURL = URL(fileURLWithPath: "/usr/bin/ping")
        ping.arguments = ["-c", "3", "-i", "0.2", "-W", "2", guestIP]
        ping.standardOutput = FileHandle.nullDevice
        try ping.run()
        ping.waitUntilExit()
        #expect(ping.terminationStatus == 0, "\(v.label) host could not ping \(guestIP)")

        // A LAN machine routing the VM subnet through this host can't reach
        // the VM: setup-network.sh drops forwarded flows toward the tap.
        if let probe = NetEnv.probeDir {
            func probeFromLAN(_ name: String) async throws -> String {
                let base = "\(probe)/\(name)"
                try guestIP.write(toFile: base + ".target", atomically: true, encoding: .utf8)
                for _ in 0..<100 {
                    let r = ((try? String(contentsOfFile: base + ".result", encoding: .utf8)) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !r.isEmpty { return r }
                    try await Task.sleep(for: .milliseconds(100))
                }
                return "no answer"
            }
            let control = try await probeFromLAN("\(machine.rawValue).control")
            let real = try await probeFromLAN(machine.rawValue)
            print("INBOUND \(v.label) a LAN host pinging \(guestIP) through this host: \(real) (with the drop rule overridden: \(control))")
            #expect(control == "reachable", "\(v.label) the control probe didn't get through: \(control)")
            #expect(real == "unreachable", "\(v.label) LAN -> VM was \(real)")
        }

        // Guest -> beyond the uplink, masqueraded (test-network.sh's wan side).
        let r = try await shell(v.conns, """
            ip -4 -br addr show scope global; ip -4 route show default; \\
            python3 -c "import socket; socket.socket(socket.AF_INET, socket.SOCK_DGRAM).sendto(b'\\\\x12\\\\x34\\\\x01\\\\x00\\\\x00\\\\x01\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x00\\\\x08bromure1\\\\x04test\\\\x00\\\\x00\\\\x01\\\\x00\\\\x01', ('\(NetEnv.dns)', 53))"
            """)
        #expect(r.exitCode == 0 && r.output.contains("\(guestIP)/24") && r.output.contains("default via 192.168.64.1"),
                "\(v.label) \(r.output)")
        if let wanLog = NetEnv.wanLog {
            var seen = ""
            for _ in 0..<100 where seen.isEmpty {
                seen = String(((try? String(contentsOfFile: wanLog, encoding: .utf8)) ?? "").dropFirst(wanBefore))
                if seen.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
            }
            #expect(!seen.isEmpty, "\(v.label) no guest datagram reached the far side")
            print("NAT \(v.label) beyond the uplink: \(seen.split(separator: "\n").first ?? "")")
        }

        if let (host, base) = NetEnv.services {
            let cpu0 = selfCPUSeconds()
            let p = try await shell(v.conns, probeScript(host: host, base: base), timeout: 120)
            let cpu = selfCPUSeconds() - cpu0
            #expect(p.exitCode == 0, "\(v.label) probe: \(p.output)")
            print("PERF \(v.label) tap, guest MTU \(mtu): \(p.output.replacingOccurrences(of: "\n", with: " | ")) "
                  + "| switch-process CPU \(String(format: "%.2f", cpu)) s")
        }
        #expect(v.port.dropped == 0 && tap.sendErrors == 0)
        await v.tearDown(listener)
        sw.stop()
        tap.close()
    }
}

@Suite("Network bridge over passt (rootless)", .serialized, .enabled(if: NetEnv.passtReady))
struct PasstBridgeTests {
    @Test("two VMs behind one passt: DHCP, DNS, LAN TCP, no host loopback, throughput and latency")
    func passt() async throws {
        let dir = "/tmp/acl-pt-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let lan = try #require(hostLANAddress(), "no IPv4 default route on this host")
        let base = 41_000 + Int.random(in: 0..<500) * 8
        let lanSvc = try await startServices(ip: lan, base: base)
        let loopSvc = try await startServices(ip: "127.0.0.1", base: base + 4)
        defer { stopHelper(lanSvc); stopHelper(loopSvc) }

        let passt = try await PasstUplink.start(.init(logPath: dir + "/passt.log"))
        let passtPID = try #require(passt.pid)
        // VM A gets passt's 65520 MTU, VM B the Ethernet-standard 1500: the
        // throughput difference is the frame rate through switch + passt.
        let macA = "52:54:00:c0:00:01", macB = "52:54:00:c0:00:02"
        let bigMTU = passt.mtu
        let sw = TestSwitch(uplink: passt, gateway: "192.168.64.1", dns: "192.168.64.1",
                            mtu: { $0 == macBytes(macA) ? bigMTU : 1500 })
        let listener = try await VsockListener.shared(port: agentPort)
        let a = try await SwitchedVM.make(.q35, mac: macA, on: sw, listener: listener, tag: "passt", mtu: bigMTU)
        let b = try await SwitchedVM.make(.microvm, mac: macB, on: sw, listener: listener, tag: "passt", mtu: 1500)

        async let dialA = a.boot()
        async let dialB = b.boot()
        let (tA, tB) = try await (dialA, dialB)
        print("TIMING \(a.label) agentd dial on :\(agentPort) at \(ms(tA)) (booted alongside \(b.label))")
        print("TIMING \(b.label) agentd dial on :\(agentPort) at \(ms(tB))")
        #expect(tA < .seconds(30) && tB < .seconds(30))

        for (v, mtu) in [(a, bigMTU), (b, 1500)] {
            let ip = ipString(sw.dhcp.lease(for: macBytes(v.mac)))
            // Lease, route, MTU; DNS through passt's --dns-forward to the
            // host's resolver; ICMP to the host's LAN address.
            let r = try await shell(v.conns, """
                ip -4 -br addr show scope global; ip -4 route show default; \\
                cat /sys/class/net/$(ip -4 route show default | awk '{print $5; exit}')/mtu; \\
                getent ahostsv4 ubuntu.com | head -1; ping -c 3 -i 0.2 -W 2 \(lan) | tail -1
                """)
            print("GUEST \(v.label) \(r.output.replacingOccurrences(of: "\n", with: " | "))")
            #expect(r.exitCode == 0, "\(v.label) \(r.output)")
            #expect(r.output.contains("\(ip)/24") && r.output.contains("default via 192.168.64.1"))
            #expect(r.output.contains("\n\(mtu)\n"), "\(v.label) MTU \(mtu) not applied")
            #expect(r.output.contains("STREAM"), "\(v.label) DNS through passt failed")

            // Host loopback must stay out of reach: the gateway isn't mapped
            // to 127.0.0.1, and a loopback-only service isn't on the LAN address.
            let neg = try await shell(v.conns, """
                python3 - <<'PY'
                import socket
                for h in ("192.168.64.1", "\(lan)"):
                    try:
                        print("REACHED", h, socket.create_connection((h, \(base + 6)), timeout=3).recv(100))
                    except OSError as e:
                        print("BLOCKED", h, type(e).__name__)
                PY
                """)
            print("LOOPBACK \(v.label) \(neg.output.replacingOccurrences(of: "\n", with: " | "))")
            #expect(!neg.output.contains("REACHED"), "\(v.label) reached host loopback: \(neg.output)")
            #expect(neg.output.components(separatedBy: "BLOCKED").count == 3, "\(v.label) \(neg.output)")
        }

        // Both guests at once through the one passt.
        let hello = "python3 -c \"import socket; print(socket.create_connection(('\(lan)', \(base + 2)), timeout=5).recv(100).decode().strip())\""
        async let ha = shell(a.conns, hello)
        async let hb = shell(b.conns, hello)
        let (oa, ob) = try await (ha, hb)
        #expect(oa.output.contains("hello from \(lan)") && ob.output.contains("hello from \(lan)"),
                "\(oa.output) / \(ob.output)")

        for (v, mtu) in [(a, bigMTU), (b, 1500)] {
            let p0 = cpuSeconds(pid: passtPID), s0 = selfCPUSeconds()
            // 1 GiB at both MTUs, also through a debug build: with FramePort
            // backpressure the switch slows TCP down instead of dropping.
            // passt itself occasionally drops a flow at MTU 1500 (it stops
            // ACKing; see linux/ACLinux README "passt stall"): retry once, and
            // say so with our ports' counters, which show nothing lost here.
            var p = try await shell(v.conns, probeScript(host: lan, base: base, timeout: 45), timeout: 300)
            if p.exitCode != 0, p.output.contains("TimeoutError") {
                let st = sw.portStats(mac: v.mac)
                print("PASST-STALL \(v.label) MTU \(mtu): passt stopped ACKing a flow; our port: dropped \(st?.dropped ?? -1), "
                      + "queued \(st?.queued ?? -1); uplink dropped \(passt.stats.dropped). Retrying once.")
                #expect((st?.dropped ?? 1) == 0 && passt.stats.dropped == 0, "a stall with frames lost in the switch")
                p = try await shell(v.conns, probeScript(host: lan, base: base, timeout: 45), timeout: 300)
            }
            let pc = cpuSeconds(pid: passtPID) - p0, sc = selfCPUSeconds() - s0
            #expect(p.exitCode == 0, "\(v.label) probe: \(p.output)")
            if p.exitCode != 0 {
                let log = ((try? String(contentsOfFile: v.ws.dir + "/outbox/agentd.log", encoding: .utf8)) ?? "")
                let serial = ((try? String(contentsOfFile: v.ws.dir + "/run/serial.log", encoding: .utf8)) ?? "")
                print("DIAG \(v.label) agentd.log tail:\n" + log.split(separator: "\n").suffix(25).joined(separator: "\n")
                      + "\nDIAG serial tail:\n" + serial.split(separator: "\n").suffix(25).joined(separator: "\n")
                      + "\nDIAG qemu running: \(await v.vm.state)"
                      + "\nDIAG virtiofsd-bromure-meta.log:\n" + (((try? String(contentsOfFile: v.ws.dir + "/run/virtiofsd-bromure-meta.log", encoding: .utf8)) ?? "").split(separator: "\n").suffix(15).joined(separator: "\n"))
                      + "\nDIAG qemu.log:\n" + ((try? String(contentsOfFile: v.ws.dir + "/run/qemu.log", encoding: .utf8)) ?? ""))
            }
            print("PERF \(v.label) passt, guest MTU \(mtu): \(p.output.replacingOccurrences(of: "\n", with: " | ")) "
                  + "| passt CPU \(String(format: "%.2f", pc)) s, switch-process CPU \(String(format: "%.2f", sc)) s")
        }
        #expect(passt.restarts == 0)
        #expect(a.port.dropped == 0 && b.port.dropped == 0)
        await a.tearDown(listener)
        await b.tearDown(listener)
        sw.stop()
        await passt.close()
    }
}


@Suite("Interim switch backpressure (passt)", .serialized, .enabled(if: NetEnv.passtReady))
struct StallTests {
    /// Guest-side upload to the sink; prints THROUGHPUT_MBPS.
    func upload(_ v: SwitchedVM, _ lan: String, _ base: Int, mib: Int) async throws -> Double {
        let r = try await shell(v.conns, """
            python3 - <<'PY'
            import socket, time
            s = socket.create_connection(("\(lan)", \(base)), timeout=30); buf = bytes(1 << 20); t = time.time()
            for _ in range(\(mib)): s.sendall(buf)
            s.shutdown(socket.SHUT_WR); got = int(s.recv(64)); print("MBPS %.1f" % (got / (time.time() - t) / 1e6))
            PY
            """, timeout: 300)
        return Double(r.output.split(separator: " ").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    }

    @Test("a VM whose port stops draining doesn't slow another VM by more than ~10%; its own drop counter rises")
    func stalledPort() async throws {
        let dir = "/tmp/acl-st-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { if !FileManager.default.fileExists(atPath: dir + "/KEEP") { try? FileManager.default.removeItem(atPath: dir) } }
        let lan = try #require(hostLANAddress())
        let base = 46_000 + Int.random(in: 0..<400) * 8
        let svc = try await startServices(ip: lan, base: base)
        defer { stopHelper(svc) }
        var pc = PasstUplink.Config(logPath: dir + "/passt.log")
        if ProcessInfo.processInfo.environment["BROMURE_PASST_PCAP"] == "1" { pc.pcapPath = dir + "/passt.pcap" }
        let passt = try await PasstUplink.start(pc)
        let macA = "52:54:00:e0:00:01", macB = "52:54:00:e0:00:02"
        let sw = TestSwitch(uplink: passt, gateway: "192.168.64.1", dns: "192.168.64.1", mtu: { _ in 1500 })
        let listener = try await VsockListener.shared(port: agentPort)
        let a = try await SwitchedVM.make(.q35, mac: macA, on: sw, listener: listener, tag: "stall", mtu: 1500)
        // B's port queue is small, so one TCP window in flight toward the
        // paused VM (~700 frames at 1500) overflows it.
        let b = try await SwitchedVM.make(.microvm, mac: macB, on: sw, listener: listener, tag: "stall", mtu: 1500,
                                          queueFrames: 256)
        async let ba = a.boot()
        async let bb = b.boot()
        _ = try await (ba, bb)

        // Single uploads vary a lot run to run (guest scheduling, CPU
        // frequency), so compare medians of five.
        let mib = 128, samples = 5
        // Median of the transfers that completed: a 0 is passt dropping a flow
        // at MTU 1500 (it stops ACKing; our ports lose nothing), not the switch.
        func median(_ xs: [Double]) -> Double {
            let ok = xs.filter { $0 > 0 }.sorted()
            return ok.isEmpty ? 0 : ok[ok.count / 2]
        }
        // Diagnostics: the ports' counters every 5 s (a stuck transfer shows
        // which side stopped moving).
        let watch = Task {
            let t0 = ContinuousClock.now
            var lastOut = -1, dumped = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                let pa = sw.portStats(mac: macA), up = passt.stats
                if let o = pa?.sent, o == lastOut, !dumped {
                    dumped = true
                    let ss = Process()
                    ss.executableURL = URL(fileURLWithPath: "/usr/bin/ss")
                    ss.arguments = ["-tnimp", "( sport = :\(base) or dport = :\(base) )"]
                    let pipe = Pipe(); ss.standardOutput = pipe
                    try? ss.run(); ss.waitUntilExit()
                    print("DIAG ss:\n" + String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
                    if pc.pcapPath != nil { print("DIAG pcap: \(dir)/passt.pcap (kept)"); FileManager.default.createFile(atPath: dir + "/KEEP", contents: nil) }
                }
                lastOut = pa?.sent ?? -1
                print("DIAG t+\(ms(ContinuousClock.now - t0)) A: in \(pa?.received ?? -1) out \(pa?.sent ?? -1) q \(pa?.queued ?? -1) drop \(pa?.dropped ?? -1) pauses \(pa?.inboundPauses ?? -1) | uplink: in \(up.received) out \(up.sent) q \(up.queued) drop \(up.dropped) pauses \(up.inboundPauses)")
            }
        }
        defer { watch.cancel() }
        var alone: [Double] = []
        for _ in 0..<samples { alone.append(try await upload(a, lan, base, mib: mib)) }
        let baseline = median(alone)

        // B starts a big download, then is paused: its NIC stops taking frames,
        // so its port stops draining while passt still has in-flight data for it.
        _ = try await shell(b.conns, """
            nohup python3 -c "import socket; s=socket.create_connection(('\(lan)', \(base + 3))); s.sendall(b'4294967296\\n'); [s.recv(1<<20) for _ in iter(int, 1)]" >/dev/null 2>&1 &
            echo started
            """)
        try await Task.sleep(for: .seconds(1))
        let qmpB = try #require(await b.vm.qmp)
        try await qmpB.execute("stop")
        let droppedBefore = sw.portStats(mac: macB)?.dropped ?? 0
        var during: [Double] = []
        for _ in 0..<samples { during.append(try await upload(a, lan, base, mib: mib)) }
        let stalled = median(during)
        let droppedAfter = sw.portStats(mac: macB)?.dropped ?? 0
        let statsB = sw.portStats(mac: macB)
        try await qmpB.execute("cont")
        print("STALL A alone: median \(baseline) of \(alone) MB/s; with B paused: median \(stalled) of \(during) MB/s (\(String(format: "%.0f", stalled / baseline * 100))%); "
              + "B's port: dropped \(droppedBefore) -> \(droppedAfter), queued \(statsB?.queued ?? -1); A's port dropped \(sw.portStats(mac: macA)?.dropped ?? -1)")
        #expect(alone.filter { $0 > 0 }.count >= 3 && during.filter { $0 > 0 }.count >= 3, "too many passt stalls to compare")
        #expect(stalled >= baseline * 0.9, "A slowed to \(stalled) from \(baseline) MB/s")
        #expect(droppedAfter > droppedBefore, "B's drops should rise while it can't drain")
        #expect((sw.portStats(mac: macA)?.dropped ?? 1) == 0)
        await a.tearDown(listener)
        await b.tearDown(listener)
        sw.stop()
        await passt.close()
    }
}
