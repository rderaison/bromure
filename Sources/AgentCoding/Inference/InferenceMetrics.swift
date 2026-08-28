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

    // Metric names for the in-process MLX engine (see MLXMetrics) FIRST,
    // then vLLM's `/metrics` equivalents — one parse serves both engines
    // (Ollama exposes no Prometheus endpoint; its tab uses /api/ps instead).
    public var promptTokens: Double?     { first(["mlx_prompt_tokens_total", "vllm:prompt_tokens_total"]) }
    /// Tokens actually prefilled = full prompt minus the reused KV-cache
    /// prefix. This — not `promptTokens` — is what TTFT measured, so it's the
    /// correct numerator for prefill throughput. (MLX only; vLLM doesn't
    /// export it, so its prefill rate falls back to promptTokens.)
    public var prefilledTokens: Double?  { values["mlx_prefill_tokens_total"] }
    public var generationTokens: Double? { first(["mlx_completion_tokens_total", "vllm:generation_tokens_total"]) }
    public var requestsRunning: Double?  { first(["mlx_scheduler_running_requests", "vllm:num_requests_running"]) }
    public var requestsWaiting: Double?  { first(["mlx_scheduler_waiting_requests", "vllm:num_requests_waiting"]) }
    public var requestsInFlight: Double? { values["mlx_http_requests_in_flight"] }
    public var cacheHitRate: Double?     { first(["mlx_cache_hit_rate", "vllm:gpu_prefix_cache_hit_rate"]) }
    public var metalMemoryBytes: Double? { values["mlx_metal_memory_bytes"] }
    /// vLLM's KV-cache occupancy (0–1); no MLX equivalent.
    public var kvCacheUsage: Double?     { values["vllm:gpu_cache_usage_perc"] }
    public var uptimeSeconds: Double?    { values["mlx_engine_uptime_seconds"] }
    /// Mean inference latency (s) = duration sum / count.
    public var avgInferenceLatency: Double? {
        guard let s = first(["mlx_inference_request_duration_seconds_sum",
                             "vllm:e2e_request_latency_seconds_sum"]),
              let c = first(["mlx_inference_request_duration_seconds_count",
                             "vllm:e2e_request_latency_seconds_count"]), c > 0 else { return nil }
        return s / c
    }

    /// Cumulative time-to-first-token seconds (≈ prompt prefill time).
    public var ttftSeconds: Double? {
        first(["mlx_inference_ttft_seconds_sum", "vllm:time_to_first_token_seconds_sum"])
    }

    /// Cumulative *decode* seconds = total request duration minus the
    /// prefill (TTFT). Completion tokens ÷ this is the true generation rate;
    /// dividing by wall-clock (or by total duration, which includes prefill)
    /// is what made the throughput read 1–4 tok/s instead of tens.
    public var decodeSeconds: Double? {
        guard let dur = first(["mlx_inference_request_duration_seconds_sum",
                               "vllm:e2e_request_latency_seconds_sum"]) else { return nil }
        return max(0, dur - (ttftSeconds ?? 0))
    }
}

/// One inference engine the metrics window can inspect: the built-in MLX
/// engine, or a distinct user-supplied server (Ollama/vLLM/…) referenced by
/// one or more workspaces. Enumerated from the profile list when the window
/// opens — a mixed fleet (built-in + two Ollamas + a vLLM) gets one tab per
/// distinct engine.
public struct EngineTarget: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case builtin, external }
    public var id: String            // "builtin" or the normalized base URL
    public var label: String         // tab title: "Built-in" or host[:port]
    public var kind: Kind
    public var base: URL?            // external only
    public var apiKey: String?
    public var workspaces: [String]  // profile names using this engine

    public static let builtin = EngineTarget(
        id: "builtin", label: "Built-in", kind: .builtin,
        base: nil, apiKey: nil, workspaces: [])

    /// Distinct engines across `profiles`, built-in first, externals sorted
    /// by label. A profile counts as using local inference when its routing
    /// isn't cloud, any agent is in `.local` auth, or a Fusion local
    /// leg/judge is set. With no local user at all, the built-in tab still
    /// shows (the window degrades to today's single view).
    public static func enumerate(profiles: [Profile]) -> [EngineTarget] {
        var external: [String: EngineTarget] = [:]
        var builtinWorkspaces: [String] = []
        for p in profiles {
            let usesLocal = p.modelRouting != .cloud
                || p.allToolSpecs.contains { $0.authMode == .local }
                || p.fusionLocalLeg?.isEmpty == false
                || p.fusionJudgeLocal
            guard usesLocal else { continue }
            if let base = p.localEngineBaseURL {
                let key = base.absoluteString.lowercased()
                var t = external[key] ?? EngineTarget(
                    id: key,
                    label: (base.host ?? key) + (base.port.map { ":\($0)" } ?? ""),
                    kind: .external, base: base,
                    apiKey: p.localEngineAPIKey, workspaces: [])
                t.workspaces.append(p.name)
                if t.apiKey?.isEmpty != false { t.apiKey = p.localEngineAPIKey }
                external[key] = t
            } else {
                builtinWorkspaces.append(p.name)
            }
        }
        var out: [EngineTarget] = []
        if !builtinWorkspaces.isEmpty || external.isEmpty {
            var b = EngineTarget.builtin
            b.workspaces = builtinWorkspaces
            out.append(b)
        }
        out += external.values.sorted { $0.label < $1.label }
        return out
    }
}

/// Proxy-measured throughput for one external engine, accumulated by the
/// repair proxy across every request it relays there. This is how the
/// metrics window shows real tok/s for engines with no metrics endpoint
/// (Ollama has none — its per-request eval stats ride the native API
/// responses, which our OpenAI-compat path never sees): the proxy times
/// each turn (TTFT = first streamed delta) and reads the usage off the
/// final message.
public final class EngineProxyStats: @unchecked Sendable {
    public struct Snapshot: Sendable, Equatable {
        public var requests = 0
        public var promptTokens = 0
        public var completionTokens = 0
        public var e2eSeconds: Double = 0
        public var ttfbSeconds: Double = 0

        /// Completion tokens per second of decode time (e2e minus TTFT).
        public var decodeTokensPerSecond: Double? {
            let decode = e2eSeconds - ttfbSeconds
            guard completionTokens > 0, decode > 0.05 else { return nil }
            return Double(completionTokens) / decode
        }
        public var avgLatencySeconds: Double? {
            requests > 0 ? e2eSeconds / Double(requests) : nil
        }
    }

    public static let shared = EngineProxyStats()
    public init() {}
    private let lock = NSLock()
    private var byEngine: [String: Snapshot] = [:]

    /// `engineID` matches EngineTarget.id (the normalized base URL, lowercased).
    public func record(engineID: String, promptTokens: Int, completionTokens: Int,
                       e2eSeconds: Double, ttfbSeconds: Double) {
        lock.lock(); defer { lock.unlock() }
        var s = byEngine[engineID] ?? Snapshot()
        s.requests += 1
        s.promptTokens += promptTokens
        s.completionTokens += completionTokens
        s.e2eSeconds += e2eSeconds
        s.ttfbSeconds += min(ttfbSeconds, e2eSeconds)
        byEngine[engineID] = s
    }

    public func snapshot(engineID: String) -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        return byEngine[engineID]
    }
}

/// One loaded model reported by an Ollama server's `/api/ps`.
public struct OllamaLoadedModel: Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var sizeVRAM: Double
    public var contextLength: Int?
    public var expiresAt: Date?
}

/// Polls the engine's `/metrics` endpoint and derives a live throughput.
/// Lives outside any view so a metrics window keeps updating; observed by
/// SwiftUI via `@Observable`.
@MainActor
@Observable
public final class InferenceMetricsModel {
    public let target: EngineTarget
    public private(set) var latest: InferenceMetrics?
    /// Decode throughput (tokens generated per second of generation time).
    public private(set) var tokensPerSecond: Double?
    /// Prompt-prefill throughput (tokens processed per second of TTFT). This is
    /// the real bottleneck for big agent prompts — slow prefill, not decode.
    public private(set) var prefillTokensPerSecond: Double?
    public private(set) var error: String?
    public private(set) var loadedModels: [String] = []
    /// Ollama servers expose no Prometheus endpoint; their tab shows the
    /// /api/ps snapshot instead.
    public private(set) var ollamaModels: [OllamaLoadedModel] = []
    public private(set) var serverVersion: String?
    /// Proxy-measured throughput (engines with no metrics endpoint).
    public private(set) var proxyStats: EngineProxyStats.Snapshot?
    /// "MLX (built-in)", "vLLM-style (/metrics)" or "Ollama" once detected.
    public private(set) var engineFlavor: String?

    /// External-server flavor, detected on the first successful fetch and
    /// remembered (probing both endpoints every poll would be wasteful).
    private enum ExternalFlavor { case prometheus, ollama }
    private var detectedFlavor: ExternalFlavor?

    private var task: Task<Void, Never>?

    public init(target: EngineTarget = .builtin) {
        self.target = target
    }

    private var metricsURL: URL {
        if let base = target.base { return base.appendingPathComponent("metrics") }
        return URL(string: "http://\(InferenceService.engineHost):\(InferenceService.enginePort)/metrics")!
    }

    /// The address line shown under the tab header.
    public var displayAddress: String {
        target.base?.absoluteString ?? "127.0.0.1:\(InferenceService.enginePort)"
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
        if case .external = target.kind {
            await refreshExternal()
            return
        }
        engineFlavor = "MLX (built-in)"
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
            // Prefill rate over the tokens ACTUALLY prefilled, not the full
            // prompt: with prefix caching most of the prompt is a KV-cache hit
            // that TTFT never measured, so prompt/ttft read as absurdly high
            // (e.g. a 20k-token prompt over a 0.14s cached-prefix TTFT → ~148k
            // tok/s). Fall back to promptTokens only for a pre-counter engine.
            if let pf = (m.prefilledTokens ?? m.promptTokens), let ttft = m.ttftSeconds, ttft > 0.05 {
                prefillTokensPerSecond = pf / ttft
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

    // MARK: External engines (vLLM / Ollama / …)

    private func fetch(_ path: String, method: String = "GET",
                       body: Data? = nil) async -> (Data, Int)? {
        guard let base = target.base else { return nil }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.timeoutInterval = 4
        req.httpMethod = method
        req.httpBody = body
        if let key = target.apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let status = (resp as? HTTPURLResponse)?.statusCode else { return nil }
        return (data, status)
    }

    /// vLLM-style servers answer `/metrics` with Prometheus text; Ollama
    /// answers `/api/ps` with its loaded-model snapshot. Detect once, then
    /// poll only the matching endpoint.
    private func refreshExternal() async {
        if detectedFlavor != .ollama,
           let (data, status) = await fetch("metrics"), status == 200,
           let text = String(data: data, encoding: .utf8) {
            let m = InferenceMetrics.parse(text)
            if !m.values.isEmpty {
                detectedFlavor = .prometheus
                engineFlavor = "vLLM-style (/metrics)"
                error = nil
                latest = m
                if let comp = m.generationTokens, let dec = m.decodeSeconds, dec > 0.05 {
                    tokensPerSecond = comp / dec
                }
                if let pf = (m.prefilledTokens ?? m.promptTokens), let ttft = m.ttftSeconds, ttft > 0.05 {
                    prefillTokensPerSecond = pf / ttft
                }
                if let (mdata, mstatus) = await fetch("v1/models"), mstatus == 200,
                   let obj = (try? JSONSerialization.jsonObject(with: mdata)) as? [String: Any],
                   let list = obj["data"] as? [[String: Any]] {
                    loadedModels = list.compactMap { $0["id"] as? String }.sorted()
                }
                return
            }
        }

        guard let (data, status) = await fetch("api/ps"), status == 200,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else {
            error = detectedFlavor == nil
                ? "engine not reachable (no /metrics, no /api/ps)"
                : "engine not reachable"
            return
        }
        detectedFlavor = .ollama
        engineFlavor = "Ollama"
        error = nil
        proxyStats = EngineProxyStats.shared.snapshot(engineID: target.id)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoPlain = ISO8601DateFormatter()
        ollamaModels = models.compactMap { m in
            guard let name = m["name"] as? String else { return nil }
            let expires = (m["expires_at"] as? String).flatMap {
                iso.date(from: $0) ?? isoPlain.date(from: $0)
            }
            return OllamaLoadedModel(
                name: name,
                sizeVRAM: (m["size_vram"] as? NSNumber)?.doubleValue ?? 0,
                contextLength: (m["context_length"] as? NSNumber)?.intValue,
                expiresAt: expires)
        }
        loadedModels = ollamaModels.map(\.name)
        if serverVersion == nil,
           let (vdata, vstatus) = await fetch("api/version"), vstatus == 200,
           let v = (try? JSONSerialization.jsonObject(with: vdata)) as? [String: Any] {
            serverVersion = v["version"] as? String
        }
    }
}
