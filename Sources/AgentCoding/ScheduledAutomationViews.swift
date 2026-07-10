import SwiftUI

// MARK: - Sidebar section

/// "Automations" — the third sidebar group, after the Grid node and the
/// workspace rows. One row per automation, colored by its owning workspace;
/// selecting a row shows the editor as the stage surface (same overlay
/// pattern as the Docker dashboard).
struct AutomationsSection: View {
    var store: ScheduledAutomationStore
    @Bindable var model: SessionListModel
    let onSelect: (UUID) -> Void
    let onNew: () -> Void
    let onRunNow: (UUID) -> Void
    let onToggle: (UUID) -> Void
    let onDelete: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text("Automations")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.7)
                Spacer()
                Button(action: onNew) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("New automation", comment: ""))
            }
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .padding(.top, 14)
            .padding(.bottom, 4)

            ForEach(store.automations) { automation in
                AutomationRow(
                    automation: automation,
                    accentHex: model.profileRows.first { $0.id == automation.profileID }?
                        .accentHex ?? "#888888",
                    nextFire: store.nextFire(for: automation.id),
                    lastRun: store.lastRun(for: automation.id),
                    isSelected: model.automationSelectedID == automation.id,
                    onSelect: { onSelect(automation.id) },
                    onRunNow: { onRunNow(automation.id) },
                    onToggle: { onToggle(automation.id) },
                    onDelete: { onDelete(automation.id) })
            }
        }
    }
}

private struct AutomationRow: View {
    let automation: ScheduledAutomation
    let accentHex: String
    let nextFire: Date?
    let lastRun: AutomationRunRecord?
    let isSelected: Bool
    let onSelect: () -> Void
    let onRunNow: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    private static let fireFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        return f
    }()

    private var metaText: String {
        guard automation.enabled else {
            return NSLocalizedString("Paused", comment: "automation row")
        }
        var parts = [scheduleSummary(automation)]
        if let nextFire {
            parts.append(String(format: NSLocalizedString("next %@", comment: "automation row"),
                                Self.fireFormatter.string(from: nextFire)))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(hex: accentHex))
                    .frame(width: 8, height: 8)
                    .opacity(automation.enabled ? 1 : 0.4)
                VStack(alignment: .leading, spacing: 0) {
                    Text(automation.name.isEmpty
                         ? NSLocalizedString("Untitled automation", comment: "")
                         : automation.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                    Text(metaText)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if let lastRun {
                    Image(systemName: lastRun.outcome.glyph)
                        .font(.system(size: 10))
                        .foregroundStyle(lastRun.outcome.tint)
                        .help(lastRun.outcome.helpText)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(isSelected ? Color.accentColor.opacity(0.16) : .clear))
        .contextMenu {
            Button(NSLocalizedString("Run Now", comment: "")) { onRunNow() }
            Button(automation.enabled
                   ? NSLocalizedString("Pause", comment: "")
                   : NSLocalizedString("Resume", comment: "")) { onToggle() }
            Divider()
            Button(NSLocalizedString("Delete…", comment: ""), role: .destructive) { onDelete() }
        }
    }
}

/// "Weekdays 9:00" / "Fri 17:00" / "PR · owner/repo" — the row's one-line
/// trigger summary.
func scheduleSummary(_ a: ScheduledAutomation) -> String {
    switch a.trigger {
    case .githubPullRequest, .githubIssue:
        let kind = a.trigger == .githubIssue ? "Issue" : "PR"
        return "\(kind) · " + (a.githubRepo.isEmpty ? "?" : a.githubRepo)
    case .githubCommit:
        var s = "Commit · " + (a.githubRepo.isEmpty ? "?" : a.githubRepo)
        if !a.filters.commitSubfolder.isEmpty { s += "/" + a.filters.commitSubfolder }
        return s
    case .linearIssue:
        var parts = ["Linear"]
        if !a.linearTeam.isEmpty { parts.append(a.linearTeam.uppercased()) }
        parts.append(a.assignmentFilter == .assignedToMe
                     ? NSLocalizedString("Mine", comment: "linear row summary")
                     : NSLocalizedString("Unassigned", comment: "linear row summary"))
        return parts.joined(separator: " · ")
    case .schedule:
        break
    }
    let time = String(format: "%d:%02d", a.hour, a.minute)
    switch a.frequency {
    case .interval:
        let m = max(5, a.intervalMinutes)
        return m % 60 == 0
            ? String(format: NSLocalizedString("Every %dh", comment: ""), m / 60)
            : String(format: NSLocalizedString("Every %dm", comment: ""), m)
    case .daily:    return String(format: NSLocalizedString("Daily %@", comment: ""), time)
    case .weekdays: return String(format: NSLocalizedString("Weekdays %@", comment: ""), time)
    case .weekly:
        let symbols = Calendar.current.shortWeekdaySymbols
        let day = symbols[(min(max(a.weekday, 1), 7)) - 1]
        return "\(day) \(time)"
    }
}

extension AutomationRunRecord.Outcome {
    var glyph: String {
        switch self {
        case .launched: return "checkmark.circle"
        case .skipped:  return "forward.end"
        case .failed:   return "xmark.circle"
        case .blocked:  return "shield.slash"
        }
    }
    var tint: Color {
        switch self {
        case .launched: return .green
        case .skipped:  return .secondary
        case .failed:   return .red
        case .blocked:  return .red
        }
    }
    var helpText: String {
        switch self {
        case .launched: return NSLocalizedString("Last run launched", comment: "")
        case .skipped:  return NSLocalizedString("Last run skipped (Mac was asleep)", comment: "")
        case .failed:   return NSLocalizedString("Last run failed", comment: "")
        case .blocked:  return NSLocalizedString("Last item blocked by the prompt-injection screen", comment: "")
        }
    }
}

/// Right-click "New automation…" on a terminal tab: seeds the editor with
/// that tab's workspace and working directory.
struct AutomationPrefill: Sendable {
    var profileID: UUID
    /// Guest path of the tab's cwd.
    var repoPath: String
}

// MARK: - Editor

/// The automation editor, shown as a stage overlay. Sections mirror the
/// agreed design: Trigger, Task, unattended-run warnings, recent runs.
/// Guardrail overrides and macOS notifications are follow-ups — the
/// permissions section links to the workspace's settings instead.
struct AutomationEditorView: View {
    var store: ScheduledAutomationStore
    /// Snapshot of the delegate's profiles at presentation time.
    let profiles: [Profile]
    let onSave: (ScheduledAutomation) -> Void
    let onRunNow: (ScheduledAutomation) -> Void
    let onDelete: (UUID) -> Void
    let onEditWorkspace: (UUID) -> Void

    @State private var draft: ScheduledAutomation
    private let isNew: Bool

    /// Repo/team dropdown state: nil = loading, [] with error = fetch failed
    /// (fall back to the free-text field). Fetched with the workspace token,
    /// so a populated list is also proof the token works.
    @State private var repoChoices: [String]?
    @State private var repoLoadError: String?
    @State private var teamChoices: [LinearPoller.LinearTeam]?
    @State private var teamLoadError: String?
    @State private var projectChoices: [LinearPoller.LinearProject]?
    /// Branches / directories for the selected repo. nil = loading; a nil
    /// dirChoices with dirsUnavailable = the tree was too big, use free text.
    @State private var branchChoices: [String]?
    @State private var dirChoices: [String]?
    @State private var filtersExpanded = false

    /// A persistent caption above a control — TextFields only show their
    /// title as disappearing placeholder text, which left fields unlabeled.
    @ViewBuilder
    private func captioned(_ title: String,
                           @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    /// The workspace's usable github.com token, if any.
    private var githubToken: String? {
        selectedProfile?.gitHTTPSCredentials.first(where: { cred in
            guard cred.isUsable else { return false }
            let h = cred.host.lowercased()
            return h == "github.com" || h.hasSuffix(".github.com")
        })?.token
    }

    /// Branch dropdown (from the fetched list) with a free-text fallback.
    /// `anyLabel` names the empty option — "Any branch" vs "Default branch".
    @ViewBuilder
    private func branchField(_ caption: String, selection: Binding<String>,
                             anyLabel: String) -> some View {
        captioned(caption) {
            if let branches = branchChoices, !branches.isEmpty {
                Picker("", selection: selection) {
                    Text(anyLabel).tag("")
                    if !selection.wrappedValue.isEmpty,
                       !branches.contains(selection.wrappedValue) {
                        Text(selection.wrappedValue).tag(selection.wrappedValue)
                    }
                    ForEach(branches, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            } else {
                TextField("", text: selection, prompt: Text(verbatim: "main"))
            }
        }
    }

    /// Subfolder dropdown (from the repo tree) with a free-text fallback for
    /// huge/truncated trees.
    @ViewBuilder
    private var subfolderField: some View {
        let caption = NSLocalizedString(
            "Subfolder — fire only for commits that touch this folder", comment: "")
        captioned(caption) {
            if let dirs = dirChoices, !dirs.isEmpty {
                Picker("", selection: $draft.filters.commitSubfolder) {
                    Text(NSLocalizedString("Whole repository", comment: "")).tag("")
                    if !draft.filters.commitSubfolder.isEmpty,
                       !dirs.contains(draft.filters.commitSubfolder) {
                        Text(draft.filters.commitSubfolder).tag(draft.filters.commitSubfolder)
                    }
                    ForEach(dirs, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            } else {
                TextField("", text: $draft.filters.commitSubfolder,
                          prompt: Text(verbatim: "services/api"))
            }
        }
    }

    init(store: ScheduledAutomationStore,
         profiles: [Profile],
         editing id: UUID?,
         prefill: AutomationPrefill? = nil,
         onSave: @escaping (ScheduledAutomation) -> Void,
         onRunNow: @escaping (ScheduledAutomation) -> Void,
         onDelete: @escaping (UUID) -> Void,
         onEditWorkspace: @escaping (UUID) -> Void) {
        self.store = store
        self.profiles = profiles
        self.onSave = onSave
        self.onRunNow = onRunNow
        self.onDelete = onDelete
        self.onEditWorkspace = onEditWorkspace
        if let id, let existing = store.automation(id) {
            _draft = State(initialValue: existing)
            _filtersExpanded = State(
                initialValue: existing.filters != ScheduledAutomation.TriggerFilters())
            isNew = false
        } else {
            var fresh = ScheduledAutomation(
                profileID: prefill?.profileID ?? profiles.first?.id ?? UUID())
            if let prefill {
                fresh.repoPath = Self.displayGuestPath(prefill.repoPath)
            }
            if let owner = profiles.first(where: { $0.id == fresh.profileID }) {
                fresh.tool = owner.tool
            }
            _draft = State(initialValue: fresh)
            isNew = true
        }
    }

    /// "/home/ubuntu/foo" → "~/foo" for the repo-path field.
    private static func displayGuestPath(_ path: String) -> String {
        let home = "/home/ubuntu"
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    private var selectedProfile: Profile? {
        profiles.first { $0.id == draft.profileID }
    }

    /// Agents this workspace has configured — the only ones offerable.
    private var toolChoices: [Profile.ToolSpec] {
        selectedProfile?.allToolSpecs ?? []
    }

    private var selectedSpec: Profile.ToolSpec? {
        toolChoices.first { $0.tool == draft.tool }
    }

    private var askLabels: [String] {
        selectedProfile?.askBeforeUseCredentialLabels ?? []
    }

    private var hasGitHubToken: Bool {
        selectedProfile?.hasGitHubCredential ?? false
    }

    private var hasLinearToken: Bool {
        !(selectedProfile?.linearToken.isEmpty ?? true)
    }

    /// Whether the workspace has the credential a trigger kind needs.
    private func triggerAvailable(_ kind: ScheduledAutomation.TriggerKind) -> Bool {
        switch kind {
        case .schedule:      return true
        case .linearIssue:   return hasLinearToken
        default:             return kind.isGitHub ? hasGitHubToken : true
        }
    }

    /// What still blocks saving, in the user's words. Shown next to the Save
    /// button — a disabled button with no reason reads as a bug.
    private var saveBlockers: [String] {
        var out: [String] = []
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append(NSLocalizedString("give it a name", comment: "save blocker"))
        }
        if draft.prompt.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append(NSLocalizedString("write a prompt", comment: "save blocker"))
        }
        if selectedProfile == nil {
            out.append(NSLocalizedString("pick a workspace", comment: "save blocker"))
        }
        switch draft.trigger {
        case .schedule:
            break
        case .githubPullRequest, .githubIssue, .githubCommit:
            if !GitHubPRPoller.isValidRepoSlug(draft.githubRepo) {
                out.append(NSLocalizedString("set the repository as owner/name",
                                             comment: "save blocker"))
            }
            if !hasGitHubToken {
                out.append(NSLocalizedString("add a GitHub token to the workspace",
                                             comment: "save blocker"))
            }
        case .linearIssue:
            if !hasLinearToken {
                out.append(NSLocalizedString("add a Linear API key to the workspace",
                                             comment: "save blocker"))
            }
        }
        return out
    }

    private var canSave: Bool { saveBlockers.isEmpty }

    /// Live proof the schedule is evaluated: the next fire computed from the
    /// current draft, exactly as the engine will compute it on save.
    private var nextFirePreview: Date? {
        guard draft.trigger == .schedule, draft.enabled else { return nil }
        return AutomationSchedule.nextFire(for: draft, after: Date())
    }

    /// Comma-separated text ↔ the label list.
    private var labelsBinding: Binding<String> {
        Binding(
            get: { draft.filters.labels.joined(separator: ", ") },
            set: { text in
                draft.filters.labels = text.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            })
    }

    /// The shared filter block for both trigger families. Collapsed by
    /// default (assignment + repo/team cover the common case); auto-expanded
    /// when the automation already carries filters.
    @ViewBuilder
    private func filtersGroup(isPR: Bool, isLinear: Bool) -> some View {
        DisclosureGroup(isExpanded: $filtersExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if isLinear {
                    if let projects = projectChoices, !projects.isEmpty {
                        Picker(NSLocalizedString("Project", comment: ""),
                               selection: $draft.filters.linearProjectID) {
                            Text(NSLocalizedString("All projects", comment: "")).tag("")
                            ForEach(projects) { Text($0.name).tag($0.id) }
                        }
                        .onChange(of: draft.filters.linearProjectID) {
                            draft.filters.linearProjectName = projects
                                .first { $0.id == draft.filters.linearProjectID }?.name ?? ""
                        }
                    }
                    Picker(NSLocalizedString("Priority", comment: ""),
                           selection: $draft.filters.linearMinPriority) {
                        Text(NSLocalizedString("Any", comment: "priority")).tag(0)
                        Text(NSLocalizedString("Urgent only", comment: "priority")).tag(1)
                        Text(NSLocalizedString("High or higher", comment: "priority")).tag(2)
                        Text(NSLocalizedString("Normal or higher", comment: "priority")).tag(3)
                    }
                }
                captioned(NSLocalizedString(
                    "Labels — fire only if the item has any of these (comma-separated)",
                    comment: "")) {
                    TextField("", text: labelsBinding,
                              prompt: Text(verbatim: isLinear ? "Bug, Agent" : "bug, agent-ok"))
                }
                if isPR {
                    branchField(NSLocalizedString(
                        "Base branch — fire only for PRs targeting this branch", comment: ""),
                        selection: $draft.filters.baseBranch,
                        anyLabel: NSLocalizedString("Any branch", comment: ""))
                    Toggle(NSLocalizedString("Ignore draft PRs", comment: ""),
                           isOn: $draft.filters.excludeDrafts)
                }
                if !isLinear {
                    Toggle(NSLocalizedString("Ignore bot authors (dependabot, renovate, …)",
                                             comment: ""),
                           isOn: $draft.filters.ignoreBots)
                }
                captioned(NSLocalizedString(
                    "Title contains — fire only if the title includes this text", comment: "")) {
                    TextField("", text: $draft.filters.titleContains,
                              prompt: Text(verbatim: "security"))
                }
            }
            .padding(.top, 6)
        } label: {
            Text(NSLocalizedString("Filters", comment: "trigger filters"))
                .font(.system(size: 12, weight: .medium))
        }
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: draft.hour, minute: draft.minute,
                                      second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                draft.hour = c.hour ?? 9
                draft.minute = c.minute ?? 0
            })
    }

    var body: some View {
        if profiles.isEmpty {
            ContentUnavailableView(
                NSLocalizedString("No workspaces yet", comment: ""),
                systemImage: "clock.badge.questionmark",
                description: Text(NSLocalizedString(
                    "Automations run inside a workspace. Create one first.",
                    comment: "")))
        } else {
            editor
        }
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                triggerSection
                taskSection
                finishSection
                if !askLabels.isEmpty { unattendedWarning }
                if !isNew { runsSection }
                footer
            }
            .padding(24)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // Reload the repo/team dropdowns whenever the workspace (and so the
        // tokens) changes. Doubles as a live token check.
        .task(id: draft.profileID) { await loadTriggerSources() }
        // Branches + directories depend on the chosen repo AND branch.
        .task(id: repoBranchKey) { await loadRepoDetails() }
    }

    /// Refetch branches/dirs when the repo or the commit branch changes.
    private var repoBranchKey: String { draft.githubRepo + "\u{1}" + draft.filters.commitBranch }

    private func loadTriggerSources() async {
        repoChoices = nil; repoLoadError = nil
        teamChoices = nil; teamLoadError = nil
        guard let profile = selectedProfile else { return }
        if let token = githubToken, !token.isEmpty {
            do {
                repoChoices = try await GitHubPRPoller.fetchRepos(token: token)
                // Prefilled from a terminal tab: if the folder name matches
                // one of the token's repos, preselect it.
                if draft.githubRepo.isEmpty {
                    let base = (draft.repoPath as NSString).lastPathComponent.lowercased()
                    if !base.isEmpty, base != "~",
                       let match = repoChoices?.first(where: {
                           $0.lowercased().hasSuffix("/" + base)
                       }) {
                        draft.githubRepo = match
                    }
                }
            } catch { repoLoadError = error.localizedDescription }
        }
        if !profile.linearToken.isEmpty {
            do { teamChoices = try await LinearPoller.fetchTeams(token: profile.linearToken) }
            catch { teamLoadError = error.localizedDescription }
            projectChoices = try? await LinearPoller.fetchProjects(token: profile.linearToken)
        }
    }

    /// Branch list (always) + directory list (commit trigger) for the current
    /// repo. Both degrade to free-text fields on any failure.
    private func loadRepoDetails() async {
        branchChoices = nil; dirChoices = nil
        guard draft.trigger.isGitHub,
              GitHubPRPoller.isValidRepoSlug(draft.githubRepo),
              let token = githubToken, !token.isEmpty else { return }
        branchChoices = (try? await GitHubPRPoller.fetchBranches(
            repo: draft.githubRepo, token: token)) ?? []
        if draft.trigger == .githubCommit {
            // nil result (tree truncated) or a throw → empty, which the
            // subfolder field reads as "fall back to free text".
            dirChoices = ((try? await GitHubPRPoller.fetchDirectories(
                repo: draft.githubRepo, token: token,
                branch: draft.filters.commitBranch)) ?? nil) ?? []
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            TextField(NSLocalizedString("Automation name", comment: ""), text: $draft.name)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .bold))
            Toggle(NSLocalizedString("Enabled", comment: ""), isOn: $draft.enabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .help(NSLocalizedString("Enabled", comment: ""))
        }
    }

    private var triggerSection: some View {
        GroupBox(NSLocalizedString("Trigger", comment: "automation editor")) {
            VStack(alignment: .leading, spacing: 10) {
                triggerKindControl
                switch draft.trigger {
                case .schedule:                        scheduleControls
                case .githubPullRequest, .githubIssue: githubControls
                case .githubCommit:                    commitControls
                case .linearIssue:                     linearControls
                }
            }
            .padding(6)
        }
    }

    /// Segmented-style trigger switch. The GitHub option stays visible when
    /// the workspace has no github.com token — greyed, with the reason and a
    /// path to fix — so the capability is discoverable.
    private var triggerKindControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                triggerButton(.schedule, label: NSLocalizedString("Schedule", comment: ""))
                triggerButton(.githubPullRequest,
                              label: NSLocalizedString("GitHub PR", comment: ""))
                    .disabled(!hasGitHubToken)
                    .help(hasGitHubToken
                          ? NSLocalizedString("Fire when a pull request is opened", comment: "")
                          : NSLocalizedString(
                              "Add a GitHub token to this workspace to enable GitHub triggers",
                              comment: ""))
                triggerButton(.githubIssue,
                              label: NSLocalizedString("GitHub Issue", comment: ""))
                    .disabled(!hasGitHubToken)
                    .help(hasGitHubToken
                          ? NSLocalizedString("Fire when an issue is opened", comment: "")
                          : NSLocalizedString(
                              "Add a GitHub token to this workspace to enable GitHub triggers",
                              comment: ""))
                triggerButton(.githubCommit,
                              label: NSLocalizedString("GitHub Commit", comment: ""))
                    .disabled(!hasGitHubToken)
                    .help(hasGitHubToken
                          ? NSLocalizedString("Fire when a commit lands on a branch", comment: "")
                          : NSLocalizedString(
                              "Add a GitHub token to this workspace to enable GitHub triggers",
                              comment: ""))
                triggerButton(.linearIssue,
                              label: NSLocalizedString("Linear", comment: ""))
                    .disabled(!hasLinearToken)
                    .help(hasLinearToken
                          ? NSLocalizedString("Fire when a Linear issue appears", comment: "")
                          : NSLocalizedString(
                              "Add a Linear API key to this workspace to enable Linear triggers",
                              comment: ""))
                Spacer()
            }
            if !hasGitHubToken || !hasLinearToken {
                HStack(spacing: 6) {
                    Text(missingTokenHint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button(NSLocalizedString("Add one…", comment: "")) {
                        onEditWorkspace(draft.profileID)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
                }
            }
        }
    }

    private var missingTokenHint: String {
        switch (hasGitHubToken, hasLinearToken) {
        case (false, false):
            return NSLocalizedString(
                "GitHub triggers need a GitHub token; Linear triggers need a Linear API key.",
                comment: "")
        case (false, true):
            return NSLocalizedString(
                "GitHub triggers need a GitHub token in this workspace.", comment: "")
        default:
            return NSLocalizedString(
                "Linear triggers need a Linear API key in this workspace.", comment: "")
        }
    }

    private func triggerButton(_ kind: ScheduledAutomation.TriggerKind,
                               label: String) -> some View {
        Button(label) { draft.trigger = kind }
            .buttonStyle(.bordered)
            .tint(draft.trigger == kind ? Color.accentColor : nil)
    }

    private func intervalLabel(_ minutes: Int) -> String {
        if minutes % 60 == 0 {
            let h = minutes / 60
            return String(format: NSLocalizedString("%d hours", comment: ""), h)
        }
        return String(format: NSLocalizedString("%d minutes", comment: ""), minutes)
    }

    @ViewBuilder
    private var scheduleControls: some View {
        Picker(NSLocalizedString("Repeats", comment: ""), selection: $draft.frequency) {
            ForEach(ScheduledAutomation.Frequency.allCases, id: \.self) {
                Text($0.displayName).tag($0)
            }
        }
        .pickerStyle(.segmented)
        if draft.frequency == .interval {
            Picker(NSLocalizedString("Every", comment: "interval"),
                   selection: $draft.intervalMinutes) {
                Text(NSLocalizedString("5 minutes", comment: "")).tag(5)
                Text(NSLocalizedString("15 minutes", comment: "")).tag(15)
                Text(NSLocalizedString("30 minutes", comment: "")).tag(30)
                Text(NSLocalizedString("Hour", comment: "")).tag(60)
                Text(NSLocalizedString("2 hours", comment: "")).tag(120)
                Text(NSLocalizedString("4 hours", comment: "")).tag(240)
                Text(NSLocalizedString("12 hours", comment: "")).tag(720)
                if ![5, 15, 30, 60, 120, 240, 720].contains(draft.intervalMinutes) {
                    Text(intervalLabel(draft.intervalMinutes)).tag(draft.intervalMinutes)
                }
            }
        } else {
            if draft.frequency == .weekly {
                Picker(NSLocalizedString("On", comment: "weekday"), selection: $draft.weekday) {
                    ForEach(1...7, id: \.self) { day in
                        Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                    }
                }
            }
            DatePicker(NSLocalizedString("At", comment: "time of day"),
                       selection: timeBinding, displayedComponents: .hourAndMinute)
        }
        Picker(NSLocalizedString("If the Mac is asleep at fire time", comment: ""),
               selection: $draft.missedRunPolicy) {
            ForEach(ScheduledAutomation.MissedRunPolicy.allCases, id: \.self) {
                Text($0.displayName).tag($0)
            }
        }
        if let next = nextFirePreview {
            Label(String(format: NSLocalizedString("Next run: %@", comment: ""),
                         next.formatted(date: .abbreviated, time: .shortened)),
                  systemImage: "clock")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        Text(NSLocalizedString(
            "Skipped runs stay visible in the run history — nothing fails silently.",
            comment: ""))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var commitControls: some View {
        repoPicker
        branchField(NSLocalizedString("Branch to watch", comment: ""),
                    selection: $draft.filters.commitBranch,
                    anyLabel: NSLocalizedString("Default branch", comment: ""))
        subfolderField
        backlogToggle
        Text(NSLocalizedString(
            "Fires for each commit on the branch touching the subfolder (whole repo if blank), once each, checked every 3 minutes. The prompt can use {{commit.title}}, {{commit.body}}, {{commit.author}}, {{commit.url}}, {{commit.key}} (short SHA); without them the commit's details are appended automatically.",
            comment: ""))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        pollStatusLine
    }

    @ViewBuilder
    private var linearControls: some View {
        Picker(NSLocalizedString("Issues", comment: "linear scope"),
               selection: $draft.assignmentFilter) {
            ForEach(ScheduledAutomation.AssignmentFilter.allCases, id: \.self) {
                Text($0.displayName).tag($0)
            }
        }
        .pickerStyle(.segmented)
        if let teams = teamChoices, !teams.isEmpty {
            Picker(NSLocalizedString("Team", comment: ""), selection: $draft.linearTeam) {
                Text(NSLocalizedString("All teams", comment: "")).tag("")
                ForEach(teams) { Text("\($0.name) (\($0.key))").tag($0.key) }
            }
        } else if teamLoadError == nil && hasLinearToken {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(NSLocalizedString("Checking the Linear key and loading teams…",
                                       comment: ""))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        if teamLoadError != nil || (teamChoices?.isEmpty ?? false) {
            if let teamLoadError {
                Label(teamLoadError, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            captioned(NSLocalizedString("Team key (optional)", comment: "")) {
                TextField("", text: $draft.linearTeam, prompt: Text(verbatim: "ENG"))
            }
        }
        filtersGroup(isPR: false, isLinear: true)
        backlogToggle
        Text(NSLocalizedString(
            "Each issue runs once, checked every 3 minutes with the workspace's Linear API key — no webhooks.",
            comment: ""))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Text(NSLocalizedString(
            "The prompt can use {{issue.key}}, {{issue.title}}, {{issue.body}}, {{issue.branch}}, {{issue.author}}, {{issue.url}}. Without them, the issue's details are appended automatically.",
            comment: ""))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        pollStatusLine
    }

    @ViewBuilder
    private var githubControls: some View {
        let isIssue = draft.trigger == .githubIssue
        let ns = isIssue ? "issue" : "pr"
        repoPicker
        if isIssue {
            Picker(NSLocalizedString("Issues", comment: "issue scope"),
                   selection: $draft.assignmentFilter) {
                ForEach(ScheduledAutomation.AssignmentFilter.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            .pickerStyle(.segmented)
        }
        filtersGroup(isPR: !isIssue, isLinear: false)
        backlogToggle
        if isIssue {
            Text(NSLocalizedString(
                "The issue's comments are included in the agent's context automatically (and screened for prompt injection).",
                comment: ""))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        Text(String(format: NSLocalizedString(
            "Each event runs once, checked every 3 minutes with the workspace's GitHub token — no webhooks. The prompt can use {{%@.number}}, {{%@.title}}, {{%@.body}}, {{%@.author}}, {{%@.url}}; without them the details are appended automatically.",
            comment: "template namespace"), ns, ns, ns, ns, ns))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        pollStatusLine
    }

    /// Shared across every event trigger. Default-on; the caption states what
    /// "off" does so the long explanation isn't needed.
    @ViewBuilder
    private var backlogToggle: some View {
        Toggle(NSLocalizedString("Ignore backlog", comment: ""),
               isOn: $draft.ignoreBacklog)
        Text(draft.ignoreBacklog
             ? NSLocalizedString(
                "Only items appearing after you save fire. The existing open items are skipped.",
                comment: "")
             : NSLocalizedString(
                "The existing open backlog is processed once, too, then new items as they appear.",
                comment: ""))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var repoPicker: some View {
        if let repos = repoChoices, !repos.isEmpty {
            Picker(NSLocalizedString("Repository", comment: ""),
                   selection: $draft.githubRepo) {
                if !repos.contains(draft.githubRepo) {
                    Text(draft.githubRepo.isEmpty
                         ? NSLocalizedString("Choose…", comment: "")
                         : draft.githubRepo).tag(draft.githubRepo)
                }
                ForEach(repos, id: \.self) { Text($0).tag($0) }
            }
        } else if repoLoadError == nil && hasGitHubToken {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(NSLocalizedString("Checking the GitHub token and loading repositories…",
                                       comment: ""))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        if repoLoadError != nil || (repoChoices?.isEmpty ?? false) {
            if let repoLoadError {
                Label(repoLoadError, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            // Fetch failed or returned nothing — free-text entry still works.
            captioned(NSLocalizedString("Repository", comment: "")) {
                TextField("", text: $draft.githubRepo, prompt: Text(verbatim: "owner/repo"))
            }
        }
    }

    /// "Last checked 14:32 · 12 open · watching for new items" — or the
    /// poll's error. The direct answer to "is this even polling?".
    @ViewBuilder
    private var pollStatusLine: some View {
        if !isNew, let state = store.pollState(for: draft.id) {
            if let err = state.lastError {
                Label(String(format: NSLocalizedString("Last check failed: %@", comment: ""), err),
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            } else if let at = state.lastPolledAt {
                let count = state.lastOpenCount.map {
                    String(format: NSLocalizedString("%d open", comment: "poll status"), $0)
                }
                let base = state.highWater == nil
                    ? NSLocalizedString("baseline set", comment: "poll status")
                    : NSLocalizedString("watching for new items", comment: "poll status")
                Label([at.formatted(date: .omitted, time: .shortened), count, base]
                          .compactMap(\.self)
                          .joined(separator: " · "),
                      systemImage: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } else if !isNew {
            Label(NSLocalizedString("First check runs within 30 seconds of saving.",
                                    comment: ""),
                  systemImage: "antenna.radiowaves.left.and.right")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var taskSection: some View {
        GroupBox(NSLocalizedString("Task", comment: "automation editor")) {
            VStack(alignment: .leading, spacing: 10) {
                Picker(NSLocalizedString("Workspace", comment: ""), selection: $draft.profileID) {
                    ForEach(profiles) { p in
                        Text(p.name).tag(p.id)
                    }
                }
                .onChange(of: draft.profileID) {
                    // The new workspace may not have the previously chosen
                    // agent configured — snap to its primary.
                    if !toolChoices.contains(where: { $0.tool == draft.tool }),
                       let primary = selectedProfile?.tool {
                        draft.tool = primary
                    }
                    // And it may lack the credential the trigger needs.
                    if !triggerAvailable(draft.trigger) {
                        draft.trigger = .schedule
                    }
                }
                Picker(NSLocalizedString("Agent", comment: ""), selection: $draft.tool) {
                    ForEach(toolChoices) { spec in
                        Text("\(spec.tool.displayName) — \(spec.authMode.displayName)")
                            .tag(spec.tool)
                    }
                }
                if selectedSpec?.authMode == .subscription {
                    Label(NSLocalizedString(
                        "This agent signs in interactively — an expired login can stall an unattended run.",
                        comment: ""), systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                TextField(NSLocalizedString("Repository path in the workspace", comment: ""),
                          text: $draft.repoPath, prompt: Text(verbatim: "~/my-repo"))
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("Prompt", comment: ""))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $draft.prompt)
                        .font(.system(size: 12))
                        .frame(minHeight: 88)
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.primary.opacity(0.12)))
                    Text(NSLocalizedString(
                        "Each run starts the agent with this prompt — in a fresh worktree when the path is a git repo, in a plain tab at that path otherwise.",
                        comment: ""))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
    }

    private var finishSection: some View {
        GroupBox(NSLocalizedString("When it finishes", comment: "automation editor")) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(NSLocalizedString(
                    "Close the tab when the agent finishes", comment: ""),
                       isOn: $draft.closeWhenDone)
                    .disabled(draft.tool != .claude)
                Text(draft.tool == .claude
                     ? NSLocalizedString(
                        "The transcript is saved to .bromure-automation/transcript.jsonl in the worktree first. Turn off to leave the session up for inspection.",
                        comment: "")
                     : NSLocalizedString(
                        "Only Claude reports completion reliably (its Stop hook); other agents' tabs stay open.",
                        comment: ""))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
        }
    }

    /// The amber banner from the design: named credentials, stated
    /// consequence, and a one-click path to fix — never a save blocker.
    private var unattendedWarning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("Won't run fully unattended", comment: ""))
                    .font(.system(size: 12, weight: .semibold))
                Text(String(format: NSLocalizedString(
                    "%@ %@ set to Ask before use. A run that needs %@ will pause in the consent dialog until you approve it on this Mac.",
                    comment: "list of credentials, is/are, it/them"),
                    askLabels.joined(separator: ", "),
                    askLabels.count == 1
                        ? NSLocalizedString("is", comment: "") : NSLocalizedString("are", comment: ""),
                    askLabels.count == 1
                        ? NSLocalizedString("it", comment: "") : NSLocalizedString("them", comment: "")))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(NSLocalizedString("Open Workspace Settings…", comment: "")) {
                    onEditWorkspace(draft.profileID)
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color.orange.opacity(0.35)))
    }

    private var runsSection: some View {
        GroupBox(NSLocalizedString("Recent runs", comment: "automation editor")) {
            let recent = Array(store.runs(for: draft.id).prefix(8))
            VStack(alignment: .leading, spacing: 6) {
                if recent.isEmpty {
                    Text(NSLocalizedString("No runs yet.", comment: ""))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                ForEach(recent) { run in
                    HStack(spacing: 8) {
                        Image(systemName: run.outcome.glyph)
                            .font(.system(size: 11))
                            .foregroundStyle(run.outcome.tint)
                        Text(run.firedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 11).monospacedDigit())
                        Text(run.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(6)
        }
    }

    private var footer: some View {
        HStack {
            if !isNew {
                Button(NSLocalizedString("Delete Automation…", comment: ""), role: .destructive) {
                    onDelete(draft.id)
                }
            }
            Spacer()
            if !canSave {
                Text(String(format: NSLocalizedString("To save: %@", comment: ""),
                            saveBlockers.joined(separator: ", ")))
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
            Button(NSLocalizedString("Run Now", comment: "")) {
                onRunNow(draft)
            }
            .disabled(!canSave)
            .help(NSLocalizedString("Saves, then fires immediately — the schedule is untouched.",
                                    comment: ""))
            Button(NSLocalizedString("Save", comment: "")) {
                onSave(draft)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
    }
}
