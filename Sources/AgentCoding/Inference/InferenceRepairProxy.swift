import Foundation

/// A tiny loopback HTTP proxy that sits in front of the vllm-mlx engine and
/// applies `ToolCallRepair` to `/v1/messages` responses. The vsock bridge
/// (and the MITM local route) point here instead of straight at the engine,
/// so leaked-as-text tool calls become real `tool_use` blocks before the
/// agent ever sees them.
///
/// `/v1/messages` is buffered (we force `stream:false` upstream so we can
/// inspect the whole message, then re-emit it as SSE). Every other path is
/// forwarded transparently. Loopback-only; one accept loop, a thread per
/// connection — same shape as the other small servers here.
final class InferenceRepairProxy: @unchecked Sendable {
    static let shared = InferenceRepairProxy()

    /// Port the bridge/clients connect to — **kernel-assigned** in
    /// `startIfNeeded` (was a fixed 11500, which clashed with anything else
    /// holding that port). 0 until started. The engine itself binds
    /// `InferenceService.enginePort`; we forward there.
    private(set) var listenPort = 0

    private var listenFD: Int32 = -1
    private var running = false
    private let lock = NSLock()

    /// Set by the app: record a per-VM local-inference call into the TraceStore.
    /// The proxy runs in the parent process, so it records directly (no IPC).
    var onLocalTrace: ((_ event: [String: Any]) -> Void)?

    /// Set by the app: the given profile's agent is mid local-inference call —
    /// drives the "thinking" indicator. Fired at request start and re-fired
    /// while the (possibly long) generation is in flight.
    var onLocalActivity: ((_ profileID: UUID) -> Void)?

    /// profile id → the repo the `bromure-local` sentinel resolves to for that
    /// workspace. The guest's agents are pinned to the sentinel; switching the
    /// workspace's model just updates this map, so no agent restart is needed.
    private let modelMapLock = NSLock()
    private var activeModelByProfile: [UUID: String] = [:]

    func setActiveModel(_ profileID: UUID, repo: String) {
        modelMapLock.lock(); activeModelByProfile[profileID] = repo; modelMapLock.unlock()
    }
    func clearActiveModel(_ profileID: UUID) {
        modelMapLock.lock(); activeModelByProfile[profileID] = nil; modelMapLock.unlock()
    }
    func activeModel(for profileID: UUID) -> String? {
        modelMapLock.lock(); defer { modelMapLock.unlock() }; return activeModelByProfile[profileID]
    }

    /// Start the accept loop if not already running. Idempotent.
    func startIfNeeded(enginePort: Int = InferenceService.enginePort) {
        lock.lock(); defer { lock.unlock() }
        if running { return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0   // kernel-assigned: avoids clashing with whatever holds 11500
        _ = inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 || listen(fd, 64) != 0 { close(fd); return }
        // Read back the port the kernel handed us so the vsock bridge + MITM
        // routing know where to forward.
        var actual = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        listenPort = Int(UInt16(bigEndian: actual.sin_port))
        listenFD = fd
        running = true
        Thread.detachNewThread { [weak self] in self?.acceptLoop(enginePort: enginePort) }
    }

    private func acceptLoop(enginePort: Int) {
        while true {
            let c = accept(listenFD, nil, nil)
            if c < 0 { break }
            Thread.detachNewThread { [weak self] in self?.handle(clientFD: c, enginePort: enginePort) }
        }
    }

    // MARK: - Per-connection

    private func handle(clientFD: Int32, enginePort: Int) {
        defer { close(clientFD) }
        while let req = Self.readRequest(fd: clientFD) {
            let resp = Self.respond(to: req, enginePort: enginePort)
            if !Self.writeAll(clientFD, resp) { break }
            // Honour keep-alive; the read loop exits on EOF / next-request error.
            if req.headerValue("connection")?.lowercased() == "close" { break }
        }
    }

    struct Request {
        var method: String
        var path: String
        var headers: [(String, String)]
        var body: Data
        func headerValue(_ name: String) -> String? {
            headers.first { $0.0.lowercased() == name.lowercased() }?.1
        }
    }

    /// Hard ceilings on what we'll buffer from a single request. This proxy
    /// runs in the **parent app process** and the vsock bridge splices *any*
    /// guest connection straight to it, so an attacker-controlled
    /// `Content-Length` (or an endless header stream) would otherwise grow
    /// these buffers until the host app OOMs — before the upstream engine ever
    /// checks the per-VM bearer. Real inference requests (prompt + tools) are
    /// comfortably under the body cap; anything larger is dropped.
    static let maxHeaderBytes = 256 * 1024          // 256 KB of request headers
    static let maxBodyBytes   = 64 * 1024 * 1024    // 64 MB request body

    /// Read one HTTP/1.1 request (request line + headers + Content-Length body).
    static func readRequest(fd: Int32) -> Request? {
        var buf = Data()
        // Read until end of headers.
        var tmp = [UInt8](repeating: 0, count: 16 * 1024)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { return nil }
            buf.append(contentsOf: tmp[0..<n])
            headerEnd = buf.range(of: Data("\r\n\r\n".utf8))
            // Bound the header scan — a guest that never sends CRLFCRLF must
            // not be able to grow `buf` without limit.
            if headerEnd == nil && buf.count > maxHeaderBytes { return nil }
        }
        guard let he = headerEnd,
              let head = String(data: buf.subdata(in: 0..<he.lowerBound), encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        guard let reqLine = lines.first else { return nil }
        let parts = reqLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [(String, String)] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers.append((String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                            String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
        }
        var body = buf.subdata(in: he.upperBound..<buf.endIndex)
        let contentLength = headers.first { $0.0.lowercased() == "content-length" }
            .flatMap { Int($0.1) } ?? 0
        // Reject an oversized declared body before draining a single byte of it.
        if contentLength > maxBodyBytes { return nil }
        while body.count < contentLength {
            let n = read(fd, &tmp, tmp.count)
            if n <= 0 { break }
            body.append(contentsOf: tmp[0..<n])
            if body.count > maxBodyBytes { return nil }
        }
        return Request(method: String(parts[0]), path: String(parts[1]), headers: headers, body: body)
    }

    /// The three agent inference endpoints we repair, each with its own
    /// response/SSE shape. `rescue(text:)` underneath is shared.
    private enum API {
        case messages   // Anthropic /v1/messages (Claude)
        case chat       // OpenAI /v1/chat/completions (Grok)
        case responses  // OpenAI /v1/responses (Codex)
        static func of(path: String) -> API? {
            switch path.split(separator: "?").first.map(String.init) {
            case "/v1/messages": return .messages
            case "/v1/chat/completions": return .chat
            case "/v1/responses": return .responses
            default: return nil
            }
        }
        /// A wire-native error body so the agent surfaces the reason instead of
        /// a blank response. Anthropic needs `{"type":"error","error":{…}}`; the
        /// OpenAI surfaces use `{"error":{…}}`. Mirrors `Wire.errorJSON`.
        func errorBody(message: String) -> [String: Any] {
            switch self {
            case .messages:
                return ["type": "error", "error": ["type": "api_error", "message": message]]
            case .chat, .responses:
                return ["error": ["message": message, "type": "api_error", "code": NSNull()]]
            }
        }

        /// Repair the buffered upstream message, then render it back as SSE.
        func repairedSSE(_ message: [String: Any], toolNames: Set<String>) -> Data {
            switch self {
            case .messages: return ToolCallRepair.sse(message: ToolCallRepair.repair(message: message, toolNames: toolNames))
            case .chat: return ToolCallRepair.chatSSE(ToolCallRepair.repairChat(message, toolNames: toolNames))
            case .responses: return ToolCallRepair.responsesSSE(ToolCallRepair.repairResponses(message, toolNames: toolNames))
            }
        }

        /// Tool names declared in the request body — Anthropic `tools[].name`
        /// and OpenAI `tools[].function.name`.
        static func toolNames(in payload: [String: Any]) -> Set<String> {
            var names = Set<String>()
            for t in (payload["tools"] as? [[String: Any]]) ?? [] {
                if let n = t["name"] as? String { names.insert(n) }
                if let fn = t["function"] as? [String: Any], let n = fn["name"] as? String { names.insert(n) }
            }
            return names
        }

        // MARK: - Stuck-preamble continuation helpers

        /// The assistant text in the buffered upstream message.
        func assistantText(_ message: [String: Any]) -> String {
            switch self {
            case .messages:
                return (message["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
            case .chat:
                return ((message["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String ?? ""
            case .responses:
                return (message["output"] as? [[String: Any]])?.compactMap { item in
                    (item["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
                }.joined() ?? ""
            }
        }

        /// True when the turn carries no tool call — neither a native one from the
        /// engine's parser nor one we could rescue from the text.
        func hasNoToolCall(_ message: [String: Any], toolNames: Set<String>) -> Bool {
            switch self {
            case .messages:
                if (message["content"] as? [[String: Any]])?.contains(where: { ($0["type"] as? String) == "tool_use" }) == true { return false }
            case .chat:
                if let m = (message["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
                   (m["tool_calls"] as? [Any])?.isEmpty == false { return false }
            case .responses:
                if (message["output"] as? [[String: Any]])?.contains(where: { ($0["type"] as? String) == "function_call" }) == true { return false }
            }
            return ToolCallRepair.rescue(text: assistantText(message), toolNames: toolNames).blocks.isEmpty
        }

        /// The turn ended cleanly (model's own end-of-turn), not truncated by the
        /// output-token cap — a truncated call needs more tokens, not a re-prompt.
        func cleanStop(_ message: [String: Any]) -> Bool {
            switch self {
            case .messages: return (message["stop_reason"] as? String) != "max_tokens"
            case .chat:     return ((message["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String) != "length"
            case .responses: return (message["status"] as? String ?? "completed") == "completed"
            }
        }

        /// Append a user turn that quotes the preamble back and asks the model to
        /// call the tool it skipped. A user message (not an assistant one) keeps the
        /// shape well-known across engines. `attempt` escalates the wording.
        func continuationPayload(_ payload: [String: Any], preamble: String, attempt: Int) -> [String: Any] {
            var p = payload
            let head = "Your previous response ended after describing the next step:\n\n\"\(String(preamble.suffix(500)))\"\n\n…but you did NOT call a tool to perform it."
            let nudge = attempt == 0
                ? head + " Call the appropriate tool now to carry out exactly that step. Respond with the tool call only — no prose."
                // Show the XML format (NOT JSON): the values are raw, so a large
                // file body doesn't have to be JSON-escaped — which a quantized
                // model botches, producing a malformed call that can't be rescued.
                : head + " Output a tool call NOW and nothing else, in this EXACT format (raw values, NOT JSON):\n<tool_call>\n<function=ExactToolName>\n<parameter=name>\nvalue\n</parameter>\n</function>\n</tool_call>\nPerform the step; do not describe it again."
            switch self {
            case .responses:
                var input = (payload["input"] as? [[String: Any]]) ?? []
                input.append(["role": "user", "content": [["type": "input_text", "text": nudge]]])
                p["input"] = input
            case .chat, .messages:
                var msgs = (payload["messages"] as? [[String: Any]]) ?? []
                msgs.append(["role": "user", "content": nudge])
                p["messages"] = msgs
            }
            // Honored if the engine implements it; harmless otherwise.
            p["tool_choice"] = "required"
            return p
        }
    }

    /// Build the full HTTP response bytes for a request.
    static func respond(to req: Request, enginePort: Int) -> Data {
        let base = "http://127.0.0.1:\(enginePort)"

        // Anything that isn't a repairable inference POST: transparent proxy.
        guard let api = API.of(path: req.path), req.method == "POST",
              var payload = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any] else {
            return passthrough(req, base: base)
        }

        // Identify the calling VM from its per-VM key (nil for admin/internal).
        let rawAuth = req.headerValue("authorization") ?? ""
        let pid = EngineKey.profileID(forKey: rawAuth.hasPrefix("Bearer ") ? String(rawAuth.dropFirst(7)) : rawAuth)

        // Resolve the local-model sentinel: the guest always sends
        // "bromure-local"; map it to this workspace's currently-active repo so
        // switching the model is a host-side remap (no agent restart). Any
        // explicit model is left untouched.
        if let pid, (payload["model"] as? String) == InferenceService.localModelSentinel,
           let repo = shared.activeModel(for: pid) {
            payload["model"] = repo
        }

        // Force non-streaming upstream so we can inspect + repair the message.
        payload["stream"] = false
        let upstreamBody = (try? JSONSerialization.data(withJSONObject: payload)) ?? req.body
        guard let url = URL(string: base + req.path) else { return passthrough(req, base: base) }
        var ur = URLRequest(url: url)
        ur.httpMethod = "POST"
        ur.httpBody = upstreamBody
        for (k, v) in req.headers where !["host", "content-length", "connection", "accept-encoding"].contains(k.lowercased()) {
            ur.setValue(v, forHTTPHeaderField: k)
        }
        ur.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Drive the "thinking" indicator for the whole generation: fire now and
        // keep re-firing (a single local call can outlast the indicator's clear
        // timer), stopping once the engine responds.
        var ticker: DispatchSourceTimer?
        if let pid, let activity = shared.onLocalActivity {
            activity(pid)
            let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            t.schedule(deadline: .now() + 2.5, repeating: 2.5)
            t.setEventHandler { activity(pid) }
            t.resume()
            ticker = t
        }

        if ProcessInfo.processInfo.environment["BROMURE_REPAIR_DEBUG"] != nil {
            // Pair with the `<-` line below: a `->` with no following `<-` (while
            // the agent spins) means the engine HUNG on this request — distinct
            // from a turn that ended with no tool call (which logs a `<-`).
            appendRepairLog("[repair] -> \(req.path) model=\(payload["model"] as? String ?? "?") msgs=\((payload["messages"] as? [Any])?.count ?? (payload["input"] as? [Any])?.count ?? -1)\n")
        }
        let t0 = Date()
        let (data, status) = syncData(ur)
        ticker?.cancel()
        // Trace this call back to the parent, tagged with the calling VM.
        shipTrace(profileID: pid,
                  model: payload["model"] as? String ?? "?", path: req.path, status: status,
                  requestBytes: req.body.count, responseBytes: data?.count ?? 0,
                  latencyMs: Date().timeIntervalSince(t0) * 1000,
                  requestBody: req.body, responseData: data)
        guard status == 200, let data, !data.isEmpty,
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // Upstream error. If the engine returned a body (already wire-shaped
            // by MLXServer, e.g. a model-load failure), relay it verbatim. If it
            // sent nothing — engine unreachable / reloading / stopped — the agent
            // would otherwise see a blank 502; synthesize a clear wire-shaped
            // error so it shows *why* (and the trace carries a reason).
            if let data, !data.isEmpty {
                return httpResponse(status: status, headers: [("Content-Type", "application/json")], body: data)
            }
            let msg = "Local inference engine unreachable (starting up, reloading a model, or stopped) — retry in a moment."
            let body = (try? JSONSerialization.data(withJSONObject: api.errorBody(message: msg))) ?? Data()
            return httpResponse(status: status == 200 ? 503 : status,
                                headers: [("Content-Type", "application/json")], body: body)
        }
        let toolNames = API.toolNames(in: payload)

        // Auto-continue a "stuck preamble": a local model (notably Qwen3-Coder)
        // often narrates the next step — "Now I'll create the server file:" — then
        // emits its end-of-turn token WITHOUT the tool call (observed: 22 completion
        // tokens, status=completed, no function_call). The agent shows that text and
        // stops. When a turn announces an action but carries no tool call, re-prompt
        // ONCE — quoting the preamble back — so the model emits the call it skipped.
        // Bounded to a single retry; on failure we keep the original message (the
        // turn just ends, exactly as before — no regression).
        let finalMessage: [String: Any] = {
            guard !toolNames.isEmpty, api.cleanStop(message),
                  api.hasNoToolCall(message, toolNames: toolNames),
                  looksLikeStuckPreamble(api.assistantText(message)) else { return message }
            let preamble = api.assistantText(message)
            let dbg = ProcessInfo.processInfo.environment["BROMURE_REPAIR_DEBUG"] != nil
            if dbg { appendRepairLog("[repair] ~~ \(req.path) stuck preamble detected; re-prompting\n") }
            // Up to two re-prompts, escalating: the nudge gets blunter and the
            // second adds temperature so a greedy model can't just re-emit the same
            // preamble. The first attempt that yields a tool call wins; otherwise we
            // keep the original message and the turn ends as before.
            for attempt in 0..<2 {
                var cont = api.continuationPayload(payload, preamble: preamble, attempt: attempt)
                cont["stream"] = false
                if attempt > 0 { cont["temperature"] = 0.7 }
                guard let body = try? JSONSerialization.data(withJSONObject: cont) else { break }
                var cur = ur
                cur.httpBody = body
                let (d2, s2) = syncData(cur)
                guard s2 == 200, let d2,
                      let m2 = (try? JSONSerialization.jsonObject(with: d2)) as? [String: Any] else {
                    if dbg { appendRepairLog("[repair] ~~ \(req.path) attempt \(attempt + 1): engine status \(s2)\n") }
                    continue
                }
                if !api.hasNoToolCall(m2, toolNames: toolNames) {
                    if dbg { appendRepairLog("[repair] ~~ \(req.path) recovered a tool call on attempt \(attempt + 1)\n") }
                    return m2
                }
                if dbg {
                    let mt = api.assistantText(m2)
                    let mtail = String(mt.suffix(180)).replacingOccurrences(of: "\n", with: "\\n")
                    appendRepairLog("[repair] ~~ \(req.path) attempt \(attempt + 1): still no tool call (\(mt.count) chars) tail=\(mtail)\n")
                }
            }
            return message
        }()

        if ProcessInfo.processInfo.environment["BROMURE_REPAIR_DEBUG"] != nil {
            let txt = ((finalMessage["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined())
                ?? ((finalMessage["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
                ?? ((finalMessage["output"] as? [[String: Any]])?.compactMap { item in
                        (item["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
                    }.joined())
                ?? ""
            // finish/stop reason + whether the engine ALREADY emitted a structured
            // tool call. A "stuck" turn — the agent narrates a next step then
            // nothing happens — shows up here as reason=stop/end_turn, native=false,
            // rescued=0: the model ENDED the turn after the narration without
            // emitting the tool call. Contrast: reason=length = the call was
            // truncated (raise max output tokens); rescued>0 = we recovered a leaked
            // call (fine); native=true = the engine's own parser produced the call
            // (fine). The tail of the text is where the premature stop is visible.
            let (reason, native): (String, Bool) = {
                if let ch = (finalMessage["choices"] as? [[String: Any]])?.first {     // chat (codex/grok)
                    return (ch["finish_reason"] as? String ?? "?",
                            (ch["message"] as? [String: Any])?["tool_calls"] as? [Any] != nil)
                }
                if let out = finalMessage["output"] as? [[String: Any]] {             // responses
                    return (finalMessage["status"] as? String ?? "?",
                            out.contains { ($0["type"] as? String) == "function_call" })
                }
                return (finalMessage["stop_reason"] as? String ?? "?",               // anthropic messages
                        (finalMessage["content"] as? [[String: Any]])?.contains { ($0["type"] as? String) == "tool_use" } ?? false)
            }()
            let rescued = ToolCallRepair.rescue(text: txt, toolNames: toolNames).blocks.count
            let tail = String(txt.suffix(400)).replacingOccurrences(of: "\n", with: "\\n")
            appendRepairLog("[repair] <- \(req.path) reason=\(reason) native=\(native) rescued=\(rescued) tools=\(toolNames.sorted()) textlen=\(txt.count) tail=\(tail)\n")
        }
        return httpResponse(status: 200,
                            headers: [("Content-Type", "text/event-stream"), ("Cache-Control", "no-cache")],
                            body: api.repairedSSE(finalMessage, toolNames: toolNames))
    }

    /// Heuristic: the assistant text ANNOUNCES an imminent action it then didn't
    /// take — a colon cliffhanger ("…the structure:") or an "I'll …" / "Now I'll …"
    /// / "Next, I'll …" lead-in near the end. Deliberately conservative: a genuine
    /// final answer reads as a summary, and a miss just lets the turn end as before.
    private static func looksLikeStuckPreamble(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count < 1200 else { return false }
        if t.hasSuffix(":") { return true }
        let lower = t.lowercased()
        // Don't re-prompt an obvious wrap-up.
        if lower.contains("let me know") || lower.hasSuffix("done.")
            || lower.contains("is complete") || lower.contains("all set")
            || lower.contains("you're all set") { return false }
        // An action lead-in in the tail is where the missing call would be.
        let tail = String(lower.suffix(180))
        let announces = ["i'll ", "i will ", "now i", "next i", "next, i",
                         "let me ", "let's ", "i'm going to", "i am going to",
                         "going to ", "first, i", "first i", "then i'll"]
        return announces.contains { tail.contains($0) }
    }

    /// Append one line to `/tmp/bromure-repair.log` (BROMURE_REPAIR_DEBUG only).
    private static func appendRepairLog(_ line: String) {
        if let h = FileHandle(forWritingAtPath: "/tmp/bromure-repair.log") {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else { try? line.write(toFile: "/tmp/bromure-repair.log", atomically: true, encoding: .utf8) }
    }

    private static func passthrough(_ req: Request, base: String) -> Data {
        guard let url = URL(string: base + req.path) else {
            return httpResponse(status: 502, headers: [], body: Data("bad path".utf8))
        }
        var ur = URLRequest(url: url)
        ur.httpMethod = req.method
        if !req.body.isEmpty { ur.httpBody = req.body }
        for (k, v) in req.headers where !["host", "content-length", "connection", "accept-encoding"].contains(k.lowercased()) {
            ur.setValue(v, forHTTPHeaderField: k)
        }
        let (data, status) = syncData(ur)
        return httpResponse(status: status, headers: [("Content-Type", "application/json")], body: data ?? Data())
    }

    // MARK: - Per-VM trace recording

    /// Record one inference call into the TraceStore (via the app's callback),
    /// tagged with the calling VM — the profileID recovered from its per-VM key.
    /// No-op for the admin key / internal probes (only requests bearing a valid
    /// per-VM key are traced).
    private static func shipTrace(profileID: UUID?, model: String, path: String,
                                  status: Int, requestBytes: Int, responseBytes: Int,
                                  latencyMs: Double, requestBody: Data, responseData: Data?) {
        guard let cb = shared.onLocalTrace, let pid = profileID else { return }

        var prompt = 0, completion = 0
        if let d = responseData, let m = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           let u = m["usage"] as? [String: Any] {
            prompt = (u["input_tokens"] as? Int) ?? (u["prompt_tokens"] as? Int) ?? 0
            completion = (u["output_tokens"] as? Int) ?? (u["completion_tokens"] as? Int) ?? 0
        }
        // Carry the full request (prompt + tools) and response so the trace
        // inspector can show them — the parent decides whether to persist them,
        // gated on the workspace's trace level (same as the MITM does for cloud).
        cb(["profileID": pid.uuidString, "model": model, "path": path, "status": status,
            "requestBytes": requestBytes, "responseBytes": responseBytes, "latencyMs": latencyMs,
            "promptTokens": prompt, "completionTokens": completion,
            "requestBody": requestBody, "responseBody": responseData ?? Data()])
    }

    /// Synchronous URLSession fetch (we're on a dedicated connection thread).
    private static func syncData(_ req: URLRequest) -> (Data?, Int) {
        let sem = DispatchSemaphore(value: 0)
        var out: Data?; var status = 502
        // Generous: a large model with a big prompt can prefill/generate for
        // many minutes, and the engine streams nothing until done. Kept under
        // the MITM's 1800s idle cap on the local leg so, on a true hang, this
        // times out first and returns a wire-shaped error the MITM can relay
        // (rather than the MITM aborting the connection mid-flight).
        var r = req; r.timeoutInterval = 1500
        let task = URLSession.shared.dataTask(with: r) { d, resp, _ in
            out = d; status = (resp as? HTTPURLResponse)?.statusCode ?? 502; sem.signal()
        }
        task.resume()
        sem.wait()
        return (out, status)
    }

    private static func httpResponse(status: Int, headers: [(String, String)], body: Data) -> Data {
        var s = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\n"
        for (k, v) in headers { s += "\(k): \(v)\r\n" }
        s += "Content-Length: \(body.count)\r\n"
        s += "Connection: keep-alive\r\n\r\n"
        var out = Data(s.utf8); out.append(body); return out
    }

    @discardableResult
    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
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
