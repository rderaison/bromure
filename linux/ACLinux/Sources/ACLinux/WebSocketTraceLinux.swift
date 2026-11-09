import Foundation

/// A switched WebSocket's trace on the Linux proxy (macOS:
/// handleWebSocketUpgrade's collectors, then emitWebSocketTrace): both
/// directions' messages, inflated when permessage-deflate is in use and
/// bodies are captured, rendered into one transcript at the close; the
/// realtime tap reads the server's messages as they come. Fed on the
/// connection's event loop (the guest's and the upstream's channels share it).
// @port-skip linux-only: the Linux proxy's share of handleWebSocketUpgrade (collectors, byte counts)
final class WSTraceSession {
    let handshake: Data
    private let c2u: WSTraceCollector?
    private let u2c: WSTraceCollector?
    let tap: RealtimeEventTap?
    private(set) var clientBytes = 0
    private(set) var upstreamBytes = 0

    // @port-skip linux-only: see WSTraceSession
    init(handshake: Data, host: String, path: String, profileID: UUID, captureBody: Bool) {
        self.handshake = handshake
        let deflate = WSDeflateParams.parse(handshakeResponse: handshake)
        // Only a body-capturing trace reads the messages (and the realtime
        // tap with them): elsewhere the per-frame work is wasted.
        tap = captureBody ? RealtimeEventTap(profileID: profileID, host: host, path: path, statusCode: 101) : nil
        c2u = captureBody
            ? WSTraceCollector(direction: .clientToUpstream,
                               inflater: deflate.map { WSInflater(noContextTakeover: $0.clientNoContextTakeover) })
            : nil
        u2c = captureBody
            ? WSTraceCollector(direction: .upstreamToClient,
                               inflater: deflate.map { WSInflater(noContextTakeover: $0.serverNoContextTakeover) },
                               deliverCap: tap != nil ? WSMessageAssembler.maxMessage : WSTraceCollector.perMessageCap)
            : nil
        if let tap { u2c?.onMessage = { tap.handle($0) } }
    }

    /// The guest's bytes after the switch, as it sent them.
    // @port-skip linux-only: see WSTraceSession
    func client(_ bytes: Data) {
        clientBytes += bytes.count
        c2u?.feed(bytes)
    }

    /// The upstream's bytes after its 101, as they came.
    // @port-skip linux-only: see WSTraceSession
    func upstream(_ bytes: Data) {
        upstreamBytes += bytes.count
        u2c?.feed(bytes)
    }

    /// Both directions as one text, or nil without body capture.
    // @port-skip linux-only: see WSTraceSession
    var transcript: Data? {
        guard let c2u, let u2c else { return nil }
        return WSTranscriptRenderer.render(c2u: c2u, u2c: u2c)
    }
}

extension TraceEmitter {
    /// A WebSocket's trace record at its close: the handshake and the
    /// transcript as one response body, the conversation parsed from it (its
    /// cloud events too, unless the realtime tap already streamed them).
    /// The token-swap events went out when the upgrade was forwarded
    /// (RequestReader.rewrite), as for every request on the Linux proxy.
    // partial: the swap events go out at forwarding on Linux (macOS: here, before the trace gate)
    // @port HTTPMitmConnection.emitWebSocketTrace(host: String, port: Int, preSwapRequest: Data, handshakeResponse: Data, transcript: Data?, clientBytes: Int, upstreamBytes: Int, statusCode: Int, swaps: [SwapRecord], leaks: [LeakEntry], latencyMs: Double, skipLLMExtract: Bool) h=61385580f81ea870 @285807ef
    static func emitWebSocket(session: TraceSession?, store: TraceStore, profileID: UUID,
                              host: String, port: Int,
                              preSwapRequest: Data,
                              handshakeResponse: Data,
                              transcript: Data?,
                              clientBytes: Int,
                              upstreamBytes: Int,
                              statusCode: Int,
                              swaps: [SwapRecord],
                              leaks: [LeakEntry],
                              latencyMs: Double,
                              skipLLMExtract: Bool = false) {
        guard let session, session.level.recordsActivity else { return }
        let (method, path) = HTTPFrames.parseRequestLine(preSwapRequest)
        let captureBody = session.level.capturesBodyForHost(host)
        let bodyStored = captureBody && (transcript != nil || !preSwapRequest.isEmpty)

        // Handshake + transcript: the inspector renders both as one text.
        var responseBlob = handshakeResponse
        if captureBody, let t = transcript {
            if responseBlob.range(of: Data("\r\n\r\n".utf8)) == nil { responseBlob.append(Data("\r\n\r\n".utf8)) }
            responseBlob.append(t)
        }
        let conversation: Conversation? = (captureBody && transcript != nil)
            ? ConversationParser.parse(host: host, requestBody: preSwapRequest, responseBody: responseBlob)
            : nil
        if let conv = conversation, !skipLLMExtract {
            LLMEventExtractor.emit(profileID: profileID, host: host, path: path, statusCode: statusCode,
                                   latencyMs: latencyMs, responseBody: responseBlob, conversation: conv)
        }
        let record = TraceRecord(
            sessionID: session.sessionID,
            profileID: profileID,
            host: host, port: port,
            method: method, path: path,
            statusCode: statusCode,
            requestBytes: clientBytes,
            responseBytes: upstreamBytes,
            latencyMs: latencyMs,
            swaps: swaps.map { SwapEntry(header: "Authorization/x-api-key", fakePreview: $0.fakePreview, realPreview: $0.realPreview) },
            leaks: leaks,
            bodyStored: bodyStored,
            isConversation: conversation != nil
        )
        // The same redaction as the HTTP path: auth-bearing headers of both
        // handshakes scrubbed before the store.
        let req = captureBody ? HTTPFrames.redactSensitiveHeaders(preSwapRequest) : nil
        let res = captureBody ? HTTPFrames.redactSensitiveHeaders(responseBlob) : nil
        store.record(record, requestBody: req, responseBody: res)
    }
}
