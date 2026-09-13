#if os(macOS)
import SwiftUI

// MARK: - The "Models" preferences pane
//
// One global place (no per-workspace duplication, no "Agents" tab) to:
//   • register each provider once — Anthropic, OpenAI, xAI, z.ai, Moonshot,
//     or a custom OpenAI-compatible endpoint (API key or subscription),
//   • wire up a local route — a user-run server (RECOMMENDED) and/or on-device
//     models (the "lazy" backup that runs in-process on this Mac),
//   • pick a model for the three capability TIERS (small / medium / large),
//     each carrying the model's fetched-then-editable capabilities.
//
// Everything binds to the app-wide `ModelSettingsStore.shared`; a workspace
// only chooses WHICH agent to launch, never its models or credentials.

struct ModelsSettingsView: View {
    @ObservedObject var store = ModelSettingsStore.shared

    /// A live model list per source so the tier pickers offer real ids:
    /// the local server's `/v1/models`, refreshed on demand.
    @State private var localServerModels: [String] = []
    @State private var localServerProbe: SourceProbe = .idle
    /// Force the on-device rows to re-read `CatalogStore.isInstalled` (a
    /// non-observable disk read) after a Download / Remove.
    @State private var catalogTick = 0
    /// Tier whose "type a custom model id" prompt is open, plus its buffer.
    @State private var customIDTier: ModelTier?
    @State private var customIDText = ""

    private let downloads = ModelDownloadManager.shared
    private var hostGB: Int { HostMemory.unifiedMemoryGB() }

    private enum SourceProbe: Equatable {
        case idle, probing
        case ok(Int)
        case failed(String)
    }

    var body: some View {
        let _ = catalogTick   // establish the dependency (see catalogTick)
        return Form {
            tiersSection
            providersSection
            localServerSection
            onDeviceSection
        }
        .formStyle(.grouped)
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
            Text("The id exactly as the backend names it (e.g. claude-sonnet-4-5, glm-5.3-flash, qwen3-coder).")
        }
    }

    // MARK: Tiers

    @ViewBuilder private var tiersSection: some View {
        Section {
            ForEach(ModelTier.allCases, id: \.self) { tier in
                tierRow(tier)
            }
        } header: {
            Text("Model tiers")
        } footer: {
            Text("Every agent draws from these three tiers. Claude Code maps small → haiku, medium → sonnet, large → opus; every single-model agent (Codex, Grok, Kimi, omp) uses **medium**.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func tierRow(_ tier: ModelTier) -> some View {
        let ref = store.settings.tiers[tier]
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(tier.displayName).font(.body.weight(.medium))
                    Text("≈ \(tier.claudeTierHint)")
                        .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
                .frame(width: 90, alignment: .leading)

                tierPicker(tier, current: ref)
                Spacer()
                if ref != nil {
                    Button {
                        store.setTier(tier, nil)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear this tier")
                }
            }

            if let ref { capabilitiesEditor(tier, ref: ref) }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func tierPicker(_ tier: ModelTier, current: ModelRef?) -> some View {
        Menu {
            // Registered cloud providers (only the usable ones).
            ForEach(usableProviders, id: \.self) { p in
                Menu(p.displayName) {
                    ForEach(ProviderModels.suggestions(for: p), id: \.self) { id in
                        Button(id) { assign(tier, source: .provider(p), modelID: id) }
                    }
                    Divider()
                    Button("Custom id…") { beginCustomID(tier, source: .provider(p)) }
                }
            }

            // The user's local server.
            if store.settings.localServer != nil {
                Menu("Local server") {
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

            // On-device (installed catalog models).
            let installed = installedOnDevice
            if !installed.isEmpty {
                Menu("On-device") {
                    ForEach(installed) { m in
                        Button(m.displayName) {
                            assign(tier, source: .localRun(catalogID: m.id), modelID: m.id)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: sourceGlyph(current?.source))
                    .foregroundStyle(current == nil ? Color.secondary : sourceColor(current!.source))
                Text(current?.modelID ?? "Choose a model")
                    .foregroundStyle(current == nil ? Color.secondary : Color.primary)
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: Capabilities editor

    @ViewBuilder private func capabilitiesEditor(_ tier: ModelTier, ref: ModelRef) -> some View {
        let caps = ref.capabilities
        HStack(spacing: 14) {
            // Context window (K tokens).
            HStack(spacing: 4) {
                Text("Context").font(.caption).foregroundStyle(.secondary)
                TextField("auto", text: contextBinding(tier), prompt: Text("auto"))
                    .frame(width: 60).textFieldStyle(.roundedBorder)
                    .font(.caption.monospacedDigit())
                Text("K").font(.caption2).foregroundStyle(.tertiary)
            }
            Toggle("Reasoning", isOn: boolCapBinding(tier, \.reasoning))
                .toggleStyle(.checkbox).font(.caption)
            Toggle("Images", isOn: inputBinding(tier, .image))
                .toggleStyle(.checkbox).font(.caption)

            if ref.capabilitiesOverridden {
                Button("Re-fetch") { probeCapabilities(tier, force: true) }
                    .buttonStyle(.borderless).controlSize(.small)
                    .help("Discard manual edits and re-probe the backend")
            } else if caps.isKnown {
                Text("from server").font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text("not probed").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 98)
    }

    // MARK: Providers

    @ViewBuilder private var providersSection: some View {
        Section {
            ForEach(ModelProvider.allCases, id: \.self) { p in
                ProviderRow(provider: p,
                            credential: store.settings.credential(p),
                            onChange: { cred in
                                store.update { s in
                                    s.providers.removeAll { $0.provider == p }
                                    if let cred, cred.isUsable { s.providers.append(cred) }
                                }
                            })
            }
        } header: {
            Text("Providers")
        } footer: {
            Text("Register each provider once. Anthropic and OpenAI also accept a subscription (interactive sign-in) in place of an API key.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Local server (recommended)

    @ViewBuilder private var localServerSection: some View {
        Section {
            Toggle(isOn: localServerEnabled) {
                Text("Use a local server")
                Text("Recommended for local models — full-size weights, your GPU, your rules.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let server = store.settings.localServer {
                TextField("Server URL", text: localServerURL,
                          prompt: Text(verbatim: "http://127.0.0.1:11434/v1"))
                SecureField("API key (optional)", text: localServerKey)
                HStack(spacing: 8) {
                    Button("Test Connection") { probeLocalServer() }
                        .disabled(URL(string: server.baseURL) == nil || localServerProbe == .probing)
                    switch localServerProbe {
                    case .idle:    EmptyView()
                    case .probing: ProgressView().controlSize(.small)
                    case .ok(let n):
                        Label(String(format: NSLocalizedString("Connected — %d model(s)", comment: "local server probe ok"), n),
                              systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                    case .failed(let why):
                        Label(why, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.red).lineLimit(2)
                    }
                }
            }
        } header: {
            Text("Local server  ·  recommended")
        } footer: {
            Text("Any OpenAI-compatible server works — vLLM, Ollama, LM Studio, llama-server — on this Mac or another machine. Agents keep speaking their native APIs; Bromure translates in between.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: On-device (backup)

    @ViewBuilder private var onDeviceSection: some View {
        Section {
            ForEach(CatalogStore.shared.effective().sortedForDisplay) { model in
                onDeviceRow(model)
            }
        } header: {
            Text("On-device models  ·  \(hostGB) GB unified memory")
        } footer: {
            Text("The lazy backup: models run in-process on this Mac — nothing to install, but bounded by what fits in memory. Greyed-out models need more memory than this Mac has.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func onDeviceRow(_ model: CatalogModel) -> some View {
        let fit = RAMFitGate.fit(model: model, hostUnifiedMemGB: hostGB)
        let wontFit = (fit == .wontFit)
        let state = downloads.state(repo: model.repo)
        let installed = (state == nil) && CatalogStore.shared.isInstalled(repo: model.repo)

        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
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
        .disabled(wontFit)
        .padding(.vertical, 2)
    }

    @ViewBuilder private func onDeviceAction(model: CatalogModel,
                                             state: ModelDownloadManager.State?,
                                             installed: Bool, wontFit: Bool) -> some View {
        switch state {
        case .downloading(let frac, let label):
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    ProgressView(value: frac).progressViewStyle(.linear).frame(width: 110)
                    Text(label).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                Button {
                    downloads.cancel(repo: model.repo)
                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless).help("Stop download")
            }
        case .interrupted(let onDisk, let total):
            HStack(spacing: 8) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Interrupted").font(.caption2).foregroundStyle(.orange)
                    Text(total > 0 ? ProgressBar.bytesLabel(onDisk, total)
                                   : ByteCountFormatter.string(fromByteCount: onDisk, countStyle: .file))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                Button("Resume") { startDownload(model) }.controlSize(.small)
                Button {
                    downloads.discard(repo: model.repo)
                } label: { Image(systemName: "trash").foregroundStyle(.secondary) }
                .buttonStyle(.borderless).help("Discard the partial download")
            }
        case .failed(let msg):
            Button("Retry") { startDownload(model) }.controlSize(.small).help(msg)
        case nil:
            if installed {
                Menu {
                    Button("Remove", role: .destructive) { removeModel(model) }
                } label: {
                    Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                .platformBorderlessMenuStyle().fixedSize()
            } else {
                Button("Download") { startDownload(model) }
                    .controlSize(.small).disabled(wontFit)
            }
        }
    }

    // MARK: - Derived data

    private var usableProviders: [ModelProvider] {
        ModelProvider.allCases.filter { store.settings.credential($0)?.isUsable ?? false }
    }

    private var installedOnDevice: [CatalogModel] {
        _ = catalogTick
        return CatalogStore.shared.effective().sortedForDisplay
            .filter { CatalogStore.shared.isInstalled(repo: $0.repo) }
    }

    // MARK: - Actions

    /// Assign a model to a tier and (re)seed its capabilities from the backend.
    private func assign(_ tier: ModelTier, source: ModelRef.Source, modelID: String) {
        let existing = store.settings.tiers[tier]
        // Reuse existing capabilities only when it's the very same model/source
        // AND the user had overridden them; otherwise start fresh + re-probe.
        var ref = ModelRef(source: source, modelID: modelID)
        if let existing, existing.source == source, existing.modelID == modelID,
           existing.capabilitiesOverridden {
            ref = existing
        }
        store.setTier(tier, ref)
        if !ref.capabilitiesOverridden { probeCapabilities(tier, force: false) }
    }

    private func startDownload(_ model: CatalogModel) {
        downloads.start(repo: model.repo,
                        totalBytes: Int64(model.downloadGB * 1_000_000_000))
    }

    private func removeModel(_ model: CatalogModel) {
        do { try CatalogStore.shared.removeInstalled(repo: model.repo) }
        catch { InferenceLog.shared.record("[models] remove \(model.repo) failed: \(error)") }
        // Drop any tier that pointed at it.
        store.update { s in
            for (tier, ref) in s.tiers {
                if case .localRun(let id) = ref.source, id == model.id { s.tiers[tier] = nil }
            }
        }
        catalogTick += 1
    }

    /// Probe the endpoint that serves a tier's model and fold the result into
    /// its capabilities (never clobbering a user override unless `force`).
    private func probeCapabilities(_ tier: ModelTier, force: Bool) {
        guard let ref = store.settings.tiers[tier] else { return }
        if ref.capabilitiesOverridden && !force { return }

        switch ref.source {
        case .localRun(let cid):
            // On-device: the curated catalog is the source of truth (the engine
            // may not be running at settings-edit time).
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
            // Cloud providers don't expose a metadata probe here; seed from the
            // static suggestion table when we know the model, else leave blank
            // for the user to fill in.
            if let caps = ProviderModels.capabilities(for: ref.modelID) {
                applyProbed(caps, to: tier)
            }
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

    /// Fold probed capabilities into a tier without marking it user-overridden.
    private func applyProbed(_ caps: ModelCapabilities, to tier: ModelTier) {
        store.update { s in
            guard var ref = s.tiers[tier], !ref.capabilitiesOverridden else { return }
            ref.capabilities = caps
            s.tiers[tier] = ref
        }
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

    // MARK: - Custom-id prompt

    @State private var pendingCustomSource: ModelRef.Source?
    private func beginCustomID(_ tier: ModelTier, source: ModelRef.Source) {
        pendingCustomSource = source
        customIDText = store.settings.tiers[tier]?.modelID ?? ""
        customIDTier = tier
    }
    private var customIDAlertBinding: Binding<Bool> {
        Binding(get: { customIDTier != nil }, set: { if !$0 { customIDTier = nil } })
    }

    // MARK: - Capability bindings

    private func contextBinding(_ tier: ModelTier) -> Binding<String> {
        Binding(
            get: {
                guard let n = store.settings.tiers[tier]?.capabilities.contextWindow else { return "" }
                return String(n / 1000)
            },
            set: { txt in
                store.update { s in
                    guard var ref = s.tiers[tier] else { return }
                    let k = Int(txt.trimmingCharacters(in: .whitespaces))
                    ref.capabilities.contextWindow = (k.map { $0 * 1000 }) ?? nil
                    ref.capabilitiesOverridden = true
                    s.tiers[tier] = ref
                }
            })
    }

    private func boolCapBinding(_ tier: ModelTier, _ path: WritableKeyPath<ModelCapabilities, Bool?>) -> Binding<Bool> {
        Binding(
            get: { store.settings.tiers[tier]?.capabilities[keyPath: path] ?? false },
            set: { on in
                store.update { s in
                    guard var ref = s.tiers[tier] else { return }
                    ref.capabilities[keyPath: path] = on
                    ref.capabilitiesOverridden = true
                    s.tiers[tier] = ref
                }
            })
    }

    private func inputBinding(_ tier: ModelTier, _ input: ModelCapabilities.Input) -> Binding<Bool> {
        Binding(
            get: { store.settings.tiers[tier]?.capabilities.inputs?.contains(input) ?? false },
            set: { on in
                store.update { s in
                    guard var ref = s.tiers[tier] else { return }
                    var set = Set(ref.capabilities.inputs ?? [.text])
                    if on { set.insert(input) } else { set.remove(input) }
                    set.insert(.text)   // text is always accepted
                    ref.capabilities.inputs = ModelCapabilities.Input.allCases.filter { set.contains($0) }
                    ref.capabilitiesOverridden = true
                    s.tiers[tier] = ref
                }
            })
    }

    // MARK: - Local-server bindings

    private var localServerEnabled: Binding<Bool> {
        Binding(
            get: { store.settings.localServer != nil },
            set: { on in
                store.update { s in
                    s.localServer = on ? (s.localServer ?? LocalServer(baseURL: "")) : nil
                }
                if !on { localServerModels = []; localServerProbe = .idle }
            })
    }
    private var localServerURL: Binding<String> {
        Binding(
            get: { store.settings.localServer?.baseURL ?? "" },
            set: { txt in store.update { $0.localServer?.baseURL = txt } })
    }
    private var localServerKey: Binding<String> {
        Binding(
            get: { store.settings.localServer?.apiKey ?? "" },
            set: { txt in store.update { $0.localServer?.apiKey = txt.isEmpty ? nil : txt } })
    }

    // MARK: - Source presentation

    private func sourceGlyph(_ source: ModelRef.Source?) -> String {
        switch source {
        case .none:                 return "questionmark.circle"
        case .provider(.anthropic): return "cloud.fill"
        case .provider:             return "cloud"
        case .localServer:          return "server.rack"
        case .localRun:             return "cpu.fill"
        }
    }
    private func sourceColor(_ source: ModelRef.Source) -> Color {
        switch source {
        case .provider: return .blue
        case .localServer: return .mint
        case .localRun: return .purple
        }
    }
}

// MARK: - One provider's registration row

private struct ProviderRow: View {
    let provider: ModelProvider
    var credential: ProviderCredential?
    var onChange: (ProviderCredential?) -> Void

    @State private var expanded = false

    private var isConfigured: Bool { credential?.isUsable ?? false }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                if provider.supportsSubscription {
                    Toggle("Use subscription (sign in)", isOn: subscriptionBinding)
                        .toggleStyle(.switch)
                }
                if !(credential?.useSubscription ?? false) {
                    SecureField("API key", text: apiKeyBinding)
                        .textFieldStyle(.roundedBorder)
                    if provider == .custom {
                        TextField("Base URL", text: baseURLBinding,
                                  prompt: Text(verbatim: "https://host:8000/v1"))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Text(provider.displayName)
                Spacer()
                if isConfigured {
                    Label(credential?.useSubscription == true ? "Subscription" : "Key",
                          systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption).foregroundStyle(.green)
                }
            }
        }
    }

    private func mutate(_ f: (inout ProviderCredential) -> Void) {
        var cred = credential ?? ProviderCredential(provider: provider)
        f(&cred)
        onChange(cred)
    }

    private var subscriptionBinding: Binding<Bool> {
        Binding(get: { credential?.useSubscription ?? false },
                set: { on in mutate { $0.useSubscription = on; if on { $0.apiKey = nil } } })
    }
    private var apiKeyBinding: Binding<String> {
        Binding(get: { credential?.apiKey ?? "" },
                set: { txt in mutate { $0.apiKey = txt.isEmpty ? nil : txt } })
    }
    private var baseURLBinding: Binding<String> {
        Binding(get: { credential?.baseURL ?? "" },
                set: { txt in mutate { $0.baseURL = txt.isEmpty ? nil : txt } })
    }
}

// MARK: - Known cloud model suggestions
//
// A small, non-exhaustive table so the tier pickers offer sensible ids without
// forcing the user to type. "Custom id…" always covers anything missing, and
// capabilities are seeded from here for the ids we recognize.

enum ProviderModels {
    static func suggestions(for provider: ModelProvider) -> [String] {
        switch provider {
        case .anthropic:
            return ["claude-opus-4-5", "claude-sonnet-4-5", "claude-haiku-4-5"]
        case .openai:
            return ["gpt-5.2", "gpt-5.2-mini", "o4"]
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

    /// Best-effort capabilities for well-known ids (context window, reasoning,
    /// image input). Returns nil for unrecognized ids — the user fills those in.
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
