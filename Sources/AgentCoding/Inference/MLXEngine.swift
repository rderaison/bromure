import Foundation
import MLX
import MLXLMCommon
import MLXLLM
import MLXHuggingFace
import Tokenizers

/// In-process MLX inference engine — the Swift-native replacement for the
/// Python `vllm-mlx` subprocess. Loads MLX models straight from the Hugging
/// Face hub cache and streams token generation on the GPU, in-process, with no
/// venv / pip / HTTP-to-a-subprocess hop.
///
/// Higher layers (the OpenAI/Anthropic/Responses HTTP shim, `InferenceService`)
/// drive this; it owns model loading, an LRU multi-model registry bounded by a
/// memory budget, and streaming generation. Tool-call / reasoning parsing lives
/// one layer up (the wire-format servers), since it's protocol-specific.
actor MLXEngine {
    static let shared = MLXEngine()

    enum EngineError: LocalizedError {
        case notDownloaded(String)
        case loadFailed(String, underlying: String)

        var errorDescription: String? {
            switch self {
            case .notDownloaded(let r): return "Model not downloaded: \(r)"
            case .loadFailed(let r, let u):
                // An unsupported architecture is permanent (the on-device MLX
                // engine doesn't implement that model type yet), not a transient
                // load failure — say so plainly instead of leaking the raw
                // `unsupportedModelType("…")` so the user doesn't keep retrying.
                if let type = Self.unsupportedModelType(in: u) {
                    return "Can't run \(r): its architecture “\(type)” isn't supported by the on-device engine yet — pick a different model."
                }
                return "Couldn't load \(r): \(u)"
            }
        }

        /// Extract the model type from a `unsupportedModelType("…")` description.
        private static func unsupportedModelType(in s: String) -> String? {
            guard s.contains("unsupportedModelType"),
                  let open = s.firstIndex(of: "\""),
                  let close = s[s.index(after: open)...].firstIndex(of: "\"") else { return nil }
            return String(s[s.index(after: open)..<close])
        }
    }

    /// A resident model plus its bookkeeping for LRU eviction.
    private final class Resident {
        let repo: String
        let container: ModelContainer
        let estMemGB: Int
        var lastUsed: Date
        init(repo: String, container: ModelContainer, estMemGB: Int) {
            self.repo = repo; self.container = container
            self.estMemGB = estMemGB; self.lastUsed = Date()
        }
    }

    private var residents: [String: Resident] = [:]
    /// In-flight loads, so concurrent requests for the same model await one load.
    private var loading: [String: Task<ModelContainer, Error>] = [:]
    /// Resident-set memory budget (GB). 0 = unbounded (single-model use).
    private var memoryBudgetGB: Int = 0

    /// A reusable KV cache for one conversation: the cache arrays plus the exact
    /// token sequence they encode (cache offset == `tokens.count`). Reused across
    /// requests by matching the longest common token prefix, so each agent turn
    /// prefills only the *newly appended* tokens instead of re-prefilling the
    /// whole transcript. This is the single biggest win for an agent like Claude
    /// Code, whose prompt (system + tools + growing history) is re-sent in full
    /// every turn — without reuse that's O(transcript) prefill per turn (a
    /// quadratic blow-up over a session); with it, O(new tokens).
    private final class SessionCache {
        var cache: [KVCache] = []
        var tokens: [Int] = []
        var lastUsed = Date()
    }

    /// The cache slots for one repo — a small LRU set, not a single slot,
    /// because "one conversation per model" is not what an agent actually
    /// sends. Claude Code fires sidechains at the same model (conversation
    /// title, sub-agents) interleaved with the main conversation; with one
    /// slot each sidechain trims the conversation's cache down to the shared
    /// system prefix, so the next real turn re-prefills the whole transcript —
    /// exactly the O(transcript)-per-turn blow-up the cache exists to prevent.
    /// With a few slots the sidechain takes its own cache and the main
    /// conversation's prefix survives untouched.
    ///
    /// A reference type mutated only inside `generate` (which holds `genLock`),
    /// the same ownership pattern as SessionCache itself; the actor only ever
    /// swaps whole entries in/out of `sessionCaches`.
    private final class SessionSlots {
        var slots: [SessionCache] = []
    }

    private var sessionCaches: [String: SessionSlots] = [:]

    private func sessionSlots(for repo: String) -> SessionSlots {
        if let s = sessionCaches[repo] { return s }
        let s = SessionSlots()
        sessionCaches[repo] = s
        return s
    }

    /// Max cache slots per repo. Each slot holds one conversation's KV cache
    /// (order of 100 KB/token for the 30B MoE at fp16), so the set stays small:
    /// the real shape is one long-lived conversation plus short sidechains.
    /// BROMURE_CACHE_SLOTS tunes it; 1 restores the old single-slot behavior.
    static let maxCacheSlots: Int = {
        let raw = ProcessInfo.processInfo.environment["BROMURE_CACHE_SLOTS"]
            .flatMap { Int($0) } ?? 4
        return min(max(raw, 1), 8)
    }()

    /// How a request maps onto the cache slots.
    enum SlotDecision: Equatable {
        /// Continue in slot `i`: trim its divergent tail, prefill the suffix.
        case reuse(Int)
        /// No slot is safe to continue — take a fresh one (LRU-evict at cap).
        case fresh
    }

    /// Pick the slot for a prompt. A slot may be reused *in place* only when
    /// the prompt is a plausible continuation of it: trimming to the shared
    /// prefix must destroy little — retokenization drift or a repaired tool
    /// call, bounded by max(1024, prefix/4) tokens. A prompt that shares only
    /// the system prefix with a long conversation (a sidechain) fails the test
    /// and gets a fresh slot: it pays its own full prefill once instead of
    /// destroying a 40k-token cache the next real turn needs. Among acceptable
    /// slots the deepest prefix wins; an empty slot is always acceptable
    /// (prefix 0, nothing to destroy).
    static func chooseSlot(prompt: [Int], slotTokens: [[Int]]) -> SlotDecision {
        var best: (index: Int, prefix: Int)?
        for (i, tokens) in slotTokens.enumerated() {
            let prefix = commonPrefix(tokens, prompt)
            let lost = tokens.count - prefix
            guard lost <= max(1024, prefix / 4) else { continue }
            if best == nil || prefix > best!.prefix { best = (i, prefix) }
        }
        if let best { return .reuse(best.index) }
        return .fresh
    }

    // MARK: - Generation serialization
    //
    // Generation mutates the per-repo prefix KV cache (trim + prefill + decode).
    // `container.perform`'s closure `await`s (e.g. `processor.prepare`), and the
    // ModelContainer is an actor — so a second concurrent `generate` RE-ENTERS
    // the container at that await and interleaves with the first, both mutating
    // the same KVCache. The result is an off-by-one cache offset and an MLX
    // shape-broadcast crash that kills the engine child (seen as 502s).
    // Interactive Claude triggers this constantly: it fires the conversation
    // title sidechain alongside the main request. Serialize so exactly one
    // generation runs at a time; the GPU is single-model anyway, so this costs
    // nothing real and makes the cache safe.
    private var genBusy = false
    private var genWaiters: [CheckedContinuation<Void, Never>] = []
    private func genLock() async {
        if !genBusy { genBusy = true; return }
        await withCheckedContinuation { genWaiters.append($0) }
    }
    private func genUnlock() {
        if genWaiters.isEmpty { genBusy = false }
        else { genWaiters.removeFirst().resume() }
    }

    /// A firm, format-exact reminder appended to the system prompt whenever the
    /// request declares tools. The chat template already documents the format,
    /// but local models (esp. quantized, at long context) drift — emitting tool
    /// calls as malformed JSON or mixed shapes that leak as text. This pins them
    /// to the one shape `ToolCallRepair` and the template agree on.
    static let toolFormatReminder = """
    ──────────────────────────────────────────────
    TOOL-CALL FORMAT — follow this EXACTLY, every time.
    To call a tool, emit ONLY this structure (nothing else inside it):
    <tool_call>
    <function=ExactToolName>
    <parameter=first_param_name>
    value
    </parameter>
    <parameter=second_param_name>
    value
    </parameter>
    </function>
    </tool_call>
    Rules:
    - One <function=…> per call; close it with </function>.
    - Each argument is its own <parameter=name>…</parameter> block.
    - NEVER emit a tool call as JSON ({"name":…,"arguments":…}) or any other shape.
    - Use exact tool names as declared. No extra prose inside <tool_call>.
    - When you say you will do something (create/run/edit a file), emit its tool
      call in the SAME response. NEVER end your turn with only a description of an
      action you have not yet performed.
    ──────────────────────────────────────────────
    """

    /// Gemma variant: its template teaches the model's own native call format
    /// (`<|tool_call>call:Name{…}<tool_call|>`), so prescribing the Qwen XML
    /// shape above would fight the training. Keep only the behavioral rule
    /// that fixes stuck preambles.
    static let gemmaToolReminder = """
    ──────────────────────────────────────────────
    TOOL-CALL RULES:
    - Call tools in your native tool-call format, using exact tool names as declared.
    - When you say you will do something (create/run/edit a file), emit its tool
      call in the SAME response. NEVER end your turn with only a description of an
      action you have not yet performed.
    ──────────────────────────────────────────────
    """

    /// Append the tool reminder to the (first) system message when the request
    /// declares tools — keeping it in the stable prompt prefix so the KV cache
    /// still reuses across turns.
    static func withToolReminder(_ messages: [Chat.Message], hasTools: Bool,
                                 gemma: Bool = false) -> [Chat.Message] {
        guard hasTools else { return messages }
        let reminder = gemma ? gemmaToolReminder : toolFormatReminder
        var msgs = messages
        if let i = msgs.firstIndex(where: { $0.role == .system }) {
            msgs[i].content += "\n\n" + reminder
        } else {
            msgs.insert(.system(reminder), at: 0)
        }
        return msgs
    }

    /// Length of the shared leading run of two token sequences.
    private static func commonPrefix(_ a: [Int], _ b: [Int]) -> Int {
        let n = min(a.count, b.count)
        var i = 0
        while i < n && a[i] == b[i] { i += 1 }
        return i
    }

    /// Drop `<think>…</think>` spans from a model's text. A safety net for
    /// reasoning models even when `enable_thinking=false` is passed — without
    /// it the raw chain-of-thought leaks into the agent's visible output and
    /// gets re-sent verbatim in the next turn's transcript.
    static func stripThinking(_ s: String) -> String {
        guard s.contains("<think>") else { return s }
        var out = ""
        var rest = Substring(s)
        while let open = rest.range(of: "<think>") {
            out += rest[..<open.lowerBound]
            if let close = rest.range(of: "</think>", range: open.upperBound..<rest.endIndex) {
                rest = rest[close.upperBound...]
            } else {
                rest = ""   // unterminated think block → drop the remainder
            }
        }
        out += rest
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Gemma-family models don't use `<think>` — their reasoning rides a
    /// thought channel: `<|channel>thought\n…<channel|>` before the answer.
    /// Gate Gemma-specific handling on the repo name so no other model's
    /// output is ever touched.
    static func isGemmaModel(_ repo: String) -> Bool {
        repo.lowercased().contains("gemma")
    }

    /// Drop Gemma thought channels from a model's text. A verbatim port of
    /// the strip_thinking macro in Gemma 4's own chat template (the canonical
    /// semantics — it's what the template applies to model turns in history):
    /// split on the closing `<channel|>`; within each part, drop everything
    /// from the opening `<|channel>` on. An unterminated thought (the final
    /// part carries an opening with no close) is dropped the same way. Tool
    /// calls survive: `<|tool_call>…<tool_call|>` contains neither marker.
    static func stripGemmaChannels(_ s: String) -> String {
        guard s.contains("<|channel>") || s.contains("<channel|>") else { return s }
        var out = ""
        for part in s.components(separatedBy: "<channel|>") {
            if let open = part.range(of: "<|channel>") {
                out += part[..<open.lowerBound]
            } else {
                out += part
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The repos currently held resident — mirrors vllm-mlx's `loadedModelRepos`.
    var loadedRepos: [String] { Array(residents.keys).sorted() }

    func setMemoryBudget(_ gb: Int) {
        memoryBudgetGB = gb
        // Bound MLX's GPU buffer cache. The default is unbounded, so the large
        // transient allocations of prefilling a big agent prompt could pile up
        // and fill the macOS compressor (the old "40 GB on an 8 GB model").
        // Prefix-caching now keeps per-turn prefill small, so the cap that used
        // to be 1 GB was throttling buffer reuse — raise it (still bounded so a
        // fresh full prefill can't run away). Tunable: BROMURE_GPU_CACHE_GB.
        let cacheGB = ProcessInfo.processInfo.environment["BROMURE_GPU_CACHE_GB"]
            .flatMap { Int($0) } ?? 4
        MLX.Memory.cacheLimit = cacheGB << 30
        // A soft overall ceiling when a budget is set, so the engine sheds cache
        // instead of OOM-killing this out-of-process child.
        if gb > 0 { MLX.Memory.memoryLimit = gb << 30 }
    }

    // MARK: - Model resolution & loading

    /// The directory holding a loadable `config.json` for a repo, if present —
    /// the flat local models dir (`…/BromureAC/models/<org>--<name>/`). Legacy
    /// hub-cache models are migrated here once at startup, so the engine never
    /// loads out of `~/.cache`.
    func snapshotDirectory(repo: String) -> URL? {
        let fm = FileManager.default
        let slug = repo.replacingOccurrences(of: "/", with: "--")
        let local = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BromureAC/models/\(slug)", isDirectory: true)
        return fm.fileExists(atPath: local.appendingPathComponent("config.json").path) ? local : nil
    }

    /// Load (or return cached) the model for `repo`. Concurrent callers for the
    /// same repo share one in-flight load.
    func ensureLoaded(repo: String, estMemGB: Int = 0) async throws -> ModelContainer {
        if let r = residents[repo] { r.lastUsed = Date(); return r.container }
        if let inFlight = loading[repo] { return try await inFlight.value }

        guard let dir = snapshotDirectory(repo: repo) else {
            throw EngineError.notDownloaded(repo)
        }
        let task = Task<ModelContainer, Error> {
            do {
                return try await loadModelContainer(from: dir, using: #huggingFaceTokenizerLoader())
            } catch {
                throw EngineError.loadFailed(repo, underlying: "\(error)")
            }
        }
        loading[repo] = task
        defer { loading[repo] = nil }
        let container = try await task.value
        residents[repo] = Resident(repo: repo, container: container, estMemGB: estMemGB)
        evictIfNeeded(keeping: repo)
        return container
    }

    /// Drop least-recently-used residents until the budget is satisfied. Never
    /// evicts the model just requested. No-op when the budget is 0 (unbounded).
    private func evictIfNeeded(keeping repo: String) {
        guard memoryBudgetGB > 0 else { return }
        func total() -> Int { residents.values.reduce(0) { $0 + max(1, $1.estMemGB) } }
        while total() > memoryBudgetGB, residents.count > 1 {
            let victim = residents.values
                .filter { $0.repo != repo }
                .min { $0.lastUsed < $1.lastUsed }
            guard let victim else { break }
            residents[victim.repo] = nil
            sessionCaches[victim.repo] = nil   // drop its KV cache too
        }
    }

    /// Unload everything (engine stop).
    func unloadAll() {
        residents.removeAll()
        sessionCaches.removeAll()
        MLX.Memory.clearCache()
    }

    /// Unload any resident model not in `keep` — used when a workspace closes
    /// and its model is no longer wanted by any open workspace. LRU eviction
    /// still bounds memory for the survivors; this just frees dropped ones
    /// promptly instead of waiting for pressure.
    func retain(only keep: Set<String>) {
        for repo in residents.keys where !keep.contains(repo) {
            residents[repo] = nil
            sessionCaches[repo] = nil
        }
        MLX.Memory.clearCache()
    }

    // MARK: - Generation

    /// Sampling + cache knobs, mapped from a request / catalog entry.
    struct Params: Sendable {
        var maxTokens: Int = 2048
        var temperature: Float = 0.6
        var topP: Float = 1.0
        var repetitionPenalty: Float?
        /// Cap the KV cache to bound memory on long contexts (RotatingKVCache).
        var maxKVSize: Int?
        /// Quantize the KV cache to this many bits (8 or 4). At an agent's real
        /// context (Claude Code sends ~20k-token prompts), decode is bound by
        /// reading the KV cache during attention; quantizing it speeds those
        /// reads (and halves/quarters its memory) for a small quality cost.
        /// nil = full-precision cache. `kvBitsStartAt` defers quantization until
        /// the context passes a threshold so short prompts stay exact.
        var kvBits: Int?
        var kvBitsStartAt: Int = 0
        /// Pass `enable_thinking` to the chat template. When on, the reasoning
        /// model (Qwen3) thinks before answering — but the `<think>` block is
        /// always stripped from the returned text (`stripThinking`), so the
        /// reasoning stays *silent*: it never reaches the agent or bloats the
        /// next turn's transcript. The cost is the extra tokens it spends
        /// thinking (hundreds/turn at ~85 tok/s); turn it off for raw speed.
        var enableThinking: Bool = true

        func toGenerateParameters() -> GenerateParameters {
            GenerateParameters(
                maxTokens: maxTokens,
                maxKVSize: maxKVSize,
                kvBits: kvBits,
                quantizedKVStart: kvBitsStartAt,
                temperature: temperature,
                topP: topP,
                repetitionPenalty: repetitionPenalty)
        }
    }

    /// Result of a completed generation.
    struct Completion: Sendable {
        var text: String
        var promptTokens: Int
        /// Tokens actually prefilled this turn — the full prompt minus the
        /// leading KV-cache prefix that was reused. This (not `promptTokens`) is
        /// what TTFT actually measured, so it's the correct numerator for
        /// prefill throughput. With prefix caching the two diverge sharply: an
        /// agent re-sending a 20k-token transcript prefills only the new turn.
        var prefilledTokens: Int
        var completionTokens: Int
        /// Time to first token (prefill seconds).
        var ttft: TimeInterval
        /// Decode seconds (generation, excluding prefill).
        var decodeSeconds: TimeInterval
        var finishReason: String   // "stop" | "length"
    }

    /// Stream a chat completion. `onDelta` receives each newly-decoded text
    /// fragment; return `false` to cancel generation early. `tools` are passed
    /// to the chat template so the model formats native tool calls.
    @discardableResult
    func generate(
        repo: String,
        messages: [Chat.Message],
        tools: [ToolDef]? = nil,
        params: Params,
        estMemGB: Int = 0,
        onDelta: @Sendable @escaping (String) -> Bool
    ) async throws -> Completion {
        // One generation at a time — the prefix KV cache can't be shared by
        // concurrent (re-entrant) generations. See genLock above.
        await genLock()
        defer { genUnlock() }
        let container = try await ensureLoaded(repo: repo, estMemGB: estMemGB)
        let gp = params.toGenerateParameters()
        let sessions = sessionSlots(for: repo)
        let maxTokens = params.maxTokens
        let enableThinking = params.enableThinking

        // Pin this model's working set as non-pageable for the run — Apple's
        // recommendation for LLM serving (WWDC25 298) so a memory-pressured host
        // (the VMs share unified memory) can't page weights out mid-decode.
        // Scoped: the previous limit is restored when generation returns.
        let wiredBytes = (estMemGB > 0 ? estMemGB : max(memoryBudgetGB, 1)) << 30
        return try await MLX.Memory.withWiredLimit(wiredBytes) {
        try await container.perform { [sessions] (context: ModelContext) in
            let input = try await context.processor.prepare(
                input: UserInput(chat: MLXEngine.withToolReminder(messages, hasTools: tools?.isEmpty == false,
                                                                  gemma: MLXEngine.isGemmaModel(repo)),
                                 tools: tools?.map(\.asToolSpec),
                                 additionalContext: ["enable_thinking": enableThinking]))
            // The full prompt as token ids — what we prefix-match the cache on.
            let promptIds = input.text.tokens.asArray(Int32.self).map(Int.init)

            // --- Slot selection -----------------------------------------------
            // Route the request to the slot it continues; a divergent prompt
            // (sidechain, new conversation) takes a fresh slot so it can't
            // trash the main conversation's cache. See chooseSlot.
            let session: SessionCache
            let slotIndex: Int
            switch MLXEngine.chooseSlot(prompt: promptIds,
                                        slotTokens: sessions.slots.map(\.tokens)) {
            case .reuse(let i):
                session = sessions.slots[i]
                slotIndex = i
            case .fresh:
                session = SessionCache()
                if sessions.slots.count >= MLXEngine.maxCacheSlots,
                   let lru = sessions.slots.indices.min(by: {
                       sessions.slots[$0].lastUsed < sessions.slots[$1].lastUsed }) {
                    sessions.slots[lru] = session
                    slotIndex = lru
                } else {
                    sessions.slots.append(session)
                    slotIndex = sessions.slots.count - 1
                }
            }
            // Mark now, not just after generation, so a request that dies
            // mid-decode still counts as recent for LRU eviction.
            session.lastUsed = Date()

            // --- Prefix-cache reuse -------------------------------------------
            // Reuse the longest leading run of tokens already in the KV cache and
            // prefill only the divergent suffix. For an agent re-sending its whole
            // transcript each turn, the shared prefix is everything up to the new
            // turn, so prefill collapses from O(transcript) to O(new tokens).
            if session.cache.isEmpty {
                session.cache = context.model.newCache(parameters: gp)
                session.tokens = []
            }
            var reuse = max(0, min(MLXEngine.commonPrefix(session.tokens, promptIds),
                                   promptIds.count - 1))
            let drop = session.tokens.count - reuse
            if drop > 0 {
                if session.cache.allSatisfy({ $0.isTrimmable }) {
                    for c in session.cache { _ = c.trim(drop) }
                } else {
                    // Non-trimmable cache (e.g. RotatingKVCache from maxKVSize) —
                    // can't rewind, so start fresh and prefill the whole prompt.
                    session.cache = context.model.newCache(parameters: gp)
                    reuse = 0
                }
            }
            let suffix = Array(promptIds[reuse...]).map { Int32($0) }
            let lmInput = LMInput(tokens: MLXArray(suffix))
            let reusedCount = reuse

            let iterator = try TokenIterator(
                input: lmInput, model: context.model, cache: session.cache, parameters: gp)

            var detok = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
            var text = ""
            var generatedIds: [Int] = []
            var cancelled = false

            let start = Date()
            var firstTokenAt: Date?

            let info = MLXLMCommon.generate(
                input: lmInput, context: context, iterator: iterator
            ) { (token: Int) in
                if firstTokenAt == nil { firstTokenAt = Date() }
                generatedIds.append(token)
                detok.append(token: token)
                if let piece = detok.next(), !piece.isEmpty {
                    text += piece
                    if !onDelta(piece) { cancelled = true; return .stop }
                }
                if generatedIds.count >= maxTokens { return .stop }
                return .more
            }
            _ = info

            // Keep the ledger exactly aligned with the cache offset: the iterator
            // may advance the cache past the tokens we counted (the EOS step / an
            // in-flight lookahead). Trim the excess so the next prefix match is
            // sound; clamp the ledger if the cache somehow came up short.
            session.tokens = promptIds + generatedIds
            if let off = session.cache.first?.offset {
                if off > session.tokens.count, session.cache.allSatisfy({ $0.isTrimmable }) {
                    for c in session.cache { _ = c.trim(off - session.tokens.count) }
                } else if off < session.tokens.count {
                    session.tokens = Array(session.tokens.prefix(off))
                }
            }
            session.lastUsed = Date()

            let ttft = (firstTokenAt ?? Date()).timeIntervalSince(start)
            let decode = Date().timeIntervalSince(firstTokenAt ?? start)
            let reachedCap = generatedIds.count >= maxTokens
            let finish = (cancelled || reachedCap) ? "length" : "stop"
            if ProcessInfo.processInfo.environment["BROMURE_INFER_DEBUG"] != nil {
                let tps = Double(generatedIds.count) / max(decode, 0.001)
                FileHandle.standardError.write(Data(
                    "[mlx] slot=\(slotIndex)/\(sessions.slots.count) prompt=\(promptIds.count) reused=\(reusedCount) prefilled=\(suffix.count) gen=\(generatedIds.count) ttft=\(String(format: "%.2f", ttft))s \(String(format: "%.1f", tps)) tok/s\n".utf8))
            }
            let visible = MLXEngine.isGemmaModel(repo)
                ? MLXEngine.stripGemmaChannels(MLXEngine.stripThinking(text))
                : MLXEngine.stripThinking(text)
            return Completion(
                text: visible,
                promptTokens: promptIds.count,
                prefilledTokens: suffix.count,
                completionTokens: generatedIds.count,
                ttft: ttft,
                decodeSeconds: decode,
                finishReason: finish)
        }
        }
    }
}

/// A tool definition, protocol-agnostic, fed to the chat template. The wire
/// servers translate Anthropic `input_schema` / OpenAI `function.parameters`
/// into this shape. The JSON-Schema parameters are carried as a serialized
/// string so the type stays `Sendable` across the actor boundary (the
/// `[String: Any]` the template wants is rebuilt inside the engine).
struct ToolDef: Sendable {
    var name: String
    var description: String
    /// Serialized JSON Schema object for the tool's parameters.
    var parametersJSONString: String

    /// `Tokenizers.ToolSpec` (`[String: Any]`) the chat template consumes.
    var asToolSpec: [String: Any] {
        let raw = (try? JSONSerialization.jsonObject(
            with: Data(parametersJSONString.utf8))) as? [String: Any] ?? [:]
        // Drop JSON `null`s — swift-jinja can't convert NSNull and aborts the
        // whole chat-template render ("Cannot convert Optional<Any> to Jinja
        // Value"), 500ing any request whose tool schema has a null field.
        let stripped = (Self.stripNulls(raw) as? [String: Any]) ?? [:]
        // …and normalize `type` to a plain string. Gemma-family templates run
        // `value['type'] | upper` on every parameter schema, so a JSON-Schema
        // union (`"type": ["string", "null"]`) or a type-less property
        // (anyOf/enum-only — both common in coding-agent tools) aborts the
        // render with "upper filter requires string".
        let params = (Self.normalizeSchemaTypes(stripped) as? [String: Any]) ?? [:]
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": params,
            ],
        ]
    }

    static func stripNulls(_ v: Any) -> Any? {
        if v is NSNull { return nil }
        if let d = v as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, val) in d { if let s = stripNulls(val) { out[k] = s } }
            return out
        }
        if let a = v as? [Any] { return a.compactMap { stripNulls($0) } }
        return v
    }

    /// Keys whose value is a *map of name → schema*. Their values are schemas;
    /// the map itself is not — a parameter literally named "items" or "enum"
    /// must never make the map look like a schema.
    private static let schemaMapKeys: Set<String> =
        ["properties", "patternProperties", "definitions", "$defs"]
    /// Keys whose value is a single subschema.
    private static let schemaKeys: Set<String> =
        ["items", "additionalProperties", "additionalItems", "not",
         "if", "then", "else", "contains", "propertyNames"]
    /// Keys whose value is a list of subschemas.
    private static let schemaListKeys: Set<String> =
        ["anyOf", "oneOf", "allOf", "prefixItems"]

    /// Ensure every node in *schema position* carries a plain-string `type`.
    /// Gemma-family templates run `value['type'] | upper` on each node they
    /// walk — a union array (["string", "null"]), a non-string, or a missing
    /// `type` (description-only / anyOf-only properties, both routine in
    /// agent tools) all abort the render with "upper filter requires string"
    /// (swift-jinja throws on undefined too, unlike Python's `| upper`).
    /// Only known schema-carrying keys are recursed into; everything else
    /// (description, enum, default, required, …) passes through verbatim, so
    /// non-schema values can never grow phantom keys.
    static func normalizeSchemaTypes(_ v: Any) -> Any {
        guard var out = v as? [String: Any] else { return v }
        for (k, val) in out {
            if Self.schemaMapKeys.contains(k), let m = val as? [String: Any] {
                out[k] = m.mapValues { normalizeSchemaTypes($0) }
            } else if Self.schemaKeys.contains(k) {
                // `items` may be a tuple (list of schemas); bools
                // (additionalProperties: false) pass through untouched.
                if let list = val as? [Any] { out[k] = list.map { normalizeSchemaTypes($0) } }
                else { out[k] = normalizeSchemaTypes(val) }
            } else if Self.schemaListKeys.contains(k), let list = val as? [Any] {
                out[k] = list.map { normalizeSchemaTypes($0) }
            }
        }
        if let types = out["type"] as? [Any] {
            // Union: keep the first non-"null" member; remember nullability
            // (Gemma's OpenAPI-style declarations render `nullable`).
            let names = types.compactMap { $0 as? String }
            out["type"] = names.first { $0.lowercased() != "null" } ?? "string"
            if names.contains(where: { $0.lowercased() == "null" }), out["nullable"] == nil {
                out["nullable"] = true
            }
        } else if !(out["type"] is String) {
            if out["properties"] != nil { out["type"] = "object" }
            else if out["items"] != nil || out["prefixItems"] != nil { out["type"] = "array" }
            else { out["type"] = "string" }   // enum/anyOf/description-only/…
        }
        return out
    }
}
