import Foundation

/// Cumulative engine counters, exposed at `/metrics` in Prometheus text using
/// the same `vllm_mlx_*` names ``InferenceMetrics`` already parses — so the
/// Local-inference window keeps working unchanged against the in-process
/// engine. TTFT and request-duration are accumulated so the window can derive
/// the true decode rate (completion ÷ (duration − ttft)).
final class EngineMetrics: @unchecked Sendable {
    static let shared = EngineMetrics()
    private let lock = NSLock()

    private var promptTokensTotal = 0
    private var completionTokensTotal = 0
    private var ttftSum = 0.0
    private var ttftCount = 0
    private var durationSum = 0.0
    private var durationCount = 0
    private var inFlight = 0
    private var requestsTotal = 0

    func requestStarted() { lock.lock(); inFlight += 1; requestsTotal += 1; lock.unlock() }
    func requestFinished() { lock.lock(); inFlight = max(0, inFlight - 1); lock.unlock() }

    func record(prompt: Int, completion: Int, ttft: TimeInterval, duration: TimeInterval) {
        lock.lock()
        promptTokensTotal += prompt
        completionTokensTotal += completion
        ttftSum += ttft; ttftCount += 1
        durationSum += duration; durationCount += 1
        lock.unlock()
    }

    func prometheus(uptime: TimeInterval, loaded: Int) -> String {
        lock.lock()
        let pt = promptTokensTotal, ct = completionTokensTotal
        let ts = ttftSum, tc = ttftCount, ds = durationSum, dc = durationCount
        let inf = inFlight, run = inFlight, total = requestsTotal
        lock.unlock()
        return """
        # in-process MLX engine metrics
        vllm_mlx_prompt_tokens_total \(pt)
        vllm_mlx_completion_tokens_total \(ct)
        vllm_mlx_inference_ttft_seconds_sum \(ts)
        vllm_mlx_inference_ttft_seconds_count \(tc)
        vllm_mlx_inference_request_duration_seconds_sum \(ds)
        vllm_mlx_inference_request_duration_seconds_count \(dc)
        vllm_mlx_inference_requests_total \(total)
        vllm_mlx_http_requests_in_flight \(inf)
        vllm_mlx_scheduler_running_requests \(run)
        vllm_mlx_scheduler_waiting_requests 0
        vllm_mlx_model_loaded \(loaded)
        vllm_mlx_engine_uptime_seconds \(Int(uptime))

        """
    }
}
