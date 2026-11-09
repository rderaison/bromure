import Foundation
import Testing
@testable import ACLinux

/// The WebSocket trace pieces on Linux (shared WebSocketTrace.swift, the
/// zlib WSInflater): frames reassembled into messages, permessage-deflate
/// inflated with and without context takeover, the transcript rendered.
@Suite("WebSocket traces")
struct WebSocketTraceTests {
    static func hex(_ s: String) -> Data {
        var d = Data(); var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return d
    }
    /// One server frame, FIN set, RSV1 (compressed) when asked.
    static func frame(_ opcode: UInt8, _ payload: Data, fin: Bool = true, rsv1: Bool = false) -> Data {
        var d = WSFrame.encode(opcode: opcode, payload: payload, masked: false)
        if !fin { d[d.startIndex] &= 0x7F }
        if rsv1 { d[d.startIndex] |= 0x40 }
        return d
    }

    // Two permessage-deflate messages from one sender (python zlib, raw,
    // sync-flushed, 00 00 FF FF stripped): the second only decodes with the
    // first's window (context takeover).
    static let event = #"{"type":"response.output_text.delta","delta":"hello world, hello again"}"#
    static let first = hex("aa562aa92c4855b2522a4a2d2ec8cf2b4ed5cb2f2d29282d892f49ad28d14b49cd294954d25182d0564a19a93939f90ae5f94539293a0a104e627a62669e522d00")
    static let second = hex("aaa692390000")

    @Test func contextTakeoverCarriesTheWindowAcrossMessages() {
        let z = WSInflater(noContextTakeover: false)
        #expect(z.inflate(Self.first).map { String(decoding: $0, as: UTF8.self) } == Self.event)
        #expect(z.inflate(Self.second).map { String(decoding: $0, as: UTF8.self) } == Self.event, "decoded with the first's window")
        // Without the window (no context takeover), the second can't decode.
        let reset = WSInflater(noContextTakeover: true)
        _ = reset.inflate(Self.first)
        #expect(reset.inflate(Self.second) == nil, "a corrupt message inflates to nil: the trace shows its raw bytes")
        #expect(WSInflater(noContextTakeover: true).inflate(Data([0xff, 0xff, 0xff])) == nil)
    }

    @Test func framesBecomeMessagesInflatedOnTheWay() {
        let c = WSTraceCollector(direction: .upstreamToClient, inflater: WSInflater(noContextTakeover: false))
        var wire = Self.frame(0x1, Self.first, rsv1: true)
        // A fragmented text message with a ping between its fragments.
        wire += Self.frame(0x1, Data("hel".utf8), fin: false)
        wire += Self.frame(0x9, Data("p".utf8))
        wire += Self.frame(0x0, Data("lo".utf8))
        wire += Self.frame(0x1, Self.second, rsv1: true)
        // Fed in odd-sized chunks, as a socket delivers them.
        var i = wire.startIndex
        while i < wire.endIndex { let j = wire.index(i, offsetBy: min(7, wire.distance(from: i, to: wire.endIndex))); c.feed(wire[i..<j]); i = j }
        let got = c.messages.map { ($0.kind, String(decoding: $0.payload, as: UTF8.self)) }
        #expect(got.map(\.0) == [.text, .ping, .text, .text])
        #expect(got.map(\.1) == [Self.event, "p", "hello", Self.event])
    }

    @Test func theTranscriptHasBothDirections() {
        let up = WSTraceCollector(direction: .clientToUpstream), down = WSTraceCollector(direction: .upstreamToClient)
        up.feed(WSFrame.encode(opcode: 0x1, payload: Data(#"{"type":"response.create"}"#.utf8), masked: true))
        down.feed(Self.frame(0x1, Data(Self.event.utf8)))
        let text = String(decoding: WSTranscriptRenderer.render(c2u: up, u2c: down), as: UTF8.self)
        #expect(text.contains("response.create") && text.contains("hello world"), "\(text)")
    }

    /// A traced socket's close: one record with the handshake and both
    /// directions' messages (inflated) as its response body; `activity`
    /// keeps the record and no body.
    @Test @MainActor func aClosedSocketIsOneTraceRecordWithItsTranscript() async throws {
        let d = try shortTempDir()
        let store = TraceStore(rootDir: URL(fileURLWithPath: d, isDirectory: true))
        let pid = UUID()
        let request = Data("GET /v1/responses HTTP/1.1\r\nHost: api.example.com\r\nUpgrade: websocket\r\nAuthorization: Bearer brm-fake\r\n\r\n".utf8)
        let handshake = Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nSec-WebSocket-Extensions: permessage-deflate\r\n\r\n".utf8)
        func session(_ level: TraceLevel) -> WSTraceSession {
            let ws = WSTraceSession(handshake: handshake, host: "api.example.com", path: "/v1/responses", profileID: pid,
                                    captureBody: level.capturesBodyForHost("api.example.com"))
            ws.client(WSFrame.encode(opcode: 0x1, payload: Data(#"{"type":"response.create"}"#.utf8), masked: true))
            ws.toGuest(Self.frame(0x1, Self.first, rsv1: true))
            ws.toGuest(Self.frame(0x1, Self.second, rsv1: true))
            return ws
        }
        for level in [TraceLevel.activity, .all] {
            let ws = session(level)
            let transcript: Data? = await withCheckedContinuation { c in ws.finish { t, _ in c.resume(returning: t) } }
            TraceEmitter.emitWebSocket(session: TraceSession(sessionID: UUID(), level: level), store: store, profileID: pid,
                                       host: "api.example.com", port: 443, preSwapRequest: request, handshakeResponse: handshake,
                                       transcript: transcript, clientBytes: request.count + ws.clientBytes,
                                       upstreamBytes: handshake.count + ws.upstreamBytes, statusCode: 101,
                                       swaps: [], leaks: [], latencyMs: 5)
        }
        for _ in 0..<100 where store.recent.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.recent.count == 2)
        let bare = try #require(store.recent.first { !$0.bodyStored })
        #expect(bare.method == "GET" && bare.path == "/v1/responses" && bare.statusCode == 101)
        let full = try #require(store.recent.first { $0.bodyStored })
        var body = ""
        for _ in 0..<100 {
            if let b = store.loadBody(for: full, kind: .response) { body = String(decoding: b, as: UTF8.self); break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(body.hasPrefix("HTTP/1.1 101") && body.contains("response.create"), "\(body)")
        #expect(body.components(separatedBy: "hello world, hello again").count == 3, "both server messages, inflated: \(body)")
        let req = String(decoding: store.loadBody(for: full, kind: .request) ?? Data(), as: UTF8.self)
        #expect(!req.contains("brm-fake"), "auth headers redacted: \(req)")
    }

    /// A socket faster than its trace: past the queue's cap the bytes are
    /// dropped and counted, and the transcript says where it has a gap.
    @Test func aTraceThatFallsBehindSaysSo() async {
        let ws = WSTraceSession(handshake: Data(), host: "api.example.com", path: "/", profileID: UUID(),
                                captureBody: true, maxQueued: 16)
        ws.toGuest(Self.frame(0x1, Data("small".utf8)))
        ws.toGuest(Self.frame(0x1, Data(repeating: 0x61, count: 64)))   // past the cap
        let t: Data? = await withCheckedContinuation { c in ws.finish { t, _ in c.resume(returning: t) } }
        let text = t.map { String(decoding: $0, as: UTF8.self) } ?? ""
        #expect(text.contains("small") && text.contains("66 bytes of this WebSocket not traced"), "\(text)")
    }
}

