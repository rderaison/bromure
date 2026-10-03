#if os(macOS)
import AppKit
import SwiftUI

// MARK: - Automations home
//
// The hub's first tab: everything set up to run on its own, grouped by what
// starts it — a schedule, a GitHub / Linear event, or a repository security
// watch — each row saying in words when it runs, what it does, and how it
// last went.

struct AutomationsHomeTab: View {
    var automationStore: ScheduledAutomationStore
    var findingStore: FindingStore
    @Bindable var model: SessionListModel
    @Bindable var hub: AutomationHubModel
    let actions: AutomationHubView.Actions
    var onChoose: (AutomationDescriber.Kind) -> Void

    /// Runs whose session is up right now.
    private var liveRunIDs: Set<UUID> {
        var out = Set<UUID>()
        for run in automationStore.runs where run.outcome == .launched && run.completedAt == nil {
            guard let slug = run.branchSlug,
                  let pid = run.runProfileID ?? automationStore.automation(run.automationID)?.profileID,
                  let entry = model.entries.first(where: { $0.id == pid }) else { continue }
            if entry.model.tabs.contains(where: {
                AutomationBoard.branchMatches($0.worktreeBranch, slug: slug)
            }) { out.insert(run.id) }
        }
        return out
    }

    private var own: [ScheduledAutomation] {
        automationStore.automations.filter { $0.watchID == nil }
            .sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        let live = liveRunIDs
        let scheduled = own.filter { $0.trigger == .schedule }
        let events = own.filter { $0.trigger != .schedule }
        let watches = findingStore.watches
        let attention = AutomationBoard.classify(runs: automationStore.runs) { live.contains($0.id) }
            .needsAttention
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if scheduled.isEmpty && events.isEmpty && watches.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(NSLocalizedString("Nothing runs on its own yet", comment: "automations home"))
                            .font(.system(size: 22, weight: .semibold))
                        Text(NSLocalizedString(
                            "Pick what should start an agent. Every automation runs unattended in one of your workspaces, under its credentials and guardrails.",
                            comment: "automations home"))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    AutomationKindCards(onChoose: onChoose)
                } else {
                    if !attention.isEmpty {
                        attentionBanner(attention.count)
                    }
                    section(.scheduled, count: scheduled.count) {
                        ForEach(scheduled) { a in row(a, live: live) }
                    }
                    section(.event, count: events.count) {
                        ForEach(events) { a in row(a, live: live) }
                    }
                    section(.security, count: watches.count) {
                        ForEach(watches) { w in
                            WatchSummaryRow(
                                watch: w,
                                automationStore: automationStore,
                                findings: findingStore.findings(forWatch: w.id),
                                workspace: model.profileRows.first { $0.id == w.profileID },
                                scanning: w.automationIDs.values.contains { aid in
                                    automationStore.runs.contains { $0.automationID == aid && live.contains($0.id) }
                                },
                                onOpen: {
                                    hub.repoFilter = w.repo
                                    hub.showSecurity(.findings)
                                },
                                onEdit: {
                                    hub.editingWatchIsNew = false
                                    hub.editingWatch = w
                                },
                                onScan: { actions.scanNow(w.id) },
                                onToggle: { actions.toggleWatch(w.id) })
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func row(_ a: ScheduledAutomation, live: Set<UUID>) -> some View {
        let runs = automationStore.runs(for: a.id)
        let running = runs.filter { live.contains($0.id) }.count
        let upstream = a.chainedAutomationID.flatMap { automationStore.automation($0)?.name }
        return AutomationListRow(
            automation: a,
            workspace: model.profileRows.first { $0.id == a.profileID },
            upstreamName: upstream,
            nextFire: automationStore.nextFire(for: a.id),
            lastRun: runs.first { $0.outcome != .skipped || $0.itemKey == nil },
            pollState: automationStore.pollState(for: a.id),
            runningCount: running,
            onEdit: { actions.board.selectAutomation(a.id) },
            onRunNow: { actions.board.runNow(a.id) },
            onToggle: { actions.board.toggle(a.id) },
            onDelete: { actions.board.delete(a.id) },
            onShowRuns: { hub.tab = .runs })
    }

    private func attentionBanner(_ n: Int) -> some View {
        Button {
            hub.tab = .runs
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(String(format: NSLocalizedString("%d run(s) need your attention", comment: "automations home"), n))
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
                Text(NSLocalizedString("Open Runs", comment: "automations home"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.orange.opacity(0.3)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func section<Content: View>(_ kind: AutomationDescriber.Kind, count: Int,
                                        @ViewBuilder rows: () -> Content) -> some View {
        let tint = AutomationKindCards.tint(kind)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: AutomationKindCards.icon(kind))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 26, height: 26)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(AutomationKindCards.title(kind))
                            .font(.system(size: 14, weight: .semibold))
                        if count > 0 {
                            Text("\(count)")
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Color.primary.opacity(0.07), in: Capsule())
                        }
                    }
                    Text(AutomationKindCards.tagline(kind))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    onChoose(kind)
                } label: {
                    Label(NSLocalizedString("Add", comment: "automations home"), systemImage: "plus")
                }
                .controlSize(.small)
            }
            if count == 0 {
                Button {
                    onChoose(kind)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle")
                        Text(emptyText(kind))
                        Spacer()
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .foregroundStyle(Color.primary.opacity(0.18)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 8) { rows() }
            }
        }
    }

    private func emptyText(_ kind: AutomationDescriber.Kind) -> String {
        switch kind {
        case .scheduled:
            return NSLocalizedString("No scheduled automations — e.g. a weekday-morning triage of open issues", comment: "automations home")
        case .event:
            return NSLocalizedString("No event automations — e.g. review every new pull request", comment: "automations home")
        case .security:
            return NSLocalizedString("No repository is watched — set up a continuous code review", comment: "automations home")
        }
    }
}

// MARK: - Rows

struct AutomationListRow: View {
    let automation: ScheduledAutomation
    let workspace: SessionListModel.ProfileRow?
    let upstreamName: String?
    let nextFire: Date?
    let lastRun: AutomationRunRecord?
    let pollState: ScheduledAutomationStore.PRPollState?
    let runningCount: Int
    var onEdit: () -> Void
    var onRunNow: () -> Void
    var onToggle: () -> Void
    var onDelete: () -> Void
    var onShowRuns: () -> Void
    @State private var hovering = false

    private var name: String {
        automation.name.isEmpty ? NSLocalizedString("Untitled automation", comment: "") : automation.name
    }

    var body: some View {
        let kind = AutomationDescriber.kind(of: automation)
        let tint = AutomationKindCards.tint(kind)
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill((automation.enabled ? tint : Color.secondary).opacity(0.13))
                Image(systemName: triggerIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(automation.enabled ? tint : .secondary)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                    if !automation.enabled {
                        Text(NSLocalizedString("Paused", comment: "watch"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Text(AutomationDescriber.when(automation, upstreamName: upstreamName))
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.8))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let workspace {
                        Circle().fill(Color(hex: workspace.accentHex)).frame(width: 6, height: 6)
                    }
                    Text(AutomationDescriber.what(automation, workspace: workspace?.name ?? "?"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            status
                .frame(minWidth: 150, alignment: .trailing)
            HStack(spacing: 4) {
                Button(action: onRunNow) {
                    Image(systemName: "play.fill").font(.system(size: 11))
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(NSLocalizedString("Run now", comment: "automations home"))
                Toggle("", isOn: Binding(get: { automation.enabled }, set: { _ in onToggle() }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help(automation.enabled ? NSLocalizedString("Pause", comment: "")
                                             : NSLocalizedString("Resume", comment: ""))
                Menu {
                    Button(NSLocalizedString("Edit…", comment: ""), action: onEdit)
                    Button(NSLocalizedString("Run Now", comment: ""), action: onRunNow)
                    Button(NSLocalizedString("Show Runs", comment: "automations home"), action: onShowRuns)
                    Divider()
                    Button(NSLocalizedString("Delete…", comment: ""), role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .modifier(FloatingCardBackground(cornerRadius: 12, hovering: hovering))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovering = $0 }
        .onTapGesture(perform: onEdit)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var triggerIcon: String {
        switch automation.trigger {
        case .schedule:          return automation.frequency == .interval ? "arrow.clockwise" : "clock"
        case .githubPullRequest: return "arrow.triangle.pull"
        case .githubIssue:       return "exclamationmark.circle"
        case .githubCommit:      return "point.topleft.down.to.point.bottomright.curvepath"
        case .linearIssue:       return "line.3.horizontal.decrease.circle"
        case .afterAutomation:   return "link"
        }
    }

    /// Right-hand status: what's happening now, then how it last went.
    @ViewBuilder private var status: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if runningCount > 0 {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(runningCount == 1
                         ? NSLocalizedString("Running now", comment: "automations home")
                         : String(format: NSLocalizedString("%d running", comment: ""), runningCount))
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.blue)
            } else if let err = pollState?.lastError, automation.enabled {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(err)
            } else if automation.enabled, automation.trigger == .schedule, let next = nextFire {
                Text(String(format: NSLocalizedString("Next %@", comment: "automations home"),
                            next.formatted(.relative(presentation: .named))))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } else if automation.enabled, automation.trigger != .schedule,
                      automation.trigger != .afterAutomation {
                Text(pollState?.lastPolledAt.map {
                    String(format: NSLocalizedString("Watching · checked %@", comment: "automations home"),
                           $0.formatted(.relative(presentation: .named)))
                } ?? NSLocalizedString("watching", comment: "scan line"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            if let last = lastRun {
                HStack(spacing: 4) {
                    Image(systemName: last.completedAt != nil ? "checkmark.circle.fill" : last.outcome.glyph)
                        .foregroundStyle(last.completedAt != nil ? .green : last.outcome.tint)
                    Text(String(format: NSLocalizedString("Last run %@", comment: "automations home"),
                                last.firedAt.formatted(.relative(presentation: .named))))
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            } else {
                Text(NSLocalizedString("Hasn't run yet", comment: "automations home"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct WatchSummaryRow: View {
    let watch: WatchedRepo
    var automationStore: ScheduledAutomationStore
    let findings: [RepoFinding]
    let workspace: SessionListModel.ProfileRow?
    let scanning: Bool
    var onOpen: () -> Void
    var onEdit: () -> Void
    var onScan: () -> Void
    var onToggle: () -> Void
    @State private var hovering = false

    private var scanSummary: String {
        var parts: [String] = []
        if watch.scans.contains(.fullScan) {
            let day = Calendar.current.shortWeekdaySymbols[min(max(watch.fullScanWeekday, 1), 7) - 1]
            parts.append(String(format: NSLocalizedString("Full scan %1$@ %2$02d:00", comment: "watch row: weekday, hour"),
                                day, watch.fullScanHour))
        }
        if watch.scans.contains(.commits) { parts.append(NSLocalizedString("every commit", comment: "watch row")) }
        if watch.scans.contains(.pullRequests) { parts.append(NSLocalizedString("every pull request", comment: "watch row")) }
        return parts.isEmpty ? NSLocalizedString("Scan Now only", comment: "watch row") : parts.joined(separator: " · ")
    }

    var body: some View {
        let stats = FindingStats(findings)
        let tint = AutomationKindCards.tint(.security)
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill((watch.enabled ? tint : .secondary).opacity(0.13))
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(watch.enabled ? tint : .secondary)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(watch.repo).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                    if !watch.enabled {
                        Text(NSLocalizedString("Paused", comment: "watch"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Text(scanSummary)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.8))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let workspace {
                        Circle().fill(Color(hex: workspace.accentHex)).frame(width: 6, height: 6)
                        Text(workspace.name)
                    }
                    Text("· " + watch.tool.displayName + " · " + watch.focus.displayName)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 4) {
                if scanning {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text(NSLocalizedString("Scanning", comment: "watch row"))
                    }
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.blue)
                }
                HStack(spacing: 5) {
                    if stats.open == 0 {
                        Label(NSLocalizedString("No open findings", comment: "watch row"), systemImage: "checkmark.shield")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.green)
                    } else {
                        ForEach(RepoFinding.Severity.allCases.filter { (stats.openBySeverity[$0] ?? 0) > 0 },
                                id: \.self) { sev in
                            Text("\(stats.openBySeverity[sev] ?? 0) \(sev.displayName)")
                                .font(.system(size: 10.5, weight: .semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .foregroundStyle(sev.tint)
                                .background(sev.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
            }
            .frame(minWidth: 150, alignment: .trailing)
            HStack(spacing: 4) {
                Button(action: onScan) {
                    Image(systemName: "play.fill").font(.system(size: 11))
                        .frame(width: 26, height: 22)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(NSLocalizedString("Scan now", comment: "watch row"))
                Toggle("", isOn: Binding(get: { watch.enabled }, set: { _ in onToggle() }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                Menu {
                    Button(NSLocalizedString("Edit…", comment: ""), action: onEdit)
                    Button(NSLocalizedString("Show Findings", comment: "watch row"), action: onOpen)
                } label: {
                    Image(systemName: "ellipsis").frame(width: 22, height: 22)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .modifier(FloatingCardBackground(cornerRadius: 12, hovering: hovering))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovering = $0 }
        .onTapGesture(perform: onOpen)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
#endif
