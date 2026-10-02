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
    /// "+": the board with a blank task's editor open.
    var onNew: () -> Void = {}

    /// Everything not done — the header's count.
    private var openCount: Int {
        store.backlogTasks().count + store.tasks(in: .planning).count
            + store.tasks(in: .inProgress).count + store.tasks(in: .testing).count
    }

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
            SidebarSectionHeader(title: NSLocalizedString("Tasks", comment: "sidebar section"),
                                 selected: model.taskBoardSelected,
                                 badges: [(attentionCount, .red), (reviewCount, .orange)],
                                 count: openCount,
                                 help: NSLocalizedString("Open the coding board (⇧⌘T)", comment: ""),
                                 onTitle: onShowBoard,
                                 onAdd: onNew,
                                 addHelp: NSLocalizedString("New task", comment: ""))

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
        /// Testing → Done as it stands (no merge, nothing removed).
        var markDone: (UUID) -> Void = { _ in }
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
        /// Who a task can be handed to instead of a new worktree agent.
        var assignees: () -> TaskAssigneeChoices = { TaskAssigneeChoices() }
        /// Queue a task for new agents, a session or a room (nil = take it
        /// off its queue). nil closure = queues aren't available here.
        var assign: ((UUID, TaskAssignment?) -> Void)?
        /// Answer the assignee's question.
        var answer: (UUID, String) -> Void = { _, _ in }
        /// Take a handed-off task back to the backlog.
        var recall: (UUID) -> Void = { _ in }
        /// Show the session (or room) working on a handed-off task.
        var openAssignee: (CodingTask) -> Void = { _ in }
    }

    var store: CodingTaskStore
    @Bindable var model: SessionListModel
    /// Fresh profile snapshot for the editor sheet's pickers.
    let profilesProvider: () -> [Profile]
    let actions: Actions

    /// The editor sheet's subject: an existing task or a fresh draft.
    @State private var editing: CodingTask?
    /// The "who picks this up" sheet's subject.
    @State private var assigning: CodingTask?
    /// Where new backlog items go (TaskAssignment.autoAssign, mirrored here
    /// so the header redraws).
    @State private var autoAssign: TaskAssignment? = TaskAssignment.autoAssign
    @State private var finishWithPR = TaskAssignment.finishWithPullRequest
    /// Plan-column multi-selection (batch start).
    @State private var selectedPhases: Set<UUID> = []
    @State private var confirmingBatchDelete = false
    /// Compact = iPhone portrait → columns stack in one vertical scroll.
    @Environment(\.horizontalSizeClass) private var hSize
    private var compact: Bool { hSize == .compact }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if os(macOS)
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
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
                // Five columns rarely fit (an iPad in portrait, a Mac window
                // with the sidebar and Files pane open), so the board pans
                // horizontally. Columns fill the width when there's room and
                // never shrink below a readable minimum — beyond that the
                // strip scrolls. (On the Mac the board used to overflow its
                // stage and spill over the sidebar.)
                GeometryReader { geo in
                    // An empty Plan column folds to a rail: most boards have
                    // no phases, and four columns then fit where five didn't.
                    let planEmpty = store.tasks(in: .planning).isEmpty
                    let w = Self.columnWidth(count: planEmpty ? 4 : 5,
                                             available: geo.size.width - (planEmpty ? 60 : 0))
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(alignment: .top, spacing: 14) {
                            backlogColumn.frame(width: w)
                            if planEmpty {
                                KanbanRail(
                                    title: NSLocalizedString("Plan", comment: "kanban column"),
                                    systemImage: "list.number", tint: .blue,
                                    help: NSLocalizedString(
                                        "No phases yet — click Plan on a backlog card to have an agent split it into ordered phases.",
                                        comment: "kanban"))
                            } else {
                                planColumn.frame(width: w)
                            }
                            inProgressColumn.frame(width: w)
                            testingColumn.frame(width: w)
                            doneColumn.frame(width: w)
                        }
                        .padding(16)
                    }
                }
            }
        }
        .background(BoardBackdrop(tints: [.blue, .purple, .indigo]))
        // iOS puts the board inside a NavigationStack, which already has a bar
        // across the top — so the in-board header would be the SECOND title on
        // screen. Hand the same icon + title + New action to that bar instead
        // and give the columns the space back.
        #if os(iOS) || os(visionOS)
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
        // The sidebar's "+" asked for a blank task: open its editor whether
        // the board was just mounted for it or already on stage.
        .onAppear { consumeNewTaskRequest() }
        .onChange(of: model.newTaskRequested) { _, _ in consumeNewTaskRequest() }
        .sheet(item: $editing) { task in
            TaskEditorSheet(
                task: task,
                profiles: profilesProvider(),
                siblings: task.parentTaskID.map { parent in
                    store.tasks.filter { $0.parentTaskID == parent && $0.id != task.id }
                        .sorted { $0.createdAt < $1.createdAt }
                } ?? [],
                isNew: store.task(task.id) == nil,
                onSave: { saved in
                    actions.save(saved)
                    // A queued task (or a new one under the board's standing
                    // choice) goes to its assignee's queue now.
                    if saved.stage == .backlog, let a = saved.assignment, let assign = actions.assign {
                        assign(saved.id, a)
                    }
                    editing = nil
                },
                onPlan: { draft in
                    actions.save(draft)
                    actions.plan(draft.id)
                    editing = nil
                },
                onDelete: { id in actions.delete(id); editing = nil },
                onCancel: { editing = nil },
                assignees: actions.assign == nil ? TaskAssigneeChoices() : actions.assignees(),
                canAssign: actions.assign != nil)
        }
        .sheet(item: $assigning) { task in
            AssignTaskSheet(
                task: task,
                choices: actions.assignees(),
                onPick: { a in
                    actions.assign?(task.id, a)
                    assigning = nil
                },
                onStartNow: {
                    actions.start(task.id)
                    assigning = nil
                },
                onCancel: { assigning = nil })
        }
    }

    private func consumeNewTaskRequest() {
        guard model.newTaskRequested, editing == nil else { return }
        model.newTaskRequested = false
        editing = newDraft()
    }

    /// A blank task on the first workspace — the "New Task" subject —
    /// queued for the board's standing choice, if it has one.
    private func newDraft() -> CodingTask {
        let profiles = profilesProvider()
        var t = CodingTask(profileID: profiles.first?.id ?? UUID(),
                           tool: profiles.first?.tool ?? .claude)
        if actions.assign != nil { t.assignment = autoAssign }
        return t
    }

    private var header: some View {
        let running = store.tasks(in: .inProgress).count
        let review = store.tasks(in: .testing).count
        let needsYou = store.tasks(in: .inProgress).filter { liveStatus(of: $0) == .needsInput }.count
        return HStack(spacing: 12) {
            Image(systemName: "checklist")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.tint)
            Text(NSLocalizedString("Coding Tasks", comment: "coding kanban title"))
                .font(.system(size: 16, weight: .bold))
            HStack(spacing: 6) {
                if needsYou > 0 {
                    CardStatusPill(text: String(format: NSLocalizedString("%d need you", comment: "task board"), needsYou),
                                   tint: .red)
                }
                if running > 0 {
                    CardStatusPill(text: String(format: NSLocalizedString("%d running", comment: ""), running),
                                   tint: .blue)
                }
                if review > 0 {
                    CardStatusPill(text: String(format: NSLocalizedString("%d to review", comment: "task board"), review),
                                   tint: .purple)
                }
            }
            Spacer()
            if actions.assign != nil {
                autoAssignMenu
            }
            Button { editing = newDraft() } label: {
                Label(NSLocalizedString("New Task", comment: ""), systemImage: "plus")
            }
            .modifier(ProminentGlassButton())
            .help(NSLocalizedString("New task — or ⇧⌥Space from any app for a quick one", comment: "task board"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .modifier(GlassCapsule(cornerRadius: 20))
    }

    /// "New items go to: …" — the board's standing choice for new backlog
    /// items, so they're picked up without assigning each one.
    private var autoAssignMenu: some View {
        let choices = actions.assignees()
        return Menu {
            Section(NSLocalizedString("New backlog items go to", comment: "auto assign")) {
                Button {
                    setAutoAssign(nil)
                } label: {
                    Label(NSLocalizedString("Nobody — I start them", comment: "auto assign"),
                          systemImage: autoAssign == nil ? "checkmark" : "hand.raised")
                }
                Button {
                    setAutoAssign(.switchboard)
                } label: {
                    Label(NSLocalizedString("The Switchboard — it picks a session", comment: "quick task"),
                          systemImage: autoAssign?.kind == .switchboard ? "checkmark" : "switch.2")
                }
                Button {
                    setAutoAssign(.newAgent)
                } label: {
                    Label(String(format: NSLocalizedString("A new agent each (%d at a time)", comment: "auto assign"),
                                 TaskAssignment.newAgentConcurrency),
                          systemImage: autoAssign?.kind == .worktree ? "checkmark" : "arrow.triangle.branch")
                }
            }
            if !choices.sessions.isEmpty {
                Section(NSLocalizedString("A session", comment: "auto assign")) {
                    ForEach(choices.sessions) { s in
                        Button {
                            setAutoAssign(TaskAssignment(kind: .session, id: s.id, label: s.label))
                        } label: {
                            Label(s.label + (s.workspace.isEmpty ? "" : "  ·  " + s.workspace),
                                  systemImage: autoAssign?.kind == .session && autoAssign?.id == s.id
                                    ? "checkmark" : "person.crop.circle")
                        }
                    }
                }
            }
            if !choices.rooms.isEmpty {
                Section(NSLocalizedString("A room", comment: "auto assign")) {
                    ForEach(choices.rooms) { r in
                        Button {
                            setAutoAssign(TaskAssignment(kind: .room, id: r.id, label: "#" + r.name))
                        } label: {
                            Label("#" + r.name,
                                  systemImage: autoAssign?.kind == .room && autoAssign?.id == r.id
                                    ? "checkmark" : "square.grid.2x2")
                        }
                    }
                }
            }
            Divider()
            Toggle(NSLocalizedString("Sessions and rooms open a pull request when done", comment: "auto assign"),
                   isOn: Binding(get: { finishWithPR }, set: { finishWithPR = $0; TaskAssignment.finishWithPullRequest = $0 }))
        } label: {
            Label(autoAssign.map {
                String(format: NSLocalizedString("New items → %@", comment: "auto assign"), $0.label)
            } ?? NSLocalizedString("Auto-pickup: off", comment: "auto assign"),
                  systemImage: autoAssign == nil ? "tray.and.arrow.down" : "bolt.fill")
        }
        .fixedSize()
        .help(NSLocalizedString(
            "Who picks up new backlog items on their own and takes them to Testing/Review. Each task can still be assigned by hand.",
            comment: "auto assign"))
    }

    private func setAutoAssign(_ a: TaskAssignment?) {
        autoAssign = a
        TaskAssignment.autoAssign = a
    }

    #if os(iOS) || os(visionOS)
    /// Kanban column width for the horizontally-panning iPad board: split the
    /// viewport when it's wide enough, floor at 300pt (then the strip scrolls),
    /// cap at the column's own 400pt max so wide boards don't balloon.
    #endif
    static func columnWidth(count: Int, available: CGFloat) -> CGFloat {
        let spacing: CGFloat = 14, inset: CGFloat = 36
        let split = (available - inset - spacing * CGFloat(count - 1)) / CGFloat(count)
        #if os(macOS)
        return min(400, max(205, split))
        #else
        return min(400, max(300, split))
        #endif
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
        // Demo fixture (doc/video captures): in-progress cards run, no VM behind them.
        #if os(macOS)
        if DemoMode.isOn, task.stage == .inProgress { return .working }
        #endif
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
                                                         comment: "kanban"),
                            subtitle: NSLocalizedString("Briefs waiting to start", comment: "kanban column")) {
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
                    onDelete: { actions.delete(task.id) },
                    queuePosition: TaskAssignment.queuePosition(of: task, in: store.tasks),
                    onAssign: actions.assign == nil ? nil : { assigning = task },
                    onUnassign: actions.assign.map { assign in { assign(task.id, nil) } })
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
                                comment: "kanban"),
                            subtitle: NSLocalizedString("Phases, in order", comment: "kanban column")) {
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
                            tint: .blue,
                            emptyText: NSLocalizedString("Nothing running", comment: "kanban"),
                            subtitle: NSLocalizedString("Agents at work", comment: "kanban column")) {
            ForEach(tasks) { task in
                if let a = task.assignment, a.kind != .worktree {
                    AssignedTaskCard(
                        task: task,
                        accentHex: accentHex(for: task.profileID),
                        onOpen: { actions.openAssignee(task) },
                        onAnswer: { actions.answer(task.id, $0) },
                        onRecall: { actions.recall(task.id) })
                } else {
                InProgressTaskCard(
                    task: task,
                    accentHex: accentHex(for: task.profileID),
                    workspaceName: workspaceName(for: task.profileID),
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
    }

    private var testingColumn: some View {
        let tasks = store.tasks(in: .testing)
        return KanbanColumn(title: NSLocalizedString("Testing/Review", comment: "kanban column"),
                            systemImage: "eye",
                            count: tasks.count,
                            tint: .purple,
                            emptyText: NSLocalizedString("Nothing to review", comment: "kanban"),
                            subtitle: NSLocalizedString("Waiting for your review", comment: "kanban column")) {
            ForEach(tasks) { task in
                TestingTaskCard(
                    task: task,
                    accentHex: accentHex(for: task.profileID),
                    workspaceName: workspaceName(for: task.profileID),
                    onOpen: { actions.openReview(task.id) })
                    .modifier(RemovableCard(title: task.title, stage: task.stage,
                                            onRemove: { actions.delete(task.id) },
                                            onDestroy: { actions.destroy(task.id) }))
                    .contextMenu {
                        Button(NSLocalizedString("Mark as Done", comment: "kanban menu")) {
                            actions.markDone(task.id)
                        }
                        Divider()
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
                            tint: .green,
                            emptyText: NSLocalizedString("Nothing shipped yet", comment: "kanban"),
                            subtitle: NSLocalizedString("Merged or closed", comment: "kanban column")) {
            ForEach(tasks) { task in
                DoneTaskCard(task: task,
                             accentHex: accentHex(for: task.profileID),
                             workspaceName: workspaceName(for: task.profileID),
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
                    let excerpt = plainExcerpt(task.details)
                    if !excerpt.isEmpty {
                        Text(excerpt)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
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
                        CardErrorLine(text: err)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .modifier(CardChrome(borderTint: isSelected ? .accentColor : .clear))
    }
}

/// A brief's markdown as one line of plain prose, for card excerpts:
/// headings, list markers, emphasis and code fences dropped.
func plainExcerpt(_ markdown: String) -> String {
    var out: [String] = []
    var inFence = false
    for raw in markdown.split(whereSeparator: \.isNewline) {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("```") { inFence.toggle(); continue }
        if inFence || line.isEmpty { continue }
        while let f = line.first, "#>-*+".contains(f) {
            line.removeFirst()
            line = line.trimmingCharacters(in: .whitespaces)
        }
        if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty {
            line = String(line[line.index(after: dot)...]).trimmingCharacters(in: .whitespaces)
        }
        line = line.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
        if !line.isEmpty { out.append(line) }
        if out.joined(separator: " ").count > 400 { break }
    }
    return out.joined(separator: " ")
}

/// A card's error, one line, full text on hover.
private struct CardErrorLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9.5))
            Text(text)
                .lineLimit(2)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.red)
        .help(text)
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
    /// Its place in its assignee's queue (1 = next), when queued.
    var queuePosition: Int? = nil
    /// Open the "who picks this up" sheet; nil = queues aren't available.
    var onAssign: (() -> Void)? = nil
    var onUnassign: (() -> Void)? = nil

    /// While the planning session runs, the card IS the door to it.
    private var planningLive: Bool {
        task.validationInFlight && task.branchSlug != nil
    }

    private var untitled: Bool { task.title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        Button(action: { planningLive ? onOpenSession() : onEdit() }) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    WorkspaceChip(name: workspaceName, accentHex: accentHex)
                        .layoutPriority(-1)
                    Spacer(minLength: 4)
                    if let onAssign, !planningLive {
                        Button(action: onAssign) {
                            if let a = task.assignment {
                                Label(a.label, systemImage: a.kind == .switchboard ? "switch.2" : a.kind == .room ? "square.grid.2x2"
                                      : a.kind == .worktree ? "arrow.triangle.branch" : "person.crop.circle")
                                    .lineLimit(1)
                            } else {
                                Label(NSLocalizedString("Assign", comment: "task card"),
                                      systemImage: "person.crop.circle.badge.plus")
                            }
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(task.assignment == nil ? Color.secondary : Color.indigo)
                        .help(NSLocalizedString("Who picks this task up", comment: "task card"))
                    }
                    if planningLive {
                        CardStatusPill(text: NSLocalizedString("Planning", comment: "task card"),
                                       tint: .blue, spinning: true)
                            .help(NSLocalizedString(
                                "A visible planning session is running — click the card to open it; phases appear in the Plan column as it files them.",
                                comment: ""))
                    } else if task.validation != nil {
                        Image(systemName: "person.fill.checkmark")
                            .font(.system(size: 10))
                            .foregroundStyle(.purple)
                            .help(NSLocalizedString("Plan reviewed by the agent", comment: ""))
                    }
                }
                Text(untitled ? NSLocalizedString("Untitled task", comment: "") : task.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                let excerpt = plainExcerpt(task.details)
                if !excerpt.isEmpty {
                    Text(excerpt)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let parentTitle {
                    Label(String(format: NSLocalizedString("part of “%@”", comment: ""),
                                 parentTitle),
                          systemImage: "arrow.turn.down.right")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let err = task.lastError {
                    CardErrorLine(text: err)
                }
                if let a = task.assignment, let pos = queuePosition, task.lastError == nil {
                    HStack(spacing: 6) {
                        Image(systemName: "hourglass")
                        Text(pos == 1
                             ? String(format: NSLocalizedString("Next for %@", comment: "task card"), a.label)
                             : String(format: NSLocalizedString("#%1$d in %2$@'s queue", comment: "task card"), pos, a.label))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if let onUnassign {
                            Button(NSLocalizedString("Unassign", comment: "task card"), action: onUnassign)
                                .buttonStyle(.borderless)
                                .font(.system(size: 10.5))
                        }
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.indigo)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                } else {
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        Button(NSLocalizedString("Plan", comment: "task card")) { onPlan() }
                            .controlSize(.small)
                            .disabled(untitled || task.validationInFlight)
                            .help(NSLocalizedString(
                                "A planner agent reads the brief and the repository, then files ordered phase cards (with dependencies) in the Plan column.",
                                comment: "task card"))
                        Button {
                            onStart()
                        } label: {
                            Label(NSLocalizedString("One shot", comment: "task card"), systemImage: "play.fill")
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .disabled(untitled)
                        .help(NSLocalizedString(
                            "Straight to In Progress: a new agent does the whole task in a fresh worktree and hands you the diff in Testing/Review. To give it to a session or a room, use Assign.",
                            comment: "task card"))
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(CardChrome(borderTint: task.lastError != nil ? .red : .clear))
        .contextMenu {
            Button(NSLocalizedString("Edit…", comment: ""), action: onEdit)
            if !untitled {
                Button(NSLocalizedString("Start: New Agent in a Worktree", comment: "task card"), action: onStart)
            }
            if let onAssign {
                Button(NSLocalizedString("Assign…", comment: "task card"), action: onAssign)
            }
            if task.assignment != nil, let onUnassign {
                Button(NSLocalizedString("Unassign", comment: "task card"), action: onUnassign)
            }
            Divider()
            Button(NSLocalizedString("Delete", comment: ""), role: .destructive,
                   action: onDelete)
        }
    }
}

/// "Who picks this up?": search sessions by @nickname, rooms by #name, or
/// hand it to a new agent.
struct AssignTaskSheet: View {
    let task: CodingTask
    let choices: TaskAssigneeChoices
    var onPick: (TaskAssignment?) -> Void
    var onStartNow: () -> Void
    var onCancel: () -> Void
    @State private var query = ""
    @State private var prWhenDone = TaskAssignment.finishWithPullRequest
    @FocusState private var searchFocused: Bool

    private var q: String {
        query.trimmingCharacters(in: .whitespaces).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "@#"))
    }

    private var sessions: [TaskAssigneeChoices.Session] {
        guard !q.isEmpty else { return choices.sessions }
        return choices.sessions.filter {
            $0.label.lowercased().contains(q) || $0.workspace.lowercased().contains(q)
        }
    }

    private var rooms: [TaskAssigneeChoices.Room] {
        guard !q.isEmpty else { return choices.rooms }
        return choices.rooms.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("Who picks this up?", comment: "assign sheet"))
                    .font(.system(size: 16, weight: .semibold))
                Text(task.title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding([.horizontal, .top], 18)
            .padding(.bottom, 10)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(NSLocalizedString("@nickname or #room", comment: "assign sheet"), text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit {
                        if let s = sessions.first {
                            onPick(TaskAssignment(kind: .session, id: s.id, label: s.label))
                        } else if let r = rooms.first {
                            onPick(TaskAssignment(kind: .room, id: r.id, label: "#" + r.name))
                        }
                    }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if q.isEmpty {
                        row(icon: "arrow.triangle.branch", tint: .blue,
                            title: NSLocalizedString("A new agent", comment: "assign sheet"),
                            subtitle: NSLocalizedString("In its own fresh worktree — queued with the other new-agent tasks", comment: "assign sheet"),
                            selected: task.assignment?.kind == .worktree) { onPick(.newAgent) }
                    }
                    if q.isEmpty || "switchboard".hasPrefix(q) {
                        row(icon: "switch.2", tint: .orange,
                            title: NSLocalizedString("@switchboard", comment: "assign sheet"),
                            subtitle: NSLocalizedString("The app's Switchboard picks the session best placed for it", comment: "assign sheet"),
                            selected: task.assignment?.kind == .switchboard) { onPick(.switchboard) }
                    }
                    if !sessions.isEmpty {
                        header(NSLocalizedString("Sessions", comment: "assign sheet"))
                        ForEach(sessions) { s in
                            row(icon: "person.crop.circle.fill", tint: .indigo, title: s.label,
                                subtitle: [s.workspace, s.busy ? NSLocalizedString("busy — it takes this after its current work", comment: "assign sheet") : ""]
                                    .filter { !$0.isEmpty }.joined(separator: " · "),
                                selected: task.assignment?.kind == .session && task.assignment?.id == s.id) {
                                onPick(TaskAssignment(kind: .session, id: s.id, label: s.label))
                            }
                        }
                    }
                    if !rooms.isEmpty {
                        header(NSLocalizedString("Rooms", comment: "assign sheet"))
                        ForEach(rooms) { r in
                            row(icon: "square.grid.2x2.fill", tint: .teal, title: "#" + r.name,
                                subtitle: NSLocalizedString("The room's Switchboard picks a member", comment: "assign sheet"),
                                selected: task.assignment?.kind == .room && task.assignment?.id == r.id) {
                                onPick(TaskAssignment(kind: .room, id: r.id, label: "#" + r.name))
                            }
                        }
                    }
                    if sessions.isEmpty && rooms.isEmpty && !q.isEmpty {
                        Text(NSLocalizedString("No session or room matches.", comment: "assign sheet"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                    if choices.sessions.isEmpty && q.isEmpty {
                        Text(NSLocalizedString("No sessions yet — start one, give it a @nickname, and it can take tasks from the board.", comment: "assign sheet"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.top, 8)
                    }
                }
                .padding(10)
            }
            Divider()
            HStack {
                Toggle(NSLocalizedString("Open a pull request when done", comment: "assign sheet"),
                       isOn: Binding(get: { prWhenDone }, set: { prWhenDone = $0; TaskAssignment.finishWithPullRequest = $0 }))
                    .platformCheckboxToggle()
                    .font(.system(size: 11.5))
                    .help(NSLocalizedString("A session or room pushes its branch and opens a pull request before the card moves to Testing/Review.", comment: "assign sheet"))
                Spacer()
                if task.assignment != nil {
                    Button(NSLocalizedString("Unassign", comment: "task card")) { onPick(nil) }
                }
                Spacer()
                Button(NSLocalizedString("Cancel", comment: ""), action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
        }
        .frame(width: 440, height: 480)
        .onAppear { searchFocused = true }
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 8)
            .padding(.top, 8)
    }

    private func row(icon: String, tint: Color, title: String, subtitle: String, selected: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accentColor.opacity(0.1) : .clear))
    }
}

/// An In Progress card for a task handed to a session or a room: who has
/// it, what they last said, and their question when they're blocked.
private struct AssignedTaskCard: View {
    let task: CodingTask
    let accentHex: String
    var onOpen: () -> Void
    var onAnswer: (String) -> Void
    var onRecall: () -> Void
    @State private var answering = false
    @State private var reply = ""

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: task.assignment?.systemImage ?? "person.crop.circle")
                        Text(task.assignment?.label ?? "")
                            .lineLimit(1)
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.indigo)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.indigo.opacity(0.12)))
                    Spacer(minLength: 4)
                    if task.pendingQuestion != nil {
                        CardStatusPill(text: NSLocalizedString("Question", comment: "task card"),
                                       tint: .red, systemImage: "questionmark")
                    } else if task.delegationID == nil {
                        CardStatusPill(text: NSLocalizedString("Handing over", comment: "task card"),
                                       tint: .secondary, spinning: true)
                    } else {
                        CardStatusPill(text: NSLocalizedString("Working", comment: "task card"),
                                       tint: .blue, spinning: true)
                    }
                }
                Text(task.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let q = task.pendingQuestion {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(q)
                            .font(.system(size: 11.5))
                            .lineLimit(5)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            answering = true
                        } label: {
                            Label(NSLocalizedString("Answer…", comment: "task card"),
                                  systemImage: "arrowshape.turn.up.left.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.small)
                    }
                    .padding(8)
                    .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                } else if let note = task.assigneeNote {
                    Label(note, systemImage: "text.bubble")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                if let err = task.lastError {
                    Text(err).font(.system(size: 10.5)).foregroundStyle(.red).lineLimit(2).help(err)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(CardChrome(borderTint: task.pendingQuestion != nil ? .red : .indigo))
        .help(NSLocalizedString("Show the session working on it", comment: "task card"))
        .contextMenu {
            Button(NSLocalizedString("Show the Session", comment: "task card"), action: onOpen)
            Button(NSLocalizedString("Take It Back", comment: "task card"), role: .destructive, action: onRecall)
        }
        .alert(String(format: NSLocalizedString("Answer %@", comment: "task card"), task.assignment?.label ?? ""),
               isPresented: $answering) {
            TextField(NSLocalizedString("Your answer", comment: "task card"), text: $reply)
            Button(NSLocalizedString("Send", comment: "")) {
                let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { onAnswer(text) }
                reply = ""
            }
            Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) { reply = "" }
        } message: {
            Text(task.pendingQuestion ?? "")
        }
    }
}

private struct InProgressTaskCard: View {
    let task: CodingTask
    let accentHex: String
    var workspaceName: String = ""
    let status: AgentStatus?
    let onOpen: () -> Void
    var onResume: () -> Void = {}

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                // TimelineView so the whole card re-evaluates on a timer:
                // the relative time ticks, and "starting…" ages into
                // "session gone" even when nothing else redraws the board.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    HStack(spacing: 6) {
                        WorkspaceChip(name: workspaceName, accentHex: accentHex)
                            .layoutPriority(-1)
                        Spacer(minLength: 4)
                        if status == .needsInput {
                            CardStatusPill(text: NSLocalizedString("Needs you", comment: "task card"),
                                           tint: .red, systemImage: "hand.raised.fill")
                        } else if status == .done {
                            CardStatusPill(text: NSLocalizedString("Finishing", comment: "task card"),
                                           tint: .green)
                        } else if status != nil {
                            CardStatusPill(text: NSLocalizedString("Working", comment: "task card"),
                                           tint: .blue, spinning: true)
                        } else if let started = task.startedAt,
                                  context.date.timeIntervalSince(started) < 300 {
                            // No tab yet: within the boot/attach window that's
                            // normal startup, not a lost session.
                            CardStatusPill(text: NSLocalizedString("Starting", comment: "task card"),
                                           tint: .secondary, spinning: true)
                        } else {
                            CardStatusPill(text: NSLocalizedString("Session gone", comment: "task card"),
                                           tint: .orange, systemImage: "exclamationmark")
                        }
                    }
                }
                Text(task.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 8) {
                        if let started = task.startedAt {
                            Label {
                                RelativeTimeText(
                                    format: NSLocalizedString("started %@", comment: ""),
                                    date: started)
                                    .lineLimit(1)
                            } icon: {
                                Image(systemName: "clock")
                            }
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        }
                        if status == nil, let started = task.startedAt,
                           context.date.timeIntervalSince(started) >= 300 {
                            // A lost session isn't a dead end: reboot the
                            // workspace and re-launch the agent on the
                            // existing worktree.
                            Button {
                                onResume()
                            } label: {
                                Label(NSLocalizedString("Restart session", comment: "task card"),
                                      systemImage: "arrow.clockwise")
                                    .frame(maxWidth: .infinity)
                            }
                            .controlSize(.small)
                            .help(NSLocalizedString(
                                "The session is gone — boot the workspace if needed and relaunch the agent on this task's worktree.",
                                comment: "task card"))
                        } else {
                            HStack(spacing: 3) {
                                Text(NSLocalizedString("Open session", comment: "task card"))
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.tint)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(CardChrome(borderTint: status == .needsInput ? .red : .blue))
        .help(NSLocalizedString("Open the task's live session", comment: ""))
    }
}

private struct TestingTaskCard: View {
    let task: CodingTask
    let accentHex: String
    var workspaceName: String = ""
    let onOpen: () -> Void

    private var unsent: Int { task.comments.filter { $0.sentAt == nil }.count }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    WorkspaceChip(name: workspaceName, accentHex: accentHex)
                    Spacer(minLength: 4)
                    if unsent > 0 {
                        CardStatusPill(text: String(format: NSLocalizedString("%d comment(s)", comment: "task card"),
                                                    unsent),
                                       tint: .purple, systemImage: "text.bubble.fill")
                            .help(NSLocalizedString("Draft review comments", comment: ""))
                    }
                }
                Text(task.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let branch = task.branch {
                    Label(branch, systemImage: "arrow.triangle.branch")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let pr = task.pullRequestURL, let url = URL(string: pr) {
                    Link(destination: url) {
                        Label(String(format: NSLocalizedString("Pull request #%@", comment: "task card"),
                                     url.lastPathComponent),
                              systemImage: "arrow.triangle.pull")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .help(pr)
                }
                if let summary = task.deliverySummary {
                    VStack(alignment: .leading, spacing: 2) {
                        if let who = task.assignment?.label {
                            Text(String(format: NSLocalizedString("%@ says:", comment: "task card"), who))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.indigo)
                        }
                        Text(plainExcerpt(summary))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }
                if task.mergingAt != nil {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text(NSLocalizedString("Merging… goes Done once the changes land",
                                               comment: "task card"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                } else if let err = task.lastError {
                    CardErrorLine(text: err)
                } else {
                    HStack {
                        Spacer(minLength: 0)
                        Label(NSLocalizedString("Review Changes", comment: "task card"), systemImage: "eye")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.purple))
                    }
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
    var workspaceName: String = ""
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
        return ("xmark.circle", .secondary)
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: outcomeGlyph.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(outcomeGlyph.tint)
                    .frame(width: 18)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(2)
                        .foregroundStyle(task.merged || task.prOpened == true ? .primary : .secondary)
                    Text(outcomeText)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let done = task.completedAt {
                        Text(done.formatted(.relative(presentation: .named)))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    if !workspaceName.isEmpty {
                        WorkspaceChip(name: workspaceName, accentHex: accentHex)
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
/// The task editor — the board's New / Edit sheet, and the Quick Task
/// panel grown full size (`glass`). Title first, the who / where as chips,
/// a roomy description, ⌘↩ to save.
struct TaskEditorSheet: View {
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
    /// Sessions and rooms the task can be queued for.
    var assignees: TaskAssigneeChoices = TaskAssigneeChoices()
    /// Queues are available (the host runs a dispatcher).
    var canAssign = false
    /// Drawn on Liquid Glass (inside the Quick Task panel) instead of as a
    /// plain sheet.
    var glass = false

    @State private var preview = false
    @State private var editingFolder = false
    @State private var assigneeQuery = ""
    @FocusState private var titleFocused: Bool

    private var selectedProfile: Profile? {
        profiles.first { $0.id == task.profileID }
    }

    private var toolChoices: [Profile.ToolSpec] {
        selectedProfile?.allToolSpecs ?? []
    }

    /// A title, or a description to take one from — not every task
    /// deserves one of its own.
    private var canSave: Bool {
        selectedProfile != nil && !Self.titled(task).title.isEmpty
    }

    /// The task as saved: with no title of its own, it's named after its
    /// description, the way a session is named after its first message.
    static func titled(_ task: CodingTask) -> CodingTask {
        var t = task
        if t.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            t.title = AgentSession.title(fromMessage: t.details.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return t
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

    /// Compact = iPhone portrait → the sheet fills the screen and scrolls.
    @Environment(\.horizontalSizeClass) private var hSize
    private var compact: Bool { hSize == .compact }

    var body: some View {
        Group {
            if compact {
                ScrollView { formContent.padding(18) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                formContent
                    .padding(.horizontal, 26)
                    .padding(.top, 22)
                    .padding(.bottom, 18)
                    .frame(width: glass ? 760 : 720)
                    .frame(minHeight: 520, idealHeight: 600, maxHeight: 680)
            }
        }
        .modifier(EditorChrome(glass: glass))
        .onAppear { if isNew { titleFocused = true } }
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Label(isNew ? NSLocalizedString("New Task", comment: "task editor")
                            : NSLocalizedString("Edit Task", comment: "task editor"),
                      systemImage: isNew ? "plus.circle.fill" : "pencil.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if task.stage != .backlog {
                    Text(task.stage.rawValue.capitalized)
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
            }
            // No title yet: the one it'll get from the description, greyed.
            TextField(task.title.isEmpty && !Self.titled(task).title.isEmpty
                      ? Self.titled(task).title
                      : NSLocalizedString("What needs doing?", comment: "quick task"),
                      text: $task.title, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 24, weight: .bold))
                .lineLimit(1...3)
                .focused($titleFocused)

            chips

            descriptionCard
                .layoutPriority(1)

            if !isNew, let said = task.mergeReport ?? task.deliverySummary ?? task.assigneeNote,
               !said.isEmpty {
                assigneeCard(said)
            }

            if !siblings.isEmpty {
                dependencyChips
            }

            footer
        }
    }

    /// What the agent the task was handed to said: its delivery (or merge),
    /// else its latest progress report.
    private func assigneeCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(String(format: NSLocalizedString("%@ says", comment: "review: the assignee's delivery"),
                         task.assignment?.label ?? NSLocalizedString("The agent", comment: "review")),
                  systemImage: "text.bubble")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.indigo)
            ViewThatFits(in: .vertical) {
                MarkdownBlocks(text: text, compact: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ScrollView {
                    MarkdownBlocks(text: text, compact: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: 180)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.indigo.opacity(0.06)))
    }

    // MARK: Chips

    private var chips: some View {
        // Wraps on narrow widths (a phone).
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { chipList }
            VStack(alignment: .leading, spacing: 8) { chipList }
        }
    }

    /// A session or room decides where and with what the task runs —
    /// its own workspace, agent and folder.
    private var decidedByAssignee: TaskAssignment? {
        guard let a = task.assignment, a.kind != .worktree else { return nil }
        return a
    }

    @ViewBuilder private var chipList: some View {
        if canAssign && task.stage == .backlog {
            assigneeChip
        }
        Group {
            workspaceChip
            agentChip
            folderChip
        }
        .disabled(decidedByAssignee != nil)
        .opacity(decidedByAssignee != nil ? 0.4 : 1)
        .help(decidedByAssignee.map {
            String(format: NSLocalizedString("%@ works in its own workspace and folder, with its own agent", comment: "task editor"), $0.label)
        } ?? "")
        .animation(.easeOut(duration: 0.15), value: decidedByAssignee)
    }

    private func chipLabel(_ icon: String, _ text: String, tint: Color = .secondary,
                           active: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(text).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold)).opacity(0.6)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(active ? tint : Color.primary.opacity(0.8))
        .padding(.horizontal, 11).padding(.vertical, 6)
        .background(Capsule().fill(active ? tint.opacity(0.14) : Color.primary.opacity(0.06)))
        .overlay(Capsule().strokeBorder(active ? tint.opacity(0.3) : Color.primary.opacity(0.08)))
        .contentShape(Capsule())
    }

    private var assigneeChip: some View {
        Menu {
            Button {
                task.assignment = nil
            } label: { Label(NSLocalizedString("Nobody — I'll start it", comment: "task editor"), systemImage: "tray") }
            Button {
                task.assignment = .newAgent
            } label: { Label(NSLocalizedString("A new agent (in its own worktree)", comment: "task editor"),
                             systemImage: "arrow.triangle.branch") }
            Button {
                task.assignment = .switchboard
            } label: { Label(NSLocalizedString("The Switchboard — it picks a session", comment: "quick task"),
                             systemImage: "switch.2") }
            if !assignees.sessions.isEmpty {
                Section(NSLocalizedString("Sessions", comment: "assign sheet")) {
                    ForEach(assignees.sessions) { s in
                        Button {
                            task.assignment = TaskAssignment(kind: .session, id: s.id, label: s.label)
                            // Its work happens in its workspace: the card shows that one.
                            if let pid = s.profileID { task.profileID = pid }
                        } label: {
                            Label(s.label + (s.workspace.isEmpty ? "" : "  ·  " + s.workspace),
                                  systemImage: "person.crop.circle")
                        }
                    }
                }
            }
            if !assignees.rooms.isEmpty {
                Section(NSLocalizedString("Rooms", comment: "assign sheet")) {
                    ForEach(assignees.rooms) { r in
                        Button {
                            task.assignment = TaskAssignment(kind: .room, id: r.id, label: "#" + r.name)
                        } label: { Label("#" + r.name, systemImage: "square.grid.2x2") }
                    }
                }
            }
        } label: {
            chipLabel(task.assignment?.systemImage ?? "person.crop.circle.badge.plus",
                      task.assignment.map { String(format: NSLocalizedString("Queue for %@", comment: "quick task"), $0.label) }
                        ?? NSLocalizedString("Unassigned", comment: "task editor"),
                      tint: .indigo, active: task.assignment != nil)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(NSLocalizedString("Who picks it up", comment: "task editor"))
    }

    private var workspaceChip: some View {
        Menu {
            ForEach(profiles) { p in
                Button(p.name) {
                    task.profileID = p.id
                    if !toolChoices.contains(where: { $0.tool == task.tool }), let primary = selectedProfile?.tool {
                        task.tool = primary
                    }
                }
            }
        } label: {
            chipLabel("macwindow", selectedProfile?.name ?? NSLocalizedString("Workspace", comment: ""))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(NSLocalizedString("Workspace", comment: ""))
    }

    private var agentChip: some View {
        Menu {
            ForEach(toolChoices) { spec in
                Button(spec.tool.displayName) { task.tool = spec.tool }
            }
        } label: {
            chipLabel("cpu", task.tool.displayName)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(NSLocalizedString("Agent", comment: ""))
    }

    private var folderChip: some View {
        Button {
            editingFolder = true
        } label: {
            chipLabel("folder", task.repoPath.isEmpty ? "~" : task.repoPath)
        }
        .buttonStyle(.plain)
        .help(NSLocalizedString("Start the agent in — a folder inside the workspace", comment: "task editor"))
        .popover(isPresented: $editingFolder, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text(NSLocalizedString("Start the agent in — a folder inside the workspace", comment: "task editor"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("", text: $task.repoPath, prompt: Text(verbatim: "~/my-repo"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13, design: .monospaced))
                TextField("", text: Binding(
                    get: { task.cloneURL ?? "" },
                    set: { task.cloneURL = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }),
                          prompt: Text(verbatim: "https://github.com/org/repo.git"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .help(NSLocalizedString(
                        "Optional: clone this git repository into the folder above before the first start, using the workspace's git credentials. Skipped when the folder already holds a repository.",
                        comment: "task editor"))
                Toggle(NSLocalizedString("Create folder & git repo if needed", comment: "task editor"),
                       isOn: Binding(get: { task.initRepo ?? false },
                                     set: { task.initRepo = $0 ? true : nil }))
                    .platformCheckboxToggle()
                    .font(.system(size: 11.5))
            }
            .padding(14)
            .frame(width: 380)
        }
    }

    // MARK: Description

    private var descriptionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(NSLocalizedString("Description", comment: "task editor"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $preview) {
                    Text(NSLocalizedString("Write", comment: "editor mode")).tag(false)
                    Text(NSLocalizedString("Preview", comment: "editor mode")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
            Group {
                if preview {
                    ScrollView {
                        MarkdownBlocks(text: task.details)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                    }
                } else {
                    ZStack(alignment: .topLeading) {
                        if task.details.isEmpty {
                            Text(NSLocalizedString("Describe the task — what's wrong, where, what done looks like. Markdown welcome.",
                                                   comment: "task editor"))
                                .font(.system(size: 13.5))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 14)
                                .padding(.top, 8)
                                .allowsHitTesting(false)
                        }
                        TextEditor(text: $task.details)
                            .font(.system(size: 13.5))
                            .scrollContentBackground(.hidden)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 2)
                    }
                }
            }
            .frame(minHeight: compact ? 220 : 180, maxHeight: compact ? nil : .infinity)
        }
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.primary.opacity(glass ? 0.05 : 0.035)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08)))
    }

    // MARK: Dependencies

    private var dependencyChips: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(NSLocalizedString("Depends on — phases that must finish first", comment: "task editor"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(siblings) { sib in
                        let on = dependencyBinding(sib).wrappedValue
                        Button {
                            dependencyBinding(sib).wrappedValue.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: sib.stage == .done ? "checkmark.circle.fill"
                                      : on ? "lock.fill" : "circle")
                                Text(sib.title).lineLimit(1)
                            }
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(on ? Color.orange : sib.stage == .done ? .green : .secondary)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Capsule().fill((on ? Color.orange : Color.primary).opacity(on ? 0.13 : 0.05)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if !isNew {
                Button(role: .destructive) {
                    onDelete(task.id)
                } label: {
                    Image(systemName: "trash")
                }
                .help(NSLocalizedString("Delete", comment: ""))
            }
            Text(task.assignment.map { a -> String in
                a.kind == .worktree
                    ? NSLocalizedString("A new agent picks it up from the queue and takes it to Testing/Review.", comment: "task editor")
                    : String(format: NSLocalizedString("%@ picks it up on its own and takes it to Testing/Review.", comment: "task editor"), a.label)
            } ?? NSLocalizedString("Start it from the board: One shot, or Plan to split it into phases.", comment: "task editor"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if task.stage == .backlog && task.assignment == nil {
                Button {
                    onPlan(Self.titled(task))
                } label: {
                    Label(NSLocalizedString("Plan", comment: "task editor"), systemImage: "list.number")
                }
                .disabled(!canSave)
                .help(NSLocalizedString(
                    "Saves, then opens a visible planning session: the agent explores the repo (ask it things — it can see you) and files ordered phase cards with dependencies into the Plan column.",
                    comment: "task editor"))
            }
            Button(NSLocalizedString("Cancel", comment: ""), action: onCancel)
                .keyboardShortcut(.cancelAction)
            Button {
                onSave(Self.titled(task))
            } label: {
                Text(isNew ? NSLocalizedString("Add Task", comment: "task editor")
                           : NSLocalizedString("Save", comment: ""))
                    .padding(.horizontal, 6)
            }
            .modifier(ProminentGlassButton())
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSave)
            .help("⌘↩")
        }
        .controlSize(.large)
    }
}

/// The editor's backdrop: Liquid Glass in the Quick Task panel, the board's
/// soft wash as a sheet.
private struct EditorChrome: ViewModifier {
    let glass: Bool
    func body(content: Content) -> some View {
        if glass {
            content.modifier(GlassCapsule(cornerRadius: 28))
        } else {
            content.background(BoardBackdrop(tints: [.blue, .purple, .indigo]))
        }
    }
}
