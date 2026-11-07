import Foundation
#if canImport(SandboxEngine)
import SandboxEngine
#endif

// Which edits of a running workspace its live refresh re-emits, on any
// host: the macOS app delegate's applyLiveSessionRefresh and the Linux
// daemon's.

extension Profile {
    /// True if an edit touches anything the live refresh re-emits: env
    /// vars, guardrail policy, or any credential (which moves the token
    /// swap map and/or the api_key.env / proxy.env content). Cosmetic
    /// edits (name, color, opacity) return false so the guest doesn't
    /// print a spurious "environment refreshed" line.
    static func sessionRefreshAffectingChange(from old: Profile, to new: Profile) -> Bool {
        old.environmentVariables != new.environmentVariables
            || old.guardrails != new.guardrails
            // The egress firewall (`egressRules`) is NOT here: it has its own
            // live path (applyLiveFirewall, run before this guard), so a rule
            // edit / toggle doesn't re-emit the guest env or print a spurious
            // "environment refreshed" line. An OpenShell policy and its
            // providers are: they also carry credentials and the guest
            // sandbox's policy.
            || old.networkPolicy != new.networkPolicy
            || old.openShellProviders != new.openShellProviders
            || old.supplyChain != new.supplyChain
            || old.promptInjection != new.promptInjection
            || old.pii != new.pii
            || old.httpDatabases != new.httpDatabases
            || old.tool != new.tool
            || old.authMode != new.authMode
            || old.apiKey != new.apiKey
            || old.additionalTools != new.additionalTools
            || old.manualTokens != new.manualTokens
            || old.gitHTTPSCredentials != new.gitHTTPSCredentials
            || old.digitalOceanToken != new.digitalOceanToken
            || old.linearToken != new.linearToken
            || old.twilioCredential != new.twilioCredential
            || old.dockerRegistries != new.dockerRegistries
            || old.awsCredentials != new.awsCredentials
            || old.kubeconfigs != new.kubeconfigs
            || old.mcpServers != new.mcpServers
            || old.gitUserName != new.gitUserName
            || old.gitUserEmail != new.gitUserEmail
            // `.local` agents carry the REAL model name in their env/config
            // files, so a model or engine change must re-emit them (the proxy
            // remaps the retired name for already-running agents).
            || old.activeModelID != new.activeModelID
            || old.modelRouting != new.modelRouting
            || old.localEngineURL != new.localEngineURL
            || old.localEngineAPIKey != new.localEngineAPIKey
            // A workspace's own model settings (or dropping them to inherit the
            // global ones) change what the overlay stages for every agent.
            || old.modelOverride != new.modelOverride
            || old.claudeGatewayBaseURL != new.claudeGatewayBaseURL
            || old.claudeGatewayModels != new.claudeGatewayModels
            // Approval-gate toggles flip a credential's consentCredentialID in the
            // token map, so the live refresh must re-emit it.
            || old.apiKeyRequiresApproval != new.apiKeyRequiresApproval
            || old.digitalOceanTokenRequiresApproval != new.digitalOceanTokenRequiresApproval
            || old.linearTokenRequiresApproval != new.linearTokenRequiresApproval
            // Toggling transparent interception re-emits the meta-share so the
            // guest re-sources a consistent proxy env for the new mode (see the
            // applyInterceptDisabled call in applyLiveSessionRefresh).
            || old.disableTransparentProxy != new.disableTransparentProxy
            || old.strictCredentials != new.strictCredentials
    }
}
