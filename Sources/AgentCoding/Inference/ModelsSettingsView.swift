#if os(macOS)
import SwiftUI

// MARK: - The "Models" preferences pane
//
// A two-column mapping board that fits the editor's narrow detail pane without
// scrolling, so the agent→model mapping is always in view:
//
//   left  — SOURCES: every provider Bromure can pull models from. Cloud
//           providers (Anthropic / OpenAI / xAI / z.ai / Moonshot), a custom
//           OpenAI-compatible server, and the on-device MLX engine are all just
//           providers here. Click one to configure it in a popover (sign-in /
//           API key / server URL / downloads) — kept out of the column so it
//           stays compact.
//   right — AGENTS: every agent with a model picker. The Default row feeds all
//           agents; each agent can override. Claude Code (and the Default) break
//           out into small/medium/large tiers; every other agent is one model.
//
// Chips are color-coded by source. The view is scope-agnostic — it edits a bound
// `ModelSettings`: the global store in Preferences, or a per-workspace override
// in the workspace editor (see GlobalModelsSettingsView / WorkspaceModelsSettingsView).

/// Host hooks injected by the editor: subscription sign-in (throwaway-VM
/// capture) + a live model-list fetch for a registered provider.
struct ModelsSubscriptionHooks {
    var savedAt: (ModelProvider) -> Date?
    var register: (ModelProvider) -> Void
    var forget: (ModelProvider) -> Void
    /// Resolve a provider's current models from its API using the credential the
    /// pane holds (`useSubscription`, `apiKey`) — so a per-workspace override's
    /// own key works, not just the global one. Empty on failure.
    var fetchModels: ((ModelProvider, _ useSubscription: Bool, _ apiKey: String?,
                       @escaping ([String]) -> Void) -> Void)?
    /// When the provider REJECTED the saved sign-in (it must be redone), or nil.
    var reauthAt: (ModelProvider) -> Date? = { _ in nil }
    /// Whether this host can log the provider out here (a hook is wired) —
    /// "Log out" is hidden rather than left as a button that does nothing.
    var canForget: (ModelProvider) -> Bool = { _ in true }
}

/// A workspace's LAYER over the global settings (see `ModelOverride`): the
/// pane then reads the resolved result (global + layer, exclusions applied)
/// and writes only the layer — so an untouched provider or tier keeps
/// inheriting, live.
struct ModelsLayerContext {
    /// The global settings the layer sits on.
    var global: ModelSettings
    /// Global providers the workspace opts out of (`.custom` = the custom server).
    var excluded: Binding<[ModelProvider]>
}

struct ModelsSettingsView: View {
    @Binding var settings: ModelSettings
    var subscription: ModelsSubscriptionHooks? = nil
    /// Non-nil: `settings` is a workspace layer over `layer.global`.
    var layer: ModelsLayerContext? = nil
    /// The pane's own "Models" heading. Off when the host already titles the
    /// screen (the onboarding wizard's step heading).
    var showsTitle: Bool = true

    /// A source in the left column.
    enum Source: Hashable, Identifiable {
        case provider(ModelProvider)
        case customServer
        case onDevice
        var id: String {
            switch self {
            case .provider(let p): return "p.\(p.rawValue)"
            case .customServer:    return "customServer"
            case .onDevice:        return "onDevice"
            }
        }
    }

    @State private var openSource: Source?
    @State private var localServerModels: [String] = []
    @State private var localServerProbe: SourceProbe = .idle
    @State private var providerModels: [ModelProvider: [String]] = [:]
    @State private var catalogTick = 0
    @State private var subTick = 0
    @State private var customIDContext: (agent: ModelAgent?, tier: ModelTier, source: ModelRef.Source)?
    @State private var customIDText = ""
    /// Agents whose optional "Sizes" (large/small) section is expanded.
    @State private var openSizes: Set<String> = []

    private let downloads = ModelDownloadManager.shared
    private var hostGB: Int { HostMemory.unifiedMemoryGB() }
    private enum SourceProbe: Equatable { case idle, probing, ok(Int), failed(String) }

    /// The live model list of a provider with no agent of its own to ask
    /// (OpenRouter…): its OpenAI-compatible `/v1/models`, with the pane's key.
    /// Empty when the provider has no such endpoint or it can't be reached.
    static func fetchCompatibleModels(_ provider: ModelProvider, apiKey: String?,
                                      completion: @escaping ([String]) -> Void) {
        guard let raw = provider.openAICompatibleBase, let base = URL(string: raw) else {
            completion([]); return
        }
        Task {
            let ids = (try? await ExternalEngine.listModels(base: base, apiKey: apiKey)) ?? []
            await MainActor.run { completion(ids) }
        }
    }

    /// Mutate the bound settings in place. The binding's setter persists (global
    /// store) or updates the workspace draft (committed on the editor's Save).
    private func mutate(_ f: (inout ModelSettings) -> Void) {
        var s = settings; f(&s); settings = s
    }

    /// What's in effect: the bound settings themselves, or — for a workspace
    /// layer — the global settings with the layer applied. Every READ of a
    /// credential / tier / server goes through this; writes go to `settings`.
    private var resolved: ModelSettings {
        guard let layer else { return settings }
        return ModelOverride(inheritsGlobal: true, settings: settings,
                             excludedProviders: layer.excluded.wrappedValue)
            .resolved(over: layer.global)
    }
    private var excluded: [ModelProvider] {
        get { layer?.excluded.wrappedValue ?? [] }
    }
    private func setExcluded(_ provider: ModelProvider, _ on: Bool) {
        guard let layer else { return }
        var list = layer.excluded.wrappedValue
        list.removeAll { $0 == provider }
        if on { list.append(provider) }
        layer.excluded.wrappedValue = list
    }
    /// A layered workspace's relationship to one provider.
    private func providerStatus(_ provider: ModelProvider) -> ModelOverride.ProviderStatus? {
        guard let layer else { return nil }
        return ModelOverride(inheritsGlobal: true, settings: settings, excludedProviders: excluded)
            .providerStatus(provider, global: layer.global)
    }

    // Custom is a UI concept (the custom server), not a listed cloud provider.
    private let cloudProviders: [ModelProvider] =
        ModelProvider.allCases.filter { $0 != .custom }

    private var sources: [Source] {
        cloudProviders.map { Source.provider($0) } + [.customServer, .onDevice]
    }

    var body: some View {
        let _ = (catalogTick, subTick)
        return VStack(alignment: .leading, spacing: 14) {
            if showsTitle {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Models").font(.title2.bold())
                    Text("Register a source on the left. Each agent runs its provider’s default model unless you pick one on the right.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                sourcesColumn.frame(width: 210)
                agentsColumn.frame(maxWidth: .infinity, alignment: .top)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .onAppear {
            if resolved.localServer != nil { probeLocalServer() }
            syncSubscriptions()
            fetchUsableProviderModels()
            // A provider registered outside this pane (an API key the
            // onboarding scan imported) gets its native agent pre-filled the
            // same way a key pasted here does — never over an explicit choice.
            for p in usableProviders { autofillAgent(for: p) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .bromureSubscriptionStoresChanged)) { _ in
            subTick &+= 1
            syncSubscriptions()
            fetchUsableProviderModels()
        }
        .alert("Model id", isPresented: customIDAlertBinding) {
            TextField("model-id", text: $customIDText)
            Button("Cancel", role: .cancel) { customIDContext = nil }
            Button("Use") {
                if let c = customIDContext {
                    let id = customIDText.trimmingCharacters(in: .whitespaces)
                    if !id.isEmpty { assign(c.agent, c.tier, source: c.source, modelID: id) }
                }
                customIDContext = nil
            }
        } message: {
            Text("The id exactly as the backend names it (e.g. claude-opus-5, glm-4.6, qwen3-coder).")
        }
    }

    // MARK: Left column — sources

    private var sourcesColumn: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(sources) { source in
                    sourceRow(source)
                    if source != sources.last { Divider() }
                }
            }
            .padding(.vertical, 2)
        } label: {
            Label("Providers", systemImage: "cloud.fill").font(.headline)
        }
    }

    @ViewBuilder private func sourceRow(_ source: Source) -> some View {
        Button {
            openSource = source
        } label: {
            HStack(spacing: 8) {
                Circle().fill(sourceStatusColor(source)).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text(sourceName(source)).foregroundStyle(.primary)
                    if let sub = sourceSubtitle(source) {
                        Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .popover(isPresented: popoverBinding(source), arrowEdge: .trailing) {
            // Read subTick/catalogTick so a sign-in / log-out (which bumps them
            // via the change notification) re-renders THIS popover, not just the
            // row behind it — otherwise the popover keeps showing stale state.
            let _ = (subTick, catalogTick)
            sourcePopover(source).frame(width: source == .onDevice ? 380 : 300)
        }
    }

    @ViewBuilder private func sourcePopover(_ source: Source) -> some View {
        switch source {
        case .provider(.bedrock): bedrockPopover
        case .provider(let p):    providerPopover(p)
        case .customServer:       customServerPopover
        case .onDevice:           onDevicePopover
        }
    }

    /// Bedrock has no key or login here: enabling it says "Claude Code goes
    /// through Amazon Bedrock", and each workspace signs with the AWS
    /// credentials in its own Credentials → AWS section.
    @ViewBuilder private var bedrockPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ModelProvider.bedrock.displayName).font(.headline)
            Text("Any agent can run on Amazon Bedrock: Claude Code natively, the others through Bedrock's OpenAI-compatible API. Sign requests with each workspace's own AWS credentials (Credentials → AWS), or paste a Bedrock API key.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let status = providerStatus(.bedrock), status == .inherited || status == .excluded {
                layerStatusHeader(.bedrock, status)
            }
            Toggle("Use Amazon Bedrock", isOn: bedrockEnabled)
            if resolved.credential(.bedrock)?.isUsable == true {
                TextField("AWS region", text: bedrockRegion,
                          prompt: Text(verbatim: "\(Bedrock.defaultRegion) — empty: each workspace's AWS region"))
                    .textFieldStyle(.roundedBorder)
                SecureField("Bedrock API key (optional — else AWS credentials sign)", text: bedrockKey)
                    .textFieldStyle(.roundedBorder)
                Text("Model ids as Bedrock names them, e.g. \(ProviderModels.bedrockPlaceholder) — pick them per agent on the right, or type your own.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
    }

    // MARK: Source popovers

    @ViewBuilder private func providerPopover(_ provider: ModelProvider) -> some View {
        let status = providerStatus(provider)
        VStack(alignment: .leading, spacing: 0) {
            if let status, status == .inherited || status == .excluded {
                // Layered workspace, nothing of its own for this provider: say
                // where it comes from and offer to override / opt out. The
                // credential form below is what "override" reveals.
                layerStatusHeader(provider, status).padding([.horizontal, .top], 16)
            }
            if status != .excluded {
                // A dedicated, self-observing subview: it re-reads sign-in status on the
                // subscription-store change notification itself, so logging out reliably
                // flips it back to "Sign in…" even though a parent popover isn't always
                // re-evaluated on SwiftUI state changes.
                ProviderConfigPopover(
                    provider: provider,
                    hasCapture: provider.supportsSubscription && subscription != nil,
                    savedAt: { subscription?.savedAt(provider) },
                    reauthAt: { subscription?.reauthAt(provider) },
                    onSignIn: { subscription?.register(provider) },
                    onLogOut: (subscription?.canForget(provider) ?? false)
                        ? { subscription?.forget(provider) } : nil,
                    apiKey: providerKeyBinding(provider, settings.credential(provider)),
                    ownOverride: status == .overridden ? { useGlobalCredential(provider) } : nil,
                    inheritedHint: status == .inherited)
            } else {
                Spacer(minLength: 16)
            }
        }
    }

    /// Layered workspace: how this provider is sourced, with the switch to
    /// opt out of / back into the global one.
    @ViewBuilder private func layerStatusHeader(_ provider: ModelProvider,
                                                _ status: ModelOverride.ProviderStatus) -> some View {
        let globalCred = layer?.global.credential(provider)
        let how: String = {
            if provider.isBedrock { return "AWS credentials" }
            if globalCred?.useSubscription == true { return "subscription" }
            return "API key"
        }()
        VStack(alignment: .leading, spacing: 6) {
            if status == .inherited {
                Label(String(format: NSLocalizedString("Inherited from Preferences → Models (%@).", comment: "layered provider status"), how),
                      systemImage: "arrow.down.to.line")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Don't use in this workspace") { setExcluded(provider, true) }
                        .controlSize(.small)
                    Text("— or override it below.").font(.caption2).foregroundStyle(.tertiary)
                }
            } else {
                Label("Not used in this workspace — the global settings have it.",
                      systemImage: "nosign")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Use the global provider") { setExcluded(provider, false) }
                    .controlSize(.small)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Layered workspace: drop the workspace's own credential so the provider
    /// inherits the global one again (its layer tiers stay).
    private func useGlobalCredential(_ provider: ModelProvider) {
        mutate { s in s.providers.removeAll { $0.provider == provider } }
        setExcluded(provider, false)
        fetchProviderModels(provider)
    }

    @ViewBuilder private var customServerPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Custom server").font(.headline)
            Text("Any OpenAI-compatible server (vLLM, Ollama, LM Studio, llama-server), on this Mac or another. Recommended for local models.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if layer != nil, settings.localServer == nil, layer?.global.localServer != nil {
                Label(excluded.contains(.custom)
                      ? "Not used in this workspace — the global settings have one."
                      : "Inherited from Preferences → Models. Editing it below makes it this workspace's own.",
                      systemImage: excluded.contains(.custom) ? "nosign" : "arrow.down.to.line")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if layer != nil, settings.localServer != nil {
                HStack {
                    Label("This workspace's own server.", systemImage: "pencil")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if layer?.global.localServer != nil {
                        Button("Use the global server") {
                            mutate { $0.localServer = nil }
                            setExcluded(.custom, false)
                            localServerModels = []; localServerProbe = .idle
                        }.controlSize(.small)
                    }
                }
            }
            Toggle("Enabled", isOn: localServerEnabled)
            if resolved.localServer != nil {
                TextField("Server URL", text: localServerURL,
                          prompt: Text(verbatim: "http://127.0.0.1:11434/v1")).textFieldStyle(.roundedBorder)
                SecureField("API key (optional)", text: localServerKey).textFieldStyle(.roundedBorder)
                HStack(spacing: 8) {
                    Button("Test Connection") { probeLocalServer() }
                        .controlSize(.small)
                        .disabled(URL(string: resolved.localServer?.baseURL ?? "") == nil
                                  || localServerProbe == .probing)
                    switch localServerProbe {
                    case .idle:    EmptyView()
                    case .probing: ProgressView().controlSize(.small)
                    case .ok(let n):
                        Label(String(format: NSLocalizedString("%d model(s)", comment: "probe ok"), n),
                              systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    case .failed(let why):
                        Label(why, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.red).lineLimit(2)
                    }
                }
            }
        }
        .padding(16)
    }

    @ViewBuilder private var onDevicePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("On-device models").font(.headline)
            Text("MLX models run in-process on this Mac (\(hostGB) GB) — the lazy backup, nothing to install.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(CatalogStore.shared.effective().sortedForDisplay) { model in
                        onDeviceRow(model)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(16)
    }

    @ViewBuilder private func onDeviceRow(_ model: CatalogModel) -> some View {
        let fit = RAMFitGate.fit(model: model, hostUnifiedMemGB: hostGB)
        let wontFit = (fit == .wontFit)
        let state = downloads.state(repo: model.repo)
        let installed = (state == nil) && CatalogStore.shared.isInstalled(repo: model.repo)
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.displayName).font(.callout)
                HStack(spacing: 5) {
                    Text(fit.badge)
                        .foregroundStyle(fit == .fits ? .green : (fit == .tight ? .orange : .secondary))
                    Text("· \(Int(model.downloadGB)) GB")
                }.font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            switch state {
            case .downloading(let frac, _):
                HStack(spacing: 4) {
                    ProgressView(value: frac).progressViewStyle(.linear).frame(width: 60)
                    Button { downloads.cancel(repo: model.repo) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.borderless)
                }
            case .interrupted: Button("Resume") { startDownload(model) }.controlSize(.small)
            case .failed(let msg): Button("Retry") { startDownload(model) }.controlSize(.small).help(msg)
            case nil:
                if installed {
                    Button("Remove", role: .destructive) { removeModel(model) }
                        .buttonStyle(.borderless).controlSize(.small).foregroundStyle(.secondary)
                } else {
                    Button("Get") { startDownload(model) }.controlSize(.small).disabled(wontFit)
                }
            }
        }
        .opacity(wontFit ? 0.5 : 1)
        .padding(.vertical, 2)
    }

    // MARK: Right column — agents

    private var agentsColumn: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                agentRow(nil)                       // Default
                Divider()
                ForEach(ModelAgent.allCases, id: \.self) { agent in
                    agentRow(agent)
                    if agent != ModelAgent.allCases.last { Divider() }
                }
            }
            .padding(.vertical, 2)
        } label: {
            Label("Agents", systemImage: "sparkles").font(.headline)
        }
    }

    /// One agent (nil = Default): its main model, like Claude Code's /model.
    /// Claude Code (and the Default) can also pin separate small/large models
    /// — tucked behind "Sizes", opened only when one is already set.
    @ViewBuilder private func agentRow(_ agent: ModelAgent?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(agentName(agent)).fontWeight(agent == nil ? .semibold : .regular)
                Spacer()
                tierChip(agent, .medium)
            }
            if usesAllTiers(agent) {
                let sizesSet = explicitRef(agent, .small) != nil || explicitRef(agent, .large) != nil
                DisclosureGroup(isExpanded: sizesBinding(agent, forcedOpen: sizesSet)) {
                    VStack(spacing: 6) {
                        tierLine(agent, .large)
                        tierLine(agent, .small)
                        if let agent, !(settings.agentTiers[agent]?.isEmpty ?? true) {
                            HStack {
                                Spacer()
                                Button("Reset to Default") { mutate { $0.resetAgentOverrides(agent) } }
                                    .buttonStyle(.borderless).controlSize(.small)
                            }
                        }
                    }
                    .padding(.top, 2).padding(.leading, 4)
                } label: {
                    Text("Sizes").font(.caption).foregroundStyle(.secondary)
                }
                .help("Optional: different models for Claude Code's large (opus) and small/background (haiku) slots. Unset, they follow Claude Code's own defaults.")
            }
        }
        .padding(.vertical, 6)
    }

    private func sizesBinding(_ agent: ModelAgent?, forcedOpen: Bool) -> Binding<Bool> {
        let key = agent?.rawValue ?? "default"
        return Binding(get: { forcedOpen || openSizes.contains(key) },
                       set: { if $0 { openSizes.insert(key) } else { openSizes.remove(key) } })
    }

    /// One tier's label + chip inside an expanded agent.
    @ViewBuilder private func tierLine(_ agent: ModelAgent?, _ tier: ModelTier) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text(tier.displayName).font(.callout)
                Text("≈ \(tier.claudeTierHint)").font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            .frame(width: 74, alignment: .leading)
            tierChip(agent, tier)
            Spacer()
        }
    }

    @ViewBuilder private func tierChip(_ agent: ModelAgent?, _ tier: ModelTier) -> some View {
        let explicit = explicitRef(agent, tier)
        let effective = effectiveRef(agent, tier)
        // "inherited": from the Default row (an agent), or — in a workspace
        // layer — from the global settings (any row, the Default included).
        let inherited = (agent != nil || layer != nil) && explicit == nil && effective != nil
        HStack(spacing: 4) {
            Menu {
                ForEach(usableProviders.filter { providerAllowed($0, for: agent) }, id: \.self) { p in
                    Menu(p.displayName) {
                        ForEach(modelOptions(for: p, tier: tier), id: \.self) { id in
                            Button(id) { assign(agent, tier, source: .provider(p), modelID: id) }
                        }
                        Divider()
                        Button("Custom id…") { beginCustomID(agent, tier, source: .provider(p)) }
                    }
                }
                if resolved.localServer != nil {
                    Menu("Custom server") {
                        if localServerModels.isEmpty {
                            Text("Test the connection to list models").foregroundStyle(.secondary)
                        }
                        ForEach(localServerModels, id: \.self) { id in
                            Button(id) { assign(agent, tier, source: .localServer, modelID: id) }
                        }
                        Divider()
                        Button("Custom id…") { beginCustomID(agent, tier, source: .localServer) }
                    }
                }
                let installed = installedOnDevice
                if !installed.isEmpty {
                    Menu("On-device") {
                        ForEach(installed) { m in
                            Button(m.displayName) { assign(agent, tier, source: .localRun(catalogID: m.id), modelID: m.id) }
                        }
                    }
                }
                let allowed = usableProviders.filter { providerAllowed($0, for: agent) }
                if allowed.isEmpty, resolved.localServer == nil, installedOnDevice.isEmpty {
                    // Distinguish "nothing registered" from "registered, but a
                    // subscription can't power this agent" (EULA).
                    if usableProviders.isEmpty {
                        Text("Configure a provider first").foregroundStyle(.secondary)
                    } else {
                        Text("A subscription can only power its own agent").foregroundStyle(.secondary)
                    }
                }
                if agent != nil || layer != nil, explicit != nil {
                    Divider()
                    Button(clearLabel(agent)) { assignRef(agent, tier, nil) }
                }
            } label: {
                modelChip(effective, inherited: inherited,
                          placeholder: nativeDefaultLabel(agent, tier))
            }
            .menuStyle(.borderlessButton).fixedSize()
            if explicit != nil {
                Button { assignRef(agent, tier, nil) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help(agent == nil ? (layer == nil ? "Clear" : "Inherit the global setting") : "Inherit Default")
            }
        }
    }

    @ViewBuilder private func modelChip(_ ref: ModelRef?, inherited: Bool,
                                        placeholder: String? = nil) -> some View {
        let color = ref.map { sourceColor($0.source) } ?? (placeholder != nil ? .green : .secondary)
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(ref?.modelID ?? placeholder ?? "Choose…")
                .font(.callout)
                .foregroundStyle(ref == nil ? Color.secondary : Color.primary)
                .lineLimit(1).truncationMode(.middle)
            if inherited { Text("· inherited").font(.caption2).foregroundStyle(.tertiary) }
            Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(color.opacity(0.25)))
    }

    // MARK: Derived

    /// The agent's own provider is signed in / keyed, so with nothing chosen
    /// it simply runs that provider's default model — no pick needed.
    private func nativeProviderUsable(_ agent: ModelAgent?) -> Bool {
        guard let p = agent?.nativeCloudProvider else { return false }
        if providerStatus(p) == .excluded { return false }
        return (resolved.credential(p)?.isUsable ?? false) || subscription?.savedAt(p) != nil
    }
    /// What an unset chip reads when the agent runs its own default:
    /// "Claude Code default" (main model) / "default" (a size slot).
    private func nativeDefaultLabel(_ agent: ModelAgent?, _ tier: ModelTier) -> String? {
        guard let agent, nativeProviderUsable(agent) else { return nil }
        return tier == .medium
            ? String(format: NSLocalizedString("%@ default", comment: "model chip: the agent's own default model"),
                     agent.displayName)
            : NSLocalizedString("default", comment: "model chip: a size slot left at the agent's default")
    }
    private func clearLabel(_ agent: ModelAgent?) -> String {
        guard let agent else { return NSLocalizedString("Use the global setting", comment: "") }
        return nativeProviderUsable(agent) && effectiveDefaultTiersEmpty
            ? String(format: NSLocalizedString("Use %@’s default", comment: "model menu"), agent.displayName)
            : NSLocalizedString("Use Default", comment: "model menu")
    }
    private var effectiveDefaultTiersEmpty: Bool { resolved.tiers.isEmpty }

    private func usesAllTiers(_ agent: ModelAgent?) -> Bool {
        agent == nil || agent?.usesAllTiers == true
    }
    private func agentName(_ agent: ModelAgent?) -> String {
        agent?.displayName ?? "Default"
    }
    private var usableProviders: [ModelProvider] {
        cloudProviders.filter { resolved.credential($0)?.isUsable ?? false }
    }
    /// Whether a usable provider may power `agent`. A provider in SUBSCRIPTION
    /// mode is bound to its own agent only — a Claude/ChatGPT subscription can't
    /// legally drive another agent, and can't be a Default (which feeds all
    /// agents). API-key providers are unrestricted (pay-per-use).
    private func providerAllowed(_ provider: ModelProvider, for agent: ModelAgent?) -> Bool {
        guard let cred = resolved.credential(provider), cred.isUsable else { return false }
        if cred.useSubscription {
            return agent != nil && agent == provider.nativeAgent
        }
        // Bedrock is pay-per-use (a key or the workspace's AWS account), so
        // like an API key it may power any agent: Claude Code natively, the
        // others through Bedrock's OpenAI-compatible surface.
        return true
    }
    private var installedOnDevice: [CatalogModel] {
        _ = catalogTick
        return CatalogStore.shared.effective().sortedForDisplay
            .filter { CatalogStore.shared.isInstalled(repo: $0.repo) }
    }
    /// Merge the live `/v1/models` list (when the provider is registered) with
    /// the curated list, deduped and tier-ordered — so a curated model the live
    /// list omits (e.g. Fable) still appears, and live-only models (e.g. new
    /// OpenAI models) show up too. "Custom id…" always covers the rest.
    private func modelOptions(for p: ModelProvider, tier: ModelTier) -> [String] {
        let live = providerModels[p] ?? []
        var seen = Set<String>(); var merged: [String] = []
        for id in live + ProviderModels.allSuggestions(for: p) where !seen.contains(id) {
            seen.insert(id); merged.append(id)
        }
        return ProviderModels.ordered(merged, for: p, tier: tier)
    }
    private func explicitRef(_ agent: ModelAgent?, _ tier: ModelTier) -> ModelRef? {
        if let a = agent { return settings.agentTiers[a]?[tier] }
        return settings.tiers[tier]
    }
    private func effectiveRef(_ agent: ModelAgent?, _ tier: ModelTier) -> ModelRef? {
        let r = resolved
        if let a = agent { return r.ref(for: a, tier: tier) }
        return r.tiers[tier]
    }

    // Source presentation
    private func sourceName(_ source: Source) -> String {
        switch source {
        case .provider(let p): return p.displayName
        case .customServer:    return "Custom server"
        case .onDevice:        return "On-device"
        }
    }
    private func sourceSubtitle(_ source: Source) -> String? {
        switch source {
        case .provider(let p):
            let r = resolved
            switch providerStatus(p) {
            case .excluded?:   return "off here"
            case .overridden?: return r.credential(p)?.isUsable == true ? "overridden here" : "override (not configured)"
            case .inherited?:
                if p.isBedrock { return "inherited" }
                return r.credential(p)?.useSubscription == true ? "inherited subscription" : "inherited API key"
            default: break
            }
            if p.isBedrock { return r.credential(p)?.isUsable == true ? "AWS credentials" : nil }
            if subscription?.savedAt(p) != nil {
                return subscription?.reauthAt(p) != nil
                    ? NSLocalizedString("sign-in expired", comment: "provider row subtitle") : "subscription"
            }
            if r.credential(p)?.isUsable == true { return "API key" }
            return nil
        case .customServer:
            if layer != nil, excluded.contains(.custom), settings.localServer == nil { return "off here" }
            return resolved.localServer?.baseURL.isEmpty == false
                ? URL(string: resolved.localServer!.baseURL)?.host : nil
        case .onDevice:
            let n = installedOnDevice.count
            return n > 0 ? "\(n) installed" : nil
        }
    }
    private func sourceStatusColor(_ source: Source) -> Color {
        switch source {
        case .provider(let p):
            if providerStatus(p) == .excluded { return .secondary.opacity(0.4) }
            if subscription?.savedAt(p) != nil, subscription?.reauthAt(p) != nil,
               providerStatus(p) != .overridden { return .orange }
            let usable = (resolved.credential(p)?.isUsable ?? false)
                || (subscription?.savedAt(p) != nil && providerStatus(p) != .overridden)
            return usable ? .green : .secondary.opacity(0.4)
        case .customServer:
            return (resolved.localServer?.baseURL.isEmpty == false) ? .mint : .secondary.opacity(0.4)
        case .onDevice:
            return installedOnDevice.isEmpty ? .secondary.opacity(0.4) : .purple
        }
    }
    private func sourceColor(_ source: ModelRef.Source) -> Color {
        switch source {
        case .provider:    return .blue
        case .localServer: return .mint
        case .localRun:    return .purple
        }
    }
    private func popoverBinding(_ source: Source) -> Binding<Bool> {
        Binding(get: { openSource == source }, set: { if !$0 { openSource = nil } })
    }

    // MARK: Mutations

    /// Pre-fill a provider's native agent with a model when the provider
    /// becomes usable. Only fills tiers that agent hasn't set explicitly (never
    /// clobbers a deliberate choice).
    private func autofillAgent(for provider: ModelProvider) {
        guard let agent = provider.nativeAgent else { return }   // z.ai / custom: no native agent
        // An agent on its OWN provider (Claude ← Anthropic, Codex ← OpenAI…)
        // needs no pick: unset, it runs that provider's default model. Only
        // Bedrock, which has no default to fall back on, is pre-filled.
        guard provider.isBedrock else { return }
        // A workspace layer only pre-fills for a provider IT registered; an
        // inherited provider's agent keeps inheriting whatever the global
        // settings say (or don't) — opening the editor must not write overrides.
        if layer != nil, settings.credential(provider) == nil { return }
        // Bedrock pins one model (Claude Code's ANTHROPIC_MODEL); the other
        // tiers keep inheriting.
        let tiers: [ModelTier] = (agent.usesAllTiers && !provider.isBedrock)
            ? [.large, .medium, .small] : [.medium]
        // A workspace layer only fills a tier NOTHING resolves for — an
        // inherited choice must not be copied into the layer as an override.
        for tier in tiers where (layer == nil ? explicitRef(agent, tier) : effectiveRef(agent, tier)) == nil {
            if let id = modelOptions(for: provider, tier: tier).first {
                assign(agent, tier, source: .provider(provider), modelID: id)
            }
        }
    }

    /// Reconcile the interactive-subscription records (host-side) with the
    /// provider credentials here: signing in marks the provider useSubscription
    /// (so it's usable + drives subscription auth at launch) and pre-fills its
    /// agent; logging out drops a key-less subscription credential.
    private func syncSubscriptions() {
        guard let subscription else { return }
        for p in cloudProviders where p.supportsSubscription {
            // A layered workspace inheriting this provider: the (shared) login
            // belongs to the global settings — don't turn it into an override.
            if let st = providerStatus(p), st == .inherited || st == .excluded { continue }
            let signedIn = subscription.savedAt(p) != nil
            let cred = settings.credential(p)
            let hasKey = !((cred?.apiKey ?? "").isEmpty)
            if signedIn, cred?.useSubscription != true {
                mutate { s in
                    var c = s.credential(p) ?? ProviderCredential(provider: p)
                    c.useSubscription = true
                    s.providers.removeAll { $0.provider == p }
                    s.providers.append(c)
                }
                autofillAgent(for: p)
            } else if !signedIn, cred?.useSubscription == true, !hasKey {
                mutate { s in s.providers.removeAll { $0.provider == p } }
            }
        }
    }

    private func assign(_ agent: ModelAgent?, _ tier: ModelTier, source: ModelRef.Source, modelID: String) {
        let existing = explicitRef(agent, tier)
        var ref = ModelRef(source: source, modelID: modelID)
        if let existing, existing.source == source, existing.modelID == modelID,
           existing.capabilitiesOverridden { ref = existing }
        assignRef(agent, tier, ref)
        if !ref.capabilitiesOverridden { probeCapabilities(agent, tier) }
    }
    private func assignRef(_ agent: ModelAgent?, _ tier: ModelTier, _ ref: ModelRef?) {
        mutate { $0.setTier(tier, ref, for: agent) }
    }

    private func startDownload(_ model: CatalogModel) {
        downloads.start(repo: model.repo, totalBytes: Int64(model.downloadGB * 1_000_000_000))
    }
    private func removeModel(_ model: CatalogModel) {
        do { try CatalogStore.shared.removeInstalled(repo: model.repo) }
        catch { InferenceLog.shared.record("[models] remove \(model.repo) failed: \(error)") }
        mutate { s in
            func drop(_ t: inout [ModelTier: ModelRef]) {
                for (tier, r) in t { if case .localRun(let id) = r.source, id == model.id { t[tier] = nil } }
            }
            drop(&s.tiers)
            for a in s.agentTiers.keys { var t = s.agentTiers[a]!; drop(&t); s.agentTiers[a] = t.isEmpty ? nil : t }
        }
        catalogTick += 1
    }

    // MARK: Live model fetch

    private func fetchUsableProviderModels() { for p in usableProviders { fetchProviderModels(p) } }
    private func fetchProviderModels(_ p: ModelProvider) {
        guard resolved.credential(p)?.isUsable ?? false else { providerModels[p] = nil; return }
        let cred = resolved.credential(p)
        subscription?.fetchModels?(p, cred?.useSubscription ?? false, cred?.apiKey) { ids in
            providerModels[p] = ids
        }
    }

    // MARK: Capability probe (seeds fetched-but-editable capabilities)

    private func probeCapabilities(_ agent: ModelAgent?, _ tier: ModelTier) {
        guard let ref = explicitRef(agent, tier), !ref.capabilitiesOverridden else { return }
        switch ref.source {
        case .localRun(let cid):
            if let m = CatalogStore.shared.resolve(cid) {
                var caps = ModelCapabilities()
                caps.contextWindow = m.context
                caps.reasoning = (m.reasoningParser != nil)
                caps.inputs = m.tags.contains("vision") ? [.text, .image] : [.text]
                applyProbed(caps, agent, tier)
            }
        case .localServer:
            guard let s = resolved.localServer, let base = URL(string: s.baseURL) else { return }
            let key = s.apiKey, model = ref.modelID
            Task {
                let meta = await ExternalEngine.modelMeta(base: base, apiKey: key, model: model)
                await MainActor.run { applyProbed(capabilities(from: meta), agent, tier) }
            }
        case .provider:
            if let caps = ProviderModels.capabilities(for: ref.modelID) { applyProbed(caps, agent, tier) }
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
    private func applyProbed(_ caps: ModelCapabilities, _ agent: ModelAgent?, _ tier: ModelTier) {
        guard var ref = explicitRef(agent, tier), !ref.capabilitiesOverridden else { return }
        ref.capabilities = caps
        assignRef(agent, tier, ref)
    }

    private func probeLocalServer() {
        guard let s = resolved.localServer, let base = URL(string: s.baseURL) else { return }
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

    private func beginCustomID(_ agent: ModelAgent?, _ tier: ModelTier, source: ModelRef.Source) {
        customIDText = explicitRef(agent, tier)?.modelID ?? ""
        customIDContext = (agent, tier, source)
    }
    private var customIDAlertBinding: Binding<Bool> {
        Binding(get: { customIDContext != nil }, set: { if !$0 { customIDContext = nil } })
    }

    // MARK: Bindings

    private func providerKeyBinding(_ provider: ModelProvider, _ cred: ProviderCredential?) -> Binding<String> {
        Binding(
            get: { cred?.apiKey ?? "" },
            set: { txt in
                mutate { s in
                    s.providers.removeAll { $0.provider == provider }
                    var c = cred ?? ProviderCredential(provider: provider)
                    c.apiKey = txt.isEmpty ? nil : txt
                    c.useSubscription = false
                    if c.isUsable { s.providers.append(c) }
                }
                fetchProviderModels(provider)
                if !txt.isEmpty { autofillAgent(for: provider) }  // pre-fill its agent
            })
    }
    private var bedrockEnabled: Binding<Bool> {
        Binding(
            get: { resolved.credential(.bedrock)?.isUsable ?? false },
            set: { on in
                // Layered workspace with nothing of its own: opt out of / back
                // into the GLOBAL Bedrock rather than editing the layer.
                if let st = providerStatus(.bedrock), st == .inherited || st == .excluded {
                    setExcluded(.bedrock, !on)
                    return
                }
                mutate { s in
                    s.providers.removeAll { $0.provider == .bedrock }
                    if on { s.providers.append(ProviderCredential(provider: .bedrock)) }
                    else {
                        // Off: every Bedrock-pinned tier points at nothing
                        // now — drop them so those agents inherit again.
                        for (t, r) in s.tiers where r.source == .provider(.bedrock) { s.tiers[t] = nil }
                        for a in s.agentTiers.keys {
                            var t = s.agentTiers[a] ?? [:]
                            for (tier, r) in t where r.source == .provider(.bedrock) { t[tier] = nil }
                            s.agentTiers[a] = t.isEmpty ? nil : t
                        }
                    }
                }
                if on { autofillAgent(for: .bedrock) }
            })
    }
    /// Layered workspace editing an INHERITED Bedrock's region/key: copy the
    /// global credential into the layer first so the edit lands on its own.
    private func materializeBedrock(_ s: inout ModelSettings) {
        guard s.credential(.bedrock) == nil, let g = layer?.global.credential(.bedrock) else { return }
        s.providers.append(g)
    }
    private var bedrockRegion: Binding<String> {
        Binding(get: { resolved.credential(.bedrock)?.region ?? "" },
                set: { txt in
                    mutate { s in
                        materializeBedrock(&s)
                        guard let i = s.providers.firstIndex(where: { $0.provider == .bedrock }) else { return }
                        s.providers[i].region = txt.trimmingCharacters(in: .whitespaces).isEmpty ? nil : txt
                    }
                })
    }
    private var bedrockKey: Binding<String> {
        Binding(get: { resolved.credential(.bedrock)?.apiKey ?? "" },
                set: { txt in
                    mutate { s in
                        materializeBedrock(&s)
                        guard let i = s.providers.firstIndex(where: { $0.provider == .bedrock }) else { return }
                        s.providers[i].apiKey = txt.isEmpty ? nil : txt
                    }
                })
    }
    private var localServerEnabled: Binding<Bool> {
        Binding(
            get: { resolved.localServer != nil },
            set: { on in
                if let layer, settings.localServer == nil, layer.global.localServer != nil {
                    // Inherited: the switch opts out of / back into the global one.
                    setExcluded(.custom, !on)
                } else {
                    mutate { s in s.localServer = on ? (s.localServer ?? LocalServer(baseURL: "")) : nil }
                    if !on, layer?.global.localServer != nil { setExcluded(.custom, true) }
                    if on { setExcluded(.custom, false) }
                }
                if !on { localServerModels = []; localServerProbe = .idle }
            })
    }
    /// Layered workspace editing the INHERITED server: copy it into the layer
    /// first so the edit becomes the workspace's own.
    private func materializeLocalServer(_ s: inout ModelSettings) {
        if s.localServer == nil, let g = layer?.global.localServer { s.localServer = g }
    }
    private var localServerURL: Binding<String> {
        Binding(get: { resolved.localServer?.baseURL ?? "" },
                set: { txt in mutate { materializeLocalServer(&$0); $0.localServer?.baseURL = txt } })
    }
    private var localServerKey: Binding<String> {
        Binding(get: { resolved.localServer?.apiKey ?? "" },
                set: { txt in mutate { materializeLocalServer(&$0); $0.localServer?.apiKey = txt.isEmpty ? nil : txt } })
    }
}

// MARK: - Provider config popover (sign-in / log out / API key)

/// Its own View so it can observe `.bromureSubscriptionStoresChanged` directly:
/// a sign-in (from the separate registration window) or a log-out re-reads
/// `savedAt` here and flips the controls, without depending on the parent
/// popover being re-evaluated.
private struct ProviderConfigPopover: View {
    let provider: ModelProvider
    let hasCapture: Bool
    let savedAt: () -> Date?
    let reauthAt: () -> Date?
    let onSignIn: () -> Void
    /// nil: this host can't log the provider out from here.
    let onLogOut: (() -> Void)?
    @Binding var apiKey: String
    /// Layered workspace with its OWN credential for this provider: the action
    /// that drops it and inherits the global one again. nil otherwise.
    var ownOverride: (() -> Void)? = nil
    /// Layered workspace inheriting this provider: the form below overrides it.
    var inheritedHint: Bool = false
    @State private var tick = 0
    @State private var confirmLogOut = false

    var body: some View {
        let _ = tick
        let saved = hasCapture ? savedAt() : nil
        let expired = saved != nil ? reauthAt() : nil
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(provider.displayName).font(.headline)
                Spacer()
                if let ownOverride {
                    Button("Use the global provider") { ownOverride() }.controlSize(.small)
                }
            }
            if inheritedHint {
                Text("Override for this workspace:").font(.caption).foregroundStyle(.secondary)
            } else if ownOverride != nil {
                Label("This workspace's own credential.", systemImage: "pencil")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if hasCapture {
                if let saved, expired != nil {
                    // The provider rejected the saved sign-in: nothing works
                    // until it's redone, so this is the one thing to do here.
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Sign-in expired", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout.weight(.semibold)).foregroundStyle(.orange)
                        Text("\(provider.displayName) rejected the saved sign-in (from \(saved.formatted(.relative(presentation: .named)))). Sessions can't use it until you sign in again.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button { onSignIn() } label: {
                                Label("Sign in again", systemImage: "arrow.clockwise.circle")
                            }
                            .buttonStyle(.borderedProminent).tint(.orange)
                            if onLogOut != nil {
                                Button("Log out…") { confirmLogOut = true }
                            }
                        }
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                } else if let saved {
                    Label("Signed in \(saved.formatted(.relative(presentation: .named)))",
                          systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(.green)
                    HStack {
                        Button { onSignIn() } label: {
                            Label("Sign in again…", systemImage: "arrow.clockwise")
                        }
                        if onLogOut != nil {
                            Button("Log out…") { confirmLogOut = true }
                        }
                    }
                    .controlSize(.small)
                } else {
                    Button {
                        onSignIn()
                    } label: {
                        Label("Sign in with \(provider.displayName)", systemImage: "person.crop.circle.badge.plus")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.regular)
                    Text("Interactive login in a temporary VM — no API key needed.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("or paste an API key").font(.caption2).foregroundStyle(.tertiary)
                }
            }

            SecureField("API key", text: $apiKey).textFieldStyle(.roundedBorder)

            if apiKey.isEmpty, saved == nil {
                Text("Not configured yet.").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .onReceive(NotificationCenter.default.publisher(for: .bromureSubscriptionStoresChanged)) { _ in
            tick &+= 1
        }
        .confirmationDialog("Log out of \(provider.displayName)?", isPresented: $confirmLogOut) {
            Button("Log Out", role: .destructive) { onLogOut?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Workspaces using this sign-in stop working until you sign in again.")
        }
    }
}

// MARK: - Scope wrappers

/// Preferences: the Models pane bound to the global `ModelSettingsStore`.
struct GlobalModelsSettingsView: View {
    @ObservedObject var store = ModelSettingsStore.shared
    var subscription: ModelsSubscriptionHooks? = nil
    var showsTitle: Bool = true
    var body: some View {
        ModelsSettingsView(
            settings: Binding(get: { store.settings },
                              set: { store.settings = $0; store.save() }),
            subscription: subscription,
            showsTitle: showsTitle)
    }
}

/// Workspace editor: an optional per-workspace override of the global settings —
/// layered (inherit, change what's set here) or standalone.
struct WorkspaceModelsSettingsView: View {
    @Binding var override: ModelOverride?
    var globalSettings: ModelSettings
    var subscription: ModelsSubscriptionHooks? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: overrideEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Custom model settings for this workspace").font(.body.weight(.medium))
                        Text(override == nil
                             ? "Inheriting the global settings (Preferences → Models)."
                             : (override?.inheritsGlobal == true
                                ? "Starts from the global settings; only what you set below is different here."
                                : "This workspace has its own providers, logins and model choices below — the global settings are ignored."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if override != nil {
                    Picker("", selection: modeBinding) {
                        Text("Inherit, with changes").tag(true)
                        Text("Standalone").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
                }
            }
            .padding(18)
            Divider()
            if let o = override {
                ModelsSettingsView(
                    settings: layerSettings,
                    subscription: subscription,
                    layer: o.inheritsGlobal
                        ? ModelsLayerContext(global: globalSettings, excluded: excludedBinding)
                        : nil)
            } else {
                inheritedSummary.padding(18)
                Spacer(minLength: 0)
            }
        }
    }

    private var overrideEnabled: Binding<Bool> {
        // On: a layered override with nothing set yet — everything still
        // inherits until the user changes something.
        Binding(get: { override != nil },
                set: { on in override = on ? ModelOverride(inheritsGlobal: true) : nil })
    }
    private var modeBinding: Binding<Bool> {
        Binding(get: { override?.inheritsGlobal ?? true },
                set: { layered in
                    guard var o = override, o.inheritsGlobal != layered else { return }
                    if layered {
                        // Back to inheriting: start from an empty layer.
                        o = ModelOverride(inheritsGlobal: true)
                    } else {
                        // Standalone: seed from what's live so the user starts
                        // from the current effective setup, not a blank slate.
                        o = .standalone(o.resolved(over: globalSettings))
                    }
                    override = o
                })
    }
    private var layerSettings: Binding<ModelSettings> {
        Binding(get: { override?.settings ?? ModelSettings() },
                set: { override?.settings = $0 })
    }
    private var excludedBinding: Binding<[ModelProvider]> {
        Binding(get: { override?.excludedProviders ?? [] },
                set: { override?.excludedProviders = $0 })
    }

    @ViewBuilder private var inheritedSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Inherited models").font(.headline)
            ForEach([ModelTier.large, .medium, .small], id: \.self) { tier in
                HStack {
                    Text(tier.displayName).frame(width: 70, alignment: .leading).foregroundStyle(.secondary)
                    Text(globalSettings.tiers[tier]?.modelID ?? "—")
                    Spacer()
                }.font(.callout)
            }
            let providers = globalSettings.providers.filter(\.isUsable).map(\.provider.displayName)
            if !providers.isEmpty {
                Text("Providers: " + providers.joined(separator: ", "))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Turn on the switch above to give this workspace its own keys, logins or models — for some providers or all of them.")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
        }
    }
}

// MARK: - Static model suggestions (offline seed / fallback)

enum ProviderModels {
    /// Bedrock has no model listing on the bedrock-runtime endpoint, so the
    /// picker offers the ids the Claude Code and Bedrock docs use as examples
    /// (cross-region `us.` inference profiles; OpenAI-compatible GPT OSS) and
    /// the user types their own via "Custom id…" when theirs differ.
    static let bedrockPlaceholder = "us.anthropic.claude-sonnet-4-6"

    /// The full curated lineup for a provider (every tier), merged with the live
    /// list by the picker so a curated model is always selectable.
    static func allSuggestions(for provider: ModelProvider) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for tier in [ModelTier.large, .medium, .small] {
            for id in suggestions(for: provider, tier: tier) where !seen.contains(id) {
                seen.insert(id); out.append(id)
            }
        }
        return out
    }

    static func suggestions(for provider: ModelProvider, tier: ModelTier) -> [String] {
        switch provider {
        case .anthropic:
            switch tier {
            case .large:  return ["claude-opus-5", "claude-fable-5-1", "claude-opus-4-8", "claude-sonnet-5"]
            case .medium: return ["claude-sonnet-5", "claude-sonnet-4-6", "claude-opus-5"]
            case .small:  return ["claude-haiku-4-5-20251001", "claude-sonnet-5"]
            }
        case .openai:   return ["gpt-5.5", "gpt-5.2", "gpt-5", "gpt-4o"]
        case .xai:      return ["grok-4", "grok-4-fast", "grok-3"]
        case .zai:      return ["glm-5.3", "glm-5.3-flash", "glm-4.6"]
        case .moonshot: return ["kimi-k2.5", "kimi-k2", "kimi-k2-turbo-preview"]
        // OpenRouter's catalog is fetched live (its /models endpoint); these
        // are the ids its API docs use as examples, so the picker is never empty.
        case .openrouter: return ["anthropic/claude-sonnet-4.6", "openai/gpt-5.2"]
        case .bedrock:
            switch tier {
            case .large:  return ["us.anthropic.claude-opus-4-8", bedrockPlaceholder]
            case .medium: return [bedrockPlaceholder, "openai.gpt-oss-120b-1:0"]
            case .small:  return ["us.anthropic.claude-haiku-4-5-20251001-v1:0", "openai.gpt-oss-20b-1:0"]
            }
        case .custom:   return []
        }
    }

    static func ordered(_ live: [String], for provider: ModelProvider, tier: ModelTier) -> [String] {
        guard provider == .anthropic || provider == .bedrock else { return live }
        let hints: [String]
        switch tier {
        case .large:  hints = ["opus", "fable"]
        case .medium: hints = ["sonnet"]
        case .small:  hints = ["haiku"]
        }
        let (preferred, rest) = live.stablePartition { id in
            hints.contains { id.lowercased().contains($0) }
        }
        return preferred + rest
    }

    static func capabilities(for modelID: String) -> ModelCapabilities? {
        let id = modelID.lowercased()
        if id.hasPrefix("claude") || id.contains("anthropic/claude") || id.contains(".anthropic.claude") {
            return ModelCapabilities(contextWindow: 200_000, reasoning: true, inputs: [.text, .image])
        }
        if id.hasPrefix("gpt-5") || id.hasPrefix("gpt-4") || id.hasPrefix("o4") || id.hasPrefix("o3") {
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

private extension Array {
    func stablePartition(_ belongsFirst: (Element) -> Bool) -> ([Element], [Element]) {
        var a: [Element] = [], b: [Element] = []
        for e in self { if belongsFirst(e) { a.append(e) } else { b.append(e) } }
        return (a, b)
    }
}
#endif
