import Foundation
import MLX
import MLXLMCommon
import MLXLLM
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
            case .loadFailed(let r, let u): return "Couldn't load \(r): \(u)"
            }
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

    /// The repos currently held resident — mirrors vllm-mlx's `loadedModelRepos`.
    var loadedRepos: [String] { Array(residents.keys).sorted() }

    func setMemoryBudget(_ gb: Int) { memoryBudgetGB = gb }

    // MARK: - Model resolution & loading

    /// The HF hub-cache snapshot directory for a repo, if fully present. The
    /// download path (CatalogStore / the Swift Hub downloader) populates this;
    /// we just locate the revision that carries a loadable `config.json`.
    private func snapshotDirectory(repo: String) -> URL? {
        let slug = "models--" + repo.replacingOccurrences(of: "/", with: "--")
        let snapshots = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/\(slug)/snapshots", isDirectory: true)
        guard let revs = try? FileManager.default.contentsOfDirectory(
            at: snapshots, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        return revs.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("config.json").path)
        }
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
                return try await loadModelContainer(directory: dir)
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
        }
    }

    /// Unload everything (engine stop).
    func unloadAll() {
        residents.removeAll()
        MLX.GPU.clearCache()
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

        func toGenerateParameters() -> GenerateParameters {
            GenerateParameters(
                maxTokens: maxTokens,
                maxKVSize: maxKVSize,
                temperature: temperature,
                topP: topP,
                repetitionPenalty: repetitionPenalty)
        }
    }

    /// Result of a completed generation.
    struct Completion: Sendable {
        var text: String
        var promptTokens: Int
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
        let container = try await ensureLoaded(repo: repo, estMemGB: estMemGB)
        let gp = params.toGenerateParameters()

        return try await container.perform { (context: ModelContext) in
            let input = try await context.processor.prepare(
                input: UserInput(chat: messages, tools: tools?.map(\.asToolSpec)))

            var detok = NaiveStreamingDetokenizer(tokenizer: context.tokenizer)
            var text = ""
            var completionTokens = 0
            var cancelled = false

            let start = Date()
            var firstTokenAt: Date?

            let info = try MLXLMCommon.generate(
                input: input, parameters: gp, context: context
            ) { token in
                if firstTokenAt == nil { firstTokenAt = Date() }
                completionTokens += 1
                detok.append(token: token)
                if let piece = detok.next(), !piece.isEmpty {
                    text += piece
                    if !onDelta(piece) { cancelled = true; return .stop }
                }
                return .more
            }

            let ttft = (firstTokenAt ?? Date()).timeIntervalSince(start)
            let decode = Date().timeIntervalSince(firstTokenAt ?? start)
            let promptTokens = input.text.tokens.size
            let reachedCap = completionTokens >= (params.maxTokens)
            let finish = (cancelled || reachedCap) ? "length" : "stop"
            _ = info
            return Completion(
                text: text,
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                ttft: ttft,
                decodeSeconds: decode,
                finishReason: finish)
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
        let params = (try? JSONSerialization.jsonObject(
            with: Data(parametersJSONString.utf8))) as? [String: Any] ?? [:]
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": params,
            ],
        ]
    }
}
