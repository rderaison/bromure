import Foundation
import Testing
@testable import bromure_ac

// MARK: - Tool-call repair (rescuing leaked-as-text calls)

@Suite("ToolCallRepair")
struct ToolCallRepairTests {
    @Test("Rescues <function name=… arguments=…> leaked as text")
    func functionTag() {
        let txt = "I'll do that.\n```xml\n<function name=\"Write\" arguments='{\"file_path\": \"/x/hello.txt\", \"content\": \"hi\"}'>\n```"
        let (clean, blocks) = ToolCallRepair.rescue(text: txt)
        #expect(blocks.count == 1)
        #expect(blocks.first?["name"] as? String == "Write")
        let input = blocks.first?["input"] as? [String: Any]
        #expect(input?["file_path"] as? String == "/x/hello.txt")
        #expect(!clean.contains("<function"))
    }

    @Test("Rescues the markdown [{name,parameters}](…) shape")
    func markdownShape() {
        let txt = "[{\"name\":\"Read\",\"parameters\":{\"file_path\":\"/y\"}}](/y)"
        let (_, blocks) = ToolCallRepair.rescue(text: txt)
        #expect(blocks.first?["name"] as? String == "Read")
    }

    @Test("Rescues a bare <tool_call>{…}</tool_call>")
    func toolCallTag() {
        let txt = "<tool_call>{\"name\": \"Bash\", \"arguments\": {\"command\": \"ls\"}}</tool_call>"
        let (_, blocks) = ToolCallRepair.rescue(text: txt)
        #expect(blocks.first?["name"] as? String == "Bash")
        #expect((blocks.first?["input"] as? [String: Any])?["command"] as? String == "ls")
    }

    @Test("repair() promotes leaked text to tool_use + sets stop_reason")
    func repairPromotes() {
        let msg: [String: Any] = ["content": [
            ["type": "text", "text": "<function name=\"Write\" arguments='{\"file_path\":\"/a\",\"content\":\"b\"}'>"]],
            "stop_reason": "end_turn"]
        let out = ToolCallRepair.repair(message: msg)
        let content = out["content"] as? [[String: Any]] ?? []
        #expect(content.contains { ($0["type"] as? String) == "tool_use" })
        #expect(out["stop_reason"] as? String == "tool_use")
    }

    @Test("repair() leaves a real tool_use untouched")
    func repairNoop() {
        let msg: [String: Any] = ["content": [
            ["type": "tool_use", "id": "call_x", "name": "Write", "input": ["a": 1]]],
            "stop_reason": "tool_use"]
        let out = ToolCallRepair.repair(message: msg)
        #expect((out["content"] as? [[String: Any]])?.count == 1)
    }

    @Test("Clean text yields no rescued calls")
    func cleanText() {
        let (_, blocks) = ToolCallRepair.rescue(text: "Here is a summary of the change.")
        #expect(blocks.isEmpty)
    }

    @Test("repairChat promotes leaked content to OpenAI tool_calls")
    func chatRepair() {
        let resp: [String: Any] = ["choices": [["index": 0, "finish_reason": NSNull(),
            "message": ["role": "assistant",
                        "content": "```xml\n<function name=\"Write\" arguments='{\"file_path\":\"/a\",\"content\":\"b\"}'/>\n```"]]]]
        let out = ToolCallRepair.repairChat(resp)
        let msg = (out["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
        let tc = (msg?["tool_calls"] as? [[String: Any]])?.first
        #expect((tc?["function"] as? [String: Any])?["name"] as? String == "Write")
        #expect((out["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String == "tool_calls")
        let sse = String(data: ToolCallRepair.chatSSE(out), encoding: .utf8) ?? ""
        #expect(sse.contains("tool_calls"))
        #expect(sse.contains("[DONE]"))
    }

    @Test("repairChat leaves a real tool_calls response untouched")
    func chatNoop() {
        let resp: [String: Any] = ["choices": [["index": 0, "finish_reason": "tool_calls",
            "message": ["role": "assistant", "tool_calls": [["id": "call_a", "type": "function",
                "function": ["name": "Write", "arguments": "{}"]]]]]]]
        let out = ToolCallRepair.repairChat(resp)
        let msg = (out["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
        #expect((msg?["tool_calls"] as? [[String: Any]])?.count == 1)
    }

    @Test("repairResponses promotes leaked output_text to a function_call item")
    func responsesRepair() {
        let resp: [String: Any] = ["output": [["id": "msg_1", "type": "message", "role": "assistant",
            "content": [["type": "output_text",
                         "text": "<function name=\"Read\" arguments='{\"file_path\":\"/y\"}'/>"]]]]]
        let out = ToolCallRepair.repairResponses(resp)
        let fc = (out["output"] as? [[String: Any]])?.first { ($0["type"] as? String) == "function_call" }
        #expect(fc?["name"] as? String == "Read")
        #expect(fc?["call_id"] != nil)
        let sse = String(data: ToolCallRepair.responsesSSE(out), encoding: .utf8) ?? ""
        #expect(sse.contains("response.output_item.added"))
        #expect(sse.contains("response.function_call_arguments.done"))
        #expect(sse.contains("response.completed"))
    }

    @Test("sse() emits a tool_use stream")
    func sseStream() {
        let msg = ToolCallRepair.repair(message: ["content": [
            ["type": "text", "text": "<function name=\"Write\" arguments='{\"file_path\":\"/a\",\"content\":\"b\"}'>"]]])
        let s = String(data: ToolCallRepair.sse(message: msg), encoding: .utf8) ?? ""
        #expect(s.contains("message_start"))
        #expect(s.contains("\"type\":\"tool_use\"") || s.contains("\"type\": \"tool_use\""))
        #expect(s.contains("input_json_delta"))
        #expect(s.contains("message_stop"))
    }
}

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

    @Test("Effective catalog replaces baseline + keeps downloaded extras")
    func replaceAndExtras() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("bromure-cat-\(UUID().uuidString)")
        let hub = tmp.appendingPathComponent("hub")
        // A fully-downloaded "retired" repo on disk, not in the catalog.
        let snap = hub.appendingPathComponent("models--x--retired/snapshots/main")
        try fm.createDirectory(at: snap, withIntermediateDirectories: true)
        try "{}".write(to: snap.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        // A cached remote catalog (CatalogStore.init loads supportDir/catalog.json).
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        try #"{"version":9,"models":[{"id":"only","repo":"y/only","name":"Only","download_gb":1,"min_unified_mem_gb":8}]}"#
            .write(to: tmp.appendingPathComponent("catalog.json"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: tmp) }

        let store = CatalogStore(supportDir: tmp, hubCacheDir: hub)
        #expect(store.installedRepos().contains("x/retired"))
        let eff = store.effective()
        // Remote fully REPLACED the bundled baseline (its ids don't leak in).
        #expect(eff.models.contains { $0.repo == "y/only" })
        #expect(!eff.models.contains { $0.id == "qwen2.5-coder-7b-mlx-4bit" })
        // The downloaded retired model is preserved as an installed extra.
        #expect(eff.models.contains { $0.repo == "x/retired" && $0.tags.contains("installed") })
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

    @Test("Output-token extraction feeds the budget") func tokens() {
        // Anthropic streamed message_delta carries the cumulative total.
        let sse = Data(#"event: message_delta\ndata: {"usage":{"output_tokens":137}}\n"#.utf8)
        #expect(HTTPMitmConnection.extractOutputTokens(sse) == 137)
        // OpenAI completion_tokens.
        let oai = Data(#"{"usage":{"prompt_tokens":10,"completion_tokens":42}}"#.utf8)
        #expect(HTTPMitmConnection.extractOutputTokens(oai) == 42)
        #expect(HTTPMitmConnection.extractOutputTokens(Data("no usage here".utf8)) == nil)
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
                == ["pip", "install", "--python", "/tmp/eng/bin/python", "--prerelease", "allow", "-r", "/tmp/req.lock"])
        // --upgrade pulls a republished wheel even when something's installed.
        #expect(EngineProvisioner.pipInstallArgs(venvPython: py, requirementsFile: req, upgrade: true)
                == ["pip", "install", "--python", "/tmp/eng/bin/python", "--prerelease", "allow", "--upgrade", "-r", "/tmp/req.lock"])
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
        // Bearer auth (ANTHROPIC_AUTH_TOKEN), not x-api-key — vllm-mlx only
        // checks Bearer. And only one of them, to avoid Claude's warning.
        #expect(env["ANTHROPIC_AUTH_TOKEN"] == InferenceService.apiKey)
        #expect(env["ANTHROPIC_API_KEY"] == nil)
        #expect(InferenceService.apiKey.hasPrefix("brk-"))
    }

    @Test("Codex carries only the dummy key (config.toml does the routing)") func codexEnv() {
        let codex = Dictionary(uniqueKeysWithValues:
            Profile.Tool.codex.localEnvExports(model: "m").map { ($0.name, $0.value) })
        #expect(codex["OPENAI_API_KEY"] == InferenceService.apiKey)
        // Codex is redirected by the config.toml provider, not env vars.
        #expect(codex["OPENAI_BASE_URL"] == nil)
    }

    @Test("Grok uses the custom-models endpoint env (GROK_MODELS_BASE_URL + XAI_API_KEY)") func grokEnv() {
        let grok = Dictionary(uniqueKeysWithValues:
            Profile.Tool.grok.localEnvExports(model: "m").map { ($0.name, $0.value) })
        #expect(grok["GROK_MODELS_BASE_URL"] == "http://127.0.0.1:11434/v1")
        #expect(grok["XAI_API_KEY"] == InferenceService.apiKey)
        // The old names are ignored by the grok CLI — must not be set.
        #expect(grok["GROK_BASE_URL"] == nil)
        #expect(grok["GROK_API_KEY"] == nil)
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

    @Test("Accessors map to the real vllm-mlx metric names") func metricsRealNames() {
        // Shape verified against vllm-mlx v0.4.0rc1 /metrics (labels included).
        let text = """
        vllm_mlx_completion_tokens_total{model="a"} 80
        vllm_mlx_completion_tokens_total{model="b"} 40
        vllm_mlx_prompt_tokens_total{model="a"} 200
        vllm_mlx_scheduler_running_requests 1
        vllm_mlx_scheduler_waiting_requests 3
        vllm_mlx_http_requests_in_flight 2
        vllm_mlx_cache_hit_rate 0.75
        vllm_mlx_cache_utilization_ratio 0.4
        vllm_mlx_metal_memory_bytes 8589934592
        vllm_mlx_inference_request_duration_seconds_sum 5.0
        vllm_mlx_inference_request_duration_seconds_count 10
        """
        let m = InferenceMetrics.parse(text)
        #expect(m.generationTokens == 120)        // completion tokens, summed
        #expect(m.promptTokens == 200)
        #expect(m.requestsRunning == 1)
        #expect(m.requestsWaiting == 3)
        #expect(m.requestsInFlight == 2)
        #expect(m.cacheHitRate == 0.75)
        #expect(m.cacheUsage == 0.4)
        #expect(m.metalMemoryBytes == 8589934592)
        #expect(m.avgInferenceLatency == 0.5)     // 5.0 / 10
    }

    @Test("Distinct local models gather across tools + fusion") func distinctModels() {
        var p = Profile(name: "t", tool: .claude, authMode: .local)
        p.activeModelID = "m1"
        p.additionalTools = [Profile.ToolSpec(tool: .codex, authMode: .local, localModelID: "m2")]
        p.fusionLocalLeg = "m3"
        #expect(Set(p.distinctLocalModelIDs) == ["m1", "m2", "m3"])
    }

    @Test("Codex local provider TOML uses the responses wire API") func codexTOML() {
        let toml = SessionDisk.codexLocalProviderTOML(model: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit")
        #expect(toml.contains("model_provider = \"bromure-local\""))
        #expect(toml.contains("base_url = \"http://127.0.0.1:11434/v1\""))
        #expect(toml.contains("wire_api = \"responses\""))
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
