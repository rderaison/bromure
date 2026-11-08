import Foundation

// The agents' own config files in the meta share, the guest init's to lay
// down: Codex's and Grok's local-engine providers, Kimi's managed block and
// approval flag, omp's model, models.yml and settings overlay. macOS
// (SessionDisk.prepareMetadataShare) and the Linux daemon stage the same
// files.

extension SessionDisk {

    /// Each agent's config files for `profile`, into the meta share `tmp`.
    static func writeAgentConfigs(into tmp: URL, profile: Profile, tokenPlan: SessionTokenPlan?) throws {
        // Codex local inference: Codex uses the Responses API via a config-file
        // provider, so env vars don't redirect it. Write a model_provider with
        // wire_api="responses" targeting the endpoint vllm-mlx serves on the
        // loopback (the guest init lays this down before the MCP block so the
        // top-level keys stay valid TOML).
        if profile.allToolSpecs.contains(where: { $0.tool == .codex && $0.authMode == .local }),
           let localModel = profile.localAgentModelName {
            // Send the real served model id (not the old sentinel) so Codex
            // knows what it's talking to; a model switch restages this file
            // and the proxy remaps the retired name for the running agent.
            // Carry the model's real context window (catalog / probed server
            // value) so Codex sizes compaction correctly.
            try Self.codexLocalProviderTOML(model: localModel,
                                            contextWindow: Self.localModelContext(profile: profile)).write(
                to: tmp.appendingPathComponent("codex-local.toml"),
                atomically: true, encoding: .utf8)
        }

        // Grok local inference: GROK_MODELS_BASE_URL + XAI_API_KEY (env) point
        // grok at the engine, but grok still sends its default model id
        // "grok-build" — which the engine 404s. A [model.grok-build] override
        // in config.toml rewrites that to the served repo (guest init appends).
        if profile.allToolSpecs.contains(where: { $0.tool == .grok && $0.authMode == .local }),
           let localModel = profile.localAgentModelName {
            // Map grok-build → the real served model id (not the old
            // sentinel); a model switch restages this file and the proxy
            // remaps the retired name for the running agent.
            try Self.grokLocalModelMapTOML(model: localModel).write(
                to: tmp.appendingPathComponent("grok-local.toml"),
                atomically: true, encoding: .utf8)
        }

        // Kimi Code managed config block, merged marker-guarded into
        // ~/.kimi-code/config.toml by the guest init. Always carries the
        // status `[[hooks]]` (working/done/needsInput → sidebar dot, and the
        // automation done signal); token mode adds the open-platform provider
        // with the FAKE key, since kimi reads provider credentials only from
        // config.toml — never from the shell environment.
        if let kimiSpec = profile.allToolSpecs.first(where: { $0.tool == .kimi }) {
            var toml = Self.kimiHooksTOML
            if kimiSpec.authMode == .token,
               let fake = tokenPlan?.fakeForKimi() {
                toml += Self.kimiTokenProviderTOML(fakeKey: fake)
            }
            try toml.write(to: tmp.appendingPathComponent("kimi.toml"),
                           atomically: true, encoding: .utf8)
        }
        // Kimi's approval mode flag (`--auto` / `--yolo`), read by the .bashrc
        // tab launcher for the launches the guest builds itself (board tasks,
        // plans, branch sessions). Host-typed launches carry it inline
        // (AgentSessionEngine.roleFlags). Rewritten on a live refresh, so a
        // changed setting reaches the next launch without a reboot.
        try (profile.kimiApprovals.launchFlag + "\n")
            .write(to: tmp.appendingPathComponent(Self.kimiApprovalsMetaFile),
                   atomically: true, encoding: .utf8)

        // omp: stage the resolved `--model` (bashrc reads it at launch) and,
        // for a `.custom` OpenAI-compatible provider or local mode, a
        // models.yml so omp knows the endpoint + model. The default Anthropic
        // path needs neither — omp uses ANTHROPIC_API_KEY + a provider model.
        if let ompSpec = profile.allToolSpecs.first(where: { $0.tool == .omp }) {
            // Local fallback is the REAL served model id (not the old
            // `bromure-local` sentinel) — omp keys its provider entry and
            // token accounting off the name.
            let localFallback = profile.localAgentModelName
            if let model = ompSpec.resolvedOmpModel(localFallback: localFallback) {
                try (model + "\n").write(to: tmp.appendingPathComponent("omp-model"),
                                         atomically: true, encoding: .utf8)
            }
            // models.yml for custom / local: an OpenAI-compatible provider
            // entry pointing omp at the user's base URL (custom) or the on-host
            // engine through the MITM sentinel host (local).
            let prov = ompSpec.effectiveOmpProvider
            let modelName = ompSpec.resolvedOmpModel(localFallback: localFallback)
                ?? localFallback ?? "default"
            var yaml: String? = nil
            if ompSpec.authMode == .local {
                // Capability flags come from the engine probe: omp gates
                // image attachments on `input` and its thinking-effort UI on
                // `reasoning`, so a vision-capable Ollama model is unusable
                // for images without them.
                let meta = Self.localModelMeta(profile: profile)
                // Built-in MLX: advertise thinking only for models that
                // actually reason — the catalog marks them with a
                // `reasoning_parser` (Qwen3-8B yes; Qwen3-Coder-Next no).
                // A blanket flag made omp treat coder models as reasoning
                // models, showing an effort UI the model can't honor.
                // BROMURE_THINKING=0 still disables it (the engine child
                // inherits this env). External: the server's capability.
                let thinkEnv = ProcessInfo.processInfo.environment["BROMURE_THINKING"]
                let builtinThinking = profile.localEngineBaseURL == nil
                    && profile.activeModelID.flatMap { CatalogStore.shared.resolve($0)?.reasoningParser } != nil
                    && !(thinkEnv == "0" || thinkEnv?.lowercased() == "false")
                yaml = Self.ompModelsYAML(
                    base: "https://\(InferenceService.localMitmHost)/v1",
                    model: modelName,
                    contextWindow: Self.ompLocalContext(profile: profile),
                    vision: meta?.vision == true,
                    reasoning: meta?.thinking == true || builtinThinking,
                    extras: profile.ompExtraProviders)
            } else if prov == .custom, let base = ompSpec.ompBaseURL,
                      !base.trimmingCharacters(in: .whitespaces).isEmpty {
                yaml = Self.ompModelsYAML(base: base, model: modelName,
                                          contextWindow: profile.ompContextWindow,
                                          extras: profile.ompExtraProviders)
            }
            // The other providers in Settings → Models stay on offer next
            // to the assigned one, which remains the default (`--model`).
            if yaml == nil {
                let extras = profile.ompExtraProviders.compactMap(OmpYAMLProvider.init(extra:))
                if !extras.isEmpty { yaml = Self.ompModelsYAML(providers: extras) }
            }
            if let yaml {
                try yaml.write(to: tmp.appendingPathComponent("omp-models.yml"),
                               atomically: true, encoding: .utf8)
            }
            // Settings overlay every omp launch loads (the bashrc omp()
            // wrapper passes --config):
            //  • browser.enabled:false — the built-in puppeteer browser tool
            //    must be OFF or omp filters browser-automation MCP servers,
            //    cutting the agent off from the embedded browser pane.
            //  • setupVersion — skips omp's first-run 5-step onboarding wizard
            //    ("Set up your providers", pick a model). Bromure fully manages
            //    the provider (proxy-injected auth) and the model (--model at
            //    launch + models.yml), so that wizard is never appropriate. The
            //    wizard runs only when setupVersion is ABSENT (verified live);
            //    a high value keeps it skipped across omp version bumps.
            //  • modelRoles.default — pins the model even for a bare `omp` (no
            //    --model, e.g. the user typing `omp` in the shell). omp persists
            //    the last resolved model to ~/.omp/agent/config.yml and would
            //    otherwise keep using a stale one (e.g. an old "glm" default that
            //    resolved to the flagship GLM-5.3 rather than GLM-5.3-Flash). The
            //    overlay overrides that persisted value (verified); an explicit
            //    --model still wins over both. Cloud providers fuzzy-match the
            //    bare model; local/custom need the models.yml provider qualifier.
            //  • enabledModels — scope omp's model universe to the configured
            //    provider so no role can silently fall back to a cloud model
            //    whose key is only present for a sibling agent (see the helper).
            let overlay = Self.ompConfigOverlay(authMode: ompSpec.authMode,
                                                provider: prov, modelName: modelName,
                                                extraProviders: profile.ompExtraProviders.map(\.ompSlug))
            try overlay.write(
                to: tmp.appendingPathComponent("omp-config.yml"),
                atomically: true, encoding: .utf8)
            // Key env vars omp must not see (a sibling agent's / an unused
            // provider's): the bashrc omp() wrapper unsets them per launch.
            try Self.ompHiddenKeyEnvVars(profile: profile).map { $0 + "\n" }.joined().write(
                to: tmp.appendingPathComponent(Self.ompEnvUnsetMetaFile),
                atomically: true, encoding: .utf8)
        }
    }

    /// Codex `~/.codex/config.toml` top matter that points Codex at the
    /// on-host engine. `wire_api = "responses"` — Codex's native Responses
    /// API, which vllm-mlx serves at /v1/responses (verified working).
    /// Top-level keys come first so it stays valid TOML when the MCP
    /// `[mcp_servers.*]` tables are appended after it.
    static func codexLocalProviderTOML(model: String, contextWindow: Int) -> String {
        // Cap Codex's context window to the active local model's real size. Codex
        // can't find the `bromure-local` sentinel in its model registry, so it
        // warns and uses fallback metadata (a generic 272k window); model_context_
        // window pins it to what the model actually supports (e.g. 40k for an 8B).
        // The warning itself is unavoidable for an unknown slug, and is harmless:
        // the fallback is non-reasoning with default tools, which suits a local
        // model better than masquerading as a known (reasoning) Codex model would.
        // (model_max_output_tokens is NOT a Codex config key — it's ignored.)
        return """
        # Generated by Bromure AC — local inference provider.
        check_for_update_on_startup = false
        model = \(tomlQuote(model))
        model_provider = "bromure-local"
        model_context_window = \(contextWindow)

        [model_providers.bromure-local]
        name = "Bromure Local"
        base_url = "https://\(InferenceService.localMitmHost)/v1"
        wire_api = "responses"
        env_key = "OPENAI_API_KEY"

        """
    }

    /// Grok `~/.grok/config.toml` fragment mapping grok's default model id
    /// (`grok-build`) to the served repo. The guest init APPENDS this (grok's
    /// config already has [cli]/[ui]); the sentinel markers let re-boots strip
    /// the prior block so it stays idempotent. Per grok's "Custom Models"
    /// docs: when `model` is set on a `[model.*]` entry, that value is the id
    /// sent to the API, so grok-build → the served repo.
    static func grokLocalModelMapTOML(model: String) -> String {
        """
        # >>> bromure-local
        [model.grok-build]
        model = \(tomlQuote(model))
        # <<< bromure-local
        """
    }

    /// Status hooks for Kimi Code — its `[[hooks]]` events mirror Claude
    /// Code's hook names, and the commands reuse the same reporter script
    /// `prepareHomeDirectory` writes for Claude. Stop doubles as the
    /// automation done signal.
    static let kimiHooksTOML = """
    [[hooks]]
    event = "UserPromptSubmit"
    command = "/home/ubuntu/.bromure/agent-status.sh working"

    [[hooks]]
    event = "PreToolUse"
    command = "/home/ubuntu/.bromure/agent-status.sh working"

    [[hooks]]
    event = "Stop"
    command = "/home/ubuntu/.bromure/agent-status.sh done"

    [[hooks]]
    event = "PermissionRequest"
    command = "/home/ubuntu/.bromure/agent-status.sh needsInput"

    # Answered: back to work (else "needs you" until the turn ends).
    [[hooks]]
    event = "PermissionResult"
    command = "/home/ubuntu/.bromure/agent-status.sh working"

    # A turn the provider refused fires StopFailure, not Stop: the user's to fix.
    [[hooks]]
    event = "StopFailure"
    command = "/home/ubuntu/.bromure/agent-status.sh needsInput"

    # Esc: no Stop follows. Idle, not done: the turn didn't finish.
    [[hooks]]
    event = "Interrupt"
    command = "/home/ubuntu/.bromure/agent-status.sh idle"

    # Agent-to-agent traffic (our own delegation MCP to the host) never
    # waits on an approval. Kimi matches a rule's pattern (picomatch) against
    # the tool's qualified name, mcp__<server>__<tool>: a bare server name
    # matches nothing; the glob does. NOTE: Kimi Code 2.1.1 (and 0.43.x)
    # parses and validates these rules but never loads them into its
    # permission gate (nothing calls its rules service's addRules), so they
    # take effect only on a Kimi that wires them up.
    [[permission.rules]]
    decision = "allow"
    pattern = "mcp__delegation__*"

    # The same server where a folder declares it under its project name.
    [[permission.rules]]
    decision = "allow"
    pattern = "mcp__bromure-delegation__*"

    # Showing the user a picture or a chart needs no approval either.
    [[permission.rules]]
    decision = "allow"
    pattern = "mcp__display__*"

    # A Switchboard's own tools (only its tab has the server) — Claude's
    # Switchboard runs them unprompted (--allowedTools mcp__switchboard).
    [[permission.rules]]
    decision = "allow"
    pattern = "mcp__switchboard__*"

    """

    /// Open-platform provider entry for token-mode Kimi: config.toml is the
    /// ONLY place kimi reads provider credentials from (shell env vars are
    /// deliberately ignored by the CLI), so the fake key lands here and the
    /// proxy swaps it on requests to api.moonshot.ai.
    static func kimiTokenProviderTOML(fakeKey: String) -> String {
        """

        [providers.kimi]
        type = "kimi"
        base_url = "https://api.moonshot.ai/v1"
        api_key = \(tomlQuote(fakeKey))

        """
    }

    /// The `omp-config.yml` overlay staged for every omp launch (the bashrc
    /// `omp()` wrapper passes it as `--config`). Three jobs:
    ///
    ///  • `browser.enabled: false` — omp filters browser-automation MCP servers
    ///    while its built-in browser tool is on, cutting the agent off from the
    ///    embedded browser pane.
    ///  • `setupVersion` — skips omp's first-run onboarding wizard (Bromure
    ///    manages provider + model, so it's never appropriate). A high value
    ///    keeps it skipped across omp version bumps.
    ///  • `enabledModels` — scope omp's model universe to the provider this
    ///    workspace configured it for, so NO role ever silently falls back to a
    ///    cloud model whose key is only present for a sibling agent. A workspace
    ///    can enable several agents (e.g. Claude on Anthropic + omp on a local
    ///    model), so `api_key.env` exports ANTHROPIC_API_KEY alongside omp's own
    ///    key. omp reads whatever provider keys it sees and, whenever
    ///    `modelRoles.default` can't be resolved — most often a cold custom
    ///    server whose `/v1/models` probe hasn't landed yet — picks a
    ///    *credentialed* provider as its default, quietly running (and billing)
    ///    on Anthropic instead of the local model the user chose. A `default`
    ///    pin alone doesn't stop this (the fallback fires when the pin itself
    ///    can't resolve), and `enabledProviders` doesn't gate the fallback
    ///    either; only an `enabledModels` glob does (all verified live against
    ///    omp 18.2.x). `web`/`local` (omp's own search + tts/stt providers) stay
    ///    enabled so those tools keep working.
    ///  • `modelRoles.default` — pins the model even for a bare `omp` (no
    ///    `--model`); the overlay overrides omp's persisted `config.yml` value,
    ///    while an explicit `--model` still wins over both. Cloud providers
    ///    fuzzy-match the bare model; local/custom need the `bromure/` qualifier.
    ///
    /// Pure (no I/O) so it's unit-tested — see `OmpAgentTests`.
    ///
    /// `extraProviders`: the other providers configured in Settings → Models
    /// (omp's slug for each — `zai`, `bromure-openrouter`…), enabled next to
    /// its own so its picker offers them (issue #37); the guest adds the
    /// providers the user defined in omp's models.yml. The default stays
    /// pinned to the assigned model.
    static func ompConfigOverlay(authMode: Profile.AuthMode,
                                 provider: Profile.OmpProvider,
                                 modelName: String,
                                 extraProviders: [String] = []) -> String {
        // A local model (on-device engine or a custom OpenAI-compatible server)
        // is served under the `bromure` provider written into models.yml; a
        // cloud omp uses its own provider slug (which equals the raw case name).
        let local = (authMode == .local || provider == .custom)
        let providerSlug = local ? "bromure" : provider.rawValue
        var overlay = "# Generated by Bromure AC; do not edit.\n"
            + "browser.enabled: false\n"
            + "setupVersion: 99\n"
            + "enabledModels:\n"
            + "  - \"\(providerSlug)/*\"\n"
            + extraProviders.filter { $0 != providerSlug }.map { "  - \"\($0)/*\"\n" }.joined()
            + "  - \"web/*\"\n"
            + "  - \"local/*\"\n"
        // Every built-in provider omp isn't configured for is DISABLED: omp
        // otherwise polls ~a dozen model catalogs on each launch (real keys
        // swapped in for any provider whose env var it sees), and lists their
        // models in /model. disabledProviders is the one switch that gates
        // both discovery and selection (verified in omp 18.6.1's
        // model-registry). The guest merge drops any name the user defined
        // in omp's own models.yml from this list.
        let keep = Set([providerSlug, "web", "local"] + extraProviders)
        overlay += "disabledProviders:\n"
            + ompBuiltInProviders.filter { !keep.contains($0) }.map { "  - \"\($0)\"\n" }.joined()
        // No update / plugin-marketplace polling (npm) and no "Update
        // Available" banner: omp is baked into the image and Bromure updates
        // it, so `omp update` in a session is never the right advice.
        overlay += "startup:\n  checkUpdate: false\n"
            + "marketplace:\n  autoUpdate: \"off\"\n"
        if modelName != "default", !modelName.isEmpty {
            let qualify = local && !modelName.contains("/")
            let role = qualify ? "bromure/\(modelName)" : modelName
            overlay += "modelRoles:\n  default: \(role)\n"
        }
        return overlay
    }

    /// omp's built-in providers (omp 18.6.1: pi-catalog's model-manager
    /// descriptors + bundled/models.dev catalog providers + the special
    /// OAuth-discovered ones), minus `web`/`local` (its search and tts/stt
    /// tools). An id a later omp drops is ignored; one it adds stays enabled
    /// until listed here, but `enabledModels` still hides its models.
    /// Meta-share file listing the env vars the omp() wrapper unsets.
    static let ompEnvUnsetMetaFile = "omp-env-unset"

    static let ompBuiltInProviders: [String] = [
        "abliteration", "aiand", "aimlapi", "alibaba-coding-plan", "alibaba-token-plan",
        "amazon-bedrock", "anthropic", "azure", "baseten", "bedrock-mantle", "cerebras",
        "charm-hyper", "cline-pass", "cloudflare-ai-gateway", "commandcode", "coreweave",
        "cursor", "deepinfra", "deepseek", "devin", "factory-droid", "firepass", "fireworks",
        "github-copilot", "gitlab-duo", "gitlab-duo-agent", "gmi-cloud", "google",
        "google-antigravity", "google-gemini-cli", "google-vertex", "groq", "helmcode",
        "huggingface", "kilo", "kimi-code", "litellm", "lm-studio", "meta", "minimax",
        "minimax-cn", "minimax-code", "minimax-code-cn", "mistral", "moonshot", "muse-code",
        "nanogpt", "novita", "nvidia", "ollama", "ollama-cloud", "openai", "openai-codex",
        "opencode-go", "opencode-zen", "openrouter", "qianfan", "qwen-portal", "sakana",
        "siliconflow", "siliconflow-cn", "singularityapi-dev", "singularityapi-tech",
        "stepfun", "synthetic", "together", "typesafe", "umans", "venice",
        "vercel-ai-gateway", "vllm", "wafer-serverless", "xai", "xai-oauth", "xiaomi",
        "xiaomi-token-plan-ams", "xiaomi-token-plan-cn", "xiaomi-token-plan-sgp",
        "yolo-auto", "zai", "zenmux", "zhipu-coding-plan",
    ]

    /// Provider key env vars present in the shared guest env (exported for a
    /// sibling agent, or a registered provider) that omp must NOT see: every
    /// agent/provider key var except the ones omp's configured providers
    /// read. The bashrc `omp()` wrapper `env -u`s them, so omp can neither
    /// poll those providers' catalogs with the real (swapped) key nor fall
    /// back onto them. Pure — see `OmpAgentTests`.
    static func ompHiddenKeyEnvVars(profile: Profile) -> [String] {
        guard let omp = profile.allToolSpecs.first(where: { $0.tool == .omp }) else { return [] }
        var used: Set<String> = []
        if omp.authMode == .local || omp.effectiveOmpProvider == .custom {
            used.insert("OPENAI_API_KEY")   // models.yml `bromure` apiKey
        } else {
            used.insert(omp.effectiveOmpProvider.apiKeyEnvVar)
        }
        for extra in profile.ompExtraProviders { used.insert(extra.envVar) }
        var all: [String] = []
        for v in Profile.Tool.allCases.map(\.apiKeyEnvVar)
            + Profile.OmpProvider.allCases.map(\.apiKeyEnvVar)
            + ["ANTHROPIC_AUTH_TOKEN", "MOONSHOT_API_KEY", "KIMI_API_KEY", "OPENROUTER_API_KEY"]
        where !v.isEmpty && !all.contains(v) && !used.contains(v) {
            all.append(v)
        }
        return all
    }

    /// omp `~/.omp/agent/models.yml` declaring one OpenAI-compatible provider
    /// (`bromure`) at `base` serving `model`. Used for the `.custom` provider
    /// and local-inference modes; the guest init copies it into place.
    /// Schema per omp v18 (validated live against 18.0.8): `api` must name a
    /// wire (`openai-completions` = the /v1/chat/completions shape both the
    /// built-in engine and external vLLM/Ollama serve), and `apiKey` names
    /// the env var the key resolves from — the per-VM EngineKey SessionDisk
    /// exports as OPENAI_API_KEY, which the proxy needs to identify the
    /// workspace (so `auth: none` is not an option).
    ///
    /// Reasoning models need `reasoning: true` AND a `thinking` block: omp
    /// clamps its session thinking level against `thinking.efforts`, and a
    /// bare `reasoning: true` resolves to an EMPTY effort list → level Off →
    /// the TUI hides the thinking block even though `delta.reasoning` chunks
    /// stream in fine (verified live against omp 18.0.8). The engine treats
    /// thinking as binary and ignores the effort value, so the tiers only
    /// drive omp's effort UI.
    static func ompModelsYAML(base: String, model: String,
                              contextWindow: Int? = nil,
                              vision: Bool = false,
                              reasoning: Bool = false,
                              extras: [Profile.OmpExtraProvider] = []) -> String {
        ompModelsYAML(providers: [OmpYAMLProvider(
            name: "bromure", base: base, apiKeyEnv: "OPENAI_API_KEY",
            models: [OmpYAMLModel(id: model, contextWindow: contextWindow,
                                  vision: vision, reasoning: reasoning)])]
            + extras.compactMap(OmpYAMLProvider.init(extra:)))
    }

    /// One provider entry in omp's models.yml.
    struct OmpYAMLProvider {
        var name: String
        var base: String
        /// The env var omp reads the key from.
        var apiKeyEnv: String
        var models: [OmpYAMLModel]

        init(name: String, base: String, apiKeyEnv: String, models: [OmpYAMLModel]) {
            self.name = name; self.base = base; self.apiKeyEnv = apiKeyEnv; self.models = models
        }
        /// An OpenAI-compatible provider omp isn't on (a native one needs no entry).
        init?(extra: Profile.OmpExtraProvider) {
            guard let base = extra.baseURL, !extra.models.isEmpty else { return nil }
            self.init(name: extra.yamlName, base: base, apiKeyEnv: extra.envVar,
                      models: extra.models.map { OmpYAMLModel(id: $0) })
        }
    }
    struct OmpYAMLModel {
        var id: String
        var contextWindow: Int? = nil
        var vision = false
        var reasoning = false
    }

    /// Bromure's providers sit between these lines in omp's models.yml; the
    /// guest swaps that block in at each launch and keeps everything else
    /// (providers the user added in omp) as it is.
    static let ompManagedBegin = "# >>> bromure-managed (rewritten at every launch; providers outside this block are yours)"
    static let ompManagedEnd = "# <<< bromure-managed"

    static func ompModelsYAML(providers: [OmpYAMLProvider]) -> String {
        var lines = ["# Generated by Bromure AC; do not edit.", "providers:", "  " + ompManagedBegin]
        for p in providers {
            lines += ["  \(p.name):",
                      "    api: openai-completions",
                      "    baseUrl: \(yamlQuote(p.base))",
                      "    apiKey: \(p.apiKeyEnv)",
                      "    models:"]
            for m in p.models {
                lines += ["      - id: \(yamlQuote(m.id))", "        name: \(yamlQuote(m.id))"]
                if let c = m.contextWindow { lines.append("        contextWindow: \(c)") }
                if m.vision { lines.append("        input: [\"text\", \"image\"]") }
                if m.reasoning {
                    lines += ["        reasoning: true",
                              "        thinking:",
                              "          mode: \"effort\"",
                              "          efforts: [\"low\", \"medium\", \"high\"]"]
                }
            }
        }
        lines.append("  " + ompManagedEnd)
        return lines.joined(separator: "\n") + "\n"
    }

    /// Metadata of the profile's active local model on a custom engine: the
    /// probed/cached server values (a first boot against an unprobed server
    /// does one 1.5s-capped synchronous probe; the launch-path probe heals
    /// the cache after that). nil for the built-in engine or no model.
    static func localModelMeta(profile: Profile) -> ExternalEngine.ModelMeta? {
        guard let id = profile.activeModelID, !id.isEmpty,
              let base = profile.localEngineBaseURL else { return nil }
        if let m = EngineModelMeta.meta(base: base, model: id) { return m }
        return EngineModelMeta.refresh(base: base, apiKey: profile.localEngineAPIKey,
                                       model: id, waitUpTo: 1.5)
    }

    /// The context window staged in omp's models.yml on the local route: the
    /// value on omp's own Models row (what Settings shows), else the shared
    /// local model's. One source for both, so they never disagree.
    static func ompLocalContext(profile: Profile) -> Int {
        if let c = profile.ompContextWindow, c > 0 { return c }
        return localModelContext(profile: profile)
    }

    /// Context window of the profile's active local model: the catalog's
    /// number for built-in models; the probed/cached server value for a
    /// custom engine. 128k when nothing better is known.
    static func localModelContext(profile: Profile) -> Int {
        if let set = profile.localModelContextWindow, set > 0 { return set }
        guard let id = profile.activeModelID, !id.isEmpty else { return 128_000 }
        if profile.localEngineBaseURL != nil {
            return localModelMeta(profile: profile)?.context ?? 128_000
        }
        return CatalogStore.shared.resolve(id)?.context ?? 128_000
    }

    /// Minimal YAML scalar quoting (double-quote + escape backslash/quote).
    static func yamlQuote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
