import Foundation
import Testing
@testable import bromure_ac

/// Host-side Kimi provisioning: the managed provider + model list the CLI
/// needs in `config.toml`, generated from `/models` the way `kimi login`
/// does it, so a session seeded from a record without a captured config
/// still starts with a default model.
@MainActor
@Suite("Kimi managed-provider provisioning")
struct KimiProvisioningTests {

    /// A verbatim `/models` answer from api.kimi.ai/coding/v1 (2026-09-22).
    static let liveModels = """
    {"data":[{"id":"kimi-for-coding","created":1761264000,"object":"model","display_name":"K2.8 Preview","type":"model","context_length":1048576,"supports_reasoning":true,"supports_image_in":true,"supports_video_in":true,"supports_dynamic_tools":true,"supports_thinking_type":"only","think_efforts":{"support":true,"valid_efforts":["low","high","max"],"default_effort":"max"}},{"id":"kimi-for-coding-highspeed","created":1761264000,"object":"model","display_name":"K2.7 Code Highspeed","type":"model","context_length":262144,"supports_reasoning":true,"supports_image_in":true,"supports_video_in":true,"supports_dynamic_tools":false,"supports_thinking_type":"only"},{"id":"k3-256k","object":"model","display_name":"K3-256k","type":"model","context_length":262144,"supports_reasoning":true,"supports_image_in":true,"supports_video_in":false,"supports_dynamic_tools":true,"supports_thinking_type":"only","think_efforts":{"support":true,"valid_efforts":["low","high","max"],"default_effort":"high"}}],"object":"list","has_more":false}
    """

    @Test("parses /models the way kimi's toModelInfo does")
    func parsesModels() throws {
        let models = try KimiProvisioning.models(fromModelsResponse: Data(Self.liveModels.utf8))
        #expect(models.map(\.id) == ["kimi-for-coding", "kimi-for-coding-highspeed", "k3-256k"])
        let first = try #require(models.first)
        #expect(first.contextLength == 1_048_576)
        #expect(first.displayName == "K2.8 Preview")
        #expect(first.supportsThinkingType == "only")
        #expect(first.supportEfforts == ["low", "high", "max"])
        #expect(first.defaultEffort == "max")
        #expect(first.supportsToolUse)          // absent → true, like kimi
        #expect(first.supportsDynamicTools)
        #expect(first.modelProtocol == nil)
        // No think_efforts block → no efforts.
        #expect(models[1].supportEfforts == nil && models[1].defaultEffort == nil)
        #expect(KimiProvisioning.capabilities(first)
                == ["thinking", "always_thinking", "image_in", "video_in", "tool_use", "dynamically_loaded_tools"])
        #expect(KimiProvisioning.capabilities(models[2])
                == ["thinking", "always_thinking", "image_in", "tool_use", "dynamically_loaded_tools"])
    }

    @Test("a model without a positive context_length is rejected, like kimi")
    func rejectsBadContextLength() {
        let bad = Data(#"{"data":[{"id":"x","context_length":0}]}"#.utf8)
        #expect(throws: KimiProvisioning.ProvisioningError.self) {
            _ = try KimiProvisioning.models(fromModelsResponse: bad)
        }
        #expect(throws: KimiProvisioning.ProvisioningError.self) {
            _ = try KimiProvisioning.models(fromModelsResponse: Data("[]".utf8))
        }
    }

    @Test("writes the config kimi login would: default model, provider, aliases, thinking, services")
    func writesProvisionedConfig() throws {
        let models = try KimiProvisioning.models(fromModelsResponse: Data(Self.liveModels.utf8))
        let toml = try KimiProvisioning.configTOML(
            models: models, baseURL: "https://api.kimi.ai/coding/v1/",
            credentialName: "kimi-code-env-0e4f99c69cc27850", oauthHost: "auth.kimi.ai")

        #expect(toml.hasPrefix("default_model = \"kimi-code/kimi-for-coding\"\n"))
        #expect(toml.contains("[providers.\"managed:kimi-code\"]\ntype = \"kimi\"\nbase_url = \"https://api.kimi.ai/coding/v1\"\napi_key = \"\"\n"))
        #expect(toml.contains("[providers.\"managed:kimi-code\".oauth]\nstorage = \"file\"\nkey = \"oauth/kimi-code-env-0e4f99c69cc27850\"\noauth_host = \"https://auth.kimi.ai\"\n"))
        #expect(toml.contains("[models.\"kimi-code/kimi-for-coding\"]\nprovider = \"managed:kimi-code\"\nmodel = \"kimi-for-coding\"\nmax_context_size = 1048576\ncapabilities = [\"thinking\", \"always_thinking\", \"image_in\", \"video_in\", \"tool_use\", \"dynamically_loaded_tools\"]\ndisplay_name = \"K2.8 Preview\"\nsupport_efforts = [\"low\", \"high\", \"max\"]\ndefault_effort = \"max\"\n"))
        #expect(toml.contains("[models.\"kimi-code/kimi-for-coding-highspeed\"]\n"))
        #expect(!toml.contains("support_efforts = []"))
        #expect(toml.contains("[thinking]\nenabled = true\n"))
        #expect(toml.contains("[services.moonshot_search]\nbase_url = \"https://api.kimi.ai/coding/v1/search\"\napi_key = \"\"\n\n[services.moonshot_search.oauth]\n"))
        #expect(toml.contains("[services.moonshot_fetch]\nbase_url = \"https://api.kimi.ai/coding/v1/fetch\"\n"))
        // Nothing the CLI's own writer wouldn't emit for these models.
        #expect(!toml.contains("protocol") && !toml.contains("beta_api"))
        #expect(KimiProvisioner.isProvisioned(toml))
        #expect(ACAppDelegate.kimiConfigIsProvisioned(toml))
    }

    @Test("anthropic-protocol models carry beta_api and adaptive_thinking")
    func anthropicProtocolFields() throws {
        let m = KimiProvisioning.Model(id: "k-anthropic", contextLength: 1000, supportsReasoning: true,
                                       modelProtocol: "anthropic")
        let toml = try KimiProvisioning.configTOML(
            models: [m], baseURL: "https://api.kimi.ai/coding/v1",
            credentialName: "kimi-code-env-abc", oauthHost: "https://auth.kimi.ai")
        #expect(toml.contains("protocol = \"anthropic\"\nbeta_api = true\nadaptive_thinking = true\n"))
        // supportsReasoning with no thinking type → thinking on.
        #expect(toml.contains("[thinking]\nenabled = true\n"))
    }

    @Test("the legacy .com default slot leaves oauth_host out, as kimi's persistedOAuthHost does")
    func legacySlotOmitsOAuthHost() throws {
        let m = KimiProvisioning.Model(id: "m", contextLength: 10, supportsThinkingType: "no")
        let toml = try KimiProvisioning.configTOML(
            models: [m], baseURL: "https://api.kimi.com/coding/v1",
            credentialName: "kimi-code", oauthHost: "auth.kimi.com")
        #expect(toml.contains("key = \"oauth/kimi-code\"\n\n"))
        #expect(!toml.contains("oauth_host"))
        #expect(toml.contains("[thinking]\nenabled = false\n"))
    }

    @Test("an empty model list is an error")
    func emptyModelsRejected() {
        #expect(throws: KimiProvisioning.ProvisioningError.self) {
            _ = try KimiProvisioning.configTOML(models: [], baseURL: "https://api.kimi.ai/coding/v1",
                                                credentialName: "kimi-code-env-x", oauthHost: "auth.kimi.ai")
        }
    }

    @Test("a provider block without a default_model does not count as provisioned")
    func providerAloneIsNotProvisioned() {
        let providerOnly = "[providers.\"managed:kimi-code\"]\ntype = \"kimi\"\n"
        #expect(!KimiProvisioner.isProvisioned(providerOnly))
        #expect(!ACAppDelegate.kimiConfigIsProvisioned(providerOnly))
        #expect(!KimiProvisioner.isProvisioned(nil))
        #expect(!KimiProvisioner.isProvisioned("# >>> bromure-kimi\n[[hooks]]\nevent = \"Stop\"\n"))
    }

    @Test("TOML strings and keys are escaped and quoted")
    func tomlEscaping() {
        #expect(KimiProvisioning.TOMLValue.string("a\"b\\c\n").rendered == "\"a\\\"b\\\\c\\n\"")
        #expect(KimiProvisioning.tomlKey("kimi-code_1") == "kimi-code_1")
        #expect(KimiProvisioning.tomlKey("kimi-code/k3") == "\"kimi-code/k3\"")
    }
}
