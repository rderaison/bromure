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
        case backlog, planning, inProgress, testing, done
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
    /// The implementation plan the agent recorded via board_set_plan —
    /// shown in the review window above the diff.
    var plan: String?
    /// Set when this card was filed by an agent as a subtask of another
    /// task (board_create_subtasks / the Plan decomposition).
    var parentTaskID: UUID?
    /// Phases that must reach Done before this one may start. A start
    /// attempt with unmet dependencies queues instead (see `queuedAt`).
    var dependsOn: [UUID]?
    /// Set when the user started this phase while its dependencies were
    /// unmet — it auto-starts the moment they all reach Done.
    var queuedAt: Date?
    /// Set while a merge is running in the guest. The card stays in Testing
    /// ("Merging…") until the engine VERIFIES the branch landed in the
    /// target — only then does it go Done and unblock dependent phases.
    var mergingAt: Date?
    /// Create `repoPath` (mkdir -p + git init + empty root commit) before
    /// launching, when it isn't already its own repository. Off by default:
    /// a monorepo subdirectory must NOT get a nested repo by surprise.
    var initRepo: Bool?

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
         lastError: String? = nil, plan: String? = nil,
         parentTaskID: UUID? = nil, dependsOn: [UUID]? = nil,
         queuedAt: Date? = nil, initRepo: Bool? = nil) {
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
        self.plan = plan
        self.parentTaskID = parentTaskID
        self.dependsOn = dependsOn
        self.queuedAt = queuedAt
        self.initRepo = initRepo
    }

    /// Dependencies not yet Done, looked up in `all`. Deleted dependencies
    /// count as satisfied — a removed phase must never wedge the queue.
    func unmetDependencies(in all: [CodingTask]) -> [UUID] {
        (dependsOn ?? []).filter { depID in
            guard let dep = all.first(where: { $0.id == depID }) else { return false }
            return dep.stage != .done
        }
    }

    /// A validation round is running: requested, with no result since.
    /// Bounded so a host crash mid-round can't pin the editor's spinner.
    var validationInFlight: Bool {
        guard let requested = validationRequestedAt else { return false }
        if let done = validatedAt, done >= requested { return false }
        return Date().timeIntervalSince(requested) < 3600
    }
}

/// One piece of review feedback on a task's changes. `file` scopes a
/// comment to one changed file (nil = about the change as a whole).
struct ReviewComment: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var text: String
    var file: String?
    /// New-file line number the comment anchors to (margin annotations).
    var line: Int?
    var createdAt: Date
    /// Set when a "send back to In Progress" round delivered this comment
    /// to the agent.
    var sentAt: Date?

    init(id: UUID = UUID(), text: String, file: String? = nil,
         line: Int? = nil, createdAt: Date = Date(), sentAt: Date? = nil) {
        self.id = id
        self.text = text
        self.file = file
        self.line = line
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

    /// Backlog items that still belong on the board: a brief whose
    /// planning has filed phases is superseded by its cards in the Plan
    /// column and disappears from Backlog (it stays in the store as the
    /// phases' parent — title chip, plan overview). If every phase is
    /// later deleted, the brief resurfaces.
    func backlogTasks() -> [CodingTask] {
        tasks.filter { t in
            t.stage == .backlog
                && !(t.validatedAt != nil
                     && tasks.contains { $0.parentTaskID == t.id })
        }
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
    Do ALL of the work in THIS session yourself: do NOT spawn subagents or \
    background tasks (the Task/Agent tools) — the board tracks only this \
    session, and ending your turn while delegated work runs marks the task \
    done prematurely. \
    When the task is complete, COMMIT all of your work to this branch with \
    clear commit messages: do not leave uncommitted changes, do not merge \
    into any other branch, and do not push. Then, as your VERY LAST action, \
    run this command to hand the task to review: \
    `sh ~/.bromure/agent-status.sh done` \
    If review feedback arrives later in this session, address it, commit \
    again, and finish with that same command.
    """

    /// The Plan session prompt: a VISIBLE session (the user can watch and
    /// answer) whose only job is planning — it files the phases itself via
    /// the board MCP, so they appear on the board as it works.
    /// Recognize the planner meta-prompt in a session transcript and
    /// return just the user's brief. The window renders the brief — the
    /// tool directives are plumbing, not conversation, and showing them
    /// first makes the session open on a wall of internal instructions.
    nonisolated static func planBrief(fromPrompt text: String) -> String? {
        guard text.hasPrefix("You are PLANNING this task") else { return nil }
        guard let r = text.range(of: "The task brief:\n\n---\n") else { return nil }
        return String(text[r.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func plannerPrompt(for task: CodingTask) -> String {
        var brief = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = task.details.trimmingCharacters(in: .whitespacesAndNewlines)
        if !details.isEmpty { brief += "\n\n" + details }
        return """
        You are PLANNING this task, not implementing it. The user can see \
        this session — narrate what you're doing, and ask them questions \
        if the brief leaves real choices open (they may answer here). \
        Explore the repository read-only, then:
        1. File the implementation phases with the board_create_subtasks \
        tool: ordered, each roughly one reviewable pull request of work, \
        with dependsOn set (1-based phase numbers, counting every phase \
        you've filed for this task so far) for phases that need earlier \
        ones DONE first. dependsOn metadata is the ONLY thing that \
        sequences phases — a dependency mentioned in a phase's brief text \
        is NOT enforced, and a phase without dependsOn starts in parallel \
        with everything else. The tool result echoes the recorded \
        dependency graph: check it, and fix any omission with \
        board_set_dependencies. The phases appear on the user's board as \
        cards.
        2. Record a short overview of the plan with board_set_plan.
        Do NOT write any code, do NOT modify or commit anything. Explore in \
        THIS session directly — do NOT spawn subagents or background tasks \
        (the Task/Agent tools): the board tracks only this session, and \
        ending your turn while delegated work runs aborts the planning. \
        When the phases are filed, summarize them here and run this command \
        to end the planning session: `sh ~/.bromure/agent-status.sh done`

        The task brief:

        ---
        \(brief)
        """
    }

    /// Appended to every task prompt: the board tools task sessions carry
    /// (wired via --mcp-config by the guest agent).
    nonisolated static let mcpDirectives = """
    This session has the bromure-board MCP tools: board_get_task (your \
    card: brief, plan, review comments), board_set_plan (record the plan \
    on the card), board_create_subtasks (file out-of-scope follow-up work \
    as ordered cards in the Plan column, with dependencies), and \
    board_ready_for_review (hand this task to review — prefer it over the \
    shell command when available).
    """

    nonisolated static func prompt(for task: CodingTask) -> String {
        var out = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = task.details.trimmingCharacters(in: .whitespacesAndNewlines)
        if !details.isEmpty { out += "\n\n" + details }
        return out + "\n\n" + taskDirectives + "\n" + mcpDirectives
    }

    /// The follow-up prompt for a review round: the unsent comments,
    /// verbatim, under a short preamble.
    nonisolated static func feedbackPrompt(comments: [ReviewComment]) -> String {
        var out = "Review feedback on your changes on this branch — address "
        out += "each point, then commit the updates:\n"
        for c in comments {
            if let file = c.file, !file.isEmpty {
                let at = c.line.map { "\(file), line \($0)" } ?? file
                out += "\n- In \(at): \(c.text)"
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

        Be terse: short bullet points, no preamble, no praise, never restate \
        the brief, write "None" for an empty section, hard cap 120 words \
        total. The brief:

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
        // Headless reviewer. `bash -ilc` — INTERACTIVE login shell — because
        // the generated .bashrc that exports the agent's auth env (the
        // subscription stand-in key the MITM proxy swaps, base URLs, PATH)
        // guards on interactivity; a plain `bash -lc` skips it and claude
        // reports "Not logged in". The tab auto-launch hooks in that same
        // .bashrc gate on `-t 1` (a real tty), which an exec'd shell lacks,
        // so nothing auto-starts. Prompt travels base64 so arbitrary
        // markdown survives the shell.
        let b64 = Data(prompt.utf8).base64EncodedString()
        let q = "'" + guestPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let cmd = "bash -ilc 'cd \(q) 2>/dev/null || cd ~; "
            + "claude -p --dangerously-skip-permissions "
            + "\"$(echo \(b64) | base64 -d)\" 2>&1 | head -c 20000'"
        do {
            let out = try await delegate.guestExec(profileID: profileID,
                                                   command: cmd, timeout: 240)
            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return NSLocalizedString("⚠️ The reviewer returned nothing — try again.",
                                         comment: "plan validation")
            }
            // Auth failures come back as Claude's terse CLI errors — turn
            // them into the action the user can actually take.
            if trimmed.contains("Not logged in") || trimmed.contains("/login") {
                return trimmed + "\n\n" + NSLocalizedString(
                    "⚠️ This workspace's Claude isn't signed in (subscription mode signs in interactively, inside the VM). Open a terminal tab in the workspace, run `claude`, complete `/login` once — the login persists in the workspace — then validate again.",
                    comment: "plan validation")
            }
            if trimmed.contains("401") && trimmed.lowercased().contains("expired") {
                return trimmed + "\n\n" + NSLocalizedString(
                    "⚠️ The workspace's Claude credentials have expired. Re-authenticate once in a terminal tab of this workspace, then validate again.",
                    comment: "plan validation")
            }
            return trimmed
        } catch {
            return String(format: NSLocalizedString(
                "⚠️ Validation failed: %@", comment: "plan validation"),
                error.localizedDescription)
        }
    }

    // MARK: Start (Backlog → In Progress)

    /// Launch the task: agent in a fresh worktree of the task's repo, on a
    /// running workspace (booted first when it isn't). Same outbox path and
    /// yolo mode as automation fires. The repo gets a host-side trust
    /// pre-seed first — a belt to the guest agentd's `_pretrust` suspenders,
    /// because a workspace resumed from suspend still runs the agentd it
    /// booted with and may predate that fix.
    /// Launch a task or plan phase: agent in a fresh worktree, fully
    /// autonomous. Dependencies gate the launch — starting a phase whose
    /// dependencies aren't Done QUEUES it instead (it auto-starts when
    /// they land). The card moves to In Progress immediately ("One shot"
    /// must feel instant); a failed launch moves it back with the reason.
    func start(_ taskID: UUID) {
        guard let task = store.task(taskID),
              task.stage == .backlog || task.stage == .planning,
              let delegate else { return }
        guard delegate.profile(for: task.profileID) != nil else {
            store.mutate(taskID) { $0.lastError = NSLocalizedString(
                "The workspace no longer exists", comment: "task start") }
            return
        }
        // Unmet dependencies: queue, don't launch. pumpQueue() fires the
        // start again when the last dependency reaches Done.
        let unmet = task.unmetDependencies(in: store.tasks)
        guard unmet.isEmpty else {
            BACDebug.log("tasks", "“\(task.title)”: queued behind \(unmet.count) dependenc\(unmet.count == 1 ? "y" : "ies")")
            store.mutate(taskID) { $0.queuedAt = Date(); $0.lastError = nil }
            return
        }
        let priorStage = task.stage
        let slug = ScheduledAutomationEngine.branchSlug(for: task.title, at: Date())
        let guestPath = ScheduledAutomationEngine.guestPath(task.repoPath)
        let args = [guestPath, slug, task.title, task.tool.rawValue,
                    Self.prompt(for: task), "task"]
        let profileID = task.profileID
        let title = task.title
        let isClaude = task.tool == .claude

        // Optimistic: the card is In Progress from the click; the async
        // half reverts it with a reason if the launch can't happen.
        store.mutate(taskID) {
            $0.stage = .inProgress
            $0.branchSlug = slug
            $0.startedAt = Date()
            $0.queuedAt = nil
            $0.lastError = nil
        }
        func revert(_ reason: String) {
            store.mutate(taskID) {
                $0.stage = priorStage
                $0.branchSlug = nil
                $0.startedAt = nil
                $0.lastError = reason
            }
        }

        Task { [weak self] in
            guard let self, let delegate = self.delegate else { return }
            // Make sure the workspace is reachable (boot when it isn't).
            var up = (try? await delegate.guestExec(profileID: profileID,
                                                    command: "true", timeout: 5)) != nil
            if !up {
                BACDebug.log("tasks", "“\(title)”: workspace not running — starting")
                if !self.pendingBoots.contains(profileID) {
                    self.pendingBoots.insert(profileID)
                    delegate.startProfileForAutomation(profileID)
                }
                let deadline = Date().addingTimeInterval(Self.bootTimeout)
                while Date() < deadline {
                    try? await Task.sleep(nanoseconds: Self.bootPollInterval)
                    if (try? await delegate.guestExec(profileID: profileID,
                                                      command: "true", timeout: 5)) != nil {
                        up = true; break
                    }
                }
                self.pendingBoots.remove(profileID)
            }
            guard up else {
                revert(NSLocalizedString("The workspace did not boot in time",
                                         comment: "task start"))
                return
            }
            // The board's whole lifecycle — done-signal matching, diff
            // review, merge — rides the task's worktree BRANCH. A non-repo
            // start path silently falls back to a plain agent tab with no
            // branch, and the card can never leave In Progress. Refuse it
            // with the reason instead.
            let q = "'" + guestPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
            if task.initRepo == true {
                _ = try? await delegate.guestExec(
                    profileID: profileID,
                    command: Self.initRepoCommand(quotedPath: q), timeout: 15)
            }
            guard await self.usableRepo(profileID: profileID, quotedPath: q) else {
                revert(String(format: NSLocalizedString(
                    "“%@” isn't a git repository of its own — tasks run on their own branch. Pick a repo folder, or edit the task and enable “Create folder & git repo”.",
                    comment: "task start"), task.repoPath))
                return
            }
            if isClaude {
                await delegate.pretrustGuestPath(profileID: profileID, dir: guestPath)
            }
            guard delegate.automationWorktreeCommand(
                profileNameOrID: profileID.uuidString, action: "run", args: args) else {
                revert(NSLocalizedString("Couldn't reach the workspace — is it running?",
                                         comment: "task start"))
                return
            }
            BACDebug.log("tasks", "started “\(title)” → \(slug)")
        }
    }

    // MARK: Plan (Backlog → phases in the Plan column)

    /// Launch the PLANNING SESSION for a backlog brief: a visible agent
    /// tab (worktree) whose only job is to file the phases via the board
    /// MCP. The parent stays in Backlog with the in-flight spinner; its
    /// branchSlug binds the MCP connection and lets the card jump to the
    /// live session. The spinner clears when the phases land (the MCP
    /// stamps validatedAt) or after the bounded window.
    func plan(_ taskID: UUID) {
        guard let task = store.task(taskID), task.stage == .backlog,
              !task.validationInFlight, let delegate else { return }
        guard delegate.profile(for: task.profileID) != nil else {
            store.mutate(taskID) { $0.lastError = NSLocalizedString(
                "The workspace no longer exists", comment: "task plan") }
            return
        }
        let slug = ScheduledAutomationEngine.branchSlug(
            for: "plan " + task.title, at: Date())
        let guestPath = ScheduledAutomationEngine.guestPath(task.repoPath)
        let args = [guestPath, slug,
                    String(format: NSLocalizedString("Plan: %@", comment: "plan tab"),
                           task.title),
                    task.tool.rawValue, Self.plannerPrompt(for: task), "plan"]
        let profileID = task.profileID
        let isClaude = task.tool == .claude
        store.mutate(taskID) {
            $0.branchSlug = slug
            $0.validationRequestedAt = Date()
            $0.lastError = nil
        }
        func revert(_ reason: String) {
            store.mutate(taskID) {
                $0.branchSlug = nil
                $0.validationRequestedAt = nil
                $0.lastError = reason
            }
        }
        Task { [weak self] in
            guard let self, let delegate = self.delegate else { return }
            var up = (try? await delegate.guestExec(profileID: profileID,
                                                    command: "true", timeout: 5)) != nil
            if !up {
                if !self.pendingBoots.contains(profileID) {
                    self.pendingBoots.insert(profileID)
                    // Headless: the plan window is the surface for this
                    // session — raising the terminal would bury it.
                    delegate.startProfileForAutomation(profileID, detached: true)
                }
                let deadline = Date().addingTimeInterval(Self.bootTimeout)
                while Date() < deadline {
                    try? await Task.sleep(nanoseconds: Self.bootPollInterval)
                    if (try? await delegate.guestExec(profileID: profileID,
                                                      command: "true", timeout: 5)) != nil {
                        up = true; break
                    }
                }
                self.pendingBoots.remove(profileID)
            }
            guard up else {
                revert(NSLocalizedString("The workspace did not boot in time",
                                         comment: "task plan"))
                return
            }
            // Planning happens IN the configured directory (no worktree —
            // the interview writes no code and must see the tree exactly
            // as the user left it). The directory just has to exist.
            let q = "'" + guestPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
            if task.initRepo == true {
                _ = try? await delegate.guestExec(
                    profileID: profileID,
                    command: Self.initRepoCommand(quotedPath: q), timeout: 15)
            }
            let dirExists = (try? await delegate.guestExec(
                profileID: profileID, command: "test -d \(q)", timeout: 10)) != nil
            guard dirExists else {
                revert(String(format: NSLocalizedString(
                    "“%@” doesn't exist in the workspace — pick an existing folder, or edit the task and enable “Create folder & git repo”.",
                    comment: "task plan"), task.repoPath))
                return
            }
            if isClaude {
                await delegate.pretrustGuestPath(profileID: profileID, dir: guestPath)
            }
            guard delegate.automationWorktreeCommand(
                profileNameOrID: profileID.uuidString, action: "run", args: args) else {
                revert(NSLocalizedString("Couldn't reach the workspace — is it running?",
                                         comment: "task plan"))
                return
            }
            BACDebug.log("tasks", "planning session for “\(task.title)” → \(slug)")
            self.watchPlanning(taskID, slug: slug, profileID: profileID)
        }
    }

    /// Tear a task down completely: kill its agent tab, delete its
    /// worktree and branch in the guest, and remove the card. The
    /// destructive sibling of a plain card removal — offered when the
    /// user removes a card that still has a session or checkout behind it.
    func destroy(_ taskID: UUID) {
        guard let task = store.task(taskID) else { return }
        let profileID = task.profileID
        let branch = task.branch ?? liveBranch(of: task)
        if let branch {
            let root = task.rootRepo
                ?? delegate?.pane(for: profileID)?.model.tabs
                    .first { $0.worktreeBranch == branch }?.rootRepo
            closeSessionTab(profileID: profileID, branch: branch, afterSeconds: 0)
            if let root, !root.isEmpty {
                // Give the tab kill a beat, then drop the checkout.
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    _ = self?.delegate?.automationWorktreeCommand(
                        profileNameOrID: profileID.uuidString,
                        action: "remove", args: [root, branch])
                }
            }
            BACDebug.log("tasks", "“\(task.title)” destroyed (\(branch))")
        }
        store.remove(taskID)
        pumpQueue()
    }

    /// Auto-start queued phases whose dependencies just reached Done.
    /// Called from every Done transition (merge, close, PR) and deletes.
    func pumpQueue() {
        for t in store.tasks
        where t.stage == .planning && t.queuedAt != nil
            && t.unmetDependencies(in: store.tasks).isEmpty {
            BACDebug.log("tasks", "“\(t.title)”: dependencies met — auto-starting")
            start(t.id)
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
        func matches(_ t: CodingTask) -> Bool {
            guard t.profileID == profileID, let slug = t.branchSlug else { return false }
            return slugPart == slug || (slugPart.hasPrefix(slug + "-")
                && Int(slugPart.dropFirst(slug.count + 1)) != nil)
        }
        if let task = store.tasks.first(where: {
            ($0.stage == .inProgress || $0.stage == .planning) && matches($0)
        }) {
            guard !settling.contains(task.id) else { return }
            settling.insert(task.id)
            // Finalize only after the session is quiet — a Stop-hook done
            // with background subagents still running isn't done.
            Task { [weak self] in
                await self?.delegate?.waitForSessionQuiet(profileID: profileID,
                                                          branch: branch)
                guard let self else { return }
                self.settling.remove(task.id)
                await self.finalizeTaskDone(task.id, profileID: profileID,
                                            branch: branch)
            }
            return
        }
        // A planning session signaling done: the parent card sits in
        // Backlog. Close the interview tab; if the agent quit WITHOUT
        // filing phases, say so on the card.
        if let parent = store.tasks.first(where: {
            $0.stage == .backlog && $0.validationRequestedAt != nil && matches($0)
        }) {
            guard !settling.contains(parent.id) else { return }
            settling.insert(parent.id)
            Task { [weak self] in
                // Subagents the planner spawned may still be exploring — or
                // about to file phases through the MCP. Settle first, judge
                // "ended before filing" after.
                await self?.delegate?.waitForSessionQuiet(profileID: profileID,
                                                          branch: branch)
                guard let self else { return }
                self.settling.remove(parent.id)
                BACDebug.log("tasks", "planning session done for “\(parent.title)”")
                self.closeSessionTab(profileID: profileID, branch: branch,
                                     afterSeconds: 10)
                guard let p = self.store.task(parent.id) else { return }
                if p.validationInFlight {
                    self.abortPlanning(parent.id, reason: NSLocalizedString(
                        "The planning session ended before filing phases — click Plan to retry.",
                        comment: "plan watchdog"))
                } else {
                    self.planWatchdogs[parent.id]?.cancel()
                    self.planWatchdogs[parent.id] = nil
                }
            }
        }
    }

    /// The actual done transition: worktree metadata off the tab (or the
    /// guest, for a DETACHED session — no window means no pane roster, and
    /// a card without worktreeDir/parentBranch can never show its review
    /// diff), stage → Testing, session tab closed. Idempotent via the
    /// stage guard.
    private func finalizeTaskDone(_ taskID: UUID, profileID: UUID,
                                  branch: String) async {
        guard let task = store.task(taskID),
              task.stage == .inProgress || task.stage == .planning else { return }
        let tab = delegate?.pane(for: profileID)?.model.tabs
            .first { $0.worktreeBranch == branch }
        var dir = tab?.repoRoot?.isEmpty == false ? tab?.repoRoot : tab?.cwd
        var parent = tab?.parentBranch
        var root = tab?.rootRepo
        if dir == nil || parent == nil || root == nil {
            let m = await resolveWorktreeMetadata(profileID: profileID,
                                                  branch: branch,
                                                  repoPath: task.repoPath)
            dir = dir ?? m.dir
            parent = parent ?? m.parent
            root = root ?? m.root
        }
        BACDebug.log("tasks", "“\(task.title)” agent done → testing (\(branch))")
        store.mutate(taskID) {
            $0.stage = .testing
            $0.testingAt = Date()
            $0.branch = branch
            if let dir { $0.worktreeDir = dir }
            if let parent { $0.parentBranch = parent }
            if let root { $0.rootRepo = root }
        }
        // The agent is done; a finished session left open is just an idle
        // claude eating a tab. Review send-back reopens the worktree via
        // task-resume when needed.
        closeSessionTab(profileID: profileID, branch: branch)
    }

    /// Tab-independent worktree metadata: the checkout dir from
    /// `git worktree list` in the task's repo, the parent branch from the
    /// guest agent's worktree registry (falling back to the repo's current
    /// branch — worktrees are cut from HEAD).
    func resolveWorktreeMetadata(profileID: UUID, branch: String,
                                 repoPath: String) async
        -> (dir: String?, parent: String?, root: String?) {
            guard let delegate, Self.isSafeBranch(branch) else {
                return (nil, nil, nil)
            }
            let root = ScheduledAutomationEngine.guestPath(repoPath)
            let q = "'" + root.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let cmd = "root=$(git -C \(q) rev-parse --show-toplevel 2>/dev/null); "
                + "[ -n \"$root\" ] || exit 0; "
                + "dir=$(git -C \"$root\" worktree list --porcelain 2>/dev/null "
                + "| awk -v b='refs/heads/\(branch)' "
                + "'/^worktree /{d=substr($0,10)} $0==\"branch \" b {print d; exit}'); "
                + "reg=\"$HOME/.bromure/worktrees/$(basename \"$root\")/.registry\"; "
                + "parent=$(awk -F'\\x1f' -v b='\(branch)' '$1==b {print $2; exit}' "
                + "\"$reg\" 2>/dev/null); "
                + "[ -n \"$parent\" ] || parent=$(git -C \"$root\" rev-parse "
                + "--abbrev-ref HEAD 2>/dev/null); "
                + "printf '%s\\n%s\\n%s\\n' \"$dir\" \"$parent\" \"$root\""
            guard let out = try? await delegate.guestExec(
                profileID: profileID, command: cmd, timeout: 15) else {
                return (nil, nil, nil)
            }
            let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            func v(_ i: Int) -> String? {
                lines.indices.contains(i) && !lines[i].isEmpty ? lines[i] : nil
            }
            return (v(0), v(1), v(2))
    }

    /// Immediate hand-to-review for the board_ready_for_review MCP tool: a
    /// DELIBERATE call from the agent is not the premature Stop-hook case,
    /// so it skips the quiescence settle and transitions synchronously.
    @discardableResult
    func handToReview(profileID: UUID, worktreeBranch: String?) -> Bool {
        guard let branch = worktreeBranch, branch.hasPrefix("wt/") else { return false }
        let slugPart = String(branch.dropFirst(3))
        guard let task = store.tasks.first(where: { t in
            guard t.stage == .inProgress || t.stage == .planning,
                  t.profileID == profileID,
                  let slug = t.branchSlug else { return false }
            return slugPart == slug || (slugPart.hasPrefix(slug + "-")
                && Int(slugPart.dropFirst(slug.count + 1)) != nil)
        }) else { return false }
        // The MCP response needs the transition NOW; metadata capture and
        // the tab close follow asynchronously (the tab lives until then,
        // so the guest queries still see it).
        let tab = delegate?.pane(for: profileID)?.model.tabs
            .first { $0.worktreeBranch == branch }
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
        let taskID = task.id
        Task { [weak self] in
            guard let self else { return }
            if let t = self.store.task(taskID),
               t.worktreeDir == nil || t.parentBranch == nil || t.rootRepo == nil {
                let m = await self.resolveWorktreeMetadata(profileID: profileID,
                                                           branch: branch,
                                                           repoPath: t.repoPath)
                self.store.mutate(taskID) {
                    if $0.worktreeDir == nil { $0.worktreeDir = m.dir }
                    if $0.parentBranch == nil { $0.parentBranch = m.parent }
                    if $0.rootRepo == nil { $0.rootRepo = m.root }
                }
            }
            self.closeSessionTab(profileID: profileID, branch: branch)
        }
        return store.task(task.id)?.stage == .testing
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

        var delivered = await typeIntoSession(
            profileID: task.profileID, branch: branch, text: feedback)
        if !delivered {
            delivered = delegate.automationWorktreeCommand(
                profileNameOrID: task.profileID.uuidString, action: "task-resume",
                args: [task.rootRepo ?? "", branch, task.parentBranch ?? "",
                       task.title, task.tool.rawValue, feedback])
        }
        guard delivered else {
            // Workspace down (or its session gone): don't strand the card —
            // the full resume path boots the workspace and re-launches the
            // agent on the existing worktree with this same feedback.
            resumeSession(taskID)
            return
        }
        let now = Date()
        store.mutate(taskID) {
            $0.stage = .inProgress
            $0.lastError = nil
            $0.mergingAt = nil   // cancels a pending merge verification
            for i in $0.comments.indices where $0.comments[i].sentAt == nil {
                $0.comments[i].sentAt = now
            }
        }
        BACDebug.log("tasks", "“\(task.title)”: \(unsent.count) comment(s) sent back")
    }

    /// Recovery for a task whose session can't be found (workspace
    /// rebooted, tab closed, agent dead): boot the workspace if needed and
    /// re-launch the agent on the EXISTING worktree via guest task-resume.
    /// Unsent review comments ride along; otherwise the agent gets a
    /// resume brief telling it to pick up where the worktree stands.
    func resumeSession(_ taskID: UUID) {
        guard let task = store.task(taskID),
              task.stage == .inProgress || task.stage == .testing,
              let branch = task.branch ?? task.branchSlug.map({ "wt/" + $0 }),
              delegate != nil else { return }
        let profileID = task.profileID
        let unsent = task.comments.filter { $0.sentAt == nil }
        let prompt = unsent.isEmpty
            ? Self.resumePrompt(for: task)
            : Self.feedbackPrompt(comments: unsent)
        store.mutate(taskID) { $0.lastError = nil }
        BACDebug.log("tasks", "“\(task.title)”: restarting session (\(branch))")
        Task { [weak self] in
            guard let self, let delegate = self.delegate else { return }
            var up = (try? await delegate.guestExec(profileID: profileID,
                                                    command: "true", timeout: 5)) != nil
            if !up {
                if !self.pendingBoots.contains(profileID) {
                    self.pendingBoots.insert(profileID)
                    delegate.startProfileForAutomation(profileID)
                }
                let deadline = Date().addingTimeInterval(Self.bootTimeout)
                while Date() < deadline {
                    try? await Task.sleep(nanoseconds: Self.bootPollInterval)
                    if (try? await delegate.guestExec(profileID: profileID,
                                                      command: "true", timeout: 5)) != nil {
                        up = true; break
                    }
                }
                self.pendingBoots.remove(profileID)
            }
            guard up else {
                self.store.mutate(taskID) { $0.lastError = NSLocalizedString(
                    "The workspace did not boot in time", comment: "task resume") }
                return
            }
            // A live session may already exist (workspace was just slow):
            // deliver the comments there instead of opening a second tab.
            if await self.tabIndex(profileID: profileID, branch: branch) != nil {
                if !unsent.isEmpty {
                    _ = await self.typeIntoSession(profileID: profileID,
                                                   branch: branch, text: prompt)
                }
            } else {
                guard delegate.automationWorktreeCommand(
                    profileNameOrID: profileID.uuidString, action: "task-resume",
                    args: [self.store.task(taskID)?.rootRepo ?? "", branch,
                           self.store.task(taskID)?.parentBranch ?? "",
                           task.title, task.tool.rawValue, prompt])
                else {
                    self.store.mutate(taskID) { $0.lastError = NSLocalizedString(
                        "Couldn't reach the workspace — is it running?",
                        comment: "task start") }
                    return
                }
            }
            let now = Date()
            self.store.mutate(taskID) {
                $0.stage = .inProgress
                $0.startedAt = now   // restart the session-gone clock
                for i in $0.comments.indices where $0.comments[i].sentAt == nil {
                    $0.comments[i].sentAt = now
                }
            }
        }
    }

    /// Prompt for re-launching an interrupted task session on its existing
    /// worktree: orient in the checkout, then continue as originally
    /// briefed (the full prompt, directives included, follows).
    nonisolated static func resumePrompt(for task: CodingTask) -> String {
        "This session was RESTARTED — you were already working on this task "
            + "in this worktree before the session was interrupted. Run "
            + "`git status` and `git log` to see where things stand, keep "
            + "what's already done, and continue from there.\n\n"
            + prompt(for: task)
    }

    /// The guest command that types text into a session's agent (base64
    /// through the guest shell so arbitrary text survives quoting, then
    /// Enter). Shared with the fat client, which runs it over the tunnel.
    nonisolated static func typeCommand(tabIndex: Int, text: String) -> String {
        let b64 = Data(text.utf8).base64EncodedString()
        return "echo \(b64) | base64 -d | xargs -0 tmux send-keys "
            + "-t bromure:\(tabIndex) -l && sleep 1 && "
            + "tmux send-keys -t bromure:\(tabIndex) Enter"
    }

    /// The guest command that tails a plan session's live Claude transcript.
    /// The planner runs IN the task's configured directory, so the project
    /// dir is derived from that path the way Claude encodes it ("/" and "."
    /// become "-"); `since` (epoch seconds) skips transcripts of earlier
    /// sessions in the same directory. Output is capped so a long session
    /// stays cheap to poll. Nil when the path has characters we won't quote.
    nonisolated static func planTranscriptCommand(guestCwd: String, since: Int) -> String? {
        var path = guestCwd
        while path.count > 1 && path.hasSuffix("/") { path = String(path.dropLast()) }
        let allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
            + "0123456789-_./+ "
        guard !path.isEmpty, path.allSatisfy({ allowed.contains($0) }) else { return nil }
        let enc1 = path.replacingOccurrences(of: "/", with: "-")
        let enc2 = path.replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        let dirs = (enc1 == enc2 ? [enc1] : [enc1, enc2])
            .map { "\"$HOME/.claude/projects/\($0)\"" }.joined(separator: " ")
        // The pq file is a PreToolUse hook's dump of a PENDING
        // AskUserQuestion (see the guest agent's _seed_question_hooks):
        // Claude Code doesn't write the assistant turn to the transcript
        // until the question is answered, so this is the only way the
        // window can show the question while it's actually being asked.
        // tr strips newlines so a pretty-printed dump still parses as one
        // transcript line.
        let pq = "\"$HOME/.bromure/pq-\(enc2).json\""
        return "f=$(find \(dirs) -maxdepth 1 -name '*.jsonl' -newermt @\(since) "
            + "2>/dev/null | xargs -r ls -t 2>/dev/null | head -1); "
            + "if [ -n \"$f\" ]; then tail -c 300000 \"$f\"; fi; "
            + "if [ -n \"$(find \(pq) -newermt @\(since) 2>/dev/null)\" ]; "
            + "then echo; tr -d '\\n' < \(pq); echo; fi"
    }

    /// The guest command that dumps a task session's FULL transcript —
    /// project dir by worktree-slug glob (transcripts live under
    /// ~/.claude/projects, so this works long after the worktree itself
    /// was merged away), with the plain-tab marker fallback. The home is
    /// a persistent ext4 image, so this is readable for as long as the
    /// workspace exists — the board's Done cards read it on demand.
    nonisolated static func taskTranscriptCommand(branch: String) -> String? {
        guard branch.hasPrefix("wt/") else { return nil }
        let slug = String(branch.dropFirst(3))
        guard !slug.isEmpty,
              slug.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" })
        else { return nil }
        return "d=$(ls -td ~/.claude/projects/*-\(slug) 2>/dev/null | head -1); "
            + "if [ -z \"$d\" ]; then "
            + "cwd=$(tmux list-windows -t bromure -F '#{@worktree}\t#{pane_current_path}' "
            + "2>/dev/null | awk -F'\t' -v b='wt/\(slug)' '$1==b {print $2; exit}'); "
            + "if [ -n \"$cwd\" ]; then "
            + "e1=$(printf %s \"$cwd\" | tr / -); e2=$(printf %s \"$cwd\" | tr ./ --); "
            + "d=$(ls -td \"$HOME/.claude/projects/$e1\" \"$HOME/.claude/projects/$e2\" "
            + "2>/dev/null | head -1); fi; fi; "
            + "f=$(ls -t \"$d\"/*.jsonl 2>/dev/null | head -1); "
            + "if [ -n \"$f\" ]; then head -c 25000000 \"$f\"; fi"
    }

    /// The guest command that prints the age (seconds) of the newest write
    /// to a session's transcript — the "are background subagents still
    /// working?" probe. Project dir by worktree-slug glob, with the
    /// plain-tab fallback through the wt/ marker's cwd. Prints nothing
    /// when no transcript exists.
    nonisolated static func transcriptAgeCommand(slug: String) -> String? {
        guard !slug.isEmpty,
              slug.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" })
        else { return nil }
        return "d=$(ls -td ~/.claude/projects/*-\(slug) 2>/dev/null | head -1); "
            + "if [ -z \"$d\" ]; then "
            + "cwd=$(tmux list-windows -t bromure -F '#{@worktree}\t#{pane_current_path}' "
            + "2>/dev/null | awk -F'\t' -v b='wt/\(slug)' '$1==b {print $2; exit}'); "
            + "if [ -n \"$cwd\" ]; then "
            + "e1=$(printf %s \"$cwd\" | tr / -); e2=$(printf %s \"$cwd\" | tr ./ --); "
            + "d=$(ls -td \"$HOME/.claude/projects/$e1\" \"$HOME/.claude/projects/$e2\" "
            + "2>/dev/null | head -1); fi; fi; "
            // The WHOLE tree, recursively: subagent transcripts land as
            // separate files (agent-*.jsonl, possibly nested), and a probe
            // watching only the newest top-level session file reads "quiet"
            // while five agents are hard at work.
            + "newest=$(find \"$d\" -type f -name '*.jsonl' -printf '%T@\\n' "
            + "2>/dev/null | sort -rn | head -1 | cut -d. -f1); "
            + "if [ -n \"$newest\" ]; then echo $(( $(date +%s) - newest )); fi"
    }

    /// The guest command that makes a task's directory usable: mkdir -p,
    /// git init when the directory isn't already its own repo root, and an
    /// empty root commit when the repo has no HEAD (worktrees need one).
    nonisolated static func initRepoCommand(quotedPath: String) -> String {
        "mkdir -p \(quotedPath) && cd \(quotedPath) && "
            + "{ [ \"$(git rev-parse --show-toplevel 2>/dev/null)\" = \"$(pwd -P)\" ] "
            + "|| git init -q; } && "
            + "{ git rev-parse -q --verify HEAD >/dev/null 2>&1 || "
            + "git -c user.name=Bromure -c user.email=tasks@bromure.io "
            + "commit -q --allow-empty -m 'task root'; }"
    }

    /// True when `guestPath` belongs to a repo the board can work with —
    /// inside a work tree whose root is NOT the home directory. The guest
    /// home may itself be a git repo (dotfiles, user experiments); cutting
    /// worktrees off it silently scoops the whole home, so it doesn't count.
    private func usableRepo(profileID: UUID, quotedPath: String) async -> Bool {
        guard let delegate else { return false }
        let cmd = "t=$(git -C \(quotedPath) rev-parse --show-toplevel) && "
            + "[ \"$t\" != \"$HOME\" ]"
        return (try? await delegate.guestExec(
            profileID: profileID, command: cmd, timeout: 10)) != nil
    }

    /// The guest command for a sequence of TUI keystrokes into a session's
    /// tab (answering an AskUserQuestion picker). Digits are sent literally,
    /// named keys (Enter, Right) as tmux key names, with a beat between
    /// keystrokes — the picker debounces and swallows bursts.
    nonisolated static func answerKeysCommand(tabIndex: Int, keys: [String]) -> String {
        keys.compactMap { k -> String? in
            let named = ["Enter", "Right", "Left", "Down", "Up", "Tab", "Space"]
            let isDigit = k.count == 1 && k.first!.isNumber
            guard isDigit || named.contains(k) else { return nil }
            return "tmux send-keys -t bromure:\(tabIndex) \(isDigit ? "-l " : "")\(k)"
        }.joined(separator: " && sleep 1 && ")
    }

    /// Send picker keystrokes into a live session (see answerKeysCommand).
    /// Refuses until the picker is actually ON SCREEN: keystrokes that
    /// arrive while the agent is still streaming (or after the picker
    /// closed) land in the chat input, which INTERRUPTS the pending tool
    /// call — Claude records "user declined to answer". Waits up to ~30s
    /// for the picker footer, then answers.
    func answerInSession(profileID: UUID, branch: String, keys: [String]) async -> Bool {
        guard let delegate, !keys.isEmpty,
              let index = await tabIndex(profileID: profileID, branch: branch)
        else { return false }
        let probe = "tmux capture-pane -p -t bromure:\(index) 2>/dev/null "
            + "| grep -q 'Enter to select'"
        var visible = false
        for _ in 0..<15 {
            if (try? await delegate.guestExec(
                profileID: profileID, command: probe, timeout: 8)) != nil {
                visible = true
                break
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        guard visible else {
            BACDebug.log("tasks", "picker not on screen for \(branch) — not sending")
            return false
        }
        return (try? await delegate.guestExec(
            profileID: profileID,
            command: Self.answerKeysCommand(tabIndex: index, keys: keys),
            timeout: 60)) != nil
    }

    nonisolated static func isSafeBranch(_ branch: String) -> Bool {
        !branch.isEmpty && branch.allSatisfy {
            $0.isLowercase || $0.isNumber || $0 == "-" || $0 == "/"
        }
    }

    /// The guest tmux window index backing a session branch. The attached
    /// pane's roster when there is one; a DETACHED session (planning boots
    /// the VM headless) has no pane, so ask the guest's tmux directly.
    func tabIndex(profileID: UUID, branch: String) async -> Int? {
        if let i = delegate?.pane(for: profileID)?.model.tabs
            .first(where: { $0.worktreeBranch == branch })?.index {
            return i
        }
        guard let delegate, Self.isSafeBranch(branch) else { return nil }
        let cmd = "tmux list-windows -t bromure -F '#{window_index} #{@worktree}' "
            + "2>/dev/null | awk -v b='\(branch)' '$2==b {print $1; exit}'"
        guard let out = try? await delegate.guestExec(
            profileID: profileID, command: cmd, timeout: 8) else { return nil }
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The actual wt/ branch of the task's live session — pane roster
    /// first, guest tmux when the session runs detached.
    func liveBranchResolved(of task: CodingTask) async -> String? {
        if let b = liveBranch(of: task) { return b }
        guard let slug = task.branchSlug, let delegate,
              Self.isSafeBranch(slug) else { return nil }
        let cmd = "tmux list-windows -t bromure -F '#{@worktree}' 2>/dev/null"
        guard let out = try? await delegate.guestExec(
            profileID: task.profileID, command: cmd, timeout: 8) else { return nil }
        return out.split(whereSeparator: \.isNewline).map(String.init)
            .first { AutomationBoard.branchMatches($0, slug: slug) }
    }

    /// Type text into a live session's agent. Used by review send-back and
    /// the plan window's input box.
    func typeIntoSession(profileID: UUID, branch: String, text: String) async -> Bool {
        guard let delegate,
              let index = await tabIndex(profileID: profileID, branch: branch)
        else { return false }
        return (try? await delegate.guestExec(
            profileID: profileID,
            command: Self.typeCommand(tabIndex: index, text: text),
            timeout: 20)) != nil
    }

    // MARK: Planning watchdog

    private var planWatchdogs: [UUID: Task<Void, Never>] = [:]
    /// Tasks whose done signal arrived and is settling (see
    /// waitForSessionQuiet) — later Stop signals are ignored meanwhile.
    private var settling: Set<UUID> = []

    /// End a planning session's in-flight state with a reason — the card
    /// stops spinning and says what to do, instead of waiting forever.
    /// Kill the guest tmux window backing a session branch. Called when
    /// the agent has finished (task → Testing, or planning wrapped up):
    /// the tab would otherwise sit there as an idle claude / dead shell.
    /// Review send-back reopens the worktree via task-resume, so nothing
    /// needs the old tab. A short grace lets final writes flush.
    func closeSessionTab(profileID: UUID, branch: String,
                         afterSeconds: UInt64 = 3) {
        guard branch.allSatisfy({
            $0.isLowercase || $0.isNumber || $0 == "-" || $0 == "/"
        }), !branch.isEmpty else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: afterSeconds * 1_000_000_000)
            guard let delegate = self?.delegate else { return }
            let cmd = "for i in $(tmux list-windows -t bromure "
                + "-F '#{window_index} #{@worktree}' "
                + "| awk -v b='\(branch)' '$2==b {print $1}'); "
                + "do tmux kill-window -t bromure:$i; done"
            _ = try? await delegate.guestExec(profileID: profileID,
                                              command: cmd, timeout: 15)
            BACDebug.log("tasks", "closed session tab for \(branch)")
        }
    }

    private func abortPlanning(_ taskID: UUID, reason: String) {
        planWatchdogs[taskID]?.cancel()
        planWatchdogs[taskID] = nil
        guard let t = store.task(taskID), t.stage == .backlog,
              t.validationRequestedAt != nil else { return }
        // Phases already landed? Then the session ending is just... done.
        if let done = t.validatedAt, let req = t.validationRequestedAt,
           done >= req { return }
        BACDebug.log("tasks", "“\(t.title)”: planning aborted — \(reason)")
        store.mutate(taskID) {
            $0.validationRequestedAt = nil
            $0.branchSlug = nil
            $0.lastError = reason
        }
    }

    /// Watch a launched planning session and abort the card's in-flight
    /// state when the session dies: tab never appears, tab disappears (VM
    /// reboot, user closed it), the agent process exits back to a bare
    /// shell (user quit claude), or the 1-hour window lapses. Ends itself
    /// quietly once phases land.
    func watchPlanning(_ taskID: UUID, slug: String, profileID: UUID) {
        planWatchdogs[taskID]?.cancel()
        planWatchdogs[taskID] = Task { [weak self] in
            let started = Date()
            var seenTab = false
            var sawAgent = false
            var bareShellPolls = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, let delegate = self.delegate else { return }
                guard let t = self.store.task(taskID),
                      t.stage == .backlog,
                      let req = t.validationRequestedAt else { return }
                if let done = t.validatedAt, done >= req {
                    // Phases landed — the interview is over. Give the agent
                    // a beat to print its summary, then close its tab.
                    if let branch = self.liveBranch(of: t) {
                        self.closeSessionTab(profileID: profileID,
                                             branch: branch, afterSeconds: 20)
                    }
                    return
                }
                if Date().timeIntervalSince(started) > 3600 {
                    self.abortPlanning(taskID, reason: NSLocalizedString(
                        "The planning session timed out without filing phases — click Plan to retry.",
                        comment: "plan watchdog"))
                    return
                }
                // Pane roster when attached; guest tmux when the session
                // runs detached (planning boots the VM headless).
                let index = await self.tabIndex(profileID: profileID,
                                                branch: "wt/" + slug)
                guard let index else {
                    if seenTab || Date().timeIntervalSince(started) > 240 {
                        self.abortPlanning(taskID, reason: seenTab
                            ? NSLocalizedString(
                                "The planning session ended before filing phases — click Plan to retry.",
                                comment: "plan watchdog")
                            : NSLocalizedString(
                                "The planning session never started — is the workspace running? Click Plan to retry.",
                                comment: "plan watchdog"))
                        return
                    }
                    continue
                }
                seenTab = true
                // Did the agent exit back to a bare shell (user quit claude)?
                let cmd = "tmux list-panes -t bromure:\(index) "
                    + "-F '#{pane_current_command}' 2>/dev/null | head -1"
                guard let out = try? await delegate.guestExec(
                    profileID: profileID, command: cmd, timeout: 5) else { continue }
                let proc = out.trimmingCharacters(in: .whitespacesAndNewlines)
                if ["bash", "zsh", "sh", "dash"].contains(proc) {
                    if sawAgent {
                        bareShellPolls += 1
                        if bareShellPolls >= 2 {
                            self.abortPlanning(taskID, reason: NSLocalizedString(
                                "Claude exited before filing phases — click Plan to retry.",
                                comment: "plan watchdog"))
                            return
                        }
                    }
                } else if !proc.isEmpty {
                    sawAgent = true
                    bareShellPolls = 0
                }
            }
        }
    }

    /// App-launch sweep: re-arm watchdogs for planning sessions that were
    /// in flight when the app quit, so a stale spinner can't survive a
    /// restart unnoticed.
    func resumePlanningWatchdogs() {
        for t in store.tasks
        where t.stage == .backlog && t.validationInFlight {
            if let slug = t.branchSlug {
                watchPlanning(t.id, slug: slug, profileID: t.profileID)
            } else {
                abortPlanning(t.id, reason: NSLocalizedString(
                    "The planning session was interrupted — click Plan to retry.",
                    comment: "plan watchdog"))
            }
        }
    }

    // MARK: Merge (Testing → Done)

    /// Merge the task's branch into its parent — or `target`, when the
    /// review picked another branch — and mark the task Done. The guest
    /// opens the usual merge tab (squash flavor on request); conflicts
    /// spawn the resolver flow.
    func merge(_ taskID: UUID, into targetOverride: String? = nil,
               squash: Bool = false) {
        guard let task = store.task(taskID), task.stage == .testing,
              let branch = task.branch, let delegate else { return }
        guard let target = targetOverride ?? task.parentBranch,
              let root = task.rootRepo else {
            // Metadata capture failed at hand-to-review (workspace down at
            // the time?). Resolve it now and retry once — a silent return
            // here looked like "merge did nothing" on the board.
            Task { [weak self] in
                guard let self else { return }
                let m = await self.resolveWorktreeMetadata(
                    profileID: task.profileID, branch: branch,
                    repoPath: task.repoPath)
                self.store.mutate(taskID) {
                    if $0.worktreeDir == nil { $0.worktreeDir = m.dir }
                    if $0.parentBranch == nil { $0.parentBranch = m.parent }
                    if $0.rootRepo == nil { $0.rootRepo = m.root }
                }
                if let t = self.store.task(taskID),
                   (targetOverride ?? t.parentBranch) != nil, t.rootRepo != nil {
                    self.merge(taskID, into: targetOverride, squash: squash)
                } else {
                    self.store.mutate(taskID) { $0.lastError = NSLocalizedString(
                        "Couldn't determine the branch's parent or repo root — is the workspace running?",
                        comment: "task merge") }
                }
            }
            return
        }
        guard task.mergingAt == nil else { return }   // one merge in flight
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
        // NOT Done yet: the guest merge can take a while (agent committing
        // outstanding work, conflict resolution awaiting the user) — and
        // dependent phases queued on this card must not start until the
        // changes actually exist on the target. Verify, then finish.
        store.mutate(taskID) { $0.mergingAt = Date(); $0.lastError = nil }
        Task { [weak self] in
            await self?.verifyMergeLanded(taskID, branch: branch, target: target,
                                          root: root, squash: squash)
        }
    }

    private static let mergeVerifyTimeout: TimeInterval = 1800   // 30 min
    private static let mergeVerifyInterval: UInt64 = 5_000_000_000  // 5s

    /// Poll the guest's git state until the branch's changes are contained
    /// in the target, then flip the card Done and pump the queue. Merge
    /// flavor decides the check: a normal merge makes the branch an ancestor
    /// of the target; a squash merge doesn't, but leaves the two trees
    /// identical. The task's worktree must also be clean — the agent-driven
    /// dirty-merge path commits there first, and until it has, an
    /// "already-an-ancestor" branch (uncommitted-only work) must not count.
    private func verifyMergeLanded(_ taskID: UUID, branch: String,
                                   target: String, root: String,
                                   squash: Bool) async {
        func q(_ s: String) -> String {
            "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        var check = squash
            ? "git -C \(q(root)) diff --quiet \(q(target)) \(q(branch)) -- 2>/dev/null"
            : "git -C \(q(root)) merge-base --is-ancestor \(q(branch)) \(q(target)) 2>/dev/null"
        if let wt = store.task(taskID)?.worktreeDir, !wt.isEmpty {
            check = "[ -z \"$(git -C \(q(wt)) status --porcelain 2>/dev/null)\" ] && " + check
        }
        let cmd = check + " && echo MERGED"
        let deadline = Date().addingTimeInterval(Self.mergeVerifyTimeout)
        while Date() < deadline {
            // Merge cancelled or superseded (sent back to In Progress,
            // closed without merge, card deleted) → stop quietly.
            guard let task = store.task(taskID), task.stage == .testing,
                  task.mergingAt != nil, let delegate else { return }
            let out = try? await delegate.guestExec(
                profileID: task.profileID, command: cmd, timeout: 10)
            if out?.contains("MERGED") == true {
                BACDebug.log("tasks", "“\(task.title)”: merge verified on \(target)")
                store.mutate(taskID) {
                    $0.stage = .done
                    $0.completedAt = Date()
                    $0.merged = true
                    $0.mergingAt = nil
                    $0.lastError = nil
                }
                pumpQueue()
                return
            }
            try? await Task.sleep(nanoseconds: Self.mergeVerifyInterval)
        }
        store.mutate(taskID) {
            guard $0.mergingAt != nil else { return }
            $0.mergingAt = nil
            $0.lastError = NSLocalizedString(
                "The merge hasn't completed — check the merge tab in the workspace (conflicts wait for your confirmation), then click Merge again, or use Close (no merge).",
                comment: "task merge")
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
        pumpQueue()
    }

    /// Close a task without merging (abandoned, or merged by hand).
    func closeWithoutMerge(_ taskID: UUID) {
        store.mutate(taskID) {
            $0.stage = .done
            $0.completedAt = Date()
            $0.merged = false
            $0.mergingAt = nil
        }
        pumpQueue()
    }

    /// Manual Testing → In Progress with no feedback (the user just wants
    /// the agent tab back in play), and manual In Progress → Testing for
    /// non-Claude agents that never signal done.
    func moveToInProgress(_ taskID: UUID) {
        store.mutate(taskID) {
            if $0.stage == .testing || $0.stage == .planning {
                $0.stage = .inProgress
                $0.mergingAt = nil   // cancels a pending merge verification
            }
        }
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
        /// Line number in the NEW file (nil for removed/hunk lines) — what
        /// a margin annotation anchors to.
        var newLine: Int?
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
        var newCounter = 0
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
            var newLine: Int?
            switch kind {
            case .hunk:
                // "@@ -a,b +c,d @@" — c is where the new side resumes.
                if let plus = line.split(separator: " ").first(where: { $0.hasPrefix("+") }),
                   let start = Int(plus.dropFirst().split(separator: ",")[0]) {
                    newCounter = start
                }
            case .added, .context:
                newLine = newCounter
                newCounter += 1
            case .removed:
                break
            }
            current?.lines.append(.init(id: lineID, kind: kind,
                                        text: String(line), newLine: newLine))
        }
        if let f = current { files.append(f) }
        return files
    }
}
