import Foundation

/// Snoops the guest's DNS answers so hostname firewall rules work for *every*
/// protocol, not just TLS (where SNI carries the name). The switch already
/// forwards DNS to the gateway and the responses back; we peek those responses,
/// map each answer IPv4 → the queried name (and the record's owner name), and
/// keep an IP→hostnames cache with TTL. When a flow to some dst IP is evaluated,
/// the cache supplies the hostnames a rule can match.
///
/// IPv4 A-records only — the switch intercepts/​filters IPv4 (v6 passes through),
/// so an IPv6 answer can't be matched by an IPv4 rule anyway.
enum DNSSnoop {
    /// (ipv4, name, ttl) for every A record in a DNS *response* payload (payload
    /// begins at the DNS header, i.e. after the UDP header). Each A record is
    /// mapped to BOTH the overall query name and the record's owner name, so a
    /// rule written against the queried FQDN matches even through CNAME chains.
    static func parseResponse(_ b: [UInt8]) -> [(ip: UInt32, name: String, ttl: UInt32)] {
        guard b.count >= 12 else { return [] }
        let flags = UInt16(b[2]) << 8 | UInt16(b[3])
        guard (flags & 0x8000) != 0 else { return [] }          // QR = response
        let qd = Int(b[4]) << 8 | Int(b[5])
        let an = Int(b[6]) << 8 | Int(b[7])
        guard an > 0 else { return [] }

        var p = 12
        var queryName = ""
        for i in 0..<qd {
            let (name, next) = readName(b, p)
            if i == 0 { queryName = name }
            p = next + 4                                          // + qtype(2) + qclass(2)
            guard p <= b.count else { return [] }
        }

        var out: [(UInt32, String, UInt32)] = []
        for _ in 0..<an {
            guard p < b.count else { break }
            let (owner, afterName) = readName(b, p)
            var q = afterName
            guard q + 10 <= b.count else { break }
            let type = UInt16(b[q]) << 8 | UInt16(b[q + 1])
            let ttl = UInt32(b[q + 4]) << 24 | UInt32(b[q + 5]) << 16
                    | UInt32(b[q + 6]) << 8 | UInt32(b[q + 7])
            let rdlen = Int(b[q + 8]) << 8 | Int(b[q + 9])
            q += 10
            guard q + rdlen <= b.count else { break }
            if type == 1, rdlen == 4 {                            // A record
                let ip = UInt32(b[q]) << 24 | UInt32(b[q + 1]) << 16
                       | UInt32(b[q + 2]) << 8 | UInt32(b[q + 3])
                if !queryName.isEmpty { out.append((ip, queryName, ttl)) }
                if owner != queryName, !owner.isEmpty { out.append((ip, owner, ttl)) }
            }
            p = q + rdlen
        }
        return out
    }

    /// Read a (possibly compression-pointer) DNS name starting at `off`. Returns
    /// the lowercased dotted name and the offset of the byte AFTER the name in
    /// the record stream (pointer jumps don't advance the stream past the 2-byte
    /// pointer). Bounded against pointer loops.
    static func readName(_ b: [UInt8], _ off: Int) -> (String, Int) {
        var labels: [String] = []
        var p = off
        var afterPointer = -1
        var hops = 0
        while p < b.count, hops < 64 {
            let len = Int(b[p])
            if len == 0 { p += 1; break }
            if (len & 0xC0) == 0xC0 {                             // compression pointer
                guard p + 1 < b.count else { break }
                if afterPointer < 0 { afterPointer = p + 2 }
                p = ((len & 0x3F) << 8) | Int(b[p + 1])
                hops += 1
                continue
            }
            guard p + 1 + len <= b.count else { break }
            labels.append(String(decoding: b[(p + 1)..<(p + 1 + len)], as: UTF8.self))
            p += 1 + len
        }
        return (labels.joined(separator: ".").lowercased(), afterPointer >= 0 ? afterPointer : p)
    }
}

/// Thread-safe IPv4 → hostnames cache with per-entry TTL. Its own lock so the
/// snoop path (uplink→VM frames) and the verdict path (VM→uplink frames) — on
/// different threads — don't contend the switch's forwarding lock.
final class DNSSnoopCache: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [UInt32: (names: Set<String>, expiry: Date)] = [:]
    /// Cap a record's lifetime so a huge TTL can't pin a stale mapping forever,
    /// and floor it so a 0-TTL answer is still usable for the flow that follows.
    private let minTTL: TimeInterval = 60
    private let maxTTL: TimeInterval = 3600

    func record(ip: UInt32, name: String, ttl: UInt32, now: Date = Date()) {
        let life = min(max(TimeInterval(ttl), minTTL), maxTTL)
        let expiry = now.addingTimeInterval(life)
        lock.lock(); defer { lock.unlock() }
        if var e = map[ip], e.expiry > now {
            e.names.insert(name)
            e.expiry = max(e.expiry, expiry)
            map[ip] = e
        } else {
            map[ip] = (Set([name]), expiry)
            if map.count > 8192 { pruneLocked(now) }
        }
    }

    func names(for ip: UInt32, now: Date = Date()) -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard let e = map[ip], e.expiry > now else { return [] }
        return Array(e.names)
    }

    private func pruneLocked(_ now: Date) {
        map = map.filter { $0.value.expiry > now }
    }
}
