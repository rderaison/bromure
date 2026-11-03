import Foundation

// A proxied request's trace record -- the Trace Inspector's rows, their
// (redacted, text-only) bodies, the conversation they carry and the cloud
// events it yields -- on any host's proxy: HTTPMitmConnection (macOS) and
// the Linux server's.

enum TraceEmitter {
    /// Build + record the TraceRecord. Body capture decision is made
    /// here so the proxy hot path doesn't pay the cost when traces
    /// are off. Runs on the connection's Task — no main-actor hop
    /// for the body files (TraceStore.queue handles them off-thread).
    /// `onConversation`: the host's own look at a parsed conversation.
    static func emit(session: TraceSession?, store: TraceStore, profileID: UUID,
                     host: String, port: Int,
                     preSwapRequest: Data,
                     upstreamResponse: Data,
                     upstreamWireBytes: Int,
                     responseTruncated: Bool,
                     swaps: [SwapRecord],
                     leaks: [LeakEntry],
                     latencyMs: Double,
                     servedBy: String? = nil,
                     onConversation: ((Conversation) -> Void)? = nil) async {
        guard let session, session.level.recordsActivity else { return }
        let traceT0 = Date()
        BACDebug.log("[mitm/trace]",
                     "emit start host=\(host) reqBytes=\(preSwapRequest.count) respBytes=\(upstreamResponse.count) truncated=\(responseTruncated)")
        defer {
            BACDebug.log("[mitm/trace]",
                         "emit done host=\(host) total=\(BACDebug.ms(traceT0))")
        }

        // Parse the request line for the trace.
        let (method, path) = HTTPFrames.parseRequestLine(preSwapRequest)
        let statusCode = HTTPFrames.parseStatusCode(upstreamResponse)

        let captureBody = session.level.capturesBodyForHost(host)
        // Truncated responses are deliberately not stored as bodies —
        // a partial dialogue would mislead the inspector. The trace
        // record still carries accurate `responseBytes`, just no body
        // file for the response side.
        let canStoreResponseBody = captureBody && !responseTruncated
        let bodyStored = (captureBody && !preSwapRequest.isEmpty)
            || (canStoreResponseBody && !upstreamResponse.isEmpty)

        // Cheap eager parse — we still have the bodies in memory at
        // this point (no decrypt round-trip) and the parser short-
        // circuits fast on non-AI hosts. Lets the inspector's
        // "Conversations only" filter be a true boolean check
        // instead of "host is AI" approximation. Skip when the
        // response was truncated; running the conversation parser on
        // a partial SSE stream would misclassify.
        //
        // Side benefit: when the parse succeeds we hand the
        // Conversation to the cloud event extractor so admins see
        // structured `llm.request` / `tool.use` / `file.*` /
        // `command.run` events even though the recording was for the
        // local trace inspector. The extractor only emits when the
        // Mac is enrolled with bromure.io.
        let parseT0 = Date()
        BACDebug.log("[mitm/trace]",
                     "convparse start host=\(host) gated=\(bodyStored && !responseTruncated) bodyStored=\(bodyStored) responseTruncated=\(responseTruncated)")
        let conversation: Conversation? = (bodyStored && !responseTruncated)
            ? ConversationParser.parse(host: host,
                                       requestBody: preSwapRequest,
                                       responseBody: upstreamResponse)
            : nil
        let isConversation = (conversation != nil)
        BACDebug.log("[mitm/trace]",
                     "convparse done host=\(host) isConv=\(isConversation) took=\(BACDebug.ms(parseT0))")
        if let conv = conversation {
            let extractT0 = Date()
            BACDebug.log("[mitm/trace]",
                         "llmextract start host=\(host) provider=\(conv.provider.rawValue) messages=\(conv.messages.count)")
            LLMEventExtractor.emit(
                profileID: profileID,
                host: host, path: path,
                statusCode: statusCode,
                latencyMs: latencyMs,
                responseBody: upstreamResponse,
                conversation: conv)
            BACDebug.log("[mitm/trace]",
                         "llmextract done host=\(host) took=\(BACDebug.ms(extractT0))")

            // The host's own look at the conversation (macOS: the
            // prompt-injection "log" scan).
            onConversation?(conv)
        }
        // Audit trail for credential.token_swap: every fake → real
        // substitution that just left the VM. One event per swap so
        // the admin UI can list "AI authenticated as <token name>
        // against <host>". Previews only — real values stay in
        // memory; the server would never see the secret bytes.
        if !swaps.isEmpty {
            BACDebug.log("[mitm/trace]", "swap-events emit count=\(swaps.count) host=\(host)")
        }
        for s in swaps {
            BACEventEmitter.shared.emitDetached(
                profileID: profileID,
                eventType: "credential.token_swap",
                eventData: [
                    "host": .string(host),
                    "path": .string(path),
                    "fake_preview": .string(s.fakePreview),
                    "real_preview": .string(s.realPreview),
                ])
        }

        let record = TraceRecord(
            sessionID: session.sessionID,
            profileID: profileID,
            host: host, port: port,
            method: method, path: path,
            statusCode: statusCode,
            requestBytes: preSwapRequest.count,
            responseBytes: upstreamWireBytes,
            latencyMs: latencyMs,
            swaps: swaps.map { SwapEntry(header: "Authorization/x-api-key",
                                         fakePreview: $0.fakePreview,
                                         realPreview: $0.realPreview) },
            leaks: leaks,
            bodyStored: bodyStored,
            isConversation: isConversation,
            servedBy: servedBy
        )

        // At every level above .activity, skip bodies that look like
        // binary downloads (images, video, audio, archives, octet-
        // stream, etc.) — they consume the per-session body cap fast
        // and their decoded form isn't useful in the inspector. Text
        // bodies (json, html, xml, plain, js, css, form, sse) are kept.
        //
        // Auth-bearing headers (Authorization, Proxy-Authorization,
        // *-api-key, Cookie, Set-Cookie) are redacted before the body
        // is handed to the trace store. The swap log already records
        // a previewed token; storing the full secret in the body
        // file would defeat the encrypted-at-rest guarantee.
        let req = captureBody
            ? HTTPFrames.bodyForTrace(preSwapRequest).map { HTTPFrames.redactSensitiveHeaders($0) }
            : nil
        let res = canStoreResponseBody
            ? HTTPFrames.bodyForTrace(upstreamResponse).map { HTTPFrames.redactSensitiveHeaders($0) }
            : nil
        let storeT0 = Date()
        BACDebug.log("[mitm/trace]",
                     "store.record hop->main start host=\(host) reqBodyBytes=\(req?.count ?? 0) resBodyBytes=\(res?.count ?? 0)")
        await MainActor.run {
            store.record(record, requestBody: req, responseBody: res)
        }
        BACDebug.log("[mitm/trace]",
                     "store.record hop->main done host=\(host) took=\(BACDebug.ms(storeT0))")
    }
}

/// Reading and redacting raw HTTP/1.1 frames, for the trace and the proxy.
enum HTTPFrames {
    /// Rewrite the headers of an HTTP frame so any header on the
    /// `sensitiveHeaders` list has its value replaced with
    /// `<redacted>`. Body bytes are passed through unchanged. If the
    /// frame doesn't have a CRLF-CRLF separator, returns the input
    /// unchanged.
    static func redactSensitiveHeaders(_ raw: Data) -> Data {
        guard let endRange = raw.range(of: Data("\r\n\r\n".utf8)) else { return raw }
        let headerData = raw.subdata(in: 0..<endRange.lowerBound)
        let bodyData   = raw.subdata(in: endRange.lowerBound..<raw.count)
        // Latin-1: a non-ASCII header byte must not skip redaction (the old
        // `.ascii` decode returned the frame unredacted on any such byte).
        guard let headerStr = String(data: headerData, encoding: .isoLatin1) else { return raw }

        var lines = headerStr.components(separatedBy: "\r\n")
        for i in lines.indices {
            let line = lines[i]
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            if Self.isSensitiveHeader(name) {
                lines[i] = String(line[..<colon]) + ": <redacted>"
            }
        }
        let rebuilt = lines.joined(separator: "\r\n")
        var out = Data()
        let rebuiltBytes = rebuilt.data(using: .isoLatin1) ?? Data(rebuilt.utf8)
        out.reserveCapacity(rebuiltBytes.count + bodyData.count)
        out.append(rebuiltBytes)
        out.append(bodyData)
        return out
    }

    static func isSensitiveHeader(_ lowered: String) -> Bool {
        if lowered == "authorization"
            || lowered == "proxy-authorization"
            || lowered == "cookie"
            || lowered == "set-cookie"
            || lowered == "x-amz-security-token"
            || lowered == "x-goog-iap-jwt-assertion" {
            return true
        }
        // `x-api-key`, `anthropic-api-key`, `openai-api-key`, and the
        // catch-all `*-api-key` / `api-key` pattern all carry secrets.
        if lowered == "api-key" || lowered.hasSuffix("-api-key") {
            return true
        }
        return false
    }

    /// Returns the original buffer iff the parsed Content-Type looks
    /// like text (or there's no Content-Type at all — rare, treated
    /// as benign), and iff total size is under a per-record cap.
    /// Otherwise returns nil so the caller skips the body write.
    static func bodyForTrace(_ raw: Data) -> Data? {
        // Per-record cap. Anything bigger is a download / upload that
        // would fill the session-cap on its own.
        let perRecordCap = 5 * 1024 * 1024
        guard raw.count <= perRecordCap else { return nil }
        guard !raw.isEmpty else { return nil }
        guard let endRange = raw.range(of: Data("\r\n\r\n".utf8)) else {
            // No header/body split — not a normal HTTP frame, but still
            // small enough to keep.
            return raw
        }
        let header = raw.subdata(in: 0..<endRange.lowerBound)
        guard let headerStr = String(data: header, encoding: .isoLatin1) else {
            return raw
        }
        let lines = headerStr.split(separator: "\r\n")
        let ctLine = lines.first(where: { $0.lowercased().hasPrefix("content-type:") })
        let ct: String = ctLine.flatMap {
            $0.split(separator: ":", maxSplits: 1).last
                .map { String($0).trimmingCharacters(in: .whitespaces).lowercased() }
        } ?? ""
        if ct.isEmpty { return raw }
        // Whitelist: anything we'd want to read in the inspector.
        let textPrefixes = [
            "text/", "application/json", "application/xml",
            "application/javascript", "application/x-www-form-urlencoded",
            "application/x-ndjson", "application/ld+json",
            "application/graphql", "application/yaml", "application/x-yaml",
            "application/problem+json",
            "multipart/form-data",  // small forms; large uploads gated by perRecordCap
        ]
        if textPrefixes.contains(where: { ct.hasPrefix($0) }) { return raw }
        // application/* with a +json or +xml suffix (RFC 6839)
        if ct.hasPrefix("application/") && (ct.contains("+json") || ct.contains("+xml")) {
            return raw
        }
        // Server-Sent Events
        if ct.hasPrefix("text/event-stream") { return raw }
        return nil
    }

    /// Pull "GET /foo HTTP/1.1" → ("GET", "/foo").
    ///
    /// Only the request-line bytes (up to the first CRLF) are decoded. The
    /// old code decoded the whole 8 KB prefix — headers AND the start of the
    /// body — as ASCII, so one UTF-8 byte in a body ("héllo", "—", emoji)
    /// turned the method into "?" and silently bypassed every method-gated
    /// protection (firewall `web` verb rules, PII, guardrails) — B35.
    /// Latin-1 maps every byte, so the decode itself can never fail.
    static func parseRequestLine(_ raw: Data) -> (method: String, path: String) {
        let window = raw.prefix(8 * 1024)
        return parseRequestLineWindow(window)
    }

    static func parseRequestLineWindow(_ window: Data) -> (method: String, path: String) {
        guard let lineEnd = window.range(of: Data("\r\n".utf8)) else {
            return ("?", "/")
        }
        let lineBytes = window[window.startIndex..<lineEnd.lowerBound]
        guard let line = String(data: lineBytes, encoding: .isoLatin1) else {
            return ("?", "/")
        }
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return ("?", "/") }
        return (String(parts[0]), String(parts[1]))
    }

    /// Pull "HTTP/1.1 200 OK" → 200.
    static func parseStatusCode(_ raw: Data) -> Int {
        guard let str = String(data: raw.prefix(64), encoding: .isoLatin1),
              let lineEnd = str.range(of: "\r\n") else { return 0 }
        let line = str[..<lineEnd.lowerBound]
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let n = Int(parts[1]) else { return 0 }
        return n
    }
}
