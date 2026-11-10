import Foundation
import NIOConcurrencyHelpers

/// A workspace's model routing in the Linux proxy (macOS: MitmEngine's
/// routing contexts, read by HTTPProxy): under `.local`, an agent that is
/// itself on the local model has its real cloud host's LLM calls served by
/// the on-host engine (the repair proxy, in clear on loopback), its
/// management and telemetry calls answered with an empty 200, and its cloud
/// auth replaced by the workspace's engine key. The sentinel host is always
/// local.
extension MitmProxy {
    // @port MitmEngine.setRouting(_: Profile.Routing, modelLabel: String, localCloudHosts: Set<String>, for: UUID) h=7139368342379a9d @647ee46e
    func setRouting(_ routing: Profile.Routing, modelLabel: String, localCloudHosts: Set<String> = [],
                    for profileID: UUID) {
        // A new snapshot, never the old one changed in place: requests
        // hold contexts outside the lock.
        let context = LLMRoutingContext(routing: routing, localModelLabel: modelLabel, localCloudHosts: localCloudHosts)
        routingContexts.withLockedValue { $0[profileID] = context }
    }

    // @port-skip linux-only: the routing half of clearWorkspacePolicies
    func clearRouting(for profileID: UUID) {
        _ = routingContexts.withLockedValue { $0.removeValue(forKey: profileID) }
    }

    // @port-skip linux-only: HTTPProxy.routingProvider, on the Linux proxy
    func routingContext(for profileID: UUID?) -> LLMRoutingContext? {
        guard let profileID else { return nil }
        return routingContexts.withLockedValue { $0[profileID] }
    }

    /// Whether a request to `host` is served by the on-host engine: the
    /// sentinel always; a real cloud LLM host when the workspace routes it
    /// there (LLMRouting.decide).
    /// The trace's served-by marker for a request to `host` (macOS:
    /// driveTLS's `servedByMarker`, LLMRouting.decide's), nil off the
    /// routing or for a host it doesn't route.
    // @port-skip linux-only: HTTPProxy's servedByMarker, as a question
    func servedByMarker(host: String, port: Int, profileID: UUID?) -> String? {
        guard let ctx = routingContext(for: profileID), LLMRouting.isLLMHost(host) else { return nil }
        return LLMRouting.decide(host: host, port: port, context: ctx, sessionKey: profileID?.uuidString ?? "",
                                 now: Date().timeIntervalSince1970).servedBy
    }

    // @port-skip linux-only: HTTPProxy's `routedBackend == .local`, as a question
    func servedLocally(host: String, port: Int, profileID: UUID?) -> Bool {
        if host.lowercased() == InferenceService.localMitmHost { return true }
        guard let ctx = routingContext(for: profileID), LLMRouting.isLLMHost(host) else { return false }
        return LLMRouting.decide(host: host, port: port, context: ctx, sessionKey: profileID?.uuidString ?? "",
                                 now: Date().timeIntervalSince1970).backend == .local
    }

    /// Claude Code's non-LLM cloud calls under strictly-local routing,
    /// answered with an empty 200 and never sent: its management calls when
    /// Claude itself is local (anything off `/v1/`), and telemetry hosts.
    /// nil: not one of those.
    // @port-skip linux-only: HTTPProxy's local short-circuit (non-LLM calls), on the Linux request chain
    func localShortCircuit(host: String, path: String, profileID: UUID) -> Data? {
        guard let ctx = routingContext(for: profileID), ctx.routing == .local else { return nil }
        let h = host.lowercased()
        let anthropicMgmt = (h == "api.anthropic.com" || h.hasSuffix(".anthropic.com"))
            && !path.hasPrefix("/v1/")
            && ctx.isLocalProviderHost(host)
        let telemetry = ["api.mixpanel.com", "api.statsig.com",
                         "statsig.anthropic.com", "events.statsigapi.net"].contains(h)
            || h.hasSuffix(".sentry.io") || h.hasSuffix(".datadoghq.com")
        guard anthropicMgmt || telemetry else { return nil }
        FileHandle.standardError.write(Data("[mitm] short-circuited non-LLM \(h)\(path) (local routing)\n".utf8))
        let body = "{}"
        return Data(("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                     + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body).utf8)
    }

    /// A turn the on-host engine serves still carries the guest's cloud
    /// auth (a stand-in, or a real key the swap put in): x-api-key always
    /// dropped, and the Authorization replaced by the workspace's own
    /// engine key, unless it already is THIS workspace's per-VM key (the
    /// sentinel path), which is kept.
    // @port-skip linux-only: relayUpstream's local-engine auth swap, on the raw request
    static func engineAuth(_ request: Data, profileID: UUID) -> Data {
        guard let head = SubscriptionAuthRewrite.rawHeaderSection(of: request) else { return request }
        let bearer = SubscriptionAuthRewrite.headerValue("authorization", inHeaderSection: head)
            .map { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : $0 }
        if let bearer, EngineKey.profileID(forKey: bearer) == profileID {
            guard SubscriptionAuthRewrite.headerValue("x-api-key", inHeaderSection: head) != nil else { return request }
            return HTTPRequestFraming.replacingHeaders(request, drop: ["authorization", "x-api-key"],
                                                       add: "Authorization: Bearer \(bearer)")
        }
        return HTTPRequestFraming.replacingHeaders(request, drop: ["authorization", "x-api-key"],
                                                   add: "Authorization: Bearer \(EngineKey.perVM(profileID: profileID))")
    }
}

extension Daemon {
    /// The workspace's routing, pushed to the proxy (macOS: applyRouting):
    /// the global model settings overlaid, and `effectiveModelRouting`, so a
    /// local route with no local agent never reroutes real cloud traffic.
    // @port ACAppDelegate.applyRouting(_: MitmEngine, for: Profile) h=fe02a5822fa68a02 @3b4acf09
    func applyRouting(for raw: Profile) async {
        applyRouting(staged: await stagedProfile(raw))
    }

    /// applyRouting for a profile already overlaid (stagedProfile).
    // @port-skip linux-only: applyRouting's second half, for callers holding the staged profile
    func applyRouting(staged profile: Profile) {
        mitm?.setRouting(profile.effectiveModelRouting, modelLabel: profile.activeModelID ?? "default",
                         localCloudHosts: profile.localProviderCloudHosts, for: profile.id)
    }

    /// `POST /vms/<id>/routing {"mode": cloud|local}`: the workspace's model
    /// routing saved and pushed to the proxy at once. 409 when the VM isn't
    /// running or the mode isn't one.
    // @port ACAppDelegate.automationSetRouting(idOrName: String, mode: String) h=c2937c2ca8547013 @3b4acf09
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onSetRouting h=5ae3d0768405fded @d3ebbda2
    func routingRoute(_ rec: VMRecord, _ body: JSONValue) async -> ControlResponse {
        guard live[rec.id] != nil, var profile = existingProfile(for: rec) else {
            return ControlResponse(409, ["ok": false, "error": .string("VM not found: \(rec.name)")])
        }
        guard let raw = body["mode"]?.stringValue else {
            return ControlResponse(400, ["ok": false, "error": "mode (cloud or local) required"])
        }
        guard let routing = Profile.Routing(rawValue: raw.lowercased()) else {
            return ControlResponse(409, ["ok": false, "error": "Routing must be 'cloud' or 'local'."])
        }
        do {
            if let saved = try ProfileWrites.edit(profile.id, store: profileStore, { $0.modelRouting = routing; return true }) {
                profile = saved
            } else { profile.modelRouting = routing }
        } catch {
            return ControlResponse(409, ["ok": false, "error": .string("couldn't save: \(error.localizedDescription)")])
        }
        // The running session's copies, as macOS updates session.profile: a
        // later edit back is then seen as the change it is.
        liveApplied[rec.id]?.modelRouting = routing
        lastStagedProfiles[rec.id]?.modelRouting = routing
        await applyRouting(for: profile)
        return ControlResponse(200, ["ok": true, "routing": .string(routing.rawValue)])
    }

}
