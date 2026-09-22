import Foundation
#if canImport(Combine)
import Combine
#endif

/// The single, app-wide `ModelSettings` — loaded once at launch, edited in the
/// Models preferences pane, and read by every session's launch staging + the
/// proxy. Persisted encrypted (it holds provider API keys) next to the profile
/// template at `~/Library/Application Support/BromureAC/models.enc`, using the
/// same AES-GCM vault as `secrets.enc`.
///
/// Global by design: a workspace picks *which* agent to run, but the models and
/// credentials all come from here, so every agent is configured everywhere.
@MainActor
public final class ModelSettingsStore: ObservableObject {
    public static let shared = ModelSettingsStore()

    @Published public var settings: ModelSettings

    private let url: URL

    init(url: URL? = nil) {
        let resolved = url ?? Self.defaultURL
        self.url = resolved
        self.settings = Self.load(resolved) ?? ModelSettings()
    }

    static var defaultURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("BromureAC", isDirectory: true)
            .appendingPathComponent("models.enc")
    }

    private static func load(_ url: URL) -> ModelSettings? {
        guard let cipher = try? Data(contentsOf: url),
              let plain = try? SecretsVault.decrypt(cipher),
              let s = try? JSONDecoder().decode(ModelSettings.self, from: plain)
        else { return nil }
        return s
    }

    /// Persist the current settings (encrypted). Failures are logged, not fatal.
    public func save() {
        do {
            let data = try JSONEncoder().encode(settings)
            let cipher = try SecretsVault.encrypt(data)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try cipher.write(to: url, options: .atomic)
        } catch {
            InferenceLog.shared.record("[models] settings save failed: \(error)")
        }
    }

    /// Mutate + persist in one call (the SwiftUI edit path).
    public func update(_ mutate: (inout ModelSettings) -> Void) {
        mutate(&settings)
        save()
    }

    /// Reload from disk, discarding unsaved in-memory changes.
    public func reload() {
        settings = Self.load(url) ?? ModelSettings()
    }

    // MARK: Provider convenience (register / clear a credential in place)

    public func setProvider(_ provider: ModelProvider,
                            apiKey: String? = nil,
                            useSubscription: Bool = false,
                            baseURL: String? = nil) {
        update { s in
            var creds = s.providers.filter { $0.provider != provider }
            creds.append(ProviderCredential(provider: provider, apiKey: apiKey,
                                            useSubscription: useSubscription, baseURL: baseURL))
            s.providers = creds
        }
    }

    public func removeProvider(_ provider: ModelProvider) {
        update { s in s.providers.removeAll { $0.provider == provider } }
    }

    /// Set (or clear) the DEFAULT model for a tier.
    public func setTier(_ tier: ModelTier, _ ref: ModelRef?) {
        update { s in s.tiers[tier] = ref }
    }

    /// Set (or clear) a tier's model for one agent (nil `agent` = the default).
    /// Clearing an agent override makes that tier inherit the default again.
    public func setTier(_ tier: ModelTier, _ ref: ModelRef?, for agent: ModelAgent?) {
        guard let agent else { setTier(tier, ref); return }
        update { s in
            var t = s.agentTiers[agent] ?? [:]
            t[tier] = ref
            if t.isEmpty { s.agentTiers[agent] = nil } else { s.agentTiers[agent] = t }
        }
    }

    /// Drop every override for an agent so it inherits the default entirely.
    public func resetAgentOverrides(_ agent: ModelAgent) {
        update { s in s.agentTiers[agent] = nil }
    }

    /// The settings a workspace actually runs with: the global settings, or
    /// its override resolved over them — layered (its own providers, keys,
    /// subscriptions and model choices on top of the global ones, exclusions
    /// applied) or standalone (its own complete configuration).
    public func effective(for profile: Profile) -> ModelSettings {
        profile.modelOverride?.resolved(over: settings) ?? settings
    }
}
