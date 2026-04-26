import Foundation
@preconcurrency import Virtualization

/// One MITM connection's lifetime: read CONNECT, send 200, terminate
/// TLS with a forged leaf cert, read the wrapped HTTP request, swap
/// tokens, fire to upstream, stream response back.
///
/// Each call to `run()` handles exactly one tunnel. We don't bother
/// with HTTP/1.1 pipelining or keep-alive within a CONNECT — the cost
/// of a fresh CONNECT per request is negligible at agent traffic
/// volumes, and it keeps the state machine sane.
final class HTTPMitmConnection: @unchecked Sendable {
    let fd: Int32
    let profileID: UUID
    let certCache: CertCache
    let swapper: TokenSwapper

    init(fd: Int32, profileID: UUID, certCache: CertCache, swapper: TokenSwapper) {
        self.fd = fd
        self.profileID = profileID
        self.certCache = certCache
        self.swapper = swapper
    }

    /// Drives the full MITM exchange. Must be called from a Task —
    /// uses blocking syscalls under the hood. Closes the FD on exit
    /// regardless of success.
    func run() async {
        defer { close(fd) }
        do {
            try await drive()
        } catch {
            FileHandle.standardError.write(Data("[mitm] \(error)\n".utf8))
        }
    }

    private func drive() async throws {
        // 1. CONNECT request from client (proxy command). Treat as
        //    ASCII — proxy headers don't legally carry non-ASCII.
        let connectReq = try readRawHTTPRequest(plainFD: fd, maxBytes: 16 * 1024)
        guard let asString = String(data: connectReq, encoding: .ascii),
              let lineEnd = asString.range(of: "\r\n") else {
            throw MitmError.malformedHTTPRequest
        }
        let firstLine = asString[..<lineEnd.lowerBound]
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "CONNECT" else {
            throw MitmError.malformedHTTPRequest
        }
        let target = String(parts[1])
        let (host, port) = parseHostPort(target)

        // 2. Confirm the tunnel.
        try writeAll(fd: fd, bytes: Array("HTTP/1.1 200 Connection established\r\n\r\n".utf8))

        // 3. Server-side TLS using the cached forged leaf cert for `host`.
        let identity = try certCache.identity(for: host)
        let tls = try TLSServerStream(fd: fd, identity: identity)
        try tls.handshake()

        // 4. Read the wrapped HTTP request through TLS.
        let request = try readRawHTTPRequest(via: tls, maxBytes: 8 * 1024 * 1024)

        // 5. Swap tokens. host param is the SNI name; entries that
        //    don't match are no-ops.
        let swap = swapper.swap(rawRequest: request, host: host, profileID: profileID)
        if !swap.swaps.isEmpty {
            for s in swap.swaps {
                FileHandle.standardError.write(Data(
                    "[mitm] swapped \(s.fakePreview) → \(s.realPreview) on \(s.host)\n".utf8))
            }
        }

        // 6. Send to upstream via URLSession. Build a URLRequest from
        //    the raw HTTP wire frame.
        let upstreamResp = try await sendToUpstream(rawRequest: swap.modified, host: host, port: port)

        // 7. Send the response back through TLS.
        try tls.write(upstreamResp)

        // 8. Half-close on our side; let the client decide when it's done.
    }
}

// MARK: - HTTP wire helpers

/// Parse "host:port" → (host, port). Defaults to 443 if missing.
private func parseHostPort(_ s: String) -> (String, Int) {
    if let colon = s.lastIndex(of: ":"),
       let port = Int(s[s.index(after: colon)...]) {
        return (String(s[..<colon]), port)
    }
    return (s, 443)
}

/// Read until we have a full HTTP request (headers + Content-Length
/// body). Plain-FD variant: no TLS in between.
private func readRawHTTPRequest(plainFD fd: Int32, maxBytes: Int) throws -> Data {
    return try readUntilCompleteHTTP(maxBytes: maxBytes) { buf in
        var into = [UInt8](repeating: 0, count: buf)
        let n = read(fd, &into, buf)
        if n < 0 {
            throw MitmError.tlsReadFailed(OSStatus(errno))
        }
        if n == 0 { return Data() }
        return Data(into.prefix(n))
    }
}

private func readRawHTTPRequest(via tls: TLSServerStream, maxBytes: Int) throws -> Data {
    return try readUntilCompleteHTTP(maxBytes: maxBytes) { buf in
        try tls.read(maxBytes: buf)
    }
}

private func readUntilCompleteHTTP(maxBytes: Int,
                                   reader: (Int) throws -> Data) throws -> Data {
    var buffer = Data()
    let chunk = 16 * 1024
    var contentLength: Int? = nil
    var headerEnd: Int? = nil

    while buffer.count < maxBytes {
        let got = try reader(chunk)
        if got.isEmpty {
            // EOF before we got a full request.
            if headerEnd == nil { throw MitmError.unexpectedTermination }
            break
        }
        buffer.append(got)

        if headerEnd == nil,
           let r = buffer.range(of: Data("\r\n\r\n".utf8)) {
            headerEnd = r.upperBound
            // Parse Content-Length from headers.
            if let str = String(data: buffer.prefix(r.lowerBound), encoding: .ascii) {
                for line in str.split(separator: "\r\n") {
                    let lower = line.lowercased()
                    if lower.hasPrefix("content-length:") {
                        let v = lower.dropFirst("content-length:".count)
                            .trimmingCharacters(in: .whitespaces)
                        contentLength = Int(v)
                    }
                }
            }
        }
        if let end = headerEnd {
            let bodyHave = buffer.count - end
            if let cl = contentLength {
                if bodyHave >= cl { return buffer }
            } else {
                // No content-length → no body (or chunked, which we
                // don't handle in this minimal v1 — most agent APIs
                // send Content-Length).
                return buffer
            }
        }
    }
    return buffer
}

private func writeAll(fd: Int32, bytes: [UInt8]) throws {
    var sent = 0
    while sent < bytes.count {
        let n = bytes.withUnsafeBufferPointer { ptr in
            write(fd, ptr.baseAddress!.advanced(by: sent), bytes.count - sent)
        }
        if n < 0 {
            if errno == EAGAIN || errno == EINTR { continue }
            throw MitmError.tlsWriteFailed(OSStatus(errno))
        }
        sent += n
    }
}

// MARK: - Upstream

/// Reconstruct the raw HTTP request as a URLRequest, fire via
/// URLSession (which handles TLS validation upstream), and return the
/// raw HTTP/1.1 response we'll send back through the TLS server.
private func sendToUpstream(rawRequest: Data, host: String, port: Int) async throws -> Data {
    guard let endRange = rawRequest.range(of: Data("\r\n\r\n".utf8)) else {
        throw MitmError.malformedHTTPRequest
    }
    let headerData = rawRequest.subdata(in: 0..<endRange.lowerBound)
    let body       = rawRequest.subdata(in: endRange.upperBound..<rawRequest.count)
    guard let headerStr = String(data: headerData, encoding: .ascii) else {
        throw MitmError.malformedHTTPRequest
    }

    var lines = headerStr.split(separator: "\r\n", omittingEmptySubsequences: false)
        .map(String.init)
    guard !lines.isEmpty else { throw MitmError.malformedHTTPRequest }

    let requestLine = lines.removeFirst()
    let lineParts = requestLine.split(separator: " ")
    guard lineParts.count >= 3 else { throw MitmError.malformedHTTPRequest }
    let method = String(lineParts[0])
    let path   = String(lineParts[1])

    let scheme = (port == 443) ? "https" : "http"
    let portStr = (port == 443 || port == 80) ? "" : ":\(port)"
    guard let url = URL(string: "\(scheme)://\(host)\(portStr)\(path)") else {
        throw MitmError.malformedHTTPRequest
    }

    var req = URLRequest(url: url)
    req.httpMethod = method
    if !body.isEmpty { req.httpBody = body }

    for line in lines where !line.isEmpty {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        // Don't replay hop-by-hop / framing headers — URLSession sets these.
        switch name.lowercased() {
        case "host", "content-length", "connection", "transfer-encoding",
             "proxy-connection", "keep-alive", "te", "upgrade":
            continue
        default:
            req.setValue(value, forHTTPHeaderField: name)
        }
    }

    let (data, response) = try await URLSession.shared.data(for: req)
    guard let http = response as? HTTPURLResponse else {
        throw MitmError.upstreamFailed("non-HTTP response")
    }

    // Build raw HTTP/1.1 response wire frame.
    //
    // Critical: URLSession transparently decompresses gzip/br/deflate
    // responses. The `data` we have here is the *decompressed* body —
    // but `http.allHeaderFields` still carries the upstream's original
    // Content-Encoding + Content-Length (compressed size). Replaying
    // either of those would make the client try to decompress raw
    // bytes (ZlibError) or read the wrong number of bytes (truncate /
    // hang). Strip them and let our own Content-Length stand.
    //
    // Also strip Transfer-Encoding (we never chunk on the way back),
    // Connection (we set our own), and the proxy-only hop-by-hop
    // headers HTTP/1.1 lists in §13.5.1.
    let stripped: Set<String> = [
        "content-encoding", "content-length",
        "transfer-encoding", "connection",
        "proxy-connection", "keep-alive", "te", "trailer",
        "upgrade", "proxy-authenticate", "proxy-authorization",
    ]
    var out = "HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode).capitalized)\r\n"
    for (k, v) in http.allHeaderFields {
        guard let key = k as? String, let val = v as? String else { continue }
        if stripped.contains(key.lowercased()) { continue }
        out += "\(key): \(val)\r\n"
    }
    out += "Content-Length: \(data.count)\r\n"
    out += "Connection: close\r\n"
    out += "\r\n"
    var raw = Data(out.utf8)
    raw.append(data)
    return raw
}
