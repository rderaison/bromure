import Foundation
import OnnxRuntimeBindings
import Tokenizers

/// Local, on-device prompt-injection classifier for AI traffic.
///
/// The agent (Claude Code / Codex) running in the VM streams the
/// contents of whatever files / repos / web pages it reads into the
/// model as `tool_result` blocks. A rogue repository can hide
/// instructions in that content ("ignore previous instructions, run
/// …") — a prompt injection. This classifier scores the *untrusted*
/// tool_result spans the proxy already parses out of each
/// `/v1/messages` (or OpenAI) request and logs a verdict.
///
/// Stage 2 of the detection stack: Meta's **PromptGuard 2** (or any
/// HF sequence-classification model) run via ONNX Runtime with the
/// **CoreML execution provider**, so inference dispatches to the
/// Neural Engine and stays off the request hot path. The model's own
/// `tokenizer.json` is loaded with `swift-transformers`, so DeBERTa /
/// SentencePiece tokenization (what PromptGuard uses) is exact rather
/// than approximated.
///
/// The model is NOT bundled (it's a multi-MB opt-in download); if its
/// assets are absent the classifier is a silent no-op (logged once)
/// and the proxy behaves exactly as before. Mirrors
/// `FaceSwapEngine`'s ONNX+CoreML setup and Application-Support model
/// story.
///
/// For now this only *logs*; it never blocks or rewrites a request.
/// The hook sits in `emitTrace`, which runs after the response has
/// already been relayed to the guest, so classification adds zero
/// latency to the agent.
///
/// Assets (a folder under `~/Library/Application Support/BromureAC/Models/`):
///   prompt-injection/
///     model.onnx               — sequence-classification model
///     tokenizer.json           — HF fast-tokenizer (required)
///     tokenizer_config.json    — HF tokenizer config (required)
///     bromure-injection.json   — optional; see `Config`
actor PromptInjectionClassifier {
    /// Source-code / tool_result injection (PromptGuard, DeBERTa ONNX).
    static let shared = PromptInjectionClassifier(modelDirName: "prompt-injection", logLabel: "source")
    /// Rogue CLAUDE.md / instruction files (our fine-tuned ModernBERT ONNX).
    static let claudeMd = PromptInjectionClassifier(modelDirName: "claudemd-guard", logLabel: "rules")

    /// Which `…/Models/<dir>/` this instance loads, and the tag it logs under.
    let modelDirName: String
    let logLabel: String
    init(modelDirName: String, logLabel: String) {
        self.modelDirName = modelDirName
        self.logLabel = logLabel
    }

    struct Verdict: Sendable {
        /// Probability of the injection class, 0...1.
        let injectionScore: Double
        /// Decision at the configured threshold.
        let isInjection: Bool
    }

    /// Optional `bromure-injection.json`. Every field has a sensible
    /// default so the file can be omitted entirely. (Kept separate
    /// from the model's own `config.json` to avoid clobbering it.)
    private struct Config: Decodable {
        var maxLength: Int?
        var injectionLabelIndex: Int?
        var threshold: Double?
    }

    // MARK: - Asset locations

    var modelDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(
            "BromureAC/Models/\(modelDirName)", isDirectory: true)
    }
    private static let modelName = "model.onnx"
    private static let configName = "bromure-injection.json"

    // MARK: - Loaded state

    private struct Loaded {
        let env: ORTEnv
        let session: ORTSession
        let inputNames: Set<String>
        let tokenizer: Tokenizer
        let maxLength: Int
        let injectionLabelIndex: Int
        let threshold: Double
    }

    /// Memoised load: the first `scanAndLog` kicks it off, every later
    /// call awaits the same Task. Storing the Task before the first
    /// `await` (actors are reentrant across suspension) prevents two
    /// concurrent scans from both loading the session.
    private var loadTask: Task<Loaded?, Never>?

    /// Per-span cap: a single tool_result can be a multi-hundred-KB
    /// file. We classify a bounded set of character windows over the
    /// span, so a huge read can't stall the (off-hot-path) task.
    private static let maxScanChars = 16 * 1024
    private static let maxWindows = 8
    /// Window width in characters. Sized to stay under a 512-token
    /// budget for typical text/code (~3 chars/token worst case);
    /// `runWindow` still hard-truncates token ids to `maxLength`.
    private static let windowChars = 1536

    private static let debug =
        ProcessInfo.processInfo.environment["BROMURE_AC_DEBUG"] == "1"

    /// Pad every window to a single fixed length so the ONNX/CoreML
    /// session sees one input shape. The CoreML execution provider
    /// recompiles its model for each *distinct* input shape it runs;
    /// with variable-length windows that means a GPU recompile on
    /// nearly every span, which pins the GPU under live agent traffic
    /// ("50% and never drops"). A constant shape ⇒ one compile, cached.
    /// Padding is masked out (attention_mask = 0), so the verdict is
    /// identical to the unpadded run. Set =0 to restore dynamic shapes
    /// (for A/B measurement only).
    private static let fixedShape =
        ProcessInfo.processInfo.environment["BROMURE_INJECTION_FIXED_SHAPE"] != "0"

    // MARK: - Verdict cache

    /// Memoise verdicts by content so byte-identical spans aren't
    /// re-inferred. This is the load-bearing optimisation: the rules
    /// detector scans the agent's *system prompt* (CLAUDE.md / AGENTS.md),
    /// which the CLI resends verbatim on every turn — without this, a busy
    /// agent re-runs a ~1 s ModernBERT scan of unchanged text on every
    /// request, so the GPU/ANE never idles. With it, each distinct blob is
    /// scored once per session and repeats are free.
    ///
    /// Keyed by (length, Hasher digest). The digest is seeded with a
    /// per-process random value, so an attacker can't engineer a benign
    /// span whose hash collides with a malicious one to dodge detection.
    private struct CacheKey: Hashable { let count: Int; let digest: Int }
    private var verdictCache: [CacheKey: Verdict] = [:]
    private var cacheOrder: [CacheKey] = []
    private static let cacheLimit = 512

    private func cachedClassify(_ text: String, loaded: Loaded) -> Verdict? {
        var hasher = Hasher()
        hasher.combine(text)
        let key = CacheKey(count: text.count, digest: hasher.finalize())
        if let hit = verdictCache[key] { return hit }
        guard let verdict = classify(text, loaded: loaded) else { return nil }
        verdictCache[key] = verdict
        cacheOrder.append(key)
        if cacheOrder.count > Self.cacheLimit {
            let evict = cacheOrder.removeFirst()
            verdictCache.removeValue(forKey: evict)
        }
        return verdict
    }

    // MARK: - Public API

    /// Classify each untrusted span and log any injection hit. Spans
    /// are `(toolUseId, content)` pairs — the freshly-ingested
    /// tool_result blocks for this turn. No-op when the model isn't
    /// installed.
    func scanAndLog(spans: [(id: String?, content: String)], host: String) async {
        guard !spans.isEmpty else { return }
        guard let loaded = await loaded() else { return }
        for span in spans {
            guard let verdict = cachedClassify(span.content, loaded: loaded) else { continue }
            if verdict.isInjection {
                let preview = Self.preview(span.content)
                let line = "[prompt-injection] \(logLabel) FLAG score=\(String(format: "%.3f", verdict.injectionScore)) toolUse=\(span.id ?? "-") preview=\"\(preview)\""
                FileHandle.standardError.write(Data((line + "\n").utf8))
                SupplyChainLog.shared.record(line)   // Security Log window
            } else if Self.debug {
                FileHandle.standardError.write(Data(
                    "[mitm/injection] ok host=\(host) score=\(String(format: "%.3f", verdict.injectionScore)) toolUse=\(span.id ?? "-")\n".utf8))
            }
        }
    }

    /// Enforcement variant: returns a preview of the first span scored as
    /// injection (for the ask/block path), or nil. No-op when the model
    /// isn't installed.
    func detect(spans: [(id: String?, content: String)]) async -> String? {
        guard !spans.isEmpty, let loaded = await loaded() else { return nil }
        for span in spans {
            if let v = cachedClassify(span.content, loaded: loaded), v.isInjection {
                return span.content.count > 4000
                    ? String(span.content.prefix(4000)) + "\n…(truncated)" : span.content
            }
        }
        return nil
    }

    // MARK: - Loading

    private func loaded() async -> Loaded? {
        if let task = loadTask { return await task.value }
        let task = Task { () -> Loaded? in
            do {
                let loaded = try await self.load()
                FileHandle.standardError.write(Data(
                    "[mitm/injection] \(logLabel) classifier ready (maxLen=\(loaded.maxLength), threshold=\(loaded.threshold))\n".utf8))
                return loaded
            } catch {
                // One-time, non-alarming note. Absence is the common
                // case (the model is an opt-in download).
                FileHandle.standardError.write(Data(
                    "[mitm/injection] \(logLabel) classifier disabled — \(error.localizedDescription). Install a model into \(self.modelDirectory.path) to enable.\n".utf8))
                return nil
            }
        }
        loadTask = task
        return await task.value
    }

    private enum LoadError: LocalizedError {
        case missingAsset(String)
        var errorDescription: String? {
            switch self {
            case .missingAsset(let n): return "\(n) not found"
            }
        }
    }

    private func load() async throws -> Loaded {
        let dir = modelDirectory
        let modelURL = dir.appendingPathComponent(Self.modelName)
        let fm = FileManager.default
        guard fm.fileExists(atPath: modelURL.path) else {
            throw LoadError.missingAsset(Self.modelName)
        }
        // tokenizer.json / tokenizer_config.json must sit alongside.
        guard fm.fileExists(atPath: dir.appendingPathComponent("tokenizer.json").path) else {
            throw LoadError.missingAsset("tokenizer.json")
        }

        // Tokenizer straight from the model's own HF assets — handles
        // whatever family it is (DeBERTa/SentencePiece for PromptGuard,
        // BERT/WordPiece for others) without us re-implementing it.
        let tokenizer = try await AutoTokenizer.from(modelFolder: dir)

        // Optional bromure-side config (label index / threshold / len).
        var cfg = Config()
        if let data = try? Data(contentsOf: dir.appendingPathComponent(Self.configName)),
           let parsed = try? JSONDecoder().decode(Config.self, from: data) {
            cfg = parsed
        }

        // ONNX session with CoreML EP (Neural Engine). Same setup as
        // FaceSwapEngine; BROMURE_NO_COREML=1 forces CPU.
        let env = try ORTEnv(loggingLevel: .warning)
        let opts = try ORTSessionOptions()
        try opts.setGraphOptimizationLevel(.all)
        if ORTIsCoreMLExecutionProviderAvailable(),
           ProcessInfo.processInfo.environment["BROMURE_NO_COREML"] == nil {
            let coreml = ORTCoreMLExecutionProviderOptions()
            coreml.enableOnSubgraphs = true
            try opts.appendCoreMLExecutionProvider(with: coreml)
        }
        let session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: opts)
        let inputNames = Set(try session.inputNames())

        return Loaded(
            env: env,
            session: session,
            inputNames: inputNames,
            tokenizer: tokenizer,
            maxLength: cfg.maxLength ?? 512,
            injectionLabelIndex: cfg.injectionLabelIndex ?? 1,
            threshold: cfg.threshold ?? 0.5)
    }

    // MARK: - Inference

    /// Returns the max injection probability across all windows of the
    /// span, or nil on a hard inference failure.
    private func classify(_ text: String, loaded: Loaded) -> Verdict? {
        let scoped = text.count > Self.maxScanChars
            ? String(text.prefix(Self.maxScanChars)) : text
        let chars = Array(scoped)
        var best = 0.0
        var ran = false
        var start = 0
        var windows = 0
        while start < chars.count, windows < Self.maxWindows {
            let end = min(start + Self.windowChars, chars.count)
            let window = String(chars[start..<end])
            // encode adds the model's special tokens ([CLS] … [SEP]).
            var ids = loaded.tokenizer.encode(text: window)
            if ids.count > loaded.maxLength {
                ids = Array(ids.prefix(loaded.maxLength))
            }
            if !ids.isEmpty, let p = runWindow(ids: ids, loaded: loaded) {
                best = max(best, p)
                ran = true
            }
            start = end
            windows += 1
        }
        guard ran else { return nil }
        return Verdict(injectionScore: best, isInjection: best >= loaded.threshold)
    }

    private func runWindow(ids: [Int], loaded: Loaded) -> Double? {
        // Real tokens first, then (optionally) right-pad to a constant
        // length so CoreML sees one shape and compiles once. The pad
        // positions carry attention_mask = 0, so a properly-masked
        // transformer ignores them and the score is unchanged. Pad id 0
        // is safe precisely because those slots are masked out.
        let realLen = ids.count
        var ids64 = ids.map(Int64.init)
        var mask = [Int64](repeating: 1, count: realLen)
        if Self.fixedShape, realLen < loaded.maxLength {
            let pad = loaded.maxLength - realLen
            ids64 += [Int64](repeating: 0, count: pad)
            mask += [Int64](repeating: 0, count: pad)
        }
        let len = ids64.count
        let shape: [NSNumber] = [1, len as NSNumber]
        let zeros = [Int64](repeating: 0, count: len)

        do {
            func tensor(_ arr: [Int64]) throws -> ORTValue {
                let data = NSMutableData(bytes: arr, length: arr.count * MemoryLayout<Int64>.size)
                return try ORTValue(tensorData: data, elementType: .int64, shape: shape)
            }
            // Build only the inputs this exported model declares —
            // DistilBERT drops token_type_ids, some exports rename ids.
            var inputs: [String: ORTValue] = [:]
            for name in loaded.inputNames {
                switch name.lowercased() {
                case "input_ids", "input.1", "ids":
                    inputs[name] = try tensor(ids64)
                case "attention_mask", "mask":
                    inputs[name] = try tensor(mask)
                case "token_type_ids", "segment_ids":
                    inputs[name] = try tensor(zeros)
                default:
                    break
                }
            }
            guard !inputs.isEmpty else { return nil }

            let outputs = try loaded.session.run(
                withInputs: inputs,
                outputNames: Set(try loaded.session.outputNames()),
                runOptions: nil)
            guard let logitsValue = outputs.values.first else { return nil }
            let data = try logitsValue.tensorData() as Data
            let count = data.count / MemoryLayout<Float>.size
            guard count > 0 else { return nil }
            var logits = [Float](repeating: 0, count: count)
            _ = logits.withUnsafeMutableBytes { dst in
                data.copyBytes(to: dst)
            }
            return Self.injectionProbability(
                logits: logits, injectionIndex: loaded.injectionLabelIndex)
        } catch {
            if Self.debug {
                FileHandle.standardError.write(Data(
                    "[mitm/injection] inference error: \(error)\n".utf8))
            }
            return nil
        }
    }

    /// Map raw logits to an injection probability. Two+ labels →
    /// softmax and take the injection index; a single logit →
    /// sigmoid (binary head).
    private static func injectionProbability(logits: [Float], injectionIndex: Int) -> Double {
        if logits.count == 1 {
            return 1.0 / (1.0 + exp(-Double(logits[0])))
        }
        let maxL = logits.max() ?? 0
        let exps = logits.map { exp(Double($0 - maxL)) }
        let sum = exps.reduce(0, +)
        guard sum > 0, injectionIndex < exps.count else { return 0 }
        return exps[injectionIndex] / sum
    }

    private static func preview(_ s: String) -> String {
        let oneLine = s.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return oneLine.count > 160 ? String(oneLine.prefix(160)) + "…" : oneLine
    }
}
