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
    private let state = NIOLockedValueBox<(channel: Channel?, process: ChildProcess?,
                                           closing: Bool, restarts: Int)>((nil, nil, false, 0))
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
    }

    // @port-skip linux-only: rootless uplink
    private func launch() async throws {
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
        if let pause = Self.launchPauseForTesting.withLockedValue({ $0 }) { try? await Task.sleep(for: pause) }
        let ch: Channel
        let conn: NIOAsyncChannel<ByteBuffer, ByteBuffer>
        do {
            (ch, conn) = try await ClientBootstrap(group: group)
                .withConnectedSocket(fds[0]) { c in
                    c.eventLoop.makeCompletedFuture {
                        try c.pipeline.syncOperations.addHandler(ByteToMessageHandler(
                            LengthPrefixedFrameDecoder(onDrop: { _ in })))
                        return (c, try NIOAsyncChannel<ByteBuffer, ByteBuffer>(wrappingChannelSynchronously: c,
                            configuration: .init(backPressureStrategy: .init(lowWatermark: 64, highWatermark: 256))))
                    }
                }
        } catch {
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
            return true
        }
        guard wanted else {
            try? await conn.executeThenClose { _, _ in }   // one-off passt exits on EOF
            if await p.waitForExit(timeout: .seconds(2)) == nil { p.signal(SIGKILL) }
            throw ChannelError.alreadyClosed
        }
        // Pump: passt's frames into the port, paced by the consumer (reading
        // stops while the switch lags; passt holds them and its TCP slows).
        let core = self.core, writer = self.writer
        Task {
            try? await conn.executeThenClose { inbound, outbound in
                writer.withLockedValue { $0 = outbound }
                for try await frame in inbound {
                    guard await core.deliver(Data(frame.readableBytesView)) else { break }
                }
                writer.withLockedValue { $0 = nil }
            }
        }
        Task { [weak self] in
            _ = await p.waitForExit()
            await self?.processExited(p)
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
            return (s.channel, s.process)
        }
        try? await ch?.close()
        if let p, await p.waitForExit(timeout: .seconds(2)) == nil {
            p.signal(SIGTERM)
            if await p.waitForExit(timeout: .seconds(2)) == nil { p.signal(SIGKILL) }
        }
        core.finish()
    }
}
