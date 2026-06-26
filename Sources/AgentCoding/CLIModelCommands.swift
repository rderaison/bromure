import ArgumentParser
import Foundation

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

    @Argument(help: "VM id or profile name.")
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
    @Argument(help: "VM id or profile name.") var vm: String
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
    @Argument(help: "VM id or profile name.") var vm: String
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
    @Argument(help: "VM id or profile name.") var vm: String
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
                      ModelLS.self, ModelUse.self, ModelRM.self])
}

struct ModelInstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Provision the local vllm-mlx engine (uv + pinned venv).")

    func run() throws {
        if EngineProvisioner.shared.isProvisioned {
            print("Engine already provisioned at \(EngineProvisioner.shared.engineDir.path).")
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

    func run() throws {
        let hostGB = HostMemory.unifiedMemoryGB()
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
                              m.downloadGB, m.name as NSString, installed as NSString)
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
        print("Validating \(repo) …")
        let total = max(1, Int64((CatalogStore.shared.resolve(model)?.downloadGB ?? 1) * 1_000_000_000))
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
                try await ModelDownloader.pull(repo: repo, onProgress: { _ in })
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
        abstract: "Set the active local model for a running VM's profile.")

    @Argument(help: "Catalog id or org/repo.")
    var model: String

    @Argument(help: "VM id or profile name.")
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
