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
struct ProxyDestinationDenied: Error, CustomStringConvertible {
    let host: String
    let port: Int
    let reason: String
    // @port-skip linux-only: the refusal's text
    var description: String { reason }
}

extension MitmProxy {
    typealias IPAddress = OpenShellPolicy.IPAddress

    /// Resolve `host` and check every answer, off the event loop; the
    /// addresses to dial (empty: the name didn't resolve, and the connect
    /// fails on its own), or ProxyDestinationDenied.
    // partial: no OpenShell policy on Linux yet, so only the always-blocked addresses (and the host's own, multi-user)
    // @port HTTPMitmConnection.checkDestination(host: String, port: Int) h=dd146338138184b2 @32a528c5
    func checkDestination(host: String, port: Int, on loop: EventLoop) -> EventLoopFuture<[IPAddress]> {
        Self.checkDestination(host: host, port: port, hostAddresses: blocksHostAddresses, on: loop)
    }

    // @port-skip linux-only: the static half of checkDestination (tests)
    static func checkDestination(host: String, port: Int, hostAddresses: Bool, on loop: EventLoop) -> EventLoopFuture<[IPAddress]> {
        if host.lowercased() == InferenceService.localMitmHost { return loop.makeSucceededFuture([]) }
        let promise = loop.makePromise(of: [IPAddress].self)
        DispatchQueue.global(qos: .userInitiated).async {
            let resolved = Self.resolve(host, port: port)
            if let reason = Self.destinationDenial(host: host, resolved: resolved, hostAddresses: hostAddresses) {
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
    static func destinationDenial(host: String, resolved: [IPAddress], hostAddresses: Bool) -> String? {
        for ip in resolved {
            if OpenShellPolicy.isAlwaysBlocked(ip) {
                return "\(host) resolves to always-blocked address \(ip), connection rejected"
            }
            if hostAddresses, let v4 = Self.v4(ip), HostAddresses.shared.contains(v4) {
                return "\(host) resolves to this server's own address \(ip), connection rejected"
            }
        }
        return nil
    }

    // @port-skip linux-only: IPv4 or v4-mapped IPv6
    static func v4(_ ip: IPAddress) -> UInt32? {
        if case .v4(let v) = ip { return v }
        return ip.mappedV4
    }

    /// Every A/AAAA answer for `host` (an IP literal is its own answer).
    // @port UpstreamPinning.static resolve(_: String, port: Int) h=017333f9aa2e6c7d @b52f56b0
    static func resolve(_ host: String, port: Int) -> [IPAddress] {
        let lookup = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let ip = IPAddress(lookup) { return [ip] }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
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
