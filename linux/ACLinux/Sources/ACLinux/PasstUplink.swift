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
        /// MTU the switch should advertise. passt terminates TCP in userspace
        /// and re-segments for the real path, so the guest MTU needn't fit the
        /// path MTU (the macOS 1280/1400 VPN clamp isn't needed for TCP); a
        /// bigger one means fewer frames through the switch and passt.
        public var mtu = 65_520
        /// Host interface for outbound sockets (default: the default route's).
        public var outboundInterface: String?
        public var logPath: String?
        public var binary = "/usr/bin/passt"

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
            return a
        }
    }

    public let config: Config
    public let frames: AsyncStream<Data>
    private let sink: AsyncStream<Data>.Continuation
    private let group: EventLoopGroup
    private let state = NIOLockedValueBox<(channel: Channel?, process: ChildProcess?,
                                           closing: Bool, restarts: Int)>((nil, nil, false, 0))

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
        (frames, sink) = AsyncStream<Data>.makeStream(bufferingPolicy: .bufferingNewest(4096))
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
        let sink = self.sink
        let ch: Channel
        do {
            ch = try await ClientBootstrap(group: group)
                .channelInitializer { c in
                    c.eventLoop.makeCompletedFuture {
                        try c.pipeline.syncOperations.addHandler(ByteToMessageHandler(
                            LengthPrefixedFrameDecoder(onDrop: { _ in })))
                        try c.pipeline.syncOperations.addHandler(FrameSink(sink))
                    }
                }
                .withConnectedSocket(fds[0]).get()
        } catch {
            Glibc.close(fds[0])
            p.signal(SIGKILL)
            throw error
        }
        state.withLockedValue { $0.channel = ch; $0.process = p }
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

    // @port-skip linux-only: rootless uplink
    public func send(_ frame: Data) {
        guard frame.count >= StreamPort.minFrame, frame.count <= StreamPort.maxFrame,
              let ch = state.withLockedValue({ $0.channel }) else { return }
        ch.writeAndFlush(StreamPort.encode(frame, allocator: ch.allocator), promise: nil)
    }

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
        sink.finish()
    }
}
