import Foundation

/// The agents' subscription sign-ins on the wire: a workspace's stand-in
/// credentials swapped for the host's live tokens, the stand-in refreshes
/// answered by the host, and the header edits they take. Foundation only:
/// HTTPMitmConnection (macOS) and the Linux server's proxy both run it, so
/// the two swap the same way.
enum SubscriptionAuthRewrite {
    /// The live tokens a request was given, per agent, for the post-relay
    /// 401 self-heal (`noteUnauthorized`).
    struct Injected: Sendable {
        var claude: String?
        var codex: String?
        var grok: String?
        var kimi: String?
    }

    enum Outcome {
        /// Send this request on (its stand-ins swapped for live tokens).
        case forward(Data, Injected)
        /// Answer the guest with this reply; nothing goes upstream.
        case answer(Data)
    }

    /// A workspace's request as the proxy sends it: its subscription
    /// stand-ins swapped for the host's live tokens, or the host's own
    /// answer (a stand-in refresh, a sign-in that can't be renewed). The
    /// caller skips it for an insecure-bypass request; `spooledBody` is a
    /// body streamed from disk (never a refresh).
    static func apply(rawRequest: Data, host: String, method reqMethod: String, path reqPath: String,
                      profileID: UUID, spooledBody: Bool) async -> Outcome {
        var req = rawRequest
        var injected = Injected()

        // 5c. Claude subscription auth. In subscription mode the guest runs in
        //     API-key mode with a *bogus* ANTHROPIC_API_KEY (so it never does
        //     OAuth and never stores a real credential). Here we turn that into
        //     a real subscription request: drop x-api-key, add Authorization:
        //     Bearer <live access token> + the OAuth beta header. The token is
        //     held only on the host, in a store shared by every session, and
        //     the host owns its refresh — so one refresh serves all VMs.
        //     `injected.claude` carries the injected token to the post-relay
        //     401 self-heal (noteUnauthorized).
        // 5c'. …and with account features on, the machine holds an OAuth
        //     stand-in (ClaudeStandIn) and sends it as Bearer to Anthropic's
        //     and Claude's hosts: a value swap for the live token.
        if Self.isClaudeHost(host),
           let provider = SubscriptionProviders.claude, let (_, refresher) = provider(),
           let headerSection = Self.rawHeaderSection(of: req),
           let bearer = Self.bearerToken(inHeaderSection: headerSection),
           Self.isClaudeStandIn(bearer, profileID: profileID) {
            do {
                let access = try await refresher.accessToken(for: profileID)
                req = Self.replaceAuthorizationBearer(rawRequest: req, token: access)
                injected.claude = access
                FileHandle.standardError.write(Data(
                    "[mitm] swapped Claude OAuth stand-in for \(host)\(reqPath)\n".utf8))
            } catch {
                let rejected = (error as? ClaudeSubscriptionError)?.isRejection ?? false
                let reply = rejected
                    ? SignInCapture.response(status: 401, reason: "Unauthorized", json: [
                        "type": "error",
                        "error": ["type": "authentication_error",
                                  "message": "Your Claude sign-in expired. Sign in again from Bromure (the workspace's sign-in card or Preferences → Models) — not with /login inside the VM."],
                    ])
                    : SignInCapture.response(status: 529, reason: "Overloaded", json: [
                        "type": "error",
                        "error": ["type": "overloaded_error",
                                  "message": "Bromure couldn't renew the Claude sign-in just now; retrying."],
                    ])
                return .answer(reply)
            }
        }
        if host == "api.anthropic.com" || host.hasSuffix(".anthropic.com"),
           let provider = SubscriptionProviders.claude, let (store, refresher) = provider(),
           let headerSection = Self.rawHeaderSection(of: req),
           let apiKey = Self.headerValue("x-api-key", inHeaderSection: headerSection),
           store.profileForBogusKey(apiKey) != nil {
            do {
                let access = try await refresher.accessToken(for: profileID)
                req = Self.injectClaudeSubscriptionAuth(rawRequest: req, access: access)
                injected.claude = access
                Self.logTokenInjection("Claude subscription token", host: host, profileID: profileID)
            } catch {
                FileHandle.standardError.write(Data(
                    "[mitm] Claude subscription token unavailable for \(host): \(error)\n".utf8))
                // Never forward the bogus key: Anthropic would answer "invalid
                // x-api-key" and Claude Code would tell the user to /login —
                // which, in the guest, would mint a separate grant inside the
                // VM. Answer here instead: a transient failure (network, 5xx,
                // 429) as a retryable 529 that Claude Code backs off and
                // retries; a rejected grant as a 401 that says where to fix it.
                let rejected = (error as? ClaudeSubscriptionError)?.isRejection ?? false
                let reply = rejected
                    ? SignInCapture.response(status: 401, reason: "Unauthorized", json: [
                        "type": "error",
                        "error": ["type": "authentication_error",
                                  "message": "Your Claude sign-in expired. Sign in again from Bromure (the workspace's sign-in card or Preferences → Models) — not with /login inside the VM."],
                    ])
                    : SignInCapture.response(status: 529, reason: "Overloaded", json: [
                        "type": "error",
                        "error": ["type": "overloaded_error",
                                  "message": "Bromure couldn't renew the Claude sign-in just now; retrying."],
                    ])
                return .answer(reply)
            }
        }

        // 5d. Codex / ChatGPT subscription auth. The guest's ~/.codex/auth.json
        //     holds a *bogus* far-future-exp JWT (so it never refreshes); on the
        //     ChatGPT backend it sends that as `Authorization: Bearer`. Swap it
        //     for the live real access token from the host store, which the host
        //     refreshes. Distinct from the Claude path (x-api-key → Bearer):
        //     here the guest already sends a Bearer, so it's a value swap.
        if host == "chatgpt.com" || host.hasSuffix(".chatgpt.com") || host == "api.openai.com",
           let provider = SubscriptionProviders.codex, let (_, refresher) = provider(),
           let headerSection = Self.rawHeaderSection(of: req),
           let bearer = Self.bearerToken(inHeaderSection: headerSection),
           Self.isCodexStandIn(bearer, profileID: profileID) {
            do {
                let access = try await refresher.accessToken(for: profileID)
                req = Self.replaceAuthorizationBearer(rawRequest: req, token: access)
                injected.codex = access
                Self.logTokenInjection("Codex subscription token", host: host, profileID: profileID)
            } catch {
                FileHandle.standardError.write(Data(
                    "[mitm] Codex subscription token unavailable for \(host): \(error)\n".utf8))
                // Never forward the stand-in (or a dead token): answer here.
                // A rejected / flagged login → a 401 that says where to sign
                // in (Codex then prints its "sign in again" banner, which the
                // session turns into a sign-in card); a transient failure → a
                // retryable 503.
                let rejected = (error as? CodexSubscriptionError)?.isRejection ?? false
                let reply = rejected
                    ? SignInCapture.response(status: 401, reason: "Unauthorized",
                                             json: CodexSignInExpired.apiErrorJSON)
                    : SignInCapture.response(status: 503, reason: "Service Unavailable", json: [
                        "error": ["message": "Bromure couldn't renew the ChatGPT sign-in just now; retrying.",
                                  "type": "server_error"] as [String: Any],
                    ])
                return .answer(reply)
            }
        }

        // 5e. Grok (xAI) subscription auth. The guest's ~/.grok/auth.json holds
        //     a bogus OIDC token with a far-future expiry (so it never
        //     refreshes); on the chat proxy it sends that as Bearer. Swap it for
        //     the live real access token from the host store, which the host
        //     refreshes against auth.x.ai.
        if host == "cli-chat-proxy.grok.com" || host.hasSuffix(".grok.com")
            || host == "x.ai" || host.hasSuffix(".x.ai"),
           let provider = SubscriptionProviders.grok, let (_, refresher) = provider(),
           let headerSection = Self.rawHeaderSection(of: req),
           let bearer = Self.bearerToken(inHeaderSection: headerSection),
           Self.isGrokStandIn(bearer, profileID: profileID) {
            do {
                let access = try await refresher.accessToken(for: profileID)
                req = Self.replaceAuthorizationBearer(rawRequest: req, token: access)
                injected.grok = access
                Self.logTokenInjection("Grok subscription token", host: host, profileID: profileID)
            } catch {
                FileHandle.standardError.write(Data(
                    "[mitm] Grok subscription token unavailable for \(host): \(error)\n".utf8))
                // Never forward the stand-in (or a dead token): a rejected /
                // flagged login → a 401 that says where to sign in; a
                // transient failure → a retryable 503.
                let rejected = (error as? GrokSubscriptionError)?.isRejection ?? false
                return .answer(Self.subscriptionUnavailableReply(provider: "Grok", rejected: rejected))
            }
        }

        // 5f. Kimi (Moonshot) subscription auth. The guest's
        //     ~/.kimi-code/credentials/<name>.json holds a bogus OAuth token
        //     with a far-future expiry (so the CLI never refreshes); it sends
        //     that as Bearer to api.kimi.ai/coding/v1. Swap it for the live
        //     real access token from the host store, which the host refreshes
        //     against auth.kimi.ai (the international region; see KimiRegion).
        if KimiRegion.isSubscriptionHost(host),
           let provider = SubscriptionProviders.kimi, let (_, refresher) = provider(),
           let headerSection = Self.rawHeaderSection(of: req),
           let bearer = Self.bearerToken(inHeaderSection: headerSection),
           Self.isKimiStandIn(bearer, profileID: profileID) {
            do {
                let access = try await refresher.accessToken(for: profileID)
                req = Self.replaceAuthorizationBearer(rawRequest: req, token: access)
                injected.kimi = access
                Self.logTokenInjection("Kimi subscription token", host: host, profileID: profileID)
            } catch {
                FileHandle.standardError.write(Data(
                    "[mitm] Kimi subscription token unavailable for \(host): \(error)\n".utf8))
                let rejected = (error as? KimiSubscriptionError)?.isRejection ?? false
                return .answer(Self.subscriptionUnavailableReply(provider: "Kimi", rejected: rejected))
            }
        }

        // 5f′. Kimi stand-in refresh. The guest's credential file holds a
        //     bogus refresh token it is never meant to use — but kimi 2.0.x
        //     FORCES a refresh (`ensureFresh({force:true})`) the moment its
        //     managed-models provisioning call gets a 401, and a refresh that
        //     auth.kimi.ai rejects is persisted as a revoked tombstone (empty
        //     access token): the CLI reports "requires login" from then on,
        //     until the next re-seed. So when the guest POSTs
        //     `grant_type=refresh_token` with ANY of our stand-ins (an older
        //     one too: a machine resumed across an app restart or a host-side
        //     rotation still holds it), answer it here: refresh the REAL
        //     credential host-side (forced, rate-limited) and hand back fresh
        //     stand-ins minted from the current real record. The real refresh
        //     token never enters the VM; a genuine (non-stand-in) refresh —
        //     e.g. the registration VM's own login — passes through untouched.
        //
        // 5e″. Grok stand-in refresh, the same way: Grok refreshes when xAI
        //     turns a request down (a 401 — which an unrecognised stand-in
        //     used to cause after an app restart), and its stand-in refresh
        //     token sent on to auth.x.ai was rejected: Grok logged out.
        if !spooledBody,
           let reply = await Self.answerStandInRefresh(host: host, method: reqMethod, path: reqPath,
                                                       rawRequest: req, profileID: profileID) {
            return .answer(reply)
        }

        // 5c''. Claude stand-in refresh: answered here with the stand-in
        //     again (the host keeps the real login fresh), never sent on.
        if !spooledBody, reqMethod.uppercased() == "POST",
           Self.isClaudeHost(host), reqPath.hasPrefix("/v1/oauth/token"),
           let provider = SubscriptionProviders.claude, let (store, refresher) = provider(),
           store.record(for: profileID) != nil,
           let bodyStart = req.range(of: Data("\r\n\r\n".utf8)) {
            let body = req.subdata(in: bodyStart.upperBound..<req.count)
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let form = "?" + String(decoding: body, as: UTF8.self)
            let grant = (json?["grant_type"] as? String) ?? Self.urlQueryParam("grant_type", inPath: form)
            let sent = (json?["refresh_token"] as? String) ?? Self.urlQueryParam("refresh_token", inPath: form)
            if grant == "refresh_token", let sent, ClaudeStandIn.isRefresh(sent) {
                let reply: Data
                do {
                    _ = try await refresher.accessToken(for: profileID)
                    reply = SignInCapture.response(status: 200, reason: "OK",
                                                   json: ClaudeStandIn.refreshAnswer(ClaudeStandIn.mint(profileID: profileID)))
                    FileHandle.standardError.write(Data(
                        "[mitm] answered Claude stand-in refresh for \(profileID.uuidString.prefix(8))\n".utf8))
                } catch {
                    reply = SignInCapture.response(status: 400, reason: "Bad Request", json: [
                        "error": "invalid_grant",
                        "error_description": "Bromure could not refresh the Claude subscription on the host: \(error)",
                    ])
                }
                return .answer(reply)
            }
        }

        // 5e'. Codex stand-in refresh. Codex refreshes when OpenAI turns its
        //     token down (a 401) — which a stand-in the proxy didn't swap
        //     used to cause — and a stand-in refresh token sent on to OpenAI
        //     came back "Your access token could not be refreshed. Please
        //     log out and sign in again." Answered here instead, like Kimi's:
        //     the host refreshes the real login and Codex gets fresh stand-ins.
        if !spooledBody, reqMethod.uppercased() == "POST",
           host == "auth.openai.com", reqPath.hasPrefix("/oauth/token"),
           let provider = SubscriptionProviders.codex, let (store, refresher) = provider(),
           store.record(for: profileID) != nil,
           let bodyStart = req.range(of: Data("\r\n\r\n".utf8)) {
            let body = req.subdata(in: bodyStart.upperBound..<req.count)
            let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            let form = "?" + String(decoding: body, as: UTF8.self)
            let grant = (json?["grant_type"] as? String) ?? Self.urlQueryParam("grant_type", inPath: form)
            let sent = (json?["refresh_token"] as? String) ?? Self.urlQueryParam("refresh_token", inPath: form)
            if grant == "refresh_token", let sent, SubscriptionFakeMint.isCodexRefreshFake(sent) {
                let reply: Data
                do {
                    // Codex only refreshes after OpenAI turned it down: refresh
                    // the REAL login for real (not just "it isn't expired yet"),
                    // and fail honestly when the login is dead.
                    let refreshedNow = try await refresher.refreshForStandIn(for: profileID)
                    guard let fresh = store.record(for: profileID),
                          let standIn = CodexStandIn.mint(fresh, profileID: profileID)
                    else { throw CodexSubscriptionError.noCredential }
                    store.registerBogusKey(standIn.access, for: profileID)
                    reply = SignInCapture.response(status: 200, reason: "OK", json: CodexStandIn.refreshAnswer(standIn))
                    FileHandle.standardError.write(Data(
                        "[mitm] answered Codex stand-in refresh for \(profileID.uuidString.prefix(8)) (\(refreshedNow ? "host refreshed the real credential" : "real credential refreshed moments ago; reused"))\n".utf8))
                } catch {
                    reply = SignInCapture.response(status: 401, reason: "Unauthorized",
                                                   json: CodexSignInExpired.refreshRejectedJSON(error))
                    FileHandle.standardError.write(Data(
                        "[mitm] Codex stand-in refresh for \(profileID.uuidString.prefix(8)) failed host-side: \(error)\n".utf8))
                }
                return .answer(reply)
            }
        }

        return .forward(req, injected)
    }

    /// A live token the provider turned down (a 401 on the reply): refresh
    /// it in the background so the next request uses a fresh one (the agent
    /// retries the failed call on its own). De-duped in each refresher.
    static func noteUnauthorized(_ injected: Injected, response: Data, profileID pid: UUID) {
        if let stale = injected.claude, let (_, refresher) = SubscriptionProviders.claude?() {
            Task { await refresher.noteUnauthorized(stale: stale, for: pid) }
        }
        if let stale = injected.codex, let (_, refresher) = SubscriptionProviders.codex?() {
            let invalidated = CodexSignInExpired.isInvalidation(response)
            Task { await refresher.noteUnauthorized(stale: stale, for: pid, invalidated: invalidated) }
        }
        if let stale = injected.grok, let (_, refresher) = SubscriptionProviders.grok?() {
            Task { await refresher.noteUnauthorized(stale: stale, for: pid) }
        }
        if let stale = injected.kimi, let (_, refresher) = SubscriptionProviders.kimi?() {
            Task { await refresher.noteUnauthorized(stale: stale, for: pid) }
        }
    }

    /// "injected … token" lines, at most once a minute per (what, host,
    /// workspace): every request — every Codex WebSocket turn — gets one, and
    /// dozens a turn drowned the log.
    private static let injectionLogLock = NSLock()
    nonisolated(unsafe) private static var injectionLogLast: [String: Date] = [:]
    static func shouldLogTokenInjection(_ key: String, now: Date = Date(),
                                        interval: TimeInterval = 60) -> Bool {
        injectionLogLock.lock(); defer { injectionLogLock.unlock() }
        if let last = injectionLogLast[key], now.timeIntervalSince(last) < interval { return false }
        injectionLogLast[key] = now
        return true
    }

    static func logTokenInjection(_ what: String, host: String, profileID: UUID) {
        guard shouldLogTokenInjection("\(what)|\(host)|\(profileID.uuidString)") else { return }
        FileHandle.standardError.write(Data(
            "[mitm] injected \(what) for \(host) (logged once a minute)\n".utf8))
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

    /// Anthropic's API and Claude's own hosts (claude.ai, platform.claude.com).
    static func isClaudeHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "api.anthropic.com" || h.hasSuffix(".anthropic.com")
            || h == "claude.ai" || h.hasSuffix(".claude.ai") || h.hasSuffix(".claude.com") || h == "claude.com"
    }

    /// Claude's OAuth stand-in, from a workspace that has a Claude login.
    static func isClaudeStandIn(_ bearer: String, profileID: UUID) -> Bool {
        guard ClaudeStandIn.isAccess(bearer),
              let (store, _) = SubscriptionProviders.claude?() else { return false }
        return store.record(for: profileID) != nil
    }

    /// A Codex stand-in for this workspace: one the host registered, or one
    /// it minted any time (its Bromure-marked signature) for a workspace that
    /// has a Codex login — the registry is in memory, and a machine that
    /// outlives an app restart (or a host-side refresh) still holds an older
    /// stand-in. Only ever resolved to THIS connection's workspace's login.
    static func isCodexStandIn(_ bearer: String, profileID: UUID) -> Bool {
        guard let (store, _) = SubscriptionProviders.codex?() else { return false }
        if store.profileForBogusKey(bearer) != nil { return true }
        return SubscriptionFakeMint.isJWTFake(bearer) && store.record(for: profileID) != nil
    }

    /// A Grok stand-in for this workspace: one the host registered, or one
    /// it minted any time (Bromure's mark) for a workspace that has a Grok
    /// login — the registry is in memory, and a machine resumed across an
    /// app restart (or a host-side refresh) still holds an older stand-in.
    /// Only ever resolved to THIS connection's workspace's login.
    static func isGrokStandIn(_ bearer: String, profileID: UUID) -> Bool {
        guard let (store, _) = SubscriptionProviders.grok?() else { return false }
        if store.profileForBogusKey(bearer) != nil { return true }
        return GrokStandIn.isAccess(bearer) && store.record(for: profileID) != nil
    }

    /// Kimi's twin of ``isGrokStandIn(_:profileID:)``.
    static func isKimiStandIn(_ bearer: String, profileID: UUID) -> Bool {
        guard let (store, _) = SubscriptionProviders.kimi?() else { return false }
        if store.profileForBogusKey(bearer) != nil { return true }
        return KimiStandIn.isAccess(bearer) && store.record(for: profileID) != nil
    }

    /// The refresh token of a `grant_type=refresh_token` request (form or
    /// JSON body), when `matching` says it is one of our stand-ins.
    static func standInRefreshToken(in rawRequest: Data, matching: (String) -> Bool) -> String? {
        guard let bodyStart = rawRequest.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let body = rawRequest.subdata(in: bodyStart.upperBound..<rawRequest.count)
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let form = "?" + String(decoding: body, as: UTF8.self)
        let grant = (json?["grant_type"] as? String) ?? urlQueryParam("grant_type", inPath: form)
        let sent = (json?["refresh_token"] as? String) ?? urlQueryParam("refresh_token", inPath: form)
        guard grant == "refresh_token", let sent, matching(sent) else { return nil }
        return sent
    }

    /// What a Grok / Kimi request carrying a stand-in hears when the host has
    /// no usable login: never the stand-in forwarded upstream.
    static func subscriptionUnavailableReply(provider: String, rejected: Bool) -> Data {
        rejected
            ? SignInCapture.response(status: 401, reason: "Unauthorized", json: [
                "error": ["message": "Your \(provider) sign-in expired or was rejected. Sign in again from Bromure (the session's sign-in card or Preferences → Models).",
                          "type": "authentication_error", "code": "sign_in_required"] as [String: Any],
            ])
            : SignInCapture.response(status: 503, reason: "Service Unavailable", json: [
                "error": ["message": "Bromure couldn't renew the \(provider) sign-in just now; retrying.",
                          "type": "server_error"] as [String: Any],
            ])
    }

    /// The proxy's answer to a Grok / Kimi refresh the guest sent with one
    /// of Bromure's stand-in refresh tokens (5e″ / 5f′), or nil when the
    /// request isn't one (it then goes on untouched). Never forwards it: the
    /// host refreshes the real login (forced, rate-limited per slot) and the
    /// guest gets fresh stand-ins — or the truth: a rejected login as a
    /// permanent error, a transient failure as a retryable 503.
    static func answerStandInRefresh(host: String, method: String, path: String,
                                     rawRequest: Data, profileID: UUID) async -> Data? {
        guard method.uppercased() == "POST" else { return nil }
        let pid8 = profileID.uuidString.prefix(8)
        func outcome(_ refreshedNow: Bool) -> String {
            refreshedNow ? "host refreshed the real credential" : "reused the host's recently refreshed credential"
        }
        if (host == "auth.kimi.ai" || host == "auth.kimi.com"), path.hasPrefix("/api/oauth/token"),
           let (store, refresher) = SubscriptionProviders.kimi?(),
           store.record(for: profileID) != nil,
           standInRefreshToken(in: rawRequest, matching: KimiStandIn.isRefresh) != nil {
            do {
                let refreshedNow = try await refresher.refreshForStandIn(for: profileID)
                // Mint from the CURRENT real record (the refresher persisted it).
                guard let fresh = store.record(for: profileID) else { throw KimiSubscriptionError.noCredential }
                let answer = KimiRefreshAnswer.build(record: fresh, profileID: profileID)
                store.registerBogusKey(answer.bogusAccess, for: profileID)
                FileHandle.standardError.write(Data(
                    "[mitm] answered Kimi stand-in refresh for \(pid8) (\(outcome(refreshedNow)))\n".utf8))
                return SignInCapture.response(status: 200, reason: "OK", json: answer.json)
            } catch {
                FileHandle.standardError.write(Data(
                    "[mitm] Kimi stand-in refresh for \(pid8) failed host-side: \(error)\n".utf8))
                // A transient failure must never read as a 401: the CLI would
                // persist it as a revoked login.
                let rejected = (error as? KimiSubscriptionError)?.isRejection ?? false
                return rejected
                    ? SignInCapture.response(status: 401, reason: "Unauthorized", json: [
                        "error": "invalid_grant",
                        "error_description": "Bromure could not refresh the Kimi subscription on the host: \(error). Sign in again from Bromure.",
                    ])
                    : SignInCapture.response(status: 503, reason: "Service Unavailable", json: [
                        "error": "temporarily_unavailable",
                        "error_description": "Bromure couldn't renew the Kimi sign-in just now; retrying: \(error)",
                    ])
            }
        }
        if host == "auth.x.ai", path.hasPrefix("/oauth2/token"),
           let (store, refresher) = SubscriptionProviders.grok?(),
           store.record(for: profileID) != nil,
           standInRefreshToken(in: rawRequest, matching: GrokStandIn.isRefresh) != nil {
            do {
                let refreshedNow = try await refresher.refreshForStandIn(for: profileID)
                guard let fresh = store.record(for: profileID) else { throw GrokSubscriptionError.noCredential }
                let standIn = GrokStandIn.mint(fresh, profileID: profileID)
                store.registerBogusKey(standIn.access, for: profileID)
                FileHandle.standardError.write(Data(
                    "[mitm] answered Grok stand-in refresh for \(pid8) (\(outcome(refreshedNow)))\n".utf8))
                return SignInCapture.response(status: 200, reason: "OK", json: GrokStandIn.refreshAnswer(standIn))
            } catch {
                FileHandle.standardError.write(Data(
                    "[mitm] Grok stand-in refresh for \(pid8) failed host-side: \(error)\n".utf8))
                let rejected = (error as? GrokSubscriptionError)?.isRejection ?? false
                return rejected
                    ? SignInCapture.response(status: 400, reason: "Bad Request", json: [
                        "error": "invalid_grant",
                        "error_description": "Bromure could not refresh the Grok subscription on the host: \(error). Sign in again from Bromure.",
                    ])
                    : SignInCapture.response(status: 503, reason: "Service Unavailable", json: [
                        "error": "temporarily_unavailable",
                        "error_description": "Bromure couldn't renew the Grok sign-in just now; retrying: \(error)",
                    ])
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
}
