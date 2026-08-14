import CVmnet
import Foundation
import Virtualization

private let switchDebug = ProcessInfo.processInfo.environment["BROMURE_SWITCH_DEBUG"] != nil

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
}

/// Process-wide host-side L2 software switch that multiplexes many VMs onto a
/// single shared vmnet (NAT) interface.
///
/// **Why this exists.** Bringing up one vmnet/NAT context per VM — whether via
/// Apple's `VZNATNetworkDeviceAttachment` or a per-VM `NetworkFilter` — gives
/// each VM its *own* DHCP server, and each independently hands out the low
/// address (`.2`) first. Every VM then lands on `192.168.<x>.2` in its own
/// island, so they collide on IP *and* can't see each other.
///
/// Putting every VM behind a **single** vmnet interface fixes all of that at
/// once:
///   * one L2 segment  → VMs reach each other directly (the goal for AC)
///   * one DHCP server  → vmnet leases a distinct IP per MAC
///   * one NAT egress   → internet still works
///
/// Each VM connects through a UNIX-datagram socketpair (its `vmFileHandle` is
/// handed to `VZFileHandleNetworkDeviceAttachment`). The switch is a standard
/// MAC-learning bridge: it learns source-MAC → port from every frame, then
/// forwards VM→VM directly, VM→internet to the vmnet uplink, vmnet→VM by
/// destination MAC, flooding broadcast / multicast / not-yet-learned unicast.
///
/// vmnet's built-in DHCP can't be used here: in shared mode its `bootpd`
/// tracks only one lease per interface, so every multiplexed VM is handed the
/// same IP. We pin the interface to a `192.168.<octet>.0/24` of our choosing
/// (default 64, walking down past any subnet the host is on) and serve DHCP
/// ourselves — see the DHCP section below.
///
/// Requires the `com.apple.developer.networking.vmnet` entitlement.
public final class VMNetSwitch: @unchecked Sendable {
    public static let shared = VMNetSwitch()

    /// Pseudo-port representing the vmnet uplink (gateway + internet + DHCP).
    /// Learned MACs that map here are reachable only by writing to vmnet.
    private static let uplinkPortID = -1

    private final class Port {
        let id: Int
        let hostFD: Int32
        let vmFileHandle: FileHandle
        let readQueue: DispatchQueue
        var stopped = false
        init(id: Int, hostFD: Int32, vmFileHandle: FileHandle) {
            self.id = id
            self.hostFD = hostFD
            self.vmFileHandle = vmFileHandle
            self.readQueue = DispatchQueue(label: "io.bromure.vmnetswitch.port\(id)", qos: .userInteractive)
        }
    }

    private let lock = NSLock()
    private var ports: [Int: Port] = [:]
    private var portByHandle: [ObjectIdentifier: Int] = [:]
    /// Learned forwarding table: 48-bit MAC (packed into a UInt64) → port id.
    private var macTable: [UInt64: Int] = [:]
    private var nextPortID = 0

    /// port id → the profile that owns the VM on it (set at `attachPort`). Lets
    /// the transparent interceptor attribute a diverted flow to a profile with a
    /// direct lookup — no srcIP→MAC→port chain. Guarded by `lock`.
    private var portProfileID: [Int: UUID] = [:]
    /// port id → the VM's source MAC (packed), learned from its frames. Used as
    /// the destination MAC when injecting reply frames into a port. Guarded by
    /// `lock`.
    private var portGuestMAC: [Int: UInt64] = [:]

    /// Optional TCP interceptor (AgentCoding installs one). When set, unicast
    /// IPv4/TCP frames bound off-subnet to a port in `interceptPorts` are diverted
    /// to it instead of the vmnet uplink. Guarded by `lock`.
    private var interceptor: VMNetTCPInterceptor?
    private var interceptPorts: Set<UInt16> = []

    /// Egress firewall. Per-VM `EgressPolicy` (set at `attachPort`) decides
    /// allow/deny for each new off-subnet flow; the observer is fired once per new
    /// destination tuple for the Security Logs window + cloud upload. Guarded by
    /// `lock`.
    public struct EgressEvent: Sendable {
        public let profileID: UUID?
        public let dstIP: UInt32
        public let hostnames: [String]   // DNS-snooped names for dstIP (may be empty)
        public let proto: UInt8          // 6 = TCP, 17 = UDP
        public let port: UInt16
        public let denied: Bool          // true = blocked by the policy
    }
    public typealias EgressObserver = @Sendable (EgressEvent) -> Void
    private var egressObserver: EgressObserver?
    private struct EgressKey: Hashable { let portID: Int; let dstIP: UInt32; let dstPort: UInt16; let proto: UInt8 }
    private var egressSeen: Set<EgressKey> = []
    /// port id → firewall rules (nil = allow-all). Guarded by `lock`.
    private var portEgressPolicy: [Int: EgressPolicy] = [:]
    /// IPv4 → hostnames learned from the guest's DNS answers, for hostname rule
    /// matching across all protocols. Own lock (not `lock`).
    private let dnsCache = DNSSnoopCache()

    private var vmnetInterface: interface_ref?
    private let vmnetQueue = DispatchQueue(label: "io.bromure.vmnetswitch.vmnet", qos: .userInteractive)
    /// Serializes `vmnet_write` across all VM read loops.
    private let vmnetWriteLock = NSLock()
    private var maxPacketSize = 1600
    private var started = false

    // MARK: - Per-app policy (resolved before the interface starts)

    /// Walk the subnet's third octet *up* (65…126) instead of *down* (64…2).
    /// Bromure Web sets this so it never shares a band with AC (which walks
    /// down). Defaults to AC's downward search.
    private var ascendingSubnet = false
    /// Forward frames directly between VMs on the switch. AC wants its VMs to
    /// reach each other; Bromure Web keeps every ephemeral session mutually
    /// unreachable, so it disables peer forwarding (internet egress still flows).
    private var bridgePeers = true
    /// When set, pin `192.168.<octet>.0/24` (if that octet is free of the host's
    /// own LANs). The fat client pins its browser switch to a fixed octet so the
    /// gateway address is deterministic before the VM boots — the browser-pane
    /// PAC and the SOCKS forwarder both reference it.
    private var pinnedOctet: UInt8?

    /// How the (unpinned) NAT subnet is chosen. `.classC192` is the historical
    /// `192.168.<octet>` walk (Bromure Web, and AC's own default). `.randomClassB172`
    /// makes AC pick a persisted random `/24` within `172.16.0.0/12` so multiple
    /// bromure installs don't all collide on `192.168.64.0/24` when one rich
    /// client VPNs to several at once. Only AC opts in (see `setSubnetStrategy`).
    public enum SubnetStrategy: Sendable { case classC192, randomClassB172 }
    private var subnetStrategy: SubnetStrategy = .classC192

    // MARK: - DHCP (we serve it ourselves)

    /// vmnet's built-in `bootpd` only tracks a *single* lease per interface, so
    /// every VM multiplexed onto our one shared interface gets handed the same
    /// IP. We bypass it entirely: the switch intercepts client DHCP (UDP/67)
    /// and answers from its own per-MAC lease table below. We pin the interface
    /// to a known subnet so the gateway (vmnet uses the subnet's start address)
    /// is deterministic and we can hand it out as router + DNS. The third octet
    /// is chosen once in `startVmnetLocked` (default 64, walking *down* past any
    /// `192.168.x` the host already uses — Bromure Web walks *up* into 65…126).
    private var gatewayIP: UInt32 = 0xC0A8_4001     // 192.168.64.1
    private let subnetMask: UInt32 = 0xFFFF_FF00    // 255.255.255.0
    private var dhcpPoolStart: UInt32 = 0xC0A8_4002 // 192.168.64.2
    private var dhcpPoolEnd: UInt32 = 0xC0A8_40FE   // 192.168.64.254
    /// MAC (packed) → leased IPv4, so a client's REQUEST and later renewals get
    /// the same address its DISCOVER was offered. Guarded by `lock`.
    private var dhcpLeases: [UInt64: UInt32] = [:]
    /// Optional sqlite backing for `dhcpLeases` so a MAC keeps its IP across
    /// agent restarts (set via `enablePersistentLeases(at:)`, opened when the
    /// interface starts). nil = in-memory only.
    private var leaseStoreURL: URL?
    private var leaseStore: DHCPLeaseStore?
    /// Locally-administered MAC we send DHCP replies from. The real default
    /// route (gateway IP) still resolves to vmnet's own gateway MAC via ARP, so
    /// routing and NAT egress are unaffected by this synthetic address.
    private static let dhcpServerMAC: [UInt8] = [0x02, 0x62, 0x72, 0x6d, 0x72, 0x01]
    private static let dhcpLeaseSeconds: UInt32 = 86_400  // 24h; VMs are ephemeral

    private init() {}

    // MARK: - Configuration

    /// Opt into a non-default policy. Must be called before the first
    /// `attachPort()` (no-op once the interface has started). Bromure Web calls
    /// this to walk the subnet up and isolate its VMs; AC relies on the defaults.
    public func configure(ascendingSubnet: Bool, bridgePeers: Bool, pinnedOctet: UInt8? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        self.ascendingSubnet = ascendingSubnet
        self.bridgePeers = bridgePeers
        self.pinnedOctet = pinnedOctet
    }

    /// AC-only opt-in: put the shared NAT interface on a persisted random `/24`
    /// within `172.16.0.0/12` (skipping Docker's `172.17–172.20` and any `/24`
    /// the host is already on) instead of `192.168.64.0/24`. Because
    /// `VMNetSwitch.shared` is a per-process singleton and only AC calls this,
    /// Bromure Web keeps its `192.168.x` walk untouched. A pinned browser switch
    /// (the fat client) stays in `192.168` — its subnet is local to the rich
    /// client and can't collide with a remote's workspace subnet. No-op once the
    /// interface has started; call once at process startup before any VM boots.
    public func setSubnetStrategy(_ strategy: SubnetStrategy) {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        subnetStrategy = strategy
    }

    /// Persist DHCP leases to a sqlite db at `url` so a MAC keeps its IP across
    /// agent restarts. Must be called before the interface starts (i.e. before
    /// the first `attachPort()`); a no-op afterwards.
    public func enablePersistentLeases(at url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        self.leaseStoreURL = url
    }

    /// The subnet the shared interface is leasing from, once started. Lets a
    /// switch-backed `NetworkFilter` build its filter rules from the real
    /// gateway/network/mask instead of guessing.
    public var subnet: VmnetSubnet? {
        lock.lock()
        defer { lock.unlock() }
        guard started else { return nil }
        return VmnetSubnet(gateway: gatewayIP, mask: subnetMask, poolEnd: dhcpPoolEnd)
    }

    // MARK: - Port lifecycle

    /// Attach a new VM to the switch.
    ///
    /// Returns a `FileHandle` to pass to `VZFileHandleNetworkDeviceAttachment`,
    /// or `nil` if the shared vmnet interface can't be started (e.g. missing
    /// entitlement) — callers should fall back to `VZNATNetworkDeviceAttachment`.
    public func attachPort(profileID: UUID? = nil, egressPolicy: EgressPolicy? = nil) -> FileHandle? {
        lock.lock()

        if !started {
            // Start the shared interface while holding the lock so two
            // concurrent attaches can't race two interfaces into existence.
            // We deliberately don't latch a permanent failure: the vmnet
            // entitlement can take a moment to become effective right after
            // Gatekeeper approval, so a later attach is allowed to retry.
            guard startVmnetLocked() else {
                lock.unlock()
                print("[VMNetSwitch] vmnet interface failed to start — caller should fall back to NAT")
                return nil
            }
            started = true
        }

        var fds: [Int32] = [0, 0]
        guard fds.withUnsafeMutableBufferPointer({ buf in
            Darwin.socketpair(AF_UNIX, SOCK_DGRAM, 0, buf.baseAddress!)
        }) == 0 else {
            lock.unlock()
            print("[VMNetSwitch] socketpair failed: \(errno)")
            return nil
        }
        let vmSideFD = fds[0]
        let hostFD = fds[1]

        var bufSize: Int32 = 1024 * 1024
        for fd in [vmSideFD, hostFD] {
            setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        }

        // closeOnDealloc is deliberately false: `detachPort` is the single owner
        // of this fd's lifecycle and closes it explicitly. If the FileHandle
        // also closed on dealloc, a delayed dealloc (the caller's NetworkFilter
        // can outlive the session) would close(2) an fd number the OS may have
        // already recycled for another port — silently breaking that session.
        let handle = FileHandle(fileDescriptor: vmSideFD, closeOnDealloc: false)
        let id = nextPortID
        nextPortID += 1
        let port = Port(id: id, hostFD: hostFD, vmFileHandle: handle)
        ports[id] = port
        portByHandle[ObjectIdentifier(handle)] = id
        if let profileID { portProfileID[id] = profileID }
        if let egressPolicy { portEgressPolicy[id] = egressPolicy }
        lock.unlock()

        if switchDebug { print("[VMNetSwitch] port \(id) attached (\(ports.count) total)") }

        port.readQueue.async { [weak self] in
            self?.readVMLoop(port)
        }
        return handle
    }

    /// Detach a VM from the switch (call on VM teardown). Closes the host side
    /// of the socketpair and forgets any MACs learned on that port.
    ///
    /// `releaseLease` controls whether the VM's DHCP lease is also freed. Pass
    /// `false` when the VM is only being *suspended* (e.g. AC saving a RAM
    /// snapshot to disk): the resumed VM restores with the same IP without
    /// re-DHCPing, so the lease must stay reserved or another VM could grab that
    /// address while it's away. A real teardown frees it (the default).
    public func detachPort(_ handle: FileHandle, releaseLease: Bool = true) {
        lock.lock()
        guard let id = portByHandle.removeValue(forKey: ObjectIdentifier(handle)),
              let port = ports.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        port.stopped = true
        let macsOnPort = macTable.compactMap { $0.value == id ? $0.key : nil }
        macTable = macTable.filter { $0.value != id }
        portProfileID[id] = nil
        portGuestMAC[id] = nil
        portEgressPolicy[id] = nil
        egressSeen = egressSeen.filter { $0.portID != id }
        let intercept = interceptor
        if releaseLease {
            for m in macsOnPort { dhcpLeases[m] = nil }
        }
        lock.unlock()

        // Let the interceptor tear down any flows it holds for this port before
        // the fd is closed out from under them.
        intercept?.portClosed(portID: id)

        // Closing the host fd unblocks the port's read loop; closing the VM-side
        // fd (which the FileHandle no longer auto-closes) reclaims the second
        // half of the socketpair. detachPort is the single owner of both ends.
        Darwin.close(port.hostFD)
        try? handle.close()
        if switchDebug { print("[VMNetSwitch] port \(id) detached (\(ports.count) remaining)") }
    }

    // MARK: - vmnet lifecycle

    /// Start the single shared vmnet interface in shared (NAT) mode on the
    /// default `192.168.64.0/24` network. Must be called with `lock` held.
    private func startVmnetLocked() -> Bool {
        let desc = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(desc, vmnet_operation_mode_key, UInt64(kVmnetSharedMode))

        // Pick a free /24 (192.168.<octet> by default, or a random 172.16/12
        // one under .randomClassB172), avoiding any the host is really on.
        let base = chooseSubnetBase()
        gatewayIP = base | 1
        dhcpPoolStart = base | 2
        dhcpPoolEnd = base | 254

        // Pin to that subnet so the gateway (= start address, per vmnet) is
        // deterministic. We serve DHCP ourselves, so vmnet's bootpd never sees
        // a request — this just fixes the address space we lease from.
        xpc_dictionary_set_string(desc, vmnet_start_address_key, Self.ipString(gatewayIP))
        xpc_dictionary_set_string(desc, vmnet_end_address_key, Self.ipString(dhcpPoolEnd))
        xpc_dictionary_set_string(desc, vmnet_subnet_mask_key, Self.ipString(subnetMask))
        if switchDebug { print("[VMNetSwitch] using subnet \(Self.ipString(base))/24, gateway \(Self.ipString(gatewayIP))") }

        let sem = DispatchSemaphore(value: 0)
        var success = false

        vmnetInterface = vmnet_start_interface(desc, vmnetQueue) { [weak self] status, params in
            if status == vmnet_return_t(rawValue: kVmnetSuccess) {
                success = true
                if let params, let self {
                    let mps = Int(xpc_dictionary_get_uint64(params, vmnet_max_packet_size_key))
                    self.maxPacketSize = mps == 0 ? 1600 : mps
                }
            } else {
                // NSLog, not print: this failure means every VM silently falls
                // back to NAT (no shared subnet, no /state vmnetSubnet, dead
                // fat-client tunnels) — it must be findable in Console.app on
                // a GUI launch, where stdout goes nowhere.
                NSLog("[VMNetSwitch] vmnet_start_interface failed: status %d", status.rawValue)
            }
            sem.signal()
        }
        sem.wait()

        guard success, vmnetInterface != nil else { return false }
        if switchDebug { print("[VMNetSwitch] shared vmnet started, max packet size \(maxPacketSize)") }

        if let leaseStoreURL {
            // Cap the persisted table at the number of leasable addresses — no
            // point remembering more MACs than the pool can ever serve at once.
            leaseStore = DHCPLeaseStore(
                url: leaseStoreURL, capacity: Int(dhcpPoolEnd - dhcpPoolStart + 1))
        }

        startVmnetReadCallback()
        return true
    }

    private func startVmnetReadCallback() {
        guard let iface = vmnetInterface else { return }
        vmnet_interface_set_event_callback(
            iface,
            interface_event_t(rawValue: kVmnetInterfacePacketsAvail),
            vmnetQueue
        ) { [weak self] _, _ in
            self?.drainVmnetToVMs()
        }
    }

    // MARK: - Forwarding

    /// Blocking loop: read Ethernet frames from one VM and switch them.
    private func readVMLoop(_ port: Port) {
        let bufSize = maxPacketSize
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }

        while !port.stopped {
            let n = Darwin.read(port.hostFD, buf, bufSize)
            guard n > 0 else { break }
            handleFromVM(port.id, buf, n)
        }
    }

    /// Drain all pending frames from the vmnet uplink toward the VMs.
    private func drainVmnetToVMs() {
        let bufSize = maxPacketSize
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }

        while true {
            guard let iface = vmnetInterface else { break }
            var iov = iovec(iov_base: buf, iov_len: bufSize)
            var count: Int32 = 1
            var pktSize = 0
            let ret = withUnsafeMutablePointer(to: &iov) { iovPtr in
                var pkt = vmpktdesc(vm_pkt_size: bufSize, vm_pkt_iov: iovPtr, vm_pkt_iovcnt: 1, vm_flags: 0)
                let r = vmnet_read(iface, &pkt, &count)
                pktSize = pkt.vm_pkt_size
                return r
            }
            guard ret == vmnet_return_t(rawValue: kVmnetSuccess), count > 0 else { break }
            handleFromVmnet(buf, pktSize)
        }
    }

    /// Forward a frame received from VM `srcPortID`.
    private func handleFromVM(_ srcPortID: Int, _ buf: UnsafeMutablePointer<UInt8>, _ n: Int) {
        guard n >= 14 else { return }
        let dst = Self.mac(buf, 0)
        let src = Self.mac(buf, 6)
        learn(src, port: srcPortID)
        recordGuestMAC(src, port: srcPortID)

        // Intercept client DHCP (UDP/67) and answer it ourselves rather than
        // forwarding to vmnet, whose single-lease bootpd hands every VM the
        // same IP. Matching on L4 (not the broadcast bit) also catches unicast
        // renewals addressed to the gateway MAC, so leases stay stable.
        if Self.isDHCPClientFrame(buf, n) {
            handleDHCP(srcPortID, buf, n)
            return
        }

        // Broadcast / multicast (covers ARP + DHCP DISCOVER): always reaches the
        // uplink so the gateway / DHCP server sees it. Only flood peer VMs when
        // peer bridging is on (AC); with it off (Bromure Web) VMs can't even ARP
        // each other, so they stay mutually unreachable.
        if buf[0] & 0x01 != 0 {
            if bridgePeers {
                for fd in peerPortFDs(except: srcPortID) { _ = Darwin.write(fd, buf, n) }
            }
            writeToVmnet(buf, n)
            return
        }

        // Egress firewall + transparent interception for off-subnet flows from a
        // *session* VM. Evaluates the per-profile EgressPolicy (deny → drop+RST),
        // logs the flow, and diverts intercepted TCP (443) into the MiTM. Returns
        // true when it consumed the frame. Broadcast/DHCP/ARP are handled above;
        // same-subnet peer traffic and non-session (bake/installer) ports fall
        // through to the native switch unchanged.
        if handleEgress(srcPortID, buf, n) { return }

        switch lookupPort(forMAC: dst) {
        case Self.uplinkPortID:
            writeToVmnet(buf, n)
        case .some(let dstPort) where dstPort != srcPortID:
            // A frame addressed to a peer VM — deliver only when bridging peers,
            // otherwise drop it to preserve inter-VM isolation.
            if bridgePeers, let fd = portFD(dstPort) { _ = Darwin.write(fd, buf, n) }
        case .some:
            break  // destined back to itself — drop
        case nil:
            // Unknown unicast: always try the uplink; flood peers only when
            // bridging is enabled.
            if bridgePeers {
                for fd in peerPortFDs(except: srcPortID) { _ = Darwin.write(fd, buf, n) }
            }
            writeToVmnet(buf, n)
        }
    }

    /// Forward a frame received from the vmnet uplink toward the VMs.
    private func handleFromVmnet(_ buf: UnsafeMutablePointer<UInt8>, _ n: Int) {
        guard n >= 14 else { return }
        let dst = Self.mac(buf, 0)
        let src = Self.mac(buf, 6)
        learn(src, port: Self.uplinkPortID)

        // Snoop the guest's DNS answers (UDP src port 53) so hostname firewall
        // rules can match by destination IP for every protocol.
        Self.snoopDNSResponse(buf, n, into: dnsCache)

        if buf[0] & 0x01 != 0 {
            for fd in peerPortFDs(except: nil) { _ = Darwin.write(fd, buf, n) }
            return
        }
        if case .some(let dstPort) = lookupPort(forMAC: dst),
           dstPort != Self.uplinkPortID, let fd = portFD(dstPort) {
            _ = Darwin.write(fd, buf, n)
        } else {
            // Unknown unicast from the uplink: flood; VM NICs drop mismatches.
            for fd in peerPortFDs(except: nil) { _ = Darwin.write(fd, buf, n) }
        }
    }

    private func writeToVmnet(_ buf: UnsafeMutablePointer<UInt8>, _ n: Int) {
        vmnetWriteLock.lock()
        defer { vmnetWriteLock.unlock() }
        guard let iface = vmnetInterface else { return }
        var iov = iovec(iov_base: buf, iov_len: n)
        var count: Int32 = 1
        withUnsafeMutablePointer(to: &iov) { iovPtr in
            var pkt = vmpktdesc(vm_pkt_size: n, vm_pkt_iov: iovPtr, vm_pkt_iovcnt: 1, vm_flags: 0)
            vmnet_write(iface, &pkt, &count)
        }
    }

    // MARK: - Subnet selection

    /// The `/24` network address (low byte 0) the interface leases from. A pinned
    /// browser switch and every `.classC192` caller stay in `192.168.<octet>`;
    /// only an unpinned `.randomClassB172` caller (AC opting in) lands in
    /// `172.16.0.0/12`.
    private func chooseSubnetBase() -> UInt32 {
        if subnetStrategy == .randomClassB172, pinnedOctet == nil {
            return Self.persistedRandom172Base(hostUsed: HostNetworkInfo.localPrivate172Slash24s())
        }
        return 0xC0A8_0000 | (UInt32(chooseSubnetOctet()) << 8)   // 192.168.<octet>.0
    }

    /// Choose the third octet for our `192.168.<octet>.0/24` NAT subnet.
    /// Starts at 64 (the historical AC default) and walks *down* — 63, 62, … —
    /// past any `192.168.x` the host is already on, so we never shadow a real
    /// LAN/VPN/bridge the user is connected to. Bromure Web walks *up* into
    /// 65…126, so the two never meet. Falls back to 64 if the whole 2…64 band
    /// is somehow taken (vanishingly unlikely).
    private func chooseSubnetOctet() -> UInt8 {
        Self.selectOctet(ascending: ascendingSubnet, pinned: pinnedOctet,
                         used: HostNetworkInfo.localPrivateClassCOctets())
    }

    /// UserDefaults key holding AC's chosen `/24` network address (a `UInt32`
    /// stored as `Int`). Under `CFFIXED_USER_HOME` this relocates with the rest
    /// of the app's defaults, so two isolated instances get independent subnets.
    public static let subnetBase172DefaultsKey = "vmnet.switch.subnetBase172"

    /// 172.16/12 second octets we'll pick from — 16, then 21…31, skipping
    /// Docker's default bridge range (172.17–172.20).
    private static let allowed172SecondOctets: [UInt32] = [16] + Array(21...31)

    /// The persisted random `/24` in `172.16.0.0/12`, chosen once and reused. It
    /// is re-rolled only if the host has since joined that `/24` (e.g. a VPN or a
    /// Docker bridge moved onto it) — which is exactly the collision this feature
    /// exists to avoid. Persists the choice on first pick.
    public static func persistedRandom172Base(hostUsed: Set<UInt32>) -> UInt32 {
        let d = UserDefaults.standard
        if d.object(forKey: subnetBase172DefaultsKey) != nil {
            let saved = UInt32(bitPattern: Int32(truncatingIfNeeded: d.integer(forKey: subnetBase172DefaultsKey)))
            if isEligible172(saved, hostUsed: hostUsed) { return saved }
        }
        let chosen = randomEligible172(hostUsed: hostUsed)
        d.set(Int(chosen), forKey: subnetBase172DefaultsKey)
        return chosen
    }

    /// Pick (and persist, on first call) AC's random 172.16/12 `/24`, doing the
    /// host-collision scan internally. Convenience for the migration flow and the
    /// Settings display; reuses the saved choice thereafter.
    @discardableResult
    public static func ensureRandom172Base() -> UInt32 {
        persistedRandom172Base(hostUsed: HostNetworkInfo.localPrivate172Slash24s())
    }

    /// Roll a fresh eligible `/24` (172.16/12, not Docker's range, host-free).
    /// Persists it as the new choice; used by the "Randomize" Settings action.
    @discardableResult
    public static func rerollRandom172Base() -> UInt32 {
        let base = randomEligible172(hostUsed: HostNetworkInfo.localPrivate172Slash24s())
        UserDefaults.standard.set(Int(base), forKey: subnetBase172DefaultsKey)
        return base
    }

    /// The persisted `/24` network base formatted as dotted-decimal (e.g.
    /// "172.23.181.0"), or nil if none has been chosen yet. For the Settings UI.
    public static func savedRandom172BaseString() -> String? {
        let d = UserDefaults.standard
        guard d.object(forKey: subnetBase172DefaultsKey) != nil else { return nil }
        let base = UInt32(bitPattern: Int32(truncatingIfNeeded: d.integer(forKey: subnetBase172DefaultsKey)))
        return ipString(base)
    }

    static func randomEligible172(hostUsed: Set<UInt32>) -> UInt32 {
        for _ in 0..<4096 {
            let b2 = allowed172SecondOctets.randomElement()!
            let b3 = UInt32.random(in: 0...255)
            let base = 0xAC10_0000 | ((b2 & 0x0F) << 16) | (b3 << 8)   // 172.<b2>.<b3>.0
            if isEligible172(base, hostUsed: hostUsed) { return base }
        }
        return 0xAC10_0000   // 172.16.0.0/24 last resort
    }

    /// A `/24` (low byte 0) inside 172.16/12, outside Docker's 172.17–172.20, and
    /// not one the host currently occupies.
    static func isEligible172(_ base: UInt32, hostUsed: Set<UInt32>) -> Bool {
        let b2 = (base >> 16) & 0xFF
        return (base & 0x0000_00FF) == 0
            && (base & 0xFFF0_0000) == 0xAC10_0000
            && allowed172SecondOctets.contains(b2)
            && !hostUsed.contains(base)
    }

    /// Pure octet selection: honor `pinned` when it's a valid, host-LAN-free
    /// octet; otherwise walk (up 65→126 when ascending, else down 64→2) skipping
    /// the host's own class-C octets. Extracted so it can be unit-tested without
    /// the entitled vmnet interface.
    static func selectOctet(ascending: Bool, pinned: UInt8?, used: Set<UInt8>) -> UInt8 {
        if let pinned, (2...254).contains(pinned), !used.contains(pinned) { return pinned }
        if ascending {
            for octet in 65...126 where !used.contains(UInt8(octet)) { return UInt8(octet) }
            return 65
        }
        var octet = 64
        while octet >= 2 {
            if !used.contains(UInt8(octet)) { return UInt8(octet) }
            octet -= 1
        }
        return 64
    }

    // MARK: - DHCP server

    /// True for an IPv4/UDP frame destined to the DHCP server port (67).
    private static func isDHCPClientFrame(_ buf: UnsafeMutablePointer<UInt8>, _ n: Int) -> Bool {
        guard n >= 14 + 20 + 8, u16(buf, 12) == 0x0800 else { return false }  // IPv4
        let ihl = Int(buf[14] & 0x0F) * 4
        guard ihl >= 20, n >= 14 + ihl + 8 else { return false }
        guard buf[14 + 9] == 17 else { return false }                        // UDP
        return u16(buf, 14 + ihl + 2) == 67                                  // dport 67
    }

    /// Parse a client DHCP request and write an OFFER/ACK straight back to the
    /// originating port. Never touches vmnet.
    private func handleDHCP(_ srcPortID: Int, _ buf: UnsafeMutablePointer<UInt8>, _ n: Int) {
        let ihl = Int(buf[14] & 0x0F) * 4
        let dhcp = 14 + ihl + 8
        guard n >= dhcp + 240, buf[dhcp] == 1 else { return }                 // BOOTREQUEST
        guard Self.u32(buf, dhcp + 236) == 0x6382_5363 else { return }        // magic cookie

        let xid = Self.u32(buf, dhcp + 4)
        let broadcast = (Self.u16(buf, dhcp + 10) & 0x8000) != 0
        var clientMAC = [UInt8](repeating: 0, count: 6)
        for i in 0..<6 { clientMAC[i] = buf[dhcp + 28 + i] }
        let macKey = Self.mac(buf, dhcp + 28)

        // Option 53 = DHCP message type.
        var msgType: UInt8 = 0
        var i = dhcp + 240
        while i + 1 < n {
            let opt = buf[i]
            if opt == 0xFF { break }            // END
            if opt == 0x00 { i += 1; continue } // PAD
            let len = Int(buf[i + 1])
            if opt == 53, len >= 1, i + 2 < n { msgType = buf[i + 2] }
            i += 2 + len
        }

        let replyType: UInt8
        switch msgType {
        case 1: replyType = 2                   // DISCOVER → OFFER
        case 3: replyType = 5                   // REQUEST  → ACK
        case 7: releaseLease(macKey); return    // RELEASE
        default: return                         // DECLINE / INFORM / etc.
        }

        guard let yourIP = leaseIP(for: macKey) else {
            if switchDebug { print("[VMNetSwitch] DHCP pool exhausted") }
            return
        }

        let frame = Self.buildDHCPReply(
            replyType: replyType, xid: xid, broadcast: broadcast,
            clientMAC: clientMAC, yourIP: yourIP,
            serverIP: gatewayIP, mask: subnetMask, lease: Self.dhcpLeaseSeconds)
        if let fd = portFD(srcPortID) {
            frame.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, $0.count) }
        }
        if switchDebug {
            print("[VMNetSwitch] DHCP \(replyType == 2 ? "OFFER" : "ACK") \(Self.ipString(yourIP)) → port \(srcPortID)")
        }
    }

    /// Stable per-MAC lease from the pool, allocating on first sight.
    private func leaseIP(for mac: UInt64) -> UInt32? {
        lock.lock()
        defer { lock.unlock() }
        if let ip = dhcpLeases[mac] { return ip }
        let taken = Set(dhcpLeases.values)
        // Prefer the address this MAC held last time (persisted across restarts)
        // so a profile's VM keeps the same IP as often as possible — only moving
        // off it if it's taken or no longer inside the current subnet's pool.
        if let persisted = leaseStore?.ip(forMAC: mac),
           persisted >= dhcpPoolStart, persisted <= dhcpPoolEnd,
           persisted != gatewayIP, !taken.contains(persisted) {
            dhcpLeases[mac] = persisted
            return persisted
        }
        var ip = dhcpPoolStart
        while ip <= dhcpPoolEnd {
            if ip != gatewayIP && !taken.contains(ip) {
                dhcpLeases[mac] = ip
                leaseStore?.record(mac: mac, ip: ip)
                return ip
            }
            ip += 1
        }
        return nil
    }

    private func releaseLease(_ mac: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        dhcpLeases[mac] = nil
    }

    /// Build a complete Ethernet/IPv4/UDP/DHCP reply frame.
    private static func buildDHCPReply(
        replyType: UInt8, xid: UInt32, broadcast: Bool,
        clientMAC: [UInt8], yourIP: UInt32,
        serverIP: UInt32, mask: UInt32, lease: UInt32
    ) -> [UInt8] {
        var dhcp = [UInt8](repeating: 0, count: 240)
        dhcp[0] = 2                              // op = BOOTREPLY
        dhcp[1] = 1                              // htype = Ethernet
        dhcp[2] = 6                              // hlen
        putU32(&dhcp, 4, xid)
        if broadcast { dhcp[10] = 0x80 }         // flags: broadcast
        putU32(&dhcp, 16, yourIP)                // yiaddr
        putU32(&dhcp, 20, serverIP)              // siaddr
        for i in 0..<6 { dhcp[28 + i] = clientMAC[i] }  // chaddr
        dhcp[236] = 0x63; dhcp[237] = 0x82; dhcp[238] = 0x53; dhcp[239] = 0x63  // magic cookie

        dhcp += [53, 1, replyType]               // message type
        dhcp += [54, 4] + beBytes(serverIP)      // server identifier
        dhcp += [51, 4] + beBytes(lease)         // lease time
        dhcp += [1, 4] + beBytes(mask)           // subnet mask
        dhcp += [3, 4] + beBytes(serverIP)       // router
        dhcp += [6, 4] + beBytes(serverIP)       // DNS (vmnet gateway forwards)
        // Interface MTU (option 26): udhcpc clamps eth0 at lease time, before
        // anything races the guest-side clamp. Without this the guest keeps
        // the default 1500 and large packets blackhole on the smaller vmnet
        // egress path (LAN peers still work — same-MTU L2). Host-overridable
        // via `vm.mtu` UserDefaults; default 1280.
        let mtu = UInt16(min(9000, max(576, VMConfig.resolvedNICMTU())))
        dhcp += [26, 2, UInt8(mtu >> 8), UInt8(mtu & 0xFF)]
        dhcp += [255]                            // END
        while dhcp.count < 300 { dhcp += [0] }   // pad to BOOTP minimum

        let dstIP: UInt32 = broadcast ? 0xFFFF_FFFF : yourIP

        var udp = [UInt8](repeating: 0, count: 8)
        putU16(&udp, 0, 67)                       // sport
        putU16(&udp, 2, 68)                       // dport
        putU16(&udp, 4, UInt16(8 + dhcp.count))   // length
        let udpck = udpChecksum(srcIP: serverIP, dstIP: dstIP, udp: udp + dhcp)
        putU16(&udp, 6, udpck)

        var ip = [UInt8](repeating: 0, count: 20)
        ip[0] = 0x45                              // ver 4, ihl 5
        putU16(&ip, 2, UInt16(20 + udp.count + dhcp.count))  // total length
        ip[8] = 64                               // ttl
        ip[9] = 17                               // proto UDP
        putU32(&ip, 12, serverIP)                // src
        putU32(&ip, 16, dstIP)                   // dst
        putU16(&ip, 10, checksum(ip))

        let dstMAC: [UInt8] = broadcast ? [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] : clientMAC
        let eth = dstMAC + dhcpServerMAC + [0x08, 0x00]

        return eth + ip + udp + dhcp
    }

    // MARK: - Byte / checksum helpers

    private static func u16(_ b: UnsafeMutablePointer<UInt8>, _ o: Int) -> UInt16 {
        (UInt16(b[o]) << 8) | UInt16(b[o + 1])
    }
    private static func u32(_ b: UnsafeMutablePointer<UInt8>, _ o: Int) -> UInt32 {
        (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
    }
    private static func beBytes(_ v: UInt32) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
    private static func putU16(_ b: inout [UInt8], _ o: Int, _ v: UInt16) {
        b[o] = UInt8((v >> 8) & 0xFF); b[o + 1] = UInt8(v & 0xFF)
    }
    private static func putU32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
        b[o] = UInt8((v >> 24) & 0xFF); b[o + 1] = UInt8((v >> 16) & 0xFF)
        b[o + 2] = UInt8((v >> 8) & 0xFF); b[o + 3] = UInt8(v & 0xFF)
    }
    private static func ipString(_ v: UInt32) -> String {
        "\((v >> 24) & 0xFF).\((v >> 16) & 0xFF).\((v >> 8) & 0xFF).\(v & 0xFF)"
    }

    /// Standard one's-complement checksum (IP header / UDP).
    private static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count { sum += (UInt32(bytes[i]) << 8) | UInt32(bytes[i + 1]); i += 2 }
        if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum & 0xFFFF)
    }

    /// UDP checksum over the IPv4 pseudo-header + UDP datagram (header zeroed).
    private static func udpChecksum(srcIP: UInt32, dstIP: UInt32, udp: [UInt8]) -> UInt16 {
        var data = beBytes(srcIP) + beBytes(dstIP)
        data += [0, 17]                                                   // zero + protocol
        data += [UInt8((udp.count >> 8) & 0xFF), UInt8(udp.count & 0xFF)] // UDP length
        data += udp
        if data.count % 2 != 0 { data += [0] }
        let ck = checksum(data)
        return ck == 0 ? 0xFFFF : ck   // 0 means "no checksum"; send all-ones instead
    }

    // MARK: - Transparent TCP interception

    /// Register (or clear) the interceptor and the TCP destination ports to
    /// divert (e.g. `[443]`, optionally `[80, 6443]`). Passing nil disables
    /// interception. Safe to call at any time; takes effect for subsequent
    /// frames. AgentCoding calls this once at startup with its MiTM forwarder.
    public func setInterceptor(_ interceptor: VMNetTCPInterceptor?, ports: Set<UInt16>) {
        lock.lock()
        defer { lock.unlock() }
        self.interceptor = interceptor
        self.interceptPorts = interceptor == nil ? [] : ports
    }

    /// Register the egress firewall observer — fired once per new off-subnet
    /// destination a session VM opens (allowed or denied), for the Security Logs
    /// window + cloud upload.
    public func setEgressObserver(_ observer: EgressObserver?) {
        lock.lock()
        defer { lock.unlock() }
        self.egressObserver = observer
        egressSeen.removeAll()
    }

    /// Set (or clear) the firewall rules for a VM's port. Live-updatable mid-
    /// session; nil = allow-all.
    public func setEgressPolicy(_ policy: EgressPolicy?, for handle: FileHandle) {
        lock.lock()
        defer { lock.unlock() }
        guard let id = portByHandle[ObjectIdentifier(handle)] else { return }
        portEgressPolicy[id] = policy
    }

    /// Firewall + interception for one off-subnet frame from a session VM.
    /// Returns true when the frame was consumed (dropped by policy, or diverted
    /// into the MiTM); false to let the native switch forward it.
    ///
    /// Only session ports (a profileID) are governed. Bake/installer VMs attach
    /// without one — no firewall, no interception, native path (they also lack
    /// the Bromure CA, so MiTM would break them).
    private func handleEgress(_ srcPortID: Int, _ buf: UnsafeMutablePointer<UInt8>, _ n: Int) -> Bool {
        // IPv6: the firewall only matches IPv4 rules, so a v4 `deny` could be
        // trivially bypassed by the guest's IPv6 fallback. When any policy is
        // active, drop global-unicast v6 egress (the guest then falls back to
        // the filtered IPv4). Link-local / multicast (ND / RA / DHCPv6) pass, so
        // v6 autoconfig still works. Ports with no active policy pass v6 through.
        if Self.u16(buf, 12) == 0x86DD {
            lock.lock()
            let pid = portProfileID[srcPortID]
            let active = pid != nil && (portEgressPolicy[srcPortID]?.isActive ?? false)
            lock.unlock()
            guard active, let pid, Self.isGlobalUnicastV6Dst(buf, n) else { return false }
            fireEgress(portID: srcPortID, profileID: pid, dstIP: 0, hostnames: [],
                       proto: 41, port: 0, denied: true)
            return true      // drop
        }

        guard let (proto, dstIP, dport) = Self.offSubnetL4(buf, n),
              (dstIP & subnetMask) != (gatewayIP & subnetMask) else { return false }

        lock.lock()
        guard let pid = portProfileID[srcPortID] else { lock.unlock(); return false }  // non-session → native
        let policy = portEgressPolicy[srcPortID]
        let intercept = interceptor
        let canIntercept = intercept != nil && proto == 6 && interceptPorts.contains(dport)
        lock.unlock()

        let hostnames = dnsCache.names(for: dstIP)
        let ep: EgressPolicy.Proto = proto == 6 ? .tcp : .udp
        let verdict = policy?.verdict(ip: dstIP, hostnames: hostnames, proto: ep, port: dport) ?? .allow

        if verdict == .deny {
            fireEgress(portID: srcPortID, profileID: pid, dstIP: dstIP, hostnames: hostnames,
                       proto: proto, port: dport, denied: true)
            if proto == 6, Self.isTCPSyn(buf, n) {           // fail the connect fast
                injectIPToPort(srcPortID, ipPacket: Self.buildTCPReset(buf, n))
            }
            return true                                       // dropped
        }

        fireEgress(portID: srcPortID, profileID: pid, dstIP: dstIP, hostnames: hostnames,
                   proto: proto, port: dport, denied: false)

        // Allowed: divert intercepted TCP into the MiTM (the SNI layer re-checks
        // the host + `web` rules); otherwise let the native switch forward it.
        if canIntercept, let intercept {
            let ipPacket = [UInt8](UnsafeBufferPointer(start: buf + 14, count: n - 14))
            intercept.handleDivertedPacket(portID: srcPortID, profileID: pid, ipPacket: ipPacket)
            return true
        }
        return false
    }

    /// Fire the observer for a new flow, deduped per (port, dstIP, port, proto),
    /// separately for allow vs deny so a state change re-logs.
    private func fireEgress(portID: Int, profileID: UUID?, dstIP: UInt32, hostnames: [String],
                            proto: UInt8, port: UInt16, denied: Bool) {
        let key = EgressKey(portID: portID, dstIP: dstIP, dstPort: port, proto: denied ? proto | 0x80 : proto)
        lock.lock()
        guard let observer = egressObserver, !egressSeen.contains(key) else { lock.unlock(); return }
        if egressSeen.count > 8192 { egressSeen.removeAll() }
        egressSeen.insert(key)
        lock.unlock()
        observer(EgressEvent(profileID: profileID, dstIP: dstIP, hostnames: hostnames,
                             proto: proto, port: port, denied: denied))
    }

    /// (proto, dstIP, dstPort) for a unicast IPv4 TCP/UDP frame (first fragment
    /// only), else nil.
    private static func offSubnetL4(_ buf: UnsafeMutablePointer<UInt8>, _ n: Int) -> (UInt8, UInt32, UInt16)? {
        guard n >= 14 + 20, u16(buf, 12) == 0x0800 else { return nil }    // IPv4
        let ihl = Int(buf[14] & 0x0F) * 4
        guard ihl >= 20, n >= 14 + ihl + 4 else { return nil }
        let proto = buf[14 + 9]
        guard proto == 6 || proto == 17 else { return nil }              // TCP/UDP
        guard (u16(buf, 14 + 6) & 0x1FFF) == 0 else { return nil }       // first fragment only
        return (proto, u32(buf, 14 + 16), u16(buf, 14 + ihl + 2))
    }

    private static func isTCPSyn(_ buf: UnsafeMutablePointer<UInt8>, _ n: Int) -> Bool {
        let ihl = Int(buf[14] & 0x0F) * 4
        guard n >= 14 + ihl + 14 else { return false }
        let flags = buf[14 + ihl + 13]
        return (flags & 0x02) != 0 && (flags & 0x10) == 0               // SYN, not ACK
    }

    /// True if an IPv6 frame's destination is a routable (global / ULA) unicast
    /// address — i.e. egress. Link-local (fe80::/10), multicast (ff00::/8), and
    /// loopback/unspecified are local and return false.
    private static func isGlobalUnicastV6Dst(_ buf: UnsafeMutablePointer<UInt8>, _ n: Int) -> Bool {
        let off = 14 + 24                                               // IPv6 dst address
        guard n >= off + 16 else { return false }
        if buf[off] == 0xFF { return false }                           // multicast
        if buf[off] == 0xFE, (buf[off + 1] & 0xC0) == 0x80 { return false }  // fe80::/10
        var allZero = true
        for i in 0..<15 where buf[off + i] != 0 { allZero = false; break }
        if allZero { return false }                                    // :: or ::1
        return true
    }

    /// Snoop a DNS response frame (UDP src port 53) into the IP→hostname cache.
    private static func snoopDNSResponse(_ buf: UnsafeMutablePointer<UInt8>, _ n: Int, into cache: DNSSnoopCache) {
        guard n >= 14 + 20 + 8, u16(buf, 12) == 0x0800 else { return }
        let ihl = Int(buf[14] & 0x0F) * 4
        guard ihl >= 20, buf[14 + 9] == 17, n >= 14 + ihl + 8 else { return }  // UDP
        guard u16(buf, 14 + ihl) == 53 else { return }                        // src port 53
        let dnsOff = 14 + ihl + 8
        guard n > dnsOff else { return }
        let payload = [UInt8](UnsafeBufferPointer(start: buf + dnsOff, count: n - dnsOff))
        for a in DNSSnoop.parseResponse(payload) { cache.record(ip: a.ip, name: a.name, ttl: a.ttl) }
    }

    /// Build an IPv4 TCP RST+ACK toward the guest in response to its SYN, so a
    /// firewall-denied connect fails immediately instead of retransmitting.
    private static func buildTCPReset(_ syn: UnsafeMutablePointer<UInt8>, _ n: Int) -> [UInt8] {
        let ihl = Int(syn[14] & 0x0F) * 4
        let gIP = u32(syn, 14 + 12), dIP = u32(syn, 14 + 16)             // guest, dst
        let sPort = u16(syn, 14 + ihl), dPort = u16(syn, 14 + ihl + 2)
        let gSeq = u32(syn, 14 + ihl + 4)

        var ip = [UInt8](repeating: 0, count: 20 + 20)
        // IPv4 header
        ip[0] = 0x45; ip[2] = 0; ip[3] = 40; ip[8] = 64; ip[9] = 6       // ver/ihl, total len 40, ttl, proto TCP
        putU32(&ip, 12, dIP); putU32(&ip, 16, gIP)                       // src = dst, dst = guest
        putU16(&ip, 10, ipChecksum(ip, 0, 20))
        // TCP header (RST+ACK, seq 0, ack gSeq+1)
        putU16(&ip, 20 + 0, dPort); putU16(&ip, 20 + 2, sPort)
        putU32(&ip, 20 + 4, 0); putU32(&ip, 20 + 8, gSeq &+ 1)
        ip[20 + 12] = 0x50                                               // data offset 5
        ip[20 + 13] = 0x14                                              // RST | ACK
        putU16(&ip, 20 + 16, tcpChecksum(ip, dIP, gIP))
        return ip
    }

    private static func ipChecksum(_ b: [UInt8], _ off: Int, _ len: Int) -> UInt16 {
        var sum: UInt32 = 0
        var i = off
        while i < off + len { sum += UInt32(b[i]) << 8 | UInt32(b[i+1]); i += 2 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum & 0xFFFF)
    }
    private static func tcpChecksum(_ ip: [UInt8], _ src: UInt32, _ dst: UInt32) -> UInt16 {
        var sum: UInt32 = 0
        sum += (src >> 16) + (src & 0xFFFF) + (dst >> 16) + (dst & 0xFFFF)
        sum += 6 + 20                                                    // proto + TCP length
        var i = 20
        while i < 40 { sum += UInt32(ip[i]) << 8 | UInt32(ip[i+1]); i += 2 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum & 0xFFFF)
    }

    /// Inject an IPv4 packet (IP header onward) toward the VM on `portID`, framed
    /// as Ethernet from the DHCP-server MAC to the VM's learned MAC. Called by the
    /// interceptor's userspace TCP stack to deliver reply segments. The guest
    /// accepts inbound frames by destination MAC, so the synthetic source MAC is
    /// fine. One call = one `write` = one datagram = one frame (SOCK_DGRAM is
    /// atomic), so concurrent flows on a port never interleave.
    public func injectIPToPort(_ portID: Int, ipPacket: [UInt8]) {
        lock.lock()
        guard let p = ports[portID], !p.stopped, let guestMAC = portGuestMAC[portID] else {
            lock.unlock()
            return
        }
        let fd = p.hostFD
        lock.unlock()

        var frame = [UInt8]()
        frame.reserveCapacity(14 + ipPacket.count)
        for shift in stride(from: 40, through: 0, by: -8) {
            frame.append(UInt8((guestMAC >> UInt64(shift)) & 0xFF))    // dst = guest
        }
        frame.append(contentsOf: Self.dhcpServerMAC)                    // src = us
        frame.append(0x08); frame.append(0x00)                         // EtherType IPv4
        frame.append(contentsOf: ipPacket)
        frame.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, frame.count) }
    }


    // MARK: - Table helpers (lock-guarded)

    private func learn(_ mac: UInt64, port: Int) {
        lock.lock()
        defer { lock.unlock() }
        if macTable[mac] != port { macTable[mac] = port }
    }

    /// Record the VM's source MAC for `port` (the destination for injected reply
    /// frames). Only called for VM ingress, never the uplink.
    private func recordGuestMAC(_ mac: UInt64, port: Int) {
        lock.lock()
        defer { lock.unlock() }
        if portGuestMAC[port] != mac { portGuestMAC[port] = mac }
    }

    private func lookupPort(forMAC mac: UInt64) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return macTable[mac]
    }

    private func portFD(_ id: Int) -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        guard let p = ports[id], !p.stopped else { return nil }
        return p.hostFD
    }

    /// Host-side fds of every active VM port except `except` (the ingress).
    private func peerPortFDs(except: Int?) -> [Int32] {
        lock.lock()
        defer { lock.unlock() }
        return ports.values.compactMap { $0.id == except || $0.stopped ? nil : $0.hostFD }
    }

    /// Pack the 6-octet MAC at `offset` into a UInt64 for table keys.
    private static func mac(_ buf: UnsafeMutablePointer<UInt8>, _ offset: Int) -> UInt64 {
        (UInt64(buf[offset])     << 40) |
        (UInt64(buf[offset + 1]) << 32) |
        (UInt64(buf[offset + 2]) << 24) |
        (UInt64(buf[offset + 3]) << 16) |
        (UInt64(buf[offset + 4]) <<  8) |
         UInt64(buf[offset + 5])
    }
}
