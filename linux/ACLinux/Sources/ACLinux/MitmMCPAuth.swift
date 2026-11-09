import Foundation

/// MCP servers whose OAuth was brokered on the host (their `brm-mcp_`
/// stand-in in the workspace's token map): Claude Code is told they have no
/// OAuth, and the proxy adds the real bearer (macOS: driveTLS's 4a and 5b).
extension RequestReader {
    /// 4a. OAuth/OIDC discovery for such a host: 404. Claude Code probes
    /// several .well-known paths; one returning metadata makes it insist on
    /// its own auth flow (which can't work inside the VM), so all of them
    /// are "not found" and the bearer injection below does the auth.
    // @port-skip linux-only: HTTPMitmConnection.driveTLS's 4a step, on the Linux request chain
    static func mcpDiscoveryAnswer(path: String, host: String, profileID: UUID, proxy: MitmProxy) -> Data? {
        let isDiscovery = path.hasPrefix("/.well-known/oauth-authorization-server")
            || path.hasPrefix("/.well-known/oauth-protected-resource")
            || path.hasPrefix("/.well-known/openid-configuration")
        guard isDiscovery,
              proxy.swapper.entries(for: profileID).contains(where: { $0.host == host && $0.fake.hasPrefix("brm-mcp_") })
        else { return nil }
        FileHandle.standardError.write(Data("[mitm] blocked OAuth discovery for \(host) — using broker token\n".utf8))
        let body = "Not Found"
        var resp = "HTTP/1.1 404 Not Found\r\n"
        resp += "Content-Type: text/plain\r\nContent-Length: \(body.utf8.count)\r\n"
        resp += "Connection: close\r\n\r\n\(body)"
        return Data(resp.utf8)
    }

    /// 5b. The real bearer as an Authorization header, for such a host, when
    /// the request doesn't carry one already (Claude Code sees a plain URL).
    // @port-skip linux-only: HTTPMitmConnection.driveTLS's 5b step, on the Linux request chain
    static func injectingMCPBearer(_ req: Data, host: String, profileID: UUID, proxy: MitmProxy) -> Data {
        guard let real = proxy.swapper.entries(for: profileID)
                .first(where: { $0.host == host && $0.fake.hasPrefix("brm-mcp_") })?.real,
              let head = SubscriptionAuthRewrite.rawHeaderSection(of: req),
              SubscriptionAuthRewrite.headerValue("authorization", inHeaderSection: head) == nil
        else { return req }
        // The byte-safe splice keeps any binary body intact.
        let out = SubscriptionAuthRewrite.spliceHeaderSection(of: req, newHeader: head + "\r\nAuthorization: Bearer \(real)")
        SubscriptionAuthRewrite.logTokenInjection("MCP bearer", host: host, profileID: profileID)
        return out
    }
}

/// OpenShell credential placeholders (`openshell:resolve:env:<NAME>`):
/// resolved in the body where the endpoint opts in, and refused where one is
/// left (macOS: driveTLS's step 5 and the check after it).
extension RequestReader {
    /// The endpoint resolves placeholders in the body too: a UTF-8 JSON,
    /// form or text body of up to 256 KiB, as OpenShell.
    // @port-skip linux-only: HTTPMitmConnection.driveTLS's placeholderBody, on the Linux request chain
    static func resolvesPlaceholderBody(_ req: Data, proxy: MitmProxy, profileID: UUID, host: String, port: Int,
                                        path: String) -> Bool {
        guard let openShell = proxy.guardrailsConfig(for: profileID)?.egressPolicy?.openShell,
              openShell.credentialRewrite(host: host, port: UInt16(truncatingIfNeeded: port), target: path).body,
              let sep = req.range(of: Data("\r\n\r\n".utf8)),
              req.count - sep.upperBound <= 256 * 1024 else { return false }
        let head = SubscriptionAuthRewrite.rawHeaderSection(of: req) ?? ""
        let type = (SubscriptionAuthRewrite.headerValue("content-type", inHeaderSection: head) ?? "").lowercased()
        return type.contains("json") || type.contains("x-www-form-urlencoded") || type.hasPrefix("text/")
    }

    /// The first known OpenShell placeholder left in a request's headers (or
    /// its body, when the endpoint resolves bodies) after the swap.
    // @port HTTPMitmConnection.static unresolvedPlaceholder(in: Data, checkBody: Bool, known: [String]) h=0d38324dc211b204 @285807ef
    static func unresolvedPlaceholder(in request: Data, checkBody: Bool, known: [String]) -> String? {
        let placeholders = known.filter { $0.hasPrefix(TokenSwapper.openShellPlaceholderPrefix) }
        guard !placeholders.isEmpty else { return nil }
        let sep = request.range(of: Data("\r\n\r\n".utf8))
        let head = sep.map { request.subdata(in: request.startIndex..<$0.lowerBound) } ?? request
        let body = checkBody ? (sep.map { request.subdata(in: $0.upperBound..<request.endIndex) } ?? Data()) : Data()
        return placeholders.first { p in
            let d = Data(p.utf8)
            return head.range(of: d) != nil || body.range(of: d) != nil
        }
    }
}
