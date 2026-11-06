import Foundation
#if canImport(SandboxEngine)
import SandboxEngine
#endif

// A workspace's guardrails, built from its profile: what the proxy enforces
// for it (macOS: MitmEngine.setGuardrailsConfig; the Linux daemon's
// MitmProxy). Not on iOS, which has no Profile.
extension GuardrailsConfig {
    /// Whether a workspace's guardrails actually restrict something — for the
    /// Security Timeline's Overview. `GuardrailsPolicy.isActive` also counts
    /// the (default-on) `X-bromure-insecure` escape hatch, which relaxes rather
    /// than restricts, so it isn't used here: a write policy / egress rule the
    /// proxy enforces, or any credential set to "ask before use".
    static func restricts(_ p: Profile) -> Bool {
        if make(for: p).isActive { return true }
        return p.apiKeyRequiresApproval
            || p.additionalTools.contains { $0.requireApproval }
            || p.gitHTTPSCredentials.contains { $0.requireApproval }
            || p.manualTokens.contains { $0.requireApproval }
            || p.dockerRegistries.contains { $0.requireApproval }
            || p.httpDatabases.contains { $0.requireApproval }
            || p.kubeconfigs.contains { $0.requireApproval }
            || p.importedSSHKeys.contains { $0.requireApproval }
            || p.awsCredentials.requireApproval
            || p.digitalOceanTokenRequiresApproval
            || p.linearTokenRequiresApproval
            || p.twilioCredential.requireApproval
            || p.sshKeyRequiresApproval
    }

    /// The proxy's guardrails for a workspace: its per-protocol write
    /// policies for the hosts it holds credentials for, and its egress policy.
    static func make(for profile: Profile) -> GuardrailsConfig {
        let kubeHosts = Set(profile.kubeconfigs.compactMap {
            URL(string: $0.serverURL)?.host?.lowercased()
        })
        // Docker registry hosts the profile has creds for. "docker.io" is a
        // user-facing alias for the real Hub endpoints, so expand it.
        var dockerHosts = Set<String>()
        for reg in profile.dockerRegistries {
            let h = reg.host.lowercased()
            if h == "docker.io" || h == "index.docker.io" || h == "registry-1.docker.io" {
                dockerHosts.formUnion(["docker.io", "index.docker.io",
                                       "registry-1.docker.io", "auth.docker.io"])
            } else {
                dockerHosts.insert(h)
            }
        }
        // HTTPS-database guardrails: each configured endpoint contributes its
        // engine + (user-specified) host + per-endpoint mode.
        let databases = profile.httpDatabases.compactMap { db -> GuardrailsConfig.DBGuardrail? in
            let host = db.host.lowercased().trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, db.guardrail != .off else { return nil }
            return GuardrailsConfig.DBGuardrail(engine: db.engine, host: host, mode: db.guardrail)
        }
        let g = profile.guardrails
        var config = GuardrailsConfig(kubernetes: g.kubernetes, kubeHosts: kubeHosts,
                                      aws: g.aws,
                                      digitalOcean: g.digitalOcean,
                                      docker: g.docker, dockerHosts: dockerHosts,
                                      github: g.github, gitlab: g.gitlab, bitbucket: g.bitbucket,
                                      databases: databases,
                                      egressPolicy: profile.resolvedEgressPolicy,
                                      allowInsecureBypass: g.allowInsecureBypass)
        config.exfiltrationAlertsDisabled = profile.disableExfiltrationAlerts
        config.strictCredentials = profile.effectiveStrictCredentials
        return config
    }
}
