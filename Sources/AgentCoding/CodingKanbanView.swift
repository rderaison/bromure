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

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 7) {
            ForEach(blocks) { block in
                switch block {
                case .heading(let level, let s):
                    inline(s)
                        .font(.system(size: level == 1 ? 15 : (level == 2 ? 13.5 : 12.5),
                                      weight: .bold))
                        .padding(.top, compact ? 0 : 2)
                case .bullet(let items):
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•").font(.system(size: 12))
                                inline(item)
                                    .font(.system(size: 12))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                case .code(let lines):
                    Text(lines.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(Color.primary.opacity(0.05)))
                case .paragraph(let s):
                    inline(s)
                        .font(.system(size: 12))
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
        let running = store.tasks(in: .inProgress).count
        let review = store.tasks(in: .testing).count
        let backlog = store.tasks(in: .backlog).count
        var parts: [String] = []
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

    /// Red when any running task's agent needs the user.
    private var needsAttention: Bool {
        store.tasks(in: .inProgress).contains { task in
            guard let slug = task.branchSlug,
                  let entry = model.entries.first(where: { $0.id == task.profileID })
            else { return false }
            return entry.model.tabs.contains {
                AutomationBoard.branchMatches($0.worktreeBranch, slug: slug)
                    && $0.agentStatus == .needsInput
            }
        }
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
                Button(action: onShowBoard) {
                    Image(systemName: "rectangle.split.3x1")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(model.taskBoardSelected
                                         ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("Coding board", comment: ""))
            }
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .padding(.top, 14)
            .padding(.bottom, 4)

            Button(action: onShowBoard) {
                HStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .font(.system(size: 11))
                        .foregroundStyle(needsAttention ? .red : .secondary)
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
    }

    var store: CodingTaskStore
    @Bindable var model: SessionListModel
    /// Fresh profile snapshot for the editor sheet's pickers.
    let profilesProvider: () -> [Profile]
    let actions: Actions

    /// The editor sheet's subject: an existing task or a fresh draft.
    @State private var editing: CodingTask?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 14) {
                backlogColumn
                inProgressColumn
                testingColumn
                doneColumn
            }
            .padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $editing) { task in
            TaskEditorSheet(
                store: store,
                task: task,
                profiles: profilesProvider(),
                isNew: store.task(task.id) == nil,
                onSave: { saved in actions.save(saved); editing = nil },
                onValidate: { draft in actions.validate(draft) },
                onDelete: { id in actions.delete(id); editing = nil },
                onCancel: { editing = nil })
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.tint)
            Text(NSLocalizedString("Coding Tasks", comment: "coding kanban title"))
                .font(.system(size: 16, weight: .bold))
            Spacer()
            Button {
                let profiles = profilesProvider()
                editing = CodingTask(profileID: profiles.first?.id ?? UUID(),
                                     tool: profiles.first?.tool ?? .claude)
            } label: {
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
        let tasks = store.tasks(in: .backlog)
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
                    onEdit: { editing = task },
                    onStart: { actions.start(task.id) },
                    onDelete: { actions.delete(task.id) })
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
                    onOpen: { actions.jumpToRun(task) })
                    .contextMenu {
                        Button(NSLocalizedString("Move to Testing", comment: "")) {
                            actions.moveToTesting(task.id)
                        }
                        Button(NSLocalizedString("Close Without Merging", comment: "")) {
                            actions.closeNoMerge(task.id)
                        }
                    }
            }
        }
    }

    private var testingColumn: some View {
        let tasks = store.tasks(in: .testing)
        return KanbanColumn(title: NSLocalizedString("Testing", comment: "kanban column"),
                            systemImage: "eye",
                            count: tasks.count,
                            tint: .purple,
                            emptyText: NSLocalizedString("Nothing to review", comment: "kanban")) {
            ForEach(tasks) { task in
                TestingTaskCard(
                    task: task,
                    accentHex: accentHex(for: task.profileID),
                    onOpen: { actions.openReview(task.id) })
                    .contextMenu {
                        Button(NSLocalizedString("Merge into \(task.parentBranch ?? "parent")…",
                                                 comment: "")) {
                            actions.merge(task.id)
                        }
                        Button(NSLocalizedString("Back to In Progress", comment: "")) {
                            actions.backToInProgress(task.id)
                        }
                        Button(NSLocalizedString("Close Without Merging", comment: "")) {
                            actions.closeNoMerge(task.id)
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
                             accentHex: accentHex(for: task.profileID))
                    .contextMenu {
                        Button(NSLocalizedString("Delete", comment: ""), role: .destructive) {
                            actions.delete(task.id)
                        }
                    }
            }
        }
    }
}

// MARK: - Cards

private struct BacklogTaskCard: View {
    let task: CodingTask
    let accentHex: String
    let workspaceName: String
    let onEdit: () -> Void
    let onStart: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onEdit) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(Color(hex: accentHex)).frame(width: 8, height: 8)
                    Text(task.title.isEmpty
                         ? NSLocalizedString("Untitled task", comment: "") : task.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    if task.validationInFlight {
                        ProgressView().controlSize(.mini)
                            .help(NSLocalizedString("Agent reviewing the plan…", comment: ""))
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
                    Button(NSLocalizedString("Start", comment: "task card")) { onStart() }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .disabled(task.title.trimmingCharacters(in: .whitespaces).isEmpty)
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
                HStack(spacing: 4) {
                    if let started = task.startedAt {
                        Text(String(format: NSLocalizedString("started %@", comment: ""),
                                    started.formatted(.relative(presentation: .named))))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    if status == .needsInput {
                        Text(NSLocalizedString("Needs your input", comment: ""))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.red)
                    } else if status == nil {
                        Text(NSLocalizedString("session gone", comment: "task card"))
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
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
                Text(NSLocalizedString("Ready for review — click to see the diff",
                                       comment: "task card"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
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
        .modifier(CardChrome())
    }
}

// MARK: - Backlog editor sheet

/// The task brief editor: a large markdown text editor with a live preview
/// toggle — backlog items are supposed to be written with care, they become
/// the agent's prompt verbatim.
private struct TaskEditorSheet: View {
    var store: CodingTaskStore
    @State var task: CodingTask
    let profiles: [Profile]
    let isNew: Bool
    let onSave: (CodingTask) -> Void
    let onValidate: (CodingTask) -> Void
    let onDelete: (UUID) -> Void
    let onCancel: () -> Void

    @State private var preview = false
    @State private var validationExpanded = true

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

    /// The stored task, for validation state — the validate flow persists
    /// the draft first, so results land in the store (and mirror to fat
    /// clients) while this sheet stays open.
    private var stored: CodingTask? { store.task(task.id) }
    private var validationInFlight: Bool { stored?.validationInFlight ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew
                 ? NSLocalizedString("New Task", comment: "task editor")
                 : NSLocalizedString("Edit Task", comment: "task editor"))
                .font(.system(size: 15, weight: .bold))

            TextField(NSLocalizedString("Task title", comment: ""), text: $task.title)
                .font(.system(size: 14, weight: .semibold))
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                Picker(NSLocalizedString("Workspace", comment: ""),
                       selection: $task.profileID) {
                    ForEach(profiles) { Text($0.name).tag($0.id) }
                }
                .frame(maxWidth: 230)
                .onChange(of: task.profileID) {
                    if !toolChoices.contains(where: { $0.tool == task.tool }),
                       let primary = selectedProfile?.tool {
                        task.tool = primary
                    }
                }
                Picker(NSLocalizedString("Agent", comment: ""), selection: $task.tool) {
                    ForEach(toolChoices) { spec in
                        Text(spec.tool.displayName).tag(spec.tool)
                    }
                }
                .frame(maxWidth: 180)
                TextField(NSLocalizedString("Repository path", comment: ""),
                          text: $task.repoPath, prompt: Text(verbatim: "~/my-repo"))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }

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
            .frame(minHeight: 280, maxHeight: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.primary.opacity(0.12)))

            if let result = stored?.validation, !validationInFlight {
                validationSection(result)
            }

            Text(NSLocalizedString(
                "Starting the task launches the agent in a fresh worktree of the repository with this brief as its prompt. It works on its own branch and commits its changes; you review the diff in Testing, then merge.",
                comment: "task editor"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                if !isNew {
                    Button(NSLocalizedString("Delete", comment: ""), role: .destructive) {
                        onDelete(task.id)
                    }
                }
                Button {
                    onValidate(task)
                } label: {
                    if validationInFlight {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.small)
                            Text(NSLocalizedString("Reviewing…", comment: "task editor"))
                        }
                    } else {
                        Label(NSLocalizedString("Validate Plan with Agent",
                                                comment: "task editor"),
                              systemImage: "person.fill.questionmark")
                    }
                }
                .disabled(!canSave || validationInFlight)
                .help(NSLocalizedString(
                    "Saves the draft, then a read-only agent reviews the brief against the repository and asks its questions here — before anything runs. Boots the workspace if needed.",
                    comment: "task editor"))
                Spacer()
                Button(NSLocalizedString("Cancel", comment: ""), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(NSLocalizedString("Save", comment: "")) { onSave(task) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(18)
        .frame(minWidth: 680, minHeight: 560)
    }

    /// The reviewer's questions/assumptions/risks, rendered under the
    /// editor. Answer by refining the brief above and re-validating.
    private func validationSection(_ result: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { validationExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: validationExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                    Label(NSLocalizedString("Agent plan review", comment: "task editor"),
                          systemImage: "person.fill.questionmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.purple)
                    if let at = stored?.validatedAt {
                        Text(at.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if validationExpanded {
                ScrollView {
                    MarkdownBlocks(text: result)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 180)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(Color.purple.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.purple.opacity(0.25)))
                Text(NSLocalizedString(
                    "Answer by refining the description above, then validate again.",
                    comment: "task editor"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
