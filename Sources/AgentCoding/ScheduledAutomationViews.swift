import SwiftUI

// MARK: - Sidebar section

/// Red numeric badge for the sidebar sections — "N items need you".
/// Renders nothing at zero.
/// A relative timestamp that stays current. A plain formatted string only
/// re-renders when something else invalidates the view tree, so a quiet
/// board shows "started 1 sec ago" forever — this recomputes on a timer.
struct RelativeTimeText: View {
    /// Format with one %@ placeholder for the relative time ("started %@"),
    /// or nil for the bare relative time.
    var format: String?
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { _ in
            let rel = date.formatted(.relative(presentation: .named))
            Text(format.map { String(format: $0, rel) } ?? rel)
        }
    }
}

struct SidebarAttentionBadge: View {
    let count: Int
    var tint: Color = .red

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 9.5, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(tint))
        }
    }
}

/// "Automations" — a board-first sidebar section: header (title and icon
/// open the board, "+" creates) plus ONE status row with the pulse — count,
/// running, soonest next fire — and a red badge when runs need the user.
/// The per-automation rows are gone: they duplicated the board's Scheduled
/// column, and the board is one click (or ⇧⌘A) away.
struct AutomationsSection: View {
    var store: ScheduledAutomationStore
    @Bindable var model: SessionListModel
    let onNew: () -> Void
    /// Open the kanban board (Scheduled / In Progress / Done) in the stage.
    let onShowBoard: () -> Void

    private static let fireFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        return f
    }()

    /// Live launched runs and their agent status — resolved through the
    /// sidebar's tab models, same matching as the board.
    private var liveRuns: [AgentStatus] {
        store.runs.compactMap { run in
            guard run.outcome == .launched, run.completedAt == nil,
                  let slug = run.branchSlug,
                  let pid = run.runProfileID
                      ?? store.automation(run.automationID)?.profileID,
                  let entry = model.entries.first(where: { $0.id == pid })
            else { return nil }
            return entry.model.tabs.first {
                AutomationBoard.branchMatches($0.worktreeBranch, slug: slug)
            }?.agentStatus
        }
    }

    /// What the badge counts: the board's Needs Attention column
    /// (unacknowledged failed/blocked runs) plus live agents waiting on
    /// the user.
    private var attentionCount: Int {
        let parked = store.runs.filter {
            ($0.outcome == .failed || $0.outcome == .blocked)
                && $0.acknowledgedAt == nil
        }.count
        return parked + liveRuns.filter { $0 == .needsInput }.count
    }

    private var statusLine: String {
        guard !store.automations.isEmpty else {
            return NSLocalizedString("Open the board", comment: "automations sidebar")
        }
        var parts = ["\(store.automations.count)"]
        let running = liveRuns.count
        if running > 0 {
            parts.append(String(format: NSLocalizedString("%d running", comment: ""), running))
        }
        if let next = store.automations.filter(\.enabled)
            .compactMap({ store.nextFire(for: $0.id) }).min() {
            parts.append(String(format: NSLocalizedString("next %@", comment: ""),
                                Self.fireFormatter.string(from: next)))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                // The title itself opens the board — the icon alone was easy
                // to miss.
                Button(action: onShowBoard) {
                    Text("Automations")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(model.automationBoardSelected
                                         ? Color.accentColor : .secondary)
                        .textCase(.uppercase)
                        .tracking(0.7)
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("Open the automation board (⇧⌘A)", comment: ""))
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

            Button(action: onShowBoard) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.badge.clock")
                        .font(.system(size: 11))
                        .foregroundStyle(attentionCount > 0 ? .red : .secondary)
                    Text(statusLine)
                        .font(.system(size: 12))
                        .foregroundStyle(model.automationBoardSelected ? .primary : .secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    SidebarAttentionBadge(count: attentionCount)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(model.automationBoardSelected
                      ? Color.accentColor.opacity(0.16) : .clear))
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
    case .afterAutomation:
        return NSLocalizedString("Chained", comment: "row summary")
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
/// agreed design: Workspace (first — it decides which triggers and agents
/// are available), Trigger, Task, unattended-run warnings, recent runs.
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
    /// Fires whenever the draft starts/stops differing from what's stored,
    /// so the AppKit host can warn before tearing down an edited draft.
    let onDirtyChange: (Bool) -> Void
    /// Compact = iPhone portrait → trigger pills scroll horizontally.
    @Environment(\.horizontalSizeClass) private var hSize
    private var compact: Bool { hSize == .compact }

    @State private var draft: ScheduledAutomation
    /// The draft as presented — the baseline for the dirty check.
    private let original: ScheduledAutomation
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
         onEditWorkspace: @escaping (UUID) -> Void,
         onDirtyChange: @escaping (Bool) -> Void = { _ in }) {
        self.store = store
        self.profiles = profiles
        self.onSave = onSave
        self.onRunNow = onRunNow
        self.onDelete = onDelete
        self.onEditWorkspace = onEditWorkspace
        self.onDirtyChange = onDirtyChange
        if let id, let existing = store.automation(id) {
            _draft = State(initialValue: existing)
            original = existing
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
            original = fresh
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
        case .afterAutomation:
            if let up = draft.chainedAutomationID, store.automation(up) != nil {
                if chainWouldLoop {
                    out.append(NSLocalizedString("break the automation loop",
                                                 comment: "save blocker"))
                }
            } else {
                out.append(NSLocalizedString("pick the automation this one follows",
                                             comment: "save blocker"))
            }
        }
        return out
    }

    /// Would saving the draft's chain link close a loop (A → … → A)?
    /// Evaluated against the stored automations with the draft substituted in.
    private var chainWouldLoop: Bool {
        var all = store.automations.filter { $0.id != draft.id }
        all.append(draft)
        return ScheduledAutomation.chainCycles(from: draft.id, in: all)
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
            VStack(alignment: .leading, spacing: 22) {
                header
                Divider()
                workspaceSection
                triggerSection
                taskSection
                finishSection
                if !askLabels.isEmpty { unattendedWarning }
                if !isNew { runsSection }
            }
            .padding(.horizontal, 30)
            .padding(.top, 26)
            .padding(.bottom, 12)
            .frame(maxWidth: 660, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color.platformWindowBackground)
        // Pinned action bar so Save/Run are always reachable without scrolling.
        .safeAreaInset(edge: .bottom, spacing: 0) { footerBar }
        // Reload the repo/team dropdowns whenever the workspace (and so the
        // tokens) changes. Doubles as a live token check.
        .task(id: draft.profileID) { await loadTriggerSources() }
        // Branches + directories depend on the chosen repo AND branch.
        .task(id: repoBranchKey) { await loadRepoDetails() }
        // Tell the host when the draft diverges from (or returns to) what's
        // stored, so navigating away can warn before discarding it.
        .onChange(of: draft) { onDirtyChange(draft != original) }
    }

    /// Standardised secondary helper text under a control.
    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "bolt.badge.clock.fill")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.accentColor.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                TextField(NSLocalizedString("Automation name", comment: ""), text: $draft.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .bold))
                Text(headerSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(spacing: 3) {
                Toggle(NSLocalizedString("Enabled", comment: ""), isOn: $draft.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                Text(draft.enabled
                     ? NSLocalizedString("Enabled", comment: "")
                     : NSLocalizedString("Paused", comment: ""))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// One-line context under the name: where it runs and what fires it.
    private var headerSubtitle: String {
        let ws = selectedProfile?.name ?? NSLocalizedString("no workspace", comment: "")
        let trigger: String
        switch draft.trigger {
        case .schedule:          trigger = NSLocalizedString("on a schedule", comment: "")
        case .githubPullRequest: trigger = NSLocalizedString("on new pull requests", comment: "")
        case .githubIssue:       trigger = NSLocalizedString("on new issues", comment: "")
        case .githubCommit:      trigger = NSLocalizedString("on new commits", comment: "")
        case .linearIssue:       trigger = NSLocalizedString("on new Linear issues", comment: "")
        case .afterAutomation:   trigger = NSLocalizedString("after another automation", comment: "")
        }
        return String(format: NSLocalizedString("Runs in %1$@ · %2$@", comment: "workspace · trigger"),
                      ws, trigger)
    }

    private var triggerSection: some View {
        GroupBox(label: sectionLabel(NSLocalizedString("Trigger", comment: "automation editor"),
                                     "bolt.fill")) {
            VStack(alignment: .leading, spacing: 13) {
                triggerKindControl
                switch draft.trigger {
                case .schedule:                        scheduleControls
                case .githubPullRequest, .githubIssue: githubControls
                case .githubCommit:                    commitControls
                case .linearIssue:                     linearControls
                case .afterAutomation:                 chainControls
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 10)
        }
    }

    /// GroupBox title with a leading SF Symbol, for scannable sections.
    private func sectionLabel(_ title: String, _ symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    /// Segmented-style trigger switch. The GitHub option stays visible when
    /// the workspace has no github.com token — greyed, with the reason and a
    /// path to fix — so the capability is discoverable.
    private var triggerKindControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Six trigger pills don't fit a phone row, so they scroll
            // horizontally there; the desktop keeps the full inline row.
            if compact {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { triggerButtons }.padding(.vertical, 1)
                }
            } else {
                HStack(spacing: 2) {
                    triggerButtons
                    Spacer()
                }
            }
            if !hasGitHubToken || !hasLinearToken {
                HStack(spacing: 6) {
                    Text(missingTokenHint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button(NSLocalizedString("Add one…", comment: "")) {
                        onEditWorkspace(draft.profileID)
                    }
                    .platformLinkButtonStyle()
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

    @ViewBuilder private var triggerButtons: some View {
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
        triggerButton(.afterAutomation,
                      label: NSLocalizedString("After automation", comment: ""))
            .help(NSLocalizedString(
                "Fire when another automation's run finishes", comment: ""))
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
            // Label + control paired by hand: the bare DatePicker sizes its
            // field to the bone and "9:00 AM" barely fits — give it room.
            HStack(spacing: 8) {
                Text(NSLocalizedString("At", comment: "time of day"))
                DatePicker("", selection: timeBinding,
                           displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .frame(width: 110)
            }
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

    /// "After automation" trigger: pick the upstream automation whose
    /// finished run fires this one. Loops are refused via saveBlockers.
    @ViewBuilder
    private var chainControls: some View {
        let others = store.automations.filter { $0.id != draft.id }
        if others.isEmpty {
            hint(NSLocalizedString(
                "No other automations yet — create the one this should follow first.",
                comment: ""))
        } else {
            Picker(NSLocalizedString("Runs after", comment: "chain trigger"),
                   selection: $draft.chainedAutomationID) {
                Text(NSLocalizedString("Choose…", comment: "")).tag(UUID?.none)
                ForEach(others) { other in
                    Text(other.name.isEmpty
                         ? NSLocalizedString("Untitled automation", comment: "")
                         : other.name).tag(Optional(other.id))
                }
            }
            if let upID = draft.chainedAutomationID, let up = store.automation(upID) {
                if chainWouldLoop {
                    Label(NSLocalizedString(
                        "This choice closes a loop — the chain would fire itself forever.",
                        comment: ""), systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                } else if up.tool != .claude {
                    Label(String(format: NSLocalizedString(
                        "“%@” runs %@ — only Claude runs report finishing, so this chain will never fire.",
                        comment: "upstream name, tool"),
                        up.name, up.tool.displayName),
                        systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
            }
            hint(NSLocalizedString(
                "Fires when the chosen automation's run reports done, in this automation's own workspace and repository path. The prompt can use {{chain.automation}} and {{chain.branch}} (the upstream run's worktree branch — its work, if both automations share a repository); without them that context is appended automatically.",
                comment: ""))
        }
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
        hint(draft.ignoreBacklog
             ? NSLocalizedString(
                "Only items appearing after you save fire. The existing open items are skipped.",
                comment: "")
             : NSLocalizedString(
                "The existing open backlog is processed once, too, then new items as they appear.",
                comment: ""))
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

    /// First section by design: the chosen workspace decides which triggers
    /// are available (its tokens) and which agents can run the task.
    private var workspaceSection: some View {
        GroupBox(label: sectionLabel(NSLocalizedString("Workspace", comment: "automation editor"),
                                     "macwindow")) {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $draft.profileID) {
                    ForEach(profiles) { p in
                        Text(p.name).tag(p.id)
                    }
                }
                .labelsHidden()
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
                hint(NSLocalizedString(
                    "The workspace's credentials decide which triggers are available, and its agents run the task.",
                    comment: ""))
                Toggle(NSLocalizedString("Start the workspace if needed", comment: ""),
                       isOn: $draft.startWorkspaceIfNeeded)
                hint(draft.startWorkspaceIfNeeded
                     ? NSLocalizedString(
                        "A fire while the workspace is off or suspended boots it first.",
                        comment: "")
                     : NSLocalizedString(
                        "A fire while the workspace isn't running is recorded as skipped.",
                        comment: ""))
                Toggle(NSLocalizedString("Run in a disposable clone of the workspace",
                                         comment: ""),
                       isOn: $draft.cloneWorkspaceFirst)
                    .disabled(draft.tool != .claude)
                hint(draft.tool != .claude
                     ? NSLocalizedString(
                        "Clone runs are Claude-only — tearing the clone down needs Claude's reliable completion signal.",
                        comment: "")
                     : (draft.cloneWorkspaceFirst
                        ? NSLocalizedString(
                            "Each run copies this workspace (settings, credentials, home), boots the copy, and deletes it when the run finishes — have the prompt push results to a remote. With “Close the tab…” off, the clone is kept for inspection instead.",
                            comment: "")
                        : NSLocalizedString(
                            "The run executes in this workspace itself, as a worktree tab.",
                            comment: "")))
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 10)
        }
    }

    private var taskSection: some View {
        GroupBox(label: sectionLabel(NSLocalizedString("Task", comment: "automation editor"),
                                     "terminal.fill")) {
            VStack(alignment: .leading, spacing: 13) {
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
                captioned(NSLocalizedString(
                    "Start the agent in — a folder inside the workspace (\"~\" is home)",
                    comment: "automation editor")) {
                    TextField("", text: $draft.repoPath, prompt: Text(verbatim: "~/my-repo"))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(NSLocalizedString("Prompt", comment: ""))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $draft.prompt)
                        .font(.system(size: 12))
                        .frame(minHeight: 88)
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.primary.opacity(0.12)))
                    hint(NSLocalizedString(
                        "Each run starts the agent with this prompt — in a fresh worktree when the path is a git repo, in a plain tab at that path otherwise.",
                        comment: ""))
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 10)
        }
    }

    private var finishSection: some View {
        GroupBox(label: sectionLabel(NSLocalizedString("When it finishes", comment: "automation editor"),
                                     "checkmark.circle.fill")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(NSLocalizedString(
                    "Close the tab when the agent finishes", comment: ""),
                       isOn: $draft.closeWhenDone)
                    .disabled(draft.tool != .claude)
                hint(draft.tool == .claude
                     ? NSLocalizedString(
                        "The transcript is saved first — readable any time from the run's card on the automation board. Turn off to leave the session up for inspection.",
                        comment: "")
                     : NSLocalizedString(
                        "Only Claude reports completion reliably (its Stop hook); other agents' tabs stay open.",
                        comment: ""))
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 10)
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
        GroupBox(label: sectionLabel(NSLocalizedString("Recent runs", comment: "automation editor"),
                                     "clock.arrow.circlepath")) {
            let recent = Array(store.runs(for: draft.id).prefix(8))
            VStack(alignment: .leading, spacing: 7) {
                if recent.isEmpty {
                    hint(NSLocalizedString("No runs yet.", comment: ""))
                }
                ForEach(recent) { run in
                    HStack(spacing: 8) {
                        Image(systemName: run.outcome.glyph)
                            .font(.system(size: 11))
                            .foregroundStyle(run.outcome.tint)
                            .frame(width: 14)
                        Text(run.firedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(run.detail)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 10)
        }
    }

    /// Pinned action bar at the bottom of the editor.
    private var footerBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 10) {
                if !isNew {
                    Button(NSLocalizedString("Delete…", comment: ""), role: .destructive) {
                        onDelete(draft.id)
                    }
                    .controlSize(.large)
                }
                if !canSave {
                    Label(String(format: NSLocalizedString("To save: %@", comment: ""),
                                 saveBlockers.joined(separator: ", ")),
                          systemImage: "exclamationmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                Spacer(minLength: 12)
                Button(NSLocalizedString("Run Now", comment: "")) {
                    onRunNow(draft)
                }
                .controlSize(.large)
                .disabled(!canSave)
                .help(NSLocalizedString("Saves, then fires immediately — the schedule is untouched.",
                                        comment: ""))
                Button(NSLocalizedString("Save", comment: "")) {
                    onSave(draft)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 12)
        }
        .background(.bar)
    }
}
