import SwiftUI

/// Live engine telemetry from vllm-mlx's `/metrics` (Prometheus). Shows
/// derived throughput + the key counters as cards, plus the full raw
/// metric table. Polls only while the window is open.
struct InferenceMetricsView: View {
    @State private var model = InferenceMetricsModel()
    @State private var showRaw = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if let err = model.error {
                    Label(err, systemImage: "bolt.slash")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)],
                          spacing: 12) {
                    card("Tokens / sec", fmt(model.tokensPerSecond, "%.1f"), "speedometer", .green)
                    card("Running", fmt(model.latest?.requestsRunning, "%.0f"), "play.circle", .blue)
                    card("Waiting", fmt(model.latest?.requestsWaiting, "%.0f"), "hourglass", .orange)
                    card("In flight", fmt(model.latest?.requestsInFlight, "%.0f"), "arrow.left.arrow.right", .indigo)
                    card("Avg latency", model.latest?.avgInferenceLatency.map { String(format: "%.2fs", $0) } ?? "—",
                         "timer", .pink)
                    card("Cache hit", model.latest?.cacheHitRate.map { String(format: "%.0f%%", $0 * (($0 <= 1) ? 100 : 1)) } ?? "—",
                         "bolt.horizontal", .purple)
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
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 480, minHeight: 440)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.mint.gradient, in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 1) {
                Text("Local inference").font(.title3.bold())
                Text("vllm-mlx · 127.0.0.1:\(InferenceService.enginePort)")
                    .font(.caption).foregroundStyle(.secondary)
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
