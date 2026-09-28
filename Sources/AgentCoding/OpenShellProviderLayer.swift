#if canImport(SandboxEngine)
import Foundation
import SandboxEngine

/// The OpenShell "provider layer" for a workspace: destinations Bromure itself
/// makes the agent depend on, added to the authored policy as `_provider_*`
/// rules exactly like OpenShell composes attached providers. Without it, a
/// default-deny policy would cut the agent off from its own model API, and
/// every credential the workspace configures would be unusable.
extension Profile {
    /// The workspace's effective egress policy under an OpenShell policy. A
    /// policy that fails to parse fails closed: only the provider layer is
    /// reachable (matching OpenShell's default `fail_closed` load mode).
    var resolvedOpenShellEgressPolicy: EgressPolicy {
        let governance = OpenShellGovernance.shared
        // No policy of its own: the organization boundary is the policy.
        let source = usesOpenShellPolicy ? networkPolicy : (governance.boundaryYAML ?? "")
        var base: OpenShellPolicy
        do {
            base = try OpenShellPolicy.parse(source)
        } catch {
            FileHandle.standardError.write(Data(
                "[egress] OpenShell policy for \(name) rejected, failing closed: \(error)\n".utf8))
            base = OpenShellPolicy(networkPolicies: [], source: source, warnings: [])
        }
        if usesOpenShellPolicy,
           let result = governance.check(policyYAML: networkPolicy, providerRules: openShellProviderRules),
           !result.passed {
            FileHandle.standardError.write(Data(
                "[egress] OpenShell policy for \(name) is outside the organization boundary (\(result.summary)); failing closed\n".utf8))
            base = OpenShellPolicy(networkPolicies: [], source: source, warnings: [])
        }
        var policy = EgressPolicy(openShell: base.withProviderLayer(openShellProviderGroups)
            .withRules(openShellProviderRules))
        // Strict sandbox: a root attestor names each connection's executable,
        // so the policy's `binaries` are enforced instead of advisory.
        policy.enforceBinaries = effectiveStrictSandbox
        return policy
    }

    /// `_provider_<instance>` rules from attached OpenShell provider profiles,
    /// with their full endpoint configuration (protocol, rules, enforcement).
    var openShellProviderRules: [OpenShellPolicy.NetworkRule] {
        openShellProviders.compactMap { a in
            (try? OpenShellProviderProfile.parse(a.profileYAML))?.networkRule(instanceName: a.instanceName)
        }
    }

    /// Provider rules, one group per concern so the Security Timeline names
    /// which one admitted a flow (`_provider_claude`, `_provider_credentials`…).
    var openShellProviderGroups: [(name: String, endpoints: [OpenShellPolicy.ProviderEndpoint])] {
        var groups: [(name: String, endpoints: [OpenShellPolicy.ProviderEndpoint])] = []

        // The agents' own services (model API, sign-in, account, updates).
        for spec in allToolSpecs where spec.authMode != .local {
            let domains: [String]
            switch spec.tool {
            case .claude: domains = ["anthropic.com", "claude.ai", "claude.com"]
            case .codex:  domains = ["openai.com", "chatgpt.com"]
            case .grok:   domains = ["x.ai"]
            case .kimi:   domains = ["kimi.ai", "kimi.com", "moonshot.ai", "moonshot.cn"]
            case .omp:    domains = []          // provider-switchable: covered by its credential host
            }
            groups.append((spec.tool.rawValue, domains.flatMap(Self.domainEndpoints)))
        }

        // Every host Bromure injects a configured credential on.
        let plan = makeTokenPlan(salt: Data())
        let scopes = Array(Set(plan.credentialHostScopes)).sorted()
        groups.append(("credentials", scopes.flatMap(Self.domainEndpoints)))

        // Kubernetes API servers from imported kubeconfigs (their ports vary,
        // and 6443 would otherwise hit the control-plane-port block).
        let kube: [OpenShellPolicy.ProviderEndpoint] = kubeconfigs.compactMap {
            guard let u = URL(string: $0.serverURL), let h = u.host else { return nil }
            return .init(host: h, ports: [UInt16(u.port ?? 443)])
        }
        groups.append(("kubernetes", kube))

        if awsCredentials.isUsable {
            groups.append(("aws", Self.domainEndpoints("amazonaws.com")))
        }

        // Local Models: the in-VM sentinel never leaves this Mac.
        groups.append(("local_models", [.init(host: InferenceService.localMitmHost)]))
        return groups
    }

    /// A credential scope is a domain matched exact-or-subdomain, so it maps
    /// to the apex plus a `**.` wildcard (valid only with ≥ 3 labels).
    private static func domainEndpoints(_ domain: String) -> [OpenShellPolicy.ProviderEndpoint] {
        let d = domain.lowercased()
        var out: [OpenShellPolicy.ProviderEndpoint] = [.init(host: d)]
        if d.split(separator: ".").count >= 2 { out.append(.init(host: "**." + d)) }
        return out
    }
}
#endif
