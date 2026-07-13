import Foundation

// MARK: - Proxy auto-config (PAC) for the fat-client browser pane

/// Generates a PAC (proxy auto-config) script that sends traffic destined for a
/// connected remote's workspace subnet through that host's SOCKS forwarder
/// (`RemoteSocksForwarder`), and everything else DIRECT. The local browser VM is
/// pointed at this PAC so navigating to a remote workspace's dev server at its
/// literal `http://192.168.64.x:port` reaches the remote guest over SSH, while
/// normal internet browsing is unaffected.
///
/// For a fleet, one PAC carries a clause per host; a host that had to be
/// alias-NAT'd (subnet collision) contributes its ALIAS subnet here, and the
/// `browser-mcp` relay hands the agent the matching aliased address.
enum FatClientPAC {
    /// One remote subnet routed to a SOCKS proxy the browser VM can reach.
    struct Route: Equatable {
        let cidr: String      // e.g. "192.168.64.0/24" (literal or alias)
        let proxyHost: String // address the BROWSER VM uses to reach the SOCKS proxy
        let proxyPort: Int
    }

    /// Build a PAC from routes. Routes whose CIDR doesn't parse are skipped;
    /// returns nil if none survive (caller then leaves the browser DIRECT).
    static func script(routes: [Route]) -> String? {
        var clauses: [String] = []
        for r in routes {
            guard let (net, mask) = parseCIDR(r.cidr), r.proxyPort > 0, r.proxyPort < 65536,
                  isSafeProxyHost(r.proxyHost) else { continue }
            clauses.append("  if (isInNet(host, \"\(net)\", \"\(mask)\")) "
                + "return \"SOCKS5 \(r.proxyHost):\(r.proxyPort)\";")
        }
        guard !clauses.isEmpty else { return nil }
        return "function FindProxyForURL(url, host) {\n"
            + clauses.joined(separator: "\n") + "\n"
            + "  return \"DIRECT\";\n}\n"
    }

    /// "192.168.64.0/24" → ("192.168.64.0", "255.255.255.0"). Validates the
    /// network is a dotted quad and the prefix is 0…32, so a hostile `/state`
    /// value can't inject arbitrary JS into the PAC.
    static func parseCIDR(_ cidr: String) -> (network: String, netmask: String)? {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]), (0...32).contains(prefix) else { return nil }
        let net = String(parts[0])
        let octets = net.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              octets.allSatisfy({ Int($0).map { (0...255).contains($0) } ?? false }) else { return nil }
        let maskBits: UInt32 = prefix == 0 ? 0 : (~UInt32(0)) << (32 - prefix)
        let mask = "\((maskBits >> 24) & 0xff).\((maskBits >> 16) & 0xff)."
            + "\((maskBits >> 8) & 0xff).\(maskBits & 0xff)"
        return (net, mask)
    }

    /// Proxy host must be a plain IPv4 literal (it's ours — 127.0.0.1 or a
    /// gateway address), never anything that could break out of the JS string.
    private static func isSafeProxyHost(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        return octets.count == 4
            && octets.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }
}
