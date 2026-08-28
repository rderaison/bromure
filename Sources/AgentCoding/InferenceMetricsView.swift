import SwiftUI

/// Live engine telemetry, one tab per distinct inference engine across the
/// workspaces (built-in MLX + each external server). The built-in engine and
/// vLLM-style servers expose Prometheus `/metrics` (throughput cards + the
/// raw table); Ollama has no metrics endpoint, so its tab shows the
/// `/api/ps` snapshot — loaded models, VRAM, context, keep-alive expiry.
/// Polls only the selected tab, only while the window is open.
struct InferenceMetricsView: View {
    let targets: [EngineTarget]
    @State private var selectedID: String
    @State private var models: [String: InferenceMetricsModel] = [:]
    @State private var showRaw = false

    init(targets: [EngineTarget] = [.builtin]) {
        self.targets = targets.isEmpty ? [.builtin] : targets
        _selectedID = State(initialValue: (targets.first ?? .builtin).id)
    }

    private var selectedTarget: EngineTarget {
        targets.first { $0.id == selectedID } ?? targets[0]
    }

    private func model(for target: EngineTarget) -> InferenceMetricsModel {
        if let m = models[target.id] { return m }
        let m = InferenceMetricsModel(target: target)
        models[target.id] = m
        return m
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if targets.count > 1 {
                Picker("", selection: $selectedID) {
                    ForEach(targets) { t in
                        Text(t.label).tag(t.id)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding([.horizontal, .top], 14)
            }
            engineContent(model: model(for: selectedTarget), target: selectedTarget)
                .id(selectedID)   // re-run onAppear/onDisappear per tab switch
        }
        .frame(minWidth: 480, minHeight: 440)
        .onChange(of: selectedID) { old, _ in
            models[old]?.stop()
        }
    }

    @ViewBuilder
    private func engineContent(model: InferenceMetricsModel, target: EngineTarget) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header(model: model, target: target)

                if let err = model.error {
                    Label(err, systemImage: "bolt.slash")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }

                if model.engineFlavor == "Ollama" {
                    ollamaContent(model: model)
                } else {
                    prometheusContent(model: model)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: Prometheus engines (built-in MLX, vLLM)

    @ViewBuilder
    private func prometheusContent(model: InferenceMetricsModel) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
                  spacing: 12) {
            card("Decode tok/s", fmt(model.tokensPerSecond, "%.1f"), "speedometer", .green)
            card("Prefill tok/s", fmt(model.prefillTokensPerSecond, "%.0f"), "gauge.medium", .yellow)
            card("Running", fmt(model.latest?.requestsRunning, "%.0f"), "play.circle", .blue)
            card("Waiting", fmt(model.latest?.requestsWaiting, "%.0f"), "hourglass", .orange)
            card("In flight", fmt(model.latest?.requestsInFlight, "%.0f"), "arrow.left.arrow.right", .indigo)
            card("Avg latency", model.latest?.avgInferenceLatency.map { String(format: "%.2fs", $0) } ?? "—",
                 "timer", .pink)
            card("Cache hit", model.latest?.cacheHitRate.map { String(format: "%.0f%%", $0 * (($0 <= 1) ? 100 : 1)) } ?? "—",
                 "bolt.horizontal", .purple)
            if let kv = model.latest?.kvCacheUsage {
                card("KV cache use", String(format: "%.0f%%", kv * ((kv <= 1) ? 100 : 1)),
                     "square.stack.3d.up", .brown)
            }
            card("Metal mem", model.latest?.metalMemoryBytes.map { gib($0) } ?? "—", "memorychip", .cyan)
            card("Gen tokens", fmt(model.latest?.generationTokens, "%.0f"), "text.alignleft", .teal)
            card("Prompt tokens", fmt(model.latest?.promptTokens, "%.0f"), "text.append", .gray)
        }

        if !model.loadedModels.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Loaded models").font(.subheadline.weight(.medium))
                ForEach(model.loadedModels, id: \.self) { m in
                    Label(m, systemImage: "cpu").font(.callout)
                }
            }
        }

        DisclosureGroup("All metrics", isExpanded: $showRaw) {
            let rows = (model.latest?.values ?? [:]).sorted { $0.key < $1.key }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows, id: \.key) { k, v in
                    HStack {
                        Text(k).font(.caption.monospaced())
                        Spacer()
                        Text(String(format: "%g", v)).font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if rows.isEmpty {
                    Text("No metrics yet.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: Ollama

    @ViewBuilder
    private func ollamaContent(model: InferenceMetricsModel) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
                  spacing: 12) {
            // Throughput measured at the repair proxy (TTFT = first streamed
            // delta) — Ollama itself exposes no metrics endpoint.
            card("Decode tok/s", fmt(model.proxyStats?.decodeTokensPerSecond, "%.1f"),
                 "speedometer", .green)
            card("Avg latency", model.proxyStats?.avgLatencySeconds.map { String(format: "%.2fs", $0) } ?? "—",
                 "timer", .pink)
            card("Requests", model.proxyStats.map { "\($0.requests)" } ?? "—",
                 "arrow.left.arrow.right", .indigo)
            card("Gen tokens", model.proxyStats.map { "\($0.completionTokens)" } ?? "—",
                 "text.alignleft", .teal)
            card("Prompt tokens", model.proxyStats.map { "\($0.promptTokens)" } ?? "—",
                 "text.append", .gray)
            card("Loaded models", "\(model.ollamaModels.count)", "cpu", .mint)
            card("VRAM in use", gib(model.ollamaModels.reduce(0) { $0 + $1.sizeVRAM }),
                 "memorychip", .cyan)
            card("Server", model.serverVersion.map { "v\($0)" } ?? "—", "server.rack", .blue)
        }

        if model.ollamaModels.isEmpty {
            Text("No models loaded right now — Ollama loads on demand and unloads after its keep-alive expires.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Loaded models").font(.subheadline.weight(.medium))
                ForEach(model.ollamaModels) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Label(m.name, systemImage: "cpu").font(.callout)
                        HStack(spacing: 12) {
                            Text(gib(m.sizeVRAM))
                            if let ctx = m.contextLength {
                                Text("\(ctx / 1024)K context")
                            }
                            if let exp = m.expiresAt {
                                Text(exp > Date()
                                     ? "unloads \(exp.formatted(.relative(presentation: .named)))"
                                     : "unloading")
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.leading, 26)
                    }
                }
            }
        }

        Text("Ollama exposes no metrics endpoint, so throughput here is measured at Bromure's inference proxy across this app's own requests (since launch); models and VRAM come from the server's /api/ps.")
            .font(.caption).foregroundStyle(.tertiary)
    }

    // MARK: Shared bits

    private func header(model: InferenceMetricsModel, target: EngineTarget) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.mint.gradient, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(target.kind == .builtin ? "Local inference" : target.label)
                        .font(.title3.bold())
                    if let flavor = model.engineFlavor {
                        Text(flavor)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(verbatim: model.displayAddress)
                    .font(.caption).foregroundStyle(.secondary)
                if !target.workspaces.isEmpty {
                    Text("Workspaces: \(target.workspaces.sorted().joined(separator: ", "))")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func card(_ title: String, _ value: String, _ symbol: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.25), lineWidth: 1))
    }

    private func fmt(_ v: Double?, _ f: String) -> String {
        guard let v else { return "—" }
        return String(format: f, v)
    }

    private func gib(_ bytes: Double) -> String {
        String(format: "%.1f GB", bytes / 1_073_741_824)
    }
}
