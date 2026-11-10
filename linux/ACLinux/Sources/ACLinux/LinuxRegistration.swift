import Foundation

/// "Register with Claude / ChatGPT / Grok / Kimi" on a Linux server
/// (macOS: ClaudeRegistrationCoordinator.swift): a throwaway VM with no
/// workspace, no token plan and no swap map runs the provider's own login;
/// the page goes to the fat client that asked (RemoteRegistrationBroker in
/// /state), which tunnels the callback into the guest's loopback; the tokens
/// come back over the in-VM token agents (vsock 8446 / 8447) or, for Grok
/// and Kimi, from the guest's credential files; the VM is then destroyed.
// @port-skip linux-only: ClaudeRegistrationState's Linux twin (a VM id and token channels, no window or VZ sandbox)
@MainActor
final class LinuxRegistrationState {
    let provider: SubscriptionProvider
    let scope: SubscriptionRegistrationScope
    let scratchProfile: Profile
    var claudeBridge: TokenAgentChannel?
    var codexBridge: TokenAgentChannel?
    var listeners: [TokenAgentListener] = []
    var pollTask: Task<Void, Never>?
    var launchTask: Task<Void, Never>?
    var finished = false
    /// The credential is saved: an end during the linger before teardown
    /// (the VM stopping) is still a success.
    var captured = false
    var agentLaunchStarted = false
    /// The login CLI was seen running (or its sign-in URL reached the host).
    var agentLaunchConfirmed = false
    var onEvent: ((HostSignInEvent) -> Void)?

    // partial: no scratchDir (guest files read via guestExec)
    // @port ClaudeRegistrationState.init(provider: SubscriptionProvider, scope: SubscriptionRegistrationScope, scratchProfile: Profile, scratchDir: URL) h=c7a226b48b1ca931 @6c6cd9cf
    init(provider: SubscriptionProvider, scope: SubscriptionRegistrationScope, scratchProfile: Profile) {
        self.provider = provider
        self.scope = scope
        self.scratchProfile = scratchProfile
    }
}

/// The token agents' end on the host: Firecracker's hybrid vsock delivers
/// the guest's dial of host port `port` on `<v.sock>_<port>`; each
/// connection becomes the channel's (the agent redials every 2 s).
// @port-skip linux-only: SubscriptionTokenBridge / CodexTokenBridge's VZ listener, over hybrid vsock
@MainActor
final class TokenAgentListener {
    let path: String
    private let listenFD: Int32
    private var acceptSource: DispatchSourceRead?
    private let channel: TokenAgentChannel

    // partial: TokenAgentListener over Firecracker hybrid vsock (port 8447) + shared TokenAgentChannel
    // @port CodexTokenBridge.init(socketDevice: VZVirtioSocketDevice) h=f31ef90768c197de @6c6cd9cf
    // partial: hybrid-vsock listener instead of a VZ listener delegate
    // @port ListenerDelegate.init(onConnection: @escaping(VZVirtioSocketConnection)->Void)@AgentCoding/CodexTokenBridge.swift h=10107f1f71ecd03d @6c6cd9cf
    // partial: hybrid-vsock listener
    // @port ListenerDelegate.init(onConnection: @escaping(VZVirtioSocketConnection)->Void)@AgentCoding/SubscriptionTokenBridge.swift h=10107f1f71ecd03d @6c6cd9cf
    // @port SubscriptionTokenBridge.init(socketDevice: VZVirtioSocketDevice) h=f31ef90768c197de @6c6cd9cf
    init(udsPath: String, port: UInt32, channel: TokenAgentChannel) throws {
        path = HybridVsockListener.path(uds: udsPath, port: port)
        self.channel = channel
        listenFD = try HybridVsockListener.bindListening(path)
        _ = fcntl(listenFD, F_SETFL, fcntl(listenFD, F_GETFL) | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.acceptAll() } }
        acceptSource = src
        src.activate()
    }

    // partial: hybrid-vsock accept loop of TokenAgentListener
    // @port ListenerDelegate.listener(_: VZVirtioSocketListener, shouldAcceptNewConnection: VZVirtioSocketConnection, from: VZVirtioSocketDevice)@AgentCoding/CodexTokenBridge.swift h=3a2bb595c0f2b1d0 @6c6cd9cf
    // partial: channel.accept(fd:owner: nil) per hybrid-vsock connection
    // @port CodexTokenBridge.accept(_: VZVirtioSocketConnection) h=3ed0742573962a5f @6c6cd9cf
    // partial: TokenAgentListener hands accepted fds to TokenAgentChannel.accept
    // @port SubscriptionTokenBridge.accept(_: VZVirtioSocketConnection) h=3ed0742573962a5f @6c6cd9cf
    // @port ListenerDelegate.listener(_: VZVirtioSocketListener, shouldAcceptNewConnection: VZVirtioSocketConnection, from: VZVirtioSocketDevice)@AgentCoding/SubscriptionTokenBridge.swift h=3a2bb595c0f2b1d0 @6c6cd9cf
    private func acceptAll() {
        while true {
            let fd = accept(listenFD, nil, nil)
            if fd < 0 {
                if errno == EINTR { continue }
                return
            }
            // Blocking, as a VZ connection's: the channel reads only when
            // the source says there is something, and a read of 0 is the end.
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            channel.accept(fd: fd, owner: nil)
        }
    }

    // partial: TokenAgentListener.stop (plus state.codexBridge?.stop() at teardown)
    // @port CodexTokenBridge.stop() h=3371982ca0beddf2 @6c6cd9cf
    // partial: listener half; channel.stop by the registration teardown
    // @port SubscriptionTokenBridge.stop() h=3371982ca0beddf2 @6c6cd9cf
    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        Glibc.close(listenFD)
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// The token agents' replies (claude-token-agent / codex-token-agent `read`).
// @port-skip linux-only: SubscriptionTokenBridge.read / CodexTokenBridge.read over TokenAgentChannel (their VZ classes don't build here)
enum TokenAgentRead {
    struct Failed: Error, CustomStringConvertible {
        let reason: String
        // partial: only the agentRejected case; notConnected is TokenAgentDisconnected.description
        // @port SubscriptionTokenBridge.BridgeError.var errorDescription h=5bc91e8a7b22b9dd @6c6cd9cf
        var description: String { "VM agent refused the request: \(reason)" }
    }

    // @port SubscriptionTokenBridge.read() h=80c287a2a89df639 @6c6cd9cf
    // partial: Linux calls the shared TokenAgentChannel.rpc directly
    // @port SubscriptionTokenBridge.rpc(_: [String:Any]) h=6606a804dd953966 @6c6cd9cf
    static func claude(_ c: TokenAgentChannel) async throws -> (access: String, refresh: String)? {
        let r = try await c.rpc(["op": "read"])
        guard r["ok"] as? Bool == true else { throw Failed(reason: r["reason"] as? String ?? "unknown reason") }
        guard let a = r["access"] as? String, let f = r["refresh"] as? String else { return nil }
        return (a, f)
    }

    // @port CodexTokenBridge.read() h=5f01e6e4cbbdda44 @6c6cd9cf
    static func codex(_ c: TokenAgentChannel) async throws -> (access: String, refresh: String, idToken: String)? {
        let r = try await c.rpc(["op": "read"])
        guard r["ok"] as? Bool == true else { throw Failed(reason: r["reason"] as? String ?? "unknown reason") }
        guard let a = r["access"] as? String, let f = r["refresh"] as? String,
              let i = r["id_token"] as? String else { return nil }
        return (a, f, i)
    }
}

struct TokenAgentDisconnected: Error, CustomStringConvertible {
    // @port-skip linux-only: the bridges' notConnected message
    var description: String { "the token agent isn't connected yet" }
}

extension LinuxSessionHost {
    /// A fat client's Preferences → "Register with …" (`POST
    /// /subscriptions/register`) and a session card's sign-in both come here.
    /// A Linux server has no screen: every run is remote-initiated, quiet.
    // partial: remote-initiated only (no explainer alert, no window: a Linux server has no screen)
    // @port ACAppDelegate.beginSubscriptionRegistration(provider: SubscriptionProvider, scope: SubscriptionRegistrationScope, remoteInitiated: Bool, quiet: Bool, events: ((HostSignInEvent)->Void)?) h=eeda3dadb43b11c1 @6c6cd9cf
    func beginSubscriptionRegistration(provider: SubscriptionProvider, scope: SubscriptionRegistrationScope,
                                       events: ((HostSignInEvent) -> Void)? = nil) {
        if registration != nil || RemoteRegistrationBroker.shared.pending != nil {
            events?(.finished(success: false, message: NSLocalizedString(
                "Another sign-in is already in progress.", comment: "sign-in")))
            return
        }
        guard daemon?.mitm != nil else {
            events?(.finished(success: false, message: NSLocalizedString(
                "The Bromure proxy isn't running, so the sign-in can't be captured.", comment: "sign-in")))
            return
        }
        startSubscriptionRegistration(provider: provider, scope: scope, events: events)
    }

    /// The flow proper.
    // partial: the scratch home is the ext4 image (Grok's and Kimi's files are read from the guest, not a host-mounted home); no ShellBridge or window
    // @port ACAppDelegate.startSubscriptionRegistration(provider: SubscriptionProvider, scope: SubscriptionRegistrationScope, engine: MitmEngine, remoteInitiated: Bool, quiet: Bool, events: ((HostSignInEvent)->Void)?) h=874667841a99b342 @6c6cd9cf
    private func startSubscriptionRegistration(provider: SubscriptionProvider, scope: SubscriptionRegistrationScope,
                                               events: ((HostSignInEvent) -> Void)?) {
        RemoteRegistrationBroker.shared.begin(provider: provider.displayName)
        // Scratch profile: the right tool + subscription, no folders / SSH /
        // creds / MCP / env, fresh random id. Never saved: the daemon holds
        // it while its VM lives.
        let scratch = Profile(name: provider.scratchName, tool: provider.scratchTool, authMode: .subscription)
        let state = LinuxRegistrationState(provider: provider, scope: scope, scratchProfile: scratch)
        state.onEvent = events
        registration = state
        events?(.status(NSLocalizedString("Setting up a private sign-in machine…", comment: "sign-in")))

        Task { @MainActor in
            let uds: String
            do {
                guard let daemon = self.daemon else { throw Daemon.GuestCommandError.unavailable("the daemon is stopping") }
                // No token plan and no swap map: the real OAuth handshake
                // reaches upstream untouched. The proxy still serves egress.
                uds = try await daemon.startRegistrationVM(scratch)
            } catch {
                FileHandle.standardError.write(Data("[registration] couldn't start the sign-in machine: \(error)\n".utf8))
                let message = NSLocalizedString("Couldn't start the sign-in machine.", comment: "sign-in")
                state.onEvent?(.finished(success: false, message: message))
                state.onEvent = nil
                self.teardownSubscriptionRegistration(reason: .failure, message: message)
                return
            }
            guard self.registration === state, !state.finished else { return }
            do {
                switch provider {
                case .claude:
                    let c = TokenAgentChannel(disconnectedError: TokenAgentDisconnected())
                    state.listeners.append(try TokenAgentListener(udsPath: uds, port: 8446, channel: c))
                    state.claudeBridge = c
                case .codex:
                    let c = TokenAgentChannel(disconnectedError: TokenAgentDisconnected())
                    state.listeners.append(try TokenAgentListener(udsPath: uds, port: 8447, channel: c))
                    state.codexBridge = c
                case .grok, .kimi: break  // no vsock agent — captured from the guest's credential files
                }
            } catch {
                FileHandle.standardError.write(Data("[registration] no token listener: \(error)\n".utf8))
                self.teardownSubscriptionRegistration(reason: .failure, message: NSLocalizedString(
                    "Couldn't start the sign-in machine.", comment: "sign-in"))
                return
            }
            self.awaitRegistrationSession(state)
            self.pollForSubscriptionRegistration(state: state)
        }
    }

    /// macOS starts the launch watchdog at the scratch VM's first tab
    /// roster; here, once its tmux session answers.
    // @port-skip linux-only: sandbox.onTabList's first roster, from the guest's tmux session
    private func awaitRegistrationSession(_ state: LinuxRegistrationState) {
        let pid = state.scratchProfile.id
        state.launchTask = Task { @MainActor [weak self] in
            for _ in 0..<240 {
                guard let self, self.registration === state, !state.finished else { return }
                let up = try? await self.guestExec(profileID: pid, command:
                    "tmux has-session -t bromure 2>/dev/null && echo up || true", timeout: 10)
                if up?.contains("up") == true {
                    self.launchRegistrationAgentIfNeeded()
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// The login CLI's sign-in URL, from the guest's URL relay
    /// (guestOpenedURL): published for the client with the VM's address and
    /// the loopback port its callback comes back to.
    // partial: remote only (the broker always holds a run here); vmIP published with the URL (no onIPUpdate on Linux)
    // @port ACAppDelegate.wireRegistrationSandbox(_: UbuntuSandboxVM, window: TabbedSessionWindow) h=02792a625dab0d2c @6c6cd9cf
    func registrationOpenedURL(_ url: URL, state: LinuxRegistrationState) {
        // The CLI got as far as its sign-in URL: it is running.
        state.agentLaunchConfirmed = true
        guard GuestURLGate.opensInRealBrowser(url) else {
            FileHandle.standardError.write(Data(
                "[ac] refused guest sign-in URL with local/private host: \(url.host ?? "?")\n".utf8))
            failSubscriptionRegistration(NSLocalizedString(
                "The sign-in page the agent opened points at this Mac or its local network, so Bromure didn't open it.",
                comment: "sign-in refused: the guest's sign-in URL has a local or private host"))
            return
        }
        let broker = RemoteRegistrationBroker.shared
        let port = GuestURLGate.loopbackCallbackPort(from: url).map(Int.init) ?? 0
        state.onEvent?(.status(NSLocalizedString("Finish signing in in your browser…", comment: "sign-in")))
        // The address first: a client that sees the page also sees where
        // its callback goes.
        let pid = state.scratchProfile.id
        Task { @MainActor [weak self] in
            if let ip = await self?.daemon?.guestIP(pid) { broker.publish(vmIP: ip) }
            broker.publish(url: url.absoluteString, callbackPort: port)
        }
    }

    /// The scratch VM stopped on its own.
    // @port ACAppDelegate.wireRegistrationSandbox(_: UbuntuSandboxVM, window: TabbedSessionWindow) h=02792a625dab0d2c @6c6cd9cf
    func registrationVMStopped(_ id: UUID) {
        guard let state = registration, state.scratchProfile.id == id else { return }
        teardownSubscriptionRegistration(reason: .windowClosed, message: NSLocalizedString(
            "The sign-in machine stopped.", comment: "sign-in: the throwaway VM stopped on its own"))
    }

    /// End a sign-in that can't go on, saying why.
    // partial: no local notice (a Linux server has no screen); the client hears it through /state's registrationEnded
    // @port ACAppDelegate.failClaudeRegistration(_: String) h=9a9e69d65aa0c5b4 @6c6cd9cf
    func failSubscriptionRegistration(_ message: String) {
        if let ev = registration?.onEvent {
            ev(.finished(success: false, message: message))
            registration?.onEvent = nil
        }
        teardownSubscriptionRegistration(reason: .failure, message: message)
    }

    /// Make sure the login CLI actually runs in the scratch VM's tmux window
    /// (RegistrationLaunch.Tracker): it types the login command once the
    /// pane has been an idle shell for two probes, re-sends a bounded number
    /// of times, and stands down once the login runs or its URL arrives.
    // @port ACAppDelegate.launchRegistrationAgentIfNeeded() h=7a52bb4c49346ab2 @6c6cd9cf
    // partial: failure handled inline (onEvent + teardown); no local Retry/Cancel alert (screen-only)
    // @port ACAppDelegate.registrationLaunchFailed(state: ClaudeRegistrationState, failure: RegistrationLaunch.Failure) h=b63e52eaf9e2fb5e @6c6cd9cf
    private func launchRegistrationAgentIfNeeded() {
        guard let state = registration, !state.finished, !state.agentLaunchStarted else { return }
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
                guard let self, let live = self.registration, live === state, !live.finished else { return }
                if live.agentLaunchConfirmed { return }
                let out = try? await self.guestExec(profileID: pid, command: probe, timeout: 10)
                guard !Task.isCancelled, !live.finished else { return }
                if live.agentLaunchConfirmed { return }
                switch tracker.next(RegistrationLaunch.Probe(output: out)) {
                case .confirmed:
                    live.agentLaunchConfirmed = true
                    FileHandle.standardError.write(Data("[registration] \(provider.rawValue) login running\n".utf8))
                    return
                case .send:
                    FileHandle.standardError.write(Data(
                        "[registration] typing \(provider.rawValue) login (attempt \(tracker.sends))\n".utf8))
                    _ = try? await self.guestExec(profileID: pid, command: launch, timeout: 10)
                case .wait:
                    break
                case .fail(let failure):
                    let message = RegistrationLaunch.failureMessage(failure, provider: provider)
                    FileHandle.standardError.write(Data("[registration] launch failed: \(failure)\n".utf8))
                    live.onEvent?(.finished(success: false, message: message))
                    live.onEvent = nil
                    self.teardownSubscriptionRegistration(reason: .failure, message: message)
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// Wait for the in-VM token agent, then poll the credentials until the
    /// user's login lands real tokens (or we time out).
    // partial: Grok's and Kimi's files are read from the guest (cat), not a host-mounted home
    // @port ACAppDelegate.pollForSubscriptionRegistration(state: ClaudeRegistrationState) h=f0b3d33ce9d0d8b6 @6c6cd9cf
    private func pollForSubscriptionRegistration(state: LinuxRegistrationState) {
        let pid = state.scratchProfile.id
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
                if let claude = state.claudeBridge, let t = try? await TokenAgentRead.claude(claude) {
                    await self.finishSubscriptionRegistration(state: state,
                        record: .claude(access: t.access, refresh: t.refresh))
                    return
                }
                if let codex = state.codexBridge, let t = try? await TokenAgentRead.codex(codex) {
                    await self.finishSubscriptionRegistration(state: state,
                        record: .codex(access: t.access, refresh: t.refresh, idToken: t.idToken))
                    return
                }
                if state.provider == .grok, let g = await self.readGuestGrokAuth(pid) {
                    await self.finishSubscriptionRegistration(state: state,
                        record: .grok(access: g.access, refresh: g.refresh, scopeKey: g.scopeKey, template: g.template))
                    return
                }
                if state.provider == .kimi, let k = await self.readGuestKimiCredentials(pid) {
                    await self.finishSubscriptionRegistration(state: state,
                        record: .kimi(access: k.access, refresh: k.refresh, name: k.name,
                                      template: k.template, configTOML: k.configTOML))
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if Task.isCancelled { return }
            let late = String(format: NSLocalizedString(
                "Bromure didn't receive a %@ sign-in in time. You can try again.",
                comment: ""), state.provider.displayName)
            state.onEvent?(.finished(success: false, message: late))
            state.onEvent = nil
            self.teardownSubscriptionRegistration(reason: .timeout, message: late)
        }
    }

    /// `~/.grok/auth.json` in the scratch guest, nil until the user signed in.
    // partial: reads the scratch guest's ~/.grok/auth.json via guestExec, not a host-mounted home
    // @port ACAppDelegate.static readGrokAuthFile(at: URL) h=60338a0b46e177c8 @6c6cd9cf
    private func readGuestGrokAuth(_ pid: UUID) async
        -> (access: String, refresh: String, expiresAt: Date, scopeKey: String, template: Data)? {
        guard let out = try? await guestExec(profileID: pid, command:
                "base64 -w0 /home/ubuntu/.grok/auth.json 2>/dev/null || true", timeout: 10),
              let data = Data(base64Encoded: out.trimmingCharacters(in: .whitespacesAndNewlines)),
              !data.isEmpty else { return nil }
        return RegistrationCapture.parseGrokAuth(data)
    }

    /// `~/.kimi-code/credentials/*.json` and `config.toml` in the scratch
    /// guest, nil until the user signed in.
    // partial: reads the scratch guest's ~/.kimi-code via guestExec
    // @port ACAppDelegate.static readKimiCredentials(in: URL) h=6c5396bbf4a6d8b6 @6c6cd9cf
    private func readGuestKimiCredentials(_ pid: UUID) async
        -> (access: String, refresh: String, name: String, template: Data, configTOML: String?)? {
        // One line per file: `<name>\t<base64>`; `config.toml` as `\t<base64>`.
        let script = "k=/home/ubuntu/.kimi-code; "
            + "for f in \"$k\"/credentials/*.json; do [ -f \"$f\" ] || continue; "
            + "n=$(basename \"$f\" .json); printf '%s\\t%s\\n' \"$n\" \"$(base64 -w0 \"$f\")\"; done; "
            + "[ -f \"$k/config.toml\" ] && printf '\\t%s\\n' \"$(base64 -w0 \"$k/config.toml\")\"; true"
        guard let out = try? await guestExec(profileID: pid, command: script, timeout: 10) else { return nil }
        var files: [(name: String, data: Data)] = []
        var toml: String?
        for line in out.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, let data = Data(base64Encoded: String(parts[1])) else { continue }
            if parts[0].isEmpty { toml = String(decoding: data, as: UTF8.self) }
            else { files.append((String(parts[0]), data)) }
        }
        guard !files.isEmpty else { return nil }
        return RegistrationCapture.parseKimiCredentials(files: files, configTOML: toml)
    }

    /// Persist the captured tokens per the scope, then tear down. "Every
    /// workspace" also drops that provider's per-workspace logins, so the new
    /// sign-in really is what every workspace reads.
    // partial: remote only (the scope question goes to the client; no completion alert)
    // @port ACAppDelegate.finishClaudeRegistration(state: ClaudeRegistrationState, record: CapturedSubscription) h=df0da3ab0e19ea68 @6c6cd9cf
    // partial: RegistrationCapture.forgetOverrides called inline when shared everywhere
    // @port ACAppDelegate.forgetProviderOverrides(_: SubscriptionProvider) h=4e8088469046431d @6c6cd9cf
    private func finishSubscriptionRegistration(state: LinuxRegistrationState,
                                                record captured: CapturedSubscription) async {
        guard !state.finished, let backend = proxySignInBackend else {
            teardownSubscriptionRegistration(reason: .failure, message: NSLocalizedString(
                "The Bromure proxy isn't running, so the sign-in can't be captured.", comment: "sign-in"))
            return
        }
        var sharedEverywhere = true
        var overrideProfile: UUID? = nil
        if case .askPerSession(let pid) = state.scope {
            let title = NSLocalizedString("Share with every workspace?", comment: "")
            let body = String(format: NSLocalizedString(
                "Use this %@ sign-in for every Bromure workspace (replacing any workspace's own %@ sign-in), or only for this one?",
                comment: ""), state.provider.displayName, state.provider.displayName)
            let buttons = [NSLocalizedString("Every workspace", comment: ""),
                           NSLocalizedString("Just this workspace", comment: "")]
            // The client that registered gets the question. Nobody answering
            // keeps the conservative choice — just this workspace.
            let choice = await PendingPromptBroker.shared.askAsync(
                profileID: pid, title: title, message: body, buttons: buttons, fallback: 1)
            guard !state.finished else { return }
            sharedEverywhere = (choice == 0)
            if !sharedEverywhere { overrideProfile = pid }
        }

        do {
            try RegistrationCapture.save(captured, overrideProfile: overrideProfile, into: backend)
            if sharedEverywhere {
                RegistrationCapture.forgetOverrides(state.provider, for: ProfileStore().loadAll().map(\.id), in: backend)
            }
        } catch {
            FileHandle.standardError.write(Data("[registration] couldn't save captured credentials: \(error)\n".utf8))
        }

        NotificationCenter.default.post(name: .bromureSubscriptionStoresChanged, object: nil)
        state.captured = true
        // The sign-in card: done — it restarts the agent on the stand-in key.
        state.onEvent?(.finished(success: true, message: nil))
        state.onEvent = nil

        // Don't stop the VM out from under the OAuth callback: the CLI's
        // 127.0.0.1 server may still be answering the client's browser
        // through the loopback relay. A short drain, a linger for the TCP
        // close, then tear down.
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, await self.daemon?.hasActiveLoopbackRelays(state.scratchProfile.id) == true {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.teardownSubscriptionRegistration(reason: .success)
        }
    }

    /// Idempotent teardown: stop polling and the token channels, finish the
    /// client's relay, destroy the VM.
    // partial: no window or native terminal surfaces to retire; the VM and its files go through the daemon
    // @port ACAppDelegate.teardownClaudeRegistration(reason: ClaudeRegistrationTeardownReason, message: String?) h=d79b3f33670464e0 @6c6cd9cf
    func teardownSubscriptionRegistration(reason: ClaudeRegistrationTeardownReason, message: String? = nil) {
        guard let state = registration, !state.finished else { return }
        state.finished = true
        // Once the credential is saved, whatever ends the run is a success.
        let ended = state.captured ? .success : reason
        let message = ended == .success ? nil : (message ?? ended.endedMessage)
        if ended != .success, let ev = state.onEvent {
            ev(.finished(success: false, message: message))
            state.onEvent = nil
        }
        RemoteRegistrationBroker.shared.finish(success: ended == .success, message: message)

        state.pollTask?.cancel()
        state.launchTask?.cancel()
        state.claudeBridge?.stop()
        state.codexBridge?.stop()
        for l in state.listeners { l.stop() }
        state.listeners.removeAll()
        let id = state.scratchProfile.id
        Task { await self.daemon?.destroyRegistrationVM(id) }
        registration = nil
    }
}
