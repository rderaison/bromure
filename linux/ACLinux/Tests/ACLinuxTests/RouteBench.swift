import Foundation
import Testing
@testable import ACLinux

/// Routing cost, opt-in (BROMURE_BENCH=1; run with -c release for shipped
/// numbers): 1514-byte frames through the switch's uplink receiver to a VM
/// port whose writer drains concurrently, as passt's frames are routed.
@Suite("route bench", .enabled(if: ProcessInfo.processInfo.environment["BROMURE_BENCH"] != nil))
struct RouteBench {
    /// A FramePort that takes everything (no drops) and discards it.
    final class SinkPort: FramePort, @unchecked Sendable {
        let core: FramePortCore
        let name: String
        init(_ n: String) { name = n; core = FramePortCore(name: n, queueFrames: 1 << 22, queueBytes: 1 << 40) { _ in } }
        var inbound: FrameSequence { core.sequence }
        func send(_ f: Data) -> FrameSendResult { core.send(f) }
        func sendBatch(_ fs: [Data]) { for f in fs { _ = core.send(f) } }
        func sendWaiting(_ f: Data) async { await core.sendWaiting(f) }
        var isWritable: Bool { core.isWritable }
        var stats: FramePortStats { core.stats }
    }
    /// An uplink whose receiver the bench calls directly.
    final class DirectUplink: Uplink, @unchecked Sendable {
        let sink = SinkPort("up")
        var receiver: (@Sendable (Data) -> Void)?
        var name: String { "up" }
        var inbound: FrameSequence { sink.inbound }
        func send(_ f: Data) -> FrameSendResult { .queued }
        func sendWaiting(_ f: Data) async {}
        var isWritable: Bool { true }
        var stats: FramePortStats { sink.stats }
        var gatewayMAC: String? { "9a:55:9a:55:9a:55" }
        var mtu: Int { 65520 }
        func setReceiver(_ r: (@Sendable (Data) -> Void)?) { receiver = r }
        func close() async {}
    }

    @Test func route() async throws {
        let up = DirectUplink()
        let sw = InterimSwitch(uplink: up)
        let a = SinkPort("a"), b = SinkPort("b")
        sw.attach(a, mac: "52:54:00:00:00:0a")
        sw.attach(b, mac: "52:54:00:00:00:0b")
        let ip = sw.dhcp.lease(for: InterimSwitch.mac("52:54:00:00:00:0a"))
        _ = sw.dhcp.lease(for: InterimSwitch.mac("52:54:00:00:00:0b"))
        var bytes = [UInt8](repeating: 0, count: 1514)
        bytes[12] = 0x08; bytes[13] = 0x00; bytes[14] = 0x45
        for i in 0..<4 { bytes[30 + i] = ip[i] }
        let route = try #require(up.receiver)
        let n = 2_000_000
        // Each frame is a fresh buffer, as the passt reader hands them over.
        let frames = (0..<1024).map { _ in Data(bytes) }
        let t0 = ContinuousClock.now
        for i in 0..<n { route(frames[i & 1023]) }
        let d = ContinuousClock.now - t0
        let ns = (Double(d.components.seconds) * 1e9 + Double(d.components.attoseconds) / 1e9) / Double(n)
        print("BENCH route: \(String(format: "%.0f", ns)) ns/frame (\(String(format: "%.2f", 1e3 / ns))M frames/s); delivered \(a.stats.queued + a.stats.sent)")
        sw.stop()
    }
}
