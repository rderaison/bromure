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

    // Metric names emitted by the in-process MLX engine (see MLXMetrics).
    public var promptTokens: Double?     { values["mlx_prompt_tokens_total"] }
    public var generationTokens: Double? { values["mlx_completion_tokens_total"] }
    public var requestsRunning: Double?  { values["mlx_scheduler_running_requests"] }
    public var requestsWaiting: Double?  { values["mlx_scheduler_waiting_requests"] }
    public var requestsInFlight: Double? { values["mlx_http_requests_in_flight"] }
    public var cacheHitRate: Double?     { values["mlx_cache_hit_rate"] }
    public var metalMemoryBytes: Double? { values["mlx_metal_memory_bytes"] }
    public var uptimeSeconds: Double?    { values["mlx_engine_uptime_seconds"] }
    /// Mean inference latency (s) = duration sum / count.
    public var avgInferenceLatency: Double? {
        guard let s = values["mlx_inference_request_duration_seconds_sum"],
              let c = values["mlx_inference_request_duration_seconds_count"], c > 0 else { return nil }
        return s / c
    }

    /// Cumulative time-to-first-token seconds (≈ prompt prefill time).
    public var ttftSeconds: Double? { values["mlx_inference_ttft_seconds_sum"] }

    /// Cumulative *decode* seconds = total request duration minus the
    /// prefill (TTFT). Completion tokens ÷ this is the true generation rate;
    /// dividing by wall-clock (or by total duration, which includes prefill)
    /// is what made the throughput read 1–4 tok/s instead of tens.
    public var decodeSeconds: Double? {
        guard let dur = values["mlx_inference_request_duration_seconds_sum"] else { return nil }
        return max(0, dur - (ttftSeconds ?? 0))
    }
}

/// Polls the engine's `/metrics` endpoint and derives a live throughput.
/// Lives outside any view so a metrics window keeps updating; observed by
/// SwiftUI via `@Observable`.
@MainActor
@Observable
public final class InferenceMetricsModel {
    public private(set) var latest: InferenceMetrics?
    /// Decode throughput (tokens generated per second of generation time).
    public private(set) var tokensPerSecond: Double?
    /// Prompt-prefill throughput (tokens processed per second of TTFT). This is
    /// the real bottleneck for big agent prompts — slow prefill, not decode.
    public private(set) var prefillTokensPerSecond: Double?
    public private(set) var error: String?
    public private(set) var loadedModels: [String] = []

    private var task: Task<Void, Never>?

    public init() {}

    private var metricsURL: URL {
        URL(string: "http://\(InferenceService.engineHost):\(InferenceService.enginePort)/metrics")!
    }

    public func start(interval: TimeInterval = 5) {
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
            // Decode + prefill rates from CUMULATIVE counters, not windowed
            // deltas. The engine observes ttft at first-token time but request
            // duration at completion, so a poll landing between them desyncs the
            // deltas and collapses decode tok/s to the total (prefill+decode)
            // throughput — the ~7 tok/s artifact. Lifetime ratios stay
            // self-consistent and report the true decode rate (verified: this
            // recovers the streaming ground truth ~64 tok/s).
            if let comp = m.generationTokens, let dec = m.decodeSeconds, dec > 0.05 {
                tokensPerSecond = comp / dec
            }
            if let prompt = m.promptTokens, let ttft = m.ttftSeconds, ttft > 0.05 {
                prefillTokensPerSecond = prompt / ttft
            }
            latest = m
            loadedModels = await InferenceService.shared.loadedModelRepos
        } catch {
            // Transient connection blips are normal while the engine (re)starts
            // or is busy — show a short status, not the giant NSError dump.
            self.error = (error as? URLError)?.code == .timedOut
                ? "engine busy (timed out)" : "engine not reachable"
        }
    }
}
