import CACLinuxShims
import Foundation
import NIOConcurrencyHelpers

/// One VM's switch port over an `AF_UNIX` `SOCK_DGRAM` socketpair: the VM's
/// end goes to Firecracker (`host_dev_name: "fd:3"`), this one stays here.
///
/// One Ethernet frame per datagram, no prefix, so nothing can desync: a
/// datagram arrives whole or not at all. There is no connection either: the
/// daemon keeps its end in systemd's fd store, and a restarted daemon takes
/// the same socket back (`init(name:fd:)`) while Firecracker never notices.
/// Frames the VM sends meanwhile wait in this end's receive queue, then
/// Firecracker drops (and counts) once it is full; guest TX never stalls.
///
/// Like TapUplink, not NIO: a reader thread polls and delivers (pausing
/// while the switch lags, so the queue absorbs or Firecracker drops), and
/// the writer sends one frame per `send()`. Unlike a tap, a full peer is
/// waited for (POLLOUT), not dropped on: with net.core.wmem_max at its
/// common default only a few 64 KiB frames fit in flight, and the VM's
/// frames should slow its TCP, not be lost. The port's bounded queue
/// (FramePortCore) still drops, counted, when the VM stops reading for good.
// @port-skip linux-only: Firecracker datagram netdev (macOS: VMNetSwitch's socketpair ports)
public final class DgramPort: FramePort {
    public let name: String
    let core: FramePortCore
    /// This end of the pair.
    public let fd: Int32
    /// `running` and every send share this lock, so close() can't race a
    /// send onto a closed (or reused) descriptor; sends are non-blocking.
    private let state = NIOLockedValueBox<(running: Bool, sendErrors: Int)>((true, 0))
    private let finished = DispatchSemaphore(value: 0)
    /// Asked of both ends; the kernel caps it at net.core.{w,r}mem_max.
    static let socketBuffer: Int32 = 4 << 20
    /// Ethernet header at least; a 64 KiB MTU frame at most.
    public static let minFrame = 14
    public static let maxFrame = 65_550

    /// A new socketpair: the port on one end, and the other end for the VM
    /// (close-on-exec; hand it to the child with ChildProcess's
    /// `inheritedFDs`, then close it here).
    // @port-skip linux-only: Firecracker datagram netdev
    public static func pair(name: String) throws -> (port: DgramPort, peer: Int32) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, Int32(SOCK_DGRAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0, &fds) == 0 else {
            throw MachineError.io("socketpair", errno)
        }
        setBuffers(fds[1])
        return (DgramPort(name: name, fd: fds[0]), fds[1])
    }

    /// The port on an end that already exists (back from the fd store).
    // @port-skip linux-only: Firecracker datagram netdev
    public init(name: String, fd: Int32) {
        self.name = name
        self.fd = fd
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        Self.setBuffers(fd)
        let state = self.state
        core = FramePortCore(name: name) { frames in
            for frame in frames {
                while true {
                    let r = state.withLockedValue { st -> Int32? in
                        guard st.running else { return nil }
                        let n = frame.withUnsafeBytes { Glibc.send(fd, $0.baseAddress, $0.count, Int32(MSG_DONTWAIT | MSG_NOSIGNAL)) }
                        if n == frame.count { return 0 }
                        let e = errno
                        if n < 0 && (e == EAGAIN || e == ENOBUFS || e == EINTR) { return e }
                        st.sendErrors += 1           // the VM's end is gone: the frame with it
                        return 0
                    }
                    guard let r else { return }        // closed
                    if r == 0 { break }
                    await DgramPort.waitWritable(fd)
                }
            }
        }
        let t = Thread { [self] in self.readLoop() }
        t.name = "dgram-\(name)"
        t.start()
    }

    // @port-skip linux-only: Firecracker datagram netdev
    private static func setBuffers(_ fd: Int32) {
        var size = socketBuffer
        for opt in [SO_SNDBUF, SO_RCVBUF] {
            _ = setsockopt(fd, SOL_SOCKET, opt, &size, socklen_t(MemoryLayout<Int32>.size))
        }
    }

    /// Until the peer has room (or 100 ms, so a closing port is noticed),
    /// off the cooperative pool.
    // @port-skip linux-only: Firecracker datagram netdev
    private static func waitWritable(_ fd: Int32) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&p, 1, 100)
                c.resume()
            }
        }
    }

    // @port-skip linux-only: Firecracker datagram netdev
    private func readLoop() {
        var buf = [UInt8](repeating: 0, count: Self.maxFrame + 1)
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        while state.withLockedValue({ $0.running }) {
            pfd.revents = 0
            let r = poll(&pfd, 1, 200)
            if r < 0 && errno == EINTR { continue }
            if r < 0 { break }
            if r == 0 { continue }
            let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, Int32(MSG_DONTWAIT)) }
            if n >= Self.minFrame && n <= Self.maxFrame {
                if !core.deliverBlocking(Data(buf[0..<n])) { break }
            } else if n >= 0 {
                continue                                   // runt or oversize datagram: dropped
            } else if errno == EAGAIN || errno == EINTR {
                continue
            } else {
                break
            }
        }
        finished.signal()
    }

    // MARK: FramePort

    // @port-skip linux-only: Firecracker datagram netdev
    public var inbound: FrameSequence { core.sequence }
    // @port-skip linux-only: Firecracker datagram netdev
    @discardableResult public func send(_ frame: Data) -> FrameSendResult {
        guard frame.count >= Self.minFrame, frame.count <= Self.maxFrame else { return .dropped }
        return core.send(frame)
    }
    // @port-skip linux-only: Firecracker datagram netdev
    @discardableResult public func sendDeferred(_ frame: Data) -> FrameSendResult {
        guard frame.count >= Self.minFrame, frame.count <= Self.maxFrame else { return .dropped }
        return core.sendDeferred(frame)
    }
    // @port-skip linux-only: Firecracker datagram netdev
    public func flush() { core.flush() }
    // @port-skip linux-only: Firecracker datagram netdev
    public func sendWaiting(_ frame: Data) async {
        guard frame.count >= Self.minFrame, frame.count <= Self.maxFrame else { return }
        await core.sendWaiting(frame)
    }
    // @port-skip linux-only: Firecracker datagram netdev
    public var isWritable: Bool { core.isWritable }
    // @port-skip linux-only: Firecracker datagram netdev
    public var stats: FramePortStats { core.stats }
    /// Frames lost because the VM's end was gone.
    // @port-skip linux-only: Firecracker datagram netdev
    public var sendErrors: Int { state.withLockedValue { $0.sendErrors } }

    /// Stops the port and closes this end (the VM's is the VM's).
    // @port-skip linux-only: Firecracker datagram netdev
    public func close() {
        let wasRunning = state.withLockedValue { s -> Bool in defer { s.running = false }; return s.running }
        guard wasRunning else { return }
        core.finish()
        finished.wait()
        Glibc.close(fd)
    }
}
