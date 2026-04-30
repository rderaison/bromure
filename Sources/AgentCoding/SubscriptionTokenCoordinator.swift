import AppKit
import Foundation
import SwiftUI

/// Glues the proxy's `detectSubscriptionAccessToken` hook to the
/// SwiftUI consent sheet, the per-VM `SubscriptionTokenBridge`, and
/// the `TokenSwapper` swap registry.
///
/// One singleton, lookup-by-profile state. The proxy can fire the
/// detection hook on every outbound request — the coordinator
/// throttles per-profile so we only ever show one sheet at a time per
/// profile, regardless of how many API calls Claude Code is making in
/// parallel.
@MainActor
public final class SubscriptionTokenCoordinator {
    public static let shared = SubscriptionTokenCoordinator()
    private init() {}

    /// One bridge per active profile session, registered by the
    /// session-launch path in BromureAC.
    private var bridges: [UUID: SubscriptionTokenBridge] = [:]
    private var codexBridges: [UUID: CodexTokenBridge] = [:]
    /// Profiles whose sheet is open right now or has been answered
    /// "Not now" this run. Cleared on session teardown / unenroll.
    /// (`.declined` from the profile is the persistent counterpart;
    /// this set is the "asked already this session" cache so we don't
    /// re-fire while the user is still looking at the dialog.)
    /// Per-provider — Claude and Codex are tracked independently so
    /// declining one doesn't suppress the other.
    private var askedClaude: Set<UUID> = []
    private var askedCodex: Set<UUID> = []
    /// One open sheet at a time per (profile, provider).
    private var sheetWindowsClaude: [UUID: NSWindow] = [:]
    private var sheetWindowsCodex: [UUID: NSWindow] = [:]

    // MARK: - Wiring

    public func register(profileID: UUID, bridge: SubscriptionTokenBridge) {
        bridges[profileID] = bridge
    }

    public func registerCodex(profileID: UUID, bridge: CodexTokenBridge) {
        codexBridges[profileID] = bridge
    }

    /// Auto-seed a fresh VM with proxy-side fakes when the profile
    /// inherited real OAuth tokens from the user's preferences
    /// template. Idempotent — if the VM already has credentials of
    /// its own (the user ran `claude login` / `codex login`
    /// manually), we leave them alone. Called from BromureAC after
    /// the bridge has had a moment to connect.
    public func autoSeedIfNeeded(profile: Profile,
                                  store: ProfileStore,
                                  swapper: TokenSwapper) {
        if let stored = profile.defaultClaudeTokens,
           profile.subscriptionTokenSwap == .accepted,
           let bridge = bridges[profile.id] {
            Task { @MainActor in
                await self.seedClaude(stored: stored, profile: profile,
                                       bridge: bridge, store: store,
                                       swapper: swapper)
            }
        }
        if let stored = profile.defaultCodexTokens,
           profile.codexTokenSwap == .accepted,
           let bridge = codexBridges[profile.id] {
            Task { @MainActor in
                await self.seedCodex(stored: stored, profile: profile,
                                      bridge: bridge, store: store,
                                      swapper: swapper)
            }
        }
    }

    private func seedClaude(stored: StoredOAuthTokens,
                             profile: Profile,
                             bridge: SubscriptionTokenBridge,
                             store: ProfileStore,
                             swapper: TokenSwapper) async {
        // Wait briefly for the bridge to connect (in-VM agent
        // launches a couple of seconds after VM boot). Bail if the
        // VM already has real credentials — the user opted into a
        // separate login that we shouldn't overwrite.
        for _ in 0..<10 {
            if bridge.isConnected { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard bridge.isConnected else {
            FileHandle.standardError.write(Data(
                "[subscription-swap] auto-seed skipped (bridge not connected)\n".utf8))
            return
        }
        do {
            if (try? await bridge.read()) != nil {
                FileHandle.standardError.write(Data(
                    "[subscription-swap] auto-seed skipped (VM already has Claude creds)\n".utf8))
                return
            }
            let saltAccess = Data("anthropic-oauth-access:\(profile.id)".utf8)
            let saltRefresh = Data("anthropic-oauth-refresh:\(profile.id)".utf8)
            let fakeAccess = SessionTokenPlan.deriveFake(
                prefix: "sk-ant-oat01-brm-",
                real: stored.accessToken,
                salt: saltAccess,
                targetLength: stored.accessToken.count)
            let fakeRefresh = SessionTokenPlan.deriveFake(
                prefix: "sk-ant-ort01-brm-",
                real: stored.refreshToken,
                salt: saltRefresh,
                targetLength: stored.refreshToken.count)
            swapper.appendEntries([
                .init(fake: fakeAccess, real: stored.accessToken,
                      host: "api.anthropic.com",
                      header: .authorization),
                .init(fake: fakeRefresh, real: stored.refreshToken,
                      host: "console.anthropic.com",
                      header: .authorization, body: true),
            ], for: profile.id)
            try await bridge.write(access: fakeAccess, refresh: fakeRefresh)
        } catch {
            FileHandle.standardError.write(Data(
                "[subscription-swap] auto-seed Claude failed: \(error)\n".utf8))
        }
    }

    private func seedCodex(stored: StoredOAuthTokens,
                            profile: Profile,
                            bridge: CodexTokenBridge,
                            store: ProfileStore,
                            swapper: TokenSwapper) async {
        for _ in 0..<10 {
            if bridge.isConnected { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard bridge.isConnected else {
            FileHandle.standardError.write(Data(
                "[subscription-swap] auto-seed skipped (codex bridge not connected)\n".utf8))
            return
        }
        guard let realID = stored.idToken else {
            FileHandle.standardError.write(Data(
                "[subscription-swap] auto-seed Codex skipped (no id_token in stored defaults)\n".utf8))
            return
        }
        do {
            if (try? await bridge.read()) != nil {
                FileHandle.standardError.write(Data(
                    "[subscription-swap] auto-seed skipped (VM already has Codex creds)\n".utf8))
                return
            }
            let saltAccess = Data("codex-oauth-access:\(profile.id)".utf8)
            let saltRefresh = Data("codex-oauth-refresh:\(profile.id)".utf8)
            let saltID = Data("codex-oauth-id:\(profile.id)".utf8)
            guard let fakeAccess = SubscriptionFakeMint.mintJWTFake(
                    realJWT: stored.accessToken, salt: saltAccess),
                  let fakeID = SubscriptionFakeMint.mintJWTFake(
                    realJWT: realID, salt: saltID)
            else {
                FileHandle.standardError.write(Data(
                    "[subscription-swap] auto-seed Codex skipped (stored tokens aren't JWT-shaped)\n".utf8))
                return
            }
            let fakeRefresh = SubscriptionFakeMint.mintCodexRefreshFake(
                real: stored.refreshToken, salt: saltRefresh)
            swapper.appendEntries([
                .init(fake: fakeAccess, real: stored.accessToken,
                      host: "chatgpt.com", header: .authorization),
                .init(fake: fakeAccess, real: stored.accessToken,
                      host: "api.openai.com", header: .authorization),
                .init(fake: fakeRefresh, real: stored.refreshToken,
                      host: "auth.openai.com", header: .authorization,
                      body: true),
                .init(fake: fakeRefresh, real: stored.refreshToken,
                      host: "chatgpt.com", header: .authorization,
                      body: true),
                .init(fake: fakeID, real: realID,
                      host: "chatgpt.com", header: .authorization),
                .init(fake: fakeID, real: realID,
                      host: "auth.openai.com", header: .authorization),
            ], for: profile.id)
            try await bridge.write(access: fakeAccess,
                                    refresh: fakeRefresh,
                                    idToken: fakeID)
        } catch {
            FileHandle.standardError.write(Data(
                "[subscription-swap] auto-seed Codex failed: \(error)\n".utf8))
        }
    }

    public func unregister(profileID: UUID) {
        bridges[profileID]?.stop()
        bridges.removeValue(forKey: profileID)
        codexBridges[profileID]?.stop()
        codexBridges.removeValue(forKey: profileID)
        askedClaude.remove(profileID)
        askedCodex.remove(profileID)
        sheetWindowsClaude[profileID]?.close()
        sheetWindowsClaude.removeValue(forKey: profileID)
        sheetWindowsCodex[profileID]?.close()
        sheetWindowsCodex.removeValue(forKey: profileID)
    }

    /// Forget the per-session "Not now" decision — used when the
    /// user re-enables prompting from the profile editor.
    public func resetSessionDecision(profileID: UUID) {
        askedClaude.remove(profileID)
        askedCodex.remove(profileID)
    }

    /// Called by the proxy after an OAuth refresh response was
    /// rewritten and we have a fresh real-token triple. Updates the
    /// profile's `default*Tokens` (when set) so future sessions of
    /// the same profile auto-seed against the rotated values; also
    /// rotates the preferences template's defaults when they were
    /// the source of the profile's existing copy (i.e., the refresh
    /// token matches before the swap), so newly created profiles
    /// inherit the fresh tokens.
    public func recordRotation(profileID: UUID,
                                provider: OAuthRotationProvider,
                                tokens: StoredOAuthTokens,
                                store: ProfileStore) {
        guard var profile = store.loadAll().first(where: { $0.id == profileID })
        else { return }

        // Snapshot the pre-rotation refresh token so we can decide
        // whether the template's stored defaults travel along.
        let oldRefresh: String?
        switch provider {
        case .claude: oldRefresh = profile.defaultClaudeTokens?.refreshToken
        case .codex:  oldRefresh = profile.defaultCodexTokens?.refreshToken
        }

        // Profile-level update only when the user previously opted
        // into "save as default" — otherwise there's nothing to
        // rotate at the profile layer (the swap map already saw the
        // new pair via the rewriter).
        var profileDirty = false
        switch provider {
        case .claude:
            if profile.defaultClaudeTokens != nil {
                profile.defaultClaudeTokens = tokens
                profileDirty = true
            }
        case .codex:
            if profile.defaultCodexTokens != nil {
                profile.defaultCodexTokens = tokens
                profileDirty = true
            }
        }
        if profileDirty {
            do {
                try store.save(profile)
            } catch {
                FileHandle.standardError.write(Data(
                    "[oauth-rotate] couldn't save profile \(profileID): \(error)\n".utf8))
            }
        }

        // Template-level update: only when the template's stored
        // refresh matches the pre-rotation one — meaning the template
        // was originally seeded from this profile (or another that
        // shared the same login). If it diverged earlier (different
        // user logged in), leave it alone.
        guard let oldRefresh else { return }
        var template = store.loadTemplate()
        var templateDirty = false
        switch provider {
        case .claude:
            if template.defaultClaudeTokens?.refreshToken == oldRefresh {
                template.defaultClaudeTokens = tokens
                templateDirty = true
            }
        case .codex:
            if template.defaultCodexTokens?.refreshToken == oldRefresh {
                template.defaultCodexTokens = tokens
                templateDirty = true
            }
        }
        if templateDirty {
            do {
                try store.saveTemplate(template)
            } catch {
                FileHandle.standardError.write(Data(
                    "[oauth-rotate] couldn't save template: \(error)\n".utf8))
            }
        }
    }

    // MARK: - Detection hook

    /// Called by the proxy whenever a clean `sk-ant-oat01-…` access
    /// token is observed outbound to anthropic.com. Drops on the
    /// floor if the user has already declined / been asked this
    /// session / the bridge isn't connected yet.
    public func handleCleanAccessToken(_ token: String,
                                        profile: Profile,
                                        store: ProfileStore,
                                        swapper: TokenSwapper) {
        guard profile.subscriptionTokenSwap != .declined else { return }
        guard !askedClaude.contains(profile.id) else { return }
        askedClaude.insert(profile.id)

        // Bridge must be live — otherwise the agent isn't running yet
        // and a "Yes" would just fail. Surface a single-line stderr
        // note for debugging and bail; we'll re-prompt on the next
        // outbound request once the agent comes up.
        guard let bridge = bridges[profile.id], bridge.isConnected else {
            FileHandle.standardError.write(Data(
                "[subscription-swap] skipping prompt for \(profile.id): bridge not connected\n".utf8))
            askedClaude.remove(profile.id)
            return
        }

        presentSheet(profile: profile, bridge: bridge,
                     store: store, swapper: swapper)
    }

    /// Codex / ChatGPT counterpart of `handleCleanAccessToken`.
    public func handleCleanCodexAccessToken(_ token: String,
                                             profile: Profile,
                                             store: ProfileStore,
                                             swapper: TokenSwapper) {
        guard profile.codexTokenSwap != .declined else { return }
        guard !askedCodex.contains(profile.id) else { return }
        askedCodex.insert(profile.id)

        guard let bridge = codexBridges[profile.id], bridge.isConnected else {
            FileHandle.standardError.write(Data(
                "[subscription-swap] skipping codex prompt for \(profile.id): bridge not connected\n".utf8))
            askedCodex.remove(profile.id)
            return
        }
        presentCodexSheet(profile: profile, bridge: bridge,
                          store: store, swapper: swapper)
    }

    // MARK: - Sheet presentation

    private func presentSheet(profile: Profile,
                              bridge: SubscriptionTokenBridge,
                              store: ProfileStore,
                              swapper: TokenSwapper) {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        win.title = NSLocalizedString("Bromure — Claude Subscription Token",
                                      comment: "Subscription-token sheet window title")
        win.center()
        win.isReleasedWhenClosed = false
        let pid = profile.id
        let view = SubscriptionTokenSwapSheet(
            providerLabel: NSLocalizedString("Claude", comment: ""),
            outboundHost: "anthropic.com",
            profileName: profile.name.isEmpty ? "this profile" : profile.name
        ) { [weak self] decision in
            self?.handleClaudeDecision(decision,
                                        profile: profile,
                                        bridge: bridge,
                                        store: store,
                                        swapper: swapper)
            if decision != .swap {
                self?.sheetWindowsClaude[pid]?.close()
                self?.sheetWindowsClaude.removeValue(forKey: pid)
            }
        }
        win.contentView = NSHostingView(rootView: view)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        sheetWindowsClaude[profile.id] = win
    }

    private func presentCodexSheet(profile: Profile,
                                    bridge: CodexTokenBridge,
                                    store: ProfileStore,
                                    swapper: TokenSwapper) {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        win.title = NSLocalizedString("Bromure — Codex Subscription Token",
                                      comment: "Codex subscription sheet window title")
        win.center()
        win.isReleasedWhenClosed = false
        let pid = profile.id
        let view = SubscriptionTokenSwapSheet(
            providerLabel: NSLocalizedString("Codex", comment: ""),
            outboundHost: "chatgpt.com",
            profileName: profile.name.isEmpty ? "this profile" : profile.name
        ) { [weak self] decision in
            self?.handleCodexDecision(decision,
                                       profile: profile,
                                       bridge: bridge,
                                       store: store,
                                       swapper: swapper)
            if decision != .swap {
                self?.sheetWindowsCodex[pid]?.close()
                self?.sheetWindowsCodex.removeValue(forKey: pid)
            }
        }
        win.contentView = NSHostingView(rootView: view)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        sheetWindowsCodex[profile.id] = win
    }

    private func handleClaudeDecision(_ decision: SubscriptionTokenSwapSheet.Decision,
                                       profile: Profile,
                                       bridge: SubscriptionTokenBridge,
                                       store: ProfileStore,
                                       swapper: TokenSwapper) {
        switch decision {
        case .notNow:
            return
        case .never:
            persistClaude(profile: profile, state: .declined, store: store)
        case .swap:
            Task { @MainActor in
                defer {
                    self.sheetWindowsClaude[profile.id]?.close()
                    self.sheetWindowsClaude.removeValue(forKey: profile.id)
                }
                do {
                    try await self.runSwap(profile: profile,
                                            bridge: bridge,
                                            store: store,
                                            swapper: swapper)
                } catch {
                    self.presentSwapError(provider: "Claude",
                                           profile: profile, error: error)
                    self.askedClaude.remove(profile.id)
                }
            }
        }
    }

    private func handleCodexDecision(_ decision: SubscriptionTokenSwapSheet.Decision,
                                      profile: Profile,
                                      bridge: CodexTokenBridge,
                                      store: ProfileStore,
                                      swapper: TokenSwapper) {
        switch decision {
        case .notNow:
            return
        case .never:
            persistCodex(profile: profile, state: .declined, store: store)
        case .swap:
            Task { @MainActor in
                defer {
                    self.sheetWindowsCodex[profile.id]?.close()
                    self.sheetWindowsCodex.removeValue(forKey: profile.id)
                }
                do {
                    try await self.runCodexSwap(profile: profile,
                                                 bridge: bridge,
                                                 store: store,
                                                 swapper: swapper)
                } catch {
                    self.presentSwapError(provider: "Codex",
                                           profile: profile, error: error)
                    self.askedCodex.remove(profile.id)
                }
            }
        }
    }

    private func runSwap(profile: Profile,
                         bridge: SubscriptionTokenBridge,
                         store: ProfileStore,
                         swapper: TokenSwapper) async throws {
        guard let tokens = try await bridge.read() else {
            throw SubscriptionTokenBridge.BridgeError.agentRejected(
                "VM has no Claude credentials yet — log in inside the VM first")
        }
        let saltAccess = Data("anthropic-oauth-access:\(profile.id)".utf8)
        let saltRefresh = Data("anthropic-oauth-refresh:\(profile.id)".utf8)
        // Length-match the real tokens. Some clients (and possibly
        // Anthropic's own SDK) sanity-check token lengths; matching
        // the original avoids surprises.
        let fakeAccess = SessionTokenPlan.deriveFake(
            prefix: "sk-ant-oat01-brm-",
            real: tokens.access,
            salt: saltAccess,
            targetLength: tokens.access.count)
        let fakeRefresh = SessionTokenPlan.deriveFake(
            prefix: "sk-ant-ort01-brm-",
            real: tokens.refresh,
            salt: saltRefresh,
            targetLength: tokens.refresh.count)

        // Register both swaps before we tell the VM to write fakes —
        // otherwise an in-flight Claude API call could hit the proxy
        // with the now-fake access token before the swap is live and
        // get a 401.
        let entries: [TokenMap.Entry] = [
            .init(fake: fakeAccess, real: tokens.access,
                  host: "api.anthropic.com",
                  header: .authorization),
            // Refresh rides in the JSON body of POST /v1/oauth/token.
            // `body: true` makes the swapper sweep the body too.
            .init(fake: fakeRefresh, real: tokens.refresh,
                  host: "console.anthropic.com",
                  header: .authorization,
                  body: true),
        ]
        swapper.appendEntries(entries, for: profile.id)

        try await bridge.write(access: fakeAccess, refresh: fakeRefresh)
        persistClaude(profile: profile, state: .accepted, store: store)
        offerSaveAsDefault(provider: "Claude",
                           tokens: StoredOAuthTokens(
                               accessToken: tokens.access,
                               refreshToken: tokens.refresh,
                               idToken: nil),
                           kind: .claude,
                           store: store)
    }

    private func persistClaude(profile: Profile,
                                state: SubscriptionTokenSwapState,
                                store: ProfileStore) {
        var p = profile
        p.subscriptionTokenSwap = state
        try? store.save(p)
    }

    private func persistCodex(profile: Profile,
                               state: SubscriptionTokenSwapState,
                               store: ProfileStore) {
        var p = profile
        p.codexTokenSwap = state
        try? store.save(p)
    }

    private func runCodexSwap(profile: Profile,
                               bridge: CodexTokenBridge,
                               store: ProfileStore,
                               swapper: TokenSwapper) async throws {
        guard let tokens = try await bridge.read() else {
            throw CodexTokenBridge.BridgeError.agentRejected(
                "VM has no Codex credentials yet — run `codex login` inside the VM first")
        }
        // Codex's id_token + access_token are full JWTs that the CLI
        // parses to read non-secret claims (email, account_id, plan
        // type, expiry). The fake keeps the real header + payload and
        // replaces only the *signature* with same-length deterministic
        // chars carrying a `brm-cdX-sig` marker. The signature is the
        // only cryptographically interesting bit; the wire still
        // carries the real one because the proxy swaps it in before
        // the request leaves the Mac.
        //
        // refresh_token is NOT a JWT (`rt_<a>.<b>` shape) — it's
        // opaque to the CLI, so we just length-preserve and embed our
        // own marker after the literal `rt_` prefix.
        let saltAccess = Data("codex-oauth-access:\(profile.id)".utf8)
        let saltRefresh = Data("codex-oauth-refresh:\(profile.id)".utf8)
        let saltID = Data("codex-oauth-id:\(profile.id)".utf8)
        guard let fakeAccess = SubscriptionFakeMint.mintJWTFake(
                realJWT: tokens.access, salt: saltAccess),
              let fakeID = SubscriptionFakeMint.mintJWTFake(
                realJWT: tokens.idToken, salt: saltID)
        else {
            throw CodexTokenBridge.BridgeError.agentRejected(
                "Codex tokens aren't JWT-shaped — can't mint a structure-preserving fake")
        }
        let fakeRefresh = SubscriptionFakeMint.mintCodexRefreshFake(
            real: tokens.refresh, salt: saltRefresh)

        // Register fake↔real BEFORE asking the VM to write the fakes,
        // same reasoning as the Claude path. The refresh entries set
        // `body: true` because Codex's MCP / refresh path ships the
        // refresh token in the JSON body of POST /oauth/token, not in
        // an Authorization header.
        let entries: [TokenMap.Entry] = [
            .init(fake: fakeAccess, real: tokens.access,
                  host: "chatgpt.com", header: .authorization),
            .init(fake: fakeAccess, real: tokens.access,
                  host: "api.openai.com", header: .authorization),
            .init(fake: fakeRefresh, real: tokens.refresh,
                  host: "auth.openai.com", header: .authorization,
                  body: true),
            .init(fake: fakeRefresh, real: tokens.refresh,
                  host: "chatgpt.com", header: .authorization,
                  body: true),
            .init(fake: fakeID, real: tokens.idToken,
                  host: "chatgpt.com", header: .authorization),
            .init(fake: fakeID, real: tokens.idToken,
                  host: "auth.openai.com", header: .authorization),
        ]
        swapper.appendEntries(entries, for: profile.id)

        try await bridge.write(access: fakeAccess,
                               refresh: fakeRefresh,
                               idToken: fakeID)
        persistCodex(profile: profile, state: .accepted, store: store)
        offerSaveAsDefault(provider: "Codex",
                           tokens: StoredOAuthTokens(
                               accessToken: tokens.access,
                               refreshToken: tokens.refresh,
                               idToken: tokens.idToken),
                           kind: .codex,
                           store: store)
    }

    private enum DefaultTokenKind { case claude, codex }

    /// After a successful swap, ask the user whether to save the real
    /// tokens as the default for new profiles. On yes, write them
    /// into the global preferences template — `newProfileFromTemplate`
    /// then propagates them through the secrets blob so a freshly
    /// created profile auto-seeds its VM at first boot.
    private func offerSaveAsDefault(provider: String,
                                     tokens: StoredOAuthTokens,
                                     kind: DefaultTokenKind,
                                     store: ProfileStore) {
        let alert = NSAlert()
        alert.messageText = String(format: NSLocalizedString(
            "Use these %@ tokens for new sessions?",
            comment: "Save-as-default prompt title"), provider)
        alert.informativeText = String(format: NSLocalizedString(
            "We can save the real tokens as your default in Bromure → Preferences. New profiles you create will auto-seed their VM with proxy-side fakes derived from these tokens — you won't need to log in again on each new profile.",
            comment: "Save-as-default prompt body"))
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString(
            "Save as default", comment: ""))
        alert.addButton(withTitle: NSLocalizedString(
            "Not now", comment: ""))
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return }

        var template = store.loadTemplate()
        switch kind {
        case .claude: template.defaultClaudeTokens = tokens
        case .codex:  template.defaultCodexTokens  = tokens
        }
        // Pre-set the swap-state so freshly forked profiles skip the
        // consent prompt — the user already said "swap" once, and the
        // tokens are now in the template.
        switch kind {
        case .claude: template.subscriptionTokenSwap = .accepted
        case .codex:  template.codexTokenSwap = .accepted
        }
        do {
            try store.saveTemplate(template)
        } catch {
            let err = NSAlert()
            err.messageText = NSLocalizedString(
                "Couldn't save preferences", comment: "")
            err.informativeText = (error as? LocalizedError)?
                .errorDescription ?? "\(error)"
            err.alertStyle = .warning
            err.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            err.runModal()
        }
    }

    private func presentSwapError(provider: String,
                                   profile: Profile,
                                   error: Error) {
        let alert = NSAlert()
        alert.messageText = String(format: NSLocalizedString(
            "Couldn't swap the %@ token",
            comment: "Subscription-token swap error dialog title"), provider)
        alert.informativeText = (error as? LocalizedError)?
            .errorDescription ?? "\(error)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.runModal()
    }
}
