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

    @Test("The gate forwards binary / control frames and cuts at the first text frame")
    func gate() {
        let g = WSClientTextGate()
        let ping = frame(opcode: 0x9, "hi")
        let bin = frame(opcode: 0x2, String(repeating: "b", count: 300))
        let text = frame(opcode: 0x1, "secret")
        var stream = ping + bin + text
        stream.append(frame(opcode: 0x2, "after"))
        // Feed in awkward 7-byte slices: headers and payloads straddle chunks.
        var forwarded = Data()
        var stopped = false
        var i = stream.startIndex
        while i < stream.endIndex, !stopped {
            let end = min(i + 7, stream.endIndex)
            let (fwd, stop) = g.filter(stream.subdata(in: i..<end))
            forwarded.append(fwd)
            stopped = stop
            i = end
        }
        #expect(stopped)
        #expect(forwarded.count <= ping.count + bin.count)
        #expect(forwarded.prefix(ping.count + bin.count - 7) == (ping + bin).prefix(ping.count + bin.count - 7))
        #expect(forwarded.range(of: Data("secret".utf8)) == nil)
    }

    @Test("WebSocket presets and WEBSOCKET_TEXT rules decide client text per upgrade path")
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
        #expect(p.evaluateRequest(host: "ro.example.com", port: 443, method: "GET", target: "/ws") == .allow)
        if case .allow? = p.websocketTextDecision(host: "ro.example.com", port: 443, target: "/ws") {
            Issue.record("read-only must not allow client text")
        }
        #expect(p.websocketTextDecision(host: "rw.example.com", port: 443, target: "/ws") == .allow)
        #expect(p.websocketTextDecision(host: "rules.example.com", port: 443, target: "/v1/realtime") == .allow)
        if case .allow? = p.websocketTextDecision(host: "rules.example.com", port: 443, target: "/v1/other") {
            Issue.record("text outside the WEBSOCKET_TEXT path must be blocked")
        }
        #expect(p.websocketTextDecision(host: "rest.example.com", port: 443, target: "/x") == nil)
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
