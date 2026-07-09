import AppKit
import Foundation
import Virtualization

/// "Register with Claude / ChatGPT": capture a real subscription credential
/// once, via a dedicated throwaway VM, and store it host-side so every session
/// can use it (the guest never does OAuth — see `ClaudeSubscriptionStore` /
/// `CodexSubscriptionStore`).
///
/// The throwaway VM boots from the base image with NO profile mounts and NO
/// token-swap map, so the real `claude login` / `codex login` OAuth handshake
/// completes untouched. The sign-in URL opens in the *host* browser (AC has no
/// in-VM browser) and the `127.0.0.1` callback is bridged back over vsock,
/// exactly as in a normal session. Once the guest's credentials file holds real
/// tokens we read them over the vsock token bridge, persist them, and destroy
/// the VM.

public extension Notification.Name {
    /// Posted after a subscription credential is registered or forgotten, so
    /// open editors re-read their per-tool registration status.
    static let bromureSubscriptionStoresChanged = Notification.Name("bromureSubscriptionStoresChanged")
}

public enum SubscriptionProvider: Sendable {
    case claude
    case codex
    case grok

    var displayName: String {
        switch self { case .claude: return "Claude"; case .codex: return "ChatGPT"; case .grok: return "Grok" }
    }
    var scratchTool: Profile.Tool {
        switch self { case .claude: return .claude; case .codex: return .codex; case .grok: return .grok }
    }
    var scratchName: String { "Register with \(displayName)" }
}

/// Where captured tokens go.
public enum SubscriptionRegistrationScope: Sendable {
    /// From Preferences — store as the shared default, no prompt.
    case alwaysShared
    /// From a profile/session — ask "every session vs just this profile".
    case askPerSession(UUID)
}

enum ClaudeRegistrationTeardownReason {
    case success, cancelled, failure, timeout, windowClosed
}

/// Transient state for one in-flight registration. Retained by the app delegate
/// (`claudeRegistration`) so the window stays alive and teardown is single-shot.
@MainActor
final class ClaudeRegistrationState {
    let provider: SubscriptionProvider
    let scope: SubscriptionRegistrationScope
    let scratchProfile: Profile
    let scratchDir: URL
    var sandbox: UbuntuSandboxVM?
    var claudeBridge: SubscriptionTokenBridge?
    var codexBridge: CodexTokenBridge?
    var window: TabbedSessionWindow?
    var pollTask: Task<Void, Never>?
    var finished = false

    init(provider: SubscriptionProvider, scope: SubscriptionRegistrationScope,
         scratchProfile: Profile, scratchDir: URL) {
        self.provider = provider
        self.scope = scope
        self.scratchProfile = scratchProfile
        self.scratchDir = scratchDir
    }
}

extension ACAppDelegate {

    /// Entry point for the "Register with Claude / ChatGPT" button / menu item.
    @MainActor
    func beginSubscriptionRegistration(provider: SubscriptionProvider,
                                       scope: SubscriptionRegistrationScope) {
        // One at a time — bring an in-flight registration forward instead.
        if let existing = claudeRegistration {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let engine = mitmEngine else {
            registrationAlert(title: NSLocalizedString("Proxy unavailable", comment: ""),
                              text: NSLocalizedString(
                                "The Bromure proxy isn't running, so registration can't capture your tokens.",
                                comment: ""))
            return
        }

        // Explainer.
        let explainer = NSAlert()
        explainer.messageText = String(format: NSLocalizedString("Register with %@", comment: ""),
                                       provider.displayName)
        explainer.informativeText = String(format: NSLocalizedString(
            "Bromure will open a temporary, isolated VM with no access to your workspaces or saved secrets. %@ will open its sign-in page in your Mac's browser. After you sign in, Bromure captures the credentials, then shuts down and deletes the VM.",
            comment: ""), provider.displayName)
        explainer.addButton(withTitle: NSLocalizedString("Continue", comment: ""))
        explainer.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        guard explainer.runModal() == .alertFirstButtonReturn else { return }

        // Scratch profile: the right tool + subscription, no folders / SSH /
        // creds / MCP / env, fresh random id → unique throwaway dir we delete.
        let scratch = Profile(name: provider.scratchName, tool: provider.scratchTool,
                              authMode: .subscription)
        let scratchDir = store.profileDirectory(for: scratch)
        let state = ClaudeRegistrationState(provider: provider, scope: scope,
                                            scratchProfile: scratch, scratchDir: scratchDir)
        claudeRegistration = state

        // Session disk with NO token plan and (below) NO swap map — the real
        // OAuth handshake must reach upstream untouched. We still ship the CA +
        // bridge + token agents + loopback relay so egress works and we can read
        // the credentials back.
        let sessionDisk = SessionDisk(profile: scratch, store: store,
                                      baseDiskURL: imageManager.baseDiskURL)
        sessionDisk.tokenPlan = nil
        sessionDisk.registrationMode = true   // auto-launch the agent for login
        if let scriptURL = bridgeScriptURL {
            sessionDisk.mitmAssets = SessionDisk.MitmSessionAssets(
                caCertificatePEM: engine.ca.certificatePEM,
                bridgeScriptURL: scriptURL,
                awsCredsHelperURL: awsCredsHelperURL,
                claudeTokenAgentURL: claudeTokenAgentURL,
                codexTokenAgentURL: codexTokenAgentURL,
                shellAgentURL: nil,
                loopbackRelayAgentURL: loopbackRelayAgentURL)
        }

        let win = TabbedSessionWindow(profile: scratch, acDelegate: self)
        win.delegate = self
        win.title = String(format: NSLocalizedString("Register with %@", comment: ""),
                           provider.displayName)
        // The registration throwaway window is intercepted in windowWillClose by
        // the claudeRegistration check (teardownClaudeRegistration destroys the
        // scratch VM), so it never reaches the session detach/stop path.
        win.center()
        win.makeKeyAndOrderFront(nil)
        win.isReleasedWhenClosed = false
        state.window = win
        win.model.tabs = [TabsModel.Tab(label: "shell")]

        let sandbox = UbuntuSandboxVM(imageManager: imageManager, sessionDisk: sessionDisk)
        state.sandbox = sandbox

        Task { @MainActor in
            do {
                // Create the home dir + write the .bashrc whose auto-launch runs
                // the agent (kicking off the OAuth login). Without this the home
                // virtiofs share points at a missing path and VZ rejects the
                // config ("directory sharing configuration is invalid").
                try self.store.prepareHomeDirectory(
                    for: scratch, terminalDefaults: self.terminalDefaults)
                try sandbox.prepare()
                try await sandbox.start()
            } catch {
                self.showError(error, message: NSLocalizedString(
                    "Couldn't start the registration VM.", comment: ""))
                self.teardownClaudeRegistration(reason: .failure)
                return
            }
            guard let dev = sandbox.socketDevice else {
                self.teardownClaudeRegistration(reason: .failure)
                return
            }
            // Proxy listeners for egress — but deliberately NO swapper.setMap,
            // so this profile id has an empty swap map and tokens pass through.
            engine.register(socketDevice: dev, profileID: scratch.id)
            self.wireRegistrationSandbox(sandbox)
            self.registerSession(sandbox, profile: win.profile)
            win.sandbox = sandbox

            switch provider {
            case .claude: state.claudeBridge = SubscriptionTokenBridge(socketDevice: dev)
            case .codex:  state.codexBridge = CodexTokenBridge(socketDevice: dev)
            case .grok:   break  // no vsock agent — captured from the home-dir file
            }

            // The guest agent auto-launches the kitty → tmux session, whose
            // .bashrc runs the OAuth login (URL → host browser). No host spawn.
            self.pollForSubscriptionRegistration(state: state)
        }
    }

    /// Host-browser login + teardown-on-stop wiring for the throwaway VM.
    private func wireRegistrationSandbox(_ sandbox: UbuntuSandboxVM) {
        sandbox.onStopped = { [weak self] _ in
            Task { @MainActor in self?.teardownClaudeRegistration(reason: .windowClosed) }
        }
        sandbox.onURLOpen = { [weak self, weak sandbox] url in
            Task { @MainActor in
                if let self, let sandbox,
                   let port = ACAppDelegate.loopbackCallbackPort(from: url),
                   let dev = sandbox.socketDevice,
                   let fwd = LoopbackCallbackForwarder(port: port, socketDevice: dev) {
                    self.loopbackForwarders.removeAll { !$0.isRunning }
                    self.loopbackForwarders.append(fwd)
                }
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Wait for the in-VM token agent, then poll the credentials file until the
    /// user's login lands real tokens (or we time out).
    private func pollForSubscriptionRegistration(state: ClaudeRegistrationState) {
        // Grok has no vsock agent — its creds land in the (host-mounted) home
        // dir, which we poll directly.
        let grokAuthURL = store.homeDirectory(for: state.scratchProfile)
            .appendingPathComponent(".grok/auth.json")
        state.pollTask = Task { @MainActor in
            // Bridge providers connect ~15–60s after boot; Grok has no bridge.
            if state.provider != .grok {
                for _ in 0..<240 {
                    if Task.isCancelled { return }
                    let isUp = state.claudeBridge?.isConnected ?? state.codexBridge?.isConnected ?? false
                    if isUp { break }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            // Then poll for credentials (~4 min budget for the human login).
            for _ in 0..<240 {
                if Task.isCancelled { return }
                if let claude = state.claudeBridge, let t = try? await claude.read() {
                    self.finishClaudeRegistration(state: state,
                        record: .claude(access: t.access, refresh: t.refresh))
                    return
                }
                if let codex = state.codexBridge, let t = try? await codex.read() {
                    self.finishClaudeRegistration(state: state,
                        record: .codex(access: t.access, refresh: t.refresh, idToken: t.idToken))
                    return
                }
                if state.provider == .grok, let g = Self.readGrokAuthFile(at: grokAuthURL) {
                    self.finishClaudeRegistration(state: state,
                        record: .grok(access: g.access, refresh: g.refresh,
                                      scopeKey: g.scopeKey, template: g.template))
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if Task.isCancelled { return }
            self.registrationAlert(
                title: NSLocalizedString("Registration timed out", comment: ""),
                text: String(format: NSLocalizedString(
                    "Bromure didn't receive a %@ sign-in in time. You can try again.",
                    comment: ""), state.provider.displayName))
            self.teardownClaudeRegistration(reason: .timeout)
        }
    }

    /// Captured-token payload, shaped per provider.
    enum CapturedSubscription {
        case claude(access: String, refresh: String)
        case codex(access: String, refresh: String, idToken: String)
        case grok(access: String, refresh: String, scopeKey: String, template: Data)
    }

    /// Read real Grok tokens from a freshly-written `~/.grok/auth.json`, or nil
    /// until the user has signed in. Shape: `{ "<scope>": { key, refresh_token,
    /// expires_at, auth_mode, team_name, … } }`. We capture the FULL entry so
    /// the seed can reproduce every account-specific field grok requires.
    static func readGrokAuthFile(at url: URL)
        -> (access: String, refresh: String, expiresAt: Date, scopeKey: String, template: Data)? {
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let scopes = [grokOIDCScope] + obj.keys.filter { $0 != grokOIDCScope }
        for scope in scopes {
            guard var entry = obj[scope] as? [String: Any],
                  let key = entry["key"] as? String, !key.isEmpty,
                  !key.hasPrefix("grok-brm-") else { continue }   // skip our own bogus
            let refresh = (entry["refresh_token"] as? String) ?? ""
            let exp: Date
            if let s = entry["expires_at"] as? String,
               let d = ISO8601DateFormatter().date(from: s) { exp = d }
            else if let e = entry["expires_at"] as? Double { exp = Date(timeIntervalSince1970: e) }
            else if let e = entry["expires_at"] as? Int { exp = Date(timeIntervalSince1970: Double(e)) }
            else { exp = .distantPast }
            // Stash a template that keeps the account fields but drops the live
            // secrets (re-injected, as bogus, at seed time).
            entry.removeValue(forKey: "key")
            entry.removeValue(forKey: "refresh_token")
            entry.removeValue(forKey: "expires_at")
            let template = (try? JSONSerialization.data(withJSONObject: entry)) ?? Data()
            return (key, refresh, exp, scope, template)
        }
        return nil
    }

    /// Persist the captured tokens per the scope, then tear down + confirm.
    private func finishClaudeRegistration(state: ClaudeRegistrationState,
                                          record captured: CapturedSubscription) {
        guard !state.finished, let engine = mitmEngine else {
            teardownClaudeRegistration(reason: .failure)
            return
        }
        // distantPast expiry → the proxy refreshes on first use, which both
        // establishes the real expiry and proves the refresh path immediately.
        var sharedEverywhere = true
        var overrideProfile: UUID? = nil
        if case .askPerSession(let pid) = state.scope {
            let ask = NSAlert()
            ask.messageText = NSLocalizedString("Share with every session?", comment: "")
            ask.informativeText = String(format: NSLocalizedString(
                "Use this %@ sign-in for every Bromure session, or only for this workspace?",
                comment: ""), state.provider.displayName)
            ask.addButton(withTitle: NSLocalizedString("Every session", comment: ""))
            ask.addButton(withTitle: NSLocalizedString("Just this workspace", comment: ""))
            sharedEverywhere = (ask.runModal() == .alertFirstButtonReturn)
            if !sharedEverywhere { overrideProfile = pid }
        }

        do {
            switch captured {
            case .claude(let access, let refresh):
                let rec = ClaudeSubscriptionRecord(
                    accessToken: access, refreshToken: refresh,
                    expiresAt: .distantPast, savedAt: Date())
                if let pid = overrideProfile { try engine.claudeSubscriptionStore.setOverride(rec, for: pid) }
                else { try engine.claudeSubscriptionStore.setShared(rec) }
            case .codex(let access, let refresh, let idToken):
                let rec = CodexSubscriptionRecord(
                    accessToken: access, refreshToken: refresh, idToken: idToken,
                    expiresAt: .distantPast, savedAt: Date())
                if let pid = overrideProfile { try engine.codexSubscriptionStore.setOverride(rec, for: pid) }
                else { try engine.codexSubscriptionStore.setShared(rec) }
            case .grok(let access, let refresh, let scopeKey, let template):
                // Force an immediate proactive refresh on first use to establish
                // the real expiry + prove the refresh path.
                let rec = GrokSubscriptionRecord(
                    accessToken: access, refreshToken: refresh,
                    expiresAt: .distantPast, savedAt: Date(),
                    scopeKey: scopeKey, templateJSON: template)
                if let pid = overrideProfile { try engine.grokSubscriptionStore.setOverride(rec, for: pid) }
                else { try engine.grokSubscriptionStore.setShared(rec) }
            }
        } catch {
            showError(error, message: NSLocalizedString(
                "Couldn't save the captured credentials.", comment: ""))
        }

        let providerName = state.provider.displayName
        // Let any open profile editor flip its inline Register → Re-register.
        NotificationCenter.default.post(name: .bromureSubscriptionStoresChanged, object: nil)
        teardownClaudeRegistration(reason: .success)

        let done = NSAlert()
        done.messageText = String(format: NSLocalizedString("Registered with %@", comment: ""), providerName)
        done.informativeText = sharedEverywhere
            ? NSLocalizedString("Saved for all sessions. New sessions will use it automatically.", comment: "")
            : NSLocalizedString("Saved for this workspace.", comment: "")
        done.runModal()
    }

    /// Idempotent teardown: stop polling + bridge, kill + delete the VM, close
    /// the window. Safe to call from the window-close handler, the poll task,
    /// or the success path.
    func teardownClaudeRegistration(reason: ClaudeRegistrationTeardownReason) {
        guard let state = claudeRegistration, !state.finished else { return }
        state.finished = true

        state.pollTask?.cancel()
        state.claudeBridge?.stop()
        state.codexBridge?.stop()

        mitmEngine?.unregister(profileID: state.scratchProfile.id)
        mitmEngine?.claudeSubscriptionStore.unregisterBogusKeys(for: state.scratchProfile.id)
        mitmEngine?.codexSubscriptionStore.unregisterBogusKeys(for: state.scratchProfile.id)
        mitmEngine?.grokSubscriptionStore.unregisterBogusKeys(for: state.scratchProfile.id)

        // Drop the registry entry + the window borrow so the close path below
        // sees no VM and won't try to suspend/poweroff it — we own the stop
        // here via `state.sandbox`.
        unregisterSession(state.scratchProfile.id)
        state.window?.sandbox = nil

        let dir = state.scratchDir
        if let sandbox = state.sandbox {
            sandbox.stopPolling()
            sandbox.onStopped = nil   // don't re-enter teardown on stop
            if let vm = sandbox.vm, vm.state == .running {
                vm.stop(completionHandler: { _ in
                    try? FileManager.default.removeItem(at: dir)
                })
            } else {
                try? FileManager.default.removeItem(at: dir)
            }
        } else {
            try? FileManager.default.removeItem(at: dir)
        }

        if reason != .windowClosed {
            state.window?.close()
        }
        claudeRegistration = nil
    }

    private func registrationAlert(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
