import Foundation

// MARK: - Kimi Code managed-provider provisioning (host side)

/// The `config.toml` the Kimi Code CLI needs before it will start at all:
/// `default_model`, the managed provider and its model aliases. `kimi login`
/// writes it inside the VM as its last step (credential first, then a
/// `/models` round-trip, then the config); a registration captured before
/// that step ran leaves a record with no config, and every session seeded
/// from it dies with "No model configured" / "LLM not set" — the guest never
/// does OAuth, so nothing in it would ever provision the provider.
///
/// This is a port of kimi-code 2.0.x `applyManagedKimiCodeConfig` (+
/// `toModelInfo`, `capabilitiesForModel`, `selectDefaultModel` and the TOML
/// writers `providerToToml` / `modelToToml` / `thinkingToToml` /
/// `servicesToToml`), so the host writes the same file the CLI would, from
/// the same `/models` answer — fetched with the real credential the host
/// already owns. The guest keeps its stand-in token; nothing about auth
/// moves.
public enum KimiProvisioning {
    /// One `/models` entry, as kimi's `toModelInfo` reads it.
    public struct Model: Equatable, Sendable {
        public var id: String
        public var contextLength: Int
        public var supportsReasoning: Bool
        public var supportsImageIn: Bool
        public var supportsVideoIn: Bool
        public var supportsToolUse: Bool
        public var supportsDynamicTools: Bool
        /// "only" | "both" | "no", nil when the server didn't say.
        public var supportsThinkingType: String?
        public var supportEfforts: [String]?
        public var defaultEffort: String?
        public var displayName: String?
        /// "anthropic" | "openai_responses", nil for the default protocol.
        public var modelProtocol: String?

        public init(id: String, contextLength: Int, supportsReasoning: Bool = false,
                    supportsImageIn: Bool = false, supportsVideoIn: Bool = false,
                    supportsToolUse: Bool = true, supportsDynamicTools: Bool = false,
                    supportsThinkingType: String? = nil, supportEfforts: [String]? = nil,
                    defaultEffort: String? = nil, displayName: String? = nil,
                    modelProtocol: String? = nil) {
            self.id = id
            self.contextLength = contextLength
            self.supportsReasoning = supportsReasoning
            self.supportsImageIn = supportsImageIn
            self.supportsVideoIn = supportsVideoIn
            self.supportsToolUse = supportsToolUse
            self.supportsDynamicTools = supportsDynamicTools
            self.supportsThinkingType = supportsThinkingType
            self.supportEfforts = supportEfforts
            self.defaultEffort = defaultEffort
            self.displayName = displayName
            self.modelProtocol = modelProtocol
        }
    }

    public enum ProvisioningError: Error, CustomStringConvertible {
        case malformedModelsResponse
        case badContextLength(String)
        case noModels
        case http(Int)

        public var description: String {
            switch self {
            case .malformedModelsResponse: return "Kimi /models returned an unexpected body"
            case .badContextLength(let id): return "Kimi Code model \"\(id)\" must include a positive context_length"
            case .noModels: return "No models available for Kimi Code"
            case .http(let code): return "Kimi /models failed (HTTP \(code))"
            }
        }
    }

    /// `managed:kimi-code` — the provider name kimi's `/login` registers.
    public static let providerName = "managed:kimi-code"
    /// `kimi-code/<id>` — the alias key of every managed model.
    public static func modelKey(_ modelID: String) -> String { "kimi-code/\(modelID)" }

    /// `/models` → models. Entries without a string id are skipped (kimi
    /// does the same); a non-positive `context_length` is an error (idem).
    public static func models(fromModelsResponse data: Data) throws -> [Model] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = root["data"] as? [Any] else { throw ProvisioningError.malformedModelsResponse }
        var out: [Model] = []
        for raw in items {
            guard let item = raw as? [String: Any], let id = item["id"] as? String, !id.isEmpty else { continue }
            let contextLength: Int
            switch item["context_length"] {
            case let n as Int: contextLength = n
            case let d as Double where d == d.rounded(): contextLength = Int(d)
            case let s as String: contextLength = Int(s) ?? 0
            default: contextLength = 0
            }
            guard contextLength > 0 else { throw ProvisioningError.badContextLength(id) }
            var m = Model(id: id, contextLength: contextLength)
            m.supportsReasoning = bool(item["supports_reasoning"])
            m.supportsImageIn = bool(item["supports_image_in"])
            m.supportsVideoIn = bool(item["supports_video_in"])
            m.supportsToolUse = item["supports_tool_use"] == nil ? true : bool(item["supports_tool_use"])
            m.supportsDynamicTools = (item["supports_dynamic_tools"] as? Bool) == true
            if let t = item["supports_thinking_type"] as? String, ["only", "both", "no"].contains(t) {
                m.supportsThinkingType = t
            }
            if let efforts = item["think_efforts"] as? [String: Any], (efforts["support"] as? Bool) == true {
                let valid = (efforts["valid_efforts"] as? [Any])?.compactMap { $0 as? String }.filter { !$0.isEmpty } ?? []
                m.supportEfforts = valid.isEmpty ? nil : valid
                if let d = efforts["default_effort"] as? String, !d.isEmpty { m.defaultEffort = d }
            }
            if let name = item["display_name"] as? String, !name.isEmpty { m.displayName = name }
            switch item["protocol"] as? String {
            case "anthropic": m.modelProtocol = "anthropic"
            case "response": m.modelProtocol = "openai_responses"
            default: break
            }
            out.append(m)
        }
        return out
    }

    /// kimi's `capabilitiesForModel`, insertion order preserved.
    public static func capabilities(_ m: Model) -> [String]? {
        var caps: [String] = []
        switch m.supportsThinkingType {
        case "only": caps += ["thinking", "always_thinking"]
        case "both": caps.append("thinking")
        case "no": break
        default: if m.supportsReasoning { caps.append("thinking") }
        }
        if m.supportsImageIn { caps.append("image_in") }
        if m.supportsVideoIn { caps.append("video_in") }
        if m.supportsToolUse { caps.append("tool_use") }
        if m.supportsDynamicTools { caps.append("dynamically_loaded_tools") }
        return caps.isEmpty ? nil : caps
    }

    /// The `oauth` block kimi's `managedOAuthRef` persists. `oauth_host` is
    /// left out only for the legacy default slot on the China host (kimi's
    /// `persistedOAuthHost` rule); Bromure's `.ai` registrations always
    /// carry it.
    static func oauthRef(credentialName: String, oauthHost: String) -> [(String, TOMLValue)] {
        let key = "oauth/\(credentialName)"
        var host = oauthHost
        if !host.contains("://") { host = "https://" + host }
        while host.hasSuffix("/") { host.removeLast() }
        var out: [(String, TOMLValue)] = [("storage", .string("file")), ("key", .string(key))]
        if !(key == "oauth/kimi-code" && host.lowercased() == "https://auth.kimi.com") {
            out.append(("oauth_host", .string(host)))
        }
        return out
    }

    /// The config.toml `kimi login` writes for a fresh install: the first
    /// `/models` entry becomes `default_model`, `thinking.enabled` follows
    /// its thinking type (forced on for "only", off for "no", else whether
    /// it reasons at all), and the managed search/fetch services point at
    /// the same base with the same oauth ref.
    public static func configTOML(models: [Model], baseURL: String,
                                  credentialName: String, oauthHost: String) throws -> String {
        guard let first = models.first else { throw ProvisioningError.noModels }
        for m in models where m.contextLength <= 0 { throw ProvisioningError.badContextLength(m.id) }
        var base = baseURL
        while base.hasSuffix("/") { base.removeLast() }
        let oauth = oauthRef(credentialName: credentialName, oauthHost: oauthHost)
        let thinking: Bool
        switch first.supportsThinkingType {
        case "only": thinking = true
        case "no": thinking = false
        default: thinking = first.supportsReasoning
        }

        var out = ""
        out += "default_model = \(TOMLValue.string(modelKey(first.id)).rendered)\n\n"
        out += "[providers.\(tomlKey(providerName))]\n"
        out += "type = \"kimi\"\n"
        out += "base_url = \(TOMLValue.string(base).rendered)\n"
        out += "api_key = \"\"\n\n"
        out += "[providers.\(tomlKey(providerName)).oauth]\n"
        for (k, v) in oauth { out += "\(k) = \(v.rendered)\n" }
        out += "\n"
        for m in models {
            out += "[models.\(tomlKey(modelKey(m.id)))]\n"
            out += "provider = \(TOMLValue.string(providerName).rendered)\n"
            out += "model = \(TOMLValue.string(m.id).rendered)\n"
            out += "max_context_size = \(m.contextLength)\n"
            if let caps = capabilities(m) { out += "capabilities = \(TOMLValue.array(caps.map(TOMLValue.string)).rendered)\n" }
            if let name = m.displayName { out += "display_name = \(TOMLValue.string(name).rendered)\n" }
            if let efforts = m.supportEfforts { out += "support_efforts = \(TOMLValue.array(efforts.map(TOMLValue.string)).rendered)\n" }
            if let effort = m.defaultEffort { out += "default_effort = \(TOMLValue.string(effort).rendered)\n" }
            if let proto = m.modelProtocol {
                out += "protocol = \(TOMLValue.string(proto).rendered)\n"
                if proto == "anthropic" {
                    out += "beta_api = true\n"
                    let caps = capabilities(m) ?? []
                    if caps.contains("thinking") || caps.contains("always_thinking") { out += "adaptive_thinking = true\n" }
                }
            }
            out += "\n"
        }
        out += "[thinking]\nenabled = \(thinking)\n\n"
        for service in ["moonshot_search", "moonshot_fetch"] {
            let path = service == "moonshot_search" ? "search" : "fetch"
            out += "[services.\(service)]\n"
            out += "base_url = \(TOMLValue.string("\(base)/\(path)").rendered)\n"
            out += "api_key = \"\"\n\n"
            out += "[services.\(service).oauth]\n"
            for (k, v) in oauth { out += "\(k) = \(v.rendered)\n" }
            out += "\n"
        }
        return out
    }

    /// A TOML key: bare when it can be, quoted otherwise (`"managed:kimi-code"`).
    static func tomlKey(_ s: String) -> String {
        let bare = !s.isEmpty && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
        return bare ? s : TOMLValue.string(s).rendered
    }

    enum TOMLValue {
        case string(String)
        case array([TOMLValue])

        var rendered: String {
            switch self {
            case .string(let s):
                var out = "\""
                for ch in s.unicodeScalars {
                    switch ch {
                    case "\"": out += "\\\""
                    case "\\": out += "\\\\"
                    case "\n": out += "\\n"
                    case "\r": out += "\\r"
                    case "\t": out += "\\t"
                    default:
                        if ch.value < 0x20 || ch.value == 0x7F {
                            out += String(format: "\\u%04X", ch.value)
                        } else {
                            out.unicodeScalars.append(ch)
                        }
                    }
                }
                return out + "\""
            case .array(let items):
                return "[" + items.map(\.rendered).joined(separator: ", ") + "]"
            }
        }
    }

    private static func bool(_ v: Any?) -> Bool {
        switch v {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return !s.isEmpty
        default: return v != nil
        }
    }
}

/// Fills in a Kimi record's `configTOML` from `/models` when registration
/// didn't capture one — so a seeded session always has a provider and a
/// default model, whatever the capture timing was. One fetch per credential
/// at a time; a failure is logged and leaves the record as it was, to be
/// retried on the next boot.
public actor KimiProvisioner {
    private let store: KimiSubscriptionStore
    private let refresher: KimiSubscriptionRefresher
    private var inFlight: [String: Task<Bool, Never>] = [:]

    public init(store: KimiSubscriptionStore, refresher: KimiSubscriptionRefresher) {
        self.store = store
        self.refresher = refresher
    }

    /// True when `record(for:)` for this profile carries the managed provider
    /// (nothing to do), false when there's no record at all.
    public nonisolated func isProvisioned(for profileID: UUID?) -> Bool {
        guard let r = store.record(for: profileID) else { return false }
        return Self.isProvisioned(r.configTOML)
    }

    public nonisolated static func isProvisioned(_ toml: String?) -> Bool {
        guard let toml, !toml.isEmpty else { return false }
        return toml.contains(KimiProvisioning.providerName) && toml.contains("default_model")
    }

    /// Ensure the record behind `profileID` has a provisioned config. Returns
    /// whether it does once this returns.
    @discardableResult
    public func ensureProvisioned(for profileID: UUID?) async -> Bool {
        guard let record = store.record(for: profileID) else { return false }
        if Self.isProvisioned(record.configTOML) { return true }
        // The scope key is the credential itself: a per-profile override
        // provisions on its own, profiles sharing the default share one fetch.
        let key = record.credentialName + "|" + String(record.refreshToken.hashValue)
        if let running = inFlight[key] { return await running.value }
        let task = Task<Bool, Never> { [store, refresher] in
            do {
                let token = try await refresher.accessToken(for: profileID)
                let toml = try await Self.provision(token: token, credentialName: record.credentialName)
                guard var fresh = store.record(for: profileID) else { return false }
                if Self.isProvisioned(fresh.configTOML) { return true }   // raced a capture
                fresh.configTOML = toml
                try store.update(fresh, for: profileID)
                FileHandle.standardError.write(Data(
                    "[kimi] provisioned managed config from /models (\(record.credentialName))\n".utf8))
                return true
            } catch {
                FileHandle.standardError.write(Data(
                    "[kimi] provisioning failed — the session will lack a default model: \(error)\n".utf8))
                return false
            }
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return await task.value
    }

    /// `GET <base>/models` with the real bearer → the config kimi would write.
    static func provision(token: String, credentialName: String) async throws -> String {
        var req = URLRequest(url: URL(string: KimiRegion.baseURL + "/models")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 30
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw KimiProvisioning.ProvisioningError.malformedModelsResponse
        }
        guard http.statusCode == 200 else { throw KimiProvisioning.ProvisioningError.http(http.statusCode) }
        let models = try KimiProvisioning.models(fromModelsResponse: data)
        return try KimiProvisioning.configTOML(
            models: models, baseURL: KimiRegion.baseURL,
            credentialName: credentialName, oauthHost: KimiRegion.oauthHost)
    }
}
