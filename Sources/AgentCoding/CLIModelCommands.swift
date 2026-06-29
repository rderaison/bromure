import ArgumentParser
import Foundation
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import Tokenizers

// MARK: - Async bridge for sync ParsableCommand.run()

/// Run an async closure to completion from a synchronous CLI command.
private func blockingRun<T>(_ op: @escaping () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = UncheckedBox<Result<T, Error>>(.failure(CancellationError()))
    Task {
        do { box.value = .success(try await op()) }
        catch { box.value = .failure(error) }
        sem.signal()
    }
    sem.wait()
    return try box.value.get()
}

private final class UncheckedBox<T>: @unchecked Sendable {
    var value: T
    init(_ v: T) { value = v }
}

private func fmtGB(_ bytes: Int64) -> String {
    String(format: "%.1f GB", Double(bytes) / 1_073_741_824.0)
}

/// A carriage-return-updating terminal progress bar — the CLI counterpart
/// of the UI's determinate ProgressView. Driven by real bytes-on-disk so
/// it climbs smoothly instead of jumping 0 → 100 when a buffered installer
/// finally flushes.
enum ProgressBar {
    static func render(_ frac: Double, label: String, width: Int = 28) -> String {
        let f = max(0, min(1, frac))
        let filled = Int((Double(width) * f).rounded())
        let bar = String(repeating: "█", count: filled)
            + String(repeating: "░", count: width - filled)
        return String(format: "\r  [%@] %3d%%  %@", bar, Int(f * 100), label)
    }
    static func draw(_ frac: Double, label: String) {
        FileHandle.standardError.write(Data(render(frac, label: label).utf8))
    }
    static func finish() {
        FileHandle.standardError.write(Data("\n".utf8))
    }
    /// "12.3 / 95 GB"-style label from byte counts (decimal GB).
    static func bytesLabel(_ bytes: Int64, _ total: Int64) -> String {
        String(format: "%.1f / %.0f GB",
               Double(bytes) / 1_000_000_000, Double(total) / 1_000_000_000)
    }
}

// MARK: - `vm routing`

struct VMRouting: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "routing",
        abstract: "Set LLM backend routing for a running VM: cloud | local | hybrid.")

    @Argument(help: "cloud | local | hybrid")
    var mode: String

    @Argument(help: "VM id or workspace name.")
    var vm: String

    func run() throws {
        let m = mode.lowercased()
        guard ["cloud", "local", "hybrid"].contains(m) else {
            throw ValidationError("Mode must be 'cloud', 'local', or 'hybrid'.")
        }
        let client = ControlClient()
        try client.ensureAgentRunning()
        let resp = try client.request("POST", "/vms/\(ControlClient.encodeSegment(vm))/routing",
                                      body: ["mode": m])
        guard resp.status == 200, (resp.json["ok"] as? Bool) == true else {
            throw ValidationError(resp.json["error"] as? String ?? "Couldn't set routing for \(vm).")
        }
        print("Routing set to \(m) for \(vm).")
    }
}

// MARK: - `vm hybrid <knob>`

struct VMHybrid: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hybrid",
        abstract: "Tune hybrid-routing policy knobs for a running VM.",
        subcommands: [VMHybridBudget.self, VMHybridTTFT.self, VMHybridSplit.self])
}

private func setHybrid(knob: String, value: Double, vm: String) throws {
    let client = ControlClient()
    try client.ensureAgentRunning()
    let resp = try client.request("POST", "/vms/\(ControlClient.encodeSegment(vm))/hybrid",
                                  body: ["knob": knob, "value": value])
    guard resp.status == 200, (resp.json["ok"] as? Bool) == true else {
        throw ValidationError(resp.json["error"] as? String ?? "Couldn't set hybrid \(knob) for \(vm).")
    }
}

struct VMHybridBudget: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "budget",
        abstract: "Cloud token cap per rolling 24 h window (0 = unlimited).")
    @Argument(help: "Max cloud tokens per window (0 = unlimited).") var tokens: Int
    @Argument(help: "VM id or workspace name.") var vm: String
    func run() throws {
        try setHybrid(knob: "budget", value: Double(tokens), vm: vm)
        print("Hybrid cloud token budget set to \(tokens == 0 ? "unlimited" : String(tokens)) for \(vm).")
    }
}

struct VMHybridTTFT: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ttft",
        abstract: "Soft fallback threshold in seconds (default 5).")
    @Argument(help: "Seconds before falling back to local.") var seconds: Double
    @Argument(help: "VM id or workspace name.") var vm: String
    func run() throws {
        try setHybrid(knob: "ttft", value: seconds, vm: vm)
        print("Hybrid soft TTFT set to \(seconds)s for \(vm).")
    }
}

struct VMHybridSplit: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "split",
        abstract: "Percentage (0–100) of new sessions pinned to local.")
    @Argument(help: "Percent of new sessions to route local (0–100).") var percent: Int
    @Argument(help: "VM id or workspace name.") var vm: String
    func run() throws {
        guard (0...100).contains(percent) else {
            throw ValidationError("Split must be between 0 and 100.")
        }
        try setHybrid(knob: "split", value: Double(percent), vm: vm)
        print("Hybrid local split set to \(percent)% for \(vm).")
    }
}

// MARK: - `model`

struct Model: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "model",
        abstract: "Manage local MLX inference models (catalog, pull, use).",
        subcommands: [ModelCatalogList.self, ModelInstall.self, ModelPull.self,
                      ModelLS.self, ModelUse.self, ModelRM.self, RepairServe.self,
                      MLXSelfTest.self, MLXServe.self, MLXEngineChild.self,
                      ToolCallRepairTest.self, EngineKeyPrint.self, ConvParseTest.self,
                      SpecBench.self])
}

/// Hidden: benchmark speculative decoding (mlx-swift-lm's SpeculativeTokenIterator)
/// OFF vs ON for a main+draft model pair. Reports decode tok/s (prefill excluded).
/// `model _spec-bench <main-repo> --draft <draft-repo> [--num-draft 3] [--max-tokens 256]`.
struct SpecBench: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "_spec-bench", shouldDisplay: false)
    @Argument(help: "Main model HF repo (in hub cache).") var repo: String
    @Option(name: .long, help: "Draft model HF repo (must share the tokenizer).") var draft: String
    @Option(name: .long) var prompt = "Write a Python function that reverses a string, then explain step by step how it works and discuss edge cases."
    @Option(name: .long) var maxTokens = 256
    @Option(name: .long) var numDraft = 3
    func run() throws {
        let rlabel = repo, dlabel = draft, p = prompt, mt = maxTokens, nd = numDraft
        try blockingRun {
            guard let mainDir = await MLXEngine.shared.snapshotDirectory(repo: rlabel) else {
                throw ValidationError("not downloaded: \(rlabel)")
            }
            guard let draftDir = await MLXEngine.shared.snapshotDirectory(repo: dlabel) else {
                throw ValidationError("not downloaded: \(dlabel)")
            }
            FileHandle.standardError.write(Data("loading main \(rlabel) + draft \(dlabel) …\n".utf8))
            let mainC = try await loadModelContainer(from: mainDir, using: #huggingFaceTokenizerLoader())
            let draftC = try await loadModelContainer(from: draftDir, using: #huggingFaceTokenizerLoader())
            let draftModel = try await draftC.perform { (c: ModelContext) in c.model }
            let gp = GenerateParameters(maxTokens: mt, temperature: 0)
            try await mainC.perform { (ctx: ModelContext) in
                let input = try await ctx.processor.prepare(input: UserInput(chat: [.user(p)]))
                // Decode-only timing: start the clock at the first generated token
                // (excludes prefill, which is identical for both paths).
                func measure(_ stream: AsyncStream<TokenGeneration>) async -> (Int, Double) {
                    var n = 0; var first: Date?
                    for await g in stream where g.token != nil {
                        if first == nil { first = Date() }
                        n += 1
                        if n >= mt { break }
                    }
                    return (n, Date().timeIntervalSince(first ?? Date()))
                }
                let (offN, offS) = await measure(try generateTokens(input: input, parameters: gp, context: ctx))
                let (onN, onS) = await measure(try generateTokens(
                    input: input, parameters: gp, context: ctx,
                    draftModel: draftModel, numDraftTokens: nd))
                let offTps = Double(max(0, offN - 1)) / max(0.001, offS)
                let onTps = Double(max(0, onN - 1)) / max(0.001, onS)
                let r = String(
                    format: "\n=== %@  (draft %@, k=%d) ===\nOFF: %3d tok  %.2fs  %6.1f tok/s\nON : %3d tok  %.2fs  %6.1f tok/s\nspeedup: %.2fx\n",
                    rlabel, dlabel, nd, offN, offS, offTps, onN, onS, onTps, onTps / max(0.001, offTps))
                FileHandle.standardError.write(Data(r.utf8))
            }
        }
    }
}

/// Hidden: run the trace inspector's ConversationParser on request/response
/// JSON files — verifies what a stored body renders as (e.g. a local-engine
/// call). `model _conv-test --req r.json [--res s.json] [--host local-engine]`.
struct ConvParseTest: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "_conv-test", shouldDisplay: false)
    @Option(name: .long, help: "Request body JSON file.") var req: String
    @Option(name: .long, help: "Response body JSON file.") var res: String?
    @Option(name: .long, help: "Host to route the parser (default local-engine).") var host = "local-engine"
    func run() throws {
        let reqData = try? Data(contentsOf: URL(fileURLWithPath: req))
        let resData = res.flatMap { try? Data(contentsOf: URL(fileURLWithPath: $0)) }
        guard let conv = ConversationParser.parse(host: host, requestBody: reqData, responseBody: resData) else {
            print("parse → nil (no conversation recognized)"); return
        }
        print("provider=\(conv.provider.rawValue) model=\(conv.model ?? "?") "
              + "system=\(conv.systemPrompt != nil ? "yes" : "no") messages=\(conv.messages.count)")
        for m in conv.messages {
            let parts = m.content.map { b -> String in
                switch b {
                case .text(let t): return "text(\(t.prefix(40).replacingOccurrences(of: "\n", with: " ")))"
                case .toolUse(let name, _): return "tool_use(\(name))"
                case .toolResult: return "tool_result"
                case .image: return "image"
                }
            }
            print("  \(m.role.rawValue): \(parts.joined(separator: ", "))")
        }
    }
}

/// Hidden: print the persistent per-VM engine key for a profile id, and (if
/// given a second arg) verify a key round-trips. `model _enginekey <uuid> [key]`.
struct EngineKeyPrint: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "_enginekey", shouldDisplay: false)
    @Argument(help: "Profile UUID.") var profileID: String
    @Argument(help: "Optional key to validate against the master.") var verify: String?
    func run() throws {
        guard let id = UUID(uuidString: profileID) else { throw ValidationError("not a UUID") }
        print(EngineKey.perVM(profileID: id))
        if let v = verify {
            if let got = EngineKey.profileID(forKey: v) {
                print("verified -> \(got.uuidString)\(got == id ? " (matches)" : " (MISMATCH)")")
            } else { print("invalid key") }
        }
    }
}

/// Hidden: run ToolCallRepair.rescue on a text file's contents (`model
/// _tc-test <path>`), to validate leaked-tool-call extraction in isolation.
struct ToolCallRepairTest: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "_tc-test", shouldDisplay: false)
    @Argument(help: "Path to a file containing the model's text output.") var path: String
    @Option(name: .long, help: "Comma-separated declared tool names (gates the rescue).") var tools = ""
    func run() throws {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        let names = Set(tools.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        let (cleaned, blocks) = ToolCallRepair.rescue(text: text, toolNames: names)
        print("rescued \(blocks.count) tool_use block(s):")
        for b in blocks {
            print("  name=\(b["name"] ?? "?")")
            print("  input=\(b["input"] ?? "?")")
        }
        print("--- cleaned text (\(cleaned.count) chars) ---")
        print(cleaned.prefix(200))
    }
}

/// Hidden: the supervised engine child the main app spawns
/// (`model _mlx-engine --config <path>`). Reads the model set + budget, starts
/// MLXServer in-process, and blocks. Running here, out-of-process, is what gives
/// the host OOM isolation: if a model load jetsams this process, the app and its
/// VMs survive and the parent restarts it.
struct MLXEngineChild: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "_mlx-engine", shouldDisplay: false)
    @Option(name: .long, help: "Path to the engine spawn config JSON.") var config: String
    func run() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: config))
        let cfg = try JSONDecoder().decode(EngineSpawnConfig.self, from: data)
        guard MLXServer.shared.start(models: cfg.inferenceModels, memoryBudgetGB: cfg.memoryBudgetGB) else {
            // Couldn't bind the port — exit non-zero so the parent's readiness
            // wait fails fast (and clearly) instead of polling a dead port.
            FileHandle.standardError.write(Data(
                "[engine] exiting — HTTP server could not start on port \(InferenceService.enginePort)\n".utf8))
            Foundation.exit(1)
        }
        FileHandle.standardError.write(Data(
            "mlx engine: serving \(cfg.models.count) model(s) on 127.0.0.1:\(InferenceService.enginePort)\n".utf8))
        RunLoop.main.run()
    }
}

/// Hidden: start the in-process MLX HTTP server for a model and block, so the
/// OpenAI/Anthropic/Responses + /metrics endpoints can be exercised over HTTP
/// (`model _mlx-serve <repo>`). Prints the per-run API key for curl.
struct MLXServe: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "_mlx-serve", shouldDisplay: false)
    @Argument(help: "HF repo (must be in the models dir / hub cache).") var repo: String
    func run() throws {
        try blockingRun {
            try await InferenceService.shared.ensureRunning(modelRepo: repo)
        }
        let line = "serving \(repo) on http://127.0.0.1:\(InferenceService.enginePort)\n" +
                   "api-key: \(InferenceService.apiKey)\n"
        FileHandle.standardError.write(Data(line.utf8))
        RunLoop.main.run()
    }
}

/// Hidden: load a model through the in-process MLX engine and generate once,
/// to validate end-to-end loading + decode speed without the GUI
/// (`model _mlx-selftest <repo>`).
struct MLXSelfTest: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "_mlx-selftest", shouldDisplay: false)
    @Argument(help: "HF repo (must be in the hub cache).") var repo: String
    @Option(name: .long) var prompt = "Write a Python function that reverses a string. Code only."
    @Option(name: .long) var maxTokens = 128
    func run() throws {
        try blockingRun {
            let t0 = Date()
            FileHandle.standardError.write(Data("loading \(repo) …\n".utf8))
            let c = try await MLXEngine.shared.generate(
                repo: repo,
                messages: [.user(prompt)],
                params: MLXEngine.Params(maxTokens: maxTokens, temperature: 0)
            ) { piece in
                FileHandle.standardOutput.write(Data(piece.utf8))
                return true
            }
            let decode = Double(c.completionTokens) / max(0.001, c.decodeSeconds)
            let summary = String(
                format: "\n\n--- prompt=%d tok  completion=%d tok\n--- TTFT=%.2fs  decode=%.1f tok/s  total=%.1fs\n",
                c.promptTokens, c.completionTokens, c.ttft, decode, Date().timeIntervalSince(t0))
            FileHandle.standardError.write(Data(summary.utf8))
        }
    }
}

/// Hidden: run the tool-call repair proxy standalone for testing against a
/// running engine (`model _repair-serve --engine-port 11434`). Blocks.
struct RepairServe: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "_repair-serve", shouldDisplay: false)
    @Option(name: .long) var enginePort = InferenceService.enginePort
    func run() throws {
        InferenceRepairProxy.shared.startIfNeeded(enginePort: enginePort)
        print("repair proxy on 127.0.0.1:\(InferenceRepairProxy.listenPort) -> engine :\(enginePort)")
        RunLoop.main.run()
    }
}

struct ModelInstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Provision the local vllm-mlx engine (uv + pinned venv).")

    @Flag(name: .long, help: "Upgrade an installed engine to the newest published wheel.")
    var upgrade = false

    func run() throws {
        guard EngineProvisioner.resolveUV() != nil else {
            throw ValidationError("uv not found. The app bundles it; on a dev build, `brew install uv`.")
        }
        if upgrade {
            guard EngineProvisioner.shared.isProvisioned else {
                throw ValidationError("Engine isn't installed yet — run `model install` first.")
            }
            print("Upgrading vllm-mlx to the newest published wheel…")
            try blockingRun {
                try await EngineProvisioner.shared.refreshToLatest { line in
                    FileHandle.standardError.write(Data(line.utf8))
                }
            }
            print("Engine upgraded.")
            return
        }
        if EngineProvisioner.shared.isProvisioned {
            print("Engine already provisioned at \(EngineProvisioner.shared.engineDir.path). Use --upgrade to refresh.")
            return
        }
        guard EngineProvisioner.resolveUV() != nil else {
            throw ValidationError("uv not found. The app bundles it; on a dev build, `brew install uv`.")
        }
        print("Provisioning vllm-mlx engine (first run only)…")
        try blockingRun {
            let total = Double(EngineProvisioner.estimatedInstallBytes)
            let poller = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    let f = min(0.97, Double(EngineProvisioner.shared.installedBytes) / total)
                    ProgressBar.draw(f, label: "installing engine")
                }
            }
            do {
                try await EngineProvisioner.shared.ensureProvisioned()
                poller.cancel()
                ProgressBar.draw(1.0, label: "done"); ProgressBar.finish()
            } catch { poller.cancel(); ProgressBar.finish(); throw error }
        }
        print("Engine ready at \(EngineProvisioner.shared.vllmExecutable.path).")
    }
}

struct ModelCatalogList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "catalog",
        abstract: "List curated MLX models with RAM-fit + tool-calling badges.")

    @Flag(name: .long, help: "Show models that won't fit this Mac too.")
    var all = false

    @Flag(name: .long, help: "Skip the live catalog refresh; use bundled + cached only.")
    var offline = false

    func run() throws {
        let hostGB = HostMemory.unifiedMemoryGB()
        // Live lookup against dl.bromure.io/mlx/catalog.json (merged over the
        // bundled baseline). Non-fatal — falls back to bundled + cached on
        // any network failure.
        if !offline {
            let ok = try blockingRun { await CatalogStore.shared.refresh() }
            if !ok {
                FileHandle.standardError.write(Data(
                    "warning: couldn't reach the catalog server; showing bundled + cached.\n".utf8))
            }
        }
        let cat = CatalogStore.shared.effective()
        print("Host unified memory: \(hostGB) GB\n")
        let header = String(format: "%-26@ %-7@ %-9@ %-7@ %@",
                            "ID" as NSString, "FIT" as NSString,
                            "TOOLS" as NSString, "SIZE" as NSString, "NAME" as NSString)
        print(header)
        for m in cat.sortedForDisplay {
            let fit = RAMFitGate.fit(model: m, hostUnifiedMemGB: hostGB)
            if fit == .wontFit && !all { continue }
            let installed = CatalogStore.shared.isInstalled(repo: m.repo) ? " ✓" : ""
            let line = String(format: "%-26@ %-7@ %-9@ %5.0f GB  %@%@",
                              m.id as NSString, fit.badge as NSString,
                              m.toolCalling.rawValue as NSString,
                              m.downloadGB, m.displayName as NSString, installed as NSString)
            print(line)
        }
        if !all { print("\nUse --all to include models that won't fit.") }
    }
}

struct ModelLS: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "List installed models and disk used.")

    func run() throws {
        let cat = CatalogStore.shared.effective()
        var any = false
        for m in cat.sortedForDisplay where CatalogStore.shared.isInstalled(repo: m.repo) {
            any = true
            let bytes = CatalogStore.shared.installedBytes(repo: m.repo)
            print(String(format: "%-26@ %@  (%@)", m.id as NSString,
                         fmtGB(bytes) as NSString, m.repo as NSString))
        }
        if !any { print("No models installed. Pull one with `bromure-ac model pull <id>`.") }
    }
}

struct ModelPull: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pull",
        abstract: "Download a model by catalog id or any MLX HF repo (validated).")

    @Argument(help: "Catalog id (e.g. glm-5.2-mlx-3bit) or org/repo.")
    var model: String

    func run() throws {
        let repo = CatalogStore.shared.resolve(model)?.repo ?? model
        guard CatalogStore.looksLikeHFRepo(repo) || CatalogStore.shared.resolve(model) != nil else {
            throw ValidationError("'\(model)' isn't a known catalog id or an org/repo.")
        }
        let total = max(1, Int64((CatalogStore.shared.resolve(model)?.downloadGB ?? 1) * 1_000_000_000))
        // Fail fast on a full disk — before provisioning or hitting the network.
        try ModelDownloader.checkDiskSpace(repo: repo, expectedBytes: total)
        print("Validating \(repo) …")
        try blockingRun {
            // `hf` ships inside the engine venv — provision it first if needed.
            if EngineProvisioner.resolveUV() != nil, !EngineProvisioner.shared.isProvisioned {
                try await EngineProvisioner.shared.ensureProvisioned()
            }
            // Determinate progress from real bytes on disk.
            let poller = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    let bytes = CatalogStore.shared.installedBytes(repo: repo)
                    let f = min(0.99, Double(bytes) / Double(total))
                    ProgressBar.draw(f, label: ProgressBar.bytesLabel(bytes, total))
                }
            }
            do {
                try await ModelDownloader.pull(repo: repo, expectedBytes: total, onProgress: { _ in })
                poller.cancel()
                ProgressBar.draw(1.0, label: "done"); ProgressBar.finish()
            } catch { poller.cancel(); ProgressBar.finish(); throw error }
        }
        print("Pulled \(repo).")
    }
}

struct ModelRM: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Remove an installed model's weights from disk.")

    @Argument(help: "Catalog id or org/repo.")
    var model: String

    func run() throws {
        let repo = CatalogStore.shared.resolve(model)?.repo ?? model
        guard CatalogStore.shared.isInstalled(repo: repo) else {
            throw ValidationError("'\(repo)' isn't installed.")
        }
        try CatalogStore.shared.removeInstalled(repo: repo)
        print("Removed \(repo).")
    }
}

struct ModelUse: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "use",
        abstract: "Set the active local model for a running VM's workspace.")

    @Argument(help: "Catalog id or org/repo.")
    var model: String

    @Argument(help: "VM id or workspace name.")
    var vm: String

    func run() throws {
        let client = ControlClient()
        try client.ensureAgentRunning()
        let resp = try client.request("POST", "/vms/\(ControlClient.encodeSegment(vm))/model",
                                      body: ["modelID": model])
        guard resp.status == 200, (resp.json["ok"] as? Bool) == true else {
            throw ValidationError(resp.json["error"] as? String ?? "Couldn't set model for \(vm).")
        }
        let id = (resp.json["model"] as? String) ?? model
        print("Active model set to \(id) for \(vm).")
    }
}
