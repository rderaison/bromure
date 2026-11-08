import Foundation
import NIOCore
import NIOPosix
import SandboxEngine

/// The Linux proxy's egress and guardrails state: each workspace's
/// GuardrailsConfig (its egress policy among it), and the connections the
/// firewall may cut. The decisions themselves are ProxyPolicy's, shared
/// with macOS.
extension MitmProxy {
    // @port MitmEngine.setGuardrailsConfig(_: GuardrailsConfig, for: UUID) h=c9069918294de82f @8e2543eb
    func setGuardrailsConfig(_ config: GuardrailsConfig, for profileID: UUID) {
        // Strict credential mode follows the workspace's setting, live.
        UnmanagedCredentialGuard.shared.setEnabled(config.strictCredentials, for: profileID)
        let prior = guardrailsConfigs.withLockedValue { all -> EgressPolicy? in
            defer { all[profileID] = config }
            return all[profileID]?.egressPolicy
        }
        // The firewall is live: a connection the new rules deny is cut now,
        // and the switch re-decides its flows per frame.
        if prior != config.egressPolicy { EgressReportDeduper.shared.reset(profileID: profileID) }
        EgressConnectionRegistry.shared.applyPolicy(profileID: profileID, policy: config.egressPolicy)
    }

    // @port MitmEngine.guardrailsConfig(for: UUID) h=1ea16626b627a2bf @8e2543eb
    func guardrailsConfig(for profileID: UUID) -> GuardrailsConfig? {
        guardrailsConfigs.withLockedValue { $0[profileID] }
    }

    // @port MitmEngine.clearGuardrailsConfig(for: UUID) h=0e852c5a469fc917 @8e2543eb
    func clearGuardrailsConfig(for profileID: UUID) {
        // The next session starts here: a late reply from this one teaches
        // the guard nothing (learnIssued checks under the same lock).
        strictSessions.withLockedValue { all in
            all[profileID, default: 0] &+= 1
            UnmanagedCredentialGuard.shared.setEnabled(false, for: profileID)
            UnmanagedCredentialGuard.shared.reset(profileID: profileID)
        }
        _ = guardrailsConfigs.withLockedValue { $0.removeValue(forKey: profileID) }
        EgressConnectionRegistry.shared.forget(profileID: profileID)
    }

    /// Workspace `profileID`'s current session (a stop starts the next):
    /// strict mode's learning and the compromise handler key on it.
    // @port-skip linux-only: the session tag macOS's per-VM proxy doesn't need
    func strictSession(of profileID: UUID) -> UInt64 {
        strictSessions.withLockedValue { $0[profileID] ?? 0 }
    }

    /// The tokens a reply issued the guest, learned for strict credential
    /// mode (macOS: relayUpstream's learn), if its session is still the
    /// workspace's: a stop in between already forgot what that VM learned.
    // @port-skip linux-only: relayUpstream's learn, tagged with its session
    func learnIssued(_ response: Data, host: String, profileID: UUID, session: UInt64) {
        strictSessions.withLockedValue { all in
            guard (all[profileID] ?? 0) == session else { return }
            UnmanagedCredentialGuard.shared.learn(response: response, host: host, profileID: profileID)
        }
    }

    /// A workspace's live policies, from its profile, as macOS pushes them at
    /// launch and on a save (ACAppDelegate's setGuardrailsConfig and
    /// setPromptInjectionPolicy calls): its guardrails and egress policy,
    /// its prompt-injection policy, and the name the guardrails prompt shows.
    // @port-skip linux-only: the daemon's share of launch / applyLiveFirewall's proxy wiring
    func applyWorkspacePolicies(_ profile: Profile) {
        setPromptInjectionPolicy(profile.promptInjection, for: profile.id)
        setGuardrailsConfig(GuardrailsConfig.make(for: profile), for: profile.id)
        let (broker, name, pid) = (guardrailsBroker, profile.name, profile.id)
        Task.detached { await broker.setProfileName(name, for: pid) }
    }

    /// A stopped workspace's policies, gone (macOS: cleanupSessionRegistrations).
    // @port-skip linux-only: the daemon's share of cleanupSessionRegistrations
    func clearWorkspacePolicies(_ profileID: UUID) {
        clearPromptInjectionPolicy(for: profileID)
        clearGuardrailsConfig(for: profileID)
    }

    /// Register `channel` (a proxied connection to `host:port`) with the
    /// firewall's open-connection registry, so a rule change that denies it
    /// closes it mid-transfer; unregistered when it closes. False: a policy
    /// swap that landed before the registration denies it already (the
    /// caller closes it). macOS: HTTPMitmConnection.trackedForFirewall.
    // @port-skip linux-only: trackedForFirewall on a NIO channel (macOS wraps the connection's life in a closure)
    func trackForFirewall(_ channel: Channel, profileID: UUID, host: String, port: Int, route: String) -> Bool {
        let policy = guardrailsConfig(for: profileID)?.egressPolicy
        let token = EgressConnectionRegistry.shared.register(
            profileID: profileID, host: host, port: port, route: route,
            rule: ProxyPolicy.trackedRule(policy: policy, host: host, port: port)) { [weak channel] in
                channel?.close(promise: nil)
            }
        channel.closeFuture.whenComplete { _ in EgressConnectionRegistry.shared.unregister(token) }
        return !ProxyPolicy.deniedOnceTracked(policy: guardrailsConfig(for: profileID)?.egressPolicy,
                                              host: host, port: port, identity: nil)
    }

    /// An OpenShell `tls: skip` endpoint, or a transparent flow left alone:
    /// the guest's bytes relayed raw to the checked addresses, never
    /// terminated (macOS: MitmPassthrough.splice). `pending`: what the guest
    /// sent before the splice; `glue`: the guest side's relay, already in
    /// its pipeline (a transparent flow's, installed as its channel was
    /// made); otherwise one is added now. Either way it holds every byte the
    /// guest sends until the upstream connects, then forwards them in order.
    /// Called on the guest channel's event loop.
    // @port-skip linux-only: MitmPassthrough.splice on NIO
    func splice(_ guest: Channel, to addresses: [OpenShellPolicy.IPAddress], port: Int, pending: ByteBuffer,
                glue: ByteGlue? = nil) {
        // An e2e run reaches the local stand-ins only: with no test upstream
        // nothing, with one only the test host.
        if refusesRealUpstreams, routeAllTo.map({ r in addresses.allSatisfy { "\($0)" == r.host } }) != true {
            FileHandle.standardError.write(Data("[mitm] ✗ e2e mode: no splice to \(addresses.first.map { "\($0)" } ?? "?"):\(port)\n".utf8))
            guest.close(promise: nil)
            return
        }
        let targets = addresses.compactMap { try? SocketAddress(ipAddress: "\($0)", port: port) }
        guard let first = targets.first else { guest.close(promise: nil); return }
        let guestGlue: ByteGlue
        if let glue {
            guestGlue = glue
        } else {
            guestGlue = ByteGlue(peer: nil)
            do { try guest.pipeline.syncOperations.addHandler(guestGlue) } catch { guest.close(promise: nil); return }
        }
        ClientBootstrap(group: guest.eventLoop)
            .connectTimeout(.seconds(10))
            .channelInitializer { up in up.pipeline.addHandler(ByteGlue(peer: guest)) }
            .connect(to: first)
            .whenComplete { r in
                switch r {
                case .failure:
                    guest.close(promise: nil)
                case .success(let up):
                    guest.eventLoop.execute {
                        if pending.readableBytes > 0 { up.write(pending, promise: nil) }
                        guestGlue.attach(up)
                    }
                }
            }
    }
}

/// One direction of a raw relay: what this channel reads goes to `peer`;
/// either side closing closes the other. Until the peer is set (an upstream
/// still connecting), what it reads is held, and forwarded in order once
/// it is.
// @port-skip linux-only: NIO plumbing of the Linux proxy
final class ByteGlue: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private var peer: Channel?
    private var held: [ByteBuffer] = []
    private var heldBytes = 0
    private var gone = false
    /// Held past this before the peer connects: this side stops reading
    /// until it does.
    static let holdLimit = 256 << 10

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    init(peer: Channel?) { self.peer = peer }

    /// The other side, now connected: what was held goes first. Called on
    /// this side's event loop.
    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func attach(_ p: Channel) {
        peer = p
        for b in held { p.write(b, promise: nil) }
        held.removeAll()
        p.flush()
        if gone { p.close(promise: nil); return }
        // Reading again (the held bytes, past the peer's write watermark,
        // also resume it through channelWritabilityChanged as they drain;
        // this one doesn't depend on the watermarks).
        if heldBytes > Self.holdLimit, let own { _ = own.setOption(ChannelOptions.autoRead, value: true) }
        heldBytes = 0
    }

    /// This side's channel (set as it's added).
    private weak var own: Channel?

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func handlerAdded(context: ChannelHandlerContext) { own = context.channel }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let b = unwrapInboundIn(data)
        guard let peer else {
            held.append(b)
            heldBytes += b.readableBytes
            // Backpressure until the peer connects, not an unbounded buffer.
            if heldBytes > Self.holdLimit { _ = context.channel.setOption(ChannelOptions.autoRead, value: false) }
            return
        }
        peer.write(b, promise: nil)
        // The peer can't take more: this side stops reading until it drains
        // (the peer's glue resumes it, channelWritabilityChanged). Paused
        // before the flush: a flush that drains at once fires that resume
        // inside it, and a pause after would never be lifted.
        if !peer.isWritable {
            _ = context.channel.setOption(ChannelOptions.autoRead, value: false)
            peer.flush()
        }
    }

    /// This side drained: the side writing into it may read again.
    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable, let peer { _ = peer.setOption(ChannelOptions.autoRead, value: true) }
        context.fireChannelWritabilityChanged()
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func channelReadComplete(context: ChannelHandlerContext) { peer?.flush() }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func channelInactive(context: ChannelHandlerContext) {
        if let peer { peer.close(promise: nil) } else { gone = true }
        context.fireChannelInactive()
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

extension RequestReader {
    /// A stand-in on its way to a host it isn't bound to: the VM is
    /// exfiltrating. Refused with a plain 451 (not a byte goes upstream),
    /// recorded, and the swapper's compromise handler raised (the daemon
    /// pauses the VM and asks). macOS: HTTPProxy's detectCompromise step.
    // @port-skip linux-only: HTTPProxy's detectCompromise step on the Linux request chain
    static func compromiseAnswer(_ request: Data, proxy: MitmProxy, profileID: UUID, host: String,
                                 session: UInt64) -> Data? {
        // Raised with its request's session (the handler drops a stale one).
        let leaks = MitmProxy.$raisingSession.withValue(session) {
            proxy.swapper.detectCompromise(rawRequest: request, host: host, profileID: profileID)
        }
        guard !leaks.isEmpty else { return nil }
        let alertsOff = proxy.guardrailsConfig(for: profileID)?.exfiltrationAlertsDisabled ?? false
        for c in leaks {
            FileHandle.standardError.write(Data(
                "[mitm] COMPROMISE \(c.fakeTokenPreview) (declared \(c.declaredHost)) → \(c.observedHost)\n".utf8))
            BACEventEmitter.shared.emitDetached(profileID: profileID, eventType: "credential.exfiltration", eventData: [
                "credential": .string(c.credentialDisplayName), "fake_preview": .string(c.fakeTokenPreview),
                "declared_host": .string(c.declaredHost), "observed_host": .string(c.observedHost),
                "vm_paused": .bool(!alertsOff),
            ])
        }
        BromureBlockLog.shared.record(.credentialLeak, profileID: profileID)
        let body = "Bromure: outbound request blocked — leaked credential to non-designated host.\n"
        return Data(("HTTP/1.1 451 Unavailable For Legal Reasons\r\nContent-Type: text/plain; charset=utf-8\r\n"
                     + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body).utf8)
    }

    /// Strict credential mode: a credential Bromure didn't put in the request
    /// (found on disk, dumped from an env, guessed) never leaves the VM.
    /// Bromure's own stand-ins and subscription placeholders, the
    /// workspace's AWS key id, tokens this site issued to the guest earlier
    /// and ones approved for the session are exempt. Refused with a 451,
    /// recorded, and raised as a compromise (the daemon pauses the VM and
    /// asks; "Allow" approves exactly these credentials for the session).
    /// macOS: HTTPProxy's UnmanagedCredentialGuard step.
    // @port-skip linux-only: HTTPProxy's strict-credential step on the Linux request chain
    static func unmanagedAnswer(_ request: Data, proxy: MitmProxy, profileID: UUID, host: String,
                                session: UInt64) -> Data? {
        guard host.lowercased() != InferenceService.localMitmHost else { return nil }
        let unmanaged = UnmanagedCredentialGuard.shared.check(
            rawRequest: request, host: host, profileID: profileID,
            fakes: proxy.swapper.entries(for: profileID).map(\.fake),
            awsAccessKeyID: proxy.awsResigner.accessKeyID(for: profileID),
            isPlaceholder: { ProxyPolicy.isSubscriptionPlaceholder($0) })
        guard !unmanaged.isEmpty else { return nil }
        let alertsOff = proxy.guardrailsConfig(for: profileID)?.exfiltrationAlertsDisabled ?? false
        for u in unmanaged {
            FileHandle.standardError.write(Data("[mitm] UNMANAGED CREDENTIAL \(u.kind) \(u.preview) (\(u.location)) → \(host)\n".utf8))
            BACEventEmitter.shared.emitDetached(profileID: profileID, eventType: "credential.unmanaged", eventData: [
                "kind": .string(u.kind), "location": .string(u.location), "preview": .string(u.preview),
                "fingerprint": .string(u.fingerprint), "host": .string(host), "blocked": .bool(true),
                "vm_paused": .bool(!alertsOff),
            ])
        }
        if !alertsOff {
            var event = CompromiseEvent(
                profileID: profileID, observedHost: host,
                leaks: unmanaged.map {
                    CompromiseLeak(fakeTokenPreview: $0.preview,
                                   credentialDisplayName: "Unmanaged \($0.kind) (\($0.location))",
                                   declaredHost: "not issued by Bromure", observedHost: host)
                },
                timestamp: Date())
            event.unmanagedFingerprints = unmanaged.map(\.fingerprint)
            MitmProxy.$raisingSession.withValue(session) { proxy.swapper.raiseCompromise(event) }
        }
        let body = "Bromure: outbound request blocked — it carries a credential Bromure did not issue for \(host) (strict credential mode).\n"
        return Data(("HTTP/1.1 451 Unavailable For Legal Reasons\r\nContent-Type: text/plain; charset=utf-8\r\n"
                     + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body).utf8)
    }

    /// The workspace's policy chain for one request, before any credential is
    /// swapped in, in macOS's order (HTTPProxy's driveTLS steps): OpenShell's
    /// head checks (which may rewrite the request-target in `request`),
    /// `policy.local`, OpenShell request rules, the middleware chain (which
    /// may rewrite the body), the guardrails, then compromise detection and
    /// strict credential mode.
    /// The guest's answer, or nil to go on with `request`.
    // partial: OpenShell's strict framing limits (chunk-line, header and trailer sizes) aren't applied; the Linux framer re-frames every body with a Content-Length
    // @port-skip linux-only: driveTLS's policy steps (ProxyPolicy, shared) in the Linux proxy's order
    static func policyAnswer(_ request: inout Data, proxy: MitmProxy, profileID: UUID,
                             host: String, port: Int, tls: Bool, session: UInt64) async -> Data? {
        let guardrails = proxy.guardrailsConfig(for: profileID)
        let policy = guardrails?.egressPolicy
        let scheme = tls ? "https" : "http"
        if let answer = ProxyPolicy.openShellHeadAnswer(&request, policy: policy, profileID: profileID,
                                                        host: host, port: port, cleartext: !tls,
                                                        scheme: scheme, identity: nil) {
            return answer
        }
        let (method, path) = HTTPFrames.parseRequestLine(request)
        if host.lowercased() == OpenShellAdvisor.host {
            return await ProxyPolicy.advisorAnswer(profileID: profileID, method: method, path: path, request: request,
                                                   policy: { proxy.guardrailsConfig(for: profileID)?.egressPolicy })
        }
        if let answer = ProxyPolicy.requestRuleAnswer(policy: policy, profileID: profileID, host: host, port: port,
                                                      method: method, path: path, request: request,
                                                      bodyComplete: true, scheme: scheme, identity: nil) {
            return answer
        }
        let fakes = proxy.swapper.entries(for: profileID).map(\.fake)
        switch ProxyPolicy.middleware(request, policy: policy, profileID: profileID, host: host, port: port,
                                      method: method, path: path, spooled: false,
                                      keep: { v in fakes.contains(v) || ProxyPolicy.isSubscriptionPlaceholder(v) }) {
        case .answer(let answer): return answer
        case .forward(let out): request = out
        }
        if let guardrails,
           let answer = await ProxyPolicy.guardrailsAnswer(request, guardrails: guardrails, host: host, port: port,
                                                           method: method, path: path,
                                                           broker: proxy.guardrailsBroker, profileID: profileID) {
            return answer
        }
        // A stand-in bound elsewhere, then a credential Bromure didn't issue.
        // `session` is the request's, taken when it was read: a consent above
        // may have held it while the workspace stopped and started again.
        if let refused = compromiseAnswer(request, proxy: proxy, profileID: profileID, host: host, session: session) { return refused }
        if let refused = unmanagedAnswer(request, proxy: proxy, profileID: profileID, host: host, session: session) { return refused }
        return nil
    }
}
