import CACLinuxShims
import NIOConcurrencyHelpers

/// Hands out guest vsock CIDs that are free on this host.
///
/// QEMU fails to start on a CID another VM (any process's) already holds, so
/// besides the CIDs leased in this process, each candidate is probed the
/// way QEMU claims it: VHOST_VSOCK_SET_GUEST_CID on a fresh /dev/vhost-vsock
/// fd (EADDRINUSE = taken; closing the fd releases it again).
// @port-skip linux-only: vhost-vsock needs a host-unique CID per guest; VZ assigns them itself
public final class CIDAllocator: Sendable {
    // @port-skip linux-only: CID probing
    public enum Probe: Sendable, Equatable {
        case free, inUse
        /// The probe itself failed (no access to /dev/vhost-vsock, …).
        case unavailable(errno: Int32)
    }

    public static let shared = CIDAllocator()

    /// 0–2 are reserved (hypervisor, local, host); 0xFFFFFFFF is VMADDR_CID_ANY.
    public let range: ClosedRange<UInt32>
    private let probe: @Sendable (UInt32) -> Probe
    private let state: NIOLockedValueBox<(leased: Set<UInt32>, next: UInt32)>

    // @port-skip linux-only: CID allocation
    public init(range: ClosedRange<UInt32> = 3...0xFFFF_FFFE,
                probe: @escaping @Sendable (UInt32) -> Probe = CIDAllocator.vhostProbe) {
        precondition(range.lowerBound >= 3 && range.upperBound < 0xFFFF_FFFF)
        self.range = range
        self.probe = probe
        self.state = NIOLockedValueBox((leased: [], next: range.lowerBound))
    }

    /// Asks the kernel whether `cid` is taken.
    // @port-skip linux-only: CID probing
    public static let vhostProbe: @Sendable (UInt32) -> Probe = { cid in
        let r = acl_vhost_vsock_cid_in_use(UInt64(cid))
        switch r {
        case 0: return .free
        case 1: return .inUse
        default: return .unavailable(errno: -r)
        }
    }

    /// The next CID that is neither leased here nor in use on the host.
    /// When the host can't be probed, only this process's leases are
    /// skipped (QEMU's start then reports a clash).
    // @port-skip linux-only: CID allocation
    public func allocate() throws -> UInt32 {
        try state.withLockedValue { s in
            let span = UInt64(range.upperBound - range.lowerBound) + 1
            var cid = s.next
            for _ in 0..<min(span, 65_536) {
                defer { cid = cid == range.upperBound ? range.lowerBound : cid + 1 }
                if s.leased.contains(cid) { continue }
                if probe(cid) == .inUse { continue }
                s.leased.insert(cid)
                s.next = cid == range.upperBound ? range.lowerBound : cid + 1
                return cid
            }
            throw CIDError.exhausted
        }
    }

    /// Leases `cid` specifically (a resumed VM keeps its CID), if it's free.
    // @port-skip linux-only: CID allocation
    public func claim(_ cid: UInt32) -> Bool {
        state.withLockedValue { s in
            guard range.contains(cid), !s.leased.contains(cid), probe(cid) != .inUse else { return false }
            s.leased.insert(cid)
            return true
        }
    }

    // @port-skip linux-only: CID allocation
    public func release(_ cid: UInt32) {
        _ = state.withLockedValue { $0.leased.remove(cid) }
    }

    // @port-skip linux-only: CID allocation
    public var leased: Set<UInt32> { state.withLockedValue { $0.leased } }
}

// @port-skip linux-only: CID allocation
public enum CIDError: Error { case exhausted }
