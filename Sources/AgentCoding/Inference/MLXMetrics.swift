import Foundation
import MLX

/// Cumulative engine counters, exposed at `/metrics` in Prometheus text under
/// `mlx_*` names that ``InferenceMetrics`` parses — so the Local-inference
/// window reflects the in-process MLX engine. TTFT and request-duration are
/// accumulated so the window can derive the true decode rate
/// (completion ÷ (duration − ttft)).
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
        let metalBytes = MLX.GPU.activeMemory
        return """
        # in-process MLX engine metrics
        mlx_prompt_tokens_total \(pt)
        mlx_completion_tokens_total \(ct)
        mlx_inference_ttft_seconds_sum \(ts)
        mlx_inference_ttft_seconds_count \(tc)
        mlx_inference_request_duration_seconds_sum \(ds)
        mlx_inference_request_duration_seconds_count \(dc)
        mlx_inference_requests_total \(total)
        mlx_http_requests_in_flight \(inf)
        mlx_scheduler_running_requests \(run)
        mlx_scheduler_waiting_requests 0
        mlx_model_loaded \(loaded)
        mlx_metal_memory_bytes \(metalBytes)
        mlx_engine_uptime_seconds \(Int(uptime))

        """
    }
}
