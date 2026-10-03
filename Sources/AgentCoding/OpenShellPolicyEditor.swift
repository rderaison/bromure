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
    @State private var showHistory = false
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
                if draft.effectiveStrictSandbox, !unbound.isEmpty {
                    Label("Binary identity is enforced, so rules without binaries allow nothing: " + unbound.joined(separator: ", "),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(p.warnings.filter { !(draft.effectiveStrictSandbox && $0.hasPrefix("binaries:")) }, id: \.self) { w in
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
            guestSandboxSection

            providersSection

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Use OpenShell credential placeholders", isOn: $draft.openShellCredentialPlaceholders)
                Text("The agent sees `openshell:resolve:env:NAME` in its environment instead of Bromure's look-alike tokens, for the credentials this workspace passes as environment variables. The proxy swaps in the real value in request headers, and in request bodies or WebSocket messages only where an endpoint sets `request_body_credential_rewrite` or `websocket_credential_rewrite`. Each credential still works only on its own hosts. Some tools check a token's format and may reject a placeholder. Takes effect at the next VM start.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            advisorSection

            historySection

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
            Toggle("Enforce binaries (strict sandbox)", isOn: Binding(
                get: { draft.strictSandbox || draft.policyHasProcessSection },
                set: { draft.strictSandbox = $0 }))
                .disabled(OpenShellGovernance.shared.managed?.requireStrictSandbox == true || draft.policyHasProcessSection)
            if OpenShellGovernance.shared.managed?.requireStrictSandbox == true {
                Text("Required by your organization.").font(.caption2.weight(.medium))
            } else if draft.policyHasProcessSection {
                Text("Required by the policy's process section.").font(.caption2.weight(.medium))
            }
            Text("Rules then apply only to the executables they list (or to processes those start), as reported for every connection by a root-owned attestor in the VM. To make that report trustworthy, agents get no path to root: no sudo, no Docker, and all traffic goes through transparent interception (the proxy environment variables are removed). Each executable's hash is pinned on first use; a changed binary is refused. Takes effect at the next VM start.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if draft.effectiveStrictSandbox {
                Text("Status: " + (BinaryIdentityService.shared.isAttestorConnected(draft.id)
                                   ? "attestor connected — binaries are enforced"
                                   : "attestor not connected — until it is, only Bromure's own rules apply"))
                    .font(.caption2.weight(.medium))
            }
        }
    }

    /// OpenShell's filesystem_policy / landlock / process, enforced in the
    /// VM, and the kernel sentry that watches it from kernel space.
    @ViewBuilder private var guestSandboxSection: some View {
        let floor = OpenShellGovernance.shared.managed?.minKernelSentry.flatMap(KernelSentryMode.init(rawValue:)) ?? .off
        let sections = OpenShellSandboxSpec(policyYAML: draft.networkPolicy, workdirs: [], strictSandbox: false, sentry: "off")
        VStack(alignment: .leading, spacing: 4) {
            Text("Filesystem & process sandbox").font(.subheadline.weight(.semibold))
            if sections.filesystemPolicy == nil && sections.process == nil {
                Text("This policy has no filesystem_policy or process section, so the VM runs as usual. Add them to confine the agent to the paths you list (Landlock) and run it as a non-root user.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Insert an OpenShell filesystem template") { insertFilesystemTemplate() }
                    .font(.caption)
            } else {
                Text("Enforced inside the VM with Landlock, as OpenShell does: the agent can only read and write the paths the policy lists, and can't lift that, even as root. Only the few paths Bromure's own plumbing needs are added, and they're listed once the VM reports in. Takes effect at the next VM start.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if draft.effectiveStrictSandbox {
                    Text("With the strict sandbox, the agent also runs without sudo, under OpenShell's seccomp filters, so it can't interfere with Bromure's own processes in the VM.")
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Without the strict sandbox the agent keeps sudo: files stay confined, but the agent could stop Bromure's own processes in the VM. Turn on the strict sandbox (or add a process section) for the full OpenShell sandbox.")
                        .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let st = GuestSandboxStatusStore.shared.status(for: draft.id) {
                Text("Status: filesystem \(st.filesystem)"
                     + (st.degradedReason.map { " (\($0))" } ?? "")
                     + (st.runAsUser.map { " · runs as \($0)" } ?? "")
                     + (st.landlockABI.map { " · Landlock ABI \($0)" } ?? ""))
                    .font(.caption2.weight(.medium))
                if st.strictApplied == false {
                    Text("⚠︎ The strict sandbox didn't fully apply in the VM, so no session will start and binary rules fail closed. See the warnings below; restarting the VM retries it.")
                        .font(.caption2.weight(.medium)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
                if st.sentry == "unavailable", draft.effectiveKernelSentry != .off {
                    Text("⚠︎ Kernel sentry couldn't start" + (st.sentryReason.map { ": \($0)" } ?? "."))
                        .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(st.warnings, id: \.self) { w in
                    Text("⚠︎ " + w).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                if !st.additionsReadWrite.isEmpty || !st.additionsReadOnly.isEmpty {
                    Text("Added for Bromure: " + (st.additionsReadWrite.map { "\($0) (rw)" } + st.additionsReadOnly.map { "\($0) (ro)" })
                        .joined(separator: ", "))
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            Picker("Kernel sentry", selection: $draft.kernelSentry) {
                Text("Off").tag(KernelSentryMode.off).disabled(floor.rank > KernelSentryMode.off.rank)
                Text("Best effort").tag(KernelSentryMode.bestEffort).disabled(floor.rank > KernelSentryMode.bestEffort.rank)
                Text("Required").tag(KernelSentryMode.hard)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)
            if draft.effectiveKernelSentry == .off, sections.filesystemPolicy != nil || sections.process != nil {
                Text("Turn the kernel sentry on to see each denied file operation and blocked system call on the Security Timeline, and to be alerted when an agent keeps probing the sandbox's limits.")
                    .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if floor != .off {
                Text("Your organization requires at least “\(floor == .hard ? "Required" : "Best effort")”.").font(.caption2.weight(.medium))
            }
            Text("Streams security events (process launches, privilege changes, module and BPF loads, sandbox denials) from the VM's kernel to Bromure, outside anything the agent can stop; after it starts, the kernel is locked so not even root in the VM can load code to interfere. Silence or a gap in the stream is treated as tampering by the watchdog. “Required” won't start agent sessions without it. Takes effect at the next VM start.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Don't intercept container traffic", isOn: $draft.containerTrafficDirect)
                    .disabled(draft.effectiveKernelSentry == .off)
                Text("Traffic from containers in this VM (Docker, pods) goes out directly instead of through Bromure's proxy. The firewall still applies, and image pulls are still checked. Inside containers you lose credential brokering (Bromure's stand-in tokens aren't swapped for real ones), package checks, prompt-injection and PII scanning, and per-request logs. The kernel sentry marks container traffic in a way processes in the VM can't fake, so this needs the sentry on; without it, container traffic is intercepted as usual. Takes effect at the next VM start.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if draft.containerTrafficDirect, draft.effectiveKernelSentry != .off, !draft.effectiveContainerTrafficDirect {
                    Text("Not applied: this policy has request-level (L7) rules, which only the proxy can enforce, so container traffic stays intercepted.")
                        .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            if draft.effectiveKernelSentry != .off, let snap = KernelSentryService.shared.snapshot(draft.id) {
                Text("Sentry: " + (snap.connected ? "connected" + (snap.kernel.map { " · kernel \($0)" } ?? "") : "not connected")
                     + (snap.dropped > 0 ? " · \(snap.dropped) event(s) dropped under load" : ""))
                    .font(.caption2.weight(.medium))
            }
        }
    }

    /// Append an OpenShell-style filesystem / landlock / process block (the
    /// shape OpenShell's own default policy uses) for the user to edit.
    private func insertFilesystemTemplate() {
        let template = """

        # Filesystem sandbox (OpenShell): the paths OpenShell's own example
        # policies use, with the workload home (/sandbox there) at
        # /home/ubuntu. The agent may read the system and write only its
        # home, its project folders (include_workdir) and /tmp.
        filesystem_policy:
          include_workdir: true
          read_only: [/bin, /usr, /lib, /proc, /dev/urandom, /etc, /var/log]
          read_write: [/home/ubuntu, /tmp, /dev/null]
        landlock:
          compatibility: best_effort

        """
        var text = draft.networkPolicy
        if !text.hasSuffix("\n") { text += "\n" }
        draft.networkPolicy = text + template
    }

    /// The policy advisor: mode, and the proposals waiting for a decision.
    /// Saved versions of this policy (identical saves keep the version).
    /// Restore loads one into the editor; saving it records a new version.
    @ViewBuilder private var historySection: some View {
        let revisions = PolicyHistory.shared.revisions(in: ProfileStore().profileDirectory(for: draft)).reversed()
        DisclosureGroup(isExpanded: $showHistory) {
            if revisions.isEmpty {
                Text("No saved versions yet. Each save that changes the policy is kept here.")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(revisions), id: \.version) { r in
                        HStack(spacing: 8) {
                            Text("v\(r.version)").font(.caption.monospacedDigit().weight(.semibold))
                            Text(r.savedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2)
                            Text(r.source).font(.caption2).foregroundStyle(.secondary)
                            Text(String(r.hash.prefix(12))).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            Spacer()
                            if r.policy == draft.networkPolicy {
                                Text("current").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                            } else {
                                Button("Restore") { draft.networkPolicy = r.policy }
                                    .font(.caption).buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
        } label: {
            Text("Revision history" + (revisions.first.map { " · v\($0.version)" } ?? ""))
                .font(.subheadline.weight(.semibold))
        }
    }

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
