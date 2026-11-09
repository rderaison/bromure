import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// Fusion on the Linux proxy (macOS: driveTLS's 6d, MitmEngine's Fusion
/// state): a workspace's config and its per-session toggle, and the step
/// that answers a Claude turn with the fused reply when it's engaged.
extension MitmProxy {
    // @port MitmEngine.setFusionEngaged(_: Bool, for: UUID) h=0db65961db248cf3 @45a144c8
    func setFusionEngaged(_ engaged: Bool, for profileID: UUID) {
        let prior = fusionEngagedFlags.withLockedValue { flags -> Bool? in
            defer { flags[profileID] = engaged }
            return flags[profileID]
        }
        if prior != engaged {
            SupplyChainLog.shared.record("[fusion] \(engaged ? "engaged" : "disengaged") for \(profileID.uuidString.prefix(8))")
        }
    }

    // @port MitmEngine.fusionEngaged(for: UUID) h=ced6da0eb21af3c4 @45a144c8
    func fusionEngaged(for profileID: UUID) -> Bool {
        fusionEngagedFlags.withLockedValue { $0[profileID] ?? false }
    }

    // @port MitmEngine.clearFusionEngaged(for: UUID) h=7533ef9261d4017c @45a144c8
    func clearFusionEngaged(for profileID: UUID) {
        _ = fusionEngagedFlags.withLockedValue { $0.removeValue(forKey: profileID) }
    }

    // @port MitmEngine.setFusionConfig(_: Fusion.Config?, for: UUID) h=7ab59a1eb86cb0fc @45a144c8
    func setFusionConfig(_ config: Fusion.Config?, for profileID: UUID) {
        fusionConfigs.withLockedValue { $0[profileID] = config }
    }

    // @port MitmEngine.fusionConfig(for: UUID) h=b40e3cb5a973bd1e @45a144c8
    func fusionConfig(for profileID: UUID) -> Fusion.Config? {
        fusionConfigs.withLockedValue { $0[profileID] }
    }

    // @port MitmEngine.clearFusionConfig(for: UUID) h=3f0f71de14e79e7d @45a144c8
    func clearFusionConfig(for profileID: UUID) {
        _ = fusionConfigs.withLockedValue { $0.removeValue(forKey: profileID) }
    }
}

extension RequestReader {
    /// What the 6d step did with a turn.
    enum FusionStep { case notRun, fused(Data), failed }

    /// 6d. A Claude `/v1/messages` turn while the workspace's Fusion is
    /// engaged: its dialogue fanned out to the configured legs, judged and
    /// synthesized into one reply in the guest's wire shape (Fusion.run,
    /// shared). `.notRun`: not eligible, and the turn goes on as usual.
    /// Each leg dials with this daemon's own credentials (the workspace's
    /// swap map, this user's subscription stores); every leg's call is
    /// traced as macOS traces them. Fusion failing midway ends the
    /// connection without a reply (and without a guest trace), as macOS's
    /// throw does.
    /// Stricter than macOS, whose Fusion dials every leg by name: each leg's
    /// destination (its own scheme and port) is checked first, as any other
    /// dial is (the workspace's egress verdict, then checkDestination), and
    /// its HTTP(S) requests go to the addresses this run's checks passed only
    /// (FusionPinnedProtocol; HTTPS through PinnedHTTPS, SNI and certificate
    /// on the name). A leg refused: Fusion steps aside for this request,
    /// which goes the normal way (logged once per workspace and leg).
    // partial: the Codex-subscription leg's WebSocket is checked first but dialled by name (no URLProtocol pins a WebSocket task); none in e2e mode (no real upstream)
    // @port-skip linux-only: HTTPMitmConnection.driveTLS's 6d step, on the Linux request chain
    static func fusionAnswer(_ request: Data, proxy: MitmProxy, profileID: UUID, host: String, port: Int,
                             trace: Trace?) async -> FusionStep {
        guard !proxy.refusesRealUpstreams, proxy.fusionEngaged(for: profileID),
              let config = proxy.fusionConfig(for: profileID) else { return .notRun }
        // Fusion.run's own eligibility, before any leg is checked.
        guard let req = HTTPWire.parse(request),
              host == "api.anthropic.com" || host.hasSuffix(".anthropic.com"),
              req.method.uppercased() == "POST", req.path.hasPrefix("/v1/messages") else { return .notRun }
        let legs = Set([FusionLeg(host: host, port: port, tls: true)] + fusionLegEndpoints(config))
        var pins: [String: [MitmProxy.IPAddress]] = [:]
        for leg in legs {
            switch await proxy.checkFusionLeg(leg, profileID: profileID) {
            case .success(let addresses): pins[leg.key] = addresses
            case .failure(let why):
                if proxy.fusionRefusalsLogged.withLockedValue({ $0.insert("\(profileID)|\(leg.key)").inserted }) {
                    FileHandle.standardError.write(Data("[mitm] fusion stepped aside: its leg to \(leg.key) is refused (\(why))\n".utf8))
                }
                return .notRun
            }
        }
        guard let protocolClass = FusionPinnedProtocol.acquire(pins) else {
            FileHandle.standardError.write(Data("[mitm] fusion stepped aside: too many Fusion turns at once\n".utf8))
            return .notRun
        }
        defer { protocolClass.release() }
        let reply = CollectedReply()
        let session = URLSession(configuration: fusionSessionConfiguration(protocolClass))
        defer { session.finishTasksAndInvalidate() }
        let outcome: Fusion.Outcome?
        do {
            outcome = try await Fusion.run(rawRequest: request, host: host, port: port, session: session, tls: reply,
                                           swapper: proxy.swapper, config: config, profileID: profileID)
        } catch {
            FileHandle.standardError.write(Data("[mitm] fusion for \(host) failed: \(error)\n".utf8))
            return .failed
        }
        guard let outcome else { return .notRun }
        if let trace {
            for sc in outcome.subCalls { proxy.emitFusionCall(trace, sc) }
        }
        return .fused(outcome.buffer)
    }

    /// A Fusion run's session: its pinned protocol first, then the system's
    /// (the WebSocket leg's protocol among them).
    // @port-skip linux-only: see fusionAnswer
    static func fusionSessionConfiguration(_ pinned: FusionPinnedProtocol.Type) -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [pinned] + (URLSessionConfiguration.ephemeral.protocolClasses ?? [])
        return cfg
    }
}

extension MitmProxy {
    /// One of Fusion's upstream model calls (leg, judge, synthesis) as its
    /// own trace record, so a managed workspace audits every provider hit.
    // @port-skip linux-only: driveTLS's per-sub-call emitTrace, on the Linux proxy
    func emitFusionCall(_ t: RequestReader.Trace, _ sc: Fusion.SubCall) {
        guard let store = traces.withLockedValue({ $0 }) else { return }
        Task {
            await TraceEmitter.emit(
                session: t.session, store: store, profileID: t.profileID, host: sc.host, port: sc.port,
                preSwapRequest: sc.requestBlob, upstreamResponse: sc.responseBlob, upstreamWireBytes: sc.wireBytes,
                responseTruncated: false, swaps: [], leaks: [], latencyMs: sc.latencyMs)
        }
    }
}

/// A Fusion leg's endpoint: what's checked and pinned.
// @port-skip linux-only: Fusion's leg endpoints, for the Linux destination checks
struct FusionLeg: Hashable, Sendable {
    let host: String
    let port: Int
    let tls: Bool
    // @port-skip linux-only: see FusionLeg
    var key: String { "\(host):\(port)" }
}

extension RequestReader {
    /// The endpoints Fusion's legs and judge reach for `config`
    /// (Fusion.askModel's), by provider and auth mode; a local leg or judge
    /// is the user's external engine (its own scheme and port), the on-host
    /// engine aside (this machine's own, dialled as the routing dials it).
    // @port-skip linux-only: Fusion's leg endpoints, for the Linux destination checks
    static func fusionLegEndpoints(_ config: Fusion.Config) -> [FusionLeg] {
        func https(_ h: String) -> [FusionLeg] { [FusionLeg(host: h, port: 443, tls: true)] }
        let external: [FusionLeg] = {
            guard let url = config.localEngineBase.flatMap(URL.init(string:)), let h = url.host,
                  h != InferenceService.engineHost, let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { return [] }
            return [FusionLeg(host: h, port: url.port ?? (scheme == "https" ? 443 : 80), tls: scheme == "https")]
        }()
        func endpoints(_ tool: Profile.Tool, _ auth: Profile.AuthMode?) -> [FusionLeg] {
            switch (tool, auth ?? .token) {
            case (_, .local): return external
            case (.claude, _): return https("api.anthropic.com")
            case (.codex, .subscription): return https("chatgpt.com")
            case (.codex, _): return https("api.openai.com")
            case (.grok, .subscription): return https("cli-chat-proxy.grok.com")
            case (.grok, _): return https("api.x.ai")
            case (.kimi, .subscription): return https(URL(string: KimiRegion.apiBase)?.host ?? "api.kimi.ai")
            case (.kimi, _): return https("api.moonshot.ai")
            case (.omp, _):
                switch config.ompProvider {
                case .anthropic: return https("api.anthropic.com")
                case .openai: return https("api.openai.com")
                case .xai: return https("api.x.ai")
                default: return []
                }
            default: return []
            }
        }
        var out: [FusionLeg] = []
        for leg in config.legs { out += endpoints(leg, config.authModes[leg]) }
        if config.judgeLocal { out += external } else { out += endpoints(config.judgeProvider, config.authModes[config.judgeProvider]) }
        if config.localLegModel != nil { out += external }
        return out
    }
}

extension MitmProxy {
    /// A leg's check: its checked addresses, or why it's refused.
    enum FusionLegCheck { case success([IPAddress]), failure(String) }

    /// One Fusion leg's endpoint, checked as any dial is: the workspace's
    /// egress verdict, then checkDestination (resolved, every answer checked).
    // @port-skip linux-only: Fusion's legs through the Linux proxy's destination checks
    func checkFusionLeg(_ leg: FusionLeg, profileID: UUID) async -> FusionLegCheck {
        let policy = guardrailsConfig(for: profileID)?.egressPolicy
        if ProxyPolicy.egressVerdict(policy: policy, profileID: profileID, host: leg.host, port: leg.port, identity: nil) == .deny {
            return .failure("the workspace's firewall denies it")
        }
        do {
            let addresses = try await checkDestination(host: leg.host, port: leg.port, profileID: profileID,
                                                       on: MultiThreadedEventLoopGroup.singleton.next()).get()
            return addresses.isEmpty ? .failure("no address") : .success(addresses)
        } catch let e as ProxyDestinationDenied {
            return .failure(e.reason)
        } catch {
            return .failure("\(error)")
        }
    }
}

/// Fusion's HTTP(S) legs to the addresses its run's checks passed, never a
/// name looked up again (HTTPS through PinnedHTTPS: SNI and certificate on
/// the name; plain HTTP to the address, Host the name; no redirect followed,
/// no proxy from the environment). A request's own
/// headers can't say which run it is (a session's are added after canInit),
/// so each run has its own subclass, a slot of a small pool, registered on
/// its session alone: a host:port the run didn't check isn't dialled.
// @port-skip linux-only: the pinned dial of Fusion's legs (macOS dials them by name)
class FusionPinnedProtocol: URLProtocol, @unchecked Sendable {
    // @port-skip linux-only: see FusionPinnedProtocol
    class var slot: Int { -1 }
    private static let table = NIOLockedValueBox<[Int: [String: [MitmProxy.IPAddress]]]>([:])
    static let slots: [FusionPinnedProtocol.Type] = [
        FusionPinnedSlot0.self, FusionPinnedSlot1.self, FusionPinnedSlot2.self, FusionPinnedSlot3.self,
        FusionPinnedSlot4.self, FusionPinnedSlot5.self, FusionPinnedSlot6.self, FusionPinnedSlot7.self,
    ]

    /// A free slot holding `pins` (by "host:port"), or nil when every slot
    /// is taken.
    // @port-skip linux-only: see FusionPinnedProtocol
    static func acquire(_ pins: [String: [MitmProxy.IPAddress]]) -> FusionPinnedProtocol.Type? {
        table.withLockedValue { t in
            guard let free = slots.first(where: { t[$0.slot] == nil }) else { return nil }
            t[free.slot] = pins
            return free
        }
    }

    // @port-skip linux-only: see FusionPinnedProtocol
    class func release() { _ = table.withLockedValue { $0.removeValue(forKey: slot) } }

    // @port-skip linux-only: see FusionPinnedProtocol
    class func addresses(for key: String) -> [MitmProxy.IPAddress] { table.withLockedValue { $0[slot]?[key] } ?? [] }

    // @port-skip linux-only: see FusionPinnedProtocol
    override class func canInit(with request: URLRequest) -> Bool {
        let scheme = request.url?.scheme?.lowercased()
        return scheme == "https" || scheme == "http"
    }

    // @port-skip linux-only: see FusionPinnedProtocol
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// The dial under way, and whether the loader ended (stopped, or its
    /// one outcome delivered): checked and set under the lock, the client
    /// called outside it, so nothing reaches the client after a stop or
    /// twice, and a client stopping the loader from its callback can't
    /// deadlock.
    private let lock = NSLock()
    private var dial: Task<Void, Never>?
    private var ended = false

    // @port-skip linux-only: see FusionPinnedProtocol
    override func startLoading() {
        let req = request
        guard let url = req.url, let host = url.host else { return fail(URLError(.badURL)) }
        let tls = url.scheme?.lowercased() == "https"
        let port = url.port ?? (tls ? 443 : 80)
        let addresses = type(of: self).addresses(for: "\(host):\(port)")
        let timeout = req.timeoutInterval > 0 ? req.timeoutInterval : 600
        let task = Task {
            guard !addresses.isEmpty else { return self.fail(URLError(.cannotConnectToHost)) }
            var last: Error = URLError(.cannotConnectToHost)
            for ip in addresses {
                do {
                    // No redirect followed, no proxy from the environment:
                    // a 3xx is the leg's answer, never another dial.
                    let (raw, data) = tls
                        ? try await PinnedHTTPS.send(req, to: ip, timeout: timeout)
                        : try await PinnedHTTPS.sendPlain(req, to: ip, timeout: timeout)
                    let response = Self.unframed(raw)
                    self.deliver { client in
                        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                        client.urlProtocol(self, didLoad: data)
                        client.urlProtocolDidFinishLoading(self)
                    }
                    return
                } catch let e as PinnedHTTPS.ConnectFailed {
                    last = e   // nothing sent: the next checked address
                } catch {
                    return self.fail(error)
                }
            }
            self.fail(last)
        }
        lock.lock()
        self.dial = task
        let wasEnded = ended
        lock.unlock()
        if wasEnded { task.cancel() }
    }

    /// The leg's response as the client gets it: its body arrives whole
    /// (de-chunked), so the upstream's framing headers don't come along.
    // @port-skip linux-only: see FusionPinnedProtocol
    static func unframed(_ r: HTTPURLResponse) -> HTTPURLResponse {
        var fields: [String: String] = [:]
        for case (let k as String, let v as String) in r.allHeaderFields
        where !["transfer-encoding", "content-length"].contains(k.lowercased()) {
            fields[k] = v
        }
        return HTTPURLResponse(url: r.url ?? URL(string: "about:blank")!, statusCode: r.statusCode,
                               httpVersion: "HTTP/1.1", headerFields: fields) ?? r
    }

    // @port-skip linux-only: see FusionPinnedProtocol
    private func fail(_ error: Error) { deliver { $0.urlProtocol(self, didFailWithError: error) } }

    /// The client's callbacks, unless the loader was stopped.
    // @port-skip linux-only: see FusionPinnedProtocol
    private func deliver(_ body: (any URLProtocolClient) -> Void) {
        lock.lock()
        let mine = !ended
        ended = true
        let client = self.client
        lock.unlock()
        guard mine, let client else { return }
        body(client)
    }

    // @port-skip linux-only: see FusionPinnedProtocol
    override func stopLoading() {
        lock.lock()
        ended = true
        let dial = self.dial
        lock.unlock()
        dial?.cancel()
    }
}

// @port-skip linux-only: a slot of FusionPinnedProtocol's pool
final class FusionPinnedSlot0: FusionPinnedProtocol, @unchecked Sendable {
    // @port-skip linux-only: see FusionPinnedProtocol
    override class var slot: Int { 0 }
}
// @port-skip linux-only: a slot of FusionPinnedProtocol's pool
final class FusionPinnedSlot1: FusionPinnedProtocol, @unchecked Sendable {
    // @port-skip linux-only: see FusionPinnedProtocol
    override class var slot: Int { 1 }
}
// @port-skip linux-only: a slot of FusionPinnedProtocol's pool
final class FusionPinnedSlot2: FusionPinnedProtocol, @unchecked Sendable {
    // @port-skip linux-only: see FusionPinnedProtocol
    override class var slot: Int { 2 }
}
// @port-skip linux-only: a slot of FusionPinnedProtocol's pool
final class FusionPinnedSlot3: FusionPinnedProtocol, @unchecked Sendable {
    // @port-skip linux-only: see FusionPinnedProtocol
    override class var slot: Int { 3 }
}
// @port-skip linux-only: a slot of FusionPinnedProtocol's pool
final class FusionPinnedSlot4: FusionPinnedProtocol, @unchecked Sendable {
    // @port-skip linux-only: see FusionPinnedProtocol
    override class var slot: Int { 4 }
}
// @port-skip linux-only: a slot of FusionPinnedProtocol's pool
final class FusionPinnedSlot5: FusionPinnedProtocol, @unchecked Sendable {
    // @port-skip linux-only: see FusionPinnedProtocol
    override class var slot: Int { 5 }
}
// @port-skip linux-only: a slot of FusionPinnedProtocol's pool
final class FusionPinnedSlot6: FusionPinnedProtocol, @unchecked Sendable {
    // @port-skip linux-only: see FusionPinnedProtocol
    override class var slot: Int { 6 }
}
// @port-skip linux-only: a slot of FusionPinnedProtocol's pool
final class FusionPinnedSlot7: FusionPinnedProtocol, @unchecked Sendable {
    // @port-skip linux-only: see FusionPinnedProtocol
    override class var slot: Int { 7 }
}
