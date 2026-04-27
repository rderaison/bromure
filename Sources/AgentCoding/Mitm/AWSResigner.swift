import Foundation

/// Detects AWS-bound HTTPS requests, strips the guest's signature,
/// and re-signs with credentials that only ever live in this process's
/// address space.
///
/// **Threat model**: the AWS SDK in the VM signs every request with a
/// fake secret vended by `AWSCredentialServer`. The signature is bound
/// to fail. The resigner intercepts the proxied request, replaces the
/// guest's `Authorization` (and adds the real `X-Amz-Security-Token`
/// when the profile carries STS material), and recomputes the SigV4
/// signature using the real secret. If a request bypasses the proxy,
/// AWS rejects it with `InvalidSignatureException` — fail-closed.
///
/// **What we sign over**:
///   - `Host` (mandatory; matches what URLSession will set from the URL)
///   - `X-Amz-Date`, `X-Amz-Content-SHA256`, `X-Amz-Security-Token` (we set)
///   - `Content-Type` and any other non-hop-by-hop headers from the
///     guest request that URLSession passes through verbatim
///
/// **What we do NOT sign over**: hop-by-hop headers (`Connection`,
/// `Keep-Alive`, `Transfer-Encoding`, `TE`, `Upgrade`, `Proxy-*`),
/// `Authorization` (we replace), `Content-Length` (URLSession derives
/// from body), and the original `X-Amz-Date` / `X-Amz-Content-SHA256` /
/// `X-Amz-Security-Token` headers (we regenerate).
///
/// **Out of scope (MVP)**:
///   - `STREAMING-AWS4-HMAC-SHA256-PAYLOAD` chunked S3 uploads — chunk-
///     by-chunk signing chain isn't reproducible without the original
///     secret. Detected and surfaced to the guest as a 501 with a clear
///     message; the guest's SDK should fall back to single-shot uploads.
///   - SigV4A (asymmetric) — used by some cross-region S3 ops; rare.
///   - Query-string-signed requests (presigned URLs). The SDK doesn't
///     normally make them itself; it generates them for third parties.
public final class AWSResigner: @unchecked Sendable {
    private let credServer: AWSCredentialServer

    public init(credServer: AWSCredentialServer) {
        self.credServer = credServer
    }

    public enum Outcome {
        /// Not an AWS host, or no `Authorization: AWS4-HMAC-SHA256` —
        /// nothing to do; caller forwards `rawRequest` as-is.
        case unchanged
        /// Re-signed wire bytes; caller forwards these.
        case resigned(Data)
        /// User denied consent. Caller MUST write `response` directly
        /// back to the guest TLS stream and stop processing — do not
        /// forward upstream.
        case denied(response: Data)
        /// Resign failed (malformed Authorization, unsupported feature,
        /// etc.). Caller MUST write `response` back to the guest. The
        /// alternative — forwarding the unsigned-or-broken request to
        /// AWS — would just trigger an InvalidSignatureException after
        /// a network round-trip.
        case failed(reason: String, response: Data)
    }

    /// Match `*.amazonaws.com` and `*.amazonaws.com.cn` (covers
    /// govcloud, ISO partitions, regional + bucket-style S3, etc.)
    public static func isAWSHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "amazonaws.com"
            || h == "amazonaws.com.cn"
            || h.hasSuffix(".amazonaws.com")
            || h.hasSuffix(".amazonaws.com.cn")
    }

    /// Strip and re-sign. Returns `.unchanged` for non-AWS hosts so the
    /// caller can use this as a transparent pass-through filter.
    public func resign(rawRequest: Data, host: String, profileID: UUID) async -> Outcome {
        guard Self.isAWSHost(host) else { return .unchanged }
        guard let parsed = ParsedHTTPRequest(rawRequest: rawRequest) else {
            return .unchanged
        }
        guard let oldAuth = parsed.headerValue("Authorization"),
              oldAuth.hasPrefix("AWS4-HMAC-SHA256") else {
            // Either anonymous (e.g. some public S3 reads) or
            // signed with an algorithm we don't know how to handle.
            // Forward unmodified.
            return .unchanged
        }
        guard let scope = Self.parseScope(oldAuth) else {
            return .failed(reason: "malformed AWS Authorization header",
                           response: Self.errorResponse(
                                status: 502,
                                reason: "Bad Gateway",
                                body: "bromure: could not parse AWS Authorization\n"))
        }

        // STREAMING-AWS4-HMAC-SHA256-PAYLOAD: chunk-by-chunk signing
        // can't be reproduced without the original secret (each chunk's
        // signature chains off the previous). Bail with a clear error.
        let originalContentSHA = parsed.headerValue("X-Amz-Content-SHA256") ?? ""
        if originalContentSHA == "STREAMING-AWS4-HMAC-SHA256-PAYLOAD" {
            return .failed(reason: "streaming chunked uploads not supported",
                           response: Self.errorResponse(
                                status: 501,
                                reason: "Not Implemented",
                                body: "bromure: aws-chunked uploads not supported by the host signer\n"))
        }

        // Pull the real signing material (consent-gated when the
        // profile flagged the credential).
        let scopeHint = NSLocalizedString(
            "for any AWS API call (SigV4 signing on the host)",
            comment: "")
        let mat = await credServer.signingMaterial(
            for: profileID, scopeHint: scopeHint)
        let creds: SigV4Signer.Credentials
        switch mat {
        case .material(let c):
            creds = c
        case .denied:
            return .denied(response: Self.errorResponse(
                status: 403,
                reason: "Forbidden",
                body: "bromure: AWS API call denied by user consent\n"))
        case .missing:
            // Profile has no creds at all. Letting the request through
            // gives the SDK an InvalidClientTokenId error, which is
            // more diagnostic than us swallowing it.
            return .unchanged
        }

        // Build the headers we'll BOTH sign over AND put on the wire.
        // Drop the things URLSession overrides or that we regenerate.
        var keep: [(String, String)] = []
        for (n, v) in parsed.headers {
            switch n.lowercased() {
            case "authorization", "x-amz-date", "x-amz-content-sha256",
                 "x-amz-security-token",
                 "host", "content-length",
                 "connection", "proxy-connection", "transfer-encoding",
                 "keep-alive", "te", "upgrade", "proxy-authorization":
                continue
            default:
                keep.append((n, v))
            }
        }

        let now = Date()
        let amzDate = SigV4Signer.isoBasic(now)
        let dateOnly = String(amzDate.prefix(8))
        // Honor the SDK's intent on UNSIGNED-PAYLOAD; otherwise compute
        // the body hash ourselves.
        let unsignedPayload = (originalContentSHA == "UNSIGNED-PAYLOAD")
        let payloadHash = unsignedPayload
            ? "UNSIGNED-PAYLOAD"
            : SigV4Signer.hexSHA256(parsed.body)

        // Append the headers we generate. Order doesn't matter for
        // canonicalization (signer sorts) but does for wire consistency.
        var signedHeaders: [(String, String)] = keep
        signedHeaders.append(("Host", host))
        signedHeaders.append(("X-Amz-Date", amzDate))
        signedHeaders.append(("X-Amz-Content-SHA256", payloadHash))
        if let st = creds.sessionToken, !st.isEmpty {
            signedHeaders.append(("X-Amz-Security-Token", st))
        }

        let req = SigV4Signer.Request(
            method: parsed.method,
            path: parsed.path.isEmpty ? "/" : parsed.path,
            query: parsed.query,
            headers: signedHeaders,
            body: parsed.body)
        let signed = SigV4Signer.sign(
            request: req,
            credentials: creds,
            scope: SigV4Signer.Scope(date: dateOnly,
                                     region: scope.region,
                                     service: scope.service),
            date: now,
            unsignedPayload: unsignedPayload)

        // Reassemble. We sign over Host so the signature matches what
        // URLSession will put on the wire (URLSession derives Host from
        // the URL, which has the same hostname). Drop our synthetic
        // Host before reassembly to avoid duplicate Host headers.
        let onWire = signedHeaders.filter { $0.0.lowercased() != "host" }
            + [("Authorization", signed.authorization)]
        let bytes = Self.assemble(
            requestLine: parsed.requestLine,
            headers: onWire,
            body: parsed.body)

        let logLine = "[mitm] AWS resign \(parsed.method) \(host)\(parsed.path) " +
            "scope=\(scope.region)/\(scope.service) " +
            "akid=\(Self.maskAccessKey(creds.accessKeyID))\n"
        FileHandle.standardError.write(Data(logLine.utf8))

        return .resigned(bytes)
    }

    // MARK: - Helpers

    /// Extract `(date, region, service)` from a SigV4 Authorization
    /// header. Format:
    ///   `AWS4-HMAC-SHA256 Credential=AKID/DATE/REGION/SERVICE/aws4_request, ...`
    static func parseScope(_ auth: String) -> (date: String, region: String, service: String)? {
        guard let credRange = auth.range(of: "Credential=") else { return nil }
        let after = auth[credRange.upperBound...]
        let credValue = after.prefix { $0 != "," && !$0.isWhitespace }
        let parts = credValue.split(separator: "/")
        guard parts.count == 5, parts[4] == "aws4_request" else { return nil }
        return (date: String(parts[1]),
                region: String(parts[2]),
                service: String(parts[3]))
    }

    private static func maskAccessKey(_ akid: String) -> String {
        guard akid.count > 6 else { return "***" }
        return String(akid.prefix(4)) + "…" + String(akid.suffix(4))
    }

    private static func assemble(requestLine: String,
                                 headers: [(String, String)],
                                 body: Data) -> Data {
        var head = requestLine + "\r\n"
        for (n, v) in headers {
            head += "\(n): \(v)\r\n"
        }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }

    /// Build a minimal HTTP/1.1 error response to send back through
    /// the TLS server stream. Body is plain text so SDK error messages
    /// quote something legible.
    private static func errorResponse(status: Int, reason: String, body: String) -> Data {
        let bodyBytes = Data(body.utf8)
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: text/plain; charset=utf-8\r\n"
        head += "Content-Length: \(bodyBytes.count)\r\n"
        head += "Connection: close\r\n"
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(bodyBytes)
        return out
    }
}

/// Tiny request parser sized for the resigner's needs. Splits the
/// wire bytes into request line / headers / body. No validation —
/// the proxy's already accepted these bytes from the SDK and we
/// trust the SDK's framing.
struct ParsedHTTPRequest {
    let requestLine: String
    let method: String
    let path: String
    let query: String
    let headers: [(String, String)]
    let body: Data

    init?(rawRequest: Data) {
        guard let endRange = rawRequest.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }
        let headerData = rawRequest.subdata(in: 0..<endRange.lowerBound)
        let body = rawRequest.subdata(in: endRange.upperBound..<rawRequest.count)
        guard let headerStr = String(data: headerData, encoding: .ascii) else {
            return nil
        }
        var lines = headerStr.split(separator: "\r\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard !lines.isEmpty else { return nil }
        let line = lines.removeFirst()
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])
        let path: String
        let query: String
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            query = String(target[target.index(after: q)...])
        } else {
            path = target
            query = ""
        }
        var headers: [(String, String)] = []
        for ln in lines where !ln.isEmpty {
            guard let colon = ln.firstIndex(of: ":") else { continue }
            let n = String(ln[..<colon]).trimmingCharacters(in: .whitespaces)
            let v = String(ln[ln.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers.append((n, v))
        }
        self.requestLine = line
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    func headerValue(_ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first(where: { $0.0.lowercased() == lower })?.1
    }
}
