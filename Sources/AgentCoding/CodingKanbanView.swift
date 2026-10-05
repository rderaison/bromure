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

// MARK: - Plurals

/// Counted phrases with a real singular (no "comment(s)"): one key for 1,
/// one for the rest — the languages shipped have at most that split for
/// the counts shown here (never 0).
enum TaskPlurals {
    static func comments(_ n: Int) -> String {
        n == 1 ? NSLocalizedString("1 comment", comment: "task card: one unsent review comment")
               : String(format: NSLocalizedString("%d comments", comment: "task card: unsent review comments, 2 or more"), n)
    }

    static func commentsDrafted(_ n: Int) -> String {
        n == 1 ? NSLocalizedString("1 comment drafted", comment: "diff pane")
               : String(format: NSLocalizedString("%d comments drafted", comment: "diff pane: 2 or more"), n)
    }

    /// Unsent review comments a Done / Discard drops.
    static func undeliveredDropped(_ n: Int) -> String {
        n == 1 ? NSLocalizedString("1 review comment that never reached the agent will be discarded.",
                                   comment: "review")
               : String(format: NSLocalizedString(
                    "%d review comments that never reached the agent will be discarded.",
                    comment: "review: 2 or more"), n)
    }

    static func undeliveredBanner(_ n: Int) -> String {
        n == 1 ? NSLocalizedString(
                    "1 comment didn't reach the agent before it handed the task back. Send it back again?",
                    comment: "review")
               : String(format: NSLocalizedString(
                    "%d comments didn't reach the agent before it handed the task back. Send them back again?",
                    comment: "review: 2 or more"), n)
    }

    /// "\n\n<dropped comments>" when a task has unsent comments, else "".
    static func droppedSuffix(_ task: CodingTask) -> String {
        let n = task.comments.filter { $0.sentAt == nil }.count
        return n == 0 ? "" : "\n\n" + undeliveredDropped(n)
    }
}

// MARK: - Live state

/// A started task's agent, read the way the sidebar reads the session that
/// runs it — the one source for the card's pill, the board's "need you"
/// count and the sidebar badge, so a card never spins "Working" beside a
/// session row that says "Ready".
@MainActor
enum TaskLiveState {
    /// The task's session bucket; nil when no tab or session is found for
    /// it (starting, or gone).
    static func bucket(of task: CodingTask, in model: SessionListModel,
                       sessions: AgentSessionStore?) -> SessionBucket? {
        // Demo fixture (doc/video captures): in-progress cards run, no VM behind them.
        #if os(macOS)
        if DemoMode.isOn, task.stage == .inProgress { return .working }
        #endif
        // The session the launch was bound to (see CodingTaskEngine.bindSession)
        // first: it holds even when nothing carries the worktree branch.
        // Only while it holds a tab: a relaunch opens a new session.
        let (session, tab) = find(task, in: model, sessions: sessions)
        if let session { return SessionHome.bucket(for: session, in: model) }
        // No session record (an older mirror): the tab's own status.
        guard let tab else { return nil }
        switch tab.agentStatus {
        case .needsInput: return .needsYou
        case .working:    return .working
        case .done:       return .idle
        }
    }

    /// The task's session (and its tab), as `bucket` reads them.
    private static func find(_ task: CodingTask, in model: SessionListModel,
                             sessions: AgentSessionStore?) -> (AgentSession?, TabsModel.Tab?) {
        if let sessions, let id = task.sessionID, let s = sessions.session(id), !s.isDeleted,
           !s.isArchived, s.windowIndex != nil, s.profileID == task.profileID {
            return (s, nil)
        }
        let slugs = [task.branchSlug, task.branch.map { String($0.dropFirst(3)) }].compactMap { $0 }
        guard !slugs.isEmpty else { return (nil, nil) }
        func matches(_ branch: String?) -> Bool {
            slugs.contains { AutomationBoard.branchMatches(branch, slug: $0) }
        }
        let tabs = model.entries.first { $0.id == task.profileID }?.model.tabs ?? []
        // By branch, else by the checkout the tab runs in (a tab whose
        // @worktree tag didn't make it).
        let tab = tabs.first { matches($0.worktreeBranch) }
            ?? tabs.first { t in
                guard let cwd = t.cwd, !cwd.isEmpty else { return false }
                if let dir = task.worktreeDir, !dir.isEmpty, cwd == dir { return true }
                return slugs.contains { cwd.hasSuffix("/" + $0) }
            }
        if let sessions {
            let session = tab.flatMap { sessions.session(profileID: task.profileID, windowIndex: $0.index) }
                ?? sessions.sessions.first {
                    $0.profileID == task.profileID && !$0.isDeleted && matches($0.worktreeBranch)
                }
            if let session { return (session, tab) }
        }
        return (nil, tab)
    }

    /// The task's agent couldn't start — said "Couldn't start" on the card
    /// as on its session's sidebar row and stage: its session carries the
    /// launch failure, or (no session to carry it) the card does.
    static func couldntStart(_ task: CodingTask, in model: SessionListModel,
                             sessions: AgentSessionStore?) -> Bool {
        guard task.stage == .inProgress else { return false }
        #if os(macOS)
        if DemoMode.isOn { return false }
        #endif
        let (session, tab) = find(task, in: model, sessions: sessions)
        if let session {
            return !session.isLaunching && !(session.lastError ?? "").isEmpty
        }
        return tab == nil && task.lastError != nil
    }

    /// What the board's "need you" counts: a running task waiting on the
    /// user, or one whose agent couldn't start — every card with a red chip.
    static func needsAttention(_ task: CodingTask, in model: SessionListModel,
                               sessions: AgentSessionStore?) -> Bool {
        bucket(of: task, in: model, sessions: sessions) == .needsYou
            || couldntStart(task, in: model, sessions: sessions)
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
    /// The sessions behind running tasks (see `TaskLiveState`).
    var sessionStore: AgentSessionStore? = nil

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
                : NSLocalizedString("No open tasks", comment: "tasks sidebar"))
        }
        return parts.joined(separator: " · ")
    }

    /// Finished agent runs waiting on a human review — the orange badge.
    private var reviewCount: Int { store.tasks(in: .testing).count }

    /// What the badge counts: running tasks whose agent is waiting on the
    /// user right now.
    private var attentionCount: Int {
        store.tasks(in: .inProgress).filter {
            TaskLiveState.needsAttention($0, in: model, sessions: sessionStore)
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            SidebarSectionHeader(title: NSLocalizedString("Coding Tasks", comment: "sidebar section"),
                                 selected: model.taskBoardSelected,
                                 badges: [(attentionCount, .red), (reviewCount, .orange)],
                                 count: openCount,
                                 help: NSLocalizedString("Open Coding Tasks (⇧⌘T)", comment: ""),
                                 onTitle: onShowBoard,
                                 onAdd: onNew,
                                 addHelp: NSLocalizedString("New Task", comment: ""))

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

/// The coding kanban: Backlog → In Progress → Review → Done. Backlog cards
/// carry a markdown brief written in the editor sheet; Start launches the
/// agent in a fresh worktree; the agent's done signal lands the card in
/// Review, where the review window shows the branch diff; landing closes it.
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
        /// Merge from a card: opens the review on its Merge confirmation
        /// (where a review window exists), else lands it — after the
        /// board's own confirm when `mergeNeedsConfirm`.
        var merge: (UUID) -> Void = { _ in }
        /// Discard: Done without merging, the branch and its checkout deleted.
        var closeNoMerge: (UUID) -> Void = { _ in }
        /// Review / In Progress → Done as it stands (no merge, branch kept).
        var markDone: (UUID) -> Void = { _ in }
        /// Stop the agent, back to the Backlog (worktree and branch kept).
        var stop: (UUID) -> Void = { _ in }
        /// A fresh run on a new branch, when there's nothing left to resume
        /// into (repository or branch gone).
        var startOver: (UUID) -> Void = { _ in }
        /// No review window here (iOS): the board confirms a Merge itself.
        var mergeNeedsConfirm = false
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
        /// Retry a landing that needs the user, with the same choices.
        var retryLanding: ((UUID) -> Void)? = nil
    }

    var store: CodingTaskStore
    @Bindable var model: SessionListModel
    /// Fresh profile snapshot for the editor sheet's pickers.
    let profilesProvider: () -> [Profile]
    let actions: Actions
    /// The sessions behind the cards: a running card reads its agent's
    /// state exactly as the sidebar row does. nil: the tab roster alone.
    var sessionStore: AgentSessionStore? = nil

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
    /// Card actions that ask first: Mark Done on a task with code (its
    /// branch is kept), Discard, and Merge where no review window confirms.
    @State private var confirmingDone: CodingTask?
    @State private var confirmingDiscard: CodingTask?
    @State private var confirmingMerge: CodingTask?
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
                    // An empty Plan column is left out: most boards have no
                    // phases, and four columns then fit where five didn't.
                    let planEmpty = store.tasks(in: .planning).isEmpty
                    let w = Self.columnWidth(count: planEmpty ? 4 : 5,
                                             available: geo.size.width)
                    ScrollView(.horizontal, showsIndicators: true) {
                        HStack(alignment: .top, spacing: 14) {
                            backlogColumn.frame(width: w)
                            // No phases: no Plan column at all (a folded rail
                            // with rotated text read as a broken column). It
                            // appears as soon as a backlog card's Plan files one.
                            if !planEmpty {
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
                    TaskDraftDefaults.remember(saved)
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
        .confirmationDialog(
            NSLocalizedString("Mark done without merging?", comment: "review"),
            isPresented: Binding(get: { confirmingDone != nil }, set: { if !$0 { confirmingDone = nil } }),
            titleVisibility: .visible, presenting: confirmingDone) { t in
            Button(NSLocalizedString("Mark Done", comment: "review")) { actions.markDone(t.id) }
            Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {}
        } message: { t in
            Text((t.stage == .inProgress
                 ? String(format: NSLocalizedString("The agent is stopped. Nothing is merged; the branch %@ and its checkout are kept in the workspace.", comment: "task card"),
                          t.branch ?? t.branchSlug.map { "wt/" + $0 } ?? "")
                 : String(format: NSLocalizedString("Nothing is merged. The branch %@ and its checkout are kept in the workspace.", comment: "review"),
                          t.branch ?? "")) + TaskPlurals.droppedSuffix(t))
        }
        .confirmationDialog(
            NSLocalizedString("Discard this branch?", comment: "review"),
            isPresented: Binding(get: { confirmingDiscard != nil }, set: { if !$0 { confirmingDiscard = nil } }),
            titleVisibility: .visible, presenting: confirmingDiscard) { t in
            Button(NSLocalizedString("Discard Branch", comment: "review"), role: .destructive) { actions.closeNoMerge(t.id) }
            Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {}
        } message: { t in
            Text(String(format: NSLocalizedString(
                "The branch %@ and its checkout are deleted and the agent's session is put away. The task goes to Done as closed without merging; its transcript is kept.",
                comment: "review"), t.branch ?? t.branchSlug.map { "wt/" + $0 } ?? "")
                 + TaskPlurals.droppedSuffix(t))
        }
        .confirmationDialog(
            String(format: NSLocalizedString("Merge into %@?", comment: "landing confirm"),
                   confirmingMerge?.landingTarget ?? NSLocalizedString("parent", comment: "kanban menu")),
            isPresented: Binding(get: { confirmingMerge != nil }, set: { if !$0 { confirmingMerge = nil } }),
            titleVisibility: .visible, presenting: confirmingMerge) { t in
            Button(NSLocalizedString("Merge", comment: "landing confirm")) { actions.merge(t.id) }
            Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {}
        } message: { t in
            Text(String(format: NSLocalizedString(
                "Bromure merges it directly when it can; otherwise %1$@, the agent that wrote it, rebases onto %2$@, fixes conflicts, runs the tests and merges. Afterwards the branch is removed and the session archived.",
                comment: "landing confirm"), t.workerName, t.landingTarget ?? ""))
        }
    }

    /// Mark Done from a card: straight away for a task with nothing to
    /// merge, after a confirm for one with code (its branch is kept).
    private func requestMarkDone(_ t: CodingTask) {
        if t.stage == .testing && t.isNoCode { actions.markDone(t.id) } else { confirmingDone = t }
    }

    private func requestMerge(_ t: CodingTask) {
        if actions.mergeNeedsConfirm { confirmingMerge = t } else { actions.merge(t.id) }
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
        // The workspace (and its folder) the last task was written for —
        // the first workspace in the list is rarely the one being worked on.
        let last = TaskDraftDefaults.lastWorkspace.flatMap { id in profiles.first { $0.id == id } }
        let profile = last ?? profiles.first
        var t = CodingTask(profileID: profile?.id ?? UUID(),
                           repoPath: profile.flatMap { TaskDraftDefaults.lastFolder(for: $0.id) } ?? "~",
                           tool: profile?.tool ?? .claude)
        if actions.assign != nil { t.assignment = autoAssign }
        return t
    }

    private var header: some View {
        // A narrow window drops the pills, then the labels — never wraps the
        // title or the button one letter per line.
        ViewThatFits(in: .horizontal) {
            headerRow(compact: false)
            headerRow(compact: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .modifier(GlassCapsule(cornerRadius: 20))
    }

    private func headerRow(compact: Bool) -> some View {
        // Each task counted once: one that needs you (couldn't start, asks
        // something, a landing waiting on you) isn't also "in progress".
        let inProgress = store.tasks(in: .inProgress)
        let testing = store.tasks(in: .testing)
        let stuck = inProgress.filter { TaskLiveState.needsAttention($0, in: model, sessions: sessionStore) }.count
        let landingStuck = testing.filter { $0.landing?.phase == .needsYou }.count
        let needsYou = stuck + landingStuck
        let running = inProgress.count - stuck
        let review = testing.count - landingStuck
        return HStack(spacing: 12) {
            Image(systemName: "checklist")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.tint)
            Text(NSLocalizedString("Coding Tasks", comment: "coding kanban title"))
                .font(.system(size: 16, weight: .bold))
                .lineLimit(1)
                .fixedSize()
            if !compact {
                HStack(spacing: 6) {
                    if needsYou > 0 {
                        CardStatusPill(text: String(format: NSLocalizedString("%d need you", comment: "task board"), needsYou),
                                       tint: .red)
                    }
                    if running > 0 {
                        CardStatusPill(text: String(format: NSLocalizedString("%d in progress", comment: ""), running),
                                       tint: .blue)
                    }
                    if review > 0 {
                        CardStatusPill(text: String(format: NSLocalizedString("%d to review", comment: "task board"), review),
                                       tint: .purple)
                    }
                }
                .fixedSize()
            }
            Spacer(minLength: 8)
            if actions.assign != nil {
                autoAssignMenu(compact: compact)
            }
            Button { editing = newDraft() } label: {
                if compact {
                    Image(systemName: "plus")
                } else {
                    Label(NSLocalizedString("New Task", comment: ""), systemImage: "plus")
                        .fixedSize()
                }
            }
            .modifier(ProminentGlassButton())
            .accessibilityLabel(NSLocalizedString("New Task", comment: ""))
            .help(NSLocalizedString("New task — or ⇧⌥Space from any app for a quick one", comment: "task board"))
        }
    }

    /// "New items go to: …" — the board's standing choice for new backlog
    /// items, so they're picked up without assigning each one.
    private func autoAssignMenu(compact: Bool) -> some View {
        let choices = actions.assignees()
        return Menu {
            Section(NSLocalizedString("Assign new tasks to", comment: "auto assign")) {
                Button {
                    setAutoAssign(nil)
                } label: {
                    Label(NSLocalizedString("Unassigned — I'll start it", comment: "task editor"),
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
            Toggle(NSLocalizedString("Sessions and rooms open a pull request at delivery (skips review)", comment: "auto assign"),
                   isOn: Binding(get: { finishWithPR }, set: { finishWithPR = $0; TaskAssignment.finishWithPullRequest = $0 }))
        } label: {
            let title = autoAssign.map {
                String(format: NSLocalizedString("New tasks: assigned to %@", comment: "auto assign"), $0.label)
            } ?? NSLocalizedString("New tasks: Unassigned", comment: "auto assign")
            if compact {
                Image(systemName: autoAssign == nil ? "tray.and.arrow.down" : "bolt.fill")
            } else {
                Label(title, systemImage: autoAssign == nil ? "tray.and.arrow.down" : "bolt.fill")
                    .lineLimit(1)
            }
        }
        .fixedSize()
        .help(NSLocalizedString(
            "Who new tasks are queued for when you create them — they pick them up on their own and take them to Review. Each task can still be assigned by hand.",
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
        // A task whose workspace was deleted (or isn't known on this host)
        // still says so — an empty chip read as a rendering bug.
        model.profileRows.first { $0.id == profileID }?.name
            ?? NSLocalizedString("Deleted workspace", comment: "task card workspace chip")
    }

    /// A started task's agent, as the sidebar reads its session (observable
    /// — status changes redraw the board).
    private func liveStatus(of task: CodingTask) -> SessionBucket? {
        TaskLiveState.bucket(of: task, in: model, sessions: sessionStore)
    }

    // MARK: Columns

    private var backlogColumn: some View {
        let tasks = store.backlogTasks()
        return KanbanColumn(title: NSLocalizedString("Backlog", comment: "kanban column"),
                            systemImage: "tray",
                            count: tasks.count,
                            emptyText: NSLocalizedString("No tasks yet — write one.",
                                                         comment: "kanban"),
                            subtitle: NSLocalizedString("Tasks waiting to start", comment: "kanban column")) {
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
                    .draggable(task.id.uuidString)
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
                                "No phases yet — click Plan First on a Backlog task.",
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
                            "Start %d Selected", comment: "plan column"), selected.count),
                              systemImage: "play.fill")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .help(NSLocalizedString(
                        "Starts every selected phase. Phases whose dependencies aren't Done queue and start automatically when they are.",
                        comment: "plan column"))
                    Button(NSLocalizedString("Clear", comment: "plan column")) {
                        selectedPhases.removeAll()
                    }
                    .controlSize(.small)
                    Spacer(minLength: 0)
                    Button(role: .destructive) {
                        confirmingBatchDelete = true
                    } label: {
                        Label(NSLocalizedString("Remove", comment: "plan column"),
                              systemImage: "trash")
                    }
                    .controlSize(.small)
                    .help(NSLocalizedString("Remove every selected phase from the board",
                                            comment: "plan column"))
                    .confirmationDialog(
                        String(format: NSLocalizedString(
                            "Remove %d selected phase(s)?", comment: "plan column"),
                            selected.count),
                        isPresented: $confirmingBatchDelete, titleVisibility: .visible
                    ) {
                        Button(NSLocalizedString("Remove", comment: "plan column"),
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
                    workspaceName: workspaceName(for: task.profileID),
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
                    onEdit: { editing = task },
                    menu: CardMenuItem.list([
                        .init(title: NSLocalizedString("Start", comment: "")) { actions.start(task.id) },
                        .init(title: NSLocalizedString("Edit…", comment: "")) { editing = task },
                        .init(title: selectedPhases.contains(task.id)
                              ? NSLocalizedString("Deselect", comment: "plan card menu")
                              : NSLocalizedString("Select", comment: "plan card menu")) {
                            if selectedPhases.contains(task.id) { selectedPhases.remove(task.id) }
                            else { selectedPhases.insert(task.id) }
                        },
                        .divider,
                        .init(title: NSLocalizedString("Remove Task", comment: "task card"),
                              role: .destructive) { actions.delete(task.id) },
                    ]))
                    .draggable(task.id.uuidString)
                    .modifier(RemovableCard(title: task.title, stage: task.stage) {
                        actions.delete(task.id)
                    })
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
                        workspaceName: workspaceName(for: task.profileID),
                        onOpen: { actions.openAssignee(task) },
                        onAnswer: { actions.answer(task.id, $0) },
                        onRecall: { actions.recall(task.id) })
                } else {
                InProgressTaskCard(
                    task: task,
                    accentHex: accentHex(for: task.profileID),
                    workspaceName: workspaceName(for: task.profileID),
                    status: liveStatus(of: task),
                    couldntStart: TaskLiveState.couldntStart(task, in: model, sessions: sessionStore),
                    onOpen: { actions.jumpToRun(task) },
                    onResume: { actions.resume(task.id) },
                    onStartOver: { actions.startOver(task.id) },
                    onMarkDone: { requestMarkDone(task) },
                    menu: CardMenuItem.list([
                        .init(title: NSLocalizedString("Open Session", comment: "task card")) {
                            actions.jumpToRun(task)
                        },
                        task.restartNeeded == true
                            ? .init(title: NSLocalizedString("Start Over", comment: "task card")) {
                                actions.startOver(task.id)
                            }
                            : .init(title: NSLocalizedString("Restart Session", comment: "")) {
                                actions.resume(task.id)
                            },
                        .init(title: NSLocalizedString("Move to Review", comment: "")) {
                            actions.moveToTesting(task.id)
                        },
                        .init(title: NSLocalizedString("Mark Done", comment: "review")) {
                            requestMarkDone(task)
                        },
                        .init(title: NSLocalizedString("Stop & Return to Backlog", comment: "task card")) {
                            actions.stop(task.id)
                        },
                        .divider,
                        .init(title: NSLocalizedString("Stop & Discard Branch", comment: ""),
                              role: .destructive) { actions.destroy(task.id) },
                        .init(title: NSLocalizedString("Remove Task Only", comment: ""),
                              role: .destructive) { actions.delete(task.id) },
                    ]))
                    .modifier(RemovableCard(title: task.title, stage: task.stage,
                                            onRemove: { actions.delete(task.id) },
                                            onDestroy: { actions.destroy(task.id) }))
                }
            }
        }
        .dropDestination(for: String.self) { items, _ in
            // Backlog → In Progress: start it (a new agent in a worktree).
            var took = false
            for id in items.compactMap(UUID.init(uuidString:)) {
                guard let t = store.task(id), t.stage == .backlog || t.stage == .planning,
                      !t.title.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                actions.start(id)
                took = true
            }
            return took
        }
    }

    private var testingColumn: some View {
        let tasks = store.tasks(in: .testing)
        return KanbanColumn(title: NSLocalizedString("Review", comment: "kanban column"),
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
                    onOpen: { actions.openReview(task.id) },
                    onOpenSession: { task.delegationID != nil ? actions.openAssignee(task) : actions.jumpToRun(task) },
                    onMarkDone: { requestMarkDone(task) },
                    onRetry: actions.retryLanding.map { retry in { retry(task.id) } },
                    menu: testingMenu(task))
                    .draggable(task.id.uuidString)
                    .modifier(RemovableCard(title: task.title, stage: task.stage,
                                            onRemove: { actions.delete(task.id) },
                                            onDestroy: { confirmingDiscard = task }))
            }
        }
    }

    /// A Review card's menu: right-click, AXShowMenu and VoiceOver actions.
    private func testingMenu(_ task: CodingTask) -> [CardMenuItem] {
        let landable = task.landing == nil || task.landing?.phase == .needsYou
        var d: [CardMenuItem.Draft] = [
            .init(title: task.isNoCode ? NSLocalizedString("Read Report", comment: "task card")
                                       : NSLocalizedString("Review Changes", comment: "task card")) {
                actions.openReview(task.id)
            },
            .init(title: NSLocalizedString("Open Session", comment: "task card")) {
                task.delegationID != nil ? actions.openAssignee(task) : actions.jumpToRun(task)
            },
        ]
        if task.landing?.phase == .needsYou, let retry = actions.retryLanding {
            d.append(.init(title: NSLocalizedString("Retry Landing", comment: "task card")) {
                retry(task.id)
            })
        }
        if landable {
            d.append(.init(title: NSLocalizedString("Mark Done", comment: "review")) { requestMarkDone(task) })
        }
        if !task.isNoCode, landable {
            d.append(.init(title: String(format: NSLocalizedString("Merge into %@…", comment: "kanban menu"),
                                         task.landingTarget ?? NSLocalizedString("parent", comment: "kanban menu"))) {
                requestMerge(task)
            })
        }
        d.append(.init(title: NSLocalizedString("Back to In Progress", comment: "")) {
            actions.backToInProgress(task.id)
        })
        d.append(.divider)
        if task.branch != nil {
            d.append(.init(title: NSLocalizedString("Discard Branch…", comment: "review"),
                           role: .destructive) { confirmingDiscard = task })
        }
        d.append(.init(title: NSLocalizedString("Remove Task Only", comment: ""),
                       role: .destructive) { actions.delete(task.id) })
        return CardMenuItem.list(d)
    }

    /// A Done card's menu: the transcript, the pull request, the session
    /// while it's still alive, removal.
    private func doneMenu(_ task: CodingTask) -> [CardMenuItem] {
        var d: [CardMenuItem.Draft] = [
            .init(title: NSLocalizedString("Read Transcript", comment: "task card menu")) {
                actions.openTranscript(task.id)
            },
        ]
        if let status = liveStatus(of: task), status != .ended, status != .asleep {
            d.append(.init(title: NSLocalizedString("Open Session", comment: "task card")) {
                actions.jumpToRun(task)
            })
        }
        if let pr = task.pullRequestURL, let url = URL(string: pr) {
            d.append(.link(NSLocalizedString("Open Pull Request", comment: "review"), url))
        }
        d.append(.divider)
        d.append(.init(title: NSLocalizedString("Remove Task", comment: ""), role: .destructive) {
            actions.delete(task.id)
        })
        return CardMenuItem.list(d)
    }

    private var doneColumn: some View {
        let tasks = store.tasks(in: .done)
        return KanbanColumn(title: NSLocalizedString("Done", comment: "kanban column"),
                            systemImage: "checkmark.circle",
                            count: tasks.count,
                            tint: .green,
                            emptyText: NSLocalizedString("Nothing done yet", comment: "kanban"),
                            subtitle: NSLocalizedString("Landed or closed", comment: "kanban column: Done subtitle")) {
            ForEach(tasks) { task in
                DoneTaskCard(task: task,
                             accentHex: accentHex(for: task.profileID),
                             workspaceName: workspaceName(for: task.profileID),
                             onOpen: { actions.openTranscript(task.id) },
                             menu: doneMenu(task))
                    .modifier(RemovableCard(title: task.title, stage: task.stage) {
                        actions.delete(task.id)
                    })
            }
        }
        .dropDestination(for: String.self) { items, _ in
            // Review → Done: Mark Done (asks first when there's code).
            for id in items.compactMap(UUID.init(uuidString:)) {
                guard let t = store.task(id), t.stage == .testing else { continue }
                requestMarkDone(t)
                return true
            }
            return false
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
                    // Just outside the card's corner: inside it, it sat on
                    // the card's own top-right controls (Assign).
                    .offset(x: 7, y: -7)
                    .help(NSLocalizedString("Remove Task", comment: ""))
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
                           ? NSLocalizedString("Stop & Discard Branch",
                                               comment: "remove card")
                           : NSLocalizedString("Discard Branch",
                                               comment: "remove card"),
                           role: .destructive) {
                        onDestroy?()
                    }
                    Button(NSLocalizedString("Remove Task Only", comment: "remove card")) {
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
                        "Discarding ends the agent's session and deletes its branch and worktree, with any uncommitted or unmerged work. “Remove Task Only” leaves them in the workspace.",
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
    var workspaceName: String = ""
    let parentTitle: String?
    let dependsOnNumbers: [Int]
    let depsMet: Bool
    let isSelected: Bool
    let onToggleSelect: () -> Void
    let onEdit: () -> Void
    /// The card's menu (built by the column).
    var menu: [CardMenuItem] = []

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
                        if task.isStarting {
                            CardStatusPill(text: NSLocalizedString("Starting…", comment: "task card"),
                                           tint: .blue, spinning: true)
                        } else if task.queuedAt != nil {
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
        .modifier(CardAccessibility(
            label: [String(format: NSLocalizedString("Phase %d", comment: "plan card: accessibility"), number),
                    task.title,
                    workspaceName.isEmpty ? nil : workspaceName,
                    isSelected ? NSLocalizedString("Selected", comment: "plan card: accessibility") : nil,
                    task.isStarting ? NSLocalizedString("Starting…", comment: "task card")
                        : task.queuedAt != nil ? NSLocalizedString("queued", comment: "plan card") : nil,
                    task.lastError].compactMap { $0 }.joined(separator: ", "),
            hint: NSLocalizedString("Edit…", comment: ""),
            onPress: onEdit,
            menu: menu))
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

/// A card's error: two lines, full text on hover — and a click on it
/// unfolds the rest (a tooltip alone was easy to miss, and the card's own
/// click opens the editor, not the error).
private struct CardErrorLine: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9.5))
                Text(text)
                    .lineLimit(expanded ? nil : 2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(text)
        .accessibilityHint(expanded
            ? NSLocalizedString("Click to fold the error", comment: "task card")
            : NSLocalizedString("Click to read the whole error", comment: "task card"))
    }
}

/// A running/review card's header: the workspace chip, its date and the
/// card's pill on one line when they fit; else the date goes; else the pill
/// takes a row of its own — the chip is never squeezed to "…" (or
/// "QA-…rity") by the pill beside it.
struct CardHeader<Trailing: View>: View {
    let workspaceName: String
    let accentHex: String
    let task: CodingTask
    @ViewBuilder var trailing: Trailing

    private var chip: some View { WorkspaceChip(name: workspaceName, accentHex: accentHex) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                chip.fixedSize()
                TaskDateLabel(task: task).fixedSize()
                Spacer(minLength: 4)
                trailing.fixedSize()
            }
            HStack(spacing: 6) {
                chip.fixedSize()
                Spacer(minLength: 4)
                trailing.fixedSize()
            }
            VStack(alignment: .leading, spacing: 5) {
                chip
                HStack(spacing: 0) {
                    trailing.fixedSize()
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// A card header's date: shown whole when it fits next to the workspace
/// chip and the card's controls, dropped otherwise (the chip and the
/// controls matter more; the editor shows both dates).
struct CardDateSlot: View {
    let task: CodingTask

    var body: some View {
        ViewThatFits(in: .horizontal) {
            TaskDateLabel(task: task)
            Color.clear.frame(width: 0, height: 0)
        }
        .layoutPriority(-1)
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
                        .layoutPriority(1)
                    CardDateSlot(task: task)
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
                        // One line, always: squeezed, the label wrapped one
                        // syllable per line ("As/sig/n"). An assignee name
                        // may truncate, capped so the chip keeps its room.
                        .lineLimit(1)
                        .fixedSize(horizontal: task.assignment == nil, vertical: false)
                        .frame(maxWidth: task.assignment == nil ? nil : 120, alignment: .trailing)
                        .layoutPriority(2)
                        .help(task.assignment.map { a in
                            String(format: NSLocalizedString("Assigned to %@ — click to change", comment: "task card"), a.label)
                        } ?? NSLocalizedString("Who picks this task up", comment: "task card"))
                    }
                    if planningLive {
                        CardStatusPill(text: NSLocalizedString("Planning", comment: "task card"),
                                       tint: .blue, spinning: true)
                            .fixedSize()
                            .layoutPriority(3)
                            .help(NSLocalizedString(
                                "A visible planning session is running — click the task to open it; phases appear in the Plan column as it files them.",
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
                if task.isStarting {
                    // Checks run before the card moves (workspace up, folder
                    // there, a repository of its own): an In Progress card
                    // is a task that really started.
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        CardStatusPill(text: NSLocalizedString("Starting…", comment: "task card"),
                                       tint: .blue, spinning: true)
                            .help(NSLocalizedString(
                                "Checking the workspace and the folder — the task moves to In Progress once its agent can start.",
                                comment: "task card"))
                    }
                } else if let a = task.assignment, let pos = queuePosition, task.lastError == nil {
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
                        Button(NSLocalizedString("Plan First", comment: "task card")) { onPlan() }
                            .controlSize(.small)
                            .disabled(untitled || task.validationInFlight)
                            .help(NSLocalizedString(
                                "A planner agent reads the task and the repository, then files ordered phases (with dependencies) in the Plan column.",
                                comment: "task card"))
                        Button {
                            onStart()
                        } label: {
                            Label(NSLocalizedString("Start", comment: "task card"), systemImage: "play.fill")
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        // Not while it's being planned: that would run the
                        // whole task in parallel with its own planning.
                        .disabled(untitled || planningLive)
                        .help(NSLocalizedString(
                            "Straight to In Progress: a new agent does the whole task in a fresh worktree and hands you the diff in Review. To give it to a session or a room, use Assign.",
                            comment: "task card"))
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(CardChrome(borderTint: task.lastError != nil ? .red : .clear))
        .modifier(CardAccessibility(
            label: [untitled ? NSLocalizedString("Untitled task", comment: "task card") : task.title,
                    workspaceName.isEmpty ? nil : workspaceName,
                    planningLive ? NSLocalizedString("Planning", comment: "task card")
                        : task.isStarting ? NSLocalizedString("Starting…", comment: "task card")
                        : NSLocalizedString("In backlog", comment: "task card: accessibility state"),
                    task.lastError].compactMap { $0 }.joined(separator: ", "),
            hint: planningLive ? NSLocalizedString("Open Session", comment: "task card")
                               : NSLocalizedString("Edit…", comment: ""),
            onPress: { planningLive ? onOpenSession() : onEdit() },
            menu: menu))
    }

    /// Right-click, AXShowMenu and VoiceOver actions (see CardMenuItem).
    private var menu: [CardMenuItem] {
        var d: [CardMenuItem.Draft] = []
        if planningLive {
            d.append(.init(title: NSLocalizedString("Open Session", comment: "task card"), action: onOpenSession))
        }
        d.append(.init(title: NSLocalizedString("Edit…", comment: ""), action: onEdit))
        if !untitled && !planningLive {
            d.append(.init(title: NSLocalizedString("Start", comment: "task card"), action: onStart))
            if !task.validationInFlight {
                d.append(.init(title: NSLocalizedString("Plan First", comment: "task card"), action: onPlan))
            }
        }
        if let onAssign {
            d.append(.init(title: NSLocalizedString("Assign…", comment: "task card"), action: onAssign))
        }
        if task.assignment != nil, let onUnassign {
            d.append(.init(title: NSLocalizedString("Unassign", comment: "task card"), action: onUnassign))
        }
        d.append(.divider)
        d.append(.init(title: NSLocalizedString("Remove Task", comment: "task card"),
                       role: .destructive, action: onDelete))
        return CardMenuItem.list(d)
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
                Toggle(NSLocalizedString("Open a pull request at delivery (skips review)", comment: "assign sheet"),
                       isOn: Binding(get: { prWhenDone }, set: { prWhenDone = $0; TaskAssignment.finishWithPullRequest = $0 }))
                    .platformCheckboxToggle()
                    .font(.system(size: 11.5))
                    .help(NSLocalizedString("Off: the session or room hands its branch back for your review, and lands it once you approve. On: it pushes and opens a pull request before the task moves to Review.", comment: "assign sheet"))
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
    var workspaceName: String = ""
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
                    TaskDateLabel(task: task)
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
        .modifier(CardAccessibility(
            label: [task.title, workspaceName.isEmpty ? nil : workspaceName,
                    task.assignment?.label,
                    task.pendingQuestion != nil ? NSLocalizedString("Needs you", comment: "task card: accessibility state")
                        : NSLocalizedString("In progress", comment: "task card: accessibility state"),
                    task.pendingQuestion, task.lastError]
                .compactMap { $0 }.joined(separator: ", "),
            hint: NSLocalizedString("Show the session working on it", comment: "task card"),
            onPress: onOpen,
            menu: CardMenuItem.list(
                [.init(title: NSLocalizedString("Open Session", comment: "task card"), action: onOpen)]
                + (task.pendingQuestion != nil
                   ? [.init(title: NSLocalizedString("Answer…", comment: "task card"),
                            action: { answering = true })] : [])
                + [.divider,
                   .init(title: NSLocalizedString("Stop & Return to Backlog", comment: "task card"),
                         role: .destructive, action: onRecall)])))
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
    /// The task's session, as the sidebar shows it (`TaskLiveState`).
    let status: SessionBucket?
    /// Its agent couldn't start (`TaskLiveState.couldntStart`): the chip
    /// says so, in the words the sidebar row and the stage use.
    var couldntStart = false
    let onOpen: () -> Void
    var onResume: () -> Void = {}
    var onStartOver: () -> Void = {}
    var onMarkDone: () -> Void = {}
    /// The card's menu (built by the column: it knows every action).
    var menu: [CardMenuItem] = []
    @State private var hovering = false

    /// The sidebar row's and the stage's word for an agent that died at launch.
    static var couldntStartTitle: String { NSLocalizedString("Couldn't start", comment: "session status") }

    /// No live agent to open: its session is paused, or no tab turned up
    /// within the boot window.
    private func sessionLost(at now: Date) -> Bool {
        switch status {
        case .asleep, .ended: return true
        case nil:
            // A launch that failed (its reason on the card) isn't starting.
            if task.lastError != nil { return true }
            guard let started = task.startedAt else { return true }
            return now.timeIntervalSince(started) >= 300
        default: return false
        }
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                // TimelineView so the whole card re-evaluates on a timer:
                // the relative time ticks, and "starting…" ages into
                // "session gone" even when nothing else redraws the board.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    CardHeader(workspaceName: workspaceName, accentHex: accentHex, task: task) {
                        // The same words, tints and spinner as the session's
                        // sidebar row (SessionBucket).
                        if couldntStart {
                            CardStatusPill(text: Self.couldntStartTitle, tint: .red,
                                           systemImage: "exclamationmark.triangle.fill")
                                .layoutPriority(2)
                        } else if let status, status != .asleep, status != .ended {
                            CardStatusPill(text: status.title, tint: status.tint,
                                           spinning: status == .working,
                                           systemImage: status == .needsYou ? "hand.raised.fill" : nil)
                                .layoutPriority(2)
                                .help(status == .idle
                                      ? NSLocalizedString("The agent is waiting at its prompt without having handed the task over — open its session to see where it is.", comment: "task card")
                                      : "")
                        } else if status != nil {
                            CardStatusPill(text: SessionBucket.asleep.title, tint: .secondary,
                                           systemImage: "pause.fill")
                        } else if task.lastError != nil {
                            // The error line below says what went wrong —
                            // never "Starting…" beside it.
                            EmptyView()
                        } else if let started = task.startedAt,
                                  context.date.timeIntervalSince(started) < 300 {
                            // No tab yet: within the boot/attach window that's
                            // normal startup, not a lost session.
                            CardStatusPill(text: NSLocalizedString("Starting…", comment: "task card"),
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
                        if let err = task.lastError {
                            CardErrorLine(text: err)
                        }
                        HStack(spacing: 6) {
                        if task.restartNeeded == true {
                            // Nothing left to resume into: a fresh run.
                            Button {
                                onStartOver()
                            } label: {
                                Label(NSLocalizedString("Start Over", comment: "task card"),
                                      systemImage: "arrow.counterclockwise")
                                    .frame(maxWidth: .infinity)
                            }
                            .controlSize(.small)
                            .help(NSLocalizedString(
                                "Runs the task again from scratch on a new branch.",
                                comment: "task card"))
                        } else if sessionLost(at: context.date) {
                            // A lost session isn't a dead end: reboot the
                            // workspace and re-launch the agent on the
                            // existing worktree.
                            Button {
                                onResume()
                            } label: {
                                Label(NSLocalizedString("Restart Session", comment: ""),
                                      systemImage: "arrow.clockwise")
                                    .frame(maxWidth: .infinity)
                            }
                            .controlSize(.small)
                            .help(NSLocalizedString(
                                "The session is gone — boot the workspace if needed and relaunch the agent on this task's worktree.",
                                comment: "task card"))
                        } else {
                            HStack(spacing: 3) {
                                Text(NSLocalizedString("Open Session", comment: "task card"))
                                    .lineLimit(1)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 9, weight: .semibold))
                            }
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.tint)
                            Spacer(minLength: 0)
                        }
                        // In the card's action row, beside the action —
                        // never on top of a control.
                        if hovering { QuickDoneButton(action: onMarkDone) }
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(CardChrome(borderTint: status == .needsYou || task.lastError != nil ? .red : .blue))
        .onHover { hovering = $0 }
        .help(NSLocalizedString("Open the task's live session", comment: ""))
        .modifier(CardAccessibility(
            label: [task.title, workspaceName.isEmpty ? nil : workspaceName,
                    couldntStart ? Self.couldntStartTitle : status?.title
                        ?? (task.lastError == nil ? NSLocalizedString("Starting…", comment: "task card") : nil),
                    task.lastError].compactMap { $0 }.joined(separator: ", "),
            hint: NSLocalizedString("Open the task's live session", comment: ""),
            onPress: onOpen,
            menu: menu))
    }
}

/// One entry of a card's menu. The same list feeds the right-click menu,
/// AXShowMenu and VoiceOver's actions, so all three always agree.
struct CardMenuItem: Identifiable {
    enum Role { case normal, destructive, divider }
    let id: Int
    let title: String
    var role: Role = .normal
    var url: URL? = nil
    var action: () -> Void = {}

    /// Items with ids by position (stable while the menu reads the same).
    static func list(_ items: [CardMenuItem.Draft]) -> [CardMenuItem] {
        items.enumerated().map { i, d in
            CardMenuItem(id: i, title: d.title, role: d.role, url: d.url, action: d.action)
        }
    }

    /// An entry before it gets its position.
    struct Draft {
        let title: String
        var role: Role = .normal
        var url: URL? = nil
        var action: () -> Void = {}
        static var divider: Draft { Draft(title: "", role: .divider) }
        static func link(_ title: String, _ url: URL) -> Draft { Draft(title: title, url: url) }
    }
}

/// A card's right-click menu from its `CardMenuItem`s.
private struct CardMenuContent: View {
    let items: [CardMenuItem]
    var body: some View {
        ForEach(items) { item in
            switch item.role {
            case .divider: Divider()
            case .destructive:
                Button(item.title, role: .destructive, action: item.action)
            case .normal:
                if let url = item.url {
                    Link(item.title, destination: url)
                } else {
                    Button(item.title, action: item.action)
                }
            }
        }
    }
}

#if os(macOS)
/// Pops a card's menu for AXShowMenu (VoiceOver's "show menu"), at the
/// pointer — the same entries as its right-click menu.
@MainActor
private final class CardMenuPopper: NSObject {
    private let items: [CardMenuItem]
    private let openURL: (URL) -> Void
    init(items: [CardMenuItem], openURL: @escaping (URL) -> Void) {
        self.items = items
        self.openURL = openURL
    }

    /// At the pointer, or under `view` (an assistive client's "show menu"
    /// has no pointer to speak of).
    func popUp(in view: NSView? = nil) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            if item.role == .divider { menu.addItem(.separator()); continue }
            let m = NSMenuItem(title: item.title, action: #selector(run(_:)), keyEquivalent: "")
            m.target = self
            m.tag = item.id
            menu.addItem(m)
        }
        // Synchronous: the menu tracks until dismissed, `self` alive throughout.
        if let view {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.height : 0), in: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    @objc private func run(_ sender: NSMenuItem) {
        guard let item = items.first(where: { $0.id == sender.tag }) else { return }
        if let url = item.url { openURL(url) } else { item.action() }
    }
}

/// The card's accessibility element, in AppKit: a plain NSView that IS the
/// element — role button, its label as AXDescription, its hint as AXHelp,
/// AXPress to open the card, AXShowMenu for its menu, the menu's entries as
/// named actions. SwiftUI's own element for a card only ever exposed the
/// label as AXAttributedDescription (no AXDescription / AXTitle) to tools
/// reading plain attributes, whatever modifiers it was given. Laid over the
/// card, clicks pass through it (`hitTest` → nil): only assistive clients
/// see it.
final class CardAXView: NSView {
    // Set (not just overridden): stored, they answer the attribute API
    // (AXDescription, AXRole, AXHelp) as well as the NSAccessibility one.
    var label = "" { didSet { setAccessibilityLabel(label) } }
    var hint = "" { didSet { setAccessibilityHelp(hint.isEmpty ? nil : hint) } }
    var onPress: () -> Void = {}
    var menuItems: [CardMenuItem] = []
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityEnabled(true)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityPerformPress() -> Bool { onPress(); return true }
    override func accessibilityPerformShowMenu() -> Bool {
        guard !menuItems.isEmpty else { return false }
        CardMenuPopper(items: menuItems, openURL: openURL).popUp(in: self)
        return true
    }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        let items = menuItems.filter { $0.role != .divider }
        guard !items.isEmpty else { return nil }
        return items.map { item in
            NSAccessibilityCustomAction(name: item.title) { [weak self] in
                if let url = item.url { self?.openURL(url) } else { item.action() }
                return true
            }
        }
    }
}

struct CardAXElement: NSViewRepresentable {
    let label: String
    let hint: String
    let onPress: () -> Void
    let menu: [CardMenuItem]
    let openURL: (URL) -> Void

    func makeNSView(context: Context) -> CardAXView { update(CardAXView()) }
    func updateNSView(_ v: CardAXView, context: Context) { _ = update(v) }
    private func update(_ v: CardAXView) -> CardAXView {
        v.label = label
        v.hint = hint
        v.onPress = onPress
        v.menuItems = menu
        v.openURL = openURL
        return v
    }
}
#endif

extension View {
    /// Stand a plain text-titled button in for this control in the
    /// accessibility tree: an icon (or icon + label) button exposed its name
    /// only as AXAttributedDescription — AXTitle/AXDescription were empty
    /// for tools that read the plain attributes. The visual control is
    /// unchanged; modifiers after this (hint, value) apply to the stand-in.
    func plainAccessibilityButton(_ title: String, action: @escaping () -> Void) -> some View {
        accessibilityRepresentation { Button(title, action: action) }
    }
}

/// A board card as one accessible control: named by its title and state
/// (VoiceOver reads the label — a `.contain` container dropped it), pressed
/// (AXPress) to open it, its menu on AXShowMenu and as named actions —
/// which is also how its inner buttons stay reachable.
struct CardAccessibility: ViewModifier {
    let label: String
    let hint: String
    let onPress: () -> Void
    var menu: [CardMenuItem] = []
    @Environment(\.openURL) private var openURL

    private func run(_ item: CardMenuItem) {
        if let url = item.url { openURL(url) } else { item.action() }
    }

    /// The menu's actions in the order `accessibilityActions` needs to show
    /// them as the menu does (it lists them in reverse).
    static func actionOrder(_ menu: [CardMenuItem]) -> [CardMenuItem] {
        Array(menu.filter { $0.role != .divider }.reversed())
    }

    func body(content: Content) -> some View {
        #if os(macOS)
        // The card's visible pieces stay out of the tree; the AppKit
        // element laid over it is the card (`CardAXView`).
        content
            .contextMenu { CardMenuContent(items: menu) }
            .accessibilityHidden(true)
            .overlay(CardAXElement(label: label, hint: hint, onPress: onPress, menu: menu,
                                   openURL: { openURL($0) })
                        .allowsHitTesting(false))
        #else
        swiftUIElement(content)
        #endif
    }

    private func swiftUIElement(_ content: Content) -> some View {
        content
            .contextMenu { CardMenuContent(items: menu) }
            // One element for the whole card — a button named by `label`,
            // verbatim (never looked up as a localization key). No stand-in
            // representation: the substituted button carried its own
            // attributed text and the card's label reached assistive tools
            // only as AXAttributedDescription, with no plain description.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: label))
            .accessibilityHint(Text(verbatim: hint))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) { onPress() }
            .accessibilityActions {
                // Named actions come out last-first; fed reversed they list
                // in the context menu's order.
                ForEach(Self.actionOrder(menu)) { item in
                    Button(item.title) { run(item) }
                }
            }
            #if os(macOS)
            .accessibilityAction(.showMenu) {
                guard !menu.isEmpty else { return }
                CardMenuPopper(items: menu, openURL: { openURL($0) }).popUp()
            }
            #endif
    }
}

/// The hover ✓ on In Progress and Review cards: Mark Done.
private struct QuickDoneButton: View {
    let action: () -> Void
    var body: some View {
        // Icon only: a word here wrapped a letter or two per line beside
        // the card's own action at the narrowest column width.
        Button(action: action) {
            Image(systemName: "checkmark")
                .font(.system(size: 10.5, weight: .bold))
                .frame(width: 22, height: 20)
                .background(Circle().fill(Color.green.opacity(0.16)))
                .foregroundStyle(.green)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(NSLocalizedString("Mark Done", comment: "review"))
        .accessibilityLabel(NSLocalizedString("Mark Done", comment: "review"))
    }
}

private struct TestingTaskCard: View {
    let task: CodingTask
    let accentHex: String
    var workspaceName: String = ""
    let onOpen: () -> Void
    var onOpenSession: () -> Void = {}
    var onMarkDone: () -> Void = {}
    /// Retry a landing that needs the user (nil: not offered here).
    var onRetry: (() -> Void)? = nil
    /// The card's menu (built by the column).
    var menu: [CardMenuItem] = []
    @State private var hovering = false

    private var unsent: Int { task.comments.filter { $0.sentAt == nil }.count }
    private var needsYou: Bool { task.landing?.phase == .needsYou }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(workspaceName: workspaceName, accentHex: accentHex, task: task) {
                    if unsent > 0 {
                        CardStatusPill(text: TaskPlurals.comments(unsent),
                                       tint: .purple, systemImage: "text.bubble.fill")
                            .help(NSLocalizedString("Draft review comments", comment: ""))
                    }
                }
                Text(task.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let branch = task.branch, !task.isNoCode {
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
                stateLine
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(CardChrome(borderTint: needsYou ? .red : .purple))
        .onHover { hovering = $0 }
        .modifier(CardAccessibility(
            label: [task.title, workspaceName.isEmpty ? nil : workspaceName,
                    TaskLandingText.line(for: task)
                        ?? (task.isNoCode ? NSLocalizedString("No code changes", comment: "task card")
                                          : NSLocalizedString("Ready to land", comment: "task card")),
                    unsent > 0 ? TaskPlurals.comments(unsent) : nil,
                    task.lastError].compactMap { $0 }.joined(separator: ", "),
            hint: task.isNoCode ? NSLocalizedString("Read Report", comment: "task card")
                                : NSLocalizedString("Review Changes", comment: "task card"),
            onPress: onOpen,
            menu: menu))
    }

    /// The hover ✓, in the action row next to the card's own control —
    /// an overlay sat on top of the Review pill.
    @ViewBuilder private var quickDone: some View {
        if hovering, task.landing == nil || needsYou {
            QuickDoneButton(action: onMarkDone)
        }
    }

    /// "Review Changes" (or "Read Report") — the card's own action, never
    /// wrapped: the short form when the full one doesn't fit.
    private func reviewPill(short: Bool) -> some View {
        let title = task.isNoCode
            ? (short ? NSLocalizedString("Report", comment: "task card: short Read Report")
                     : NSLocalizedString("Read Report", comment: "task card"))
            : (short ? NSLocalizedString("Review", comment: "task card: short Review Changes")
                     : NSLocalizedString("Review Changes", comment: "task card"))
        return Label(title, systemImage: task.isNoCode ? "doc.text" : "eye")
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.purple))
    }

    @ViewBuilder private var stateLine: some View {
        if let l = task.landing, l.phase != .needsYou {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(TaskLandingText.line(for: task) ?? "")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let line = l.agentLine, !line.isEmpty {
                    Text(line)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .help(line)
                }
            }
        } else if needsYou {
            VStack(alignment: .leading, spacing: 6) {
                // The reason, two lines on the card, all of it on hover.
                let reason = TaskLandingText.line(for: task) ?? ""
                Text(reason)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(task.landing?.detail ?? reason)
                HStack(spacing: 6) {
                    if let onRetry {
                        Button(NSLocalizedString("Retry", comment: ""), action: onRetry)
                            .controlSize(.small)
                            .help(NSLocalizedString("Land it again with the same choices", comment: "task card"))
                    }
                    Button(NSLocalizedString("Open Session", comment: "task landing"), action: onOpenSession)
                        .controlSize(.small)
                    Spacer(minLength: 0)
                    quickDone
                }
            }
        } else if let err = task.lastError {
            HStack(alignment: .top, spacing: 6) {
                CardErrorLine(text: err)
                Spacer(minLength: 0)
                quickDone
            }
        } else {
            // The state on its own row, the actions below it: side by side
            // at the narrowest column they wrapped mid-word.
            VStack(alignment: .leading, spacing: 6) {
                Text(task.isNoCode ? NSLocalizedString("No code changes", comment: "task card")
                                   : NSLocalizedString("Ready to land", comment: "task card"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    ViewThatFits(in: .horizontal) {
                        reviewPill(short: false)
                        reviewPill(short: true)
                    }
                    Spacer(minLength: 0)
                    quickDone
                }
            }
        }
    }
}

private struct DoneTaskCard: View {
    let task: CodingTask
    let accentHex: String
    var workspaceName: String = ""
    var onOpen: () -> Void = {}
    /// The card's menu (built by the column).
    var menu: [CardMenuItem] = []

    private var outcomeGlyph: (name: String, tint: Color) {
        switch task.effectiveCompletion {
        case .merged?: return ("arrow.triangle.merge", .green)
        case .prOpened?: return ("arrow.triangle.pull", .blue)
        case .markedDone?: return ("checkmark.circle", .green)
        case .closedWithoutMerge?, nil: return ("xmark.circle", .secondary)
        }
    }

    private var closed: Bool {
        if case .closedWithoutMerge? = task.effectiveCompletion { return true }
        return false
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
                        .foregroundStyle(closed ? .secondary : .primary)
                        .help(task.title)
                    Text(TaskLandingText.done(task))
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
        .modifier(CardAccessibility(
            label: [task.title, workspaceName.isEmpty ? nil : workspaceName,
                    TaskLandingText.done(task)].compactMap { $0 }.joined(separator: ", "),
            hint: NSLocalizedString("Read Transcript", comment: "task card menu"),
            onPress: onOpen,
            menu: menu))
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
                if !isNew {
                    TaskDateLabel(task: task, full: true)
                }
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

            if let err = task.lastError, !isNew {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(err).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.red)
            }

            optionsRow

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
            } label: { Label(NSLocalizedString("Unassigned — I'll start it", comment: "task editor"), systemImage: "tray") }
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
                      task.assignment.map { String(format: NSLocalizedString("Assigned to %@", comment: "task card"), $0.label) }
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
        .accessibilityLabel(String(format: NSLocalizedString("Workspace: %@", comment: "task editor chip"),
                                   selectedProfile?.name ?? ""))
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
        .accessibilityLabel(String(format: NSLocalizedString("Agent: %@", comment: "task editor chip"),
                                   task.tool.displayName))
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
        .accessibilityLabel(String(format: NSLocalizedString("Folder: %@", comment: "task editor chip"),
                                   task.repoPath.isEmpty ? "~" : task.repoPath))
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
                    .accessibilityLabel(NSLocalizedString("Folder", comment: "task editor"))
                Text(NSLocalizedString("Clone this repository first (optional)", comment: "task editor"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField("", text: Binding(
                    get: { task.cloneURL ?? "" },
                    set: { task.cloneURL = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }),
                          prompt: Text(verbatim: "https://github.com/org/repo.git"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .accessibilityLabel(NSLocalizedString("Clone this repository first (optional)", comment: "task editor"))
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

    /// The folder's "create it" switch (the start error points at it) and
    /// how the task leaves review once approved.
    private var optionsRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { optionsList }
            VStack(alignment: .leading, spacing: 8) { optionsList }
        }
        .font(.system(size: 11.5))
    }

    @ViewBuilder private var optionsList: some View {
        if decidedByAssignee == nil {
            Toggle(NSLocalizedString("Create folder & git repo if needed", comment: "task editor"),
                   isOn: Binding(get: { task.initRepo ?? false },
                                 set: { task.initRepo = $0 ? true : nil }))
                .platformCheckboxToggle()
                .help(NSLocalizedString("Make the folder and an empty git repository when they don't exist yet — tasks run on their own branch.", comment: "task editor"))
        }
        Picker(NSLocalizedString("When a task is approved", comment: "task finish preference"), selection: Binding(
            get: { task.finish },
            set: { task.finish = $0 })) {
            Text(String(format: NSLocalizedString("Workspace default (%@)", comment: "task editor"),
                        (selectedProfile?.taskFinish ?? TaskFinish.appDefault).label))
                .tag(TaskFinish?.none)
            ForEach(TaskFinish.allCases, id: \.self) { f in
                Text(f.label).tag(TaskFinish?.some(f))
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help(NSLocalizedString("What happens when you approve the task in Review: merged into the branch it came from, or opened as a pull request.", comment: "task editor"))
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
                .help(NSLocalizedString("Remove Task", comment: "task card"))
            }
            Text(task.assignment.map { a -> String in
                a.kind == .worktree
                    ? NSLocalizedString("A new agent picks it up from the queue and takes it to Review.", comment: "task editor")
                    : String(format: NSLocalizedString("%@ picks it up on its own and takes it to Review.", comment: "task editor"), a.label)
            } ?? NSLocalizedString("Start it from the board, or Plan First to split it into phases.", comment: "task editor"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if task.stage == .backlog && task.assignment == nil {
                Button {
                    onPlan(Self.titled(task))
                } label: {
                    Label(NSLocalizedString("Plan First", comment: "task editor"), systemImage: "list.number")
                }
                .disabled(!canSave)
                .help(NSLocalizedString(
                    "Saves, then opens a visible planning session: the agent explores the repo (ask it things — it can see you) and files ordered phases with dependencies into the Plan column.",
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


/// When a task was created, and last changed: a compact relative date on
/// cards ("Updated 5 min ago"), both dates in the tooltip; written out in
/// the task's details (`full`).
struct TaskDateLabel: View {
    let task: CodingTask
    var full = false

    private var modified: Date? {
        task.updatedAt.flatMap { $0.timeIntervalSince(task.createdAt) > 1 ? $0 : nil }
    }

    var body: some View {
        Text(text)
            .font(.system(size: full ? 11 : 10))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .fixedSize()
            .help(tooltip)
    }

    private var text: String {
        if full {
            let created = String(format: NSLocalizedString("Created %@", comment: "task date"),
                                 task.createdAt.formatted(date: .abbreviated, time: .shortened))
            guard let m = modified else { return created }
            return created + "  ·  " + String(format: NSLocalizedString("Modified %@", comment: "task date"),
                                              m.formatted(date: .abbreviated, time: .shortened))
        }
        let rel = { (d: Date) in d.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)) }
        if let m = modified {
            return String(format: NSLocalizedString("Updated %@", comment: "task date"), rel(m))
        }
        return String(format: NSLocalizedString("Created %@", comment: "task date"), rel(task.createdAt))
    }

    private var tooltip: String {
        var lines = [String(format: NSLocalizedString("Created %@", comment: "task date"),
                            task.createdAt.formatted(date: .long, time: .shortened))]
        if let m = modified {
            lines.append(String(format: NSLocalizedString("Modified %@", comment: "task date"),
                                m.formatted(date: .long, time: .shortened)))
        }
        return lines.joined(separator: "\n")
    }
}

/// What a new task starts from: the workspace the last one was written for,
/// and the folder last used in that workspace ("~" is rarely a repository).
enum TaskDraftDefaults {
    private static let workspaceKey = "codingTasks.lastWorkspace"
    private static let foldersKey = "codingTasks.lastFolders"

    static var lastWorkspace: UUID? {
        UserDefaults.standard.string(forKey: workspaceKey).flatMap(UUID.init(uuidString:))
    }

    static func lastFolder(for workspace: UUID) -> String? {
        let map = UserDefaults.standard.dictionary(forKey: foldersKey) as? [String: String]
        return map?[workspace.uuidString]
    }

    static func remember(_ t: CodingTask) {
        UserDefaults.standard.set(t.profileID.uuidString, forKey: workspaceKey)
        let folder = t.repoPath.trimmingCharacters(in: .whitespaces)
        guard !folder.isEmpty, folder != "~" else { return }
        var map = (UserDefaults.standard.dictionary(forKey: foldersKey) as? [String: String]) ?? [:]
        map[t.profileID.uuidString] = folder
        UserDefaults.standard.set(map, forKey: foldersKey)
    }
}
