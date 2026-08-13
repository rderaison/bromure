import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Minimal TLS ClientHello SNI extractor for the transparent-interception path.
/// A transparent flow has no CONNECT line, so the destination name is recovered
/// from the ClientHello's server_name extension — it decides the forged-cert
/// name and the MiTM-vs-passthrough choice. This does no validation beyond
/// locating the SNI; trust is TLSServerStream's job.
enum TLSClientHello {
    enum Result: Equatable {
        case needMoreData      // not enough bytes yet; peek again
        case notTLS            // first record isn't a TLS handshake
        case noSNI             // valid ClientHello, no usable server_name
        case sni(String)       // lowercased host_name
    }

    /// Parse the SNI from a buffer that begins at the TLS record layer.
    ///
    /// Returns `.needMoreData` ONLY while the first record isn't fully buffered;
    /// once it is, every path is terminal (so a peek loop can't spin forever on a
    /// complete-but-odd hello). A ClientHello that spans multiple records — rare —
    /// is treated as `.noSNI` (falls to passthrough) rather than hang.
    static func parseSNI(_ b: [UInt8]) -> Result {
        func u16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }

        // TLS record: content_type(1)=0x16 handshake, version(2), length(2).
        // Check the content type before the length so a non-TLS first byte is
        // rejected immediately, even with fewer than 5 bytes buffered.
        guard let first = b.first else { return .needMoreData }
        guard first == 0x16 else { return .notTLS }
        guard b.count >= 5 else { return .needMoreData }
        let recLen = u16(3)
        guard b.count >= 5 + recLen else { return .needMoreData }

        // From here the first record is fully present: never return needMoreData.
        var p = 5
        // Handshake header: msg_type(1)=0x01 ClientHello, length(3).
        guard p + 4 <= b.count else { return .noSNI }
        guard b[p] == 0x01 else { return .notTLS }
        let hsLen = Int(b[p + 1]) << 16 | Int(b[p + 2]) << 8 | Int(b[p + 3])
        let hsEnd = p + 4 + hsLen
        guard hsEnd <= b.count else { return .noSNI }   // spans records → skip
        p += 4

        p += 2 + 32                                     // client_version + random
        guard p + 1 <= b.count else { return .noSNI }
        p += 1 + Int(b[p])                              // session_id
        guard p + 2 <= b.count else { return .noSNI }
        p += 2 + u16(p)                                 // cipher_suites
        guard p + 1 <= b.count else { return .noSNI }
        p += 1 + Int(b[p])                              // compression_methods

        guard p + 2 <= b.count else { return .noSNI }   // no extensions block
        let extEnd = min(p + 2 + u16(p), hsEnd)
        p += 2
        while p + 4 <= extEnd {
            let type = u16(p), len = u16(p + 2)
            p += 4
            guard p + len <= b.count else { return .noSNI }
            if type == 0x0000 {                         // server_name
                var q = p
                guard q + 2 <= p + len else { return .noSNI }
                let listEnd = min(q + 2 + u16(q), p + len)
                q += 2
                while q + 3 <= listEnd {
                    let nameType = b[q], nameLen = u16(q + 1)
                    q += 3
                    guard q + nameLen <= b.count else { return .noSNI }
                    if nameType == 0 {                  // host_name
                        if let s = String(bytes: b[q..<q + nameLen], encoding: .utf8), !s.isEmpty {
                            return .sni(s.lowercased())
                        }
                        return .noSNI
                    }
                    q += nameLen
                }
                return .noSNI
            }
            p += len
        }
        return .noSNI
    }

    /// Peek (MSG_PEEK — never consume) the ClientHello on `fd` and extract the
    /// SNI. Because nothing is consumed, `TLSServerStream`'s handshake re-reads
    /// the same bytes and a passthrough splice forwards them on its first read.
    /// Bounded by `cap` bytes and `timeoutMs`; returns `.needMoreData` if neither
    /// a full hello nor a terminal verdict arrives in time (caller fails open).
    static func peek(fd: Int32, cap: Int = 8192, timeoutMs: Int32 = 5000) -> Result {
        var buf = [UInt8](repeating: 0, count: cap)
        let start = Date()
        while true {
            let remaining = timeoutMs - Int32(Date().timeIntervalSince(start) * 1000)
            if remaining <= 0 { return .needMoreData }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pr = withUnsafeMutablePointer(to: &p) { poll($0, 1, remaining) }
            if pr <= 0 { return .needMoreData }         // timeout or poll error
            let n = recv(fd, &buf, cap, Int32(MSG_PEEK))
            if n < 0 { if errno == EINTR { continue }; return .notTLS }
            if n == 0 { return .notTLS }                // peer closed before a hello
            let r = parseSNI(Array(buf[0..<Int(n)]))
            if r != .needMoreData { return r }
            if Int(n) >= cap { return .noSNI }          // hello bigger than our cap
        }
    }
}
