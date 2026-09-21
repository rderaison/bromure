import Foundation
import CVmnet

/// A raw Ethernet presence on the Mac's physical LAN, owned by this process:
/// a vmnet interface in bridged mode with nobody's VM behind it. Frames the
/// LAN sends to the tap's MAC (or broadcast) arrive in `onFrame`; anything
/// written goes out on the wire with the tap's own MAC. The host kernel never
/// sees these addresses — nothing bound on the Mac is reachable through them.
///
/// Used by the Kubernetes LAN load balancer to do what MetalLB's speaker does:
/// answer ARP for service IPs and terminate their TCP flows in userspace.
/// Needs only the vmnet entitlement the app already ships; no root, no
/// interface aliases.
public final class LANTap: @unchecked Sendable {
    public let interfaceName: String
    /// The MAC vmnet assigned (locally administered when it didn't).
    public private(set) var macAddress: [UInt8] = [0x02, 0x62, 0x72, 0x6d, 0x00, 0x00]
    public private(set) var maxPacketSize = 1600

    private var iface: interface_ref?
    private let queue = DispatchQueue(label: "io.bromure.lantap", qos: .userInitiated)
    private let onFrame: ([UInt8]) -> Void
    private var stopped = false
    private let writeLock = NSLock()

    /// Start a bridged interface on `interfaceName` (e.g. "en0"). nil when
    /// vmnet refuses (no entitlement, interface not bridgeable, Wi-Fi quirks).
    public init?(interfaceName: String, onFrame: @escaping ([UInt8]) -> Void) {
        self.interfaceName = interfaceName
        self.onFrame = onFrame

        let desc = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_uint64(desc, vmnet_operation_mode_key, UInt64(kVmnetBridgedMode))
        xpc_dictionary_set_string(desc, vmnet_shared_interface_name_key, interfaceName)

        let sem = DispatchSemaphore(value: 0)
        var ok = false
        var mac: String?
        var maxSize = 0
        iface = vmnet_start_interface(desc, queue) { status, params in
            if status == vmnet_return_t(rawValue: kVmnetSuccess) {
                ok = true
                if let params {
                    maxSize = Int(xpc_dictionary_get_uint64(params, vmnet_max_packet_size_key))
                    if let s = xpc_dictionary_get_string(params, vmnet_mac_address_key) {
                        mac = String(cString: s)
                    }
                }
            } else {
                print("[LANTap] vmnet bridged start on \(interfaceName) failed: \(status.rawValue)")
            }
            sem.signal()
        }
        sem.wait()
        guard ok, let iface else { return nil }
        if maxSize > 0 { maxPacketSize = maxSize }
        if let mac, let parsed = Self.parseMAC(mac) {
            macAddress = parsed
        } else {
            // Locally administered, random — a MAC only this tap answers for.
            macAddress = [0x02, 0x62, UInt8.random(in: 0...255), UInt8.random(in: 0...255),
                          UInt8.random(in: 0...255), UInt8.random(in: 0...255)]
        }
        vmnet_interface_set_event_callback(iface, interface_event_t(rawValue: kVmnetInterfacePacketsAvail), queue) { [weak self] _, _ in
            self?.drain()
        }
        print("[LANTap] up on \(interfaceName) as \(Self.macString(macAddress))")
    }

    public var macString: String { Self.macString(macAddress) }

    public func write(_ frame: [UInt8]) {
        guard !stopped, let iface else { return }
        var bytes = frame
        // Pad runts to the Ethernet minimum; some NICs drop shorter frames.
        if bytes.count < 60 { bytes.append(contentsOf: [UInt8](repeating: 0, count: 60 - bytes.count)) }
        writeLock.lock(); defer { writeLock.unlock() }
        bytes.withUnsafeMutableBytes { raw in
            var iov = iovec(iov_base: raw.baseAddress, iov_len: raw.count)
            var count: Int32 = 1
            withUnsafeMutablePointer(to: &iov) { iovPtr in
                var pkt = vmpktdesc(vm_pkt_size: raw.count, vm_pkt_iov: iovPtr, vm_pkt_iovcnt: 1, vm_flags: 0)
                _ = vmnet_write(iface, &pkt, &count)
            }
        }
    }

    public func stop() {
        guard !stopped else { return }
        stopped = true
        if let iface {
            vmnet_stop_interface(iface, queue) { _ in }
            self.iface = nil
        }
    }

    deinit { stop() }

    private func drain() {
        guard let iface, !stopped else { return }
        let bufSize = maxPacketSize
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }
        while !stopped {
            var iov = iovec(iov_base: buf, iov_len: bufSize)
            var count: Int32 = 1
            var size = 0
            let ret = withUnsafeMutablePointer(to: &iov) { iovPtr -> vmnet_return_t in
                var pkt = vmpktdesc(vm_pkt_size: bufSize, vm_pkt_iov: iovPtr, vm_pkt_iovcnt: 1, vm_flags: 0)
                let r = vmnet_read(iface, &pkt, &count)
                size = pkt.vm_pkt_size
                return r
            }
            guard ret == vmnet_return_t(rawValue: kVmnetSuccess), count > 0, size >= 14 else { break }
            onFrame(Array(UnsafeBufferPointer(start: buf, count: size)))
        }
    }

    public static func parseMAC(_ s: String) -> [UInt8]? {
        let parts = s.split(separator: ":")
        guard parts.count == 6 else { return nil }
        var out: [UInt8] = []
        for p in parts {
            guard let b = UInt8(p, radix: 16) else { return nil }
            out.append(b)
        }
        return out
    }

    public static func macString(_ m: [UInt8]) -> String {
        m.map { String(format: "%02x", $0) }.joined(separator: ":")
    }
}
