import Foundation

/// The daemon as the proxy sign-in's host (macOS: SessionSignIn+App.swift),
/// and where a fat client's sign-ins start: the card's and Preferences'
/// both run the registration machine (LinuxRegistration), whose page is
/// published for the client (RemoteRegistrationBroker in /state); the
/// client opens it and tunnels the callback into the guest's loopback
/// (`forward <vmIP> <port>`, the vsock 5010 relay). guestExec and
/// proxySignIns are the session host's.
extension LinuxSessionHost: ProxySignInHost {
    /// The proxy's side; nil while the daemon has no proxy.
    // @port-skip linux-only: ACAppDelegate.proxySignInBackend over the daemon's MitmProxy
    var proxySignInBackend: ProxySignInBackend? {
        guard let mitm = daemon?.mitm else { return nil }
        return ProxySignInBackend(captures: mitm.captures, claude: mitm.claudeStore, codex: mitm.codexStore,
                                  grok: mitm.grokStore, kimi: mitm.kimiStore)
    }

    /// `POST /agent-sessions/<id>/signin`, a fat client's sign-in card: the
    /// throwaway machine runs here (LinuxRegistration), the client opens the
    /// page (RemoteRegistrationBroker via /state) and tunnels the callback;
    /// once the credential lands, the session's agent restarts on the
    /// stand-in key. The reply names the run (`registration`); its end
    /// reaches the client through /state's `registrationEnded`.
    // @port-skip linux-only: the "signin" case of ACAppDelegate's onAgentSessionCommand, over LinuxRegistration
    func remoteSignIn(_ sid: UUID) -> [String: Any] {
        guard let s = agentSessionStore.session(sid) else { return ["error": "unknown session"] }
        guard let provider = SubscriptionProvider(rawValue: s.tool.rawValue) else {
            return ["error": "no account sign-in for \(s.tool.rawValue)"]
        }
        guard registration == nil else {
            return ["error": NSLocalizedString("Another sign-in is already in progress.", comment: "sign-in")]
        }
        let pid = s.profileID
        // A start that fails at once says why in the reply; a later end
        // reaches the client's card through /state's `registrationEnded`.
        var refused: String?
        beginSubscriptionRegistration(provider: provider, scope: .alwaysShared, events: { [weak self] event in
            guard case .finished(let ok, let message) = event else { return }
            guard ok else { refused = message; return }
            Task { @MainActor in
                guard let self else { return }
                self.applyRegisteredSubscription(provider: provider, profileID: pid)
                SessionStores.shared?.engine?.relaunchAfterSignIn(sid)
            }
        })
        guard let run = RemoteRegistrationBroker.shared.pending?.id else {
            return ["error": refused ?? RemoteRegistrationBroker.shared.ended?.message ?? "the sign-in couldn't start"]
        }
        return ["ok": true, "registration": run.uuidString]
    }

    /// `POST /subscriptions/register {provider, profileId?}` (Preferences or
    /// a workspace's editor): nil when started, else why not. With a
    /// workspace, the client is asked whether the login is for every
    /// workspace or just that one.
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onBeginRegistration h=1ec1fe4d5d722db0 @7057d502
    func beginRemoteRegistration(provider: String, profileID: String?) -> String? {
        guard let p = SubscriptionProvider(rawValue: provider) else { return "unknown provider \(provider)" }
        guard registration == nil else {   // one at a time
            return NSLocalizedString("Another sign-in is already in progress.", comment: "sign-in")
        }
        let scope: SubscriptionRegistrationScope = profileID
            .flatMap(UUID.init(uuidString:)).map { .askPerSession($0) } ?? .alwaysShared
        var refused: String?
        beginSubscriptionRegistration(provider: p, scope: scope, events: { event in
            if case .finished(false, let message) = event { refused = message }
        })
        // Only the synchronous refusal; a later end reaches the client
        // through /state.
        registration?.onEvent = nil
        guard RemoteRegistrationBroker.shared.pending != nil else {
            return refused ?? RemoteRegistrationBroker.shared.ended?.message
                ?? NSLocalizedString("The sign-in didn't complete. You can try again.", comment: "sign-in")
        }
        return nil
    }

    /// The workspace runs the agent on its subscription now (macOS: the
    /// same profile edit, then a live credential push).
    // @port ACAppDelegate.applyRegisteredSubscription(provider: SubscriptionProvider, profileID: UUID) h=6e8dabf79e5bbc2c @dd7ba30d
    func applyRegisteredSubscription(provider: SubscriptionProvider, profileID: UUID) {
        let store = ProfileStore()
        guard var p = store.loadAll().first(where: { $0.id == profileID }) else { return }
        let tool = provider.scratchTool
        var changed = false
        if p.tool == tool, p.authMode != .subscription { p.authMode = .subscription; changed = true }
        for i in p.additionalTools.indices
        where p.additionalTools[i].tool == tool && p.additionalTools[i].authMode != .subscription {
            p.additionalTools[i].authMode = .subscription; changed = true
        }
        if p.tool != tool, !p.additionalTools.contains(where: { $0.tool == tool }) {
            p.additionalTools.append(Profile.ToolSpec(tool: tool, authMode: .subscription))
            changed = true
        }
        if changed {
            do { try store.update(p) } catch {
                FileHandle.standardError.write(Data("bromure-ac daemon: sign-in: couldn't save profile: \(error)\n".utf8))
            }
            applyLiveEditToRunningSession(p)
        } else if let daemon, Self.running.withLockedValue({ $0.contains(p.id) }) {
            // Nothing in the profile moved, but a credential exists now: the
            // whole restage (macOS: pushLiveCredentials).
            let pid = p.id
            Task { if let id = await daemon.runningVMID(of: pid) { await daemon.scheduleLiveRestage(id) } }
        }
    }

    /// The guests' URL relay (`url-*.txt` in the outbox or its relay folder,
    /// from bromure-open): at most 8 a tick, 8 KiB each, http(s) only,
    /// consumed as read (macOS: UbuntuSandboxVM's outbox poll).
    // @port-skip linux-only: the url-*.txt half of UbuntuSandboxVM.startOutboxPolling, on the host
    func readGuestURLs() {
        let fm = FileManager.default
        for id in Self.running.withLockedValue({ $0 }) {
            let outbox = stateDir + "/vms/" + id.uuidString.lowercased() + "/outbox/"
            let paths = HomeSeed.outboxFolders(outbox, SessionDisk.outboxURLRelayFolder).flatMap { dir in
                ((try? fm.contentsOfDirectory(atPath: dir)) ?? [])
                    .filter { $0.hasPrefix("url-") && $0.hasSuffix(".txt") }.map { (name: $0, path: dir + $0) }
            }.sorted { $0.name < $1.name }.map(\.path)
            for path in paths.prefix(8) {
                let raw = GuestOutbox.read(path, limit: 8 << 10)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                try? fm.removeItem(atPath: path)
                guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
                      ["http", "https"].contains(scheme) else { continue }
                guestOpenedURL(url, profileID: id)
            }
        }
    }

    /// A page the guest opened. A server has no browser: the one it acts on
    /// is a sign-in's, published for the client that asked for it, with the
    /// guest port its callback comes back to; any other is logged, dropped.
    // partial: a page that isn't a sign-in's is dropped (a macOS server opens it on its own screen)
    // @port ACAppDelegate.wireSandboxCallbacks(_: UbuntuSandboxVM) / sandbox.onURLOpen h=1e83b10fabd16924 @b10aa434
    func guestOpenedURL(_ url: URL, profileID pid: UUID) {
        // The registration machine's login: its page goes to the client.
        if let reg = registration, reg.scratchProfile.id == pid, !reg.finished {
            registrationOpenedURL(url, state: reg)
            return
        }
        guard let signIn = proxySignIns[pid], !signIn.finished else {
            // Any other page: a macOS server shows it on its own screen; a
            // Linux server has none (the agents' browsing rides the browser
            // MCP relay to the client instead).
            FileHandle.standardError.write(Data("bromure-ac daemon: guest page not opened (no browser here): \(url.host ?? "?")\n".utf8))
            return
        }
        guard GuestURLGate.opensInRealBrowser(url) else {
            endProxySignIn(signIn, success: false, message: NSLocalizedString(
                "The sign-in page the agent opened points at this Mac or its local network, so Bromure didn't open it.",
                comment: "sign-in refused: the guest's sign-in URL has a local or private host"))
            return
        }
        let broker = RemoteRegistrationBroker.shared
        let port = GuestURLGate.loopbackCallbackPort(from: url).map(Int.init) ?? 0
        signIn.onEvent?(.status(NSLocalizedString("Finish signing in in your browser…", comment: "sign-in")))
        // The address first: a client that sees the page also sees where
        // its callback goes.
        Task { @MainActor [weak self] in
            if let ip = await self?.daemon?.guestIP(pid) { broker.publish(vmIP: ip) }
            broker.publish(url: url.absoluteString, callbackPort: port)
        }
    }
}

extension Daemon {
    /// `POST /debug/sign-in-sim {profile, state?}` (the control socket's
    /// owner only): macOS's `sign-in-sim` / `sign-in-sim-state` e2e hooks. A
    /// capture armed as a real sign-in arms one, on SignInSimulator's host,
    /// whose provider reply is canned; a guest POST to it drives the proxy's
    /// capture, the hook's hop and its release, with no browser and no
    /// credential store touched.
    // @port-skip linux-only: the debug UI command's sign-in-sim actions, as a control route
    func signInSimulator(_ body: JSONValue) async -> ControlResponse {
        guard let pid = body["profile"]?.stringValue.flatMap(UUID.init(uuidString:)) else {
            return .error(400, "profile (a workspace id) required")
        }
        let wantState = body["state"] == .bool(true)
        let r: [String: Any] = await MainActor.run {
            guard let host = LinuxSessionHost.shared else { return ["error": "no session host"] }
            if wantState {
                let s = host.proxySignIns[pid]
                return ["ok": true, "inFlight": s.map { !$0.finished } ?? false, "completed": SignInSimulator.completed]
            }
            guard let token = host.beginSimulatedSignIn(profileID: pid) else {
                return ["error": "a sign-in is already in flight there (or the proxy is down)"]
            }
            return ["ok": true, "token": token.uuidString, "host": SignInSimulator.host, "path": SignInSimulator.path]
        }
        return ControlResponse(r["error"] == nil ? 200 : 400, JSONValue(foundation: r) ?? .object([:]))
    }
}
