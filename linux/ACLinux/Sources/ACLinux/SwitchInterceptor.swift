import Foundation
import Glibc
import NIOConcurrencyHelpers
import SandboxEngine

/// Bridges the guest TCP flows the switch diverts (VMNetTCPInterceptor) into
/// the host MiTM (macOS: SwitchMitmForwarder): each diverted flow is
/// terminated in userspace with the shared TCPFlow, spliced to one end of a
/// socketpair, and the other end handed to MitmProxy.acceptTransparentFlow
/// (SNI / Host peek → passthrough or MiTM). Reply segments go back to the
/// originating VM through the switch (SwitchEgressFirewall.inject).
// @port-skip linux-only: SwitchMitmForwarder for the Linux switch (macOS's injects through VMNetSwitch.injectIPToPort)
final class SwitchInterceptor: VMNetTCPInterceptor, @unchecked Sendable {
    private struct FlowRef: Hashable {
        let portID: Int
        let key: UtunPacket.FlowKey
    }

    private let proxy: MitmProxy
    /// Hands a reply packet (IP header onward) to the VM on `portID`.
    private let inject: @Sendable (_ portID: Int, _ ipPacket: [UInt8]) -> Void
    /// Emitted-segment MSS: the guest NIC MTU − IP(20) − TCP(20).
    private let mss: Int

    private let lock = NIOLock()
    private var flows: [FlowRef: TCPFlow] = [:]

    // @port SwitchMitmForwarder.init(engine: MitmEngine, switch: VMNetSwitch, guestMTU: Int) h=ac67de5df85baa30 @da668bda
    init(proxy: MitmProxy, guestMTU: Int, inject: @escaping @Sendable (_ portID: Int, _ ipPacket: [UInt8]) -> Void) {
        self.proxy = proxy
        self.inject = inject
        self.mss = max(536, guestMTU - 40)
    }

    // @port SwitchMitmForwarder.handleDivertedPacket(portID: Int, profileID: UUID?, ipPacket: [UInt8]) h=0a1c17edfd57ffa9 @da668bda
    func handleDivertedPacket(portID: Int, profileID: UUID?, ipPacket: [UInt8]) {
        guard let seg = UtunPacket.parse(ipPacket) else { return }
        let ref = FlowRef(portID: portID, key: UtunPacket.FlowKey(seg))
        if let existing = lock.withLock({ flows[ref] }) {
            existing.onInbound(seg)
            return
        }
        // Only a bare SYN opens a flow; any other packet for an unknown flow
        // gets a RST so the guest kernel gives up rather than retransmitting.
        guard seg.flags & UtunPacket.SYN != 0, seg.flags & UtunPacket.ACK == 0 else {
            if seg.flags & UtunPacket.RST == 0 { sendRST(portID: portID, to: seg) }
            return
        }
        openFlow(ref, profileID: profileID, seg: seg)
    }

    /// The firewall now denies this established flow: drop it, closing the
    /// MiTM side and its upstream connection. The switch already RST the guest.
    // @port SwitchMitmForwarder.flowDenied(portID: Int, ipPacket: [UInt8]) h=ca653c3cfc794409 @da668bda
    func flowDenied(portID: Int, ipPacket: [UInt8]) {
        guard let seg = UtunPacket.parse(ipPacket) else { return }
        let ref = FlowRef(portID: portID, key: UtunPacket.FlowKey(seg))
        let victim = lock.withLock { flows.removeValue(forKey: ref) }
        victim?.close()
    }

    // @port SwitchMitmForwarder.portClosed(portID: Int) h=71357145f503db73 @da668bda
    func portClosed(portID: Int) {
        let victims: [TCPFlow] = lock.withLock {
            let v = flows.filter { $0.key.portID == portID }
            for (k, _) in v { flows.removeValue(forKey: k) }
            return Array(v.values)
        }
        for f in victims { f.close() }
    }

    /// Open flows (tests).
    // @port-skip linux-only: tests
    var openFlows: Int { lock.withLock { flows.count } }

    // @port SwitchMitmForwarder.openFlow(_: FlowRef, profileID: UUID?, seg: UtunPacket.TCPSegment) h=594be0fcf4be5e6c @da668bda
    private func openFlow(_ ref: FlowRef, profileID: UUID?, seg: UtunPacket.TCPSegment) {
        let destIP = UtunPacket.ipString(seg.dstIP)
        let destPort = Int(seg.dstPort)
        let portID = ref.portID

        // socketpair: end A driven by the userspace TCP stack; end B is the
        // "application" fd the MiTM (or passthrough splice) reads/writes.
        // (No SO_NOSIGPIPE on Linux: the daemon ignores SIGPIPE.)
        var fds: [Int32] = [0, 0]
        guard fds.withUnsafeMutableBufferPointer({
            socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, $0.baseAddress!)
        }) == 0 else {
            sendRST(portID: portID, to: seg)
            return
        }
        let endA = fds[0], endB = fds[1]

        let inject = self.inject
        let flow = TCPFlow(
            key: ref.key, clientISN: seg.seq, mss: mss,
            dial: { endA },     // the stack owns end A
            send: { s in inject(portID, UtunPacket.build(s)) },
            onClosed: { [weak self] _ in
                guard let self else { return }
                _ = self.lock.withLock { self.flows.removeValue(forKey: ref) }
            })
        lock.withLock { flows[ref] = flow }

        // Hand end B to the proxy (SNI peek → passthrough or MiTM); it owns
        // and closes it. Without a profile identity a flow is NEVER MiTM'd (a
        // mis-attributed connection would inject another session's real
        // credentials): spliced raw instead, to the address the guest chose.
        if let pid = profileID {
            proxy.acceptTransparentFlow(appFD: endB, profileID: pid, destIP: destIP, destPort: destPort,
                                        srcPort: Int(seg.srcPort))
        } else {
            proxy.spliceRaw(appFD: endB, destIP: destIP, destPort: destPort)
        }
        flow.start()
    }

    // @port SwitchMitmForwarder.sendRST(portID: Int, to: UtunPacket.TCPSegment) h=73b110c2a4d29358 @da668bda
    private func sendRST(portID: Int, to seg: UtunPacket.TCPSegment) {
        let rst = UtunPacket.TCPSegment(
            srcIP: seg.dstIP, dstIP: seg.srcIP, srcPort: seg.dstPort, dstPort: seg.srcPort,
            seq: seg.ack, ack: seg.seq &+ UInt32(seg.payload.count),
            flags: UtunPacket.RST | UtunPacket.ACK, window: 0, payload: [][...])
        inject(portID, UtunPacket.build(rst))
    }
}
