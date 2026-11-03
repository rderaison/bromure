import Foundation

/// The daemon as the proxy sign-in's host (macOS: SessionSignIn+App.swift),
/// and a fat client's sign-in card on a Linux server: the session's own
/// machine runs its CLI's login in its tab (SessionSignIn), the provider's
/// page is published for the client (RemoteRegistrationBroker in /state),
/// the client opens it and tunnels the callback into the guest's loopback
/// (`forward <vmIP> <port>`, the vsock 5010 relay), and the proxy's capture
/// keeps the credential. guestExec and proxySignIns are the session host's.
extension LinuxSessionHost: ProxySignInHost {
    /// The proxy's side; nil while the daemon has no proxy.
    // @port-skip linux-only: ACAppDelegate.proxySignInBackend over the daemon's MitmProxy
    var proxySignInBackend: ProxySignInBackend? {
        guard let mitm = daemon?.mitm else { return nil }
        return ProxySignInBackend(captures: mitm.captures, claude: mitm.claudeStore, codex: mitm.codexStore,
                                  grok: mitm.grokStore, kimi: mitm.kimiStore)
    }

    /// `POST /agent-sessions/<id>/signin`: the session's agent signs in in
    /// its own tab, published for the client through the broker. The reply
    /// names the run (`registration`); its end reaches the client through
    /// /state's `registrationEnded`.
    // @port-skip linux-only: the card's sign-in on a Linux server (macOS runs a throwaway registration VM: ACAppDelegate.beginSubscriptionRegistration)
    func remoteSignIn(_ sid: UUID) -> [String: Any] {
        let store = agentSessionStore
        guard let s = store.session(sid) else { return ["error": "unknown session"] }
        guard let provider = SubscriptionProvider(rawValue: s.tool.rawValue) else {
            return ["error": "no account sign-in for \(s.tool.rawValue)"]
        }
        guard let w = s.windowIndex, !s.hasEnded else { return ["error": "That session has no live tab to sign in from."] }
        let broker = RemoteRegistrationBroker.shared
        guard broker.pending == nil else {
            return ["error": NSLocalizedString("Another sign-in is already in progress.", comment: "sign-in")]
        }
        broker.begin(provider: provider.rawValue)
        let pid = s.profileID
        beginProxySignIn(provider: provider, profileID: pid, windowIndex: w) { [weak self] event in
            guard case .finished(let ok, let message) = event else { return }
            broker.finish(success: ok, message: message)
            guard ok, let self else { return }
            self.applyRegisteredSubscription(provider: provider, profileID: pid)
            SessionStores.shared?.engine?.relaunchAfterSignIn(sid)
        }
        guard let run = broker.pending?.id else {
            return ["error": broker.ended?.message ?? "the sign-in couldn't start"]
        }
        return ["ok": true, "registration": run.uuidString]
    }

    /// The workspace runs the agent on its subscription now (macOS: the
    /// same profile edit, then a live credential push the relaunch does here).
    // partial: the relaunch pushes the stand-in (no pushLiveCredentials / live profile edit on Linux)
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
        }
    }

    /// The guests' URL relay (`url-*.txt` in the outbox, from bromure-open):
    /// at most 8 a tick, 8 KiB each, http(s) only, consumed as read (macOS:
    /// UbuntuSandboxVM's outbox poll).
    // @port-skip linux-only: the url-*.txt half of UbuntuSandboxVM.startOutboxPolling, on the host
    func readGuestURLs() {
        let fm = FileManager.default
        for id in Self.running.withLockedValue({ $0 }) {
            let outbox = stateDir + "/vms/" + id.uuidString.lowercased() + "/outbox/"
            let names = ((try? fm.contentsOfDirectory(atPath: outbox)) ?? [])
                .filter { $0.hasPrefix("url-") && $0.hasSuffix(".txt") }.sorted()
            for name in names.prefix(8) {
                let raw = GuestOutbox.read(outbox + name, limit: 8 << 10)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                try? fm.removeItem(atPath: outbox + name)
                guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
                      ["http", "https"].contains(scheme) else { continue }
                guestOpenedURL(url, profileID: id)
            }
        }
    }

    /// A page the guest opened. A server has no browser: the one it acts on
    /// is a sign-in's, published for the client that asked for it, with the
    /// guest port its callback comes back to.
    // @port ACAppDelegate.wireSandboxCallbacks(_: UbuntuSandboxVM) / sandbox.onURLOpen h=d249db054a08a5ca @5ba53c17
    func guestOpenedURL(_ url: URL, profileID pid: UUID) {
        guard let signIn = proxySignIns[pid], !signIn.finished else {
            // Any other page: offered to the fat client (GuestPageBroker).
            let name = ProfileStore().loadAll().first { $0.id == pid }?.name ?? ""
            GuestPageBroker.shared.publish(url, profileID: pid, workspace: name)
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
