import AppKit
import Foundation

// MARK: - Sign-in for a session, captured at the proxy
//
// The session's own machine runs its CLI's login subcommand in the session's
// tab. The CLI opens the provider's sign-in page through the guest URL relay
// (this Mac's browser) and the localhost callback is forwarded back in, as
// for any guest login. The proxy then answers the token exchange itself
// (`SignInCapture`): the real credential lands in the host's subscription
// store, the CLI hears an error (Claude, Codex — their machines run on a
// stand-in the host seeds) or a reply carrying stand-in tokens (Grok, Kimi —
// whose CLIs must write their credentials files in the shape the host reuses
// as a template). Then the session's agent restarts on the stand-in
// (`AgentSessionEngine.relaunchAfterSignIn`). No throwaway machine, and the
// machine never holds a real token.

/// One sign-in in flight for a workspace.
final class ProxySignIn {
    let provider: SubscriptionProvider
    let profileID: UUID
    let windowIndex: Int
    var onEvent: ((HostSignInEvent) -> Void)?
    var timeout: Task<Void, Never>?
    var finished = false

    init(provider: SubscriptionProvider, profileID: UUID, windowIndex: Int) {
        self.provider = provider
        self.profileID = profileID
        self.windowIndex = windowIndex
    }
}

extension ACAppDelegate {
    /// Each CLI's login subcommand — straight to the browser hand-off, no
    /// wizard in between (nobody answers a picker in a hidden tab).
    static func loginCommand(for provider: SubscriptionProvider) -> String {
        switch provider {
        case .claude: return "claude auth login --claudeai"
        case .codex:  return "codex login"
        case .grok:   return "grok login"
        case .kimi:   return "kimi login"
        }
    }

    /// Where each CLI exchanges its authorization (or device) code for
    /// tokens — the request the proxy answers itself.
    static func tokenEndpoint(for provider: SubscriptionProvider) -> (hosts: Set<String>, path: String) {
        switch provider {
        case .claude: return (["platform.claude.com", "console.anthropic.com"], "/v1/oauth/token")
        case .codex:  return (["auth.openai.com"], "/oauth/token")
        case .grok:   return (["auth.x.ai"], "/oauth2/token")
        case .kimi:   return (["auth.kimi.com"], "/api/oauth/token")
        }
    }

    /// The stand-in tokens the guest keeps for Grok / Kimi — the very values
    /// `seedGrokAuthFile` / `seedKimiAuthFile` mint, so the proxy's swap
    /// registry and the file the CLI writes agree.
    static func standInTokens(for provider: SubscriptionProvider, profileID pid: UUID,
                              access: String, refresh: String) -> (access: String, refresh: String) {
        let tag = provider.rawValue
        let saltA = Data("\(tag)-bogus-access:\(pid)".utf8)
        let saltR = Data("\(tag)-bogus-refresh:\(pid)".utf8)
        let bogusAccess = SubscriptionFakeMint.mintNoRefreshJWTFake(realJWT: access, salt: saltA)
            ?? SessionTokenPlan.deriveFake(prefix: "\(tag)-brm-", real: access, salt: saltA,
                                           targetLength: max(40, access.count))
        let bogusRefresh = SessionTokenPlan.deriveFake(prefix: "\(tag)rt-brm-", real: refresh, salt: saltR,
                                                       targetLength: max(40, refresh.count))
        return (bogusAccess, bogusRefresh)
    }

    /// What Claude's and Codex's CLIs hear instead of their tokens.
    private static func keptOnHostReply() -> Data {
        SignInCapture.response(status: 400, reason: "Bad Request", json: [
            "error": "bromure_captured",
            "error_description": "Bromure keeps this credential on your Mac; the machine runs on a stand-in.",
        ])
    }

    /// Start a sign-in for the session in `windowIndex` of `profileID`.
    /// `events` hears progress and the outcome (the card in the chat).
    @MainActor
    func beginProxySignIn(provider: SubscriptionProvider, profileID: UUID, windowIndex: Int,
                          events: @escaping (HostSignInEvent) -> Void) {
        guard let engine = mitmEngine else {
            events(.finished(success: false, message: NSLocalizedString(
                "The Bromure proxy isn't running, so the sign-in can't be captured.", comment: "sign-in")))
            return
        }
        if let existing = proxySignIns[profileID], !existing.finished {
            events(.finished(success: false, message: NSLocalizedString(
                "Another sign-in is already in progress.", comment: "sign-in")))
            return
        }
        let signIn = ProxySignIn(provider: provider, profileID: profileID, windowIndex: windowIndex)
        signIn.onEvent = events
        proxySignIns[profileID] = signIn

        let endpoint = Self.tokenEndpoint(for: provider)
        engine.signInCaptures.arm(SignInCapture(
            profileID: profileID, hosts: endpoint.hosts, pathPrefix: endpoint.path,
            handle: { [weak self] status, body in
                guard status == 200,
                      let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                      let access = json["access_token"] as? String, !access.isEmpty else { return nil }
                return await MainActor.run { self?.proxySignInCaptured(signIn, json: json, access: access) }
            }))

        // Leave whatever the agent shows (Ctrl-C twice exits every supported
        // TUI; C-u clears a stray keystroke from the shell line), then run
        // the login in the same tab so the session stays bound to it.
        events(.status(NSLocalizedString("Opening your browser to sign in…", comment: "sign-in")))
        let w = windowIndex
        let cmd = Self.loginCommand(for: provider)
        Task { @MainActor in
            _ = try? await self.guestExec(
                profileID: profileID,
                command: "tmux send-keys -t bromure:\(w) C-c; sleep 0.4; tmux send-keys -t bromure:\(w) C-c; "
                    + "sleep 1.5; tmux send-keys -t bromure:\(w) C-u; "
                    + "tmux send-keys -t bromure:\(w) -l '\(cmd)'; sleep 0.2; tmux send-keys -t bromure:\(w) Enter",
                timeout: 20)
        }
        signIn.timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300 * 1_000_000_000)
            guard let self, let live = self.proxySignIns[profileID], live === signIn, !live.finished else { return }
            self.endProxySignIn(signIn, success: false, message: String(format: NSLocalizedString(
                "Bromure didn't receive a %@ sign-in in time. You can try again.", comment: ""),
                provider.displayName))
        }
    }

    /// The exchange came back with tokens: keep them on the host and decide
    /// what the CLI hears.
    @MainActor
    private func proxySignInCaptured(_ s: ProxySignIn, json: [String: Any], access: String) -> Data? {
        guard !s.finished, let engine = mitmEngine else { return nil }
        let refresh = (json["refresh_token"] as? String) ?? ""
        let expiresAt = (json["expires_in"] as? Double).map { Date().addingTimeInterval($0) } ?? .distantPast
        let pid = s.profileID
        FileHandle.standardError.write(Data(
            "[sign-in] captured \(s.provider.displayName) tokens for \(pid.uuidString.prefix(8)) at the proxy\n".utf8))
        do {
            switch s.provider {
            case .claude:
                try engine.claudeSubscriptionStore.setShared(ClaudeSubscriptionRecord(
                    accessToken: access, refreshToken: refresh, expiresAt: expiresAt, savedAt: Date()))
                endProxySignIn(s, success: true, message: nil)
                return Self.keptOnHostReply()
            case .codex:
                try engine.codexSubscriptionStore.setShared(CodexSubscriptionRecord(
                    accessToken: access, refreshToken: refresh,
                    idToken: (json["id_token"] as? String) ?? "",
                    expiresAt: expiresAt, savedAt: Date()))
                endProxySignIn(s, success: true, message: nil)
                return Self.keptOnHostReply()
            case .grok, .kimi:
                let standIn = Self.standInTokens(for: s.provider, profileID: pid, access: access, refresh: refresh)
                var out = json
                out["access_token"] = standIn.access
                out["refresh_token"] = standIn.refresh
                out["expires_in"] = 10 * 365 * 24 * 3600   // the guest never refreshes; the host does
                if let idt = json["id_token"] as? String,
                   let bogusID = SubscriptionFakeMint.mintNoRefreshJWTFake(
                        realJWT: idt, salt: Data("\(s.provider.rawValue)-bogus-id:\(pid)".utf8)) {
                    out["id_token"] = bogusID
                }
                // The swap works from the first request; the record with the
                // file's template follows once the CLI has written it.
                if s.provider == .grok { engine.grokSubscriptionStore.registerBogusKey(standIn.access, for: pid) }
                else { engine.kimiSubscriptionStore.registerBogusKey(standIn.access, for: pid) }
                Task { @MainActor in
                    await self.finishFileBackedSignIn(s, access: access, refresh: refresh,
                                                      expiresAt: expiresAt, standInAccess: standIn.access)
                }
                return SignInCapture.response(status: 200, reason: "OK", json: out)
            }
        } catch {
            endProxySignIn(s, success: false, message: String(format: NSLocalizedString(
                "Couldn't save the captured credential: %@", comment: "sign-in"), error.localizedDescription))
            return nil
        }
    }

    /// Grok / Kimi: the CLI has (just) written its credentials file with the
    /// stand-in tokens; read it back for the account fields the host seeds
    /// around them on later boots (the registration VM read the same files).
    @MainActor
    private func finishFileBackedSignIn(_ s: ProxySignIn, access: String, refresh: String,
                                        expiresAt: Date, standInAccess: String) async {
        guard let engine = mitmEngine else { return }
        let pid = s.profileID
        var grokFile: [String: Any]?
        var kimiFiles: [(name: String, obj: [String: Any])] = []
        var kimiTOML: String?
        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if s.provider == .grok {
                if let out = try? await guestExec(profileID: pid,
                                                  command: "cat /home/ubuntu/.grok/auth.json 2>/dev/null", timeout: 10),
                   let obj = (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any],
                   !obj.isEmpty {
                    grokFile = obj
                    break
                }
            } else {
                let cmd = "for f in /home/ubuntu/.kimi-code/credentials/*.json; do [ -f \"$f\" ] || continue; "
                    + "printf '==FILE %s\\n' \"$f\"; cat \"$f\"; printf '\\n'; done; "
                    + "printf '==TOML\\n'; cat /home/ubuntu/.kimi-code/config.toml 2>/dev/null"
                if let out = try? await guestExec(profileID: pid, command: cmd, timeout: 10) {
                    let parts = out.components(separatedBy: "==TOML\n")
                    kimiTOML = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
                    for chunk in parts[0].components(separatedBy: "==FILE ").dropFirst() {
                        guard let nl = chunk.firstIndex(of: "\n") else { continue }
                        let path = String(chunk[..<nl])
                        let body = String(chunk[chunk.index(after: nl)...])
                        if let obj = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] {
                            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                            kimiFiles.append((name: name, obj: obj))
                        }
                    }
                    if !kimiFiles.isEmpty { break }
                }
            }
        }
        do {
            if s.provider == .grok {
                var scopeKey = grokOIDCScope
                var template = Data()
                if let file = grokFile {
                    for (key, val) in file {
                        guard var entry = val as? [String: Any] else { continue }
                        guard (entry["key"] as? String) == standInAccess || file.count == 1 else { continue }
                        scopeKey = key
                        entry.removeValue(forKey: "key")
                        entry.removeValue(forKey: "refresh_token")
                        entry.removeValue(forKey: "expires_at")
                        template = (try? JSONSerialization.data(withJSONObject: entry)) ?? Data()
                        break
                    }
                }
                try engine.grokSubscriptionStore.setShared(GrokSubscriptionRecord(
                    accessToken: access, refreshToken: refresh, expiresAt: expiresAt, savedAt: Date(),
                    scopeKey: scopeKey, templateJSON: template))
            } else {
                var name = kimiManagedCredentialName
                var template = Data()
                if let f = kimiFiles.first(where: { ($0.obj["access_token"] as? String) == standInAccess })
                    ?? kimiFiles.first {
                    name = f.name
                    var obj = f.obj
                    obj.removeValue(forKey: "access_token")
                    obj.removeValue(forKey: "refresh_token")
                    obj.removeValue(forKey: "expires_at")
                    template = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
                }
                try engine.kimiSubscriptionStore.setShared(KimiSubscriptionRecord(
                    accessToken: access, refreshToken: refresh, expiresAt: expiresAt, savedAt: Date(),
                    credentialName: name, templateJSON: template, configTOML: kimiTOML))
            }
            endProxySignIn(s, success: true, message: nil)
        } catch {
            endProxySignIn(s, success: false, message: String(format: NSLocalizedString(
                "Couldn't save the captured credential: %@", comment: "sign-in"), error.localizedDescription))
        }
    }

    /// Done, one way or the other: disarm the capture and tell the card.
    @MainActor
    func endProxySignIn(_ s: ProxySignIn, success: Bool, message: String?) {
        guard !s.finished else { return }
        s.finished = true
        s.timeout?.cancel()
        mitmEngine?.signInCaptures.disarm(profileID: s.profileID)
        if proxySignIns[s.profileID] === s { proxySignIns[s.profileID] = nil }
        if success {
            NotificationCenter.default.post(name: .bromureSubscriptionStoresChanged, object: nil)
        }
        s.onEvent?(.finished(success: success, message: message))
        s.onEvent = nil
    }
}
