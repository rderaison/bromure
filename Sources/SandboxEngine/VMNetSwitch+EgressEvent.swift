import Foundation

// What the switch's egress firewall reports for a flow, and the hook it
// diverts intercepted flows through: shared by the macOS vmnet switch and
// the Linux daemon's switch (and the report both turn an event into,
// SwitchEgressReport).

/// Host-side hook for transparently intercepting guest TCP flows at the switch.
///
/// SandboxEngine cannot depend on AgentCoding, where the userspace TCP stack
/// (`TCPFlow`) and the MiTM live — the dependency is one-way. So the switch
/// classifies and diverts here, and calls out through this protocol; the
/// implementation (which terminates the TCP flow and feeds the MiTM) lives on
/// the AgentCoding side and is registered via `VMNetSwitch.setInterceptor`.
public protocol VMNetTCPInterceptor: AnyObject, Sendable {
    /// A diverted IPv4/TCP packet — IP header onward, no Ethernet framing — from
    /// the VM on `portID`, owned by `profileID` (nil if the port was attached
    /// without one). Reply packets are delivered back with
    /// `VMNetSwitch.injectIPToPort`.
    func handleDivertedPacket(portID: Int, profileID: UUID?, ipPacket: [UInt8])
    /// The VM port was detached — drop any flow state bound to it.
    func portClosed(portID: Int)
    /// The firewall now denies the established diverted flow this packet (IP
    /// header onward) belongs to — a rule was switched off, expired or added
    /// mid-connection. Tear the flow down (and its upstream leg); the switch
    /// has already sent the guest a RST.
    func flowDenied(portID: Int, ipPacket: [UInt8])
}

extension VMNetTCPInterceptor {
    public func flowDenied(portID: Int, ipPacket: [UInt8]) {}
}

extension VMNetSwitch {
    public struct EgressEvent: Sendable {
        public let profileID: UUID?
        public let dstIP: UInt32
        /// DNS-snooped names for dstIP (may be empty), the name the guest
        /// queried first (see `DNSSnoopCache.names`), CNAME targets after.
        public let hostnames: [String]
        public let proto: UInt8          // 6 = TCP, 17 = UDP
        public let port: UInt16
        public let denied: Bool          // true = blocked by the policy
        /// The rule that decided (its `EgressPolicy.Rule.text`); nil when the
        /// default action did, or for a transport drop (`byPolicy` false).
        public var rule: String? = nil
        /// False for the drops that aren't a ruleset decision (IPv6, QUIC,
        /// IP fragments on an inspected VM).
        public var byPolicy: Bool = true
        /// A denied TCP segment of a flow that was already open (not a fresh
        /// SYN): the rules changed under an established connection. The app
        /// folds it into the "connection closed" row the MiTM's cut wrote.
        public var midFlow: Bool = false
        /// A further new connection (TCP SYN) to a destination already
        /// reported within the dedupe window: not a new row, just one more
        /// to count on the allowed row it folds into.
        public var isRepeat: Bool = false
        /// The program the guest's attestor named for a connection the
        /// identity gate denied: the row's Allow names it (never a lookup at
        /// click time, which a later connection could have changed).
        public var exe: String? = nil
    }
    public typealias EgressObserver = @Sendable (EgressEvent) -> Void
}

extension VMNetSwitch.EgressEvent {
    /// A new event (its optional fields at their defaults), for a switch in
    /// another module (the Linux daemon's): the memberwise init is internal.
    public static func of(profileID: UUID?, dstIP: UInt32, hostnames: [String], proto: UInt8, port: UInt16,
                          denied: Bool) -> Self {
        Self(profileID: profileID, dstIP: dstIP, hostnames: hostnames, proto: proto, port: port, denied: denied)
    }
}
