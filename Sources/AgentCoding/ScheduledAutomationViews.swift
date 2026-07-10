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
    if a.trigger != .schedule {
        let kind = a.trigger == .githubIssue ? "Issue" : "PR"
        return "\(kind) · " + (a.githubRepo.isEmpty ? "?" : a.githubRepo)
    }
    let time = String(format: "%d:%02d", a.hour, a.minute)
    switch a.frequency {
    case .daily:    return String(format: NSLocalizedString("Every day %@", comment: ""), time)
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
        }
    }
    var tint: Color {
        switch self {
        case .launched: return .green
        case .skipped:  return .secondary
        case .failed:   return .red
        }
    }
    var helpText: String {
        switch self {
        case .launched: return NSLocalizedString("Last run launched", comment: "")
        case .skipped:  return NSLocalizedString("Last run skipped (Mac was asleep)", comment: "")
        case .failed:   return NSLocalizedString("Last run failed", comment: "")
        }
    }
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

    init(store: ScheduledAutomationStore,
         profiles: [Profile],
         editing id: UUID?,
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
            isNew = false
        } else {
            var fresh = ScheduledAutomation(profileID: profiles.first?.id ?? UUID())
            if let first = profiles.first { fresh.tool = first.tool }
            _draft = State(initialValue: fresh)
            isNew = true
        }
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
        if draft.trigger != .schedule {
            if !GitHubPRPoller.isValidRepoSlug(draft.githubRepo) {
                out.append(NSLocalizedString("set the repository as owner/name",
                                             comment: "save blocker"))
            }
            if !hasGitHubToken {
                out.append(NSLocalizedString("add a GitHub token to the workspace",
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
                if !askLabels.isEmpty { unattendedWarning }
                if !isNew { runsSection }
                footer
            }
            .padding(24)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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
                if draft.trigger == .schedule {
                    scheduleControls
                } else {
                    githubControls
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
                Spacer()
            }
            if !hasGitHubToken {
                HStack(spacing: 6) {
                    Text(NSLocalizedString(
                        "PR triggers need a GitHub token in this workspace.",
                        comment: ""))
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

    private func triggerButton(_ kind: ScheduledAutomation.TriggerKind,
                               label: String) -> some View {
        Button(label) { draft.trigger = kind }
            .buttonStyle(.bordered)
            .tint(draft.trigger == kind ? Color.accentColor : nil)
    }

    @ViewBuilder
    private var scheduleControls: some View {
        Picker(NSLocalizedString("Repeats", comment: ""), selection: $draft.frequency) {
            ForEach(ScheduledAutomation.Frequency.allCases, id: \.self) {
                Text($0.displayName).tag($0)
            }
        }
        .pickerStyle(.segmented)
        if draft.frequency == .weekly {
            Picker(NSLocalizedString("On", comment: "weekday"), selection: $draft.weekday) {
                ForEach(1...7, id: \.self) { day in
                    Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                }
            }
        }
        DatePicker(NSLocalizedString("At", comment: "time of day"),
                   selection: timeBinding, displayedComponents: .hourAndMinute)
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
    private var githubControls: some View {
        let isIssue = draft.trigger == .githubIssue
        let ns = isIssue ? "issue" : "pr"
        TextField(NSLocalizedString("Repository", comment: ""),
                  text: $draft.githubRepo, prompt: Text(verbatim: "owner/repo"))
        Text(String(format: NSLocalizedString(
            "Fires when %@ is opened. Checked every 3 minutes from this Mac with the workspace's GitHub token — no webhooks, nothing listens on the network.",
            comment: "a pull request / an issue"),
            isIssue ? NSLocalizedString("an issue", comment: "")
                    : NSLocalizedString("a pull request", comment: "")))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Text(String(format: NSLocalizedString(
            "The prompt can use {{%@.number}}, {{%@.title}}, {{%@.body}}, {{%@.author}}, {{%@.url}}. Without them, the details are appended automatically.",
            comment: "template namespace"), ns, ns, ns, ns, ns))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
                    // And it may lack the GitHub token the GitHub triggers need.
                    if draft.trigger != .schedule && !hasGitHubToken {
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
