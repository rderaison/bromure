import Darwin
import Foundation

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

/// One prompt-injection detection, ready to record / ask about.
struct PromptInjectionFlag: Sendable, Equatable {
    /// "prompt injection" (tool output) or "rogue instructions" (CLAUDE.md…).
    let detector: String
    /// "model" or "heuristic".
    let method: String
    let source: String
    let preview: String
    /// The tool output that was scanned (source detections): what a block
    /// redacts from later requests (`PromptInjectionRedactions`).
    var spans: [String] = []
    /// The instruction-file bodies that tripped a rules detection: what a
    /// block withholds from later requests (`blockInstructions`).
    var ruleSpans: [String] = []
    var detectorCode: String { detector == "rogue instructions" ? "rules" : "source" }
}

extension HTTPMitmConnection {
    /// The enforcement scan (ask / block): fresh tool output through the
    /// source model, then the instructions through the rules scanner + model.
    static func detectPromptInjection(in conv: Conversation,
                                      policy pi: PromptInjectionPolicy) async -> PromptInjectionFlag? {
        if pi.detectSourceInjection {
            // A blocked output already went out as the placeholder: scan what's
            // left, never the placeholder itself.
            let spans = newToolResultSpans(in: conv)
            if let preview = await PromptInjectionClassifier.shared.detect(
                spans: PromptInjectionRedactions.scannable(spans)) {
                return PromptInjectionFlag(detector: "prompt injection", method: "model",
                                           source: "tool output", preview: preview,
                                           spans: spans.map(\.content))
            }
        }
        if pi.detectRulesInjection {
            // Heuristic scanner first (catches obfuscation the model can't
            // read); then the ModernBERT semantic pass over the spans.
            // Repo instruction files pasted into the conversation (Codex's
            // AGENTS.md user message, Claude's CLAUDE.md reminder) count too.
            let extra = RulesFileScanner.scannable(RulesFileScanner.conversationInstructionSpans(conv))
            if let hit = RulesFileScanner.shared.detect(systemPrompt: conv.systemPrompt,
                                                        extraSpans: extra) {
                let all = extra + (conv.systemPrompt.map(RulesFileScanner.extractInstructionSpans) ?? [])
                let flagged = all.filter { $0.source == hit.source && RulesFileScanner.isHighRisk($0.content) }
                return PromptInjectionFlag(detector: "rogue instructions", method: "heuristic",
                                           source: hit.source, preview: hit.preview,
                                           ruleSpans: flagged.map(\.content))
            }
            let ruleSpans = RulesFileScanner.classifierSpans(conv.systemPrompt, extraSpans: extra)
            if let preview = await PromptInjectionClassifier.claudeMd.detect(spans: ruleSpans) {
                // Which file(s) tripped it (each verdict is cached: cheap).
                var flagged: [(id: String?, content: String)] = []
                for s in ruleSpans where await PromptInjectionClassifier.claudeMd.detect(spans: [s]) != nil {
                    flagged.append(s)
                }
                let named = flagged.compactMap(\.id)
                let source = named.count == 1 ? named[0]
                    : extra.isEmpty ? "CLAUDE.md"
                    : extra.count == 1 ? extra[0].source : "instruction files"
                return PromptInjectionFlag(detector: "rogue instructions", method: "model",
                                           source: source, preview: preview,
                                           ruleSpans: flagged.map(\.content))
            }
        }
        return nil
    }

    /// What the agent is told happens next, on its own line (agents that
    /// print one line of the error still show a whole sentence).
    ///  - tool output: later requests carry a placeholder instead.
    ///  - instructions: the conversation itself carries the file's text —
    ///    resent every turn, so removing CLAUDE.md alone never unblocked the
    ///    session. When the flagged bodies are known they're withheld from
    ///    later requests too; otherwise the way out is a new session / clear.
    static func injectionNextStep(detector: String, instructionsWithheld: Bool) -> String {
        if detector == "prompt injection" {
            return "\nLater requests carry a placeholder instead of that output, so the next message can go through."
                + " If it keeps failing, rewind the conversation past that step or start a new session."
        }
        if instructionsWithheld {
            return "\nThis conversation still carries those instructions, so later requests carry a placeholder instead of them and the next message can go through."
                + " Fix or remove the flagged file too; to drop them from the conversation entirely, start a new session (or /clear)."
        }
        return "\nThis conversation still carries those instructions: removing the file isn't enough for this session."
            + " Fix or remove the flagged file, then start a new session (or /clear)."
    }

    /// Security log + cloud event for a resolved detection ("blocked" /
    /// "allowed").
    static func recordPromptInjection(_ f: PromptInjectionFlag, outcome: String,
                                      host: String, profileID: UUID) {
        if outcome == "blocked" {
            BromureBlockLog.shared.record(f.detectorCode == "rules" ? .rulesInjection : .promptInjection,
                                          profileID: profileID)
        }
        SupplyChainLog.shared.record(
            "[prompt-injection] \(outcome): \(f.detector) in \(f.source) → \(host)")
        PromptInjectionCloudEvent.emit(
            profileID: profileID, detector: f.detectorCode, method: f.method,
            action: outcome, host: host, source: f.source, score: nil,
            signals: [], toolUseId: nil, snippet: f.preview)
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

// MARK: - Frames

/// One RFC 6455 frame with its exact wire bytes (so an untouched frame is
/// forwarded byte-for-byte, mask and all).
struct WSFrame {
    let fin: Bool
    /// RSV1-3 (bits 0x70 of the first byte). Non-zero means an extension is
    /// in use — never the case once the relay declined them.
    let rsv: UInt8
    let opcode: UInt8
    /// Unmasked payload.
    let payload: Data
    let raw: Data
    var isControl: Bool { opcode & 0x8 != 0 }

    static let text: UInt8 = 0x1
    static let binary: UInt8 = 0x2
    static let close: UInt8 = 0x8

    /// Encode one unfragmented frame. Client→server frames must be masked
    /// (RFC 6455 §5.3), with a fresh key per frame.
    static func encode(opcode: UInt8, payload: Data, masked: Bool) -> Data {
        var out = Data(capacity: payload.count + 14)
        out.append(0x80 | (opcode & 0x0F))
        let m: UInt8 = masked ? 0x80 : 0
        let n = payload.count
        if n < 126 {
            out.append(m | UInt8(n))
        } else if n <= 0xFFFF {
            out.append(m | 126)
            out.append(UInt8(n >> 8)); out.append(UInt8(n & 0xFF))
        } else {
            out.append(m | 127)
            for i in (0..<8).reversed() { out.append(UInt8((UInt64(n) >> (UInt64(i) * 8)) & 0xFF)) }
        }
        guard masked else { out.append(payload); return out }
        var key = [UInt8](repeating: 0, count: 4)
        if SecRandomCopyBytes(kSecRandomDefault, 4, &key) != errSecSuccess {
            key = (0..<4).map { _ in UInt8.random(in: 0...255) }
        }
        out.append(contentsOf: key)
        var body = [UInt8](payload)
        for i in 0..<body.count { body[i] ^= key[i & 3] }
        out.append(contentsOf: body)
        return out
    }
}

/// Incremental frame parser for one direction of the relay.
final class WSFrameReader {
    /// A single frame past this is treated as a broken stream.
    static let maxFrame = 64 * 1024 * 1024
    private var buffer = Data()
    private var head = 0
    private(set) var failed = false

    func feed(_ d: Data) { buffer.append(d) }

    func next() -> WSFrame? {
        guard !failed else { return nil }
        let avail = buffer.count - head
        guard avail >= 2 else { compact(); return nil }
        let b = buffer.startIndex + head
        let b0 = buffer[b], b1 = buffer[b + 1]
        var hdr = 2
        var len = Int(b1 & 0x7F)
        if len == 126 {
            guard avail >= 4 else { return nil }
            len = Int(buffer[b + 2]) << 8 | Int(buffer[b + 3])
            hdr = 4
        } else if len == 127 {
            guard avail >= 10 else { return nil }
            var l: UInt64 = 0
            for i in 0..<8 { l = l << 8 | UInt64(buffer[b + 2 + i]) }
            guard l <= UInt64(Self.maxFrame) else { failed = true; return nil }
            len = Int(l)
            hdr = 10
        }
        guard len <= Self.maxFrame else { failed = true; return nil }
        let masked = b1 & 0x80 != 0
        var key: [UInt8] = []
        if masked {
            guard avail >= hdr + 4 else { return nil }
            key = [buffer[b + hdr], buffer[b + hdr + 1], buffer[b + hdr + 2], buffer[b + hdr + 3]]
            hdr += 4
        }
        guard avail >= hdr + len else { return nil }
        let raw = buffer.subdata(in: b..<(b + hdr + len))
        var payload = buffer.subdata(in: (b + hdr)..<(b + hdr + len))
        if masked {
            payload.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) in
                let u = p.bindMemory(to: UInt8.self)
                for i in 0..<u.count { u[i] ^= key[i & 3] }
            }
        }
        head += hdr + len
        compact()
        return WSFrame(fin: b0 & 0x80 != 0, rsv: b0 & 0x70, opcode: b0 & 0x0F,
                       payload: payload, raw: raw)
    }

    private func compact() {
        if head == buffer.count { buffer.removeAll(keepingCapacity: true); head = 0 }
        else if head > 256 * 1024 { buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + head)); head = 0 }
    }
}

/// Reassembles fragmented data messages (control frames never reach it).
struct WSMessageAssembler {
    enum Result {
        case incomplete
        /// A whole message: its opcode, payload and the original frames.
        case complete(opcode: UInt8, payload: Data, raw: Data)
        /// Raw frames to forward as-is (a message too big to hold).
        case passthrough(Data)
        case protocolError
    }
    /// A message past this streams through unscanned.
    static let maxMessage = 32 * 1024 * 1024

    private var opcode: UInt8?
    private var payload = Data()
    private var raw = Data()
    private var streaming = false
    private(set) var oversized = 0

    mutating func add(_ f: WSFrame) -> Result {
        if f.opcode == 0 {
            guard opcode != nil || streaming else { return .protocolError }
        } else {
            guard opcode == nil, !streaming else { return .protocolError }
            opcode = f.opcode
        }
        if streaming {
            if f.fin { streaming = false; opcode = nil }
            return .passthrough(f.raw)
        }
        payload.append(f.payload)
        raw.append(f.raw)
        if payload.count > Self.maxMessage {
            oversized += 1
            let out = raw
            payload = Data(); raw = Data()
            if f.fin { opcode = nil } else { streaming = true }
            return .passthrough(out)
        }
        guard f.fin, let op = opcode else { return .incomplete }
        defer { opcode = nil; payload = Data(); raw = Data() }
        return .complete(opcode: op, payload: payload, raw: raw)
    }
}

// MARK: - Handshake

enum WSHandshake {
    /// The upgrade request without its `Sec-WebSocket-Extensions` header(s):
    /// the upstream then can't negotiate permessage-deflate (or any other
    /// extension), and its 101 — relayed to the client unchanged — doesn't
    /// list one either, so the client sends plain frames too.
    static func strippingExtensions(_ request: Data) -> (request: Data, stripped: [String]) {
        guard let end = request.range(of: Data("\r\n\r\n".utf8)) else { return (request, []) }
        let head = String(decoding: request.subdata(in: request.startIndex..<end.lowerBound), as: UTF8.self)
        var kept: [String] = []
        var stripped: [String] = []
        for line in head.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("sec-websocket-extensions:") {
                stripped.append(String(line.dropFirst("sec-websocket-extensions:".count))
                    .trimmingCharacters(in: .whitespaces))
            } else {
                kept.append(line)
            }
        }
        guard !stripped.isEmpty else { return (request, []) }
        var out = Data(kept.joined(separator: "\r\n").utf8)
        out.append(request.subdata(in: end.lowerBound..<request.endIndex))
        return (out, stripped)
    }

    /// The extensions a handshake response says are in use, or nil.
    static func extensions(inResponse response: Data) -> String? {
        let head = String(decoding: response, as: UTF8.self)
        for line in head.components(separatedBy: "\r\n")
        where line.lowercased().hasPrefix("sec-websocket-extensions:") {
            let v = line.dropFirst("sec-websocket-extensions:".count).trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { return v }
        }
        return nil
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

    private let restorer: PIIResponseRestorer

    init(host: String, path: String, profileID: UUID, vault: PIIVault,
         piiPolicy: @escaping @Sendable () -> PIIPolicy?,
         injectionPolicy: @escaping @Sendable () -> PromptInjectionPolicy?) {
        self.host = host
        self.path = path
        self.profileID = profileID
        self.vault = vault
        self.piiPolicy = piiPolicy
        self.injectionPolicy = injectionPolicy
        self.restorer = PIIResponseRestorer(vault: vault, contentType: "text/event-stream")
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
    static func make(host: String, path: String, profileID: UUID) -> WSContentGuard? {
        let h = host.lowercased()
        // The local-inference sentinel only when its engine is off this Mac
        // (a custom server elsewhere) — the on-device engine is exempt.
        guard HTTPMitmConnection.isAIHost(h), !h.contains("huggingface.co"),
              h != InferenceService.localMitmHost
                || PIIEngineScope.offMacEngineHost(profileID: profileID) != nil else { return nil }
        let piiOn = HTTPMitmConnection.piiPolicyProvider?(profileID)?.isActive ?? false
        let piOn = HTTPMitmConnection.promptInjectionPolicyProvider?(profileID)?.isActive ?? false
        guard piiOn || piOn else { return nil }
        let pid = profileID
        return WSContentGuard(
            host: host, path: path, profileID: profileID, vault: PIIVault.forProfile(profileID),
            piiPolicy: { HTTPMitmConnection.piiPolicyProvider?(pid) },
            injectionPolicy: { HTTPMitmConnection.promptInjectionPolicyProvider?(pid) })
    }

    // MARK: Client → model

    func client(_ payload: Data) async -> ClientVerdict {
        guard payload.first(where: { !Self.isSpace($0) }) == UInt8(ascii: "{") else { return .forward(nil) }
        let pi = injectionPolicy().flatMap { $0.isActive ? $0 : nil }
        let pii = piiPolicy().flatMap { $0.isActive ? $0 : nil }
        guard pi != nil || pii != nil else { return .forward(nil) }
        let type = Self.messageType(payload)
        // Tool output the user already blocked goes out as a placeholder
        // (the conversation is resent every turn), so the session goes on.
        var payload = payload
        var redacted = false
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

    /// The event the client gets instead of a reply. A Responses turn
    /// (`response.create`) fails with `response.failed` / `invalid_prompt` —
    /// a terminal, non-retryable error Codex shows the user (a generic error
    /// code would make it retry the same blocked turn). Anything else gets the
    /// realtime-style `error` event.
    static func blockEvent(_ f: PromptInjectionFlag, requestType: String?) -> Data {
        let message = "Bromure blocked this request: possible \(f.detector) detected in \(f.source)."
            + HTTPMitmConnection.injectionNextStep(detector: f.detector,
                                                   instructionsWithheld: !f.ruleSpans.isEmpty)
        let obj: [String: Any]
        if requestType == nil || requestType == "response.create" {
            obj = ["type": "response.failed",
                   "response": ["id": "resp_bromure_blocked", "object": "response",
                                "status": "failed", "output": [] as [Any],
                                "error": ["code": "invalid_prompt", "message": message]]]
        } else {
            obj = ["type": "error",
                   "error": ["type": "invalid_request_error", "code": "bromure_blocked",
                             "message": message]]
        }
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
    }

    // MARK: Model → client

    /// Restored payload(s) for one server message, or nil for "unchanged".
    /// Deltas go through the same restorer as the Responses SSE stream (one
    /// WS message = one SSE event), including its hold-back of a stand-in
    /// split across deltas — which may turn one message into none (held) or
    /// several (a released tail ahead of the closing event).
    func server(_ payload: Data) -> [Data]? {
        guard !vault.isEmpty,
              payload.first(where: { !Self.isSpace($0) }) == UInt8(ascii: "{") else { return nil }
        var compact = payload
        if payload.contains(0x0A) || payload.contains(0x0D) {
            // One SSE `data:` line: the event must be single-line JSON.
            guard let obj = try? JSONSerialization.jsonObject(with: payload),
                  let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])
            else { return nil }
            compact = d
        }
        let out = restorer.feed(Data("data: ".utf8) + compact + Data("\n\n".utf8))
        let messages = Self.sseData(out)
        return messages == [compact] && compact == payload ? nil : messages
    }

    /// Held text released when the server ends the stream.
    func serverFinish() -> [Data] {
        guard !vault.isEmpty else { return [] }
        return Self.sseData(restorer.finish())
    }

    // MARK: Helpers

    private static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }

    /// The `data:` payload of each SSE event in `out`.
    static func sseData(_ out: Data) -> [Data] {
        guard !out.isEmpty else { return [] }
        var result: [Data] = []
        for event in String(decoding: out, as: UTF8.self).components(separatedBy: "\n\n") {
            for line in event.components(separatedBy: "\n") where line.hasPrefix("data:") {
                var v = line.dropFirst(5)
                if v.first == " " { v = v.dropFirst() }
                result.append(Data(v.utf8))
            }
        }
        return result
    }

    /// The top-level `type` of a JSON message.
    static func messageType(_ payload: Data) -> String? {
        let b = [UInt8](payload)
        guard let refs = JSONStrings.scan(b) else { return nil }
        return refs.first { $0.key == "type" && $0.top == "type" }.map { JSONStrings.decode(b, $0.range) }
    }

    /// The message as the conversation parser reads it. A Responses turn is
    /// already a Responses body; a realtime `conversation.item.create` (one
    /// item — a user message, a function_call_output) reads as a one-item
    /// `input`.
    static func conversationBody(_ payload: Data, type: String?) -> Data {
        guard type == "conversation.item.create",
              let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let item = obj["item"] as? [String: Any],
              let d = try? JSONSerialization.data(withJSONObject: ["input": [item]]) else { return payload }
        return d
    }

    /// Does this client message carry conversation text (a Responses turn,
    /// a realtime item, a chat body)?
    static func carriesConversation(_ payload: Data) -> Bool {
        for k in ["\"input\"", "\"instructions\"", "\"item\"", "\"messages\"", "\"contents\""]
        where payload.range(of: Data(k.utf8)) != nil { return true }
        return false
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
            if Task.isCancelled { return }
            if !eof {
                drain: while true {
                    let outcome: StreamReadOutcome
                    do { outcome = try client.readNB() } catch { return }
                    switch outcome {
                    case .bytes(let d): onChunk(d); reader.feed(d)
                    case .wouldBlock: break drain
                    case .eof: eof = true; break drain
                    }
                }
            }
            while let f = reader.next() {
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
                    queue.append(f.rsv == 0 ? .message(opcode: op, payload: payload, raw: raw) : .raw(raw))
                case .protocolError:
                    FileHandle.standardError.write(Data("[mitm] WS \(g.host): bad client framing — closing\n".utf8))
                    return
                }
            }
            if reader.failed { return }
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
            if !flush(&out, to: upstream) { return }
            if eof && queue.isEmpty && inflight == nil { return }
            if eof {
                usleep(20_000)   // only a scan left to finish
                continue
            }
            var pfd = pollfd(fd: client.fd, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, inflight == nil ? 250 : 20) < 0 && errno != EINTR { return }
        }
    }

    static func upstreamToClient(upstream: Endpoint, client: Endpoint, guard g: WSContentGuard,
                                 inject: InjectQueue, onChunk: (Data) -> Void, onOut: (Data) -> Void) {
        let reader = WSFrameReader()
        var assembler = WSMessageAssembler()
        var out = Data()
        while true {
            if Task.isCancelled { return }
            var eof = false
            drain: while true {
                let outcome: StreamReadOutcome
                do { outcome = try upstream.readNB() } catch { return }
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
                    return
                }
            }
            if reader.failed { return }
            for d in inject.drain() { out.append(d) }
            if !out.isEmpty { onOut(out) }
            if !flush(&out, to: client) { return }
            if eof { return }
            var pfd = pollfd(fd: upstream.fd, events: Int16(POLLIN), revents: 0)
            if poll(&pfd, 1, 100) < 0 && errno != EINTR { return }
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
