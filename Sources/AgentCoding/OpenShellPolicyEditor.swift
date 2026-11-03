import AppKit
import SwiftUI
import SandboxEngine
import UniformTypeIdentifiers

/// The workspace's sandbox engine: Bromure's firewall (a pf-style rule
/// table) or an NVIDIA OpenShell policy (YAML) enforced with the guest
/// sandbox and watched by the kernel sentry. The two are exclusive — a
/// non-empty `networkPolicy` replaces `egressRules` at every enforcement
/// point — and the sentry comes with the OpenShell engine.
struct FirewallEditor: View {
    @Binding var draft: Profile
    var onEdited: ((String) -> Void)? = nil

    private enum Engine: Hashable { case firewall, openShell }
    @State private var engine: Engine = .firewall
    @State private var loaded = false
    @State private var confirmDiscard = false
    @StateObject private var sentryFloor = KernelSentryFloorWatch()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PolicyCard(nil) {
                HStack(alignment: .center, spacing: 14) {
                    PolicyIcon(system: engine == .openShell ? "cube.transparent.fill" : "flame.fill",
                               tint: engine == .openShell ? .teal : .red, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sandbox engine").font(.headline)
                        Text(engine == .openShell
                             ? "An NVIDIA OpenShell policy, enforced in the VM and watched by the kernel sentry."
                             : "Allow or deny the VM's connections by host, address, protocol and port.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Picker("Sandbox engine", selection: Binding(get: { engine }, set: switchEngine)) {
                        Text("Bromure Firewall").tag(Engine.firewall)
                        Text("OpenShell + Sentry").tag(Engine.openShell)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }

            switch engine {
            case .firewall:
                PolicyCard("Outbound rules", icon: "list.bullet.rectangle", tint: .red) {
                    EgressRulesEditor(pfText: $draft.egressRules, profileID: draft.id,
                                      logAllowed: $draft.logAllowedConnections,
                                      onEdited: onEdited, showsHeader: false)
                }
                // Left on from before the sentry came with the OpenShell engine
                // — or required by the organization, which turning it off
                // can't go below.
                switch Self.firewallSentryCard(draft, floor: sentryFloor.floor) {
                case .none:
                    EmptyView()
                case .canTurnOff:
                    PolicyCard(nil) {
                        PolicyRow(title: "Kernel sentry is still on",
                                  caption: "It belongs to the OpenShell engine now.") {
                            Button("Turn off") { draft.kernelSentry = .off }
                        }
                    }
                case .required(let floor):
                    PolicyCard(nil) {
                        PolicyRow(title: "Kernel sentry is still on",
                                  caption: "Your organization requires at least \(floor.label).") {
                            EmptyView()
                        }
                    }
                }
            case .openShell:
                OpenShellPolicyEditor(draft: $draft)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            engine = draft.usesOpenShellPolicy ? .openShell : .firewall
        }
        .confirmationDialog("Switch to the Bromure Firewall?", isPresented: $confirmDiscard) {
            Button("Discard OpenShell policy", role: .destructive) {
                draft.networkPolicy = ""
                draft.kernelSentry = .off
                engine = .firewall
            }
        } message: {
            Text(Self.discardMessage(floor: OpenShellGovernance.shared.kernelSentryFloor))
        }
    }

    private func switchEngine(_ new: Engine) {
        guard new != engine else { return }
        switch new {
        case .openShell:
            if !draft.usesOpenShellPolicy {
                draft.networkPolicy = OpenShellGovernance.shared.managed?.defaultPolicyYAML ?? OpenShellPolicyEditor.starterPolicy
            }
            if draft.kernelSentry == .off { draft.kernelSentry = .bestEffort }
            engine = .openShell
        case .firewall:
            if draft.usesOpenShellPolicy { confirmDiscard = true }
            else { draft.kernelSentry = .off; engine = .firewall }
        }
    }

    enum SentryCard: Equatable { case none, canTurnOff, required(KernelSentryMode) }

    /// The firewall pane's sentry card, from the mode that actually applies:
    /// nothing when it's off; "turn off" when the workspace's own setting
    /// is above the organization's minimum; the minimum otherwise.
    ///
    /// Turning it off (and leaving the OpenShell engine) stores `.off`, never
    /// the minimum: the minimum is applied where the sentry starts
    /// (`Profile.effectiveKernelSentry`) and follows the organization. A
    /// stored copy outlived it — a Turn off clicked after the minimum rose
    /// to Required kept the workspace on Required once it dropped again.
    /// (Finding CWE-670, "Firewall sentry card stays stale after the
    /// organization floor changes, and Turn off can save a higher mode".)
    static func firewallSentryCard(_ p: Profile, floor: KernelSentryMode) -> SentryCard {
        let applied = p.kernelSentry.rank >= floor.rank ? p.kernelSentry : floor
        if applied == .off { return .none }
        return p.kernelSentry.rank > floor.rank ? .canTurnOff : .required(floor)
    }

    /// What discarding the policy does to the sentry, as it will actually
    /// apply: off, unless the organization requires it.
    static func discardMessage(floor: KernelSentryMode) -> String {
        floor == .off
            ? NSLocalizedString("The workspace's OpenShell policy will be removed and the kernel sentry turned off. Export the policy first if you want to keep it.", comment: "discard OpenShell policy")
            : String(format: NSLocalizedString("The workspace's OpenShell policy will be removed. The kernel sentry stays on (%@): your organization requires it. Export the policy first if you want to keep it.", comment: "discard OpenShell policy, sentry floor"), floor.label)
    }
}

/// YAML editor for an OpenShell policy with live validation, the list of
/// accepted-but-unenforced fields, and the provider rules Bromure adds.
struct OpenShellPolicyEditor: View {
    @Binding var draft: Profile
    @State private var showProviders = false
    @State private var importError: String?
    @State private var proposals: [OpenShellAdvisor.Proposal] = []
    @State private var rejectReasons: [String: String] = [:]
    @State private var showHistory = false
    @State private var boundaryTick = 0

    private var parsed: Result<OpenShellPolicy, Error> {
        Result { try OpenShellPolicy.parse(draft.networkPolicy) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PolicyCard(title: "Policy", icon: "doc.text.fill", tint: .teal,
                       info: "An [NVIDIA OpenShell](https://github.com/NVIDIA/OpenShell) sandbox policy, schema version 1. Everything is denied unless a `network_policies` rule allows it; endpoints with a `protocol` are inspected request by request (`enforce` blocks, `audit` only records). Enforced host-side at the network switch and the proxy, and every decision is recorded in the Security Timeline. Applies live, no restart.") {
                HStack(spacing: 2) {
                    Button { importPolicy() } label: { Image(systemName: "square.and.arrow.down") }
                        .help(Text("Import…"))
                    Button { exportPolicy() } label: { Image(systemName: "square.and.arrow.up") }
                        .help(Text("Export…"))
                    Button { draft.networkPolicy = Self.starterPolicy } label: { Image(systemName: "arrow.counterclockwise") }
                        .help(Text("Reset to starter policy"))
                }
                .buttonStyle(.borderless)
            } content: {
                Text("Everything is denied unless a rule allows it. Applies live.")
                    .font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $draft.networkPolicy)
                    .font(.system(.callout, design: .monospaced))
                    .autocorrectionDisabled()
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 240)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
                validation
            }

            PolicyCard(title: "Kernel sentry", icon: "waveform.path.ecg", tint: .indigo,
                       info: "Streams security events (process launches, privilege changes, module and BPF loads, sandbox denials) from the VM's kernel to Bromure, outside anything the agent can stop; after it starts, the kernel is locked so not even root in the VM can load code to interfere. Silence or a gap in the stream is treated as tampering by the watchdog. “Required” won't start agent sessions without it. Takes effect at the next VM start.") {
                EmptyView()
            } content: {
                KernelSentrySection(draft: $draft)
            }

            PolicyCard(title: sandboxNeedsAttention ? "Sandbox ⚠︎" : "Sandbox", icon: "cube.transparent.fill",
                       tint: sandboxNeedsAttention ? .orange : .teal) {
                EmptyView()
            } content: {
                strictSandboxSection
                Divider()
                guestSandboxSection
                Divider()
                packagesSection
            }

            PolicyCard(title: "Policy advisor", icon: "wand.and.stars", tint: .purple,
                       info: "When a request is blocked, the agent can propose the narrow rule it needs at http://policy.local (OpenShell's advisor API) and wait for your decision. Blocked connections are also drafted as proposals here. A proposal that reaches a host with a workspace credential, adds a method there, or uses a wildcard, private address, database or high port always waits for you; “Approve if risk-free” approves the rest. Approved rules are added to the policy above and apply live.") {
                EmptyView()
            } content: {
                advisorSection
            }

            PolicyCard(title: "Governance", icon: "building.columns.fill", tint: .gray) {
                EmptyView()
            } content: {
                boundarySection
                Divider()
                historySection
                Divider()
                DisclosureGroup(isExpanded: $showProviders) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Like OpenShell's provider rules, these keep the workspace's agents and every credential it configures reachable. They're not part of the exported policy.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                    Text("Rules Bromure adds automatically")
                }
            }
        }
    }

    @ViewBuilder private var validation: some View {
        switch parsed {
        case .failure(let e):
            Label("\(e)", systemImage: "xmark.octagon.fill")
                .font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .success(let p):
            PolicyStatus(text: "Valid policy · \(p.networkPolicies.count) network rule\(p.networkPolicies.count == 1 ? "" : "s")",
                         tone: .ok)
            let unbound = p.networkPolicies.filter { $0.binaries.isEmpty }.map(\.key)
            if draft.effectiveStrictSandbox, !unbound.isEmpty {
                PolicyStatus(text: "Binary identity is enforced, so rules without binaries allow nothing: " + unbound.joined(separator: ", "),
                             tone: .warn)
            }
            ForEach(p.warnings.filter { !(draft.effectiveStrictSandbox && $0.hasPrefix("binaries:")) }, id: \.self) { w in
                PolicyStatus(text: w)
            }
        }
    }

    /// The VM reported the sandbox or the sentry not working as asked: the
    /// Sandbox group opens by itself so it's seen.
    private var sandboxNeedsAttention: Bool {
        GuestSandboxStatusStore.shared.status(for: draft.id)?
            .needsAttention(sentryExpected: draft.effectiveKernelSentry != .off) ?? false
    }

    /// The organization boundary: where it comes from, and whether this
    /// policy fits inside it.
    @ViewBuilder private var boundarySection: some View {
        let gov = OpenShellGovernance.shared
        VStack(alignment: .leading, spacing: 4) {
            PolicyRow(title: "Organization boundary",
                      caption: gov.boundaryYAML == nil ? "None set."
                          : gov.boundaryIsManaged ? "Set by your organization (bromure.io)." : "Set on this Mac.",
                      info: "A boundary is the most any workspace's policy may allow; it's checked with NVIDIA's openshell-prover when installed, otherwise with Bromure's built-in check.") {
                if !gov.boundaryIsManaged {
                    HStack(spacing: 8) {
                        if gov.boundaryYAML != nil {
                            Button("Clear") { gov.setLocalBoundary(nil); boundaryTick += 1 }
                        }
                        Button("Set from file…") { pickBoundary() }
                    }
                }
            }
            if gov.boundaryYAML != nil {
                if let r = gov.check(policyYAML: draft.networkPolicy, providerRules: draft.openShellProviderRules) {
                    Label(r.summary, systemImage: r.passed ? "checkmark.shield.fill" : "xmark.shield.fill")
                        .font(.caption).foregroundStyle(r.passed ? .green : .red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let importError {
                Label(importError, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
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
        let required = OpenShellGovernance.shared.managed?.requireStrictSandbox == true || draft.policyHasProcessSection
        VStack(alignment: .leading, spacing: 6) {
            PolicyRow(title: "Enforce binaries",
                      caption: OpenShellGovernance.shared.managed?.requireStrictSandbox == true ? "Required by your organization."
                          : draft.policyHasProcessSection ? "Required by the policy's process section."
                          : "Rules apply only to the programs they list; the agent loses sudo and Docker.",
                      info: "Rules then apply only to the executables they list (or to processes those start), as reported for every connection by a root-owned attestor in the VM. To make that report trustworthy, agents get no path to root: no sudo, no Docker, and all traffic goes through transparent interception (the proxy environment variables are removed). Each executable's hash is pinned on first use; a changed binary is refused. Takes effect at the next VM start.") {
                Toggle("Enforce binaries", isOn: Binding(
                    get: { draft.strictSandbox || draft.policyHasProcessSection },
                    set: { draft.strictSandbox = $0 }))
                    .labelsHidden().toggleStyle(.switch)
                    .disabled(required)
            }
            if draft.effectiveStrictSandbox {
                BinaryIdentityService.shared.isAttestorConnected(draft.id)
                    ? PolicyStatus(text: NSLocalizedString("Attestor connected: binaries are enforced", comment: "sandbox status"), tone: .ok)
                    : PolicyStatus(text: NSLocalizedString("Attestor not connected: until it is, only Bromure's own rules apply", comment: "sandbox status"), tone: .warn)
            }
        }
    }

    /// OpenShell's filesystem_policy / landlock / process, enforced in the
    /// VM, and the kernel sentry that watches it from kernel space.
    @ViewBuilder private var guestSandboxSection: some View {
        let sections = OpenShellSandboxSpec(policyYAML: draft.networkPolicy, workdirs: [], strictSandbox: false, sentry: "off")
        let confined = sections.confinesGuest
        VStack(alignment: .leading, spacing: 6) {
            PolicyRow(title: "Filesystem & process",
                      caption: confined ? "The agent can only reach the paths the policy lists."
                                        : "Not confined: the policy has no filesystem_policy or process section.",
                      info: "Enforced inside the VM with Landlock, as OpenShell does: the agent can only read and write the paths the policy lists, and can't lift that, even as root. Only the few paths Bromure's own plumbing needs are added, and they're listed once the VM reports in. Takes effect at the next VM start.") {
                if !confined {
                    Button("Insert template") { insertFilesystemTemplate() }
                        .help(Text("Insert an OpenShell filesystem template"))
                }
            }
            if confined, !draft.effectiveStrictSandbox {
                PolicyStatus(text: NSLocalizedString("The agent keeps sudo, so it could stop Bromure's processes in the VM. Turn on Enforce binaries to prevent that.", comment: "sandbox status"),
                             tone: .warn)
            }
            if let st = GuestSandboxStatusStore.shared.status(for: draft.id) {
                // Orange only for what didn't go as asked: a failed or
                // degraded ruleset, an `off` the guest says failed, or one
                // asked for and not in force yet — never the policy's own
                // "not configured" / "no paths configured".
                PolicyStatus(text: (st.filesystemNotYetApplied ? "Filesystem not applied yet" : "Filesystem \(st.filesystem)")
                                 + (st.degradedReason.map { " (\($0))" } ?? "")
                                 + (st.runAsUser.map { " · runs as \($0)" } ?? "")
                                 + (st.landlockABI.map { " · Landlock ABI \($0)" } ?? ""),
                             tone: st.filesystem == "failed" ? .bad
                                 : (st.filesystemFailed || st.filesystemOffUnasked || st.filesystemNotYetApplied) ? .warn : .ok)
                if st.strictApplied == false {
                    PolicyStatus(text: NSLocalizedString("The strict sandbox didn't fully apply in the VM, so no session will start and binary rules fail closed. Restarting the VM retries it.", comment: "sandbox status"),
                                 tone: .bad)
                }
                ForEach(st.warnings, id: \.self) { w in PolicyStatus(text: w, tone: .warn) }
                if !st.additionsReadWrite.isEmpty || !st.additionsReadOnly.isEmpty {
                    PolicyStatus(text: "Added for Bromure: " + (st.additionsReadWrite.map { "\($0) (rw)" } + st.additionsReadOnly.map { "\($0) (ro)" })
                        .joined(separator: ", "))
                }
            }
        }
    }

    /// Package installs: the sandbox has no root, so pip defaults to the home
    /// folder and `apt-get install` becomes a request for the user.
    @ViewBuilder private var packagesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            PolicyRow(title: "Packages in the home folder",
                      caption: "pip installs into ~/.local; npm already uses ~/.npm-global.",
                      info: "The sandbox has no root, so system-wide installs can't work. With this on, pip installs into the home folder by default (PIP_USER), and npm installs globally into ~/.npm-global as on every workspace. Bromure's own processes outside the sandbox ignore packages in the home folder. Takes effect in new terminals.") {
                Toggle("Packages in the home folder", isOn: $draft.sandboxHomePackages)
                    .labelsHidden().toggleStyle(.switch)
            }
            PolicyRow(title: "System packages on request",
                      caption: "apt-get install asks you first; the agent never gets root.",
                      info: "When the agent runs apt-get install (with or without sudo), the request waits in the Sandbox drawer. Approve it and the VM's root supervisor installs those packages — by exact name, from Ubuntu's mirrors, which Bromure allows for this. Reject it and the agent is told not to retry. Takes effect at the next VM start.") {
                Toggle("System packages on request", isOn: $draft.sandboxSystemPackages)
                    .labelsHidden().toggleStyle(.switch)
            }
        }
    }

    /// Append an OpenShell-style filesystem / landlock / process block (the
    /// shape OpenShell's own default policy uses) for the user to edit.
    private func insertFilesystemTemplate() {
        let template = """

        # Filesystem sandbox (OpenShell): the paths OpenShell's own example
        # policies use, with the workload home (/sandbox there) at
        # /home/ubuntu, plus /opt, where the Bromure image installs tools
        # (grok, bun for omp, gcloud). The agent may read the system and
        # write only its home, its project folders (include_workdir) and /tmp.
        filesystem_policy:
          include_workdir: true
          read_only: [/bin, /usr, /lib, /opt, /proc, /dev/urandom, /etc, /var/log]
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
        }
    }

    @ViewBuilder private var advisorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            PolicyRow(title: "Agent proposals",
                      caption: "When something is blocked, the agent can ask for the rule it needs.") {
                Picker("Agent proposals", selection: $draft.openShellAdvisorMode) {
                    Text("Off").tag(OpenShellAdvisorMode.off.rawValue)
                    Text("Ask me").tag(OpenShellAdvisorMode.review.rawValue)
                    Text("Approve if risk-free").tag(OpenShellAdvisorMode.auto.rawValue)
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }

            let pending = proposals.filter { $0.status == .pending }
            if pending.isEmpty {
                PolicyStatus(text: NSLocalizedString("No pending proposals.", comment: "policy advisor"))
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

/// The kernel sentry's mode and connection status. It comes
/// with the OpenShell engine, so there's no Off here: switching the engine
/// to the Bromure Firewall turns it off.
struct KernelSentrySection: View {
    @Binding var draft: Profile
    @StateObject private var sentryFloor = KernelSentryFloorWatch()

    var body: some View {
        let floor = sentryFloor.floor
        VStack(alignment: .leading, spacing: 10) {
            if draft.effectiveKernelSentry == .off {
                // A workspace set up before the sentry came with the engine.
                PolicyRow(title: "Off for this workspace",
                          caption: "Turn it on to see sandbox denials and which process made each connection.") {
                    Button("Turn on") { draft.kernelSentry = .bestEffort }
                }
            } else {
                PolicyRow(title: "Mode",
                          caption: floor == .hard ? "Your organization requires it."
                              : "Reports which process made each connection, and why, from where the agent can't stop it.") {
                    Picker("Kernel sentry", selection: Binding(
                        get: { draft.effectiveKernelSentry == .hard ? KernelSentryMode.hard : .bestEffort },
                        set: { draft.kernelSentry = $0 })) {
                        Text("Best effort").tag(KernelSentryMode.bestEffort).disabled(floor == .hard)
                        Text("Required").tag(KernelSentryMode.hard)
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
            }
            if let snap = KernelSentryService.shared.snapshot(draft.id) {
                PolicyStatus(text: (snap.connected ? "Connected" + (snap.kernel.map { " · kernel \($0)" } ?? "") : "Not connected")
                                 + (snap.dropped > 0 ? " · \(snap.dropped) event(s) dropped under load" : ""),
                             tone: snap.connected ? (snap.dropped > 0 ? .warn : .ok) : .warn)
            }
            if let st = GuestSandboxStatusStore.shared.status(for: draft.id), st.sentry == "unavailable" {
                PolicyStatus(text: "Couldn't start" + (st.sentryReason.map { ": \($0)" } ?? "."), tone: .bad)
            }
        }
    }
}

/// OpenShell's ways in and out of the workspace's credentials, shown in the
/// Credentials pane of a workspace whose firewall is an OpenShell policy.
/// Neither is a separate store: an attached provider profile adds ordinary
/// credentials (plus a `_provider_` rule for its endpoints), and the
/// placeholders change how those credentials look inside the VM.
struct OpenShellCredentialsSection: View {
    @Binding var draft: Profile
    @State private var pendingProvider: PendingProvider?
    @State private var importError: String?

    /// A provider profile picked for import, waiting for its secrets.
    struct PendingProvider: Identifiable {
        let id = UUID()
        let yaml: String
        let profile: OpenShellProviderProfile
        var instanceName: String
        var values: [String: String] = [:]
    }

    /// Attached OpenShell provider profiles: their credentials become
    /// workspace credentials bound to the profile's endpoints, and their
    /// endpoints a `_provider_<name>` rule.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text("OpenShell provider profiles").font(.headline)
                InfoTip("Import an OpenShell provider profile to add its credentials to this workspace. Bromure keeps the real values on the Mac, gives the VM stand-ins, and only swaps them in on the profile's endpoints (hosts and paths); the profile's endpoints are added as a rule.")
            }
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
            Divider().padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Toggle("Use OpenShell credential placeholders", isOn: $draft.openShellCredentialPlaceholders)
                    InfoTip("The agent sees `openshell:resolve:env:NAME` in its environment instead of Bromure's look-alike tokens, for the credentials this workspace passes as environment variables. The proxy swaps in the real value in request headers, and in request bodies or WebSocket messages only where an endpoint sets `request_body_credential_rewrite` or `websocket_credential_rewrite`. Each credential still works only on its own hosts. Some tools check a token's format and may reject a placeholder. Takes effect at the next VM start.")
                }
                Text("Takes effect at the next VM start.").font(.caption).foregroundStyle(.secondary)
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
}

/// The organization's minimum kernel sentry, kept current for views: the
/// enrollment heartbeat changes it at any time (`OpenShellGovernance`'s
/// changedNotification), and a view that read it once in `body` went on
/// drawing the old one until something else redrew it.
@MainActor
final class KernelSentryFloorWatch: ObservableObject {
    @Published private(set) var floor: KernelSentryMode
    private let center: NotificationCenter
    private var observer: NSObjectProtocol?

    init(center: NotificationCenter = .default,
         read: @escaping @MainActor () -> KernelSentryMode = { OpenShellGovernance.shared.kernelSentryFloor }) {
        self.center = center
        floor = read()
        observer = center.addObserver(forName: OpenShellGovernance.changedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.floor = read() }
        }
    }

    deinit {
        if let observer { center.removeObserver(observer) }
    }
}
