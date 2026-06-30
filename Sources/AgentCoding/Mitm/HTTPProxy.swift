import Foundation
import Compression
@preconcurrency import Virtualization

/// One MITM connection's lifetime: read CONNECT, send 200, terminate
/// TLS with a forged leaf cert, read the wrapped HTTP request, swap
/// tokens, fire to upstream, stream response back.
///
/// Each call to `run()` handles exactly one tunnel. We don't bother
/// with HTTP/1.1 pipelining or keep-alive within a CONNECT — the cost
/// of a fresh CONNECT per request is negligible at agent traffic
/// volumes, and it keeps the state machine sane.
/// NOTE: the SecureTransport deprecation is contained to the three
/// methods that actually name `TLSServerStream` — `run()` / `drive()`
/// / `handleWebSocketUpgrade(serverTLS:…)` — rather than the whole
/// class. `TLSServerStream` is a local inside `drive()`, never a stored
/// property, so the class itself isn't "deprecated"; marking it so made
/// every unrelated member access (e.g. the static `*Provider` config
/// closures from `MitmEngine.register`) inherit the warning.
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
    /// Consent broker for the `.promptOnWrite` guardrails mode. Same
    /// shape as `consent` but scoped to write-on-X grants instead of
    /// per-credential grants.
    let guardrailsBroker: GuardrailsConsentBroker
    /// Consent broker for supply-chain prompts (lockfile-pinned
    /// bypass, per-package overrides).
    let supplyChainBroker: SupplyChainConsentBroker
    /// OSV (osv.dev) client + socket.dev client. Shared
    /// process-wide; cache lookups so the artifact-fetch hot path
    /// is cheap for repeat installs of the same (pkg, version).
    let osvClient: OSVClient
    let socketClient: SocketDevClient
    /// Publish-time backstop. Populated by metadata transforms,
    /// consulted at artifact-fetch time to detect "the agent has
    /// cached metadata from before our age gate was on and is
    /// fetching a too-fresh version directly".
    let publishTimeCache: PublishTimeCache
    let sessionTraceProvider: @Sendable () -> MitmEngine.SessionTrace?
    /// "Guardrails" guard for this profile (host-side destructive-verb removal),
    /// or nil if disabled. Read on the hot path per request.
    let guardrailsProvider: @Sendable () -> GuardrailsConfig?
    /// Supply-chain policy for this profile (age gate, OSV /
    /// socket.dev lookups, install-script stripping). Read on
    /// every registry intercept.
    let supplyChainProvider: @Sendable () -> SupplyChainPolicy?
    /// Reads the per-profile prompt-injection policy (source-code / CLAUDE.md
    /// scanning + log/ask/block action). Set once by `MitmEngine`; nil →
    /// detection off. Static to avoid threading a closure through every
    /// listener/delegate layer.
    nonisolated(unsafe) static var promptInjectionPolicyProvider: (@Sendable (UUID) -> PromptInjectionPolicy?)?
    /// Reads whether Fusion is currently engaged for a profile's session.
    /// Set once by `MitmEngine.register`; nil → treat as disengaged.
    /// Static, same rationale as `promptInjectionPolicyProvider`.
    nonisolated(unsafe) static var fusionEngagedProvider: (@Sendable (UUID) -> Bool)?
    /// Per-profile Fusion config (legs + judge + auth modes). nil → not
    /// configured. Set by `MitmEngine.register`; same static-provider rationale.
    nonisolated(unsafe) static var fusionConfigProvider: (@Sendable (UUID) -> Fusion.Config?)?
    /// Per-profile LLM routing context (Cloud/Local/Hybrid + hybrid policy
    /// engine). nil → cloud pass-through. Set by `MitmEngine.register`;
    /// same static-provider rationale as the Fusion providers above.
    nonisolated(unsafe) static var routingProvider: (@Sendable (UUID) -> LLMRoutingContext?)?
    /// Reaches the host-owned Claude subscription store + refresher. nil →
    /// subscription auth off. Set once by `MitmEngine.register`; static, same
    /// rationale as the providers above.
    nonisolated(unsafe) static var claudeSubscriptionProvider: (@Sendable () -> (ClaudeSubscriptionStore, ClaudeSubscriptionRefresher)?)?
    /// Codex / ChatGPT counterpart of `claudeSubscriptionProvider`.
    nonisolated(unsafe) static var codexSubscriptionProvider: (@Sendable () -> (CodexSubscriptionStore, CodexSubscriptionRefresher)?)?
    /// Grok (xAI) counterpart of `claudeSubscriptionProvider`.
    nonisolated(unsafe) static var grokSubscriptionProvider: (@Sendable () -> (GrokSubscriptionStore, GrokSubscriptionRefresher)?)?
    /// Process-wide consent broker for the "ask me what to do" action.
    static let promptInjectionBroker = PromptInjectionConsentBroker()

    init(fd: Int32, profileID: UUID, certCache: CertCache, swapper: TokenSwapper,
         awsResigner: AWSResigner,
         traceStore: TraceStore,
         clientIdentities: ClientIdentityRegistry,
         clusterCAs: ClusterCATrustRegistry,
         consent: ConsentBroker,
         guardrailsBroker: GuardrailsConsentBroker,
         supplyChainBroker: SupplyChainConsentBroker,
         osvClient: OSVClient,
         socketClient: SocketDevClient,
         publishTimeCache: PublishTimeCache,
         sessionTraceProvider: @escaping @Sendable () -> MitmEngine.SessionTrace?,
         guardrailsProvider: @escaping @Sendable () -> GuardrailsConfig? = { nil },
         supplyChainProvider: @escaping @Sendable () -> SupplyChainPolicy? = { nil }) {
        self.fd = fd
        self.profileID = profileID
        self.certCache = certCache
        self.swapper = swapper
        self.awsResigner = awsResigner
        self.traceStore = traceStore
        self.clientIdentities = clientIdentities
        self.clusterCAs = clusterCAs
        self.consent = consent
        self.guardrailsBroker = guardrailsBroker
        self.supplyChainBroker = supplyChainBroker
        self.osvClient = osvClient
        self.socketClient = socketClient
        self.publishTimeCache = publishTimeCache
        self.sessionTraceProvider = sessionTraceProvider
        self.guardrailsProvider = guardrailsProvider
        self.supplyChainProvider = supplyChainProvider
    }

    /// Drives the full MITM exchange. Must be called from a Task —
    /// uses blocking syscalls under the hood. Closes the FD on exit
    /// regardless of success.
    @available(macOS, deprecated: 10.15, message: "drives TLSServerStream which wraps SecureTransport")
    func run() async {
        defer { close(fd) }
        do {
            try await drive()
        } catch {
            FileHandle.standardError.write(Data("[mitm] \(error)\n".utf8))
        }
    }

    @available(macOS, deprecated: 10.15, message: "creates TLSServerStream which wraps SecureTransport")
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

        // 4a. Block OAuth/OIDC discovery for MCP hosts that have a
        // broker token. Claude Code probes multiple .well-known paths;
        // if any returns metadata it insists on its own auth flow
        // (which can't work inside the VM). Return 404 for all of
        // them so Claude Code treats the server as unauthenticated
        // and the proxy's header injection handles auth transparently.
        let (reqMethod, reqPath) = Self.parseRequestLine(request)

        // Guardrails: host-side destructive-op removal across protocols
        // (Kubernetes, AWS, DigitalOcean, Docker registries, GitHub/GitLab/
        // Bitbucket). Enforced here, before a single byte is forwarded, so a
        // compromised agent in the VM can't bypass it; the agent gets a hard
        // 403 it can react to. AWS needs the action name from the request, so
        // we parse X-Amz-Target / the Action= body param only for AWS hosts.
        if let guardrails = guardrailsProvider() {
            var amzTarget: String?
            var formAction: String?
            if guardrails.aws != .off, GuardrailsConfig.isAWSHost(host) {
                let headerText: String
                var bodyPrefix = ""
                if let sep = request.range(of: Data("\r\n\r\n".utf8)) {
                    headerText = String(decoding: request[request.startIndex..<sep.lowerBound], as: UTF8.self)
                    let bEnd = request.index(sep.upperBound, offsetBy: 4096, limitedBy: request.endIndex) ?? request.endIndex
                    bodyPrefix = String(decoding: request[sep.upperBound..<bEnd], as: UTF8.self)
                } else {
                    headerText = String(decoding: request, as: UTF8.self)
                }
                amzTarget = Self.headerValue("x-amz-target", inHeaderSection: headerText)
                formAction = amzTarget == nil ? Self.formActionValue(bodyPrefix) : nil
            }
            // ClickHouse carries the verb in the SQL — pull it from the URL
            // `query=` param and/or the request body (param leads, since
            // `POST /?query=INSERT…` puts the statement there and data in body).
            var dbQuery: String?
            if guardrails.dbNeedsQuery(host: host) {
                var sql = Self.urlQueryParam("query", inPath: reqPath) ?? ""
                if let sep = request.range(of: Data("\r\n\r\n".utf8)) {
                    let bEnd = request.index(sep.upperBound, offsetBy: 8192, limitedBy: request.endIndex) ?? request.endIndex
                    let body = String(decoding: request[sep.upperBound..<bEnd], as: UTF8.self)
                    if !body.isEmpty { sql += (sql.isEmpty ? "" : "\n") + body }
                }
                dbQuery = sql
            }
            // Use the async variant so `.promptOnWrite` mode can ask
            // the user before a sync block fires. Modes that decide
            // synchronously (off / destructive / readOnly) short-
            // circuit inside denyAsync and return immediately.
            if let denial = await guardrails.denyAsync(
                host: host, method: reqMethod, path: reqPath,
                amzTarget: amzTarget, formAction: formAction,
                dbQuery: dbQuery,
                broker: guardrailsBroker,
                profileID: profileID) {
                FileHandle.standardError.write(Data(
                    "[mitm] Guardrails blocked \(reqMethod) \(host)\(reqPath) — \(denial.reason)\n".utf8))
                var resp = "HTTP/1.1 403 Forbidden\r\nContent-Type: \(denial.contentType)\r\n"
                if let t = denial.amzErrorType { resp += "x-amzn-ErrorType: \(t)\r\n" }
                resp += "Content-Length: \(denial.body.utf8.count)\r\nConnection: close\r\n\r\n\(denial.body)"
                try? tls.write(Data(resp.utf8))
                return
            }
        }

        let isDiscovery = reqPath.hasPrefix("/.well-known/oauth-authorization-server")
            || reqPath.hasPrefix("/.well-known/oauth-protected-resource")
            || reqPath.hasPrefix("/.well-known/openid-configuration")
        if isDiscovery {
            let hasMCPBearer = swapper.entries(for: profileID)
                .contains { $0.host == host && $0.fake.hasPrefix("brm-mcp_") }
            if hasMCPBearer {
                FileHandle.standardError.write(Data(
                    "[mitm] blocked OAuth discovery for \(host) — using broker token\n".utf8))
                let body = "Not Found"
                var resp = "HTTP/1.1 404 Not Found\r\n"
                resp += "Content-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\n"
                resp += "Connection: close\r\n\r\n\(body)"
                try? tls.write(Data(resp.utf8))
                return
            }
        }

        // Short-circuit Claude Code's non-LLM cloud calls when this profile
        // runs on the LOCAL model. The CLI fires onboarding / OAuth-eligibility
        // / telemetry requests to the real cloud on startup; forwarding them
        // through the MITM blocks the agent (a 36s connect to api.anthropic.com
        // on first run was measured) and leaks usage from the sandbox. The LLM
        // endpoints (/v1/messages*) are rerouted to the on-host engine below; a
        // local agent needs nothing else from the cloud, so answer the rest with
        // a fast empty 200 and never touch the network. Strictly-local only —
        // cloud/hybrid profiles keep their real account/telemetry traffic.
        if let rctx = Self.routingProvider?(profileID), rctx.routing == .local {
            let h = host.lowercased()
            // Only suppress Claude's management calls when the *Claude* agent is
            // itself local. In a mixed profile (subscription Claude + local
            // Codex) Claude's account/management traffic is legitimate and must
            // reach the cloud — otherwise it gets a `{}` it can't parse.
            let anthropicMgmt = (h == "api.anthropic.com" || h.hasSuffix(".anthropic.com"))
                && !reqPath.hasPrefix("/v1/")            // keep /v1/messages*, /v1/models, count_tokens
                && rctx.isLocalProviderHost(host)
            let telemetry = ["api.mixpanel.com", "api.statsig.com",
                             "statsig.anthropic.com", "events.statsigapi.net"].contains(h)
                || h.hasSuffix(".sentry.io") || h.hasSuffix(".datadoghq.com")
            if anthropicMgmt || telemetry {
                let body = "{}"
                var resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                resp += "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                try? tls.write(Data(resp.utf8))
                FileHandle.standardError.write(Data(
                    "[mitm] short-circuited non-LLM \(h)\(reqPath) (local routing)\n".utf8))
                return
            }
        }

        // Pre-swap: scan for unswapped Bearer / x-api-key tokens. The
        // trace store records these as `LeakEntry` values so the user
        // sees exactly which secrets escaped the swap pipeline.
        var leaks = swapper.detectLeaks(in: request, profileID: profileID)
        // Drop false-positive "leaks" for our own bogus subscription tokens:
        // they're host-minted placeholders the transforms below rewrite to the
        // real credential — never a real secret escaping the VM.
        if let hdr = Self.rawHeaderSection(of: request) {
            // Claude: bogus x-api-key on anthropic hosts.
            if host == "api.anthropic.com" || host.hasSuffix(".anthropic.com"),
               let provider = Self.claudeSubscriptionProvider, let (store, _) = provider(),
               let apiKey = Self.headerValue("x-api-key", inHeaderSection: hdr),
               store.profileForBogusKey(apiKey) != nil {
                leaks = leaks.filter { $0.header.lowercased() != "x-api-key" }
            }
            // Codex / Grok: bogus Bearer on their backends.
            let codexHost = host == "chatgpt.com" || host.hasSuffix(".chatgpt.com") || host == "api.openai.com"
            let grokHost = host == "cli-chat-proxy.grok.com" || host.hasSuffix(".grok.com")
                || host == "x.ai" || host.hasSuffix(".x.ai")
            if codexHost || grokHost, let bearer = Self.bearerToken(inHeaderSection: hdr) {
                let codexBogus = Self.codexSubscriptionProvider?()?.0.profileForBogusKey(bearer) != nil
                let grokBogus = Self.grokSubscriptionProvider?()?.0.profileForBogusKey(bearer) != nil
                if codexBogus || grokBogus {
                    leaks = leaks.filter { $0.header.lowercased() != "authorization" }
                }
            }
        }

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
        var swap = await swapper.swap(rawRequest: request, host: host, profileID: profileID)
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

        // 5b. MCP bearer header injection. For MCP servers whose OAuth
        // was brokered on the host, Claude Code doesn't know about the
        // token — it just sees a plain URL. Inject the real bearer
        // token as an Authorization header so the upstream server
        // accepts the request. Only fires when the request doesn't
        // already carry an Authorization header.
        if let mcpReal = swapper.entries(for: profileID)
            .first(where: { $0.host == host && $0.fake.hasPrefix("brm-mcp_") })?.real {
            if let hdr = Self.rawHeaderSection(of: swap.modified),
               Self.headerValue("authorization", inHeaderSection: hdr) == nil {
                // Append our bearer to the header block; the byte-safe splice
                // keeps any binary body intact.
                swap.modified = Self.spliceHeaderSection(
                    of: swap.modified,
                    newHeader: hdr + "\r\nAuthorization: Bearer \(mcpReal)")
                FileHandle.standardError.write(Data(
                    "[mitm] injected MCP bearer for \(host)\n".utf8))
            }
        }

        // 5c. Claude subscription auth. In subscription mode the guest runs in
        //     API-key mode with a *bogus* ANTHROPIC_API_KEY (so it never does
        //     OAuth and never stores a real credential). Here we turn that into
        //     a real subscription request: drop x-api-key, add Authorization:
        //     Bearer <live access token> + the OAuth beta header. The token is
        //     held only on the host, in a store shared by every session, and
        //     the host owns its refresh — so one refresh serves all VMs.
        //     `claudeSubStaleAccess` carries the injected token to the post-
        //     relay 401 self-heal below.
        var claudeSubStaleAccess: String? = nil
        if host == "api.anthropic.com" || host.hasSuffix(".anthropic.com"),
           let provider = Self.claudeSubscriptionProvider, let (store, refresher) = provider(),
           let headerSection = Self.rawHeaderSection(of: swap.modified),
           let apiKey = Self.headerValue("x-api-key", inHeaderSection: headerSection),
           store.profileForBogusKey(apiKey) != nil {
            do {
                let access = try await refresher.accessToken(for: profileID)
                swap.modified = Self.injectClaudeSubscriptionAuth(rawRequest: swap.modified, access: access)
                claudeSubStaleAccess = access
                FileHandle.standardError.write(Data(
                    "[mitm] injected Claude subscription token for \(host)\n".utf8))
            } catch {
                FileHandle.standardError.write(Data(
                    "[mitm] Claude subscription token unavailable for \(host): \(error)\n".utf8))
            }
        }

        // 5d. Codex / ChatGPT subscription auth. The guest's ~/.codex/auth.json
        //     holds a *bogus* far-future-exp JWT (so it never refreshes); on the
        //     ChatGPT backend it sends that as `Authorization: Bearer`. Swap it
        //     for the live real access token from the host store, which the host
        //     refreshes. Distinct from the Claude path (x-api-key → Bearer):
        //     here the guest already sends a Bearer, so it's a value swap.
        var codexSubStaleAccess: String? = nil
        if host == "chatgpt.com" || host.hasSuffix(".chatgpt.com") || host == "api.openai.com",
           let provider = Self.codexSubscriptionProvider, let (store, refresher) = provider(),
           let headerSection = Self.rawHeaderSection(of: swap.modified),
           let bearer = Self.bearerToken(inHeaderSection: headerSection),
           store.profileForBogusKey(bearer) != nil {
            do {
                let access = try await refresher.accessToken(for: profileID)
                swap.modified = Self.replaceAuthorizationBearer(rawRequest: swap.modified, token: access)
                codexSubStaleAccess = access
                FileHandle.standardError.write(Data(
                    "[mitm] injected Codex subscription token for \(host)\n".utf8))
            } catch {
                FileHandle.standardError.write(Data(
                    "[mitm] Codex subscription token unavailable for \(host): \(error)\n".utf8))
            }
        }

        // 5e. Grok (xAI) subscription auth. The guest's ~/.grok/auth.json holds
        //     a bogus OIDC token with a far-future expiry (so it never
        //     refreshes); on the chat proxy it sends that as Bearer. Swap it for
        //     the live real access token from the host store, which the host
        //     refreshes against auth.x.ai.
        var grokSubStaleAccess: String? = nil
        if host == "cli-chat-proxy.grok.com" || host.hasSuffix(".grok.com")
            || host == "x.ai" || host.hasSuffix(".x.ai"),
           let provider = Self.grokSubscriptionProvider, let (store, refresher) = provider(),
           let headerSection = Self.rawHeaderSection(of: swap.modified),
           let bearer = Self.bearerToken(inHeaderSection: headerSection),
           store.profileForBogusKey(bearer) != nil {
            do {
                let access = try await refresher.accessToken(for: profileID)
                swap.modified = Self.replaceAuthorizationBearer(rawRequest: swap.modified, token: access)
                grokSubStaleAccess = access
                FileHandle.standardError.write(Data(
                    "[mitm] injected Grok subscription token for \(host)\n".utf8))
            } catch {
                FileHandle.standardError.write(Data(
                    "[mitm] Grok subscription token unavailable for \(host): \(error)\n".utf8))
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

        // Supply-chain interception + enterprise fetch telemetry.
        // Shares the same per-request URLSession the rest of the proxy
        // uses.
        //
        // We enter this block whenever there's something to *enforce*
        // OR the install is enrolled — admins expect package-download
        // visibility from enrollment alone, even with every
        // enforcement layer off (the prior behaviour gated the whole
        // block, telemetry included, on `policy.isActive`, so an
        // enrolled-but-unconfigured workspace saw no pip/npm fetches
        // at all). Enforcement work below still gates on `enforce`.
        let scPolicy = supplyChainProvider()
        let enforce = scPolicy?.isActive ?? false
        if (enforce || BACEventEmitter.shared.isStreamingEnabled),
           let kind = SupplyChainRegistry.classify(host: host, path: reqPath) {
            // Real policy when present; an all-off stand-in when we're
            // here purely to observe (so the enforcement predicates
            // below cleanly evaluate to "do nothing").
            let policy = scPolicy ?? SupplyChainPolicy(ageGateEnabled: false)
            let cutoff = Date().addingTimeInterval(-Double(policy.ageGateDays) * 86400)
            switch kind {
            case .metadata(let ecosystem, let pkg):
                // Observe-only: log the fetch and forward the response
                // untouched (no buffering / no rewrite).
                if !enforce {
                    emitSupplyChainFetch(profileID: self.profileID,
                        ecosystem: ecosystem.rawValue, package: pkg,
                        version: nil, kind: "metadata", outcome: "allowed")
                    break
                }
                // Age-gate the metadata JSON per-ecosystem. The
                // matched transform also records every per-version
                // publish time into PublishTimeCache so the
                // artifact-fetch backstop has data without
                // re-fetching.
                let allowlisted = policy.ageGateAllows(ecosystem: ecosystem.rawValue, name: pkg)
                let stripIntegrity = ecosystem == .npm
                    && policy.stripInstallScripts
                    && !policy.scriptStripAllows(ecosystem: ecosystem.rawValue, name: pkg)
                let ageOn = policy.ageGateEnabled
                let cache = publishTimeCache
                // Outcome for the enterprise event stream. "rewritten"
                // when the transform actually pipelined the body
                // through; "allowed" on the early-passthrough (e.g.
                // allowlisted + nothing to strip).
                let metaOutcome: String =
                    (allowlisted && !stripIntegrity) ? "allowed" : "rewritten"
                defer {
                    emitSupplyChainFetch(profileID: self.profileID,
                        ecosystem: ecosystem.rawValue,
                        package: pkg, version: nil,
                        kind: "metadata", outcome: metaOutcome)
                }
                // For npm, force the full packument so the age gate actually
                // sees publish times (the install path otherwise omits `time`).
                let metaForward = ecosystem == .npm
                    ? Self.forceFullNpmPackument(toForward) : toForward
                let relay = try await relayUpstreamBuffered(
                    rawRequest: metaForward, host: host, port: port,
                    session: session, tls: tls,
                    rewrite: { raw in
                        switch ecosystem {
                        case .npm:
                            var times: [(String, Date)] = []
                            let out = NPMRegistryTransforms.filterMetadata(
                                rawResponse: raw,
                                packageName: pkg,
                                allowedAfter: ageOn ? cutoff : .distantPast,
                                allowlistedPackage: allowlisted || !ageOn,
                                stripIntegrity: stripIntegrity,
                                publishTimes: &times)
                            if !times.isEmpty {
                                Task.detached { await cache.record(
                                    ecosystem: ecosystem.rawValue,
                                    name: pkg, versions: times) }
                            }
                            return out
                        case .pypi, .cargo, .rubygems, .packagist:
                            // These four record publish times +
                            // age-gate via async ecosystem-specific
                            // transforms. The transforms are async
                            // because they record into the cache
                            // actor inline (one fewer round-trip
                            // than detaching).
                            //
                            // Wrap into a blocking semaphore — we're
                            // already on a per-request task, this is
                            // fine to block here.
                            let sem = DispatchSemaphore(value: 0)
                            var result: Data = raw
                            Task {
                                if !ageOn && !stripIntegrity {
                                    result = raw   // policy disabled; passthrough
                                    sem.signal(); return
                                }
                                let allowed = ageOn ? cutoff : .distantPast
                                switch ecosystem {
                                case .pypi:
                                    // pip's default is the `/simple/`
                                    // index (HTML or PEP 691 JSON), not
                                    // the `/pypi/<pkg>/json` API — they
                                    // have different shapes, so route by
                                    // path.
                                    if reqPath.hasPrefix("/simple/") {
                                        result = await EcosystemTransforms.filterPyPISimple(
                                            rawResponse: raw,
                                            packageName: pkg,
                                            allowedAfter: allowed,
                                            allowlistedPackage: allowlisted || !ageOn,
                                            publishTimeCache: cache)
                                    } else {
                                        result = await EcosystemTransforms.filterPyPIJSON(
                                            rawResponse: raw,
                                            packageName: pkg,
                                            allowedAfter: allowed,
                                            allowlistedPackage: allowlisted || !ageOn,
                                            publishTimeCache: cache)
                                    }
                                case .cargo:
                                    result = await EcosystemTransforms.filterCargoAPI(
                                        rawResponse: raw,
                                        packageName: pkg,
                                        allowedAfter: allowed,
                                        allowlistedPackage: allowlisted || !ageOn,
                                        publishTimeCache: cache)
                                case .rubygems:
                                    result = await EcosystemTransforms.filterRubyGems(
                                        rawResponse: raw,
                                        packageName: pkg,
                                        allowedAfter: allowed,
                                        allowlistedPackage: allowlisted || !ageOn,
                                        publishTimeCache: cache)
                                case .packagist:
                                    result = await EcosystemTransforms.filterPackagist(
                                        rawResponse: raw,
                                        packageName: pkg,
                                        allowedAfter: allowed,
                                        allowlistedPackage: allowlisted || !ageOn,
                                        publishTimeCache: cache)
                                default:
                                    result = raw
                                }
                                sem.signal()
                            }
                            sem.wait()
                            return result
                        default:
                            // Maven / NuGet / Go modules don't ship
                            // per-version timestamps in their
                            // standard metadata response shapes —
                            // we'd need per-version sub-fetches.
                            // Passthrough for now; OSV/socket.dev
                            // still apply at artifact-fetch time.
                            return raw
                        }
                    })
                let elapsed = Date().timeIntervalSince(t0) * 1000
                await emitTrace(host: host, port: port,
                                preSwapRequest: request,
                                upstreamResponse: relay.buffer,
                                upstreamWireBytes: relay.wireBytes,
                                responseTruncated: relay.truncatedForTrace,
                                swaps: swap.swaps,
                                leaks: leaks,
                                latencyMs: elapsed)
                return

            case .artifact(let ecosystem, let pkg, let version):
                // Observe-only: log the download and forward it
                // untouched. This is the path that gives an enrolled-
                // but-unconfigured workspace its package-download
                // visibility (incl. pip wheels / sdists).
                if !enforce {
                    emitSupplyChainFetch(profileID: self.profileID,
                        ecosystem: ecosystem.rawValue, package: pkg,
                        version: version, kind: "artifact", outcome: "allowed")
                    break
                }
                // Diagnostic breadcrumb: confirms the proxy actually
                // saw the fetch. Without this, a clean install of an
                // older-than-age-gate, OSV-clean, socket.dev-clean
                // package looks like total proxy silence in the log
                // window — making it indistinguishable from "my
                // traffic isn't going through Bromure at all".
                SupplyChainLog.shared.record(
                    "[supply-chain] inspecting \(ecosystem.rawValue)/\(pkg)@\(version)")

                // Enterprise event stream — one `supply_chain.fetch`
                // event per artifact request, regardless of outcome.
                // Each 451 / strip path below mutates these state
                // vars before returning; the defer captures whatever
                // ended up set. Default is "allowed" for the
                // fall-through (no policy fired, package passes).
                var scOutcome = "allowed"
                var scReasonKind: String? = nil
                var scReason: String? = nil
                let scProfileID = self.profileID
                defer {
                    emitSupplyChainFetch(profileID: scProfileID,
                        ecosystem: ecosystem.rawValue,
                        package: pkg, version: version,
                        kind: "artifact", outcome: scOutcome,
                        reasonKind: scReasonKind, reason: scReason)
                }

                // Three pre-flight checks before forward. Each may
                // 451-block; none of them touch the upstream until
                // we decide to forward.

                // 1. Publish-time backstop. Catches "agent has
                //    cached metadata from before age gate was on
                //    and is fetching a too-fresh version directly".
                if policy.ageGateEnabled,
                   !policy.ageGateAllows(ecosystem: ecosystem.rawValue, name: pkg) {
                    var pub = await publishTimeCache.publishedAt(
                        ecosystem: ecosystem.rawValue, name: pkg, version: version)
                    // pip's default (HTML simple index) and any agent
                    // replaying a pre-cached version list never populate
                    // the cache — without an on-demand lookup the pip
                    // age gate silently no-ops. Fetch the per-release
                    // JSON directly, then pin it for the rest of this
                    // install burst.
                    if pub == nil, ecosystem == .pypi {
                        pub = await PyPIMetadataClient.shared.publishTime(
                            package: pkg, version: version)
                        if let p = pub {
                            await publishTimeCache.record(
                                ecosystem: "pypi", name: pkg,
                                versions: [(version, p)])
                        }
                    }
                    if let pub, pub > cutoff {
                        let age = Date().timeIntervalSince(pub)
                        let ageDesc: String
                        if age < 3600 { ageDesc = "\(Int(age / 60)) minutes" }
                        else if age < 86400 { ageDesc = "\(Int(age / 3600)) hours" }
                        else { ageDesc = String(format: "%.1f days", age / 86400) }
                        let reason = "\(ecosystem.rawValue) package \(pkg)@\(version) " +
                            "published \(ageDesc) ago — " +
                            "policy requires \(policy.ageGateDays) days minimum"
                        try? tls.write(SupplyChainEnforcer.blockResponse(reason: reason))
                        SupplyChainLog.shared.record(
                            "[supply-chain] age-gate 451: \(pkg)@\(version) — \(ageDesc) old, requires \(policy.ageGateDays)d")
                        scOutcome = "blocked"
                        scReasonKind = "age_gate"
                        scReason = reason
                        return
                    }
                }

                // Accumulates the enabled reputation sources we couldn't reach
                // for this package — drives the fail-closed hold below.
                var verifyGaps: [String] = []

                // 2. OSV check (free, no key, off by default).
                if policy.osvEnabled {
                    if let result = await osvClient.check(
                            ecosystem: ecosystem.rawValue, name: pkg, version: version) {
                        let blocking = result.vulnerabilities.filter {
                            $0.severity.rank >= OSVClient.Severity(rawValue: policy.osvSeverity.rawValue)!.rank
                        }
                        if let v = blocking.first {
                            let reason = "\(ecosystem.rawValue) package \(pkg)@\(version) " +
                                "has \(blocking.count) vulnerabilit\(blocking.count == 1 ? "y" : "ies") " +
                                "at \(policy.osvSeverity.displayName.lowercased()): " +
                                "\(v.id) — \(v.summary)"
                            try? tls.write(SupplyChainEnforcer.blockResponse(reason: reason))
                            SupplyChainLog.shared.record(
                                "[supply-chain] OSV 451: \(pkg)@\(version) → \(v.id)")
                            scOutcome = "blocked"
                            scReasonKind = "osv"
                            scReason = reason
                            return
                        }
                    } else {
                        // Lookup failed (network error, non-200, 429 rate-limit,
                        // parse error). No verdict — don't silently allow.
                        verifyGaps.append("the OSV vulnerability database")
                    }
                }

                // 3. socket.dev check (BYO key).
                if policy.socketActive {
                  if let result = await socketClient.check(
                        ecosystem: ecosystem.rawValue, name: pkg, version: version,
                        apiKey: policy.socketAPIKey) {
                    if policy.socketBlockCompromised, let bad = result.compromised.first {
                        let reason = "\(ecosystem.rawValue) package \(pkg)@\(version) " +
                            "flagged by socket.dev (\(bad.severity.rawValue)): " +
                            "\(bad.type) — \(bad.summary)"
                        try? tls.write(SupplyChainEnforcer.blockResponse(reason: reason))
                        SupplyChainLog.shared.record(
                            "[supply-chain] socket.dev compromised 451: \(pkg)@\(version) → \(bad.type) [\(bad.severity.rawValue)]")
                        scOutcome = "blocked"
                        scReasonKind = "socket_compromised"
                        scReason = reason
                        return
                    }
                    if policy.socketBlockCVE {
                        let threshold = SocketDevClient.Severity.from(string: policy.socketCVESeverity.rawValue)
                        let bad = result.vulnerabilities.first { $0.severity.rank >= threshold.rank }
                        if let v = bad {
                            let reason = "\(ecosystem.rawValue) package \(pkg)@\(version) " +
                                "has known CVE per socket.dev (\(v.severity.rawValue)): " +
                                "\(v.type) — \(v.summary)"
                            try? tls.write(SupplyChainEnforcer.blockResponse(reason: reason))
                            SupplyChainLog.shared.record(
                                "[supply-chain] socket.dev CVE 451: \(pkg)@\(version) → \(v.type) [\(v.severity.rawValue)]")
                            scOutcome = "blocked"
                            scReasonKind = "socket_cve"
                            scReason = reason
                            return
                        }
                    }
                  } else {
                    // socket.dev unreachable / non-200 / 429 / auth failure /
                    // parse error → no verdict. Don't silently allow.
                    verifyGaps.append("socket.dev")
                  }
                }

                // 3b. Fail closed. An enabled reputation check couldn't reach
                //     its source, so this package has NO verdict — and a
                //     compromised agent can *induce* that (flood OSV / socket.dev
                //     with a large install graph until they rate-limit). Rather
                //     than the documented fail-open, hold the install and ask
                //     the host user; deny (incl. no GUI / timeout) blocks. Keyed
                //     per package@version so one approval can't blanket the
                //     whole dependency graph.
                if !verifyGaps.isEmpty {
                    let gaps = verifyGaps.joined(separator: " and ")
                    let allowed = await supplyChainBroker.consent(
                        profileID: profileID,
                        scope: "verify-unavailable:\(ecosystem.rawValue):\(pkg):\(version)",
                        scopeDisplayName: NSLocalizedString("an unverified package", comment: ""),
                        detail: String(format: NSLocalizedString(
                            "Bromure couldn't reach %@ to vet %@ %@@%@. Installing it means accepting a package that wasn't checked against your configured reputation sources.\n\nAllow this install anyway?",
                            comment: ""), gaps, ecosystem.rawValue, pkg, version))
                    if !allowed {
                        let reason = "\(ecosystem.rawValue) package \(pkg)@\(version) blocked — " +
                            "reputation lookup unavailable (\(gaps)); user denied the unverified install"
                        try? tls.write(SupplyChainEnforcer.blockResponse(reason: reason))
                        SupplyChainLog.shared.record(
                            "[supply-chain] verify-unavailable 451: \(pkg)@\(version) — \(gaps)")
                        scOutcome = "blocked"
                        scReasonKind = "verify_unavailable"
                        scReason = reason
                        return
                    }
                }

                // 4. Lockfile-pinned bypass prompt — for npm,
                //    look for the `npm-command: ci` header the
                //    npm client sets on `npm ci` traffic. If the
                //    prompt is on, ask once per (profile, ecosystem)
                //    burst; pass through if allowed.
                if ecosystem == .npm, policy.lockfilePrompt,
                   Self.headerValue("npm-command", inHeaderSection: String(
                        decoding: request.prefix(min(request.count, 4096)),
                        as: UTF8.self))?.lowercased() == "ci" {
                    let scope = "lockfile:npm"
                    let broker = supplyChainBroker
                    let allowed = await broker.consent(
                        profileID: profileID,
                        scope: scope,
                        scopeDisplayName: NSLocalizedString(
                            "npm ci (lockfile-pinned install)", comment: ""),
                        detail: NSLocalizedString(
                            "An agent is running `npm ci` — package tarballs come pre-pinned with cryptographic integrity hashes, so Bromure can't strip install scripts or age-filter them without breaking npm's verification.\n\nPass these tarballs through unmodified?",
                            comment: ""))
                    if !allowed {
                        let reason = "\(ecosystem.rawValue) lockfile-pinned install (`npm ci`) " +
                            "blocked — user denied bypass via Bromure consent prompt"
                        try? tls.write(SupplyChainEnforcer.blockResponse(reason: reason))
                        SupplyChainLog.shared.record(
                            "[supply-chain] lockfile-pinned 451: \(pkg)@\(version) — user denied bypass")
                        scOutcome = "blocked"
                        scReasonKind = "lockfile_denied"
                        scReason = reason
                        return
                    }
                }

                // 5. npm tarball script-strip (the only artifact
                //    transform — everything else just forwards
                //    unmodified after the pre-flight checks pass).
                if ecosystem == .npm,
                   policy.stripInstallScripts,
                   !policy.scriptStripAllows(ecosystem: ecosystem.rawValue, name: pkg) {
                    var didStripFlag = false
                    let relay = try await relayUpstreamBuffered(
                        rawRequest: toForward, host: host, port: port,
                        session: session, tls: tls,
                        rewrite: { raw in
                            let (out, didStrip) = NPMRegistryTransforms
                                .stripScriptsFromTarball(rawResponse: raw)
                            if didStrip {
                                didStripFlag = true
                                SupplyChainLog.shared.record(
                                    "[supply-chain] stripped install scripts from \(pkg)@\(version)")
                            }
                            return out
                        })
                    let elapsed = Date().timeIntervalSince(t0) * 1000
                    await emitTrace(host: host, port: port,
                                    preSwapRequest: request,
                                    upstreamResponse: relay.buffer,
                                    upstreamWireBytes: relay.wireBytes,
                                    responseTruncated: relay.truncatedForTrace,
                                    swaps: swap.swaps,
                                    leaks: leaks,
                                    latencyMs: elapsed)
                    if didStripFlag {
                        scOutcome = "stripped"
                        scReasonKind = "scripts_stripped"
                    }
                    return
                }

            case .passthrough:
                break
            }
        }

        // Prompt-injection enforcement (ask / block). Runs pre-forward so we
        // can stop a poisoned request before the model ever sees it. `log`
        // mode is handled post-response in emitTrace (zero added latency).
        // Bounded to AI hosts: the conversation parser returns nil otherwise.
        if let pi = Self.promptInjectionPolicyProvider?(profileID), pi.isActive,
           pi.onDetection != .log,
           let conv = ConversationParser.parse(host: host, requestBody: toForward,
                                               responseBody: nil) {
            var flagged: (detector: String, method: String, source: String, preview: String)? = nil
            if pi.detectSourceInjection {
                let spans = Self.newToolResultSpans(in: conv)
                if let preview = await PromptInjectionClassifier.shared.detect(spans: spans) {
                    flagged = ("prompt injection", "model", "tool output", preview)
                }
            }
            if flagged == nil, pi.detectRulesInjection {
                // Heuristic scanner first (catches obfuscation the model can't
                // read); then the ModernBERT semantic pass over the spans.
                if let hit = RulesFileScanner.shared.detect(systemPrompt: conv.systemPrompt) {
                    flagged = ("rogue instructions", "heuristic", hit.source, hit.preview)
                } else if let preview = await PromptInjectionClassifier.claudeMd.detect(
                            spans: RulesFileScanner.classifierSpans(conv.systemPrompt)) {
                    flagged = ("rogue instructions", "model", "CLAUDE.md", preview)
                }
            }
            if let f = flagged {
                let detectorCode = f.detector == "rogue instructions" ? "rules" : "source"
                let pid = profileID
                // Record + forward the *resolved outcome* (not just the mode):
                // block → "blocked"; ask → "allowed"/"blocked" by the user.
                func record(outcome: String) {
                    SupplyChainLog.shared.record(
                        "[prompt-injection] \(outcome): \(f.detector) in \(f.source) → \(host)")
                    PromptInjectionCloudEvent.emit(
                        profileID: pid, detector: detectorCode, method: f.method,
                        action: outcome, host: host, source: f.source, score: nil,
                        signals: [], toolUseId: nil, snippet: f.preview)
                }
                switch pi.onDetection {
                case .block:
                    record(outcome: "blocked")
                    try? tls.write(Self.injectionBlockResponse(detector: f.detector, source: f.source))
                    return
                case .ask:
                    let allow = await Self.promptInjectionBroker.consent(
                        profileID: profileID, detectorName: f.detector,
                        source: f.source, flaggedText: f.preview)
                    record(outcome: allow ? "allowed" : "blocked")
                    if !allow {
                        try? tls.write(Self.injectionBlockResponse(detector: f.detector, source: f.source))
                        return
                    }
                case .log:
                    break
                }
            }
        }

        // 6d. Fusion (prototype, BROMURE_FUSION=1). For Claude
        //     /v1/messages requests where the profile also holds an
        //     OpenAI credential, fan the dialogue out to both models,
        //     judge the two answers into a structured analysis, then
        //     synthesize a single final answer — delivered back in the
        //     guest's expected wire shape. Returns nil (no bytes
        //     written) when not eligible, so we fall through to the
        //     normal single-model relay below.
        // Engaged purely by the per-session UI toggle (the title-bar
        // lightning bolt). No env override — otherwise toggling Fusion
        // off in the UI wouldn't actually turn it off.
        // Local-inference routing (vLLM.md §4). For LLM hosts under
        // Local/Hybrid routing, re-route this turn to the on-host engine,
        // reached at the loopback splice the vsock-8446 bridge serves.
        // Pure decision; cloud is an identity pass-through. The session
        // key is the profile (one coding agent per VM) so a trajectory
        // never switches backend mid-stream (coherence guard, Trap 2).
        var upstreamHost = host
        var upstreamPort = port
        var routedBackend: Backend = .cloud
        var servedByMarker: String? = nil
        let routingCtx = Self.routingProvider?(profileID)
        if let routingCtx, LLMRouting.isLLMHost(host) {
            let target = LLMRouting.decide(
                host: host, port: port, context: routingCtx,
                sessionKey: profileID.uuidString,
                now: Date().timeIntervalSince1970)
            upstreamHost = target.host
            upstreamPort = target.port
            routedBackend = target.backend
            servedByMarker = target.servedBy
        }

        // Fusion is a cloud, identity-side feature — skip it when this
        // turn is routed local.
        let fusionOn = routedBackend == .cloud && (Self.fusionEngagedProvider?(profileID) ?? false)
        if fusionOn,
           let fusionConfig = Self.fusionConfigProvider?(profileID),
           let outcome = try await Fusion.run(rawRequest: toForward,
                                              host: host, port: port,
                                              session: session, tls: tls,
                                              swapper: swapper,
                                              config: fusionConfig,
                                              profileID: profileID) {
            let elapsed = Date().timeIntervalSince(t0) * 1000
            // Trace each upstream model call Fusion made (leg A/B, judge,
            // synth) so managed mode audits every provider hit — notably
            // the api.openai.com call. These run through the same trace +
            // cloud-LLM-extraction path as ordinary proxied requests.
            for sc in outcome.subCalls {
                await emitTrace(host: sc.host, port: sc.port,
                                preSwapRequest: sc.requestBlob,
                                upstreamResponse: sc.responseBlob,
                                upstreamWireBytes: sc.wireBytes,
                                responseTruncated: false,
                                swaps: [],
                                leaks: [],
                                latencyMs: sc.latencyMs)
            }
            // Then the guest-facing exchange (original request → fused reply).
            await emitTrace(host: host, port: port,
                            preSwapRequest: request,
                            upstreamResponse: outcome.buffer,
                            upstreamWireBytes: outcome.wireBytes,
                            responseTruncated: false,
                            swaps: swap.swaps,
                            leaks: leaks,
                            latencyMs: elapsed)
            return
        }

        // The local engine speaks plain HTTP on loopback; cloud is HTTPS.
        // Local inference can stream nothing back for a long time: the repair
        // proxy buffers the whole reply (stream:false) and a large model with a
        // big prompt can prefill/generate for minutes. The default 60s idle
        // timeout would abort it (-1001) and tear down the connection, so use a
        // long-timeout loopback session for the local leg. (The cert-challenge
        // delegate is irrelevant on plain-HTTP loopback.)
        var relaySession = session
        var ownsRelaySession = false
        if routedBackend == .local {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 1800    // 30 min idle cap
            cfg.timeoutIntervalForResource = 3600
            relaySession = URLSession(configuration: cfg)
            ownsRelaySession = true
        }
        defer { if ownsRelaySession { relaySession.finishTasksAndInvalidate() } }
        let relay = try await relayUpstream(rawRequest: toForward,
                                            host: upstreamHost, port: upstreamPort,
                                            session: relaySession,
                                            tls: tls,
                                            upstreamScheme: routedBackend == .local ? "http" : "https")

        // Feed the hybrid policy engine from this cloud turn (§4.3). The
        // streaming relay already committed the response, so we can't replay
        // *this* turn — but the health gate (TTFT EWMA + error rate) and the
        // rolling token budget steer *subsequent* sessions, at session
        // granularity (the sticky-session coherence guard).
        if let routingCtx, routingCtx.routing == .hybrid, routedBackend == .cloud {
            let now = Date().timeIntervalSince1970
            let session = profileID.uuidString
            if LLMRouting.isHardErrorStatus(Self.parseStatusCode(relay.buffer)) {
                routingCtx.hybrid.recordHardError(sessionID: session, now: now)
            } else {
                // Health gate: time-to-first-token. Soft-timeout TTFTs feed in
                // as slow samples too (a slow first token raises the EWMA).
                if let ttft = relay.ttftSeconds {
                    routingCtx.hybrid.recordSuccess(ttftSeconds: ttft)
                }
                // Budget: cloud output tokens against the rolling window.
                if let toks = Self.extractOutputTokens(relay.buffer) {
                    routingCtx.hybrid.recordCloudTokens(toks, now: now)
                }
            }
        }

        // Claude subscription 401 self-heal. The streaming relay has already
        // committed the response to the guest, so we can't retry transparently
        // — instead refresh the shared token in the background so the *next*
        // request uses a fresh one (and Claude Code retries the failed call on
        // its own). De-duped in the refresher against concurrent 401s.
        if let stale = claudeSubStaleAccess,
           Self.parseStatusCode(relay.buffer) == 401,
           let provider = Self.claudeSubscriptionProvider, let (_, refresher) = provider() {
            let pid = profileID
            Task { await refresher.noteUnauthorized(stale: stale, for: pid) }
        }
        if let stale = codexSubStaleAccess,
           Self.parseStatusCode(relay.buffer) == 401,
           let provider = Self.codexSubscriptionProvider, let (_, refresher) = provider() {
            let pid = profileID
            Task { await refresher.noteUnauthorized(stale: stale, for: pid) }
        }
        if let stale = grokSubStaleAccess,
           Self.parseStatusCode(relay.buffer) == 401,
           let provider = Self.grokSubscriptionProvider, let (_, refresher) = provider() {
            let pid = profileID
            Task { await refresher.noteUnauthorized(stale: stale, for: pid) }
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
                        latencyMs: elapsed,
                        servedBy: servedByMarker)
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
    @available(macOS, deprecated: 10.15, message: "takes TLSServerStream which wraps SecureTransport")
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
                           latencyMs: Double,
                           servedBy: String? = nil) async {
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

            // Prompt-injection scan — only when the profile enabled it and the
            // action is "log but continue". ask/block run pre-forward in
            // handleConnection (they must, to stop the request). Detached so
            // logging never delays the trace write; emitTrace runs after the
            // response was already relayed, so this adds zero agent latency.
            let piPolicy = Self.promptInjectionPolicyProvider?(profileID)
            if let pi = piPolicy, pi.isActive, pi.onDetection == .log {
                let pid = profileID
                if pi.detectSourceInjection {
                    let untrusted = Self.newToolResultSpans(in: conv)
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
                    RulesFileScanner.shared.scanAndLog(
                        systemPrompt: conv.systemPrompt, host: host, profileID: pid)
                    let ruleSpans = RulesFileScanner.classifierSpans(conv.systemPrompt)
                    if !ruleSpans.isEmpty {
                        Task.detached(priority: .utility) {
                            await PromptInjectionClassifier.claudeMd.scanAndLog(
                                spans: ruleSpans, host: host, profileID: pid)
                        }
                    }
                }
            }
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

    /// Pull the untrusted `tool_result` spans that were freshly added
    /// this turn. The request re-sends the whole history every turn, so
    /// we scan only the last message that carries tool_results (the
    /// newest external ingestion) rather than re-scanning — and
    /// re-logging — every prior result. Each element is the result's
    /// `(toolUseId, content)`.
    private static func newToolResultSpans(
        in conv: Conversation
    ) -> [(id: String?, content: String)] {
        for message in conv.messages.reversed() {
            var spans: [(id: String?, content: String)] = []
            for block in message.content {
                if case let .toolResult(toolUseId, content, _) = block,
                   !content.isEmpty {
                    spans.append((id: toolUseId, content: content))
                }
            }
            if !spans.isEmpty { return spans }
        }
        return []
    }

    /// 451 response the guest sees when a prompt-injection detection blocks the
    /// request (block mode, or ask → denied). The agent gets a hard HTTP error
    /// instead of the model reply; no byte reaches the AI host.
    private static func injectionBlockResponse(detector: String, source: String) -> Data {
        let body = "Bromure blocked this request: possible \(detector) detected in \(source).\n"
        var r = "HTTP/1.1 451 Unavailable For Legal Reasons\r\n"
        r += "Content-Type: text/plain; charset=utf-8\r\n"
        r += "Content-Length: \(body.utf8.count)\r\n"
        r += "Connection: close\r\n\r\n"
        r += body
        return Data(r.utf8)
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

    /// Case-insensitive lookup of a header value in a CRLF-delimited header
    /// section (request line included; we skip it). nil if absent.
    static func headerValue(_ name: String, inHeaderSection text: String) -> String? {
        let wanted = name.lowercased()
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if key == wanted {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Downgrade an npm packument request's `Accept` to plain JSON.
    ///
    /// `npm install` asks for the abbreviated "corgi" packument
    /// (`Accept: application/vnd.npm.install-v1+json`), which the registry
    /// returns WITHOUT the `time` map. The age gate keys every drop/record
    /// decision off `time`, so on the exact path it's meant to protect it
    /// silently no-ops — a normal install of a brand-new (or just-published,
    /// likely-malicious) version sails straight through. Forcing the full
    /// packument restores `time`, so `filterMetadata` records publish times
    /// AND filters too-fresh versions out of what npm resolves against. npm
    /// accepts the full document fine; the only cost is a larger response.
    static func forceFullNpmPackument(_ rawRequest: Data) -> Data {
        guard let headerEnd = rawRequest.range(of: Data("\r\n\r\n".utf8)),
              var header = String(data: rawRequest.subdata(in: rawRequest.startIndex..<headerEnd.lowerBound),
                                  encoding: .isoLatin1),
              header.lowercased().contains("vnd.npm.install") else { return rawRequest }
        var lines = header.components(separatedBy: "\r\n")
        for idx in lines.indices where lines[idx].lowercased().hasPrefix("accept:") {
            lines[idx] = "Accept: application/json"
        }
        header = lines.joined(separator: "\r\n")
        var out = Data(header.utf8)
        out.append(rawRequest.subdata(in: headerEnd.lowerBound..<rawRequest.endIndex))
        return out
    }

    /// The header block of a raw HTTP request (request line + headers, up to
    /// but excluding the blank line), decoded body-agnostically, or nil if
    /// there's no blank line.
    ///
    /// HTTP header bytes are ASCII and Latin-1 maps every byte 1:1 (it never
    /// returns nil), so this yields the headers even when the *body* is binary
    /// — a gzip artifact upload, protobuf, etc. The swap + leak paths used to
    /// decode the whole request as UTF-8, which returned nil on a single
    /// non-UTF-8 body byte; that silently skipped subscription-token swaps
    /// (bogus token left on the wire → HTTP 401) and credential-leak
    /// suppression (false-positive `LEAK authorization=…` warnings) for e.g.
    /// Grok's `*.tar.gz` session-state and OTLP `/v1/traces` uploads.
    /// Suitable to pass to `headerValue(_:inHeaderSection:)`.
    static func rawHeaderSection(of raw: Data) -> String? {
        guard let end = raw.range(of: Data("\r\n\r\n".utf8))?.lowerBound else { return nil }
        return String(data: raw.subdata(in: raw.startIndex..<end), encoding: .isoLatin1)
    }

    /// Replace a raw request's header block with `newHeader`, keeping the
    /// original — possibly binary — body byte-for-byte (Content-Length stays
    /// valid because the body is untouched). `newHeader` is the transformed
    /// header block *without* the trailing blank line.
    static func spliceHeaderSection(of raw: Data, newHeader: String) -> Data {
        guard let sep = raw.range(of: Data("\r\n\r\n".utf8)) else {
            return newHeader.data(using: .isoLatin1) ?? raw
        }
        var out = newHeader.data(using: .isoLatin1) ?? Data()
        out.append(raw.subdata(in: sep.lowerBound..<raw.endIndex))   // "\r\n\r\n" + body
        return out
    }

    /// Turn a guest API-key request into a Claude subscription request: drop
    /// `x-api-key` and any existing `Authorization`, set `Authorization: Bearer
    /// <access>`, and ensure `anthropic-beta` carries the OAuth flag (merged,
    /// not clobbered). Body is untouched, so Content-Length stays valid.
    static func injectClaudeSubscriptionAuth(rawRequest raw: Data, access: String) -> Data {
        guard let headerBlock = Self.rawHeaderSection(of: raw) else { return raw }
        let oauthBeta = "oauth-2025-04-20"
        var outLines: [String] = []
        var sawBeta = false
        for line in headerBlock.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("x-api-key:") { continue }       // drop the bogus key
            if lower.hasPrefix("authorization:") { continue }   // we set our own
            if lower.hasPrefix("anthropic-beta:"), let colon = line.firstIndex(of: ":") {
                sawBeta = true
                let existing = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                let parts = existing.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let merged = parts.contains(oauthBeta) ? existing
                    : (existing.isEmpty ? oauthBeta : existing + "," + oauthBeta)
                outLines.append("anthropic-beta: \(merged)")
            } else {
                outLines.append(line)
            }
        }
        outLines.append("Authorization: Bearer \(access)")
        if !sawBeta { outLines.append("anthropic-beta: \(oauthBeta)") }
        return Self.spliceHeaderSection(of: raw, newHeader: outLines.joined(separator: "\r\n"))
    }

    /// The token from an `Authorization: Bearer <token>` header (or nil).
    static func bearerToken(inHeaderSection text: String) -> String? {
        guard let v = headerValue("authorization", inHeaderSection: text) else { return nil }
        let prefix = "Bearer "
        guard v.count > prefix.count,
              v.lowercased().hasPrefix(prefix.lowercased()) else { return nil }
        return String(v.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    /// Rewrite the request's `Authorization` header to `Bearer <token>`,
    /// preserving everything else (and the body / Content-Length). Operates on
    /// raw bytes so a binary body survives untouched.
    static func replaceAuthorizationBearer(rawRequest raw: Data, token: String) -> Data {
        guard let headerBlock = Self.rawHeaderSection(of: raw) else { return raw }
        var outLines: [String] = []
        var replaced = false
        for line in headerBlock.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("authorization:") {
                outLines.append("Authorization: Bearer \(token)")
                replaced = true
            } else {
                outLines.append(line)
            }
        }
        if !replaced { outLines.append("Authorization: Bearer \(token)") }
        return Self.spliceHeaderSection(of: raw, newHeader: outLines.joined(separator: "\r\n"))
    }

    /// Extract the `Action` value from a form-urlencoded AWS query-protocol
    /// body (e.g. `Action=TerminateInstances&Version=…`). `Action` need not
    /// be the first field.
    static func formActionValue(_ body: String) -> String? {
        for pair in body.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2, kv[0] == "Action" {
                return kv[1].removingPercentEncoding ?? String(kv[1])
            }
        }
        return nil
    }

    /// Extract a query-string parameter from a request path
    /// (`/?query=SELECT+1&database=x` → "SELECT 1"). Percent- and
    /// `+`-decoded. nil if the path has no query string or no such key.
    static func urlQueryParam(_ name: String, inPath path: String) -> String? {
        guard let q = path.firstIndex(of: "?") else { return nil }
        let query = path[path.index(after: q)...]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2, kv[0] == name else { continue }
            let plusDecoded = kv[1].replacingOccurrences(of: "+", with: " ")
            return plusDecoded.removingPercentEncoding ?? plusDecoded
        }
        return nil
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

    /// Best-effort output-token count from an LLM response (Anthropic
    /// `output_tokens` / OpenAI `completion_tokens`). Returns the max value
    /// seen — for streamed SSE the final `message_delta` carries the
    /// cumulative total. Feeds the hybrid cloud-token budget.
    static func extractOutputTokens(_ buffer: Data) -> Int? {
        guard let s = String(data: buffer, encoding: .utf8) else { return nil }
        var best: Int?
        for pattern in [#""output_tokens"\s*:\s*(\d+)"#, #""completion_tokens"\s*:\s*(\d+)"#] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            re.enumerateMatches(in: s, range: NSRange(s.startIndex..., in: s)) { m, _, _ in
                if let m, let r = Range(m.range(at: 1), in: s), let n = Int(s[r]) {
                    best = max(best ?? 0, n)
                }
            }
        }
        return best
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
    let (rawData, resp) = try await session.data(for: req)
    let http = (resp as? HTTPURLResponse)
    // URLSession only auto-decompresses when *we* didn't set
    // Accept-Encoding. Since we forward the client's request
    // headers verbatim (including its Accept-Encoding), URLSession
    // hands us the compressed body untouched. Decompress here so
    // downstream transforms (filterMetadata, filterPyPIJSON, …)
    // always see plain bytes — and the client gets a body that
    // matches the Content-Encoding-less head we emit.
    var data = rawData
    if let http,
       let enc = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased(),
       enc == "gzip" || enc == "deflate" || enc == "br" {
        if let inflated = decompressBody(rawData, encoding: enc) {
            data = inflated
        }
    }
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

/// Decompress an HTTP response body whose `Content-Encoding` is
/// gzip / deflate / br. Returns nil on any error so the caller can
/// fall back to forwarding the raw bytes (still safer than letting
/// downstream transforms run on undecoded data).
private func decompressBody(_ data: Data, encoding: String) -> Data? {
    switch encoding {
    case "gzip":
        return gunzipData(data)
    case "deflate":
        // Some servers send raw deflate, others zlib-wrapped.
        // Try zlib first (the more common shape), then raw deflate.
        return inflateData(data, format: .zlib)
            ?? inflateData(data, format: .raw)
    case "br":
        // Brotli isn't supported by Compression.framework on macOS;
        // bail and let the caller forward the compressed payload as
        // a last resort. The 3 hosts we tag against (npm/PyPI/CDN)
        // honour gzip when offered, so this branch is rarely hit.
        return nil
    default:
        return nil
    }
}

private enum DeflateFormat { case zlib, raw }

private func gunzipData(_ data: Data) -> Data? {
    // gzip wrapper: 10-byte header (with optional FEXTRA/FNAME/FCOMMENT
    // sections), raw deflate payload, 8-byte trailer. Strip the
    // wrapper and feed raw deflate to Compression.framework.
    guard data.count > 18,
          data[0] == 0x1f, data[1] == 0x8b, data[2] == 0x08 else { return nil }
    var offset = 10
    let flags = data[3]
    if flags & 0x04 != 0 {
        guard offset + 2 <= data.count else { return nil }
        let xlen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
        offset += 2 + xlen
    }
    if flags & 0x08 != 0 {
        while offset < data.count, data[offset] != 0 { offset += 1 }
        offset += 1
    }
    if flags & 0x10 != 0 {
        while offset < data.count, data[offset] != 0 { offset += 1 }
        offset += 1
    }
    if flags & 0x02 != 0 { offset += 2 }
    guard offset < data.count - 8 else { return nil }
    let payload = data.subdata(in: offset..<(data.count - 8))
    return inflateData(payload, format: .raw)
}

private func inflateData(_ data: Data, format: DeflateFormat) -> Data? {
    // Compression.framework streaming inflate. Output capped at
    // 64 MiB — npm/PyPI metadata never exceeds a few MB; this guards
    // against a pathological compression bomb.
    let algorithm: compression_algorithm
    switch format {
    case .raw: algorithm = COMPRESSION_ZLIB   // .zlib is "raw deflate" in Apple-speak
    case .zlib:
        // zlib has a 2-byte header + 4-byte adler trailer. Strip
        // them and feed the raw deflate.
        guard data.count > 6 else { return nil }
        let stripped = data.subdata(in: 2..<(data.count - 4))
        return inflateData(stripped, format: .raw)
    }
    let chunkSize = 64 * 1024
    let outCap = 64 * 1024 * 1024
    var out = Data()
    let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
    defer { stream.deallocate() }
    var status = compression_stream_init(stream, COMPRESSION_STREAM_DECODE, algorithm)
    guard status == COMPRESSION_STATUS_OK else { return nil }
    defer { compression_stream_destroy(stream) }
    let dstBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
    defer { dstBuf.deallocate() }
    let result: Data? = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
        guard let srcBase = src.baseAddress else { return nil }
        stream.pointee.src_ptr = srcBase.assumingMemoryBound(to: UInt8.self)
        stream.pointee.src_size = data.count
        stream.pointee.dst_ptr = dstBuf
        stream.pointee.dst_size = chunkSize
        repeat {
            status = compression_stream_process(stream,
                                                Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            switch status {
            case COMPRESSION_STATUS_OK, COMPRESSION_STATUS_END:
                let produced = chunkSize - stream.pointee.dst_size
                out.append(dstBuf, count: produced)
                if out.count > outCap { return nil }
                stream.pointee.dst_ptr = dstBuf
                stream.pointee.dst_size = chunkSize
            default:
                return nil
            }
        } while status != COMPRESSION_STATUS_END
        return out
    }
    return result
}

/// Fire-and-forget supply-chain event to the workspace backend. Emits
/// one `supply_chain.fetch` row per package fetch the MITM intercepts.
/// `BACEventEmitter.shared.emitDetached` already gates on enrollment
/// (no install identity → no-op) and per-profile private mode, so this
/// is safe to call from every supply-chain branch unconditionally.
///
/// Event shape consumed by `ac_events.event_data`:
///   { ecosystem, package, version?, kind, outcome,
///     reason_kind?, reason? }
private func emitSupplyChainFetch(profileID: UUID,
                                   ecosystem: String,
                                   package: String,
                                   version: String?,
                                   kind: String,
                                   outcome: String,
                                   reasonKind: String? = nil,
                                   reason: String? = nil) {
    var data: [String: AnyJSON] = [
        "ecosystem": .string(ecosystem),
        "package": .string(package),
        "kind": .string(kind),
        "outcome": .string(outcome),
    ]
    if let version { data["version"] = .string(version) }
    if let reasonKind { data["reason_kind"] = .string(reasonKind) }
    if let reason { data["reason"] = .string(reason) }
    BACEventEmitter.shared.emitDetached(
        profileID: profileID,
        eventType: "supply_chain.fetch",
        eventData: data)
}

@available(macOS, deprecated: 10.15)
private func relayUpstream(rawRequest: Data, host: String, port: Int,
                           session: URLSession,
                           tls: TLSServerStream,
                           upstreamScheme: String = "https") async throws -> RelayResponse {
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

    // CONNECT tunnels are TLS by definition — the port is just where the
    // upstream listens (e.g. 6443 for k8s API servers, 8443 for some
    // internal stacks). Cloud upstreams replay as https so URLSession does
    // a real TLS handshake. The local inference engine, however, speaks
    // plain HTTP on loopback, so `upstreamScheme` is "http" when routing
    // re-targeted this request there — otherwise the TLS handshake fails
    // (NSURLErrorSecureConnectionFailed) and every local turn dies.
    let portStr = (port == 443) ? "" : ":\(port)"
    guard let url = URL(string: "\(upstreamScheme)://\(host)\(portStr)\(path)") else {
        throw MitmError.malformedHTTPRequest
    }

    var req = URLRequest(url: url)
    req.httpMethod = method
    if !body.isEmpty { req.httpBody = body }

    // When re-routed to the local engine, the request still carries the
    // guest's cloud auth (a swapped fake key). The engine authenticates with
    // its own per-session key, so drop the cloud auth headers and inject the
    // engine Bearer key instead — otherwise it 401s.
    let local = (upstreamScheme == "http" && host == InferenceService.engineHost)
    // The explicit-local path carries the guest's per-VM engine key (a valid
    // EngineKey). Preserve it so the downstream repair proxy can identify the
    // workspace and resolve the `bromure-local` model sentinel — and the engine
    // accepts it directly. Only swap in the admin key when the guest sent a
    // cloud credential the engine can't use (the hybrid cloud→local fallback).
    let guestBearer: String? = lines.compactMap { line -> String? in
        guard let colon = line.firstIndex(of: ":"),
              String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased() == "authorization"
        else { return nil }
        let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        return v.hasPrefix("Bearer ") ? String(v.dropFirst(7)) : v
    }.first
    let keepGuestKey = local && (guestBearer.map { EngineKey.profileID(forKey: $0) != nil } ?? false)
    for line in lines where !line.isEmpty {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        // Don't replay hop-by-hop / framing headers — URLSession sets these.
        switch name.lowercased() {
        case "host", "content-length", "connection", "transfer-encoding",
             "proxy-connection", "keep-alive", "te", "upgrade":
            continue
        case "authorization", "x-api-key":
            if local && !keepGuestKey { continue }   // replaced below for the local engine
            req.setValue(value, forHTTPHeaderField: name)
        default:
            req.setValue(value, forHTTPHeaderField: name)
        }
    }
    if local && !keepGuestKey {
        req.setValue("Bearer \(InferenceService.apiKey)", forHTTPHeaderField: "Authorization")
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
    let reqStart = Date()
    var ttft: Double? = nil
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
            if ttft == nil { ttft = Date().timeIntervalSince(reqStart) }
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
                         truncatedForTrace: truncatedForTrace,
                         ttftSeconds: ttft)
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
    /// Seconds from request start to the first body chunk — the upstream's
    /// time-to-first-token. Feeds the hybrid health gate. nil for the
    /// buffered path (no streaming timing).
    var ttftSeconds: Double? = nil
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

    /// Accept a server cert that the SSL policy rejected *only* because of
    /// Apple's 398-day max-validity rule (which can fire on any cert in the
    /// chain — the long-lived self-signed cluster CA or the API server leaf).
    ///
    /// We re-evaluate the same trust (anchors still pinned to the user's
    /// cluster CA) with a **Basic X.509** policy, which checks chain-to-anchor
    /// and per-cert temporal validity (expired / not-yet-valid) but does NOT
    /// apply the SSL-only 398-day span rule. If that passes, the cert really
    /// does chain to the CA the user pinned for this host and isn't expired.
    /// Basic X.509 skips hostname binding, so we re-add it ourselves
    /// (best-effort) against the leaf's SANs — only refusing on a positive
    /// mismatch, never on a parsing gap.
    static func acceptPinnedDespiteValidityPeriod(_ trust: SecTrust, host: String) -> Bool {
        let basic = SecPolicyCreateBasicX509()
        SecTrustSetPolicies(trust, [basic] as CFArray)
        var err: CFError?
        guard SecTrustEvaluateWithError(trust, &err) else { return false }
        // Index 0 of the evaluated chain is the leaf. (SecTrustGetCertificateAtIndex
        // was deprecated in macOS 12; SecTrustCopyCertificateChain is the
        // replacement and returns the full chain leaf-first.)
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return true }
        return hostnameMatch(leaf, host: host) != .mismatch
    }

    private enum HostMatch { case match, mismatch, noSANs }

    /// Best-effort hostname/IP match against the leaf cert's SANs. Returns
    /// `.noSANs` (treated as acceptable) when we can't read SANs, so a parsing
    /// limitation never blocks a connection that already chained to the pinned
    /// CA.
    private static func hostnameMatch(_ cert: SecCertificate, host: String) -> HostMatch {
        guard let values = SecCertificateCopyValues(
                cert, [kSecOIDSubjectAltName] as CFArray, nil) as? [CFString: Any],
              let san = values[kSecOIDSubjectAltName] as? [CFString: Any],
              let entries = san[kSecPropertyKeyValue] as? [[CFString: Any]] else {
            return .noSANs
        }
        let target = host.lowercased()
        let targetIsIP = target.allSatisfy { $0.isNumber || $0 == "." || $0 == ":" }
        var sawAny = false
        for entry in entries {
            guard let value = (entry[kSecPropertyKeyValue] as? String)?.lowercased() else { continue }
            let label = (entry[kSecPropertyKeyLabel] as? String)?.lowercased() ?? ""
            sawAny = true
            if targetIsIP {
                if label.contains("ip"), value == target { return .match }
            } else if label.contains("dns") || label.contains("name") {
                if value == target { return .match }
                if value.hasPrefix("*.") {
                    let suffix = value.dropFirst(1)            // ".example.com"
                    if target.hasSuffix(suffix),
                       !target.dropLast(suffix.count).contains(".") { return .match }
                }
            }
        }
        return sawAny ? .mismatch : .noSANs
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
            } else if Self.acceptPinnedDespiteValidityPeriod(trust, host: host) {
                // The user explicitly pinned this cluster CA, so Apple's
                // 398-day SSL max-validity policy shouldn't reject the
                // long-lived self-signed kube-apiserver cert it issued. We
                // re-checked with a Basic X.509 policy (chain-to-pinned-anchor
                // + not expired, *without* the SSL-only 398-day rule) plus a
                // best-effort hostname match, so this isn't a blanket bypass.
                FileHandle.standardError.write(Data(
                    "[mitm] \(host): cert chains to the pinned cluster CA (Basic X.509 ok); accepting despite Apple's 398-day SSL max-validity rule\n".utf8))
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
