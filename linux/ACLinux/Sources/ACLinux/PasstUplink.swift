import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// The default uplink: one `passt` per host, in userspace and rootless. It
/// NATs every TCP/UDP/ICMP flow to ordinary host sockets: no tap, no
/// nftables, no root step, no FORWARD-chain conflicts (Docker's).
///
/// passt gets one end of a socketpair as its stdin (`--fd 0`) and speaks the
/// same `u32 length + frame` wire format as QEMU's stream netdev on it: no
/// socket file, nothing for another local user to connect to. (Its own
/// listening socket, `--socket` in `--foreground`, fails to add the accepted
/// fd to epoll on this build; daemonized it works but ignores `--one-off`.)
/// Our switch stays
/// authoritative: passt's DHCP, NDP, DHCPv6 and RA are off, and it answers as
/// the gateway (`gateway`, the subnet's .1) on `mac`. Host loopback is *not*
/// reachable from guests: passt's default maps the gateway address to the
/// host's 127.0.0.1, and that mapping is disabled here.
///
/// `--fd` implies one-off: when this process goes away, our end closes and
/// passt exits, so a crashed daemon leaves no orphan. If passt dies while we
/// run, it's restarted on a fresh socketpair (`restarts` counts it).
// @port-skip linux-only: rootless uplink (macOS: vmnet NAT does this in the kernel)
public final class PasstUplink: Uplink {
    // @port-skip linux-only: passt configuration
    public struct Config: Sendable {
        /// Our side of the VM subnet: what passt NATs for and answers ARP as.
        public var gateway = "192.168.64.1"
        public var prefixLength = 24
        /// Guest DNS sent to `gateway`:53 goes to `dnsHost` (default: the
        /// host's first resolver in /etc/resolv.conf). nil: no DNS mapping.
        public var dnsForward: String? = "192.168.64.1"
        public var dnsHost: String?
        public var mac = "9a:55:9a:55:9a:55"
        /// The guest MTU the daemon writes to `meta/mtu` (agentd applies it to
        /// eth0; DHCP option 26 is overridden by it). The rule:
        ///
        /// - **65520 by default.** passt terminates TCP in userspace and
        ///   re-segments for the real path, so guest TCP needn't fit the path
        ///   MTU, and big frames are what make the switch + passt cheap
        ///   (0.2 CPU-s/GiB at 65520 vs 1.6 at 1500).
        /// - **VPN profiles keep the macOS value** (1280, raised to 1400 by
        ///   config-agent for VPN profiles). A WireGuard/IKEv2/OpenVPN tunnel in
        ///   the guest sizes its packets from eth0's MTU; at 65520 it would
        ///   emit ~64 KB UDP datagrams that the host fragments and the
        ///   Internet drops.
        /// - **UDP gets no re-segmentation through passt**: each guest datagram
        ///   leaves as one host datagram (fragmented by the host if it's over
        ///   the path MTU). Only TCP benefits from the big MTU.
        public var mtu = 65_520
        /// Host interface for outbound sockets (default: the default route's).
        public var outboundInterface: String?
        public var logPath: String?
        public var binary = "/usr/bin/passt"
        /// Diagnosis: write every frame passt sees to this pcap (`--pcap`).
        /// (`--log-file` can't be used: Ubuntu's AppArmor profile for passt
        /// denies the read it needs, and passt exits.)
        public var pcapPath: String?

        // @port-skip linux-only: passt configuration
        public init(logPath: String? = nil) {
            self.logPath = logPath
        }

        /// passt's argv. `-a` (the "guest" address) only matters to passt for
        /// inbound forwards, which are off; it is the subnet's .2.
        // @port-skip linux-only: passt configuration
        public func arguments() -> [String] {
            let parts = gateway.split(separator: ".").compactMap { UInt8($0) }
            let guest = parts.count == 4 ? "\(parts[0]).\(parts[1]).\(parts[2]).\(parts[3] &+ 1)" : gateway
            var a = ["--foreground", "--fd", "0",
                     "-4", "--no-dhcp", "--no-ndp", "--no-dhcpv6", "--no-ra",
                     "-a", guest, "-n", "\(prefixLength)", "-g", gateway, "-M", mac,
                     "--map-host-loopback", "none", "--map-guest-addr", "none",
                     "-t", "none", "-u", "none"]
            if let dnsForward {
                a += ["--dns-forward", dnsForward]
                if let dnsHost { a += ["--dns-host", dnsHost] }
            }
            if let outboundInterface { a += ["--outbound-if4", outboundInterface] }
            if let pcapPath { a += ["--pcap", pcapPath] }
            return a
        }
    }

    public let config: Config
    let core: FramePortCore
    private let group: EventLoopGroup
    private let inbox: EagerInbox
    private let state = NIOLockedValueBox<(channel: Channel?, process: ChildProcess?,
                                           closing: Bool, restarts: Int, readFD: Int32?)>((nil, nil, false, 0, nil))
    /// The current passt connection's writer (nil between restarts).
    private let writer = NIOLockedValueBox<NIOAsyncChannelOutboundWriter<ByteBuffer>?>(nil)

    /// Tests only: a pause inside launch(), between spawning passt and
    /// installing its channel, to land a close() in that window.
    static let launchPauseForTesting = NIOLockedValueBox<Duration?>(nil)

    // @port-skip linux-only: rootless uplink
    public var gatewayMAC: String? { config.mac }
    // @port-skip linux-only: rootless uplink
    public var mtu: Int { config.mtu }
    // @port-skip linux-only: rootless uplink
    public var restarts: Int { state.withLockedValue { $0.restarts } }
    // @port-skip linux-only: rootless uplink
    public var pid: Int32? { state.withLockedValue { $0.process?.pid } }

    /// Starts passt and connects to it.
    // @port-skip linux-only: rootless uplink
    public static func start(_ config: Config,
                             group: EventLoopGroup = MultiThreadedEventLoopGroup.singleton) async throws -> PasstUplink {
        let u = PasstUplink(config: config, group: group)
        try await u.launch()
        return u
    }

    // @port-skip linux-only: rootless uplink
    private init(config: Config, group: EventLoopGroup) {
        self.config = config
        self.group = group
        let writer = self.writer
        core = FramePortCore(name: "passt") { frames in
            guard let w = writer.withLockedValue({ $0 }) else { throw ChannelError.ioOnClosedChannel }
            try await w.write(StreamPort.encode(frames))      // suspends while passt isn't reading
        }
        inbox = EagerInbox(core: core)
    }

    /// Times the reader waited because routing was 256Ki frames or 64 MiB
    /// behind (expected 0), and the deepest backlog seen (frames, bytes).
    // @port-skip linux-only: rootless uplink
    public var routeWaits: Int { inbox.stats.waits }
    // @port-skip linux-only: rootless uplink
    public var routeBacklogPeak: (frames: Int, bytes: Int) { let s = inbox.stats; return (s.peakFrames, s.peakBytes) }

    // @port-skip linux-only: rootless uplink
    private func launch() async throws {
        let core = self.core, inbox = self.inbox
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue) | Int32(SOCK_CLOEXEC.rawValue), 0, &fds) == 0 else {
            throw MachineError.io("socketpair", errno)
        }
        // fds[1] becomes passt's stdin (posix_spawn dup2s it, which drops
        // CLOEXEC on the copy); the parent's copy is closed once passt has it.
        let p: ChildProcess
        do {
            p = try ChildProcess(name: "passt", executable: config.binary, arguments: config.arguments(),
                                 logPath: config.logPath, standardInput: fds[1])
            try p.start()
        } catch {
            Glibc.close(fds[0])
            Glibc.close(fds[1])
            throw error
        }
        Glibc.close(fds[1])
        // A second descriptor on our end, for the reader thread. NIO keeps
        // fds[0] for writes only (its reads are blocked below).
        let readFD = fcntl(fds[0], F_DUPFD_CLOEXEC, 0)
        guard readFD >= 0 else {
            let e = errno
            Glibc.close(fds[0])
            p.signal(SIGKILL)
            throw MachineError.io("dup", e)
        }
        if let pause = Self.launchPauseForTesting.withLockedValue({ $0 }) { try? await Task.sleep(for: pause) }
        let ch: Channel
        let conn: NIOAsyncChannel<ByteBuffer, ByteBuffer>
        do {
            (ch, conn) = try await ClientBootstrap(group: group)
                .channelOption(ChannelOptions.autoRead, value: false)
                .withConnectedSocket(fds[0]) { c in
                    c.eventLoop.makeCompletedFuture {
                        // Writes only: every read request stops here, so the
                        // reader thread is the socket's only reader.
                        try c.pipeline.syncOperations.addHandler(NoReadHandler())
                        return (c, try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: c))
                    }
                }
        } catch {
            Glibc.close(readFD)
            Glibc.close(fds[0])
            p.signal(SIGKILL)
            throw error
        }
        // close() may have run while this (re)launch was in flight: it saw
        // the old (or no) channel, so this one is ours to tear down.
        let wanted = state.withLockedValue { s -> Bool in
            guard !s.closing else { return false }
            s.channel = ch
            s.process = p
            s.readFD = readFD
            return true
        }
        guard wanted else {
            Glibc.close(readFD)
            try? await conn.executeThenClose { _, _ in }   // one-off passt exits on EOF
            if await p.waitForExit(timeout: .seconds(2)) == nil { p.signal(SIGKILL) }
            throw ChannelError.alreadyClosed
        }
        // The reader: a thread of its own doing nothing but read passt's
        // socket and split frames, as QEMU's net backend does. passt's tap
        // writes fail with EAGAIN as soon as ~200 small frames are unread (a
        // Unix stream socket charges each against passt's send buffer), and
        // passt then loses that flow's ACKs for good. With a receiver (the
        // switch), frames go to the routing thread through the inbox; without
        // one (tests reading `inbound`), deliverBlocking paces the reader.
        let state = self.state
        let reader = Thread {
            Self.readLoop(fd: readFD, core: core, inbox: inbox)
            // Closed under the lock, so close() never shuts down a reused number.
            state.withLockedValue { s in
                if s.readFD == readFD { s.readFD = nil }
                Glibc.close(readFD)
            }
        }
        reader.name = "passt-read"
        reader.start()
        let writer = self.writer
        Task {
            try? await conn.executeThenClose { inbound, outbound in
                writer.withLockedValue { $0 = outbound }
                for try await _ in inbound {}          // never yields: only close ends it
                writer.withLockedValue { $0 = nil }
            }
        }
        Task { [weak self] in
            _ = await p.waitForExit()
            await self?.processExited(p)
        }
    }

    /// Reads passt's frames (4-byte big-endian length, then the frame) until
    /// EOF. Bad lengths are skipped byte for byte, as LengthPrefixedFrameDecoder does.
    // @port-skip linux-only: rootless uplink
    static func readLoop(fd: Int32, core: FramePortCore, inbox: EagerInbox) {
        var buf = [UInt8](repeating: 0, count: 1 << 20)
        var have = 0, skipping = 0
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        loop: while true {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + have, $0.count - have) }
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN {                // the description is non-blocking (NIO set it)
                    pfd.revents = 0
                    _ = poll(&pfd, 1, -1)
                    continue
                }
                break
            }
            have += n
            var at = 0
            while true {
                if skipping > 0 {
                    let k = min(skipping, have - at)
                    at += k
                    skipping -= k
                    if skipping > 0 { break }
                }
                guard have - at >= 4 else { break }
                let length = Int(buf[at]) << 24 | Int(buf[at + 1]) << 16 | Int(buf[at + 2]) << 8 | Int(buf[at + 3])
                if length < StreamPort.minFrame || length > StreamPort.maxFrame {
                    at += 4
                    skipping = length
                    continue
                }
                guard have - at >= 4 + length else { break }
                let frame = Data(buf[(at + 4)..<(at + 4 + length)])
                at += 4 + length
                if core.hasReceiver { inbox.push(frame) } else if !core.deliverBlocking(frame) { break loop }
            }
            if at > 0 {
                buf.withUnsafeMutableBytes { b in _ = memmove(b.baseAddress!, b.baseAddress! + at, have - at) }
                have -= at
            }
        }
    }

    // @port-skip linux-only: rootless uplink
    private func processExited(_ p: ChildProcess) async {
        let restart = state.withLockedValue { s -> Bool in
            guard !s.closing, s.process === p else { return false }
            s.channel = nil
            s.restarts += 1
            return true
        }
        guard restart else { return }
        var delay = Duration.milliseconds(100)
        while state.withLockedValue({ !$0.closing }) {
            if (try? await launch()) != nil { return }
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(5))
        }
    }

    // MARK: FramePort

    // @port-skip linux-only: rootless uplink
    public func setReceiver(_ r: (@Sendable (Data) -> Void)?, batchEnd: (@Sendable () -> Void)?) {
        core.setReceiver(r, batchEnd: batchEnd)
    }

    // @port-skip linux-only: rootless uplink
    public var name: String { "passt" }
    // @port-skip linux-only: rootless uplink
    public var inbound: FrameSequence { core.sequence }
    // @port-skip linux-only: rootless uplink
    @discardableResult public func send(_ frame: Data) -> FrameSendResult {
        guard frame.count >= StreamPort.minFrame, frame.count <= StreamPort.maxFrame else { return .dropped }
        return core.send(frame)
    }
    // @port-skip linux-only: rootless uplink
    public func sendWaiting(_ frame: Data) async {
        guard frame.count >= StreamPort.minFrame, frame.count <= StreamPort.maxFrame else { return }
        await core.sendWaiting(frame)
    }
    // @port-skip linux-only: rootless uplink
    public var isWritable: Bool { core.isWritable }
    // @port-skip linux-only: rootless uplink
    public var stats: FramePortStats { core.stats }

    // @port-skip linux-only: rootless uplink
    public func close() async {
        let (ch, p) = state.withLockedValue { s -> (Channel?, ChildProcess?) in
            s.closing = true
            // The reader's descriptor keeps the socket open: shut it down so
            // passt sees EOF (and exits) and the reader's read returns 0.
            if let fd = s.readFD { shutdown(fd, Int32(SHUT_RDWR)) }
            return (s.channel, s.process)
        }
        try? await ch?.close()
        if let p, await p.waitForExit(timeout: .seconds(2)) == nil {
            p.signal(SIGTERM)
            if await p.waitForExit(timeout: .seconds(2)) == nil { p.signal(SIGKILL) }
        }
        core.finish()
        inbox.close()
    }
}

/// Swallows read requests: the channel to passt is for writes only.
// @port-skip linux-only: rootless uplink
final class NoReadHandler: ChannelOutboundHandler, Sendable {
    typealias OutboundIn = ByteBuffer
    // @port-skip linux-only: rootless uplink
    func read(context: ChannelHandlerContext) {}
}

/// Frames read from passt, waiting for the routing thread. Never drops: a
/// lost frame from passt is worse than a late one. A dropped ACK is never
/// re-sent by passt (the stall), and dropped data makes it resend everything
/// from the last ACK (measured: 117M frames in 60 s when this dropped). The
/// backlog is bounded by the guests' TCP windows (passt can't send past
/// them); at `limit` the reader waits, a last resort that measures as
/// `readerWaits`.
// @port-skip linux-only: rootless uplink
final class EagerInbox: @unchecked Sendable {
    private let cond = NSCondition()
    private var frames: [Data] = []
    /// Frames and bytes not yet routed: queued plus the batch being routed.
    private var pendingFrames = 0, pendingBytes = 0
    private var closed = false
    private var waits = 0, peakFrames = 0, peakBytes = 0
    let frameLimit: Int, byteLimit: Int

    /// 64 MiB: at the default MTU behind passt (65520) the frame limit alone
    /// would allow ~16 GiB. The bytes bind first at any MTU above ~256 bytes
    /// (about 44Ki frames at 1500); the frame limit caps tiny-frame floods.
    // @port-skip linux-only: rootless uplink
    init(core: FramePortCore, frameLimit: Int = 1 << 18, byteLimit: Int = 64 << 20) {
        self.frameLimit = frameLimit
        self.byteLimit = byteLimit
        let t = Thread { [self] in
            while true {
                cond.lock()
                while frames.isEmpty && !closed { cond.wait() }
                if frames.isEmpty && closed { cond.unlock(); return }
                let batch = frames
                frames.removeAll(keepingCapacity: true)
                cond.unlock()
                for f in batch { _ = core.receiveEagerly(f, endsBatch: false) }
                core.endBatch()                   // one writer wake per port per batch
                cond.lock()
                pendingFrames -= batch.count
                pendingBytes -= batch.reduce(0) { $0 + $1.count }
                cond.broadcast()                  // a reader waiting at a limit
                cond.unlock()
            }
        }
        t.name = "passt-route"
        t.start()
    }

    /// Never drops: past either limit the reader waits until routing catches
    /// up (always admitting a frame when nothing is pending).
    // @port-skip linux-only: rootless uplink
    func push(_ f: Data) {
        cond.lock()
        func full() -> Bool {
            pendingFrames > 0 && (pendingFrames >= frameLimit || pendingBytes + f.count > byteLimit)
        }
        if full() {
            waits += 1
            while full() && !closed { cond.wait() }
        }
        frames.append(f)
        pendingFrames += 1
        pendingBytes += f.count
        peakFrames = max(peakFrames, pendingFrames)
        peakBytes = max(peakBytes, pendingBytes)
        cond.broadcast()
        cond.unlock()
    }

    // @port-skip linux-only: rootless uplink
    func close() {
        cond.lock(); closed = true; cond.broadcast(); cond.unlock()
    }

    /// Times the reader waited at a limit; the deepest backlog (frames, bytes).
    // @port-skip linux-only: rootless uplink
    var stats: (waits: Int, peakFrames: Int, peakBytes: Int) {
        cond.lock(); defer { cond.unlock() }
        return (waits, peakFrames, peakBytes)
    }
}
