import Foundation
import NIOConcurrencyHelpers
import NIOCore
import SandboxEngine

/// Prompt injection and PII protection on a model provider's WebSocket
/// (macOS: WSContentGuard, without Squelch, which Linux doesn't have yet).
/// Codex 0.157+ sends every turn as a `response.create` message on one
/// socket: each client message is read like a Responses POST body and
/// scanned as the HTTP path scans one. Log mode records; block refuses; ask
/// asks the client. A refused message never goes upstream: the client gets
/// the block event instead (`response.failed` / `invalid_prompt` for a
/// Responses turn). Then its personal data is swapped for stand-ins; the
/// server side (WSServerSide) puts the real values back.
// partial: no Squelch on Linux yet
// @port-skip linux-only: WSContentGuard on the Linux proxy (its providers are the proxy's own)
final class WSPromptGuard: @unchecked Sendable {
    enum Verdict {
        /// Forward: the rewritten payload, or nil for "unchanged".
        case forward(Data?)
        /// Drop the message; send `reply` (a server event) to the client.
        case block(reply: Data)
    }

    let proxy: MitmProxy
    let profileID: UUID
    let host: String
    private let vaultBox = NIOLockedValueBox<PIIVault?>(nil)

    // @port-skip linux-only: see WSPromptGuard
    init(proxy: MitmProxy, profileID: UUID, host: String) {
        self.proxy = proxy
        self.profileID = profileID
        self.host = host
    }

    /// The workspace's PII vault, opened at its first use: a socket PII
    /// protection never touches doesn't create the workspace's key.
    // @port-skip linux-only: see WSPromptGuard
    var vault: PIIVault {
        vaultBox.withLockedValue { v in
            if let v { return v }
            let opened = PIIVault.forProfile(profileID)
            v = opened
            return opened
        }
    }

    /// The guard for an upgrade, or nil when the socket stays an opaque
    /// (compressed) pipe: not a model provider's (WSContentGuard
    /// .isModelSocket), or neither prompt injection nor PII protection on.
    // @port-skip linux-only: WSContentGuard.make, without Squelch
    static func make(proxy: MitmProxy, profileID: UUID, host: String, local: Bool) -> WSPromptGuard? {
        let h = host.lowercased()
        // The local-inference sentinel only when its engine is off this
        // machine (a custom server elsewhere): the conversation leaves it then.
        guard TraceLevel.isAIHost(h), !h.contains("huggingface.co"),
              !local || PIIEngineScope.offMacEngineHost(profileID: profileID) != nil
        else { return nil }
        let piOn = proxy.promptInjectionPolicy(for: profileID)?.isActive ?? false
        let piiOn = proxy.piiPolicy(for: profileID)?.isActive ?? false
        guard piOn || piiOn else { return nil }
        return WSPromptGuard(proxy: proxy, profileID: profileID, host: host)
    }

    /// Whether the model's messages are read to restore PII (macOS reads
    /// them whenever its guard exists, and restores once the vault holds
    /// anything): PII protection on when the socket opened.
    // @port-skip linux-only: see WSPromptGuard
    var restoresReplies: Bool { proxy.piiPolicy(for: profileID)?.isActive ?? false }

    /// The engines on, as a skipped scan records them.
    // @port-skip linux-only: see WSPromptGuard
    var engines: [String] {
        [proxy.promptInjectionPolicy(for: profileID)?.isActive == true ? "prompt_injection" : nil,
         restoresReplies ? "pii" : nil].compactMap { $0 }
    }

    // @port-skip linux-only: WSContentGuard.client, without Squelch
    func client(_ payload: Data) async -> Verdict {
        guard payload.first(where: { !WSMessages.isSpace($0) }) == UInt8(ascii: "{") else { return .forward(nil) }
        let pi = proxy.promptInjectionPolicy(for: profileID).flatMap { $0.isActive ? $0 : nil }
        let pii = proxy.piiPolicy(for: profileID).flatMap { $0.isActive ? $0 : nil }
        guard pi != nil || pii != nil else { return .forward(nil) }
        let type = WSMessages.messageType(payload)
        var payload = payload
        var redacted = false
        // Tool output the user already blocked goes out as a placeholder (the
        // conversation is resent every turn), so the session goes on.
        if let pi, pi.onDetection != .log,
           let r = PromptInjectionRedactions.shared.redact(payload, profileID: profileID) {
            payload = r.body
            redacted = true
            ProxyPolicy.recordInjectionRedacted(count: r.count, host: host, profileID: profileID)
        }
        // Prompt injection first, over what the agent sent (as the HTTP
        // path). Read like a Responses POST body; a dummy head keeps the
        // parser's HTTP-framing strip off the JSON.
        if let pi, let conv = ConversationParser.parse(
            host: host, requestBody: Data("WS\r\n\r\n".utf8) + WSMessages.conversationBody(payload, type: type),
            responseBody: nil) {
            if pi.onDetection == .log {
                proxy.logPromptInjection(in: conv, host: host, profileID: profileID)
            } else if let f = await ProxyPolicy.detectPromptInjection(in: conv, policy: pi) {
                if pi.onDetection == .block {
                    ProxyPolicy.recordPromptInjection(f, outcome: "blocked", host: host, profileID: profileID)
                    PromptInjectionRedactions.shared.block(f, profileID: profileID)
                    return .block(reply: WSMessages.blockEvent(f, requestType: type))
                }
                let allow = await proxy.promptInjectionBroker.consent(profileID: profileID, detectorName: f.detector,
                                                                      source: f.source, flaggedText: f.preview)
                ProxyPolicy.recordPromptInjection(f, outcome: allow ? "allowed" : "blocked", host: host, profileID: profileID)
                if !allow {
                    PromptInjectionRedactions.shared.block(f, profileID: profileID)
                    return .block(reply: WSMessages.blockEvent(f, requestType: type))
                }
            }
        }
        guard let pii, WSMessages.carriesConversation(payload) else { return .forward(redacted ? payload : nil) }
        let t = Date()
        let outcome = await PIIRewriter.rewriteRequest(payload, policy: pii, vault: vault)
        let ms = Date().timeIntervalSince(t) * 1000
        if outcome.total > 0 || outcome.partial {
            ProxyPolicy.recordPIISwaps(outcome, host: host, profileID: profileID, ms: ms)
        }
        if outcome.total > 0 || ms > 250 || outcome.partial {
            FileHandle.standardError.write(Data(String(
                format: "[pii] %@ (WebSocket %@): %d new value(s) swapped, %d → %d bytes, %.0f ms%@\n",
                host, type ?? "message", outcome.total, payload.count, outcome.body.count, ms,
                outcome.partial ? " (model budget spent: rest by pattern rules)" : "").utf8))
        }
        return .forward(outcome.body == payload && !redacted ? nil : outcome.body)
    }
}

/// The client → model direction of a guarded WebSocket (macOS:
/// WSTransformRelay.clientToUpstream), on the guest channel's event loop:
/// frames parsed, fragmented messages reassembled, each data message scanned
/// in order off the loop while control frames (ping, pong) keep flowing. An
/// unchanged message goes up as its original frames; a rewritten one as one
/// new masked frame; a refused one not at all (the guest gets the block
/// event, through WSServerSide, at a message boundary). A close waits behind
/// the messages before it. A message too large to hold goes up unscanned,
/// recorded; a frame with an extension bit set (none is ever negotiated:
/// RFC 6455 §5.2) or a broken stream ends the connection.
// @port-skip linux-only: WSTransformRelay.clientToUpstream on NIO
final class WSClientFilter {
    private enum Item {
        case message(opcode: UInt8, payload: Data, raw: Data)
        case raw(Data)
        // @port-skip linux-only: see WSClientFilter
        var size: Int {
            switch self {
            case .message(_, _, let raw), .raw(let raw): return raw.count
            }
        }
    }

    /// Past this many bytes held (queued, or being scanned), the guest isn't
    /// read until they've gone: a scan or an ask held up never grows memory
    /// without bound. Below it, ping and pong keep flowing.
    static let heldCap = 4 << 20

    private let guard_: WSPromptGuard
    private let loop: EventLoop
    private let toUpstream: (Data) -> Void
    private let toGuest: (Data) -> Void
    private let setReading: (Bool) -> Void
    private let fail: () -> Void
    private let reader = WSFrameReader()
    private var assembler = WSMessageAssembler()
    private var queue: [Item] = []
    private var held = 0
    private var reading = true
    private var scan: Task<Void, Never>?
    private var oversizedReported = 0
    private var failed = false

    // @port-skip linux-only: see WSClientFilter
    init(guard g: WSPromptGuard, loop: EventLoop, toUpstream: @escaping (Data) -> Void,
         toGuest: @escaping (Data) -> Void, setReading: @escaping (Bool) -> Void = { _ in },
         fail: @escaping () -> Void) {
        guard_ = g
        self.loop = loop
        self.toUpstream = toUpstream
        self.toGuest = toGuest
        self.setReading = setReading
        self.fail = fail
    }

    /// The connection ended: a scan (and an ask it's waiting on) is dropped.
    // @port-skip linux-only: see WSClientFilter
    func cancel() {
        failed = true
        scan?.cancel()
        scan = nil
    }

    /// The guest's bytes, as they come (on the loop).
    // @port-skip linux-only: see WSClientFilter
    func feed(_ bytes: Data) {
        loop.preconditionInEventLoop()
        guard !failed else { return }
        reader.feed(bytes)
        while let f = reader.next() {
            if f.rsv != 0 { return broken("a reserved bit set with no extension") }
            if f.isControl {
                // Ping and pong go now; a close after the messages before it.
                if f.opcode == WSFrame.close { enqueue(.raw(f.raw)) } else { toUpstream(f.raw) }
                continue
            }
            switch assembler.add(f) {
            case .incomplete: break
            case .complete(let opcode, let payload, let raw):
                enqueue(.message(opcode: opcode, payload: payload, raw: raw))
            case .passthrough(let raw): enqueue(.raw(raw))
            case .protocolError: return broken("a continuation frame out of place")
            }
        }
        if reader.failed { return broken("a frame past \(WSFrameReader.maxFrame >> 20) MiB") }
        if assembler.oversized > oversizedReported {
            oversizedReported = assembler.oversized
            ProxyPolicy.recordScanSkipped(host: guard_.host, path: "", engines: guard_.engines,
                                          reason: "WebSocket message too large to scan", profileID: guard_.profileID)
        }
    }

    // @port-skip linux-only: see WSClientFilter
    private func broken(_ why: String) {
        failed = true
        FileHandle.standardError.write(Data("[mitm] \(guard_.host): WebSocket closed: \(why)\n".utf8))
        fail()
    }

    // @port-skip linux-only: see WSClientFilter
    private func enqueue(_ item: Item) {
        queue.append(item)
        held += item.size
        drain()
    }

    /// The guest is read while what's held is under the cap.
    // @port-skip linux-only: see WSClientFilter
    private func pace() {
        let want = held <= Self.heldCap
        if want != reading { reading = want; setReading(want) }
    }

    /// The next item, once the one before it went (or was refused).
    // @port-skip linux-only: see WSClientFilter
    private func drain() {
        defer { pace() }
        while scan == nil, !failed, !queue.isEmpty {
            let item = queue.removeFirst()
            switch item {
            case .raw(let raw):
                held -= item.size
                toUpstream(raw)
            case .message(let opcode, let payload, let raw):
                let (g, loop) = (guard_, loop)
                scan = Task {
                    let verdict = await g.client(payload)
                    loop.execute {
                        self.scan = nil
                        self.held -= item.size
                        guard !self.failed else { return }
                        switch verdict {
                        case .forward(nil): self.toUpstream(raw)
                        case .forward(let rewritten?): self.toUpstream(WSFrame.encode(opcode: opcode, payload: rewritten, masked: true))
                        case .block(let reply): self.toGuest(WSFrame.encode(opcode: WSFrame.text, payload: reply, masked: false))
                        }
                        self.drain()
                    }
                }
            }
        }
    }
}

/// The model → client direction of a guarded WebSocket (macOS:
/// WSTransformRelay.upstreamToClient), on the upstream channel's loop. A
/// block event the client side injects lands between two messages, never
/// inside a frame or a fragmented message (macOS: InjectQueue).
///
/// With a restorer (PII protection on), as macOS: frames are read, messages
/// reassembled, each one's stand-ins put back (it may become none, held, or
/// several), and what's held released before the server's close. Without
/// one, the server's bytes go to the client as they come, read only for
/// where each frame ends and whether a message is under way: nothing is
/// held, so no frame is too large.
// @port-skip linux-only: WSTransformRelay.upstreamToClient and its InjectQueue on NIO
final class WSServerSide: @unchecked Sendable {
    private let loop: EventLoop
    private let write: (Data) -> Void
    private let restorer: WSServerRestorer?
    private let reader = WSFrameReader()
    private var assembler = WSMessageAssembler()
    /// The header of the frame being read, while it's incomplete.
    private var header = Data()
    /// The payload bytes of the current frame not yet relayed.
    private var payloadLeft: UInt64 = 0
    /// Inside a fragmented message (a data frame without FIN went out).
    private var midMessage = false
    /// Between two messages: an injected event may go out.
    // @port-skip linux-only: see WSServerSide
    private var atBoundary: Bool {
        restorer != nil ? !passingThrough : !midMessage && payloadLeft == 0 && header.isEmpty
    }
    /// Restoring: a message too large to hold is going through fragment by
    /// fragment (no event may go inside it).
    private var passingThrough = false
    private let pending = NIOLockedValueBox<[Data]>([])

    // @port-skip linux-only: see WSServerSide
    init(loop: EventLoop, write: @escaping (Data) -> Void, restorer: WSServerRestorer? = nil) {
        self.loop = loop
        self.write = write
        self.restorer = restorer
    }

    /// The upstream's bytes in; what goes to the client out (the same bytes,
    /// injected events after a message), or nil for a broken stream (a
    /// continuation with no message under way, a new message inside one).
    // @port-skip linux-only: see WSServerSide
    func feed(_ bytes: Data) -> Data? {
        if let restorer { return feedRestoring(bytes, restorer) }
        var out = Data()
        var i = bytes.startIndex
        while i < bytes.endIndex {
            if payloadLeft > 0 {
                let n = Int(min(payloadLeft, UInt64(bytes.endIndex - i)))
                out.append(bytes[i..<(i + n)])
                i += n
                payloadLeft -= UInt64(n)
            } else {
                header.append(bytes[i])
                i += 1
                switch Self.frameHeader(header) {
                case .needMore: continue
                case .broken: return nil
                case .frame(let fin, let opcode, let length):
                    if opcode & 0x08 == 0 {
                        // A data frame: a continuation only inside a message,
                        // a new message only outside one.
                        guard (opcode == 0) == midMessage else { return nil }
                        midMessage = !fin
                    }
                    out.append(header)
                    header.removeAll()
                    payloadLeft = length
                }
            }
            if atBoundary { out.append(contentsOf: takeInjects()) }
        }
        return out
    }

    /// `feed` with PII restored: only whole messages go out (a fragmented
    /// one is held until its last fragment), so an injected event may go
    /// between any two of them.
    // @port-skip linux-only: see WSServerSide
    private func feedRestoring(_ bytes: Data, _ restorer: WSServerRestorer) -> Data? {
        reader.feed(bytes)
        var out = Data()
        while let f = reader.next() {
            if f.isControl {
                if f.opcode == WSFrame.close, !passingThrough {
                    for p in restorer.finish() { out.append(WSFrame.encode(opcode: WSFrame.text, payload: p, masked: false)) }
                }
                out.append(f.raw)
                continue
            }
            switch assembler.add(f) {
            case .incomplete: break
            case .passthrough(let raw):
                out.append(raw)
                passingThrough = !f.fin
            case .complete(let op, let payload, let raw):
                if f.rsv == 0, let restored = restorer.restore(payload) {
                    for p in restored { out.append(WSFrame.encode(opcode: op, payload: p, masked: false)) }
                } else {
                    out.append(raw)
                }
            case .protocolError: return nil
            }
        }
        if reader.failed { return nil }
        if atBoundary { out.append(contentsOf: takeInjects()) }
        return out
    }

    /// The upstream closed without a close frame: what the restorer holds
    /// goes to the client (macOS releases it at the close frame; a socket
    /// that just ends would drop it).
    // @port-skip linux-only: see WSServerSide
    func finishAtClose() -> Data {
        guard let restorer, !passingThrough else { return Data() }
        return restorer.finish().reduce(Data()) { $0 + WSFrame.encode(opcode: WSFrame.text, payload: $1, masked: false) }
    }

    private enum Header { case needMore, broken, frame(fin: Bool, opcode: UInt8, length: UInt64) }

    /// A frame header read from its first bytes (RFC 6455 §5.2).
    // @port-skip linux-only: see WSServerSide
    private static func frameHeader(_ h: Data) -> Header {
        let b = [UInt8](h)
        guard b.count >= 2 else { return .needMore }
        let len7 = b[1] & 0x7F
        let extra = len7 == 126 ? 2 : len7 == 127 ? 8 : 0
        let need = 2 + extra + (b[1] & 0x80 != 0 ? 4 : 0)
        guard b.count >= need else { return .needMore }
        var length = UInt64(len7)
        if extra > 0 { length = b[2..<(2 + extra)].reduce(0) { $0 << 8 | UInt64($1) } }
        guard length >> 63 == 0 else { return .broken }
        return .frame(fin: b[0] & 0x80 != 0, opcode: b[0] & 0x0F, length: length)
    }

    /// A server event for the client (a refused turn's): now if no message
    /// is under way, else right after it.
    // @port-skip linux-only: see WSServerSide
    func inject(_ frame: Data) {
        pending.withLockedValue { $0.append(frame) }
        loop.execute {
            guard self.atBoundary else { return }
            let d = self.takeInjects()
            if !d.isEmpty { self.write(d) }
        }
    }

    // @port-skip linux-only: see WSServerSide
    private func takeInjects() -> Data {
        pending.withLockedValue { p in defer { p.removeAll() }; return p.reduce(Data(), +) }
    }
}
