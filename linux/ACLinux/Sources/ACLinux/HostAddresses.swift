import Foundation
import NIOConcurrencyHelpers

/// The host's own IPv4 addresses (every interface's, loopback and 0.0.0.0/8
/// included), re-read at most every 5 s: what a multi-user server's guests
/// may not reach. passt would otherwise connect to them like any address, and
/// the host's services (the gateway, other users' anything) would answer.
// @port-skip linux-only: multi-user isolation (macOS is single-user)
public final class HostAddresses: Sendable {
    public static let shared = HostAddresses()
    private let cache = NIOLockedValueBox<(set: Set<UInt32>, at: ContinuousClock.Instant)>(([], .now - .seconds(60)))
    private let cache6 = NIOLockedValueBox<(set: Set<[UInt8]>, at: ContinuousClock.Instant)>(([], .now - .seconds(60)))

    // @port-skip linux-only: multi-user isolation
    public func contains(_ ip: UInt32) -> Bool {
        if ip >> 24 == 127 || ip >> 24 == 0 { return true }
        let set = cache.withLockedValue { c -> Set<UInt32> in
            if ContinuousClock.now - c.at > .seconds(5) { c = (Self.read(), .now) }
            return c.set
        }
        return set.contains(ip)
    }

    /// The host's own IPv6 addresses (`b`: 16 bytes), the same way.
    // @port-skip linux-only: multi-user isolation
    public func contains6(_ b: [UInt8]) -> Bool {
        let set = cache6.withLockedValue { c -> Set<[UInt8]> in
            if ContinuousClock.now - c.at > .seconds(5) { c = (Self.read6(), .now) }
            return c.set
        }
        return set.contains(b)
    }

    // @port-skip linux-only: multi-user isolation
    static func read6() -> Set<[UInt8]> {
        var out = Set<[UInt8]>()
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return out }
        defer { freeifaddrs(head) }
        var p = head
        while let ifa = p {
            if let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET6) {
                let a = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                out.insert(withUnsafeBytes(of: a) { Array($0) })
            }
            p = ifa.pointee.ifa_next
        }
        return out
    }

    // @port-skip linux-only: multi-user isolation
    static func read() -> Set<UInt32> {
        var out = Set<UInt32>()
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return out }
        defer { freeifaddrs(head) }
        var p = head
        while let ifa = p {
            if let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) {
                let a = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                out.insert(UInt32(bigEndian: a))
            }
            p = ifa.pointee.ifa_next
        }
        return out
    }
}
