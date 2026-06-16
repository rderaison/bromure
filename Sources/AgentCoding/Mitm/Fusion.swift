import Foundation

/// **Fusion** — OpenRouter-style multi-model answer synthesis, done
/// inside the MITM proxy.
///
/// When the guest fires a Claude `/v1/messages` request *and* the
/// profile also holds an OpenAI credential, we don't just forward the
/// call. Instead we:
///
///   1. Ask **both** models the same question (Claude via the original
///      request; GPT via a translated chat-completions request).
///   2. Hand both answers to a **judge** model and ask it to map the
///      terrain — where the two agree, where they contradict, what each
///      uniquely contributed, what both missed. The judge emits a JSON
///      *analysis artifact*, not prose.
///   3. Feed that analysis back to the same model in a **second** call:
///      "here's the analysis, now write the final answer." The final
///      answer is grounded in the structured analysis rather than a raw
///      eyeball-and-cherry-pick of the two drafts.
///
/// The fused answer is streamed back to the guest in whatever wire
/// shape it asked for (Anthropic SSE or a single JSON body), so the
/// in-VM agent (Claude Code etc.) never knows two models were involved.
///
/// This is a **prototype**: it's engaged per-session from the title-bar
/// lightning toggle, logs verbosely to stderr with a `[fusion]` prefix,
/// and falls through to a normal single-model relay whenever anything it
/// needs is missing.
enum Fusion {

    // MARK: Config
    //
    // Fusion is engaged per-session from the title-bar lightning toggle
    // (wired through MitmEngine.setFusionEngaged → the proxy's
    // fusionEngagedProvider). There is intentionally no env "force on"
    // switch — it would override the UI toggle. The remaining
    // `BROMURE_FUSION_*` env vars below only tune behaviour once engaged.

    /// OpenAI model used for leg B. Override with `BROMURE_FUSION_OPENAI_MODEL`.
    static var openAIModel: String {
        ProcessInfo.processInfo.environment["BROMURE_FUSION_OPENAI_MODEL"]
            ?? "gpt-5.5-2026-04-23"
    }

    /// True for GPT-5 family / o-series models, which use the newer
    /// chat-completions conventions: `max_completion_tokens` instead of
    /// `max_tokens`, and only the default `temperature` (so we omit it).
    /// gpt-4o and earlier keep the classic params.
    static func isNewerOpenAIModel(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.hasPrefix("gpt-5") || m.hasPrefix("o1") || m.hasPrefix("o3")
            || m.hasPrefix("o4")
    }

    /// Model used for the judge + synthesis legs. Pinned to Opus — the
    /// terrain-mapping and synthesis steps are the quality-critical part
    /// of Fusion, so we don't inherit a weaker requested model here.
    /// Override with `BROMURE_FUSION_JUDGE_MODEL`.
    static var judgeModel: String {
        ProcessInfo.processInfo.environment["BROMURE_FUSION_JUDGE_MODEL"]
            ?? "claude-opus-4-8"
    }

    /// Hard cap on tokens we ask the judge / synthesis legs to emit.
    static let synthMaxTokens = 4096

    /// Per-request timeout (seconds) for every Fusion upstream leg.
    /// Fusion forces leg A non-streaming, so no bytes arrive until the
    /// model has generated the whole answer — which can take minutes on
    /// a large max_tokens. URLSession's 60s default times out long
    /// before that, so we raise it. Override with `BROMURE_FUSION_TIMEOUT`.
    static var requestTimeout: TimeInterval {
        ProcessInfo.processInfo.environment["BROMURE_FUSION_TIMEOUT"]
            .flatMap(TimeInterval.init) ?? 600
    }

    /// Ceiling for the OpenAI leg's completion-token budget. Claude Code
    /// asks for large budgets (e.g. 64000); we clamp to what the target
    /// model actually accepts so the request doesn't 400. The default is
    /// model-aware — gpt-4o caps completion at 16384, while the GPT-5
    /// family allows 128000 — so Claude Code's ask passes through
    /// untouched on GPT-5.5. Override with `BROMURE_FUSION_OPENAI_MAX_TOKENS`.
    static func openAIMaxTokensCap(model: String) -> Int {
        if let override = ProcessInfo.processInfo
            .environment["BROMURE_FUSION_OPENAI_MAX_TOKENS"].flatMap(Int.init) {
            return override
        }
        return isNewerOpenAIModel(model) ? 128_000 : 16_384
    }

    // MARK: Logging

    static func log(_ msg: String) {
        FileHandle.standardError.write(Data("[fusion] \(msg)\n".utf8))
    }

    // MARK: Result

    /// One upstream model call Fusion made (leg A / leg B / judge /
    /// synth), captured in HTTP wire form so the caller can run it
    /// through the normal trace pipeline. This is what makes the side
    /// calls visible in managed mode — otherwise the proxy only ever
    /// sees the single guest-facing exchange and an admin would never
    /// know GPT (api.openai.com) was contacted.
    struct SubCall: Sendable {
        let host: String
        let port: Int
        let requestBlob: Data
        let responseBlob: Data
        let wireBytes: Int
        let latencyMs: Double
    }

    /// What `run()` hands back so the caller can emit a trace record.
    /// `buffer` is the full wire response we already wrote to the guest;
    /// `subCalls` are the upstream model calls to trace separately.
    struct Outcome {
        let buffer: Data
        let wireBytes: Int
        let subCalls: [SubCall]
    }

    /// Sequential collector for the upstream calls Fusion makes within a
    /// single `run()`. Not concurrency-safe by design — Fusion's legs run
    /// one after another (leg A must resolve before we decide to fuse),
    /// so a plain array behind a class reference is enough.
    final class CallLog: @unchecked Sendable {
        private(set) var calls: [SubCall] = []
        func add(_ c: SubCall) { calls.append(c) }
    }

    // MARK: Entry point

    /// Attempt to handle `rawRequest` (the post-swap, real-credentialed
    /// bytes) as a Fusion exchange.
    ///
    /// Returns `nil` **before writing anything to `tls`** when the
    /// request isn't Fusion-eligible — the caller then falls through to
    /// a normal single-model relay. Returns an `Outcome` once it has
    /// written a complete response to the guest.
    ///
    /// - Parameters:
    ///   - rawRequest: the wire request as forwarded upstream (real creds).
    ///   - host/port:  the Anthropic endpoint the guest CONNECTed to.
    ///   - session:    the per-connection URLSession (reused for all 4 legs).
    ///   - tls:        guest-facing TLS stream we write the fused reply to.
    @available(macOS, deprecated: 10.15, message: "uses TLSServerStream which wraps SecureTransport")
    static func run(rawRequest: Data,
                    host: String,
                    port: Int,
                    session: URLSession,
                    tls: TLSServerStream,
                    swapper: TokenSwapper,
                    profileID: UUID) async throws -> Outcome? {

        // ---- Eligibility: Anthropic /v1/messages POST only ----------
        guard let req = HTTPWire.parse(rawRequest) else { return nil }
        let isAnthropic = host == "api.anthropic.com" || host.hasSuffix(".anthropic.com")
        guard isAnthropic,
              req.method.uppercased() == "POST",
              req.path.hasPrefix("/v1/messages") else {
            return nil
        }

        guard let anthropicBody = (try? JSONSerialization.jsonObject(with: req.body))
                as? [String: Any] else {
            log("eligible host but body wasn't JSON — falling through")
            return nil
        }

        // ---- Need an OpenAI credential for leg B --------------------
        guard let openAIToken = openAITokenInMap(swapper: swapper, profileID: profileID) else {
            let hosts = swapper.entries(for: profileID)
                .map { $0.host ?? "*" }.joined(separator: ", ")
            log("no OpenAI credential in token map (map hosts: [\(hosts)]) — falling through to plain Claude relay")
            return nil
        }

        let requestedModel = anthropicBody["model"] as? String
        let wantsStream = (anthropicBody["stream"] as? Bool) ?? false
        log("ENGAGED for model=\(requestedModel ?? "?") stream=\(wantsStream) path=\(req.path)")

        // Records every upstream model call so the caller can trace them
        // (managed-mode audit: leg A/B, judge, synth all show up).
        let callLog = CallLog()

        // ===== Leg A: Claude, with tools intact ======================
        // We call Claude FIRST (buffered, streaming off) carrying the
        // guest's original request — tools and all. We then look at what
        // Claude wants to do this turn:
        //
        //   • If Claude wants to call a tool (stop_reason "tool_use", or
        //     any tool_use block), this turn is an *action*, not a final
        //     answer. Fusing two models' prose here would strip the tool
        //     call and break the agentic loop (no file writes, no bash).
        //     So we replay Claude's own response verbatim and skip
        //     fusion entirely — no GPT call, no judge/synth.
        //
        //   • Only when Claude returns a plain text answer (the turn that
        //     actually talks to the user) do we run the OpenAI leg, judge
        //     the two drafts, and synthesize a fused reply.
        guard let (codeA, dataA) = await callAnthropicRaw(
                body: forceNonStreaming(anthropicBody),
                host: host, headers: req.headers, session: session, callLog: callLog),
              codeA == 200,
              let messageA = (try? JSONSerialization.jsonObject(with: dataA)) as? [String: Any]
        else {
            log("leg A (Claude) failed or unparseable — falling through to normal relay")
            return nil
        }

        if messageIsToolTurn(messageA) {
            // Hand Claude's real response (tool calls intact) back to the
            // guest in its expected wire shape and let Claude Code run
            // the tools. This is the common case in agentic coding.
            let wire = wireFromMessage(messageA, wantsStream: wantsStream)
            try tls.write(wire)
            log("leg A is a TOOL turn (stop=\(messageA["stop_reason"] as? String ?? "?")) "
                + "— passthrough, fusion skipped (\(wire.count) wire bytes)")
            return Outcome(buffer: wire, wireBytes: wire.count, subCalls: callLog.calls)
        }

        let claudeText = extractAnthropicTextFromMessage(messageA)
        log("leg A (Claude) is a TEXT turn — \(claudeText.count) chars; fusing")

        // ===== Leg B: GPT (translated to chat-completions) ===========
        // Only reached on text turns, so we never spend a GPT call on a
        // tool-use turn.
        let openAIBody = translateToOpenAI(anthropicBody: anthropicBody, model: openAIModel)
        let gptAnswer = await callOpenAI(
            body: openAIBody, token: openAIToken, session: session, callLog: callLog)
        let gptText: String
        switch gptAnswer {
        case .success(let txt): gptText = txt; log("leg B (GPT) ok — \(txt.count) chars")
        case .failure(let why):  gptText = ""; log("leg B (GPT) FAILED — \(why)")
        }

        // If GPT failed we have nothing to fuse against — just return
        // Claude's own text answer rather than a degraded single-model
        // "fusion".
        if gptText.isEmpty {
            let wire = wireFromMessage(messageA, wantsStream: wantsStream)
            try tls.write(wire)
            log("no GPT draft — returning Claude's text answer unchanged (\(wire.count) wire bytes)")
            return Outcome(buffer: wire, wireBytes: wire.count, subCalls: callLog.calls)
        }

        // The user-visible question = the last user turn. Used to ground
        // the judge + synthesis prompts.
        let question = lastUserText(anthropicBody: anthropicBody)

        // ===== Judge: structured analysis (NOT a combined answer) =====
        let analysis = await judge(question: question,
                                   claude: claudeText, gpt: gptText,
                                   model: judgeModel,
                                   host: host, headers: req.headers,
                                   session: session, callLog: callLog)
        log("judge analysis — \(analysis.count) chars of JSON")

        // ===== Synthesis: final answer FROM the analysis ==============
        var finalText = await synthesize(question: question, analysis: analysis,
                                         model: judgeModel,
                                         host: host, headers: req.headers,
                                         session: session, callLog: callLog)
        if finalText.isEmpty {
            // Degrade gracefully: prefer Claude's raw draft, else GPT's.
            finalText = claudeText.isEmpty ? gptText : claudeText
            log("synthesis empty — falling back to a raw model draft (\(finalText.count) chars)")
        } else {
            log("synthesis ok — final answer \(finalText.count) chars")
        }

        // ===== Deliver in the guest's expected wire format ============
        // Reuse Claude's own message envelope (id/model/usage) but swap
        // its content for the single fused text block, so the guest sees
        // a well-formed end_turn text answer.
        let fusedMessage = textMessage(finalText, basedOn: messageA,
                                       fallbackModel: requestedModel ?? "claude")
        let wire = wireFromMessage(fusedMessage, wantsStream: wantsStream)
        try tls.write(wire)
        log("delivered fused answer to guest (\(wire.count) wire bytes, \(wantsStream ? "SSE" : "JSON"))")
        return Outcome(buffer: wire, wireBytes: wire.count, subCalls: callLog.calls)
    }

    // MARK: - Credential lookup

    /// First real OpenAI token in the profile's swap map, if any. We
    /// match on the entry's declared host family rather than the header
    /// kind so both API-key and OAuth entries are found.
    private static func openAITokenInMap(swapper: TokenSwapper, profileID: UUID) -> String? {
        for e in swapper.entries(for: profileID) {
            // The OpenAI session-token entry is scoped to the bare
            // registered domain "openai.com" (see SessionTokenPlan
            // .hostScope), so match that plus any subdomain.
            let h = (e.host ?? "").lowercased()
            if h == "openai.com" || h.hasSuffix(".openai.com") {
                return e.real
            }
        }
        return nil
    }

    // MARK: - Upstream legs

    private enum LegResult {
        case success(String)
        case failure(String)
        func get() throws -> String {
            switch self {
            case .success(let s): return s
            case .failure(let e): throw NSError(domain: "fusion", code: 1,
                                                userInfo: [NSLocalizedDescriptionKey: e])
            }
        }
    }

    /// Result of one upstream call: the parsed status + decoded body for
    /// Fusion's own logic, plus the response left in `log` for tracing.
    private struct RawResult { let status: Int; let body: Data }

    /// Fire a built `URLRequest`, record the exchange into `log` (as a
    /// `SubCall` so the proxy can trace it in managed mode), and return
    /// the status + decoded body. Returns nil on transport error.
    private static func perform(_ req: URLRequest, host: String, port: Int,
                                session: URLSession, callLog: CallLog) async -> RawResult? {
        let t0 = Date()
        do {
            let (data, resp) = try await session.data(for: req)
            let http = resp as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let latency = Date().timeIntervalSince(t0) * 1000
            let respBlob = responseWireBlob(status: status, headers: http, body: data)
            callLog.add(SubCall(host: host, port: port,
                            requestBlob: requestWireBlob(req),
                            responseBlob: respBlob,
                            wireBytes: respBlob.count,
                            latencyMs: latency))
            return RawResult(status: status, body: data)
        } catch {
            log("upstream call to \(host) errored — \(error)")
            return nil
        }
    }

    /// Build a POST to `https://<host>/v1/messages` reusing the guest's
    /// real-credentialed headers.
    private static func anthropicRequest(body: [String: Any], host: String,
                                         headers: [(String, String)]) -> URLRequest? {
        guard let url = URL(string: "https://\(host)/v1/messages"),
              let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.httpBody = payload
        r.timeoutInterval = requestTimeout
        applyForwardHeaders(headers, to: &r)
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return r
    }

    /// POST a JSON body to Anthropic; returns the joined text of all
    /// `text` content blocks (empty on any failure).
    private static func callAnthropic(body: [String: Any], host: String,
                                      headers: [(String, String)],
                                      session: URLSession, callLog: CallLog) async -> LegResult {
        guard let req = anthropicRequest(body: body, host: host, headers: headers) else {
            return .failure("could not build Anthropic request")
        }
        guard let raw = await perform(req, host: host, port: 443, session: session, callLog: callLog) else {
            return .failure("transport error")
        }
        guard raw.status == 200 else { return .failure("HTTP \(raw.status): \(snippet(raw.body))") }
        return .success(extractAnthropicText(raw.body))
    }

    /// Like `callAnthropic`, but returns the raw `(statusCode, body)` so
    /// the caller can inspect the full message (tool_use blocks,
    /// stop_reason) rather than just the joined text. Returns nil on a
    /// transport error.
    private static func callAnthropicRaw(body: [String: Any], host: String,
                                         headers: [(String, String)],
                                         session: URLSession, callLog: CallLog) async -> (Int, Data)? {
        guard let req = anthropicRequest(body: body, host: host, headers: headers) else { return nil }
        guard let raw = await perform(req, host: host, port: 443, session: session, callLog: callLog) else { return nil }
        return (raw.status, raw.body)
    }

    /// POST a chat-completions body to OpenAI with a Bearer token.
    private static func callOpenAI(body: [String: Any], token: String,
                                   session: URLSession, callLog: CallLog) async -> LegResult {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions"),
              let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return .failure("could not build OpenAI request")
        }
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.httpBody = payload
        r.timeoutInterval = requestTimeout
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let raw = await perform(r, host: "api.openai.com", port: 443,
                                      session: session, callLog: callLog) else {
            return .failure("transport error")
        }
        guard raw.status == 200 else { return .failure("HTTP \(raw.status): \(snippet(raw.body))") }
        return .success(extractOpenAIText(raw.body))
    }

    // MARK: - Wire-blob reconstruction (for tracing)

    /// Rebuild a `URLRequest` as an HTTP/1.1 request blob — the same
    /// shape the proxy's normal path feeds to `emitTrace`, so the
    /// conversation parser and cloud LLM extractor work on it.
    private static func requestWireBlob(_ req: URLRequest) -> Data {
        let path = req.url?.path ?? "/"
        let query = req.url?.query.map { "?\($0)" } ?? ""
        var s = "\(req.httpMethod ?? "POST") \(path)\(query) HTTP/1.1\r\n"
        if let h = req.url?.host { s += "Host: \(h)\r\n" }
        for (k, v) in req.allHTTPHeaderFields ?? [:] { s += "\(k): \(v)\r\n" }
        s += "\r\n"
        var out = Data(s.utf8)
        if let b = req.httpBody { out.append(b) }
        return out
    }

    /// Rebuild an HTTP/1.1 response blob from a URLResponse + decoded
    /// body. Drops framing/encoding headers (URLSession already decoded
    /// the body) and sets an accurate Content-Length.
    private static func responseWireBlob(status: Int, headers: HTTPURLResponse?,
                                         body: Data) -> Data {
        var s = "HTTP/1.1 \(status) "
        s += HTTPURLResponse.localizedString(forStatusCode: status).capitalized + "\r\n"
        if let headers {
            for (k, v) in headers.allHeaderFields {
                guard let key = k as? String, let val = v as? String else { continue }
                switch key.lowercased() {
                case "content-encoding", "content-length", "transfer-encoding", "connection":
                    continue
                default: s += "\(key): \(val)\r\n"
                }
            }
        }
        s += "Content-Length: \(body.count)\r\n\r\n"
        var out = Data(s.utf8)
        out.append(body)
        return out
    }

    // MARK: - Judge + synthesis

    private static let judgeSystem = """
    You are an impartial analysis engine comparing two AI answers to the \
    same question. Do NOT write a combined or improved answer. Your only \
    job is to map the terrain between the two answers.

    Respond with a single JSON object and nothing else, of the shape:
    {
      "consensus":      [ "points both answers agree on" ],
      "conflicts":      [ { "topic": "...", "answer_a": "...", "answer_b": "..." } ],
      "unique_to_a":    [ "insights only answer A had" ],
      "unique_to_b":    [ "insights only answer B had" ],
      "blind_spots":    [ "things both answers missed or got wrong" ],
      "verdict":        "one sentence on which answer is stronger and why"
    }
    Answer A is from Claude. Answer B is from GPT.
    """

    private static let synthSystem = """
    You are writing the definitive final answer to a user's question. \
    You are given a structured ANALYSIS comparing two earlier draft \
    answers (one from Claude, one from GPT): where they agreed, where \
    they conflicted, what each uniquely contributed, and what both \
    missed.

    Use the analysis to write the single best answer. Resolve conflicts \
    in favour of correctness, fold in the unique insights from both, and \
    cover the blind spots. Write the answer directly to the user — do not \
    mention the analysis, the drafts, or that multiple models were involved.
    """

    private static func judge(question: String, claude: String, gpt: String,
                              model: String, host: String,
                              headers: [(String, String)],
                              session: URLSession, callLog: CallLog) async -> String {
        let user = """
        QUESTION:
        \(question)

        ANSWER A (Claude):
        \(claude.isEmpty ? "(no answer)" : claude)

        ANSWER B (GPT):
        \(gpt.isEmpty ? "(no answer)" : gpt)

        Produce the JSON analysis now.
        """
        let body = anthropicCall(model: model, system: judgeSystem, user: user)
        let res = await callAnthropic(body: body, host: host, headers: headers,
                                      session: session, callLog: callLog)
        switch res {
        case .success(let s): return s
        case .failure(let e):
            log("judge leg FAILED — \(e)")
            return "{\"error\":\"judge call failed\"}"
        }
    }

    private static func synthesize(question: String, analysis: String,
                                   model: String, host: String,
                                   headers: [(String, String)],
                                   session: URLSession, callLog: CallLog) async -> String {
        let user = """
        QUESTION:
        \(question)

        ANALYSIS (JSON):
        \(analysis)

        Write the final answer now.
        """
        let body = anthropicCall(model: model, system: synthSystem, user: user)
        let res = await callAnthropic(body: body, host: host, headers: headers,
                                      session: session, callLog: callLog)
        return (try? res.get()) ?? ""
    }

    /// Minimal single-turn Anthropic /v1/messages body.
    private static func anthropicCall(model: String, system: String, user: String) -> [String: Any] {
        [
            "model": model,
            "max_tokens": synthMaxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
    }

    // MARK: - Format translation (Anthropic → OpenAI chat-completions)

    /// Flatten an Anthropic /v1/messages body into an OpenAI
    /// chat-completions body. Tools are dropped — the judge compares
    /// prose, and tool-call round-trips don't translate cleanly in a
    /// prototype. Content blocks are flattened to text.
    static func translateToOpenAI(anthropicBody: [String: Any], model: String) -> [String: Any] {
        var messages: [[String: Any]] = []
        if let sys = flattenSystem(anthropicBody["system"]), !sys.isEmpty {
            messages.append(["role": "system", "content": sys])
        }
        for m in (anthropicBody["messages"] as? [[String: Any]]) ?? [] {
            let role = (m["role"] as? String) ?? "user"
            let text = flattenContent(m["content"])
            // OpenAI only knows user/assistant/system/tool roles.
            let mapped = (role == "assistant") ? "assistant" : "user"
            if !text.isEmpty { messages.append(["role": mapped, "content": text]) }
        }
        var out: [String: Any] = ["model": model, "messages": messages]
        let newer = isNewerOpenAIModel(model)
        if let mt = anthropicBody["max_tokens"] as? Int {
            let clamped = min(mt, openAIMaxTokensCap(model: model))
            // GPT-5 / o-series renamed this param to max_completion_tokens
            // and reject the old max_tokens with a 400.
            out[newer ? "max_completion_tokens" : "max_tokens"] = clamped
            if clamped != mt {
                log("clamped max_tokens \(mt) → \(clamped) for OpenAI leg")
            }
        }
        // GPT-5 / o-series only accept the default temperature, so we
        // pass it through for classic models only.
        if !newer, let t = anthropicBody["temperature"] as? Double {
            out["temperature"] = t
        }
        log("translated dialogue → OpenAI: \(messages.count) messages, model=\(model) (newer-params=\(newer))")
        return out
    }

    /// Anthropic `system` is a String or an array of `{type:text,text}`.
    private static func flattenSystem(_ system: Any?) -> String? {
        if let s = system as? String { return s }
        if let arr = system as? [[String: Any]] {
            return arr.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
        }
        return nil
    }

    /// Anthropic message `content` is a String or an array of blocks.
    private static func flattenContent(_ content: Any?) -> String {
        if let s = content as? String { return s }
        guard let blocks = content as? [[String: Any]] else { return "" }
        var parts: [String] = []
        for b in blocks {
            switch b["type"] as? String {
            case "text":
                if let t = b["text"] as? String { parts.append(t) }
            case "tool_use":
                let name = b["name"] as? String ?? "?"
                let input = (b["input"]).flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                parts.append("[tool call: \(name) \(input)]")
            case "tool_result":
                parts.append("[tool result: \(flattenContent(b["content"]))]")
            default:
                break
            }
        }
        return parts.joined(separator: "\n")
    }

    /// Pull the most recent user turn's text for grounding the prompts.
    private static func lastUserText(anthropicBody: [String: Any]) -> String {
        let msgs = (anthropicBody["messages"] as? [[String: Any]]) ?? []
        for m in msgs.reversed() where (m["role"] as? String) == "user" {
            let t = flattenContent(m["content"])
            if !t.isEmpty { return t }
        }
        return flattenContent(msgs.last?["content"])
    }

    // MARK: - Answer extraction

    /// Join all `text` blocks of an Anthropic /v1/messages response.
    private static func extractAnthropicText(_ data: Data) -> String {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return "" }
        return extractAnthropicTextFromMessage(obj)
    }

    /// Join all `text` blocks of an already-parsed Anthropic message.
    private static func extractAnthropicTextFromMessage(_ obj: [String: Any]) -> String {
        guard let content = obj["content"] as? [[String: Any]] else { return "" }
        return content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined()
    }

    /// True if this assistant message is an *action* (wants to call a
    /// tool) rather than a final text answer. Either signal counts: the
    /// top-level `stop_reason` is "tool_use", or any content block is a
    /// tool_use block.
    private static func messageIsToolTurn(_ message: [String: Any]) -> Bool {
        if (message["stop_reason"] as? String) == "tool_use" { return true }
        let content = (message["content"] as? [[String: Any]]) ?? []
        return content.contains { ($0["type"] as? String) == "tool_use" }
    }

    /// Build a minimal assistant message carrying a single text block,
    /// reusing `template`'s id / model / usage envelope when present so
    /// the guest sees consistent metadata.
    private static func textMessage(_ text: String,
                                    basedOn template: [String: Any],
                                    fallbackModel: String) -> [String: Any] {
        [
            "id": template["id"] as? String ?? "msg_fusion_\(UUID().uuidString.prefix(16))",
            "type": "message",
            "role": "assistant",
            "model": template["model"] as? String ?? fallbackModel,
            "content": [["type": "text", "text": text]],
            "stop_reason": "end_turn",
            "stop_sequence": NSNull(),
            "usage": template["usage"] as? [String: Any]
                ?? ["input_tokens": 0, "output_tokens": 0],
        ]
    }

    /// First choice's message content from an OpenAI chat-completions response.
    private static func extractOpenAIText(_ data: Data) -> String {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let content = msg["content"] as? String else { return "" }
        return content
    }

    // MARK: - Request mutation helpers

    private static func forceNonStreaming(_ body: [String: Any]) -> [String: Any] {
        var b = body
        b["stream"] = false
        return b
    }

    /// Copy the guest's request headers onto a URLRequest, skipping the
    /// ones URLSession owns (framing, host, compression). The real
    /// Authorization / x-api-key / anthropic-* headers ride along so the
    /// upstream auth — API key or OAuth — works exactly as it did for
    /// the guest's own call.
    private static func applyForwardHeaders(_ headers: [(String, String)], to req: inout URLRequest) {
        let skip: Set<String> = [
            "host", "content-length", "connection", "transfer-encoding",
            "proxy-connection", "keep-alive", "te", "upgrade",
            "accept-encoding", "content-encoding",
        ]
        for (k, v) in headers where !skip.contains(k.lowercased()) {
            req.setValue(v, forHTTPHeaderField: k)
        }
    }

    // MARK: - Guest-facing response builders

    /// Serialize a parsed Anthropic message back onto the wire in the
    /// guest's expected shape. When `wantsStream` is false this is just
    /// the message JSON; when true it's the full Anthropic SSE event
    /// sequence. Both paths faithfully reproduce arbitrary content
    /// blocks — text, tool_use (ids + input preserved), and thinking —
    /// plus the real `stop_reason`, so a tool-use turn survives intact
    /// and Claude Code executes the tools.
    private static func wireFromMessage(_ message: [String: Any], wantsStream: Bool) -> Data {
        wantsStream ? sseFromMessage(message) : jsonFromMessage(message)
    }

    private static func jsonFromMessage(_ message: [String: Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: message)) ?? Data("{}".utf8)
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }

    private static func sseFromMessage(_ message: [String: Any]) -> Data {
        func event(_ name: String, _ payload: [String: Any]) -> String {
            let json = (try? JSONSerialization.data(withJSONObject: payload))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return "event: \(name)\r\ndata: \(json)\r\n\r\n"
        }
        let content = (message["content"] as? [[String: Any]]) ?? []
        let stopReason = message["stop_reason"] as? String ?? "end_turn"
        let stopSequence = message["stop_sequence"] ?? NSNull()
        let usage = message["usage"] as? [String: Any] ?? ["input_tokens": 0, "output_tokens": 0]

        // message_start carries the envelope with empty content.
        var startMsg = message
        startMsg["content"] = []
        startMsg["stop_reason"] = NSNull()
        startMsg["stop_sequence"] = NSNull()

        var sse = ""
        sse += event("message_start", ["type": "message_start", "message": startMsg])

        for (i, block) in content.enumerated() {
            switch block["type"] as? String {
            case "text":
                sse += event("content_block_start", [
                    "type": "content_block_start", "index": i,
                    "content_block": ["type": "text", "text": ""],
                ])
                for chunk in chunked(block["text"] as? String ?? "", size: 256) {
                    sse += event("content_block_delta", [
                        "type": "content_block_delta", "index": i,
                        "delta": ["type": "text_delta", "text": chunk],
                    ])
                }
            case "tool_use":
                // Preserve id + name so the follow-up tool_result matches.
                sse += event("content_block_start", [
                    "type": "content_block_start", "index": i,
                    "content_block": [
                        "type": "tool_use",
                        "id": block["id"] as? String ?? "toolu_\(UUID().uuidString.prefix(16))",
                        "name": block["name"] as? String ?? "",
                        "input": [String: Any](),
                    ],
                ])
                // Emit the whole input object as one input_json_delta; the
                // SDK accumulates partial_json and JSON-parses at stop.
                let inputJSON = (block["input"]).flatMap {
                    try? JSONSerialization.data(withJSONObject: $0)
                }.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                sse += event("content_block_delta", [
                    "type": "content_block_delta", "index": i,
                    "delta": ["type": "input_json_delta", "partial_json": inputJSON],
                ])
            case "thinking":
                sse += event("content_block_start", [
                    "type": "content_block_start", "index": i,
                    "content_block": ["type": "thinking", "thinking": ""],
                ])
                sse += event("content_block_delta", [
                    "type": "content_block_delta", "index": i,
                    "delta": ["type": "thinking_delta",
                              "thinking": block["thinking"] as? String ?? ""],
                ])
                if let sig = block["signature"] as? String {
                    sse += event("content_block_delta", [
                        "type": "content_block_delta", "index": i,
                        "delta": ["type": "signature_delta", "signature": sig],
                    ])
                }
            default:
                // Unknown block type — start with the raw block and stop,
                // so we at least don't drop it silently.
                sse += event("content_block_start", [
                    "type": "content_block_start", "index": i,
                    "content_block": block,
                ])
            }
            sse += event("content_block_stop", ["type": "content_block_stop", "index": i])
        }

        sse += event("message_delta", [
            "type": "message_delta",
            "delta": ["stop_reason": stopReason, "stop_sequence": stopSequence],
            "usage": usage,
        ])
        sse += event("message_stop", ["type": "message_stop"])

        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: text/event-stream; charset=utf-8\r\n"
        head += "Cache-Control: no-cache\r\n"
        head += "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(Data(sse.utf8))
        return out
    }

    private static func chunked(_ s: String, size: Int) -> [String] {
        guard !s.isEmpty else { return [""] }
        var out: [String] = []
        var idx = s.startIndex
        while idx < s.endIndex {
            let end = s.index(idx, offsetBy: size, limitedBy: s.endIndex) ?? s.endIndex
            out.append(String(s[idx..<end]))
            idx = end
        }
        return out
    }

    private static func snippet(_ data: Data) -> String {
        String(data: data.prefix(300), encoding: .utf8) ?? "<\(data.count) bytes>"
    }
}

// MARK: - Tiny HTTP request splitter

/// Splits a raw HTTP/1.1 request into method, path, headers, and body.
/// Local to Fusion so it doesn't depend on the proxy's private parsers.
enum HTTPWire {
    struct Request {
        let method: String
        let path: String
        let headers: [(String, String)]
        let body: Data
    }

    static func parse(_ raw: Data) -> Request? {
        guard let sep = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = raw.subdata(in: raw.startIndex..<sep.lowerBound)
        let body = raw.subdata(in: sep.upperBound..<raw.endIndex)
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return nil }
        var lines = headerStr.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [(String, String)] = []
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }
        return Request(method: String(requestLine[0]),
                       path: String(requestLine[1]),
                       headers: headers,
                       body: body)
    }
}
