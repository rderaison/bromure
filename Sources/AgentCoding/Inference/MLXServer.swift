import Foundation
import MLXLMCommon

/// The in-process HTTP server that fronts ``MLXEngine`` — the Swift-native
/// replacement for the `vllm-mlx serve` subprocess. Binds
/// `InferenceService.enginePort` (loopback) and speaks the same OpenAI /
/// Anthropic / Responses surface the guest agents expect.
///
/// It returns *non-streaming* protocol JSON. Streaming + tool-call repair stay
/// the job of ``InferenceRepairProxy`` (port 11500), which already buffers a
/// non-streaming upstream message, rescues leaked tool calls, and re-emits SSE
/// for all three wire formats — so the bridge wiring is unchanged: guest →
/// vsock → 11500 (repair) → 11434 (this server).
///
/// Same shape as the other small servers here: one accept loop, a thread per
/// connection, raw HTTP/1.1.
final class MLXServer: @unchecked Sendable {
    static let shared = MLXServer()

    private var listenFD: Int32 = -1
    private var running = false
    private let lock = NSLock()

    /// Repos this server will serve (set by InferenceService on start). A
    /// request's `model` must be one of these, or already in the hub cache.
    private var served: Set<String> = []
    /// Per-repo memory estimate, for MLXEngine's LRU budget.
    private var estMem: [String: Int] = [:]
    private let startedAt = Date()

    // MARK: - Lifecycle

    func start(models: [InferenceModel], memoryBudgetGB: Int) {
        lock.lock()
        served = Set(models.map(\.repo))
        estMem = Dictionary(models.map { ($0.repo, $0.estMemGB) }, uniquingKeysWith: { a, _ in a })
        let alreadyRunning = running
        lock.unlock()

        // Set the budget, then EAGERLY load the served model(s) so the first
        // request doesn't eat the multi-second weight-load latency (~7s for an
        // 8B, measured). Background so the accept loop / readiness probe is up
        // immediately; requests that arrive mid-load just await the same load.
        Task {
            await MLXEngine.shared.setMemoryBudget(memoryBudgetGB)
            for m in models {
                _ = try? await MLXEngine.shared.ensureLoaded(repo: m.repo, estMemGB: m.estMemGB)
            }
        }
        if alreadyRunning { return }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(InferenceService.enginePort).bigEndian)
        _ = inet_pton(AF_INET, InferenceService.engineHost, &addr.sin_addr)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 || listen(fd, 64) != 0 { close(fd); return }
        lock.lock(); listenFD = fd; running = true; lock.unlock()
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    func stop() {
        lock.lock(); let fd = listenFD; running = false; listenFD = -1; lock.unlock()
        if fd >= 0 { close(fd) }
        Task { await MLXEngine.shared.unloadAll() }
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    private func acceptLoop() {
        while true {
            let c = accept(listenFD, nil, nil)
            if c < 0 { break }
            Thread.detachNewThread { [weak self] in self?.handle(clientFD: c) }
        }
    }

    // MARK: - Connection handling

    private func handle(clientFD: Int32) {
        defer { close(clientFD) }
        while let req = InferenceRepairProxy.readRequest(fd: clientFD) {
            let resp = respond(to: req)
            if !Self.writeAll(clientFD, resp) { break }
            if req.headerValue("connection")?.lowercased() == "close" { break }
        }
    }

    private func respond(to req: Request) -> Data {
        // Bearer auth — same per-run key the engine used.
        let auth = req.headerValue("authorization") ?? ""
        guard auth == "Bearer \(InferenceService.apiKey)" else {
            return Self.json(status: 401, object: ["error": ["message": "unauthorized"]])
        }

        let path = req.path.split(separator: "?").first.map(String.init) ?? req.path
        switch (req.method, path) {
        case ("GET", "/v1/models"):
            return modelsResponse()
        case ("GET", "/metrics"):
            return Self.text(status: 200, contentType: "text/plain; version=0.0.4",
                             body: EngineMetrics.shared.prometheus(uptime: Date().timeIntervalSince(startedAt),
                                                             loaded: served.count))
        case ("POST", "/v1/messages"):
            return inference(req, wire: .messages)
        case ("POST", "/v1/chat/completions"):
            return inference(req, wire: .chat)
        case ("POST", "/v1/responses"):
            return inference(req, wire: .responses)
        default:
            return Self.json(status: 404, object: ["error": ["message": "not found"]])
        }
    }

    private func modelsResponse() -> Data {
        let data = served.sorted().map { ["id": $0, "object": "model", "owned_by": "bromure-local"] }
        return Self.json(status: 200, object: ["object": "list", "data": data])
    }

    // MARK: - Inference

    private func inference(_ req: Request, wire: Wire) -> Data {
        guard let payload = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] else {
            return Self.json(status: 400, object: ["error": ["message": "invalid JSON body"]])
        }
        let parsed = WireRequest.parse(payload, wire: wire)
        let repo = parsed.model

        EngineMetrics.shared.requestStarted()
        defer { EngineMetrics.shared.requestFinished() }

        // Bridge the sync connection thread to the async engine actor.
        let sem = DispatchSemaphore(value: 0)
        var result: Result<MLXEngine.Completion, Error>!
        Task {
            do {
                // Silent thinking: let the model reason (quality), but the
                // <think> block is always stripped from the reply
                // (MLXEngine.stripThinking) so it never reaches the agent or
                // bloats the next turn's transcript. Set BROMURE_THINKING=0 to
                // skip thinking entirely when you'd rather have the speed.
                let thinkEnv = ProcessInfo.processInfo.environment["BROMURE_THINKING"]
                let thinking = !(thinkEnv == "0" || thinkEnv?.lowercased() == "false")
                // KV-cache quantization OFF by default. It speeds decode ~10% at
                // long context and halves KV memory, but it degraded the local
                // model's output enough to break tool calls (malformed JSON,
                // mixed formats) — correctness wins over the marginal speedup.
                // Opt back in with BROMURE_KVBITS=8 (or 4); BROMURE_KVBITS_START
                // sets the token threshold so short prompts stay exact.
                let env = ProcessInfo.processInfo.environment
                let kvBitsRaw = env["BROMURE_KVBITS"].flatMap { Int($0) } ?? 0
                let kvBits = kvBitsRaw > 0 ? kvBitsRaw : nil
                let kvStart = env["BROMURE_KVBITS_START"].flatMap { Int($0) } ?? 4096
                let params = MLXEngine.Params(
                    maxTokens: parsed.maxTokens ?? 2048,
                    temperature: parsed.temperature ?? 0.6,
                    topP: parsed.topP ?? 1.0,
                    kvBits: kvBits,
                    kvBitsStartAt: kvStart,
                    enableThinking: thinking)
                let completion = try await MLXEngine.shared.generate(
                    repo: repo, messages: parsed.messages, tools: parsed.tools,
                    params: params, estMemGB: estMem[repo] ?? 0) { _ in true }
                result = .success(completion)
            } catch {
                result = .failure(error)
            }
            sem.signal()
        }
        sem.wait()

        switch result! {
        case .failure(let err):
            return Self.json(status: 500, object: ["error": ["message": "\(err.localizedDescription)"]])
        case .success(let c):
            EngineMetrics.shared.record(prompt: c.promptTokens, completion: c.completionTokens,
                                  ttft: c.ttft, duration: c.ttft + c.decodeSeconds)
            // Telemetry to bromure.io when enrolled (no-ops otherwise) is wired
            // in the InferenceService integration stage.
            let body = wire.nonStreamingJSON(model: repo, completion: c)
            return Self.json(status: 200, object: body)
        }
    }

    // MARK: - HTTP helpers

    typealias Request = InferenceRepairProxy.Request

    static func json(status: Int, object: [String: Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return text(status: status, contentType: "application/json", body: body)
    }

    static func text(status: Int, contentType: String, body: Data) -> Data {
        var s = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\n"
        s += "Content-Type: \(contentType)\r\n"
        s += "Content-Length: \(body.count)\r\n"
        s += "Connection: keep-alive\r\n\r\n"
        var out = Data(s.utf8); out.append(body); return out
    }

    static func text(status: Int, contentType: String, body: String) -> Data {
        text(status: status, contentType: contentType, body: Data(body.utf8))
    }

    @discardableResult
    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var off = 0
            while off < data.count {
                let w = write(fd, base + off, data.count - off)
                if w <= 0 { return false }
                off += w
            }
            return true
        }
    }
}
