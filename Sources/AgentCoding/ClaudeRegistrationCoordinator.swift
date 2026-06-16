import AppKit
import Foundation
import Virtualization

/// "Register with Claude": capture a real Claude subscription credential once,
/// via a dedicated throwaway VM, and store it host-side so every session can use
/// it (the guest never does OAuth — see `ClaudeSubscriptionStore`).
///
/// The throwaway VM boots from the base image with NO profile mounts and NO
/// token-swap map, so the real `claude login` OAuth handshake completes
/// untouched. The sign-in URL opens in the *host* browser (AC has no in-VM
/// browser) and the `127.0.0.1` callback is bridged back over vsock, exactly as
/// in a normal session. Once the guest's `~/.claude/.credentials.json` holds
/// real tokens we read them over the vsock token bridge (port 8446), persist
/// them, and destroy the VM.

/// Where captured tokens go.
public enum ClaudeRegistrationScope: Sendable {
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
    let scope: ClaudeRegistrationScope
    let scratchProfile: Profile
    let scratchDir: URL
    var sandbox: UbuntuSandboxVM?
    var bridge: SubscriptionTokenBridge?
    var window: TabbedSessionWindow?
    var pollTask: Task<Void, Never>?
    var finished = false

    init(scope: ClaudeRegistrationScope, scratchProfile: Profile, scratchDir: URL) {
        self.scope = scope
        self.scratchProfile = scratchProfile
        self.scratchDir = scratchDir
    }
}

extension ACAppDelegate {

    /// Entry point for the "Register with Claude" button / menu item.
    @MainActor
    func beginClaudeRegistration(scope: ClaudeRegistrationScope) {
        // One at a time — bring an in-flight registration forward instead.
        if let existing = claudeRegistration {
            existing.window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let engine = mitmEngine else {
            registrationAlert(title: NSLocalizedString("Proxy unavailable", comment: ""),
                              text: NSLocalizedString(
                                "The Bromure proxy isn't running, so registration can't capture your Claude tokens.",
                                comment: ""))
            return
        }

        // Explainer.
        let explainer = NSAlert()
        explainer.messageText = NSLocalizedString("Register with Claude", comment: "")
        explainer.informativeText = NSLocalizedString(
            "Bromure will open a temporary, isolated VM with no access to your profiles or saved secrets. Claude Code will open its sign-in page in your Mac's browser. After you sign in, Bromure captures the credentials, then shuts down and deletes the VM.",
            comment: "")
        explainer.addButton(withTitle: NSLocalizedString("Continue", comment: ""))
        explainer.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        guard explainer.runModal() == .alertFirstButtonReturn else { return }

        // Scratch profile: Claude + subscription, no folders / SSH / creds / MCP
        // / env, fresh random id → unique throwaway directory we delete after.
        let scratch = Profile(name: "Register with Claude", tool: .claude, authMode: .subscription)
        let scratchDir = store.profileDirectory(for: scratch)
        let state = ClaudeRegistrationState(scope: scope, scratchProfile: scratch, scratchDir: scratchDir)
        claudeRegistration = state

        // Session disk with NO token plan and (below) NO swap map — the real
        // OAuth handshake must reach Anthropic untouched. We still ship the CA +
        // bridge + token agent + loopback relay so egress works and we can read
        // the credentials back.
        let sessionDisk = SessionDisk(profile: scratch, store: store,
                                      baseDiskURL: imageManager.baseDiskURL)
        sessionDisk.tokenPlan = nil
        if let scriptURL = bridgeScriptURL {
            sessionDisk.mitmAssets = SessionDisk.MitmSessionAssets(
                caCertificatePEM: engine.ca.certificatePEM,
                bridgeScriptURL: scriptURL,
                keyboardAgentURL: keyboardAgentURL,
                awsCredsHelperURL: awsCredsHelperURL,
                claudeTokenAgentURL: claudeTokenAgentURL,
                codexTokenAgentURL: codexTokenAgentURL,
                shellAgentURL: nil,
                loopbackRelayAgentURL: loopbackRelayAgentURL)
        }

        let win = TabbedSessionWindow(profile: scratch, acDelegate: self)
        win.delegate = self
        win.title = NSLocalizedString("Register with Claude", comment: "")
        win.pendingCloseAction = .shutdown   // never snapshot a throwaway
        win.center()
        win.makeKeyAndOrderFront(nil)
        win.isReleasedWhenClosed = false
        state.window = win
        let firstTab = win.appendTab()

        let sandbox = UbuntuSandboxVM(imageManager: imageManager, sessionDisk: sessionDisk)
        state.sandbox = sandbox

        Task { @MainActor in
            do {
                // Create the home dir + write the .bashrc whose auto-launch runs
                // `claude` (kicking off the OAuth login). Without this the
                // home virtiofs share points at a missing path and VZ rejects
                // the config ("directory sharing configuration is invalid").
                try self.store.prepareHomeDirectory(
                    for: scratch, terminalDefaults: self.terminalDefaults)
                try sandbox.prepare()
                win.vmView.virtualMachine = sandbox.vm
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
            // `requestSpawnKitty` resolves the outbox via `win.sandbox` — set it
            // before spawning or the command is silently dropped (black screen,
            // no kitty).
            win.sandbox = sandbox

            let bridge = SubscriptionTokenBridge(socketDevice: dev)
            state.bridge = bridge

            // First kitty → the guest's .bashrc auto-runs `claude`; with no
            // credential it starts the OAuth login (URL → host browser).
            self.requestSpawnKitty(id: firstTab.id, in: win)
            self.pollForClaudeRegistration(state: state, bridge: bridge)
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
    private func pollForClaudeRegistration(state: ClaudeRegistrationState,
                                           bridge: SubscriptionTokenBridge) {
        state.pollTask = Task { @MainActor in
            // Agent connects ~15–60s after boot (xinitrc starts it post-getty).
            for _ in 0..<240 {
                if Task.isCancelled { return }
                if bridge.isConnected { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            // Then poll for credentials (~4 min budget for the human login).
            for _ in 0..<240 {
                if Task.isCancelled { return }
                if let tokens = try? await bridge.read() {
                    self.finishClaudeRegistration(state: state, tokens: tokens)
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if Task.isCancelled { return }
            self.registrationAlert(
                title: NSLocalizedString("Registration timed out", comment: ""),
                text: NSLocalizedString(
                    "Bromure didn't receive a Claude sign-in in time. You can try again.",
                    comment: ""))
            self.teardownClaudeRegistration(reason: .timeout)
        }
    }

    /// Persist the captured tokens per the scope, then tear down + confirm.
    private func finishClaudeRegistration(state: ClaudeRegistrationState,
                                          tokens: SubscriptionTokenBridge.Tokens) {
        guard !state.finished, let store = mitmEngine?.claudeSubscriptionStore else {
            teardownClaudeRegistration(reason: .failure)
            return
        }
        // distantPast expiry → the proxy refreshes on first use, which both
        // establishes the real expiry and proves the refresh path immediately.
        let record = ClaudeSubscriptionRecord(
            accessToken: tokens.access, refreshToken: tokens.refresh,
            expiresAt: .distantPast, savedAt: Date())

        var sharedEverywhere = true
        if case .askPerSession(let pid) = state.scope {
            let ask = NSAlert()
            ask.messageText = NSLocalizedString("Share with every session?", comment: "")
            ask.informativeText = NSLocalizedString(
                "Use this Claude sign-in for every Bromure session, or only for this profile?",
                comment: "")
            ask.addButton(withTitle: NSLocalizedString("Every session", comment: ""))
            ask.addButton(withTitle: NSLocalizedString("Just this profile", comment: ""))
            sharedEverywhere = (ask.runModal() == .alertFirstButtonReturn)
            do {
                if sharedEverywhere { try store.setShared(record) }
                else { try store.setOverride(record, for: pid) }
            } catch {
                showError(error, message: NSLocalizedString(
                    "Couldn't save the Claude credentials.", comment: ""))
            }
        } else {
            do { try store.setShared(record) }
            catch {
                showError(error, message: NSLocalizedString(
                    "Couldn't save the Claude credentials.", comment: ""))
            }
        }

        teardownClaudeRegistration(reason: .success)

        let done = NSAlert()
        done.messageText = NSLocalizedString("Registered with Claude", comment: "")
        done.informativeText = sharedEverywhere
            ? NSLocalizedString("Saved for all sessions. New Claude sessions will use it automatically.", comment: "")
            : NSLocalizedString("Saved for this profile.", comment: "")
        done.runModal()
    }

    /// Idempotent teardown: stop polling + bridge, kill + delete the VM, close
    /// the window. Safe to call from the window-close handler, the poll task,
    /// or the success path.
    func teardownClaudeRegistration(reason: ClaudeRegistrationTeardownReason) {
        guard let state = claudeRegistration, !state.finished else { return }
        state.finished = true

        state.pollTask?.cancel()
        state.bridge?.stop()

        mitmEngine?.unregister(profileID: state.scratchProfile.id)
        mitmEngine?.claudeSubscriptionStore.unregisterBogusKeys(for: state.scratchProfile.id)

        // Detach the window's sandbox so the close path below doesn't try to
        // suspend/poweroff it (we own the stop here).
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

        // When the user closed the window, AppKit is already tearing it down;
        // otherwise close it ourselves. Either way, `claudeRegistration` is
        // still set so the close handler re-enters here and no-ops via
        // `finished`.
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
