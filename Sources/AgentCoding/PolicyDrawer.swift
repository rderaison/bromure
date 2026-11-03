import AppKit
import SwiftUI
import SandboxEngine

/// The Sandbox drawer: a running workspace's blocked connections and the
/// policy advisor's proposals, decided in place instead of in Settings ›
/// Sandbox Policy. Slides in over the right edge of the workspace window
/// (the toolbar's shield button, which counts new blocks). Works for both
/// engines: the Bromure Firewall gets a rule with a time limit, OpenShell a
/// policy rule (naming the program when Enforce binaries is on).
struct PolicyDrawer: View {
    @Bindable var list: SessionListModel
    let onClose: () -> Void
    let onOpenSettings: (UUID) -> Void

    enum Tab: Hashable { case blocked, files, proposals, temporary }
    @State private var tab: Tab = ProcessInfo.processInfo.environment["BROMURE_SHOT_DRAWER_TAB"] == "files" ? .files : .blocked
    @State private var dismissed: Set<String> = []
    @State private var allowed: Set<String> = []
    /// Folders allowed in this drawer: they need a restart to apply.
    @State private var needsRestart: Set<String> = []
    @State private var busy: Set<String> = []
    @State private var errors: [String: String] = [:]
    @State private var proposals: [OpenShellAdvisor.Proposal] = []
    @State private var packages: [OpenShellAdvisor.PackageRequest] = []
    @State private var now = Date()
    @ObservedObject private var ticker = FirewallRulesTicker.shared
    /// The timeline and workspace to show (screenshots pass stand-ins; the
    /// app uses its own).
    var timeline: SecurityTimeline = .shared
    var profileOverride: Profile? = nil
    private let clock = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var delegate: ACAppDelegate? { NSApp.delegate as? ACAppDelegate }
    private var profile: Profile? {
        let _ = ticker.generation
        if let profileOverride { return profileOverride }
        guard let id = list.stageProfileID else { return nil }
        return delegate?.profiles.first { $0.id == id }
    }
    private var isOpenShell: Bool { profile?.usesOpenShellPolicy ?? false }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let profile {
                tabs(profile)
                    .padding(.horizontal, 16).padding(.bottom, 10)
                Divider().opacity(0.5)
                ScrollView {
                    LazyVStack(spacing: 8) {
                        switch tab {
                        case .blocked:   blockedList(profile)
                        case .files:     filesList(profile)
                        case .proposals: proposalList(profile)
                        case .temporary: temporaryList(profile)
                        }
                    }
                    .padding(12)
                }
                Divider().opacity(0.5)
                footer(profile)
            } else {
                Spacer()
                emptyState(icon: "shield.lefthalf.filled", title: "No workspace selected",
                           text: "Pick a workspace to see what its sandbox blocked.")
                Spacer()
            }
        }
        .frame(width: 368)
        .frame(maxHeight: .infinity)
        .modifier(DrawerSurface())
        .onAppear { reloadProposals(); markSeen() }
        .onChange(of: list.stageProfileID) { _, _ in
            dismissed = []; allowed = []; needsRestart = []; errors = [:]; reloadProposals(); markSeen()
        }
        .onReceive(NotificationCenter.default.publisher(for: OpenShellAdvisor.changedNotification)) { _ in
            reloadProposals()
        }
        // Closing only hides the drawer (its view, and this clock, live on),
        // so each open — not just the first appearance — and the close itself
        // mark what was on screen as seen.
        .onChange(of: list.policyDrawerOpen) { _, open in
            if open { reloadProposals() }
            PolicyDrawer.markSeen(list, closing: !open)
        }
        .onReceive(clock) { now = $0; markSeen() }
    }

    // MARK: Header, tabs, footer

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            PolicyIcon(system: isOpenShell ? "cube.transparent.fill" : "flame.fill",
                       tint: isOpenShell ? .teal : .red, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sandbox").font(.title3.weight(.semibold))
                if let profile {
                    Text(verbatim: profile.name + " · "
                         + (isOpenShell ? NSLocalizedString("OpenShell + Sentry", comment: "sandbox engine")
                                        : NSLocalizedString("Bromure Firewall", comment: "sandbox engine")))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.07)))
            }
            .buttonStyle(.plain)
            .help(Text("Close"))
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 12)
    }

    private func tabs(_ profile: Profile) -> some View {
        Picker("", selection: $tab) {
            Text(label(isOpenShell ? "Network" : "Blocked", blocked(profile).count)).tag(Tab.blocked)
            if isOpenShell, hasFilesystemSandbox(profile) {
                Text(label("Files", fileDenials(profile).count)).tag(Tab.files)
            }
            if isOpenShell {
                Text(label("Proposals", proposals.filter { $0.status == .pending }.count
                           + packages.filter { $0.status == .pending }.count)).tag(Tab.proposals)
            } else {
                Text(label("Temporary", temporaryRules(profile).count)).tag(Tab.temporary)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .onChange(of: isOpenShell) { _, _ in tab = .blocked }
    }

    private func label(_ key: String, _ n: Int) -> String {
        let t = NSLocalizedString(key, comment: "network drawer tab")
        return n > 0 ? "\(t) \(n)" : t
    }

    private func footer(_ profile: Profile) -> some View {
        HStack {
            Text(tab == .files ? "File access applies at the next start."
                 : isOpenShell ? "Network changes apply live." : "Rules apply live; timed ones end on their own.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Sandbox Policy…") { onOpenSettings(profile.id) }
                .controlSize(.small)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func emptyState(icon: String, title: LocalizedStringKey, text: LocalizedStringKey) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(.callout.weight(.medium))
            Text(text).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40).padding(.horizontal, 24)
    }

    // MARK: Blocked

    struct Blocked: Identifiable {
        var id: String { key }
        let key: String
        let host: String
        let port: Int
        let fw: SecurityTimeline.Firewall
        let last: Date
        let count: Int
    }

    /// The workspace's distinct blocked destinations from the last two
    /// hours, newest first.
    private func blocked(_ profile: Profile) -> [Blocked] {
        Self.blockedRows(timeline.allEvents, profileID: profile.id, since: now.addingTimeInterval(-2 * 3600))
            .filter { !dismissed.contains($0.key) }
    }

    /// One row per destination and program: a deny for another program (its
    /// event names it) never takes over a row, and so never what its Allow
    /// grants.
    static func rowKey(host: String, port: Int, exe: String?) -> String {
        "\(host.lowercased()):\(port)" + (exe.map { "|" + $0 } ?? "")
    }

    static func blockedRows(_ events: [SecurityTimeline.Event], profileID: UUID, since cutoff: Date) -> [Blocked] {
        var byKey: [String: Blocked] = [:]
        for e in events where e.profileID == profileID && e.machine == nil && e.time > cutoff {
            guard let fw = e.firewall, fw.denied, fw.byPolicy,
                  let host = fw.host ?? fw.ip, let port = fw.port, port > 0 else { continue }
            let key = rowKey(host: host, port: port, exe: fw.exe)
            let n = (byKey[key]?.count ?? 0) + (e.count ?? 1)
            if let old = byKey[key], old.last > e.time {
                byKey[key] = Blocked(key: key, host: old.host, port: port, fw: old.fw, last: old.last, count: n)
            } else {
                byKey[key] = Blocked(key: key, host: host.lowercased(), port: port, fw: fw, last: e.time, count: n)
            }
        }
        return byKey.values.sorted { $0.last > $1.last }
    }

    @ViewBuilder private func blockedList(_ profile: Profile) -> some View {
        let items = blocked(profile)
        if items.isEmpty {
            emptyState(icon: "checkmark.shield", title: "Nothing blocked",
                       text: "Connections the sandbox refuses show up here, ready to allow.")
        }
        ForEach(items) { item in
            DrawerCard {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: allowed.contains(item.key) ? "checkmark.circle.fill" : "nosign")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(allowed.contains(item.key) ? Color.green : Color.red)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "\(item.host):\(item.port)")
                            .font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        // The program on its own line, clipped in the middle:
                        // /tmp/curl and /usr/bin/curl are different grants, and
                        // a tail cut hid the file name (Finding CWE-451,
                        // "Drawer subtitle clips the program path at the file
                        // name").
                        if let exe = program(item, profile) {
                            Text(verbatim: exe)
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                                .help(Text(verbatim: exe))
                        }
                        Text(verbatim: Self.blockedSubtitle(count: item.count, last: item.last, now: now))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if let err = errors[item.key] {
                            Text(verbatim: err).font(.caption).foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if allowed.contains(item.key) {
                        Text("Allowed").font(.caption.weight(.medium)).foregroundStyle(.green)
                    } else if busy.contains(item.key) {
                        ProgressView().controlSize(.small)
                    } else {
                        allowControl(item, profile)
                        Button { dismissed.insert(item.key) } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain).help(Text("Dismiss"))
                    }
                }
            }
        }
    }

    /// How often and when, under the program line.
    static func blockedSubtitle(count: Int, last: Date, now: Date) -> String {
        var parts: [String] = []
        if count > 1 { parts.append("\(count)×") }
        parts.append(RelativeDateTimeFormatter().localizedString(for: last, relativeTo: now))
        return parts.joined(separator: " · ")
    }

    /// Allow's help names the program it grants, in full.
    static func allowHelp(exe: String?) -> String {
        guard let exe else {
            return NSLocalizedString("Add a rule for this host and port", comment: "sandbox drawer: Allow help, no program known")
        }
        return String(format: NSLocalizedString("Add a rule for this host and port, for %@",
                                                comment: "sandbox drawer: Allow help, the program's full path"), exe)
    }

    /// The program that tried: the attestor's answer on the block's own
    /// event (what Allow grants), else the kernel sentry's flow report (the
    /// leaf of its process chain).
    private func program(_ item: Blocked, _ profile: Profile) -> String? {
        if let exe = item.fw.exe { return exe }
        for e in timeline.allEvents.reversed() where e.profileID == profile.id && e.eventType == "net.flow" {
            guard let d = e.detail, case .int(let port)? = d["dport"], port == item.port else { continue }
            var host: String? = nil
            if case .string(let h)? = d["host"] { host = h.lowercased() }
            var dst: String? = nil
            if case .string(let v)? = d["dst"] { dst = v }
            guard host == item.host || dst == item.fw.ip else { continue }
            if case .array(let procs)? = d["processes"], case .object(let leaf)? = procs.last,
               case .string(let exe)? = leaf["exe"] { return exe }
        }
        return nil
    }

    @ViewBuilder private func allowControl(_ item: Blocked, _ profile: Profile) -> some View {
        if isOpenShell {
            Button("Allow") { allowOpenShell(item, profile) }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.small)
                .help(Text(verbatim: Self.allowHelp(exe: item.fw.exe)))
        } else if let target = FirewallRuleActions.targets(for: item.fw).first,
                  let rule = FirewallRuleActions.allowRule(target: target.name, fw: item.fw) {
            Menu {
                Button("Always") { allowFirewall(item, rule, .always, profile) }
                Button("For 15 minutes") { allowFirewall(item, rule, .fifteenMinutes, profile) }
                Button("For 1 hour") { allowFirewall(item, rule, .oneHour, profile) }
                Button("Until the workspace stops") { allowFirewall(item, rule, .untilStop, profile) }
            } label: {
                Text("Allow")
            } primaryAction: {
                allowFirewall(item, rule, .always, profile)
            }
            .menuStyle(.borderedButton).buttonBorderShape(.capsule).controlSize(.small)
            .fixedSize()
            .help(Text("Allow always — or pick a time limit from the arrow"))
        }
    }

    private func allowFirewall(_ item: Blocked, _ rule: EgressPolicy.Rule, _ d: FirewallRuleActions.Duration, _ profile: Profile) {
        var r = rule
        d.apply(to: &r, now: Date())
        if delegate?.applyFirewallEdit(.insert(r), profileID: profile.id) == true || allowedNow(item, profile) {
            allowed.insert(item.key); errors[item.key] = nil
        } else {
            errors[item.key] = NSLocalizedString("Couldn't add the rule.", comment: "network drawer")
        }
    }

    private func allowedNow(_ item: Blocked, _ profile: Profile) -> Bool {
        FirewallRuleActions.currentDecision(for: item.fw, policy: profile.resolvedEgressPolicy)?.denied == false
    }

    private func allowOpenShell(_ item: Blocked, _ profile: Profile) {
        busy.insert(item.key)
        let pid = profile.id, host = item.host, port = item.port, key = item.key, exe = item.fw.exe
        Task { @MainActor in
            let error = await OpenShellAdvisor.shared.allow(profileID: pid, host: host, port: port, exe: exe)
            busy.remove(key)
            if let error { errors[key] = error } else { allowed.insert(key); errors[key] = nil }
        }
    }

    // MARK: Files (OpenShell's filesystem sandbox)

    struct FileDenial: Identifiable {
        var id: String { folder }
        /// The folder an allow grants (the tried path's package folder).
        let folder: String
        let path: String
        let program: String?
        let op: String
        let last: Date
        let count: Int
    }

    private func hasFilesystemSandbox(_ profile: Profile) -> Bool {
        (try? OpenShellPolicy.parse(profile.networkPolicy))?.filesystem != nil
    }

    /// What a denied path most likely needs: under the home folder its own
    /// folder; elsewhere the top two levels (`/opt/grok` for
    /// `/opt/grok/bin/grok`), the unit tools install into.
    static func folder(for path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        if path.hasPrefix("/home/") {
            return parts.count > 3 ? "/" + parts.dropLast().joined(separator: "/") : path
        }
        return parts.count > 2 ? "/" + parts.prefix(2).joined(separator: "/") : path
    }

    /// The sandbox's filesystem denials from the last two hours, by folder.
    private func fileDenials(_ profile: Profile) -> [FileDenial] {
        let cutoff = now.addingTimeInterval(-2 * 3600)
        var byFolder: [String: FileDenial] = [:]
        for e in timeline.allEvents where e.profileID == profile.id && e.machine == nil && e.time > cutoff
            && e.eventType == "sentry.event" {
            guard let d = e.detail, case .string(let path)? = d["path"], path.hasPrefix("/") else { continue }
            if case .string("seccomp_denied")? = d["kind"] { continue }
            var n = 1
            if case .int(let c)? = d["count"] { n = max(1, c) }
            var exe: String? = nil
            if case .string(let v)? = d["exe"] { exe = v } else if case .string(let v)? = d["comm"] { exe = v }
            var op = "open"
            if case .string(let v)? = d["op"] { op = v }
            let folder = Self.folder(for: path)
            let prev = byFolder[folder]
            let newer = prev.map { $0.last <= e.time } ?? true
            byFolder[folder] = FileDenial(folder: folder, path: newer ? path : prev!.path,
                                          program: newer ? exe : prev!.program, op: newer ? op : prev!.op,
                                          last: newer ? e.time : prev!.last, count: (prev?.count ?? 0) + n)
        }
        return byFolder.values.filter { !dismissed.contains("fs:" + $0.folder) }.sorted { $0.last > $1.last }
    }

    @ViewBuilder private func filesList(_ profile: Profile) -> some View {
        let items = fileDenials(profile)
        if !needsRestart.isEmpty {
            DrawerCard {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.clockwise.circle.fill").font(.system(size: 18)).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Restart to apply").font(.callout.weight(.medium))
                        Text("The filesystem sandbox is set when the workspace starts.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Restart") { delegate?.restartProfile(profile.id) }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.small).tint(.orange)
                }
            }
        }
        if items.isEmpty && needsRestart.isEmpty {
            emptyState(icon: "folder.badge.questionmark", title: "No file denials",
                       text: profile.effectiveKernelSentry == .off
                           ? "Turn the kernel sentry on to see what the sandbox refuses."
                           : "Files and folders the sandbox refuses show up here.")
        }
        ForEach(items) { item in
            DrawerCard {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: needsRestart.contains(item.folder) ? "checkmark.circle.fill" : "folder.badge.minus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(needsRestart.contains(item.folder) ? Color.green : Color.red)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: item.folder).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                        Text(verbatim: "\(item.op) \((item.path as NSString).lastPathComponent)")
                            .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                            .help(Text(verbatim: item.path))
                        Text(verbatim: fileSubtitle(item))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if let err = errors["fs:" + item.folder] {
                            Text(verbatim: err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if needsRestart.contains(item.folder) {
                        Text("Allowed").font(.caption.weight(.medium)).foregroundStyle(.green)
                    } else {
                        Menu {
                            Button("Read only") { allowPath(item.folder, readWrite: false, profile) }
                            Button("Read and write") { allowPath(item.folder, readWrite: true, profile) }
                            if item.path != item.folder {
                                Divider()
                                Button(String(format: NSLocalizedString("Only %@ (read only)", comment: "network drawer: allow one file"),
                                              (item.path as NSString).lastPathComponent)) {
                                    allowPath(item.path, readWrite: false, profile, key: item.folder)
                                }
                            }
                        } label: {
                            Text("Allow")
                        } primaryAction: {
                            allowPath(item.folder, readWrite: false, profile)
                        }
                        .menuStyle(.borderedButton).buttonBorderShape(.capsule).controlSize(.small).fixedSize()
                        .help(Text("Allow reading this folder — or pick read and write from the arrow"))
                        Button { dismissed.insert("fs:" + item.folder) } label: {
                            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain).help(Text("Dismiss"))
                    }
                }
            }
        }
    }

    private func fileSubtitle(_ item: FileDenial) -> String {
        var parts: [String] = []
        if let p = item.program { parts.append((p as NSString).lastPathComponent) }
        if item.count > 1 { parts.append("\(item.count)×") }
        parts.append(RelativeDateTimeFormatter().localizedString(for: item.last, relativeTo: now))
        return parts.joined(separator: " · ")
    }

    private func allowPath(_ path: String, readWrite: Bool, _ profile: Profile, key: String? = nil) {
        let k = key ?? path
        if let error = delegate?.addSandboxPath(profileID: profile.id, path: path, readWrite: readWrite) {
            errors["fs:" + k] = error
        } else {
            needsRestart.insert(k); errors["fs:" + k] = nil
        }
    }

    // MARK: Proposals (OpenShell)

    @ViewBuilder private func proposalList(_ profile: Profile) -> some View {
        let pending = proposals.filter { $0.status == .pending }
        packageList(profile)
        if pending.isEmpty && packages.isEmpty {
            emptyState(icon: "wand.and.stars", title: "No proposals",
                       text: profile.openShellAdvisorMode == OpenShellAdvisorMode.off.rawValue
                           ? "The policy advisor is off for this workspace."
                           : "When the agent asks for a rule, it waits here for you.")
        }
        ForEach(pending) { p in
            DrawerCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: p.source == "agent_authored" ? "person.crop.circle.badge.questionmark" : "wand.and.stars")
                            .foregroundStyle(.purple)
                        Text(verbatim: "\(p.host):\(p.port)").font(.callout.weight(.medium)).lineLimit(1)
                        Spacer()
                        Text(p.source == "agent_authored" ? "from the agent" : "drafted from a block")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if !p.intent.isEmpty {
                        Text(verbatim: p.intent).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !p.rule.binaries.isEmpty {
                        Label(p.rule.binaries.joined(separator: ", "), systemImage: "terminal")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !p.findings.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(p.findings, id: \.self) { f in
                                Text(verbatim: f.replacingOccurrences(of: "_", with: " "))
                                    .font(.caption2.weight(.medium))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.orange.opacity(0.15)))
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Reject") {
                            OpenShellAdvisor.shared.reject(id: p.id, profileID: profile.id, reason: "")
                        }
                        .buttonBorderShape(.capsule)
                        Button("Approve") {
                            let id = p.id, pid = profile.id
                            Task { await OpenShellAdvisor.shared.approve(id: id, profileID: pid) }
                        }
                        .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func reloadProposals() {
        guard let id = list.stageProfileID else { proposals = []; packages = []; return }
        proposals = OpenShellAdvisor.shared.proposals(for: id)
        packages = OpenShellAdvisor.shared.packageRequests(for: id)
    }

    /// System packages the agent asked for: waiting, installing, or just
    /// done (the last few, so the outcome is seen).
    @ViewBuilder private func packageList(_ profile: Profile) -> some View {
        let shown = packages.filter { $0.status == .pending || $0.status == .installing }
            + packages.filter { $0.status != .pending && $0.status != .installing }.suffix(3).reversed()
        ForEach(shown) { r in
            DrawerCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "shippingbox.fill").foregroundStyle(.orange)
                        Text(verbatim: r.packages.joined(separator: " ")).font(.callout.weight(.medium))
                            .lineLimit(2).truncationMode(.tail)
                        Spacer()
                        Text(verbatim: "apt").font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                    switch r.status {
                    case .pending:
                        Text("The agent asked to install these system packages.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            Button("Reject") {
                                OpenShellAdvisor.shared.rejectPackages(id: r.id, profileID: profile.id, reason: "")
                            }
                            .buttonBorderShape(.capsule)
                            Button("Install") {
                                let id = r.id, pid = profile.id
                                Task.detached { await OpenShellAdvisor.shared.approvePackages(id: id, profileID: pid) }
                            }
                            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
                        }
                        .controlSize(.small)
                    case .installing:
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Installing…").font(.caption).foregroundStyle(.secondary)
                        }
                    case .installed:
                        PolicyStatus(text: NSLocalizedString("Installed", comment: "network drawer: package request"), tone: .ok)
                    case .failed:
                        PolicyStatus(text: String(format: NSLocalizedString("Install failed (exit %d)", comment: "network drawer: package request"),
                                                  r.exitCode ?? 1), tone: .bad)
                            .help(Text(verbatim: String(r.output.suffix(1500))))
                    case .rejected:
                        PolicyStatus(text: NSLocalizedString("Rejected", comment: "network drawer: package request"))
                    }
                }
            }
        }
    }

    // MARK: Temporary rules (Bromure Firewall)

    private func temporaryRules(_ profile: Profile) -> [EgressPolicy.Rule] {
        guard let policy = try? EgressPolicy.parse(profile.egressRules) else { return [] }
        return policy.rules.filter { ($0.expiresAt != nil || $0.untilStop) && $0.isEffective(at: now) }
    }

    @ViewBuilder private func temporaryList(_ profile: Profile) -> some View {
        let rules = temporaryRules(profile)
        if rules.isEmpty {
            emptyState(icon: "timer", title: "No temporary rules",
                       text: "Rules you allow for a while are listed here until they end.")
        }
        ForEach(rules, id: \.text) { r in
            DrawerCard {
                HStack(spacing: 10) {
                    Image(systemName: "timer").foregroundStyle(.orange).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: r.text).font(.system(.caption, design: .monospaced)).lineLimit(1)
                            .truncationMode(.middle)
                        Text(verbatim: r.untilStop
                             ? NSLocalizedString("Until the workspace stops", comment: "network drawer")
                             : String(format: NSLocalizedString("Ends %@", comment: "network drawer; %@ = relative time"),
                                      RelativeDateTimeFormatter().localizedString(for: r.expiresAt ?? now, relativeTo: now)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("End") { _ = delegate?.applyFirewallEdit(.remove(ruleText: r.text), profileID: profile.id) }
                        .buttonBorderShape(.capsule).controlSize(.small)
                }
            }
        }
    }

    // MARK: Seen

    /// The toolbar badge counts blocks newer than this.
    private func markSeen() { PolicyDrawer.markSeen(list) }

    /// Only what was on screen counts as seen: while the drawer is open (or
    /// as it closes). The hidden drawer's clock and a workspace switch with
    /// the drawer closed used to mark it too, so the badge stayed at 0.
    @MainActor static func markSeen(_ list: SessionListModel, closing: Bool = false, now: Date = Date()) {
        guard list.policyDrawerOpen || closing, let id = list.stageProfileID else { return }
        list.policyDrawerSeen[id] = now
    }

    /// Distinct rows (destination and program) blocked since the drawer was last seen (the
    /// toolbar badge).
    @MainActor static func unseenCount(profileID: UUID, list: SessionListModel) -> Int {
        let since = list.policyDrawerSeen[profileID] ?? Date().addingTimeInterval(-2 * 3600)
        var keys = Set<String>()
        for e in SecurityTimeline.shared.allEvents.reversed() {
            if e.time <= since { break }
            guard e.profileID == profileID, e.machine == nil, let fw = e.firewall, fw.denied, fw.byPolicy,
                  let host = fw.host ?? fw.ip, let port = fw.port else { continue }
            keys.insert(rowKey(host: host, port: port, exe: fw.exe))
        }
        return keys.count
    }
}

/// One row of the drawer: a soft rounded tile.
private struct DrawerCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @State private var hovering = false
    var body: some View {
        content()
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.07 : 0.045)))
            .onHover { hovering = $0 }
    }
}

/// The drawer's floating surface: Liquid Glass on macOS 26, a thick material
/// before it, rounded and lifted off the window.
private struct DrawerSurface: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        if #available(macOS 26.0, *) {
            content
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.55), in: shape)
                .glassEffect(.regular, in: shape)
                .clipShape(shape)
                .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
        } else {
            content
                .background(.thickMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
                .clipShape(shape)
                .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
        }
    }
}

/// The toolbar's shield button: opens the drawer, counts new blocks.
struct PolicyDrawerButton: View {
    @Bindable var list: SessionListModel
    let profileID: UUID
    let action: () -> Void

    var body: some View {
        let _ = SecurityTimeline.shared.allEvents.count
        let n = list.policyDrawerOpen ? 0 : PolicyDrawer.unseenCount(profileID: profileID, list: list)
        HeaderIcon(system: "shield.lefthalf.filled",
                   help: NSLocalizedString("Sandbox: what it blocked, ready to allow (⌃⌘N)", comment: "toolbar"),
                   active: list.policyDrawerOpen, action: action)
            .overlay(alignment: .topTrailing) {
                if n > 0 {
                    Text(verbatim: n > 9 ? "9+" : "\(n)")
                        .font(.system(size: 9, weight: .bold)).monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
                        .background(Capsule().fill(Color.red))
                        .offset(x: 4, y: -3)
                        .allowsHitTesting(false)
                }
            }
    }
}

extension ACAppDelegate {
    /// Add a path to a workspace's OpenShell `filesystem_policy` (the Network
    /// drawer's Files tab) and save it. Landlock is set when the sandboxed
    /// session starts and can only ever narrow, so it applies at the next
    /// start. Returns an error message, or nil.
    @MainActor func addSandboxPath(profileID: UUID, path: String, readWrite: Bool) -> String? {
        guard let existing = profile(for: profileID) else { return "workspace not found" }
        var updated = existing
        do {
            updated.networkPolicy = try OpenShellPolicy.addingFilesystemPath(path, readWrite: readWrite,
                                                                              to: existing.networkPolicy)
            guard updated.networkPolicy != existing.networkPolicy else { return nil }
            try persistEditedProfile(&updated, editing: existing, generateSSH: false, policySource: "drawer")
        } catch {
            return "\(error)"
        }
        applyLiveEditToRunningSession(updated)
        return nil
    }
}
