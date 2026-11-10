import Foundation

/// The server's preferences, for a fat client's Preferences window (macOS:
/// the automation server's /preferences and /models/settings routes and the
/// app delegate's callbacks behind them): the template new workspaces start
/// from, and the global model settings. Secrets leave redacted and come back
/// merged: a blank or redacted field keeps the stored value.
extension Daemon {
    /// `GET|PUT|PATCH /preferences`, `GET|PUT|PATCH /models/settings`; nil
    /// for any other path.
    // @port-skip linux-only: the Linux router's share of ACAutomationServer.handleRequest
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool) / case ("GET", "/preferences"): h=135b9ea34619bb62 @f127f8ab
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool) / case ("PUT", "/preferences"), ("PATCH", "/preferences"): h=f4188d370ef7a6bd @f127f8ab
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool) / case ("GET", "/models/settings"): h=2694f9914b1a08f4 @f127f8ab
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool) / case ("PUT", "/models/settings"), ("PATCH", "/models/settings"): h=279aafb685a1b5b9 @f127f8ab
    func preferencesRoute(_ method: String, _ path: String, _ body: JSONValue) async -> ControlResponse? {
        let doc = (body.foundationObject as? [String: Any]) ?? [:]
        switch (method, path) {
        case ("GET", "/preferences"):
            guard let d = Self.templateExport(), let v = JSONValue(foundation: d) else { return .error(503, "unavailable") }
            return ControlResponse(200, v)
        case ("PUT", "/preferences"), ("PATCH", "/preferences"):
            return Self.okResponse(Self.updateTemplate(doc))
        case ("GET", "/models/settings"):
            let d: [String: Any]? = await MainActor.run { Self.modelSettingsExport() }
            guard let d, let v = JSONValue(foundation: d) else { return .error(503, "unavailable") }
            return ControlResponse(200, v)
        case ("PUT", "/models/settings"), ("PATCH", "/models/settings"):
            let r = await MainActor.run { Self.updateModelSettings(doc) }
            // The running workspaces follow (macOS: the settings publisher's
            // refreshModelsForRunningWorkspaces).
            if r["ok"] as? Bool == true { Task { await self.refreshModelsForRunningWorkspaces() } }
            return Self.okResponse(r)
        default:
            return nil
        }
    }

    // @port-skip linux-only: daemon route plumbing
    private static func okResponse(_ r: [String: Any]) -> ControlResponse {
        ControlResponse((r["ok"] as? Bool) == true ? 200 : 400, JSONValue(foundation: r) ?? .object([:]))
    }

    /// The preferences template, secrets blanked (model keys as the redaction
    /// stand-in, so a provider still reads as configured).
    // @port ACAppDelegate.automationTemplateExport() h=8a71f3508c4ba767 @b10aa434
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onExportTemplate h=0fc64e04425f1de9 @d3ebbda2
    static func templateExport() -> [String: Any]? {
        let p = ProfileStore().loadTemplate()
        var stripped = p
        _ = ProfileSecrets.extract(stripping: &stripped)   // blank all secrets
        stripped.kubeconfigs = p.kubeconfigs.map { $0.redactedIdentity() }
        markRedactedModelKeys(&stripped, from: p)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(stripped),
              var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        dict["_secretsRedacted"] = true
        dict["configuredCredentialRefs"] = p.configuredCredentials().map(\.id)
        return dict
    }

    /// A workspace's own model-provider keys leave as the redaction stand-in
    /// rather than blank (the remote Models pane shows them as overridden).
    // @port ACAppDelegate.static markRedactedModelKeys(_: inoutProfile, from: Profile) h=4431635cffcfd7e0 @b10aa434
    static func markRedactedModelKeys(_ stripped: inout Profile, from real: Profile) {
        guard var o = stripped.modelOverride, let realO = real.modelOverride else { return }
        for i in o.settings.providers.indices {
            let prov = o.settings.providers[i].provider
            if !(realO.settings.credential(prov)?.apiKey ?? "").isEmpty {
                o.settings.providers[i].apiKey = ModelSettings.redactedSecret
            }
        }
        if o.settings.localServer != nil, !(realO.settings.localServer?.apiKey ?? "").isEmpty {
            o.settings.localServer?.apiKey = ModelSettings.redactedSecret
        }
        stripped.modelOverride = o
    }

    /// Replace the template from a round-tripped document: blank secrets
    /// keep their stored value, typed ones replace it.
    // @port ACAppDelegate.automationUpdateTemplate(_: [String:Any]) h=4531169f2850d552 @b10aa434
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onUpdateTemplate h=cd1c109004b353a4 @d3ebbda2
    static func updateTemplate(_ rawDoc: [String: Any]) -> [String: Any] {
        var doc = rawDoc
        doc.removeValue(forKey: "_secretsRedacted")
        doc.removeValue(forKey: "generateSSH")
        doc.removeValue(forKey: "configuredCredentialRefs")
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? JSONSerialization.data(withJSONObject: doc),
              var incoming = try? dec.decode(Profile.self, from: data) else {
            return ["ok": false, "error": "Invalid preferences document"]
        }
        let store = ProfileStore()
        var existing = store.loadTemplate()
        let existingSecrets = ProfileSecrets.extract(stripping: &existing)
        var incomingCopy = incoming
        let incomingSecrets = ProfileSecrets.extract(stripping: &incomingCopy)
        var merged = existingSecrets
        merged.overlay(with: incomingSecrets)
        merged.apply(to: &incoming)
        // No VM runs on the template: it mints nothing.
        incoming.mintedCredentials = []
        // Only an explicitly sent kubeconfigs array is authoritative.
        if let sentKube = rawDoc["kubeconfigs"] as? [[String: Any]] {
            let keep = Set(sentKube.compactMap { ($0["id"] as? String).flatMap { UUID(uuidString: $0) } })
            incoming.kubeconfigs.removeAll { !keep.contains($0.id) }
        }
        do {
            try store.saveTemplate(incoming)
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
        return ["ok": true]
    }

    /// The global model settings, keys redacted.
    // @port ACAppDelegate.automationModelSettingsExport() h=3279f21655aa4db6 @b10aa434
    @MainActor
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onExportModelSettings h=bd7b730514adb887 @d3ebbda2
    static func modelSettingsExport() -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(ModelSettingsStore.shared.settings.redacted()),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }
        return dict
    }

    /// Replace the global model settings: a blank or redacted key keeps the
    /// stored one, a typed key replaces it.
    // @port ACAppDelegate.automationUpdateModelSettings(_: [String:Any]) h=2db24321b9f16274 @b10aa434
    @MainActor
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onUpdateModelSettings h=e571c771c47454c3 @d3ebbda2
    static func updateModelSettings(_ doc: [String: Any]) -> [String: Any] {
        guard let data = try? JSONSerialization.data(withJSONObject: doc),
              let incoming = try? JSONDecoder().decode(ModelSettings.self, from: data) else {
            return ["ok": false, "error": "Invalid model settings document"]
        }
        let store = ModelSettingsStore.shared
        var merged = incoming.restoringSecrets(from: store.settings)
        // A client older than the environment field sends none: keep ours.
        if doc["agentEnvironment"] == nil { merged.agentEnvironment = store.settings.agentEnvironment }
        store.update { $0 = merged }
        return ["ok": true]
    }
}
