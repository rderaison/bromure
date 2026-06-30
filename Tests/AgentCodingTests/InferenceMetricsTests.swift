import Foundation
import Testing
@testable import bromure_ac

/// Coverage for the Prometheus `/metrics` parser + derived accessors,
/// focused on the prefill-rate semantics fix: prefill throughput must be
/// computed over `mlx_prefill_tokens_total` (the tokens actually prefilled,
/// i.e. prompt minus the reused KV-cache prefix), NOT the full prompt — with
/// prefix caching the full prompt over a cached-prefix TTFT reads as absurdly
/// high. See InferenceMetrics.prefilledTokens / decodeSeconds.
@Suite("InferenceMetrics parse + accessors")
struct InferenceMetricsTests {

    /// One crafted block exercised by several tests. ttft/duration chosen so
    /// the derived values are binary-exact (no float fuzz).
    private static let block = """
    # HELP mlx_prompt_tokens_total Prompt tokens
    # TYPE mlx_prompt_tokens_total counter
    mlx_prompt_tokens_total{model="a"} 20000
    mlx_prefill_tokens_total{model="a"} 150
    mlx_completion_tokens_total{model="a"} 640
    mlx_inference_ttft_seconds_sum 0.5
    mlx_inference_request_duration_seconds_sum 8.0
    mlx_inference_request_duration_seconds_count 2
    mlx_scheduler_running_requests 3
    mlx_scheduler_waiting_requests 1
    mlx_http_requests_in_flight 4
    mlx_cache_hit_rate 0.9
    mlx_metal_memory_bytes 1073741824
    mlx_engine_uptime_seconds 42
    """

    @Test("Prefilled tokens read mlx_prefill_tokens_total, distinct from prompt")
    func prefillSemantics() {
        let m = InferenceMetrics.parse(Self.block)
        #expect(m.promptTokens == 20000)
        #expect(m.prefilledTokens == 150)
        // The whole point of the fix: prefill ≠ prompt under prefix caching.
        #expect(m.prefilledTokens != m.promptTokens)
    }

    @Test("Basic token + request accessors map to the real metric names")
    func basicAccessors() {
        let m = InferenceMetrics.parse(Self.block)
        #expect(m.generationTokens == 640)
        #expect(m.requestsRunning == 3)
        #expect(m.requestsWaiting == 1)
        #expect(m.requestsInFlight == 4)
        #expect(m.cacheHitRate == 0.9)
        #expect(m.metalMemoryBytes == 1_073_741_824)
        #expect(m.uptimeSeconds == 42)
    }

    @Test("ttft / decode / avg-latency derive from the duration counters")
    func derivedTimings() {
        let m = InferenceMetrics.parse(Self.block)
        #expect(m.ttftSeconds == 0.5)
        // decode = duration_sum − ttft_sum = 8.0 − 0.5 = 7.5 (binary-exact).
        #expect(m.decodeSeconds == 7.5)
        // avg = duration_sum / count = 8.0 / 2 = 4.0.
        #expect(m.avgInferenceLatency == 4.0)
    }

    @Test("decodeSeconds clamps to ≥ 0 when ttft exceeds duration")
    func decodeClamps() {
        let m = InferenceMetrics.parse("""
        mlx_inference_request_duration_seconds_sum 1.0
        mlx_inference_ttft_seconds_sum 9.0
        """)
        #expect(m.decodeSeconds == 0)
    }

    @Test("decodeSeconds nil without a duration counter")
    func decodeNilNoDuration() {
        let m = InferenceMetrics.parse("mlx_inference_ttft_seconds_sum 0.3")
        #expect(m.decodeSeconds == nil)
    }

    @Test("avgInferenceLatency nil when count is zero")
    func avgNilZeroCount() {
        let m = InferenceMetrics.parse("""
        mlx_inference_request_duration_seconds_sum 5.0
        mlx_inference_request_duration_seconds_count 0
        """)
        #expect(m.avgInferenceLatency == nil)
    }

    @Test("Pre-counter engine: prefilledTokens nil, promptTokens still present")
    func preCounterFallback() {
        // An engine built before mlx_prefill_tokens_total existed.
        let m = InferenceMetrics.parse("mlx_prompt_tokens_total 500")
        #expect(m.promptTokens == 500)
        #expect(m.prefilledTokens == nil)
    }

    @Test("Label sets are summed under the base name")
    func sumsLabels() {
        let m = InferenceMetrics.parse("""
        mlx_completion_tokens_total{model="a"} 80
        mlx_completion_tokens_total{model="b"} 40
        mlx_completion_tokens_total{model="c"} 5
        """)
        #expect(m.generationTokens == 125)
    }

    @Test("Comments, blanks, and unparseable lines are skipped")
    func tolerantParsing() {
        let m = InferenceMetrics.parse("""
        # a comment
        \n
        garbage line without a numeric value
        mlx_prompt_tokens_total 7
        not_a_metric foo
        """)
        #expect(m.promptTokens == 7)
        #expect(m.values["not_a_metric"] == nil)   // "foo" isn't a Double
    }

    @Test("first(_:) returns the earliest present candidate name")
    func firstHelper() {
        let m = InferenceMetrics.parse("vllm_mlx_alt 3\nplain 9")
        #expect(m.first(["missing", "plain"]) == 9)
        #expect(m.first(["missing", "vllm_mlx_alt"]) == 3)
        #expect(m.first(["nope", "nada"]) == nil)
    }

    @Test("Absent metrics surface as nil accessors")
    func absentNil() {
        let m = InferenceMetrics.parse("")
        #expect(m.promptTokens == nil)
        #expect(m.prefilledTokens == nil)
        #expect(m.generationTokens == nil)
        #expect(m.ttftSeconds == nil)
        #expect(m.cacheHitRate == nil)
        #expect(m.values.isEmpty)
    }
}
