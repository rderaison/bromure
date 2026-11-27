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
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool, testLoginUser: String?) / case ("GET", "/preferences"): h=135b9ea34619bb62 @f127f8ab
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool, testLoginUser: String?) / case ("PUT", "/preferences"), ("PATCH", "/preferences"): h=f4188d370ef7a6bd @f127f8ab
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool, testLoginUser: String?) / case ("GET", "/models/settings"): h=2694f9914b1a08f4 @f127f8ab
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool, testLoginUser: String?) / case ("PUT", "/models/settings"), ("PATCH", "/models/settings"): h=279aafb685a1b5b9 @f127f8ab
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
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onExportModelSettings h=bd7b730514adb887 @d3ebbda2
    @MainActor
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
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onUpdateModelSettings h=e571c771c47454c3 @d3ebbda2
    @MainActor
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

    /// `POST /models/probe-server {baseURL, apiKey?, scope?, profileId?}`: a
    /// fat client's "Test Connection" for a custom inference server (vLLM,
    /// Ollama, …), run from this server, the machine whose launches will
    /// reach it: the client never contacts that server itself. A failed
    /// probe is still a 200 (the answer is the error).
    // @port ACAutomationServer.route(fd: Int32, method: String, path: String, bodyJSON: [String:Any], acceptGzip: Bool, stateDelta: Bool, testLoginUser: String?) / case ("POST", "/models/probe-server"): h=928f6ba0063c332c @419a8ef59
    // @port ACAppDelegate.wireAutomationCallbacks(into: ACAutomationServer) / server.onProbeEngine h=a83f6b8743f9ca21 @419a8ef59
    func probeEngineRoute(_ body: JSONValue) async -> ControlResponse {
        let doc = (body.foundationObject as? [String: Any]) ?? [:]
        guard let base = doc["baseURL"] as? String, !base.isEmpty else { return .error(400, "Missing 'baseURL'") }
        let r = await Self.probeEngine(base: base, apiKey: doc["apiKey"] as? String, scope: EngineProbeScope(wire: doc))
        return ControlResponse(200, JSONValue(foundation: r) ?? .object([:]))
    }

    /// The probe itself. The client's copy of a stored key is redacted, so a
    /// blank or redacted key means "the key stored for this server" in the
    /// configuration being edited (`scope`), and only for that exact server,
    /// so a client can't send a stored key anywhere else.
    // @port ACAppDelegate.automationProbeEngine(base: String, apiKey: String?, scope: EngineProbeScope) h=78975660cb8db7c1 @419a8ef59
    @MainActor
    static func probeEngine(base raw: String, apiKey: String?,
                            scope: EngineProbeScope = .unspecified) async -> [String: Any] {
        guard let base = Profile.normalizedEngineBase(raw),
              ["http", "https"].contains(base.scheme?.lowercased() ?? "") else {
            return ["ok": false, "error": NSLocalizedString("That isn't a valid server URL.", comment: "engine probe")]
        }
        let key = ModelSettings.isRedactedSecret(apiKey) ? storedEngineKey(for: base, scope: scope) : apiKey
        do {
            let models = try await ExternalEngine.listModels(base: base, apiKey: key)
            return ["ok": true, "models": models]
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }

    /// The API key stored for the custom server at `base` in `scope`'s
    /// configuration (normalized URLs compared), or nil.
    // @port ACAppDelegate.storedEngineKey(for: URL, scope: EngineProbeScope) h=fb30e977a974085e @419a8ef59
    @MainActor
    private static func storedEngineKey(for base: URL, scope: EngineProbeScope) -> String? {
        let store = ProfileStore()
        let candidates = engineKeyCandidates(scope: scope,
                                             global: ModelSettingsStore.shared.settings.localServer,
                                             profiles: store.loadAll(), template: store.loadTemplate())
        return engineKey(for: base, among: candidates)
    }

    /// Where a probe's redacted key is looked up, in order:
    /// - global settings: the global custom server only;
    /// - a workspace: its own custom server (its Models override, then its
    ///   Local Models engine), then the global one if it inherits it (no
    ///   override, or a layered one that doesn't exclude it). A workspace not
    ///   saved yet is the template's copy.
    /// - unspecified (a client older than the scope): every configuration,
    ///   global first.
    /// Two configurations on one server with different keys (tenant keys)
    /// each test their own.
    // @port ACAppDelegate.static engineKeyCandidates(scope: EngineProbeScope, global: LocalServer?, profiles: [Profile], template: Profile) h=1a16851cd1a1c973 @419a8ef59
    nonisolated static func engineKeyCandidates(scope: EngineProbeScope, global: LocalServer?,
                                                profiles: [Profile], template: Profile) -> [(url: String?, key: String?)] {
        func own(_ p: Profile) -> [(url: String?, key: String?)] {
            var c: [(url: String?, key: String?)] = []
            if let ls = p.modelOverride?.settings.localServer { c.append((ls.baseURL, ls.apiKey)) }
            c.append((p.localEngineURL, p.localEngineAPIKey))
            return c
        }
        let inherited: [(url: String?, key: String?)] = global.map { [($0.baseURL, $0.apiKey)] } ?? []
        switch scope {
        case .global:
            return inherited
        case .workspace(let id):
            let p = id.flatMap { id in profiles.first { $0.id == id } } ?? template
            let inherits = p.modelOverride.map { $0.inheritsGlobal && !$0.excludedProviders.contains(.custom) } ?? true
            return own(p) + (inherits ? inherited : [])
        case .unspecified:
            return inherited + (profiles + [template]).flatMap(own)
        }
    }

    /// The first non-blank key whose server URL normalizes to `base`.
    // @port ACAppDelegate.static engineKey(for: URL, among: [(url:String?,key:String?)]) h=7c97763e0f1b3a41 @419a8ef59
    nonisolated static func engineKey(for base: URL, among candidates: [(url: String?, key: String?)]) -> String? {
        for c in candidates {
            guard let k = c.key, !ModelSettings.isRedactedSecret(k),
                  Profile.normalizedEngineBase(c.url)?.absoluteString == base.absoluteString else { continue }
            return k
        }
        return nil
    }
}
