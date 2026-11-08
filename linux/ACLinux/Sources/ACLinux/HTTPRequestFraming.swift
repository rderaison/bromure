import Foundation
import NIOCore
import SandboxEngine

/// HTTP/1.1 framing for the Linux proxy (MitmProxy): when a buffered request
/// is whole, header edits, a response's status and body. Raw bytes in and
/// out, the way the swaps (TokenSwapper, SubscriptionAuthRewrite) take them.
// @port-skip linux-only: macOS's proxy frames requests in HTTPMitmConnection (readRequest / dechunk)
enum HTTPRequestFraming {
    enum Framing: Equatable {
        case needMore
        case invalid
        /// Refused under OpenShell's framing rules (a 400 naming why).
        case rejected(String)
        /// The request (a chunked body re-framed with a Content-Length), and
        /// the bytes after it.
        case complete(Data, extra: Data)
    }

    /// Whether `buf` starts with a whole request: its head, then a
    /// Content-Length body, a chunked one (decoded), or none. `strict` (the
    /// workspace has an OpenShell policy): OpenShell's framing rules, as
    /// macOS's readRequestSpooling applies them: the head validated and its
    /// body length derived by OpenShellHTTP.parseHead (header block at most
    /// maxHeaderBytes), a chunk-size line at most maxChunkLineBytes and
    /// valid UTF-8, trailers within maxHeaderBytes and maxTrailerFields.
    // @port-skip linux-only: proxy request framing (macOS: readRequestSpooling's strict mode)
    static func complete(_ buf: Data, strict: Bool = false) -> Framing {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else {
            if strict, buf.count > OpenShellHTTP.maxHeaderBytes {
                return .rejected("HTTP request headers exceed \(OpenShellHTTP.maxHeaderBytes) bytes")
            }
            return .needMore
        }
        let headEnd = end.upperBound
        let head = String(decoding: buf[buf.startIndex..<end.lowerBound], as: UTF8.self)
        let headers = Self.headers(head)
        var chunked = headers["transfer-encoding"]?.lowercased().contains("chunked") == true
        var strictLength: Int?
        if strict {
            do {
                switch try OpenShellHTTP.parseHead(Data(buf[buf.startIndex..<headEnd])).bodyLength {
                case .none: chunked = false; strictLength = 0
                case .contentLength(let n): chunked = false; strictLength = n
                case .chunked: chunked = true
                }
            } catch let e as OpenShellHTTP.Rejection {
                return .rejected(e.reason)
            } catch {
                return .rejected("HTTP request head can't be read")
            }
        }
        if chunked {
            switch dechunk(buf[headEnd...], strict: strict) {
            case .needMore: return .needMore
            case .invalid: return .invalid
            case .rejected(let why): return .rejected(why)
            case .complete(let body, let rest):
                let h = replacingHeaders(Data(buf[buf.startIndex..<headEnd]), drop: ["transfer-encoding", "content-length"],
                                         add: "Content-Length: \(body.count)")
                return .complete(h + body, extra: rest)
            }
        }
        let length: Int
        if let n = strictLength {
            length = n
        } else if let cl = headers["content-length"] {
            guard let n = Int(cl.trimmingCharacters(in: .whitespaces)), n >= 0 else { return .invalid }
            length = n
        } else {
            length = 0
        }
        let have = buf.count - (headEnd - buf.startIndex)
        guard have >= length else { return .needMore }
        let stop = headEnd + length
        return .complete(Data(buf[buf.startIndex..<stop]), extra: Data(buf[stop...]))
    }

    /// The head's header fields, names lowercased (the last one wins).
    // @port-skip linux-only: proxy request framing
    static func headers(_ head: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in head.split(separator: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            out[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    private enum Chunks { case needMore, invalid, rejected(String), complete(Data, Data) }

    /// A chunked body decoded, or nil when it isn't complete (cut short of
    /// its last chunk) or its framing is broken.
    // @port-skip linux-only: proxy response framing
    static func dechunkedBody(_ body: Data) -> Data? {
        guard case .complete(let b, _) = dechunk(body[...]) else { return nil }
        return b
    }

    // @port-skip linux-only: proxy request framing
    private static func dechunk(_ s: Data.SubSequence, strict: Bool = false) -> Chunks {
        var body = Data()
        var i = s.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let eol = s[i...].range(of: crlf) else {
                if strict, s.distance(from: i, to: s.endIndex) > OpenShellHTTP.maxChunkLineBytes {
                    return .rejected("Chunk-size line exceeds limit")
                }
                return .needMore
            }
            if strict, String(data: Data(s[i..<eol.lowerBound]), encoding: .utf8) == nil {
                return .rejected("Invalid UTF-8 in chunk-size line")
            }
            let sizeText = String(decoding: s[i..<eol.lowerBound], as: UTF8.self)
                .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            // Hex digits only (no sign), and a size Int can hold.
            guard !sizeText.isEmpty, sizeText.allSatisfy(\.isHexDigit),
                  let size = Int(sizeText, radix: 16) else {
                return strict ? .rejected("Invalid chunk size token: \"\(sizeText)\"") : .invalid
            }
            i = eol.upperBound
            if size == 0 {
                // Trailers, then the empty line (bounded under OpenShell's rules).
                var fields = 0, bytes = 0
                while true {
                    guard let e = s[i...].range(of: crlf) else {
                        if strict, bytes + s.distance(from: i, to: s.endIndex) > OpenShellHTTP.maxHeaderBytes {
                            return .rejected("Chunk trailers exceed \(OpenShellHTTP.maxHeaderBytes) bytes")
                        }
                        return .needMore
                    }
                    let empty = e.lowerBound == i
                    bytes += s.distance(from: i, to: e.upperBound)
                    i = e.upperBound
                    if empty { return .complete(body, Data(s[i...])) }
                    fields += 1
                    if strict, bytes > OpenShellHTTP.maxHeaderBytes {
                        return .rejected("Chunk trailers exceed \(OpenShellHTTP.maxHeaderBytes) bytes")
                    }
                    if strict, fields > OpenShellHTTP.maxTrailerFields {
                        return .rejected("Chunk trailers exceed \(OpenShellHTTP.maxTrailerFields) fields")
                    }
                }
            }
            // Bounded by what's here before any arithmetic: a size near
            // Int.max made `size + 2` overflow (a trap, the daemon gone).
            let left = s.distance(from: i, to: s.endIndex)
            guard left >= 2, size <= left - 2 else { return .needMore }
            let end = s.index(i, offsetBy: size)
            // The chunk's data is followed by its CRLF.
            guard s[end] == 0x0D, s[s.index(after: end)] == 0x0A else { return .invalid }
            body.append(contentsOf: s[i..<end])
            i = s.index(end, offsetBy: 2)
        }
    }

    /// `raw` (a head, or a head and body) with the `drop` headers removed and
    /// `add` after the start line.
    // @port-skip linux-only: proxy header edits
    static func replacingHeaders(_ raw: Data, drop: Set<String>, add: String) -> Data {
        guard let end = raw.range(of: Data("\r\n\r\n".utf8)) else { return raw }
        // Latin-1 both ways: a header's bytes go back as they came.
        let head = String(data: raw[raw.startIndex..<end.lowerBound], encoding: .isoLatin1) ?? ""
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst()
        lines.removeAll { l in
            guard let colon = l.firstIndex(of: ":") else { return false }
            return drop.contains(l[..<colon].trimmingCharacters(in: .whitespaces).lowercased())
        }
        let out = ([start, add] + lines).joined(separator: "\r\n") + "\r\n\r\n"
        return (out.data(using: .isoLatin1) ?? Data(out.utf8)) + raw[end.upperBound...]
    }

    /// A response's status and body (a chunked body decoded); status 0 when
    /// it doesn't parse.
    // @port-skip linux-only: proxy response parsing (macOS: parseStatusCode)
    static func responseStatusAndBody(_ raw: Data) -> (status: Int, body: Data) {
        let line = String(decoding: raw.prefix { $0 != 13 }, as: UTF8.self).split(separator: " ")
        let status = line.count > 1 ? Int(line[1]) ?? 0 : 0
        guard let end = raw.range(of: Data("\r\n\r\n".utf8)) else { return (status, Data()) }
        let head = String(decoding: raw[raw.startIndex..<end.lowerBound], as: UTF8.self)
        if headers(head)["transfer-encoding"]?.lowercased().contains("chunked") == true,
           case .complete(let body, _) = dechunk(raw[end.upperBound...]) {
            return (status, body)
        }
        return (status, Data(raw[end.upperBound...]))
    }

    /// A buffered reply past its interim heads: 100 Continue, 102 and 103
    /// Early Hints come before the final response on the same bytes. nil
    /// for a 101 (a switched protocol has no final response), a reply
    /// that's interim heads only, or one whose interim heads are followed
    /// by anything but a head; anything else as it is from the first
    /// non-1xx head on.
    // @port-skip linux-only: URLSession consumes 1xx on macOS
    static func finalResponse(_ raw: Data) -> Data? {
        var start = raw.startIndex
        var afterInterim = false
        while true {
            let rest = raw[start...]
            guard rest.starts(with: Data("HTTP/".utf8)),
                  let end = rest.range(of: Data("\r\n\r\n".utf8)) else {
                // After an interim head, anything but another head isn't a
                // final response (whatever real reply hides behind it).
                return afterInterim ? nil : Data(rest)
            }
            let line = String(decoding: rest[rest.startIndex..<(rest.firstIndex(of: 13) ?? end.lowerBound)], as: UTF8.self)
            let status = line.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
            guard (100...199).contains(status) else { return Data(rest) }
            if status == 101 { return nil }
            afterInterim = true
            start = end.upperBound
            if start == raw.endIndex { return nil }
        }
    }

    /// A whole response with a chunked body decoded (its Transfer-Encoding
    /// dropped), as macOS's URLSession hands the trace its response; any
    /// other response, or one that doesn't decode, as it is.
    // @port-skip linux-only: the trace's response copy (macOS: URLSession de-chunks)
    static func dechunkedResponse(_ raw: Data) -> Data {
        guard let end = raw.range(of: Data("\r\n\r\n".utf8)) else { return raw }
        let head = String(decoding: raw[raw.startIndex..<end.lowerBound], as: UTF8.self)
        guard headers(head)["transfer-encoding"]?.lowercased().contains("chunked") == true,
              case .complete(let body, _) = dechunk(raw[end.upperBound...]) else { return raw }
        return replacingHeaders(Data(raw[raw.startIndex..<end.upperBound]), drop: ["transfer-encoding"],
                                add: "Content-Length: \(body.count)") + body
    }
}

/// The parts of a TLS ClientHello the proxy needs before it picks a leaf:
/// the SNI and the offered ALPN protocols (linux/spike/mitm's parser).
// @port-skip linux-only: macOS reads the SNI in TLSClientHello.swift on its own stream
struct ClientHelloInfo: Equatable {
    var serverName: String?
    var alpn: [String]

    enum Parse: Equatable {
        case needMore
        case notTLS
        case hello(ClientHelloInfo)
    }

    /// Parses the first TLS record of `buf` (not consumed). The ClientHello
    /// must fit one record (16 KiB), which it does in practice.
    // @port-skip linux-only: ClientHello parsing for the Linux proxy
    static func parse(_ buf: ByteBuffer) -> Parse {
        let b = Array(buf.readableBytesView)
        guard b.count >= 5 else { return .needMore }
        guard b[0] == 0x16, b[1] == 0x03 else { return .notTLS }
        let recLen = Int(b[3]) << 8 | Int(b[4])
        guard b.count >= 5 + recLen else { return .needMore }
        var i = 5
        func u8() -> Int? { guard i < 5 + recLen else { return nil }; defer { i += 1 }; return Int(b[i]) }
        func u16() -> Int? { guard let h = u8(), let l = u8() else { return nil }; return h << 8 | l }
        func skip(_ n: Int) -> Bool { i += n; return i <= 5 + recLen }
        guard u8() == 1, skip(3), skip(2 + 32),
              let sid = u8(), skip(sid), let cs = u16(), skip(cs), let cm = u8(), skip(cm) else { return .notTLS }
        var info = ClientHelloInfo(serverName: nil, alpn: [])
        guard let extLen = u16() else { return .hello(info) }
        let extEnd = min(i + extLen, 5 + recLen)
        while i + 4 <= extEnd {
            guard let type = u16(), let len = u16() else { break }
            let start = i
            if type == 0x0000, let listLen = u16(), listLen > 3, u8() == 0, let n = u16(), i + n <= extEnd {
                info.serverName = String(decoding: b[i..<i + n], as: UTF8.self)
            } else if type == 0x0010, let listLen = u16() {
                let end = min(i + listLen, extEnd)
                while i < end, let n = u8(), i + n <= end {
                    info.alpn.append(String(decoding: b[i..<i + n], as: UTF8.self))
                    i += n
                }
            }
            i = start + len
        }
        return .hello(info)
    }
}
