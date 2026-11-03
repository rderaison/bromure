import Foundation
import NIOCore
import SandboxEngine

/// Where the proxy may send a guest: never to an address on this server.
/// macOS refuses those only under an OpenShell policy (its proxy runs on
/// the user's own Mac); a Linux server's loopback carries other users'
/// daemons and every host-local service, so here OpenShell's always-blocked
/// set (loopback, link-local with the cloud metadata address, unspecified)
/// is refused for every workspace, and on a multi-user server the host's own
/// addresses too, as the switch refuses them. The local-inference sentinel
/// (`bromure.llm`) stays the one remap (MitmProxy.route).
/// The name didn't resolve (timeout, SERVFAIL, a dropped query): the
/// proxy fails closed, never dialing the name itself.
struct ProxyDestinationUnresolved: Error, CustomStringConvertible {
    let host: String
    let port: Int
    // @port-skip linux-only: the refusal's text
    var description: String { "DNS resolution returned no addresses for \(host)" }
}

struct ProxyDestinationDenied: Error, CustomStringConvertible {
    let host: String
    let port: Int
    let reason: String
    // @port-skip linux-only: the refusal's text
    var description: String { reason }
}

extension MitmProxy {
    typealias IPAddress = OpenShellPolicy.IPAddress

    /// Resolve `host` and check every answer, off the event loop: the
    /// addresses to dial, or ProxyDestinationDenied, or
    /// ProxyDestinationUnresolved (no answer: never dialed by name). The
    /// sentinel is the one name not looked up (MitmProxy.route remaps it).
    // partial: no OpenShell policy on Linux yet, so only the always-blocked addresses (and the host's own, multi-user)
    // @port HTTPMitmConnection.checkDestination(host: String, port: Int) h=dd146338138184b2 @32a528c5
    func checkDestination(host: String, port: Int, on loop: EventLoop) -> EventLoopFuture<[IPAddress]> {
        Self.checkDestination(host: host, port: port, hostAddresses: blocksHostAddresses, on: loop)
    }

    // @port-skip linux-only: the static half of checkDestination (tests stub the resolver and the host's addresses)
    static func checkDestination(host: String, port: Int, hostAddresses: Bool,
                                 resolver: @escaping @Sendable (String, Int) -> [IPAddress] = { resolve($0, port: $1) },
                                 hostOwn: @escaping @Sendable (IPAddress) -> Bool = { isHostOwn($0) },
                                 on loop: EventLoop) -> EventLoopFuture<[IPAddress]> {
        if host.lowercased() == InferenceService.localMitmHost { return loop.makeSucceededFuture([]) }
        let promise = loop.makePromise(of: [IPAddress].self)
        DispatchQueue.global(qos: .userInitiated).async {
            let resolved = resolver(host, port)
            if resolved.isEmpty {
                FileHandle.standardError.write(Data("[mitm] ✗ deny tcp \(host):\(port) — no address\n".utf8))
                promise.fail(ProxyDestinationUnresolved(host: host, port: port))
            } else if let reason = Self.destinationDenial(host: host, resolved: resolved, hostAddresses: hostAddresses,
                                                          hostOwn: hostOwn) {
                FileHandle.standardError.write(Data("[mitm] ✗ deny tcp \(host):\(port) — \(reason)\n".utf8))
                promise.fail(ProxyDestinationDenied(host: host, port: port, reason: reason))
            } else {
                promise.succeed(resolved)
            }
        }
        return promise.futureResult
    }

    /// Why `resolved` (the answers for `host`) may not be dialed; nil: it may.
    // @port-skip linux-only: the always-blocked half of OpenShellPolicy.validateDestination, applied without a policy (multi-user isolation)
    static func destinationDenial(host: String, resolved: [IPAddress], hostAddresses: Bool,
                                  hostOwn: (IPAddress) -> Bool = { isHostOwn($0) }) -> String? {
        for ip in resolved {
            // An IPv6 form that carries an IPv4 address is judged by it.
            if OpenShellPolicy.isAlwaysBlocked(ip) || Self.v4(ip).map({ OpenShellPolicy.isAlwaysBlocked(.v4($0)) }) == true {
                return "\(host) resolves to always-blocked address \(ip), connection rejected"
            }
            if hostAddresses, hostOwn(ip) || Self.v4(ip).map({ hostOwn(.v4($0)) }) == true {
                return "\(host) resolves to this server's own address \(ip), connection rejected"
            }
        }
        return nil
    }

    // @port-skip linux-only: multi-user isolation
    static func isHostOwn(_ ip: IPAddress) -> Bool {
        switch ip {
        case .v4(let v): return HostAddresses.shared.contains(v)
        case .v6(let b): return HostAddresses.shared.contains6(b)
        }
    }

    /// The IPv4 address `ip` is or carries: v4-mapped (::ffff:a.b.c.d),
    /// IPv4-compatible (::a.b.c.d), NAT64 (64:ff9b::/96, 64:ff9b:1::/48)
    /// and 6to4 (2002:aabb:ccdd::/48) forms included. Unreachable on most
    /// hosts, but a NAT64 or 6to4 route would make each a path.
    // @port-skip linux-only: IPv4 inside IPv6 forms
    static func v4(_ ip: IPAddress) -> UInt32? {
        switch ip {
        case .v4(let v): return v
        case .v6(let b):
            if let m = ip.mappedV4 { return m }
            let tail = UInt32(b[12]) << 24 | UInt32(b[13]) << 16 | UInt32(b[14]) << 8 | UInt32(b[15])
            if b[0..<12].allSatisfy({ $0 == 0 }), tail > 1 { return tail }        // not :: or ::1 (those are v6's own)
            if b[0..<12] == [0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0] { return tail }
            if b[0..<6] == [0x00, 0x64, 0xff, 0x9b, 0x00, 0x01] { return tail }
            if b[0] == 0x20, b[1] == 0x02 {
                return UInt32(b[2]) << 24 | UInt32(b[3]) << 16 | UInt32(b[4]) << 8 | UInt32(b[5])
            }
            return nil
        }
    }

    /// Every A/AAAA answer for `host` (an IP literal is its own answer).
    // @port UpstreamPinning.static resolve(_: String, port: Int) h=017333f9aa2e6c7d @b52f56b0
    static func resolve(_ host: String, port: Int) -> [IPAddress] {
        let lookup = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let ip = IPAddress(lookup) { return [ip] }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_flags = AI_ADDRCONFIG     // only families this host can reach
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        hints.ai_protocol = Int32(IPPROTO_TCP)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(lookup, String(port), &hints, &res) == 0 else { return [] }
        defer { freeaddrinfo(res) }
        var out: [IPAddress] = []
        var cursor = res
        while let info = cursor {
            cursor = info.pointee.ai_next
            if info.pointee.ai_family == AF_INET {
                let a = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                out.append(.v4(UInt32(bigEndian: a.sin_addr.s_addr)))
            } else if info.pointee.ai_family == AF_INET6 {
                let a = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                out.append(.v6(withUnsafeBytes(of: a.sin6_addr) { Array($0) }))
            }
        }
        var seen = Set<IPAddress>()
        return out.filter { seen.insert($0).inserted }
    }

    /// The CONNECT's (or request's) 403 for a refused destination, as macOS
    /// answers one.
    // @port HTTPMitmConnection.destinationDeniedResponse(host: String, port: Int, reason: String) h=870f78d6e53d2fc5 @32a528c5
    static func destinationDeniedResponse(host: String, port: Int, reason: String) -> Data {
        func json(_ s: String) -> String {
            let array = String(decoding: (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8), as: UTF8.self)
            return String(array.dropFirst().dropLast())
        }
        let body = "{\"error\":\"destination_denied\",\"detail\":\(json(reason)),\"host\":\(json(host)),\"port\":\(port)}"
        return Data("HTTP/1.1 403 Forbidden\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
    }
}
