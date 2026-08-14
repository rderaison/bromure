import Foundation
import Testing
@testable import bromure_ac

/// Unit coverage for the pure TraceRecord → TraceEvent conversion the
/// AC HTTP-log uploader does before shipping to session_events: URL
/// reconstruction, raw-HTTP header/body splitting, chunked decoding,
/// and secret-key body redaction. The network/batching path is not
/// exercised here (it needs a live enrolled endpoint).
@Suite struct BACTraceUploaderTests {

    // MARK: URL reconstruction

    @Test("https on :443 omits the port")
    func urlDefaultHTTPS() {
        #expect(BACTraceUploader.requestURL(host: "api.example.com", port: 443, path: "/v1/x")
                == "https://api.example.com/v1/x")
    }

    @Test("http on :80 omits the port")
    func urlDefaultHTTP() {
        #expect(BACTraceUploader.requestURL(host: "example.com", port: 80, path: "/")
                == "http://example.com/")
    }

    @Test("non-standard port is kept explicit (https)")
    func urlCustomPort() {
        #expect(BACTraceUploader.requestURL(host: "svc.internal", port: 8443, path: "/health")
                == "https://svc.internal:8443/health")
    }

    // MARK: Raw HTTP parsing

    @Test("splits request headers from body")
    func parseRequestHeadersAndBody() throws {
        let raw = Data("POST /login HTTP/1.1\r\nHost: x.test\r\nContent-Type: application/json\r\n\r\n{\"a\":1}".utf8)
        let p = try #require(BACTraceUploader.parseHTTPMessage(raw))
        #expect(p.headers["Host"] == "x.test")
        #expect(p.headers["Content-Type"] == "application/json")
        #expect(p.contentType == "application/json")
        #expect(p.body == "{\"a\":1}")
        // The request/status line must not leak into the header dict.
        #expect(p.headers["POST /login HTTP/1.1"] == nil)
    }

    @Test("response with no body yields nil body")
    func parseResponseNoBody() throws {
        let raw = Data("HTTP/1.1 204 No Content\r\nServer: nginx\r\n\r\n".utf8)
        let p = try #require(BACTraceUploader.parseHTTPMessage(raw))
        #expect(p.headers["Server"] == "nginx")
        #expect(p.body == nil)
        #expect(p.hadBodyBytes == false)
    }

    @Test("message without a header/body separator is treated as body")
    func parseUnframed() throws {
        let raw = Data("just some text".utf8)
        let p = try #require(BACTraceUploader.parseHTTPMessage(raw))
        #expect(p.headers.isEmpty)
        #expect(p.body == "just some text")
    }

    @Test("chunked response body is de-chunked")
    func parseChunked() throws {
        // "Wiki" + "pedia" across two chunks.
        let raw = Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n".utf8)
        let p = try #require(BACTraceUploader.parseHTTPMessage(raw))
        #expect(p.body == "Wikipedia")
    }

    @Test("dechunk decodes a single chunk")
    func dechunkSingle() throws {
        let chunked = Data("6\r\nabcdef\r\n0\r\n\r\n".utf8)
        let out = try #require(BACTraceUploader.dechunk(chunked))
        #expect(String(data: out, encoding: .utf8) == "abcdef")
    }

    // MARK: Secret redaction

    @Test("JSON body redacts secret-named keys, keeps the rest")
    func redactJSONBody() {
        let body = "{\"username\":\"alice\",\"password\":\"hunter2\",\"api_key\":\"sk-xyz\"}"
        let out = BACTraceUploader.redactBody(body, contentType: "application/json")
        #expect(out.contains("\"username\":\"alice\""))
        #expect(!out.contains("hunter2"))
        #expect(!out.contains("sk-xyz"))
        #expect(out.contains("***"))
    }

    @Test("urlencoded body redacts password field")
    func redactURLEncodedBody() {
        let body = "user=alice&password=hunter2&remember=1"
        let out = BACTraceUploader.redactBody(body, contentType: "application/x-www-form-urlencoded")
        #expect(out.contains("user=alice"))
        #expect(out.contains("remember=1"))
        #expect(!out.contains("hunter2"))
        #expect(out.contains("password=***"))
    }

    @Test("non-JSON/non-form body is left untouched")
    func redactPassthrough() {
        let body = "<html><body>password: hunter2</body></html>"
        let out = BACTraceUploader.redactBody(body, contentType: "text/html")
        #expect(out == body)
    }

    @Test("nested JSON secrets are redacted at depth")
    func redactNestedJSON() {
        let body = "{\"outer\":{\"token\":\"abc123\",\"ok\":true}}"
        let out = BACTraceUploader.redactBody(body, contentType: "application/json")
        #expect(!out.contains("abc123"))
        #expect(out.contains("true") || out.contains("\"ok\":true") || out.contains("\"ok\": true"))
    }
}
