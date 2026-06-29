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

    @discardableResult
    func start(models: [InferenceModel], memoryBudgetGB: Int) -> Bool {
        lock.lock()
        served = Set(models.map(\.repo))
        estMem = Dictionary(models.map { ($0.repo, $0.estMemGB) }, uniquingKeysWith: { a, _ in a })
        let alreadyRunning = running
        lock.unlock()

        // Bind the loopback engine port FIRST, retrying briefly: on a model
        // switch the previous engine child may still be releasing the port (a
        // large model can take seconds to unload). A *silent* bind failure here
        // was the bug behind "switch model -> startTimedOut" — the child claimed
        // to be serving while nothing actually listened, so the parent's
        // readiness probe timed out. Now we retry, and fail loudly if we can't.
        if !alreadyRunning {
            guard bindAndListen() else {
                FileHandle.standardError.write(Data(
                    "[engine] FATAL: could not bind \(InferenceService.engineHost):\(InferenceService.enginePort) — address already in use (a previous engine still running?)\n".utf8))
                return false
            }
            Thread.detachNewThread { [weak self] in self?.acceptLoop() }
        }

        // Then EAGERLY load the served model(s) so the first request doesn't eat
        // the multi-second weight-load latency. Log the outcome (captured into
        // the Inference Engine Log) so a model that can't load says *why*.
        Task {
            await MLXEngine.shared.setMemoryBudget(memoryBudgetGB)
            for m in models {
                do {
                    _ = try await MLXEngine.shared.ensureLoaded(repo: m.repo, estMemGB: m.estMemGB)
                    FileHandle.standardError.write(Data("[engine] loaded \(m.repo)\n".utf8))
                } catch {
                    FileHandle.standardError.write(Data(
                        "[engine] failed to load \(m.repo): \(error.localizedDescription)\n".utf8))
                }
            }
        }
        return true
    }

    /// Bind + listen on the loopback engine port, retrying for a few seconds so
    /// a port still held by a just-stopped previous engine has time to clear.
    /// Sets `listenFD`/`running` and returns true on success.
    private func bindAndListen() -> Bool {
        let deadline = Date().addingTimeInterval(8)
        var attempt = 0
        while true {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            if fd >= 0 {
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
                if bound == 0 && listen(fd, 64) == 0 {
                    lock.lock(); listenFD = fd; running = true; lock.unlock()
                    return true
                }
                close(fd)
            }
            if Date() >= deadline { return false }
            attempt += 1
            FileHandle.standardError.write(Data(
                "[engine] port \(InferenceService.enginePort) busy — waiting for the previous engine to release it (retry \(attempt))…\n".utf8))
            Thread.sleep(forTimeInterval: 0.4)
        }
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
        // Bearer auth: the parent's admin key (internal probes) or a valid
        // persistent per-VM key (a guest VM — also identifies which profile).
        let auth = req.headerValue("authorization") ?? ""
        let token = auth.hasPrefix("Bearer ") ? String(auth.dropFirst(7)) : auth
        guard token == InferenceService.apiKey || EngineKey.profileID(forKey: token) != nil else {
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
        case ("POST", "/admin/serve"):
            return adminServe(req)
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

    /// Reconfigure a RUNNING server to serve exactly `models` under `budget`
    /// without a restart: update the advertised set + memory estimates, set the
    /// budget, unload models no longer wanted, and eager-load any new ones. This
    /// is what lets a second workspace add its model to the live engine instead
    /// of killing + respawning it.
    func reconfigure(models: [InferenceModel], memoryBudgetGB: Int) {
        lock.lock()
        served = Set(models.map(\.repo))
        estMem = Dictionary(models.map { ($0.repo, $0.estMemGB) }, uniquingKeysWith: { a, _ in a })
        lock.unlock()
        let keep = Set(models.map(\.repo))
        Task {
            await MLXEngine.shared.setMemoryBudget(memoryBudgetGB)
            await MLXEngine.shared.retain(only: keep)
            for m in models {
                do {
                    _ = try await MLXEngine.shared.ensureLoaded(repo: m.repo, estMemGB: m.estMemGB)
                    FileHandle.standardError.write(Data("[engine] loaded \(m.repo)\n".utf8))
                } catch {
                    FileHandle.standardError.write(Data(
                        "[engine] failed to load \(m.repo): \(error.localizedDescription)\n".utf8))
                }
            }
        }
    }

    /// `POST /admin/serve` — the parent reconfigures the live engine's model set
    /// + budget (admin key only; never a per-VM guest key). Body:
    /// `{ "budget": <gb>, "models": [{repo, estMemGB, toolParser, reasoningParser}] }`.
    private func adminServe(_ req: Request) -> Data {
        let auth = req.headerValue("authorization") ?? ""
        let token = auth.hasPrefix("Bearer ") ? String(auth.dropFirst(7)) : auth
        guard token == InferenceService.apiKey else {
            return Self.json(status: 403, object: ["error": ["message": "admin only"]])
        }
        guard let payload = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] else {
            return Self.json(status: 400, object: ["error": ["message": "invalid JSON body"]])
        }
        let budget = (payload["budget"] as? NSNumber)?.intValue ?? 0
        let models: [InferenceModel] = ((payload["models"] as? [[String: Any]]) ?? []).compactMap { m in
            guard let repo = m["repo"] as? String, !repo.isEmpty else { return nil }
            return InferenceModel(name: repo, repo: repo,
                                  estMemGB: (m["estMemGB"] as? NSNumber)?.intValue ?? 0,
                                  toolParser: m["toolParser"] as? String ?? "auto",
                                  reasoningParser: m["reasoningParser"] as? String)
        }
        reconfigure(models: models, memoryBudgetGB: budget)
        return Self.json(status: 200, object: ["ok": true, "serving": models.map(\.repo)])
    }

    private func modelsResponse() -> Data {
        let data = served.sorted().map { ["id": $0, "object": "model", "owned_by": "bromure-local"] }
        return Self.json(status: 200, object: ["object": "list", "data": data])
    }

    // MARK: - Inference

    private func inference(_ req: Request, wire: Wire) -> Data {
        guard let payload = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] else {
            return Self.json(status: 400, object: wire.errorJSON(message: "invalid JSON body",
                                                                 type: "invalid_request_error"))
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
            // Surface the reason in the Inference Engine Log too (this runs in
            // the engine child; its stderr is teed into the log window).
            FileHandle.standardError.write(Data(
                "[engine] request for \(repo) failed: \(err.localizedDescription)\n".utf8))
            // Native per-wire error envelope carrying the engine's real reason
            // (e.g. "Couldn't load <model>: unsupported architecture") so the
            // agent shows it instead of a generic "issue with the selected
            // model" (Bug#5). A model that can't load won't load on retry, so
            // use a 4xx the agent surfaces immediately rather than a 5xx it
            // retries.
            return Self.json(status: 400,
                             object: wire.errorJSON(message: err.localizedDescription,
                                                    type: "invalid_request_error"))
        case .success(let c):
            EngineMetrics.shared.record(prompt: c.promptTokens, completion: c.completionTokens,
                                  ttft: c.ttft, duration: c.ttft + c.decodeSeconds)
            // Per-query metadata → Inference Engine Log (this runs in the engine
            // child; its stderr is teed into the log window).
            let decodeTps = Double(c.completionTokens) / max(0.001, c.decodeSeconds)
            let meta = "[engine] \(repo) — prompt \(c.promptTokens) tok, completion \(c.completionTokens) tok, "
                + String(format: "TTFT %.2fs, decode %.1f tok/s\n", c.ttft, decodeTps)
            FileHandle.standardError.write(Data(meta.utf8))
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
