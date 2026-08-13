import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Host-side list of hostnames whose TLS must NOT be intercepted — spliced raw
/// to the origin instead. Cert-pinners (google et al.) are built in; the
/// operator adds more in Preferences (`proxy.noMitmDomains`). App-global and
/// host-side, so the guest cannot influence what is or isn't inspected.
struct PassthroughList {
    private let entries: [String]

    /// Domains known to pin certificates (MiTM breaks them), always bypassed.
    static let builtins = ["google.com", "gstatic.com", "googleapis.com"]

    init(extra: [String]) {
        var all = PassthroughList.builtins
        all.append(contentsOf: extra
            .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
        self.entries = all
    }

    /// True if `host` equals or is a subdomain of any entry.
    func matches(_ host: String) -> Bool {
        let h = host.lowercased()
        return entries.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    /// Built-ins plus the operator's Preferences list.
    static func current() -> PassthroughList {
        PassthroughList(extra: UserDefaults.standard.stringArray(forKey: "proxy.noMitmDomains") ?? [])
    }
}

enum MitmPassthrough {
    /// Splice `appFD` (the guest side of the flow) to a fresh TCP connection to
    /// `destIP:destPort` — the exact IP the guest chose, never re-resolved, so a
    /// pinned host reaches its real endpoint. Raw bytes both ways; no TLS, no
    /// cert. Closes both fds when either side ends. This is also the fail-open
    /// fallback for unclassifiable flows.
    static func splice(appFD: Int32, destIP: String, destPort: Int) {
        guard let upstream = connectRawTCP(ip: destIP, port: destPort) else {
            close(appFD)
            return
        }
        let group = DispatchGroup()
        for (from, to) in [(appFD, upstream), (upstream, appFD)] {
            group.enter()
            Thread.detachNewThread {
                pump(from: from, to: to)
                shutdown(to, SHUT_WR)
                group.leave()
            }
        }
        group.notify(queue: .global()) {
            close(appFD)
            close(upstream)
        }
    }

    private static func pump(from: Int32, to: Int32) {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(from, &buf, buf.count)
            if n <= 0 { break }
            var off = 0
            let ok = buf.withUnsafeBytes { raw -> Bool in
                let base = raw.baseAddress!
                while off < n {
                    let w = Darwin.write(to, base + off, n - off)
                    if w > 0 { off += w }
                    else if w < 0 && errno == EINTR { continue }
                    else { return false }
                }
                return true
            }
            if !ok { break }
        }
    }

    /// Connect to a numeric IP literal (no DNS). Blocking.
    private static func connectRawTCP(ip: String, port: Int) -> Int32? {
        var hints = addrinfo(ai_flags: AI_NUMERICHOST, ai_family: AF_UNSPEC,
                             ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(ip, String(port), &hints, &res) == 0, let info = res else { return nil }
        defer { freeaddrinfo(res) }
        let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        if connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) != 0 {
            close(fd)
            return nil
        }
        return fd
    }
}
