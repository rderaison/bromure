import Foundation
import MLXLMCommon

/// The in-process HTTP server that fronts ``MLXEngine`` — the Swift-native
/// replacement for the `vllm-mlx serve` subprocess. Binds
/// `InferenceService.enginePort` (loopback) and speaks the same OpenAI /
/// Anthropic / Responses surface the guest agents expect.
///
/// Non-streaming requests return complete protocol JSON. `stream: true`
/// switches to a *proxy-internal* SSE protocol (the repair proxy is this
/// server's only client): thinking-stripped text deltas as they decode, then
/// one final frame carrying the exact native message the buffered path would
/// have returned — the proxy relays deltas to the guest live and still runs
/// the full repair pipeline on the final (see ``DeltaRelay`` /
/// `InferenceRepairProxy.streamBuiltinConversation`). Guest-wire SSE and
/// tool-call repair remain the proxy's job either way: guest → vsock →
/// repair proxy → this server. Both host ports are kernel-assigned (dynamic)
/// to avoid colliding with whatever else holds the old 11434 / 11500.
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
            guard let resp = respond(to: req, streamFD: clientFD) else {
                break   // streamed directly on the socket (Connection: close)
            }
            if !Self.writeAll(clientFD, resp) { break }
            if req.headerValue("connection")?.lowercased() == "close" { break }
        }
    }

    private func respond(to req: Request, streamFD: Int32? = nil) -> Data? {
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
            return inference(req, wire: .messages, streamFD: streamFD)
        case ("POST", "/v1/chat/completions"):
            return inference(req, wire: .chat, streamFD: streamFD)
        case ("POST", "/v1/responses"):
            return inference(req, wire: .responses, streamFD: streamFD)
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

    private func inference(_ req: Request, wire: Wire, streamFD: Int32? = nil) -> Data? {
        guard let payload = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] else {
            return Self.json(status: 400, object: wire.errorJSON(message: "invalid JSON body",
                                                                 type: "invalid_request_error"))
        }
        let parsed = WireRequest.parse(payload, wire: wire)
        // Selector → repo: guests configured by an older build (or a stale
        // meta share) can send the catalog ID; the engine stores weights by
        // repo, so an unresolved ID 400s as "not downloaded" even when the
        // model is right there. resolve() also synthesizes raw org/repo.
        let repo = CatalogStore.shared.resolve(parsed.model)?.repo ?? parsed.model

        EngineMetrics.shared.requestStarted()
        defer { EngineMetrics.shared.requestFinished() }

        // Streaming (`stream: true` + a socket to write on): the repair proxy
        // is the ONLY client of this server, so the stream is a proxy-internal
        // protocol, not a wire format — raw text deltas as they decode, then
        // ONE final frame carrying the exact native message the buffered path
        // would have returned (so repair sees no difference):
        //   data: {"d":"<delta>"}      (thinking-stripped, left-trimmed)
        //   data: {"final": {…}}       (wire.nonStreamingJSON, verbatim)
        //   data: [DONE]
        // A failure before the first delta returns the plain buffered error
        // (no SSE), so the proxy can fall back cleanly.
        let relay: DeltaRelay? = (streamFD != nil && payload["stream"] as? Bool == true)
            ? DeltaRelay(fd: streamFD!) : nil

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
                if ProcessInfo.processInfo.environment["BROMURE_STREAM_DEBUG"] != nil {
                    FileHandle.standardError.write(Data("[relay] inference stream=\(payload["stream"] as? Bool ?? false) relay=\(relay != nil)\n".utf8))
                }
                let completion = try await MLXEngine.shared.generate(
                    repo: repo, messages: parsed.messages, tools: parsed.tools,
                    params: params, estMemGB: estMem[repo] ?? 0) { delta in
                    // Streaming: relay the delta (returning false on a dead
                    // client cancels the generation instead of decoding into
                    // the void). Buffered: keep generating.
                    relay?.append(delta) ?? true
                }
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
            let errObj = wire.errorJSON(message: err.localizedDescription,
                                        type: "invalid_request_error")
            if let relay, relay.started {
                // Deltas already went out — close the stream with the error.
                relay.finish(errorFrame: errObj, status: 400)
                return nil
            }
            // Nothing streamed yet (load failures happen before the first
            // token) → plain buffered error, so the proxy falls back cleanly.
            return Self.json(status: 400, object: errObj)
        case .success(let c):
            EngineMetrics.shared.record(prompt: c.promptTokens, prefill: c.prefilledTokens,
                                  completion: c.completionTokens,
                                  ttft: c.ttft, duration: c.ttft + c.decodeSeconds)
            // Per-query metadata → Inference Engine Log (this runs in the engine
            // child; its stderr is teed into the log window). `prefilled` is the
            // uncached suffix actually computed; the prefill rate is over that,
            // not the full prompt (which a KV-cache hit mostly skips).
            let decodeTps = Double(c.completionTokens) / max(0.001, c.decodeSeconds)
            let prefillTps = Double(c.prefilledTokens) / max(0.001, c.ttft)
            let meta = "[engine] \(repo) — prompt \(c.promptTokens) tok (prefilled \(c.prefilledTokens)), "
                + "completion \(c.completionTokens) tok, "
                + String(format: "TTFT %.2fs (%.0f tok/s prefill), decode %.1f tok/s\n",
                         c.ttft, prefillTps, decodeTps)
            FileHandle.standardError.write(Data(meta.utf8))
            // Telemetry to bromure.io when enrolled (no-ops otherwise) is wired
            // in the InferenceService integration stage.
            let body = wire.nonStreamingJSON(model: repo, completion: c)
            if let relay {
                relay.finish(final: body)
                return nil
            }
            return Self.json(status: 200, object: body)
        }
    }

    /// Streams generation deltas to the connected repair proxy. Thinking is
    /// stripped incrementally (mirroring `MLXEngine.stripThinking`) and the
    /// text is left-trimmed so the streamed prefix always matches the final
    /// message's text; an 8-char holdback keeps a `<think>`/`</think>` tag
    /// split across deltas from ever leaking. Writes happen from the engine
    /// task while the connection thread is parked on the completion
    /// semaphore, so writers never interleave.
    private final class DeltaRelay {
        private let fd: Int32
        private var raw = ""
        private var sentCount = 0          // chars of visible() already sent
        private(set) var started = false
        private var alive = true
        private var appendCalls = 0        // BROMURE_STREAM_DEBUG logging only

        init(fd: Int32) { self.fd = fd }

        /// `stripThinking` minus its final trim (only left-trimmed): the
        /// visible prefix must only ever grow as `raw` grows — a shrink would
        /// mean unsending bytes.
        private func visible() -> String {
            var out = ""
            var rest = Substring(raw)
            while let open = rest.range(of: "<think>") {
                out += rest[..<open.lowerBound]
                if let close = rest.range(of: "</think>", range: open.upperBound..<rest.endIndex) {
                    rest = rest[close.upperBound...]
                } else {
                    rest = ""   // unterminated think block → hold the remainder
                }
            }
            out += rest
            // Gemma-family reasoning rides a `<|channel>thought…` channel, not
            // `<think>`; its stripping happens downstream of the completion.
            // Hold everything from the first channel marker — those turns
            // effectively arrive at finish, exactly like the buffered path.
            if let ch = out.range(of: "<|channel") { out = String(out[..<ch.lowerBound]) }
            return String(Substring(out).drop(while: { $0.isWhitespace }))
        }

        /// Returns false once the client is gone, cancelling the generation.
        func append(_ delta: String) -> Bool {
            guard alive else { return false }
            if ProcessInfo.processInfo.environment["BROMURE_STREAM_DEBUG"] != nil, raw.isEmpty {
                FileHandle.standardError.write(Data("[relay] first append len=\(delta.count)\n".utf8))
            }
            raw += delta
            let vis = visible()
            // 12 > every held marker ("</think>" = 8, "<|channel" = 9), so a
            // tag split across deltas can never partially leak.
            let release = max(0, vis.count - 12)
            if ProcessInfo.processInfo.environment["BROMURE_STREAM_DEBUG"] != nil {
                appendCalls += 1
                if appendCalls <= 3 || appendCalls % 50 == 0 {
                    let head = String(raw.prefix(70)).replacingOccurrences(of: "\n", with: "\\n")
                    FileHandle.standardError.write(Data(
                        "[relay] append#\(appendCalls) raw=\(raw.count) vis=\(vis.count) release=\(release) sent=\(sentCount) alive=\(alive) head=\(head)\n".utf8))
                }
            }
            guard release > sentCount else { return alive }
            let chunk = String(vis.prefix(release).dropFirst(sentCount))
            sentCount = release
            send(frame: ["d": chunk])
            return alive
        }

        func finish(final: [String: Any]) {
            send(frame: ["final": final])
            write("data: [DONE]\n\n")
        }

        func finish(errorFrame: [String: Any], status: Int) {
            send(frame: ["error": errorFrame, "status": status])
            write("data: [DONE]\n\n")
        }

        private func begin() {
            guard !started else { return }
            started = true
            write("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
                  + "Cache-Control: no-cache\r\nConnection: close\r\n\r\n")
        }

        private func send(frame: [String: Any]) {
            begin()
            let d = (try? JSONSerialization.data(withJSONObject: frame))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            write("data: \(d)\n\n")
        }

        private func write(_ s: String) {
            guard alive else { return }
            if !MLXServer.writeAll(fd, Data(s.utf8)) { alive = false }
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
