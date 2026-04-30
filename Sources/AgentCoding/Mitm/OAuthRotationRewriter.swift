import Foundation

/// Provider tag for OAuth-rotation handling. Determines token shapes,
/// host scoping, and which `Profile.default*Tokens` field rotates.
public enum OAuthRotationProvider: String, Sendable, Equatable {
    case claude
    case codex
}

/// Result of an in-flight rewrite. `bytes` is what gets shipped down
/// to the VM; `newReals` carries the upstream's freshly-issued real
/// tokens (so the host can update its stored defaults / template
/// without re-parsing the body). nil = nothing rotated this hop, the
/// response is being passed through unchanged.
public struct OAuthRotationResult {
    public let bytes: Data
    public let newReals: StoredOAuthTokens?
}

/// Response-body rewriter for OAuth `/oauth/token` endpoints.
///
/// Both Anthropic and OpenAI rotate the refresh token on every refresh
/// (security best practice): a `POST /oauth/token` returns a JSON body
/// carrying fresh `access_token` + `refresh_token` (+ `id_token` for
/// Codex). If we let those reach the VM verbatim, the on-disk write
/// would clobber the fakes we put there during initial swap, and the
/// next request would carry the *real* token — defeating the whole
/// point.
///
/// This rewriter sits on the host's response path: it parses the JSON,
/// mints fresh fakes via the same minting helpers the coordinator
/// uses, registers the new fake↔real entries with the `TokenSwapper`,
/// and substitutes the fake values into the response body before it
/// reaches TLS. From the VM's perspective the refresh "just worked"
/// and the on-disk credentials still hold fakes.
///
/// On a successful rewrite, `result.newReals` carries the *real*
/// tokens — the proxy uses those to keep host-side default-token
/// storage (`profile.defaultClaudeTokens` / `defaultCodexTokens`,
/// optionally the preferences template) in lockstep with whatever
/// the upstream issued.
public enum OAuthRotationRewriter {
    /// Returns the matching provider for the URL, or nil if this
    /// isn't a token endpoint we need to buffer-and-rewrite.
    public static func provider(for host: String, path: String) -> OAuthRotationProvider? {
        let h = host.lowercased()
        if (h == "console.anthropic.com" || h.hasSuffix(".anthropic.com"))
            && path.contains("/oauth/token") {
            return .claude
        }
        if (h == "auth.openai.com" || h == "chatgpt.com"
                || h.hasSuffix(".chatgpt.com") || h.hasSuffix(".openai.com"))
            && path.contains("/oauth/token") {
            return .codex
        }
        return nil
    }

    /// True for URLs we need to buffer-and-rewrite.
    /// Kept as a thin wrapper for any caller that only needs the bool.
    public static func isOAuthTokenEndpoint(host: String, path: String) -> Bool {
        provider(for: host, path: path) != nil
    }

    /// Apply the rewrite. `raw` is the full HTTP response (status line,
    /// headers, blank line, body). On any structural failure we return
    /// `raw` unchanged with `newReals = nil` — failure means we
    /// couldn't parse the JSON, so there's nothing to register, and
    /// the VM will write whatever the body says (same as today).
    public static func rewrite(
        raw: Data,
        provider: OAuthRotationProvider,
        profileID: UUID,
        swapper: TokenSwapper,
    ) -> OAuthRotationResult {
        switch provider {
        case .claude: return rewriteClaude(raw: raw, profileID: profileID, swapper: swapper)
        case .codex:  return rewriteCodex(raw: raw, profileID: profileID, swapper: swapper)
        }
    }

    // MARK: - Anthropic

    private static func rewriteClaude(
        raw: Data,
        profileID: UUID,
        swapper: TokenSwapper,
    ) -> OAuthRotationResult {
        guard let split = raw.range(of: Data("\r\n\r\n".utf8)) else {
            return .init(bytes: raw, newReals: nil)
        }
        let headerData = raw.subdata(in: 0..<split.lowerBound)
        let bodyData   = raw.subdata(in: split.upperBound..<raw.count)
        guard !bodyData.isEmpty,
              var json = (try? JSONSerialization.jsonObject(with: bodyData))
                as? [String: Any] else {
            return .init(bytes: raw, newReals: nil)
        }

        guard let realAccess = json["access_token"] as? String,
              let realRefresh = json["refresh_token"] as? String,
              realAccess.hasPrefix("sk-ant-oat01-"),
              realRefresh.hasPrefix("sk-ant-ort01-"),
              !realAccess.hasPrefix("sk-ant-oat01-brm-"),
              !realRefresh.hasPrefix("sk-ant-ort01-brm-")
        else { return .init(bytes: raw, newReals: nil) }

        let saltAccess = Data("anthropic-oauth-access:\(profileID)".utf8)
        let saltRefresh = Data("anthropic-oauth-refresh:\(profileID)".utf8)
        let fakeAccess = SessionTokenPlan.deriveFake(
            prefix: "sk-ant-oat01-brm-",
            real: realAccess,
            salt: saltAccess,
            targetLength: realAccess.count)
        let fakeRefresh = SessionTokenPlan.deriveFake(
            prefix: "sk-ant-ort01-brm-",
            real: realRefresh,
            salt: saltRefresh,
            targetLength: realRefresh.count)

        swapper.appendEntries([
            .init(fake: fakeAccess, real: realAccess,
                  host: "api.anthropic.com",
                  header: .authorization),
            .init(fake: fakeRefresh, real: realRefresh,
                  host: "console.anthropic.com",
                  header: .authorization, body: true),
        ], for: profileID)

        json["access_token"] = fakeAccess
        json["refresh_token"] = fakeRefresh
        guard let rewrittenBody = try? JSONSerialization.data(
            withJSONObject: json, options: []
        ) else { return .init(bytes: raw, newReals: nil) }

        let patchedHeader = patchContentLength(
            headerData, newBodyLength: rewrittenBody.count)
        var out = Data()
        out.reserveCapacity(patchedHeader.count + 4 + rewrittenBody.count)
        out.append(patchedHeader)
        out.append(Data("\r\n\r\n".utf8))
        out.append(rewrittenBody)

        return .init(
            bytes: out,
            newReals: StoredOAuthTokens(
                accessToken: realAccess,
                refreshToken: realRefresh,
                idToken: nil))
    }

    // MARK: - Codex / ChatGPT

    private static func rewriteCodex(
        raw: Data,
        profileID: UUID,
        swapper: TokenSwapper,
    ) -> OAuthRotationResult {
        guard let split = raw.range(of: Data("\r\n\r\n".utf8)) else {
            return .init(bytes: raw, newReals: nil)
        }
        let headerData = raw.subdata(in: 0..<split.lowerBound)
        let bodyData   = raw.subdata(in: split.upperBound..<raw.count)
        guard !bodyData.isEmpty,
              var json = (try? JSONSerialization.jsonObject(with: bodyData))
                as? [String: Any] else {
            return .init(bytes: raw, newReals: nil)
        }

        guard let realAccess = json["access_token"] as? String,
              let realRefresh = json["refresh_token"] as? String,
              realAccess.hasPrefix("eyJ"),
              !SubscriptionFakeMint.isJWTFake(realAccess)
        else { return .init(bytes: raw, newReals: nil) }
        // id_token is optional: present on initial /token and on
        // refresh-with-scope but not always otherwise.
        let realID = json["id_token"] as? String

        let saltAccess = Data("codex-oauth-access:\(profileID)".utf8)
        let saltRefresh = Data("codex-oauth-refresh:\(profileID)".utf8)
        let saltID = Data("codex-oauth-id:\(profileID)".utf8)

        guard let fakeAccess = SubscriptionFakeMint.mintJWTFake(
                realJWT: realAccess, salt: saltAccess)
        else { return .init(bytes: raw, newReals: nil) }
        let fakeRefresh = SubscriptionFakeMint.mintCodexRefreshFake(
            real: realRefresh, salt: saltRefresh)
        var fakeID: String? = nil
        if let realID, realID.hasPrefix("eyJ"),
           !SubscriptionFakeMint.isJWTFake(realID) {
            fakeID = SubscriptionFakeMint.mintJWTFake(realJWT: realID, salt: saltID)
        }

        var entries: [TokenMap.Entry] = [
            .init(fake: fakeAccess, real: realAccess,
                  host: "chatgpt.com", header: .authorization),
            .init(fake: fakeAccess, real: realAccess,
                  host: "api.openai.com", header: .authorization),
            .init(fake: fakeRefresh, real: realRefresh,
                  host: "auth.openai.com", header: .authorization,
                  body: true),
            .init(fake: fakeRefresh, real: realRefresh,
                  host: "chatgpt.com", header: .authorization,
                  body: true),
        ]
        if let realID, let fakeID {
            entries.append(.init(fake: fakeID, real: realID,
                                 host: "chatgpt.com",
                                 header: .authorization))
            entries.append(.init(fake: fakeID, real: realID,
                                 host: "auth.openai.com",
                                 header: .authorization))
        }
        swapper.appendEntries(entries, for: profileID)

        json["access_token"] = fakeAccess
        json["refresh_token"] = fakeRefresh
        if let realID, let fakeID, json["id_token"] != nil {
            json["id_token"] = fakeID
            _ = realID  // keep optional bind explicit for the reader
        }

        guard let rewrittenBody = try? JSONSerialization.data(
            withJSONObject: json, options: []
        ) else { return .init(bytes: raw, newReals: nil) }

        let patchedHeader = patchContentLength(
            headerData, newBodyLength: rewrittenBody.count)
        var out = Data()
        out.reserveCapacity(patchedHeader.count + 4 + rewrittenBody.count)
        out.append(patchedHeader)
        out.append(Data("\r\n\r\n".utf8))
        out.append(rewrittenBody)

        return .init(
            bytes: out,
            newReals: StoredOAuthTokens(
                accessToken: realAccess,
                refreshToken: realRefresh,
                idToken: realID))
    }

    private static func patchContentLength(_ headerData: Data,
                                            newBodyLength: Int) -> Data {
        guard let str = String(data: headerData, encoding: .ascii) else {
            return headerData
        }
        var lines = str.components(separatedBy: "\r\n")
        var sawCL = false
        for i in lines.indices {
            let line = lines[i]
            if line.lowercased().hasPrefix("content-length:") {
                lines[i] = "Content-Length: \(newBodyLength)"
                sawCL = true
            }
        }
        if !sawCL {
            // No Content-Length — fine; the relay path uses
            // `Connection: close` framing for these responses anyway.
            return headerData
        }
        return Data(lines.joined(separator: "\r\n").utf8)
    }
}
