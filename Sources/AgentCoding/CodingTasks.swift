import Foundation
import Observation

// MARK: - Model

/// One coding task on the coding kanban: Backlog → In Progress → Testing →
/// Done. A started task is an agent run in a fresh git worktree (the same
/// guest path automations use); Testing shows the branch's diff for review;
/// review feedback goes back to the agent on the same branch; Done merges
/// the branch into its parent.
struct CodingTask: Codable, Identifiable, Equatable, Sendable {
    enum Stage: String, Codable, CaseIterable, Sendable {
        case backlog, inProgress, testing, done
    }

    var id: UUID
    var title: String
    /// Markdown task description — the agent's brief, written in the
    /// backlog editor and rendered on the card.
    var details: String
    /// Workspace the task runs in.
    var profileID: UUID
    /// Guest path of the repo to worktree off ("~" conventions as
    /// automations; must be a git repo for the branch flow to work).
    var repoPath: String
    var tool: Profile.Tool
    var stage: Stage

    /// The branch slug requested at start ("fix-login-260718-1502"); the
    /// guest may uniquify with "-N".
    var branchSlug: String?
    /// The ACTUAL worktree branch ("wt/<slug>[-N]"), captured from the tab
    /// when the agent reports done — merge and diff key off this.
    var branch: String?
    /// Worktree checkout dir in the guest, captured with `branch`.
    var worktreeDir: String?
    /// The branch this task's worktree was cut from — the merge target.
    var parentBranch: String?
    /// The main checkout's path — where merges run.
    var rootRepo: String?

    /// Review feedback. Comments accumulate across review rounds;
    /// `sentAt` marks the round that carried them back to the agent.
    var comments: [ReviewComment]

    var createdAt: Date
    var startedAt: Date?
    /// When the agent last reported done (entered Testing).
    var testingAt: Date?
    var completedAt: Date?
    /// Done via merge (true) or closed without merging (false).
    var merged: Bool
    /// Done via "Create Pull Request" — the branch left for review on the
    /// forge instead of merging locally.
    var prOpened: Bool?
    /// The plan-validation agent's markdown review (questions, assumptions,
    /// risks) — produced in the backlog editor BEFORE the task starts, so
    /// the clarifying questions get asked while a human is still in the loop.
    var validation: String?
    var validatedAt: Date?
    /// When a validation round was requested — drives the editor's spinner
    /// (a request newer than the last result = one in flight).
    var validationRequestedAt: Date?
    /// Why the last start attempt failed, shown on the backlog card.
    var lastError: String?

    init(id: UUID = UUID(), title: String = "", details: String = "",
         profileID: UUID, repoPath: String = "~", tool: Profile.Tool = .claude,
         stage: Stage = .backlog, branchSlug: String? = nil,
         branch: String? = nil, worktreeDir: String? = nil,
         parentBranch: String? = nil, rootRepo: String? = nil,
         comments: [ReviewComment] = [], createdAt: Date = Date(),
         startedAt: Date? = nil, testingAt: Date? = nil,
         completedAt: Date? = nil, merged: Bool = false,
         prOpened: Bool? = nil, validation: String? = nil,
         validatedAt: Date? = nil, validationRequestedAt: Date? = nil,
         lastError: String? = nil) {
        self.id = id
        self.title = title
        self.details = details
        self.profileID = profileID
        self.repoPath = repoPath
        self.tool = tool
        self.stage = stage
        self.branchSlug = branchSlug
        self.branch = branch
        self.worktreeDir = worktreeDir
        self.parentBranch = parentBranch
        self.rootRepo = rootRepo
        self.comments = comments
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.testingAt = testingAt
        self.completedAt = completedAt
        self.merged = merged
        self.prOpened = prOpened
        self.validation = validation
        self.validatedAt = validatedAt
        self.validationRequestedAt = validationRequestedAt
        self.lastError = lastError
    }

    /// A validation round is running: requested, with no result since.
    /// Bounded so a host crash mid-round can't pin the editor's spinner.
    var validationInFlight: Bool {
        guard let requested = validationRequestedAt else { return false }
        if let done = validatedAt, done >= requested { return false }
        return Date().timeIntervalSince(requested) < 300
    }
}

/// One piece of review feedback on a task's changes. `file` scopes a
/// comment to one changed file (nil = about the change as a whole).
struct ReviewComment: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var text: String
    var file: String?
    var createdAt: Date
    /// Set when a "send back to In Progress" round delivered this comment
    /// to the agent.
    var sentAt: Date?

    init(id: UUID = UUID(), text: String, file: String? = nil,
         createdAt: Date = Date(), sentAt: Date? = nil) {
        self.id = id
        self.text = text
        self.file = file
        self.createdAt = createdAt
        self.sentAt = sentAt
    }
}

// MARK: - Store

/// Persistence for the coding board: one JSON blob at
/// ~/Library/Application Support/BromureAC/tasks.json, same conventions as
/// the automation store (iso8601, atomic writes, backup-excluded).
@MainActor
@Observable
final class CodingTaskStore {
    private(set) var tasks: [CodingTask] = []

    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!
            self.fileURL = appSupport
                .appendingPathComponent("BromureAC", isDirectory: true)
                .appendingPathComponent("tasks.json")
        }
        load()
    }

    func task(_ id: UUID) -> CodingTask? {
        tasks.first { $0.id == id }
    }

    func upsert(_ task: CodingTask) {
        if let i = tasks.firstIndex(where: { $0.id == task.id }) {
            tasks[i] = task
        } else {
            tasks.insert(task, at: 0)
        }
        save()
    }

    func remove(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        save()
    }

    /// In-place update + save; no-op when the task is gone.
    func mutate(_ id: UUID, _ change: (inout CodingTask) -> Void) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[i])
        save()
    }

    /// Fat-client mirror: replace the whole task list from a remote
    /// snapshot, in memory only (no save — a mirror store is a read model
    /// of another machine's state). No-op when nothing changed.
    func mirror(tasks newTasks: [CodingTask]) {
        if tasks != newTasks { tasks = newTasks }
    }

    func tasks(in stage: CodingTask.Stage) -> [CodingTask] {
        tasks.filter { $0.stage == stage }
    }

    // MARK: Persistence

    private struct FilePayload: Codable { var tasks: [CodingTask] }

    private func load() {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? d.decode(FilePayload.self, from: data)
        else { return }
        tasks = payload.tasks
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(FilePayload(tasks: tasks)) else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }
}

// MARK: - Engine

/// Drives the coding board's transitions that touch the guest: starting a
/// task (agent in a fresh worktree), catching the agent's done signal
/// (→ Testing), sending review feedback back (→ In Progress), and merging
/// (→ Done). UI-only moves (backlog edits, dismiss) go straight through
/// the store.
@MainActor
final class CodingTaskEngine {
    private weak var delegate: ACAppDelegate?
    let store: CodingTaskStore

    /// Workspaces this engine asked to boot and is still waiting on.
    private var pendingBoots: Set<UUID> = []

    private static let bootTimeout: TimeInterval = 180
    private static let bootPollInterval: UInt64 = 5_000_000_000  // 5s

    init(store: CodingTaskStore, delegate: ACAppDelegate?) {
        self.store = store
        self.delegate = delegate
    }

    /// Operating constraints appended to every task prompt. Unlike
    /// automations, a human IS reachable (the red dot + live terminal), but
    /// the flow is designed to run hands-off until review — and the review
    /// diff/merge only work if the agent actually commits to its branch.
    nonisolated static let taskDirectives = """
    ---
    Operating notes for this task (added automatically): You are working in \
    a dedicated git worktree on your own branch. Work autonomously — make \
    reasonable decisions on your own rather than waiting for confirmation. \
    When the task is complete, COMMIT all of your work to this branch with \
    clear commit messages: do not leave uncommitted changes, do not merge \
    into any other branch, and do not push. If review feedback arrives \
    later in this session, address it and commit again.
    """

    nonisolated static func prompt(for task: CodingTask) -> String {
        var out = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = task.details.trimmingCharacters(in: .whitespacesAndNewlines)
        if !details.isEmpty { out += "\n\n" + details }
        return out + "\n\n" + taskDirectives
    }

    /// The follow-up prompt for a review round: the unsent comments,
    /// verbatim, under a short preamble.
    nonisolated static func feedbackPrompt(comments: [ReviewComment]) -> String {
        var out = "Review feedback on your changes on this branch — address "
        out += "each point, then commit the updates:\n"
        for c in comments {
            if let file = c.file, !file.isEmpty {
                out += "\n- [\(file)] \(c.text)"
            } else {
                out += "\n- \(c.text)"
            }
        }
        return out + "\n\n" + taskDirectives
    }

    // MARK: Plan validation (backlog editor)

    /// The reviewer prompt: read-only, questions-first, bounded. The brief
    /// is spliced in verbatim; the user answers by editing the brief and
    /// re-validating.
    nonisolated static func validationPrompt(for task: CodingTask) -> String {
        var brief = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = task.details.trimmingCharacters(in: .whitespacesAndNewlines)
        if !details.isEmpty { brief += "\n\n" + details }
        return """
        You are reviewing a task brief BEFORE another agent implements it in \
        this repository (the current directory). Do NOT implement anything \
        and do NOT modify any files — explore the code read-only as needed, \
        then reply in markdown with exactly these sections:

        ## Questions
        Clarifying questions whose answers would change how the task is \
        done — the things an implementer would otherwise have to guess. \
        Number them. If the brief leaves nothing worth asking, write "None".

        ## Assumptions
        The defaults you would pick if the questions go unanswered.

        ## Risks
        Anything in the brief that conflicts with the codebase as it \
        actually is (missing files, different naming, already-done work).

        Keep the whole reply under 300 words. The brief:

        ---
        \(brief)
        """
    }

    /// Run a validation round: boot the workspace if needed, run the
    /// reviewer agent headless (`claude -p`) in the task's repo, and store
    /// its reply on the task. Async and fire-and-forget from the caller's
    /// perspective — the editor (and the fat-client mirror) watch the store.
    func validate(_ taskID: UUID) {
        guard let task = store.task(taskID), !task.validationInFlight else { return }
        store.mutate(taskID) { $0.validationRequestedAt = Date() }
        let prompt = Self.validationPrompt(for: task)
        let guestPath = ScheduledAutomationEngine.guestPath(task.repoPath)
        Task { [weak self] in
            guard let self, let delegate = self.delegate else { return }
            let result = await self.runValidation(
                delegate: delegate, profileID: task.profileID,
                guestPath: guestPath, prompt: prompt)
            self.store.mutate(taskID) {
                $0.validation = result
                $0.validatedAt = Date()
            }
        }
    }

    private func runValidation(delegate: ACAppDelegate, profileID: UUID,
                               guestPath: String, prompt: String) async -> String {
        // Make sure the workspace is up (same boot courtesy as start()).
        if (try? await delegate.guestExec(profileID: profileID,
                                          command: "true", timeout: 5)) == nil {
            if !pendingBoots.contains(profileID) {
                pendingBoots.insert(profileID)
                delegate.startProfileForAutomation(profileID)
            }
            let deadline = Date().addingTimeInterval(Self.bootTimeout)
            var up = false
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: Self.bootPollInterval)
                if (try? await delegate.guestExec(profileID: profileID,
                                                  command: "true", timeout: 5)) != nil {
                    up = true; break
                }
            }
            pendingBoots.remove(profileID)
            guard up else {
                return NSLocalizedString(
                    "⚠️ The workspace did not boot in time — try again.",
                    comment: "plan validation")
            }
        }
        // Headless reviewer. `bash -lc` so the login env (agent proxy,
        // PATH) applies, exactly like a terminal tab; prompt travels base64
        // so arbitrary markdown survives the shell.
        let b64 = Data(prompt.utf8).base64EncodedString()
        let q = "'" + guestPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let cmd = "bash -lc 'cd \(q) 2>/dev/null || cd ~; "
            + "claude -p --dangerously-skip-permissions "
            + "\"$(echo \(b64) | base64 -d)\" 2>&1 | head -c 20000'"
        do {
            let out = try await delegate.guestExec(profileID: profileID,
                                                   command: cmd, timeout: 240)
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? NSLocalizedString("⚠️ The reviewer returned nothing — try again.",
                                    comment: "plan validation")
                : trimmed
        } catch {
            return String(format: NSLocalizedString(
                "⚠️ Validation failed: %@", comment: "plan validation"),
                error.localizedDescription)
        }
    }

    // MARK: Start (Backlog → In Progress)

    /// Launch the task: agent in a fresh worktree of the task's repo, on a
    /// running workspace (booted first when it isn't). Same outbox path and
    /// yolo mode as automation fires.
    func start(_ taskID: UUID) {
        guard let task = store.task(taskID), task.stage == .backlog,
              let delegate else { return }
        guard delegate.profile(for: task.profileID) != nil else {
            store.mutate(taskID) { $0.lastError = NSLocalizedString(
                "The workspace no longer exists", comment: "task start") }
            return
        }
        let slug = ScheduledAutomationEngine.branchSlug(for: task.title, at: Date())
        let args = [ScheduledAutomationEngine.guestPath(task.repoPath), slug,
                    task.title, task.tool.rawValue, Self.prompt(for: task)]

        func markStarted() {
            store.mutate(taskID) {
                $0.stage = .inProgress
                $0.branchSlug = slug
                $0.startedAt = Date()
                $0.lastError = nil
            }
        }

        if delegate.automationWorktreeCommand(
            profileNameOrID: task.profileID.uuidString, action: "run", args: args) {
            BACDebug.log("tasks", "started “\(task.title)” → \(slug)")
            markStarted()
            return
        }

        // Workspace off/suspended: boot it, then queue the run.
        BACDebug.log("tasks", "“\(task.title)”: workspace not running — starting")
        if !pendingBoots.contains(task.profileID) {
            pendingBoots.insert(task.profileID)
            delegate.startProfileForAutomation(task.profileID)
        }
        let deadline = Date().addingTimeInterval(Self.bootTimeout)
        let profileID = task.profileID
        Task { [weak self] in
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: Self.bootPollInterval)
                guard let self, let delegate = self.delegate else { return }
                if delegate.automationWorktreeCommand(
                    profileNameOrID: profileID.uuidString, action: "run", args: args) {
                    self.pendingBoots.remove(profileID)
                    BACDebug.log("tasks", "started “\(task.title)” → \(slug) (after boot)")
                    self.markStartedOnMain(taskID, slug: slug)
                    return
                }
            }
            guard let self else { return }
            self.pendingBoots.remove(profileID)
            self.store.mutate(taskID) { $0.lastError = NSLocalizedString(
                "The workspace did not boot in time", comment: "task start") }
        }
    }

    private func markStartedOnMain(_ taskID: UUID, slug: String) {
        store.mutate(taskID) {
            $0.stage = .inProgress
            $0.branchSlug = slug
            $0.startedAt = Date()
            $0.lastError = nil
        }
    }

    // MARK: Done signal (In Progress → Testing)

    /// Delegate callback alongside the automation engine's: a Claude tab
    /// flipped to .done. If its branch belongs to an in-progress task, the
    /// task moves to Testing and the worktree metadata (actual branch,
    /// checkout dir, parent, main root) is captured off the tab — the
    /// review window and the merge run on these.
    func agentFinished(profileID: UUID, worktreeBranch: String?) {
        guard let branch = worktreeBranch, branch.hasPrefix("wt/") else { return }
        let slugPart = String(branch.dropFirst(3))
        guard let task = store.tasks.first(where: { t in
            guard t.stage == .inProgress, t.profileID == profileID,
                  let slug = t.branchSlug else { return false }
            return slugPart == slug || (slugPart.hasPrefix(slug + "-")
                && Int(slugPart.dropFirst(slug.count + 1)) != nil)
        }) else { return }
        let tab = delegate?.pane(for: profileID)?.model.tabs
            .first { $0.worktreeBranch == branch }
        BACDebug.log("tasks", "“\(task.title)” agent done → testing (\(branch))")
        store.mutate(task.id) {
            $0.stage = .testing
            $0.testingAt = Date()
            $0.branch = branch
            if let tab {
                $0.worktreeDir = tab.repoRoot?.isEmpty == false ? tab.repoRoot : tab.cwd
                $0.parentBranch = tab.parentBranch
                $0.rootRepo = tab.rootRepo
            }
        }
    }

    // MARK: Review round (Testing → In Progress)

    /// Send the unsent review comments back to the agent and return the
    /// task to In Progress. A live tab gets the feedback typed into its
    /// session (the agent is still sitting there); a dead one gets a fresh
    /// agent tab reopened on the same worktree (guest `task-resume`).
    func sendBack(_ taskID: UUID) async {
        guard let task = store.task(taskID), task.stage == .testing,
              let branch = task.branch, let delegate else { return }
        let unsent = task.comments.filter { $0.sentAt == nil }
        guard !unsent.isEmpty else { return }
        let feedback = Self.feedbackPrompt(comments: unsent)

        let liveTab = delegate.pane(for: task.profileID)?.model.tabs
            .first { $0.worktreeBranch == branch }
        var delivered = false
        if let tab = liveTab {
            // Type into the live session: base64 through the guest shell so
            // arbitrary feedback text survives quoting, then Enter.
            let b64 = Data(feedback.utf8).base64EncodedString()
            let cmd = "echo \(b64) | base64 -d | xargs -0 tmux send-keys "
                + "-t bromure:\(tab.index) -l && sleep 1 && "
                + "tmux send-keys -t bromure:\(tab.index) Enter"
            delivered = (try? await delegate.guestExec(
                profileID: task.profileID, command: cmd, timeout: 20)) != nil
        }
        if !delivered {
            delivered = delegate.automationWorktreeCommand(
                profileNameOrID: task.profileID.uuidString, action: "task-resume",
                args: [task.rootRepo ?? "", branch, task.parentBranch ?? "",
                       task.title, task.tool.rawValue, feedback])
        }
        guard delivered else {
            store.mutate(taskID) { $0.lastError = NSLocalizedString(
                "Couldn't reach the workspace — is it running?", comment: "task review") }
            return
        }
        let now = Date()
        store.mutate(taskID) {
            $0.stage = .inProgress
            $0.lastError = nil
            for i in $0.comments.indices where $0.comments[i].sentAt == nil {
                $0.comments[i].sentAt = now
            }
        }
        BACDebug.log("tasks", "“\(task.title)”: \(unsent.count) comment(s) sent back")
    }

    // MARK: Merge (Testing → Done)

    /// Merge the task's branch into its parent — or `target`, when the
    /// review picked another branch — and mark the task Done. The guest
    /// opens the usual merge tab (squash flavor on request); conflicts
    /// spawn the resolver flow.
    func merge(_ taskID: UUID, into targetOverride: String? = nil,
               squash: Bool = false) {
        guard let task = store.task(taskID), task.stage == .testing,
              let branch = task.branch,
              let target = targetOverride ?? task.parentBranch,
              let root = task.rootRepo, let delegate else { return }
        let ok = delegate.automationWorktreeCommand(
            profileNameOrID: task.profileID.uuidString, action: "merge",
            args: [branch, target, root,
                   String(format: NSLocalizedString("Merge → %@", comment: "merge tab"),
                          target),
                   task.tool.rawValue, squash ? "squash" : "merge"])
        guard ok else {
            store.mutate(taskID) { $0.lastError = NSLocalizedString(
                "Couldn't reach the workspace — is it running?", comment: "task merge") }
            return
        }
        BACDebug.log("tasks",
                     "“\(task.title)”: \(squash ? "squash-" : "")merging \(branch) → \(target)")
        store.mutate(taskID) {
            $0.stage = .done
            $0.completedAt = Date()
            $0.merged = true
            $0.lastError = nil
        }
    }

    /// "Create Pull Request": the existing worktree-pr flow — an agent tab
    /// that reviews, pushes, and `gh pr create`s the branch. The task closes
    /// as "PR opened"; the merge happens on the forge.
    func openPR(_ taskID: UUID) {
        guard let task = store.task(taskID), task.stage == .testing,
              let branch = task.branch, let parent = task.parentBranch,
              let root = task.rootRepo, let delegate else { return }
        let ok = delegate.automationWorktreeCommand(
            profileNameOrID: task.profileID.uuidString, action: "pr",
            args: [branch, parent, root,
                   String(format: NSLocalizedString("PR: %@", comment: "pr tab"),
                          task.title),
                   task.tool.rawValue])
        guard ok else {
            store.mutate(taskID) { $0.lastError = NSLocalizedString(
                "Couldn't reach the workspace — is it running?", comment: "task pr") }
            return
        }
        BACDebug.log("tasks", "“\(task.title)”: opening PR for \(branch)")
        store.mutate(taskID) {
            $0.stage = .done
            $0.completedAt = Date()
            $0.merged = false
            $0.prOpened = true
            $0.lastError = nil
        }
    }

    /// Close a task without merging (abandoned, or merged by hand).
    func closeWithoutMerge(_ taskID: UUID) {
        store.mutate(taskID) {
            $0.stage = .done
            $0.completedAt = Date()
            $0.merged = false
        }
    }

    /// Manual Testing → In Progress with no feedback (the user just wants
    /// the agent tab back in play), and manual In Progress → Testing for
    /// non-Claude agents that never signal done.
    func moveToInProgress(_ taskID: UUID) {
        store.mutate(taskID) { if $0.stage == .testing { $0.stage = .inProgress } }
    }

    func moveToTesting(_ taskID: UUID) {
        guard let task = store.task(taskID), task.stage == .inProgress else { return }
        agentFinished(profileID: task.profileID,
                      worktreeBranch: liveBranch(of: task))
        // No live tab to derive metadata from → still move, without it.
        if store.task(taskID)?.stage == .inProgress {
            store.mutate(taskID) { $0.stage = .testing; $0.testingAt = Date() }
        }
    }

    /// The actual wt/ branch of the task's live tab, if any.
    func liveBranch(of task: CodingTask) -> String? {
        guard let slug = task.branchSlug,
              let tabs = delegate?.pane(for: task.profileID)?.model.tabs else { return nil }
        return tabs.first {
            AutomationBoard.branchMatches($0.worktreeBranch, slug: slug)
        }?.worktreeBranch
    }
}

// MARK: - Diff parsing (review window)

/// One changed file in a task's review diff.
struct TaskDiffFile: Identifiable, Equatable, Sendable {
    enum LineKind: Equatable, Sendable { case context, added, removed, hunk }
    struct Line: Identifiable, Equatable, Sendable {
        let id: Int
        var kind: LineKind
        var text: String
    }
    var id: String { path }
    var path: String
    var lines: [Line]
    var added: Int { lines.filter { $0.kind == .added }.count }
    var removed: Int { lines.filter { $0.kind == .removed }.count }
}

/// Tolerant unified-diff reader for `git diff` output.
enum TaskDiffParser {
    static func parse(_ raw: String) -> [TaskDiffFile] {
        var files: [TaskDiffFile] = []
        var current: TaskDiffFile?
        var lineID = 0
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                if let f = current { files.append(f) }
                // "diff --git a/path b/path" — take the b/ side (handles
                // renames and new files).
                let parts = line.split(separator: " ")
                let path = parts.last.map {
                    $0.hasPrefix("b/") ? String($0.dropFirst(2)) : String($0)
                } ?? String(line)
                current = TaskDiffFile(path: path, lines: [])
                continue
            }
            guard current != nil else { continue }
            // File-header noise between the diff line and the first hunk.
            if line.hasPrefix("index ") || line.hasPrefix("--- ")
                || line.hasPrefix("+++ ") || line.hasPrefix("new file")
                || line.hasPrefix("deleted file") || line.hasPrefix("similarity")
                || line.hasPrefix("rename ") || line.hasPrefix("Binary files")
                || line.hasPrefix("old mode") || line.hasPrefix("new mode") {
                continue
            }
            lineID += 1
            let kind: TaskDiffFile.LineKind
            if line.hasPrefix("@@") { kind = .hunk }
            else if line.hasPrefix("+") { kind = .added }
            else if line.hasPrefix("-") { kind = .removed }
            else { kind = .context }
            current?.lines.append(.init(id: lineID, kind: kind, text: String(line)))
        }
        if let f = current { files.append(f) }
        return files
    }
}
