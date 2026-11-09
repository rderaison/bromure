import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing
@testable import ACLinux

/// PII protection on a model provider's WebSocket (macOS: WSContentGuard's
/// PII swap and WSTransformRelay.upstreamToClient's restore): a turn goes
/// up with stand-ins, the model's messages come back with the real values.
@Suite("PII protection: WebSocket turns")
struct WebSocketPIITests {
    static let email = PIIProxyTests.email

    /// A Codex turn carrying the address.
    static func turn(_ text: String = "mail \(email) the report") -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "type": "response.create", "model": "gpt-x",
            "input": [["role": "user", "content": [["type": "input_text", "text": text]]]],
        ])
    }

    /// Two text deltas carrying `text` split in the middle, as the server
    /// sends them (unmasked frames), then the block's end.
    static func deltas(_ text: String) -> [Data] {
        let mid = text.index(text.startIndex, offsetBy: text.count / 2)
        return [String(text[..<mid]), String(text[mid...])].map { piece in
            let o: [String: Any] = ["type": "content_block_delta", "index": 0,
                                    "delta": ["type": "text_delta", "text": piece]]
            return WSFrame.encode(opcode: WSFrame.text, payload: try! JSONSerialization.data(withJSONObject: o), masked: false)
        } + [WSFrame.encode(opcode: WSFrame.text, payload: Data(#"{"type":"content_block_stop","index":0}"#.utf8), masked: false)]
    }

    /// The deltas' text in what reached the client, its messages reassembled
    /// (one the restorer left unchanged goes through in its original
    /// fragments: whether it's changed depends on the key order its JSON is
    /// written back in, which varies from run to run).
    static func text(_ wire: Data) -> String {
        let r = WSFrameReader()
        r.feed(wire)
        var assembler = WSMessageAssembler()
        var out = ""
        while let f = r.next() {
            guard !f.isControl, case .complete(_, let payload, _) = assembler.add(f) else { continue }
            let o = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
            out += (o?["delta"] as? [String: Any])?["text"] as? String ?? ""
        }
        return out
    }

    /// PII on, prompt injection off: the guard exists, and a turn goes up
    /// with a stand-in the vault maps back.
    @Test func aTurnGoesUpWithAStandIn() async throws {
        let (proxy, pid, dir) = try PIIProxyTests.proxy()
        defer { PIIProxyTests.cleanup(dir, pid) }
        let g = try #require(WSPromptGuard.make(proxy: proxy, profileID: pid, host: "chatgpt.com", local: false))
        #expect(g.restoresReplies)
        guard case .forward(let out?) = await g.client(Self.turn()) else { Issue.record("not rewritten"); return }
        let sent = String(decoding: out, as: UTF8.self)
        #expect(!sent.contains(Self.email) && g.vault.restore(sent).contains(Self.email), "\(sent)")
        // Not a conversation: left alone.
        guard case .forward(nil) = await g.client(Data(#"{"type":"session.update"}"#.utf8)) else { Issue.record("changed"); return }
        // Neither engine on: no guard, the socket stays a pipe.
        proxy.setPIIPolicy(PIIPolicy(enabled: false), for: pid)
        #expect(WSPromptGuard.make(proxy: proxy, profileID: pid, host: "chatgpt.com", local: false) == nil)
    }

    /// The server side restores: a stand-in split across two deltas comes
    /// back whole; a fragmented message is held to its last fragment while a
    /// ping passes; what's held goes before the server's close.
    @Test func theServerSideRestores() throws {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let vault = PIIVault(secret: Data(repeating: 9, count: 32))
        let s = vault.learn(Self.email, label: .email).surrogate
        let server = WSServerSide(loop: loop, write: { _ in }, restorer: WSServerRestorer(vault: vault))
        let d = Self.deltas("to \(s) ok")
        var out = try loop.submit { server.feed(d[0] + d[1]) }.wait() ?? Data()
        // Another delta, fragmented (40 payload bytes, then the rest), a
        // ping between its fragments.
        let p = Data(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" again"}}"#.utf8)
        let a = Data([0x01, 40]) + p.prefix(40)                        // text, no FIN
        let ping = WSFrame.encode(opcode: 0x9, payload: Data(), masked: false)
        let b = Data([0x80, UInt8(p.count - 40)]) + p.dropFirst(40)    // FIN, continuation
        let mid = try loop.submit { server.feed(a + ping) }.wait() ?? Data()
        #expect(mid == ping, "only the ping while the message is in fragments")
        out += mid + (try loop.submit { server.feed(b + d[2]) }.wait() ?? Data())
        #expect(Self.text(out) == "to \(Self.email) ok again", "\(String(decoding: out, as: UTF8.self))")
        // A held tail goes before the close.
        let tail = Self.deltas("bye \(s)")[0...1].reduce(Data(), +)
        let close = WSFrame.encode(opcode: WSFrame.close, payload: Data([0x03, 0xE8]), masked: false)
        let end = try loop.submit { server.feed(tail + close) }.wait() ?? Data()
        #expect(Self.text(end) == "bye \(Self.email)" && end.suffix(close.count) == close)
    }

    /// PII protection turned on mid-socket (macOS: the guard always owns its
    /// restorer): messages before it pass as they are, the ones after are
    /// restored; the restorer is asked for at each message until there is one.
    @Test func protectionTurnedOnMidSocketRestoresFromThen() throws {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let vault = PIIVault(secret: Data(repeating: 9, count: 32))
        let s = vault.learn(Self.email, label: .email).surrogate
        let on = NIOLockedValueBox(false), asked = NIOLockedValueBox(0)
        let server = WSServerSide(loop: loop, write: { _ in }, makeRestorer: {
            asked.withLockedValue { $0 += 1 }
            return on.withLockedValue { $0 } ? WSServerRestorer(vault: vault) : nil
        })
        let before = try loop.submit { server.feed(Self.deltas("was \(s)").reduce(Data(), +)) }.wait() ?? Data()
        #expect(Self.text(before) == "was \(s)", "off: as it came")
        on.withLockedValue { $0 = true }
        let after = try loop.submit { server.feed(Self.deltas("to \(s) ok").reduce(Data(), +)) }.wait() ?? Data()
        #expect(Self.text(after) == "to \(Self.email) ok", "on: restored")
        let n = asked.withLockedValue { $0 }
        _ = try loop.submit { server.feed(Self.deltas("more").reduce(Data(), +)) }.wait()
        #expect(asked.withLockedValue { $0 } == n, "kept once made")
    }

    /// Restoring, a message too large to hold goes through fragment by
    /// fragment: an event waits for its last fragment, not just the next
    /// frame boundary.
    @Test func anEventWaitsForAMessageTooLargeToHold() throws {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let vault = PIIVault(secret: Data(repeating: 9, count: 32))
        _ = vault.learn(Self.email, label: .email)
        let written = NIOLockedValueBox<[Data]>([])
        let server = WSServerSide(loop: loop, write: { d in written.withLockedValue { $0.append(d) } },
                                  restorer: WSServerRestorer(vault: vault))
        var first = WSFrame.encode(opcode: WSFrame.text, payload: Data(repeating: 0x61, count: WSMessageAssembler.maxMessage + 1), masked: false)
        first[first.startIndex] &= 0x7F                                 // no FIN
        let last = Data([0x80, 1, 0x61])                                // FIN, continuation, "a"
        let event = WSFrame.encode(opcode: WSFrame.text, payload: Data("{}".utf8), masked: false)
        let a = try loop.submit { server.feed(first) }.wait() ?? Data()
        server.inject(event)
        try loop.submit {}.wait()
        #expect(a.count == first.count && written.withLockedValue { $0 }.isEmpty, "held while the message is open")
        let b = try loop.submit { server.feed(last) }.wait() ?? Data()
        #expect(b == last + event, "right after its last fragment")
    }

    /// The server's close inside a message too large to hold (a control
    /// frame may come between its fragments) doesn't release what's held
    /// into it.
    @Test func aCloseInsideAPassingMessageReleasesNothing() throws {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let vault = PIIVault(secret: Data(repeating: 9, count: 32))
        let s = vault.learn(Self.email, label: .email).surrogate
        let server = WSServerSide(loop: loop, write: { _ in }, restorer: WSServerRestorer(vault: vault))
        let d = Self.deltas("bye \(s)")
        _ = try loop.submit { server.feed(d[0] + d[1]) }.wait()            // the tail held
        var first = WSFrame.encode(opcode: WSFrame.text, payload: Data(repeating: 0x61, count: WSMessageAssembler.maxMessage + 1), masked: false)
        first[first.startIndex] &= 0x7F
        _ = try loop.submit { server.feed(first) }.wait()
        let close = WSFrame.encode(opcode: WSFrame.close, payload: Data([0x03, 0xE8]), masked: false)
        #expect(try loop.submit { server.feed(close) }.wait() == close)
    }

    /// A socket that ends without a close frame still gets what's held.
    @Test func aHeldTailGoesWhenTheSocketJustEnds() throws {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let vault = PIIVault(secret: Data(repeating: 9, count: 32))
        let s = vault.learn(Self.email, label: .email).surrogate
        let server = WSServerSide(loop: loop, write: { _ in }, restorer: WSServerRestorer(vault: vault))
        let d = Self.deltas("bye \(s)")
        let out = try loop.submit { server.feed(d[0] + d[1]) }.wait() ?? Data()
        #expect(!Self.text(out).contains(Self.email), "the tail is held")
        let tail = try loop.submit { server.finishAtClose() }.wait()
        #expect(Self.text(out + tail) == "bye \(Self.email)")
    }

    /// The guard keeps the upgrade's path, which a skipped scan and the PII
    /// log name (macOS: g.path; its engines are always pii + prompt_injection).
    @Test func theGuardKeepsTheUpgradesPath() throws {
        let (proxy, pid, dir) = try PIIProxyTests.proxy()
        defer { PIIProxyTests.cleanup(dir, pid) }
        let g = try #require(WSPromptGuard.make(proxy: proxy, profileID: pid, host: "chatgpt.com", path: "/backend-api/codex/responses", local: false))
        #expect(g.path == "/backend-api/codex/responses")
    }

    /// The whole path: the upstream sees only the stand-in and sends it back
    /// split across deltas; the client reads the real address.
    @Test func throughTheRequestReader() async throws {
        let (proxy, pid, dir) = try PIIProxyTests.proxy()
        defer { PIIProxyTests.cleanup(dir, pid) }
        let ip = try #require(Daemon.primaryIPv4(), "a host address (loopback is always refused)")
        let up = try WSUpstream(host: ip, reply: { payload in
            let text = String(decoding: payload, as: UTF8.self)
            let addr = text.range(of: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[a-z]+", options: .regularExpression)
                .map { String(text[$0]) } ?? "none"
            return WebSocketPIITests.deltas("to \(addr) ok")
        })
        defer { up.stop() }
        proxy.routeAllTo = (ip, up.port)
        let w = try await DaemonGlobalSuites.WebSocketGuardTests.Wire(proxy: proxy, pid: pid)
        defer { w.close() }
        w.send(DaemonGlobalSuites.WebSocketGuardTests.upgrade)
        #expect(String(decoding: w.read(), as: UTF8.self).hasPrefix("HTTP/1.1 101"))
        w.send(WSFrame.encode(opcode: WSFrame.text, payload: Self.turn(), masked: true))
        var got = Data()
        for _ in 0..<10 where !Self.text(got).hasSuffix(" ok") { got += w.read() }
        let upFrames = up.frames.withLockedValue { $0 }
        #expect(upFrames.count == 1 && !String(decoding: upFrames.first ?? Data(), as: UTF8.self).contains(Self.email))
        #expect(Self.text(got) == "to \(Self.email) ok", "\(String(decoding: got, as: UTF8.self))")
    }

    /// Traced, the server's side is recorded as the guest got it (macOS:
    /// onClientOut): the real address, never the stand-in the model sent.
    @Test @MainActor func theTraceHasWhatTheGuestGot() async throws {
        let (proxy, pid, dir) = try PIIProxyTests.proxy()
        defer { PIIProxyTests.cleanup(dir, pid) }
        proxy.setUpTraceStore(rootDir: URL(fileURLWithPath: dir + "/traces", isDirectory: true))
        proxy.setSessionTrace(TraceSession(sessionID: UUID(), level: .all), for: pid)
        let ip = try #require(Daemon.primaryIPv4(), "a host address (loopback is always refused)")
        let standIn = NIOLockedValueBox("")
        let up = try WSUpstream(host: ip, reply: { payload in
            let text = String(decoding: payload, as: UTF8.self)
            let addr = text.range(of: "[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[a-z]+", options: .regularExpression)
                .map { String(text[$0]) } ?? "none"
            standIn.withLockedValue { $0 = addr }
            // One whole message (not split), so the stand-in would show whole.
            let o: [String: Any] = ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "to \(addr) ok"]]
            return [WSFrame.encode(opcode: WSFrame.text, payload: try! JSONSerialization.data(withJSONObject: o), masked: false),
                    WSFrame.encode(opcode: WSFrame.text, payload: Data(#"{"type":"content_block_stop","index":0}"#.utf8), masked: false)]
        })
        defer { up.stop() }
        proxy.routeAllTo = (ip, up.port)
        let w = try await DaemonGlobalSuites.WebSocketGuardTests.Wire(proxy: proxy, pid: pid)
        w.send(DaemonGlobalSuites.WebSocketGuardTests.upgrade)
        #expect(String(decoding: w.read(), as: UTF8.self).hasPrefix("HTTP/1.1 101"))
        w.send(WSFrame.encode(opcode: WSFrame.text, payload: Self.turn(), masked: true))
        var got = Data()
        for _ in 0..<10 where !Self.text(got).hasSuffix(" ok") { got += w.read() }
        #expect(Self.text(got) == "to \(Self.email) ok")
        w.close()
        let sent = standIn.withLockedValue { $0 }
        #expect(!sent.isEmpty && sent != Self.email, "the model saw a stand-in: \(sent)")
        let store = try #require(proxy.traces.withLockedValue { $0 })
        for _ in 0..<200 where !store.recent.contains(where: { $0.statusCode == 101 }) { try await Task.sleep(for: .milliseconds(10)) }
        let r = try #require(store.recent.first { $0.statusCode == 101 })
        var body = ""
        for _ in 0..<100 {
            if let b = store.loadBody(for: r, kind: .response) { body = String(decoding: b, as: UTF8.self); break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(body.contains("to \(Self.email) ok"), "the reply as the guest got it: \(body)")
        #expect(!body.contains(sent), "not the stand-in the model sent: \(body)")
    }
}

