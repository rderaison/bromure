import Foundation
import NIOCore
import NIOPosix
import SandboxEngine
import Testing
@testable import ACLinux

/// OpenShell's framing rules on the Linux proxy (macOS: readRequestSpooling's
/// strict mode, under an OpenShell policy): what the lenient framer takes, the
/// strict one refuses with a reason (a 400 before any policy step).
@Suite("Strict request framing")
struct StrictFramingTests {
    static func rejected(_ f: HTTPRequestFraming.Framing) -> String? {
        if case .rejected(let why) = f { return why }
        return nil
    }

    @Test func aBareLFHeadIsRefusedOnlyWhenStrict() {
        let raw = Data("GET / HTTP/1.1\r\nHost: a\nX: y\r\n\r\n".utf8)
        #expect(Self.rejected(HTTPRequestFraming.complete(raw, strict: true))?.contains("bare LF") == true)
        if case .complete = HTTPRequestFraming.complete(raw) {} else { Issue.record("lenient takes it") }
    }

    @Test func anOversizedHeadIsRefusedBeforeItEnds() {
        let raw = Data(("GET / HTTP/1.1\r\nHost: a\r\nX: " + String(repeating: "a", count: OpenShellHTTP.maxHeaderBytes)).utf8)
        #expect(Self.rejected(HTTPRequestFraming.complete(raw, strict: true))?.contains("headers exceed") == true)
        #expect(HTTPRequestFraming.complete(raw) == .needMore)
    }

    @Test func chunkLinesAndTrailersAreBounded() {
        let head = "POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n"
        let longLine = Data((head + String(repeating: "0", count: OpenShellHTTP.maxChunkLineBytes + 1)).utf8)
        #expect(Self.rejected(HTTPRequestFraming.complete(longLine, strict: true)) == "Chunk-size line exceeds limit")
        #expect(HTTPRequestFraming.complete(longLine) == .needMore)

        var trailers = head + "0\r\n"
        for k in 0...OpenShellHTTP.maxTrailerFields { trailers += "T\(k): v\r\n" }
        trailers += "\r\n"
        #expect(Self.rejected(HTTPRequestFraming.complete(Data(trailers.utf8), strict: true))?.contains("fields") == true)
        if case .complete = HTTPRequestFraming.complete(Data(trailers.utf8)) {} else { Issue.record("lenient takes it") }

        let bad = Data((head + "zz\r\nab\r\n0\r\n\r\n").utf8)
        #expect(Self.rejected(HTTPRequestFraming.complete(bad, strict: true))?.contains("Invalid chunk size token") == true)
        #expect(HTTPRequestFraming.complete(bad) == .invalid)
    }

    @Test func aWellFramedRequestIsTheSameEitherWay() {
        let raw = Data("POST /x HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n".utf8)
        let strict = HTTPRequestFraming.complete(raw, strict: true)
        #expect(strict == HTTPRequestFraming.complete(raw))
        guard case .complete(let req, let extra) = strict else { Issue.record("\(strict)"); return }
        let text = String(decoding: req, as: UTF8.self)
        #expect(text.contains("Content-Length: 3\r\n") && text.hasSuffix("\r\n\r\nabc") && extra.isEmpty, "\(text)")
        // Content-Length and Transfer-Encoding together: OpenShell refuses it.
        let both = Data("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n".utf8)
        #expect(Self.rejected(HTTPRequestFraming.complete(both, strict: true)) != nil)
    }

    /// Through the proxy: under an OpenShell policy a malformed request is a
    /// 400 naming why, and nothing goes upstream.
    @Test func theProxyAnswersA400UnderAnOpenShellPolicy() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
        let pid = UUID()
        let policy = EgressPolicy(openShell: try OpenShellPolicy.parse("""
        version: 1
        network_policies:
          any:
            endpoints: [{ host: ws.example, port: 80 }]
        """))
        proxy.setGuardrailsConfig(GuardrailsConfig(kubernetes: .off, kubeHosts: [], egressPolicy: policy), for: pid)
        let w = try await OpenShellWebSocketRouteTests.Wire(proxy: proxy, pid: pid)
        defer { w.close() }
        w.send(Data("GET / HTTP/1.1\r\nHost: ws.example\nX: y\r\n\r\n".utf8))
        let out = String(decoding: w.read(), as: UTF8.self)
        #expect(out.hasPrefix("HTTP/1.1 400") && out.contains("invalid_http_request") && out.contains("bare LF"), "\(out)")
    }
}
