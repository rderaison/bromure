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
    /// 6d. A Claude `/v1/messages` turn while the workspace's Fusion is
    /// engaged: its dialogue fanned out to the configured legs, judged and
    /// synthesized into one reply in the guest's wire shape (Fusion.run,
    /// shared). Nil: not eligible (Fusion says so), and the turn goes on as
    /// usual. Each leg dials with this daemon's own credentials (the
    /// workspace's swap map, this user's subscription stores); every leg's
    /// call is traced as macOS traces them. Fusion failing midway ends the
    /// connection without a reply, as macOS's throw does.
    /// Every leg's destination is checked first, as any other dial is (the
    /// workspace's egress verdict, then checkDestination: resolved, every
    /// answer checked), and the HTTPS legs are dialled to the checked
    /// addresses only (FusionPinnedProtocol, SNI and certificate on the
    /// name; macOS: the connection's pinned dialer). A leg refused: Fusion
    /// steps aside for this request, which goes the normal way.
    // partial: the Codex-subscription leg's WebSocket is checked first but dialled by name (URLSessionWebSocketTask doesn't go through a URLProtocol); none in e2e mode (no real upstream)
    // @port-skip linux-only: HTTPMitmConnection.driveTLS's 6d step, on the Linux request chain
    static func fusionAnswer(_ request: Data, proxy: MitmProxy, profileID: UUID, host: String, port: Int,
                             trace: Trace?) async -> Data? {
        guard !proxy.refusesRealUpstreams, proxy.fusionEngaged(for: profileID),
              let config = proxy.fusionConfig(for: profileID) else { return nil }
        let hosts = Set([host] + fusionLegHosts(config))
        var pins: [String: [MitmProxy.IPAddress]] = [:]
        for leg in hosts {
            switch await proxy.checkFusionLeg(leg, profileID: profileID) {
            case .success(let addresses): pins[leg] = addresses
            case .failure(let why):
                FileHandle.standardError.write(Data("[mitm] fusion for \(host) stepped aside: its leg to \(leg) is refused (\(why))\n".utf8))
                return nil
            }
        }
        let reply = CollectedReply()
        let run = UUID()
        FusionPinnedProtocol.add(run, pins)
        defer { FusionPinnedProtocol.remove(run) }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [FusionPinnedProtocol.self]
        let session = URLSession(configuration: cfg)
        defer { session.finishTasksAndInvalidate() }
        let outcome: Fusion.Outcome?
        do {
            outcome = try await Fusion.run(rawRequest: request, host: host, port: port, session: session, tls: reply,
                                           swapper: proxy.swapper, config: config, profileID: profileID)
        } catch {
            FileHandle.standardError.write(Data("[mitm] fusion for \(host) failed: \(error)\n".utf8))
            return Data()
        }
        guard let outcome else { return nil }
        if let trace {
            for sc in outcome.subCalls { proxy.emitFusionCall(trace, sc) }
        }
        return outcome.buffer
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

extension RequestReader {
    /// The hosts Fusion's legs and judge reach for `config` (Fusion.askModel's
    /// endpoints), the on-host engine aside (it's this machine's own,
    /// dialled as the routing dials it).
    // @port-skip linux-only: Fusion's leg endpoints, for the Linux destination checks
    static func fusionLegHosts(_ config: Fusion.Config) -> [String] {
        func host(_ tool: Profile.Tool, _ auth: Profile.AuthMode?) -> [String] {
            switch (tool, auth ?? .token) {
            case (.claude, _): return ["api.anthropic.com"]
            case (.codex, .subscription): return ["chatgpt.com"]
            case (.codex, _): return ["api.openai.com"]
            case (.grok, .subscription): return ["cli-chat-proxy.grok.com"]
            case (.grok, _): return ["api.x.ai"]
            case (.kimi, .subscription): return [URL(string: KimiRegion.apiBase)?.host ?? "api.kimi.ai"]
            case (.kimi, _): return ["api.moonshot.ai"]
            case (.omp, _):
                switch config.ompProvider {
                case .anthropic: return ["api.anthropic.com"]
                case .openai: return ["api.openai.com"]
                case .xai: return ["api.x.ai"]
                default: return []
                }
            default: return []
            }
        }
        var out: [String] = []
        for leg in config.legs { out += host(leg, config.authModes[leg]) }
        if !config.judgeLocal { out += host(config.judgeProvider, config.authModes[config.judgeProvider]) }
        let usesLocal = config.localLegModel != nil || config.judgeLocal
        if usesLocal, let base = config.localEngineBase.flatMap(URL.init(string:))?.host, base != InferenceService.engineHost {
            out.append(base)
        }
        return out
    }
}

extension MitmProxy {
    /// A leg's check: its checked addresses, or why it's refused.
    enum FusionLegCheck { case success([IPAddress]), failure(String) }

    /// One Fusion leg's host, checked as any dial is: the workspace's egress
    /// verdict, then checkDestination (resolved, every answer checked).
    // @port-skip linux-only: Fusion's legs through the Linux proxy's destination checks
    func checkFusionLeg(_ host: String, profileID: UUID) async -> FusionLegCheck {
        let policy = guardrailsConfig(for: profileID)?.egressPolicy
        if ProxyPolicy.egressVerdict(policy: policy, profileID: profileID, host: host, port: 443, identity: nil) == .deny {
            return .failure("the workspace's firewall denies it")
        }
        do {
            let addresses = try await checkDestination(host: host, port: 443, profileID: profileID,
                                                       on: MultiThreadedEventLoopGroup.singleton.next()).get()
            return addresses.isEmpty ? .failure("no address") : .success(addresses)
        } catch let e as ProxyDestinationDenied {
            return .failure(e.reason)
        } catch {
            return .failure("\(error)")
        }
    }
}

/// Fusion's HTTPS legs to the addresses its checks passed, never a name
/// looked up again (PinnedHTTPS: SNI and certificate on the name). Only
/// Fusion's sessions register it, and it takes their every HTTPS request
/// (a request's own headers can't say which run it is: the session's are
/// added after canInit): a host is dialled to the addresses every running
/// Fusion that checked it passed (their intersection, so no workspace's
/// run dials an address its own checks refused); a host no run checked,
/// or no common address, isn't dialled.
// @port-skip linux-only: the pinned dial of Fusion's legs (macOS: the connection's PinnedUpstreamDialer)
final class FusionPinnedProtocol: URLProtocol, @unchecked Sendable {
    private static let runs = NIOLockedValueBox<[UUID: [String: [MitmProxy.IPAddress]]]>([:])

    // @port-skip linux-only: see FusionPinnedProtocol
    static func add(_ run: UUID, _ pins: [String: [MitmProxy.IPAddress]]) { runs.withLockedValue { $0[run] = pins } }
    // @port-skip linux-only: see FusionPinnedProtocol
    static func remove(_ run: UUID) { _ = runs.withLockedValue { $0.removeValue(forKey: run) } }

    /// The addresses every run that checked `host` passed.
    // @port-skip linux-only: see FusionPinnedProtocol
    static func addresses(for host: String) -> [MitmProxy.IPAddress] {
        let lists = runs.withLockedValue { $0.values.compactMap { $0[host] } }
        guard var common = lists.first else { return [] }
        for l in lists.dropFirst() { common = common.filter { l.contains($0) } }
        return common
    }

    // @port-skip linux-only: see FusionPinnedProtocol
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme?.lowercased() == "https"
    }

    // @port-skip linux-only: see FusionPinnedProtocol
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    // @port-skip linux-only: see FusionPinnedProtocol
    override func startLoading() {
        let req = request
        let addresses = Self.addresses(for: req.url?.host ?? "")
        Task {
            guard !addresses.isEmpty else { return self.fail(URLError(.cannotConnectToHost)) }
            var last: Error = URLError(.cannotConnectToHost)
            for ip in addresses {
                do {
                    let (response, data) = try await PinnedHTTPS.send(req, to: ip, timeout: req.timeoutInterval > 0 ? req.timeoutInterval : 600)
                    self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    self.client?.urlProtocol(self, didLoad: data)
                    self.client?.urlProtocolDidFinishLoading(self)
                    return
                } catch let e as PinnedHTTPS.ConnectFailed {
                    last = e   // nothing sent: the next checked address
                } catch {
                    return self.fail(error)
                }
            }
            self.fail(last)
        }
    }

    // @port-skip linux-only: see FusionPinnedProtocol
    private func fail(_ error: Error) { client?.urlProtocol(self, didFailWithError: error) }

    // @port-skip linux-only: see FusionPinnedProtocol
    override func stopLoading() {}
}
