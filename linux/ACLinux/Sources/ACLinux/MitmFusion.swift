import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
    // partial: the legs go out through URLSession by name (macOS: the connection's pinned dialer checks each leg's destination); none in e2e mode (no real upstream)
    // @port-skip linux-only: HTTPMitmConnection.driveTLS's 6d step, on the Linux request chain
    static func fusionAnswer(_ request: Data, proxy: MitmProxy, profileID: UUID, host: String, port: Int,
                             trace: Trace?) async -> Data? {
        guard !proxy.refusesRealUpstreams, proxy.fusionEngaged(for: profileID),
              let config = proxy.fusionConfig(for: profileID) else { return nil }
        let reply = CollectedReply()
        let session = URLSession(configuration: .ephemeral)
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
