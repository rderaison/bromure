import Foundation
import SandboxEngine
#if canImport(Darwin)
import Darwin
#endif

/// Bridges the guest TCP flows the switch diverts (`VMNetTCPInterceptor`) into
/// the host MiTM. The Ethernet-side analog of `UtunForwarder`: it terminates
/// each diverted flow in userspace with `TCPFlow`, splices it to one end of a
/// `socketpair`, and hands the other end to `MitmEngine.acceptTransparentFlow`
/// (SNI-peek → passthrough or MiTM). Reply segments are injected back into the
/// originating guest port via `VMNetSwitch.injectIPToPort`.
///
/// Lives in AgentCoding because it references `TCPFlow` and `MitmEngine`, which
/// SandboxEngine (where the switch lives) cannot depend on.
final class SwitchMitmForwarder: VMNetTCPInterceptor, @unchecked Sendable {
    private struct FlowRef: Hashable {
        let portID: Int
        let key: UtunForwarder.FlowKey
    }

    private let engine: MitmEngine
    private let sw: VMNetSwitch
    /// Emitted-segment MSS: guest NIC MTU (1280) − IP(20) − TCP(20).
    private let mss: Int

    private let lock = NSLock()
    private var flows: [FlowRef: TCPFlow] = [:]

    init(engine: MitmEngine, switch sw: VMNetSwitch, guestMTU: Int = 1280) {
        self.engine = engine
        self.sw = sw
        self.mss = max(536, guestMTU - 40)
    }

    // MARK: - VMNetTCPInterceptor

    func handleDivertedPacket(portID: Int, profileID: UUID?, ipPacket: [UInt8]) {
        guard let seg = UtunPacket.parse(ipPacket) else { return }
        let ref = FlowRef(portID: portID, key: UtunForwarder.FlowKey(seg))

        lock.lock()
        let existing = flows[ref]
        lock.unlock()
        if let existing {
            existing.onInbound(seg)
            return
        }
        // Only a bare SYN opens a flow; any other packet for an unknown flow gets
        // a RST so the guest kernel gives up rather than retransmitting forever.
        guard seg.flags & UtunPacket.SYN != 0, seg.flags & UtunPacket.ACK == 0 else {
            if seg.flags & UtunPacket.RST == 0 { sendRST(portID: portID, to: seg) }
            return
        }
        openFlow(ref, profileID: profileID, seg: seg)
    }

    func portClosed(portID: Int) {
        lock.lock()
        let victims = flows.filter { $0.key.portID == portID }
        for (k, _) in victims { flows.removeValue(forKey: k) }
        lock.unlock()
        for (_, f) in victims { f.close() }
    }

    // MARK: -

    @available(macOS, deprecated: 10.15)
    private func openFlow(_ ref: FlowRef, profileID: UUID?, seg: UtunPacket.TCPSegment) {
        let destIP = UtunPacket.ipString(seg.dstIP)
        let destPort = Int(seg.dstPort)
        let portID = ref.portID

        // socketpair: end A driven by the userspace TCP stack; end B is the
        // "application" fd the MiTM (or passthrough splice) reads/writes.
        var fds: [Int32] = [0, 0]
        guard fds.withUnsafeMutableBufferPointer({
            Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, $0.baseAddress!)
        }) == 0 else {
            sendRST(portID: portID, to: seg)
            return
        }
        let endA = fds[0], endB = fds[1]
        var one: Int32 = 1
        for fd in [endA, endB] {
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        }

        let flow = TCPFlow(
            key: ref.key, clientISN: seg.seq, mss: mss,
            dial: { endA },     // the stack owns end A
            send: { [weak self] s in
                self?.sw.injectIPToPort(portID, ipPacket: UtunPacket.build(s))
            },
            onClosed: { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.flows.removeValue(forKey: ref); self.lock.unlock()
            })
        lock.lock(); flows[ref] = flow; lock.unlock()

        // Hand end B to the engine (SNI peek → passthrough or MiTM). It owns and
        // closes end B. Without a profile identity we must NEVER MiTM (a mis-
        // attributed connection would inject another session's real credentials),
        // so splice raw instead.
        if let pid = profileID {
            engine.acceptTransparentFlow(appFD: endB, profileID: pid, destIP: destIP, destPort: destPort)
        } else {
            MitmPassthrough.splice(appFD: endB, destIP: destIP, destPort: destPort)
        }
        flow.start()
    }

    private func sendRST(portID: Int, to seg: UtunPacket.TCPSegment) {
        let rst = UtunPacket.TCPSegment(
            srcIP: seg.dstIP, dstIP: seg.srcIP, srcPort: seg.dstPort, dstPort: seg.srcPort,
            seq: seg.ack, ack: seg.seq &+ UInt32(seg.payload.count),
            flags: UtunPacket.RST | UtunPacket.ACK, window: 0, payload: [][...])
        sw.injectIPToPort(portID, ipPacket: UtunPacket.build(rst))
    }
}
