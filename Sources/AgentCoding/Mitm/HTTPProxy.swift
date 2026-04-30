import Foundation
@preconcurrency import Virtualization

/// One MITM connection's lifetime: read CONNECT, send 200, terminate
/// TLS with a forged leaf cert, read the wrapped HTTP request, swap
/// tokens, fire to upstream, stream response back.
///
/// Each call to `run()` handles exactly one tunnel. We don't bother
/// with HTTP/1.1 pipelining or keep-alive within a CONNECT — the cost
/// of a fresh CONNECT per request is negligible at agent traffic
/// volumes, and it keeps the state machine sane.
@available(macOS, deprecated: 10.15, message: "owns a TLSServerStream which wraps SecureTransport")
final class HTTPMitmConnection: @unchecked Sendable {
    let fd: Int32
    let profileID: UUID
    let certCache: CertCache
    let swapper: TokenSwapper
    let awsResigner: AWSResigner
    let traceStore: TraceStore
    let clientIdentities: ClientIdentityRegistry
    let clusterCAs: ClusterCATrustRegistry
    let consent: ConsentBroker
    let sessionTraceProvider: @Sendable () -> MitmEngine.SessionTrace?
    /// Fired when the proxy sees a clean Anthropic subscription OAuth
    /// access token in an outbound request. The host wires this to
    /// `SubscriptionTokenCoordinator.handleCleanAccessToken` which
    /// throttles per-profile and presents the consent sheet.
    let subscriptionTokenSeen: (@Sendable (UUID, String) -> Void)?
    /// Codex / ChatGPT counterpart: fires when a clean JWT-shaped
    /// access token is seen on chatgpt.com / openai.com.
    let codexTokenSeen: (@Sendable (UUID, String) -> Void)?
    /// Fires after a successful `/oauth/token` response rewrite — the
    /// host uses this to keep `Profile.default*Tokens` and the
    /// preferences template in sync with whatever the upstream just
    /// rotated to. nil = host doesn't care.
    let oauthRotated: (@Sendable (UUID, OAuthRotationProvider, StoredOAuthTokens) -> Void)?

    init(fd: Int32, profileID: UUID, certCache: CertCache, swapper: TokenSwapper,
         awsResigner: AWSResigner,
         traceStore: TraceStore,
         clientIdentities: ClientIdentityRegistry,
         clusterCAs: ClusterCATrustRegistry,
         consent: ConsentBroker,
         sessionTraceProvider: @escaping @Sendable () -> MitmEngine.SessionTrace?,
         subscriptionTokenSeen: (@Sendable (UUID, String) -> Void)? = nil,
         codexTokenSeen: (@Sendable (UUID, String) -> Void)? = nil,
         oauthRotated: (@Sendable (UUID, OAuthRotationProvider, StoredOAuthTokens) -> Void)? = nil) {
        self.fd = fd
        self.profileID = profileID
        self.certCache = certCache
        self.swapper = swapper
        self.awsResigner = awsResigner
        self.traceStore = traceStore
        self.clientIdentities = clientIdentities
        self.clusterCAs = clusterCAs
        self.consent = consent
        self.sessionTraceProvider = sessionTraceProvider
        self.subscriptionTokenSeen = subscriptionTokenSeen
        self.codexTokenSeen = codexTokenSeen
        self.oauthRotated = oauthRotated
    }

    /// Drives the full MITM exchange. Must be called from a Task —
    /// uses blocking syscalls under the hood. Closes the FD on exit
    /// regardless of success.
    func run() async {
        defer { close(fd) }
        do {
            try await drive()
        } catch {
            FileHandle.standardError.write(Data("[mitm] \(error)\n".utf8))
        }
    }

    private func drive() async throws {
        let t0 = Date()

        // 1. CONNECT request from client (proxy command). Treat as
        //    ASCII — proxy headers don't legally carry non-ASCII.
        let connectReq = try readRawHTTPRequest(plainFD: fd, maxBytes: 16 * 1024)
        guard let asString = String(data: connectReq, encoding: .ascii),
              let lineEnd = asString.range(of: "\r\n") else {
            throw MitmError.malformedHTTPRequest
        }
        let firstLine = asString[..<lineEnd.lowerBound]
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "CONNECT" else {
            throw MitmError.malformedHTTPRequest
        }
        let target = String(parts[1])
        let (host, port) = parseHostPort(target)

        // 2. Confirm the tunnel.
        try writeAll(fd: fd, bytes: Array("HTTP/1.1 200 Connection established\r\n\r\n".utf8))

        // 3. Server-side TLS using the cached forged leaf cert for `host`.
        let identity = try certCache.identity(for: host)
        let tls = try TLSServerStream(fd: fd, identity: identity)
        try tls.handshake()

        // 4. Read the wrapped HTTP request through TLS.
        let request = try readRawHTTPRequest(via: tls, maxBytes: 8 * 1024 * 1024)

        // Pre-swap: scan for unswapped Bearer / x-api-key tokens. The
        // trace store records these as `LeakEntry` values so the user
        // sees exactly which secrets escaped the swap pipeline.
        let leaks = swapper.detectLeaks(in: request, profileID: profileID)

        // Aho-Corasick scan over headers + body for any fake token
        // bound for a host outside the scope the fake was minted for.
        // A fake should never appear on the wire to a third-party
        // host: the VM only ever holds fakes, and the swap path
        // strictly substitutes them on their designated domain. If
        // one slips out elsewhere, the VM is exfiltrating — abort
        // the upstream call and let the engine's compromise handler
        // pause + alert.
        let compromise = swapper.detectCompromise(
            rawRequest: request, host: host, profileID: profileID)
        if !compromise.isEmpty {
            for c in compromise {
                FileHandle.standardError.write(Data(
                    "[mitm] COMPROMISE \(c.fakeTokenPreview) (declared \(c.declaredHost)) → \(c.observedHost)\n".utf8))
            }
            // Reply to the in-VM client with a plain 451; the agent
            // sees a hard failure rather than a hung connection. We
            // never forward a single byte to the destination host
            // when a leak fires.
            let body = "Bromure: outbound request blocked — leaked credential to non-designated host.\n"
            var resp = "HTTP/1.1 451 Unavailable For Legal Reasons\r\n"
            resp += "Content-Type: text/plain; charset=utf-8\r\n"
            resp += "Content-Length: \(body.utf8.count)\r\n"
            resp += "Connection: close\r\n\r\n"
            resp += body
            try? tls.write(Data(resp.utf8))
            return
        }

        // 5. Swap tokens. host param is the SNI name; entries that
        //    don't match are no-ops.
        let swap = await swapper.swap(rawRequest: request, host: host, profileID: profileID)
        if !swap.swaps.isEmpty {
            for s in swap.swaps {
                FileHandle.standardError.write(Data(
                    "[mitm] swapped \(s.fakePreview) → \(s.realPreview) on \(s.host)\n".utf8))
            }
        }
        for leak in leaks {
            FileHandle.standardError.write(Data(
                "[mitm] LEAK \(leak.header)=\(leak.valuePreview) on \(host) (\(leak.suspicion.rawValue))\n".utf8))
        }

        // Subscription-token swap: clean `sk-ant-oat01-…` going out to
        // anthropic.com? Surface to the coordinator so it can prompt
        // (once per session per profile). The hook is fire-and-forget:
        // we still forward the request as-is; the swap kicks in on the
        // *next* outbound request once the user accepts.
        if host == "api.anthropic.com" || host.hasSuffix(".anthropic.com") {
            if let cleanToken = swapper.detectSubscriptionAccessToken(
                in: swap.modified, profileID: profileID) {
                subscriptionTokenSeen?(profileID, cleanToken)
            }
        }
        // Codex / ChatGPT subscription-token swap. Codex CLI auths
        // against chatgpt.com (browser flow) and refreshes against
        // auth.openai.com — same JWT shape on the wire.
        if host == "chatgpt.com" || host.hasSuffix(".chatgpt.com")
            || host == "auth.openai.com"
            || host == "api.openai.com" {
            if let cleanToken = swapper.detectCodexAccessToken(
                in: swap.modified, profileID: profileID) {
                codexTokenSeen?(profileID, cleanToken)
            }
        }

        // 6a. WebSocket upgrade — bypass URLSession (which can't
        //     surface the 101 + raw bidirectional byte stream) and
        //     do a manual TLS-client connect + opaque pump. Used by
        //     OpenAI's Realtime API and any other agent transport
        //     that rides on WS instead of plain HTTP/SSE.
        if isWebSocketUpgrade(rawRequest: swap.modified) {
            FileHandle.standardError.write(Data(
                "[mitm] WebSocket upgrade → \(host):\(port)\n".utf8))
            // Decide body capture *before* the pump so we don't pay
            // frame-parsing cost when the user has tracing off.
            let captureBody = sessionTraceProvider()?
                .level.capturesBodyForHost(host) ?? false
            // Streaming event tap: extracts BAC events from
            // `response.completed` server frames as they arrive, so
            // long-lived OpenAI Realtime sessions don't wait until WS
            // close to surface activity. Only attached when we're
            // already capturing bodies on this host (managed AI
            // hosts) — otherwise the per-frame JSON parse is wasted
            // work for raw passthrough WebSockets.
            let (_, reqPath) = Self.parseRequestLine(swap.modified)
            let realtimeTap: RealtimeEventTap? = captureBody
                ? RealtimeEventTap(
                    profileID: profileID,
                    host: host,
                    path: reqPath,
                    statusCode: 101)
                : nil
            let result = try await handleWebSocketUpgrade(
                serverTLS: tls,
                rawRequest: swap.modified,
                host: host, port: port,
                captureBody: captureBody,
                onUpstreamMessage: realtimeTap.map { tap in
                    { @Sendable msg in tap.handle(msg) }
                })
            let elapsed = Date().timeIntervalSince(t0) * 1000
            let streamedAny = realtimeTap?.streamedAnyEvents ?? false
            if streamedAny {
                BACDebug.log("[mitm/wsTrace]",
                             "skip close-time llmextract (streamed=\(realtimeTap?.streamedResponseCount ?? 0)) host=\(host)")
            }
            await emitWebSocketTrace(host: host, port: port,
                                     preSwapRequest: request,
                                     handshakeResponse: result.handshakeResponse,
                                     transcript: result.transcript,
                                     clientBytes: result.clientBytes,
                                     upstreamBytes: result.upstreamBytes,
                                     statusCode: result.statusCode,
                                     swaps: swap.swaps,
                                     leaks: leaks,
                                     latencyMs: elapsed,
                                     skipLLMExtract: streamedAny)
            return
        }

        // 6b. AWS resign. No-op for non-AWS hosts. For AWS hosts, the
        //     guest's SDK has signed with a fake secret vended by
        //     `AWSCredentialServer`; we strip that signature and
        //     replace it with one computed from the real material on
        //     the host. Denial / unsupported features short-circuit
        //     with a response written straight back to the guest, so
        //     the SDK gets a meaningful HTTP error rather than an
        //     opaque InvalidSignatureException after a round-trip.
        let toForward: Data
        let resignOutcome = await awsResigner.resign(
            rawRequest: swap.modified, host: host, profileID: profileID)
        switch resignOutcome {
        case .unchanged:
            toForward = swap.modified
        case .resigned(let bytes):
            toForward = bytes
        case .denied(let response):
            try tls.write(response)
            let elapsed = Date().timeIntervalSince(t0) * 1000
            await emitTrace(host: host, port: port,
                            preSwapRequest: request,
                            upstreamResponse: response,
                            upstreamWireBytes: response.count,
                            responseTruncated: false,
                            swaps: swap.swaps,
                            leaks: leaks,
                            latencyMs: elapsed)
            return
        case .failed(let reason, let response):
            FileHandle.standardError.write(Data(
                "[mitm] AWS resign failed for \(host): \(reason)\n".utf8))
            try tls.write(response)
            let elapsed = Date().timeIntervalSince(t0) * 1000
            await emitTrace(host: host, port: port,
                            preSwapRequest: request,
                            upstreamResponse: response,
                            upstreamWireBytes: response.count,
                            responseTruncated: false,
                            swaps: swap.swaps,
                            leaks: leaks,
                            latencyMs: elapsed)
            return
        }

        // 6c. Stream the upstream response back to the guest via the
        //     same TLS server stream. `relayUpstream` writes chunks
        //     to `tls` as URLSession's delegate hands them over, so
        //     SSE / Bedrock eventstream / long-poll endpoints reach
        //     the guest in real time. The returned Data is the full
        //     captured response — only used for the trace record;
        //     the wire write already happened inside relayUpstream.
        //     The session's delegate looks up the profile's per-host
        //     SecIdentity (Kubernetes API server et al.) when the
        //     upstream challenges for a client cert.
        let session = upstreamSession(for: host)
        // URLSession strong-refs its delegate until invalidated (per
        // Apple's docs). Without this `defer`, every MITM connection
        // leaks one URLSession + one ClientCertChallengeDelegate
        // (which transitively retains the per-profile identity / CA /
        // consent registries) for the rest of the process lifetime —
        // visible as a steady RSS climb on long-running sessions.
        // `finishTasksAndInvalidate` lets the in-flight request
        // complete normally, then breaks the retain cycle.
        defer { session.finishTasksAndInvalidate() }

        // OAuth rotation: when this is a refresh request on a token
        // endpoint we know about, hold the response (don't stream) so
        // the OAuthRotationRewriter can replace the new access /
        // refresh / id tokens in the body before the VM sees them.
        // Streaming would be too late — the SDK would write the real
        // values to disk before our rewrite could fire.
        let (_, refreshPath) = Self.parseRequestLine(toForward)
        let oauthProvider = OAuthRotationRewriter.provider(
            for: host, path: refreshPath)
        let relay: RelayResponse
        if let provider = oauthProvider {
            let rotatedHook = self.oauthRotated
            relay = try await relayUpstreamBuffered(
                rawRequest: toForward,
                host: host, port: port,
                session: session,
                tls: tls,
                rewrite: { [profileID, swapper] raw in
                    let result = OAuthRotationRewriter.rewrite(
                        raw: raw, provider: provider,
                        profileID: profileID, swapper: swapper)
                    if let newReals = result.newReals {
                        rotatedHook?(profileID, provider, newReals)
                    }
                    return result.bytes
                })
        } else {
            relay = try await relayUpstream(rawRequest: toForward,
                                            host: host, port: port,
                                            session: session,
                                            tls: tls)
        }

        // 7. Trace. Build a TraceRecord from what we observed and
        //    hand it to the engine's TraceStore. Body capture is
        //    gated by the per-session level + host allowlist.
        let elapsed = Date().timeIntervalSince(t0) * 1000
        await emitTrace(host: host, port: port,
                        preSwapRequest: request,
                        upstreamResponse: relay.buffer,
                        upstreamWireBytes: relay.wireBytes,
                        responseTruncated: relay.truncatedForTrace,
                        swaps: swap.swaps,
                        leaks: leaks,
                        latencyMs: elapsed)
    }

    /// True iff the request contains the HTTP/1.1 upgrade tokens for
    /// WebSocket. Both `Upgrade: websocket` and a `Connection` header
    /// listing `Upgrade` are required by RFC 6455 — but in practice
    /// either is enough to know we should *not* hand this to URLSession.
    private func isWebSocketUpgrade(rawRequest: Data) -> Bool {
        guard let endRange = rawRequest.range(of: Data("\r\n\r\n".utf8)),
              let headerStr = String(data: rawRequest.subdata(in: 0..<endRange.lowerBound),
                                     encoding: .ascii) else {
            return false
        }
        var sawUpgrade = false
        var sawConnectionUpgrade = false
        for line in headerStr.split(separator: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("upgrade:") && lower.contains("websocket") {
                sawUpgrade = true
            }
            if lower.hasPrefix("connection:") && lower.contains("upgrade") {
                sawConnectionUpgrade = true
            }
        }
        return sawUpgrade || sawConnectionUpgrade
    }

    /// Result of the WebSocket-upgrade fast-path. Populated whether
    /// or not the upstream actually switched protocols, so the
    /// caller can emit a meaningful trace for failed upgrades too.
    struct WebSocketResult {
        /// Raw upstream response headers (the 101 line + headers, or
        /// whatever upstream sent if the upgrade was rejected).
        var handshakeResponse: Data
        /// Rendered text transcript of frames seen, or nil when the
        /// caller asked for no body capture.
        var transcript: Data?
        /// Total plaintext bytes the VM sent to upstream (handshake +
        /// every WebSocket frame's full wire size). The frame-level
        /// counter sums *application* payload bytes; here we report
        /// the wire-level total since that's what users think of as
        /// "data sent".
        var clientBytes: Int
        var upstreamBytes: Int
        var statusCode: Int
    }

    /// Open a TLS connection to upstream, replay the (already token-
    /// swapped) request bytes verbatim, then bidirectionally pump
    /// every byte that follows. When `captureBody` is true, also
    /// parse RFC 6455 frames in both directions and accumulate a
    /// chronological transcript that the caller renders into the
    /// trace's response body.
    private func handleWebSocketUpgrade(serverTLS: TLSServerStream,
                                        rawRequest: Data,
                                        host: String, port: Int,
                                        captureBody: Bool,
                                        onUpstreamMessage: (@Sendable (WSMessage) -> Void)? = nil) async throws -> WebSocketResult {
        let upstreamFD = try connectTCP(host: host, port: port)
        let upstreamTLS: TLSClientStream
        do {
            upstreamTLS = try TLSClientStream(fd: upstreamFD, peerName: host)
            try upstreamTLS.handshake()
        } catch {
            close(upstreamFD)
            throw error
        }
        defer { close(upstreamFD) }

        // Forward the upgrade request as-is. URLSession's hop-by-hop
        // header strip would have eaten Upgrade/Connection — that's
        // exactly why we bypass it here.
        try upstreamTLS.write(rawRequest)
        var clientBytes = rawRequest.count

        // Read the response headers (everything up to the first blank
        // line) and forward them to the client. We don't care about
        // status: even a 4xx/5xx upgrade refusal should be relayed
        // verbatim so the client sees the real failure.
        let respHeaders = try readUntilDoubleCRLF(via: upstreamTLS,
                                                  maxBytes: 64 * 1024)
        try serverTLS.write(respHeaders)
        var upstreamBytes = respHeaders.count
        let statusCode = parseStatusCode(rawHeaders: respHeaders)

        // If upstream didn't switch protocols, drain any trailing
        // response body so the client sees the full upstream
        // message, then return — there's no frame stream to trace.
        guard statusCode == 101 else {
            for _ in 0..<8 {
                let chunk = (try? upstreamTLS.read(maxBytes: 16 * 1024)) ?? Data()
                if chunk.isEmpty { break }
                upstreamBytes += chunk.count
                try? serverTLS.write(chunk)
            }
            return WebSocketResult(handshakeResponse: respHeaders,
                                   transcript: nil,
                                   clientBytes: clientBytes,
                                   upstreamBytes: upstreamBytes,
                                   statusCode: statusCode)
        }

        // Per-direction byte counters + (optional) frame collectors.
        // The collectors are class instances so each child task can
        // mutate its own without locking; we only read them after
        // the pump completes, and never share a single instance
        // across both tasks.
        let counters = WSByteCounters()
        // permessage-deflate (RFC 7692) is what codex+OpenAI almost
        // always negotiate. Without inflating, every text frame
        // looks like binary garbage in the trace and the inspector
        // falls back to "(binary N bytes)".
        let deflate = WSDeflateParams.parse(handshakeResponse: respHeaders)
        if deflate != nil {
            FileHandle.standardError.write(Data(
                "[mitm] WebSocket negotiated permessage-deflate on \(host)\n".utf8))
        }
        let c2uInflater = (captureBody && deflate != nil)
            ? WSInflater(noContextTakeover: deflate!.clientNoContextTakeover) : nil
        let u2cInflater = (captureBody && deflate != nil)
            ? WSInflater(noContextTakeover: deflate!.serverNoContextTakeover) : nil
        let c2uCollector = captureBody
            ? WSTraceCollector(direction: .clientToUpstream, inflater: c2uInflater) : nil
        let u2cCollector = captureBody
            ? WSTraceCollector(direction: .upstreamToClient, inflater: u2cInflater) : nil
        u2cCollector?.onMessage = onUpstreamMessage

        await withTaskGroup(of: Void.self) { group in
            let server = serverTLS
            let upstream = upstreamTLS
            group.addTask {
                while true {
                    let chunk: Data
                    do { chunk = try server.read(maxBytes: 16 * 1024) }
                    catch { return }
                    if chunk.isEmpty { return }
                    counters.addClient(chunk.count)
                    c2uCollector?.feed(chunk)
                    do { try upstream.write(chunk) }
                    catch { return }
                }
            }
            group.addTask {
                while true {
                    let chunk: Data
                    do { chunk = try upstream.read(maxBytes: 16 * 1024) }
                    catch { return }
                    if chunk.isEmpty { return }
                    counters.addUpstream(chunk.count)
                    u2cCollector?.feed(chunk)
                    do { try server.write(chunk) }
                    catch { return }
                }
            }
            await group.next()
            group.cancelAll()
        }

        clientBytes  += counters.client
        upstreamBytes += counters.upstream

        let transcript: Data?
        if let c2u = c2uCollector, let u2c = u2cCollector {
            transcript = WSTranscriptRenderer.render(c2u: c2u, u2c: u2c)
        } else {
            transcript = nil
        }
        return WebSocketResult(handshakeResponse: respHeaders,
                               transcript: transcript,
                               clientBytes: clientBytes,
                               upstreamBytes: upstreamBytes,
                               statusCode: statusCode)
    }

    /// Emit a TraceRecord for a finished WebSocket session. Builds a
    /// synthetic response body that is the upstream's handshake
    /// response followed (after the standard CRLFCRLF separator) by
    /// the rendered frame transcript, so the inspector's existing
    /// body-display path serves it without any new code path.
    private func emitWebSocketTrace(host: String, port: Int,
                                    preSwapRequest: Data,
                                    handshakeResponse: Data,
                                    transcript: Data?,
                                    clientBytes: Int,
                                    upstreamBytes: Int,
                                    statusCode: Int,
                                    swaps: [SwapRecord],
                                    leaks: [LeakEntry],
                                    latencyMs: Double,
                                    skipLLMExtract: Bool = false) async {
        guard let session = sessionTraceProvider(),
              session.level.recordsActivity else { return }

        let (method, path) = Self.parseRequestLine(preSwapRequest)
        let captureBody = session.level.capturesBodyForHost(host)
        let bodyStored = captureBody && (transcript != nil || !preSwapRequest.isEmpty)

        // Compose the response body: handshake + transcript so the
        // inspector renders both as one continuous text blob.
        var responseBlob = handshakeResponse
        if captureBody, let t = transcript {
            if responseBlob.range(of: Data("\r\n\r\n".utf8)) == nil {
                responseBlob.append(Data("\r\n\r\n".utf8))
            }
            responseBlob.append(t)
        }

        // Try the conversation parser on the synthesized bodies so
        // the inspector can render the chat view (set the
        // `isConversation` flag at record-time, like the regular
        // HTTP path does). Re-use the Conversation for the cloud
        // event extractor when the parse succeeds.
        let wsParseT0 = Date()
        BACDebug.log("[mitm/wsTrace]",
                     "convparse start host=\(host) gated=\(captureBody && transcript != nil)")
        let conversation: Conversation? = (captureBody && transcript != nil)
            ? ConversationParser.parse(host: host,
                                       requestBody: preSwapRequest,
                                       responseBody: responseBlob)
            : nil
        let isConversation = (conversation != nil)
        BACDebug.log("[mitm/wsTrace]",
                     "convparse done host=\(host) isConv=\(isConversation) took=\(BACDebug.ms(wsParseT0))")
        if let conv = conversation, !skipLLMExtract {
            let wsExtractT0 = Date()
            BACDebug.log("[mitm/wsTrace]",
                         "llmextract start host=\(host) provider=\(conv.provider.rawValue)")
            LLMEventExtractor.emit(
                profileID: profileID,
                host: host, path: path,
                statusCode: statusCode,
                latencyMs: latencyMs,
                responseBody: responseBlob,
                conversation: conv)
            BACDebug.log("[mitm/wsTrace]",
                         "llmextract done host=\(host) took=\(BACDebug.ms(wsExtractT0))")
        }
        // Audit trail for credential.token_swap on the WS path —
        // mirror the HTTP-emit hook above.
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
            requestBytes: clientBytes,
            responseBytes: upstreamBytes,
            latencyMs: latencyMs,
            swaps: swaps.map { SwapEntry(header: "Authorization/x-api-key",
                                         fakePreview: $0.fakePreview,
                                         realPreview: $0.realPreview) },
            leaks: leaks,
            bodyStored: bodyStored,
            isConversation: isConversation
        )

        let store = traceStore
        // Same redaction as the regular HTTP path: scrub auth-bearing
        // headers from both the request handshake and the response
        // handshake before they hit the trace store.
        let req = captureBody ? Self.redactSensitiveHeaders(preSwapRequest) : nil
        let res = captureBody ? Self.redactSensitiveHeaders(responseBlob) : nil
        await MainActor.run {
            store.record(record, requestBody: req, responseBody: res)
        }
    }

    /// Pull the numeric status code out of a raw response header
    /// blob ("HTTP/1.1 101 Switching Protocols\r\n…" → 101).
    private func parseStatusCode(rawHeaders: Data) -> Int {
        guard let str = String(data: rawHeaders.prefix(64), encoding: .ascii),
              let lineEnd = str.range(of: "\r\n") else { return 0 }
        let parts = str[..<lineEnd.lowerBound].split(separator: " ")
        guard parts.count >= 2, let n = Int(parts[1]) else { return 0 }
        return n
    }

    /// Build + record the TraceRecord. Body capture decision is made
    /// here so the proxy hot path doesn't pay the cost when traces
    /// are off. Runs on the connection's Task — no main-actor hop
    /// for the body files (TraceStore.queue handles them off-thread).
    private func emitTrace(host: String, port: Int,
                           preSwapRequest: Data,
                           upstreamResponse: Data,
                           upstreamWireBytes: Int,
                           responseTruncated: Bool,
                           swaps: [SwapRecord],
                           leaks: [LeakEntry],
                           latencyMs: Double) async {
        guard let session = sessionTraceProvider(),
              session.level.recordsActivity else { return }
        let traceT0 = Date()
        BACDebug.log("[mitm/trace]",
                     "emit start host=\(host) reqBytes=\(preSwapRequest.count) respBytes=\(upstreamResponse.count) truncated=\(responseTruncated)")
        defer {
            BACDebug.log("[mitm/trace]",
                         "emit done host=\(host) total=\(BACDebug.ms(traceT0))")
        }

        // Parse the request line for the trace.
        let (method, path) = Self.parseRequestLine(preSwapRequest)
        let statusCode = Self.parseStatusCode(upstreamResponse)

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
            isConversation: isConversation
        )

        let store = traceStore
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
            ? Self.bodyForTrace(preSwapRequest).map { Self.redactSensitiveHeaders($0) }
            : nil
        let res = canStoreResponseBody
            ? Self.bodyForTrace(upstreamResponse).map { Self.redactSensitiveHeaders($0) }
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

    /// Rewrite the headers of an HTTP frame so any header on the
    /// `sensitiveHeaders` list has its value replaced with
    /// `<redacted>`. Body bytes are passed through unchanged. If the
    /// frame doesn't have a CRLF-CRLF separator, returns the input
    /// unchanged.
    static func redactSensitiveHeaders(_ raw: Data) -> Data {
        guard let endRange = raw.range(of: Data("\r\n\r\n".utf8)) else { return raw }
        let headerData = raw.subdata(in: 0..<endRange.lowerBound)
        let bodyData   = raw.subdata(in: endRange.lowerBound..<raw.count)
        guard let headerStr = String(data: headerData, encoding: .ascii) else { return raw }

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
        out.reserveCapacity(rebuilt.utf8.count + bodyData.count)
        out.append(Data(rebuilt.utf8))
        out.append(bodyData)
        return out
    }

    private static func isSensitiveHeader(_ lowered: String) -> Bool {
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
    private static func bodyForTrace(_ raw: Data) -> Data? {
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
        guard let headerStr = String(data: header, encoding: .ascii) else {
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

    /// Build a per-request URLSession whose delegate fields client-
    /// cert challenges with the matching SecIdentity from the
    /// profile's identity registry. The session is single-use because
    /// URLSessionDelegate must be retained for the session's lifetime
    /// and we want the connection's identity binding to be tight.
    private func upstreamSession(for host: String) -> URLSession {
        let delegate = ClientCertChallengeDelegate(
            identityRegistry: clientIdentities,
            caRegistry: clusterCAs,
            consent: consent,
            profileID: profileID, host: host)
        let cfg = URLSessionConfiguration.ephemeral
        return URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
    }

    /// Pull "GET /foo HTTP/1.1" → ("GET", "/foo").
    private static func parseRequestLine(_ raw: Data) -> (method: String, path: String) {
        guard let str = String(data: raw.prefix(8 * 1024), encoding: .ascii),
              let lineEnd = str.range(of: "\r\n") else {
            return ("?", "/")
        }
        let line = str[..<lineEnd.lowerBound]
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return ("?", "/") }
        return (String(parts[0]), String(parts[1]))
    }

    /// Pull "HTTP/1.1 200 OK" → 200.
    private static func parseStatusCode(_ raw: Data) -> Int {
        guard let str = String(data: raw.prefix(64), encoding: .ascii),
              let lineEnd = str.range(of: "\r\n") else { return 0 }
        let line = str[..<lineEnd.lowerBound]
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let n = Int(parts[1]) else { return 0 }
        return n
    }
}

// MARK: - HTTP wire helpers

/// Parse "host:port" → (host, port). Defaults to 443 if missing.
private func parseHostPort(_ s: String) -> (String, Int) {
    if let colon = s.lastIndex(of: ":"),
       let port = Int(s[s.index(after: colon)...]) {
        return (String(s[..<colon]), port)
    }
    return (s, 443)
}

/// Read until we have a full HTTP request (headers + Content-Length
/// body). Plain-FD variant: no TLS in between.
private func readRawHTTPRequest(plainFD fd: Int32, maxBytes: Int) throws -> Data {
    return try readUntilCompleteHTTP(maxBytes: maxBytes) { buf in
        var into = [UInt8](repeating: 0, count: buf)
        let n = read(fd, &into, buf)
        if n < 0 {
            throw MitmError.tlsReadFailed(OSStatus(errno))
        }
        if n == 0 { return Data() }
        return Data(into.prefix(n))
    }
}

@available(macOS, deprecated: 10.15)
private func readRawHTTPRequest(via tls: TLSServerStream, maxBytes: Int) throws -> Data {
    return try readUntilCompleteHTTP(maxBytes: maxBytes) { buf in
        try tls.read(maxBytes: buf)
    }
}

private func readUntilCompleteHTTP(maxBytes: Int,
                                   reader: (Int) throws -> Data) throws -> Data {
    var buffer = Data()
    let chunk = 16 * 1024
    var contentLength: Int? = nil
    var headerEnd: Int? = nil

    while buffer.count < maxBytes {
        let got = try reader(chunk)
        if got.isEmpty {
            // EOF before we got a full request.
            if headerEnd == nil { throw MitmError.unexpectedTermination }
            break
        }
        buffer.append(got)

        if headerEnd == nil,
           let r = buffer.range(of: Data("\r\n\r\n".utf8)) {
            headerEnd = r.upperBound
            // Parse Content-Length from headers.
            if let str = String(data: buffer.prefix(r.lowerBound), encoding: .ascii) {
                for line in str.split(separator: "\r\n") {
                    let lower = line.lowercased()
                    if lower.hasPrefix("content-length:") {
                        let v = lower.dropFirst("content-length:".count)
                            .trimmingCharacters(in: .whitespaces)
                        contentLength = Int(v)
                    }
                }
            }
        }
        if let end = headerEnd {
            let bodyHave = buffer.count - end
            if let cl = contentLength {
                if bodyHave >= cl { return buffer }
            } else {
                // No content-length → no body (or chunked, which we
                // don't handle in this minimal v1 — most agent APIs
                // send Content-Length).
                return buffer
            }
        }
    }
    return buffer
}

/// Lightweight byte-counter used by the WebSocket pump. Each child
/// task touches exactly one of the two fields, so we don't bother
/// with locking — the @unchecked Sendable marker is honest because
/// the access pattern is disjoint by construction.
private final class WSByteCounters: @unchecked Sendable {
    var client = 0
    var upstream = 0
    func addClient(_ n: Int) { client += n }
    func addUpstream(_ n: Int) { upstream += n }
}

/// Read from a TLS stream until we see `\r\n\r\n` (end of headers)
/// or hit `maxBytes`. Returns whatever was buffered (which may
/// include bytes past the blank line — unlikely on a 101 because
/// the upstream waits for our ACK, but tolerated). Used only by
/// the WebSocket upgrade fast-path; the main request path has its
/// own length-aware reader because it needs to honour Content-Length.
@available(macOS, deprecated: 10.15)
private func readUntilDoubleCRLF(via tls: TLSClientStream, maxBytes: Int) throws -> Data {
    var buffer = Data()
    while buffer.count < maxBytes {
        let got = try tls.read(maxBytes: 16 * 1024)
        if got.isEmpty {
            if buffer.isEmpty { throw MitmError.unexpectedTermination }
            return buffer
        }
        buffer.append(got)
        if buffer.range(of: Data("\r\n\r\n".utf8)) != nil { return buffer }
    }
    return buffer
}

/// Open a synchronous TCP socket to `host:port` using `getaddrinfo`
/// on a background queue so we don't block the cooperative pool.
/// Returns the connected FD (caller owns the close). Tries each
/// resolved address until one connects; throws `upstreamFailed` if
/// none succeed.
private func connectTCP(host: String, port: Int) throws -> Int32 {
    var hints = addrinfo(
        ai_flags: 0,
        ai_family: AF_UNSPEC,
        ai_socktype: SOCK_STREAM,
        ai_protocol: IPPROTO_TCP,
        ai_addrlen: 0,
        ai_canonname: nil,
        ai_addr: nil,
        ai_next: nil
    )
    var res: UnsafeMutablePointer<addrinfo>? = nil
    let rc = getaddrinfo(host, String(port), &hints, &res)
    if rc != 0 || res == nil {
        let msg = String(cString: gai_strerror(rc))
        throw MitmError.upstreamFailed("getaddrinfo(\(host)): \(msg)")
    }
    defer { freeaddrinfo(res) }

    var lastErrno: Int32 = 0
    var cursor = res
    while let info = cursor {
        let fd = socket(info.pointee.ai_family,
                        info.pointee.ai_socktype,
                        info.pointee.ai_protocol)
        if fd < 0 {
            lastErrno = errno
            cursor = info.pointee.ai_next
            continue
        }
        if connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 {
            return fd
        }
        lastErrno = errno
        close(fd)
        cursor = info.pointee.ai_next
    }
    let msg = String(cString: strerror(lastErrno))
    throw MitmError.upstreamFailed("connect(\(host):\(port)): \(msg)")
}

private func writeAll(fd: Int32, bytes: [UInt8]) throws {
    var sent = 0
    while sent < bytes.count {
        let n = bytes.withUnsafeBufferPointer { ptr in
            write(fd, ptr.baseAddress!.advanced(by: sent), bytes.count - sent)
        }
        if n < 0 {
            if errno == EAGAIN || errno == EINTR { continue }
            throw MitmError.tlsWriteFailed(OSStatus(errno))
        }
        sent += n
    }
}

// MARK: - Upstream

/// Reconstruct the guest's HTTP request as a URLRequest, fire via
/// URLSession, and **stream** the response back through the guest's
/// TLS server stream as bytes arrive — no full-body buffering.
///
/// Why streaming matters: SSE (`text/event-stream`), Bedrock's
/// eventstream framing, long-polling endpoints, and any other open-
/// ended response would otherwise sit invisibly in URLSession's
/// buffer until upstream finished sending. With the previous
/// `URLSession.data(for:)` path, a Claude streaming reply through
/// Bedrock would arrive at the VM as one giant blob after the model
/// fully generated, defeating the whole point of streaming.
///
/// Returns the full constructed wire response (head + accumulated
/// body) so `emitTrace` can record bytes / status / body for the
/// inspector. The accumulation is the same memory cost as the prior
/// implementation — we just send to the wire as we receive instead
/// of waiting for completion. Caller must NOT also `tls.write()` the
/// returned bytes (already streamed during the call).
@available(macOS, deprecated: 10.15, message: "uses TLSServerStream which wraps SecureTransport")
/// Variant of `relayUpstream` for short responses we need to mutate
/// before they hit the wire (Anthropic OAuth rotation). Accumulates the
/// full upstream response, runs `rewrite`, then writes the rewritten
/// bytes to TLS in one shot. Bounded by the same 8 MB body cap as the
/// streaming path; OAuth refresh responses are well under 1 KB so this
/// never trips.
@available(macOS, deprecated: 10.15)
private func relayUpstreamBuffered(rawRequest: Data, host: String, port: Int,
                                   session: URLSession,
                                   tls: TLSServerStream,
                                   rewrite: (Data) -> Data) async throws -> RelayResponse {
    let buffered = try await relayUpstreamCollecting(
        rawRequest: rawRequest, host: host, port: port, session: session)
    let rewritten = rewrite(buffered)
    try tls.write(rewritten)
    return RelayResponse(buffer: rewritten,
                         wireBytes: rewritten.count,
                         truncatedForTrace: false)
}

/// Collect the full upstream response (no TLS write side-effect).
/// Shared between the buffered relay and any other call site that
/// needs the full body before responding to the client.
private func relayUpstreamCollecting(rawRequest: Data, host: String, port: Int,
                                     session: URLSession) async throws -> Data {
    guard let endRange = rawRequest.range(of: Data("\r\n\r\n".utf8)) else {
        throw MitmError.malformedHTTPRequest
    }
    let headerData = rawRequest.subdata(in: 0..<endRange.lowerBound)
    let body       = rawRequest.subdata(in: endRange.upperBound..<rawRequest.count)
    guard let headerStr = String(data: headerData, encoding: .ascii) else {
        throw MitmError.malformedHTTPRequest
    }
    var lines = headerStr.split(separator: "\r\n", omittingEmptySubsequences: false)
        .map(String.init)
    guard !lines.isEmpty else { throw MitmError.malformedHTTPRequest }
    let requestLine = lines.removeFirst()
    let lineParts = requestLine.split(separator: " ")
    guard lineParts.count >= 3 else { throw MitmError.malformedHTTPRequest }
    let method = String(lineParts[0])
    let path   = String(lineParts[1])
    let portStr = (port == 443) ? "" : ":\(port)"
    guard let url = URL(string: "https://\(host)\(portStr)\(path)") else {
        throw MitmError.malformedHTTPRequest
    }
    var req = URLRequest(url: url)
    req.httpMethod = method
    if !body.isEmpty { req.httpBody = body }
    for line in lines where !line.isEmpty {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        switch name.lowercased() {
        case "host", "content-length", "connection", "transfer-encoding",
             "proxy-connection", "keep-alive", "te", "upgrade":
            continue
        default:
            req.setValue(value, forHTTPHeaderField: name)
        }
    }
    let stripped: Set<String> = [
        "content-encoding", "content-length",
        "transfer-encoding", "connection",
        "proxy-connection", "keep-alive", "te", "trailer",
        "upgrade", "proxy-authenticate", "proxy-authorization",
    ]
    let (data, resp) = try await session.data(for: req)
    let http = (resp as? HTTPURLResponse)
    var head = "HTTP/1.1 \(http?.statusCode ?? 200) "
    head += HTTPURLResponse.localizedString(
        forStatusCode: http?.statusCode ?? 200).capitalized
    head += "\r\n"
    if let http {
        for (k, v) in http.allHeaderFields {
            guard let key = k as? String, let val = v as? String else { continue }
            if stripped.contains(key.lowercased()) { continue }
            head += "\(key): \(val)\r\n"
        }
    }
    head += "Content-Length: \(data.count)\r\n"
    head += "Connection: close\r\n"
    head += "\r\n"
    var out = Data(head.utf8)
    out.append(data)
    return out
}

@available(macOS, deprecated: 10.15)
private func relayUpstream(rawRequest: Data, host: String, port: Int,
                           session: URLSession,
                           tls: TLSServerStream) async throws -> RelayResponse {
    guard let endRange = rawRequest.range(of: Data("\r\n\r\n".utf8)) else {
        throw MitmError.malformedHTTPRequest
    }
    let headerData = rawRequest.subdata(in: 0..<endRange.lowerBound)
    let body       = rawRequest.subdata(in: endRange.upperBound..<rawRequest.count)
    guard let headerStr = String(data: headerData, encoding: .ascii) else {
        throw MitmError.malformedHTTPRequest
    }

    var lines = headerStr.split(separator: "\r\n", omittingEmptySubsequences: false)
        .map(String.init)
    guard !lines.isEmpty else { throw MitmError.malformedHTTPRequest }

    let requestLine = lines.removeFirst()
    let lineParts = requestLine.split(separator: " ")
    guard lineParts.count >= 3 else { throw MitmError.malformedHTTPRequest }
    let method = String(lineParts[0])
    let path   = String(lineParts[1])

    // CONNECT tunnels are TLS by definition — the port is just where
    // the upstream listens (e.g. 6443 for k8s API servers, 8443 for
    // some internal stacks). Always replay as https so URLSession
    // performs a real TLS handshake upstream; firing http:// at a
    // TLS-only port lands a Bad Request.
    let portStr = (port == 443) ? "" : ":\(port)"
    guard let url = URL(string: "https://\(host)\(portStr)\(path)") else {
        throw MitmError.malformedHTTPRequest
    }

    var req = URLRequest(url: url)
    req.httpMethod = method
    if !body.isEmpty { req.httpBody = body }

    for line in lines where !line.isEmpty {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        // Don't replay hop-by-hop / framing headers — URLSession sets these.
        switch name.lowercased() {
        case "host", "content-length", "connection", "transfer-encoding",
             "proxy-connection", "keep-alive", "te", "upgrade":
            continue
        default:
            req.setValue(value, forHTTPHeaderField: name)
        }
    }

    // Bridge URLSession's delegate callbacks (head / data chunks /
    // completion) into an AsyncThrowingStream the consumer iterates.
    // Each chunk yielded by the delegate becomes a tls.write on the
    // consumer's task — TLS access stays serialized to one task.
    enum UpstreamEvent {
        case head(HTTPURLResponse)
        case chunk(Data)
    }

    let events = AsyncThrowingStream<UpstreamEvent, Error> { continuation in
        let delegate = StreamingRelayDelegate(
            onHead:  { continuation.yield(.head($0)) },
            onChunk: { continuation.yield(.chunk($0)) },
            onComplete: { error in
                if let e = error { continuation.finish(throwing: e) }
                else { continuation.finish() }
            }
        )
        let task = session.dataTask(with: req)
        task.delegate = delegate
        // Retain the delegate for the task's lifetime — URLSessionTask
        // only weakly references its delegate. Storing on the task
        // itself isn't a thing, so park it on the continuation's
        // termination cleanup.
        continuation.onTermination = { _ in
            task.cancel()
            _ = delegate  // keepalive
        }
        task.resume()
    }

    // Strip headers URLSession either lies about (post-decompression)
    // or that we own framing of (Transfer-Encoding / Connection /
    // hop-by-hop §13.5.1). We don't emit a Content-Length — the
    // response length is unknown when we start streaming, and we
    // signal end-of-body with `Connection: close`.
    let stripped: Set<String> = [
        "content-encoding", "content-length",
        "transfer-encoding", "connection",
        "proxy-connection", "keep-alive", "te", "trailer",
        "upgrade", "proxy-authenticate", "proxy-authorization",
    ]

    // Hard cap on what we keep in memory for the trace record. Set
    // slightly above `bodyForTrace`'s 5 MB perRecordCap so any
    // response we'd actually save fits, but a streaming SSE/Bedrock
    // dialogue (think a multi-hour Claude conversation) doesn't
    // accumulate in RAM only to be discarded by `bodyForTrace` later.
    // Without this cap, a 1 TB streamed response would buffer 1 TB
    // here just to hand it to a function that throws it away.
    let bodyBufferCap = 8 * 1024 * 1024
    var responseBuffer = Data()
    var totalWireBytes = 0
    var truncatedForTrace = false
    for try await event in events {
        switch event {
        case .head(let http):
            var head = "HTTP/1.1 \(http.statusCode) "
            head += HTTPURLResponse.localizedString(forStatusCode: http.statusCode).capitalized
            head += "\r\n"
            for (k, v) in http.allHeaderFields {
                guard let key = k as? String, let val = v as? String else { continue }
                if stripped.contains(key.lowercased()) { continue }
                head += "\(key): \(val)\r\n"
            }
            head += "Connection: close\r\n"
            head += "\r\n"
            let headData = Data(head.utf8)
            try tls.write(headData)
            totalWireBytes += headData.count
            // The head always fits — bound above by RFC's practical
            // header limits, well under any sensible cap.
            responseBuffer.append(headData)
        case .chunk(let chunk):
            try tls.write(chunk)
            totalWireBytes += chunk.count
            if responseBuffer.count + chunk.count <= bodyBufferCap {
                responseBuffer.append(chunk)
            } else if responseBuffer.count < bodyBufferCap {
                // Last partial chunk before the cap — keep just enough
                // to fill the buffer and flag truncation so the trace
                // path doesn't save a partial body that would mislead
                // the inspector.
                let take = bodyBufferCap - responseBuffer.count
                responseBuffer.append(chunk.prefix(take))
                truncatedForTrace = true
            } else {
                truncatedForTrace = true
            }
        }
    }
    return RelayResponse(buffer: responseBuffer,
                         wireBytes: totalWireBytes,
                         truncatedForTrace: truncatedForTrace)
}

/// Tuple-ish return for `relayUpstream`. Splits "what we kept for
/// the trace record" from "what the wire actually saw" because
/// large streaming responses are now capped in memory but their
/// wire byte count must still be accurate in the trace.
struct RelayResponse {
    let buffer: Data
    let wireBytes: Int
    /// True when the response exceeded the in-memory cap. The trace
    /// path uses this to refuse to save a partial body.
    let truncatedForTrace: Bool
}

/// URLSessionDataDelegate that funnels the response head, each body
/// chunk, and completion into an AsyncThrowingStream. Keeps strong
/// refs to its closures so the relay function can stash it via the
/// continuation termination handler — `URLSessionTask.delegate` is
/// declared weak.
private final class StreamingRelayDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let onHead: @Sendable (HTTPURLResponse) -> Void
    let onChunk: @Sendable (Data) -> Void
    let onComplete: @Sendable (Error?) -> Void

    init(onHead: @escaping @Sendable (HTTPURLResponse) -> Void,
         onChunk: @escaping @Sendable (Data) -> Void,
         onComplete: @escaping @Sendable (Error?) -> Void) {
        self.onHead = onHead
        self.onChunk = onChunk
        self.onComplete = onComplete
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            onHead(http)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        onChunk(data)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        onComplete(error)
    }
}

// MARK: - Client-cert challenge handler

/// URLSessionDelegate that satisfies an upstream's mTLS challenge by
/// looking up the matching SecIdentity from the per-profile registry,
/// and (when a per-host CA is registered) anchors the server-trust
/// evaluation against it instead of the system trust store. The CA
/// override is what lets us reach private k8s API servers whose cert
/// chains don't appear in macOS's roots.
private final class ClientCertChallengeDelegate: NSObject, URLSessionDelegate {
    let identityRegistry: ClientIdentityRegistry
    let caRegistry: ClusterCATrustRegistry
    let consent: ConsentBroker
    let profileID: UUID
    let host: String

    init(identityRegistry: ClientIdentityRegistry,
         caRegistry: ClusterCATrustRegistry,
         consent: ConsentBroker,
         profileID: UUID, host: String) {
        self.identityRegistry = identityRegistry
        self.caRegistry = caRegistry
        self.consent = consent
        self.profileID = profileID
        self.host = host
    }

    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                                  URLCredential?) -> Void) {
        let method = challenge.protectionSpace.authenticationMethod
        switch method {
        case NSURLAuthenticationMethodClientCertificate:
            guard let entry = identityRegistry.entry(for: host, profileID: profileID) else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            // Gate via the consent broker if the source kubeconfig
            // entry is flagged. The challenge handler is sync, but
            // its completionHandler can be invoked asynchronously —
            // bridge to the actor and call back when the user (or a
            // live grant) decides.
            if let credID = entry.consentCredentialID {
                FileHandle.standardError.write(Data(
                    "[mitm] client-cert challenge on \(host) gated → consent \(credID)\n".utf8))
                let display = entry.consentDisplayName ?? credID
                let pid = profileID
                let hostName = host
                let broker = consent
                Task {
                    let allowed = await broker.consent(
                        profileID: pid,
                        credentialID: credID,
                        credentialDisplayName: display,
                        scopeHint: String(format: NSLocalizedString(
                            "to authenticate with the API server at %@",
                            comment: ""), hostName))
                    if allowed {
                        completionHandler(.useCredential,
                                          URLCredential(identity: entry.identity,
                                                        certificates: nil,
                                                        persistence: .forSession))
                    } else {
                        completionHandler(.cancelAuthenticationChallenge, nil)
                    }
                }
            } else {
                completionHandler(.useCredential,
                                  URLCredential(identity: entry.identity,
                                                certificates: nil,
                                                persistence: .forSession))
            }

        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust,
                  let ca = caRegistry.ca(for: host, profileID: profileID) else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            // Anchor exclusively against the user-supplied CA — the
            // private k8s root almost never chains to macOS's bundled
            // roots, and falling back would defeat the override.
            SecTrustSetAnchorCertificates(trust, [ca] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            // Use the SSL policy with hostname binding. BasicX509 alone
            // would let any cert chained to the same pinned CA satisfy
            // a request for any hostname under that CA — fine for
            // single-cert clusters, fatal for any cluster with kubelet /
            // etcd / sibling-API certs under the same root. Apple's
            // max-validity / CT restrictions only apply when chaining
            // to system roots; against a custom anchor with
            // anchorCertificatesOnly=true the long self-signed cluster
            // cert lifetimes are accepted.
            let policy = SecPolicyCreateSSL(true, host as CFString)
            SecTrustSetPolicies(trust, [policy] as CFArray)
            var err: CFError?
            if SecTrustEvaluateWithError(trust, &err) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                let reason = (err as Error?).map { "\($0)" } ?? "unknown"
                FileHandle.standardError.write(Data(
                    "[mitm] trust eval failed for \(host) using registered CA: \(reason)\n".utf8))
                completionHandler(.cancelAuthenticationChallenge, nil)
            }

        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
