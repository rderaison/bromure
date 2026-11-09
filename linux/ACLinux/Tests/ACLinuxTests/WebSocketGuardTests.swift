import Foundation
import Glibc
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import SandboxEngine
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// Prompt injection on a model provider's WebSocket (macOS: WSContentGuard
    /// and WSTransformRelay): Codex's response.create turns are read like a
    /// Responses POST body; a poisoned one never goes upstream and the client
    /// gets the block event. Nested in the serialized parent with the other
    /// suites that set ConsentPrompt.chooseForTesting.
    @Suite("Prompt injection: WebSocket turns", .serialized)
    struct WebSocketGuardTests {
        static let poisoned = PromptInjectionEnforcementTests.poisoned
        static let benign = PromptInjectionEnforcementTests.benign

        /// A Codex turn, as its WebSocket carries it.
        static func turn(_ instructions: String) -> Data {
            try! JSONSerialization.data(withJSONObject: [
                "type": "response.create", "model": "gpt-x", "instructions": instructions,
                "input": [["role": "user", "content": [["type": "input_text", "text": "hello"]]]],
            ])
        }

        static func proxy(_ action: PromptInjectionPolicy.Action) throws -> (MitmProxy, UUID, String) {
            let (p, pid, dir) = try PromptInjectionEnforcementTests.proxy(action)
            return (p, pid, dir)
        }

        /// After a test: its directory, its blocks, the readiness seam
        /// (process-wide: nil for the next suite), the consent hook.
        static func cleanup(_ dir: String, _ pids: UUID...) {
            try? FileManager.default.removeItem(atPath: dir)
            for pid in pids { PromptInjectionRedactions.shared.reset(profileID: pid) }
            RequestReader.detectorReadinessForTesting.withLockedValue { $0 = nil }
            ConsentPrompt.chooseForTesting.withLockedValue { $0 = nil }
        }

        /// A filter on a real loop, its outputs collected.
        final class Rig: @unchecked Sendable {
            let loop = MultiThreadedEventLoopGroup.singleton.next()
            let up = NIOLockedValueBox<[Data]>([])
            let guest = NIOLockedValueBox<[Data]>([])
            let failed = NIOLockedValueBox(false)
            let reading = NIOLockedValueBox<[Bool]>([])
            var filter: WSClientFilter!
            init(_ g: WSPromptGuard) {
                let (up, guest, failed, reading) = (up, guest, failed, reading)
                filter = WSClientFilter(guard: g, loop: loop, toUpstream: { d in up.withLockedValue { $0.append(d) } },
                                        toGuest: { d in guest.withLockedValue { $0.append(d) } },
                                        setReading: { on in reading.withLockedValue { $0.append(on) } },
                                        fail: { failed.withLockedValue { $0 = true } })
            }
            func feed(_ d: Data) throws { try loop.submit { self.filter.feed(d) }.wait() }
            func until(_ cond: () -> Bool) async -> Bool {
                for _ in 0..<500 where !cond() { try? await Task.sleep(for: .milliseconds(10)) }
                return cond()
            }
        }

        static func payloads(_ frames: [Data]) -> [Data] {
            let r = WSFrameReader()
            frames.forEach(r.feed)
            var out: [Data] = []
            while let f = r.next() { out.append(f.payload) }
            return out
        }

        @Test func aPoisonedTurnIsRefusedAndABenignOneGoesUpAsItCame() async throws {
            let (proxy, pid, dir) = try Self.proxy(.block)
            defer { Self.cleanup(dir, pid) }
            let g = try #require(WSPromptGuard.make(proxy: proxy, profileID: pid, host: "chatgpt.com", local: false))
            let rig = Rig(g)
            let bad = WSFrame.encode(opcode: WSFrame.text, payload: Self.turn(Self.poisoned), masked: true)
            try rig.feed(bad)
            #expect(await rig.until { !rig.guest.withLockedValue { $0 }.isEmpty }, "the client heard back")
            let reply = try #require(Self.payloads(rig.guest.withLockedValue { $0 }).first)
            let obj = try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
            #expect(obj["type"] as? String == "response.failed", "\(String(decoding: reply, as: UTF8.self))")
            #expect(((obj["response"] as? [String: Any])?["error"] as? [String: Any])?["code"] as? String == "invalid_prompt")
            #expect(rig.up.withLockedValue { $0 }.isEmpty, "nothing went upstream")
            // A clean turn: up as the client framed it, byte for byte.
            let good = WSFrame.encode(opcode: WSFrame.text, payload: Self.turn(Self.benign), masked: true)
            try rig.feed(good)
            #expect(await rig.until { rig.up.withLockedValue { $0 }.count == 1 })
            #expect(rig.up.withLockedValue { $0 } == [good])
        }

        /// A message split over frames is read whole; ping goes on its own.
        @Test func aFragmentedTurnIsReassembledAndAPingPasses() async throws {
            let (proxy, pid, dir) = try Self.proxy(.block)
            defer { Self.cleanup(dir, pid) }
            let rig = Rig(try #require(WSPromptGuard.make(proxy: proxy, profileID: pid, host: "chatgpt.com", local: false)))
            let payload = Self.turn(Self.poisoned)
            let cut = payload.count / 2
            var first = WSFrame.encode(opcode: WSFrame.text, payload: payload.prefix(cut), masked: true)
            first[first.startIndex] &= 0x7F                       // FIN off: more follows
            var second = WSFrame.encode(opcode: 0x0, payload: payload.dropFirst(cut), masked: true)
            second[second.startIndex] = 0x80                       // FIN, continuation
            let ping = WSFrame.encode(opcode: 0x9, payload: Data("hi".utf8), masked: true)
            try rig.feed(first + ping + second)
            #expect(await rig.until { !rig.guest.withLockedValue { $0 }.isEmpty }, "refused whole")
            #expect(rig.up.withLockedValue { $0 } == [ping], "only the ping went up")
        }

        /// A reserved bit set (no extension is ever negotiated): the
        /// connection fails (RFC 6455 §5.2), a data frame or a control one,
        /// and nothing goes up unscanned (macOS does the same).
        @Test(arguments: [WSFrame.text, 0x9] as [UInt8])   // text, ping
        func aReservedBitEndsTheConnection(opcode: UInt8) async throws {
            let (proxy, pid, dir) = try Self.proxy(.block)
            defer { Self.cleanup(dir, pid) }
            let rig = Rig(try #require(WSPromptGuard.make(proxy: proxy, profileID: pid, host: "chatgpt.com", local: false)))
            var f = WSFrame.encode(opcode: opcode, payload: opcode == WSFrame.text ? Self.turn(Self.benign) : Data(), masked: true)
            f[f.startIndex] |= 0x40                                // RSV1
            try rig.feed(f + WSFrame.encode(opcode: WSFrame.text, payload: Self.turn(Self.benign), masked: true))
            try await Task.sleep(for: .milliseconds(200))
            #expect(rig.failed.withLockedValue { $0 })
            #expect(rig.up.withLockedValue { $0 }.isEmpty && rig.guest.withLockedValue { $0 }.isEmpty)
        }

        /// Once blocked, the same text resent with the next turn goes out as
        /// the placeholder: one new masked frame, the session goes on.
        @Test func aBlockedTextResentGoesOutRedactedInANewFrame() async throws {
            let (proxy, pid, dir) = try Self.proxy(.block)
            defer { Self.cleanup(dir, pid) }
            let rig = Rig(try #require(WSPromptGuard.make(proxy: proxy, profileID: pid, host: "chatgpt.com", local: false)))
            try rig.feed(WSFrame.encode(opcode: WSFrame.text, payload: Self.turn(Self.poisoned), masked: true))
            #expect(await rig.until { rig.guest.withLockedValue { $0 }.count == 1 }, "blocked first")
            let again = WSFrame.encode(opcode: WSFrame.text, payload: Self.turn(Self.poisoned), masked: true)
            try rig.feed(again)
            #expect(await rig.until { rig.up.withLockedValue { $0 }.count == 1 }, "then sent on")
            let sent = try #require(rig.up.withLockedValue { $0 }.first)
            let r = WSFrameReader(); r.feed(sent)
            let f = try #require(r.next())
            #expect(sent != again && sent[sent.startIndex + 1] & 0x80 != 0, "a new frame, masked")
            #expect(!String(decoding: f.payload, as: UTF8.self).contains("Ignore all previous instructions"), "redacted")
        }

        @Test(arguments: [0, 1])
        func askAsksTheClient(answer: Int) async throws {
            let (proxy, pid, dir) = try Self.proxy(.ask)
            defer { Self.cleanup(dir, pid) }
            ConsentPrompt.chooseForTesting.withLockedValue { $0 = { _ in answer } }   // 1: allow, 0: block
            let rig = Rig(try #require(WSPromptGuard.make(proxy: proxy, profileID: pid, host: "chatgpt.com", local: false)))
            let f = WSFrame.encode(opcode: WSFrame.text, payload: Self.turn(Self.poisoned), masked: true)
            try rig.feed(f)
            if answer == 1 {
                #expect(await rig.until { rig.up.withLockedValue { $0 } == [f] }, "allowed: up as sent")
            } else {
                #expect(await rig.until { !rig.guest.withLockedValue { $0 }.isEmpty } && rig.up.withLockedValue { $0 }.isEmpty)
            }
        }

        @Test func logModeSendsOnAndRecords() async throws {
            let (proxy, pid, dir) = try Self.proxy(.log)
            defer { Self.cleanup(dir) }
            let rig = Rig(try #require(WSPromptGuard.make(proxy: proxy, profileID: pid, host: "chatgpt.com", local: false)))
            let before = SupplyChainLog.shared.snapshot().last?.id ?? 0   // ids grow; the ring is capped
            // Content of its own: the scanner records a given file once.
            let f = WSFrame.encode(opcode: WSFrame.text, payload: Self.turn(Self.poisoned + "\n<!-- \(UUID()) -->\n"), masked: true)
            try rig.feed(f)
            #expect(await rig.until { rig.up.withLockedValue { $0 } == [f] })
            #expect(SupplyChainLog.shared.snapshot().contains { $0.id > before && $0.message.contains("[prompt-injection] rules FLAG") })
        }

        /// A close waits behind the message being scanned (here: an ask held
        /// open); everything held over the cap pauses the guest's reads.
        @Test func aCloseWaitsBehindAScanAndTooMuchHeldPausesReading() async throws {
            let (proxy, pid, dir) = try Self.proxy(.ask)
            defer { Self.cleanup(dir, pid) }
            let gate = AsyncStream<Void>.makeStream()
            ConsentPrompt.chooseForTesting.withLockedValue { $0 = { _ in
                var it = gate.stream.makeAsyncIterator(); _ = await it.next(); return 0
            } }
            let rig = Rig(try #require(WSPromptGuard.make(proxy: proxy, profileID: pid, host: "chatgpt.com", local: false)))
            try rig.feed(WSFrame.encode(opcode: WSFrame.text, payload: Self.turn(Self.poisoned), masked: true))
            // 5 MiB more behind the scan: past the cap, the guest isn't read.
            let big = Data(repeating: 0x61, count: 5 << 20)
            try rig.feed(WSFrame.encode(opcode: WSFrame.binary, payload: big, masked: true))
            #expect(rig.reading.withLockedValue { $0 }.last == false, "paused: \(rig.reading.withLockedValue { $0 })")
            let close = WSFrame.encode(opcode: WSFrame.close, payload: Data([0x03, 0xE8]), masked: true)
            try rig.feed(close)
            try await Task.sleep(for: .milliseconds(200))
            #expect(rig.up.withLockedValue { $0 }.isEmpty, "the close waits behind the scan")
            gate.continuation.finish()
            #expect(await rig.until { rig.up.withLockedValue { $0 }.count == 2 }, "refused; then the big one and the close")
            #expect(rig.up.withLockedValue { $0 }.last == close)
            #expect(rig.reading.withLockedValue { $0 }.last == true, "read again once they went")
        }

        @Test func aContinuationWithoutAStartEndsTheConnection() async throws {
            let (proxy, pid, dir) = try Self.proxy(.block)
            defer { Self.cleanup(dir) }
            let rig = Rig(try #require(WSPromptGuard.make(proxy: proxy, profileID: pid, host: "chatgpt.com", local: false)))
            var f = WSFrame.encode(opcode: 0x0, payload: Data("x".utf8), masked: true)
            f[f.startIndex] = 0x80                                 // FIN, continuation
            try rig.feed(f)
            #expect(rig.failed.withLockedValue { $0 } && rig.up.withLockedValue { $0 }.isEmpty)
        }

        /// A message past what's held for a scan goes up unscanned, recorded.
        @Test func aMessageTooLargeToScanIsRecorded() async throws {
            let (proxy, pid, dir) = try Self.proxy(.block)
            defer { Self.cleanup(dir) }
            let rig = Rig(try #require(WSPromptGuard.make(proxy: proxy, profileID: pid, host: "chatgpt.com", local: false)))
            let before = SupplyChainLog.shared.snapshot().last?.id ?? 0   // ids grow; the ring is capped
            let huge = Data(repeating: 0x20, count: WSMessageAssembler.maxMessage + 1)
            try rig.feed(WSFrame.encode(opcode: WSFrame.text, payload: huge, masked: true))
            #expect(await rig.until { rig.up.withLockedValue { $0 }.count == 1 }, "sent on")
            #expect(SupplyChainLog.shared.snapshot().contains { $0.id > before && $0.message.contains("WebSocket message too large to scan") })
        }

        /// 16- and 64-bit payload lengths read right (a clean turn padded).
        @Test(arguments: [300, 70_000])
        func longerLengthsAreRead(size: Int) async throws {
            let (proxy, pid, dir) = try Self.proxy(.block)
            defer { Self.cleanup(dir) }
            let rig = Rig(try #require(WSPromptGuard.make(proxy: proxy, profileID: pid, host: "chatgpt.com", local: false)))
            let pad = String(repeating: "x", count: size)
            let bad = WSFrame.encode(opcode: WSFrame.text, payload: Self.turn(Self.poisoned + pad), masked: true)
            try rig.feed(bad)
            #expect(await rig.until { !rig.guest.withLockedValue { $0 }.isEmpty } && rig.up.withLockedValue { $0 }.isEmpty, "read whole, refused")
            let good = WSFrame.encode(opcode: WSFrame.text, payload: Self.turn(Self.benign + pad), masked: true)
            try rig.feed(good)
            #expect(await rig.until { rig.up.withLockedValue { $0 } == [good] })
        }

        /// The server side: its bytes go on as they come, and a block event
        /// never lands inside a server frame or a fragmented message; it goes
        /// right after it.
        @Test func aBlockEventWaitsForTheServersFrameToEnd() throws {
            let loop = MultiThreadedEventLoopGroup.singleton.next()
            let written = NIOLockedValueBox<[Data]>([])
            let server = WSServerSide(loop: loop, write: { d in written.withLockedValue { $0.append(d) } })
            let frame = WSFrame.encode(opcode: WSFrame.text, payload: Data(repeating: 0x62, count: 1000), masked: false)
            let event = WSFrame.encode(opcode: WSFrame.text, payload: Data("{\"type\":\"response.failed\"}".utf8), masked: false)
            let first = try loop.submit { server.feed(frame.prefix(500)) }.wait()
            server.inject(event)
            try loop.submit {}.wait()                                  // its hop has run
            #expect(first == frame.prefix(500) && written.withLockedValue { $0 }.isEmpty, "relayed; the event held mid-frame")
            let rest = try loop.submit { server.feed(Data(frame.dropFirst(500))) }.wait()
            #expect(rest == Data(frame.dropFirst(500)) + event, "after the frame")
            // Between messages: written at once.
            server.inject(event)
            try loop.submit {}.wait()
            #expect(written.withLockedValue { $0 } == [event])
        }

        /// A fragmented server message goes on fragment by fragment (a ping
        /// between them too); the event waits for its last fragment.
        @Test func aBlockEventWaitsForAFragmentedServerMessage() throws {
            let loop = MultiThreadedEventLoopGroup.singleton.next()
            let server = WSServerSide(loop: loop, write: { _ in })
            var start = WSFrame.encode(opcode: WSFrame.text, payload: Data("{\"a\":".utf8), masked: false)
            start[start.startIndex] &= 0x7F                            // no FIN
            let ping = WSFrame.encode(opcode: 0x9, payload: Data(), masked: false)
            var end = WSFrame.encode(opcode: 0x0, payload: Data("1}".utf8), masked: false)
            end[end.startIndex] = 0x80                                 // FIN, continuation
            let event = WSFrame.encode(opcode: WSFrame.text, payload: Data("{}".utf8), masked: false)
            #expect(try loop.submit { server.feed(start + ping) }.wait() == start + ping)
            server.inject(event)
            try loop.submit {}.wait()
            #expect(try loop.submit { server.feed(end) }.wait() == end + event)
            // A continuation with no message under way: broken.
            #expect(try loop.submit { server.feed(end) }.wait() == nil)
        }

        /// A server frame past 64 MiB isn't refused: it's never held.
        @Test func aLargeServerFrameGoesOn() throws {
            let loop = MultiThreadedEventLoopGroup.singleton.next()
            let server = WSServerSide(loop: loop, write: { _ in })
            let length: UInt64 = 80 << 20
            var head = Data([0x82, 127])
            for k in (0..<8).reversed() { head.append(UInt8(truncatingIfNeeded: length >> (8 * UInt64(k)))) }
            let chunk = Data(repeating: 0x63, count: 1 << 20)
            #expect(try loop.submit { server.feed(head + chunk) }.wait() == head + chunk)
            #expect(try loop.submit { server.feed(chunk) }.wait() == chunk)
        }

        /// The upgrade declines permessage-deflate when the socket is read;
        /// left as it came when prompt injection is off.
        @Test func theUpgradeDeclinesCompressionOnlyWhenTheSocketIsRead() async throws {
            let upgrade = Data("GET /backend-api/codex/responses HTTP/1.1\r\nHost: chatgpt.com\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Extensions: permessage-deflate; client_max_window_bits\r\n\r\n".utf8)
            for on in [true, false] {
                let (proxy, pid, dir) = try Self.proxy(.block)
                defer { Self.cleanup(dir) }
                if !on { proxy.clearPromptInjectionPolicy(for: pid) }
                var trace: RequestReader.Trace?
                let plan = await RequestReader.rewrite(upgrade, proxy: proxy, profileID: pid, host: "chatgpt.com", port: 443,
                                                       tls: true, session: proxy.strictSession(of: pid), trace: &trace)
                guard case .forward(let out, _, _, let isUpgrade, _, let ws, _, _, _, _, _, _, _) = plan else { Issue.record("\(plan)"); continue }
                let s = String(decoding: out, as: UTF8.self).lowercased()
                #expect(isUpgrade && (ws != nil) == on)
                #expect(s.contains("sec-websocket-extensions") != on, "on: \(on): \(s)")
            }
        }

        /// A guest socket on a real RequestReader, its upstream the test route
        /// (the name pinned, never looked up or dialed).
        final class Wire {
            let guest: Int32
            let channel: Channel
            init(proxy: MitmProxy, pid: UUID) async throws {
                var sv: [Int32] = [-1, -1]
                guard socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &sv) == 0 else { throw POSIXError(.EIO) }
                guest = sv[0]
                var tv = timeval(tv_sec: 5, tv_usec: 0)
                setsockopt(guest, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                let pinned = [OpenShellPolicy.IPAddress("203.0.113.9")!]
                channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                    .channelInitializer { $0.pipeline.addHandler(RequestReader(proxy: proxy, profileID: pid, host: "chatgpt.com",
                                                                              port: 80, tls: false, pinned: pinned)) }
                    .withConnectedSocket(sv[1]).get()
            }
            func send(_ d: Data) { _ = d.withUnsafeBytes { Glibc.send(guest, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) } }
            func read() -> Data {
                var buf = [UInt8](repeating: 0, count: 65536)
                let n = recv(guest, &buf, buf.count, 0)
                return n > 0 ? Data(buf[0..<n]) : Data()
            }
            func close() { channel.close(promise: nil); Glibc.close(guest) }
        }

        static let upgrade = Data("GET /backend-api/codex/responses HTTP/1.1\r\nHost: chatgpt.com\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Extensions: permessage-deflate\r\n\r\n".utf8)

        /// The whole path: the 101 from a local upstream, then a poisoned turn
        /// refused and a clean one relayed.
        @Test func throughTheRequestReader() async throws {
            let (proxy, pid, dir) = try Self.proxy(.block)
            defer { Self.cleanup(dir, pid) }
            let ip = try #require(Daemon.primaryIPv4(), "a host address (loopback is always refused)")
            let up = try WSUpstream(host: ip)
            defer { up.stop() }
            proxy.routeAllTo = (ip, up.port)
            let w = try await Wire(proxy: proxy, pid: pid)
            defer { w.close() }
            w.send(Self.upgrade)
            let head = String(decoding: w.read(), as: UTF8.self)
            #expect(head.hasPrefix("HTTP/1.1 101"), "\(head)")
            #expect(!up.head.withLockedValue { $0 }.lowercased().contains("sec-websocket-extensions"), "declined upstream")
            w.send(WSFrame.encode(opcode: WSFrame.text, payload: Self.turn(Self.poisoned), masked: true))
            let reply = Self.payloads([w.read()]).first.map { String(decoding: $0, as: UTF8.self) } ?? ""
            #expect(reply.contains("response.failed") && reply.contains("invalid_prompt"), "\(reply)")
            let good = WSFrame.encode(opcode: WSFrame.text, payload: Self.turn(Self.benign), masked: true)
            w.send(good)
            for _ in 0..<300 where up.frames.withLockedValue({ $0 }).isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            #expect(up.frames.withLockedValue { $0 } == [good], "only the clean turn reached the upstream, as sent")
        }

        /// A turn sent with the upgrade, before the 101: held, then scanned.
        @Test func aTurnPipelinedBeforeThe101IsScanned() async throws {
            let (proxy, pid, dir) = try Self.proxy(.block)
            defer { Self.cleanup(dir, pid) }
            let ip = try #require(Daemon.primaryIPv4())
            let up = try WSUpstream(host: ip)
            defer { up.stop() }
            proxy.routeAllTo = (ip, up.port)
            let w = try await Wire(proxy: proxy, pid: pid)
            defer { w.close() }
            w.send(Self.upgrade + WSFrame.encode(opcode: WSFrame.text, payload: Self.turn(Self.poisoned), masked: true))
            var got = Data()
            for _ in 0..<5 where !String(decoding: got, as: UTF8.self).contains("invalid_prompt") { got += w.read() }
            #expect(String(decoding: got, as: UTF8.self).contains("invalid_prompt"), "refused: \(String(decoding: got.prefix(300), as: UTF8.self))")
            try await Task.sleep(for: .milliseconds(200))
            #expect(up.frames.withLockedValue { $0 }.isEmpty, "nothing went up")
        }

        /// The guest is read again only when both the upstream and the filter
        /// want it: a scan held open (an ask) with more than the cap behind
        /// it, then the upstream filling (a large message gone up) and
        /// draining — the drain alone doesn't resume the guest.
        @Test func anUpstreamDrainDoesntResumeAGuestTheFilterHolds() async throws {
            let (proxy, pid, dir) = try Self.proxy(.ask)
            defer { Self.cleanup(dir, pid) }
            let gate = AsyncStream<Void>.makeStream()
            ConsentPrompt.chooseForTesting.withLockedValue { $0 = { _ in
                var it = gate.stream.makeAsyncIterator(); _ = await it.next(); return 0
            } }
            defer { gate.continuation.finish() }
            let ip = try #require(Daemon.primaryIPv4())
            let up = try WSUpstream(host: ip, hold: true)
            defer { up.stop() }
            proxy.routeAllTo = (ip, up.port)
            let w = try await Wire(proxy: proxy, pid: pid)
            defer { w.close() }
            w.send(Self.upgrade)
            #expect(String(decoding: w.read(), as: UTF8.self).hasPrefix("HTTP/1.1 101"))
            // An ask held open, 5 MiB behind it: the filter stops the reads.
            w.send(WSFrame.encode(opcode: WSFrame.text, payload: Self.turn(Self.poisoned), masked: true))
            w.send(WSFrame.encode(opcode: WSFrame.binary, payload: Data(repeating: 0x61, count: 5 << 20), masked: true))
            let reader = try await w.channel.pipeline.handler(type: RequestReader.self).get()
            // The upstream fills (a large message gone up; it isn't reading)...
            let big = WSFrame.encode(opcode: WSFrame.binary, payload: Data(repeating: 0x62, count: 8 << 20), masked: true)
            let unwritable = try await w.channel.eventLoop.submit { () -> Bool in
                guard let u = reader.upstreamForTesting else { return false }
                u.writeAndFlush(u.allocator.buffer(bytes: big), promise: nil)
                return !u.isWritable
            }.get()
            #expect(unwritable, "the upstream is full")
            // ...then drains, and turns writable.
            up.resume()
            for _ in 0..<500 {
                if try await w.channel.eventLoop.submit({ reader.upstreamForTesting?.isWritable == true }).get() { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(try await w.channel.eventLoop.submit { reader.upstreamForTesting?.isWritable == true }.get(), "drained")
            try await Task.sleep(for: .milliseconds(100))
            // The guest stays paused: past its socket buffer, it can't send more.
            let flood = WSFrame.encode(opcode: WSFrame.binary, payload: Data(repeating: 0x63, count: 40 << 20), masked: true)
            let flags = fcntl(w.guest, F_GETFL)
            _ = fcntl(w.guest, F_SETFL, flags | O_NONBLOCK)
            var sent = 0
            let deadline = Date().addingTimeInterval(2)
            while sent < flood.count, Date() < deadline {
                let n = flood.withUnsafeBytes { Glibc.send(w.guest, $0.baseAddress! + sent, min(65536, flood.count - sent), Int32(MSG_NOSIGNAL)) }
                if n > 0 { sent += n } else { try await Task.sleep(for: .milliseconds(5)) }
            }
            _ = fcntl(w.guest, F_SETFL, flags)
            #expect(sent < 4 << 20, "the guest was read past the cap: \(sent) bytes taken")
        }

        /// An upstream that answers with an extension anyway: its frames can't
        /// be read, so the socket is an opaque pipe, and that's recorded.
        @Test func a101WithAnExtensionFallsBackToThePipeAndSaysSo() async throws {
            let (proxy, pid, dir) = try Self.proxy(.block)
            defer { Self.cleanup(dir, pid) }
            let ip = try #require(Daemon.primaryIPv4())
            let up = try WSUpstream(host: ip, extensionHeader: "permessage-deflate")
            defer { up.stop() }
            proxy.routeAllTo = (ip, up.port)
            let before = SupplyChainLog.shared.snapshot().last?.id ?? 0   // ids grow; the ring is capped
            let w = try await Wire(proxy: proxy, pid: pid)
            defer { w.close() }
            w.send(Self.upgrade)
            #expect(String(decoding: w.read(), as: UTF8.self).hasPrefix("HTTP/1.1 101"))
            let f = WSFrame.encode(opcode: WSFrame.text, payload: Self.turn(Self.poisoned), masked: true)
            w.send(f)
            for _ in 0..<300 where up.frames.withLockedValue({ $0 }).isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            #expect(up.frames.withLockedValue { $0 } == [f], "sent on unread")
            #expect(SupplyChainLog.shared.snapshot().contains { $0.id > before && $0.message.contains("WebSocket extension permessage-deflate in use") })
        }
    }
}

/// A WebSocket upstream: answers the upgrade with a 101 (no extensions),
/// then keeps what the client sends. `hold`: after the 101 it doesn't read
/// (a small receive buffer: the proxy's side fills fast) until `resume()`.
final class WSUpstream: @unchecked Sendable {
    let head = NIOLockedValueBox("")
    let frames = NIOLockedValueBox<[Data]>([])
    let child = NIOLockedValueBox<Channel?>(nil)
    let channel: Channel
    var port: Int { channel.localAddress!.port! }

    /// `reply`: the frames sent back for each client message's payload.
    init(host: String, extensionHeader: String? = nil, hold: Bool = false,
         reply: (@Sendable (Data) -> [Data])? = nil) throws {
        let (head, frames, child) = (head, frames, child)
        channel = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_rcvbuf), value: hold ? 4096 : 131072)
            .childChannelInitializer { ch in
                child.withLockedValue { $0 = ch }
                return ch.pipeline.addHandler(Handler(head, frames, ext: extensionHeader, hold: hold, reply: reply))
            }
            .bind(host: host, port: 0).wait()
    }
    func resume() { _ = child.withLockedValue { $0 }?.setOption(ChannelOptions.autoRead, value: true) }
    func stop() { channel.close(promise: nil) }

    final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        let head: NIOLockedValueBox<String>
        let frames: NIOLockedValueBox<[Data]>
        var acc = Data()
        var switched = false
        let reader = WSFrameReader()
        let ext: String?
        let hold: Bool
        let reply: (@Sendable (Data) -> [Data])?
        init(_ h: NIOLockedValueBox<String>, _ f: NIOLockedValueBox<[Data]>, ext: String?, hold: Bool,
             reply: (@Sendable (Data) -> [Data])?) {
            head = h; frames = f; self.ext = ext; self.hold = hold; self.reply = reply
        }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let b = unwrapInboundIn(data)
            if switched {
                reader.feed(Data(b.readableBytesView))
                while let f = reader.next() {
                    frames.withLockedValue { $0.append(f.raw) }
                    for d in reply?(f.payload) ?? [] {
                        context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(bytes: d)), promise: nil)
                    }
                }
                return
            }
            acc.append(contentsOf: b.readableBytesView)
            guard let end = acc.range(of: Data("\r\n\r\n".utf8)) else { return }
            head.withLockedValue { $0 = String(decoding: acc[acc.startIndex..<end.lowerBound], as: UTF8.self) }
            switched = true
            let rest = acc[end.upperBound...]
            if !rest.isEmpty { reader.feed(Data(rest)) }
            context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(string:
                "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n"
                + (ext.map { "Sec-WebSocket-Extensions: \($0)\r\n" } ?? "") + "\r\n")), promise: nil)
            if hold { _ = context.channel.setOption(ChannelOptions.autoRead, value: false) }
        }
    }
}
