import Foundation

// A guarded WebSocket's PII share of the content guard (WebSocketTransform
// .swift's WSContentGuard): the model's messages with their stand-ins put
// back, and the message type the client side reads. Shared with the Linux
// proxy.

/// A model → client message stream with PII stand-ins put back. Deltas go
/// through the same restorer as the Responses SSE stream (one WS message =
/// one SSE event), including its hold-back of a stand-in split across
/// deltas — which may turn one message into none (held) or several (a
/// released tail ahead of the closing event).
final class WSServerRestorer: @unchecked Sendable {
    let vault: PIIVault
    private let restorer: PIIResponseRestorer

    init(vault: PIIVault) {
        self.vault = vault
        self.restorer = PIIResponseRestorer(vault: vault, contentType: "text/event-stream")
    }

    /// Restored payload(s) for one server message, or nil for "unchanged".
    func restore(_ payload: Data) -> [Data]? {
        guard !vault.isEmpty,
              payload.first(where: { !WSMessages.isSpace($0) }) == UInt8(ascii: "{") else { return nil }
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
    func finish() -> [Data] {
        guard !vault.isEmpty else { return [] }
        return Self.sseData(restorer.finish())
    }

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
}

extension WSMessages {
    /// The top-level `type` of a JSON message.
    static func messageType(_ payload: Data) -> String? {
        let b = [UInt8](payload)
        guard let refs = JSONStrings.scan(b) else { return nil }
        return refs.first { $0.key == "type" && $0.top == "type" }.map { JSONStrings.decode(b, $0.range) }
    }

    static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }
}
