import Compression
import Foundation

/// RFC 6455 frame parser. Feed it raw bytes (plaintext, post-TLS) as
/// they arrive on one side of a MITM'd WebSocket; pull complete
/// frames out via `nextFrame()` until it returns nil. Stateful — the
/// parser holds whatever bytes it couldn't yet form into a frame.
///
/// Used only by the MITM tracing path; the proxy itself still pumps
/// raw bytes through opaquely. So a parse failure here can degrade
/// trace fidelity but cannot stall or corrupt the WS tunnel.
final class WSFrameDecoder {
    /// Application-level interpretation of one WebSocket frame.
    struct Frame {
        let fin: Bool
        /// RSV1 — when permessage-deflate is in effect, this bit on
        /// the *first* frame of a message means the payload (after
        /// concatenating continuations) is raw-deflate compressed.
        /// Continuation frames always carry RSV1=0; the message-
        /// level decision is made off the head frame.
        let rsv1: Bool
        let opcode: UInt8
        /// Already-unmasked payload — masking is symmetric so we
        /// strip it on the way in to keep transcripts readable.
        let payload: Data
    }

    private var buffer = Data()

    func feed(_ bytes: Data) {
        buffer.append(bytes)
    }

    /// Pull the next complete frame, or nil if the buffer doesn't
    /// have enough bytes yet. Caller loops until nil.
    func nextFrame() -> Frame? {
        guard buffer.count >= 2 else { return nil }
        let base = buffer.startIndex
        let b0 = buffer[base]
        let b1 = buffer[base + 1]
        let fin = (b0 & 0x80) != 0
        let rsv1 = (b0 & 0x40) != 0
        let opcode = b0 & 0x0F
        let masked = (b1 & 0x80) != 0
        let len7 = Int(b1 & 0x7F)

        var headerSize = 2
        var length = len7
        if len7 == 126 {
            guard buffer.count >= headerSize + 2 else { return nil }
            length = (Int(buffer[base + 2]) << 8) | Int(buffer[base + 3])
            headerSize += 2
        } else if len7 == 127 {
            guard buffer.count >= headerSize + 8 else { return nil }
            length = 0
            for i in 0..<8 {
                length = (length << 8) | Int(buffer[base + 2 + i])
            }
            headerSize += 8
        }

        // 64-bit lengths in the protocol; we cap at 64 MB per frame
        // to bound the trace's memory footprint. Anything bigger is
        // almost certainly garbage on the wire — drop the rest of the
        // buffer and signal end-of-stream by returning a synthetic
        // close-like marker the caller can ignore.
        if length < 0 || length > 64 * 1024 * 1024 {
            buffer.removeAll(keepingCapacity: false)
            return Frame(fin: true, rsv1: false, opcode: 0x8, payload: Data())
        }

        var maskKey: [UInt8] = []
        if masked {
            guard buffer.count >= headerSize + 4 else { return nil }
            maskKey.reserveCapacity(4)
            for i in 0..<4 {
                maskKey.append(buffer[base + headerSize + i])
            }
            headerSize += 4
        }

        guard buffer.count >= headerSize + length else { return nil }
        var payload = buffer.subdata(
            in: (base + headerSize)..<(base + headerSize + length)
        )
        if masked {
            // RFC 6455 §5.3: XOR each byte with mask[i % 4].
            payload.withUnsafeMutableBytes { raw in
                guard let p = raw.baseAddress else { return }
                for i in 0..<length {
                    p.storeBytes(of: p.load(fromByteOffset: i, as: UInt8.self) ^ maskKey[i % 4],
                                 toByteOffset: i, as: UInt8.self)
                }
            }
        }
        buffer.removeFirst(headerSize + length)
        return Frame(fin: fin, rsv1: rsv1, opcode: opcode, payload: payload)
    }
}

/// Inflater for RFC 7692 permessage-deflate. Apple's `COMPRESSION_ZLIB`
/// is RFC 1951 raw-DEFLATE (no zlib container) which matches what
/// permessage-deflate actually puts on the wire. RFC 7692 §7.2.2
/// requires appending the bytes `00 00 FF FF` to each *message*
/// before inflating — that's the deflate flush marker the sender
/// stripped off. With `noContextTakeover`, the LZ77 window is reset
/// between messages; otherwise context persists for cross-message
/// dictionary reuse.
final class WSInflater {
    private let stream: UnsafeMutablePointer<compression_stream>
    private var initialized = false
    private let noContextTakeover: Bool

    init(noContextTakeover: Bool) {
        self.noContextTakeover = noContextTakeover
        self.stream = .allocate(capacity: 1)
        // compression_stream_init writes into the struct; we don't
        // care about the field values prior to that call.
        let status = compression_stream_init(stream,
                                             COMPRESSION_STREAM_DECODE,
                                             COMPRESSION_ZLIB)
        initialized = (status == COMPRESSION_STATUS_OK)
    }

    deinit {
        if initialized { compression_stream_destroy(stream) }
        stream.deallocate()
    }

    /// Inflate one application-level message. Returns nil if the
    /// stream errored — the caller falls back to showing the raw
    /// (still-compressed) bytes so trace fidelity degrades rather
    /// than disappears.
    func inflate(_ compressed: Data) -> Data? {
        guard initialized else { return nil }

        // Append the deflate "empty block" trailer per RFC 7692.
        var input = compressed
        input.append(contentsOf: [0x00, 0x00, 0xFF, 0xFF])

        let bufSize = 32 * 1024
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buf.deallocate() }

        var output = Data()
        var ok = true
        input.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let inPtr = raw.bindMemory(to: UInt8.self).baseAddress else {
                ok = false; return
            }
            stream.pointee.src_ptr = inPtr
            stream.pointee.src_size = input.count

            // Loop until all input consumed AND the inflater drained.
            while true {
                stream.pointee.dst_ptr = buf
                stream.pointee.dst_size = bufSize
                let status = compression_stream_process(stream, 0)
                let written = bufSize - stream.pointee.dst_size
                if written > 0 {
                    output.append(buf, count: written)
                }
                if status == COMPRESSION_STATUS_ERROR {
                    ok = false
                    return
                }
                // 32 MB cap per message — anything past that is
                // either a runaway inflate or a deliberately
                // pathological compressed payload, and we don't
                // want to OOM the host.
                if output.count > 32 * 1024 * 1024 {
                    ok = false
                    return
                }
                if status == COMPRESSION_STATUS_END { break }
                if stream.pointee.src_size == 0 && stream.pointee.dst_size == bufSize {
                    // No more input and nothing produced → done.
                    break
                }
            }
        }

        if noContextTakeover {
            // Reset stream so the next message starts with a fresh
            // LZ77 dictionary, as the peer promised.
            compression_stream_destroy(stream)
            initialized = (compression_stream_init(stream,
                                                   COMPRESSION_STREAM_DECODE,
                                                   COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK)
        }

        return ok ? output : nil
    }
}

/// Parsed parameters from a `Sec-WebSocket-Extensions` response
/// header. Only present when the server confirmed permessage-deflate
/// — otherwise `nil` and the trace path skips inflation entirely.
struct WSDeflateParams {
    let serverNoContextTakeover: Bool
    let clientNoContextTakeover: Bool

    /// Parse the response handshake's extensions header. Returns nil
    /// when permessage-deflate isn't negotiated.
    static func parse(handshakeResponse: Data) -> WSDeflateParams? {
        guard let str = String(data: handshakeResponse, encoding: .ascii) else {
            return nil
        }
        for rawLine in str.split(separator: "\r\n") {
            let line = String(rawLine)
            let lower = line.lowercased()
            guard lower.hasPrefix("sec-websocket-extensions:") else { continue }
            // Only a "permessage-deflate" token enables the extension.
            // Other values (e.g. "x-webkit-deflate-frame") are not
            // RFC 7692 and would need different framing — treat as
            // unsupported rather than approximating.
            guard lower.contains("permessage-deflate") else { return nil }
            return WSDeflateParams(
                serverNoContextTakeover: lower.contains("server_no_context_takeover"),
                clientNoContextTakeover: lower.contains("client_no_context_takeover"))
        }
        return nil
    }
}

/// One application-level WebSocket message (after defragmenting
/// continuation frames) or one control frame, with the direction and
/// arrival timestamp recorded for transcript ordering.
struct WSMessage: Sendable {
    enum Direction: String, Sendable {
        case clientToUpstream  // VM → OpenAI
        case upstreamToClient  // OpenAI → VM
    }
    enum Kind: String, Sendable {
        case text, binary, close, ping, pong, unknown
    }
    let direction: Direction
    let timestamp: Date
    let kind: Kind
    /// Truncated to `WSTraceCollector.perMessageCap`; `truncated`
    /// flags whether bytes were dropped.
    let payload: Data
    let truncated: Bool
    /// Original payload size before truncation. Useful in the
    /// transcript header so the user sees real frame sizes.
    let totalBytes: Int
}

/// Holds the per-direction defragmenting state plus an array of
/// completed messages. Two of these (one per direction) are owned by
/// the WS-upgrade handler — each pump task touches only its own
/// instance, so no locking is needed during the bidirectional pump.
final class WSTraceCollector: @unchecked Sendable {
    /// 1 MB per inflated message. Was 32 KB which silently truncated
    /// codex's response.create payload mid-JSON (instructions +
    /// conversation history regularly clears 60 KB before deflate),
    /// leaving the conversation parser with malformed JSON it
    /// couldn't parse. The transcript-level guard is `maxMessages`
    /// below, plus the proxy's overall body cap upstream.
    static let perMessageCap = 1 * 1024 * 1024
    static let maxMessages   = 4096

    private let direction: WSMessage.Direction
    private let decoder = WSFrameDecoder()
    private let inflater: WSInflater?
    private var pendingKind: WSMessage.Kind?
    /// Concatenated *raw* payload bytes for the in-progress message.
    /// Capped at perMessageCap when no inflater is active; when
    /// permessage-deflate is in use we keep the full compressed
    /// bytes (bounded by the inflater's own per-message cap) because
    /// truncating compressed input mid-block makes inflate fail.
    private var pendingPayload = Data()
    private var pendingTotal = 0
    /// RSV1 of the head frame — when the inflater is set, this
    /// determines whether to inflate before recording the message.
    private var pendingCompressed = false

    private(set) var messages: [WSMessage] = []

    /// Per-message hook fired as soon as a complete frame is assembled
    /// (data frames after defragment + inflate; control frames
    /// directly). Used by the proxy to emit BAC `llm.request` /
    /// `tool.use` events incrementally during long-lived OpenAI
    /// Realtime sessions, instead of only at WS close.
    /// Set once at construction; not synchronised — the owning Task
    /// is the only writer.
    var onMessage: (@Sendable (WSMessage) -> Void)?

    init(direction: WSMessage.Direction, inflater: WSInflater? = nil) {
        self.direction = direction
        self.inflater = inflater
    }

    /// Feed a chunk of bytes. Internally parses frames, defragments
    /// continuations, and appends complete messages. Returns the
    /// number of *application* bytes (sum of all frame payloads,
    /// including continuations) seen in this chunk — the caller adds
    /// these to its byte counters.
    @discardableResult
    func feed(_ bytes: Data) -> Int {
        decoder.feed(bytes)
        var appBytes = 0
        while let frame = decoder.nextFrame() {
            appBytes += frame.payload.count
            handle(frame: frame)
            if messages.count >= Self.maxMessages { break }
        }
        return appBytes
    }

    private func handle(frame: WSFrameDecoder.Frame) {
        switch frame.opcode {
        case 0x0:  // continuation
            extendPending(with: frame.payload)
            if frame.fin { flushPending() }
        case 0x1:  // text
            beginPending(kind: .text, first: frame.payload, rsv1: frame.rsv1)
            if frame.fin { flushPending() }
        case 0x2:  // binary
            beginPending(kind: .binary, first: frame.payload, rsv1: frame.rsv1)
            if frame.fin { flushPending() }
        case 0x8:  // close
            emitControl(.close, payload: frame.payload)
        case 0x9:  // ping
            emitControl(.ping, payload: frame.payload)
        case 0xA:  // pong
            emitControl(.pong, payload: frame.payload)
        default:
            emitControl(.unknown, payload: frame.payload)
        }
    }

    private func beginPending(kind: WSMessage.Kind, first: Data, rsv1: Bool) {
        // Per spec a non-FIN data frame must not interrupt another
        // fragmented message. If we see one anyway, treat the
        // previous fragments as a truncated message and start fresh.
        if pendingKind != nil { flushPending() }
        pendingKind = kind
        pendingCompressed = rsv1 && (inflater != nil)
        pendingPayload = pendingCompressed ? first : takePreview(first)
        pendingTotal = first.count
    }

    private func extendPending(with payload: Data) {
        guard pendingKind != nil else {
            // Continuation without a starting frame — bogus stream;
            // record as binary control so it's visible in the trace.
            emitControl(.unknown, payload: payload)
            return
        }
        pendingTotal += payload.count
        if pendingCompressed {
            // Keep the full compressed payload — inflate after FIN.
            pendingPayload.append(payload)
        } else {
            let remaining = Self.perMessageCap - pendingPayload.count
            if remaining > 0 {
                pendingPayload.append(payload.prefix(remaining))
            }
        }
    }

    private func flushPending() {
        guard let kind = pendingKind else { return }

        // If the message was permessage-deflate compressed, inflate
        // before truncation/preview — running the preview cap on
        // compressed input mid-block would corrupt it.
        var payload = pendingPayload
        if pendingCompressed, let inflater {
            if let inflated = inflater.inflate(payload) {
                payload = inflated.count > Self.perMessageCap
                    ? inflated.prefix(Self.perMessageCap)
                    : inflated
            }
            // On inflate failure: fall through with the still-
            // compressed bytes so the user sees something rather
            // than an empty record. The "looks like text?" branch
            // in the renderer will fall back to hex.
        }

        let truncated = pendingTotal > payload.count
        let msg = WSMessage(
            direction: direction,
            timestamp: Date(),
            kind: kind,
            payload: payload,
            truncated: truncated,
            totalBytes: pendingTotal)
        messages.append(msg)
        onMessage?(msg)
        pendingKind = nil
        pendingPayload = Data()
        pendingTotal = 0
        pendingCompressed = false
    }

    private func emitControl(_ kind: WSMessage.Kind, payload: Data) {
        let preview = takePreview(payload)
        let msg = WSMessage(
            direction: direction,
            timestamp: Date(),
            kind: kind,
            payload: preview,
            truncated: payload.count > preview.count,
            totalBytes: payload.count)
        messages.append(msg)
        onMessage?(msg)
    }

    private func takePreview(_ data: Data) -> Data {
        return data.count <= Self.perMessageCap
            ? data
            : data.prefix(Self.perMessageCap)
    }
}

/// Render two collectors into a single chronologically-ordered text
/// transcript. The output goes after the upstream's handshake
/// response (separated by a blank line) so the existing trace body
/// pipeline serves it as the response body.
enum WSTranscriptRenderer {
    static func render(c2u: WSTraceCollector, u2c: WSTraceCollector) -> Data {
        var all = c2u.messages + u2c.messages
        all.sort { $0.timestamp < $1.timestamp }

        var out = Data()
        out.append(Data("--- WebSocket session transcript ---\n".utf8))
        if all.isEmpty {
            out.append(Data("(no application frames observed before close)\n".utf8))
            return out
        }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for m in all {
            let arrow = m.direction == .clientToUpstream ? ">>>" : "<<<"
            let truncMark = m.truncated ? " (truncated, total \(m.totalBytes) bytes)" : ""
            let header = "\(arrow) [\(fmt.string(from: m.timestamp))] " +
                         "\(m.kind.rawValue.uppercased()) \(m.totalBytes)B\(truncMark)\n"
            out.append(Data(header.utf8))
            switch m.kind {
            case .text:
                appendAsValidUTF8(m.payload, to: &out)
            case .binary, .unknown, .ping, .pong:
                // OpenAI's responses_websockets protocol carries
                // JSON, sometimes in binary frames. Try UTF-8 first
                // so the inspector can render it; only fall back to
                // hex if the payload genuinely isn't text.
                if looksLikeText(m.payload) {
                    appendAsValidUTF8(m.payload, to: &out)
                } else {
                    let hex = m.payload.prefix(256).map { String(format: "%02x", $0) }.joined()
                    out.append(Data((hex + "\n").utf8))
                }
            case .close:
                // Close payload format (when present): 2-byte BE code
                // followed by optional UTF-8 reason. Render readable.
                if m.payload.count >= 2 {
                    let code = (UInt16(m.payload[m.payload.startIndex]) << 8)
                             | UInt16(m.payload[m.payload.startIndex + 1])
                    let reason = m.payload.count > 2
                        ? String(data: m.payload.subdata(in: (m.payload.startIndex + 2)..<m.payload.endIndex),
                                 encoding: .utf8) ?? ""
                        : ""
                    let line = "code=\(code) \"\(reason)\"\n"
                    out.append(Data(line.utf8))
                } else {
                    out.append(Data("(empty close payload)\n".utf8))
                }
            }
        }
        return out
    }

    /// Decode `data` as UTF-8 with U+FFFD replacement for invalid
    /// sequences (the same fallback `String(decoding:as:)` does), so
    /// any payload appended to the transcript is guaranteed-valid
    /// UTF-8. Required because the inspector decodes the *whole*
    /// body as UTF-8 — a single bad byte from a mid-codepoint
    /// truncation would cause the entire transcript to render as
    /// "(binary N bytes)".
    static func appendAsValidUTF8(_ data: Data, to out: inout Data) {
        let s = String(decoding: data, as: UTF8.self)
        out.append(Data(s.utf8))
        if !data.last.map({ $0 == 0x0A }).intoBool() {
            out.append(0x0A)
        }
    }

    /// Heuristic for "decode this as text instead of hex". Mostly
    /// printable ASCII / UTF-8 ⇒ text. Used for binary-opcode frames
    /// because OpenAI's responses_websockets puts JSON in binary
    /// frames (after deflate, post-inflate the payload is JSON).
    static func looksLikeText(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        let sample = data.prefix(2048)
        var nonText = 0
        for byte in sample {
            // Tab, LF, CR, plus any byte 0x20+. Below 0x20 = control.
            if byte == 0x09 || byte == 0x0A || byte == 0x0D || byte >= 0x20 {
                continue
            }
            nonText += 1
        }
        // Allow up to 5% control bytes — JSON shouldn't have any,
        // but we don't want a one-off NUL to flip the whole frame
        // to hex.
        return nonText * 20 < sample.count
    }
}

/// Tiny helper: `Optional<Bool>?.intoBool()` returns false on nil so
/// callers don't have to spell out `?? false` inline.
private extension Optional where Wrapped == Bool {
    func intoBool() -> Bool { self ?? false }
}
