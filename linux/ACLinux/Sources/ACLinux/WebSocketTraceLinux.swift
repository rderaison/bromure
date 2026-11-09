import NIOConcurrencyHelpers
import NIOCore
import Foundation

/// A switched WebSocket's trace on the Linux proxy (macOS:
/// handleWebSocketUpgrade's collectors, then emitWebSocketTrace): both
/// directions' messages, inflated when permessage-deflate is in use and
/// bodies are captured, rendered into one transcript at the close; the
/// realtime tap reads the server's messages as they come. The server's side
/// is what the guest got (its values restored), as macOS's onClientOut.
/// Fed from the connection's event loop, which only copies and counts: the
/// parsing, inflating, the tap and the rendering run on the session's own
/// queue, in order (macOS: the pump's threads).
// @port-skip linux-only: the Linux proxy's share of handleWebSocketUpgrade (collectors, byte counts)
final class WSTraceSession: @unchecked Sendable {
    let handshake: Data
    private let c2u: WSTraceCollector?
    private let u2c: WSTraceCollector?
    let tap: RealtimeEventTap?
    private(set) var clientBytes = 0
    private(set) var upstreamBytes = 0
    private let work = DispatchQueue(label: "io.bromure.ac.ws-trace", qos: .utility)
    /// Bytes handed to `work` and not yet read: past `maxQueued` (a socket
    /// faster than its trace) they're dropped and counted, and the
    /// transcript says where it has a gap.
    private let queued = NIOLockedValueBox(0)
    private let dropped = NIOLockedValueBox(0)
    private let maxQueued: Int

    /// Whether the messages are read at all (bodies captured): else only
    /// byte counts, and nothing is copied.
    // @port-skip linux-only: see WSTraceSession
    var captures: Bool { u2c != nil }

    // @port-skip linux-only: see WSTraceSession
    init(handshake: Data, host: String, path: String, profileID: UUID, captureBody: Bool, maxQueued: Int = 64 << 20) {
        self.handshake = handshake
        self.maxQueued = maxQueued
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
        guard let c2u, !bytes.isEmpty else { return }
        enqueue(bytes) { c2u.feed(bytes) }
    }

    /// The guest's bytes as NIO read them: copied only when captured.
    // @port-skip linux-only: see WSTraceSession
    func client(_ buffer: ByteBuffer) {
        guard captures else { clientBytes += buffer.readableBytes; return }
        client(Data(buffer.readableBytesView))
    }

    /// The upstream's bytes after its 101, counted as they came.
    // @port-skip linux-only: see WSTraceSession
    func upstream(count: Int) { upstreamBytes += count }

    /// What the guest got from the server side (restored, with any injected
    /// event), as it went out.
    // @port-skip linux-only: see WSTraceSession
    func toGuest(_ bytes: Data) {
        guard let u2c, !bytes.isEmpty else { return }
        enqueue(bytes) { u2c.feed(bytes) }
    }

    /// What went to the guest as NIO holds it: copied only when captured.
    // @port-skip linux-only: see WSTraceSession
    func toGuest(_ buffer: ByteBuffer) {
        guard captures, buffer.readableBytes > 0 else { return }
        toGuest(Data(buffer.readableBytesView))
    }

    /// `feed` on the queue, unless too much already waits there.
    // @port-skip linux-only: see WSTraceSession
    private func enqueue(_ bytes: Data, _ feed: @escaping @Sendable () -> Void) {
        let n = bytes.count
        let room = queued.withLockedValue { q -> Bool in
            guard q + n <= self.maxQueued else { return false }
            q += n
            return true
        }
        guard room else { dropped.withLockedValue { $0 += n }; return }
        work.async { [queued] in
            feed()
            queued.withLockedValue { $0 -= n }
        }
    }

    /// Both directions as one text (nil without body capture), once every
    /// byte fed so far is read: on the session's queue.
    // @port-skip linux-only: see WSTraceSession
    func finish(_ done: @escaping @Sendable (Data?, Bool) -> Void) {
        let c2u = c2u, u2c = u2c, tap = tap, dropped = dropped
        work.async {
            var transcript = (c2u != nil && u2c != nil) ? WSTranscriptRenderer.render(c2u: c2u!, u2c: u2c!) : nil
            let gap = dropped.withLockedValue { $0 }
            if gap > 0 {
                // The trace fell behind the socket: what it didn't read is said.
                transcript?.append(Data("\n[\(gap) bytes of this WebSocket not traced: the trace fell behind]\n".utf8))
            }
            done(transcript, tap?.streamedAnyEvents ?? false)
        }
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
