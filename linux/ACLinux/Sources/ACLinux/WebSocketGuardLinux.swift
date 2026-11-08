import Foundation
import NIOConcurrencyHelpers
import NIOCore
import SandboxEngine

/// Prompt injection on a model provider's WebSocket (macOS: WSContentGuard's
/// client side, its prompt-injection part; PII isn't on Linux yet). Codex
/// 0.157+ sends every turn as a `response.create` message on one socket:
/// each client message is read like a Responses POST body and scanned as the
/// HTTP path scans one. Log mode records; block refuses; ask asks the client.
/// A refused message never goes upstream: the client gets the block event
/// instead (`response.failed` / `invalid_prompt` for a Responses turn).
// @port-skip linux-only: WSContentGuard.client's prompt-injection part (macOS's also swaps PII and squelches)
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

    // @port-skip linux-only: see WSPromptGuard
    init(proxy: MitmProxy, profileID: UUID, host: String) {
        self.proxy = proxy
        self.profileID = profileID
        self.host = host
    }

    /// The guard for an upgrade, or nil when the socket stays an opaque
    /// (compressed) pipe: not a model provider's (macOS: isModelSocket), or
    /// prompt injection off for the workspace.
    // @port-skip linux-only: WSContentGuard.make, for prompt injection
    static func make(proxy: MitmProxy, profileID: UUID, host: String) -> WSPromptGuard? {
        let h = host.lowercased()
        // The local-inference sentinel only when its engine is off this
        // machine (a custom server elsewhere): the conversation leaves it then.
        guard TraceLevel.aiHosts.contains(where: { h.contains($0) }), !h.contains("huggingface.co"),
              h != InferenceService.localMitmHost || engineIsElsewhere(profileID),
              proxy.promptInjectionPolicy(for: profileID)?.isActive == true else { return nil }
        return WSPromptGuard(proxy: proxy, profileID: profileID, host: host)
    }

    /// The workspace's external inference engine runs on another machine
    /// (macOS: PIIEngineScope.offMacEngineHost).
    // @port-skip linux-only: PIIEngineScope.offMacEngineHost's test (the PII rewriter's file isn't on Linux)
    static func engineIsElsewhere(_ profileID: UUID) -> Bool {
        guard var h = InferenceRepairProxy.shared.externalEngine(for: profileID)?.base.host?.lowercased(),
              !h.isEmpty else { return false }
        if h.hasPrefix("["), h.hasSuffix("]") { h = String(h.dropFirst().dropLast()) }
        if h == "localhost" || h.hasSuffix(".localhost") || h == "::1" || h == "::" { return false }
        let me = localHostName
        if h == me || h == me.split(separator: ".").first.map(String.init) { return false }
        if let ip = VMNetSwitch.parseIPv4(h), HostAddresses.shared.contains(ip) { return false }
        return true
    }

    /// This machine's name, as gethostname(2) has it: read once, never looked
    /// up (ProcessInfo.hostName can reverse-resolve on corelibs, and this
    /// runs on the event loop).
    static let localHostName: String = {
        var buf = [CChar](repeating: 0, count: 256)
        guard gethostname(&buf, buf.count - 1) == 0 else { return "" }
        return String(cString: buf).lowercased()
    }()

    // @port-skip linux-only: WSContentGuard.client's prompt-injection part
    func client(_ payload: Data) async -> Verdict {
        guard payload.first(where: { !Self.isSpace($0) }) == UInt8(ascii: "{"),
              let pi = proxy.promptInjectionPolicy(for: profileID), pi.isActive else { return .forward(nil) }
        let type = Self.messageType(payload)
        var payload = payload
        var redacted = false
        // Tool output the user already blocked goes out as a placeholder (the
        // conversation is resent every turn), so the session goes on.
        if pi.onDetection != .log, let r = PromptInjectionRedactions.shared.redact(payload, profileID: profileID) {
            payload = r.body
            redacted = true
            ProxyPolicy.recordInjectionRedacted(count: r.count, host: host, profileID: profileID)
        }
        // Read like a Responses POST body; a dummy head keeps the parser's
        // HTTP-framing strip off the JSON.
        guard let conv = ConversationParser.parse(
            host: host, requestBody: Data("WS\r\n\r\n".utf8) + WSMessages.conversationBody(payload, type: type),
            responseBody: nil) else { return .forward(redacted ? payload : nil) }
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
        return .forward(redacted ? payload : nil)
    }

    /// The top-level `type` of a JSON message (macOS reads it with
    /// JSONStrings, part of the PII rewriter, not on Linux).
    // @port-skip linux-only: WSContentGuard.messageType on JSONSerialization
    static func messageType(_ payload: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: payload) as? [String: Any])?["type"] as? String
    }

    // @port-skip linux-only: see WSPromptGuard
    private static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }
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
            ProxyPolicy.recordScanSkipped(host: guard_.host, path: "", engines: ["prompt_injection"],
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
/// WSTransformRelay.upstreamToClient, without the PII restore Linux doesn't
/// have yet), on the upstream channel's loop: the server's bytes go to the
/// client as they come, read only for where each frame ends and whether a
/// message is under way, so that a block event the client side injects lands
/// between two messages, never inside a frame or a fragmented message
/// (macOS: InjectQueue). No size limit: nothing is held.
// @port-skip linux-only: WSTransformRelay.upstreamToClient and its InjectQueue on NIO
final class WSServerSide: @unchecked Sendable {
    private let loop: EventLoop
    private let write: (Data) -> Void
    /// The header of the frame being read, while it's incomplete.
    private var header = Data()
    /// The payload bytes of the current frame not yet relayed.
    private var payloadLeft: UInt64 = 0
    /// Inside a fragmented message (a data frame without FIN went out).
    private var midMessage = false
    /// Between two messages: an injected event may go out.
    // @port-skip linux-only: see WSServerSide
    private var atBoundary: Bool { !midMessage && payloadLeft == 0 && header.isEmpty }
    private let pending = NIOLockedValueBox<[Data]>([])

    // @port-skip linux-only: see WSServerSide
    init(loop: EventLoop, write: @escaping (Data) -> Void) {
        self.loop = loop
        self.write = write
    }

    /// The upstream's bytes in; what goes to the client out (the same bytes,
    /// injected events after a message), or nil for a broken stream (a
    /// continuation with no message under way, a new message inside one).
    // @port-skip linux-only: see WSServerSide
    func feed(_ bytes: Data) -> Data? {
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
