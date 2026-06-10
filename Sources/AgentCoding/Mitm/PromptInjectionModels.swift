import Foundation

/// Locates + downloads the local detector models for prompt-injection /
/// rules-file detection. Mirrors `FaceSwapEngine`'s "fetch to Application
/// Support" pattern: files come from `dl.bromure.io/llms/<dir>/<file>` and
/// land in `~/Library/Application Support/BromureAC/Models/<dir>/<file>` —
/// the same dirs the ONNX runtime loads from. Models are never bundled.
public enum PromptInjectionModels {
    public enum Kind: Sendable, CaseIterable {
        case promptGuard      // source-code / tool_result injection (PromptGuard)
        case claudeMdGuard    // rogue CLAUDE.md / instruction files (ModernBERT)

        var dirName: String {
            switch self {
            case .promptGuard:   return "prompt-injection"
            case .claudeMdGuard: return "claudemd-guard"
            }
        }
        /// (filename, min bytes). The size floor rejects truncated downloads
        /// and HTML error pages so a bad fetch fails loudly rather than
        /// silently disabling the detector.
        var files: [(name: String, minBytes: Int)] {
            switch self {
            case .promptGuard:
                return [("model.onnx", 50_000_000), ("tokenizer.json", 1_000_000),
                        ("tokenizer_config.json", 100), ("special_tokens_map.json", 50)]
            case .claudeMdGuard:
                return [("model.onnx", 100_000_000), ("tokenizer.json", 500_000),
                        ("tokenizer_config.json", 100), ("config.json", 100)]
            }
        }
    }

    private static let baseURL = URL(string: "https://dl.bromure.io/llms")!

    public static var modelsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BromureAC/Models", isDirectory: true)
    }
    public static func directory(for kind: Kind) -> URL {
        modelsRoot.appendingPathComponent(kind.dirName, isDirectory: true)
    }

    public static func isInstalled(_ kind: Kind) -> Bool {
        let dir = directory(for: kind)
        let fm = FileManager.default
        return kind.files.allSatisfy { f in
            guard let sz = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(f.name).path)[.size]) as? Int
            else { return false }
            return sz >= f.minBytes
        }
    }

    /// Download every file for `kind` (skipping ones already present + valid).
    /// Atomic per-file; verifies the size floor.
    public static func download(_ kind: Kind,
                                progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let dir = directory(for: kind)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = kind.files
        for (i, f) in files.enumerated() {
            let dest = dir.appendingPathComponent(f.name)
            if let sz = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size]) as? Int,
               sz >= f.minBytes {
                progress(Double(i + 1) / Double(files.count)); continue
            }
            let url = baseURL.appendingPathComponent("\(kind.dirName)/\(f.name)")
            let (tmp, resp) = try await URLSession.shared.download(from: url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                throw Err.http((resp as? HTTPURLResponse)?.statusCode ?? 0, f.name)
            }
            let sz = ((try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size]) as? Int) ?? 0
            guard sz >= f.minBytes else { throw Err.truncated(f.name, sz, f.minBytes) }
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tmp, to: dest)
            progress(Double(i + 1) / Double(files.count))
        }
    }

    /// Fire a background download when a detector is enabled but its model is
    /// missing. Idempotent (a second call while running just re-checks +
    /// no-ops). Progress / outcome lands in the Security log.
    public static func ensureInstalledInBackground(_ kind: Kind) {
        guard !isInstalled(kind) else { return }
        Task.detached(priority: .utility) {
            guard !isInstalled(kind) else { return }
            SupplyChainLog.shared.record("[prompt-injection] downloading \(kind.dirName) model from bromure.io…")
            do {
                try await download(kind)
                SupplyChainLog.shared.record("[prompt-injection] \(kind.dirName) model installed.")
            } catch {
                SupplyChainLog.shared.record("[prompt-injection] \(kind.dirName) download failed: \(error.localizedDescription)")
            }
        }
    }

    enum Err: LocalizedError {
        case http(Int, String)
        case truncated(String, Int, Int)
        var errorDescription: String? {
            switch self {
            case .http(let s, let f): return "HTTP \(s) downloading \(f)"
            case .truncated(let f, let got, let min):
                return "\(f) too small (\(got) < \(min) bytes) — truncated download"
            }
        }
    }
}
