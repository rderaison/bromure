import Foundation
import NIOCore
import NIOPosix
import SandboxEngine

/// The Linux proxy's egress and guardrails state: each workspace's
/// GuardrailsConfig (its egress policy among it), and the connections the
/// firewall may cut. The decisions themselves are ProxyPolicy's, shared
/// with macOS.
extension MitmProxy {
    // partial: strict credentials (UnmanagedCredentialGuard) aren't on Linux yet
    // @port MitmEngine.setGuardrailsConfig(_: GuardrailsConfig, for: UUID) h=c9069918294de82f @8e2543eb
    func setGuardrailsConfig(_ config: GuardrailsConfig, for profileID: UUID) {
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

    // partial: strict credentials (UnmanagedCredentialGuard) aren't on Linux yet
    // @port MitmEngine.clearGuardrailsConfig(for: UUID) h=0e852c5a469fc917 @8e2543eb
    func clearGuardrailsConfig(for profileID: UUID) {
        _ = guardrailsConfigs.withLockedValue { $0.removeValue(forKey: profileID) }
        EgressConnectionRegistry.shared.forget(profileID: profileID)
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

    /// An OpenShell `tls: skip` endpoint: the guest's bytes relayed raw to
    /// the checked addresses, never terminated (macOS: MitmPassthrough.splice).
    // @port-skip linux-only: MitmPassthrough.splice on NIO
    func splice(_ guest: Channel, to addresses: [OpenShellPolicy.IPAddress], port: Int, pending: ByteBuffer) {
        let targets = addresses.compactMap { try? SocketAddress(ipAddress: "\($0)", port: port) }
        guard let first = targets.first else { guest.close(promise: nil); return }
        ClientBootstrap(group: guest.eventLoop)
            .connectTimeout(.seconds(10))
            .channelInitializer { up in up.pipeline.addHandler(ByteGlue(peer: guest)) }
            .connect(to: first)
            .whenComplete { r in
                switch r {
                case .failure:
                    guest.close(promise: nil)
                case .success(let up):
                    if pending.readableBytes > 0 { up.writeAndFlush(pending, promise: nil) }
                    guest.pipeline.addHandler(ByteGlue(peer: up)).whenFailure { _ in up.close(promise: nil) }
                }
            }
    }
}

/// One direction of a raw relay: what this channel reads goes to `peer`;
/// either side closing closes the other.
// @port-skip linux-only: NIO plumbing of the Linux proxy
final class ByteGlue: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let peer: Channel

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    init(peer: Channel) { self.peer = peer }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        peer.write(unwrapInboundIn(data), promise: nil)
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func channelReadComplete(context: ChannelHandlerContext) { peer.flush() }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func channelInactive(context: ChannelHandlerContext) {
        peer.close(promise: nil)
        context.fireChannelInactive()
    }

    // @port-skip linux-only: NIO plumbing of the Linux proxy
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

extension RequestReader {
    /// The workspace's policy chain for one request, before any credential is
    /// swapped in, in macOS's order (HTTPMitmConnection.driveTLS, steps 4–4b
    /// and the guardrails): OpenShell's head checks (which may rewrite the
    /// request-target in `request`), `policy.local`, OpenShell request rules,
    /// the middleware chain (which may rewrite the body), the guardrails.
    /// The guest's answer, or nil to go on with `request`.
    // partial: OpenShell's strict framing limits (chunk-line, header and trailer sizes) aren't applied; the Linux framer re-frames every body with a Content-Length
    // @port-skip linux-only: driveTLS's policy steps (ProxyPolicy, shared) in the Linux proxy's order
    static func policyAnswer(_ request: inout Data, proxy: MitmProxy, profileID: UUID,
                             host: String, port: Int, tls: Bool) async -> Data? {
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
        return nil
    }
}
