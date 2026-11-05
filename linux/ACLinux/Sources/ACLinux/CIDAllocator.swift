import NIOConcurrencyHelpers

/// Hands out guest vsock CIDs unique within this daemon. With Firecracker's
/// hybrid vsock a CID is private to its VM (its own Unix socket), so nothing
/// host-wide needs probing by default; the CID also seeds the VM's MAC (and
/// so its DHCP lease), which must be unique on this daemon's switch.
// @port-skip linux-only: guest CIDs (VZ assigns them itself)
public final class CIDAllocator: Sendable {
    // @port-skip linux-only: CID probing
    public enum Probe: Sendable, Equatable {
        case free, inUse
        /// The probe itself failed.
        case unavailable(errno: Int32)
    }

    public static let shared = CIDAllocator()

    /// 0–2 are reserved (hypervisor, local, host); 0xFFFFFFFF is VMADDR_CID_ANY.
    public let range: ClosedRange<UInt32>
    private let probe: @Sendable (UInt32) -> Probe
    private let state: NIOLockedValueBox<(leased: Set<UInt32>, next: UInt32)>

    // @port-skip linux-only: CID allocation
    public init(range: ClosedRange<UInt32> = 3...0xFFFF_FFFE,
                probe: @escaping @Sendable (UInt32) -> Probe = { _ in .free }) {
        precondition(range.lowerBound >= 3 && range.upperBound < 0xFFFF_FFFF)
        self.range = range
        self.probe = probe
        self.state = NIOLockedValueBox((leased: [], next: range.lowerBound))
    }

    /// The next CID that is neither leased here nor in use on the host,
    /// nor one `skip` refuses (another VM record's, which this process may
    /// not have leased: a stopped VM's). When the host can't be probed,
    /// only this process's leases are skipped (the VM's start then reports
    /// a clash).
    // @port-skip linux-only: CID allocation
    public func allocate(skip: (UInt32) -> Bool = { _ in false }) throws -> UInt32 {
        try state.withLockedValue { s in
            let span = UInt64(range.upperBound - range.lowerBound) + 1
            var cid = s.next
            for _ in 0..<min(span, 65_536) {
                defer { cid = cid == range.upperBound ? range.lowerBound : cid + 1 }
                if s.leased.contains(cid) || skip(cid) { continue }
                if probe(cid) == .inUse { continue }
                s.leased.insert(cid)
                s.next = cid == range.upperBound ? range.lowerBound : cid + 1
                return cid
            }
            throw CIDError.exhausted
        }
    }

    /// Leases `cid` for a VM whose Firecracker already holds it (a re-adopted VM):
    /// no probe, which would see that VM and answer in use.
    // @port-skip linux-only: CID leasing
    public func adopt(_ cid: UInt32) -> Bool {
        state.withLockedValue { s in
            guard range.contains(cid), !s.leased.contains(cid) else { return false }
            s.leased.insert(cid)
            return true
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
