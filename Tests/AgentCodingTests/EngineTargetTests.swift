import Foundation
import Testing
@testable import bromure_ac

/// The metrics window's engine enumeration + the vLLM metric-name mapping.
@Suite("Inference metrics engine targets")
struct EngineTargetTests {

    private func profile(_ name: String, routing: Profile.Routing,
                         engine: String? = nil) -> Profile {
        var p = Profile(name: name, tool: .claude, authMode: routing == .cloud ? .token : .local)
        p.modelRouting = routing
        p.localEngineURL = engine
        return p
    }

    @Test("Mixed fleet: built-in + deduped externals, cloud-only excluded")
    func mixedFleet() {
        let targets = EngineTarget.enumerate(profiles: [
            profile("ws1", routing: .local),                                    // built-in
            profile("ws2", routing: .local, engine: "http://ollama1:11434"),
            profile("ws3", routing: .local, engine: "http://ollama2:11434"),
            profile("ws4", routing: .local, engine: "http://vllm:8000"),
            profile("ws5", routing: .local, engine: "http://ollama1:11434"),    // dup base
            profile("cloudy", routing: .cloud),                                 // excluded
        ])
        #expect(targets.count == 4)
        #expect(targets.first?.id == "builtin")
        #expect(targets.first?.workspaces == ["ws1"])
        let ollama1 = targets.first { $0.label == "ollama1:11434" }
        #expect(ollama1?.workspaces.sorted() == ["ws2", "ws5"])
        #expect(targets.contains { $0.label == "vllm:8000" })
    }

    @Test("No local users → single built-in tab (today's behavior)")
    func cloudOnly() {
        let targets = EngineTarget.enumerate(profiles: [profile("c", routing: .cloud)])
        #expect(targets.map(\.id) == ["builtin"])
    }

    @Test("vLLM metric names resolve through the shared derived properties")
    func vllmNames() {
        let m = InferenceMetrics.parse("""
        vllm:prompt_tokens_total{model="q"} 1000
        vllm:generation_tokens_total{model="q"} 500
        vllm:num_requests_running 2
        vllm:num_requests_waiting 1
        vllm:gpu_cache_usage_perc 0.42
        vllm:e2e_request_latency_seconds_sum 90
        vllm:e2e_request_latency_seconds_count 10
        vllm:time_to_first_token_seconds_sum 40
        """)
        #expect(m.promptTokens == 1000)
        #expect(m.generationTokens == 500)
        #expect(m.requestsRunning == 2)
        #expect(m.requestsWaiting == 1)
        #expect(m.kvCacheUsage == 0.42)
        #expect(m.avgInferenceLatency == 9)
        #expect(m.ttftSeconds == 40)
        #expect(m.decodeSeconds == 50)
    }
}

@Suite("Proxy-measured engine stats")
struct EngineProxyStatsTests {
    @Test("Accumulation + decode rate math")
    func math() {
        let stats = EngineProxyStats()
        stats.record(engineID: "e1", promptTokens: 100, completionTokens: 200,
                     e2eSeconds: 12, ttfbSeconds: 2)
        stats.record(engineID: "e1", promptTokens: 50, completionTokens: 100,
                     e2eSeconds: 8, ttfbSeconds: 3)
        let s = stats.snapshot(engineID: "e1")
        #expect(s?.requests == 2)
        #expect(s?.promptTokens == 150)
        #expect(s?.completionTokens == 300)
        // decode = (12+8) - (2+3) = 15s → 300/15 = 20 tok/s
        #expect(s?.decodeTokensPerSecond == 20)
        #expect(s?.avgLatencySeconds == 10)
        #expect(stats.snapshot(engineID: "other") == nil)
    }
}
