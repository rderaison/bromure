import Foundation
import OnnxRuntimeBindings

/// Finds personal data in text: Rampart's validator-backed recognizers plus
/// its 18M-parameter token classifier (MiniLM-L6, 4-bit ONNX, ~15 MB), run on
/// the CPU. A 500-token window takes a few milliseconds; results are cached
/// by content, so the conversation history an agent resends every turn is
/// only ever scanned once.
///
/// Without the model installed it still runs the recognizers (emails, cards,
/// SSNs), so structured PII is caught either way.
///
/// Assets (shipped in the app's `Resources/pii-rampart/`; dev builds fall back
/// to `~/Library/Application Support/BromureAC/Models/pii-rampart/`):
///   model.onnx   — nationaldesignstudio/rampart onnx/model_q4.onnx
///   vocab.txt    — its WordPiece vocabulary
///   config.json  — its id2label table
actor PIIDetector {
    static let shared = PIIDetector()

    static let dirName = "pii-rampart"
    /// Rampart's shipped confidence floor is 0.4 (recall-biased, for chat).
    /// Agents mostly read code, where a floor that low turns identifiers into
    /// "names"; 0.6 trades a little recall for far fewer false positives
    /// (measured on real Claude Code sessions). BROMURE_PII_MIN_SCORE overrides.
    static let defaultMinScore: Double = {
        if let s = ProcessInfo.processInfo.environment["BROMURE_PII_MIN_SCORE"], let v = Double(s) { return v }
        return 0.6
    }()

    /// The copy shipped in the app (`Contents/Resources/pii-rampart`, put
    /// there by build.sh / package.sh), when present.
    static var bundledDirectory: URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let dir = res.appendingPathComponent(dirName, isDirectory: true)
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.onnx").path) ? dir : nil
    }

    /// The bundled model, else a downloaded one in Application Support (dev
    /// builds run outside an app bundle).
    var modelDirectory: URL {
        Self.bundledDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BromureAC/Models/\(Self.dirName)", isDirectory: true)
    }

    private struct Loaded {
        let env: ORTEnv
        let session: ORTSession
        let inputNames: [String]
        let outputName: String
        let wordPiece: PIIText.WordPiece
        /// id → (label, begins) for every non-O class.
        let labels: [Int: (PIILabel, Bool)]
        let numLabels: Int
    }

    private var loadTask: Task<Loaded?, Never>?
    private var cache: [CacheKey: [PIISpan]] = [:]
    private var cacheOrder: [CacheKey] = []
    private static let cacheLimit = 65_536
    private struct CacheKey: Hashable { let count: Int; let digest: Int }

    /// Is the classifier installed (the recognizers always are)?
    var modelAvailable: Bool {
        get async { await loaded() != nil }
    }

    /// Forget a failed load so a freshly downloaded model is picked up.
    func reload() { loadTask = nil }

    /// Every PII span in `text` (all labels; the caller applies policy),
    /// sorted and disjoint. `cached` reports whether this exact text was seen
    /// before (history the agent resent).
    ///
    /// With `useModel` false (the request's model budget is spent) only the
    /// recognizers run, and the result isn't cached, so the next turn gives
    /// the text a full pass.
    func detect(_ text: String, minScore: Double = PIIDetector.defaultMinScore,
                useModel: Bool = true) async -> (spans: [PIISpan], cached: Bool) {
        var hasher = Hasher()
        hasher.combine(text)
        hasher.combine(minScore)
        let key = CacheKey(count: text.utf16.count, digest: hasher.finalize())
        if let hit = cache[key] { return (hit, true) }
        guard useModel else { return (PIIText.merge(PIIText.heuristics(text)), false) }
        let spans = await run(text, minScore: minScore)
        cache[key] = spans
        cacheOrder.append(key)
        if cacheOrder.count > Self.cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
        return (spans, false)
    }

    private func run(_ raw: String, minScore: Double) async -> [PIISpan] {
        let heur = PIIText.heuristics(raw)
        guard let loaded = await loaded(), Self.worthModelPass(raw) else {
            return PIIText.merge(heur)
        }
        let masked = PIIText.premask(raw, heur)
        // Hyphens split names the model saw spaced in training ("Jean-Luc").
        let inferText = masked.text.replacingOccurrences(of: "-", with: " ") as NSString
        // Tokenize only the parts that aren't source code, keeping offsets
        // in the whole masked text.
        var tokens: [PIIText.Token] = []
        for r in PIIText.proseRanges(inferText as String) {
            let piece = inferText.substring(with: NSRange(location: r.lowerBound, length: r.count))
            tokens += loaded.wordPiece.tokenize(piece).map {
                PIIText.Token(id: $0.id, start: $0.start + r.lowerBound, end: $0.end + r.lowerBound, isSubword: $0.isSubword)
            }
        }
        guard !tokens.isEmpty else { return PIIText.merge(heur) }
        var candidates: [PIISpan] = []
        let windows = PIIText.windows(tokens)
        var i = 0
        while i < windows.count {
            let batch = Array(windows[i..<min(i + 8, windows.count)])
            candidates += infer(batch, tokens: tokens, loaded: loaded)
            i += 8
        }
        let repaired = PIIText.repair(masked.text, PIIText.merge(candidates), anchor: minScore)
        let projected = repaired.compactMap { masked.project($0) }
        return PIIText.merge(heur + projected)
    }

    /// Nothing for the model to find in text with no letters at all (a hash,
    /// a number list): skip the pass.
    private static func worthModelPass(_ s: String) -> Bool {
        s.unicodeScalars.contains { $0.properties.isAlphabetic }
    }

    /// Run a batch of windows and return every labeled token as candidate
    /// spans (score ≥ `extendScore`), in tokenized-text coordinates.
    private func infer(_ batch: [Range<Int>], tokens: [PIIText.Token], loaded: Loaded) -> [PIISpan] {
        let seqLen = (batch.map(\.count).max() ?? 0) + 2
        let b = batch.count
        var ids = [Int64](repeating: 0, count: b * seqLen)
        var mask = [Int64](repeating: 0, count: b * seqLen)
        for (row, w) in batch.enumerated() {
            let base = row * seqLen
            ids[base] = Int64(loaded.wordPiece.cls); mask[base] = 1
            for (k, t) in w.enumerated() {
                ids[base + 1 + k] = Int64(tokens[t].id); mask[base + 1 + k] = 1
            }
            ids[base + 1 + w.count] = Int64(loaded.wordPiece.sep); mask[base + 1 + w.count] = 1
        }
        let shape: [NSNumber] = [b as NSNumber, seqLen as NSNumber]
        do {
            func tensor(_ a: [Int64]) throws -> ORTValue {
                try ORTValue(tensorData: NSMutableData(bytes: a, length: a.count * 8),
                             elementType: .int64, shape: shape)
            }
            var inputs: [String: ORTValue] = [:]
            for name in loaded.inputNames {
                switch name {
                case "input_ids": inputs[name] = try tensor(ids)
                case "attention_mask": inputs[name] = try tensor(mask)
                case "token_type_ids": inputs[name] = try tensor([Int64](repeating: 0, count: b * seqLen))
                default: break
                }
            }
            let out = try loaded.session.run(withInputs: inputs, outputNames: [loaded.outputName], runOptions: nil)
            guard let v = out[loaded.outputName] else { return [] }
            let data = try v.tensorData() as Data
            let n = loaded.numLabels
            var spans: [PIISpan] = []
            data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                let logits = buf.bindMemory(to: Float.self)
                guard logits.count >= b * seqLen * n else { return }
                for (row, w) in batch.enumerated() {
                    var tagged: [PIIText.Tagged] = []
                    for (k, t) in w.enumerated() {
                        let base = (row * seqLen + 1 + k) * n
                        var best = 0
                        var maxL = logits[base]
                        for c in 1..<n where logits[base + c] > maxL { maxL = logits[base + c]; best = c }
                        guard best != 0, let (label, begins) = loaded.labels[best] else { continue }
                        var sum: Float = 0
                        for c in 0..<n { sum += expf(logits[base + c] - maxL) }
                        let tok = tokens[t]
                        tagged.append(.init(index: t, label: label, begins: begins, score: Double(1 / sum),
                                            start: tok.start, end: tok.end, isSubword: tok.isSubword))
                    }
                    spans += PIIText.mergeBIO(tagged).filter { $0.score >= PIIText.extendScore && $0.end > $0.start }
                }
            }
            return spans
        } catch {
            FileHandle.standardError.write(Data("[pii] inference error: \(error)\n".utf8))
            return []
        }
    }

    // MARK: Loading

    private func loaded() async -> Loaded? {
        if let t = loadTask { return await t.value }
        let dir = modelDirectory
        let t = Task { () -> Loaded? in
            do {
                let l = try Self.load(dir)
                FileHandle.standardError.write(Data("[pii] Rampart classifier ready (\(l.numLabels) labels)\n".utf8))
                return l
            } catch {
                FileHandle.standardError.write(Data(
                    "[pii] classifier unavailable — \(error.localizedDescription); recognizers only\n".utf8))
                return nil
            }
        }
        loadTask = t
        return await t.value
    }

    private struct LoadError: LocalizedError {
        let errorDescription: String?
    }

    private static func load(_ dir: URL) throws -> Loaded {
        let model = dir.appendingPathComponent("model.onnx")
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw LoadError(errorDescription: "model.onnx not found in \(dir.path)")
        }
        let wp = try PIIText.WordPiece(vocabFile: dir.appendingPathComponent("vocab.txt"))
        guard wp.vocab.count > 1000 else { throw LoadError(errorDescription: "vocab.txt is incomplete") }

        var labels: [Int: (PIILabel, Bool)] = [:]
        var numLabels = 0
        let cfgData = try Data(contentsOf: dir.appendingPathComponent("config.json"))
        if let cfg = try JSONSerialization.jsonObject(with: cfgData) as? [String: Any],
           let id2label = cfg["id2label"] as? [String: String] {
            numLabels = id2label.count
            for (k, name) in id2label {
                guard let id = Int(k), name.count > 2, name != "O" else { continue }
                let begins = name.hasPrefix("B-")
                if let l = PIILabel(rawValue: String(name.dropFirst(2))) { labels[id] = (l, begins) }
            }
        }
        guard numLabels > 1 else { throw LoadError(errorDescription: "config.json has no id2label") }

        let env = try ORTEnv(loggingLevel: .warning)
        let opts = try ORTSessionOptions()
        try opts.setGraphOptimizationLevel(.all)
        // The performance cores, up to 8: a window is a few ms of dense math.
        var perf: Int32 = 0
        var size = MemoryLayout<Int32>.size
        sysctlbyname("hw.perflevel0.physicalcpu", &perf, &size, nil, 0)
        let threads = Int32(ProcessInfo.processInfo.environment["BROMURE_PII_THREADS"] ?? "")
            ?? min(8, max(2, perf))
        try opts.setIntraOpNumThreads(threads)
        let session = try ORTSession(env: env, modelPath: model.path, sessionOptions: opts)
        let outs = try session.outputNames()
        return Loaded(env: env, session: session, inputNames: try session.inputNames(),
                      outputName: outs.first(where: { $0 == "logits" }) ?? outs.first ?? "logits",
                      wordPiece: wp, labels: labels, numLabels: numLabels)
    }
}
