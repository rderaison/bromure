import Foundation

/// The server's subscription sign-ins for a fat client's Preferences →
/// Models (macOS: the automation server's /subscriptions routes and
/// /state's `subscriptions`), over the proxy's stores.
extension Daemon {
    /// `POST /subscriptions/register|forget`; nil for any other path.
    // @port-skip linux-only: the Linux router's share of ACAutomationServer.handleRequest
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool) / case ("POST", "/subscriptions/register"): h=660996cce7a181e6 @f127f8ab
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool) / case ("POST", "/subscriptions/forget"): h=588a794720f01642 @f127f8ab
    func subscriptionsRoute(_ method: String, _ path: String, _ body: JSONValue) async -> ControlResponse? {
        let provider = body["provider"]?.stringValue ?? ""
        let pid = body["profileId"]?.stringValue.flatMap(UUID.init(uuidString:))
        switch (method, path) {
        case ("POST", "/subscriptions/register"):
            // The throwaway machine runs here; the page comes back through
            // /state's pendingRegistration, and the run's id names how it
            // ended in `registrationEnded`. A refusal says why.
            guard !provider.isEmpty else { return .error(400, "Missing 'provider'") }
            let (refused, run) = await MainActor.run { () -> (String?, String?) in
                guard let host = LinuxSessionHost.shared else { return ("registration unavailable", nil) }
                let refused = host.beginRemoteRegistration(provider: provider, profileID: pid?.uuidString)
                return (refused, refused == nil ? RemoteRegistrationBroker.shared.pending?.id.uuidString : nil)
            }
            var reply: [String: JSONValue] = ["ok": .bool(refused == nil), "error": .string(refused ?? "")]
            if let run { reply["registration"] = .string(run) }
            return ControlResponse(refused == nil ? 202 : 409, .object(reply))
        case ("POST", "/subscriptions/forget"):
            guard let p = SubscriptionProvider(rawValue: provider) else { return .error(400, "Missing 'provider'") }
            let ok = await MainActor.run { () -> Bool in
                guard let mitm = self.mitm else { return false }
                Self.forgetSubscription(p, profileID: pid, mitm: mitm)
                return true
            }
            return ControlResponse(ok ? 200 : 400, ["ok": .bool(ok)])
        default:
            return nil
        }
    }

    /// Log a subscription out: with a workspace, the scope in effect for it
    /// (its own sign-in if it has one, else the shared one); without, the
    /// shared one.
    // @port ACAppDelegate.forgetSubscription(_: SubscriptionProvider, profileID: UUID?) h=2b6d62a75938ccc3 @b10aa434
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onForgetSubscription h=e27654dd84afe541 @d3ebbda2
    @MainActor
    static func forgetSubscription(_ provider: SubscriptionProvider, profileID: UUID?, mitm: MitmProxy) {
        switch provider {
        case .claude:
            let s = mitm.claudeStore
            try? s.forget(for: profileID.flatMap { s.hasProfileRecord($0) ? $0 : nil })
        case .codex:
            let s = mitm.codexStore
            try? s.forget(for: profileID.flatMap { s.hasProfileRecord($0) ? $0 : nil })
        case .grok:
            let s = mitm.grokStore
            try? s.forget(for: profileID.flatMap { s.hasProfileRecord($0) ? $0 : nil })
        case .kimi:
            let s = mitm.kimiStore
            try? s.forget(for: profileID.flatMap { s.hasProfileRecord($0) ? $0 : nil })
        }
        FileHandle.standardError.write(Data(
            "[subscription] logged out \(provider.rawValue) (\(profileID.map { "workspace \($0.uuidString.prefix(8))" } ?? "shared"))\n".utf8))
        NotificationCenter.default.post(name: .bromureSubscriptionStoresChanged, object: nil)
    }

    /// `/state`'s `subscriptions`: per agent, when its sign-in was stored,
    /// the re-auth flag and the login's health (never token data), and the
    /// workspaces whose own sign-in shadows the shared one.
    // partial: no per-launch auth notes (launchAuth) on Linux
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onSubscriptionStatus h=7804aacc121a331d @b10aa434
    // partial: health is merged into /state's subscriptions per provider (store.health(for:))
    // @port ACAppDelegate.localSubscriptionHealth(_: ModelProvider, profileID: UUID?) h=9cf74db898ae82eb @d3ebbda2
    @MainActor
    static func subscriptionStatus(mitm: MitmProxy?, profileID pid: UUID? = nil) -> [String: Any] {
        guard let mitm else { return [:] }
        let allProfiles = ProfileStore().loadAll()
        func entry(_ savedAt: Date?, _ reauth: Date?, health: SubscriptionLoginHealth?,
                   hasOwn: (UUID) -> Bool) -> [String: Any]? {
            guard let savedAt else {
                return health?.storeUnreadable == true ? ["storeUnreadable": true] : nil
            }
            var d: [String: Any] = ["registeredAt": savedAt.timeIntervalSince1970]
            if let reauth { d["reauthRequiredAt"] = reauth.timeIntervalSince1970 }
            if let health { d.merge(health.stateJSON) { cur, _ in cur } }
            if let pid {
                d["scope"] = hasOwn(pid) ? "workspace" : "shared"
            } else {
                let overrides = allProfiles.filter { hasOwn($0.id) }.map { $0.id.uuidString }
                if !overrides.isEmpty { d["overrides"] = overrides }
            }
            return d
        }
        var out: [String: Any] = [:]
        if let e = entry(mitm.claudeStore.record(for: pid)?.savedAt, mitm.claudeStore.reauthRequiredAt(for: pid),
                         health: mitm.claudeStore.health(for: pid), hasOwn: mitm.claudeStore.hasProfileRecord) { out["claude"] = e }
        if let e = entry(mitm.codexStore.record(for: pid)?.savedAt, mitm.codexStore.reauthRequiredAt(for: pid),
                         health: mitm.codexStore.health(for: pid), hasOwn: mitm.codexStore.hasProfileRecord) { out["codex"] = e }
        if let e = entry(mitm.grokStore.record(for: pid)?.savedAt, mitm.grokStore.reauthRequiredAt(for: pid),
                         health: mitm.grokStore.health(for: pid), hasOwn: mitm.grokStore.hasProfileRecord) { out["grok"] = e }
        if let e = entry(mitm.kimiStore.record(for: pid)?.savedAt, mitm.kimiStore.reauthRequiredAt(for: pid),
                         health: mitm.kimiStore.health(for: pid), hasOwn: mitm.kimiStore.hasProfileRecord) { out["kimi"] = e }
        // How each subscription agent authenticated at the workspace's last
        // staging: "api_key_fallback" / "sign_in_needed" make a signed-out
        // subscription visible instead of silently billed.
        if let pid, let notes = subscriptionAuthNotes.withLockedValue({ $0[pid] }) {
            for (tool, verdict) in notes { out[tool.rawValue] = Self.withLaunchAuth(out[tool.rawValue], verdict) }
        }
        return out
    }

    /// A subscription entry with its `launchAuth` (macOS's wording).
    // @port-skip linux-only: see subscriptionStatus
    static func withLaunchAuth(_ entry: Any?, _ verdict: Profile.SubscriptionResolution) -> [String: Any] {
        var d = entry as? [String: Any] ?? [:]
        switch verdict {
        case .subscription:   d["launchAuth"] = "subscription"
        case .signInNeeded:   d["launchAuth"] = "sign_in_needed"
        case .apiKeyFallback: d["launchAuth"] = "api_key_fallback"
        }
        return d
    }

    /// `/state`'s `securityTimeline`: the rows the timeline holds, as macOS
    /// mirrors them to a client. The proxy's egress, guardrail and PII events
    /// reach it as on macOS (ProxyPolicy emits them through BACEventEmitter,
    /// which records them here).
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onSecurityTimeline h=b7ea08f0aaba6afa @b10aa434
    @MainActor
    static func securityTimelineRows() -> [Any] { SecurityTimeline.shared.mirrorRows() }
}
