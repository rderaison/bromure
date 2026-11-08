import Darwin
import Foundation
import SandboxEngine

// WebSocket content protection.
//
// Codex (0.157+) talks to its model over one long-lived WebSocket
// (`chatgpt.com/backend-api/codex/responses`, or the API host's
// `/v1/responses`): every turn is a `response.create` client message carrying
// the conversation, and the reply streams back as `response.*` server
// messages — the same JSON the HTTP Responses API carries, one event per
// message instead of one per SSE block. The raw relay forwarded those frames
// untouched, so PII protection and prompt-injection detection never saw a
// Codex subscription turn.
//
// When either engine is on for the workspace, an AI host's WebSocket goes
// through `WSTransformRelay` instead of the opaque pump: frames are parsed,
// fragmented messages reassembled, client messages scanned and swapped like a
// Responses POST body, server messages restored like its SSE stream. To read
// and rewrite the payloads the relay declines permessage-deflate during the
// handshake (RFC 6455 §9.1 / RFC 7692 §5: an extension the server's response
// doesn't list isn't in use), so both legs carry plain frames. With both
// engines off the socket keeps the opaque pump — and its compression.

// MARK: - Prompt-injection helpers (shared with the HTTP path)

extension HTTPMitmConnection {
    /// ProxyPolicy's (shared with the Linux proxy).
    static func detectPromptInjection(in conv: Conversation,
                                      policy pi: PromptInjectionPolicy) async -> PromptInjectionFlag? {
        await ProxyPolicy.detectPromptInjection(in: conv, policy: pi)
    }

    /// ProxyPolicy's (shared with the Linux proxy).
    static func injectionNextStep(detector: String, instructionsWithheld: Bool) -> String {
        ProxyPolicy.injectionNextStep(detector: detector, instructionsWithheld: instructionsWithheld)
    }

    /// ProxyPolicy's (shared with the Linux proxy).
    static func recordPromptInjection(_ f: PromptInjectionFlag, outcome: String,
                                      host: String, profileID: UUID) {
        ProxyPolicy.recordPromptInjection(f, outcome: outcome, host: host, profileID: profileID)
    }

    /// "Log but continue": scan detached, never delaying the traffic.
    static func logPromptInjection(in conv: Conversation, policy pi: PromptInjectionPolicy,
                                   host: String, profileID: UUID) {
        let pid = profileID
        if pi.detectSourceInjection {
            let untrusted = PromptInjectionRedactions.scannable(newToolResultSpans(in: conv))
            if !untrusted.isEmpty {
                Task.detached(priority: .utility) {
                    await PromptInjectionClassifier.shared.scanAndLog(
                        spans: untrusted, host: host, profileID: pid)
                }
            }
        }
        if pi.detectRulesInjection {
            // Deterministic pass (hidden-Unicode + capability heuristics)
            // …plus the fine-tuned ModernBERT semantic pass over the same
            // instruction-file spans.
            let extra = RulesFileScanner.scannable(RulesFileScanner.conversationInstructionSpans(conv))
            RulesFileScanner.shared.scanAndLog(
                systemPrompt: conv.systemPrompt, extraSpans: extra, host: host, profileID: pid)
            let ruleSpans = RulesFileScanner.classifierSpans(conv.systemPrompt, extraSpans: extra)
            if !ruleSpans.isEmpty {
                Task.detached(priority: .utility) {
                    await PromptInjectionClassifier.claudeMd.scanAndLog(
                        spans: ruleSpans, host: host, profileID: pid)
                }
            }
        }
    }
}

// MARK: - Content guard

/// The per-socket content engines: scans + swaps client messages, restores
/// server messages. `client` may run concurrently with `server` (the vault is
/// thread-safe); `server`/`serverFinish` are only called from the
/// upstream→client direction.
final class WSContentGuard: @unchecked Sendable {
    enum ClientVerdict {
        /// Forward: the rewritten payload, or nil for "unchanged".
        case forward(Data?)
        /// Drop the message; send `reply` (a server event) to the client.
        case block(reply: Data)
    }

    let host: String
    let path: String
    let profileID: UUID
    let vault: PIIVault
    let piiPolicy: @Sendable () -> PIIPolicy?
    let injectionPolicy: @Sendable () -> PromptInjectionPolicy?
    var detect: @Sendable (Conversation, PromptInjectionPolicy) async -> PromptInjectionFlag? = {
        await HTTPMitmConnection.detectPromptInjection(in: $0, policy: $1)
    }
    var consent: @Sendable (PromptInjectionFlag) async -> Bool
    var logScan: @Sendable (Conversation, PromptInjectionPolicy) -> Void
    var recordInjection: @Sendable (PromptInjectionFlag, String) -> Void
    var recordSwaps: @Sendable (PIIRewriter.Outcome, Double) -> Void

    /// Squelch for this socket's turns, and the conversation the upgrade
    /// named (Codex's `session_id` header) — where its savings are counted.
    var squelch: @Sendable () -> SquelchPolicy? = { nil }
    var conversation: String?
    var squelchLedger: SquelchLedger = .shared

    private let serverRestorer: WSServerRestorer

    init(host: String, path: String, profileID: UUID, vault: PIIVault,
         piiPolicy: @escaping @Sendable () -> PIIPolicy?,
         injectionPolicy: @escaping @Sendable () -> PromptInjectionPolicy?) {
        self.host = host
        self.path = path
        self.profileID = profileID
        self.vault = vault
        self.piiPolicy = piiPolicy
        self.injectionPolicy = injectionPolicy
        self.serverRestorer = WSServerRestorer(vault: vault)
        consent = { f in
            await HTTPMitmConnection.promptInjectionBroker.consent(
                profileID: profileID, detectorName: f.detector,
                source: f.source, flaggedText: f.preview)
        }
        logScan = { conv, pi in
            HTTPMitmConnection.logPromptInjection(in: conv, policy: pi, host: host, profileID: profileID)
        }
        recordInjection = { f, outcome in
            HTTPMitmConnection.recordPromptInjection(f, outcome: outcome, host: host, profileID: profileID)
        }
        recordSwaps = { o, ms in
            HTTPMitmConnection.recordPIISwaps(o, host: host, profileID: profileID, ms: ms)
        }
    }

    /// The guard for an upgrade, or nil when the socket should stay an
    /// opaque (compressed) pipe: not a model provider, or neither engine on.
    /// A model provider's socket, which these engines read.
    static func isModelSocket(host: String, profileID: UUID) -> Bool {
        let h = host.lowercased()
        // The local-inference sentinel only when its engine is off this Mac
        // (a custom server elsewhere) — the on-device engine is exempt.
        return HTTPMitmConnection.isAIHost(h) && !h.contains("huggingface.co")
            && (h != InferenceService.localMitmHost || PIIEngineScope.offMacEngineHost(profileID: profileID) != nil)
    }

    /// Squelch is on for this socket.
    static func squelchApplies(host: String, profileID: UUID) -> Bool {
        isModelSocket(host: host, profileID: profileID)
            && (HTTPMitmConnection.squelchPolicyProvider?(profileID)?.enabled ?? false)
    }

    /// Squelch as an OpenShell message transform, for a socket on the
    /// per-message pump (a policy or rewrite is installed, so there is no
    /// guard): client text is trimmed first, then `then` runs on it.
    static func squelchingTransform(then: ((String) -> OpenShellWebSocket.MessageTransform)?, profileID: UUID,
                                    conversation: String?, ledger: SquelchLedger = .shared)
        -> (String) -> OpenShellWebSocket.MessageTransform {
        { text in
            var current = text
            var changed = false
            let data = Data(text.utf8)
            if HTTPMitmConnection.squelchPolicyProvider?(profileID)?.enabled == true,
               SquelchRewriter.mayCarryToolOutput(data) {
                let o = SquelchRewriter.rewrite(data, priorCall: { SquelchCallRegistry.shared.call(profileID, $0) })
                ledger.record(o, profileID: profileID, conversation: conversation ?? o.conversation)
                if o.body != data { current = String(decoding: o.body, as: UTF8.self); changed = true }
            }
            switch then?(current) ?? .unchanged {
            case .unchanged: break
            case .replaced(let t): current = t; changed = true
            case .failed(let why, let failOpen): return .failed(why, failOpen: failOpen)
            }
            return changed ? .replaced(current) : .unchanged
        }
    }

    static func make(host: String, path: String, profileID: UUID, conversation: String? = nil) -> WSContentGuard? {
        guard isModelSocket(host: host, profileID: profileID) else { return nil }
        let piiOn = HTTPMitmConnection.piiPolicyProvider?(profileID)?.isActive ?? false
        let piOn = HTTPMitmConnection.promptInjectionPolicyProvider?(profileID)?.isActive ?? false
        let squelchOn = HTTPMitmConnection.squelchPolicyProvider?(profileID)?.enabled ?? false
        guard piiOn || piOn || squelchOn else { return nil }
        let pid = profileID
        let g = WSContentGuard(
            host: host, path: path, profileID: profileID, vault: PIIVault.forProfile(profileID),
            piiPolicy: { HTTPMitmConnection.piiPolicyProvider?(pid) },
            injectionPolicy: { HTTPMitmConnection.promptInjectionPolicyProvider?(pid) })
        g.squelch = { HTTPMitmConnection.squelchPolicyProvider?(pid) }
        g.conversation = conversation
        return g
    }

    // MARK: Client → model

    func client(_ payload: Data) async -> ClientVerdict {
        guard payload.first(where: { !Self.isSpace($0) }) == UInt8(ascii: "{") else { return .forward(nil) }
        let pi = injectionPolicy().flatMap { $0.isActive ? $0 : nil }
        let pii = piiPolicy().flatMap { $0.isActive ? $0 : nil }
        let squelchOn = squelch()?.enabled ?? false
        guard pi != nil || pii != nil || squelchOn else { return .forward(nil) }
        let type = Self.messageType(payload)
        // Tool output the user already blocked goes out as a placeholder
        // (the conversation is resent every turn), so the session goes on.
        var payload = payload
        // "Changed": what goes out isn't what the client sent.
        var redacted = false
        // Squelch, before the scans: they read what the model will.
        if squelchOn, SquelchRewriter.mayCarryToolOutput(payload) {
            let pid = profileID
            let o = SquelchRewriter.rewrite(payload, priorCall: { SquelchCallRegistry.shared.call(pid, $0) })
            squelchLedger.record(o, profileID: profileID,
                                        conversation: conversation ?? o.conversation)
            if o.body != payload { payload = o.body; redacted = true }
        }
        guard pi != nil || pii != nil else { return .forward(redacted ? payload : nil) }
        if pi != nil, pi?.onDetection != .log,
           let r = PromptInjectionRedactions.shared.redact(payload, profileID: profileID) {
            payload = r.body
            redacted = true
            HTTPMitmConnection.recordInjectionRedacted(count: r.count, host: host, profileID: profileID)
        }

        // Prompt injection first, over what the agent sent (as the HTTP path).
        // The parser reads the message exactly like a Responses POST body;
        // a dummy head keeps its HTTP-framing strip off the JSON.
        if let pi, let conv = ConversationParser.parse(
            host: host, requestBody: Data("WS\r\n\r\n".utf8) + Self.conversationBody(payload, type: type),
            responseBody: nil) {
            if pi.onDetection == .log {
                logScan(conv, pi)
            } else if let f = await detect(conv, pi) {
                if pi.onDetection == .block {
                    recordInjection(f, "blocked")
                    PromptInjectionRedactions.shared.block(f, profileID: profileID)
                    return .block(reply: Self.blockEvent(f, requestType: type))
                }
                let allow = await consent(f)
                recordInjection(f, allow ? "allowed" : "blocked")
                if !allow {
                    PromptInjectionRedactions.shared.block(f, profileID: profileID)
                    return .block(reply: Self.blockEvent(f, requestType: type))
                }
            }
        }

        guard let pii, Self.carriesConversation(payload) else { return .forward(redacted ? payload : nil) }
        let t = Date()
        let outcome = await PIIRewriter.rewriteRequest(payload, policy: pii, vault: vault)
        let ms = Date().timeIntervalSince(t) * 1000
        if outcome.total > 0 || outcome.partial { recordSwaps(outcome, ms) }
        if outcome.total > 0 || ms > 250 || outcome.partial {
            FileHandle.standardError.write(Data(String(
                format: "[pii] %@ %@ (WebSocket %@): %d new value(s) swapped, %d → %d bytes, %.0f ms%@\n",
                host, path, type ?? "message", outcome.total, payload.count, outcome.body.count, ms,
                outcome.partial ? " (model budget spent: rest by pattern rules)" : "").utf8))
        }
        return .forward(outcome.body == payload && !redacted ? nil : outcome.body)
    }

    /// WSMessages' (shared with the Linux proxy).
    static func blockEvent(_ f: PromptInjectionFlag, requestType: String?) -> Data {
        WSMessages.blockEvent(f, requestType: requestType)
    }

    // MARK: Model → client

    /// Restored payload(s) for one server message, or nil for "unchanged".
    /// Deltas go through the same restorer as the Responses SSE stream (one
    /// WS message = one SSE event), including its hold-back of a stand-in
    /// split across deltas — which may turn one message into none (held) or
    /// several (a released tail ahead of the closing event).
    func server(_ payload: Data) -> [Data]? {
        // The calls the model makes: what a chained turn's bare results are
        // matched with (Squelch).
        if squelch()?.enabled == true {
            SquelchCallRegistry.shared.learn(fromServerEvent: payload, profileID: profileID)
        }
        return serverRestorer.restore(payload)
    }

    /// Held text released when the server ends the stream.
    func serverFinish() -> [Data] {
        serverRestorer.finish()
    }

    // MARK: Helpers

    private static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }

    /// WSServerRestorer's (shared with the Linux proxy).
    static func sseData(_ out: Data) -> [Data] { WSServerRestorer.sseData(out) }

    /// WSMessages' (shared with the Linux proxy).
    static func messageType(_ payload: Data) -> String? { WSMessages.messageType(payload) }

    /// WSMessages' (shared with the Linux proxy).
    static func conversationBody(_ payload: Data, type: String?) -> Data {
        WSMessages.conversationBody(payload, type: type)
    }

    /// WSMessages' (shared with the Linux proxy).
    static func carriesConversation(_ payload: Data) -> Bool {
        WSMessages.carriesConversation(payload)
    }
}

// MARK: - Relay

/// Frame-level relay for a guarded WebSocket. Same concurrency contract as the
/// opaque pump (`pumpDirection`): each direction reads one stream and writes
/// the other through the streams' own non-blocking, per-stream-locked
/// `readNB`/`writeNB`, waiting in `poll()` outside any lock — never two
/// concurrent SSL calls on one context, never a blocking call under a lock.
/// The client→model direction never awaits inline: a message being scanned
/// (or held for the user's answer) runs in its own task while the loop keeps
/// relaying control frames (ping/pong) and queuing later messages in order.
enum WSTransformRelay {
    struct Endpoint: @unchecked Sendable {
        let fd: Int32
        let readNB: () throws -> StreamReadOutcome
        let writeNB: (Data) throws -> Int
    }

    /// Server events the client→model side wants delivered to the client
    /// (a blocked turn's error). Written by the model→client side only — at
    /// a message boundary, so they never split a frame.
    final class InjectQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Data] = []
        func push(_ d: Data) { lock.lock(); items.append(d); lock.unlock() }
        func drain() -> [Data] { lock.lock(); defer { items.removeAll(); lock.unlock() }; return items }
    }

    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T?
        func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
        func take() -> T? { lock.lock(); defer { value = nil; lock.unlock() }; return value }
    }

    /// Run both directions until either side ends.
    /// `onClientBytes`/`onUpstreamBytes` see raw bytes as read (counters,
    /// activity); `onClientIn`/`onClientOut` see the guest's view of the
    /// traffic (what it sent, what it received) for the trace transcript.
    static func run(client: Endpoint, upstream: Endpoint, guard g: WSContentGuard,
                    onClientBytes: @escaping @Sendable (Data) -> Void,
                    onUpstreamBytes: @escaping @Sendable (Data) -> Void,
                    onClientOut: @escaping @Sendable (Data) -> Void = { _ in }) async {
        let inject = InjectQueue()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                clientToUpstream(client: client, upstream: upstream, guard: g,
                                 inject: inject, onChunk: onClientBytes)
            }
            group.addTask {
                upstreamToClient(upstream: upstream, client: client, guard: g,
                                 inject: inject, onChunk: onUpstreamBytes, onOut: onClientOut)
            }
            await group.next()
            group.cancelAll()
        }
    }

    private enum Item {
        case raw(Data)
        /// A whole data message to scan (JSON rides in text frames, and
        /// sometimes in binary ones: the opcode is kept on re-encode).
        case message(opcode: UInt8, payload: Data, raw: Data)
    }

    static func clientToUpstream(client: Endpoint, upstream: Endpoint, guard g: WSContentGuard,
                                 inject: InjectQueue, onChunk: (Data) -> Void) {
        let reader = WSFrameReader()
        var assembler = WSMessageAssembler()
        var queue: [Item] = []
        var inflight: (box: Box<WSContentGuard.ClientVerdict>, task: Task<Void, Never>)? = nil
        defer { inflight?.task.cancel() }
        var out = Data()
        var eof = false
        var skippedReported = 0
        while true {
            // One pool per pass: this runs on a raw Thread (mitm-io) for the
            // connection's lifetime, and its implicit pool never drains.
            let go = autoreleasepool { () -> Bool in
                if Task.isCancelled { return false }
                if !eof {
                    drain: while true {
                        let outcome: StreamReadOutcome
                        do { outcome = try client.readNB() } catch { return false }
                        switch outcome {
                        case .bytes(let d): onChunk(d); reader.feed(d)
                        case .wouldBlock: break drain
                        case .eof: eof = true; break drain
                        }
                    }
                }
                while let f = reader.next() {
                    // An extension bit with no extension negotiated (they're
                    // stripped from the handshake, and one in use falls back
                    // to the pump): RFC 6455 §5.2, the connection fails —
                    // never a message sent on unscanned.
                    if f.rsv != 0 {
                        FileHandle.standardError.write(Data("[mitm] WS \(g.host): reserved bits set — closing\n".utf8))
                        return false
                    }
                    if f.isControl {
                        // Close waits behind held messages; ping/pong may go
                        // between them (RFC 6455 §5.4 lets control frames
                        // interleave with a message's fragments).
                        if f.opcode == WSFrame.close { queue.append(.raw(f.raw)) } else { out.append(f.raw) }
                        continue
                    }
                    switch assembler.add(f) {
                    case .incomplete: break
                    case .passthrough(let raw): queue.append(.raw(raw))
                    case .complete(let op, let payload, let raw):
                        queue.append(.message(opcode: op, payload: payload, raw: raw))
                    case .protocolError:
                        FileHandle.standardError.write(Data("[mitm] WS \(g.host): bad client framing — closing\n".utf8))
                        return false
                    }
                }
                if reader.failed { return false }
                if assembler.oversized > skippedReported {
                    skippedReported = assembler.oversized
                    HTTPMitmConnection.recordScanSkipped(
                        host: g.host, path: g.path, engines: ["pii", "prompt_injection"],
                        reason: "WebSocket message too large to scan", profileID: g.profileID)
                }
                while let first = queue.first {
                    if let inf = inflight {
                        guard let verdict = inf.box.take() else { break }
                        inflight = nil
                        queue.removeFirst()
                        guard case .message(let op, _, let raw) = first else { continue }
                        switch verdict {
                        case .forward(nil): out.append(raw)
                        case .forward(let p?): out.append(WSFrame.encode(opcode: op, payload: p, masked: true))
                        case .block(let reply):
                            inject.push(WSFrame.encode(opcode: WSFrame.text, payload: reply, masked: false))
                        }
                        continue
                    }
                    switch first {
                    case .raw(let r):
                        out.append(r)
                        queue.removeFirst()
                    case .message(_, let payload, _):
                        let box = Box<WSContentGuard.ClientVerdict>()
                        let task = Task.detached { box.set(await g.client(payload)) }
                        inflight = (box, task)
                    }
                }
                if !flush(&out, to: upstream) { return false }
                if eof && queue.isEmpty && inflight == nil { return false }
                if eof {
                    usleep(20_000)   // only a scan left to finish
                    return true
                }
                var pfd = pollfd(fd: client.fd, events: Int16(POLLIN), revents: 0)
                if poll(&pfd, 1, inflight == nil ? 250 : 20) < 0 && errno != EINTR { return false }
                return true
            }
            if !go { return }
        }
    }

    static func upstreamToClient(upstream: Endpoint, client: Endpoint, guard g: WSContentGuard,
                                 inject: InjectQueue, onChunk: (Data) -> Void, onOut: (Data) -> Void) {
        let reader = WSFrameReader()
        var assembler = WSMessageAssembler()
        var out = Data()
        while true {
            // One pool per pass: this runs on a raw Thread (mitm-io) for the
            // connection's lifetime, and its implicit pool never drains.
            let go = autoreleasepool { () -> Bool in
                if Task.isCancelled { return false }
                var eof = false
                drain: while true {
                    let outcome: StreamReadOutcome
                    do { outcome = try upstream.readNB() } catch { return false }
                    switch outcome {
                    case .bytes(let d): onChunk(d); reader.feed(d)
                    case .wouldBlock: break drain
                    case .eof: eof = true; break drain
                    }
                }
                while let f = reader.next() {
                    if f.isControl {
                        if f.opcode == WSFrame.close {
                            for p in g.serverFinish() {
                                out.append(WSFrame.encode(opcode: WSFrame.text, payload: p, masked: false))
                            }
                        }
                        out.append(f.raw)
                        continue
                    }
                    switch assembler.add(f) {
                    case .incomplete: break
                    case .passthrough(let raw): out.append(raw)
                    case .complete(let op, let payload, let raw):
                        if f.rsv == 0, let restored = g.server(payload) {
                            for p in restored { out.append(WSFrame.encode(opcode: op, payload: p, masked: false)) }
                        } else {
                            out.append(raw)
                        }
                    case .protocolError:
                        FileHandle.standardError.write(Data("[mitm] WS \(g.host): bad server framing — closing\n".utf8))
                        return false
                    }
                }
                if reader.failed { return false }
                for d in inject.drain() { out.append(d) }
                if !out.isEmpty { onOut(out) }
                if !flush(&out, to: client) { return false }
                if eof { return false }
                var pfd = pollfd(fd: upstream.fd, events: Int16(POLLIN), revents: 0)
                if poll(&pfd, 1, 100) < 0 && errno != EINTR { return false }
                return true
            }
            if !go { return }
        }
    }

    /// Write everything, waiting for writability (backpressure) outside any
    /// lock. False when the peer is gone or the relay was cancelled.
    private static func flush(_ out: inout Data, to ep: Endpoint) -> Bool {
        while !out.isEmpty {
            let n: Int
            do { n = try ep.writeNB(out) } catch { return false }
            if n > 0 { out.removeFirst(n); continue }
            if Task.isCancelled { return false }
            var pfd = pollfd(fd: ep.fd, events: Int16(POLLOUT), revents: 0)
            if poll(&pfd, 1, 250) < 0 && errno != EINTR { return false }
        }
        return true
    }
}
