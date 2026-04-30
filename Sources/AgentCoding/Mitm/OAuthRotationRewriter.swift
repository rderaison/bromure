import Foundation

/// Response-body rewriter for the Anthropic OAuth token endpoint.
///
/// Anthropic rotates the refresh token on every refresh (security best
/// practice): a `POST /v1/oauth/token` returns a JSON body carrying
/// fresh `access_token` + `refresh_token` values. If we let those
/// reach the VM verbatim, Claude Code's on-disk write would clobber
/// the fakes we put there during initial swap, and the next request
/// would carry the *real* access token in its `Authorization` header
/// — defeating the whole point.
///
/// This rewriter sits on the host's response path: it parses the JSON,
/// mints fresh fakes via the same `SessionTokenPlan.deriveFake` call
/// the coordinator uses, registers the new fake↔real entries with the
/// `TokenSwapper`, and substitutes the fake values into the response
/// body before it reaches TLS. From the VM's perspective the refresh
/// "just worked" and the on-disk credentials still hold fakes.
///
/// The host MUST hold this response (not stream it) because the rewrite
/// only works on a fully-assembled JSON body; the caller switches to
/// buffered mode for any URL that matches `isOAuthTokenEndpoint`.
public enum OAuthRotationRewriter {
    /// True for URLs we need to buffer-and-rewrite.
    public static func isOAuthTokenEndpoint(host: String, path: String) -> Bool {
        let h = host.lowercased()
        if !(h == "console.anthropic.com" || h.hasSuffix(".anthropic.com")) {
            return false
        }
        // Match the OAuth path. We're permissive on the prefix so a
        // future API version (`/v2/oauth/token`) is still caught.
        return path.contains("/oauth/token")
    }

    /// Apply the rewrite. `raw` is the full HTTP response (status line,
    /// headers, blank line, body). Returns the rewritten bytes — same
    /// shape, just with `access_token` and `refresh_token` swapped to
    /// freshly-minted fakes.
    ///
    /// On any structural failure we return `raw` unchanged. That's not
    /// a security regression: failure means we couldn't parse the JSON,
    /// so there's nothing to register, and the VM will write whatever
    /// the body says — same as today.
    public static func rewrite(
        raw: Data,
        profileID: UUID,
        swapper: TokenSwapper,
    ) -> Data {
        guard let split = raw.range(of: Data("\r\n\r\n".utf8)) else { return raw }
        let headerData = raw.subdata(in: 0..<split.lowerBound)
        let bodyData   = raw.subdata(in: split.upperBound..<raw.count)
        guard !bodyData.isEmpty else { return raw }

        // Anthropic's OAuth token responses are application/json — but
        // be lenient (parse what we can; fall back to the original
        // bytes on anything weird).
        guard var json = (try? JSONSerialization.jsonObject(with: bodyData))
                as? [String: Any] else {
            return raw
        }

        // Pull and validate the two fields we care about. If either is
        // missing or already brm-shaped, leave the body alone — we
        // already handled an earlier rotation, or this is a non-rotate
        // response (error / introspection / etc.).
        guard let realAccess = json["access_token"] as? String,
              let realRefresh = json["refresh_token"] as? String,
              realAccess.hasPrefix("sk-ant-oat01-"),
              realRefresh.hasPrefix("sk-ant-ort01-"),
              !realAccess.hasPrefix("sk-ant-oat01-brm-"),
              !realRefresh.hasPrefix("sk-ant-ort01-brm-")
        else { return raw }

        let saltAccess = Data("anthropic-oauth-access:\(profileID)".utf8)
        let saltRefresh = Data("anthropic-oauth-refresh:\(profileID)".utf8)
        let fakeAccess = SessionTokenPlan.deriveFake(
            prefix: "sk-ant-oat01-brm-",
            real: realAccess,
            salt: saltAccess)
        let fakeRefresh = SessionTokenPlan.deriveFake(
            prefix: "sk-ant-ort01-brm-",
            real: realRefresh,
            salt: saltRefresh)

        // Register the new fake↔real pairs FIRST. If we replaced in the
        // body but failed to register, the VM would write a fake the
        // proxy doesn't know how to swap on the next API call.
        swapper.appendEntries([
            .init(fake: fakeAccess, real: realAccess,
                  host: "api.anthropic.com",
                  header: .authorization),
            .init(fake: fakeRefresh, real: realRefresh,
                  host: "console.anthropic.com",
                  header: .authorization),
        ], for: profileID)

        json["access_token"] = fakeAccess
        json["refresh_token"] = fakeRefresh

        guard let rewrittenBody = try? JSONSerialization.data(
            withJSONObject: json, options: []
        ) else { return raw }

        // Length might have changed (the fakes are likely a different
        // length from the reals). Patch Content-Length if it was
        // present; the body delimiter stays \r\n\r\n.
        let patchedHeader = patchContentLength(
            headerData, newBodyLength: rewrittenBody.count)

        var out = Data()
        out.reserveCapacity(patchedHeader.count + 4 + rewrittenBody.count)
        out.append(patchedHeader)
        out.append(Data("\r\n\r\n".utf8))
        out.append(rewrittenBody)
        return out
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
