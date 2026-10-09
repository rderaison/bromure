import Foundation
import Observation
import CryptoKit

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
    /// Files marked viewed in the review window: path → fingerprint of the
    /// diff that was seen.
    var reviewViewed: [String: String]?

    var createdAt: Date
    /// When the task last changed (the store stamps it). nil: not since
    /// it was created.
    var updatedAt: Date?
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
    /// A start is being checked (workspace up, folder present, a repo of
    /// its own) — the card stays where it is with a "Starting…" spinner and
    /// moves to In Progress only once the launch can actually happen.
    var startingAt: Date?
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
    /// `git clone` this URL into `repoPath` before the first start (or plan)
    /// when the folder doesn't hold a repository yet. Uses the workspace's
    /// git credentials / SSH key like any clone the agent would run. A
    /// folder that already is a repo is left alone (a restart never
    /// re-clones over the agent's work).
    var cloneURL: String?
    /// Set when a resume found nothing to resume INTO — the repository
    /// folder or the task's branch is gone (workspace reset, merge cleanup,
    /// a deleted checkout). `lastError` carries the explanation; the only
    /// way forward is `startOver`, which clears this.
    var restartNeeded: Bool?

    /// Who works on the task when it isn't a new agent in a fresh worktree
    /// (nil, the default): an existing session, or a room (its Switchboard
    /// hands it to a member). Rides a delegation request from the board.
    var assignment: TaskAssignment?
    /// The board's request to the assignee (DelegationStore record).
    var delegationID: UUID?
    /// The assignee's latest progress report.
    var assigneeNote: String?
    /// A question the assignee asked the board, waiting for the user.
    var pendingQuestion: String?
    var pendingAskID: UUID?
    /// What the assignee said when it delivered.
    var deliverySummary: String?
    /// What the assignee said when it merged the task on acceptance.
    var mergeReport: String?
    /// The pull request the assignee opened for it (found in its delivery).
    var pullRequestURL: String?

    /// How this task leaves review when approved (nil = its workspace's,
    /// else the app's choice — see `TaskFinish.resolve`).
    var finish: TaskFinish?
    /// The landing under way (or stuck) — set from the moment the user
    /// approves a merge or a pull request until the card goes Done.
    var landing: TaskLanding?
    /// How a Done card got there (nil on cards finished by older builds —
    /// `effectiveCompletion` derives one from `merged`/`prOpened`).
    var completion: TaskCompletion?
    /// Files the branch changes against its target, as last measured (the
    /// review summary). 0 = a task that produced no code; nil = unknown.
    var codeChanges: Int?
    /// When the idle Review sweep put the agent's session away (its tab
    /// closed after ~2 h in Review with nobody touching it).
    var sessionParkedAt: Date?
    /// The agent session the task's launch opened (bound once the agent is
    /// seen up) — how the card finds its live state even when the tab or
    /// session doesn't carry the worktree branch.
    var sessionID: UUID? = nil
    /// A planned brief: when its planning session ended normally with
    /// phases filed — the plan is complete. Only such a brief can roll up
    /// to Done with its phases (see `briefRollUp`).
    var planCompletedAt: Date? = nil
    /// How many phases the planner said the plan has (board_set_plan
    /// phaseCount). nil: not stated.
    var plannedPhases: Int? = nil
    /// The branch a task stopped back to the Backlog was on ("wt/…") — its
    /// worktree stays in the workspace, and the next start resumes there
    /// instead of cutting (and orphaning) a new one.
    var resumeBranch: String? = nil

    /// The first GitHub pull-request link in `text`.
    static func pullRequestURL(in text: String) -> String? {
        let pattern = #"https://github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/pull/[0-9]+"#
        guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
        return String(text[r])
    }

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
         queuedAt: Date? = nil, initRepo: Bool? = nil,
         cloneURL: String? = nil) {
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
        self.cloneURL = cloneURL
    }

    /// The clone URL, trimmed; nil when unset or blank.
    var effectiveCloneURL: String? {
        let u = (cloneURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return u.isEmpty ? nil : u
    }

    /// The user-facing part of a task prompt as it appears in a transcript:
    /// the brief (and a resume preface), minus the operating notes and the
    /// board-tool blurb the engine appends — plumbing, not conversation.
    static func displayPrompt(_ text: String) -> String {
        var s = text
        for marker in ["\n---\nOperating notes for this task",
                       "This session has the bromure-board MCP tools"] {
            if let r = s.range(of: marker) { s = String(s[..<r.lowerBound]) }
        }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? text : trimmed
    }

    /// "github.com/org/repo" for a chip — scheme, user, and ".git" dropped.
    static func shortRepoURL(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if let at = s.firstIndex(of: "@") { s = String(s[s.index(after: at)...]) }
        s = s.replacingOccurrences(of: ":", with: "/")
        while s.hasSuffix("/") { s.removeLast() }
        if s.lowercased().hasSuffix(".git") { s.removeLast(4) }
        return s
    }

    /// The folder name a clone of `url` would create ("repo" for
    /// github.com/org/repo.git); nil when the URL has no usable last segment.
    static func repoName(fromCloneURL url: String) -> String? {
        let short = shortRepoURL(url)
        guard let last = short.split(separator: "/").last else { return nil }
        let name = String(last).map { ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_") ? $0 : "-" }
        let cleaned = String(name).trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return cleaned.isEmpty ? nil : cleaned
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

    /// A start is being checked (see `startingAt`). Bounded so a host
    /// crash mid-check can't pin the spinner (a cold boot plus a clone
    /// fits well inside it).
    var isStarting: Bool {
        guard let at = startingAt, stage == .backlog || stage == .planning else { return false }
        return Date().timeIntervalSince(at) < 900
    }

    /// A task with nothing to merge: no branch at all, a delegated delivery
    /// whose worktree was never found, or a branch measured with no change
    /// against its target. Review offers Mark Done, not git.
    var isNoCode: Bool {
        if branch == nil && branchSlug == nil { return true }
        if delegationID != nil && stage == .testing && (worktreeDir ?? "").isEmpty { return true }
        return codeChanges == 0
    }

    /// Who does (and lands) the task, for cards: the assignee ("@hotfixes")
    /// or the agent a new-agent task ran ("Kimi Code").
    var workerName: String {
        if let a = assignment, a.kind != .worktree { return a.label }
        return tool.displayName
    }

    /// The branch this task lands in: the landing's own target while one
    /// runs, else where the work forked from.
    var landingTarget: String? {
        landing?.target ?? parentBranch
    }

    /// How the card got to Done — recorded, or derived for cards an older
    /// build finished.
    var effectiveCompletion: TaskCompletion? {
        if let completion { return completion }
        guard stage == .done else { return nil }
        if merged { return .merged(target: parentBranch ?? "", verified: true, by: nil) }
        if prOpened == true { return .prOpened(url: pullRequestURL) }
        return .closedWithoutMerge
    }

    /// Old builds kept an in-flight merge in `mergingAt`: it becomes an
    /// agent landing into the parent (the guest merge tab finishes it);
    /// the old field is cleared so it never writes again.
    static func migrateLegacy(_ t: CodingTask) -> CodingTask {
        var t = t
        if let at = t.mergingAt {
            if t.landing == nil, t.stage == .testing {
                t.landing = TaskLanding(mode: .merge, target: t.parentBranch ?? "",
                                        phase: .agentLanding, startedAt: at)
            }
            t.mergingAt = nil
        }
        return t
    }
}

/// An approved task on its way out of Review.
struct TaskLanding: Codable, Equatable, Sendable {
    enum Mode: String, Codable, Sendable { case merge, squash, pr }
    enum Phase: String, Codable, Sendable {
        /// Reading the branch and the target on the machine.
        case checking
        /// Bromure is merging it itself (a clean fast-forward).
        case fastMerging
        /// The agent that wrote it is rebasing, testing and merging (or
        /// pushing and opening the pull request).
        case agentLanding
        /// Stuck — `detail` says why; the user decides.
        case needsYou
        /// In — the card is about to go Done.
        case landed
    }
    var mode: Mode
    var target: String
    var phase: Phase
    var detail: String?
    var startedAt: Date
    var prURL: String?
    var verified: Bool = false
    /// Keep the branch (and its checkout) once it has landed.
    var keepBranch: Bool = false
    /// Merge landings: push the target to its remote afterwards — done only
    /// once the remote has it. nil/false = a local merge.
    var push: Bool?
    /// The remote it goes to ("origin"), resolved when the landing starts.
    var remote: String?
    var pushes: Bool { push == true && mode != .pr }
    /// The agent's latest line while it lands, for the card — only ever
    /// from after the brief reached it.
    var agentLine: String?
    /// The landing brief is on its way to the agent (typed in, or its
    /// conversation being resumed): not landing yet. nil once delivered.
    var handingOver: Bool?
}

/// How a Done card got there — what its card says.
enum TaskCompletion: Codable, Equatable, Sendable {
    /// Merged into `target`; `verified` = Bromure saw it in the target's
    /// history; `by` = who reported it, when Bromure couldn't look.
    case merged(target: String, verified: Bool, by: String?)
    case prOpened(url: String?)
    case markedDone(byUser: Bool)
    case closedWithoutMerge
}

/// What cards and the review window say about a task's way out.
enum TaskLandingText {
    /// The Review card's state line (nil: nothing to say).
    static func line(for t: CodingTask) -> String? {
        switch TaskLandingLine.of(t) {
        case .readyToLand?:
            return NSLocalizedString("Ready to land", comment: "task card")
        case .handingOver(let agent)?:
            return String(format: NSLocalizedString("Handing over to %@…", comment: "task card"), agent)
        case .fastMerging(let target)?:
            return String(format: NSLocalizedString("Landing — merging into %@…", comment: "task card"), target)
        case .landing(let agent, let target, let mode, _)?:
            return mode == .pr
                ? String(format: NSLocalizedString("Landing — %1$@ is opening a pull request into %2$@…", comment: "task card"), agent, target)
                : String(format: NSLocalizedString("Landing — %1$@ is merging into %2$@…", comment: "task card"), agent, target)
        case .needsYou(let why)?:
            return String(format: NSLocalizedString("Needs you — %@", comment: "task landing"), why)
        case nil:
            return nil
        }
    }

    /// A Done card's outcome line, from the recorded provenance.
    static func done(_ t: CodingTask) -> String {
        switch t.effectiveCompletion {
        case .merged(let target, let verified, let by)?:
            let into = target.isEmpty
                ? NSLocalizedString("Merged", comment: "task card: done")
                : String(format: NSLocalizedString("Merged into %@", comment: "task card: done"), target)
            if verified { return into }
            if by == "user" {
                return into + " · " + NSLocalizedString("marked by you", comment: "task card: done")
            }
            return into + " · " + String(format: NSLocalizedString("reported by %@, not verified", comment: "task card: done"),
                                         by ?? NSLocalizedString("the agent", comment: "task card: done"))
        case .prOpened(let url)?:
            if let url, let n = URL(string: url)?.lastPathComponent, Int(n) != nil {
                return String(format: NSLocalizedString("PR #%@ opened", comment: "task card: done"), n)
            }
            return NSLocalizedString("Pull request opened", comment: "task card: done")
        case .markedDone(let byUser)?:
            return byUser ? NSLocalizedString("Marked done by you", comment: "task card: done")
                          : NSLocalizedString("All its phases are done", comment: "task card: done")
        case .closedWithoutMerge?, nil:
            return NSLocalizedString("Closed without merging", comment: "task card: done")
        }
    }
}

/// The card's one-line state while a task is in Review or landing.
enum TaskLandingLine: Equatable {
    case readyToLand
    case landing(agent: String, target: String, mode: TaskLanding.Mode, line: String?)
    /// The landing brief hasn't reached the agent yet.
    case handingOver(agent: String)
    case fastMerging(target: String)
    case needsYou(String)

    static func of(_ t: CodingTask) -> TaskLandingLine? {
        guard t.stage == .testing else { return nil }
        guard let l = t.landing else { return t.isNoCode ? nil : .readyToLand }
        switch l.phase {
        case .needsYou: return .needsYou(l.detail ?? "")
        case .checking, .fastMerging, .landed: return .fastMerging(target: l.target)
        case .agentLanding:
            if l.handingOver == true { return .handingOver(agent: t.workerName) }
            return .landing(agent: t.workerName, target: l.target, mode: l.mode, line: l.agentLine)
        }
    }
}

/// Who picks a backlog task up: a new agent in a fresh worktree (each
/// task its own), a session that already exists, or a room (its
/// Switchboard hands it to a member). Tasks queued for the same assignee
/// are taken one after another, oldest first.
struct TaskAssignment: Codable, Equatable, Sendable, Hashable {
    /// worktree: a new agent; session: an existing one; room: the room's
    /// Switchboard picks a member; switchboard: the app's Switchboard picks
    /// any session.
    enum Kind: String, Codable, Sendable { case worktree, session, room, switchboard }
    var kind: Kind
    /// The session's id, or the room's (unused for worktree).
    var id: UUID
    /// "@hotfixes" / "#payments" / "New agent" — how the card names it.
    var label: String

    static let newAgent = TaskAssignment(
        kind: .worktree, id: UUID(uuidString: "00000000-0000-4000-8000-00000000A6E7")!,
        label: NSLocalizedString("New agent", comment: "task assignee"))
    static let switchboard = TaskAssignment(
        kind: .switchboard, id: UUID(uuidString: "00000000-0000-4000-8000-0000005B0A2D")!,
        label: "@switchboard")

    /// The SF Symbol for an assignee.
    var systemImage: String {
        switch kind {
        case .worktree:    return "arrow.triangle.branch"
        case .session:     return "person.crop.circle.fill"
        case .room:        return "square.grid.2x2.fill"
        case .switchboard: return "switch.2"
        }
    }

    /// How many new-agent tasks run at once from the queue.
    static let newAgentConcurrency = 2

    func same(as other: TaskAssignment?) -> Bool {
        guard let other else { return false }
        return kind == other.kind && (kind == .worktree || kind == .switchboard || id == other.id)
    }

    /// Where `task` stands in its assignee's queue (1 = next), nil when it
    /// isn't queued.
    static func queuePosition(of task: CodingTask, in tasks: [CodingTask]) -> Int? {
        guard task.stage == .backlog, let a = task.assignment else { return nil }
        let queue = tasks.filter { $0.stage == .backlog && a.same(as: $0.assignment) }
            .sorted { $0.createdAt < $1.createdAt }
        return queue.firstIndex { $0.id == task.id }.map { $0 + 1 }
    }

    /// Explicit opt-in: sessions and rooms push their branch and open a pull
    /// request AT DELIVERY (no local review first). Off by default — the
    /// work comes back for review, and the approved task lands the way its
    /// finish preference says (`TaskFinish`).
    static var finishWithPullRequest: Bool {
        get { UserDefaults.standard.object(forKey: "codingTasks.finishWithPR") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "codingTasks.finishWithPR") }
    }

    /// The board's standing choice for NEW backlog items (per Mac).
    static var autoAssign: TaskAssignment? {
        get {
            guard let data = UserDefaults.standard.data(forKey: "codingTasks.autoAssign") else { return nil }
            return try? JSONDecoder().decode(TaskAssignment.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: "codingTasks.autoAssign")
            } else {
                UserDefaults.standard.removeObject(forKey: "codingTasks.autoAssign")
            }
        }
    }
}

/// What the board can hand a task to: live sessions and rooms.
struct TaskAssigneeChoices: Equatable, Sendable {
    struct Session: Identifiable, Equatable, Sendable, Hashable {
        let id: UUID
        let label: String
        let workspace: String
        let busy: Bool
        /// Its workspace: a task queued for it is that workspace's (the
        /// card's chip, review, merge), whatever the editor defaulted to.
        var profileID: UUID? = nil
    }
    struct Room: Identifiable, Equatable, Sendable, Hashable {
        let id: UUID
        let name: String
    }
    var sessions: [Session] = []
    var rooms: [Room] = []

    /// The workspace a task queued this way belongs to: the session's, when
    /// it goes to one (nil: a room, the Switchboard, a new agent — keep the
    /// task's own).
    func workspace(for assignment: TaskAssignment?) -> UUID? {
        guard let a = assignment, a.kind == .session else { return nil }
        return sessions.first { $0.id == a.id }?.profileID
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
    /// Still pending when the agent handed the task back to Review: it
    /// never reached the agent (the review says so, and offers Send Back).
    var undelivered: Bool?

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
            var t = task
            Self.settleComments(before: tasks[i], after: &t)
            if !Self.sameContent(tasks[i], t) { t.updatedAt = Date() }
            tasks[i] = t
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
        // The card is gone; its archived transcript goes with it. (The
        // fat-client mirror never calls remove — deletes ride the tunnel.)
        TaskTranscriptArchive.remove(id)
    }

    /// In-place update + save; no-op when the task is gone.
    func mutate(_ id: UUID, _ change: (inout CodingTask) -> Void) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        let before = tasks[i]
        change(&tasks[i])
        Self.settleComments(before: before, after: &tasks[i])
        if !Self.sameContent(before, tasks[i]) { tasks[i].updatedAt = Date() }
        save()
    }

    /// Review comments that never reached the agent, on a stage change:
    /// handed back to Review with some still pending → they're flagged
    /// undelivered (the review offers to send them again, never silently);
    /// gone Done → pending ones are dropped (nobody will deliver them).
    static func settleComments(before: CodingTask, after: inout CodingTask) {
        guard before.stage != after.stage else { return }
        switch after.stage {
        case .testing where before.stage == .inProgress:
            for i in after.comments.indices where after.comments[i].sentAt == nil {
                after.comments[i].undelivered = true
            }
        case .done:
            let n = after.comments.count
            after.comments.removeAll { $0.sentAt == nil }
            if after.comments.count != n {
                BACDebug.log("tasks", "“\(after.title)”: \(n - after.comments.count) undelivered comment(s) dropped at Done")
            }
        default:
            break
        }
    }

    /// Equal apart from when they last changed — a save that changes
    /// nothing doesn't count as a modification.
    static func sameContent(_ a: CodingTask, _ b: CodingTask) -> Bool {
        var a = a, b = b
        a.updatedAt = nil; b.updatedAt = nil
        return a == b
    }

    /// Fat-client mirror: replace the whole task list from a remote
    /// snapshot, in memory only (no save — a mirror store is a read model
    /// of another machine's state). No-op when nothing changed.
    func mirror(tasks newTasks: [CodingTask]) {
        let newTasks = newTasks.map(CodingTask.migrateLegacy)
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
        tasks = payload.tasks.map(CodingTask.migrateLegacy)
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

// MARK: - Session-store locator (all platforms)

/// What ties a read to ONE conversation when the agent's store is keyed by
/// folder (Kimi): the session id once known, else the earliest moment its
/// journal may have been begun.
struct TranscriptPin: Equatable, Sendable {
    /// Kimi's "session_<uuid>": read that session's journal, nothing else.
    var kimiSession: String? = nil
    /// Epoch seconds: a Kimi journal begun before this is another
    /// conversation's (a fresh launch's floor).
    var kimiCreatedSince: Int? = nil
    /// Kimi sessions other sessions on the machine own: never this tab's,
    /// however recently written (two Kimi tabs in one folder).
    var kimiExclude: [String] = []
    /// Grok's session (its folder `~/.grok/sessions/<cwd>/<uuid>/`) or
    /// Codex's conversation (`rollout-…-<uuid>.jsonl`): that file only —
    /// never the folder's newest, which after a relaunch was an archived
    /// session's (Grok), or a second session's live rollout (Codex).
    var grokSession: String? = nil
    var codexSession: String? = nil
    /// omp's session (`~/.omp/agent/sessions/<cwd>/<ts>_<uuid>.jsonl`):
    /// that file only, never the folder's newest (another session's).
    var ompSession: String? = nil
    /// Grok / Codex conversations (lowercased uuids) other sessions on the
    /// machine own, for a session not pinned to its own yet: the folder's
    /// newest is then never one of those — Codex A's header took B's token
    /// total after B ran in the same folder (A's copy read B's rollout).
    var foreignConversations: [String] = []

    /// The pin a session's own conversation id gives (`agentTranscriptID`),
    /// for the agents that key their store by folder or date.
    static func conversation(tool: String, id: String?) -> TranscriptPin {
        var p = TranscriptPin()
        guard let id else { return p }
        switch tool {
        case "kimi" where AgentSessionLocator.isKimiSessionID(id): p.kimiSession = id
        case "grok" where AgentSessionLocator.isConversationUUID(id): p.grokSession = id
        case "codex" where AgentSessionLocator.isConversationUUID(id): p.codexSession = id
        case "omp" where AgentSessionLocator.isConversationUUID(id): p.ompSession = id
        default: break
        }
        return p
    }

    /// A Kimi tab whose session isn't pinned yet: the session its process
    /// names on its command line (`-S session_…`) when it does; else only
    /// a journal no other session owns, and — for a fresh start (no resume
    /// flag) — one begun by this run (`since`: when the process started).
    static func kimiUnpinned(argsSession: String?, resumed: Bool, since: Int,
                             exclude: [String]) -> TranscriptPin {
        var p = TranscriptPin()
        if let id = argsSession, AgentSessionLocator.isKimiSessionID(id) {
            p.kimiSession = id
            return p
        }
        p.kimiExclude = exclude.filter(AgentSessionLocator.isKimiSessionID)
        if !resumed, since > 0 { p.kimiCreatedSince = since - 2 }
        return p
    }
}

/// Builds the guest-shell block that finds the newest session transcript a
/// coding agent wrote for a working directory — one fragment per tool's
/// on-disk store. Shared by the macOS engine and the fat client's iOS shim
/// (both tail live transcripts over their respective transports).
enum AgentSessionLocator {
    /// The epoch a `find -newermt @<epoch>` floor is written as. "No floor"
    /// (0: a resumed agent, an unknown foreground process) and anything else
    /// in 1970's first day become 1970-01-02 UTC — still older than any real
    /// file, but a date BSD find parses in every time zone. A Bromure Sidecar
    /// runs these commands through a `find` shim that turns `@0` into a LOCAL
    /// date ("1969-12-31 19:00:00" west of Greenwich), which macOS find
    /// rejects ("Can't parse date/time"): every lookup printed nothing, and a
    /// resumed session's chat never found its transcript.
    nonisolated static func findEpoch(_ since: Int) -> Int { max(since, 86_400) }

    /// The cwd as it may be spliced between single quotes in a shell line:
    /// trailing slashes stripped, nil when it has characters we won't quote.
    /// Letters of any script pass (a folder named "请用…-1004-2143" read no
    /// transcript at all when this was ASCII-only); in ASCII only the safe
    /// set does, and no control or line-separator character anywhere —
    /// the path is spliced between single and double quotes alike.
    nonisolated static func sanitized(guestCwd: String) -> String? {
        var path = guestCwd
        while path.count > 1 && path.hasSuffix("/") { path = String(path.dropLast()) }
        let allowed = Set<Character>("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
            + "0123456789-_./+ ")
        let unsafe = CharacterSet.controlCharacters.union(.newlines).union(.illegalCharacters)
        guard !path.isEmpty, path.unicodeScalars.allSatisfy({ u in
            u.isASCII ? allowed.contains(Character(u)) : !unsafe.contains(u)
        }) else { return nil }
        return path
    }

    /// The block that sets `$d` (logical cwd) / `$r` (resolved cwd) and
    /// leaves the newest matching session file in `$f` (empty when none).
    /// `agent` is a canonical `BromureIcons` agent kind; nil (or a tool
    /// without a known store) probes every store and takes the newest
    /// match — a session's directory belongs to whichever tool ran there,
    /// so at most one store matches in practice, and if several do
    /// (claude yesterday, codex today) the newest write is the live one.
    /// Every store keys off BOTH paths: the CLIs resolve symlinks (a
    /// folder share is a symlink into /mnt/bromure-share-N), while the
    /// caller's tab knows the logical path.
    nonisolated static func locateBlock(path: String, since: Int,
                                        agent: String?, kimiCreatedSince: Int? = nil,
                                        kimiExclude: [String] = []) -> String {
        var cmd = "d='\(path)'; r=$(readlink -f \"$d\" 2>/dev/null || printf %s \"$d\"); "
        switch agent {
        case "claude": cmd += claudeFragment(path: path, since: since, into: "f")
        case "codex": cmd += codexFragment(since: since, into: "f")
        case "grok": cmd += grokFragment(path: path, since: since, into: "f")
        case "kimi": cmd += kimiFragment(since: since, createdSince: kimiCreatedSince,
                                         exclude: kimiExclude, into: "f")
        case "omp": cmd += ompFragment(since: since, into: "f")
        default:
            cmd += claudeFragment(path: path, since: since, into: "tc")
            cmd += codexFragment(since: since, into: "tx")
            cmd += grokFragment(path: path, since: since, into: "tg")
            cmd += kimiFragment(since: since, into: "tk")
            cmd += ompFragment(since: since, into: "to")
            cmd += "set --; for c in \"$tc\" \"$tx\" \"$tg\" \"$tk\" \"$to\"; do "
                + "[ -n \"$c\" ] && set -- \"$@\" \"$c\"; done; "
                + "f=\"\"; [ $# -gt 0 ] && f=$(ls -t \"$@\" 2>/dev/null | head -1); "
        }
        return cmd
    }

    /// Each fragment assumes `$d`/`$r` are set and leaves its best
    /// candidate (newest matching file, mtime-filtered by `since`) in the
    /// shell variable `varName`. All failures are silenced: a missing
    /// store is simply no candidate.

    /// Claude Code: ~/.claude/projects/<encoded-cwd>/<session>.jsonl, the
    /// dir encoded by flattening EVERY non-alphanumeric to '-'. The
    /// host-side '/'- and './'-only encodings are kept so transcripts of
    /// older sessions stay findable.
    nonisolated static func claudeFragment(path: String, since: Int,
                                           into varName: String) -> String {
        let enc1 = path.replacingOccurrences(of: "/", with: "-")
        let enc2 = path.replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        let legacy = (enc1 == enc2 ? [enc1] : [enc1, enc2])
            .map { "\"$HOME/.claude/projects/\($0)\"" }.joined(separator: " ")
        return "e1=$(printf %s \"$d\" | tr -c 'a-zA-Z0-9' '-'); "
            + "e2=$(printf %s \"$r\" | tr -c 'a-zA-Z0-9' '-'); "
            + "\(varName)=$(find \"$HOME/.claude/projects/$e1\" \"$HOME/.claude/projects/$e2\" "
            + "\(legacy) -maxdepth 1 -name '*.jsonl' -newermt @\(AgentSessionLocator.findEpoch(since)) "
            + "2>/dev/null | sort -u | xargs -r ls -t 2>/dev/null | head -1); "
    }

    /// Codex CLI: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl, date-keyed
    /// rather than cwd-keyed — but line 1 (session_meta) records the cwd,
    /// so grep the newest files' heads for it. The candidate cap keeps the
    /// probe cheap; beyond ~2 dozen rollouts the one we want is stale
    /// anyway (`since` already floors the search).
    nonisolated static func codexFragment(since: Int, into varName: String) -> String {
        "\(varName)=\"\"; for c in $(find \"$HOME/.codex/sessions\" "
            + "-name 'rollout-*.jsonl' -newermt @\(AgentSessionLocator.findEpoch(since)) 2>/dev/null "
            + "| xargs -r ls -t 2>/dev/null | head -24); do "
            + "head -c 8192 \"$c\" 2>/dev/null "
            + "| grep -qF -e \"\\\"cwd\\\":\\\"$d\\\"\" -e \"\\\"cwd\\\":\\\"$r\\\"\" "
            + "&& { \(varName)=\"$c\"; break; }; done; "
    }

    /// Grok CLI: ~/.grok/sessions/<pct-encoded-cwd>/<uuid>/updates.jsonl.
    /// The logical path is encoded host-side (the rule is RFC 3986 with an
    /// empty safe set); the resolved path can only be encoded guest-side —
    /// python3 is guaranteed in the guest (bromure-agentd runs on it).
    nonisolated static func grokFragment(path: String, since: Int,
                                         into varName: String) -> String {
        "g1=\"$HOME/.grok/sessions/\(grokPercentEncode(path))\"; g2=\"\"; "
            + "if [ \"$r\" != \"$d\" ]; then "
            + "ge=$(python3 -c 'import urllib.parse,sys;"
            + "print(urllib.parse.quote(sys.argv[1],safe=\"\"))' \"$r\" 2>/dev/null); "
            + "[ -n \"$ge\" ] && g2=\"$HOME/.grok/sessions/$ge\"; fi; "
            + "\(varName)=$(find \"$g1\" ${g2:+\"$g2\"} -maxdepth 2 -name updates.jsonl "
            + "-newermt @\(AgentSessionLocator.findEpoch(since)) 2>/dev/null | sort -u | xargs -r ls -t 2>/dev/null "
            + "| head -1); "
    }

    /// Kimi Code: ~/.kimi-code/sessions/wd_<slug>_<hash12>/session_*/
    /// agents/main/wire.jsonl — slug is the lowercased basename with runs
    /// of anything outside [a-z0-9._-] collapsed to '-' (trimmed, first 40
    /// chars), hash the first 12 hex of SHA-256 of the full path. Both are
    /// recomputed guest-side; a slug-only glob backstops hash-rule drift.
    /// Main-agent journals only — subagent files (agents/agent-N) would
    /// otherwise win the mtime race while subagents work. The bare
    /// `wire.jsonl` alternative covers v1-engine sessions (journal at the
    /// session root).
    /// `createdSince` (epoch seconds): only a journal Kimi BEGAN at or after
    /// it counts — its first record (`metadata`) carries `created_at` in ms.
    /// The mtime floor alone let the previous conversation in the folder
    /// stand in for a just-launched one: interactive Kimi creates its
    /// session only at the first prompt, seconds after the process starts,
    /// and an older session still being written (another tab) passes any
    /// mtime test (B72). A journal without the field (an older engine) is
    /// judged by mtime alone.
    /// `exclude`: Kimi session ids other sessions own — their journals are
    /// never a candidate, however recently written.
    nonisolated static func kimiFragment(since: Int, createdSince: Int? = nil,
                                         exclude: [String] = [], into varName: String) -> String {
        let pick: String
        let candidates = kimiCandidates(since: since) + kimiExcludeFilter(exclude)
        if let createdSince {
            pick = "kc=$(" + candidates + "); \(varName)=\"\"; "
                + "for c in $kc; do ca=$(head -c 1024 \"$c\" 2>/dev/null "
                + "| grep -o '\"created_at\":[0-9]*' | head -1 | cut -d: -f2); "
                + "if [ -z \"$ca\" ] || [ \"$ca\" -ge \(max(0, createdSince) * 1000) ]; then "
                + "\(varName)=\"$c\"; break; fi; done; "
        } else {
            pick = "\(varName)=$(" + candidates + " | head -1); "
        }
        return kimiBucketVars + pick
    }

    /// A pipeline stage dropping the journals of the given sessions (their
    /// ids are a fixed shape, so they're safe to splice); empty for none.
    nonisolated static func kimiExcludeFilter(_ ids: [String]) -> String {
        let safe = ids.filter(isKimiSessionID)
        guard !safe.isEmpty else { return "" }
        return " | grep -v -F " + safe.map { "-e '/\($0)/'" }.joined(separator: " ")
    }

    /// Kimi Code 2.1's `slugifyWorkDirName` (workdir-slug.ts), exactly:
    /// lowercased, every run of characters outside `[a-z0-9._-]` one "-"
    /// (letters of other scripts and accented ones included — "café" is
    /// "caf", "请用中文回答-1004-2143" is "1004-2143"), dashes trimmed, cut
    /// to 40, trimmed again; nothing left (or "." / "..") is "workspace".
    nonisolated static func kimiWorkDirSlug(_ name: String) -> String {
        var out = ""
        var inRun = false
        for u in name.lowercased().unicodeScalars {
            let keep = (u.value >= 0x61 && u.value <= 0x7A) || (u.value >= 0x30 && u.value <= 0x39)
                || u == "." || u == "_" || u == "-"
            if keep { out.unicodeScalars.append(u); inRun = false }
            else if !inRun { out.append("-"); inRun = true }
        }
        func trimDashes(_ s: String) -> String {
            String(s.drop(while: { $0 == "-" }).reversed().drop(while: { $0 == "-" }).reversed())
        }
        let slug = trimDashes(String(trimDashes(out).prefix(40)))
        return slug.isEmpty || slug == "." || slug == ".." ? "workspace" : slug
    }

    /// Kimi's session bucket for a working directory (`encodeWorkDirKey`):
    /// `wd_<slug of the basename>_<first 12 hex of SHA-256 of the path>`,
    /// trailing slashes dropped.
    nonisolated static func kimiWorkDirKey(_ path: String) -> String {
        var p = path.replacingOccurrences(of: "\\", with: "/")
        while p.hasSuffix("/") { p.removeLast() }
        let base = p.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? p
        let hex = SHA256.hash(data: Data(p.utf8)).map { String(format: "%02x", $0) }.joined()
        return "wd_\(kimiWorkDirSlug(base))_\(hex.prefix(12))"
    }

    /// `$kb`/`$kh`/`$kr`: the workspace bucket's slug and hashes for `$d`/`$r`
    /// (`kimiWorkDirKey`, byte-wise in the C locale: each run of non-ASCII
    /// bytes is one "-", as each run of such characters is in Kimi's rule).
    nonisolated static let kimiBucketVars =
        "kb=$(basename \"$d\" | LC_ALL=C tr 'A-Z' 'a-z' "
            + "| LC_ALL=C sed -E 's/[^a-z0-9._-]+/-/g;s/^-+//;s/-+$//' "
            + "| cut -c1-40 | sed -E 's/-+$//'); "
            + "case \"$kb\" in ''|.|..) kb=workspace;; esac; "
            + "kh=$(printf %s \"$d\" | sha256sum | cut -c1-12); "
            + "kr=$(printf %s \"$r\" | sha256sum | cut -c1-12); "

    /// The bucket's main-agent journals touched since `since`, newest first.
    private nonisolated static func kimiCandidates(since: Int) -> String {
        "find \"$HOME/.kimi-code/sessions/wd_${kb}_$kh\" "
            + "\"$HOME/.kimi-code/sessions/wd_${kb}_$kr\" "
            + "\"$HOME/.kimi-code/sessions/wd_${kb}_\"* "
            + "\\( -path '*/agents/main/wire.jsonl' "
            + "-o \\( -name wire.jsonl ! -path '*/agents/*' \\) \\) "
            + "-newermt @\(AgentSessionLocator.findEpoch(since)) 2>/dev/null | sort -u "
            + "| xargs -r ls -t 2>/dev/null"
    }

    /// A Kimi session id as its store names the session's folder
    /// ("session_<uuid>") — what `kimi -S` resumes and what pins a
    /// session's transcript.
    nonisolated static func isKimiSessionID(_ s: String) -> Bool {
        s.hasPrefix("session_") && s.count == 44 && UUID(uuidString: String(s.dropFirst(8))) != nil
    }

    /// A conversation id as Grok and Codex name their files: a UUID, in
    /// its canonical 36-character form (safe to splice into a glob).
    nonisolated static func isConversationUUID(_ s: String) -> Bool {
        s.count == 36 && UUID(uuidString: s) != nil
    }

    /// `$varName` = Grok session `id`'s transcript, whatever folder it's under.
    nonisolated static func grokPinnedFragment(id: String, into varName: String) -> String {
        guard isConversationUUID(id) else { return "" }
        return "\(varName)=$(ls -t \"$HOME\"/.grok/sessions/*/\(id)/updates.jsonl 2>/dev/null | head -1); "
    }

    /// `$varName` = Codex conversation `id`'s rollout, whatever day it began.
    nonisolated static func codexPinnedFragment(id: String, into varName: String) -> String {
        guard isConversationUUID(id) else { return "" }
        return "\(varName)=$(find \"$HOME/.codex/sessions\" -name 'rollout-*\(id).jsonl' 2>/dev/null "
            + "| xargs -r ls -t 2>/dev/null | head -1); "
    }

    /// `$varName` = omp session `id`'s file, whatever folder it's under.
    nonisolated static func ompPinnedFragment(id: String, into varName: String) -> String {
        guard isConversationUUID(id) else { return "" }
        return "\(varName)=$(ls -t \"${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}\"/sessions/*/*_\(id).jsonl 2>/dev/null | head -1); "
    }

    /// The Kimi session id in a journal's path, nil when it isn't one.
    nonisolated static func kimiSessionID(inPath path: String) -> String? {
        path.split(separator: "/").map(String.init).first(where: isKimiSessionID)
    }

    /// `$varName` = the main journal of Kimi session `id`, wherever its
    /// workspace bucket is — the session's own file, no floor needed.
    nonisolated static func kimiPinnedFragment(id: String, into varName: String) -> String {
        guard isKimiSessionID(id) else { return "" }
        return "\(varName)=$(ls -t \"$HOME\"/.kimi-code/sessions/wd_*/\(id)/agents/main/wire.jsonl "
            + "\"$HOME\"/.kimi-code/sessions/wd_*/\(id)/wire.jsonl 2>/dev/null | head -1); "
    }

    /// omp (Oh My Pi): ${PI_CODING_AGENT_DIR:-~/.omp/agent}/sessions/<dir>/…jsonl
    /// where <dir> encodes the run's cwd with omp v18's scoped rules
    /// (session-paths.ts `getDefaultSessionDirName`):
    ///   • under $HOME:  "-" + the home-RELATIVE path flattened
    ///     (~/proj → -proj, $HOME itself → -)
    ///   • under /tmp:   "-tmp" + the tmp-relative path flattened
    ///     (/tmp/x → -tmp-x)
    ///   • elsewhere:    "--" + absolute path (leading / stripped) flattened + "--"
    ///     (/mnt/share/x → --mnt-share-x--)
    /// A full-path flatten (the old rule here) only coincided with the /tmp
    /// form, so home-dir projects never matched — "No transcript" for every
    /// real omp session. The transcript is the newest `*.jsonl` directly
    /// inside the dir; the logical and readlink-resolved paths are both tried
    /// (a worktree cwd may be a symlink).
    nonisolated static func ompFragment(since: Int, into varName: String) -> String {
        // POSIX-sh encoder, inlined twice (fragments concatenate with other
        // agents' probes, so no function definitions / reused temp names).
        func enc(_ src: String, into v: String) -> String {
            "if [ \"$\(src)\" = \"$HOME\" ]; then \(v)=-; "
            + "elif [ \"${\(src)#$HOME/}\" != \"$\(src)\" ]; then "
            + "\(v)=\"-$(printf %s \"${\(src)#$HOME/}\" | tr /: -)\"; "
            + "elif [ \"$\(src)\" = /tmp ]; then \(v)=-tmp; "
            + "elif [ \"${\(src)#/tmp/}\" != \"$\(src)\" ]; then "
            + "\(v)=\"-tmp-$(printf %s \"${\(src)#/tmp/}\" | tr /: -)\"; "
            + "else \(v)=\"--$(printf %s \"${\(src)#/}\" | tr /: -)--\"; fi; "
        }
        // omp doesn't always keep the tab's folder as its own cwd (it has been
        // seen running in /tmp while its tab sat in the home), so when the
        // folder-keyed store is empty fall back to the newest omp session
        // anywhere that's newer than the floor — the floor is the agent's
        // own start time, so that file is this agent's.
        return "ob=\"${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}/sessions\"; "
            + enc("d", into: "os1") + enc("r", into: "os2")
            + "\(varName)=$(find \"$ob/$os1\" \"$ob/$os2\" -maxdepth 1 -name '*.jsonl' "
            + "-newermt @\(AgentSessionLocator.findEpoch(since)) 2>/dev/null | sort -u | xargs -r ls -t 2>/dev/null "
            + "| head -1); "
            + "[ -z \"$\(varName)\" ] && [ \(since) -gt 0 ] && \(varName)=$(find \"$ob\" -mindepth 2 -maxdepth 2 "
            + "-name '*.jsonl' -newermt @\(AgentSessionLocator.findEpoch(since)) 2>/dev/null | xargs -r ls -t 2>/dev/null | head -1); "
    }

    /// The tab's folder and the transcript floor for its agent, as the
    /// guest reports them: "<cwd>\n<epoch floor>". The floor is the agent
    /// process's start (a newer transcript is this agent's; an older one a
    /// previous run's) — 0 for a resumed agent, which reattaches an older
    /// file, or when the foreground process can't be told. Shared by the
    /// desktop chat and the mobile room cells.
    nonisolated static func floorProbeCommand(window: Int) -> String {
        "i=\(window); "
        + "cwd=$(tmux -u display-message -p -t bromure:$i '#{pane_current_path}' 2>/dev/null); "
        + "tty=$(tmux display-message -p -t bromure:$i '#{pane_tty}' 2>/dev/null); "
        // The foreground process — but never the tab's SHELL: an agent
        // launched by the managed .bashrc shares bash's foreground group,
        // so bash reads as "+" too (and first, by pid). Its start time is
        // the tab's, not the agent's, and its args carry no resume flag —
        // a `--continue` relaunched in a fresh tab was floored out. Take
        // the first "+" process that isn't a shell; a shell only if
        // nothing else is in the foreground. Still the FIRST such process
        // (pid order), so a short-lived tool child of the agent doesn't
        // win either.
        + "pid=$(ps -t \"${tty#/dev/}\" -o pid=,stat=,args= 2>/dev/null | awk '"
        + "$2 ~ /\\+/ { if (first == \"\") first = $1; "
        + "if (!found && $3 !~ /(^|\\/)-?(bash|sh|zsh|dash|fish|login)$/) { print $1; found = 1 } } "
        + "END { if (!found) print first }'); "
        + "et=$(ps -o etimes= -p \"$pid\" 2>/dev/null | tr -d ' '); "
        + "if [ -n \"$et\" ]; then s=$(( $(date +%s) - et )); else s=0; fi; ps0=$s; "
        // Resuming reattaches an older transcript → don't floor it out. Match
        // only the long flags: the args string also contains the (free-text)
        // prompt, so short flags / bare words like `-c` or `resume` there
        // would false-positive and resurrect a stale session on a FRESH run.
        + "a=$(ps -ww -o args= -p \"$pid\" 2>/dev/null); "
        + "case \"$a\" in "
        + "*--resume*|*--continue*|*--restore*) s=0;; "
        + "esac; "
        // A Kimi session the process names (`-S session_…`): the tab's own
        // conversation, whatever else is being written in its folder.
        + "ks=$(printf %s \"$a\" | grep -o -E 'session_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' | head -1); "
        // Resumed (a short flag too — Kimi's -c / -S): an older journal is
        // its own, so no "begun by this run" test.
        + "rs=0; case \" $a \" in *' -c '*|*' -S '*|*' --session '*|*' --session='*|*' --continue'*|*' --resume'*) rs=1;; esac; "
        // Last: when the process itself started, resumed or not — a turn
        // the transcript shows open from before then was interrupted.
        + "printf '%s\\n%s\\n%s\\n%s\\n%s\\n' \"$cwd\" \"$s\" \"$ks\" \"$rs\" \"$ps0\""
    }

    /// `floorProbeCommand`'s answer: the tab's cwd, its floor (epoch
    /// seconds), the Kimi session its process names (if any) and whether
    /// the process resumed a conversation. nil when unreadable.
    nonisolated static func parseFloorProbe(_ out: String?)
        -> (cwd: String, since: Int, kimiSession: String?, resumed: Bool, started: Int)? {
        let lines = (out ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2 else { return nil }
        let cwd = lines[0].trimmingCharacters(in: .whitespaces)
        guard !cwd.isEmpty else { return nil }
        let field = { (i: Int) in lines.count > i ? lines[i].trimmingCharacters(in: .whitespaces) : "" }
        let ks = field(2)
        let since = Int(field(1)) ?? 0
        return (cwd, since, isKimiSessionID(ks) ? ks : nil, field(3) == "1", Int(field(4)) ?? since)
    }

    /// Sets `$varName` to the transcript the agent in tmux window `window`
    /// recorded for itself (agent-status.sh, per window index), or empty
    /// when that record isn't this tab's. The record's second line names
    /// the pane and guest boot it came from; a mismatch means the index was
    /// reused — the last tab closed and a new one took its number, or the
    /// machine booted fresh — and the path is the previous occupant's. A
    /// one-line record is ignored too: the host re-stages agent-status.sh
    /// every boot and it always stamps, so such a file predates the stamp
    /// and survived on /home (it pinned two room cells to one old file).
    /// `window` is a shell word: a number, or `$i` inside a loop.
    /// `$f` = the transcript the window's agent pinned, when it's this
    /// agent's (newer than the floor). A pin whose file doesn't exist yet —
    /// a fresh Claude that hasn't had a prompt — sets `$pe`: the chat stays
    /// empty rather than falling back to "the newest file in the folder",
    /// which in a folder shared with a live session is THAT session's.
    nonisolated static func pinnedPick(window: Int, since: Int) -> String {
        pinnedTranscriptBlock(window: String(window), into: "c")
            + "pe=\"\"; if [ -n \"$c\" ]; then if [ -f \"$c\" ]; then "
            + "[ -n \"$(find \"$c\" -newermt @\(AgentSessionLocator.findEpoch(since)) 2>/dev/null)\" ] && f=\"$c\"; "
            + "else pe=1; fi; fi; "
    }

    nonisolated static func pinnedTranscriptBlock(window: String, into varName: String) -> String {
        "pp=\"$HOME/.bromure/transcript-\(window).path\"; \(varName)=\"\"; "
            + "if [ -f \"$pp\" ]; then \(varName)=$(sed -n 1p \"$pp\" 2>/dev/null); "
            + "pk=$(sed -n 2p \"$pp\" 2>/dev/null); "
            + "if [ -z \"$pk\" ] || [ \"$pk\" != \"$(tmux display-message -p -t bromure:\(window) '#{pane_id}' 2>/dev/null) "
            + "$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)\" ]; then \(varName)=\"\"; fi; fi; "
    }

    /// RFC 3986 percent-encoding with an empty safe set ('/' included) —
    /// the rule Grok uses to name a cwd's session folder.
    nonisolated static func grokPercentEncode(_ s: String) -> String {
        let unreserved = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }
}

// MARK: - Agent liveness in a tab

/// Is a coding agent running in a tmux tab? Asked of every process on the
/// pane's tty — never `pane_current_command` or the tab's label. An agent
/// a tab's .bashrc starts during shell startup (before job control) shares
/// the shell's process group, so tmux names the shell for as long as the
/// agent runs; an agent under an interpreter reads as the interpreter; and
/// a task tab's label is its title. Judged "a shell" on any of those, a
/// working agent was killed and relaunched.
enum AgentPaneProbe {
    enum State: Equatable, Sendable {
        /// An agent is running in the pane (its kind as seen).
        case running(String)
        /// Only the shell (and programs that aren't agents) left.
        case shell
        /// No such window.
        case gone
    }

    /// Agent names as they show in a process's arguments (path or
    /// interpreter script), whole words only — "omp" inside "compile" is no
    /// agent.
    nonisolated static let agentNames = "claude|codex|kimi|grok|omp|aider|goose|opencode|gemini"
    nonisolated static let shellLines = "^-?([^ ]*/)?(bash|sh|zsh|dash|fish|login|tmux)( |$)"

    /// One line: `pane gone`, `pane none`, or `pane <agent>`.
    nonisolated static func command(window: Int) -> String {
        "t=$(tmux display-message -p -t bromure:\(window) '#{pane_tty}' 2>/dev/null); "
            + "if [ -z \"$t\" ]; then echo 'pane gone'; exit 0; fi; "
            + "a=$(ps -t \"${t#/dev/}\" -o args= 2>/dev/null | \(agentFilter)); "
            + "echo \"pane ${a:-none}\""
    }

    /// Process argument lines in, the first agent's name out (nothing when
    /// only shells and other programs run).
    nonisolated static var agentFilter: String {
        "grep -v -E '\(shellLines)' "
            + "| grep -E -o -m1 '(^|[^A-Za-z0-9])(\(agentNames))([^A-Za-z]|$)' "
            + "| head -1 | tr -cd 'a-z'"
    }

    /// nil when the answer isn't one (the guest couldn't be asked).
    nonisolated static func parse(_ out: String) -> State? {
        for raw in out.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("pane") else { continue }
            let v = String(line.dropFirst(4)).lowercased().filter { $0.isLetter }
            switch v {
            case "gone": return .gone
            case "", "none": return .shell
            default: return .running(v)
            }
        }
        return nil
    }

    /// What delivering a message to a task's conversation does.
    enum Route: Equatable, Sendable {
        /// The agent is running in this window: type it in.
        case type(window: Int)
        /// No agent to type into: resume the conversation in a fresh tab,
        /// closing this window first (only ever one seen with a bare shell).
        case relaunch(closeWindow: Int?)
        /// The tab is there but couldn't be asked — never kill it on a guess.
        case undecided
    }

    nonisolated static func route(window: Int?, state: State?) -> Route {
        guard let window else { return .relaunch(closeWindow: nil) }
        switch state {
        case .running?: return .type(window: window)
        case .shell?: return .relaunch(closeWindow: window)
        case .gone?: return .relaunch(closeWindow: nil)
        case nil: return .undecided
        }
    }

    /// `command(window:)` plus the launcher's death marker: the last
    /// "exited with status N" line in the pane's recent output (printed by
    /// the worktree launcher when the agent dies — Profile's .bashrc hook).
    nonisolated static func launchCommand(window: Int) -> String {
        command(window: window) + "; "
            + "tmux capture-pane -p -J -t bromure:\(window) -S -120 2>/dev/null "
            + "| grep -a -o 'exited with status [0-9]*' | tail -1"
    }

    /// The agent's exit status from the launcher's marker in `out`, nil
    /// when there is none.
    nonisolated static func exitStatus(_ out: String) -> Int? {
        var found: Int? = nil
        for raw in out.split(whereSeparator: \.isNewline) {
            guard let r = raw.range(of: "exited with status ") else { continue }
            let digits = raw[r.upperBound...].prefix { $0.isNumber }
            if let n = Int(digits) { found = n }
        }
        return found
    }

    /// What a launch watch makes of one probe.
    enum LaunchOutcome: Equatable, Sendable {
        /// The agent is running in this window.
        case up(window: Int)
        /// The agent died (or never ran): its exit status when the launcher
        /// printed one.
        case died(status: Int?)
        /// Not seen up within the time allowed.
        case timedOut
    }

    /// The launch-watch verdict so far: running → up; a death marker with
    /// only a shell left → died at once; a bare shell for `shellProbesToFail`
    /// probes in a row after `grace` seconds → died. nil = keep watching.
    nonisolated static let shellProbesToFail = 4
    nonisolated static func launchVerdict(state: State?, exitStatus: Int?, window: Int,
                                          elapsed: TimeInterval, grace: TimeInterval,
                                          shellStreak: Int) -> LaunchOutcome? {
        switch state {
        case .running?: return .up(window: window)
        case .shell?:
            if let exitStatus { return .died(status: exitStatus) }
            if elapsed >= grace && shellStreak >= shellProbesToFail { return .died(status: nil) }
            return nil
        default: return nil
        }
    }

    /// Agents a task tab starts with no message on the command line (Kimi
    /// only takes one in its one-shot mode, which exits after the turn): the
    /// host types it in once the agent is up.
    nonisolated static func typesOpeningMessage(_ tool: Profile.Tool) -> Bool { tool == .kimi }
}

// MARK: - Guarded host → tmux typing

/// Where host-typed text goes, and what must hold there right before every
/// keystroke batch. A tmux window INDEX is reused the moment its tab
/// closes — a task's resume brief once landed in another task's bare bash
/// prompt that had taken the number — so a target is resolved IN THE GUEST,
/// at send time, to the window's stable id (`@N`), and the window's own
/// markers (`@worktree`, `@display`, the id itself) must still name the
/// intended task or session. On top of that the pane's FOREGROUND program
/// must be what the text is for: an agent for a message (never a shell —
/// bash would run it, backticks and all), a shell for a relaunch command.
struct PaneTarget: Equatable, Sendable, Codable {
    enum Ref: Equatable, Sendable, Codable {
        /// `bromure:<index>` — what a pane roster knows.
        case index(Int)
        /// A tmux window id ("@12"): stable for the window's whole life.
        case windowID(String)
        /// The window tagged `@worktree <branch>` (a task's tab).
        case worktree(String)
    }
    enum Foreground: Equatable, Sendable, Codable {
        /// An agent must be in the pane's foreground process group.
        case agent
        /// Only a shell (no agent) — for typing a command line.
        case shell
    }
    var ref: Ref
    var expectWorktree: String? = nil
    var expectDisplay: String? = nil
    /// A second `@display` that also names the intended window: the
    /// session's current title on a Bromure Sidecar machine, whose rename
    /// (and resume) rewrites the tab's `@display` while the session's
    /// `launchDisplay` keeps the old name — every chat send to a renamed
    /// Sidecar session was refused as somebody else's tab. nil on VMs.
    var expectDisplayAlt: String? = nil
    var expectWindowID: String? = nil
    var foreground: Foreground = .agent

    static func index(_ i: Int, foreground: Foreground = .agent) -> PaneTarget {
        PaneTarget(ref: .index(i), foreground: foreground)
    }

    /// A board task's tab: found by its branch, and still carrying it.
    static func task(branch: String, foreground: Foreground = .agent) -> PaneTarget {
        PaneTarget(ref: .worktree(branch), expectWorktree: branch, foreground: foreground)
    }

    /// A chat's tab (the composer, its approval and picker keys, a review
    /// draft): by the window's stable id when known — and then only that
    /// window — else its index, and in either case still carrying the
    /// markers it showed (`@display`, `@worktree`), with an agent in front.
    /// `alsoDisplay`: another name the tab may carry for this same session
    /// (`expectDisplayAlt` — a Sidecar session's current title).
    static func chat(window: Int, windowID: String?, display: String?, worktree: String?,
                     alsoDisplay: String? = nil,
                     foreground: Foreground = .agent) -> PaneTarget {
        let id = windowID.flatMap { PaneTypeGuard.isWindowID($0) ? $0 : nil }
        var t = PaneTarget(ref: id.map { .windowID($0) } ?? .index(window), foreground: foreground)
        t.expectWindowID = id
        if let d = display, !d.isEmpty {
            t.expectDisplay = d
            if let a = alsoDisplay, !a.isEmpty, a != d { t.expectDisplayAlt = a }
        }
        if let w = worktree, !w.isEmpty { t.expectWorktree = w }
        return t
    }
}

/// Why a guarded send typed nothing.
enum PaneRefusal: String, Equatable, Sendable {
    /// No such window (closed, or never resolved).
    case gone
    /// The window there now is somebody else's (marker mismatch).
    case identity
    /// A shell, not the agent, holds the pane's foreground.
    case shell
    /// An agent holds the pane where a shell was expected.
    case agent
}

enum PaneTypeGuard {
    /// Printed (with the reason) when a guard refused to type.
    nonisolated static let refusedMarker = "BROMURE_TYPE_REFUSED"

    /// What a command's output says about a refusal, nil when none.
    nonisolated static func refusal(in out: String) -> PaneRefusal? {
        guard let r = out.range(of: refusedMarker + " ") else { return nil }
        let word = out[r.upperBound...].prefix { $0.isLetter }
        return PaneRefusal(rawValue: String(word)) ?? .gone
    }

    /// A tmux window id as tmux prints it.
    nonisolated static func isWindowID(_ s: String) -> Bool {
        s.count >= 2 && s.first == "@" && s.dropFirst().allSatisfy(\.isNumber)
    }

    /// Single-quoted for sh.
    nonisolated static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Sets `$_bt` to the target's window id (empty when it can't be found).
    /// Every later step of the command targets "$_bt" — never the index
    /// again, which may name another window by then.
    nonisolated static func resolve(_ t: PaneTarget) -> String {
        switch t.ref {
        case .index(let i):
            return "_bt=$(tmux display-message -p -t bromure:\(i) '#{window_id}' 2>/dev/null); "
        case .windowID(let id):
            let q = isWindowID(id) ? quote(id) : "''"
            return "_bt=$(tmux display-message -p -t \(q) '#{window_id}' 2>/dev/null); "
        case .worktree(let b):
            // The newest window carrying the tag (an old dead tab of the
            // same task may linger a moment while a resume opens its new one).
            return "_bt=$(tmux list-windows -t bromure -F '#{window_id} #{@worktree}' 2>/dev/null "
                + "| awk -v b=\(quote(b)) '$2==b {w=$1} END {print w}'); "
        }
    }

    /// Shell words: process args → the first agent's name (empty for shells
    /// and other programs). Shells are recognized by path too
    /// ("/bin/bash -c … kimi" is a launcher, not Kimi).
    nonisolated static var shellArgs: String { AgentPaneProbe.shellLines }

    /// Defines `_bg`: true (exit 0) when the window `$_bt` is still the
    /// intended one and its foreground is what `t` wants; else prints the
    /// refusal and is false.
    nonisolated static func guardFunction(_ t: PaneTarget) -> String {
        func refuse(_ r: PaneRefusal) -> String { "{ echo '\(refusedMarker) \(r.rawValue)'; return 1; }" }
        var f = "_bg() { "
        f += "[ -n \"$_bt\" ] || \(refuse(.gone)); "
        f += "[ \"$(tmux display-message -p -t \"$_bt\" '#{window_id}' 2>/dev/null)\" = \"$_bt\" ] || \(refuse(.gone)); "
        if let id = t.expectWindowID {
            f += "[ \"$_bt\" = \(quote(id)) ] || \(refuse(.identity)); "
        }
        if let w = t.expectWorktree {
            f += "[ \"$(tmux display-message -p -t \"$_bt\" '#{@worktree}' 2>/dev/null)\" = \(quote(w)) ] || \(refuse(.identity)); "
        }
        if let d = t.expectDisplay {
            // A tab not named (yet) says nothing; a tab named otherwise is another's.
            f += "_bd=$(tmux display-message -p -t \"$_bt\" '#{@display}' 2>/dev/null); "
            let alt = t.expectDisplayAlt.map { " || [ \"$_bd\" = \(quote($0)) ]" } ?? ""
            f += "[ -z \"$_bd\" ] || [ \"$_bd\" = \(quote(d)) ]\(alt) || \(refuse(.identity)); "
        }
        // The pane's foreground process group: the processes whose group
        // is the tty's foreground group (an agent .bashrc starts before job
        // control shares the shell's group — still the foreground one).
        f += "_by=$(tmux display-message -p -t \"$_bt\" '#{pane_tty}' 2>/dev/null); "
        f += "[ -n \"$_by\" ] || \(refuse(.gone)); "
        // Every process, filtered to this tty in awk: `ps -t` with several
        // `-o` columns misprints on macOS (an attached Mac), and procps reads
        // a comma list after "=" as one header.
        f += "_ba=$(ps -A -o tty= -o tpgid= -o pgid= -o args= 2>/dev/null "
            + "| awk -v t=\"${_by#/dev/}\" '$1==t && $2==$3 { $1=\"\"; $2=\"\"; $3=\"\"; sub(/^ +/, \"\"); print }' "
            + "| grep -v -E '\(shellArgs)' "
            + "| grep -E -o -m1 '(^|[^A-Za-z0-9])(\(AgentPaneProbe.agentNames))([^A-Za-z]|$)' "
            + "| head -1 | tr -cd 'a-z'); "
        switch t.foreground {
        case .agent: f += "[ -n \"$_ba\" ] || \(refuse(.shell)); "
        case .shell: f += "[ -z \"$_ba\" ] || \(refuse(.agent)); "
        }
        f += "return 0; }; "
        return f
    }

    /// Resolve + guard, ready for `if _bg; then …; fi`.
    nonisolated static func prelude(_ t: PaneTarget) -> String {
        resolve(t) + guardFunction(t)
    }

    /// The text as it is typed: line breaks as LF only. A CR is Return to
    /// an agent's TUI — CRLF text (pasted from a web page or an office
    /// document) went in as several messages, cut at the first line.
    nonisolated static func normalizedText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// The literal send of `text` into "$_bt": as ONE PASTE — loaded into a
    /// tmux buffer from stdin and pasted with `paste-buffer -p` (bracketed,
    /// when the agent asked for it) `-r` (line breaks kept as LF, never
    /// turned into Return) `-d` (the buffer goes with it). Not `send-keys
    /// -l`: tmux refuses a command over 16 KB ("command too long" — the
    /// message vanished while the chat showed it sent), and keystrokes
    /// make every CR an Enter. The text travels base64 through the guest
    /// shell (no quoting ever reaches a shell) — inline, or from `staged`,
    /// a file `stageCommands` wrote (a text too big for one command line).
    nonisolated static func literalSend(_ text: String, staged: String? = nil) -> String {
        let source: String
        if let staged, isStagePath(staged) {
            source = "base64 -d < \(quote(staged))"
        } else {
            source = "echo \(Data(normalizedText(text).utf8).base64EncodedString()) | base64 -d"
        }
        return "{ _bb=bromure-msg-$$; \(source) | tmux load-buffer -b \"$_bb\" - "
            + "&& tmux paste-buffer -p -r -d -b \"$_bb\" -t \"$_bt\" "
            + "|| { tmux delete-buffer -b \"$_bb\" 2>/dev/null; false; }; }"
    }

    /// `text` with a space after it when it ends in a token an agent's
    /// composer completes — a path or a slash command ("… && ls /tmp"), an
    /// @-mention, a $skill. Grok fuzzy-matched the pasted "/tmp" against its
    /// slash commands and the submitting Enter took the popup's pick: the
    /// message went out as "ls /timestamps". After a space the token is
    /// finished and no popup stays open; agents trim the space. A message
    /// that IS one slash command ("/model") keeps its popup (Enter there
    /// runs that command). Idempotent.
    nonisolated static func completionSafe(_ text: String) -> String {
        let t = normalizedText(text)
        guard let end = t.last, !end.isWhitespace else { return text }
        let tokens = t.split(whereSeparator: \.isWhitespace)
        guard tokens.count >= 2, let last = tokens.last, let first = last.first else { return text }
        guard "/@$".contains(first) || last.contains("/") else { return text }
        return text + " "
    }

    /// Text longer than this (bytes) is staged in pieces before it's typed:
    /// one guest command line is one argv string, capped at 128 KB.
    nonisolated static let inlineLimit = 24 * 1024
    /// Base64 characters per staging command.
    nonisolated static let stageChunk = 64 * 1024

    nonisolated static func needsStaging(_ text: String) -> Bool {
        normalizedText(text).utf8.count > inlineLimit
    }

    /// A fresh path for a staged message (in the guest's /tmp).
    nonisolated static func newStagePath() -> String {
        "/tmp/bromure-msg-\(UUID().uuidString.lowercased()).b64"
    }

    nonisolated static func isStagePath(_ p: String) -> Bool {
        p.hasPrefix("/tmp/bromure-msg-") && p.hasSuffix(".b64")
            && p.dropFirst(5).allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
    }

    /// The guest commands that write `text` (base64) to `path`, each well
    /// under the per-argument cap.
    nonisolated static func stageCommands(_ text: String, path: String) -> [String] {
        guard isStagePath(path) else { return [] }
        let b64 = Data(normalizedText(text).utf8).base64EncodedString()
        var out: [String] = ["umask 077; : > \(quote(path))"]
        var i = b64.startIndex
        while i < b64.endIndex {
            let j = b64.index(i, offsetBy: stageChunk, limitedBy: b64.endIndex) ?? b64.endIndex
            out.append("printf %s \(b64[i..<j]) >> \(quote(path))")
            i = j
        }
        return out
    }

    /// What a guarded type prints when it held off because a menu or
    /// dialog is up in the tab (`menuFunction`): nothing more was typed.
    nonisolated static let heldMarker = "BROMURE_TYPE_HELD"
    /// What it prints once the text and its Enter went in. Anything else —
    /// no marker at all — is a failure (tmux refused it, the exec failed),
    /// never a success.
    nonisolated static let typedMarker = "BROMURE_TYPE_OK"

    /// Defines `_bm`: true while a menu, picker or approval dialog is up in
    /// "$_bt" — any agent's picker footer, or a highlighted numbered row
    /// (`AgentPhrases.menuOpenRegex`), in the bottom of the screen.
    nonisolated static var menuFunction: String {
        "_bm() { tmux capture-pane -p -t \"$_bt\" 2>/dev/null | tail -n 30 | tr '[:upper:]' '[:lower:]' "
            + "| grep -qE '\(AgentPhrases.menuOpenRegex)'; }; "
    }

    /// Guarded type + Enter: checked before the text and again before the
    /// Enter. Nothing is typed when the check fails (the refusal is printed).
    /// For an AGENT (a message), also never while one of its menus or
    /// dialogs is up — an approval picker takes a digit or Return as its
    /// answer ("1. Approve once"), and the rest of the text would go into
    /// the agent's queue — in the same command, right before the text and
    /// again before the Enter, so no check-then-type race: `heldMarker` is
    /// printed instead, for the caller to hold the message until the dialog
    /// closes. A shell command line (a relaunch) has no such dialog.
    /// `typedMarker` is printed once it all went in. `staged`: the text was
    /// written to that file first (`stageCommands`); removed at the end.
    nonisolated static func typeCommand(target: PaneTarget, text: String, staged: String? = nil) -> String {
        let send = literalSend(target.foreground == .agent ? completionSafe(text) : text, staged: staged)
        let enter = "tmux send-keys -t \"$_bt\" Enter && echo \(typedMarker)"
        var cmd: String
        switch target.foreground {
        case .shell:
            cmd = prelude(target)
                + "if _bg; then \(send) && sleep 1 && "
                + "if _bg; then \(enter); fi; fi"
        case .agent:
            cmd = prelude(target) + menuFunction + confirmFunctions
                + "if _bg; then if _bm; then echo \(heldMarker); "
                + "else \(send) && _bsettle && "
                + "if _bg; then if _bm; then echo \(heldMarker); else \(confirmedEnter); fi; fi; fi; fi"
        }
        if let staged, isStagePath(staged) { cmd += "; rm -f \(quote(staged))" }
        return cmd
    }

    /// What a guarded type prints when the text went in but its Enter never
    /// took — the screen didn't move after it, even on a second Enter (omp
    /// still folding a long paste into its "📄 #1 +182 lines" chip
    /// swallowed it). The text is still in the agent's input box.
    nonisolated static let unconfirmedMarker = "BROMURE_TYPE_UNCONFIRMED"

    /// `_bcap`: "$_bt"'s whole screen (an inline TUI's input box sits right
    /// under its content — near the top of a fresh pane). `_bsettle`: waits for the
    /// screen to hold still after a paste (a TUI collapsing a long one into
    /// a chip redraws for a while; an Enter sent into that is lost) — at
    /// least 0.9 s, at most ~6.5 s. `_bok`: true once the screen moved
    /// after the Enter (up to ~2.4 s) — an input box that took its message
    /// clears.
    nonisolated static var confirmFunctions: String {
        "_bcap() { tmux capture-pane -p -t \"$_bt\" 2>/dev/null; }; "
            + "_bsettle() { sleep 0.5; _bp=$(_bcap); _bi=0; while [ $_bi -lt 15 ]; do sleep 0.4; "
            + "_bc=$(_bcap); [ \"$_bc\" = \"$_bp\" ] && return 0; _bp=$_bc; _bi=$((_bi+1)); done; return 0; }; "
            + "_bok() { _bi=0; while [ $_bi -lt 8 ]; do sleep 0.3; [ \"$(_bcap)\" != \"$_b0\" ] && return 0; "
            + "_bi=$((_bi+1)); done; return 1; }; "
    }

    /// Enter, confirmed by the screen moving; once more if it didn't (and
    /// no menu came up meanwhile); `unconfirmedMarker` if it still didn't.
    nonisolated static var confirmedEnter: String {
        "_b0=$(_bcap); tmux send-keys -t \"$_bt\" Enter && "
            + "if _bok; then echo \(typedMarker); "
            + "elif _bg && ! _bm && _b0=$(_bcap) && tmux send-keys -t \"$_bt\" Enter && _bok; then echo \(typedMarker); "
            + "else echo \(unconfirmedMarker); fi"
    }

    /// Whether a guarded type went in but its Enter never took.
    nonisolated static func unconfirmed(in out: String) -> Bool { out.contains(unconfirmedMarker) }

    /// Whether a guarded type held off for an open menu or dialog.
    nonisolated static func held(in out: String) -> Bool { out.contains(heldMarker) }
    /// Whether a guarded type went all the way in (text and Enter).
    nonisolated static func typed(in out: String) -> Bool { out.contains(typedMarker) }

    /// What `runType` prints in place of the guest's verdict when the
    /// Enter didn't take but the agent's input box is EMPTY: the text never
    /// stayed there (the TUI dropped it, or took it after all, late) —
    /// never "in the input box".
    nonisolated static let droppedMarker = "BROMURE_TYPE_DROPPED"

    /// Whether a type's text isn't in the agent's box after its Enter
    /// didn't take (`droppedMarker`).
    nonisolated static func dropped(in out: String) -> Bool { out.contains(droppedMarker) }

    /// The bottom of "$_bt"'s screen with its escapes, for `AgentInputBox`.
    nonisolated static func boxProbeCommand(_ t: PaneTarget) -> String {
        resolve(t) + "[ -n \"$_bt\" ] && tmux capture-pane -p -e -t \"$_bt\" 2>/dev/null | tail -n 30"
    }

    /// Enter (confirmed, `confirmedEnter`) for text already in the box —
    /// unless a menu came up or the window stopped being the agent's.
    nonisolated static func enterCommand(_ t: PaneTarget) -> String {
        var t = t
        t.foreground = .agent
        return prelude(t) + menuFunction + confirmFunctions
            + "if _bg; then if _bm; then echo \(heldMarker); else \(confirmedEnter); fi; fi"
    }

    /// Whether the agent's input box still holds something after an Enter:
    /// a draft `AgentInputBox` reads, or omp's paste chip ("╰─ 📄 #1"),
    /// which it may draw in a colour the reader takes for a placeholder.
    nonisolated static func boxHolds(_ capture: String) -> Bool {
        if case .text = AgentInputBox.content(capture) { return true }
        // Escapes stripped: the band row's raw text.
        let plain = capture.replacingOccurrences(of: "\u{1B}\\[[0-9;:?]*[ -/]*[@-~]", with: "",
                                                 options: .regularExpression)
        let rows = plain.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let bar = rows.lastIndex(where: AgentInputBox.isStatusBar), bar + 1 < rows.count else { return false }
        let band = rows[(bar + 1)...].prefix(4).joined(separator: "\n")
        return band.contains("📄") || band.range(of: "\\+[0-9]+ lines", options: .regularExpression) != nil
    }

    /// The Enter of a type that said it went in, checked against what
    /// matters — the agent took the TURN: its input box is empty again. A
    /// screen that merely moved (omp finishing its paste chip as the Enter
    /// arrived, a status bar ticking) used to count as taken; the 21 KB
    /// paste then sat in the box unsent, and went out bundled with the next
    /// message. Text still there: Enter again (twice at most), then
    /// `unconfirmedMarker`. The guest's own "unconfirmed" with an EMPTY
    /// box: `droppedMarker` (nothing is waiting in the box). The box can't
    /// be read (no answer, an unknown TUI): the guest's verdict stands.
    nonisolated static func confirmTaken(target: PaneTarget, out: String,
                                         exec: (String) async -> String?,
                                         pause: UInt64 = 700_000_000) async -> String {
        guard typed(in: out) || unconfirmed(in: out) else { return out }
        var current = out
        for round in 0..<3 {
            if round > 0 || typed(in: current) { try? await Task.sleep(nanoseconds: pause) }
            guard let screen = await exec(boxProbeCommand(target)), !screen.isEmpty else { return current }
            guard boxHolds(screen) else {
                return typed(in: current) ? current : droppedMarker
            }
            guard round < 2 else { break }
            guard let again = await exec(enterCommand(target)) else { return current }
            if refusal(in: again) != nil || held(in: again) { return again }
            current = again
        }
        return unconfirmedMarker
    }

    /// Run `typeCommand` through `exec`, staging a long text first. The
    /// command's output (nil when the machine couldn't be asked, or a
    /// staging step failed — nothing typed then). For an agent, the Enter
    /// is then confirmed by the input box (`confirmTaken`).
    nonisolated static func runType(target: PaneTarget, text: String,
                                    exec: (String) async -> String?) async -> String? {
        guard let out = await typeOnce(target: target, text: text, exec: exec) else { return nil }
        guard target.foreground == .agent else { return out }
        return await confirmTaken(target: target, out: out, exec: exec)
    }

    private nonisolated static func typeOnce(target: PaneTarget, text: String,
                                             exec: (String) async -> String?) async -> String? {
        guard needsStaging(text) else { return await exec(typeCommand(target: target, text: text)) }
        let text = target.foreground == .agent ? completionSafe(text) : text
        let path = newStagePath()
        for step in stageCommands(text, path: path) {
            guard await exec(step) != nil else {
                _ = await exec("rm -f \(quote(path))")
                return nil
            }
        }
        return await exec(typeCommand(target: target, text: text, staged: path))
    }

    /// Named tmux keys into the target, one at a time with `beat` seconds
    /// between, each re-checked (`_bg`). A refusal stops the rest and the
    /// command fails (exit 1). Only key-name tokens pass (letters, digits,
    /// `-`); anything else is dropped, never interpolated.
    nonisolated static func keysCommand(target: PaneTarget, keys: [String], beat: Double = 0.4) -> String {
        let safe = keys.filter { k in !k.isEmpty && k.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }
        guard !safe.isEmpty else { return "" }
        let steps = safe.map { "_bg && tmux send-keys -t \"$_bt\" \($0)" }
        return prelude(target) + "{ " + steps.joined(separator: " && sleep \(beat) && ") + "; }"
    }

    /// True (exit 0) while an agent's option picker is on screen in "$_bt".
    nonisolated static let pickerVisibleInTarget =
        "tmux capture-pane -p -t \"$_bt\" 2>/dev/null | grep -qE 'Enter to (select|confirm)'"

    /// An AskUserQuestion picker's key sequence into the target: digits
    /// literally and only while the picker is still on screen (it can
    /// instant-commit a key early), named keys as tmux key names, a beat
    /// between. Every key re-checks the window's identity and the agent in
    /// front (`_bg`); a refusal types nothing more and fails the command.
    /// Empty when no key is valid.
    nonisolated static func answerKeysCommand(target: PaneTarget, keys: [String]) -> String {
        let named = ["Enter", "Right", "Left", "Down", "Up", "Tab", "Space"]
        let steps = keys.compactMap { k -> String? in
            let isDigit = k.count == 1 && k.first!.isNumber
            guard isDigit || named.contains(k) else { return nil }
            let send = "tmux send-keys -t \"$_bt\" \(isDigit ? "-l " : "")\(k)"
            return isDigit ? "{ _bg || exit 1; \(pickerVisibleInTarget) && \(send); true; }"
                           : "{ _bg || exit 1; \(send); }"
        }
        guard !steps.isEmpty else { return "" }
        return prelude(target) + steps.joined(separator: "; sleep 1; ")
    }
}

// MARK: - Pending work

/// Background work by key that a later step must wait out (a tab close in
/// its grace period, a put-away resolving its branch). The newest one
/// registered under a key is what `wait` waits for — and any registered
/// while waiting.
@MainActor
final class PendingWork {
    private var work: [String: (token: UUID, task: Task<Void, Never>)] = [:]

    func register(_ key: String, token: UUID, task: Task<Void, Never>) {
        work[key] = (token, task)
    }

    /// The work under `token` is over (a newer one under the key stays).
    func finish(_ key: String, token: UUID) {
        if work[key]?.token == token { work[key] = nil }
    }

    func isPending(_ key: String) -> Bool { work[key] != nil }

    func wait(_ key: String) async {
        while let pending = work[key] {
            await pending.task.value
            if work[key]?.token == pending.token { work[key] = nil }
        }
    }
}

// MARK: - Engine

/// Drives the coding board's transitions that touch the guest: starting a
/// task (agent in a fresh worktree), catching the agent's done signal
/// (→ Testing), sending review feedback back (→ In Progress), and merging
/// (→ Done). UI-only moves (backlog edits, dismiss) go straight through
/// the store.
#if os(macOS)
@MainActor
final class CodingTaskEngine {
    weak var delegate: ACAppDelegate?
    let store: CodingTaskStore
    /// Landings this engine is watching (one watcher per task).
    var landingWatches: Set<UUID> = []
    /// Tasks Bromure saw land in git while their agent was still at it: the
    /// card is Done but the agent's session (and its board binding) stays
    /// for a grace period, so the agent's own `board_report_landing` lands
    /// as a no-op success instead of "isn't bound to a board task".
    var landingGrace: Set<UUID> = []
    /// Grace periods the agent ended early (it reported, or its turn ended).
    var landingGraceEnded: Set<UUID> = []
    /// The agent's last pane line when the landing brief went in — the
    /// previous turn's, not news (see `watchLanding`).
    var landingBaselineLine: [UUID: String] = [:]
    /// The idle-Review sweep's timer (see `startHousekeeping`).
    var housekeeping: Timer?

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
        2. Record a short overview of the plan with board_set_plan, with \
        phaseCount set to the total number of phases — file them all.
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

    /// The workspace answering, booting it first when it isn't: nil once it
    /// answers, else why it won't — a start the app refused, with its reason
    /// (nobody was there to answer its prompt), or the boot timeout.
    func ensureWorkspaceUp(_ profileID: UUID, delegate: ACAppDelegate,
                                   detached: Bool = false) async -> String? {
        if (try? await delegate.guestExec(profileID: profileID, command: "true", timeout: 5)) != nil {
            return nil
        }
        if !pendingBoots.contains(profileID) {
            pendingBoots.insert(profileID)
            delegate.startProfileForAutomation(profileID, detached: detached)
        }
        defer { pendingBoots.remove(profileID) }
        let deadline = Date().addingTimeInterval(Self.bootTimeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: Self.bootPollInterval)
            if let why = delegate.unattendedLaunchRefusal(profileID) { return why }
            if (try? await delegate.guestExec(profileID: profileID, command: "true", timeout: 5)) != nil {
                return nil
            }
        }
        return NSLocalizedString("The workspace did not boot in time", comment: "task start")
    }

    private func runValidation(delegate: ACAppDelegate, profileID: UUID,
                               guestPath: String, prompt: String) async -> String {
        // Make sure the workspace is up (same boot courtesy as start()).
        if let why = await ensureWorkspaceUp(profileID, delegate: delegate) {
            return "⚠️ " + why + " — " + NSLocalizedString("try again.", comment: "plan validation")
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
    /// they land). The card shows "Starting…" at once and moves to In
    /// Progress only once the checks pass (workspace up, folder present, a
    /// repository of its own) — a task that can't start never flashes In
    /// Progress, on the board or over the API; it keeps its column and
    /// shows the reason.
    func start(_ taskID: UUID) {
        guard let task = store.task(taskID),
              task.stage == .backlog || task.stage == .planning,
              !task.isStarting,
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
        // Stopped earlier: pick the work back up on its own branch.
        if let rb = task.resumeBranch, rb.hasPrefix("wt/"), Self.isSafeBranch(rb) {
            resumeStopped(taskID, branch: rb)
            return
        }
        let priorStage = task.stage
        let slug = ScheduledAutomationEngine.branchSlug(for: task.title, at: Date())
        let guestPath = ScheduledAutomationEngine.guestPath(task.repoPath)
        // Kimi takes no opening message at launch (only its one-shot mode
        // does): it starts interactive and the brief is typed in once its
        // input is up.
        let typedBrief = AgentPaneProbe.typesOpeningMessage(task.tool) ? Self.prompt(for: task) : nil
        let args = [guestPath, slug, task.title, task.tool.rawValue,
                    typedBrief == nil ? Self.prompt(for: task) : "", "task"]
        let profileID = task.profileID
        let title = task.title
        let isClaude = task.tool == .claude

        // The card says "Starting…" from the click; it moves to In
        // Progress once the checks below pass, or shows why it can't.
        store.mutate(taskID) {
            $0.startingAt = Date()
            $0.queuedAt = nil
            $0.lastError = nil
        }
        func refuse(_ reason: String) {
            store.mutate(taskID) {
                $0.startingAt = nil
                $0.lastError = reason
            }
        }
        func revert(_ reason: String) {
            store.mutate(taskID) {
                $0.stage = priorStage
                $0.branchSlug = nil
                $0.startedAt = nil
                $0.startingAt = nil
                $0.lastError = reason
            }
        }

        Task { [weak self] in
            guard let self, let delegate = self.delegate else { return }
            // Make sure the workspace is reachable (boot when it isn't).
            if let why = await self.ensureWorkspaceUp(profileID, delegate: delegate) {
                BACDebug.log("tasks", "“\(title)”: \(why)")
                refuse(why)
                return
            }
            // The board's whole lifecycle — done-signal matching, diff
            // review, merge — rides the task's worktree BRANCH. A non-repo
            // start path silently falls back to a plain agent tab with no
            // branch, and the card can never leave In Progress. Refuse it
            // with the reason instead.
            let q = "'" + guestPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
            if let cloneError = await self.cloneIfRequested(task, profileID: profileID, quotedPath: q) {
                refuse(cloneError)
                return
            }
            if task.initRepo == true {
                _ = try? await delegate.guestExec(
                    profileID: profileID,
                    command: Self.initRepoCommand(quotedPath: q), timeout: 15)
            }
            let dirExists = (try? await delegate.guestExec(
                profileID: profileID, command: "test -d \(q)", timeout: 10)) != nil
            guard dirExists else {
                refuse(String(format: NSLocalizedString(
                    "“%@” doesn't exist in the workspace — pick an existing folder, or edit the task and enable “Create folder & git repo”.",
                    comment: "task plan"), task.repoPath))
                return
            }
            guard await self.usableRepo(profileID: profileID, quotedPath: q) else {
                refuse(String(format: NSLocalizedString(
                    "“%@” isn't a git repository of its own — tasks run on their own branch. Pick a repo folder, or edit the task and enable “Create folder & git repo”.",
                    comment: "task start"), task.repoPath))
                return
            }
            // A user-inited repo with no commits yet would fail the worktree
            // cut (git needs a HEAD) — give it the same empty root commit
            // the initRepo path makes. No-ops whenever HEAD exists.
            _ = try? await delegate.guestExec(
                profileID: profileID,
                command: Self.ensureHeadCommand(quotedPath: q), timeout: 15)
            if isClaude {
                await delegate.pretrustGuestPath(profileID: profileID, dir: guestPath)
            }
            // Removed, stopped or started elsewhere while the checks ran.
            guard let now = self.store.task(taskID), now.isStarting,
                  now.stage == priorStage else {
                self.store.mutate(taskID) { $0.startingAt = nil }
                return
            }
            // Checks passed: In Progress, on the branch the launch makes.
            self.store.mutate(taskID) {
                $0.stage = .inProgress
                $0.branchSlug = slug
                $0.startedAt = Date()
                $0.startingAt = nil
                $0.lastError = nil
            }
            guard delegate.automationWorktreeCommand(
                profileNameOrID: profileID.uuidString, action: "run", args: args) else {
                revert(NSLocalizedString("Couldn't reach the workspace — is it running?",
                                         comment: "task start"))
                return
            }
            BACDebug.log("tasks", "started “\(title)” → \(slug)")
            if let typedBrief {
                self.typeOpeningBrief(taskID, profileID: profileID, branch: "wt/" + slug,
                                      text: typedBrief, worker: task.workerName)
            } else {
                self.watchStart(taskID, profileID: profileID, branch: "wt/" + slug,
                                worker: task.workerName)
            }
        }
    }

    /// An agent that takes its brief on the command line: watch the launch
    /// so one that dies at once (bad flag, missing binary) puts the reason
    /// on the card in seconds, not never.
    func watchStart(_ taskID: UUID, profileID: UUID, branch: String, worker: String) {
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.watchLaunch(profileID: profileID, branch: branch, within: 240)
            guard case .died = outcome, let t = self.store.task(taskID), t.stage == .inProgress,
                  t.branchSlug.map({ "wt/" + $0 }) == branch || t.branch == branch else { return }
            let why = Self.launchFailure(worker: worker, outcome)
            self.store.mutate(taskID) { $0.lastError = why }
            self.noteSessionLaunchFailed(taskID, branch: branch, reason: why)
        }
    }

    /// A task's agent died at launch: say so on its SESSION too, so the
    /// chat stage shows the failure (its error card) and the status chip
    /// reads "Couldn't start" — not "Ready", then "Paused" — matching the
    /// card. The session is the task's own when bound, else the one bound
    /// to the task's tab (adopted a roster tick or two after the tab
    /// opened, so it is looked for a few times).
    func noteSessionLaunchFailed(_ taskID: UUID, branch: String, reason: String) {
        Task { [weak self] in
            for _ in 0..<6 {
                guard let self, let delegate = self.delegate, let t = self.store.task(taskID) else { return }
                let sessions = delegate.agentSessionStore
                var sid: UUID? = t.sessionID.flatMap { id in
                    sessions.session(id).flatMap { ($0.isArchived || $0.isDeleted) ? nil : $0.id } }
                if sid == nil, let idx = delegate.pane(for: t.profileID)?.model.tabs
                    .first(where: { $0.worktreeBranch == branch })?.index {
                    sid = sessions.session(profileID: t.profileID, windowIndex: idx)?.id
                }
                if let sid {
                    sessions.mutate(sid) { $0.lastError = reason; $0.launchingSince = nil }
                    self.store.mutate(taskID) { if $0.sessionID != sid { $0.sessionID = sid } }
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// Type a launch's opening brief into the agent once it's up (Kimi —
    /// `AgentPaneProbe.typesOpeningMessage`). Not delivered: the card says so.
    func typeOpeningBrief(_ taskID: UUID, profileID: UUID, branch: String, text: String,
                          worker: String) {
        Task { [weak self] in
            guard let self else { return }
            guard let failure = await self.deliverOnceUpOutcome(
                profileID: profileID, branch: branch, text: text, within: 240) else {
                BACDebug.log("tasks", "opening brief typed into \(branch)")
                return
            }
            BACDebug.log("tasks", "opening brief NOT delivered to \(branch)")
            let why = Self.onceUpFailure(worker: worker, failure)
            self.store.mutate(taskID) { $0.lastError = why }
            if case .launch = failure { self.noteSessionLaunchFailed(taskID, branch: branch, reason: why) }
        }
    }

    /// Start a task that was stopped back to the Backlog: on its kept
    /// branch and checkout, the agent's conversation resumed. A branch
    /// that's gone since means a fresh start.
    private func resumeStopped(_ taskID: UUID, branch: String) {
        guard let task = store.task(taskID), let delegate else { return }
        store.mutate(taskID) { $0.startingAt = Date(); $0.queuedAt = nil; $0.lastError = nil }
        Task { [weak self] in
            guard let self else { return }
            // Stopped a moment ago: its old tab is still closing. Typed into
            // now, the resume brief would land there and die with it (and a
            // roster that still lists the killed tab routed it there: "the
            // tab is gone"). So: wait for the whole put-away, then close
            // whatever still carries the branch — the stopped run's, never a
            // tab to reuse — and the resume always opens a tab of its own.
            await self.awaitPutAway(taskID)
            await self.awaitPendingTabClose(profileID: task.profileID, branch: branch)
            self.closeSessionTab(profileID: task.profileID, branch: branch, afterSeconds: 0)
            await self.awaitPendingTabClose(profileID: task.profileID, branch: branch)
            if let why = await self.ensureWorkspaceUp(task.profileID, delegate: delegate) {
                self.store.mutate(taskID) { $0.startingAt = nil; $0.lastError = why }
                return
            }
            let hint = (task.rootRepo ?? "").isEmpty
                ? ScheduledAutomationEngine.guestPath(task.repoPath) : task.rootRepo!
            switch await self.checkoutState(profileID: task.profileID, repoHint: hint, branch: branch) {
            case .branchMissing, .repoMissing:
                BACDebug.log("tasks", "“\(task.title)”: kept branch \(branch) is gone — fresh start")
                self.store.mutate(taskID) {
                    $0.resumeBranch = nil; $0.startingAt = nil
                    $0.worktreeDir = nil; $0.rootRepo = nil; $0.parentBranch = nil
                }
                self.start(taskID)
                return
            case .ok, .worktreeMissing:
                break
            }
            self.store.mutate(taskID) {
                $0.stage = .inProgress
                $0.branch = branch
                $0.branchSlug = String(branch.dropFirst(3))
                $0.resumeBranch = nil
                $0.startedAt = Date()
                $0.startingAt = nil
                $0.lastError = nil
            }
            BACDebug.log("tasks", "“\(task.title)”: resuming on its kept branch \(branch)")
            let prompt = self.store.task(taskID).map(Self.resumePrompt(for:)) ?? Self.resumePrompt(for: task)
            if await self.relaunchConversation(taskID, branch: branch, prompt: prompt, closeWindow: nil) {
                self.store.mutate(taskID) { $0.lastError = nil }
            }
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
                    task.tool.rawValue,
                    AgentPaneProbe.typesOpeningMessage(task.tool) ? "" : Self.plannerPrompt(for: task), "plan"]
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
            // Headless: the plan window is the surface for this session —
            // raising the terminal would bury it.
            if let why = await self.ensureWorkspaceUp(profileID, delegate: delegate, detached: true) {
                revert(why)
                return
            }
            // Planning happens IN the configured directory (no worktree —
            // the interview writes no code and must see the tree exactly
            // as the user left it). The directory just has to exist.
            let q = "'" + guestPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
            if let cloneError = await self.cloneIfRequested(task, profileID: profileID, quotedPath: q) {
                revert(cloneError)
                return
            }
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
            if AgentPaneProbe.typesOpeningMessage(task.tool) {
                self.typeOpeningBrief(taskID, profileID: profileID, branch: "wt/" + slug,
                                      text: Self.plannerPrompt(for: task), worker: task.workerName)
            }
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
        // A streamed planning session has no tab — end its driver directly.
        if let slug = task.branchSlug {
            delegate?.endPlanStream(profileID: profileID, branch: "wt/" + slug)
        }
        let knownRoot = task.rootRepo
            ?? task.branch.flatMap { b in
                delegate?.pane(for: profileID)?.model.tabs.first { $0.worktreeBranch == b }?.rootRepo }
        store.remove(taskID)
        pumpQueue()
        guard task.branch != nil || task.branchSlug != nil else { return }
        // The branch off the card, else the live tab's — asked of the guest
        // when the workspace runs detached (no pane roster here): the agent
        // must stop and its checkout go even then.
        Task { [weak self] in
            guard let self else { return }
            var branch = task.branch
            if branch == nil { branch = await self.liveBranchResolved(of: task) }
            if branch == nil, let slug = task.branchSlug { branch = "wt/" + slug }
            guard let branch else { return }
            self.closeSessionTab(profileID: profileID, branch: branch, afterSeconds: 0)
            var root = knownRoot
            if (root ?? "").isEmpty {
                root = await self.resolveWorktreeMetadata(
                    profileID: profileID, branch: branch, repoPath: task.repoPath).root
            }
            if let root, !root.isEmpty {
                // Give the tab kill a beat, then drop the checkout.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                _ = self.delegate?.automationWorktreeCommand(
                    profileNameOrID: profileID.uuidString,
                    action: "remove", args: [root, branch])
            }
            BACDebug.log("tasks", "“\(task.title)” destroyed (\(branch))")
        }
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

    /// A phase just reached Done: its planned brief goes Done too when the
    /// whole plan is (it was hidden behind its phases in the Backlog
    /// forever). Only ever on that transition — never on a load or a
    /// queue pump, so an upgrade can't rewrite existing cards.
    func rollUpBrief(afterPhaseDone phaseID: UUID) {
        guard let parentID = Self.briefRollUp(store.tasks, phaseDone: phaseID),
              let parent = store.task(parentID) else { return }
        store.mutate(parentID) {
            $0.stage = .done
            $0.completedAt = Date()
            $0.completion = .markedDone(byUser: false)
        }
        BACDebug.log("tasks", "“\(parent.title)”: every planned phase is done — brief done")
    }

    /// The brief to roll up to Done now that `phaseID` is Done, if any. All
    /// of: its plan is complete (the planning session ended with phases
    /// filed), every phase the plan has was FILED — as many as the planner
    /// declared (board_set_plan phaseCount) and as the plan text numbers
    /// ("Phase 6") — and every filed phase is Done. A brief with phases
    /// still unfiled stays in the Backlog.
    nonisolated static func briefRollUp(_ tasks: [CodingTask], phaseDone phaseID: UUID) -> UUID? {
        guard let phase = tasks.first(where: { $0.id == phaseID }), phase.stage == .done,
              let parentID = phase.parentTaskID,
              let parent = tasks.first(where: { $0.id == parentID }),
              parent.stage == .backlog, parent.planCompletedAt != nil else { return nil }
        let phases = tasks.filter { $0.parentTaskID == parentID }
        guard !phases.isEmpty, phases.allSatisfy({ $0.stage == .done }) else { return nil }
        let expected = max(parent.plannedPhases ?? 0, phaseNumbersMentioned(in: parent.plan ?? ""))
        guard phases.count >= expected else { return nil }
        return parentID
    }

    /// The highest "Phase N" a plan's text names (0 when none) — a plan
    /// listing six phases expects six cards.
    nonisolated static func phaseNumbersMentioned(in plan: String) -> Int {
        guard let re = try? NSRegularExpression(pattern: #"(?i)\bphase\s*#?\s*(\d{1,3})\b"#) else { return 0 }
        let ns = plan as NSString
        var best = 0
        for m in re.matches(in: plan, range: NSRange(location: 0, length: ns.length)) {
            if let n = Int(ns.substring(with: m.range(at: 1))), n <= 200 { best = max(best, n) }
        }
        return best
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
        // The agent landing an approved task ended its turn: look now.
        if let task = store.tasks.first(where: {
            $0.stage == .testing && $0.landing?.phase == .agentLanding && matches($0)
        }) {
            landingAgentStopped(task.id)
            return
        }
        // Landed (seen in git) while the agent was still wrapping up: its
        // turn ending closes the post-landing grace.
        if let task = store.tasks.first(where: {
            $0.stage == .done && landingGrace.contains($0.id) && matches($0)
        }) {
            landingAgentStopped(task.id)
            return
        }
        // A planning session signaling done. Claude's Stop hook fires at the
        // end of EVERY turn — for an interactive interview that includes the
        // agent merely pausing for the user's reply, so "done" alone must
        // NEVER kill the session. Only once the phases have actually landed
        // is the signal the session's real completion; an unfiled "done" is
        // ignored (the watchdog owns true deaths: claude exiting to a bare
        // shell, the tab disappearing, the 1-hour cap).
        if let parent = store.tasks.first(where: {
            $0.stage == .backlog && $0.validationRequestedAt != nil && matches($0)
        }) {
            guard !settling.contains(parent.id) else { return }
            settling.insert(parent.id)
            Task { [weak self] in
                // Subagents the planner spawned may still be exploring — or
                // about to file phases through the MCP. Settle before judging.
                await self?.delegate?.waitForSessionQuiet(profileID: profileID,
                                                          branch: branch)
                guard let self else { return }
                self.settling.remove(parent.id)
                guard let p = self.store.task(parent.id) else { return }
                guard !p.validationInFlight else {
                    BACDebug.log("tasks", "“\(p.title)”: turn-end Stop before filing — interview continues")
                    return
                }
                BACDebug.log("tasks", "planning session done for “\(parent.title)”")
                self.store.mutate(parent.id) { $0.planCompletedAt = Date() }
                self.closeSessionTab(profileID: profileID, branch: branch,
                                     afterSeconds: 10)
                self.planWatchdogs[parent.id]?.cancel()
                self.planWatchdogs[parent.id] = nil
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
            $0.sessionParkedAt = nil
            $0.landing = nil
            // Handed over: whatever failed on the way here (a send-back
            // that didn't get through, a relaunch that timed out) is moot.
            $0.lastError = nil
            $0.restartNeeded = nil
            if let dir { $0.worktreeDir = dir }
            if let parent { $0.parentBranch = parent }
            if let root { $0.rootRepo = root }
        }
        // The agent stays in its tab through review: send-back types into
        // the same conversation, and landing hands the merge to the agent
        // that wrote the change. The tab is put away when the task lands, is
        // marked done or discarded — or after a long idle spell in Review
        // (`sweepIdleReview`).
        await measureCodeChanges(taskID)
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
            let cmd = Self.worktreeMetadataCommand(
                repoPath: ScheduledAutomationEngine.guestPath(repoPath), branch: branch)
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

    /// The guest command behind `resolveWorktreeMetadata`: prints the
    /// branch's worktree dir, its parent branch and the repo root. The
    /// parent is the one the registry recorded when the board made the
    /// worktree; failing that (a task an agent did in a worktree of its
    /// own), the branch the work forked from — the one `branch` is the
    /// fewest commits ahead of, other task branches aside, the checked-out
    /// one on a tie. The folder's HEAD alone named whatever that checkout
    /// happened to be on, not where the work came from.
    nonisolated static func worktreeMetadataCommand(repoPath: String, branch: String) -> String {
        let q = "'" + repoPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "root=$(git -C \(q) rev-parse --show-toplevel 2>/dev/null); "
            + "[ -n \"$root\" ] || exit 0; "
            + "dir=$(git -C \"$root\" worktree list --porcelain 2>/dev/null "
            + "| awk -v b='refs/heads/\(branch)' "
            + "'/^worktree /{d=substr($0,10)} $0==\"branch \" b {print d; exit}'); "
            + "reg=\"$HOME/.bromure/worktrees/$(basename \"$root\")/.registry\"; "
            + "parent=$(awk -F'\\x1f' -v b='\(branch)' '$1==b {print $2; exit}' "
            + "\"$reg\" 2>/dev/null); "
            + "if [ -z \"$parent\" ]; then "
            + "best=999999; "
            + "head=$(git -C \"$root\" rev-parse --abbrev-ref HEAD 2>/dev/null); "
            + "for b in \"$head\" $(git -C \"$root\" for-each-ref --count=300 --format='%(refname:short)' refs/heads/); do "
            + "case \"$b\" in ''|HEAD|wt/*|\"\(branch)\") continue;; esac; "
            + "n=$(git -C \"$root\" rev-list --count \"$b..\(branch)\" 2>/dev/null) || continue; "
            + "if [ \"$n\" -lt \"$best\" ]; then best=$n; parent=$b; fi; "
            + "done; fi; "
            + "printf '%s\\n%s\\n%s\\n' \"$dir\" \"$parent\" \"$root\""
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
            $0.sessionParkedAt = nil
            $0.landing = nil
            // Handed over: whatever failed on the way here (a send-back
            // that didn't get through, a relaunch that timed out) is moot.
            $0.lastError = nil
            $0.restartNeeded = nil
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
            // The session stays for review (see finalizeTaskDone).
            await self.measureCodeChanges(taskID)
        }
        return store.task(task.id)?.stage == .testing
    }

    // MARK: Review round (Testing → In Progress)

    /// Send the unsent review comments back to the agent and return the
    /// task to In Progress. They go into the agent's OWN conversation: typed
    /// into its tab only while the agent is running there (a tab whose
    /// agent exited is a bare shell — text typed into it runs as bash
    /// commands), else that conversation is resumed in a fresh tab with the
    /// feedback. The comments count as sent only once the delivery is
    /// confirmed; a failed one leaves them pending with the reason on the
    /// card, and Restart Session sends them.
    func sendBack(_ taskID: UUID) async {
        guard let task = store.task(taskID), task.stage == .testing,
              let branch = task.branch, let delegate else { return }
        let unsent = task.comments.filter { $0.sentAt == nil }
        guard !unsent.isEmpty else { return }
        let ids = Set(unsent.map(\.id))
        let feedback = Self.feedbackPrompt(comments: unsent)

        // Done by someone else's session (a board request): the feedback
        // goes back through the delegation, not into a task tab.
        if task.delegationID != nil {
            guard await delegate.taskDispatcher.sendBack(taskID, feedback: feedback) else { return }
            store.mutate(taskID) {
                $0.stage = .inProgress
                $0.lastError = nil
                $0.landing = nil
                $0.deliverySummary = nil
            }
            markCommentsSent(taskID, ids)
            return
        }

        // Back to In Progress now — the agent is being put back on it.
        store.mutate(taskID) {
            $0.stage = .inProgress
            $0.lastError = nil
            $0.landing = nil   // cancels a landing under way
            $0.sessionParkedAt = nil
            $0.startedAt = Date()   // restart the session-gone clock
        }
        if await deliverToConversation(taskID, branch: branch, text: feedback) {
            markCommentsSent(taskID, ids)
            BACDebug.log("tasks", "“\(task.title)”: \(unsent.count) comment(s) sent back")
        } else {
            store.mutate(taskID) {
                if $0.lastError == nil {
                    $0.lastError = NSLocalizedString(
                        "Your review comments didn't reach the agent — they're still pending. Restart Session sends them.",
                        comment: "task send back")
                }
            }
            BACDebug.log("tasks", "“\(task.title)”: send-back not delivered — comments kept pending")
        }
    }

    /// Stamp exactly these comments as sent (ones added meanwhile stay
    /// pending).
    func markCommentsSent(_ taskID: UUID, _ ids: Set<UUID>) {
        let now = Date()
        store.mutate(taskID) {
            for i in $0.comments.indices where ids.contains($0.comments[i].id) && $0.comments[i].sentAt == nil {
                $0.comments[i].sentAt = now
                $0.comments[i].undelivered = nil
            }
        }
    }

    /// Put `text` into the task agent's own conversation. A tab where the
    /// agent is RUNNING (seen in the pane's process tree) gets it typed in
    /// (held while a menu is open); a tab left with only a shell — confirmed
    /// over a few seconds, so an agent still starting isn't judged dead — or
    /// no tab at all resumes the conversation (`task-resume … continue`) in
    /// a fresh tab, booting the workspace and re-creating a removed checkout
    /// first. A tab that can't be asked is never killed on a guess. True
    /// once delivered: typed into the running agent. Failures put their
    /// reason in `lastError`; a delivery clears a stale one.
    func deliverToConversation(_ taskID: UUID, branch: String, text: String) async -> Bool {
        guard let delegate, let task = store.task(taskID) else { return false }
        let profileID = task.profileID
        let idx = await tabIndex(profileID: profileID, branch: branch)
        let state: AgentPaneProbe.State? = idx == nil ? nil
            : await agentState(profileID: profileID, windowIndex: idx!, confirmShell: true)
        let ok: Bool
        switch AgentPaneProbe.route(window: idx, state: state) {
        case .type:
            // By the task's branch, re-checked in the guest right before each
            // keystroke batch: the index probed a moment ago may be another
            // tab's by now.
            let result = await Self.typeWhenFreeResult(delegate, profileID: profileID,
                                                       target: .task(branch: branch),
                                                       text: text, patience: 180)
            ok = result == .typed
            if case .refused(let r) = result {
                BACDebug.log("tasks", "“\(task.title)”: delivery refused (\(r.rawValue)) — nothing typed")
                store.mutate(taskID) { $0.lastError = Self.refusalReason(r, worker: task.workerName) }
            } else if !ok {
                store.mutate(taskID) {
                    $0.lastError = result == .draftInBox
                        ? String(format: NSLocalizedString(
                            "There's unsent text in %@'s input box in the task's session, so the message wasn't typed — open the session, send or clear it, then try again.",
                            comment: "task send back"), task.workerName)
                        : String(format: NSLocalizedString(
                            "%@ kept a menu open in the task's session, so the message wasn't typed — open the session, answer it, then try again.",
                            comment: "task send back"), task.workerName)
                }
            }
        case .relaunch(let close):
            ok = await relaunchConversation(taskID, branch: branch, prompt: text, closeWindow: close)
        case .undecided:
            store.mutate(taskID) {
                $0.lastError = NSLocalizedString(
                    "Couldn't check on the agent in the task's session — is the workspace running?",
                    comment: "task send back")
            }
            ok = false
        }
        if ok { store.mutate(taskID) { $0.lastError = nil } }
        return ok
    }

    /// Resume the task agent's conversation in a fresh tab on the task's
    /// checkout, with `prompt` as its message — see `deliverToConversation`.
    /// `closeWindow`: the task's old tab, seen with only a shell left.
    private func relaunchConversation(_ taskID: UUID, branch: String, prompt: String,
                                      closeWindow: Int?) async -> Bool {
        guard let delegate, let task = store.task(taskID) else { return false }
        let profileID = task.profileID
        @MainActor func fail(_ reason: String, restart: Bool = false) {
            store.mutate(taskID) {
                $0.lastError = reason
                $0.restartNeeded = restart ? true : nil
            }
        }
        if let why = await ensureWorkspaceUp(profileID, delegate: delegate) {
            fail(why)
            return false
        }
        // Only a shell left in the tab (the agent exited): close it, never
        // type into it — after one last look, so a live agent is never
        // killed.
        if let w = closeWindow {
            if case .running? = await agentState(profileID: profileID, windowIndex: w) {
                BACDebug.log("tasks", "“\(task.title)”: agent came up in tab \(w) — typing instead")
                let r = await Self.typeWhenFreeResult(delegate, profileID: profileID,
                                                      target: .task(branch: branch),
                                                      text: prompt, patience: 180)
                if case .refused(let why) = r { fail(Self.refusalReason(why, worker: task.workerName)) }
                return r == .typed
            }
            BACDebug.log("tasks", "“\(task.title)”: agent gone from tab \(w) — resuming its conversation")
            // Only the task's own tab, and only while just a shell is in it.
            _ = try? await delegate.guestExec(
                profileID: profileID,
                command: Self.killShellTabCommand(branch: branch), timeout: 10)
        }
        guard let root = await ensureCheckout(taskID, branch: branch, fail: fail) else { return false }
        // The parent branch tags the tab (@parent_branch → nested under its
        // folder, merge target). A task resumed after Stop & Return to
        // Backlog may not know it any more: ask the guest's registry.
        if (store.task(taskID)?.parentBranch ?? "").isEmpty {
            let m = await resolveWorktreeMetadata(profileID: profileID, branch: branch,
                                                  repoPath: task.repoPath)
            if let parent = m.parent, !parent.isEmpty {
                store.mutate(taskID) { $0.parentBranch = parent }
            }
        }
        // The task's session was put away with its old tab (Stop & Return
        // to Backlog, a finished run): bring it back unbound, so it takes
        // the new tab — the one task-resume opens under the same name —
        // instead of a stranger being minted, or the archived record
        // ending the new tab as "archived … is back".
        if let sid = store.task(taskID)?.sessionID,
           let s = delegate.agentSessionStore.session(sid), s.isArchived {
            delegate.agentSessionStore.unbind(sid)
            delegate.agentSessionStore.setArchived(sid, false)
        }
        let typed = AgentPaneProbe.typesOpeningMessage(task.tool)
        guard delegate.automationWorktreeCommand(
            profileNameOrID: profileID.uuidString, action: "task-resume",
            args: [root, branch, store.task(taskID)?.parentBranch ?? "",
                   task.title, task.tool.rawValue, typed ? "" : prompt, "continue"]) else {
            fail(NSLocalizedString("Couldn't reach the workspace — is it running?", comment: "task start"))
            return false
        }
        // The message rides the launch for agents that take one on their
        // command line: delivered once the agent is seen up. Kimi gets it
        // typed in once its input is ready.
        if typed {
            guard let f = await deliverOnceUpOutcome(profileID: profileID, branch: branch,
                                                     text: prompt, within: 150) else { return true }
            let why = Self.onceUpFailure(worker: task.workerName, f)
            fail(why)
            if case .launch = f { noteSessionLaunchFailed(taskID, branch: branch, reason: why) }
            return false
        }
        let outcome = await watchLaunch(profileID: profileID, branch: branch, within: 150)
        if case .up = outcome { return true }
        let why = Self.launchFailure(worker: task.workerName, outcome)
        fail(why)
        noteSessionLaunchFailed(taskID, branch: branch, reason: why)
        return false
    }

    /// The tab (by branch) once its agent is seen running, nil if it isn't
    /// within `within` seconds.
    func waitForAgent(profileID: UUID, branch: String, within: TimeInterval) async -> Int? {
        if case .up(let w) = await watchLaunch(profileID: profileID, branch: branch, within: within) {
            return w
        }
        return nil
    }

    /// Watch a just-launched task tab until its agent is up — failing FAST
    /// when it dies instead of waiting out `within`: the launcher's "exited
    /// with status N" marker with only a shell left ends the watch at once,
    /// and a bare shell for several probes in a row after a grace period
    /// (the agent never came up, no marker) ends it too.
    func watchLaunch(profileID: UUID, branch: String, within: TimeInterval,
                     grace: TimeInterval = 20) async -> AgentPaneProbe.LaunchOutcome {
        let started = Date()
        let deadline = started.addingTimeInterval(within)
        var shellStreak = 0
        var lastWindow: Int? = nil
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let delegate, let idx = await tabIndex(profileID: profileID, branch: branch) else {
                shellStreak = 0
                continue
            }
            if idx != lastWindow { shellStreak = 0; lastWindow = idx }
            let out = try? await delegate.guestExec(
                profileID: profileID, command: AgentPaneProbe.launchCommand(window: idx), timeout: 10)
            let state = out.flatMap(AgentPaneProbe.parse)
            let status = out.flatMap(AgentPaneProbe.exitStatus)
            shellStreak = state == .shell ? shellStreak + 1 : 0
            if let verdict = AgentPaneProbe.launchVerdict(
                state: state, exitStatus: status, window: idx,
                elapsed: Date().timeIntervalSince(started), grace: grace, shellStreak: shellStreak) {
                if case .died(let st) = verdict {
                    BACDebug.log("tasks", "\(branch): agent died at launch (status \(st.map(String.init) ?? "?"))")
                }
                if case .up(let w) = verdict { bindSession(profileID: profileID, branch: branch, window: w) }
                return verdict
            }
        }
        return .timedOut
    }

    /// Remember the session behind a task's tab (`CodingTask.sessionID`),
    /// once the session store has adopted the tab (a roster tick or two).
    func bindSession(profileID: UUID, branch: String, window: Int) {
        guard branch.hasPrefix("wt/") else { return }
        let slugPart = String(branch.dropFirst(3))
        guard let task = store.tasks.first(where: { t in
            guard t.profileID == profileID, t.stage != .done, let slug = t.branchSlug else { return false }
            return AutomationBoard.branchMatches(branch, slug: slug) || slugPart == slug
        }) else { return }
        let taskID = task.id
        Task { [weak self] in
            for _ in 0..<10 {
                guard let self, let delegate = self.delegate else { return }
                if let s = delegate.agentSessionStore.session(profileID: profileID, windowIndex: window) {
                    // Not stamped as a branch session: the board owns the
                    // task's branch (merge/archive prompts stay the board's).
                    self.store.mutate(taskID) { if $0.sessionID != s.id { $0.sessionID = s.id } }
                    return
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// The card's reason for a launch that didn't come up.
    nonisolated static func launchFailure(worker: String, _ outcome: AgentPaneProbe.LaunchOutcome) -> String {
        switch outcome {
        case .died(let status?):
            return String(format: NSLocalizedString(
                "%@ exited right after it started (status %d) — open the session to see why, then Restart Session.",
                comment: "task launch failed"), worker, status)
        case .died(nil):
            return String(format: NSLocalizedString(
                "%@ quit right after it started — open the session to see why, then Restart Session.",
                comment: "task launch failed"), worker)
        case .up, .timedOut:
            return String(format: NSLocalizedString(
                "%@ didn't start in the task's session — open it to see why, then Restart Session.",
                comment: "task send back"), worker)
        }
    }

    /// Type `text` into the tab's agent once it is up AND its screen has
    /// settled (the TUI drew its input box — text typed before that is
    /// lost): the sessions path's `deliverWhenAlive`, for a task tab. True
    /// once typed.
    func deliverOnceUp(profileID: UUID, branch: String, text: String,
                       within: TimeInterval) async -> Bool {
        await deliverOnceUpOutcome(profileID: profileID, branch: branch, text: text,
                                   within: within) == nil
    }

    /// Why a once-up delivery typed nothing.
    enum OnceUpFailure: Equatable {
        /// The agent never came up (or died at launch).
        case launch(AgentPaneProbe.LaunchOutcome)
        /// Up, but the guard refused the tab at send time.
        case refused(PaneRefusal)
        /// Up, but a menu or a draft kept the text out.
        case notTyped
    }

    nonisolated static func onceUpFailure(worker: String, _ f: OnceUpFailure) -> String {
        switch f {
        case .launch(let o): return launchFailure(worker: worker, o)
        case .refused(let r): return refusalReason(r, worker: worker)
        case .notTyped: return launchFailure(worker: worker, .timedOut)
        }
    }

    /// `deliverOnceUp` with the reason it failed: nil = typed. Typed by the
    /// task's BRANCH, re-checked in the guest at send time — never into
    /// whatever tab took the index the launch watch saw.
    func deliverOnceUpOutcome(profileID: UUID, branch: String, text: String,
                              within: TimeInterval) async -> OnceUpFailure? {
        let outcome = await watchLaunch(profileID: profileID, branch: branch, within: within)
        guard case .up(let idx) = outcome, let delegate else { return .launch(outcome) }
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        await waitForSettledScreen(profileID: profileID, windowIndex: idx, maxWait: 30)
        switch await Self.typeWhenFreeResult(delegate, profileID: profileID,
                                             target: .task(branch: branch),
                                             text: text, patience: 120) {
        case .typed: return nil
        case .refused(let r): return .refused(r)
        case .menuOpen, .draftInBox: return .notTyped
        }
    }

    /// Kill the task's tab — found by its branch — only while nothing but
    /// a shell is left in it (the guard prints a refusal otherwise).
    nonisolated static func killShellTabCommand(branch: String) -> String {
        PaneTypeGuard.prelude(.task(branch: branch, foreground: .shell))
            + "if _bg; then tmux kill-window -t \"$_bt\"; fi"
    }

    /// Wait until the pane shows something and stops changing (two equal
    /// captures in a row), up to `maxWait` seconds.
    private func waitForSettledScreen(profileID: UUID, windowIndex: Int, maxWait: TimeInterval) async {
        guard let delegate else { return }
        let deadline = Date().addingTimeInterval(maxWait)
        var last: String? = nil
        while Date() < deadline {
            let out = (try? await delegate.guestExec(
                profileID: profileID,
                command: "tmux capture-pane -p -t bromure:\(windowIndex) 2>/dev/null | cksum",
                timeout: 8)) ?? ""
            let sum = out.trimmingCharacters(in: .whitespacesAndNewlines)
            // "<crc> 0": an empty pane, nothing drawn yet.
            if !sum.isEmpty, !sum.hasSuffix(" 0"), sum == last { return }
            last = sum
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    /// Make sure the task's checkout is there to resume into: the
    /// repository root, after re-creating a removed worktree directory. nil
    /// (with the reason passed to `fail`) when the branch or the repository
    /// is gone — Start Over is the way forward then.
    private func ensureCheckout(_ taskID: UUID, branch: String,
                                fail: @MainActor (String, Bool) -> Void) async -> String? {
        guard let task = store.task(taskID) else { return nil }
        let profileID = task.profileID
        let hint = (task.rootRepo ?? "").isEmpty
            ? ScheduledAutomationEngine.guestPath(task.repoPath) : task.rootRepo!
        switch await checkoutState(profileID: profileID, repoHint: hint, branch: branch) {
        case .ok(let root, let dir):
            store.mutate(taskID) {
                if ($0.rootRepo ?? "").isEmpty { $0.rootRepo = root }
                if ($0.worktreeDir ?? "").isEmpty { $0.worktreeDir = dir }
            }
            return root
        case .worktreeMissing(let root):
            // The branch (and the work on it) is safe — only the checkout
            // directory went away. Put it back.
            BACDebug.log("tasks", "“\(task.title)”: worktree for \(branch) missing — re-creating")
            guard let dir = await recreateWorktree(
                profileID: profileID, root: root, branch: branch,
                preferredDir: task.worktreeDir) else {
                fail(String(format: NSLocalizedString(
                    "The checkout for %@ is gone and couldn't be re-created in %@. Start Over runs the task again on a new branch.",
                    comment: "task resume"), branch, root), true)
                return nil
            }
            store.mutate(taskID) { $0.rootRepo = root; $0.worktreeDir = dir }
            return root
        case .branchMissing(let root):
            fail(String(format: NSLocalizedString(
                "The task's branch %@ no longer exists in %@ — its checkout was removed (merged and cleaned up, or deleted). Start Over runs the task again on a new branch.",
                comment: "task resume"), branch, root), true)
            return nil
        case .repoMissing:
            fail(String(format: NSLocalizedString(
                "The repository folder “%@” is gone from the workspace, so there is nothing to resume into. Start Over runs the task again from scratch%@.",
                comment: "task resume"), task.repoPath,
                task.effectiveCloneURL != nil
                    ? NSLocalizedString(", cloning the repository first", comment: "task resume")
                    : ""), true)
            return nil
        }
    }

    /// What is left of a task's checkout in the guest, probed before a
    /// relaunch: the whole repository, its branch, or just the worktree
    /// directory may be gone.
    private enum CheckoutState {
        case ok(root: String, dir: String)
        case worktreeMissing(root: String)
        case branchMissing(root: String)
        case repoMissing
    }

    private func checkoutState(profileID: UUID, repoHint: String, branch: String) async -> CheckoutState {
        guard let delegate, Self.isSafeBranch(branch) else { return .repoMissing }
        let qp = Self.shellQuote(repoHint)
        let cmd = "r=$(git -C \(qp) rev-parse --show-toplevel 2>/dev/null); "
            + "[ -n \"$r\" ] || { echo repo-missing; exit 0; }; "
            + "git -C \"$r\" show-ref --verify --quiet 'refs/heads/\(branch)' "
            + "|| { echo \"branch-missing $r\"; exit 0; }; "
            + "d=$(git -C \"$r\" worktree list --porcelain 2>/dev/null "
            + "| awk -v b='branch refs/heads/\(branch)' '/^worktree /{d=substr($0,10)} $0==b {print d; exit}'); "
            + "if [ -n \"$d\" ] && [ -d \"$d\" ]; then echo \"ok $r $d\"; else echo \"worktree-missing $r\"; fi"
        guard let out = try? await delegate.guestExec(profileID: profileID, command: cmd, timeout: 15)
        else { return .repoMissing }
        let parts = out.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 2).map(String.init)
        switch parts.first {
        case "ok" where parts.count == 3:            return .ok(root: parts[1], dir: parts[2])
        case "worktree-missing" where parts.count >= 2: return .worktreeMissing(root: parts[1])
        case "branch-missing" where parts.count >= 2:   return .branchMissing(root: parts[1])
        default:                                     return .repoMissing
        }
    }

    /// Re-create a task's worktree directory for a branch that still exists
    /// (the checkout was removed but the work is safe on the branch). The
    /// original directory when the task remembers one, else the guest's
    /// worktrees layout. nil on failure.
    /// Why a task's worktree is locked (`git worktree list` shows it on the
    /// Mac for a shared repository). Same words as agentd's.
    static let worktreeLockReason = "Bromure task checkout inside the workspace VM; unlocked and removed when the task ends"

    private func recreateWorktree(profileID: UUID, root: String, branch: String,
                                  preferredDir: String?) async -> String? {
        guard let delegate, Self.isSafeBranch(branch) else { return nil }
        let dir: String
        if let d = preferredDir, !d.isEmpty {
            dir = d
        } else {
            let repoName = (root as NSString).lastPathComponent
            dir = "/home/ubuntu/.bromure/worktrees/\(repoName)/\(branch.dropFirst("wt/".count))"
        }
        let qr = Self.shellQuote(root), qd = Self.shellQuote(dir)
        let cmd = "git -C \(qr) worktree prune 2>/dev/null; mkdir -p \"$(dirname \(qd))\" && "
            + "git -C \(qr) worktree add \(qd) '\(branch)' 2>&1 | tail -3 >&2; "
            // Locked like agentd's own (`_worktree_lock`): a host-side
            // prune in a shared repo would otherwise drop it.
            + "git -C \(qr) worktree lock --reason \(Self.shellQuote(Self.worktreeLockReason)) \(qd) 2>/dev/null; "
            + "[ -d \(qd) ]"
        guard (try? await delegate.guestExec(profileID: profileID, command: cmd, timeout: 60)) != nil
        else { return nil }
        return dir
    }

    /// Run the task again from scratch on a fresh branch — the way forward
    /// when its repository or branch is gone. Keeps the brief and the review
    /// comments (delivered with the new run's first prompt), drops the old
    /// branch metadata and any done/merge state.
    func startOver(_ taskID: UUID) {
        guard let task = store.task(taskID),
              task.stage == .inProgress || task.stage == .testing || task.stage == .done
        else { return }
        BACDebug.log("tasks", "“\(task.title)”: starting over on a fresh branch")
        store.mutate(taskID) {
            $0.stage = .backlog
            $0.branchSlug = nil; $0.branch = nil; $0.worktreeDir = nil
            $0.parentBranch = nil; $0.rootRepo = nil
            $0.startedAt = nil; $0.testingAt = nil; $0.completedAt = nil
            $0.landing = nil; $0.merged = false; $0.prOpened = nil
            $0.completion = nil; $0.codeChanges = nil; $0.sessionParkedAt = nil
            $0.lastError = nil; $0.restartNeeded = nil; $0.resumeBranch = nil
        }
        start(taskID)
    }

    /// Recovery for a task whose session can't be found (workspace
    /// rebooted, tab closed, agent dead) — or a finished task the user wants
    /// to keep working on: boot the workspace if needed, make sure there is
    /// a checkout to resume into, and re-launch the agent on the task's
    /// branch via guest task-resume. Unsent review comments ride along;
    /// otherwise the agent gets a resume brief telling it to pick up where
    /// the worktree stands. A missing worktree directory is re-created from
    /// the branch; a missing branch or repository is reported on the task
    /// with `restartNeeded` (the page then offers Start over) instead of
    /// failing silently inside the guest.
    func resumeSession(_ taskID: UUID) {
        guard let task = store.task(taskID),
              task.stage == .inProgress || task.stage == .testing || task.stage == .done,
              let branch = task.branch ?? task.branchSlug.map({ "wt/" + $0 }),
              delegate != nil else { return }
        let unsent = task.comments.filter { $0.sentAt == nil }
        let ids = Set(unsent.map(\.id))
        store.mutate(taskID) { $0.lastError = nil; $0.restartNeeded = nil }
        BACDebug.log("tasks", "“\(task.title)”: restarting session (\(branch))")
        Task { [weak self] in
            guard let self else { return }
            // A live session may already exist (workspace was just slow, or
            // the user hit Resume on a session that's still there): an agent
            // that is alive gets the comments, or a nudge to pick the task
            // back up when there are none — before this, Resume on a live
            // idle session did nothing. Otherwise its conversation is resumed
            // in a fresh tab (a tab with only a shell left is closed, never
            // typed into) — with the same context, not a new conversation.
            let alive: Bool
            if let idx = await self.tabIndex(profileID: task.profileID, branch: branch) {
                alive = await self.agentAlive(profileID: task.profileID, windowIndex: idx, branch: branch)
            } else {
                alive = false
            }
            let text = !unsent.isEmpty ? Self.feedbackPrompt(comments: unsent)
                : alive ? Self.nudgePrompt : Self.resumePrompt(for: task)
            guard await self.deliverToConversation(taskID, branch: branch, text: text) else { return }
            self.store.mutate(taskID) {
                $0.stage = .inProgress
                $0.startedAt = Date()   // restart the session-gone clock
                // A finished task picked back up is active again.
                $0.completedAt = nil; $0.merged = false; $0.prOpened = nil; $0.landing = nil
                $0.completion = nil; $0.sessionParkedAt = nil
                $0.restartNeeded = nil
            }
            self.markCommentsSent(taskID, ids)
        }
    }

    /// Is a coding agent still running in the session's tab? Asked of the
    /// pane's process tree (`AgentPaneProbe`) — the tab's label is its
    /// title and tmux's foreground command can name the shell while the
    /// agent runs. False when it can't be told.
    func agentAlive(profileID: UUID, windowIndex: Int, branch: String) async -> Bool {
        if case .running? = await agentState(profileID: profileID, windowIndex: windowIndex) { return true }
        return false
    }

    /// The tab's agent state; nil when the guest can't be asked.
    /// `confirmShell`: a bare shell must be seen three times over ~6 s (an
    /// agent still starting runs as its shell for a moment).
    func agentState(profileID: UUID, windowIndex: Int,
                    confirmShell: Bool = false) async -> AgentPaneProbe.State? {
        guard let delegate else { return nil }
        var last: AgentPaneProbe.State? = nil
        for attempt in 0..<(confirmShell ? 3 : 1) {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 3_000_000_000) }
            let out = try? await delegate.guestExec(
                profileID: profileID, command: AgentPaneProbe.command(window: windowIndex), timeout: 10)
            last = out.flatMap(AgentPaneProbe.parse)
            switch last {
            case .running?, .gone?: return last
            case .shell?, nil: continue
            }
        }
        return last
    }

    /// Typed into a LIVE but idle session when the user hits Resume with no
    /// review comments pending: pick the task back up and finish it.
    nonisolated static let nudgePrompt =
        "Please continue with this task from where you left off: run `git status` "
        + "and `git log` to see what's already done, finish the remaining work, "
        + "commit it, and hand the task to review with "
        + "`sh ~/.bromure/agent-status.sh done` when complete."

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
    /// Guarded (`PaneTypeGuard`): nothing is typed unless an AGENT holds
    /// the pane's foreground — a bare shell would run the text.
    nonisolated static func typeCommand(tabIndex: Int, text: String) -> String {
        PaneTypeGuard.typeCommand(target: .index(tabIndex), text: text)
    }

    /// `typeCommand` for any target (a task's tab by branch, a session's
    /// tab with its markers).
    nonisolated static func typeCommand(target: PaneTarget, text: String) -> String {
        PaneTypeGuard.typeCommand(target: target, text: text)
    }

    /// Type a COMMAND LINE into a tab whose agent exited (a relaunch in
    /// place): only while a shell — not an agent, which would take it as a
    /// message — holds the pane, and only in the intended window.
    nonisolated static func shellLineCommand(target: PaneTarget, line: String) -> String {
        var t = target
        t.foreground = .shell
        return PaneTypeGuard.typeCommand(target: t, text: line)
    }

    /// What `guardedTypeCommand` prints when it held off.
    nonisolated static let typeHeldMarker = PaneTypeGuard.heldMarker

    /// `typeCommand` for text nobody watches arrive (a delegation or
    /// Switchboard notice, a message for a session just brought back). An
    /// Enter into an open menu or dialog picks its default — a permission
    /// granted, an "auto mode" setup accepted — and a digit in the text can
    /// pick a numbered option. So the tab is checked for one (the picker
    /// footers every agent prints — `AgentPhrases` — or a highlighted
    /// numbered row, "❯ 1." / Grok's "1 (●)") before typing and again before Enter; with one up nothing more is
    /// sent and `typeHeldMarker` is printed, for the caller to hold the text.
    nonisolated static func guardedTypeCommand(tabIndex: Int, text: String) -> String {
        guardedTypeCommand(target: .index(tabIndex), text: text)
    }

    /// Defines `_bm`: true while a menu or dialog is up in "$_bt".
    nonisolated static var menuFunction: String { PaneTypeGuard.menuFunction }

    /// `guardedTypeCommand` on a stable target: the window is resolved once
    /// (to its id) and re-checked — identity and an agent in the
    /// foreground (`PaneTypeGuard`) — before the text and again before the
    /// Enter. A failed check types nothing more and prints the refusal.
    nonisolated static func guardedTypeCommand(target: PaneTarget, text: String) -> String {
        var t = target
        t.foreground = .agent
        return PaneTypeGuard.typeCommand(target: t, text: text)
    }

    /// The guest command that tails a plan session's live agent transcript.
    /// The agent runs IN the task's configured directory, so the session
    /// store entry is derived from that path the way each tool encodes it;
    /// `since` (epoch seconds) skips transcripts of earlier sessions in the
    /// same directory. Output is capped so a long session stays cheap to
    /// poll. `agent` is a canonical `BromureIcons` agent kind — nil (or a
    /// tool without a known store) searches every store and takes the
    /// newest match, so a tab whose label hasn't resolved yet still reads.
    /// Nil return when the path has characters we won't quote.
    nonisolated static func planTranscriptCommand(guestCwd: String, since: Int,
                                                  agent: String? = nil,
                                                  pinnedWindow: Int? = nil,
                                                  pin: TranscriptPin = TranscriptPin()) -> String? {
        guard let path = AgentSessionLocator.sanitized(guestCwd: guestCwd)
        else { return nil }
        var cmd = transcriptLocatePrefix(path: path, since: since, agent: agent,
                                         pinnedWindow: pinnedWindow, pin: pin)
        // iconv -c drops the orphan bytes a byte-cap cut can leave mid
        // UTF-8 sequence — a strict decode downstream used to collapse the
        // whole response.
        cmd += "if [ -n \"$f\" ]; then tail -c 300000 \"$f\" | iconv -f UTF-8 -t UTF-8 -c; fi; "
        if agent == nil || agent == "claude" {
            // The pq file is a PreToolUse hook's dump of a PENDING
            // AskUserQuestion (see the guest agent's _seed_question_hooks):
            // Claude Code doesn't write the assistant turn to the transcript
            // until the question is answered, so this is the only way the
            // window can show the question while it's actually being asked.
            // tr strips newlines so a pretty-printed dump still parses as one
            // transcript line. The pq name stays LOGICAL-path-encoded — the
            // hook derives it from $(pwd), which keeps the symlink.
            let enc2 = path.replacingOccurrences(of: ".", with: "-")
                .replacingOccurrences(of: "/", with: "-")
            let pq = "\"$HOME/.bromure/pq-\(enc2).json\""
            cmd += "if [ -n \"$(find \(pq) -newermt @\(AgentSessionLocator.findEpoch(since)) 2>/dev/null)\" ]; "
                + "then echo; tr -d '\\n' < \(pq); echo; fi"
        }
        return cmd
    }

    /// The shell that resolves `$f` — the transcript file a tab's agent is
    /// writing (its own pinned path first, else the newest store in the
    /// folder, floored by `since`). Shared by the one-shot tail and the
    /// beautified view's incremental reader.
    private nonisolated static func transcriptLocatePrefix(
        path: String, since: Int, agent: String?, pinnedWindow: Int?,
        pin: TranscriptPin = TranscriptPin()) -> String {
        var cmd = "f=\"\"; pe=\"\"; "
        // Kimi records no per-window path, so the session's own id (pinned
        // by the engine once this launch's journal appeared) names its file.
        if agent == "kimi", let id = pin.kimiSession, AgentSessionLocator.isKimiSessionID(id) {
            cmd += AgentSessionLocator.kimiPinnedFragment(id: id, into: "f")
        } else if agent == "grok", let id = pin.grokSession, AgentSessionLocator.isConversationUUID(id) {
            // The session's own conversation, or nothing yet (`pe`): never
            // the folder's newest, which may be another session's.
            cmd += AgentSessionLocator.grokPinnedFragment(id: id, into: "f") + "[ -z \"$f\" ] && pe=1; "
        } else if agent == "codex", let id = pin.codexSession, AgentSessionLocator.isConversationUUID(id) {
            cmd += AgentSessionLocator.codexPinnedFragment(id: id, into: "f") + "[ -z \"$f\" ] && pe=1; "
        } else if agent == "omp", let id = pin.ompSession, AgentSessionLocator.isConversationUUID(id) {
            cmd += AgentSessionLocator.ompPinnedFragment(id: id, into: "f") + "[ -z \"$f\" ] && pe=1; "
        } else if let w = pinnedWindow {
            // The transcript the tab's agent itself named (its hook records the
            // path per window — see agent-status.sh) wins over "the newest file
            // in the folder": two agents in one folder (a delegate beside its
            // delegator) would otherwise take turns owning each other's view.
            // Still floored: a file older than this process is another's.
            cmd += AgentSessionLocator.pinnedPick(window: w, since: since)
        }
        cmd += "if [ -z \"$f\" ] && [ -z \"$pe\" ]; then "
            + AgentSessionLocator.locateBlock(path: path, since: since, agent: agent,
                                              kimiCreatedSince: pin.kimiCreatedSince,
                                              kimiExclude: pin.kimiExclude)
            + "fi; "
        return cmd
    }

    /// The beautified view's transcript reader: one round-trip that resolves
    /// the file and returns only what the host doesn't hold yet, so the view
    /// can keep the WHOLE conversation instead of re-reading a small tail on
    /// every poll. Output (empty when no transcript exists):
    ///
    ///     <file path>\n<pending-question line or empty>\n<file size>\n<start>\n<end>\n<bytes…>
    ///
    /// `tail` mode: when `$f` is `knownPath`, bytes from file offset
    /// `knownOffset` to the last complete line; otherwise (first read, another
    /// file, a truncated one) the last `bytes` of the file, aligned to a line.
    /// `earlier` mode: the `bytes` before `knownOffset` (the history's start),
    /// line-aligned, for "load earlier conversation". `start`/`end` are file
    /// offsets of the returned bytes; whole JSONL lines only, so the chunk is
    /// valid UTF-8 (the shell agent decodes stdout strictly) and the host can
    /// simply concatenate chunks.
    nonisolated static func transcriptChunkCommand(
        guestCwd: String, since: Int, agent: String? = nil, pinnedWindow: Int? = nil,
        pin: TranscriptPin = TranscriptPin(),
        knownPath: String?, knownOffset: Int, bytes: Int, earlier: Bool) -> String? {
        guard let path = AgentSessionLocator.sanitized(guestCwd: guestCwd)
        else { return nil }
        var cmd = transcriptLocatePrefix(path: path, since: since, agent: agent,
                                         pinnedWindow: pinnedWindow, pin: pin)
        cmd += "if [ -n \"$f\" ]; then printf '%s\\n' \"$f\"; "
        if agent == nil || agent == "claude" {
            // Same pending-AskUserQuestion dump as `planTranscriptCommand`,
            // on its own header line (it isn't part of the file, so it must
            // not land in the accumulated history).
            let enc2 = path.replacingOccurrences(of: ".", with: "-")
                .replacingOccurrences(of: "/", with: "-")
            let pq = "\"$HOME/.bromure/pq-\(enc2).json\""
            cmd += "if [ -n \"$(find \(pq) -newermt @\(AgentSessionLocator.findEpoch(since)) 2>/dev/null)\" ]; "
                + "then tr -d '\\n' < \(pq); fi; "
        }
        cmd += "echo; "
        let py = transcriptReaderPython
        cmd += "python3 - \"$f\" \(shellQuote(knownPath ?? "")) \(knownOffset) \(bytes) "
            + (earlier ? "earlier" : "tail")
            + " <<'BROMURE_PY' | iconv -f UTF-8 -t UTF-8 -c\n" + py + "\nBROMURE_PY\nfi"
        return cmd
    }

    /// The reader `transcriptChunkCommand` runs in the guest (argv: file,
    /// known path, offset, window bytes, "tail"|"earlier"); prints
    /// `size\nstart\nend\n` then the file's bytes [start, end) — whole
    /// lines only, `start` always at a line's beginning.
    ///
    /// Bounded both ways, so one exec never ships (or reads) far more than
    /// its window — what keeps a call over a slow tunnel inside its timeout:
    /// - a first read aligns BACK to the start of the line the window opens
    ///   in only within another window's worth; a longer line (a multi-MB
    ///   tool result or screenshot) is skipped forward past instead — unless
    ///   it is the last whole line, which must still show;
    /// - a tail read more than `tailJumpFactor` windows behind the file
    ///   (the chat was away while the agent wrote tens of MB) starts over
    ///   from a fresh window at the end; "load earlier" fetches the gap;
    /// - the line scans walk 64 KB blocks (the old first read loaded the
    ///   whole file before the window to find one newline: 86 MB for a
    ///   long Claude session).
    /// "Earlier" always makes progress: a line longer than the window comes
    /// back whole rather than as nothing (which stalled "load earlier").
    nonisolated static let tailJumpFactor = 4
    nonisolated static let transcriptReaderPython = #"""
    import sys, os
    f, known, off, want, mode = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
    try:
        size = os.path.getsize(f)
    except OSError:
        sys.exit(0)
    want = max(want, 1)
    BLK = 1 << 16
    def line_start(fh, pos, limit):
        # Start of the line holding byte `pos`; None when it begins more
        # than `limit` bytes back (limit None: no bound).
        p = pos
        floor = 0 if limit is None else max(0, pos - limit)
        while p > floor:
            q = max(floor, p - BLK)
            fh.seek(q)
            b = fh.read(p - q)
            j = b.rfind(b'\n')
            if j >= 0:
                return q + j + 1
            p = q
        return 0 if floor == 0 else None
    def next_line(fh, pos, end):
        # Offset just past the first newline in [pos, end); None if none.
        p = pos
        while p < end:
            fh.seek(p)
            b = fh.read(min(BLK, end - p))
            if not b:
                break
            j = b.find(b'\n')
            if j >= 0:
                return p + j + 1
            p += len(b)
        return None
    def whole_end(fh, start, end):
        # Offset just past the last newline in [start, end); start if none.
        p = end
        while p > start:
            q = max(start, p - BLK)
            fh.seek(q)
            b = fh.read(p - q)
            j = b.rfind(b'\n')
            if j >= 0:
                return q + j + 1
            p = q
        return start
    with open(f, 'rb') as fh:
        if mode == 'earlier':
            end = min(max(off, 0), size)
            s0 = max(0, end - want)
            start = 0
            if s0 > 0:
                nx = next_line(fh, s0, end)
                start = nx if nx is not None and nx < end else line_start(fh, max(end - 1, 0), None)
        else:
            fresh = (f != known) or off < 0 or off > size or (size - off) > want * TAILJUMP
            if fresh:
                s0 = max(0, size - want)
                start = 0
                if s0 > 0:
                    ls = line_start(fh, s0, want)
                    if ls is not None:
                        start = ls
                    else:
                        we = whole_end(fh, s0, size)
                        nx = next_line(fh, s0, we)
                        start = nx if nx is not None and nx < we else line_start(fh, s0, None)
            else:
                start = off
            end = whole_end(fh, start, size)
        sys.stdout.write('%d\n%d\n%d\n' % (size, start, end))
        sys.stdout.flush()
        fh.seek(start)
        left = end - start
        while left > 0:
            b = fh.read(min(1 << 20, left))
            if not b:
                break
            sys.stdout.buffer.write(b)
            left -= len(b)
    """#.replacingOccurrences(of: "TAILJUMP", with: String(tailJumpFactor))

    /// The guest command that dumps a task session's FULL transcript —
    /// session store keyed by worktree slug where the tool allows it
    /// (transcripts live in per-tool stores under the home, so this works
    /// long after the worktree itself was merged away), with the plain-tab
    /// marker fallback through the tab's cwd. The home is a persistent
    /// ext4 image, so this is readable for as long as the workspace exists
    /// — the board's Done cards read it on demand. `agent` picks the
    /// store; each task records the tool it ran.
    nonisolated static func taskTranscriptCommand(
        branch: String, agent: Profile.Tool = .claude) -> String? {
        guard branch.hasPrefix("wt/") else { return nil }
        let slug = String(branch.dropFirst(3))
        guard !slug.isEmpty,
              slug.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" })
        else { return nil }
        // The tab's cwd through the wt/ marker — how every store copes
        // with a NON-REPO run (plain tab at the automation's own path,
        // where nothing is named after the slug). Only works while the
        // tab still exists.
        let markerCwd =
            "cwd=$(tmux -u list-windows -t bromure -F '#{@worktree}\t#{pane_current_path}' "
            + "2>/dev/null | awk -F'\t' -v b='wt/\(slug)' '$1==b {print $2; exit}'); "
        let emit = "if [ -n \"$f\" ]; then head -c 25000000 \"$f\" "
            + "| iconv -f UTF-8 -t UTF-8 -c; fi"
        switch agent {
        case .claude:
            return "d=$(ls -td ~/.claude/projects/*-\(slug) 2>/dev/null | head -1); "
                + "if [ -z \"$d\" ]; then "
                + markerCwd
                + "if [ -n \"$cwd\" ]; then "
                // Claude's real project-dir rule (flatten every non-alnum, keyed
                // off the PHYSICAL path) first; the old two encodings after, for
                // transcripts of older sessions.
                + "rc=$(readlink -f \"$cwd\" 2>/dev/null || printf %s \"$cwd\"); "
                + "e1=$(printf %s \"$cwd\" | tr -c 'a-zA-Z0-9' '-'); "
                + "e2=$(printf %s \"$rc\" | tr -c 'a-zA-Z0-9' '-'); "
                + "e3=$(printf %s \"$cwd\" | tr / -); e4=$(printf %s \"$cwd\" | tr ./ --); "
                + "d=$(ls -td \"$HOME/.claude/projects/$e1\" \"$HOME/.claude/projects/$e2\" "
                + "\"$HOME/.claude/projects/$e3\" \"$HOME/.claude/projects/$e4\" "
                + "2>/dev/null | head -1); fi; fi; "
                + "f=$(ls -t \"$d\"/*.jsonl 2>/dev/null | head -1); "
                + emit
        case .kimi:
            // Workspace bucket by slug glob (a worktree's basename IS the
            // slug, "-N" when the guest deduped it); the cwd-derived
            // slug+hash covers non-repo runs. Main-agent journal only,
            // newest session wins.
            return "d=$(ls -td ~/.kimi-code/sessions/wd_\(kimiSlug(slug))_* "
                + "~/.kimi-code/sessions/wd_\(slug)-[0-9]*_* 2>/dev/null | head -1); "
                + "if [ -z \"$d\" ]; then "
                + markerCwd
                + "if [ -n \"$cwd\" ]; then "
                + "kb=$(basename \"$cwd\" | LC_ALL=C tr 'A-Z' 'a-z' "
                + "| LC_ALL=C sed -E 's/[^a-z0-9._-]+/-/g;s/^-+//;s/-+$//' "
                + "| cut -c1-40 | sed -E 's/-+$//'); "
                + "case \"$kb\" in ''|.|..) kb=workspace;; esac; "
                + "kh=$(printf %s \"$cwd\" | sha256sum | cut -c1-12); "
                + "kr=$(printf %s \"$(readlink -f \"$cwd\" 2>/dev/null || printf %s \"$cwd\")\" "
                + "| sha256sum | cut -c1-12); "
                + "d=$(ls -td \"$HOME/.kimi-code/sessions/wd_${kb}_$kh\" "
                + "\"$HOME/.kimi-code/sessions/wd_${kb}_$kr\" 2>/dev/null | head -1); fi; fi; "
                + "f=$(find \"$d\" \\( -path '*/agents/main/wire.jsonl' "
                + "-o \\( -name wire.jsonl ! -path '*/agents/*' \\) \\) 2>/dev/null "
                + "| xargs -r ls -t 2>/dev/null | head -1); "
                + emit
        case .codex:
            // Rollouts are date-keyed; match by the session_meta cwd — the
            // tab's exact cwd when the tab still exists, a "/<slug>" path
            // suffix afterwards (the worktree's basename is the slug).
            return markerCwd
                + "rc=$(readlink -f \"$cwd\" 2>/dev/null || printf %s \"$cwd\"); f=\"\"; "
                + "for c in $(find \"$HOME/.codex/sessions\" -name 'rollout-*.jsonl' "
                + "2>/dev/null | xargs -r ls -t 2>/dev/null | head -48); do "
                + "if [ -n \"$cwd\" ]; then head -c 8192 \"$c\" 2>/dev/null "
                + "| grep -qF -e \"\\\"cwd\\\":\\\"$cwd\\\"\" -e \"\\\"cwd\\\":\\\"$rc\\\"\" "
                + "&& { f=\"$c\"; break; }; "
                + "else head -c 8192 \"$c\" 2>/dev/null "
                + "| grep -qE '\"cwd\":\"[^\"]*/\(slug)(-[0-9]+)?\"' "
                + "&& { f=\"$c\"; break; }; fi; done; "
                + emit
        case .grok:
            // Per-cwd store: exact percent-encoded cwd while the tab
            // exists; the encoded name ends in "%2F<slug>" afterwards.
            return markerCwd
                + "f=\"\"; if [ -n \"$cwd\" ]; then "
                + "eg=$(python3 -c 'import urllib.parse,sys;"
                + "print(urllib.parse.quote(sys.argv[1],safe=\"\"))' \"$cwd\" 2>/dev/null); "
                + "er=$(python3 -c 'import urllib.parse,sys;"
                + "print(urllib.parse.quote(sys.argv[1],safe=\"\"))' "
                + "\"$(readlink -f \"$cwd\" 2>/dev/null || printf %s \"$cwd\")\" 2>/dev/null); "
                + "[ -n \"$eg$er\" ] && f=$(find ${eg:+\"$HOME/.grok/sessions/$eg\"} "
                + "${er:+\"$HOME/.grok/sessions/$er\"} -maxdepth 2 -name updates.jsonl "
                + "2>/dev/null | sort -u | xargs -r ls -t 2>/dev/null | head -1); fi; "
                + "if [ -z \"$f\" ]; then "
                + "d=$(ls -td \"$HOME/.grok/sessions/\"*%2F\(slug) "
                + "\"$HOME/.grok/sessions/\"*%2F\(slug)-[0-9]* 2>/dev/null | head -1); "
                + "[ -n \"$d\" ] && f=$(find \"$d\" -maxdepth 2 -name updates.jsonl "
                + "2>/dev/null | xargs -r ls -t 2>/dev/null | head -1); fi; "
                + emit
        case .omp:
            // omp names each session dir after the run's cwd with '/' → '-'
            // (e.g. /home/ubuntu/wt-foo → -home-ubuntu-wt-foo); the transcript
            // is the newest `*.jsonl` inside. Prefer the marker cwd's dir (exact
            // + readlink-resolved), else newest session overall.
            return markerCwd
                + "base=\"${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}/sessions\"; d=\"\"; "
                + "if [ -n \"$cwd\" ]; then "
                + "s1=$(printf %s \"$cwd\" | tr / -); "
                + "s2=$(printf %s \"$(readlink -f \"$cwd\" 2>/dev/null || printf %s \"$cwd\")\" | tr / -); "
                + "d=$(ls -td \"$base/$s1\" \"$base/$s2\" 2>/dev/null | head -1); fi; "
                + "f=$(find \"${d:-$base}\" -name '*.jsonl' 2>/dev/null "
                + "| xargs -r ls -t 2>/dev/null | head -1); "
                + emit
        }
    }

    /// A worktree slug as Kimi names its workspace bucket
    /// (`AgentSessionLocator.kimiWorkDirSlug`: a long task title's slug is
    /// cut to 40 — the full-slug glob never matched it).
    nonisolated static func kimiSlug(_ slug: String) -> String {
        AgentSessionLocator.kimiWorkDirSlug(slug)
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
        // Kimi Code's session store is keyed by an opaque workspace id
        // `wd_<dir-basename-slug>_<hash>` under ~/.kimi-code/sessions — and a
        // worktree's directory basename IS the slug (or "<slug>-N" on the
        // guest's dedup path), so the glob finds the run's bucket without
        // recomputing the hash. Globbed alongside Claude's tree rather than
        // instead of it: a run uses one agent, so at most one can match, and
        // the probe stays tool-agnostic.
        return "d=$(ls -td ~/.claude/projects/*-\(slug) "
            + "~/.kimi-code/sessions/wd_\(kimiSlug(slug))_* "
            + "~/.kimi-code/sessions/wd_\(slug)-[0-9]*_* 2>/dev/null | head -1); "
            + "if [ -z \"$d\" ]; then "
            + "cwd=$(tmux -u list-windows -t bromure -F '#{@worktree}\t#{pane_current_path}' "
            + "2>/dev/null | awk -F'\t' -v b='wt/\(slug)' '$1==b {print $2; exit}'); "
            + "if [ -n \"$cwd\" ]; then "
            + "rc=$(readlink -f \"$cwd\" 2>/dev/null || printf %s \"$cwd\"); "
            + "e1=$(printf %s \"$cwd\" | tr -c 'a-zA-Z0-9' '-'); "
            + "e2=$(printf %s \"$rc\" | tr -c 'a-zA-Z0-9' '-'); "
            + "e3=$(printf %s \"$cwd\" | tr / -); e4=$(printf %s \"$cwd\" | tr ./ --); "
            + "d=$(ls -td \"$HOME/.claude/projects/$e1\" \"$HOME/.claude/projects/$e2\" "
            + "\"$HOME/.claude/projects/$e3\" \"$HOME/.claude/projects/$e4\" "
            + "2>/dev/null | head -1); fi; fi; "
            // The WHOLE tree, recursively: subagent transcripts land as
            // separate files (agent-*.jsonl, possibly nested), and a probe
            // watching only the newest top-level session file reads "quiet"
            // while five agents are hard at work.
            + "newest=$(find \"$d\" -type f \\( -name '*.jsonl' -o -name '*.json' \\) "
            + "-printf '%T@\\n' "
            + "2>/dev/null | sort -rn | head -1 | cut -d. -f1); "
            + "if [ -n \"$newest\" ]; then echo $(( $(date +%s) - newest )); fi"
    }

    /// "The repo has a HEAD" — an empty root commit when it doesn't.
    /// Worktrees can't be cut from a commit-less repo, and that's git's
    /// actual requirement (a commit, not files — no README needed).
    private nonisolated static let ensureHeadFragment =
        "{ git rev-parse -q --verify HEAD >/dev/null 2>&1 || "
        + "git -c user.name=Bromure -c user.email=tasks@bromure.io "
        + "commit -q --allow-empty -m 'task root'; }"

    /// The guest command that makes a task's directory usable: mkdir -p,
    /// git init when the directory isn't already its own repo root, and an
    /// empty root commit when the repo has no HEAD (worktrees need one).
    nonisolated static func initRepoCommand(quotedPath: String) -> String {
        "mkdir -p \(quotedPath) && cd \(quotedPath) && "
            + "{ [ \"$(git rev-parse --show-toplevel 2>/dev/null)\" = \"$(pwd -P)\" ] "
            + "|| git init -q; } && " + ensureHeadFragment
    }

    /// The guest command that clones `quotedURL` into `quotedPath` for a task
    /// with a clone URL — only when the folder holds no repository yet: an
    /// existing repo is left untouched (restarts never re-clone over work),
    /// a non-empty non-repo folder is refused rather than clobbered. Never
    /// prompts: a missing credential fails fast instead of hanging the
    /// start; an unknown SSH host is pinned on first contact.
    nonisolated static func cloneRepoCommand(quotedPath: String, quotedURL: String) -> String {
        "if git -C \(quotedPath) rev-parse --show-toplevel >/dev/null 2>&1; then :; "
            + "elif [ -e \(quotedPath) ] && [ -n \"$(ls -A \(quotedPath) 2>/dev/null)\" ]; then "
            + "echo 'the folder exists and is not a git repository' >&2; exit 3; "
            + "else mkdir -p \"$(dirname \(quotedPath))\" && "
            + "GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=accept-new -o BatchMode=yes' "
            + "git clone --quiet \(quotedURL) \(quotedPath) 2>&1 | tail -5 >&2; "
            + "test \"${PIPESTATUS[0]}\" -eq 0; fi"
    }

    /// Run the task's clone (if it has a URL). nil = fine (cloned, or
    /// nothing to do); otherwise the reason to revert the start with.
    private func cloneIfRequested(_ task: CodingTask, profileID: UUID,
                                  quotedPath: String) async -> String? {
        guard let url = task.effectiveCloneURL, let delegate else { return nil }
        let qu = "'" + url.replacingOccurrences(of: "'", with: "'\\''") + "'"
        BACDebug.log("tasks", "“\(task.title)”: cloning \(url) → \(task.repoPath)")
        do {
            // A big repo takes a while — well past the usual exec timeout.
            _ = try await delegate.guestExec(
                profileID: profileID,
                command: "bash -c " + Self.shellQuote(
                    Self.cloneRepoCommand(quotedPath: quotedPath, quotedURL: qu)),
                timeout: 900)
            return nil
        } catch {
            return String(format: NSLocalizedString("Couldn't clone %@ — %@", comment: "task start"),
                          url, error.localizedDescription)
        }
    }

    nonisolated static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// HEAD-ensure alone, for repos the USER initialized: a brand-new
    /// `git init` with no commits can't host worktrees, so every phase
    /// start would fail. Unlike `initRepoCommand` this never runs
    /// `git init` — a task pointing into a monorepo subdirectory must not
    /// grow a nested repo.
    nonisolated static func ensureHeadCommand(quotedPath: String) -> String {
        "cd \(quotedPath) && " + ensureHeadFragment
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
    /// keystrokes — the picker debounces and swallows bursts. Every DIGIT
    /// is gated on the picker still being on screen: the picker
    /// instant-commits (a digit can answer AND submit), so a scripted
    /// sequence can outlive it by a key — an ungated late digit lands as
    /// stray text in the chat input. Named keys stay ungated (a stray
    /// Enter on an empty input is invisible; refusing the final Enter on a
    /// submit stop whose footer reads differently would break submission).
    /// True (exit 0) while an agent's option picker is ON SCREEN in `tabIndex`.
    ///
    /// Claude Code ships TWO footers and both have to match. Single-select ends
    /// "Enter to select"; multi-select ends "Space to toggle, Enter to confirm,
    /// a to select all, …" — which does NOT contain "Enter to select", so a
    /// probe for that string alone silently refused to answer every
    /// multiple-choice question, the exact shape a remote reader most needs.
    nonisolated static func pickerVisibleCommand(tabIndex: Int) -> String {
        "tmux capture-pane -p -t bromure:\(tabIndex) 2>/dev/null "
            + "| grep -qE 'Enter to (select|confirm)'"
    }

    /// By index (the window is resolved to its id once, and re-checked —
    /// an agent in front — before every key); `PaneTypeGuard.answerKeysCommand`
    /// takes a stable identity when the caller has one.
    nonisolated static func answerKeysCommand(tabIndex: Int, keys: [String]) -> String {
        PaneTypeGuard.answerKeysCommand(target: .index(tabIndex), keys: keys)
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
        let probe = Self.pickerVisibleCommand(tabIndex: index)
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
        // By the task's branch, re-checked before every key: the index
        // probed above may name another tab by now.
        return (try? await delegate.guestExec(
            profileID: profileID,
            command: PaneTypeGuard.answerKeysCommand(target: .task(branch: branch), keys: keys),
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

    /// Type text into a live session's agent — the plan window's input box.
    /// Only while the agent is RUNNING in the tab: one that exited leaves a
    /// bare shell, which would run the text as commands. False then (the
    /// caller says so); review send-back resumes the conversation instead
    /// (`deliverToConversation`).
    func typeIntoSession(profileID: UUID, branch: String, text: String) async -> Bool {
        guard let delegate,
              let index = await tabIndex(profileID: profileID, branch: branch),
              await agentAlive(profileID: profileID, windowIndex: index, branch: branch),
              let out = await PaneTypeGuard.runType(target: .task(branch: branch), text: text, exec: {
                  try? await delegate.guestExec(profileID: profileID, command: $0, timeout: 20)
              })
        else { return false }
        // Held (a menu or approval dialog is up) or failed: the box keeps it.
        return PaneTypeGuard.typed(in: out)
    }

    // MARK: Planning watchdog

    private var planWatchdogs: [UUID: Task<Void, Never>] = [:]
    /// Tasks whose done signal arrived and is settling (see
    /// waitForSessionQuiet) — later Stop signals are ignored meanwhile.
    var settling: Set<UUID> = []

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
        let scheduledAt = Date()
        let key = Self.pendingCloseKey(profileID: profileID, branch: branch)
        let token = UUID()
        let task = Task { [weak self] in
            defer { self?.tabCloses.finish(key, token: token) }
            // The tabs to close are the ones there NOW, by window id: a tab
            // the task opens on the same branch during the grace (Start right
            // after Stop & Return to Backlog) is a new window and is spared.
            guard let first = self?.delegate,
                  let ids = try? await first.guestExec(
                    profileID: profileID, command: Self.windowIDsCommand(branch: branch), timeout: 10)
            else { return }
            let windows = ids.split(whereSeparator: \.isNewline).map(String.init)
                .filter(PaneTypeGuard.isWindowID)
            try? await Task.sleep(nanoseconds: afterSeconds * 1_000_000_000)
            guard let delegate = self?.delegate else { return }
            // The run is finished: its session is put away with the tab,
            // not left as Ended. Just before the kill — archiving ends the
            // agent too, and the grace above is for its last words.
            // Restarted meanwhile (the task's new tab carries the same
            // branch): only sessions provably on the closing windows go.
            let restarted = self?.store.tasks.contains { t in
                t.profileID == profileID && (t.branch == branch || t.branchSlug.map { "wt/" + $0 } == branch)
                    && (t.startedAt ?? .distantPast) > scheduledAt
            } ?? false
            delegate.archiveFinishedSession(profileID: profileID, worktreeBranch: branch,
                                            windowIDs: Set(windows), strict: restarted)
            guard !windows.isEmpty else { return }
            let cmd = windows.map { "tmux kill-window -t '\($0)' 2>/dev/null" }.joined(separator: "; ") + "; true"
            _ = try? await delegate.guestExec(profileID: profileID,
                                              command: cmd, timeout: 15)
            BACDebug.log("tasks", "closed session tab for \(branch)")
        }
        tabCloses.register(key, token: token, task: task)
    }

    /// Tab closes scheduled by `closeSessionTab` and not done yet, by
    /// workspace + branch. A Start right after Stop & Return to Backlog
    /// waits for its branch's: until then the old tab is still there,
    /// carrying the branch, and the resume brief went into it — moments
    /// before it was killed.
    let tabCloses = PendingWork()

    private static func pendingCloseKey(profileID: UUID, branch: String) -> String {
        "\(profileID.uuidString)|\(branch)"
    }

    /// Whether a close of `branch`'s tab is still pending.
    func hasPendingTabClose(profileID: UUID, branch: String) -> Bool {
        tabCloses.isPending(Self.pendingCloseKey(profileID: profileID, branch: branch))
    }

    /// Wait until no close of `branch`'s tab is pending (one scheduled
    /// meanwhile is waited for too).
    func awaitPendingTabClose(profileID: UUID, branch: String) async {
        await tabCloses.wait(Self.pendingCloseKey(profileID: profileID, branch: branch))
    }

    /// Put-aways under way, by task: the branch is resolved first when
    /// the pane roster doesn't know it (a detached workspace), and the
    /// close it schedules must not be missed by a Start in that gap.
    let putAways = PendingWork()

    /// Wait until the task's put-away — branch resolution, archive, and
    /// the tab's kill — is over.
    func awaitPutAway(_ taskID: UUID) async {
        await putAways.wait(taskID.uuidString)
    }

    /// The tmux window ids of the tabs tagged with `branch`, one per line.
    nonisolated static func windowIDsCommand(branch: String) -> String {
        "tmux list-windows -t bromure -F '#{window_id} #{@worktree}' 2>/dev/null "
            + "| awk -v b='\(branch)' '$2==b {print $1}'"
    }

    private func abortPlanning(_ taskID: UUID, reason: String) {
        planWatchdogs[taskID]?.cancel()
        planWatchdogs[taskID] = nil
        guard let t = store.task(taskID), t.stage == .backlog,
              t.validationRequestedAt != nil else { return }
        // Phases already landed? Then the session ending is just... done.
        if let done = t.validatedAt, let req = t.validationRequestedAt,
           done >= req { return }
        // A streamed driver may still be running (timeout abort) — tear it
        // down; safe no-op when the stream is already gone.
        if let slug = t.branchSlug {
            delegate?.endPlanStream(profileID: t.profileID, branch: "wt/" + slug)
        }
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
                    // a beat to print its summary, then close its tab. A
                    // streamed session has no tab (liveBranch is nil for it)
                    // — send the driver its end command instead, or the
                    // whole agent stack leaks in the guest until VM shutdown.
                    if let branch = self.liveBranch(of: t) {
                        self.closeSessionTab(profileID: profileID,
                                             branch: branch, afterSeconds: 20)
                    }
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 20_000_000_000)
                        self?.delegate?.endPlanStream(profileID: profileID,
                                                      branch: "wt/" + slug)
                    }
                    return
                }
                if Date().timeIntervalSince(started) > 3600 {
                    self.abortPlanning(taskID, reason: NSLocalizedString(
                        "The planning session timed out without filing phases — click Plan First to retry.",
                        comment: "plan watchdog"))
                    return
                }
                // A streamed (driver-mode) planning session has no tmux tab
                // at all — its liveness is the vsock event stream, and its
                // death arrives as a result/fatal event through
                // planStreamEnded. Treat "streaming" as "tab present, agent
                // running" so the tab checks below can't abort it.
                if delegate.planStreamLive(profileID: profileID,
                                           branch: "wt/" + slug) {
                    seenTab = true
                    sawAgent = true
                    bareShellPolls = 0
                    continue
                }
                // Pane roster when attached; guest tmux when the session
                // runs detached (planning boots the VM headless).
                let index = await self.tabIndex(profileID: profileID,
                                                branch: "wt/" + slug)
                guard let index else {
                    if seenTab || Date().timeIntervalSince(started) > 240 {
                        self.abortPlanning(taskID, reason: seenTab
                            ? NSLocalizedString(
                                "The planning session ended before filing phases — click Plan First to retry.",
                                comment: "plan watchdog")
                            : String(format: NSLocalizedString(
                                "The planning session didn't start — %@ may not be set up in this workspace. Open a session there to check, then click Plan First to retry.",
                                comment: "plan watchdog"), t.tool.displayName))
                        return
                    }
                    continue
                }
                seenTab = true
                // Did the agent exit back to a bare shell (user quit claude)?
                // Asked of the pane's process tree: tmux's foreground
                // command names the shell while a Kimi started from .bashrc runs.
                guard let state = await self.agentState(profileID: profileID, windowIndex: index)
                else { continue }
                if state == .shell {
                    if sawAgent {
                        bareShellPolls += 1
                        if bareShellPolls >= 2 {
                            self.abortPlanning(taskID, reason: String(format: NSLocalizedString(
                                "%@ exited before filing phases — click Plan First to retry.",
                                comment: "plan watchdog"), t.tool.displayName))
                            return
                        }
                    }
                } else if case .running = state {
                    sawAgent = true
                    bareShellPolls = 0
                }
            }
        }
    }

    /// Streamed (driver-mode) planning ended — the terminal plan-stream
    /// event, the counterpart of the tab path's Stop signal. Judge
    /// filed-vs-not the same way; there is no tab to close.
    func planStreamEnded(profileID: UUID, branch: String, ok: Bool,
                         error: String?) {
        guard branch.hasPrefix("wt/") else { return }
        let slugPart = String(branch.dropFirst(3))
        guard let parent = store.tasks.first(where: { t in
            guard t.stage == .backlog, t.validationRequestedAt != nil,
                  t.profileID == profileID, let slug = t.branchSlug
            else { return false }
            return slugPart == slug || (slugPart.hasPrefix(slug + "-")
                && Int(slugPart.dropFirst(slug.count + 1)) != nil)
        }) else { return }
        if store.task(parent.id)?.validationInFlight == true {
            abortPlanning(parent.id, reason: (error?.isEmpty == false ? error! : nil)
                ?? NSLocalizedString(
                    "The planning session ended before filing phases — click Plan First to retry.",
                    comment: "plan watchdog"))
        } else {
            BACDebug.log("tasks", "“\(parent.title)”: streamed planning complete")
            store.mutate(parent.id) { $0.planCompletedAt = Date() }
            planWatchdogs[parent.id]?.cancel()
            planWatchdogs[parent.id] = nil
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
                    "The planning session was interrupted — click Plan First to retry.",
                    comment: "plan watchdog"))
            }
        }
    }

    // MARK: Completion housekeeping (transcript archive + worktree cleanup)

    /// A card reached Done: pull the session transcript into the host
    /// archive — durable across branch deletion, workspace deletion, even
    /// the VM — then optionally drop the worktree + branch in the guest.
    /// Strictly in that order; cleanup must never outrun the archive.
    func archiveTranscriptThenCleanup(_ taskID: UUID, removeWorktree: Bool,
                                      removeIfEmpty: Bool = false) {
        guard let task = store.task(taskID) else { return }
        let branch = task.branch
        let root = task.rootRepo
        let profileID = task.profileID
        Task { [weak self] in
            guard let self, let delegate = self.delegate else { return }
            // A beat for the Stop hook's final transcript lines to land
            // (same courtesy as the automation pull).
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !TaskTranscriptArchive.has(taskID),
               let text = await delegate.fetchTaskTranscriptRaw(task), !text.isEmpty {
                TaskTranscriptArchive.save(text, taskID: taskID)
                BACDebug.log("tasks", "“\(task.title)”: transcript archived "
                    + "(\(text.utf8.count) bytes)")
            }
            var remove = removeWorktree
            if !remove, removeIfEmpty, let branch, let root, !root.isEmpty,
               let parent = task.parentBranch, !parent.isEmpty,
               let out = try? await delegate.guestExec(
                profileID: profileID,
                command: Self.emptyBranchCommand(root: root, branch: branch, parent: parent,
                                                 worktreeDir: task.worktreeDir),
                timeout: 15),
               out.contains("EMPTY") {
                remove = true
            }
            if remove, let branch, let root, !root.isEmpty {
                _ = delegate.automationWorktreeCommand(
                    profileNameOrID: profileID.uuidString,
                    action: "remove", args: [root, branch])
                BACDebug.log("tasks", "“\(task.title)”: worktree removed (\(branch))")
            }
        }
    }

    /// Prints EMPTY when `branch` adds no commit to `parent` and its
    /// checkout has nothing uncommitted (ignored files and build/cache
    /// litter don't count — `TaskLitter`).
    nonisolated static func emptyBranchCommand(root: String, branch: String, parent: String,
                                               worktreeDir: String?) -> String {
        var cmd = "[ \"$(git -C \(shellQuote(root)) rev-list --count \(shellQuote(parent + ".." + branch)) 2>/dev/null)\" = 0 ] || exit 0; "
        if let wt = worktreeDir, !wt.isEmpty {
            cmd += "[ -z \"$(\(TaskLitter.status(shellQuote(wt))))\" ] || exit 0; "
        }
        return cmd + "echo EMPTY"
    }

    // MARK: Review → Done
    //
    // Landing (merge / pull request) lives in CodingTaskLanding.swift.

    /// Done as it stands — nothing merged, nothing removed: the worktree and
    /// its branch stay exactly where they are (merged by hand, or kept, or a
    /// task that produced no code). The agent's session is put away; the
    /// transcript is archived as for any finished task. From Review, or
    /// straight from In Progress (the agent is stopped).
    func markDone(_ taskID: UUID) {
        guard let task = store.task(taskID),
              task.stage == .testing || task.stage == .inProgress else { return }
        store.mutate(taskID) {
            $0.stage = .done
            $0.completedAt = Date()
            $0.merged = false
            $0.prOpened = nil
            $0.landing = nil
            $0.lastError = nil
            $0.completion = .markedDone(byUser: true)
        }
        BACDebug.log("tasks", "“\(task.title)”: marked done")
        putSessionAway(task)
        rollUpBrief(afterPhaseDone: taskID)
        pumpQueue()
        // A branch with nothing on it (a task that produced no code) goes
        // with it — kept, it's just litter in the Branches window.
        archiveTranscriptThenCleanup(taskID, removeWorktree: false,
                                     removeIfEmpty: task.delegationID == nil)
    }

    /// Discard: Done without merging, the worktree and its branch removed.
    /// The archived transcript keeps the record of what the agent did.
    func closeWithoutMerge(_ taskID: UUID) {
        guard let task = store.task(taskID), task.stage != .done else { return }
        store.mutate(taskID) {
            $0.stage = .done
            $0.completedAt = Date()
            $0.merged = false
            $0.prOpened = nil
            $0.landing = nil
            $0.completion = .closedWithoutMerge
        }
        putSessionAway(task)
        rollUpBrief(afterPhaseDone: taskID)
        pumpQueue()
        archiveTranscriptThenCleanup(taskID, removeWorktree: true)
    }

    /// Stop the agent and put the task back in the Backlog — nothing is
    /// deleted: the worktree and its branch stay in the workspace (the
    /// Branches window finds them), the card is a plain brief again.
    /// Only a task In Progress has an agent at work to stop: anything else
    /// is refused with the reason (nil = stopped), never a silent no-op.
    @discardableResult
    func stopToBacklog(_ taskID: UUID) -> String? {
        guard let task = store.task(taskID) else {
            return NSLocalizedString("No such task.", comment: "task stop refused")
        }
        guard task.stage == .inProgress else { return Self.stopRefusal(task.stage) }
        if task.delegationID != nil {
            delegate?.taskDispatcher.recall(taskID)
            return nil
        }
        // The branch is remembered (not just left in the workspace): the
        // next start resumes on it rather than orphaning it for a new one.
        // So is its worktree metadata (parent branch, checkout, repo root),
        // read off the live tab before it is put away — the resume tags the
        // new tab with the parent branch.
        let kept = task.branch ?? liveBranch(of: task) ?? task.branchSlug.map { "wt/" + $0 }
        let tab = kept.flatMap { b in
            delegate?.pane(for: task.profileID)?.model.tabs.first { $0.worktreeBranch == b } }
        putSessionAway(task)
        store.mutate(taskID) {
            if let tab {
                if ($0.parentBranch ?? "").isEmpty, let p = tab.parentBranch, !p.isEmpty { $0.parentBranch = p }
                if ($0.rootRepo ?? "").isEmpty, let r = tab.rootRepo, !r.isEmpty { $0.rootRepo = r }
                if ($0.worktreeDir ?? "").isEmpty {
                    let d = tab.repoRoot?.isEmpty == false ? tab.repoRoot : tab.cwd
                    if let d, !d.isEmpty { $0.worktreeDir = d }
                }
            }
            $0.stage = .backlog
            $0.startedAt = nil
            $0.branchSlug = nil
            $0.branch = nil
            $0.resumeBranch = kept
            $0.lastError = nil
            $0.restartNeeded = nil
        }
        BACDebug.log("tasks", "“\(task.title)”: stopped, back to the backlog")
        pumpQueue()
        return nil
    }

    /// Why Stop & Return to Backlog doesn't apply to a task in `stage`.
    nonisolated static func stopRefusal(_ stage: CodingTask.Stage) -> String {
        switch stage {
        case .testing:
            return NSLocalizedString(
                "The task is in Review: its agent has finished. Send it back to In Progress, or discard its branch, instead.",
                comment: "task stop refused")
        case .done:
            return NSLocalizedString("The task is done: there's no agent to stop.", comment: "task stop refused")
        case .backlog, .planning:
            return NSLocalizedString("The task isn't running: there's no agent to stop.", comment: "task stop refused")
        case .inProgress:
            return ""
        }
    }

    /// End a task's agent session: archive it and close its tab — resolved
    /// in the guest when the workspace runs detached (no pane roster here).
    /// A task done by someone else's session leaves that session alone.
    /// Registered at once (`putAways`), whichever way the branch is found,
    /// so a Start in the grace waits for all of it.
    func putSessionAway(_ task: CodingTask, afterSeconds: UInt64 = 3) {
        guard task.delegationID == nil else { return }
        let key = task.id.uuidString
        let token = UUID()
        if let b = task.branch ?? liveBranch(of: task) {
            closeSessionTab(profileID: task.profileID, branch: b, afterSeconds: afterSeconds)
            let work = Task { [weak self] in
                await self?.awaitPendingTabClose(profileID: task.profileID, branch: b)
                self?.putAways.finish(key, token: token)
            }
            putAways.register(key, token: token, task: work)
            return
        }
        guard task.branchSlug != nil else { return }
        let work = Task { [weak self] in
            defer { self?.putAways.finish(key, token: token) }
            guard let self, let b = await self.liveBranchResolved(of: task) else { return }
            self.closeSessionTab(profileID: task.profileID, branch: b, afterSeconds: afterSeconds)
            await self.awaitPendingTabClose(profileID: task.profileID, branch: b)
        }
        putAways.register(key, token: token, task: work)
    }

    /// Manual Review → In Progress with no feedback (the user just wants
    /// the agent back at work), and manual In Progress → Review for agents
    /// that never signal done.
    func moveToInProgress(_ taskID: UUID) {
        store.mutate(taskID) {
            if $0.stage == .testing || $0.stage == .planning {
                $0.stage = .inProgress
                $0.landing = nil   // cancels a landing under way
            }
        }
    }

    func moveToTesting(_ taskID: UUID) {
        guard let task = store.task(taskID), task.stage == .inProgress else { return }
        agentFinished(profileID: task.profileID,
                      worktreeBranch: liveBranch(of: task))
        // No live tab to derive metadata from → still move, without it.
        if store.task(taskID)?.stage == .inProgress {
            store.mutate(taskID) { $0.stage = .testing; $0.testingAt = Date(); $0.lastError = nil }
        }
    }

    /// Whether a board task that isn't finished owns the tab on `branch`
    /// (its `@worktree` tag is the task's mark): such a tab is never ended
    /// on behalf of a session that was put away — it's the task's relaunch.
    func ownsLiveTab(profileID: UUID, branch: String) -> Bool {
        Self.taskOwnsTab(store.tasks, profileID: profileID, branch: branch)
    }

    nonisolated static func taskOwnsTab(_ tasks: [CodingTask], profileID: UUID, branch: String) -> Bool {
        guard branch.hasPrefix("wt/") else { return false }
        return tasks.contains { t in
            guard t.profileID == profileID, t.stage != .done else { return false }
            if t.branch == branch { return true }
            if let slug = t.branchSlug {
                return AutomationBoard.branchMatches(branch, slug: slug) || branch == "wt/" + slug
            }
            return false
        }
    }

    /// The board task a session (or a tab on `branch`) works on.
    func task(profileID: UUID, sessionID: UUID?, branch: String?) -> CodingTask? {
        if let sid = sessionID, let t = store.tasks.first(where: { $0.sessionID == sid && $0.stage != .done }) {
            return t
        }
        guard let b = branch, b.hasPrefix("wt/") else { return nil }
        return store.tasks.first { t in
            t.profileID == profileID && t.stage != .done
                && (t.branch == b || t.branchSlug.map { AutomationBoard.branchMatches(b, slug: $0) } == true)
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


extension CodingTaskEngine {
    /// Type `text` into an agent's tab with `guardedTypeCommand`, trying
    /// again every few seconds while a menu or dialog is open there, for up
    /// to `patience`. True once it went in. Never when the tab turns out to
    /// be someone else's or shows a shell (`PaneTypeGuard`).
    @MainActor
    static func typeWhenFree(_ delegate: ACAppDelegate, profileID: UUID, tabIndex: Int, text: String,
                             patience: TimeInterval = 600) async -> Bool {
        await typeWhenFree(delegate, profileID: profileID, target: .index(tabIndex), text: text,
                           patience: patience)
    }

    @MainActor
    static func typeWhenFree(_ delegate: ACAppDelegate, profileID: UUID, target: PaneTarget, text: String,
                             patience: TimeInterval = 600) async -> Bool {
        await typeWhenFreeResult(delegate, profileID: profileID, target: target, text: text,
                                 patience: patience) == .typed
    }

    /// The same, through any machine's exec (an attached Mac's, say).
    static func typeWhenFree(exec: @escaping (String) async throws -> String, tabIndex: Int, text: String,
                             patience: TimeInterval = 600) async -> Bool {
        await typeWhenFreeResult(exec: exec, target: .index(tabIndex), text: text, patience: patience) == .typed
    }

    enum TypeResult: Equatable {
        case typed
        /// A menu or dialog stayed open.
        case menuOpen
        /// Someone else's text sat in the agent's input box.
        case draftInBox
        /// The guard refused: the window isn't the intended one any more, or
        /// no agent holds it. Nothing was typed; never retried.
        case refused(PaneRefusal)
    }

    @MainActor
    static func typeWhenFreeResult(_ delegate: ACAppDelegate, profileID: UUID, tabIndex: Int, text: String,
                                   patience: TimeInterval = 600) async -> TypeResult {
        await typeWhenFreeResult(delegate, profileID: profileID, target: .index(tabIndex), text: text,
                                 patience: patience)
    }

    @MainActor
    static func typeWhenFreeResult(_ delegate: ACAppDelegate, profileID: UUID, target: PaneTarget, text: String,
                                   patience: TimeInterval = 600) async -> TypeResult {
        await typeWhenFreeResult(exec: { cmd in try await delegate.guestExec(profileID: profileID, command: cmd, timeout: 20) },
                                 target: target, text: text, patience: patience)
    }

    /// The pane's bottom rows with their escapes, for `AgentInputBox`.
    nonisolated static func inputProbeCommand(tabIndex: Int) -> String {
        inputProbeCommand(target: .index(tabIndex))
    }

    nonisolated static func inputProbeCommand(target: PaneTarget) -> String {
        PaneTypeGuard.resolve(target)
            + "[ -n \"$_bt\" ] && tmux capture-pane -p -e -t \"$_bt\" 2>/dev/null | tail -n 30"
    }

    nonisolated static func cursorProbeCommand(target: PaneTarget) -> String {
        PaneTypeGuard.resolve(target)
            + "[ -n \"$_bt\" ] && { \(AgentInputBox.cursorProbeCommand(target: "\"$_bt\"")); }"
    }

    /// `typeWhenFree` with why it gave up. Never types onto text already
    /// in the agent's input box: our own message from an earlier try that
    /// held off before Enter just gets its Enter; anything else (a user's
    /// draft, a stray command) holds the text until the box is clear —
    /// concatenating the two would send neither as meant. A guard refusal
    /// (wrong window, a shell in the foreground) ends it at once.
    static func typeWhenFreeResult(exec: @escaping (String) async throws -> String, target: PaneTarget,
                                   text: String, patience: TimeInterval = 600) async -> TypeResult {
        let deadline = Date().addingTimeInterval(patience)
        var last: TypeResult = .menuOpen
        let label = "\(target.ref)"
        // Our text went in last round but its Enter never took: what the box
        // shows now is ours, however the agent drew it (omp's paste chip).
        var typedUnconfirmed = false
        var unconfirmedRounds = 0
        while true {
            let screen = (try? await exec(inputProbeCommand(target: target))) ?? ""
            var command: String? = nil   // nil: the guarded type (staged when long)
            var held = false
            var box = AgentInputBox.content(screen)
            if box == .unknown {
                // No ruled box: the terminal cursor's line (Kimi's prompt).
                let probe = (try? await exec(cursorProbeCommand(target: target))) ?? ""
                box = AgentInputBox.cursorContent(probe)
            }
            if case .text(let draft) = box {
                if typedUnconfirmed || AgentInputBox.isOwn(draft, of: text) {
                    BACDebug.log("type", "\(label): our text is already in the box — Enter only")
                    command = guardedEnterCommand(target: target)
                } else {
                    BACDebug.log("type", "held text for \(label): the input box has text in it")
                    held = true
                    last = .draftInBox
                }
            }
            if !held {
                var agentTarget = target
                agentTarget.foreground = .agent
                let run: String?
                if let command {
                    run = try? await exec(command)
                } else {
                    run = await PaneTypeGuard.runType(target: agentTarget, text: text) { try? await exec($0) }
                }
                guard let out = run else {
                    // The guest couldn't be asked: nothing is known typed.
                    last = .refused(.gone)
                    guard Date() < deadline else { return last }
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    continue
                }
                if let r = PaneTypeGuard.refusal(in: out) {
                    BACDebug.log("type", "REFUSED to type into \(label): \(r.rawValue)")
                    return .refused(r)
                }
                if PaneTypeGuard.typed(in: out) { return .typed }
                if PaneTypeGuard.unconfirmed(in: out) {
                    BACDebug.log("type", "\(label): the Enter didn't take — confirming again")
                    typedUnconfirmed = true
                    unconfirmedRounds += 1
                    last = .draftInBox
                    // Never Enter after Enter for long: twice more, then the
                    // caller says it wasn't delivered.
                    guard Date() < deadline, unconfirmedRounds < 3 else { return last }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    continue
                }
                if out.contains(typeHeldMarker) {
                    BACDebug.log("type", "held text for \(label): a menu or dialog is open")
                    last = .menuOpen
                } else {
                    // Ran, but didn't go through (tmux refused it): try
                    // again — what did land is found in the box next time.
                    BACDebug.log("type", "typing into \(label) FAILED — retrying")
                    last = .refused(.gone)
                }
            }
            guard Date() < deadline else { return last }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    /// Enter for text already in the box — unless a menu came up, or the
    /// window stopped being the intended agent's.
    nonisolated static func guardedEnterCommand(tabIndex: Int) -> String {
        guardedEnterCommand(target: .index(tabIndex))
    }

    nonisolated static func guardedEnterCommand(target: PaneTarget) -> String {
        PaneTypeGuard.prelude(target) + menuFunction + PaneTypeGuard.confirmFunctions
            + "if _bg; then if _bm; then echo \(typeHeldMarker); else \(PaneTypeGuard.confirmedEnter); fi; fi"
    }

    /// The user-facing reason a guarded send typed nothing.
    nonisolated static func refusalReason(_ r: PaneRefusal, worker: String) -> String {
        switch r {
        case .shell:
            return String(format: NSLocalizedString(
                "%@ isn't running in the task's session any more (only a shell is left), so nothing was typed — Restart Session to bring it back.",
                comment: "task send refused"), worker)
        case .identity, .gone, .agent:
            return String(format: NSLocalizedString(
                "The task's session tab is gone or now belongs to something else, so nothing was typed into it — Restart Session to bring %@ back.",
                comment: "task send refused"), worker)
        }
    }
}

#else
/// iOS shim: the coding-board engine runs on the HOST, never the fat client.
/// Only its pure guest-command builders are needed here (the file explorer
/// types a message into a session's tmux tab), so expose those and nothing
/// else. Kept byte-identical to the macOS engine's statics.
enum CodingTaskEngine {
    /// Guarded (`PaneTypeGuard`): nothing is typed unless an AGENT holds
    /// the pane's foreground — a bare shell would run the text.
    nonisolated static func typeCommand(tabIndex: Int, text: String) -> String {
        PaneTypeGuard.typeCommand(target: .index(tabIndex), text: text)
    }

    nonisolated static func typeCommand(target: PaneTarget, text: String) -> String {
        PaneTypeGuard.typeCommand(target: target, text: text)
    }

    /// What `guardedTypeCommand` prints when it held off.
    nonisolated static let typeHeldMarker = PaneTypeGuard.heldMarker

    nonisolated static func guardedTypeCommand(tabIndex: Int, text: String) -> String {
        guardedTypeCommand(target: .index(tabIndex), text: text)
    }

    nonisolated static var menuFunction: String { PaneTypeGuard.menuFunction }

    /// Mirrors the macOS engine's `guardedTypeCommand(target:text:)`.
    nonisolated static func guardedTypeCommand(target: PaneTarget, text: String) -> String {
        var t = target
        t.foreground = .agent
        return PaneTypeGuard.typeCommand(target: t, text: text)
    }

    /// The guest command that tails a plan session's live agent transcript.
    /// The agent runs IN the task's configured directory, so the session
    /// store entry is derived from that path the way each tool encodes it
    /// (`AgentSessionLocator`); `since` (epoch seconds) skips transcripts
    /// of earlier sessions in the same directory. Output is capped so a
    /// long session stays cheap to poll. Nil when the path has characters
    /// we won't quote.
    /// Mirrors the macOS engine's copy, with one fat-client-only twist: the
    /// pending-question (pq) file is keyed by the guest's LOGICAL `$(pwd)`, but
    /// the reader only knows tmux's PHYSICAL path, so for a symlinked workspace
    /// the exact name misses. We fall back to the freshest pq written in the
    /// last few minutes (one plan runs at a time per VM), so a live planning
    /// question still surfaces.
    nonisolated static func planTranscriptCommand(guestCwd: String, since: Int,
                                                  agent: String? = nil,
                                                  pinnedWindow: Int? = nil) -> String? {
        guard let path = AgentSessionLocator.sanitized(guestCwd: guestCwd)
        else { return nil }
        var cmd = "f=\"\"; pe=\"\"; "
        // The transcript the tab's agent itself named (its hook records the
        // path per window — see agent-status.sh) wins over "the newest file
        // in the folder": two agents in one folder (a delegate beside its
        // delegator) would otherwise take turns owning each other's view.
        // Still floored: a file older than this process is another's.
        if let w = pinnedWindow {
            cmd += AgentSessionLocator.pinnedPick(window: w, since: since)
        }
        cmd += "if [ -z \"$f\" ] && [ -z \"$pe\" ]; then "
            + AgentSessionLocator.locateBlock(path: path, since: since, agent: agent)
            + "fi; "
        cmd += "if [ -n \"$f\" ]; then tail -c 300000 \"$f\" | iconv -f UTF-8 -t UTF-8 -c; fi; "
        if agent == nil || agent == "claude" {
            // The pq dump is Claude's pending AskUserQuestion — no other
            // tool writes one.
            let enc2 = path.replacingOccurrences(of: ".", with: "-")
                .replacingOccurrences(of: "/", with: "-")
            let pq = "\"$HOME/.bromure/pq-\(enc2).json\""
            cmd += "q=\(pq); "
                + "if [ ! -f \"$q\" ]; then n=$(date +%s); "
                + "q=$(find \"$HOME/.bromure\" -maxdepth 1 -name 'pq-*.json' "
                + "-newermt @$((n-300)) 2>/dev/null | xargs -r ls -t 2>/dev/null | head -1); fi; "
                + "if [ -n \"$q\" ] && [ -n \"$(find \"$q\" -newermt @\(AgentSessionLocator.findEpoch(since)) 2>/dev/null)\" ]; "
                + "then echo; tr -d '\\n' < \"$q\"; echo; fi"
        }
        return cmd
    }

    /// The guest command that answers a live AskUserQuestion picker by typing
    /// its key sequence. Byte-identical to the macOS engine's copy — the phone
    /// renders the same interactive question card and answers the same way.
    ///
    /// Each digit re-checks that the picker is still on screen: a keystroke that
    /// lands after it closed goes into the chat input and interrupts the pending
    /// tool call, which Claude records as the user declining to answer.
    /// True (exit 0) while an agent's option picker is ON SCREEN in `tabIndex`.
    ///
    /// Claude Code ships TWO footers and both have to match. Single-select ends
    /// "Enter to select"; multi-select ends "Space to toggle, Enter to confirm,
    /// a to select all, …" — which does NOT contain "Enter to select", so a
    /// probe for that string alone silently refused to answer every
    /// multiple-choice question, the exact shape a remote reader most needs.
    nonisolated static func pickerVisibleCommand(tabIndex: Int) -> String {
        "tmux capture-pane -p -t bromure:\(tabIndex) 2>/dev/null "
            + "| grep -qE 'Enter to (select|confirm)'"
    }

    /// By index (the window is resolved to its id once, and re-checked —
    /// an agent in front — before every key); `PaneTypeGuard.answerKeysCommand`
    /// takes a stable identity when the caller has one.
    nonisolated static func answerKeysCommand(tabIndex: Int, keys: [String]) -> String {
        PaneTypeGuard.answerKeysCommand(target: .index(tabIndex), keys: keys)
    }
}
#endif

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
    /// This file's section of the `git diff` output, headers included —
    /// what Copy Diff puts on the pasteboard ("" when not parsed from one).
    var raw: String = ""
    var added: Int { lines.filter { $0.kind == .added }.count }
    var removed: Int { lines.filter { $0.kind == .removed }.count }

    /// The file's diff as a patch: the git output when there is one, else
    /// rebuilt from the lines with a minimal header.
    var patch: String {
        if !raw.isEmpty { return raw.hasSuffix("\n") ? raw : raw + "\n" }
        let body = lines.map(\.text).joined(separator: "\n")
        return "diff --git a/\(path) b/\(path)\n--- a/\(path)\n+++ b/\(path)\n" + body + (body.isEmpty ? "" : "\n")
    }

    /// Several files' diffs as one patch (the whole branch, or what the
    /// review shows).
    static func patch(of files: [TaskDiffFile]) -> String {
        files.map(\.patch).joined()
    }
}

/// Tolerant unified-diff reader for `git diff` output.
enum TaskDiffParser {
    /// The b/ side of a "diff --git a/… b/…" line.
    static func newPath(fromDiffLine line: String) -> String {
        let t = line.trimmingCharacters(in: .whitespaces)
        if let r = t.range(of: " b/", options: .backwards) { return String(t[r.upperBound...]) }
        return t.split(separator: " ").last.map(String.init) ?? t
    }

    static func parse(_ raw: String) -> [TaskDiffFile] {
        var files: [TaskDiffFile] = []
        var current: TaskDiffFile?
        var lineID = 0
        var newCounter = 0
        var rawLines: [Substring] = []
        func close() {
            guard var f = current else { return }
            // A trailing empty piece is the final newline, not a line.
            while rawLines.last?.isEmpty == true { rawLines.removeLast() }
            f.raw = rawLines.joined(separator: "\n") + "\n"
            files.append(f)
            rawLines = []
        }
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") {
                close()
                // "diff --git a/path b/path" — take the b/ side (handles
                // renames and new files, and names with spaces).
                let path = Self.newPath(fromDiffLine: String(line))
                current = TaskDiffFile(path: path, lines: [])
                rawLines = [line]
                continue
            }
            guard current != nil else { continue }
            rawLines.append(line)
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
        close()
        return files
    }
}
