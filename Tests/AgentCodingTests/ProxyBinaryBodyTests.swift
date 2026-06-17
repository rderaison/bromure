import Foundation
import Testing
@testable import bromure_ac

/// Regression tests for the subscription token-swap / leak-suppression paths
/// on requests with a **non-UTF-8 body** — e.g. Grok's gzip `*.tar.gz`
/// session-state and OTLP `/v1/traces` uploads. The proxy used to decode the
/// whole request as UTF-8, which returned nil on such bodies and silently
/// skipped both the Bearer swap (bogus token → HTTP 401) and the
/// false-positive-leak suppression. The header path is now body-agnostic.
@Suite("Proxy binary-body header handling")
struct ProxyBinaryBodyTests {

    /// A request whose body is a real gzip stream (starts with 1f 8b and
    /// contains bytes that are invalid as UTF-8), with a Bearer header.
    private func gzipBodyRequest(bearer: String) -> Data {
        let header =
            "POST /v1/traces HTTP/1.1\r\n" +
            "host: cli-chat-proxy.grok.com\r\n" +
            "authorization: Bearer \(bearer)\r\n" +
            "content-encoding: gzip\r\n" +
            "content-length: 6\r\n\r\n"
        var data = Data(header.utf8)
        // gzip magic + bytes that are NOT valid UTF-8 (0x8b, 0xff, 0xfe).
        let body: [UInt8] = [0x1f, 0x8b, 0x08, 0x00, 0xff, 0xfe]
        data.append(contentsOf: body)
        return data
    }

    @Test("Whole-request UTF-8 decode fails on a gzip body (old code path)")
    func utf8DecodeFailsButHeaderSucceeds() {
        let req = gzipBodyRequest(bearer: "bogus-token-xyz")
        // This is exactly the guard the old swap/leak paths used — it drops
        // the request on the floor for a binary body.
        #expect(String(data: req, encoding: .utf8) == nil)
        // The new body-agnostic path still recovers the headers.
        let hdr = HTTPMitmConnection.rawHeaderSection(of: req)
        #expect(hdr != nil)
        #expect(HTTPMitmConnection.bearerToken(inHeaderSection: hdr!) == "bogus-token-xyz")
    }

    @Test("Bearer swap rewrites the header and preserves the binary body byte-for-byte")
    func swapPreservesBinaryBody() {
        let req = gzipBodyRequest(bearer: "bogus-token-xyz")
        let out = HTTPMitmConnection.replaceAuthorizationBearer(
            rawRequest: req, token: "REAL-ACCESS-123")

        // Split the output at the header terminator.
        let sep = out.range(of: Data("\r\n\r\n".utf8))!
        let outHeader = String(data: out.subdata(in: out.startIndex..<sep.lowerBound),
                               encoding: .isoLatin1)!
        let outBody = out.subdata(in: sep.upperBound..<out.endIndex)

        // Header now carries the real token, not the bogus one.
        #expect(outHeader.contains("Authorization: Bearer REAL-ACCESS-123"))
        #expect(!outHeader.contains("bogus-token-xyz"))
        // Other headers survive.
        #expect(outHeader.contains("content-encoding: gzip"))
        // Body bytes are untouched.
        #expect(Array(outBody) == [0x1f, 0x8b, 0x08, 0x00, 0xff, 0xfe])
    }

    @Test("Header-only append (MCP-style splice) keeps the binary body")
    func spliceKeepsBinaryBody() {
        let req = gzipBodyRequest(bearer: "x")
        let hdr = HTTPMitmConnection.rawHeaderSection(of: req)!
        let out = HTTPMitmConnection.spliceHeaderSection(
            of: req, newHeader: hdr + "\r\nX-Test: 1")
        let sep = out.range(of: Data("\r\n\r\n".utf8))!
        let outBody = out.subdata(in: sep.upperBound..<out.endIndex)
        #expect(Array(outBody) == [0x1f, 0x8b, 0x08, 0x00, 0xff, 0xfe])
        let outHeader = String(data: out.subdata(in: out.startIndex..<sep.lowerBound),
                               encoding: .isoLatin1)!
        #expect(outHeader.hasSuffix("X-Test: 1"))
    }
}
