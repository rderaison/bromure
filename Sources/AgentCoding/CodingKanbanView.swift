import SwiftUI

// MARK: - Lightweight markdown rendering

/// Block-level markdown for task descriptions: headings, bullets, fenced
/// code, paragraphs — with inline markdown (bold/italic/`code`) per line.
/// Dependency-free on purpose; task briefs don't need a full CommonMark
/// engine to be legible.
struct MarkdownBlocks: View {
    let text: String
    var compact = false

    private enum Block: Identifiable {
        case heading(Int, String)
        case bullet([String])
        case code([String])
        case paragraph(String)
        var id: String {
            switch self {
            case .heading(let l, let s): return "h\(l):\(s)"
            case .bullet(let items):     return "b:" + items.joined(separator: "\u{1}")
            case .code(let lines):       return "c:" + lines.joined(separator: "\u{1}")
            case .paragraph(let s):      return "p:" + s
            }
        }
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var bullets: [String] = []
        var code: [String] = []
        var inCode = false
        var paragraph: [String] = []

        func flushBullets() {
            if !bullets.isEmpty { out.append(.bullet(bullets)); bullets = [] }
        }
        func flushParagraph() {
            if !paragraph.isEmpty {
                out.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode { out.append(.code(code)); code = [] }
                else { flushBullets(); flushParagraph() }
                inCode.toggle()
                continue
            }
            if inCode { code.append(line); continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flushBullets(); flushParagraph(); continue }
            if trimmed.hasPrefix("#") {
                flushBullets(); flushParagraph()
                let level = trimmed.prefix(while: { $0 == "#" }).count
                let body = trimmed.drop(while: { $0 == "#" })
                    .trimmingCharacters(in: .whitespaces)
                out.append(.heading(min(level, 3), body))
                continue
            }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flushParagraph()
                bullets.append(String(trimmed.dropFirst(2)))
                continue
            }
            flushBullets()
            paragraph.append(trimmed)
        }
        if inCode, !code.isEmpty { out.append(.code(code)) }
        flushBullets()
        flushParagraph()
        return out
    }

    /// Inline markdown (bold, italic, `code`, links) via Foundation.
    private func inline(_ s: String) -> Text {
        if let attr = try? AttributedString(
            markdown: s,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attr)
        }
        return Text(s)
    }

    /// Compact (kanban cards) renders a step smaller than the editor
    /// preview — card descriptions are a glance, not a reading surface.
    private var bodySize: CGFloat { compact ? 11 : 12 }
    private var codeSize: CGFloat { compact ? 10 : 11 }
    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1:  return compact ? 12.5 : 15
        case 2:  return compact ? 12 : 13.5
        default: return compact ? 11.5 : 12.5
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 7) {
            ForEach(blocks) { block in
                switch block {
                case .heading(let level, let s):
                    inline(s)
                        .font(.system(size: headingSize(level), weight: .bold))
                        .padding(.top, compact ? 0 : 2)
                case .bullet(let items):
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•").font(.system(size: bodySize))
                                inline(item)
                                    .font(.system(size: bodySize))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                case .code(let lines):
                    Text(lines.joined(separator: "\n"))
                        .font(.system(size: codeSize, design: .monospaced))
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(Color.primary.opacity(0.05)))
                case .paragraph(let s):
                    inline(s)
                        .font(.system(size: bodySize))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
    }
}

// MARK: - Sidebar section

/// "Tasks" — the sidebar entry for the coding board: a header with the
/// board button and a one-line status row ("2 in progress · 1 to review")
/// that opens the board.
struct CodingTasksSection: View {
    var store: CodingTaskStore
    @Bindable var model: SessionListModel
    let onShowBoard: () -> Void

    private var statusLine: String {
        let planning = store.tasks(in: .planning).count
        let running = store.tasks(in: .inProgress).count
        let review = store.tasks(in: .testing).count
        let backlog = store.backlogTasks().count
        var parts: [String] = []
        if planning > 0 {
            parts.append(String(format: NSLocalizedString("%d planned", comment: ""), planning))
        }
        if running > 0 {
            parts.append(String(format: NSLocalizedString("%d in progress", comment: ""), running))
        }
        if review > 0 {
            parts.append(String(format: NSLocalizedString("%d to review", comment: ""), review))
        }
        if parts.isEmpty {
            parts.append(backlog > 0
                ? String(format: NSLocalizedString("%d in backlog", comment: ""), backlog)
                : NSLocalizedString("Open the board", comment: "tasks sidebar"))
        }
        return parts.joined(separator: " · ")
    }

    /// Finished agent runs waiting on a human review — the orange badge.
    private var reviewCount: Int { store.tasks(in: .testing).count }

    /// What the badge counts: running tasks whose agent is waiting on the
    /// user right now.
    private var attentionCount: Int {
        store.tasks(in: .inProgress).filter { task in
            guard let slug = task.branchSlug,
                  let entry = model.entries.first(where: { $0.id == task.profileID })
            else { return false }
            return entry.model.tabs.contains {
                AutomationBoard.branchMatches($0.worktreeBranch, slug: slug)
                    && $0.agentStatus == .needsInput
            }
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Button(action: onShowBoard) {
                    Text(NSLocalizedString("Tasks", comment: "sidebar section"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(model.taskBoardSelected
                                         ? Color.accentColor : .secondary)
                        .textCase(.uppercase)
                        .tracking(0.7)
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("Open the coding board (⇧⌘T)", comment: ""))
                Spacer()
            }
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .padding(.top, 14)
            .padding(.bottom, 4)

            Button(action: onShowBoard) {
                HStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .font(.system(size: 11))
                        .foregroundStyle(attentionCount > 0 ? .red : .secondary)
                    Text(statusLine)
                        .font(.system(size: 12))
                        .foregroundStyle(model.taskBoardSelected ? .primary : .secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    SidebarAttentionBadge(count: reviewCount, tint: .orange)
                    SidebarAttentionBadge(count: attentionCount)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(model.taskBoardSelected ? Color.accentColor.opacity(0.16) : .clear))
        }
    }
}

// MARK: - Coding board

/// The coding kanban: Backlog → In Progress → Testing → Done. Backlog cards
/// carry a markdown brief written in the editor sheet; Start launches the
/// agent in a fresh worktree; the agent's done signal lands the card in
/// Testing, where the review window shows the branch diff; merge closes it.
struct CodingKanbanView: View {
    struct Actions {
        var start: (UUID) -> Void = { _ in }
        /// Decompose the brief into ordered phase cards in the Plan column
        /// (headless planner agent; dependencies included).
        var plan: (UUID) -> Void = { _ in }
        var openReview: (UUID) -> Void = { _ in }
        var jumpToRun: (CodingTask) -> Void = { _ in }
        var moveToTesting: (UUID) -> Void = { _ in }
        var backToInProgress: (UUID) -> Void = { _ in }
        var merge: (UUID) -> Void = { _ in }
        var closeNoMerge: (UUID) -> Void = { _ in }
        var delete: (UUID) -> Void = { _ in }
        var save: (CodingTask) -> Void = { _ in }
        /// Persist the draft, then run the plan-validation agent; the
        /// result lands on the stored task (editor watches the store).
        var validate: (CodingTask) -> Void = { _ in }
        /// Open the native planning-conversation window for a card whose
        /// planning session is live.
        var openPlanSession: (UUID) -> Void = { _ in }
        /// Remove the card AND kill its agent + delete its worktree/branch.
        var destroy: (UUID) -> Void = { _ in }
        /// Re-launch a lost session on the task's existing worktree.
        var resume: (UUID) -> Void = { _ in }
        /// Open a finished task's session transcript (read from the
        /// workspace's persistent home).
        var openTranscript: (UUID) -> Void = { _ in }
    }

    var store: CodingTaskStore
    @Bindable var model: SessionListModel
    /// Fresh profile snapshot for the editor sheet's pickers.
    let profilesProvider: () -> [Profile]
    let actions: Actions

    /// The editor sheet's subject: an existing task or a fresh draft.
    @State private var editing: CodingTask?
    /// Plan-column multi-selection (batch start).
    @State private var selectedPhases: Set<UUID> = []
    @State private var confirmingBatchDelete = false
    /// Compact = iPhone portrait → columns stack in one vertical scroll.
    @Environment(\.horizontalSizeClass) private var hSize
    private var compact: Bool { hSize == .compact }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if !os(iOS)
            header
            Divider()
            #endif
            if compact {
                // Phone: one vertical scroll with the columns stacked.
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        backlogColumn
                        planColumn
                        inProgressColumn
                        testingColumn
                        doneColumn
                    }
                    .padding(14)
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    backlogColumn
                    planColumn
                    inProgressColumn
                    testingColumn
                    doneColumn
                }
                .padding(14)
            }
        }
        .background(Color.platformWindowBackground)
        // iOS puts the board inside a NavigationStack, which already has a bar
        // across the top — so the in-board header would be the SECOND title on
        // screen. Hand the same icon + title + New action to that bar instead
        // and give the columns the space back.
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // .titleAndIcon is not the default in a navigation bar — a bare
                // Label renders icon-only there.
                Label(NSLocalizedString("Coding Tasks", comment: "coding kanban title"),
                      systemImage: "checklist")
                    .labelStyle(.titleAndIcon)
                    .font(.headline)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { editing = newDraft() } label: { Image(systemName: "plus") }
                    .accessibilityLabel(NSLocalizedString("New Task", comment: ""))
            }
        }
        #endif
        .sheet(item: $editing) { task in
            TaskEditorSheet(
                task: task,
                profiles: profilesProvider(),
                siblings: task.parentTaskID.map { parent in
                    store.tasks.filter { $0.parentTaskID == parent && $0.id != task.id }
                        .sorted { $0.createdAt < $1.createdAt }
                } ?? [],
                isNew: store.task(task.id) == nil,
                onSave: { saved in actions.save(saved); editing = nil },
                onPlan: { draft in
                    actions.save(draft)
                    actions.plan(draft.id)
                    editing = nil
                },
                onDelete: { id in actions.delete(id); editing = nil },
                onCancel: { editing = nil })
        }
    }

    /// A blank task on the first workspace — the "New Task" subject.
    private func newDraft() -> CodingTask {
        let profiles = profilesProvider()
        return CodingTask(profileID: profiles.first?.id ?? UUID(),
                          tool: profiles.first?.tool ?? .claude)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.tint)
            Text(NSLocalizedString("Coding Tasks", comment: "coding kanban title"))
                .font(.system(size: 16, weight: .bold))
            Spacer()
            Button { editing = newDraft() } label: {
                Label(NSLocalizedString("New Task", comment: ""), systemImage: "plus")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func accentHex(for profileID: UUID) -> String {
        model.profileRows.first { $0.id == profileID }?.accentHex ?? "#888888"
    }

    private func workspaceName(for profileID: UUID) -> String {
        model.profileRows.first { $0.id == profileID }?.name ?? ""
    }

    /// Live tab status for a started task, via the sidebar's tab models
    /// (observable — status changes redraw the board).
    private func liveStatus(of task: CodingTask) -> AgentStatus? {
        guard let slug = task.branchSlug,
              let entry = model.entries.first(where: { $0.id == task.profileID })
        else { return nil }
        return entry.model.tabs.first {
            AutomationBoard.branchMatches($0.worktreeBranch, slug: slug)
        }?.agentStatus
    }

    // MARK: Columns

    private var backlogColumn: some View {
        let tasks = store.backlogTasks()
        return KanbanColumn(title: NSLocalizedString("Backlog", comment: "kanban column"),
                            systemImage: "tray",
                            count: tasks.count,
                            emptyText: NSLocalizedString("No tasks yet — write one.",
                                                         comment: "kanban")) {
            ForEach(tasks) { task in
                BacklogTaskCard(
                    task: task,
                    accentHex: accentHex(for: task.profileID),
                    workspaceName: workspaceName(for: task.profileID),
                    parentTitle: task.parentTaskID.flatMap { store.task($0)?.title },
                    onEdit: { editing = task },
                    onOpenSession: { actions.openPlanSession(task.id) },
                    onStart: { actions.start(task.id) },
                    onPlan: { actions.plan(task.id) },
                    onDelete: { actions.delete(task.id) })
                    .modifier(RemovableCard(title: task.title, stage: task.stage) {
                        actions.delete(task.id)
                    })
            }
        }
    }

    private var planColumn: some View {
        // Phase cards in plan order (creation order = the planner's order).
        let tasks = store.tasks(in: .planning)
            .sorted { $0.createdAt < $1.createdAt }
        let selected = selectedPhases.intersection(tasks.map(\.id))
        return KanbanColumn(title: NSLocalizedString("Plan", comment: "kanban column"),
                            systemImage: "list.number",
                            count: tasks.count,
                            tint: .blue,
                            emptyText: NSLocalizedString(
                                "No phases yet — click Plan on a backlog card.",
                                comment: "kanban")) {
            if !selected.isEmpty {
                HStack(spacing: 8) {
                    Button {
                        for id in tasks.map(\.id) where selected.contains(id) {
                            actions.start(id)
                        }
                        selectedPhases.removeAll()
                    } label: {
                        Label(String(format: NSLocalizedString(
                            "Start %d selected", comment: "plan column"), selected.count),
                              systemImage: "play.fill")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .help(NSLocalizedString(
                        "One-shots every selected phase. Phases whose dependencies aren't Done queue and auto-start when they are.",
                        comment: "plan column"))
                    Button(NSLocalizedString("Clear", comment: "plan column")) {
                        selectedPhases.removeAll()
                    }
                    .controlSize(.small)
                    Spacer(minLength: 0)
                    Button(role: .destructive) {
                        confirmingBatchDelete = true
                    } label: {
                        Label(NSLocalizedString("Delete", comment: "plan column"),
                              systemImage: "trash")
                    }
                    .controlSize(.small)
                    .help(NSLocalizedString("Remove every selected phase from the board",
                                            comment: "plan column"))
                    .confirmationDialog(
                        String(format: NSLocalizedString(
                            "Delete %d selected phase(s)?", comment: "plan column"),
                            selected.count),
                        isPresented: $confirmingBatchDelete, titleVisibility: .visible
                    ) {
                        Button(NSLocalizedString("Delete", comment: "plan column"),
                               role: .destructive) {
                            for id in tasks.map(\.id) where selected.contains(id) {
                                actions.delete(id)
                            }
                            selectedPhases.removeAll()
                        }
                        Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {}
                    } message: {
                        Text(NSLocalizedString("This can't be undone.", comment: "remove card"))
                    }
                }
                .padding(.bottom, 2)
            }
            ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                PlanPhaseCard(
                    task: task,
                    number: index + 1,
                    accentHex: accentHex(for: task.profileID),
                    parentTitle: task.parentTaskID.flatMap { store.task($0)?.title },
                    dependsOnNumbers: (task.dependsOn ?? []).compactMap { depID in
                        tasks.firstIndex { $0.id == depID }.map { $0 + 1 }
                    },
                    depsMet: task.unmetDependencies(in: store.tasks).isEmpty,
                    isSelected: selectedPhases.contains(task.id),
                    onToggleSelect: {
                        if selectedPhases.contains(task.id) { selectedPhases.remove(task.id) }
                        else { selectedPhases.insert(task.id) }
                    },
                    onEdit: { editing = task })
                    .modifier(RemovableCard(title: task.title, stage: task.stage) {
                        actions.delete(task.id)
                    })
                    .contextMenu {
                        Button(NSLocalizedString("Start", comment: "")) {
                            actions.start(task.id)
                        }
                        Button(NSLocalizedString("Edit…", comment: "")) { editing = task }
                        Divider()
                        Button(NSLocalizedString("Delete", comment: ""), role: .destructive) {
                            actions.delete(task.id)
                        }
                    }
            }
        }
    }

    private var inProgressColumn: some View {
        let tasks = store.tasks(in: .inProgress)
        return KanbanColumn(title: NSLocalizedString("In Progress", comment: "kanban column"),
                            systemImage: "play.circle",
                            count: tasks.count,
                            emptyText: NSLocalizedString("Nothing running", comment: "kanban")) {
            ForEach(tasks) { task in
                InProgressTaskCard(
                    task: task,
                    accentHex: accentHex(for: task.profileID),
                    status: liveStatus(of: task),
                    onOpen: { actions.jumpToRun(task) },
                    onResume: { actions.resume(task.id) })
                    .modifier(RemovableCard(title: task.title, stage: task.stage,
                                            onRemove: { actions.delete(task.id) },
                                            onDestroy: { actions.destroy(task.id) }))
                    .contextMenu {
                        Button(NSLocalizedString("Restart Session", comment: "")) {
                            actions.resume(task.id)
                        }
                        Button(NSLocalizedString("Move to Testing", comment: "")) {
                            actions.moveToTesting(task.id)
                        }
                        Button(NSLocalizedString("Close Without Merging", comment: "")) {
                            actions.closeNoMerge(task.id)
                        }
                        Divider()
                        Button(NSLocalizedString("Stop Agent & Delete Worktree",
                                                 comment: ""),
                               role: .destructive) {
                            actions.destroy(task.id)
                        }
                        Button(NSLocalizedString("Remove Card Only", comment: ""),
                               role: .destructive) {
                            actions.delete(task.id)
                        }
                    }
            }
        }
    }

    private var testingColumn: some View {
        let tasks = store.tasks(in: .testing)
        return KanbanColumn(title: NSLocalizedString("Testing/Review", comment: "kanban column"),
                            systemImage: "eye",
                            count: tasks.count,
                            tint: .purple,
                            emptyText: NSLocalizedString("Nothing to review", comment: "kanban")) {
            ForEach(tasks) { task in
                TestingTaskCard(
                    task: task,
                    accentHex: accentHex(for: task.profileID),
                    onOpen: { actions.openReview(task.id) })
                    .modifier(RemovableCard(title: task.title, stage: task.stage,
                                            onRemove: { actions.delete(task.id) },
                                            onDestroy: { actions.destroy(task.id) }))
                    .contextMenu {
                        Button(String(format: NSLocalizedString("Merge into %@…",
                                                                comment: "kanban menu"),
                                      task.parentBranch ?? NSLocalizedString(
                                        "parent", comment: "kanban menu"))) {
                            actions.merge(task.id)
                        }
                        Button(NSLocalizedString("Back to In Progress", comment: "")) {
                            actions.backToInProgress(task.id)
                        }
                        Button(NSLocalizedString("Close Without Merging", comment: "")) {
                            actions.closeNoMerge(task.id)
                        }
                        Divider()
                        Button(NSLocalizedString("Delete Worktree & Branch",
                                                 comment: ""),
                               role: .destructive) {
                            actions.destroy(task.id)
                        }
                        Button(NSLocalizedString("Remove Card Only", comment: ""),
                               role: .destructive) {
                            actions.delete(task.id)
                        }
                    }
            }
        }
    }

    private var doneColumn: some View {
        let tasks = store.tasks(in: .done)
        return KanbanColumn(title: NSLocalizedString("Done", comment: "kanban column"),
                            systemImage: "checkmark.circle",
                            count: tasks.count,
                            emptyText: NSLocalizedString("Nothing shipped yet", comment: "kanban")) {
            ForEach(tasks) { task in
                DoneTaskCard(task: task,
                             accentHex: accentHex(for: task.profileID),
                             onOpen: { actions.openTranscript(task.id) })
                    .modifier(RemovableCard(title: task.title, stage: task.stage) {
                        actions.delete(task.id)
                    })
                    .contextMenu {
                        Button(NSLocalizedString("View Transcript", comment: "")) {
                            actions.openTranscript(task.id)
                        }
                        Button(NSLocalizedString("Delete", comment: ""), role: .destructive) {
                            actions.delete(task.id)
                        }
                    }
            }
        }
    }
}

// MARK: - Cards

/// Hover-revealed ✕ on a kanban card, behind a confirmation so a stray
/// click can't nuke a task. Removal deletes the card only — a running
/// agent session, its branch, and its worktree are untouched.
private struct RemovableCard: ViewModifier {
    let title: String
    let stage: CodingTask.Stage
    let onRemove: () -> Void
    /// Kill the agent + delete the worktree/branch too. Offered for cards
    /// that have (or may have) a session or checkout behind them.
    var onDestroy: (() -> Void)?

    @State private var hovering = false
    @State private var confirming = false

    private var hasBackingWork: Bool {
        onDestroy != nil && (stage == .inProgress || stage == .testing)
    }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button {
                        confirming = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(3)
                    .help(NSLocalizedString("Remove from board", comment: ""))
                }
            }
            .onHover { hovering = $0 }
            .confirmationDialog(
                String(format: NSLocalizedString("Remove “%@”?",
                                                 comment: "remove card"), title),
                isPresented: $confirming, titleVisibility: .visible
            ) {
                if hasBackingWork {
                    Button(stage == .inProgress
                           ? NSLocalizedString("Stop Agent & Delete Worktree",
                                               comment: "remove card")
                           : NSLocalizedString("Delete Worktree & Branch",
                                               comment: "remove card"),
                           role: .destructive) {
                        onDestroy?()
                    }
                    Button(NSLocalizedString("Remove Card Only", comment: "remove card")) {
                        onRemove()
                    }
                } else {
                    Button(NSLocalizedString("Remove", comment: ""), role: .destructive) {
                        onRemove()
                    }
                }
                Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {}
            } message: {
                Text(hasBackingWork
                     ? NSLocalizedString(
                        "Stopping deletes the agent session and its uncommitted/unmerged work in the worktree. “Remove Card Only” leaves them in the workspace.",
                        comment: "remove card")
                     : NSLocalizedString("This can't be undone.", comment: "remove card"))
            }
    }
}


/// One decomposed phase in the Plan column: numbered, selectable for batch
/// start, with dependency and queue state. Clicking the body edits; the
/// checkbox selects; starting happens from the selection bar or the
/// context menu — phases run fully autonomously.
private struct PlanPhaseCard: View {
    let task: CodingTask
    let number: Int
    let accentHex: String
    let parentTitle: String?
    let dependsOnNumbers: [Int]
    let depsMet: Bool
    let isSelected: Bool
    let onToggleSelect: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onToggleSelect) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor)
                                                : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
            .padding(.top, 1)
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("\(number)")
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(width: 16, height: 16)
                            .background(Circle().fill(Color(hex: accentHex)))
                        Text(task.title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .lineLimit(2)
                        Spacer(minLength: 4)
                    }
                    if !task.details.isEmpty {
                        MarkdownBlocks(text: task.details, compact: true)
                            .frame(maxHeight: 54, alignment: .top)
                            .clipped()
                            .allowsHitTesting(false)
                    }
                    HStack(spacing: 6) {
                        if let parentTitle {
                            Label(parentTitle, systemImage: "arrow.turn.down.right")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if task.queuedAt != nil {
                            Text(NSLocalizedString("queued", comment: "plan card"))
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(.orange)
                                .help(NSLocalizedString(
                                    "Starts automatically when its dependencies are Done.",
                                    comment: "plan card"))
                        }
                        if !dependsOnNumbers.isEmpty {
                            Label(dependsOnNumbers.map(String.init).joined(separator: ","),
                                  systemImage: depsMet ? "lock.open" : "lock")
                                .font(.system(size: 9.5).monospacedDigit())
                                .foregroundStyle(depsMet ? AnyShapeStyle(.secondary)
                                                         : AnyShapeStyle(Color.orange))
                                .help(NSLocalizedString(
                                    "Phases that must be Done before this one starts.",
                                    comment: "plan card"))
                        }
                    }
                    if let err = task.lastError {
                        Label(err, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .lineLimit(2)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .modifier(CardChrome(borderTint: isSelected ? .accentColor : .clear))
    }
}

private struct BacklogTaskCard: View {
    let task: CodingTask
    let accentHex: String
    let workspaceName: String
    /// Set when this card is an agent-filed subtask of another task.
    let parentTitle: String?
    let onEdit: () -> Void
    /// Jump to the live planning session (while one is running).
    let onOpenSession: () -> Void
    let onStart: () -> Void
    let onPlan: () -> Void
    let onDelete: () -> Void

    /// While the planning session runs, the card IS the door to it.
    private var planningLive: Bool {
        task.validationInFlight && task.branchSlug != nil
    }

    var body: some View {
        Button(action: { planningLive ? onOpenSession() : onEdit() }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: accentHex)).frame(width: 8, height: 8)
                    Text(task.title.isEmpty
                         ? NSLocalizedString("Untitled task", comment: "") : task.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if planningLive {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text(NSLocalizedString("planning — click to watch", comment: "task card"))
                                .font(.system(size: 9.5))
                                .foregroundStyle(.blue)
                        }
                        .help(NSLocalizedString(
                            "A visible planning session is running — click the card to open it; phases appear in the Plan column as it files them.",
                            comment: ""))
                    } else if task.validation != nil {
                        Image(systemName: "person.fill.checkmark")
                            .font(.system(size: 9))
                            .foregroundStyle(.purple)
                            .help(NSLocalizedString("Plan reviewed by the agent", comment: ""))
                    }
                }
                if !task.details.isEmpty {
                    MarkdownBlocks(text: task.details, compact: true)
                        .frame(maxHeight: 76, alignment: .top)
                        .clipped()
                        .allowsHitTesting(false)   // the card is the click target
                }
                if let parentTitle {
                    Label(String(format: NSLocalizedString("part of “%@”", comment: ""),
                                 parentTitle),
                          systemImage: "arrow.turn.down.right")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let err = task.lastError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                HStack {
                    if !workspaceName.isEmpty {
                        Text(workspaceName)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    Button(NSLocalizedString("Plan", comment: "task card")) { onPlan() }
                        .controlSize(.small)
                        .disabled(task.title.trimmingCharacters(in: .whitespaces).isEmpty
                                  || task.validationInFlight)
                        .help(NSLocalizedString(
                            "A planner agent reads the brief and the repository, then files ordered phase cards (with dependencies) in the Plan column.",
                            comment: "task card"))
                    Button(NSLocalizedString("One shot", comment: "task card")) { onStart() }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .disabled(task.title.trimmingCharacters(in: .whitespaces).isEmpty)
                        .help(NSLocalizedString(
                            "Straight to In Progress: the agent does the whole task autonomously and hands you the diff in Testing/Review.",
                            comment: "task card"))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(CardChrome())
        .contextMenu {
            Button(NSLocalizedString("Edit…", comment: ""), action: onEdit)
            Button(NSLocalizedString("Delete", comment: ""), role: .destructive,
                   action: onDelete)
        }
    }
}

private struct InProgressTaskCard: View {
    let task: CodingTask
    let accentHex: String
    let status: AgentStatus?
    let onOpen: () -> Void
    var onResume: () -> Void = {}

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    AgentStatusDot(status: status ?? .working)
                    Text(task.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Circle().fill(Color(hex: accentHex)).frame(width: 7, height: 7)
                }
                // TimelineView so the whole row re-evaluates on a timer:
                // the relative time ticks, and "starting…" ages into
                // "session gone" even when nothing else redraws the board.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HStack(spacing: 4) {
                        if let started = task.startedAt {
                            RelativeTimeText(
                                format: NSLocalizedString("started %@", comment: ""),
                                date: started)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                        if status == .needsInput {
                            Text(NSLocalizedString("Needs your input", comment: ""))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.red)
                        } else if status == nil {
                            // No tab yet: within the boot/attach window that's
                            // normal startup, not a lost session.
                            if let started = task.startedAt,
                               context.date.timeIntervalSince(started) < 300 {
                                Text(NSLocalizedString("starting…", comment: "task card"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            } else {
                                // A lost session isn't a dead end: reboot
                                // the workspace and re-launch the agent on
                                // the existing worktree.
                                Button {
                                    onResume()
                                } label: {
                                    Label(NSLocalizedString("Restart session",
                                                            comment: "task card"),
                                          systemImage: "arrow.clockwise")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(.orange)
                                }
                                .buttonStyle(.plain)
                                .help(NSLocalizedString(
                                    "The session is gone — boot the workspace if needed and relaunch the agent on this task's worktree.",
                                    comment: "task card"))
                            }
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(CardChrome(borderTint: status == .needsInput ? .red : .clear))
        .help(NSLocalizedString("Open the task's live session", comment: ""))
    }
}

private struct TestingTaskCard: View {
    let task: CodingTask
    let accentHex: String
    let onOpen: () -> Void

    private var unsent: Int { task.comments.filter { $0.sentAt == nil }.count }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "eye")
                        .font(.system(size: 10))
                        .foregroundStyle(.purple)
                    Text(task.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Circle().fill(Color(hex: accentHex)).frame(width: 7, height: 7)
                }
                HStack(spacing: 4) {
                    if let branch = task.branch {
                        Text(branch)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if unsent > 0 {
                        Text("\(unsent)")
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.purple))
                            .help(NSLocalizedString("Draft review comments", comment: ""))
                    }
                }
                if task.mergingAt != nil {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text(NSLocalizedString("Merging… goes Done once the changes land",
                                               comment: "task card"))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                } else if let err = task.lastError {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                } else {
                    Text(NSLocalizedString("Ready for review — click to see the diff",
                                           comment: "task card"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(CardChrome(borderTint: .purple))
    }
}

private struct DoneTaskCard: View {
    let task: CodingTask
    let accentHex: String
    var onOpen: () -> Void = {}

    private var outcomeText: String {
        if task.merged {
            return String(format: NSLocalizedString("merged into %@", comment: ""),
                          task.parentBranch ?? "parent")
        }
        if task.prOpened == true {
            return NSLocalizedString("pull request opened", comment: "")
        }
        return NSLocalizedString("closed without merge", comment: "")
    }

    private var outcomeGlyph: (name: String, tint: Color) {
        if task.merged { return ("arrow.triangle.merge", .green) }
        if task.prOpened == true { return ("arrow.up.forward.square", .blue) }
        return ("checkmark.circle", .secondary)
    }

    var body: some View {
        Button(action: onOpen) {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: outcomeGlyph.name)
                    .font(.system(size: 10))
                    .foregroundStyle(outcomeGlyph.tint)
                Text(task.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                Spacer(minLength: 4)
                Circle().fill(Color(hex: accentHex)).frame(width: 6, height: 6)
            }
            HStack {
                Text(outcomeText)
                    .font(.system(size: 10))
                    .foregroundStyle(task.merged ? .secondary : .tertiary)
                Spacer(minLength: 0)
                if let done = task.completedAt {
                    Text(done.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Read the agent's full session transcript",
                                comment: "task transcript"))
        .modifier(CardChrome())
    }
}

// MARK: - Backlog editor sheet

/// The task brief editor: a large markdown text editor with a live preview
/// toggle — backlog items are supposed to be written with care, they become
/// the agent's prompt verbatim.
private struct TaskEditorSheet: View {
    @State var task: CodingTask
    let profiles: [Profile]
    /// Fellow phases of the same plan (any stage), in plan order — the
    /// pool a phase's dependencies are picked from. Empty for plain tasks.
    let siblings: [CodingTask]
    let isNew: Bool
    let onSave: (CodingTask) -> Void
    /// Save the draft and run the planner: ordered phase cards (with
    /// dependencies) land in the Plan column.
    let onPlan: (CodingTask) -> Void
    let onDelete: (UUID) -> Void
    let onCancel: () -> Void

    @State private var preview = false

    /// A persistent caption above a control — TextFields only show their
    /// title as disappearing placeholder text, which leaves a prefilled
    /// field (like the "~" start path) unlabeled. Same pattern as the
    /// automation editor.
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

    private var selectedProfile: Profile? {
        profiles.first { $0.id == task.profileID }
    }

    private var toolChoices: [Profile.ToolSpec] {
        selectedProfile?.allToolSpecs ?? []
    }

    private var canSave: Bool {
        !task.title.trimmingCharacters(in: .whitespaces).isEmpty
            && selectedProfile != nil
    }

    /// The Write/Preview description editor block. Frames come from the
    /// caller: alone it fills the sheet's middle; with a plan review it
    /// shares a VSplitView with the review pane.
    private var editorArea: some View {
        Group {
            if preview {
                ScrollView {
                    MarkdownBlocks(text: task.details)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.03)))
            } else {
                TextEditor(text: $task.details)
                    .font(.system(size: 12.5, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.03)))
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.primary.opacity(0.12)))
    }

    private func dependencyBinding(_ sibling: CodingTask) -> Binding<Bool> {
        Binding(
            get: { task.dependsOn?.contains(sibling.id) ?? false },
            set: { on in
                var deps = task.dependsOn ?? []
                deps.removeAll { $0 == sibling.id }
                if on { deps.append(sibling.id) }
                // Keep plan order so the card badges read naturally.
                let order = Dictionary(uniqueKeysWithValues:
                    siblings.enumerated().map { ($1.id, $0) })
                deps.sort { (order[$0] ?? .max) < (order[$1] ?? .max) }
                task.dependsOn = deps.isEmpty ? nil : deps
            })
    }

    /// Which phases must reach Done before this one may start. Checked
    /// rows are this phase's dependencies; already-Done ones show as met.
    private var dependenciesSection: some View {
        captioned(NSLocalizedString("Depends on — phases that must finish first",
                                    comment: "task editor")) {
            // A big plan has a dozen-plus phases — the list scrolls inside
            // a fixed height so it can't push the editor's footer out of
            // the sheet.
            ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(siblings) { sib in
                    dependencyRow(sib)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            }
            // A FIRM height, not a cap: the description editor above has
            // layoutPriority(1) + maxHeight .infinity and would squeeze a
            // merely-capped ScrollView to zero. Sized to the rows, capped
            // so a dozen-phase plan scrolls instead of pushing the footer
            // out of the sheet.
            .frame(height: min(150, CGFloat(siblings.count) * 30 + 16))
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.12)))
        }
    }

    /// One phase-dependency row. Extracted from the `captioned {…}` builder so
    /// the whole editor expression stays inside the type-checker's budget (the
    /// nested Toggle + conditional status was the tipping point on iOS).
    @ViewBuilder
    private func dependencyRow(_ sib: CodingTask) -> some View {
        HStack(spacing: 6) {
            Toggle(isOn: dependencyBinding(sib)) {
                Text(sib.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            .platformCheckboxToggle()
            Spacer(minLength: 4)
            if sib.stage == .done {
                Label(NSLocalizedString("done", comment: "task editor dep"),
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else if dependencyBinding(sib).wrappedValue {
                Text(NSLocalizedString("waiting", comment: "task editor dep"))
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Compact = iPhone portrait → the sheet fills the screen, the field row
    /// stacks, and the whole form scrolls. macOS/iPad keep the wide fixed sheet.
    @Environment(\.horizontalSizeClass) private var hSize
    private var compact: Bool { hSize == .compact }

    var body: some View {
        if compact {
            ScrollView { formContent.padding(18) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            formContent
                .padding(18)
                // Capped: content shares space inside this; the sheet itself must
                // stay shorter than any reasonable window.
                .frame(minWidth: 680, minHeight: 500, idealHeight: 620, maxHeight: 660)
        }
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew
                 ? NSLocalizedString("New Task", comment: "task editor")
                 : NSLocalizedString("Edit Task", comment: "task editor"))
                .font(.system(size: 15, weight: .bold))

            TextField(NSLocalizedString("Task title", comment: ""), text: $task.title)
                .font(.system(size: 14, weight: .semibold))
                .textFieldStyle(.roundedBorder)

            fieldsRow

            HStack {
                Text(NSLocalizedString("Description (markdown)", comment: ""))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $preview) {
                    Text(NSLocalizedString("Write", comment: "editor mode")).tag(false)
                    Text(NSLocalizedString("Preview", comment: "editor mode")).tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .labelsHidden()
            }

            editorArea
                .frame(minHeight: compact ? 200 : 140,
                       maxHeight: compact ? nil : .infinity)
                .layoutPriority(1)

            if !siblings.isEmpty {
                dependenciesSection
            }

            Text(NSLocalizedString(
                "Starting the task launches the agent in a fresh worktree of the repository with this brief as its prompt. It works on its own branch and commits its changes; you review the diff in Testing, then merge.",
                comment: "task editor"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            bottomButtons
        }
    }

    /// Workspace / Agent / start-folder — a row on the desktop, stacked on a
    /// phone (three pickers/fields side by side overflow a narrow screen).
    @ViewBuilder private var fieldsRow: some View {
        let layout = compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        layout {
            captioned(NSLocalizedString("Workspace", comment: "")) {
                Picker("", selection: $task.profileID) {
                    ForEach(profiles) { Text($0.name).tag($0.id) }
                }
                .labelsHidden()
                .onChange(of: task.profileID) {
                    if !toolChoices.contains(where: { $0.tool == task.tool }),
                       let primary = selectedProfile?.tool {
                        task.tool = primary
                    }
                }
            }
            .frame(maxWidth: compact ? .infinity : 220, alignment: .leading)
            captioned(NSLocalizedString("Agent", comment: "")) {
                Picker("", selection: $task.tool) {
                    ForEach(toolChoices) { spec in
                        Text(spec.tool.displayName).tag(spec.tool)
                    }
                }
                .labelsHidden()
            }
            .frame(maxWidth: compact ? .infinity : 160, alignment: .leading)
            captioned(NSLocalizedString("Start the agent in — a folder inside the workspace",
                                        comment: "task editor")) {
                repoPathField
                    .font(.system(size: 13, design: .monospaced))
                    .help(NSLocalizedString(
                        "A path inside the workspace VM. \"~\" is the home folder (/home/ubuntu). When it's a git repository, the task runs in its own worktree and branch there.",
                        comment: "task editor"))
                Toggle(NSLocalizedString("Create folder & git repo if needed",
                                         comment: "task editor"),
                       isOn: Binding(
                           get: { task.initRepo ?? false },
                           set: { task.initRepo = $0 ? true : nil }))
                    .platformCheckboxToggle()
                    .font(.system(size: 11))
                    .help(NSLocalizedString(
                        "Starting or planning first runs mkdir + git init (with an empty root commit) when the folder isn't already a git repository of its own. Leave off for a folder inside an existing repo.",
                        comment: "task editor"))
            }
            .frame(maxWidth: compact ? .infinity : nil, alignment: .leading)
        }
    }

    /// The path field. On a phone the default `.roundedBorder` fill is a faint
    /// grey that blends into the sheet (grey-on-grey); use an explicit
    /// control-background box with a visible border and primary text instead.
    @ViewBuilder private var repoPathField: some View {
        let field = TextField("", text: $task.repoPath, prompt: Text(verbatim: "~/my-repo"))
            .foregroundStyle(.primary)
        if compact {
            field
                .textFieldStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 8)
                    .fill(Color.platformControlBackground))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.18)))
        } else {
            field.textFieldStyle(.roundedBorder)
        }
    }

    private var bottomButtons: some View {
        HStack {
            if !isNew {
                Button(NSLocalizedString("Delete", comment: ""), role: .destructive) {
                    onDelete(task.id)
                }
            }
            if task.stage == .backlog {
                Button {
                    onPlan(task)
                } label: {
                    Label(NSLocalizedString("Plan", comment: "task editor"),
                          systemImage: "list.number")
                }
                .disabled(!canSave)
                .help(NSLocalizedString(
                    "Saves, then opens a visible planning session: the agent explores the repo (ask it things — it can see you) and files ordered phase cards with dependencies into the Plan column.",
                    comment: "task editor"))
            }
            Spacer()
            Button(NSLocalizedString("Cancel", comment: ""), action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button(NSLocalizedString("Save", comment: "")) { onSave(task) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
    }

}
