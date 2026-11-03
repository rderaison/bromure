import Foundation

// MARK: - Destination validation (port of openshell-core `net.rs` and
// openshell-supervisor-network `proxy/destination.rs`)
//
// After the policy allows `host:port`, OpenShell resolves the name itself,
// checks EVERY resolved address against the route's address authorization,
// and connects only to the addresses that passed (so a second DNS answer
// can't swap the destination). The authorization comes from the first
// matching endpoint config: explicit `allowed_ips`, an IP-literal host, an
// exact declared hostname (only always-blocked addresses refused), or —
// the default — public addresses only.

extension OpenShellPolicy {
    /// An IPv4 or IPv6 address.
    public enum IPAddress: Hashable, Sendable, CustomStringConvertible {
        case v4(UInt32)
        case v6([UInt8])            // 16 bytes

        public init?(_ s: String) {
            var t = s.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("["), t.hasSuffix("]") { t = String(t.dropFirst().dropLast()) }
            var a4 = in_addr(), a6 = in6_addr()
            if inet_pton(AF_INET, t, &a4) == 1 {
                self = .v4(UInt32(bigEndian: a4.s_addr))
            } else if inet_pton(AF_INET6, t, &a6) == 1 {
                self = .v6(withUnsafeBytes(of: a6) { Array($0) })
            } else {
                return nil
            }
        }

        /// `::ffff:a.b.c.d` → a.b.c.d.
        public var mappedV4: UInt32? {
            guard case .v6(let b) = self, b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff else { return nil }
            return UInt32(b[12]) << 24 | UInt32(b[13]) << 16 | UInt32(b[14]) << 8 | UInt32(b[15])
        }

        public var description: String {
            switch self {
            case .v4(let v): return EgressPolicy.ipv4String(v)
            case .v6(let b):
                var a = in6_addr()
                withUnsafeMutableBytes(of: &a) { $0.copyBytes(from: b) }
                var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                return inet_ntop(AF_INET6, &a, &buf, socklen_t(buf.count)).map { String(cString: $0) } ?? "?"
            }
        }
    }

    /// A CIDR (`ipnet::IpNet`); a bare address is a /32 or /128.
    public struct IPNet: Hashable, Sendable {
        public let address: IPAddress
        public let prefix: Int

        public init?(_ s: String) {
            let parts = s.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard let a = IPAddress(String(parts[0])) else { return nil }
            let maxLen: Int = { if case .v4 = a { return 32 }; return 128 }()
            if parts.count == 2 {
                guard !parts[1].isEmpty, parts[1].allSatisfy(\.isNumber), let p = Int(parts[1]), p <= maxLen else { return nil }
                prefix = p
            } else {
                prefix = maxLen
            }
            address = a
        }

        init(_ a: IPAddress, _ p: Int) { address = a; prefix = p }

        private static func bits(_ a: IPAddress) -> [UInt8] {
            switch a {
            case .v4(let v): return [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)]
            case .v6(let b): return b
            }
        }

        private static func masked(_ b: [UInt8], _ prefix: Int) -> [UInt8] {
            b.enumerated().map { i, byte in
                let keep = max(0, min(8, prefix - i * 8))
                return keep == 8 ? byte : byte & UInt8(truncatingIfNeeded: 0xff << (8 - keep))
            }
        }

        /// Same family only, as `IpNet::contains`.
        public func contains(_ ip: IPAddress) -> Bool {
            switch (address, ip) {
            case (.v4, .v4), (.v6, .v6):
                return Self.masked(Self.bits(address), prefix) == Self.masked(Self.bits(ip), prefix)
            default:
                return false
            }
        }

        var network: [UInt8] { Self.masked(Self.bits(address), prefix) }
        var broadcast: [UInt8] {
            Self.bits(address).enumerated().map { i, byte in
                let keep = max(0, min(8, prefix - i * 8))
                return keep == 8 ? byte : byte | UInt8(truncatingIfNeeded: 0xff >> keep)
            }
        }
        func intersects(_ o: IPNet) -> Bool {
            guard network.count == o.network.count else { return false }
            return !(broadcast.lexicographicallyPrecedes(o.network)) && !(o.broadcast.lexicographicallyPrecedes(network))
        }
    }

    // MARK: net.rs classification

    private static func v4(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 { a << 24 | b << 16 | c << 8 | d }
    private static func inV4(_ ip: UInt32, _ net: UInt32, _ bits: UInt32) -> Bool {
        let mask: UInt32 = bits == 0 ? 0 : 0xFFFF_FFFF << (32 - bits)
        return ip & mask == net & mask
    }

    static func isLinkLocal(_ ip: IPAddress) -> Bool {
        switch ip {
        case .v4(let v): return inV4(v, v4(169, 254, 0, 0), 16)
        case .v6(let b):
            if b[0] == 0xfe, b[1] & 0xc0 == 0x80 { return true }
            return ip.mappedV4.map { inV4($0, v4(169, 254, 0, 0), 16) } ?? false
        }
    }

    public static func isAlwaysBlocked(_ ip: IPAddress) -> Bool {
        switch ip {
        case .v4(let v): return inV4(v, v4(127, 0, 0, 0), 8) || inV4(v, v4(169, 254, 0, 0), 16) || v == 0
        case .v6(let b):
            if b == [UInt8](repeating: 0, count: 15) + [1] || b.allSatisfy({ $0 == 0 }) { return true }
            if isLinkLocal(ip) { return true }
            if let m = ip.mappedV4 { return inV4(m, v4(127, 0, 0, 0), 8) || m == 0 }
            return false
        }
    }

    private static func isInternalV4(_ v: UInt32) -> Bool {
        let nets: [(UInt32, UInt32)] = [
            (v4(127, 0, 0, 0), 8), (v4(10, 0, 0, 0), 8), (v4(172, 16, 0, 0), 12), (v4(192, 168, 0, 0), 16),
            (v4(169, 254, 0, 0), 16), (v4(192, 0, 2, 0), 24), (v4(198, 51, 100, 0), 24), (v4(203, 0, 113, 0), 24),
            (v4(100, 64, 0, 0), 10), (v4(192, 0, 0, 0), 24), (v4(198, 18, 0, 0), 15),
        ]
        return v == 0 || v == 0xFFFF_FFFF || nets.contains { inV4(v, $0.0, $0.1) }
    }

    public static func isInternal(_ ip: IPAddress) -> Bool {
        switch ip {
        case .v4(let v): return isInternalV4(v)
        case .v6(let b):
            if b == [UInt8](repeating: 0, count: 15) + [1] || b.allSatisfy({ $0 == 0 }) { return true }
            if isLinkLocal(ip) { return true }
            if b[0] & 0xfe == 0xfc { return true }
            return ip.mappedV4.map(isInternalV4) ?? false
        }
    }

    /// `is_always_blocked_net`: a range touching loopback, link-local or the
    /// unspecified address.
    static func isAlwaysBlockedNet(_ n: IPNet) -> Bool {
        switch n.address {
        case .v4:
            let lo = IPNet(.v4(v4(127, 0, 0, 0)), 8), ll = IPNet(.v4(v4(169, 254, 0, 0)), 16)
            return n.intersects(lo) || n.intersects(ll) || n.network == [0, 0, 0, 0]
        case .v6:
            let loop = IPAddress("::1")!, zero = IPAddress("::")!, fe80 = IPAddress("fe80::")!
            if n.contains(loop) || n.contains(zero) { return true }
            if n.network[0] == 0xfe, n.network[1] & 0xc0 == 0x80 { return true }
            if n.contains(fe80) { return true }
            let net = IPAddress.v6(n.network)
            if let m = net.mappedV4, inV4(m, v4(127, 0, 0, 0), 8) || inV4(m, v4(169, 254, 0, 0), 16) || m == 0 { return true }
            for mapped in ["::ffff:127.0.0.1", "::ffff:169.254.0.0", "::ffff:0.0.0.0"] where n.contains(IPAddress(mapped)!) {
                return true
            }
            return false
        }
    }

    static let blockedControlPlanePorts: Set<UInt16> = [2379, 2380, 6443, 10250, 10255]

    // MARK: destination.rs

    public enum AddressAuthorization: Equatable, Sendable {
        case explicitAllowedIPs([IPNet])
        case implicitIPLiteral(IPAddress)
        case exactDeclaredHost
        case defaultPublicOnly
    }

    public struct DestinationDenial: Error, Equatable, Sendable { public let reason: String }

    /// The address authorization OpenShell derives for an allowed
    /// connection (`build_validation_plan`): the first matching endpoint
    /// config's `allowed_ips`, else an IP-literal host, else an exact declared
    /// hostname, else public addresses only.
    public func destinationPlan(host: String, port: UInt16, identity: BinaryIdentity? = nil,
                                enforceBinaries: Bool = false) -> Result<AddressAuthorization, DestinationDenial> {
        let h = host.lowercased()
        // Rego `_matching_policy_names` iterates policies by name.
        let policies = networkPolicies.filter { $0.applies(to: identity, enforce: enforceBinaries) }
            .sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
        let matchingPolicies = policies.filter { rule in rule.endpoints.contains { $0.matches(host: h, port: port) } }
        let firstConfig = matchingPolicies.lazy.flatMap(\.endpoints).first { ep in
            ep.matches(host: h, port: port)
                && ((ep.l7 != nil && ep.l7 != .tcp) || !ep.ambiguity.allowedIPsRaw.isEmpty || ep.tlsSkip)
        }
        if let raw = firstConfig?.ambiguity.allowedIPsRaw, !raw.isEmpty {
            var nets: [IPNet] = [], errors: [String] = []
            for entry in raw {
                guard let n = IPNet(entry) else { errors.append("invalid CIDR/IP in allowed_ips: \(entry)"); continue }
                if Self.isAlwaysBlockedNet(n) {
                    errors.append("allowed_ips entry \(entry) falls within always-blocked range (loopback/link-local/unspecified); remove this entry — SSRF hardening prevents traffic to these destinations regardless of policy")
                    continue
                }
                nets.append(n)
            }
            if !errors.isEmpty { return .failure(DestinationDenial(reason: errors.joined(separator: "; "))) }
            return .success(.explicitAllowedIPs(nets))
        }
        var lookup = h
        if lookup.hasPrefix("["), lookup.hasSuffix("]") { lookup = String(lookup.dropFirst().dropLast()) }
        if lookup.hasSuffix(".") { lookup.removeLast() }
        if let ip = IPAddress(lookup), !Self.isAlwaysBlocked(ip) { return .success(.implicitIPLiteral(ip)) }
        let exact = policies.contains { rule in
            rule.endpoints.contains { ep in
                guard let eh = ep.host, !eh.contains("*") else { return false }
                return eh == h && ep.ports.contains(port)
            }
        }
        return .success(exact ? .exactDeclaredHost : .defaultPublicOnly)
    }

    /// `validate_destination` over already-resolved addresses: every one must
    /// pass; the survivors are the only addresses to connect to.
    public static func validateDestination(_ plan: AddressAuthorization, host: String, port: UInt16,
                                           resolved: [IPAddress]) -> Result<[IPAddress], DestinationDenial> {
        func deny(_ r: String) -> Result<[IPAddress], DestinationDenial> { .failure(DestinationDenial(reason: r)) }
        var lookup = host
        if lookup.hasPrefix("["), lookup.hasSuffix("]") { lookup = String(lookup.dropFirst().dropLast()) }
        if lookup.hasSuffix(".") { lookup.removeLast() }
        guard !resolved.isEmpty else { return deny("DNS resolution returned no addresses for \(lookup)") }
        switch plan {
        case .defaultPublicOnly:
            if let ip = resolved.first(where: isInternal) {
                return deny("\(host) resolves to internal address \(ip), connection rejected")
            }
        case .exactDeclaredHost:
            if blockedControlPlanePorts.contains(port) { return deny("port \(port) is a blocked control-plane port, connection rejected") }
            if let ip = resolved.first(where: isAlwaysBlocked) {
                return deny("\(host) resolves to always-blocked address \(ip), connection rejected")
            }
        case .explicitAllowedIPs(let nets):
            if blockedControlPlanePorts.contains(port) { return deny("port \(port) is a blocked control-plane port, connection rejected") }
            for ip in resolved {
                if isAlwaysBlocked(ip) { return deny("\(host) resolves to always-blocked address \(ip), connection rejected") }
                if !nets.contains(where: { $0.contains(ip) }) {
                    return deny("\(host) resolves to \(ip) which is not in allowed_ips, connection rejected")
                }
            }
        case .implicitIPLiteral(let expected):
            if blockedControlPlanePorts.contains(port) { return deny("port \(port) is a blocked control-plane port, connection rejected") }
            for ip in resolved {
                if isAlwaysBlocked(ip) { return deny("\(host) resolves to always-blocked address \(ip), connection rejected") }
                if !IPNet(expected, { if case .v4 = expected { return 32 }; return 128 }()).contains(ip) {
                    return deny("\(host) resolves to \(ip) which is not in allowed_ips, connection rejected")
                }
            }
        }
        var seen = Set<IPAddress>()
        return .success(resolved.filter { seen.insert($0).inserted })
    }
}

// MARK: - Binary identity pinning (port of openshell-supervisor-network
// `identity.rs` `verify_or_cache_supplied_identity`)

extension OpenShellPolicy {
    /// Trust-on-first-use pins for attested executables: the first sha256
    /// seen for a path is the only one accepted afterwards.
    public struct BinaryPinStore: Sendable {
        public static let capacity = 4096
        public private(set) var pins: [String: String] = [:]
        public init() {}

        /// Check `links` (the executable first, then its ancestors) and pin
        /// the new ones. Returns the refusal reason, or nil when accepted.
        /// Nothing is pinned unless the whole identity is accepted.
        public mutating func verifyOrPin(_ links: [(exe: String, sha256: String?)]) -> String? {
            var supplied: [String: String] = [:]
            for link in links {
                guard !link.exe.isEmpty, link.exe.hasPrefix("/") else {
                    return "Invalid executable identity path: \(link.exe) must be absolute"
                }
                guard let digest = link.sha256, !digest.isEmpty else {
                    return "Invalid executable identity evidence: \(link.exe) has missing digest"
                }
                if let existing = supplied[link.exe], existing != digest {
                    return "Invalid executable identity: conflicting evidence for \(link.exe)"
                }
                supplied[link.exe] = digest
            }
            for (path, digest) in supplied.sorted(by: { $0.key < $1.key }) {
                if let known = pins[path], known != digest {
                    return "Binary integrity violation: \(path) executable changed"
                }
            }
            let fresh = supplied.keys.filter { pins[$0] == nil }.count
            guard fresh <= Self.capacity - pins.count else {
                return "Binary identity cache capacity exhausted (maximum \(Self.capacity) pinned paths)"
            }
            for (path, digest) in supplied where pins[path] == nil { pins[path] = digest }
            return nil
        }
    }
}

extension OpenShellPolicy {
    /// Some endpoint names a hostname (not an IP literal) on this port, so a
    /// flow's verdict can still change once its TLS SNI / HTTP Host is known.
    public func hostnameEndpointCovers(port: UInt16) -> Bool {
        networkPolicies.contains { rule in
            rule.endpoints.contains { ep in
                guard ep.ports.contains(port), let host = ep.host else { return false }
                return IPAddress(host) == nil
            }
        }
    }
}

extension OpenShellPolicy {
    /// Ports of endpoints whose traffic is inspected: an inspecting L7
    /// protocol, or any middleware in the policy (middlewares rewrite HTTP
    /// bodies). Native `protocol: tcp` and `tls: skip` endpoints are relayed
    /// opaquely and don't count.
    public var inspectedPorts: Set<UInt16> {
        var out: Set<UInt16> = []
        for rule in networkPolicies {
            for ep in rule.endpoints where !ep.tlsSkip && ep.l7 != .tcp && ((ep.l7?.inspects ?? false) || !middlewares.isEmpty) {
                out.formUnion(ep.ports)
            }
        }
        return out
    }
}

extension OpenShellPolicy {
    /// OpenShell's credential-rewrite opt-ins on the endpoint a request routes
    /// to: whether `openshell:resolve:env:` placeholders are resolved in the
    /// request body (`request_body_credential_rewrite`) and in client
    /// WebSocket text (`websocket_credential_rewrite`). Headers always are.
    public func credentialRewrite(host: String, port: UInt16, target: String) -> (body: Bool, websocket: Bool) {
        guard let route = routedEndpoint(host: host, port: port, target: target) else { return (false, false) }
        return (route.primary.ambiguity.requestBodyCredentialRewrite,
                route.primary.ambiguity.websocketCredentialRewrite)
    }

    /// The prefix of an OpenShell credential placeholder.
    public static let credentialPlaceholderPrefix = "openshell:resolve:env:"
}
