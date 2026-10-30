import CACLinuxShims
import Foundation
import NIOConcurrencyHelpers

/// The switch's uplink: a persistent tap (`bromure0`, made once by
/// linux/setup-network.sh) that the host routes and masquerades.
///
/// A tap is datagram-like: one frame per read() and per write(). That's why
/// this doesn't go through NIO: a pipe channel may coalesce queued writes
/// into one writev(), which a tap takes as a single, corrupt frame. A reader
/// thread polls the fd and hands frames to the port (pausing while the switch
/// lags, so the kernel's tap queue absorbs or drops, as a NIC would); the
/// writer writes one frame per write().
// @port-skip linux-only: tap uplink (macOS: VMNetSwitch's vmnet NAT interface)
public final class TapUplink: FramePort {
    public let name: String
    let core: FramePortCore
    private let fd: Int32
    private let state = NIOLockedValueBox<(running: Bool, sendErrors: Int)>((true, 0))
    private let finished = DispatchSemaphore(value: 0)

    /// Attaches to an existing tap this user owns.
    // @port-skip linux-only: tap uplink
    public static func open(name: String) throws -> TapUplink {
        let fd = acl_tap_open(name)
        guard fd >= 0 else { throw MachineError.io("attach tap \(name)", -fd) }
        return TapUplink(name: name, fd: fd)
    }

    // @port-skip linux-only: tap uplink
    private init(name: String, fd: Int32) {
        self.name = name
        self.fd = fd
        let state = self.state
        core = FramePortCore(name: name) { frames in
            // One write() per frame: a tap takes each write as one frame.
            var failed = 0
            for frame in frames {
                let n = frame.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                if n != frame.count { failed += 1 }
            }
            if failed > 0 { state.withLockedValue { $0.sendErrors += failed } }
        }
        // The thread holds the uplink until close() ends the loop.
        let t = Thread { [self] in self.readLoop() }
        t.name = "tap-\(name)"
        t.start()
    }

    // @port-skip linux-only: tap uplink
    private func readLoop() {
        var buf = [UInt8](repeating: 0, count: 65_550)
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while state.withLockedValue({ $0.running }) {
            pfd.revents = 0
            let r = poll(&pfd, 1, 200)
            if r < 0 && errno == EINTR { continue }
            if r < 0 { break }
            if r == 0 { continue }
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 { if !core.deliverBlocking(Data(buf[0..<n])) { break } }
            else if n < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            else { break }
        }
        finished.signal()
    }

    // MARK: FramePort (write errors, the tap down or ENOBUFS, drop the frame
    // like a full link would, counted in `sendErrors` and `stats.dropped`)

    // @port-skip linux-only: tap uplink
    public var inbound: FrameSequence { core.sequence }
    // @port-skip linux-only: tap uplink
    @discardableResult public func send(_ frame: Data) -> FrameSendResult { core.send(frame) }
    // @port-skip linux-only: tap uplink
    public func sendWaiting(_ frame: Data) async { await core.sendWaiting(frame) }
    // @port-skip linux-only: tap uplink
    public var isWritable: Bool { core.isWritable }
    // @port-skip linux-only: tap uplink
    public var stats: FramePortStats { core.stats }

    // @port-skip linux-only: tap uplink
    public var sendErrors: Int { state.withLockedValue { $0.sendErrors } }

    /// The tap's MAC address as the host sees it (`aa:bb:…`).
    // @port-skip linux-only: tap uplink
    public var hostMAC: String? {
        (try? String(contentsOfFile: "/sys/class/net/\(name)/address", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // @port-skip linux-only: tap uplink
    public func close() {
        let wasRunning = state.withLockedValue { s -> Bool in defer { s.running = false }; return s.running }
        guard wasRunning else { return }
        core.finish()                 // releases a reader paused on the consumer
        finished.wait()
        Glibc.close(fd)
    }
}
