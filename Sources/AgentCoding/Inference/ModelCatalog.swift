import Foundation

// MARK: - Catalog model entry

/// Whether a quant has been smoke-tested for agent-grade tool-calling.
/// This is the headline quality gate for agentic coding: the dominant
/// failure mode is quantized models that silently break tool-calls.
public enum ToolCalling: String, Codable, CaseIterable, Sendable {
    case verified
    case untested
    case broken
}

/// One curated (or user-pasted) MLX model. Mirrors the §5.2 schema in
/// the integration plan. `download_gb` / `min_unified_mem_gb` drive the
/// RAM-fit gate; `tool_calling` drives the agentic-use filter.
public struct CatalogModel: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    /// Hugging Face repo (`org/name`) already in MLX safetensors format.
    public var repo: String
    /// Engine that serves it — currently always `vllm-mlx`.
    public var engine: String
    public var name: String
    public var publisher: String?
    public var license: String?
    public var paramsTotalB: Double?
    public var paramsActiveB: Double?
    public var quant: String?
    /// On-disk download size in GB (for the `model pull` progress + ls).
    public var downloadGB: Double
    /// Minimum unified memory (GB) to load + serve this without OOM.
    public var minUnifiedMemGB: Int
    public var context: Int?
    public var tags: [String]
    public var toolCalling: ToolCalling
    public var minChip: String?
    public var recommended: Bool

    public init(id: String, repo: String, engine: String = "vllm-mlx",
                name: String, publisher: String? = nil, license: String? = nil,
                paramsTotalB: Double? = nil, paramsActiveB: Double? = nil,
                quant: String? = nil, downloadGB: Double, minUnifiedMemGB: Int,
                context: Int? = nil, tags: [String] = [],
                toolCalling: ToolCalling = .untested, minChip: String? = nil,
                recommended: Bool = false) {
        self.id = id
        self.repo = repo
        self.engine = engine
        self.name = name
        self.publisher = publisher
        self.license = license
        self.paramsTotalB = paramsTotalB
        self.paramsActiveB = paramsActiveB
        self.quant = quant
        self.downloadGB = downloadGB
        self.minUnifiedMemGB = minUnifiedMemGB
        self.context = context
        self.tags = tags
        self.toolCalling = toolCalling
        self.minChip = minChip
        self.recommended = recommended
    }

    private enum CodingKeys: String, CodingKey {
        case id, repo, engine, name, publisher, license
        case paramsTotalB = "params_total_b"
        case paramsActiveB = "params_active_b"
        case quant
        case downloadGB = "download_gb"
        case minUnifiedMemGB = "min_unified_mem_gb"
        case context, tags
        case toolCalling = "tool_calling"
        case minChip = "min_chip"
        case recommended
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        repo = try c.decode(String.self, forKey: .repo)
        engine = try c.decodeIfPresent(String.self, forKey: .engine) ?? "vllm-mlx"
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        publisher = try c.decodeIfPresent(String.self, forKey: .publisher)
        license = try c.decodeIfPresent(String.self, forKey: .license)
        paramsTotalB = try c.decodeIfPresent(Double.self, forKey: .paramsTotalB)
        paramsActiveB = try c.decodeIfPresent(Double.self, forKey: .paramsActiveB)
        quant = try c.decodeIfPresent(String.self, forKey: .quant)
        downloadGB = try c.decodeIfPresent(Double.self, forKey: .downloadGB) ?? 0
        minUnifiedMemGB = try c.decodeIfPresent(Int.self, forKey: .minUnifiedMemGB) ?? 0
        context = try c.decodeIfPresent(Int.self, forKey: .context)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        toolCalling = try c.decodeIfPresent(ToolCalling.self, forKey: .toolCalling) ?? .untested
        minChip = try c.decodeIfPresent(String.self, forKey: .minChip)
        recommended = try c.decodeIfPresent(Bool.self, forKey: .recommended) ?? false
    }
}

// MARK: - RAM-fit gating

/// Verdict for a model against the host's unified memory. Picker defaults
/// to showing only `.fits`, with a toggle to reveal the rest (§5.3).
public enum RAMFit: String, Sendable {
    case fits        // comfortable headroom
    case tight       // loads but with little room to spare
    case wontFit     // would OOM

    public var badge: String {
        switch self {
        case .fits:    return "Fits"
        case .tight:   return "Tight"
        case .wontFit: return "Won't fit"
        }
    }
}

public enum RAMFitGate {
    /// Headroom (GB) the OS + the rest of the system needs on top of the
    /// model's working set before we'll call it a comfortable fit.
    public static let headroomGB = 16

    /// Classify one model against a host's unified memory (GB).
    public static func fit(model: CatalogModel, hostUnifiedMemGB: Int) -> RAMFit {
        if hostUnifiedMemGB < model.minUnifiedMemGB { return .wontFit }
        if hostUnifiedMemGB < model.minUnifiedMemGB + headroomGB { return .tight }
        return .fits
    }
}

// MARK: - Catalog

/// A versioned set of curated models. `version` lets the remote refresh
/// (§5.1) decide whether a fetched manifest supersedes the baseline.
public struct ModelCatalog: Codable, Sendable {
    public var version: Int
    public var models: [CatalogModel]

    public init(version: Int, models: [CatalogModel]) {
        self.version = version
        self.models = models
    }

    /// Look up by catalog id.
    public func model(id: String) -> CatalogModel? {
        models.first { $0.id == id }
    }

    /// Models sorted for display: recommended first, then ascending by
    /// memory requirement (smallest/most-broadly-runnable first).
    public var sortedForDisplay: [CatalogModel] {
        models.sorted { a, b in
            if a.recommended != b.recommended { return a.recommended }
            if a.minUnifiedMemGB != b.minUnifiedMemGB {
                return a.minUnifiedMemGB < b.minUnifiedMemGB
            }
            return a.name < b.name
        }
    }

    /// Merge a fetched catalog over this one: entries with the same `id`
    /// are replaced, new ids are appended (§5.1 "merge over baseline").
    public func merged(with remote: ModelCatalog) -> ModelCatalog {
        var byID: [String: CatalogModel] = [:]
        var order: [String] = []
        for m in models { byID[m.id] = m; order.append(m.id) }
        for m in remote.models {
            if byID[m.id] == nil { order.append(m.id) }
            byID[m.id] = m
        }
        return ModelCatalog(version: max(version, remote.version),
                            models: order.compactMap { byID[$0] })
    }
}

// MARK: - Baseline (shipped, offline day one)

extension ModelCatalog {
    /// The shipped baseline — the bundled `catalog.json` resource (the
    /// *same* file uploaded to Spaces), so the catalog is data, not code:
    /// editable without a Swift change and identical to the remote source.
    /// Works offline day one; remote refresh (§5.1) layers updates on top.
    public static let baseline: ModelCatalog = loadBundledBaseline()

    static func loadBundledBaseline() -> ModelCatalog {
        if let url = acResourceBundle.url(forResource: "catalog", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let cat = try? parse(data) {
            return cat
        }
        return embeddedFallback
    }

    /// Last-resort safety net if the bundled JSON is ever missing/corrupt —
    /// a single small model so the picker is never empty. The real catalog
    /// lives in `Resources/catalog.json` (and on Spaces).
    static let embeddedFallback = ModelCatalog(version: 0, models: [
        CatalogModel(
            id: "qwen2.5-coder-7b-mlx-4bit",
            repo: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
            name: "Qwen2.5-Coder 7B (4-bit MLX)",
            publisher: "Alibaba", license: "Apache-2.0",
            quant: "q4", downloadGB: 4.3, minUnifiedMemGB: 16, context: 128_000,
            tags: ["coding", "tools", "s"],
            toolCalling: .verified, minChip: "M1", recommended: true),
    ])

    /// Coarse size tier from the memory requirement — drives the picker's
    /// S / M / L / XL grouping (vLLM.md §5.3).
    public static func tier(forMinMemGB gb: Int) -> String {
        switch gb {
        case ...16: return "S"
        case ...32: return "M"
        case ...64: return "L"
        default:    return "XL"
        }
    }

    /// Parse a catalog from JSON `Data` (a fetched/bundled manifest).
    public static func parse(_ data: Data) throws -> ModelCatalog {
        try JSONDecoder().decode(ModelCatalog.self, from: data)
    }
}

// MARK: - Host memory detection

public enum HostMemory {
    /// Host unified memory in whole GB (1 GB = 1024³ bytes), rounded.
    public static func unifiedMemoryGB() -> Int {
        let bytes = ProcessInfo.processInfo.physicalMemory
        return Int((Double(bytes) / 1_073_741_824.0).rounded())
    }
}
