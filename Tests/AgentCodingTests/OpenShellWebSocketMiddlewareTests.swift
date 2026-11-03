import Compression
import Foundation
import Testing
import SandboxEngine
@testable import bromure_ac

@Suite("OpenShell WebSocket text gating + middleware")
struct OpenShellWebSocketMiddlewareTests {
    /// A masked client frame.
    private func frame(opcode: UInt8, _ payload: String, fin: Bool = true) -> Data {
        let p = Array(payload.utf8)
        var f: [UInt8] = [(fin ? 0x80 : 0) | opcode]
        if p.count < 126 { f.append(0x80 | UInt8(p.count)) }
        else { f.append(0x80 | 126); f.append(UInt8(p.count >> 8)); f.append(UInt8(p.count & 0xFF)) }
        let mask: [UInt8] = [1, 2, 3, 4]
        f += mask
        f += p.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        return Data(f)
    }

    /// Feed `stream` in awkward 7-byte slices (headers and payloads straddle chunks).
    private func run(_ inspector: OpenShellWebSocket.ClientStream, _ stream: Data) -> (Data, Bool) {
        var forwarded = Data(), stopped = false
        var i = stream.startIndex
        while i < stream.endIndex, !stopped {
            let end = min(i + 7, stream.endIndex)
            let (fwd, stop) = inspector.feed(stream.subdata(in: i..<end))
            forwarded.append(fwd); stopped = stop; i = end
        }
        return (forwarded, stopped)
    }

    @Test("The inspector forwards binary / control frames, judges each text message, cuts at a denied one")
    func inspector() {
        let ping = frame(opcode: 0x9, "hi")
        let bin = frame(opcode: 0x2, String(repeating: "b", count: 300))
        let ok = frame(opcode: 0x1, "hello")
        // A fragmented text message with a ping between its fragments.
        let frag = frame(opcode: 0x1, "sec", fin: false) + frame(opcode: 0x9, "p") + frame(opcode: 0x0, "ret")
        let i = OpenShellWebSocket.ClientStream(compression: false) { $0 == "secret" ? .deny("nope") : .allow }
        let (forwarded, stopped) = run(i, ping + bin + ok + frag + frame(opcode: 0x2, "after"))
        #expect(stopped)
        #expect(i.closeReason == "nope")
        #expect(forwarded.starts(with: ping + bin + ok))
        #expect(forwarded.range(of: frame(opcode: 0x1, "sec", fin: false)) == nil)   // held, never forwarded
    }

    @Test("Protocol violations end the session: unmasked frames, fragmented control, stray continuation")
    func protocolViolations() {
        let unmasked = Data([0x81, 0x02]) + Data("hi".utf8)
        for bad in [unmasked, frame(opcode: 0x9, "x", fin: false), frame(opcode: 0x0, "x"), frame(opcode: 0x3, "x")] {
            let i = OpenShellWebSocket.ClientStream(compression: false) { _ in .allow }
            #expect(run(i, bad).1)
        }
    }

    @Test("A compressed text message is inflated before it's judged")
    func compressed() throws {
        let text = Data("please inflate me please inflate me".utf8)
        var raw = Data(count: 512)
        let n = raw.withUnsafeMutableBytes { dst in text.withUnsafeBytes { src in
            compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, 512,
                                      src.bindMemory(to: UInt8.self).baseAddress!, text.count, nil, COMPRESSION_ZLIB) } }
        let deflated = raw.prefix(n)
        // A masked text frame with RSV1 set.
        let mask: [UInt8] = [9, 8, 7, 6]
        var f = Data([0xC1, 0x80 | UInt8(deflated.count)]) + Data(mask)
        f += Data(deflated.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        var seen: String?
        let i = OpenShellWebSocket.ClientStream(compression: true) { seen = $0; return .allow }
        let (fwd, stop) = run(i, f)
        #expect(!stop)
        #expect(fwd == f)
        #expect(seen == String(data: text, encoding: .utf8))
        // Without negotiated compression, RSV1 is a protocol error.
        #expect(run(OpenShellWebSocket.ClientStream(compression: false) { _ in .allow }, f).1)
    }

    @Test("A middleware rewrite is re-judged and forwarded as a fresh uncompressed frame")
    func middlewareRewrite() {
        let msg = frame(opcode: 0x1, #"{"k":"sk-abcdefghijklmnop1234"}"#)
        var judged: [String] = []
        let i = OpenShellWebSocket.ClientStream(compression: false, decide: { judged.append($0); return .allow },
            transform: { t in
                guard let (d, _) = OpenShellPolicy.regexRedact(Data(t.utf8)) else { return .unchanged }
                return .replaced(String(decoding: d, as: UTF8.self))
            })
        let (fwd, stop) = run(i, msg)
        #expect(!stop)
        #expect(judged == [#"{"k":"sk-abcdefghijklmnop1234"}"#, #"{"k":"[REDACTED]"}"#])
        // Unmask what was forwarded.
        let b = [UInt8](fwd)
        #expect(b[0] == 0x81)                                   // FIN text, no RSV1
        let key = Array(b[2..<6])                               // short frame: 2-byte header + mask
        let text = String(decoding: b[6...].enumerated().map { $0.element ^ key[$0.offset & 3] }, as: UTF8.self)
        #expect(text == #"{"k":"[REDACTED]"}"#)
    }

    @Test("A failing middleware: fail-open forwards unchanged, fail-closed ends the session")
    func middlewareFailure() {
        let msg = frame(opcode: 0x1, "hello")
        let open = OpenShellWebSocket.ClientStream(compression: false, decide: { _ in .allow },
                                                   transform: { _ in .failed("boom", failOpen: true) })
        #expect(run(open, msg) == (msg, false))
        let closed = OpenShellWebSocket.ClientStream(compression: false, decide: { _ in .allow },
                                                     transform: { _ in .failed("boom", failOpen: false) })
        #expect(run(closed, msg).1)
        #expect(closed.closeReason == "middleware_failed: boom")
    }

    @Test("openshell/regex as a chain entry: capacity and UTF-8 are middleware failures")
    func regexMiddlewareOutcomes() {
        #expect(OpenShellPolicy.regexMiddleware(Data("no secrets".utf8)) == .unchanged)
        #expect(OpenShellPolicy.regexMiddleware(Data([0xff, 0xfe])) == .failed("openshell/regex requires UTF-8 request bodies"))
        #expect(OpenShellPolicy.regexMiddleware(Data(count: 256 * 1024 + 1)) == .failed("request_body_over_capacity"))
        if case .rewritten(let d, let n) = OpenShellPolicy.regexMiddleware(Data("a sk-abcdefghijklmnopq b sk-0123456789abcdefXY".utf8)) {
            #expect(n == 2)
            #expect(String(decoding: d, as: UTF8.self) == "a [REDACTED] b [REDACTED]")
        } else { Issue.record("expected a rewrite") }
    }

    @Test("permessage-deflate: only offered without client context takeover")
    func extensionOffer() throws {
        let r = OpenShellWebSocket.rewrittenExtensionOffer
        #expect(try r(["permessage-deflate; client_max_window_bits"]).get() == nil)
        #expect(try r(["permessage-deflate; client_no_context_takeover"]).get() == "permessage-deflate; client_no_context_takeover")
        #expect(try r(["x-foo, permessage-deflate; client_no_context_takeover; server_no_context_takeover"]).get()
                == "permessage-deflate; client_no_context_takeover; server_no_context_takeover")
        #expect(throws: OpenShellHTTP.Rejection.self) { try r(["permessage-deflate; ;"]).get() }
    }

    @Test("WebSocket presets and WEBSOCKET_TEXT rules decide each client text message")
    func textDecision() throws {
        let p = try OpenShellPolicy.parse("""
        version: 1
        network_policies:
          rt:
            endpoints:
              - { host: ro.example.com, port: 443, protocol: websocket, enforcement: enforce, access: read-only }
              - { host: rw.example.com, port: 443, protocol: websocket, enforcement: enforce, access: read-write }
              - host: rules.example.com
                port: 443
                protocol: websocket
                enforcement: enforce
                rules:
                  - allow: { method: GET, path: "/v1/**" }
                  - allow: { method: WEBSOCKET_TEXT, path: /v1/realtime }
          plain:
            endpoints: [{ host: rest.example.com, port: 443, protocol: rest, access: full }]
        """)
        let d = { (h: String, t: String) in p.websocketMessageDecision(host: h, port: 443, target: t, text: "{}") }
        #expect(p.evaluateRequest(host: "ro.example.com", port: 443, method: "GET", target: "/ws") == .allow)
        if case .allow = d("ro.example.com", "/ws") { Issue.record("read-only must not allow client text") }
        #expect(d("rw.example.com", "/ws") == .allow)
        #expect(d("rules.example.com", "/v1/realtime") == .allow)
        if case .allow = d("rules.example.com", "/v1/other") { Issue.record("text outside the WEBSOCKET_TEXT path must be blocked") }
        #expect(d("rest.example.com", "/x") == .allow)        // not a WebSocket route: not inspected
    }

    @Test("openshell/regex redacts sk- tokens but keeps Bromure placeholders")
    func regex() throws {
        let body = Data(#"{"a":"sk-abcdefghijklmnop1234","b":"sk-ant-api03-brm-KEEPKEEPKEEPKEEP"}"#.utf8)
        let (out, n) = try #require(OpenShellPolicy.regexRedact(body, keep: { $0.contains("-brm-") }))
        #expect(n == 1)
        let s = String(decoding: out, as: UTF8.self)
        #expect(s.contains("[REDACTED]"))
        #expect(s.contains("sk-ant-api03-brm-KEEPKEEPKEEPKEEP"))
        #expect(OpenShellPolicy.regexRedact(Data("nothing here".utf8)) == nil)
    }

    @Test("Middleware selection, validation, and body replacement")
    func middlewareConfig() throws {
        let p = try OpenShellPolicy.parse("""
        version: 1
        network_middlewares:
          redact:
            middleware: openshell/regex
            order: 10
            endpoints: { include: ["*.example.com"], exclude: [trusted.example.com] }
          guard:
            middleware: content-guard
            order: 20
            on_error: fail_open
            endpoints: { include: [api.example.com] }
        """)
        #expect(p.middlewares(for: "api.example.com").map(\.key) == ["redact", "guard"])
        #expect(p.middlewares(for: "trusted.example.com").isEmpty)
        #expect(p.warnings.contains { $0.contains("content-guard") })
        #expect(throws: OpenShellPolicy.ParseError.self) {
            try OpenShellPolicy.parse("""
            version: 1
            network_policies:
              s:
                endpoints: [{ host: smtp.example.com, port: 465, tls: skip }]
            network_middlewares:
              g:
                middleware: content-guard
                endpoints: { include: [smtp.example.com] }
            """)
        }
        let req = Data("POST /x HTTP/1.1\r\nHost: a\r\nContent-Length: 3\r\n\r\nabc".utf8)
        let out = String(decoding: HTTPMitmConnection.replacingBody(of: req, with: Data("hello".utf8)), as: UTF8.self)
        #expect(out.hasSuffix("Content-Length: 5\r\n\r\nhello"))
        #expect(!out.contains("Content-Length: 3"))
    }
}
