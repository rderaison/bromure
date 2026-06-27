import Foundation
import Observation

/// Parsed Prometheus metrics from the engine's `/metrics` endpoint
/// (`--enable-metrics`). We keep it format-tolerant: any `name value` line
/// is captured, label sets summed, so it works across vllm-mlx metric-name
/// changes without a hard-coded schema.
public struct InferenceMetrics: Sendable, Equatable {
    /// Base metric name (labels stripped) → summed value.
    public var values: [String: Double]

    public init(values: [String: Double] = [:]) { self.values = values }

    /// Parse Prometheus text exposition format.
    public static func parse(_ text: String) -> InferenceMetrics {
        var out: [String: Double] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            // `metric_name{labels...} value`  or  `metric_name value`
            guard let lastSpace = line.lastIndex(of: " ") else { continue }
            let valueStr = line[line.index(after: lastSpace)...]
            guard let value = Double(valueStr) else { continue }
            var name = String(line[..<lastSpace])
            if let brace = name.firstIndex(of: "{") { name = String(name[..<brace]) }
            name = name.trimmingCharacters(in: .whitespaces)
            out[name, default: 0] += value
        }
        return InferenceMetrics(values: out)
    }

    /// First present value among candidate metric names (handles the
    /// `vllm:` prefix and plain variants across versions).
    public func first(_ names: [String]) -> Double? {
        for n in names { if let v = values[n] { return v } }
        return nil
    }

    // Names as emitted by vllm-mlx (verified against v0.4.0rc1 /metrics),
    // with the older `vllm:` variants kept as fallbacks.
    public var promptTokens: Double?     { first(["vllm_mlx_prompt_tokens_total", "vllm:prompt_tokens_total", "prompt_tokens_total"]) }
    public var generationTokens: Double? { first(["vllm_mlx_completion_tokens_total", "vllm:generation_tokens_total", "generation_tokens_total"]) }
    public var requestsRunning: Double?  { first(["vllm_mlx_scheduler_running_requests", "vllm:num_requests_running", "num_requests_running"]) }
    public var requestsWaiting: Double?  { first(["vllm_mlx_scheduler_waiting_requests", "vllm:num_requests_waiting", "num_requests_waiting"]) }
    public var requestsInFlight: Double? { first(["vllm_mlx_http_requests_in_flight"]) }
    public var cacheUsage: Double?       { first(["vllm_mlx_cache_utilization_ratio", "vllm:gpu_cache_usage_perc", "kv_cache_usage_perc"]) }
    public var cacheHitRate: Double?     { first(["vllm_mlx_cache_hit_rate"]) }
    public var metalMemoryBytes: Double? { first(["vllm_mlx_metal_memory_bytes"]) }
    public var uptimeSeconds: Double?    { first(["vllm_mlx_engine_uptime_seconds"]) }
    /// Mean inference latency (s) = duration sum / count.
    public var avgInferenceLatency: Double? {
        guard let s = values["vllm_mlx_inference_request_duration_seconds_sum"],
              let c = values["vllm_mlx_inference_request_duration_seconds_count"], c > 0 else { return nil }
        return s / c
    }
}

/// Polls the engine's `/metrics` endpoint and derives a live throughput.
/// Lives outside any view so a metrics window keeps updating; observed by
/// SwiftUI via `@Observable`.
@MainActor
@Observable
public final class InferenceMetricsModel {
    public private(set) var latest: InferenceMetrics?
    public private(set) var tokensPerSecond: Double?
    public private(set) var error: String?
    public private(set) var loadedModels: [String] = []

    private var task: Task<Void, Never>?
    private var lastGen: Double?
    private var lastAt: Date?

    public init() {}

    private var metricsURL: URL {
        URL(string: "http://\(InferenceService.engineHost):\(InferenceService.enginePort)/metrics")!
    }

    public func start(interval: TimeInterval = 1.5) {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    private func refresh() async {
        var req = URLRequest(url: metricsURL)
        req.timeoutInterval = 4
        req.setValue("Bearer \(InferenceService.apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let text = String(data: data, encoding: .utf8) else {
                error = "engine not reachable"
                return
            }
            let m = InferenceMetrics.parse(text)
            error = nil
            // Derive tokens/s from the generation-tokens counter delta.
            let now = Date()
            if let gen = m.generationTokens, let lg = lastGen, let la = lastAt {
                let dt = now.timeIntervalSince(la)
                if dt > 0, gen >= lg { tokensPerSecond = (gen - lg) / dt }
            }
            lastGen = m.generationTokens
            lastAt = now
            latest = m
            loadedModels = await InferenceService.shared.loadedModelRepos
        } catch {
            self.error = "\(error)"
        }
    }
}
