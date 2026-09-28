import AppKit
import SwiftUI
import SandboxEngine
import UniformTypeIdentifiers

/// The workspace firewall: either Bromure's pf-style rule table or an NVIDIA
/// OpenShell sandbox policy (YAML). The two are exclusive — a non-empty
/// `networkPolicy` replaces `egressRules` at every enforcement point.
struct FirewallEditor: View {
    @Binding var draft: Profile

    private enum Mode: Hashable { case rules, openShell }
    @State private var mode: Mode = .rules
    @State private var loaded = false
    @State private var confirmDiscard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Firewall", selection: Binding(get: { mode }, set: switchMode)) {
                Text("Bromure rules").tag(Mode.rules)
                Text("OpenShell policy").tag(Mode.openShell)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)

            switch mode {
            case .rules:     EgressRulesEditor(pfText: $draft.egressRules)
            case .openShell: OpenShellPolicyEditor(draft: $draft)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            mode = draft.usesOpenShellPolicy ? .openShell : .rules
        }
        .confirmationDialog("Switch back to Bromure rules?", isPresented: $confirmDiscard) {
            Button("Discard OpenShell policy", role: .destructive) {
                draft.networkPolicy = ""
                mode = .rules
            }
        } message: {
            Text("The workspace's OpenShell policy will be removed. Export it first if you want to keep it.")
        }
    }

    private func switchMode(_ new: Mode) {
        guard new != mode else { return }
        switch new {
        case .openShell:
            if !draft.usesOpenShellPolicy {
                draft.networkPolicy = OpenShellGovernance.shared.managed?.defaultPolicyYAML ?? OpenShellPolicyEditor.starterPolicy
            }
            mode = .openShell
        case .rules:
            if draft.usesOpenShellPolicy { confirmDiscard = true } else { mode = .rules }
        }
    }
}

/// YAML editor for an OpenShell policy with live validation, the list of
/// accepted-but-unenforced fields, and the provider rules Bromure adds.
struct OpenShellPolicyEditor: View {
    @Binding var draft: Profile
    @State private var showProviders = false
    @State private var pendingProvider: PendingProvider?
    @State private var importError: String?
    @State private var proposals: [OpenShellAdvisor.Proposal] = []
    @State private var rejectReasons: [String: String] = [:]
    @State private var boundaryTick = 0

    /// A provider profile picked for import, waiting for its secrets.
    struct PendingProvider: Identifiable {
        let id = UUID()
        let yaml: String
        let profile: OpenShellProviderProfile
        var instanceName: String
        var values: [String: String] = [:]
    }

    private var parsed: Result<OpenShellPolicy, Error> {
        Result { try OpenShellPolicy.parse(draft.networkPolicy) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Outbound connections (OpenShell policy)").font(.headline)
            Text("An [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) sandbox policy, schema version 1. Everything is denied unless a `network_policies` rule allows it; endpoints with a `protocol` are inspected request by request (`enforce` blocks, `audit` only records). Enforced host-side at the network switch and the proxy, and every decision is recorded in the Security Timeline. Applies live, no restart.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $draft.networkPolicy)
                .font(.system(.callout, design: .monospaced))
                .autocorrectionDisabled()
                .frame(minHeight: 260)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))

            switch parsed {
            case .failure(let e):
                Label("\(e)", systemImage: "xmark.octagon.fill")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            case .success(let p):
                Label("Valid policy · \(p.networkPolicies.count) network rule\(p.networkPolicies.count == 1 ? "" : "s")",
                      systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.green)
                let unbound = p.networkPolicies.filter { $0.binaries.isEmpty }.map(\.key)
                if draft.strictSandbox, !unbound.isEmpty {
                    Label("Binary identity is enforced, so rules without binaries allow nothing: " + unbound.joined(separator: ", "),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(p.warnings.filter { !(draft.strictSandbox && $0.hasPrefix("binaries:")) }, id: \.self) { w in
                    Label(w, systemImage: "info.circle")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 12) {
                Button { importPolicy() } label: { Label("Import…", systemImage: "square.and.arrow.down") }
                Button { exportPolicy() } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                Button { draft.networkPolicy = Self.starterPolicy } label: {
                    Label("Reset to starter policy", systemImage: "arrow.counterclockwise")
                }
            }
            .buttonStyle(.borderless)

            boundarySection

            strictSandboxSection

            providersSection

            advisorSection

            DisclosureGroup(isExpanded: $showProviders) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(draft.openShellProviderGroups.filter { !$0.endpoints.isEmpty }, id: \.name) { g in
                        Text("_provider_\(g.name): " + g.endpoints.map { e in
                            e.ports == [443] ? e.host : "\(e.host):\(e.ports.map(String.init).joined(separator: ","))"
                        }.joined(separator: ", "))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("Rules Bromure adds automatically").font(.caption)
            }
            Text("Like OpenShell's provider rules, these keep the workspace's agents and every credential it configures reachable. They're not part of the exported policy.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The organization boundary: where it comes from, and whether this
    /// policy fits inside it.
    @ViewBuilder private var boundarySection: some View {
        let gov = OpenShellGovernance.shared
        VStack(alignment: .leading, spacing: 4) {
            Text("Organization boundary").font(.subheadline.weight(.semibold))
            if gov.boundaryYAML == nil {
                Text("None. A boundary is the most any workspace's policy may allow; it's checked with NVIDIA's openshell-prover when installed, otherwise with Bromure's built-in check.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(gov.boundaryIsManaged ? "Set by your organization (bromure.io)." : "Set on this Mac.")
                    .font(.caption2).foregroundStyle(.secondary)
                if let r = gov.check(policyYAML: draft.networkPolicy, providerRules: draft.openShellProviderRules) {
                    Label(r.summary, systemImage: r.passed ? "checkmark.shield.fill" : "xmark.shield.fill")
                        .font(.caption).foregroundStyle(r.passed ? .green : .red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !gov.boundaryIsManaged {
                HStack(spacing: 12) {
                    Button { pickBoundary() } label: { Label("Set boundary from file…", systemImage: "square.and.arrow.down") }
                    if gov.boundaryYAML != nil {
                        Button("Clear boundary") { gov.setLocalBoundary(nil); boundaryTick += 1 }
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        .id(boundaryTick)
    }

    private func pickBoundary() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "yaml"), UTType(filenameExtension: "yml"), .plainText]
            .compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        do {
            _ = try OpenShellPolicy.parse(text)
            OpenShellGovernance.shared.setLocalBoundary(text)
            importError = nil
        } catch {
            importError = "Boundary rejected: \(error)"
        }
        boundaryTick += 1
    }

    /// Binary identity: the strict sandbox that makes `binaries` enforceable.
    @ViewBuilder private var strictSandboxSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Enforce binaries (strict sandbox)", isOn: $draft.strictSandbox)
                .disabled(OpenShellGovernance.shared.managed?.requireStrictSandbox == true)
            if OpenShellGovernance.shared.managed?.requireStrictSandbox == true {
                Text("Required by your organization.").font(.caption2.weight(.medium))
            }
            Text("Rules then apply only to the executables they list (or to processes those start), as reported for every connection by a root-owned attestor in the VM. To make that report trustworthy, agents get no path to root: no sudo, no Docker, and all traffic goes through transparent interception (the proxy environment variables are removed). Each executable's hash is pinned on first use; a changed binary is refused. Takes effect at the next VM start.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if draft.strictSandbox {
                Text("Status: " + (BinaryIdentityService.shared.isAttestorConnected(draft.id)
                                   ? "attestor connected — binaries are enforced"
                                   : "attestor not connected — until it is, only Bromure's own rules apply"))
                    .font(.caption2.weight(.medium))
            }
        }
    }

    /// The policy advisor: mode, and the proposals waiting for a decision.
    @ViewBuilder private var advisorSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Policy advisor").font(.subheadline.weight(.semibold))
            Picker("Agent proposals", selection: $draft.openShellAdvisorMode) {
                Text("Off").tag(OpenShellAdvisorMode.off.rawValue)
                Text("Ask me").tag(OpenShellAdvisorMode.review.rawValue)
                Text("Approve if risk-free").tag(OpenShellAdvisorMode.auto.rawValue)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)
            Text("When a request is blocked, the agent can propose the narrow rule it needs at http://policy.local (OpenShell's advisor API) and wait for your decision. Blocked connections are also drafted as proposals here. A proposal that reaches a host with a workspace credential, adds a method there, or uses a wildcard, private address, database or high port always waits for you; “Approve if risk-free” approves the rest. Approved rules are added to the policy above and apply live.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            let pending = proposals.filter { $0.status == .pending }
            if pending.isEmpty {
                Text("No pending proposals.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(pending) { p in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: p.source == "mechanistic" ? "wand.and.stars" : "person.crop.circle.badge.questionmark")
                        Text("\(p.rule.key) — \(p.host):\(p.port)").font(.callout.weight(.medium))
                        Spacer()
                        Text(p.source == "mechanistic" ? "drafted from a block" : "proposed by the agent")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if !p.intent.isEmpty { Text(p.intent).font(.caption) }
                    Text(p.yaml).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                        .padding(6).background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.08)))
                    if !p.findings.isEmpty {
                        Label(p.findings.joined(separator: ", "), systemImage: "exclamationmark.shield")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    HStack {
                        TextField("Reason (sent to the agent on reject)", text: Binding(
                            get: { rejectReasons[p.id] ?? "" }, set: { rejectReasons[p.id] = $0 }))
                            .textFieldStyle(.roundedBorder).font(.caption)
                        Button("Reject") {
                            OpenShellAdvisor.shared.reject(id: p.id, profileID: draft.id, reason: rejectReasons[p.id] ?? "")
                        }
                        Button("Approve") {
                            let id = p.id, pid = draft.id
                            Task { await OpenShellAdvisor.shared.approve(id: id, profileID: pid) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            }
            let decided = proposals.filter { $0.status != .pending }.suffix(5)
            if !decided.isEmpty {
                Text("Recent decisions").font(.caption.weight(.medium)).padding(.top, 2)
                ForEach(Array(decided.reversed())) { p in
                    Text("\(p.status == .approved ? "✓" : "✗") \(p.rule.key) (\(p.host):\(p.port))"
                         + (p.auto ? " — auto" : "") + (p.rejectionReason.map { " — \($0)" } ?? ""))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { proposals = OpenShellAdvisor.shared.proposals(for: draft.id) }
        .onReceive(NotificationCenter.default.publisher(for: OpenShellAdvisor.changedNotification)) { _ in
            proposals = OpenShellAdvisor.shared.proposals(for: draft.id)
            // An approval appended its rule to the SAVED policy. Mirror it into
            // this draft (keeping any unsaved edits) so saving the editor
            // doesn't drop the approved rule.
            let draftKeys = Set(((try? OpenShellPolicy.parse(draft.networkPolicy))?.networkPolicies ?? []).map(\.key))
            for p in proposals where p.status == .approved && !draftKeys.contains(p.rule.key) {
                if let merged = try? OpenShellPolicy.insertingRules(p.yaml, into: draft.networkPolicy) {
                    draft.networkPolicy = merged
                }
            }
        }
    }

    /// Attached OpenShell provider profiles: their credentials become
    /// workspace credentials bound to the profile's endpoints, and their
    /// endpoints a `_provider_<name>` rule.
    @ViewBuilder private var providersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Provider profiles").font(.subheadline.weight(.semibold))
            Text("Import an OpenShell provider profile to add its credentials to this workspace. Bromure keeps the real values on the Mac, gives the VM stand-ins, and only swaps them in on the profile's endpoints (hosts and paths); the profile's endpoints are added as a rule.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(draft.openShellProviders) { a in
                let parsed = try? OpenShellProviderProfile.parse(a.profileYAML)
                HStack {
                    Image(systemName: "key.horizontal")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(a.instanceName) · \(parsed?.displayName ?? "unknown profile")").font(.callout)
                        Text((parsed?.credentialHostScopes ?? []).joined(separator: ", "))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { detachProvider(a) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                }
            }
            Button { pickProviderProfile() } label: { Label("Attach provider profile…", systemImage: "plus") }
                .buttonStyle(.borderless)
            if let importError {
                Label(importError, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
            }
        }
        .sheet(item: $pendingProvider) { _ in providerSheet }
    }

    @ViewBuilder private var providerSheet: some View {
        if let p = pendingProvider {
            VStack(alignment: .leading, spacing: 12) {
                Text("Attach \(p.profile.displayName)").font(.headline)
                if !p.profile.description.isEmpty {
                    Text(p.profile.description).font(.caption).foregroundStyle(.secondary)
                }
                TextField("Instance name", text: Binding(
                    get: { pendingProvider?.instanceName ?? "" },
                    set: { pendingProvider?.instanceName = $0 }))
                ForEach(p.profile.credentials, id: \.name) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name + (c.required ? " *" : "")
                             + (c.envVars.isEmpty ? "" : "  (" + c.envVars.joined(separator: ", ") + ")"))
                            .font(.caption.weight(.medium))
                        SecureField(c.description.isEmpty ? "Value" : c.description, text: Binding(
                            get: { pendingProvider?.values[c.name] ?? "" },
                            set: { pendingProvider?.values[c.name] = $0 }))
                    }
                }
                Text("Bound to: " + (p.profile.credentialHostScopes.joined(separator: ", "))
                     + (p.profile.credentialPathScopes.isEmpty ? "" : " — paths " + p.profile.credentialPathScopes.joined(separator: ", ")))
                    .font(.caption2).foregroundStyle(.secondary)
                ForEach(p.profile.warnings, id: \.self) { w in
                    Label(w, systemImage: "info.circle").font(.caption2).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Cancel") { pendingProvider = nil }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Attach") { attachPendingProvider() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canAttach(p))
                }
            }
            .padding(20)
            .frame(width: 440)
        }
    }

    private func canAttach(_ p: PendingProvider) -> Bool {
        let name = p.instanceName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !draft.openShellProviders.contains(where: { $0.instanceName == name }) else { return false }
        return p.profile.credentials.allSatisfy { !$0.required || !(p.values[$0.name] ?? "").isEmpty }
    }

    private func pickProviderProfile() {
        importError = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "yaml"), UTType(filenameExtension: "yml"),
                                     .json, .plainText].compactMap { $0 }
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        do {
            let profile = try OpenShellProviderProfile.parse(text)
            guard !profile.endpoints.isEmpty else {
                importError = "“\(profile.displayName)” declares no endpoints, so its credentials would have nowhere to be used."
                return
            }
            var name = profile.id
            var n = 2
            while draft.openShellProviders.contains(where: { $0.instanceName == name }) { name = "\(profile.id)-\(n)"; n += 1 }
            pendingProvider = PendingProvider(yaml: text, profile: profile, instanceName: name)
        } catch {
            importError = "\(error)"
        }
    }

    private func attachPendingProvider() {
        guard let p = pendingProvider, canAttach(p) else { return }
        var ids: [UUID] = []
        for c in p.profile.credentials {
            let value = (p.values[c.name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            let token = ManualToken(name: "\(p.instanceName) · \(c.name)", realValue: value,
                                    envVarName: c.envVars.first ?? "",
                                    hostFilters: p.profile.credentialHostScopes,
                                    pathFilters: p.profile.credentialPathScopes,
                                    envVarAliases: Array(c.envVars.dropFirst()))
            draft.manualTokens.append(token)
            ids.append(token.id)
        }
        draft.openShellProviders.append(OpenShellProviderAttachment(
            instanceName: p.instanceName.trimmingCharacters(in: .whitespaces), profileYAML: p.yaml, tokenIDs: ids))
        pendingProvider = nil
    }

    private func detachProvider(_ a: OpenShellProviderAttachment) {
        draft.manualTokens.removeAll { a.tokenIDs.contains($0.id) }
        draft.openShellProviders.removeAll { $0.id == a.id }
    }

    private func importPolicy() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "yaml"), UTType(filenameExtension: "yml"), .plainText]
            .compactMap { $0 }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        draft.networkPolicy = text
    }

    private func exportPolicy() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(draft.name.isEmpty ? "workspace" : draft.name)-policy.yaml"
        panel.allowedContentTypes = [UTType(filenameExtension: "yaml") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? draft.networkPolicy.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A working default for a coding agent: source hosting and the package
    /// registries, read-only where uploads are the risk. The agent's own
    /// services and credentialed hosts come from the provider layer.
    static let starterPolicy = """
    version: 1

    # OpenShell sandbox policy — https://github.com/NVIDIA/OpenShell
    # Everything not listed is denied. Bromure also allows the workspace's
    # agents and every host it injects a credential for (_provider_* rules).
    network_policies:
      github:
        endpoints:
          - { host: github.com, port: 443 }
          - { host: api.github.com, port: 443 }
          - { host: "**.githubusercontent.com", port: 443 }

      npm:
        endpoints:
          - host: registry.npmjs.org
            port: 443
            protocol: rest
            enforcement: enforce
            access: read-only          # installs work; publish is blocked
            allow_encoded_slash: true  # scoped packages (@types%2Fnode)

      pypi:
        endpoints:
          - { host: pypi.org, port: 443, protocol: rest, enforcement: enforce, access: read-only }
          - { host: files.pythonhosted.org, port: 443, protocol: rest, enforcement: enforce, access: read-only }

      ubuntu_apt:
        endpoints:
          - { host: ports.ubuntu.com, ports: [80, 443] }
          - { host: security.ubuntu.com, ports: [80, 443] }

    """
}
