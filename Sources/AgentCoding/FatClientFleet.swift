import Foundation

// MARK: - Fleet subnet routing (alias-on-collision)

/// Decides how each connected remote's workspace subnet is routed on the local
/// fat client. Two remotes are near-guaranteed to both live on 192.168.64.0/24,
/// and you can't route two identical /24s to two tunnels literally — so:
///
///  - **Route literally** when the subnet is free locally (no local interface
///    and no already-routed remote uses it). Most of the time, literal.
///  - **Alias-NAT on collision**: a colliding remote gets a distinct
///    `100.64.<n>.0/24` (CGNAT space) alias. The `browser-mcp` relay then
///    rewrites that host's advertised `192.168.64.x` → `100.64.<n>.x` (a pure
///    1:1 host-octet-preserving remap), and the PAC/route use the alias.
///
/// A dev page that emits an *absolute* literal `http://192.168.64.x` link inside
/// an aliased remote can still misroute — rare, and literal remotes are immune;
/// documented in REMOTE_FAT_CLIENT_PLAN.md.
enum FleetRouter {
    /// A connected remote and the subnet it advertised via `/state`.
    struct HostSubnet: Equatable {
        let hostID: UUID
        let cidr: String
    }

    /// The local routing decision for one remote.
    struct Route: Equatable {
        let hostID: UUID
        let remoteCIDR: String   // what the remote advertises (agent-facing)
        let localCIDR: String    // what B routes locally (== remoteCIDR if literal)
        let aliased: Bool
    }

    /// Assign a local route per remote. `localInUse` holds canonical `net/prefix`
    /// strings already occupied on B (its own vmnet + LAN interfaces). Order is
    /// preserved and stable, so the first remote on a subnet keeps it literally.
    static func assign(remotes: [HostSubnet], localInUse: Set<String>) -> [Route] {
        let occupied = Set(localInUse.compactMap(canonical))
        var claimed = Set<String>()     // subnets routed literally so far
        var usedAliasOctets = Set<Int>()
        var routes: [Route] = []

        for r in remotes {
            let canon = canonical(r.cidr)
            let free = canon.map { !occupied.contains($0) && !claimed.contains($0) } ?? false
            if let canon, free {
                claimed.insert(canon)
                routes.append(Route(hostID: r.hostID, remoteCIDR: r.cidr,
                                    localCIDR: r.cidr, aliased: false))
            } else {
                let octet = nextAliasOctet(avoiding: usedAliasOctets, occupied: occupied)
                usedAliasOctets.insert(octet)
                routes.append(Route(hostID: r.hostID, remoteCIDR: r.cidr,
                                    localCIDR: "100.64.\(octet).0/24", aliased: true))
            }
        }
        return routes
    }

    /// Remap an agent-advertised address for a route: identity for a literal
    /// route, or `<remote net>.x → <alias net>.x` (preserving the host octet)
    /// for an aliased one. Returns nil if `address` isn't in the remote subnet.
    static func remap(address: String, route: Route) -> String? {
        guard route.aliased else { return address }   // literal: unchanged
        guard let (rNet, _) = FatClientPAC.parseCIDR(route.remoteCIDR),
              let (aNet, _) = FatClientPAC.parseCIDR(route.localCIDR) else { return nil }
        let addr = address.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let rn = rNet.split(separator: ".").map(String.init)
        let an = aNet.split(separator: ".").map(String.init)
        guard addr.count == 4, rn.count == 4, an.count == 4,
              addr.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) else { return nil }
        // Only /24 remaps are supported (the alias is always a /24); the first
        // three octets must match the remote network for this to be in-subnet.
        guard Array(addr.prefix(3)) == Array(rn.prefix(3)) else { return nil }
        return "\(an[0]).\(an[1]).\(an[2]).\(addr[3])"
    }

    /// Canonicalize "192.168.64.5/24" → "192.168.64.0/24" (network address +
    /// prefix), so equal subnets compare equal regardless of the host bits.
    static func canonical(_ cidr: String) -> String? {
        guard let (net, mask) = FatClientPAC.parseCIDR(cidr) else { return nil }
        let n = net.split(separator: ".").compactMap { UInt32($0) }
        let m = mask.split(separator: ".").compactMap { UInt32($0) }
        guard n.count == 4, m.count == 4 else { return nil }
        let netAddr = (0..<4).map { n[$0] & m[$0] }
        let prefix = m.reduce(0) { $0 + $1.nonzeroBitCount }
        return "\(netAddr[0]).\(netAddr[1]).\(netAddr[2]).\(netAddr[3])/\(prefix)"
    }

    /// Lowest 100.64.<n>.0/24 octet (1…254) not yet used and not colliding with a
    /// local interface that happens to sit in 100.64/10.
    private static func nextAliasOctet(avoiding used: Set<Int>, occupied: Set<String>) -> Int {
        for n in 1...254 where !used.contains(n) && !occupied.contains("100.64.\(n).0/24") {
            return n
        }
        return 1   // 254 fleet hosts is well past any real limit
    }
}
