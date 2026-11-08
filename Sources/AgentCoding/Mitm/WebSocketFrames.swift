import Foundation

// The WebSocket frame layer and the content guard's pure message helpers
// (WebSocketTransform.swift's), shared with the Linux proxy.

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
        let key = secureRandomBytes(4)
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

// MARK: - Messages

/// The content guard's message helpers (WSContentGuard forwards here).
enum WSMessages {
    /// The event the client gets instead of a reply. A Responses turn
    /// (`response.create`) fails with `response.failed` / `invalid_prompt` —
    /// a terminal, non-retryable error Codex shows the user (a generic error
    /// code would make it retry the same blocked turn). Anything else gets the
    /// realtime-style `error` event.
    static func blockEvent(_ f: PromptInjectionFlag, requestType: String?) -> Data {
        let message = "Bromure blocked this request: possible \(f.detector) detected in \(f.source)."
            + ProxyPolicy.injectionNextStep(detector: f.detector,
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
