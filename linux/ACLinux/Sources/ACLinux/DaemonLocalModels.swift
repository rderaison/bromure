import Foundation
import NIOCore
import NIOPosix

/// Local models on a Linux server: a workspace's agents set to "Local model"
/// reach a user-supplied external engine (vLLM, Ollama, LM Studio, …) the
/// way macOS's do — the guest's bridge (127.0.0.1:11434) dials host vsock
/// 8446, which goes to the tool-call repair proxy, which speaks the engine's
/// OpenAI API. The built-in engine (MLX) is macOS-only: its downloads are
/// refused, and a workspace that selects one of its models is told so.
extension Daemon {
    /// The profile a launch stages: the workspace with Preferences › Models
    /// projected on (macOS: launch's overlaidWithGlobalModels), so the token
    /// plan, the home seed, the meta share and the engine all see the models
    /// and credentials the user configured. A sign-in VM's stays as made.
    // @port-skip linux-only: launch's projection step (macOS: inline in ACAppDelegate.launch)
    /// `create` false: only a Profile the VM already has (a restarted
    /// daemon's lookups never make one).
    func launchProfile(for rec: VMRecord, create: Bool = true) async -> Profile? {
        guard let raw = create ? profile(for: rec) : existingProfile(for: rec) else { return nil }
        if rec.registration == true { return raw }
        return await stagedProfile(raw)
    }

    /// A workspace with Preferences › Models projected on, as a launch and
    /// a live refresh stage it.
    // @port-skip linux-only: launch's projection step (macOS: inline in ACAppDelegate.launch and pushLiveCredentials)
    func stagedProfile(_ raw: Profile) async -> Profile {
        let subscribed = subscribedProviders(for: raw)
        return await MainActor.run {
            raw.overlaidWithGlobalModels(ModelSettingsStore.shared.effective(for: raw), subscribed: subscribed)
        }
    }

    /// The providers with a signed-in subscription the workspace can use.
    // @port ACAppDelegate.subscribedProviders(for: Profile) h=6f587086eef888b7 @7057d502
    func subscribedProviders(for profile: Profile) -> Set<ModelProvider> {
        guard let e = mitm else { return [] }
        var s = Set<ModelProvider>()
        if e.claudeStore.hasCredential(for: profile.id) { s.insert(.anthropic) }
        if e.codexStore.hasCredential(for: profile.id)  { s.insert(.openai) }
        if e.grokStore.hasCredential(for: profile.id)   { s.insert(.xai) }
        if e.kimiStore.hasCredential(for: profile.id)   { s.insert(.moonshot) }
        return s
    }

    /// Register the workspace's external engine with the repair proxy and
    /// probe it, for a launch whose agents use a local model. A workspace
    /// on the built-in engine is told it's macOS-only (the daemon log; its
    /// agents' calls get the proxy's wire-shaped "no engine" error).
    // partial: external engines only (the built-in MLX engine is macOS-only); status to the daemon log (no pane)
    // @port ACAppDelegate.startLocalEngineIfNeeded(for: Profile) h=f08c2a0c5693ee85 @7057d502
    func startLocalEngineIfNeeded(for profile: Profile) {
        let pid = profile.id
        guard !profile.distinctLocalModelIDs.isEmpty else {
            InferenceRepairProxy.shared.setExternalEngine(pid, nil)
            return
        }
        guard let base = profile.localEngineBaseURL else {
            InferenceRepairProxy.shared.setExternalEngine(pid, nil)
            Self.inferenceLog("'\(profile.name)': its local model needs the built-in engine, which runs on macOS only — set an external engine (OpenAI-compatible server) in Preferences › Models")
            return
        }
        let apiKey = profile.localEngineAPIKey
        // Amazon Bedrock as the engine: a pasted Bedrock API key is a plain
        // bearer; without one the host signs each request (SigV4) with the
        // workspace's AWS credentials (ExternalEngine.awsSigner).
        var config = ExternalEngine.Config(base: base, apiKey: apiKey)
        let bedrock = config.isBedrock
        if bedrock, (apiKey ?? "").isEmpty, let region = Bedrock.region(fromHost: base.host ?? "") {
            config.auth = .sigV4(profileID: pid, region: region)
        }
        InferenceRepairProxy.shared.setExternalEngine(pid, Self.testEngineRoute(config))
        if let activeID = profile.activeModelID, !activeID.isEmpty {
            InferenceRepairProxy.shared.setActiveModel(pid, repo: activeID)
            if !bedrock { EngineModelMeta.refresh(base: base, apiKey: apiKey, model: activeID) }
        }
        InferenceRepairProxy.shared.startIfNeeded()
        if bedrock {
            Self.inferenceLog("'\(profile.name)': Amazon Bedrock engine \(base.absoluteString) registered")
            return
        }
        let label = profile.activeModelID ?? base.host ?? "external engine"
        let name = profile.name
        Task.detached(priority: .userInitiated) {
            do {
                let served = try await ExternalEngine.listModels(base: base, apiKey: apiKey)
                Self.inferenceLog("'\(name)': external engine \(base.absoluteString) reachable — \(served.count) model(s), serving \(label)")
            } catch {
                Self.inferenceLog("'\(name)': external engine \(base.absoluteString) unreachable: \(error.localizedDescription)")
            }
        }
    }

    /// Debug builds, VM e2e only: a Bedrock engine's calls go to a test
    /// server (`BROMURE_AC_TEST_ENGINE_ROUTE=ip:port`, plain HTTP, the path
    /// kept), still signed as for Bedrock: the host's URLSession trusts only
    /// the system's CAs, so no test CA can stand in for AWS's. A release
    /// build has none.
    // @port-skip linux-only: e2e hook of the Linux engine registration
    static func testEngineRoute(_ config: ExternalEngine.Config) -> ExternalEngine.Config {
        #if DEBUG
        guard config.isBedrock, let v = ProcessInfo.processInfo.environment["BROMURE_AC_TEST_ENGINE_ROUTE"],
              let colon = v.lastIndex(of: ":"), let port = Int(v[v.index(after: colon)...]),
              var c = URLComponents(url: config.base, resolvingAgainstBaseURL: false) else { return config }
        c.scheme = "http"
        c.host = String(v[..<colon])
        c.port = port
        guard let url = c.url else { return config }
        FileHandle.standardError.write(Data("bromure-ac daemon: DEBUG: Bedrock engine calls go to \(v)\n".utf8))
        var out = config
        out.base = url
        return out
        #else
        return config
        #endif
    }

    /// The local-model engine's master key (every VM's engine key derives
    /// from it) in the daemon's 0700 state directory, 0600 (macOS:
    /// Application Support); one an older daemon made in the data home is
    /// moved there, so running guests' keys stay valid.
    // @port-skip linux-only: the engine key's place on a Linux server
    static func placeEngineKey(stateDir: String, from oldPath: String? = nil) {
        let fm = FileManager.default
        let old = oldPath ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BromureAC/engine-master.key").path
        EngineKey.directoryOverride = URL(fileURLWithPath: stateDir, isDirectory: true)
        let new = EngineKey.masterURL.path
        if !fm.fileExists(atPath: new), fm.fileExists(atPath: old) {
            do { try fm.moveItem(atPath: old, toPath: new) } catch {
                FileHandle.standardError.write(Data("bromure-ac daemon: couldn't move the engine key: \(error)\n".utf8))
            }
        }
        if fm.fileExists(atPath: new) { chmod(new, 0o600) }
    }

    // @port-skip linux-only: the daemon log's share of InferenceLog
    static func inferenceLog(_ line: String) {
        InferenceLog.shared.record("[inference] " + line)
        FileHandle.standardError.write(Data("[inference] \(line)\n".utf8))
    }

    /// The VM's inference bridge listener (`stored`: a restarted daemon's);
    /// none for a sign-in VM (its token agent has 8446), a cluster machine,
    /// or without a proxy.
    // @port-skip linux-only: the per-VM inference listener (macOS: MitmEngine.register's inferenceListener)
    func serveInference(_ rec: VMRecord, udsPath: String, stored: Int32?) -> InferenceBridgeListener? {
        guard mitm != nil, !rec.managed else { if let stored { close(stored) }; return nil }
        do {
            return try InferenceBridgeListener(udsPath: udsPath, fdStoreName: "llm-" + rec.shortId, stored: stored,
                                               profileID: UUID(uuidString: rec.id))
        } catch {
            FileHandle.standardError.write(Data("bromure-ac daemon: '\(rec.name)': no inference listener: \(error)\n".utf8))
            return nil
        }
    }

    /// `/state`'s `localModels`: the server's memory (the client's fit gate)
    /// and its installed built-in models — none here.
    // partial: no built-in engine on Linux, so no models
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onLocalModels h=102d14ae0a7eef91 @7057d502
    static func localModels() -> JSONValue {
        let gb = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        return ["unifiedMemGB": .number(Double(gb)), "models": .object([:])]
    }

    /// `POST /models/{download,cancel,discard,remove}`: the built-in
    /// engine's model files. Refused: that engine is macOS-only.
    // partial: refused (the built-in MLX engine is macOS-only)
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool) / case ("POST", let p) where p.hasPrefix("/models/"): h=35249da0c5fa92e9 @f127f8ab
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onModelAction h=17a44a9c542ea547 @7057d502
    func modelAction(_ path: String, _ body: JSONValue) -> ControlResponse {
        let action = String(path.dropFirst("/models/".count))
        guard ["download", "cancel", "discard", "remove"].contains(action),
              let repo = body["repo"]?.stringValue, !repo.isEmpty else {
            return .error(400, "bad action or repo")
        }
        return ControlResponse(400, ["ok": false, "error": .string(
            "This server has no built-in model engine: it runs on macOS only. Set an external engine (an OpenAI-compatible server) in Preferences › Models instead.")])
    }
}

/// One VM's host end of the guest's inference bridge: Firecracker delivers
/// the guest's vsock 8446 connections on `<v.sock>_8446`; each is spliced to
/// the repair proxy on loopback, its port read per connection (macOS:
/// InferenceListenerDelegate + InferenceVsockBridge.pump).
// @port-skip linux-only: InferenceListenerDelegate over hybrid vsock (NIO)
final class InferenceBridgeListener: @unchecked Sendable {
    static let vsockPort: UInt32 = 8446
    let path: String
    let fdStoreName: String
    private let channel: Channel

    // @port InferenceListenerDelegate.listener(_: VZVirtioSocketListener, shouldAcceptNewConnection: VZVirtioSocketConnection, from: VZVirtioSocketDevice) h=9e4a1c3a6305393e @b91fddfb
    init(udsPath: String, fdStoreName: String, stored: Int32?, profileID: UUID? = nil) throws {
        path = HybridVsockListener.path(uds: udsPath, port: Self.vsockPort)
        self.fdStoreName = fdStoreName
        let fd: Int32
        if let stored { fd = stored } else {
            fd = try HybridVsockListener.bindListening(path)
            FDStore.store(fdStoreName, [fd])
        }
        channel = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { guest in
                // A quarantined workspace reaches no model (a local engine's
                // or a provider's); a quarantine closes a connection open.
                if let profileID {
                    // Refused: a failed initializer (NIO closes the child; a
                    // close inside the initializer trips its assertion).
                    if WorkspaceQuarantine.shared.contains(profileID) {
                        return guest.eventLoop.makeFailedFuture(ChannelError.inputClosed)
                    }
                    // Registered, then checked again (a quarantine that started in
                    // between ran its cuts first); a cut closes on the loop's
                    // next turn, never under the initializer.
                    let cut = WorkspaceQuarantine.shared.onQuarantine(profileID, runNow: false) { [weak guest] in
                        guest?.eventLoop.execute { guest?.close(promise: nil) }
                    }
                    if WorkspaceQuarantine.shared.contains(profileID) {
                        WorkspaceQuarantine.shared.remove(cut, for: profileID)
                        return guest.eventLoop.makeFailedFuture(ChannelError.inputClosed)
                    }
                    guest.closeFuture.whenComplete { _ in WorkspaceQuarantine.shared.remove(cut, for: profileID) }
                }
                // Paused until the proxy side is connected.
                return guest.setOption(ChannelOptions.autoRead, value: false).flatMap {
                    ClientBootstrap(group: guest.eventLoop)
                        .channelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
                        .connect(host: "127.0.0.1", port: InferenceRepairProxy.shared.listenPort)
                }.flatMap { proxy in
                    let (a, b) = SpliceHandler.matchedPair()
                    return guest.pipeline.addHandler(a).flatMap { proxy.pipeline.addHandler(b) }.flatMap {
                        guest.setOption(ChannelOptions.autoRead, value: true)
                    }
                }.flatMapErrorThrowing { error in
                    guest.close(promise: nil)
                    throw error
                }
            }
            .withBoundSocket(fd).wait()
    }

    /// The VM is gone: the listener closed and its socket file removed.
    // @port-skip linux-only: the per-VM inference listener
    func stop() {
        channel.close(promise: nil)
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// Bytes both ways between two channels; each side's EOF half-closes the
/// other, a close closes both.
// @port-skip linux-only: NIO plumbing (macOS: InferenceVsockBridge's blocking pump)
final class SpliceHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private var partner: SpliceHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    // @port-skip linux-only: NIO plumbing
    static func matchedPair() -> (SpliceHandler, SpliceHandler) {
        let a = SpliceHandler(), b = SpliceHandler()
        a.partner = b
        b.partner = a
        return (a, b)
    }

    // @port-skip linux-only: NIO plumbing
    func handlerAdded(context: ChannelHandlerContext) { self.context = context }

    // @port-skip linux-only: NIO plumbing
    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    // @port-skip linux-only: NIO plumbing
    func channelRead(context: ChannelHandlerContext, data: NIOAny) { partner?.write(data) }

    // @port-skip linux-only: NIO plumbing
    func channelReadComplete(context: ChannelHandlerContext) { partner?.flush() }

    // @port-skip linux-only: NIO plumbing
    func channelInactive(context: ChannelHandlerContext) { partner?.closeChannel() }

    // @port-skip linux-only: NIO plumbing
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let e = event as? ChannelEvent, case .inputClosed = e { partner?.halfClose() }
        context.fireUserInboundEventTriggered(event)
    }

    // @port-skip linux-only: NIO plumbing
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }

    // Backpressure: read from this side only while the partner can write.
    // @port-skip linux-only: NIO plumbing
    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { partner?.becameWritable() }
    }

    // @port-skip linux-only: NIO plumbing
    func read(context: ChannelHandlerContext) {
        if partner?.partnerWritable ?? false { context.read() } else { pendingRead = true }
    }

    // @port-skip linux-only: NIO plumbing
    private var partnerWritable: Bool { context?.channel.isWritable ?? false }

    // @port-skip linux-only: NIO plumbing
    private func write(_ data: NIOAny) { context?.write(data, promise: nil) }
    // @port-skip linux-only: NIO plumbing
    private func flush() { context?.flush() }
    // @port-skip linux-only: NIO plumbing
    private func closeChannel() { context?.close(promise: nil) }
    // @port-skip linux-only: NIO plumbing
    private func halfClose() { context?.close(mode: .output, promise: nil) }
    // @port-skip linux-only: NIO plumbing
    private func becameWritable() {
        guard pendingRead, let context else { return }
        pendingRead = false
        context.read()
    }
}
