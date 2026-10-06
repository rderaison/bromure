import AppKit
import Foundation
import SandboxEngine
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

// Notification.Name.bromureSubscriptionStoresChanged lives in
// ProfileViews.swift (shared with iOS) next to the editor that observes it.

public enum SubscriptionProvider: String, Sendable, CaseIterable {
    case claude
    case codex
    case grok
    case kimi

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex:  return "ChatGPT"
        case .grok:   return "Grok"
        case .kimi:   return "Kimi"
        }
    }
    var scratchTool: Profile.Tool {
        switch self {
        case .claude: return .claude
        case .codex:  return .codex
        case .grok:   return .grok
        case .kimi:   return .kimi
        }
    }
    /// True for providers with no vsock token agent, whose credentials are
    /// read straight out of the (host-mounted) home dir instead.
    var capturesFromHomeDir: Bool {
        switch self {
        case .grok, .kimi: return true
        case .claude, .codex: return false
        }
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
    /// True once the host has kicked (or confirmed) the agent launch in the
    /// guest's tmux window, so the roster ticks don't retry it.
    var agentLaunchStarted = false
    /// The login CLI was seen running (or its sign-in URL reached the host),
    /// so the launch watchdog stands down.
    var agentLaunchConfirmed = false
    /// The launch watchdog (see `RegistrationLaunch`).
    var launchTask: Task<Void, Never>?
    /// A sign-in card drives this flow: no explainer or completion alerts,
    /// the throwaway VM stays off screen, and progress goes here instead.
    var quiet = false
    var onEvent: ((HostSignInEvent) -> Void)?

    init(provider: SubscriptionProvider, scope: SubscriptionRegistrationScope,
         scratchProfile: Profile, scratchDir: URL) {
        self.provider = provider
        self.scope = scope
        self.scratchProfile = scratchProfile
        self.scratchDir = scratchDir
    }
}

/// A registration started by a REMOTE client (the macOS fat client). The
/// throwaway VM and the credential store live here on the host, but the human
/// is at the other end of the tunnel — so instead of opening the provider's
/// sign-in page in this Mac's browser, we publish it for the client to open in
/// ITS browser. The OAuth callback comes back through the client's existing
/// `forward <ip> <port>` tunnel, which already reaches a guest's loopback via
/// the vsock relay on port 5010 (the same path LoopbackCallbackForwarder uses
/// locally), so no new SSH verb is needed.
@MainActor
final class RemoteRegistrationBroker {
    static let shared = RemoteRegistrationBroker()

    struct Pending {
        let provider: String
        /// The provider's sign-in URL, for the client's browser.
        var url: String?
        /// The throwaway VM's guest IP + the loopback port its CLI is waiting
        /// on. The client needs both to point its local listener at the VM.
        var vmIP: String?
        var callbackPort: Int?
        /// Set when the flow finished (captured or cancelled) so the client
        /// can tear its listener down.
        var finished = false
    }

    private(set) var pending: Pending?

    func begin(provider: String) { pending = Pending(provider: provider) }
    func publish(url: String, callbackPort: Int) {
        pending?.url = url
        pending?.callbackPort = callbackPort
    }
    func publish(vmIP: String) { pending?.vmIP = vmIP }
    func finish() { pending?.finished = true; pending = nil }

    /// `/state` payload — nil until a remote registration is in flight.
    func stateDict() -> [String: Any]? {
        guard let p = pending else { return nil }
        var d: [String: Any] = ["provider": p.provider]
        if let u = p.url { d["url"] = u }
        if let ip = p.vmIP { d["vmIP"] = ip }
        if let port = p.callbackPort { d["callbackPort"] = port }
        return d
    }
}

extension ACAppDelegate {

    /// Entry point for the "Register with Claude / ChatGPT" button / menu item.
    /// `remoteInitiated`: a fat client asked for this, so skip the local
    /// explainer alert (nobody is at this screen) and route the sign-in URL to
    /// the client instead of this Mac's browser.
    /// `quiet` + `events`: a session's sign-in card is driving — no alerts,
    /// the throwaway VM's window stays hidden, and the card hears progress
    /// (`.status`) and the outcome (`.finished`).
    @MainActor
    func beginSubscriptionRegistration(provider: SubscriptionProvider,
                                       scope: SubscriptionRegistrationScope,
                                       remoteInitiated: Bool = false,
                                       quiet: Bool = false,
                                       events: ((HostSignInEvent) -> Void)? = nil) {
        // One at a time — bring an in-flight registration forward instead
        // (only locally; a remote-initiated flow has no window to show here).
        if let existing = claudeRegistration {
            if !remoteInitiated, !quiet { existing.window?.makeKeyAndOrderFront(nil) }
            events?(.finished(success: false, message: NSLocalizedString(
                "Another sign-in is already in progress.", comment: "sign-in")))
            return
        }
        guard let engine = mitmEngine else {
            if !remoteInitiated, !quiet {
                registrationAlert(title: NSLocalizedString("Proxy unavailable", comment: ""),
                                  text: NSLocalizedString(
                                    "The Bromure proxy isn't running, so registration can't capture your tokens.",
                                    comment: ""))
            }
            events?(.finished(success: false, message: NSLocalizedString(
                "The Bromure proxy isn't running, so the sign-in can't be captured.", comment: "sign-in")))
            return
        }

        // Explainer — a sheet (or a non-modal panel), never `runModal`: this
        // is reached from main-actor tasks too, and a modal loop entered there
        // holds the whole main queue (control socket, automation boots).
        // Remote-initiated: nobody is sitting at this Mac to answer, and the
        // client already showed its own confirmation before calling. A
        // sign-in card explained itself already.
        guard !remoteInitiated, !quiet else {
            startSubscriptionRegistration(provider: provider, scope: scope, engine: engine,
                                          remoteInitiated: remoteInitiated, quiet: quiet,
                                          events: events)
            return
        }
        let explainer = NSAlert()
        explainer.messageText = String(format: NSLocalizedString("Register with %@", comment: ""),
                                       provider.displayName)
        explainer.informativeText = String(format: NSLocalizedString(
            "Bromure will open a temporary, isolated VM with no access to your workspaces or saved secrets. %@ will open its sign-in page in your Mac's browser. After you sign in, Bromure captures the credentials, then shuts down and deletes the VM.",
            comment: ""), provider.displayName)
        explainer.addButton(withTitle: NSLocalizedString("Continue", comment: ""))
        explainer.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        presentRegistrationAlert(explainer, on: nil,
                                 fallback: .alertFirstButtonReturn) { [weak self] resp in
            guard let self, resp == .alertFirstButtonReturn else { return }
            // Re-check: another flow may have started while the sheet was up.
            if let existing = self.claudeRegistration {
                existing.window?.makeKeyAndOrderFront(nil)
                return
            }
            guard let engine = self.mitmEngine else { return }
            self.startSubscriptionRegistration(provider: provider, scope: scope, engine: engine,
                                               remoteInitiated: false, quiet: false,
                                               events: events)
        }
    }

    /// The flow proper, once the user (or the caller) said go.
    private func startSubscriptionRegistration(provider: SubscriptionProvider,
                                               scope: SubscriptionRegistrationScope,
                                               engine: MitmEngine,
                                               remoteInitiated: Bool,
                                               quiet: Bool,
                                               events: ((HostSignInEvent) -> Void)?) {
        if remoteInitiated { RemoteRegistrationBroker.shared.begin(provider: provider.displayName) }

        // Scratch profile: the right tool + subscription, no folders / SSH /
        // creds / MCP / env, fresh random id → unique throwaway dir we delete.
        // Deliberately on the legacy virtiofs home: the VM lives minutes, and
        // the Grok / Kimi flows harvest their credentials file by polling the
        // host-side home dir — which only exists in the virtiofs model.
        let scratch = Profile(name: provider.scratchName, tool: provider.scratchTool,
                              authMode: .subscription, homeModel: .virtiofs)
        let scratchDir = store.profileDirectory(for: scratch)
        let state = ClaudeRegistrationState(provider: provider, scope: scope,
                                            scratchProfile: scratch, scratchDir: scratchDir)
        state.quiet = quiet
        state.onEvent = events
        claudeRegistration = state
        events?(.status(NSLocalizedString("Setting up a private sign-in machine…", comment: "sign-in")))

        // Session disk with NO token plan and (below) NO swap map — the real
        // OAuth handshake must reach upstream untouched. We still ship the CA +
        // bridge + token agents + loopback relay so egress works and we can read
        // the credentials back.
        let sessionDisk = SessionDisk(profile: scratch, store: store,
                                      baseDiskURL: imageManager.baseDiskURL)
        sessionDisk.tokenPlan = nil
        sessionDisk.registrationMode = true   // auto-launch the agent for login
        if let scriptURL = bridgeScriptURL {
            // agentd included: it creates the guest tmux session, publishes
            // the tab roster, and serves the vsock shell channel the native
            // ghostty surface attaches through — without it the login runs on
            // the invisible tty1 console and the window stays blank.
            sessionDisk.mitmAssets = SessionDisk.MitmSessionAssets(
                caCertificatePEM: engine.ca.certificatePEM,
                bridgeScriptURL: scriptURL,
                awsCredsHelperURL: awsCredsHelperURL,
                claudeTokenAgentURL: claudeTokenAgentURL,
                codexTokenAgentURL: codexTokenAgentURL,
                shellAgentURL: shellAgentURL,
                loopbackRelayAgentURL: loopbackRelayAgentURL,
                agentdURL: agentdURL)
        }

        let win = TabbedSessionWindow(profile: scratch, acDelegate: self)
        // The login is interactive (sign-in URL, the CLI's prompts) and the
        // beautified transcript hides exactly those, so this window is pinned to
        // the raw terminal regardless of the user's usual view preference.
        win.pane.beautifierLocked = true
        win.delegate = self
        win.title = String(format: NSLocalizedString("Register with %@", comment: ""),
                           provider.displayName)
        // The registration throwaway window is intercepted in windowWillClose by
        // the claudeRegistration check (teardownClaudeRegistration destroys the
        // scratch VM), so it never reaches the session detach/stop path.
        win.center()
        // Remote-initiated (fat client): keep the throwaway VM headless on the
        // server. Nobody is sitting here to see it, and showing it pops a window
        // on the wrong machine. The VM still boots and the login agent runs; the
        // sign-in page opens on the CLIENT via RemoteRegistrationBroker.
        if !remoteInitiated, !quiet {
            win.makeKeyAndOrderFront(nil)
        }
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
                if !remoteInitiated, !quiet {
                    self.registrationAlert(
                        title: NSLocalizedString("Couldn't start the registration VM.", comment: ""),
                        text: error.localizedDescription)
                }
                state.onEvent?(.finished(success: false, message: NSLocalizedString(
                    "Couldn't start the sign-in machine.", comment: "sign-in")))
                state.onEvent = nil
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
            // Shell bridge (vsock 5800): the native surface's __attach-window
            // resolves its PTY through this, exactly like a normal session.
            self.shellBridges[scratch.id] = ShellBridge(socketDevice: dev)
            self.wireRegistrationSandbox(sandbox, window: win)
            self.registerSession(sandbox, profile: win.profile)
            win.sandbox = sandbox

            switch provider {
            case .claude: state.claudeBridge = SubscriptionTokenBridge(socketDevice: dev)
            case .codex:  state.codexBridge = CodexTokenBridge(socketDevice: dev)
            case .grok, .kimi: break  // no vsock agent — captured from the home-dir file
            }

            // Window 0 of the guest tmux session sources .bashrc, whose
            // BROMURE_AC_REGISTER auto-launch runs the OAuth login (URL →
            // host browser). The first roster tick mounts the native ghostty
            // surface on that window via applyTabList. No host spawn.
            self.pollForSubscriptionRegistration(state: state)
        }
    }

    /// Host-browser login + teardown-on-stop wiring for the throwaway VM.
    /// Deliberately NOT `wireSandboxCallbacks`: its onStopped routes into the
    /// session relaunch machinery, which would fight the throwaway teardown.
    private func wireRegistrationSandbox(_ sandbox: UbuntuSandboxVM,
                                         window: TabbedSessionWindow) {
        sandbox.onStopped = { [weak self] _ in
            Task { @MainActor in self?.teardownClaudeRegistration(reason: .windowClosed) }
        }
        // Record the guest's vmnet IP (published to the outbox every ~5s).
        // Normal sessions get this via wireSandboxCallbacks, which this flow
        // deliberately skips — but lastIP feeds BOTH ends of the remote
        // (fat-client) callback tunnel: the /state publish that tells the
        // client where to point its 127.0.0.1 listener, and the forward
        // resolver's session-by-IP lookup when the OAuth callback comes back.
        // Without it the client never binds a listener and the provider's
        // localhost redirect dies on connection refused.
        sandbox.onIPUpdate = { [weak self] ip in
            Task { @MainActor in
                guard let self, let state = self.claudeRegistration else { return }
                self.runningSessions[state.scratchProfile.id]?.lastIP = ip
                if RemoteRegistrationBroker.shared.pending != nil {
                    RemoteRegistrationBroker.shared.publish(vmIP: ip)
                }
            }
        }
        // Roster → tab pills + native terminal mount (applyTabList calls
        // updateNativeTerminalMount). The registration pane isn't in the
        // shared pane registry, so target the window's pane directly. Once
        // the session is up, directly invoke the login agent in the guest —
        // don't rely on the .bashrc auto-launch heuristic.
        sandbox.onTabList = { [weak self, weak window] tabs in
            Task { @MainActor in
                window?.pane.applyTabList(tabs)
                if !tabs.isEmpty { self?.launchRegistrationAgentIfNeeded() }
            }
        }
        let providerName = self.claudeRegistration?.provider.displayName ?? "your account"
        sandbox.onURLOpen = { [weak self, weak sandbox] url in
            Task { @MainActor in
                // The CLI got as far as its sign-in URL: it is running.
                self?.claudeRegistration?.agentLaunchConfirmed = true
                // Remote-initiated: the human is at the fat client, so hand
                // it the URL + the VM's loopback port and let it open the page
                // and tunnel the callback. Opening here would sign in on the
                // wrong machine (and nobody would see the page).
                // The broker holds a Pending only for a remote-initiated run,
                // so its presence IS the "route this to the client" signal —
                // no need to thread a flag down into the sandbox wiring.
                if RemoteRegistrationBroker.shared.pending != nil {
                    let port = ACAppDelegate.loopbackCallbackPort(from: url)
                    RemoteRegistrationBroker.shared.publish(
                        url: url.absoluteString, callbackPort: Int(port ?? 0))
                    if let pid = self?.claudeRegistration?.scratchProfile.id,
                       let ip = self?.runningSessions[pid]?.lastIP {
                        RemoteRegistrationBroker.shared.publish(vmIP: ip)
                    }
                    return
                }
                if let self, let sandbox,
                   let port = ACAppDelegate.loopbackCallbackPort(from: url),
                   let dev = sandbox.socketDevice,
                   // Registration answers the browser itself with a clean
                   // success page — the CLI callback servers otherwise leave
                   // Safari on an error even though login succeeded.
                   let fwd = LoopbackCallbackForwarder(
                        port: port, socketDevice: dev,
                        browserResponse: LoopbackCallbackForwarder
                            .registrationSuccessResponse(provider: providerName)) {
                    self.loopbackForwarders.removeAll { !$0.isRunning }
                    self.loopbackForwarders.append(fwd)
                }
                self?.claudeRegistration?.onEvent?(.status(NSLocalizedString(
                    "Finish signing in in your browser…", comment: "sign-in")))
                ACAppDelegate.openGuestRelayedURL(url)
            }
        }
    }

    /// Make sure the login CLI actually runs in the scratch VM's tmux window,
    /// rather than trusting the guest `.bashrc` auto-launch (which can land on
    /// a bare shell — e.g. when agentd spawns window 0 before the virtiofs
    /// home is mounted). A watchdog probes the guest every couple of seconds
    /// (`RegistrationLaunch.Tracker`): it types the login command only once
    /// the pane has been an idle shell for two probes in a row, re-sends a
    /// bounded number of times, and stands down as soon as the login process
    /// runs or its sign-in URL reaches the host. If it never starts, the
    /// user gets a Retry / Cancel prompt (a sign-in card or a remote client
    /// hears a failure instead) — no more silent four-minute timeout on a
    /// bare `bash`. Idempotent: one watchdog per attempt.
    private func launchRegistrationAgentIfNeeded() {
        guard let state = claudeRegistration, !state.finished,
              !state.agentLaunchStarted else { return }
        state.agentLaunchStarted = true
        let provider = state.provider
        let pid = state.scratchProfile.id
        let probe = RegistrationLaunch.probeScript(for: provider)
        let launch = RegistrationLaunch.launchScript(for: provider)
        state.launchTask?.cancel()
        state.launchTask = Task { @MainActor [weak self] in
            var tracker = RegistrationLaunch.Tracker()
            // Give the guest `.bashrc` auto-launch its head start.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            while !Task.isCancelled {
                guard let self, let live = self.claudeRegistration, live === state,
                      !live.finished else { return }
                if live.agentLaunchConfirmed { return }
                let out = try? await self.guestExec(profileID: pid, command: probe, timeout: 10)
                guard !Task.isCancelled, !live.finished else { return }
                if live.agentLaunchConfirmed { return }
                switch tracker.next(RegistrationLaunch.Probe(output: out)) {
                case .confirmed:
                    live.agentLaunchConfirmed = true
                    FileHandle.standardError.write(Data(
                        "[registration] \(provider.rawValue) login running\n".utf8))
                    return
                case .send:
                    FileHandle.standardError.write(Data(
                        "[registration] typing \(provider.rawValue) login (attempt \(tracker.sends))\n".utf8))
                    _ = try? await self.guestExec(profileID: pid, command: launch, timeout: 10)
                case .wait:
                    break
                case .fail(let failure):
                    self.registrationLaunchFailed(state: live, failure: failure)
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// The login CLI never started. A local, visible flow asks Retry /
    /// Cancel on the registration window (a sheet — never a modal run from
    /// this main-actor task, which would wedge the control socket); a sign-in
    /// card or a fat client hears the failure and the VM is torn down.
    private func registrationLaunchFailed(state: ClaudeRegistrationState,
                                          failure: RegistrationLaunch.Failure) {
        let message = RegistrationLaunch.failureMessage(failure, provider: state.provider)
        FileHandle.standardError.write(Data("[registration] launch failed: \(failure)\n".utf8))
        let remote = RemoteRegistrationBroker.shared.pending != nil
        if remote || state.quiet || headless {
            state.onEvent?(.finished(success: false, message: message))
            state.onEvent = nil
            teardownClaudeRegistration(reason: .failure)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(format: NSLocalizedString(
            "Couldn't start the %@ sign-in", comment: "registration launch failure title"),
            state.provider.displayName)
        alert.informativeText = message + "\n\n" + NSLocalizedString(
            "Retry types the sign-in command into the sign-in machine again.",
            comment: "registration launch failure")
        alert.addButton(withTitle: NSLocalizedString("Retry", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        presentRegistrationAlert(alert, on: state.window,
                                 fallback: .alertSecondButtonReturn) { [weak self] resp in
            guard let self, let live = self.claudeRegistration, live === state,
                  !live.finished else { return }
            if resp == .alertFirstButtonReturn {
                live.agentLaunchStarted = false
                self.launchRegistrationAgentIfNeeded()
            } else {
                self.teardownClaudeRegistration(reason: .cancelled)
            }
        }
    }

    /// Wait for the in-VM token agent, then poll the credentials file until the
    /// user's login lands real tokens (or we time out).
    private func pollForSubscriptionRegistration(state: ClaudeRegistrationState) {
        // Grok has no vsock agent — its creds land in the (host-mounted) home
        // dir, which we poll directly.
        let home = store.homeDirectory(for: state.scratchProfile)
        let grokAuthURL = home.appendingPathComponent(".grok/auth.json")
        let kimiHome = home.appendingPathComponent(".kimi-code", isDirectory: true)
        state.pollTask = Task { @MainActor in
            // Bridge providers connect ~15–60s after boot; Grok/Kimi have none.
            if !state.provider.capturesFromHomeDir {
                for _ in 0..<240 {
                    if Task.isCancelled { return }
                    let isUp = state.claudeBridge?.isConnected ?? state.codexBridge?.isConnected ?? false
                    if isUp {
                        state.onEvent?(.status(NSLocalizedString(
                            "Almost there — your browser will open in a moment…", comment: "sign-in")))
                        break
                    }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            // Then poll for credentials (~4 min budget for the human login).
            for _ in 0..<240 {
                if Task.isCancelled { return }
                if let claude = state.claudeBridge, let t = try? await claude.read() {
                    await self.finishClaudeRegistration(state: state,
                        record: .claude(access: t.access, refresh: t.refresh))
                    return
                }
                if let codex = state.codexBridge, let t = try? await codex.read() {
                    await self.finishClaudeRegistration(state: state,
                        record: .codex(access: t.access, refresh: t.refresh, idToken: t.idToken))
                    return
                }
                if state.provider == .grok, let g = Self.readGrokAuthFile(at: grokAuthURL) {
                    await self.finishClaudeRegistration(state: state,
                        record: .grok(access: g.access, refresh: g.refresh,
                                      scopeKey: g.scopeKey, template: g.template))
                    return
                }
                if state.provider == .kimi, let k = Self.readKimiCredentials(in: kimiHome) {
                    await self.finishClaudeRegistration(state: state,
                        record: .kimi(access: k.access, refresh: k.refresh, name: k.name,
                                      template: k.template, configTOML: k.configTOML))
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if Task.isCancelled { return }
            // Never wedge the server with a blocking modal for a fat-client
            // flow — nobody is at this Mac to dismiss it, and `runModal` would
            // freeze the control loop until it's answered. Teardown clears the
            // relay so the client learns the sign-in didn't land. Only show the
            // alert when a local user started the registration.
            state.onEvent?(.finished(success: false, message: String(format: NSLocalizedString(
                "Bromure didn't receive a %@ sign-in in time. You can try again.",
                comment: ""), state.provider.displayName)))
            state.onEvent = nil
            if RemoteRegistrationBroker.shared.pending == nil, !state.quiet {
                self.registrationAlert(
                    title: NSLocalizedString("Registration timed out", comment: ""),
                    text: String(format: NSLocalizedString(
                        "Bromure didn't receive a %@ sign-in in time. You can try again.",
                        comment: ""), state.provider.displayName))
            }
            self.teardownClaudeRegistration(reason: .timeout)
        }
    }

    /// Captured-token payload, shaped per provider.
    enum CapturedSubscription {
        case claude(access: String, refresh: String)
        case codex(access: String, refresh: String, idToken: String)
        case grok(access: String, refresh: String, scopeKey: String, template: Data)
        case kimi(access: String, refresh: String, name: String, template: Data,
                  configTOML: String?)
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

    /// Read real Kimi tokens from `~/.kimi-code/credentials/<name>.json`, or
    /// nil until the user has signed in. Wire shape (packages/oauth types.ts):
    /// `{ access_token, refresh_token, expires_at (unix s), scope, token_type,
    /// expires_in }`. We prefer the managed `kimi-code` flow's file but accept
    /// any credential in the dir, capture the FULL entry minus secrets as a
    /// template, and pick up the `config.toml` `/login` wrote so a seeded guest
    /// starts with the managed provider + model list already configured.
    static func readKimiCredentials(in kimiHome: URL)
        -> (access: String, refresh: String, name: String, template: Data,
            configTOML: String?)? {
        let credDir = kimiHome.appendingPathComponent("credentials", isDirectory: true)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: credDir, includingPropertiesForKeys: nil) else { return nil }
        // Managed flow first, then any other provider the user logged into.
        let jsons = entries.filter { $0.pathExtension == "json" }
        let ordered = jsons.sorted { a, _ in
            a.deletingPathExtension().lastPathComponent == kimiManagedCredentialName
        }
        for url in ordered {
            guard let data = try? Data(contentsOf: url),
                  var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let access = obj["access_token"] as? String, !access.isEmpty,
                  // Skip our own bogus seed (both the JWT-mint and the
                  // deriveFake fallback shapes).
                  !access.hasPrefix("kimi-brm-") else { continue }
            let refresh = (obj["refresh_token"] as? String) ?? ""
            obj.removeValue(forKey: "access_token")
            obj.removeValue(forKey: "refresh_token")
            obj.removeValue(forKey: "expires_at")
            let template = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
            let name = url.deletingPathExtension().lastPathComponent
            let toml = try? String(
                contentsOf: kimiHome.appendingPathComponent("config.toml"), encoding: .utf8)
            // The credential lands FIRST; `kimi login` then provisions the
            // managed models over the network and only after that writes the
            // provider + models + default_model into config.toml. Accepting
            // the instant the credential appears captured an empty config
            // (and tore the VM down mid-provisioning), so every session that
            // re-seeded it died at "No model configured". Keep polling until
            // the managed provider is on disk; the caller's budget covers it.
            guard let toml, Self.kimiConfigIsProvisioned(toml) else { continue }
            return (access, refresh, name, template, toml)
        }
        return nil
    }

    /// Whether a captured `~/.kimi-code/config.toml` carries what `kimi
    /// login` writes once provisioning finished — the managed provider AND
    /// a `default_model` (they land in separate writes; a provider block
    /// alone still starts the CLI with "LLM not set").
    static func kimiConfigIsProvisioned(_ toml: String) -> Bool {
        KimiProvisioner.isProvisioned(toml)
    }

    /// Drop every workspace's own sign-in for `provider`, so a login the user
    /// just chose to share is the one every workspace reads.
    func forgetProviderOverrides(_ provider: SubscriptionProvider) {
        guard let engine = mitmEngine else { return }
        for p in profiles {
            switch provider {
            case .claude:
                if engine.claudeSubscriptionStore.hasProfileRecord(p.id) { try? engine.claudeSubscriptionStore.forget(for: p.id) }
            case .codex:
                if engine.codexSubscriptionStore.hasProfileRecord(p.id) { try? engine.codexSubscriptionStore.forget(for: p.id) }
            case .grok:
                if engine.grokSubscriptionStore.hasProfileRecord(p.id) { try? engine.grokSubscriptionStore.forget(for: p.id) }
            case .kimi:
                if engine.kimiSubscriptionStore.hasProfileRecord(p.id) { try? engine.kimiSubscriptionStore.forget(for: p.id) }
            }
        }
    }

    /// Persist the captured tokens per the scope, then tear down + confirm.
    ///
    /// Scope matters more than it looks: a workspace reads its own
    /// per-workspace sign-in first and the shared one only when it has none,
    /// so a stale per-workspace login silently shadows every later shared
    /// registration ("I re-registered and the proxy still uses the old
    /// token"). Hence: the question is asked over the fat client too (it
    /// used to default to per-workspace without asking), and "Every
    /// workspace" also drops that provider's per-workspace logins so the
    /// new sign-in really is what every workspace uses.
    private func finishClaudeRegistration(state: ClaudeRegistrationState,
                                          record captured: CapturedSubscription) async {
        guard !state.finished, let engine = mitmEngine else {
            teardownClaudeRegistration(reason: .failure)
            return
        }
        // distantPast expiry → the proxy refreshes on first use, which both
        // establishes the real expiry and proves the refresh path immediately.
        var sharedEverywhere = true
        var overrideProfile: UUID? = nil
        if case .askPerSession(let pid) = state.scope {
            let title = NSLocalizedString("Share with every workspace?", comment: "")
            let body = String(format: NSLocalizedString(
                "Use this %@ sign-in for every Bromure workspace (replacing any workspace's own %@ sign-in), or only for this one?",
                comment: ""), state.provider.displayName, state.provider.displayName)
            let buttons = [NSLocalizedString("Every workspace", comment: ""),
                           NSLocalizedString("Just this workspace", comment: "")]
            if RemoteRegistrationBroker.shared.pending != nil {
                // Remote flow: the client that registered gets the question
                // (a runModal here would wedge the control loop). Nobody
                // answering keeps the conservative choice — just this
                // workspace.
                let choice = await PendingPromptBroker.shared.askAsync(
                    profileID: pid, title: title, message: body, buttons: buttons, fallback: 1)
                guard !state.finished else { return }
                sharedEverywhere = (choice == 0)
            } else {
                // A sheet awaited async — `runModal` here (inside the poll
                // task, on the main actor) froze the control socket until it
                // was answered. Headless: the conservative choice.
                let ask = NSAlert()
                ask.messageText = title
                ask.informativeText = body
                for b in buttons { ask.addButton(withTitle: b) }
                let resp = await presentRegistrationAlert(ask, on: state.window,
                                                          fallback: .alertSecondButtonReturn)
                guard !state.finished else { return }
                sharedEverywhere = (resp == .alertFirstButtonReturn)
            }
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
            case .kimi(let access, let refresh, let name, let template, let configTOML):
                // Same forced-refresh-on-first-use rationale as Grok below.
                let rec = KimiSubscriptionRecord(
                    accessToken: access, refreshToken: refresh,
                    expiresAt: .distantPast, savedAt: Date(),
                    credentialName: name, templateJSON: template,
                    configTOML: configTOML)
                if let pid = overrideProfile { try engine.kimiSubscriptionStore.setOverride(rec, for: pid) }
                else { try engine.kimiSubscriptionStore.setShared(rec) }
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
            if sharedEverywhere { forgetProviderOverrides(state.provider) }
        } catch {
            if RemoteRegistrationBroker.shared.pending == nil {
                registrationAlert(
                    title: NSLocalizedString("Couldn't save the captured credentials.", comment: ""),
                    text: error.localizedDescription)
            } else {
                FileHandle.standardError.write(Data(
                    "[registration] couldn't save captured credentials: \(error)\n".utf8))
            }
        }

        let providerName = state.provider.displayName
        // Let any open profile editor flip its inline Register → Re-register.
        NotificationCenter.default.post(name: .bromureSubscriptionStoresChanged, object: nil)
        // The sign-in card: done — it restarts the agent on the stand-in key.
        state.onEvent?(.finished(success: true, message: nil))
        state.onEvent = nil

        // Don't stop the VM out from under the OAuth callback: tokens land
        // while the CLI's 127.0.0.1 server may still be answering the host
        // browser through the loopback relay, and killing the guest mid-splice
        // makes Safari report "the remote host closed the connection
        // abruptly". Wait for in-flight relays to drain (bounded), plus a
        // short linger for the TCP close to propagate, then tear down.
        Task { @MainActor in
            // Capture before teardown clears the relay below.
            let wasRemote = RemoteRegistrationBroker.shared.pending != nil
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline,
                  self.loopbackForwarders.contains(where: { $0.activeRelays > 0 }) {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.teardownClaudeRegistration(reason: .success)

            // Remote flow: the client already sees success (the subscription
            // store change flips its editor's Register → Re-register via /state).
            // Don't block the headless server with a completion modal. A
            // sign-in card said it itself.
            guard !wasRemote, !state.quiet else { return }
            let done = NSAlert()
            done.messageText = String(format: NSLocalizedString("Registered with %@", comment: ""), providerName)
            done.informativeText = sharedEverywhere
                ? NSLocalizedString("Saved for all workspaces. New workspaces will use it automatically.", comment: "")
                : NSLocalizedString("Saved for this workspace.", comment: "")
            self.presentRegistrationAlert(done, on: nil, fallback: .alertFirstButtonReturn) { _ in }
        }
    }

    /// Idempotent teardown: stop polling + bridge, kill + delete the VM, close
    /// the window. Safe to call from the window-close handler, the poll task,
    /// or the success path.
    func teardownClaudeRegistration(reason: ClaudeRegistrationTeardownReason) {
        guard let state = claudeRegistration, !state.finished else { return }
        state.finished = true
        // A card still listening only hears from here when the flow died
        // (cancelled, window closed, failure): success reported itself.
        if reason != .success, let ev = state.onEvent {
            ev(.finished(success: false, message: nil))
            state.onEvent = nil
        }

        // Clear the remote-registration relay so a fat client's /state stops
        // advertising this flow and tears down its sign-in page + callback
        // tunnel. No-op for a local flow (no pending). (Previously never called,
        // so the relay lingered after every remote registration.)
        RemoteRegistrationBroker.shared.finish()

        state.pollTask?.cancel()
        state.launchTask?.cancel()
        state.claudeBridge?.stop()
        state.codexBridge?.stop()
        shellBridges[state.scratchProfile.id]?.stop()
        shellBridges.removeValue(forKey: state.scratchProfile.id)

        mitmEngine?.unregister(profileID: state.scratchProfile.id)
        mitmEngine?.claudeSubscriptionStore.unregisterBogusKeys(for: state.scratchProfile.id)
        mitmEngine?.codexSubscriptionStore.unregisterBogusKeys(for: state.scratchProfile.id)
        mitmEngine?.grokSubscriptionStore.unregisterBogusKeys(for: state.scratchProfile.id)
        mitmEngine?.kimiSubscriptionStore.unregisterBogusKeys(for: state.scratchProfile.id)

        // Retire the pane's native terminal surfaces up front, while the view
        // is still alive, so closing the window below can't leave libghostty
        // firing an action against a freed surface (a use-after-free crash on
        // the success path). `retire()` unregisters each surface from the
        // runtime's live set and delays the free.
        state.window?.pane.retireNativeTerminals()

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
        // Defense in depth: callers already skip this on the remote-initiated
        // path, but an informational alert must never wedge a server a fat
        // client is mirroring. When someone's watching remotely, log it instead.
        if PendingPromptBroker.hasLiveListener() {
            FileHandle.standardError.write(Data("[ac/registration] \(title) — \(text)\n".utf8))
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        presentRegistrationAlert(alert, on: nil, fallback: .alertFirstButtonReturn) { _ in }
    }

    /// Show a registration alert WITHOUT a modal loop: as a sheet on
    /// `preferred` (or the home window) when one is on screen, otherwise as a
    /// free-standing non-modal panel. `NSAlert.runModal()` reached from a
    /// main-actor task holds every other main-queue job — the control socket
    /// (`/state` and every debug call hang), automation boots — until someone
    /// at this Mac clicks. Headless: nobody to ask, `fallback` at once.
    func presentRegistrationAlert(_ alert: NSAlert, on preferred: NSWindow?,
                                  fallback: NSApplication.ModalResponse,
                                  completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard !headless else { completion(fallback); return }
        let candidates: [NSWindow?] = [preferred, unifiedWindow, mainWindow]
        if let host = candidates.compactMap({ $0 }).first(where: {
            $0.isVisible && $0.attachedSheet == nil
        }) {
            alert.beginSheetModal(for: host, completionHandler: completion)
            return
        }
        NonModalAlertPresenter.show(alert, completion: completion)
    }

    func presentRegistrationAlert(_ alert: NSAlert, on preferred: NSWindow?,
                                  fallback: NSApplication.ModalResponse) async
        -> NSApplication.ModalResponse {
        await withCheckedContinuation { cont in
            presentRegistrationAlert(alert, on: preferred, fallback: fallback) {
                cont.resume(returning: $0)
            }
        }
    }
}

/// An `NSAlert` shown as an ordinary floating window instead of through
/// `runModal()`: its buttons are re-targeted at this presenter, which hides
/// the window and reports the clicked button's response. Used when there is
/// no window to hang a sheet on.
@MainActor
final class NonModalAlertPresenter: NSObject {
    private static var live: Set<NonModalAlertPresenter> = []
    private let alert: NSAlert
    private let completion: (NSApplication.ModalResponse) -> Void

    private init(alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        self.alert = alert
        self.completion = completion
    }

    static func show(_ alert: NSAlert,
                     completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if alert.buttons.isEmpty { alert.addButton(withTitle: NSLocalizedString("OK", comment: "")) }
        let p = NonModalAlertPresenter(alert: alert, completion: completion)
        live.insert(p)
        for (i, b) in alert.buttons.enumerated() {
            b.tag = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + i
            b.target = p
            b.action = #selector(NonModalAlertPresenter.clicked(_:))
        }
        alert.layout()
        let w = alert.window
        w.level = .floating
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    @objc private func clicked(_ sender: NSButton) {
        alert.window.orderOut(nil)
        Self.live.remove(self)
        completion(NSApplication.ModalResponse(rawValue: sender.tag))
    }
}
