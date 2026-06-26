import Foundation
import Testing
@testable import bromure_ac

// MARK: - Model catalog + RAM-fit gating (vLLM.md §5)

@Suite("ModelCatalog")
struct ModelCatalogTests {

    @Test("Shipped catalog.json has ≥3 tool-verified coding models across RAM tiers")
    func baselineSeed() throws {
        // Validate the actual shipped resource file (the same one uploaded
        // to Spaces), not just the in-memory fallback.
        let url = URL(fileURLWithPath: "Sources/AgentCoding/Resources/catalog.json")
        let cat = try ModelCatalog.parse(Data(contentsOf: url))
        #expect(cat.models.count >= 3)
        let verified = cat.models.filter { $0.toolCalling == .verified }
        #expect(verified.count >= 3)
        // small ~32 GB, mid ~64 GB, large ~128 GB span (§5.1 decided seed).
        let tiers = Set(cat.models.map { $0.minUnifiedMemGB })
        #expect(tiers.contains { $0 <= 32 })
        #expect(tiers.contains { $0 >= 128 })
        // Every model is coding-tagged and MLX-served.
        #expect(cat.models.allSatisfy { $0.tags.contains("coding") })
        #expect(cat.models.allSatisfy { $0.engine == "vllm-mlx" })
    }

    @Test("RAM-fit gate classifies Fits / Tight / Won't fit")
    func ramFit() {
        let big = CatalogModel(id: "glm", repo: "mlx-community/GLM-5.2-mxfp4",
                               name: "GLM", downloadGB: 95, minUnifiedMemGB: 128)
        #expect(RAMFitGate.fit(model: big, hostUnifiedMemGB: 64) == .wontFit)
        #expect(RAMFitGate.fit(model: big, hostUnifiedMemGB: 130) == .tight)   // <16 GB headroom
        #expect(RAMFitGate.fit(model: big, hostUnifiedMemGB: 192) == .fits)
        // Exactly at the requirement is a won't-fit-comfortably → tight at +0? It's tight only with headroom; at min exactly it's tight.
        #expect(RAMFitGate.fit(model: big, hostUnifiedMemGB: 128) == .tight)
    }

    @Test("Remote catalog merges over baseline by id")
    func merge() {
        let baseline = ModelCatalog(version: 1, models: [
            CatalogModel(id: "a", repo: "x/a", name: "A", downloadGB: 1, minUnifiedMemGB: 8),
            CatalogModel(id: "b", repo: "x/b", name: "B", downloadGB: 1, minUnifiedMemGB: 8),
        ])
        let remote = ModelCatalog(version: 2, models: [
            CatalogModel(id: "b", repo: "x/b2", name: "B2", downloadGB: 2, minUnifiedMemGB: 16),
            CatalogModel(id: "c", repo: "x/c", name: "C", downloadGB: 1, minUnifiedMemGB: 8),
        ])
        let merged = baseline.merged(with: remote)
        #expect(merged.version == 2)
        #expect(merged.model(id: "b")?.repo == "x/b2")   // replaced
        #expect(merged.model(id: "a") != nil)            // kept
        #expect(merged.model(id: "c") != nil)            // added
    }

    @Test("Catalog parses the §5.2 JSON schema")
    func parseSchema() throws {
        let json = """
        {"version": 3, "models": [
          {"id":"glm-5.2-mlx-3bit","repo":"mlx-community/GLM-5.2-mxfp4",
           "engine":"vllm-mlx","name":"GLM-5.2 (3-bit MLX)","publisher":"Z.ai",
           "license":"MIT","params_total_b":744,"params_active_b":40,
           "quant":"mxfp4","download_gb":95,"min_unified_mem_gb":128,
           "context":1000000,"tags":["coding","tools"],
           "tool_calling":"verified","min_chip":"M3 Max","recommended":true}
        ]}
        """
        let cat = try ModelCatalog.parse(Data(json.utf8))
        let m = try #require(cat.model(id: "glm-5.2-mlx-3bit"))
        #expect(m.downloadGB == 95)
        #expect(m.minUnifiedMemGB == 128)
        #expect(m.toolCalling == .verified)
        #expect(m.context == 1_000_000)
    }
}

// MARK: - Repo validation (vLLM.md §5.5/§5.6 — reject GGUF)

@Suite("ModelDownloader.classify")
struct ModelValidationTests {
    @Test("MLX safetensors + config → loadable") func mlx() {
        let kind = ModelDownloader.classify(siblings: [
            "config.json", "model-00001-of-00002.safetensors", "tokenizer.json"])
        #expect(kind == .mlx)
        #expect(kind.loadable)
    }
    @Test("GGUF repo → rejected as ollama path") func gguf() {
        let kind = ModelDownloader.classify(siblings: ["GLM-5.2-Q4_K_M.gguf", "README.md"])
        #expect(kind == .gguf)
        #expect(!kind.loadable)
    }
    @Test("Neither marker → unknown") func unknown() {
        #expect(ModelDownloader.classify(siblings: ["README.md"]) == .unknown)
    }
}

// MARK: - Routing decision (vLLM.md §4)

@Suite("LLMRouting")
struct LLMRoutingTests {
    private func ctx(_ routing: Profile.Routing,
                     _ cfg: HybridConfig = HybridConfig()) -> LLMRoutingContext {
        LLMRoutingContext(routing: routing, localModelLabel: "glm",
                          hybrid: HybridRouter(config: cfg))
    }

    @Test("Only LLM hosts are re-routed") func hostGate() {
        #expect(LLMRouting.isLLMHost("api.anthropic.com"))
        #expect(LLMRouting.isLLMHost("api.openai.com"))
        #expect(!LLMRouting.isLLMHost("github.com"))
        // Non-LLM host stays cloud even under local routing.
        let t = LLMRouting.decide(host: "github.com", port: 443,
                                  context: ctx(.local), sessionKey: "s", now: 0)
        #expect(t.backend == .cloud)
    }

    @Test("Cloud routing is pass-through") func cloud() {
        let t = LLMRouting.decide(host: "api.anthropic.com", port: 443,
                                  context: ctx(.cloud), sessionKey: "s", now: 0)
        #expect(t.backend == .cloud)
        #expect(t.host == "api.anthropic.com")
        #expect(t.servedBy == "cloud")
    }

    @Test("Local routing rewrites to the loopback engine") func local() {
        let t = LLMRouting.decide(host: "api.anthropic.com", port: 443,
                                  context: ctx(.local), sessionKey: "s", now: 0)
        #expect(t.backend == .local)
        #expect(t.host == InferenceService.engineHost)
        #expect(t.port == InferenceService.enginePort)
        #expect(t.servedBy == "local-glm")
    }

    @Test("Hard-error statuses are recognized") func hardErr() {
        #expect(LLMRouting.isHardErrorStatus(429))
        #expect(LLMRouting.isHardErrorStatus(529))
        #expect(LLMRouting.isHardErrorStatus(503))
        #expect(!LLMRouting.isHardErrorStatus(200))
        #expect(!LLMRouting.isHardErrorStatus(401))
    }
}

// MARK: - Hybrid policy engine (vLLM.md §4.3)

@Suite("HybridRouter")
struct HybridRouterTests {

    @Test("Healthy cloud is the default") func healthyCloud() {
        let r = HybridRouter(config: HybridConfig())
        #expect(r.route(sessionID: "s1", now: 0).backend == .cloud)
    }

    @Test("Sticky session never switches backend mid-trajectory") func sticky() {
        let r = HybridRouter(config: HybridConfig(localSplitPercent: 0))
        let first = r.route(sessionID: "s", now: 0)
        // Trip the gate hard, then re-route the SAME session.
        r.recordHardError(sessionID: "other", now: 1)
        r.recordHardError(sessionID: "other", now: 2)
        r.recordHardError(sessionID: "other", now: 3)
        let again = r.route(sessionID: "s", now: 10)
        #expect(again.backend == first.backend)
        #expect(again.reason == .sticky)
    }

    @Test("Over-budget routes new sessions local") func budget() {
        let r = HybridRouter(config: HybridConfig(cloudTokenBudget: 1000,
                                                  budgetWindowSeconds: 86_400))
        r.recordCloudTokens(1200, now: 100)
        let d = r.route(sessionID: "new", now: 200)
        #expect(d.backend == .local)
        #expect(d.reason == .overBudget)
    }

    @Test("Budget window slides — old usage expires") func budgetWindow() {
        let r = HybridRouter(config: HybridConfig(cloudTokenBudget: 1000,
                                                  budgetWindowSeconds: 100))
        r.recordCloudTokens(1200, now: 0)
        #expect(r.cloudTokensInWindow(now: 50) == 1200)
        #expect(r.cloudTokensInWindow(now: 200) == 0)   // slid past the window
        #expect(r.route(sessionID: "later", now: 200).backend == .cloud)
    }

    @Test("Health gate flips unhealthy after ≥3 failures, recovers on clean probes") func healthGate() {
        let r = HybridRouter(config: HybridConfig(failureThreshold: 3, recoveryProbes: 3))
        #expect(!r.isUnhealthy)
        r.recordHardError(sessionID: "a", now: 0)
        r.recordHardError(sessionID: "b", now: 1)
        #expect(!r.isUnhealthy)              // 2 failures — still healthy (conservative)
        r.recordHardError(sessionID: "c", now: 2)
        #expect(r.isUnhealthy)               // 3rd trips it
        #expect(r.route(sessionID: "fresh", now: 3).reason == .unhealthy)
        // Recover after a streak of clean, fast probes.
        r.recordSuccess(ttftSeconds: 0.5)
        r.recordSuccess(ttftSeconds: 0.5)
        #expect(r.isUnhealthy)               // not enough yet
        r.recordSuccess(ttftSeconds: 0.5)
        #expect(!r.isUnhealthy)
    }

    @Test("EWMA TTFT over threshold trips the gate") func ewmaGate() {
        let r = HybridRouter(config: HybridConfig(ewmaTTFTThresholdSeconds: 8, ewmaAlpha: 1.0))
        r.recordSuccess(ttftSeconds: 20)     // alpha=1 → ewma=20 > 8
        #expect(r.isUnhealthy)
    }

    @Test("Split ratio is deterministic and proportional") func split() {
        // 100% local → every session local; 0% → every session cloud.
        let all = HybridRouter(config: HybridConfig(localSplitPercent: 100))
        #expect(all.route(sessionID: "anything", now: 0).backend == .local)
        #expect(all.route(sessionID: "another", now: 0).reason == .splitRatio)

        let none = HybridRouter(config: HybridConfig(localSplitPercent: 0))
        #expect(none.route(sessionID: "anything", now: 0).backend == .cloud)

        // ~30% over many session ids lands roughly on target (deterministic hash).
        let r = HybridRouter(config: HybridConfig(localSplitPercent: 30))
        var local = 0
        for i in 0..<1000 { if r.route(sessionID: "sess-\(i)", now: 0).backend == .local { local += 1 } }
        #expect(local > 200 && local < 400)
    }

    @Test("Precedence: budget beats split") func precedence() {
        let r = HybridRouter(config: HybridConfig(cloudTokenBudget: 100,
                                                  localSplitPercent: 0))
        r.recordCloudTokens(500, now: 0)
        #expect(r.route(sessionID: "x", now: 1).reason == .overBudget)
    }
}

// MARK: - Engine provisioning (uv + on-demand venv, §3.1)

@Suite("EngineProvisioner")
struct EngineProvisionerTests {
    @Test("Engine + venv paths live under Application Support") func paths() {
        let p = EngineProvisioner(supportDir: URL(fileURLWithPath: "/tmp/bromure-test-support"))
        #expect(p.engineDir.path == "/tmp/bromure-test-support/engine")
        #expect(p.vllmExecutable.path == "/tmp/bromure-test-support/engine/bin/vllm-mlx")
        #expect(p.venvPython.path.hasSuffix("/engine/bin/python"))
    }

    @Test("uv command builders match the uv CLI") func uvArgs() {
        let dir = URL(fileURLWithPath: "/tmp/eng")
        // Always use uv's managed standalone Python — never system/Xcode python3.
        #expect(EngineProvisioner.pythonInstallArgs() == ["python", "install", "3.12"])
        #expect(EngineProvisioner.venvArgs(dir: dir)
                == ["venv", "/tmp/eng", "--python", "3.12", "--python-preference", "only-managed"])
        let py = URL(fileURLWithPath: "/tmp/eng/bin/python")
        let req = URL(fileURLWithPath: "/tmp/req.lock")
        #expect(EngineProvisioner.pipInstallArgs(venvPython: py, requirementsFile: req)
                == ["pip", "install", "--python", "/tmp/eng/bin/python", "-r", "/tmp/req.lock"])
    }

    @Test("uv resolves from BROMURE_UV override first") func resolveUV() {
        let url = EngineProvisioner.resolveUV(
            env: ["BROMURE_UV": "/opt/uv"], bundle: nil,
            fileExists: { $0 == "/opt/uv" })
        #expect(url?.path == "/opt/uv")
        // Falls through to PATH when no override / bundle.
        let onPath = EngineProvisioner.resolveUV(
            env: ["PATH": "/x:/y"], bundle: nil,
            fileExists: { $0 == "/y/uv" })
        #expect(onPath?.path == "/y/uv")
    }

    @Test("Default requirements install vllm-mlx from the Bromure index") func reqs() {
        let r = EngineProvisioner.defaultRequirements
        #expect(r.contains("vllm-mlx"))
        #expect(r.contains("--find-links"))
        #expect(r.contains("https://dl.bromure.io/mlx/find-links.html"))
    }

    @Test("Engine executable resolution prefers the env override") func engineResolve() {
        let url = InferenceService.resolveExecutable(
            env: ["BROMURE_VLLM_MLX": "/custom/vllm-mlx"],
            fileExists: { $0 == "/custom/vllm-mlx" })
        #expect(url?.path == "/custom/vllm-mlx")
    }
}

// MARK: - Per-tool local model auth (env injection)

@Suite("Local model per-tool")
struct LocalToolAuthTests {
    @Test("Claude points every model slot at the local model") func claudeSlots() {
        let env = Dictionary(uniqueKeysWithValues:
            Profile.Tool.claude.localEnvExports(model: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit")
                .map { ($0.name, $0.value) })
        #expect(env["ANTHROPIC_BASE_URL"] == "http://127.0.0.1:11434")
        // All five model slots (main + small-fast + the 3 aliases) → local.
        for k in ["ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL",
                  "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
                  "ANTHROPIC_DEFAULT_HAIKU_MODEL"] {
            #expect(env[k] == "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit")
        }
        // The key is the per-session engine API key, not a fixed dummy.
        #expect(env["ANTHROPIC_API_KEY"] == InferenceService.apiKey)
        #expect(InferenceService.apiKey.hasPrefix("brk-"))
    }

    @Test("Codex carries only the dummy key (config.toml does the routing)") func codexEnv() {
        let codex = Dictionary(uniqueKeysWithValues:
            Profile.Tool.codex.localEnvExports(model: "m").map { ($0.name, $0.value) })
        #expect(codex["OPENAI_API_KEY"] == InferenceService.apiKey)
        // Codex is redirected by the config.toml provider, not env vars.
        #expect(codex["OPENAI_BASE_URL"] == nil)
    }

    @Test("Grok uses GROK_* env (not XAI_*)") func grokEnv() {
        let grok = Dictionary(uniqueKeysWithValues:
            Profile.Tool.grok.localEnvExports(model: "m").map { ($0.name, $0.value) })
        #expect(grok["GROK_BASE_URL"] == "http://127.0.0.1:11434/v1")
        #expect(grok["GROK_MODEL"] == "m")
        #expect(grok["GROK_API_KEY"] == InferenceService.apiKey)
        #expect(grok["XAI_BASE_URL"] == nil)
    }

    @Test("Multi-model registry YAML lists each model + a memory budget") func modelsYAML() {
        let yaml = InferenceService.makeModelsYAML(models: [
            InferenceModel(name: "a/b", repo: "a/b", estMemGB: 13),
            InferenceModel(name: "c/d", repo: "c/d", estMemGB: 42),
        ], memoryBudgetGB: 110)
        #expect(yaml.contains("memory_budget_gb: 110"))
        #expect(yaml.contains("model: \"a/b\""))
        #expect(yaml.contains("estimated_memory_gb: 42"))
        #expect(yaml.contains("name: \"c/d\""))
    }

    @Test("Engine launch carries api key, offline, + tool-call parser") func launchFlags() {
        let plan = InferenceService.makeLaunchPlan(
            engine: .vllmMLX, executable: URL(fileURLWithPath: "/x/vllm-mlx"),
            modelRepo: "a/b", cached: true, toolParser: "hermes", apiKey: "brk-test", env: [:])
        #expect(plan.arguments.contains("--api-key"))
        #expect(plan.arguments.contains("brk-test"))
        #expect(plan.environment["HF_HUB_OFFLINE"] == "1")
        // Without these, the model never emits tool_use blocks.
        #expect(plan.arguments.contains("--enable-auto-tool-choice"))
        let i = plan.arguments.firstIndex(of: "--tool-call-parser")
        #expect(i != nil && plan.arguments[i! + 1] == "hermes")
    }

    @Test("Shipped catalog gives each model a tool-call parser") func catalogParsers() throws {
        let url = URL(fileURLWithPath: "Sources/AgentCoding/Resources/catalog.json")
        let cat = try ModelCatalog.parse(Data(contentsOf: url))
        #expect(cat.models.allSatisfy { ($0.toolParser ?? "").isEmpty == false })
        #expect(cat.model(id: "qwen2.5-coder-7b-mlx-4bit")?.toolParser == "hermes")
    }

    @Test("Prometheus metrics parse + sum across labels") func metricsParse() {
        let text = """
        # HELP vllm:generation_tokens_total Generated tokens
        # TYPE vllm:generation_tokens_total counter
        vllm:generation_tokens_total{model="a"} 100
        vllm:generation_tokens_total{model="b"} 50
        vllm:num_requests_running 2
        garbage line without value
        """
        let m = InferenceMetrics.parse(text)
        #expect(m.generationTokens == 150)   // summed across label sets
        #expect(m.requestsRunning == 2)
        #expect(m.promptTokens == nil)
    }

    @Test("Distinct local models gather across tools + fusion") func distinctModels() {
        var p = Profile(name: "t", tool: .claude, authMode: .local)
        p.activeModelID = "m1"
        p.additionalTools = [Profile.ToolSpec(tool: .codex, authMode: .local, localModelID: "m2")]
        p.fusionLocalLeg = "m3"
        #expect(Set(p.distinctLocalModelIDs) == ["m1", "m2", "m3"])
    }

    @Test("Codex local provider TOML uses the chat wire API") func codexTOML() {
        let toml = SessionDisk.codexLocalProviderTOML(model: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit")
        #expect(toml.contains("model_provider = \"bromure-local\""))
        #expect(toml.contains("base_url = \"http://127.0.0.1:11434/v1\""))
        #expect(toml.contains("wire_api = \"chat\""))
        #expect(toml.contains("mlx-community/Qwen2.5-Coder-7B-Instruct-4bit"))
    }

    @Test("ToolSpec local model round-trips through Codable") func specRoundTrip() throws {
        let spec = Profile.ToolSpec(tool: .claude, authMode: .local,
                                    localModelID: "qwen2.5-coder-7b-mlx-4bit")
        let back = try JSONDecoder().decode(Profile.ToolSpec.self,
                                            from: try JSONEncoder().encode(spec))
        #expect(back.authMode == .local)
        #expect(back.localModelID == "qwen2.5-coder-7b-mlx-4bit")
    }

    @Test("Primary tool's local model is the profile activeModelID") func primarySpec() {
        var p = Profile(name: "t", tool: .claude, authMode: .local)
        p.activeModelID = "qwen2.5-coder-7b-mlx-4bit"
        let primary = p.allToolSpecs.first { $0.tool == .claude }
        #expect(primary?.localModelID == "qwen2.5-coder-7b-mlx-4bit")
    }

    @Test("A local model fuses as a standalone leg, not a tool credential") func fusionLocal() {
        // Cloud Claude session + a standalone local fuse leg → 2 drafts →
        // Fusion is configurable.
        var p = Profile(name: "t", tool: .claude, authMode: .token, apiKey: "sk-ant-x")
        p.fusionLocalLeg = "qwen2.5-coder-7b-mlx-4bit"
        #expect(p.fusionConfigurable)
        // The local leg also makes the engine boot for this profile.
        #expect(p.localEngineModelID == "qwen2.5-coder-7b-mlx-4bit")

        // A tool in local *agent* mode is NOT a cloud Fusion provider — that's
        // separate from the standalone local fuse leg.
        var p2 = Profile(name: "t", tool: .claude, authMode: .token, apiKey: "sk-ant-x")
        p2.additionalTools = [Profile.ToolSpec(tool: .codex, authMode: .local,
                                               localModelID: "x")]
        #expect(!p2.hasUsableCredential(for: .codex))
        #expect(!p2.fusionUsableProviders.contains(.codex))

        // Local judge boots the engine too.
        var p3 = Profile(name: "t", tool: .claude, authMode: .token, apiKey: "sk-ant-x")
        p3.fusionJudgeLocal = true
        p3.fusionJudgeModel = "qwen2.5-coder-7b-mlx-4bit"
        #expect(p3.localEngineModelID == "qwen2.5-coder-7b-mlx-4bit")
    }

    @Test("Engine model resolves from the right source") func engineModel() {
        // Primary in local mode → its activeModelID.
        var p = Profile(name: "t", tool: .claude, authMode: .local)
        p.activeModelID = "m-primary"
        #expect(p.localEngineModelID == "m-primary")

        // Cloud primary, but an additional tool is local → its model.
        var p2 = Profile(name: "t", tool: .claude, authMode: .token)
        p2.additionalTools = [Profile.ToolSpec(tool: .codex, authMode: .local,
                                               localModelID: "m-codex")]
        #expect(p2.localEngineModelID == "m-codex")

        // Hybrid routing also needs the active model served.
        var p3 = Profile(name: "t", tool: .claude, authMode: .token)
        p3.modelRouting = .hybrid
        p3.activeModelID = "m-route"
        #expect(p3.localEngineModelID == "m-route")

        // Pure cloud, no local tool → nothing to serve.
        let p4 = Profile(name: "t", tool: .claude, authMode: .token)
        #expect(p4.localEngineModelID == nil)
    }
}

// MARK: - Profile persistence round-trip

@Suite("Profile routing persistence")
struct ProfileRoutingPersistenceTests {
    @Test("Routing + hybrid knobs round-trip through Codable") func roundTrip() throws {
        var p = Profile(name: "t", tool: .claude, authMode: .token)
        p.modelRouting = .hybrid
        p.activeModelID = "glm-5.2-mlx-3bit"
        p.hybridCloudTokenBudget = 500_000
        p.hybridSoftTTFTSeconds = 7.5
        p.hybridLocalSplitPercent = 25

        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Profile.self, from: data)
        #expect(back.modelRouting == .hybrid)
        #expect(back.activeModelID == "glm-5.2-mlx-3bit")
        #expect(back.hybridCloudTokenBudget == 500_000)
        #expect(back.hybridSoftTTFTSeconds == 7.5)
        #expect(back.hybridLocalSplitPercent == 25)
    }

    @Test("Defaults stay compact — cloud routing emits nothing extra") func defaultCompact() throws {
        let p = Profile(name: "t", tool: .claude, authMode: .token)
        #expect(p.modelRouting == .cloud)
        let json = String(data: try JSONEncoder().encode(p), encoding: .utf8)!
        #expect(!json.contains("modelRouting"))
        #expect(!json.contains("hybridCloudTokenBudget"))
    }
}
