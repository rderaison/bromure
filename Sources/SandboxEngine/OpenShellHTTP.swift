import Foundation

// MARK: - HTTP/1 request framing, OpenShell-strict
//
// Port of the checks OpenShell's L7 parser applies before any policy runs
// (openshell-supervisor-network `l7/rest.rs`: `parse_http_request`,
// `validate_http_request_header_block`, `parse_body_length`, the chunked
// reader's limits; `l7/relay.rs`: `request_authority_matches_endpoint`).
// Bromure applies them to every request when a workspace runs an OpenShell
// policy; without one, the proxy keeps its lenient framing.

public enum OpenShellHTTP {
    public static let maxHeaderBytes = 16_384
    public static let maxChunkLineBytes = maxHeaderBytes
    public static let maxTrailerFields = 128

    public struct Rejection: Error, Equatable, CustomStringConvertible {
        public let reason: String
        /// 400 for malformed framing, 403 for an authority mismatch.
        public let status: Int
        public init(_ reason: String, status: Int = 400) { self.reason = reason; self.status = status }
        public var description: String { reason }
    }

    public enum BodyLength: Equatable, Sendable {
        case none
        case contentLength(Int)
        case chunked
    }

    /// `host[:port]` as `http::uri::Authority` reads it (userinfo dropped,
    /// IPv6 brackets kept out of `host`).
    public struct Authority: Equatable, Sendable {
        public let host: String
        public let port: UInt16?

        public static func parse(_ raw: String) -> Authority? {
            var s = Substring(raw)
            guard !s.isEmpty, !s.contains(where: { $0 == " " || $0 == "/" || $0 == "?" || $0 == "#" }) else { return nil }
            if let at = s.lastIndex(of: "@") { s = s[s.index(after: at)...] }
            var host: Substring, portPart: Substring?
            if s.hasPrefix("[") {
                guard let close = s.firstIndex(of: "]") else { return nil }
                host = s[s.index(after: s.startIndex)..<close]
                let rest = s[s.index(after: close)...]
                if rest.isEmpty { portPart = nil }
                else if rest.hasPrefix(":") { portPart = rest.dropFirst() } else { return nil }
            } else if let colon = s.lastIndex(of: ":") {
                host = s[..<colon]; portPart = s[s.index(after: colon)...]
            } else {
                host = s; portPart = nil
            }
            guard !host.isEmpty else { return nil }
            var port: UInt16?
            if let p = portPart {
                if p.isEmpty { port = nil }
                else {
                    guard p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber), let v = UInt16(p) else { return nil }
                    port = v
                }
            }
            return Authority(host: String(host), port: port)
        }

        var normalizedHost: String {
            var h = host.trimmingCharacters(in: .whitespaces)
            while h.hasSuffix(".") { h.removeLast() }
            return h.lowercased()
        }
    }

    public struct RequestHead: Sendable {
        public let method: String
        public let target: String
        public let version: String
        public let host: Authority?
        public let bodyLength: BodyLength
        public let headerString: String
    }

    // MARK: header block

    /// Validate a complete header block (request line through the blank
    /// line) and derive its body framing. Throws a `Rejection` (400).
    public static func parseHead(_ header: Data) throws -> RequestHead {
        guard header.count <= maxHeaderBytes else {
            throw Rejection("HTTP request headers exceed \(maxHeaderBytes) bytes")
        }
        let bytes = [UInt8](header)
        for (i, b) in bytes.enumerated() where b == 0x0A && (i == 0 || bytes[i - 1] != 0x0D) {
            throw Rejection("HTTP headers contain bare LF (line feed without carriage return)")
        }
        guard let text = String(bytes: bytes, encoding: .utf8) else {
            throw Rejection("HTTP headers contain invalid UTF-8")
        }
        guard text.hasSuffix("\r\n\r\n") else { throw Rejection("HTTP request headers are missing the CRLF terminator") }
        // Byte-level: "\r\n" is one Character, so String.dropLast would overshoot.
        let block = String(decoding: bytes.dropLast(4), as: UTF8.self)
        var lines = block.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw Rejection("HTTP request is missing a request line") }
        let requestLine = lines.removeFirst()

        // Request line: exactly METHOD SP target SP version.
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty, !parts[2].isEmpty else {
            throw Rejection("HTTP request line must be exactly 'METHOD SP target SP HTTP/1.0|HTTP/1.1'")
        }
        let method = String(parts[0]), target = String(parts[1]), version = String(parts[2])
        guard method.utf8.allSatisfy(isTokenByte) else { throw Rejection("HTTP request method is not a valid HTTP token") }
        guard !target.utf8.contains(where: { $0 <= 0x20 || $0 == 0x7F }) else {
            throw Rejection("HTTP request target contains whitespace or a control byte")
        }
        guard version == "HTTP/1.0" || version == "HTTP/1.1" else { throw Rejection("Unsupported HTTP version: \(version)") }

        var nominated = Set<String>()
        var hosts: [String] = []
        var codings: [String] = []
        var contentLength: Int?
        for line in lines {
            if let f = line.utf8.first, f == 0x20 || f == 0x09 {
                throw Rejection("HTTP request header continuation lines are not supported")
            }
            guard let colon = line.firstIndex(of: ":") else { throw Rejection("HTTP request header field is missing ':'") }
            let name = line[..<colon], value = line[line.index(after: colon)...]
            if let l = name.utf8.last, l == 0x20 || l == 0x09 {
                throw Rejection("HTTP request header field contains whitespace before ':'")
            }
            guard !name.isEmpty, name.utf8.allSatisfy(isTokenByte) else {
                throw Rejection("HTTP request header field name is not a valid HTTP token")
            }
            guard value.utf8.allSatisfy({ $0 == 0x09 || (0x20...0x7E).contains($0) || $0 >= 0x80 }) else {
                throw Rejection("HTTP request header field value contains an invalid control byte")
            }
            let lname = name.lowercased()
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            switch lname {
            case "connection":
                for token in value.split(separator: ",", omittingEmptySubsequences: false) {
                    let t = token.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty, t.utf8.allSatisfy(isTokenByte) else {
                        throw Rejection("HTTP Connection header contains an invalid option token")
                    }
                    nominated.insert(t.lowercased())
                }
            case "host":
                hosts.append(trimmed)
            case "transfer-encoding":
                for c in value.split(separator: ",", omittingEmptySubsequences: false) {
                    let coding = c.trimmingCharacters(in: .whitespaces)
                    guard !coding.isEmpty else { throw Rejection("Request contains an empty Transfer-Encoding value") }
                    codings.append(coding.lowercased())
                }
            case "content-length":
                guard !trimmed.isEmpty, trimmed.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
                      let n = Int(trimmed) else {
                    throw Rejection("Request contains invalid Content-Length value")
                }
                if let prev = contentLength, prev != n {
                    throw Rejection("Request contains multiple Content-Length headers with differing values (\(prev) vs \(n))")
                }
                contentLength = n
            default: break
            }
        }
        if !nominated.isDisjoint(with: ["host", "content-length", "transfer-encoding"]) {
            throw Rejection("HTTP Connection header nominates a request framing or routing field")
        }

        // Host: at most one, a valid authority; required on HTTP/1.1.
        guard hosts.count <= 1 else { throw Rejection("HTTP request contains multiple Host headers") }
        var host: Authority?
        if let h = hosts.first {
            guard let a = Authority.parse(h) else { throw Rejection("HTTP request Host header contains an invalid authority") }
            host = a
        }
        if version == "HTTP/1.1", host == nil { throw Rejection("HTTP/1.1 request is missing a Host header") }
        if let abs = absoluteForm(target) {
            guard let host else { throw Rejection("HTTP absolute-form request is missing a Host header") }
            guard authoritiesMatch(abs.authority, host, scheme: abs.scheme) else {
                throw Rejection("HTTP absolute-form request authority does not match the Host header")
            }
        }

        // Framing (`parse_body_length`).
        let body: BodyLength
        if !codings.isEmpty, contentLength != nil {
            throw Rejection("Request contains both Transfer-Encoding and Content-Length headers")
        } else if !codings.isEmpty {
            guard codings == ["chunked"] else { throw Rejection("Request contains an unsupported Transfer-Encoding sequence") }
            body = .chunked
        } else if let n = contentLength {
            body = .contentLength(n)
        } else {
            body = .none
        }
        return RequestHead(method: method, target: target, version: version, host: host,
                           bodyLength: body, headerString: text)
    }

    // MARK: authority vs the authorized endpoint

    /// `request_authority_matches_endpoint`: the request's authority (the
    /// absolute-form target's, else Host) must name the tunnel's endpoint.
    /// A request without Host passes (HTTP/1.0).
    public static func authorityMatchesEndpoint(_ head: RequestHead, host endpoint: String, port: UInt16,
                                                transportDefaultPort: UInt16) -> Bool {
        guard let hostHeader = head.host else { return true }
        let authority: Authority, fallbackPort: UInt16
        if let abs = absoluteForm(head.target) {
            guard let dp = Self.defaultPort(abs.scheme) else { return false }
            authority = abs.authority; fallbackPort = dp
        } else {
            authority = hostHeader; fallbackPort = transportDefaultPort
        }
        let e = Authority(host: endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), port: nil)
        return authority.normalizedHost == e.normalizedHost && (authority.port ?? fallbackPort) == port
    }

    static func authoritiesMatch(_ a: Authority, _ b: Authority, scheme: String?) -> Bool {
        guard a.normalizedHost == b.normalizedHost else { return false }
        let d = scheme.flatMap(defaultPort)
        return (a.port ?? d) == (b.port ?? d)
    }

    static func defaultPort(_ scheme: String) -> UInt16? {
        switch scheme.lowercased() {
        case "http", "ws": return 80
        case "https", "wss": return 443
        default: return nil
        }
    }

    /// `scheme://authority…` targets.
    static func absoluteForm(_ target: String) -> (scheme: String, authority: Authority)? {
        guard let m = target.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) else { return nil }
        let scheme = String(target[m].dropLast(3))
        let rest = target[m.upperBound...]
        let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        guard let a = Authority.parse(String(rest[..<end])) else { return nil }
        return (scheme, a)
    }

    static func isTokenByte(_ b: UInt8) -> Bool {
        (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b)
            || Array("!#$%&'*+-.^_`|~".utf8).contains(b)
    }
}
