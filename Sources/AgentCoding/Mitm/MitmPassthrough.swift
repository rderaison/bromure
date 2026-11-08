import Foundation
import SandboxEngine
#if canImport(Darwin)
import Darwin
#endif

enum MitmPassthrough {
    /// Splice `appFD` (the guest side of the flow) to a fresh TCP connection to
    /// `destIP:destPort` — the exact IP the guest chose, never re-resolved, so a
    /// pinned host reaches its real endpoint. Raw bytes both ways; no TLS, no
    /// cert. Closes both fds when either side ends. This is also the fail-open
    /// fallback for unclassifiable flows.
    /// `profileID`: the workspace whose quarantine cuts the splice.
    static func splice(appFD: Int32, destIP: String, destPort: Int, profileID: UUID? = nil) {
        guard let upstream = connectRawTCP(ip: destIP, port: destPort) else {
            close(appFD)
            return
        }
        pumpBothWays(appFD: appFD, upstream: upstream, profileID: profileID)
    }

    /// Splice to addresses that already passed the destination checks (a
    /// proxied CONNECT to a `tls: skip` endpoint) — never re-resolved.
    static func splice(appFD: Int32, addresses: [OpenShellPolicy.IPAddress], destPort: Int, profileID: UUID? = nil) {
        guard let upstream = try? UpstreamPinning.connect(addresses, port: destPort) else {
            close(appFD)
            return
        }
        pumpBothWays(appFD: appFD, upstream: upstream, profileID: profileID)
    }

    private static func pumpBothWays(appFD: Int32, upstream: Int32, profileID: UUID? = nil) {
        // A quarantine shuts both sides (its cut gone before the fds close,
        // so it can never reach a reused descriptor).
        let cut = profileID.map { pid in
            WorkspaceQuarantine.shared.onQuarantine(pid) {
                shutdown(appFD, SHUT_RDWR)
                shutdown(upstream, SHUT_RDWR)
            }
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
            if let cut, let profileID { WorkspaceQuarantine.shared.remove(cut, for: profileID) }
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

    /// Connect to a numeric IP literal (never DNS). Blocking.
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
