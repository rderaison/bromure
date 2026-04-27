import Foundation
import Crypto

/// Pure SigV4 signing primitives — no HTTP I/O. `AWSResigner` calls
/// `sign(...)` to compute fresh signing material from credentials that
/// only ever live in this process's address space.
///
/// References:
///   - https://docs.aws.amazon.com/general/latest/gr/sigv4_signing.html
///   - Test vectors: https://docs.aws.amazon.com/general/latest/gr/signature-v4-test-suite.html
///
/// The "get-vanilla" reference vector is reproduced step-by-step in
/// the comments at the bottom of this file so the canonical-request
/// shape, key-derivation chain, and final signature can be checked
/// by inspection against an AWS-published expected.
public enum SigV4Signer {
    public struct Credentials: Sendable {
        public let accessKeyID: String
        public let secretAccessKey: String
        /// Optional STS session token. When present the caller MUST
        /// also include it as the `X-Amz-Security-Token` header in
        /// `Request.headers` so it gets folded into canonical-headers.
        public let sessionToken: String?
        public init(accessKeyID: String,
                    secretAccessKey: String,
                    sessionToken: String? = nil) {
            self.accessKeyID = accessKeyID
            self.secretAccessKey = secretAccessKey
            self.sessionToken = sessionToken
        }
    }

    public struct Scope: Sendable {
        /// `YYYYMMDD` portion of `X-Amz-Date`.
        public let date: String
        public let region: String
        public let service: String
        public init(date: String, region: String, service: String) {
            self.date = date
            self.region = region
            self.service = service
        }
        public var credentialScope: String {
            "\(date)/\(region)/\(service)/aws4_request"
        }
    }

    public struct Request {
        public let method: String
        /// Already-encoded path component (everything from the request
        /// line up to `?`). The SDK percent-encodes per the service's
        /// rules; we forward whatever the SDK produced.
        public let path: String
        /// Already-encoded query string (no leading `?`), in **wire**
        /// order. The signer canonicalizes (sort + join) internally —
        /// callers don't need to pre-sort.
        public let query: String
        /// Headers as `(name, value)` in submission order. Names case-
        /// insensitive; duplicates allowed (combined per RFC during
        /// canonicalization).
        public let headers: [(String, String)]
        public let body: Data
        public init(method: String, path: String, query: String,
                    headers: [(String, String)], body: Data) {
            self.method = method
            self.path = path
            self.query = query
            self.headers = headers
            self.body = body
        }
    }

    public struct SignedOutput {
        /// `AWS4-HMAC-SHA256 Credential=…, SignedHeaders=…, Signature=…`
        public let authorization: String
        /// Hex SHA256 of the body — or `UNSIGNED-PAYLOAD` when the
        /// caller passed `unsignedPayload: true`.
        public let payloadHash: String
        /// `YYYYMMDDTHHMMSSZ` — the `X-Amz-Date` header value.
        public let amzDate: String
        /// Sorted, semicolon-joined lowercase header names.
        public let signedHeaders: String
    }

    /// Sign the request. Caller must already have the headers list it
    /// intends to put on the wire (Host, Content-Type, X-Amz-Date,
    /// X-Amz-Content-SHA256, X-Amz-Security-Token if applicable, …) —
    /// `Authorization` itself is the only header excluded.
    public static func sign(
        request: Request,
        credentials: Credentials,
        scope: Scope,
        date: Date = Date(),
        unsignedPayload: Bool = false
    ) -> SignedOutput {
        let amzDate = isoBasic(date)

        let payloadHash: String
        if unsignedPayload {
            payloadHash = "UNSIGNED-PAYLOAD"
        } else {
            payloadHash = hexSHA256(request.body)
        }

        // Canonicalize headers. Values get whitespace-trimmed; runs of
        // internal whitespace outside of double-quoted strings are
        // collapsed to a single space. Names lowercased and sorted.
        // Duplicates joined with ',' (RFC 9110 §5.3).
        var byName: [String: [String]] = [:]
        for (k, v) in request.headers {
            let key = k.lowercased()
            byName[key, default: []].append(canonicalHeaderValue(v))
        }
        let names = byName.keys.sorted()
        var canonicalHeaders = ""
        for n in names {
            canonicalHeaders += "\(n):\(byName[n]!.joined(separator: ","))\n"
        }
        let signedHeaders = names.joined(separator: ";")

        let canonicalRequest = [
            request.method.uppercased(),
            request.path.isEmpty ? "/" : request.path,
            canonicalQueryString(request.query),
            canonicalHeaders,
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")

        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope.credentialScope,
            hexSHA256(Data(canonicalRequest.utf8))
        ].joined(separator: "\n")

        // Key-derivation chain: kSecret → kDate → kRegion → kService → kSigning.
        let kSecret  = Data("AWS4\(credentials.secretAccessKey)".utf8)
        let kDate    = hmac(key: kSecret,  msg: Data(scope.date.utf8))
        let kRegion  = hmac(key: kDate,    msg: Data(scope.region.utf8))
        let kService = hmac(key: kRegion,  msg: Data(scope.service.utf8))
        let kSigning = hmac(key: kService, msg: Data("aws4_request".utf8))

        let signature = hmac(key: kSigning, msg: Data(stringToSign.utf8))
            .map { String(format: "%02x", $0) }.joined()

        let auth = "AWS4-HMAC-SHA256 " +
            "Credential=\(credentials.accessKeyID)/\(scope.credentialScope), " +
            "SignedHeaders=\(signedHeaders), " +
            "Signature=\(signature)"

        return SignedOutput(authorization: auth,
                            payloadHash: payloadHash,
                            amzDate: amzDate,
                            signedHeaders: signedHeaders)
    }

    // MARK: - helpers

    public static func hexSHA256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hmac(key: Data, msg: Data) -> Data {
        let symKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: msg, using: symKey)
        return Data(mac)
    }

    /// `YYYYMMDDTHHMMSSZ` (ISO 8601 basic) in UTC.
    public static func isoBasic(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.string(from: date)
    }

    /// Canonical query string per SigV4: split on `&`, sort by key
    /// (then by value), join `key=value` with `&`. Caller is expected
    /// to have URI-encoded keys/values per the service's rules — the
    /// SDK does this for any request it intends to sign.
    static func canonicalQueryString(_ query: String) -> String {
        if query.isEmpty { return "" }
        let pairs = query.split(separator: "&", omittingEmptySubsequences: false)
            .map(String.init)
        let parsed: [(String, String)] = pairs.map { p in
            if let eq = p.firstIndex(of: "=") {
                return (String(p[..<eq]), String(p[p.index(after: eq)...]))
            }
            return (p, "")
        }
        let sorted = parsed.sorted { a, b in
            if a.0 != b.0 { return a.0 < b.0 }
            return a.1 < b.1
        }
        return sorted.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    /// Trim leading/trailing whitespace and collapse runs of internal
    /// whitespace (outside of double-quoted strings) to a single space.
    /// Per the SigV4 canonical-headers rule.
    static func canonicalHeaderValue(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        var out = ""
        var inQuotes = false
        var lastWasSpace = false
        for c in trimmed {
            if c == "\"" { inQuotes.toggle(); out.append(c); lastWasSpace = false; continue }
            if !inQuotes, c == " " || c == "\t" {
                if !lastWasSpace { out.append(" "); lastWasSpace = true }
            } else {
                out.append(c); lastWasSpace = false
            }
        }
        return out
    }
}

// MARK: - Reference vector documentation
//
// AWS "get-vanilla" test from the SigV4 test suite (paraphrased):
//
//   Method: GET
//   Path:   /
//   Query:  (empty)
//   Headers:
//     Host:        example.amazonaws.com
//     X-Amz-Date:  20150830T123600Z
//   Body: (empty)
//
//   AccessKey: AKIDEXAMPLE
//   Secret:    wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY
//   Region:    us-east-1
//   Service:   service
//   Date:      20150830T123600Z
//
// Expected canonical request:
//   GET\n
//   /\n
//   \n
//   host:example.amazonaws.com\n
//   x-amz-date:20150830T123600Z\n
//   \n
//   host;x-amz-date\n
//   e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
//
// Expected string-to-sign:
//   AWS4-HMAC-SHA256\n
//   20150830T123600Z\n
//   20150830/us-east-1/service/aws4_request\n
//   bb579772317eb040ac9ed261061d46c1f17a8133879d6129b6e1c25292927e63
//
// Expected signature:
//   5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31
//
// Expected Authorization:
//   AWS4-HMAC-SHA256
//   Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request,
//   SignedHeaders=host;x-amz-date,
//   Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31
