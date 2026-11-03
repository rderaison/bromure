import Compression
import Foundation

// MARK: - WebSocket client-message inspection (port of openshell-supervisor-
// network `l7/websocket.rs` and the extension negotiation in `l7/rest.rs`)
//
// On an OpenShell `protocol: websocket` route every client→server text
// message is judged before it's forwarded: as a `WEBSOCKET_TEXT` request
// against the route's endpoints, or — when the endpoint carries GraphQL
// operation policy — as a GraphQL-over-WebSocket operation. Frames are
// forwarded unchanged once their message is allowed; binary and control
// frames pass. Compression stays possible only as permessage-deflate with
// `client_no_context_takeover`, so each client message inflates on its own.

public enum OpenShellWebSocket {
    public static let maxTextMessageBytes = 4 * 1024 * 1024
    public static let maxRawFramePayloadBytes = 16 * 1024 * 1024

    // MARK: extension negotiation

    /// The `Sec-WebSocket-Extensions` value to forward in place of the
    /// client's (`supported_permessage_deflate_offer`): permessage-deflate
    /// with `client_no_context_takeover` (and optionally
    /// `server_no_context_takeover`) and no other parameter, else nothing.
    /// Malformed offers are a 400.
    public static func rewrittenExtensionOffer(_ values: [String]) -> Result<String?, OpenShellHTTP.Rejection> {
        func bad(_ m: String) -> Result<String?, OpenShellHTTP.Rejection> { .failure(.init(m)) }
        var offers: [(name: String, params: [(String, String?)])] = []
        for value in values {
            for ext in value.split(separator: ",", omittingEmptySubsequences: false) {
                var parts = ext.split(separator: ";", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard let name = parts.first, !name.isEmpty else { return bad("invalid WebSocket extension offer") }
                guard name.utf8.allSatisfy(OpenShellHTTP.isTokenByte) else { return bad("invalid WebSocket extension token") }
                parts.removeFirst()
                var params: [(String, String?)] = []
                for p in parts {
                    guard !p.isEmpty else { return bad("invalid WebSocket extension parameter") }
                    var pname = p, pvalue: String?
                    if let eq = p.firstIndex(of: "=") {
                        pname = p[..<eq].trimmingCharacters(in: .whitespaces)
                        let v = p[p.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                        guard !v.isEmpty, !v.hasPrefix("\""), v.utf8.allSatisfy(OpenShellHTTP.isTokenByte) else {
                            return bad("unsupported WebSocket extension parameter value")
                        }
                        pvalue = v
                    }
                    guard !pname.isEmpty, pname.utf8.allSatisfy(OpenShellHTTP.isTokenByte) else {
                        return bad("invalid WebSocket extension parameter")
                    }
                    params.append((pname, pvalue))
                }
                offers.append((name, params))
            }
        }
        for offer in offers where offer.name.lowercased() == "permessage-deflate" {
            var client = false, server = false, unsupported = false
            var seen = Set<String>()
            for (name, value) in offer.params {
                let n = name.lowercased()
                if value != nil || !seen.insert(n).inserted { unsupported = true; break }
                if n == "client_no_context_takeover" { client = true }
                else if n == "server_no_context_takeover" { server = true }
                else { unsupported = true; break }
            }
            if client, !unsupported {
                return .success("permessage-deflate; client_no_context_takeover" + (server ? "; server_no_context_takeover" : ""))
            }
        }
        return .success(nil)
    }

    /// Whether the server's 101 accepted permessage-deflate.
    public static func negotiatedCompression(responseHeader: String) -> Bool {
        responseHeader.components(separatedBy: "\r\n").contains { line in
            let l = line.lowercased()
            return l.hasPrefix("sec-websocket-extensions:") && l.contains("permessage-deflate")
        }
    }

    /// Inflate one permessage-deflate message (no context takeover).
    static func inflate(_ payload: Data) -> Result<Data, OpenShellHTTP.Rejection> {
        // The sync-flush tail, then an empty final stored block so the raw
        // DEFLATE stream is complete.
        var input = payload
        input.append(contentsOf: [0x00, 0x00, 0xff, 0xff, 0x01, 0x00, 0x00, 0xff, 0xff])
        let cap = maxTextMessageBytes + 1
        var out = Data(count: cap)
        let n = out.withUnsafeMutableBytes { dst in
            input.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, cap,
                                          src.bindMemory(to: UInt8.self).baseAddress!, input.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        if n == 0, !payload.isEmpty, payload != Data([0x00]), payload != Data([0x02, 0x00]) {
            return .failure(.init("websocket permessage-deflate decompression failed"))
        }
        if n >= cap { return .failure(.init("websocket text message exceeds \(maxTextMessageBytes) byte limit")) }
        return .success(out.prefix(n))
    }

    // MARK: client stream

    /// A network middleware's effect on one client text message.
    public enum MessageTransform: Equatable, Sendable {
        case unchanged
        case replaced(String)
        /// The middleware couldn't run; `failOpen` = forward unchanged.
        case failed(String, failOpen: Bool)
    }

    public enum MessageVerdict: Equatable, Sendable {
        case allow
        /// Logged; the message is forwarded (audit enforcement).
        case audit(String)
        /// The session ends with a 1008 close.
        case deny(String)
    }

    /// Streaming client→server frame inspector. `feed` returns the bytes that
    /// may be forwarded now; `stop` means the session must end (see
    /// `closeReason`, and the 1008 close frame to send the client).
    public final class ClientStream: @unchecked Sendable {
        private let compression: Bool
        private let decide: (String) -> MessageVerdict
        private let onAudit: (String) -> Void
        private let transform: ((String) -> MessageTransform)?
        private var buffer = Data()
        /// Raw frames of the text message being assembled (held back).
        private var heldFrames = Data()
        private var textPayload = Data()
        private var textCompressed = false
        private enum Fragment { case none, text, binary }
        private var fragment = Fragment.none
        /// Payload bytes still to pass through for a streamed binary frame.
        private var passthroughRemaining = 0
        public private(set) var closeReason: String?

        public init(compression: Bool, decide: @escaping (String) -> MessageVerdict,
                    onAudit: @escaping (String) -> Void = { _ in },
                    transform: ((String) -> MessageTransform)? = nil) {
            self.compression = compression
            self.decide = decide
            self.onAudit = onAudit
            self.transform = transform
        }

        public func feed(_ chunk: Data) -> (forward: Data, stop: Bool) {
            if closeReason != nil { return (Data(), true) }
            buffer.append(chunk)
            var out = Data()
            while true {
                if passthroughRemaining > 0 {
                    let n = min(passthroughRemaining, buffer.count)
                    guard n > 0 else { break }
                    out.append(buffer.prefix(n))
                    buffer.removeFirst(n)
                    passthroughRemaining -= n
                    continue
                }
                guard let h = Self.header(buffer) else { break }
                if let why = validate(h) { return fail(why, out) }
                let isData = h.opcode == 0x1 || h.opcode == 0x2 || h.opcode == 0x0
                let binary = h.opcode == 0x2 || (h.opcode == 0x0 && fragment == .binary)
                if binary {
                    // Stream binary frames through without buffering them.
                    out.append(buffer.prefix(h.headerLength))
                    buffer.removeFirst(h.headerLength)
                    passthroughRemaining = h.payloadLength
                    if h.opcode == 0x2 { fragment = h.fin ? .none : .binary }
                    else if h.fin { fragment = .none }
                    continue
                }
                guard buffer.count >= h.headerLength + h.payloadLength else { break }
                let frame = buffer.prefix(h.headerLength + h.payloadLength)
                var payload = Data(frame.suffix(h.payloadLength))
                if let key = h.maskKey {
                    for i in 0..<payload.count { payload[payload.startIndex + i] ^= key[i & 3] }
                }
                buffer.removeFirst(h.headerLength + h.payloadLength)
                guard isData else { out.append(frame); continue }          // control frame: passes
                // Text (start or continuation).
                if h.opcode == 0x1 { textCompressed = h.rsv1; fragment = .text }
                heldFrames.append(frame)
                textPayload.append(payload)
                if textPayload.count > OpenShellWebSocket.maxTextMessageBytes, !textCompressed {
                    return fail("websocket text message exceeds \(OpenShellWebSocket.maxTextMessageBytes) byte limit", out)
                }
                guard h.fin else { continue }
                fragment = .none
                var message = textPayload
                let frames = heldFrames
                textPayload = Data(); heldFrames = Data()
                if textCompressed {
                    switch OpenShellWebSocket.inflate(message) {
                    case .success(let d): message = d
                    case .failure(let why): return fail(why.reason, out)
                    }
                }
                guard let text = String(data: message, encoding: .utf8) else {
                    return fail("websocket text message is not valid UTF-8", out)
                }
                // Policy on the message as sent, then the middleware, then
                // policy again on whatever the middleware produced.
                switch decide(text) {
                case .allow: break
                case .audit(let why): onAudit(why)
                case .deny(let why): return fail(why, out)
                }
                switch transform?(text) ?? .unchanged {
                case .unchanged:
                    out.append(frames)
                case .failed(let why, let failOpen):
                    if !failOpen { return fail("middleware_failed: \(why)", out) }
                    out.append(frames)
                case .replaced(let replacement):
                    switch decide(replacement) {
                    case .allow: break
                    case .audit(let why): onAudit(why)
                    case .deny(let why): return fail(why, out)
                    }
                    out.append(Self.maskedTextFrame(replacement))
                }
            }
            return (out, false)
        }

        /// One FIN text frame (uncompressed; permessage-deflate is per message).
        static func maskedTextFrame(_ text: String) -> Data {
            let p = Array(text.utf8)
            var f: [UInt8] = [0x81]
            if p.count < 126 { f.append(0x80 | UInt8(p.count)) }
            else if p.count <= 0xFFFF { f += [0x80 | 126, UInt8(p.count >> 8), UInt8(p.count & 0xFF)] }
            else { f.append(0x80 | 127); for k in (0..<8).reversed() { f.append(UInt8((UInt64(p.count) >> (8 * UInt64(k))) & 0xFF)) } }
            let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
            f += mask
            f += p.enumerated().map { $0.element ^ mask[$0.offset & 3] }
            return Data(f)
        }

        private func fail(_ why: String, _ out: Data) -> (forward: Data, stop: Bool) {
            closeReason = why
            buffer = Data(); heldFrames = Data(); textPayload = Data()
            return (out, true)
        }

        private func validate(_ h: FrameHeader) -> String? {
            // RSV1 marks a compressed message: only on its first frame, only
            // when permessage-deflate was negotiated; RSV2/3 never.
            if h.rsv23 { return "websocket frame has unsupported RSV bits or extension state" }
            if h.rsv1, !(compression && (h.opcode == 0x1 || h.opcode == 0x2)) {
                return "websocket frame has unsupported RSV bits or extension state"
            }
            if h.maskKey == nil { return "websocket client frame is not masked" }
            guard [0x0, 0x1, 0x2, 0x8, 0x9, 0xA].contains(h.opcode) else { return "websocket frame uses reserved opcode" }
            if h.opcode >= 0x8 {
                if !h.fin { return "websocket control frame is fragmented" }
                if h.payloadLength > 125 { return "websocket control frame exceeds 125 bytes" }
            }
            if (h.opcode == 0x1 || h.opcode == 0x2), fragment != .none {
                return "websocket data frame started before previous fragmented message completed"
            }
            if h.opcode == 0x0, fragment == .none { return "websocket continuation frame without active fragmented message" }
            if (h.opcode == 0x2 || (h.opcode == 0x0 && fragment == .binary)), h.payloadLength > OpenShellWebSocket.maxRawFramePayloadBytes {
                return "websocket binary frame exceeds \(OpenShellWebSocket.maxRawFramePayloadBytes) byte relay limit"
            }
            if h.opcode == 0x1 || (h.opcode == 0x0 && fragment == .text), h.payloadLength > OpenShellWebSocket.maxTextMessageBytes {
                return "websocket text message exceeds \(OpenShellWebSocket.maxTextMessageBytes) byte limit"
            }
            return nil
        }

        struct FrameHeader {
            let fin: Bool, rsv1: Bool, rsv23: Bool, opcode: UInt8
            let maskKey: [UInt8]?, headerLength: Int, payloadLength: Int
        }

        static func header(_ b: Data) -> FrameHeader? {
            guard b.count >= 2 else { return nil }
            let s = b.startIndex
            let b0 = b[s], b1 = b[s + 1]
            var len = Int(b1 & 0x7F)
            var need = 2
            if len == 126 { need += 2 } else if len == 127 { need += 8 }
            let masked = b1 & 0x80 != 0
            if masked { need += 4 }
            guard b.count >= need else { return nil }
            if len == 126 {
                len = Int(b[s + 2]) << 8 | Int(b[s + 3])
            } else if len == 127 {
                var v: UInt64 = 0
                for k in 0..<8 { v = v << 8 | UInt64(b[s + 2 + k]) }
                len = v > UInt64(Int.max / 2) ? Int.max / 2 : Int(v)
            }
            let key = masked ? Array(b[(s + need - 4)..<(s + need)]) : nil
            return FrameHeader(fin: b0 & 0x80 != 0, rsv1: b0 & 0x40 != 0, rsv23: b0 & 0x30 != 0,
                               opcode: b0 & 0x0F, maskKey: key, headerLength: need, payloadLength: len)
        }
    }

    /// A server→client close frame (unmasked), 1008 "policy violation".
    public static func policyCloseFrame(reason: String) -> Data {
        var payload = Data([0x03, 0xF0])
        payload.append(Data(reason.utf8.prefix(120)))
        var f = Data([0x88, UInt8(payload.count)])
        f.append(payload)
        return f
    }
}

// MARK: - Per-message policy decision

extension OpenShellPolicy {
    enum GraphQLWebSocketMessage {
        case control(String)
        case operation(String, Result<[GraphQLRequestOp], GraphQLDocument.ParseError>)
    }

    /// `classify_graphql_websocket_message`.
    static func classifyGraphQLWebSocketMessage(_ text: String) -> GraphQLWebSocketMessage {
        func err(_ type: String, _ m: String) -> GraphQLWebSocketMessage { .operation(type, .failure(.init(message: m))) }
        guard let value = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else {
            return err("unknown", "GraphQL WebSocket message is not valid JSON")
        }
        guard let obj = value as? [String: Any] else { return err("unknown", "GraphQL WebSocket message must be a JSON object") }
        guard let type = obj["type"] as? String else { return err("unknown", "GraphQL WebSocket message missing string type") }
        switch type {
        case "subscribe", "start":
            guard let id = obj["id"] as? String, !id.isEmpty else {
                return err(type, "GraphQL WebSocket operation message missing non-empty id")
            }
            guard let payload = obj["payload"] as? [String: Any] else {
                return err(type, "GraphQL WebSocket operation message missing object payload")
            }
            return .operation(type, classifyGraphQLEnvelope(payload).map { [$0] })
        case "connection_init", "connection_terminate", "ping", "pong", "complete", "stop":
            return .control(type)
        default:
            return err(type, "unsupported GraphQL WebSocket client message type \"\(type)\"")
        }
    }

    /// Whether a WebSocket endpoint carries GraphQL operation policy
    /// (`endpoint_has_graphql_policy`).
    static func hasGraphQLPolicy(_ ep: Endpoint) -> Bool {
        !ep.gqlRules.isEmpty || !ep.gqlDenyRules.isEmpty || !ep.graphqlRegistry.isEmpty || ep.persistedQueriesAllowRegistered
    }

    /// Decide one client text message on a WebSocket upgraded at `target`
    /// (`inspect_websocket_text_message`). Malformed GraphQL-over-WebSocket
    /// messages are denied even under audit.
    public func websocketMessageDecision(host: String, port: UInt16, target: String, text: String,
                                         identity: BinaryIdentity? = nil,
                                         enforceBinaries: Bool = false) -> OpenShellWebSocket.MessageVerdict {
        var scoped = self
        if enforceBinaries { scoped.networkPolicies = networkPolicies.filter { $0.applies(to: identity, enforce: true) } }
        guard let route = scoped.routedEndpoint(host: host, port: port, target: target), route.primary.l7 == .websocket else {
            return .allow
        }
        let enforced = route.primary.enforcement == .enforce
        func verdict(_ d: RequestDecision) -> OpenShellWebSocket.MessageVerdict {
            guard case .violation(let why, _, let enf) = d else { return .allow }
            return enf ? .deny(why) : .audit(why)
        }
        guard Self.hasGraphQLPolicy(route.primary) else {
            return verdict(scoped.evaluateRequest(host: host, port: port, method: "WEBSOCKET_TEXT", target: target))
        }
        switch Self.classifyGraphQLWebSocketMessage(text) {
        case .control:
            return .allow
        case .operation(let type, .failure(let e)):
            return .deny("graphql_ws_type=\(type) GraphQL WebSocket message rejected: \(e.message)")
        case .operation(let type, .success(let ops)):
            let request = L7Request(method: "WEBSOCKET_TEXT", path: route.path, query: route.query,
                                    headers: [:], body: nil, bodyComplete: true)
            var firstDeny: String?
            var granted = false
            for ep in route.inspected {
                let v: EndpointVerdict
                if ep.l7 == .graphql || (ep.l7 == .websocket && Self.hasGraphQLPolicy(ep)) {
                    v = evaluateGraphQLOps(ops, ep)
                } else if ep.l7 == .rest || ep.l7 == .websocket {
                    v = evaluate(request, on: ep)
                } else {
                    continue
                }
                switch v {
                case .allow: granted = true
                case .deny(let why): if firstDeny == nil { firstDeny = why }
                case .hardDeny(let why): return .deny("graphql_ws_type=\(type) \(why)")
                case .notPermitted: break
                }
            }
            if let why = firstDeny { return enforced ? .deny("graphql_ws_type=\(type) \(why)") : .audit(why) }
            if granted { return .allow }
            let why = "graphql_ws_type=\(type) WEBSOCKET_TEXT \(route.path) not permitted by policy"
            return enforced ? .deny(why) : .audit(why)
        }
    }
}
