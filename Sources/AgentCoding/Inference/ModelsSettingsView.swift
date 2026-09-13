#if os(macOS)
import SwiftUI

// MARK: - The "Models" preferences pane
//
// One global place, laid out as a PROVIDERS → AGENTS mapping board:
//   • left — the sources: cloud providers (register once: subscription sign-in
//     or API key) and the local route (a custom OpenAI-compatible server, the
//     recommended option, plus on-device models as the lazy backup);
//   • right — the agents: pick a model per capability tier (small/medium/large)
//     for a "Default" that every agent inherits, or override it for one agent.
//
// Everything binds to the app-wide `ModelSettingsStore.shared`.

/// Host hooks for subscription sign-in, injected by the editor (which owns the
/// throwaway-VM registration flow). nil in previews / when unavailable.
struct ModelsSubscriptionHooks {
    var savedAt: (ModelProvider) -> Date?
    var register: (ModelProvider) -> Void
    var forget: (ModelProvider) -> Void
}

struct ModelsSettingsView: View {
    @ObservedObject var store = ModelSettingsStore.shared
    var subscription: ModelsSubscriptionHooks? = nil

    /// nil = the "Default" that every agent inherits; a value = that agent's
    /// overrides.
    @State private var selectedAgent: ModelAgent? = nil

    @State private var localServerModels: [String] = []
    @State private var localServerProbe: SourceProbe = .idle
    @State private var catalogTick = 0
    @State private var showOnDevice = false
    @State private var customIDTier: ModelTier?
    @State private var pendingCustomSource: ModelRef.Source?
    @State private var customIDText = ""

    private let downloads = ModelDownloadManager.shared
    private var hostGB: Int { HostMemory.unifiedMemoryGB() }

    private enum SourceProbe: Equatable { case idle, probing, ok(Int), failed(String) }

    // Providers shown in the UI — Custom is intentionally omitted: a custom
    // OpenAI-compatible endpoint is configured once, in the Local server card.
    private let uiProviders: [ModelProvider] =
        ModelProvider.allCases.filter { $0 != .custom }

    var body: some View {
        let _ = catalogTick
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                HStack(alignment: .top, spacing: 16) {
                    sourcesColumn.frame(maxWidth: .infinity, alignment: .top)
                    Image(systemName: "arrow.right")
                        .font(.title3).foregroundStyle(.tertiary)
                        .padding(.top, 60)
                    agentsColumn.frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .padding(20)
        }
        .onAppear { if store.settings.localServer != nil { probeLocalServer() } }
        .alert("Model id", isPresented: customIDAlertBinding) {
            TextField("model-id", text: $customIDText)
            Button("Cancel", role: .cancel) { customIDTier = nil }
            Button("Use") {
                if let t = customIDTier, let src = pendingCustomSource {
                    let id = customIDText.trimmingCharacters(in: .whitespaces)
                    if !id.isEmpty { assign(t, source: src, modelID: id) }
                }
                customIDTier = nil
            }
        } message: {
            Text("The id exactly as the backend names it (e.g. claude-opus-5, glm-5.3-flash, qwen3-coder).")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Models").font(.title2.bold())
            Text("Register your providers once, then map a model to each agent. Every agent is configured everywhere — a workspace only chooses which one to run.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Left column — sources

    private var sourcesColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(uiProviders, id: \.self) { p in
                        ProviderRow(provider: p,
                                    credential: store.settings.credential(p),
                                    subscription: subscription,
                                    onChange: { updateCredential(p, $0) })
                        if p != uiProviders.last { Divider() }
                    }
                }
            } label: {
                Label("Providers", systemImage: "cloud.fill").font(.headline)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    localServerCard
                    Divider()
                    onDeviceCard
                }
            } label: {
                Label("Local", systemImage: "cpu.fill").font(.headline)
            }
        }
    }

    @ViewBuilder private var localServerCard: some View {
        Toggle(isOn: localServerEnabled) {
            Text("Custom server").font(.callout.weight(.medium))
            Text("Recommended — any OpenAI-compatible server (vLLM, Ollama, LM Studio, llama-server), on this Mac or another. Bromure translates each agent's native API in between.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if store.settings.localServer != nil {
            TextField("Server URL", text: localServerURL,
                      prompt: Text(verbatim: "http://127.0.0.1:11434/v1"))
                .textFieldStyle(.roundedBorder)
            SecureField("API key (optional)", text: localServerKey)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: 8) {
                Button("Test Connection") { probeLocalServer() }
                    .controlSize(.small)
                    .disabled(URL(string: store.settings.localServer?.baseURL ?? "") == nil
                              || localServerProbe == .probing)
                switch localServerProbe {
                case .idle:    EmptyView()
                case .probing: ProgressView().controlSize(.small)
                case .ok(let n):
                    Label(String(format: NSLocalizedString("%d model(s)", comment: "probe ok"), n),
                          systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                case .failed(let why):
                    Label(why, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red).lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder private var onDeviceCard: some View {
        DisclosureGroup(isExpanded: $showOnDevice) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(CatalogStore.shared.effective().sortedForDisplay) { model in
                    onDeviceRow(model)
                }
            }
            .padding(.top, 4)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text("On-device models").font(.callout.weight(.medium))
                Text("The lazy backup — MLX models run in-process on this Mac (\(hostGB) GB). Nothing to install.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func onDeviceRow(_ model: CatalogModel) -> some View {
        let fit = RAMFitGate.fit(model: model, hostUnifiedMemGB: hostGB)
        let wontFit = (fit == .wontFit)
        let state = downloads.state(repo: model.repo)
        let installed = (state == nil) && CatalogStore.shared.isInstalled(repo: model.repo)
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.displayName).font(.callout)
                HStack(spacing: 6) {
                    Text(fit.badge)
                        .foregroundStyle(fit == .fits ? .green : (fit == .tight ? .orange : .secondary))
                    Text("· \(Int(model.downloadGB)) GB")
                    if model.toolCalling == .verified {
                        Label("tools", systemImage: "checkmark.seal.fill")
                            .labelStyle(.titleAndIcon).foregroundStyle(.secondary)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            onDeviceAction(model: model, state: state, installed: installed, wontFit: wontFit)
        }
        .opacity(wontFit ? 0.45 : 1)
        .padding(.vertical, 2)
    }

    @ViewBuilder private func onDeviceAction(model: CatalogModel,
                                             state: ModelDownloadManager.State?,
                                             installed: Bool, wontFit: Bool) -> some View {
        switch state {
        case .downloading(let frac, let label):
            HStack(spacing: 6) {
                ProgressView(value: frac).progressViewStyle(.linear).frame(width: 80)
                Text(label).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                Button { downloads.cancel(repo: model.repo) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.borderless)
            }
        case .interrupted:
            Button("Resume") { startDownload(model) }.controlSize(.small)
        case .failed(let msg):
            Button("Retry") { startDownload(model) }.controlSize(.small).help(msg)
        case nil:
            if installed {
                Menu {
                    Button("Remove", role: .destructive) { removeModel(model) }
                } label: {
                    Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }.platformBorderlessMenuStyle().fixedSize()
            } else {
                Button("Download") { startDownload(model) }.controlSize(.small).disabled(wontFit)
            }
        }
    }

    // MARK: Right column — agents

    private var agentsColumn: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: $selectedAgent) {
                    Text("Default").tag(ModelAgent?.none)
                    Divider()
                    ForEach(ModelAgent.allCases, id: \.self) { a in
                        Text(a.displayName).tag(ModelAgent?.some(a))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                if let agent = selectedAgent {
                    Text("Overrides the Default for \(agent.displayName) only. Unset tiers inherit the Default.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Applies to every agent unless overridden below.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                ForEach(tiersToShow, id: \.self) { tier in
                    tierRow(tier)
                    if tier != tiersToShow.last { Divider() }
                }

                if let agent = selectedAgent, !(store.settings.agentTiers[agent]?.isEmpty ?? true) {
                    Button("Reset \(agent.displayName) to Default") {
                        store.resetAgentOverrides(agent)
                    }
                    .buttonStyle(.borderless).controlSize(.small).padding(.top, 2)
                }
            }
        } label: {
            Label("Agents", systemImage: "sparkles").font(.headline)
        }
    }

    /// Claude Code (and the Default) show all three tiers; every other agent is
    /// single-model, so only Medium.
    private var tiersToShow: [ModelTier] {
        let showAll = selectedAgent == nil || (selectedAgent?.usesAllTiers ?? false)
        return showAll ? [.large, .medium, .small] : [.medium]
    }

    @ViewBuilder private func tierRow(_ tier: ModelTier) -> some View {
        let explicit = explicitRef(tier)             // set at THIS level (agent/default)
        let effective = effectiveRef(tier)           // what actually applies (may be inherited)
        let inherited = (selectedAgent != nil) && explicit == nil && effective != nil

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(tierLabel(tier)).font(.body.weight(.medium))
                    if selectedAgent == nil || selectedAgent?.usesAllTiers == true {
                        Text("≈ \(tier.claudeTierHint)")
                            .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 92, alignment: .leading)

                tierPicker(tier, current: effective, inherited: inherited)
                Spacer()
                if explicit != nil {
                    Button { assignRef(tier, nil) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                    .help(selectedAgent == nil ? "Clear this tier" : "Clear override (inherit Default)")
                }
            }
            if let explicit { capabilitiesEditor(tier, ref: explicit) }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func tierPicker(_ tier: ModelTier, current: ModelRef?, inherited: Bool) -> some View {
        Menu {
            ForEach(usableProviders, id: \.self) { p in
                Menu(p.displayName) {
                    ForEach(ProviderModels.suggestions(for: p, tier: tier), id: \.self) { id in
                        Button(id) { assign(tier, source: .provider(p), modelID: id) }
                    }
                    Divider()
                    Button("Custom id…") { beginCustomID(tier, source: .provider(p)) }
                }
            }
            if store.settings.localServer != nil {
                Menu("Custom server") {
                    if localServerModels.isEmpty {
                        Text("Test the connection to list models").foregroundStyle(.secondary)
                    }
                    ForEach(localServerModels, id: \.self) { id in
                        Button(id) { assign(tier, source: .localServer, modelID: id) }
                    }
                    Divider()
                    Button("Custom id…") { beginCustomID(tier, source: .localServer) }
                }
            }
            let installed = installedOnDevice
            if !installed.isEmpty {
                Menu("On-device") {
                    ForEach(installed) { m in
                        Button(m.displayName) { assign(tier, source: .localRun(catalogID: m.id), modelID: m.id) }
                    }
                }
            }
            if selectedAgent != nil, explicitRef(tier) != nil {
                Divider()
                Button("Use Default") { assignRef(tier, nil) }
            }
        } label: {
            modelChip(current, inherited: inherited)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// A color-coded chip naming the model + its source.
    @ViewBuilder private func modelChip(_ ref: ModelRef?, inherited: Bool) -> some View {
        let color = ref.map { sourceColor($0.source) } ?? .secondary
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(ref?.modelID ?? "Choose a model")
                .foregroundStyle(ref == nil ? Color.secondary : Color.primary)
                .lineLimit(1)
            if inherited {
                Text("· inherited").font(.caption2).foregroundStyle(.tertiary)
            }
            Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(0.25)))
    }

    // MARK: Capabilities editor (per shown ref)

    @ViewBuilder private func capabilitiesEditor(_ tier: ModelTier, ref: ModelRef) -> some View {
        let caps = ref.capabilities
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                Text("Context").font(.caption).foregroundStyle(.secondary)
                TextField("auto", text: contextBinding(tier), prompt: Text("auto"))
                    .frame(width: 54).textFieldStyle(.roundedBorder).font(.caption.monospacedDigit())
                Text("K").font(.caption2).foregroundStyle(.tertiary)
            }
            Toggle("Reasoning", isOn: boolCapBinding(tier, \.reasoning)).toggleStyle(.checkbox).font(.caption)
            Toggle("Images", isOn: inputBinding(tier, .image)).toggleStyle(.checkbox).font(.caption)
            if ref.capabilitiesOverridden {
                Button("Re-fetch") { probeCapabilities(tier, force: true) }
                    .buttonStyle(.borderless).controlSize(.small)
            } else if caps.isKnown {
                Text("from server").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 102)
    }

    // MARK: Derived

    private var usableProviders: [ModelProvider] {
        uiProviders.filter { store.settings.credential($0)?.isUsable ?? false }
    }
    private var installedOnDevice: [CatalogModel] {
        _ = catalogTick
        return CatalogStore.shared.effective().sortedForDisplay
            .filter { CatalogStore.shared.isInstalled(repo: $0.repo) }
    }
    /// The ref set at the CURRENT selection level (agent override, or default).
    private func explicitRef(_ tier: ModelTier) -> ModelRef? {
        if let a = selectedAgent { return store.settings.agentTiers[a]?[tier] }
        return store.settings.tiers[tier]
    }
    /// What actually applies for the current selection (may be inherited).
    private func effectiveRef(_ tier: ModelTier) -> ModelRef? {
        if let a = selectedAgent { return store.settings.ref(for: a, tier: tier) }
        return store.settings.tiers[tier]
    }
    private func tierLabel(_ tier: ModelTier) -> String {
        (selectedAgent?.usesAllTiers == false) ? "Model" : tier.displayName
    }

    // MARK: Mutations (agent-aware)

    private func updateCredential(_ p: ModelProvider, _ cred: ProviderCredential?) {
        store.update { s in
            s.providers.removeAll { $0.provider == p }
            if let cred, cred.isUsable { s.providers.append(cred) }
        }
    }

    private func assign(_ tier: ModelTier, source: ModelRef.Source, modelID: String) {
        let existing = explicitRef(tier)
        var ref = ModelRef(source: source, modelID: modelID)
        if let existing, existing.source == source, existing.modelID == modelID,
           existing.capabilitiesOverridden { ref = existing }
        assignRef(tier, ref)
        if !ref.capabilitiesOverridden { probeCapabilities(tier, force: false) }
    }

    private func assignRef(_ tier: ModelTier, _ ref: ModelRef?) {
        store.setTier(tier, ref, for: selectedAgent)
    }

    private func startDownload(_ model: CatalogModel) {
        downloads.start(repo: model.repo, totalBytes: Int64(model.downloadGB * 1_000_000_000))
    }
    private func removeModel(_ model: CatalogModel) {
        do { try CatalogStore.shared.removeInstalled(repo: model.repo) }
        catch { InferenceLog.shared.record("[models] remove \(model.repo) failed: \(error)") }
        store.update { s in
            func drop(_ t: inout [ModelTier: ModelRef]) {
                for (tier, r) in t { if case .localRun(let id) = r.source, id == model.id { t[tier] = nil } }
            }
            drop(&s.tiers)
            for a in s.agentTiers.keys { var t = s.agentTiers[a]!; drop(&t); s.agentTiers[a] = t.isEmpty ? nil : t }
        }
        catalogTick += 1
    }

    private func probeCapabilities(_ tier: ModelTier, force: Bool) {
        guard let ref = explicitRef(tier) else { return }
        if ref.capabilitiesOverridden && !force { return }
        switch ref.source {
        case .localRun(let cid):
            if let m = CatalogStore.shared.resolve(cid) {
                var caps = ModelCapabilities()
                caps.contextWindow = m.context
                caps.reasoning = (m.reasoningParser != nil)
                caps.inputs = m.tags.contains("vision") ? [.text, .image] : [.text]
                applyProbed(caps, to: tier)
            }
        case .localServer:
            guard let s = store.settings.localServer, let base = URL(string: s.baseURL) else { return }
            let key = s.apiKey, model = ref.modelID
            Task {
                let meta = await ExternalEngine.modelMeta(base: base, apiKey: key, model: model)
                await MainActor.run { applyProbed(capabilities(from: meta), to: tier) }
            }
        case .provider:
            if let caps = ProviderModels.capabilities(for: ref.modelID) { applyProbed(caps, to: tier) }
        }
    }
    private func capabilities(from meta: ExternalEngine.ModelMeta?) -> ModelCapabilities {
        var caps = ModelCapabilities()
        guard let meta else { return caps }
        caps.contextWindow = meta.context
        caps.reasoning = meta.thinking
        if let vision = meta.vision { caps.inputs = vision ? [.text, .image] : [.text] }
        return caps
    }
    private func applyProbed(_ caps: ModelCapabilities, to tier: ModelTier) {
        guard var ref = explicitRef(tier), !ref.capabilitiesOverridden else { return }
        ref.capabilities = caps
        assignRef(tier, ref)
    }

    private func probeLocalServer() {
        guard let s = store.settings.localServer, let base = URL(string: s.baseURL) else { return }
        localServerProbe = .probing
        let key = s.apiKey
        Task {
            do {
                let models = try await ExternalEngine.listModels(base: base, apiKey: key)
                await MainActor.run { localServerModels = models; localServerProbe = .ok(models.count) }
            } catch {
                await MainActor.run { localServerModels = []; localServerProbe = .failed(error.localizedDescription) }
            }
        }
    }

    // MARK: Custom-id prompt

    private func beginCustomID(_ tier: ModelTier, source: ModelRef.Source) {
        pendingCustomSource = source
        customIDText = explicitRef(tier)?.modelID ?? ""
        customIDTier = tier
    }
    private var customIDAlertBinding: Binding<Bool> {
        Binding(get: { customIDTier != nil }, set: { if !$0 { customIDTier = nil } })
    }

    // MARK: Capability bindings (edit the explicit ref at the current level)

    private func contextBinding(_ tier: ModelTier) -> Binding<String> {
        Binding(
            get: {
                guard let n = explicitRef(tier)?.capabilities.contextWindow else { return "" }
                return String(n / 1000)
            },
            set: { txt in
                guard var ref = explicitRef(tier) else { return }
                let k = Int(txt.trimmingCharacters(in: .whitespaces))
                ref.capabilities.contextWindow = k.map { $0 * 1000 }
                ref.capabilitiesOverridden = true
                assignRef(tier, ref)
            })
    }
    private func boolCapBinding(_ tier: ModelTier, _ path: WritableKeyPath<ModelCapabilities, Bool?>) -> Binding<Bool> {
        Binding(
            get: { explicitRef(tier)?.capabilities[keyPath: path] ?? false },
            set: { on in
                guard var ref = explicitRef(tier) else { return }
                ref.capabilities[keyPath: path] = on
                ref.capabilitiesOverridden = true
                assignRef(tier, ref)
            })
    }
    private func inputBinding(_ tier: ModelTier, _ input: ModelCapabilities.Input) -> Binding<Bool> {
        Binding(
            get: { explicitRef(tier)?.capabilities.inputs?.contains(input) ?? false },
            set: { on in
                guard var ref = explicitRef(tier) else { return }
                var set = Set(ref.capabilities.inputs ?? [.text])
                if on { set.insert(input) } else { set.remove(input) }
                set.insert(.text)
                ref.capabilities.inputs = ModelCapabilities.Input.allCases.filter { set.contains($0) }
                ref.capabilitiesOverridden = true
                assignRef(tier, ref)
            })
    }

    // MARK: Local-server bindings

    private var localServerEnabled: Binding<Bool> {
        Binding(
            get: { store.settings.localServer != nil },
            set: { on in
                store.update { s in s.localServer = on ? (s.localServer ?? LocalServer(baseURL: "")) : nil }
                if !on { localServerModels = []; localServerProbe = .idle }
            })
    }
    private var localServerURL: Binding<String> {
        Binding(get: { store.settings.localServer?.baseURL ?? "" },
                set: { txt in store.update { $0.localServer?.baseURL = txt } })
    }
    private var localServerKey: Binding<String> {
        Binding(get: { store.settings.localServer?.apiKey ?? "" },
                set: { txt in store.update { $0.localServer?.apiKey = txt.isEmpty ? nil : txt } })
    }

    // MARK: Source presentation

    private func sourceColor(_ source: ModelRef.Source) -> Color {
        switch source {
        case .provider:    return .blue
        case .localServer: return .mint
        case .localRun:    return .purple
        }
    }
}

// MARK: - One provider's registration row (subscription sign-in + API key)

private struct ProviderRow: View {
    let provider: ModelProvider
    var credential: ProviderCredential?
    var subscription: ModelsSubscriptionHooks?
    var onChange: (ProviderCredential?) -> Void

    @State private var expanded = false

    private var isConfigured: Bool { credential?.isUsable ?? false }
    private var subSavedAt: Date? {
        provider.supportsSubscription ? subscription?.savedAt(provider) : nil
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                if provider.supportsSubscription, subscription != nil {
                    HStack(spacing: 10) {
                        if let saved = subSavedAt {
                            Label("Signed in \(saved.formatted(.relative(presentation: .named)))",
                                  systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                            Button("Forget") { subscription?.forget(provider) }
                                .buttonStyle(.borderless).controlSize(.small)
                        } else {
                            Button("Sign in…") { subscription?.register(provider) }
                                .controlSize(.small)
                            Text("Interactive login — no API key needed.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                // API key is always available as an alternative (or the only
                // option for providers with no interactive login, like z.ai).
                VStack(alignment: .leading, spacing: 3) {
                    if provider.supportsSubscription, subscription != nil, subSavedAt == nil {
                        Text("or paste an API key").font(.caption2).foregroundStyle(.tertiary)
                    }
                    SecureField("API key", text: apiKeyBinding).textFieldStyle(.roundedBorder)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Text(provider.displayName)
                Spacer()
                if subSavedAt != nil {
                    Label("Subscription", systemImage: "person.crop.circle.badge.checkmark")
                        .labelStyle(.iconOnly).foregroundStyle(.green)
                } else if isConfigured {
                    Label("Key", systemImage: "key.fill")
                        .labelStyle(.iconOnly).foregroundStyle(.green)
                }
            }
        }
    }

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { credential?.apiKey ?? "" },
            set: { txt in
                var c = credential ?? ProviderCredential(provider: provider)
                c.apiKey = txt.isEmpty ? nil : txt
                c.useSubscription = false
                onChange(c)
            })
    }
}

// MARK: - Known cloud model suggestions
//
// A small, current table so the tier pickers offer sensible ids without typing.
// "Custom id…" covers anything missing; capabilities are seeded from here for
// the ids we recognize.

enum ProviderModels {
    static func suggestions(for provider: ModelProvider, tier: ModelTier) -> [String] {
        switch provider {
        case .anthropic:
            // The Claude 5 family. Fable (a fast, capable large model) is offered
            // in Large alongside Opus; Sonnet is the medium; Haiku the small.
            switch tier {
            case .large:  return ["claude-opus-5", "claude-fable-5-1", "claude-sonnet-5"]
            case .medium: return ["claude-sonnet-5", "claude-opus-5", "claude-fable-5-1"]
            case .small:  return ["claude-haiku-4-5-20251001", "claude-sonnet-5"]
            }
        case .openai:
            return ["gpt-5.2", "gpt-5.2-mini", "o4-mini"]
        case .xai:
            return ["grok-4", "grok-4-fast"]
        case .zai:
            return ["glm-5.3", "glm-5.3-flash"]
        case .moonshot:
            return ["kimi-k2", "kimi-k2-turbo"]
        case .custom:
            return []
        }
    }

    static func capabilities(for modelID: String) -> ModelCapabilities? {
        let id = modelID.lowercased()
        if id.hasPrefix("claude") {
            return ModelCapabilities(contextWindow: 200_000, reasoning: true, inputs: [.text, .image])
        }
        if id.hasPrefix("gpt-5") || id.hasPrefix("o4") {
            return ModelCapabilities(contextWindow: 256_000, reasoning: true, inputs: [.text, .image])
        }
        if id.hasPrefix("grok") {
            return ModelCapabilities(contextWindow: 256_000, reasoning: true, inputs: [.text, .image])
        }
        if id.hasPrefix("glm") {
            return ModelCapabilities(contextWindow: 128_000, reasoning: true, inputs: [.text])
        }
        if id.hasPrefix("kimi") {
            return ModelCapabilities(contextWindow: 256_000, reasoning: false, inputs: [.text])
        }
        return nil
    }
}
#endif
