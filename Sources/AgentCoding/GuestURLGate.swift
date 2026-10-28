import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Whether a URL a guest asked to open may go to the user's real browser:
/// its host, read the way the browser's URL parser reads it, must be public.
/// A guest pointing that browser at loopback or the LAN would reach those
/// services with the user's cookies (H2 "local drive-by"; Findings CWE-918).
/// Shared with Bromure Remote: its fat client opens the guest sign-in URL a
/// server publishes (an older server published one unchecked).
enum GuestURLGate {
    /// A URL host as an address parser wants it: lowercased, without IPv6
    /// brackets, an IPv6 zone (`%lo0`, `%25lo0`) or a trailing dot.
    static func bareHost(_ rawHost: String) -> String {
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.contains(":"), let pct = host.firstIndex(of: "%") { host = String(host[..<pct]) }
        if host.hasSuffix(".") { host.removeLast() }
        return host
    }

    /// A URL host as the browser's host parser leaves it before reading an
    /// address: UTS #46 domain-to-ASCII over the percent-decoded host (what
    /// `URL.host` hands back). `URL` maps a host it parses itself
    /// (`127。0。0。1` → `127.0.0.1`), but a percent-encoded one is only
    /// decoded: `%E3%80%82` stays an ideographic full stop, `%EF%BC%90%EF%BD%98`
    /// fullwidth `０ｘ`, and both read as public names while the browser
    /// dials 127.0.0.1 and 0.0.0.0 (Finding CWE-918, "Loopback gate skips
    /// UTS46 mappings, so a compatibility-dot host still opens on the Mac").
    /// The mapping is the one `URL` runs on a host it parses. nil: the host
    /// parser fails on it (a forbidden code point, a label UTS #46 refuses)
    /// -- no URL a browser opens, so nothing to open either. An IPv6 literal
    /// (bracketed or not, a zone allowed) is returned as is.
    static func browserHost(_ rawHost: String) -> String? {
        if rawHost.hasPrefix("[") || rawHost.contains(":") {
            // An IPv6 literal, or a decoded colon a browser refuses.
            var v6 = in6_addr()
            return inet_pton(AF_INET6, bareHost(rawHost), &v6) == 1 ? rawHost : nil
        }
        // The URL standard's forbidden domain code points: C0 controls,
        // space, # % / : < > ? @ [ \ ] ^ | and DEL. Decoded out of the host
        // they fail the URL; re-parsed below they would change what the host is.
        let forbidden = CharacterSet(charactersIn: " #%/:<>?@[\\]^|\u{7F}")
            .union(CharacterSet(charactersIn: UnicodeScalar(0)...UnicodeScalar(0x1F)))
        guard rawHost.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { return nil }
        guard !rawHost.unicodeScalars.allSatisfy(\.isASCII) else { return rawHost }
        guard let mapped = URL(string: "http://" + rawHost + "/")?.host,
              !mapped.isEmpty, mapped.unicodeScalars.allSatisfy(\.isASCII) else { return nil }
        return mapped
    }

    /// What a browser makes of a host under the URL standard's IPv4 parser.
    enum URLIPv4 { case notIPv4, invalid, address(UInt32) }

    /// The URL standard's IPv4 host parser -- the one Safari and Chrome run,
    /// not inet_aton, which refuses a part that is a bare `0x` (0 to a
    /// browser: `0x`, `0x.0` and `0x.0.0.0` are all 0.0.0.0). A host whose
    /// last part is a number is an IPv4 address or an invalid URL, never a
    /// name to look up.
    static func urlIPv4(_ host: String) -> URLIPv4 {
        var parts = host.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count > 1, parts.last?.isEmpty == true { parts.removeLast() }
        func number(_ part: Substring) -> UInt64? {
            var digits = part, radix = 10
            if digits.hasPrefix("0x") || digits.hasPrefix("0X") { digits = digits.dropFirst(2); radix = 16 }
            else if digits.count > 1, digits.hasPrefix("0") { digits = digits.dropFirst(); radix = 8 }
            if digits.isEmpty { return 0 }
            guard digits.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
            return UInt64(digits, radix: radix)   // nil: not this radix's digits, or too big
        }
        guard let last = parts.last, !last.isEmpty,
              last.allSatisfy({ $0.isASCII && $0.isNumber }) || number(last) != nil else { return .notIPv4 }
        guard parts.count <= 4 else { return .invalid }
        var numbers: [UInt64] = []
        for part in parts {
            guard !part.isEmpty, let n = number(part) else { return .invalid }
            numbers.append(n)
        }
        guard numbers.dropLast().allSatisfy({ $0 <= 255 }),
              numbers[numbers.count - 1] < (UInt64(1) << (8 * UInt64(5 - numbers.count))) else { return .invalid }
        var address = numbers[numbers.count - 1]
        for (i, n) in numbers.dropLast().enumerated() { address += n << (8 * UInt64(3 - i)) }
        return .address(UInt32(address))
    }

    /// 0/8, 127/8, RFC 1918, link-local 169.254/16 and CGNAT 100.64/10.
    static func ipv4IsLocalOrPrivate(_ a: UInt32) -> Bool {
        switch (a >> 24, (a >> 16) & 0xFF) {
        case (0, _), (127, _), (10, _): return true            // unspecified / loopback / RFC1918
        case (172, 16...31): return true                       // 172.16/12
        case (192, 168): return true                           // 192.168/16
        case (169, 254): return true                           // link-local
        case (100, 64...127): return true                      // CGNAT 100.64/10
        default: return false
        }
    }

    /// Whether a browser handed this URL host connects to this Mac's
    /// loopback: `localhost` and `*.localhost` (browsers resolve those
    /// themselves), any IPv4 spelling of 127/8 or 0.0.0.0 (`127.1`,
    /// `0x7f000001` and `2130706433` are all 127.0.0.1 to a URL parser), and
    /// IPv6 `::1`, `::` and the v4-mapped loopback (`::ffff:127.0.0.1`),
    /// bracketed or not, with or without a trailing dot.
    static func reachesLoopback(_ rawHost: String) -> Bool {
        // A host the browser's parser refuses goes nowhere; one it maps
        // (`127%E3%80%820%E3%80%820%E3%80%821`) is read as it maps it.
        guard let mapped = browserHost(rawHost) else { return false }
        let host = bareHost(mapped)
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        // IPv4, every form a URL parser accepts (shorthand, octal, hex, a
        // single number, a bare `0x`).
        if !host.contains(":") {
            switch urlIPv4(host) {
            case .address(let a): return a >> 24 == 127 || a == 0
            case .invalid: return false   // a browser refuses the URL
            case .notIPv4: break
            }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            let b = withUnsafeBytes(of: v6) { Array($0) }
            if b.prefix(15).allSatisfy({ $0 == 0 }), b[15] <= 1 { return true }          // ::, ::1
            if b.prefix(10).allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF,
               b[12] == 127 || b[12...15].allSatisfy({ $0 == 0 }) { return true }        // ::ffff:127.x / 0.0.0.0
            return false
        }
        return false
    }

    /// Whether `url` may be handed to the user's real browser: it must have a
    /// PUBLIC host. Empty / local / private / link-local / ULA / `.local`
    /// hosts are refused.
    static func opensInRealBrowser(_ url: URL) -> Bool {
        guard let host = url.host, !host.isEmpty else { return false }
        return !hostIsLocalOrPrivate(host)
    }

    /// Classify a URL host as local/private (loopback, RFC1918, CGNAT,
    /// link-local, IPv6 loopback/ULA/link-local, or an mDNS `.local` /
    /// `localhost` name). A plain public DNS name returns false. Pure — no
    /// actor state — so callers on any executor (and tests) can use it.
    static func hostIsLocalOrPrivate(_ rawHost: String) -> Bool {
        // Every loopback spelling first (`127.1`, `0x7f000001`, `[::1%lo0]`
        // -- inet_pton below takes none of them, and a browser goes there).
        if reachesLoopback(rawHost) { return true }
        // Read as the browser's host parser leaves it (UTS #46); a host it
        // refuses opens nothing: refused too.
        guard let mapped = browserHost(rawHost) else { return true }
        let host = bareHost(mapped)
        // Named loopback / mDNS.
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host == "local" || host.hasSuffix(".local") { return true }
        // IPv4 literal, in any spelling a URL parser accepts. One it can't
        // parse is no URL a browser opens: refused too.
        if !host.contains(":") {
            switch urlIPv4(host) {
            case .address(let a): return ipv4IsLocalOrPrivate(a)
            case .invalid: return true
            case .notIPv4: break
            }
        }
        // IPv6 literal.
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            let b = withUnsafeBytes(of: v6) { Array($0) }
            if b.allSatisfy({ $0 == 0 }) { return true }                       // ::
            if b.prefix(15).allSatisfy({ $0 == 0 }), b[15] == 1 { return true }// ::1
            if b[0] == 0xFE, (b[1] & 0xC0) == 0x80 { return true }             // fe80::/10 link-local
            if (b[0] & 0xFE) == 0xFC { return true }                           // fc00::/7 ULA
            if b.prefix(10).allSatisfy({ $0 == 0 }), b[10] == 0xFF, b[11] == 0xFF {   // ::ffff:a.b.c.d
                return ipv4IsLocalOrPrivate(b[12...15].reduce(0) { $0 << 8 | UInt32($1) })
            }
            return false
        }
        return false   // a normal public DNS name
    }
}
