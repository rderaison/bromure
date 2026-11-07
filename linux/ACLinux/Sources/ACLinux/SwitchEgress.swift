import Foundation
import NIOConcurrencyHelpers
import SandboxEngine

/// The switch's egress firewall on Linux (macOS: VMNetSwitch.handleEgress and
/// its per-port governance): every off-subnet frame a session VM sends is
/// decided against its workspace's EgressPolicy before the uplink sees it,
/// whatever the guest's proxy settings. The frame helpers, the RST it answers
/// with and the report it makes are macOS's own (VMNetSwitch+Packets.swift,
/// SwitchEgressReport); the decision follows handleEgress step for step.
// partial: no agent-watchdog quarantine or egress byte counts on Linux (no watchdog yet)
// @port-skip linux-only: VMNetSwitch's egress firewall state for the Linux switch
final class SwitchEgressFirewall: @unchecked Sendable {
    /// A session port's governance (macOS: portProfileID, portEgressPolicy,
    /// portInterceptDisabled).
    struct Governance: Sendable {
        var profileID: UUID
        var policy: EgressPolicy?
        var interceptDisabled: Bool
    }

    /// What the switch does with a frame from a VM.
    enum Action: Equatable {
        /// Forward it as before (to peers / the uplink).
        case pass
        /// Consumed: dropped, or answered (`inject`, toward the sender).
        case consumed
        /// To the peers only, never the uplink (a subnet broadcast).
        case peersOnly
    }

    /// The transparent interceptor (SwitchInterceptor) and the ports it takes,
    /// set once at start; nil: none (every allowed flow goes to the uplink).
    struct Interception: Sendable {
        let interceptor: any VMNetTCPInterceptor
        let ports: Set<UInt16>
    }

    private struct EgressKey: Hashable {
        let port: MAC
        let name: String
        let dstIP: UInt32
        let dstPort: UInt16
        let proto: UInt8
        var exe: String? = nil
    }

    private let lock = NIOLock()
    private var governance: [MAC: Governance] = [:]
    private var egressSeen: [EgressKey: Date] = [:]
    private static let egressReportEvery: TimeInterval = 60
    private var interception: Interception?
    /// The guests' DNS answers, IP → names (macOS: VMNetSwitch.dnsCache).
    let dnsCache = DNSSnoopCache()
    /// Where a decided flow is reported (macOS: the app's egress observer).
    var observer: @Sendable (VMNetSwitch.EgressEvent) -> Void = { SwitchEgressReport.record($0) }
    let gatewayIP: UInt32
    let subnetMask: UInt32
    /// Hands an IPv4 packet (IP header onward) to the VM on `mac`, framed by
    /// the switch (a RST answering a denied segment, an interceptor's reply).
    let inject: @Sendable (_ mac: MAC, _ ipPacket: [UInt8]) -> Void
    /// Whether an address on the subnet is leased to another attached VM
    /// than the sender (a peer).
    let isLeased: @Sendable (UInt32, MAC) -> Bool
    /// Whether an address is in a cluster's reserved LoadBalancer range
    /// (never leased; a cluster node answers ARP for it).
    let isReserved: @Sendable (UInt32) -> Bool
    /// The subnet is closed (the uplink NATs it into host connects): only
    /// peers and the gateway's DNS pass. Open: macOS's native path.
    let closesSubnet: Bool

    // @port-skip linux-only: the Linux switch's egress firewall
    init(gatewayIP: UInt32, subnetMask: UInt32 = 0xFFFF_FF00,
         isLeased: @escaping @Sendable (UInt32, MAC) -> Bool = { _, _ in false },
         isReserved: @escaping @Sendable (UInt32) -> Bool = { _ in false }, closesSubnet: Bool = true,
         inject: @escaping @Sendable (_ mac: MAC, _ ipPacket: [UInt8]) -> Void) {
        self.gatewayIP = gatewayIP
        self.subnetMask = subnetMask
        self.isLeased = isLeased
        self.isReserved = isReserved
        self.closesSubnet = closesSubnet
        self.inject = inject
    }

    /// The port's governance: a session VM's workspace and its policy (nil:
    /// not a session port, never governed). A new policy re-decides open flows
    /// on their next packet, as macOS's setEgressPolicy does.
    // @port VMNetSwitch.setEgressPolicy(_: EgressPolicy?, forPortID: Int) h=45ab02e9346f46d0 @ac3ea65d
    func govern(_ mac: MAC, _ g: Governance?) {
        lock.withLock {
            governance[mac] = g
            egressSeen = egressSeen.filter { $0.key.port != mac }
        }
    }

    /// A workspace's live policy change (a save, an expiry): every port of
    /// that workspace takes it, re-deciding open flows on their next packet.
    // @port-skip linux-only: setEgressPolicy / setInterceptDisabled for every port of a workspace
    func update(_ g: Governance) {
        lock.withLock {
            let macs = governance.filter { $0.value.profileID == g.profileID }.map(\.key)
            for m in macs { governance[m] = g }
            egressSeen = egressSeen.filter { !macs.contains($0.key.port) }
        }
    }

    // @port-skip linux-only: the Linux switch's egress firewall
    func setInterception(_ i: Interception?) { lock.withLock { interception = i } }

    /// The VM on `mac` was detached: its governance goes, and the interceptor
    /// drops its flows (macOS: detachPort's portEgressPolicy reset and
    /// interceptor.portClosed).
    // @port-skip linux-only: the Linux switch's egress firewall
    func portClosed(_ mac: MAC) {
        let i: Interception? = lock.withLock {
            governance[mac] = nil
            egressSeen = egressSeen.filter { $0.key.port != mac }
            return interception
        }
        i?.interceptor.portClosed(portID: mac.portID)
    }

    // @port-skip linux-only: the Linux switch's egress firewall
    func governance(of mac: MAC) -> Governance? { lock.withLock { governance[mac] } }

    /// A frame from the uplink: the guests' DNS answers fill the cache
    /// hostname rules match against (macOS: handleFromVmnet's snoop).
    // @port-skip linux-only: handleFromVmnet's DNS snoop on the Linux uplink path
    func snoop(_ f: Data) {
        f.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, raw.count >= 14 + 20 + 8 else { return }
            // Read only: the helpers take macOS's frame pointer type.
            VMNetSwitch.snoopDNSResponse(UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: UInt8.self)),
                                         raw.count, into: dnsCache)
        }
    }

    /// Firewall and interception for one frame from the VM on `src`: `.pass`
    /// to forward it, `.consumed` when it was dropped by policy, answered, or
    /// diverted into the MITM. Only session ports are governed.
    // partial: a name the guest resolves itself (its own resolver, DoH, /etc/hosts) is unseen off the intercepted ports: there the verdict has only the snooped DNS (macOS has the same limit; :80/:443 are re-decided by the SNI / Host)
    // partial: no binary-identity gate on Linux, so a flow an `enforceBinaries` policy would ask the guest's attestor about is denied (macOS without a gate does the same); no quarantine
    // @port-skip linux-only: the Data entry to decide (handleEgress's port)
    func handle(_ f: Data, from src: MAC) -> Action {
        f.withUnsafeBytes { raw -> Action in
            guard let base = raw.baseAddress else { return .pass }
            // Read only (the shared helpers take macOS's frame pointer type).
            return decide(UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: UInt8.self)), raw.count, src)
        }
    }

    // @port VMNetSwitch.handleEgress(_: Int, _: UnsafeMutablePointer<UInt8>, _: Int) h=c790fa1982cff6dc @ac3ea65d
    private func decide(_ buf: UnsafeMutablePointer<UInt8>, _ n: Int, _ src: MAC) -> Action {
        guard n >= 14 else { return .pass }
        let ethertype = VMNetSwitch.u16(buf, 12)

        // ---- IPv6 ----
        // The firewall + MiTM are IPv4-only, so routable IPv6 egress is an
        // uninspected, unfilterable bypass. Drop global-unicast v6 on an
        // INSPECTED VM (transparent proxy on, or an egress policy set); the
        // guest falls back to the filtered IPv4. Link-local / multicast
        // (ND / RA / DHCPv6) pass so v6 autoconfig still works.
        if ethertype == 0x86DD {
            guard VMNetSwitch.isGlobalUnicastV6Dst(buf, n) else { return .pass }
            let g = portGovernance(src)
            guard let pid = g.pid, g.inspected else { return .pass }
            fireEgress(port: src, profileID: pid, dstIP: 0, hostnames: [],
                       proto: 41, dport: 0, denied: true, policy: nil)
            return .consumed      // drop
        }

        // ---- IPv4 ----
        guard ethertype == 0x0800, n >= 14 + 20 else { return .pass }
        let ihl = Int(buf[14] & 0x0F) * 4
        guard ihl >= 20, n >= 14 + ihl else { return .pass }
        let dstIP = VMNetSwitch.u32(buf, 14 + 16)
        // On-subnet. macOS sends it the native way: vmnet's subnet is closed.
        // Here every frame that isn't a peer's goes to passt, which NATs it
        // into a host connect() to that address on the server's own network
        // (the gateway's on any port, any unleased .x). So only a leased
        // peer and the gateway's DNS pass; a subnet broadcast reaches the
        // peers only; anything else is refused, for every port.
        if (dstIP & subnetMask) == (gatewayIP & subnetMask) {
            return closesSubnet ? onSubnet(buf, n, dstIP, src) : .pass
        }

        let g = portGovernance(src)
        guard let pid = g.pid else { return .pass }          // non-session → native

        let hostnames = dnsCache.names(for: dstIP)
        let ipProto = buf[14 + 9]
        // An IP fragment (MF set, or a non-zero fragment offset) can't be
        // filtered or inspected as a whole.
        let fragmented = (VMNetSwitch.u16(buf, 14 + 6) & 0x3FFF) != 0
        let l4 = fragmented ? nil : VMNetSwitch.offSubnetL4(buf, n)
        let dport = l4?.2 ?? 0

        // Close the transports that would skip the firewall + MiTM on an
        // inspected VM: any IP fragment, and QUIC / HTTP-3 (UDP :443).
        if g.inspected,
           VMNetSwitch.isEgressBypassTransport(fragmented: fragmented, ipProto: ipProto, dport: dport) {
            fireEgress(port: src, profileID: pid, dstIP: dstIP, hostnames: hostnames,
                       proto: ipProto, dport: dport, denied: true, policy: nil)
            return .consumed      // drop QUIC / fragment
        }

        // Non-TCP/UDP protocols (ICMP / GRE / SCTP / 6in4) can't be filtered
        // by the L4 rules or MiTM'd; they stay on the native path.
        guard let (proto, _, _) = l4 else { return .pass }

        let ep: EgressPolicy.Proto = proto == 6 ? .tcp : .udp
        let now = Date()
        var verdict = g.policy?.verdict(ip: dstIP, hostnames: hostnames, proto: ep, port: dport, now: now) ?? .allow
        // `policy.local` (the OpenShell advisor) is answered by the MiTM itself.
        if proto == 6, dport == 80, dstIP == EgressPolicy.advisorAddress, g.policy?.openShell != nil,
           g.interceptor != nil {
            verdict = .allow
        }

        // An OpenShell policy is keyed by hostname, which the snooped DNS
        // cache may not hold for this address: on an intercepted port the
        // MiTM re-decides with the TLS SNI / Host header (and fails closed on
        // flows that carry neither), so the flow is handed over.
        if verdict == .deny, proto == 6, g.policy?.defersToInterception(port: dport) == true,
           g.interceptor != nil, g.interceptPorts.contains(dport) {
            verdict = .allow
        }

        // Binary identity: a new TCP connection the MiTM won't see is decided
        // for the program that opened it. Linux has no attestor gate, so a
        // new one (its SYN) is denied, as macOS denies it without one; later
        // segments of a flow nothing allowed take the verdict below.
        if proto == 6, let policy = g.policy, policy.enforceBinaries,
           !(g.interceptor != nil && g.interceptPorts.contains(dport)), Self.isSyn(buf, n) {
            fireEgress(port: src, profileID: pid, dstIP: dstIP, hostnames: hostnames,
                       proto: proto, dport: dport, denied: true, policy: g.policy, ep: ep, now: now)
            if Self.isSyn(buf, n) { inject(src, VMNetSwitch.buildTCPReset(buf, n)) }
            return .consumed
        }

        let tcpFlags = proto == 6 ? Self.tcpFlags(buf, n) : nil
        if verdict == .deny {
            // Any TCP segment but a fresh SYN belongs to a flow that was open.
            let midFlow = tcpFlags.map { VMNetSwitch.denyReset(tcpFlags: $0) != .syn } ?? false
            fireEgress(port: src, profileID: pid, dstIP: dstIP, hostnames: hostnames,
                       proto: proto, dport: dport, denied: true, policy: g.policy, ep: ep, now: now,
                       midFlow: midFlow)
            if proto == 6 {
                switch VMNetSwitch.denyReset(tcpFlags: tcpFlags) {
                case .syn:                                     // fail the connect fast
                    inject(src, VMNetSwitch.buildTCPReset(buf, n))
                case .established:
                    // Allowed when it opened, denied now: cut it rather than
                    // let it hang, and drop the MiTM's half of a diverted flow
                    // so its upstream connection closes too.
                    inject(src, VMNetSwitch.buildTCPReset(buf, n, established: true))
                    if let intercept = g.interceptor, g.interceptPorts.contains(dport) {
                        intercept.flowDenied(portID: src.portID,
                                             ipPacket: [UInt8](UnsafeBufferPointer(start: buf + 14, count: n - 14)))
                    }
                case .none:
                    break
                }
            }
            return .consumed                                   // dropped
        }

        // Allow verdicts are only worth a row when the firewall is actually on.
        if VMNetSwitch.reportsAllowedFlows(g.policy) {
            fireEgress(port: src, profileID: pid, dstIP: dstIP, hostnames: hostnames,
                       proto: proto, dport: dport, denied: false, policy: g.policy, ep: ep, now: now,
                       newConnection: VMNetSwitch.denyReset(tcpFlags: tcpFlags) == .syn)
        }

        // Allowed: divert intercepted TCP into the MiTM (which re-checks the
        // host + `web` rules); otherwise the switch forwards it.
        if let intercept = g.interceptor, proto == 6, g.interceptPorts.contains(dport) {
            let ipPacket = [UInt8](UnsafeBufferPointer(start: buf + 14, count: n - 14))
            intercept.handleDivertedPacket(portID: src.portID, profileID: pid, ipPacket: ipPacket)
            return .consumed
        }
        return .pass
    }

    /// An on-subnet IPv4 frame from `src` (see decide).
    // @port-skip linux-only: the closed subnet vmnet gives macOS, kept on a switch whose uplink is passt
    private func onSubnet(_ buf: UnsafeMutablePointer<UInt8>, _ n: Int, _ dstIP: UInt32, _ src: MAC) -> Action {
        // A peer VM, a cluster's LoadBalancer address, the subnet broadcast:
        // to the peers only, never the uplink (an unknown MAC is flooded to
        // the peers, and a frame to the guest's own address or to a peer's
        // behind the gateway's MAC would otherwise reach passt).
        if dstIP == gatewayIP | ~subnetMask { return .peersOnly }
        if dstIP != gatewayIP, isLeased(dstIP, src) || isReserved(dstIP) { return .peersOnly }
        let l4 = VMNetSwitch.offSubnetL4(buf, n)
        if dstIP == gatewayIP, let l4, l4.2 == 53 { return .pass }          // DNS (passt forwards it)
        // Refused: answered at once for a TCP connect, reported for a session port.
        if let l4, l4.0 == 6, Self.isSyn(buf, n) { inject(src, VMNetSwitch.buildTCPReset(buf, n)) }
        if let pid = portGovernance(src).pid {
            fireEgress(port: src, profileID: pid, dstIP: dstIP, hostnames: [],
                       proto: l4?.0 ?? buf[14 + 9], dport: l4?.2 ?? 0, denied: true, policy: nil)
        }
        return .consumed
    }

    /// A port's egress governance, snapshotted under the lock. `interceptor`
    /// is nil when the port opted out of transparent interception.
    /// `inspected` gates the bypass drops: the VM is MiTM-intercepted OR
    /// carries an active egress policy.
    // @port VMNetSwitch.portGovernance(_: Int) h=0ef13523a0580e1a @ac3ea65d
    private func portGovernance(_ src: MAC)
        -> (pid: UUID?, policy: EgressPolicy?, interceptor: (any VMNetTCPInterceptor)?,
            interceptPorts: Set<UInt16>, inspected: Bool) {
        lock.withLock {
            guard let g = governance[src] else { return (nil, nil, nil, [], false) }
            let interceptor = g.interceptDisabled ? nil : interception?.interceptor
            let inspected = interceptor != nil || (g.policy?.isActive ?? false)
            // An OpenShell policy inspects its L7 endpoints on whatever port
            // they use, not only 80/443.
            let base = interception?.ports ?? []
            let ports = interceptor == nil ? base : base.union(g.policy?.inspectedPorts ?? [])
            return (g.profileID, g.policy, interceptor, ports, inspected)
        }
    }

    /// Report a new flow, deduped per (port, destination, port, proto) — the
    /// destination being the looked-up name, else the IP — separately for
    /// allow vs deny, so a state change re-logs.
    // @port VMNetSwitch.fireEgress(portID: Int, profileID: UUID?, dstIP: UInt32, hostnames: [String], proto: UInt8, port: UInt16, denied: Bool, policy: EgressPolicy?, ep: EgressPolicy.Proto, now: Date, midFlow: Bool, newConnection: Bool, exe: String?) h=e98bdbd973efaa44 @ac3ea65d
    private func fireEgress(port: MAC, profileID: UUID, dstIP: UInt32, hostnames: [String],
                            proto: UInt8, dport: UInt16, denied: Bool,
                            policy: EgressPolicy?, ep: EgressPolicy.Proto = .any, now: Date = Date(),
                            midFlow: Bool = false, newConnection: Bool = false) {
        let name = hostnames.first ?? ""
        let key = EgressKey(port: port, name: name, dstIP: name.isEmpty ? dstIP : 0,
                            // A dying flow's trailing segments dedupe apart
                            // from fresh connections.
                            dstPort: dport, proto: (denied ? proto | 0x80 : proto) | (midFlow ? 0x40 : 0))
        let fresh: Bool = lock.withLock {
            guard now.timeIntervalSince(egressSeen[key] ?? .distantPast) >= Self.egressReportEvery else { return false }
            if egressSeen.count > 8192 {
                egressSeen = egressSeen.filter { now.timeIntervalSince($0.value) < Self.egressReportEvery }
            }
            egressSeen[key] = now
            return true
        }
        guard fresh else {
            if newConnection, !denied {
                var event = VMNetSwitch.EgressEvent.of(profileID: profileID, dstIP: dstIP, hostnames: hostnames,
                                                       proto: proto, port: dport, denied: false)
                event.rule = policy?.firstMatch(ip: dstIP, hostnames: hostnames, proto: ep, port: dport, now: now)?.text
                event.isRepeat = true
                observer(event)
            }
            return
        }
        var event = VMNetSwitch.EgressEvent.of(profileID: profileID, dstIP: dstIP, hostnames: hostnames,
                                               proto: proto, port: dport, denied: denied)
        event.midFlow = midFlow
        if let policy {
            event.rule = policy.firstMatch(ip: dstIP, hostnames: hostnames, proto: ep, port: dport, now: now)?.text
        } else {
            event.byPolicy = false
        }
        observer(event)
    }

    // @port-skip linux-only: VMNetSwitch.tcpFlags (shared) on this file's pointer
    private static func tcpFlags(_ buf: UnsafeMutablePointer<UInt8>, _ n: Int) -> UInt8? {
        VMNetSwitch.tcpFlags(buf, n)
    }

    // @port-skip linux-only: VMNetSwitch.isTCPSyn (shared) on this file's pointer
    private static func isSyn(_ buf: UnsafeMutablePointer<UInt8>, _ n: Int) -> Bool {
        VMNetSwitch.isTCPSyn(buf, n)
    }
}

extension SwitchEgressFirewall.Governance {
    /// A session VM's port governance, from its workspace (macOS: the
    /// attachPort arguments UbuntuSandboxVM passes).
    // @port-skip linux-only: UbuntuSandboxVM's attachPort(profileID:egressPolicy:interceptDisabled:) arguments
    init(_ profile: Profile) {
        self.init(profileID: profile.id, policy: profile.resolvedEgressPolicy,
                  interceptDisabled: profile.effectiveDisableTransparentProxy)
    }
}

extension MAC {
    /// The port id an interceptor keys a VM's flows by (macOS: the switch's
    /// port index): the MAC's 48 bits, unique per attached VM.
    // @port-skip linux-only: the Linux switch keys ports by MAC
    var portID: Int { Int(truncatingIfNeeded: raw) }
}
