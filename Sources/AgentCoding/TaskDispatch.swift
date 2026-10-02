#if os(macOS)
import Foundation

// MARK: - Handing a board task to a session or a room
//
// The board's default is a new agent in a fresh worktree (CodingTaskEngine).
// A task can instead go to a session that already exists ("have @hotfixes
// do it") or to a room ("#payments": its Switchboard picks the member). It
// travels as a delegation REQUEST whose requester is the board itself
// (DelegationEngine.boardSessionID): the assignee gets the usual one-line
// notice when its prompt is free, works, and answers with the delegation
// tools — `ask` when blocked, `report` for progress, `deliver` when done.
//
// The work happens in a git worktree the brief names (branch wt/<slug>), so
// the assignee's own checkout stays put and the card's review / merge /
// pull-request flow is the one every task uses.

@MainActor
final class TaskDispatcher {
    private weak var delegate: ACAppDelegate?
    private var timer: Timer?

    init(delegate: ACAppDelegate?) {
        self.delegate = delegate
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
        t.tolerance = 2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Choices

    /// Sessions and rooms the board can hand a task to.
    func choices() -> TaskAssigneeChoices {
        guard let delegate else { return TaskAssigneeChoices() }
        let store = delegate.agentSessionStore
        let model = delegate.unifiedWindow?.listModel
        let sessions = store.sessions
            .filter { !$0.isDeleted && !$0.isArchived && !$0.isSwitchboard }
            .sorted { SessionHome.lastActivity($0) > SessionHome.lastActivity($1) }
            .prefix(40)
            .map { s -> TaskAssigneeChoices.Session in
                let bucket = model.map { SessionHome.bucket(for: s, in: $0) }
                return .init(id: s.id, label: delegate.delegationEngine.label(s),
                             workspace: delegate.profile(for: s.profileID)?.name ?? "",
                             busy: bucket == .working || bucket == .needsYou,
                             profileID: s.profileID)
            }
        let rooms = delegate.agentRoomStore.rooms
            .filter { $0.archivedAt == nil }
            .map { TaskAssigneeChoices.Room(id: $0.id, name: $0.name) }
        return TaskAssigneeChoices(sessions: Array(sessions), rooms: rooms)
    }

    // MARK: Queues

    /// Queue a backlog task for a session or a room — or, with nil, take it
    /// off any queue. The assignee picks it up by itself: whenever it has no
    /// board task in progress, the oldest task queued for it is handed over.
    func assign(_ taskID: UUID, to assignment: TaskAssignment?) {
        guard let delegate, let task = delegate.codingTaskStore.task(taskID),
              task.stage == .backlog || task.stage == .planning else { return }
        // Queued for a session: the work happens in its workspace, so that's
        // the card's — not whichever workspace the editor defaulted to.
        let worker = assignment.flatMap { $0.kind == .session ? delegate.agentSessionStore.session($0.id) : nil }
        delegate.codingTaskStore.mutate(taskID) {
            $0.assignment = assignment
            $0.lastError = nil
            if let worker { $0.profileID = worker.profileID }
        }
        BACDebug.log("tasks", "“\(task.title)” queued for \(assignment?.label ?? "nobody")")
        pump()
    }

    private static func sameAssignee(_ a: TaskAssignment?, _ b: TaskAssignment?) -> Bool {
        a?.same(as: b) ?? false
    }

    /// Hand each assignee its next queued task when it has none in progress.
    func pump() {
        guard let delegate else { return }
        let tasks = delegate.codingTaskStore.tasks
        var assignees: [TaskAssignment] = []
        for t in tasks where t.stage == .backlog {
            if let a = t.assignment, !assignees.contains(where: { Self.sameAssignee($0, a) }) {
                assignees.append(a)
            }
        }
        for a in assignees {
            let running = tasks.filter {
                Self.sameAssignee($0.assignment, a) && $0.stage == .inProgress
            }.count
            // A session or room takes one task at a time; new agents run a
            // few side by side, each in its own worktree.
            let limit = a.kind == .worktree ? TaskAssignment.newAgentConcurrency : 1
            guard running < limit else { continue }
            // A session takes the next task only once it's done with
            // whatever it's doing — a queued task never lands mid-turn or on
            // a question waiting for the user (it isn't a steer).
            if a.kind == .session, !sessionIsFree(a.id) { continue }
            let ready = tasks
                .filter { $0.stage == .backlog && Self.sameAssignee($0.assignment, a)
                          && $0.lastError == nil
                          && $0.unmetDependencies(in: tasks).isEmpty
                          && !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
                .sorted { $0.createdAt < $1.createdAt }
            for next in ready.prefix(limit - running) {
                if a.kind == .worktree {
                    BACDebug.log("tasks", "“\(next.title)” picked up by a new agent")
                    delegate.codingTaskEngine.start(next.id)
                } else {
                    dispatch(next.id, to: a)
                }
            }
        }
    }


    /// The session isn't working and isn't waiting on the user: an idle,
    /// asleep or ended session can take a task (asleep/ended ones are
    /// resumed with it). Without a window model, only a live agent mid-turn
    /// counts as busy.
    private func sessionIsFree(_ id: UUID) -> Bool {
        guard let delegate, let s = delegate.agentSessionStore.session(id), !s.isDeleted else { return false }
        if let model = delegate.unifiedWindow?.listModel {
            let b = SessionHome.bucket(for: s, in: model)
            return b != .working && b != .needsYou
        }
        return true
    }

    // MARK: Hand over

    /// Hand a task to `assignment` now. The card goes to In Progress at
    /// once; a refusal puts it back in the queue with the reason (the queue
    /// skips it until the user retries).
    private func dispatch(_ taskID: UUID, to assignment: TaskAssignment) {
        guard let delegate, let task = delegate.codingTaskStore.task(taskID),
              task.stage == .backlog || task.stage == .planning else { return }
        let store = delegate.codingTaskStore
        let slug = ScheduledAutomationEngine.branchSlug(for: task.title, at: Date())
        let prior = task.stage
        store.mutate(taskID) {
            $0.stage = .inProgress
            $0.startedAt = Date()
            $0.branchSlug = slug
            $0.assignment = assignment
            $0.delegationID = nil
            $0.lastError = nil
            $0.pendingQuestion = nil
            $0.pendingAskID = nil
            $0.assigneeNote = nil
            $0.deliverySummary = nil
            $0.queuedAt = nil
        }
        func revert(_ why: String) {
            store.mutate(taskID) {
                $0.stage = prior
                $0.startedAt = nil
                $0.branchSlug = nil
                $0.delegationID = nil
                $0.lastError = why
            }
        }
        Task { [weak self] in
            guard let self, let delegate = self.delegate else { return }
            let target: UUID
            switch assignment.kind {
            case .worktree:
                delegate.codingTaskEngine.start(taskID)
                return
            case .session:
                guard let s = delegate.agentSessionStore.session(assignment.id), !s.isDeleted else {
                    revert(NSLocalizedString("That session no longer exists.", comment: "task assign"))
                    return
                }
                target = s.id
            case .switchboard:
                guard let sid = delegate.switchboardEngine.ensureSwitchboard() else {
                    revert(NSLocalizedString("There's no workspace to run the Switchboard in.", comment: "task assign"))
                    return
                }
                target = sid
            case .room:
                guard let room = delegate.agentRoomStore.room(assignment.id),
                      let sid = delegate.switchboardEngine.ensureSwitchboard(room: room) else {
                    revert(NSLocalizedString("The room has no Switchboard to take the task.", comment: "task assign"))
                    return
                }
                target = sid
            }
            // The card shows (and later reviews and merges in) the workspace
            // the work happens in: the assignee's. A room's or the
            // Switchboard's pick is corrected on delivery, from the worktree.
            if let s = delegate.agentSessionStore.session(target) {
                store.mutate(taskID) { $0.profileID = s.profileID }
            }
            let text = Self.brief(for: task, slug: slug, viaRoom: assignment.kind == .room,
                                  viaSwitchboard: assignment.kind == .switchboard,
                                  pullRequest: TaskAssignment.finishWithPullRequest)
            do {
                let d = try await delegate.delegationEngine.requestFromBoard(
                    to: target, title: task.title, text: text)
                store.mutate(taskID) { $0.delegationID = d.id }
                BACDebug.log("tasks", "“\(task.title)” handed to \(assignment.label)")
            } catch {
                revert((error as? DelegationRefusal)?.why ?? error.localizedDescription)
            }
        }
    }

    /// The request text: the task, and how to do it so the board can review.
    nonisolated static func brief(for task: CodingTask, slug: String, viaRoom: Bool,
                                  viaSwitchboard: Bool = false,
                                  pullRequest: Bool = false) -> String {
        let branch = "wt/\(slug)"
        var s = ""
        if viaSwitchboard {
            s += """
            You are the Switchboard. Pick the session best placed to do the coding task below — one already working \
            on that repository, and not busy — and hand it over with the delegation tool `request` (pass the whole \
            task, worktree instructions included). When that session delivers, `deliver` its summary back here. If \
            no session fits, start one for it with start_session.

            ---

            """
        }
        if viaRoom {
            s += """
            You are this room's Switchboard. Pick the session in the room best placed to do the coding task below \
            and hand it over with the delegation tool `request` — pass the whole task, worktree instructions \
            included. When that session delivers, `deliver` its summary back here. If no session in the room fits, \
            start one in the room for it.

            ---

            """
        }
        s += "Coding task from the Bromure board: \(task.title)\n\n"
        let details = task.details.trimmingCharacters(in: .whitespacesAndNewlines)
        if !details.isEmpty { s += details + "\n\n" }
        s += """
        ## How to work on it
        - Do the work in a NEW git worktree so your current checkout stays as it is. In the repository this task \
        is about, run: `git worktree add -b \(branch) "$HOME/.bromure/worktrees/$(basename "$(git rev-parse --show-toplevel)")/\(slug)"` \
        and work only in that directory.
        - Commit everything on branch \(branch).
        - If something blocks you, `ask` — the question reaches the user on the board.

        """
        if pullRequest {
            s += """
            - When it's done: push the branch and open a pull request with `gh pr create` against the branch \
            you started from (title: the task; body: what changed and how to verify it). Don't merge it.
            - Then call `deliver` with a short summary and the pull request's URL.
            """
        } else {
            s += """
            - When it's done and committed, call `deliver` with what changed and how to verify it. The user \
            reviews the branch's diff on the board before anything is merged — don't merge or push it yourself.
            """
        }
        return s
    }

    // MARK: Messages back

    /// What the assignee sent the board.
    func handle(_ d: Delegation, _ m: DelegationMessage) {
        guard let delegate,
              let task = delegate.codingTaskStore.tasks.first(where: { $0.delegationID == d.id })
        else { return }
        let store = delegate.codingTaskStore
        switch m.kind {
        case .ask:
            store.mutate(task.id) {
                $0.pendingQuestion = m.text
                $0.pendingAskID = m.id
            }
        case .report:
            store.mutate(task.id) { $0.assigneeNote = m.text }
        case .deliver where task.mergingAt != nil && task.stage == .testing:
            // The assignee merged it, as asked on acceptance.
            store.mutate(task.id) {
                $0.stage = .done
                $0.completedAt = Date()
                $0.merged = true
                $0.mergingAt = nil
                $0.lastError = nil
                $0.mergeReport = m.text
                $0.pendingQuestion = nil
                $0.pendingAskID = nil
            }
            BACDebug.log("tasks", "“\(task.title)”: merged by \(task.assignment?.label ?? "its assignee")")
            pump()
        case .deliver:
            store.mutate(task.id) {
                $0.deliverySummary = m.text
                $0.pullRequestURL = CodingTask.pullRequestURL(in: m.text) ?? $0.pullRequestURL
                $0.pendingQuestion = nil
                $0.pendingAskID = nil
            }
            Task {
                await self.toReview(task.id, delegation: d)
                self.pump()   // the assignee is free: its next queued task
            }
        case .note:
            // The host speaking for the far end: a failure, the peer ending.
            store.mutate(task.id) { $0.assigneeNote = m.text }
            if d.status == .failed || store.task(task.id)?.stage == .inProgress && m.text.hasPrefix("failed") {
                store.mutate(task.id) { $0.lastError = m.text }
            }
        case .brief, .answer, .steer, .cancel:
            break
        }
    }

    /// Delivered: find the worktree the brief named, then Testing/Review.
    private func toReview(_ taskID: UUID, delegation d: Delegation) async {
        guard let delegate, let task = delegate.codingTaskStore.task(taskID),
              let slug = task.branchSlug else { return }
        let branch = "wt/\(slug)"
        // Where to look: the session that delivered, or — through a room —
        // every session in the room.
        var candidates: [AgentSession] = []
        if let s = delegate.agentSessionStore.session(d.childSessionID), !s.isSwitchboard {
            candidates.append(s)
        }
        if let a = task.assignment, a.kind == .room {
            candidates += delegate.agentSessionStore.sessions.filter {
                $0.roomID == a.id && !$0.isSwitchboard && !$0.isDeleted
            }
        }
        if let a = task.assignment, a.kind == .switchboard {
            // Any session the Switchboard may have picked, most recent first.
            candidates += delegate.agentSessionStore.sessions
                .filter { !$0.isSwitchboard && !$0.isDeleted }
                .sorted { SessionHome.lastActivity($0) > SessionHome.lastActivity($1) }
                .prefix(40)
        }
        // Delegates a member started for it count too (their parents are
        // the candidates).
        let parents = Set(candidates.map(\.id))
        candidates += delegate.agentSessionStore.sessions.filter {
            $0.parentSessionID.map(parents.contains) ?? false
        }
        var seen = Set<String>()
        for s in candidates where seen.insert("\(s.profileID)|\(s.cwd)").inserted {
            let m = await delegate.codingTaskEngine.resolveWorktreeMetadata(
                profileID: s.profileID, branch: branch, repoPath: s.cwd)
            guard let dir = m.dir, let root = m.root else { continue }
            delegate.codingTaskStore.mutate(taskID) {
                $0.profileID = s.profileID
                $0.repoPath = root
                $0.branch = branch
                $0.worktreeDir = dir
                $0.rootRepo = root
                if let p = m.parent, p != branch { $0.parentBranch = p }
                $0.stage = .testing
                $0.testingAt = Date()
                $0.lastError = nil
            }
            BACDebug.log("tasks", "“\(task.title)”: delivered by \(task.assignment?.label ?? "?") → review (\(dir))")
            return
        }
        delegate.codingTaskStore.mutate(taskID) {
            $0.stage = .testing
            $0.testingAt = Date()
            $0.branch = branch
            $0.lastError = String(format: NSLocalizedString(
                "Delivered, but no worktree on branch %@ was found — the diff can't be shown. Read the summary, or send it back.",
                comment: "task assign"), branch)
        }
    }

    // MARK: Board → assignee

    /// The user answers the assignee's question from the board.
    func answer(_ taskID: UUID, text: String) async -> Bool {
        guard let delegate, let task = delegate.codingTaskStore.task(taskID),
              let ask = task.pendingAskID else { return false }
        do {
            try await delegate.delegationEngine.answer(
                from: DelegationEngine.boardSessionID, askKey: ask.uuidString, text: text, by: .user)
        } catch {
            delegate.codingTaskStore.mutate(taskID) {
                $0.lastError = (error as? DelegationRefusal)?.why ?? error.localizedDescription
            }
            return false
        }
        delegate.codingTaskStore.mutate(taskID) {
            $0.pendingQuestion = nil
            $0.pendingAskID = nil
        }
        return true
    }

    /// Review comments go back to the assignee as a steer (its own session
    /// isn't the task's tab). True when it went.
    func sendBack(_ taskID: UUID, feedback: String) async -> Bool {
        guard let delegate, let task = delegate.codingTaskStore.task(taskID),
              let did = task.delegationID else { return false }
        do {
            try await delegate.delegationEngine.steer(
                from: DelegationEngine.boardSessionID, delegationKey: did.uuidString,
                text: feedback + "\n\nKeep working on branch \(task.branch ?? "wt/\(task.branchSlug ?? "")") in the same worktree, then deliver again.",
                by: .user)
            return true
        } catch {
            delegate.codingTaskStore.mutate(taskID) {
                $0.lastError = (error as? DelegationRefusal)?.why ?? error.localizedDescription
            }
            return false
        }
    }

    /// An assigned task accepted on the board: its assignee merges its own
    /// branch — into the branch it started from (its checkout's), or
    /// `target` — where it did the work, a native machine included, and
    /// delivers again; that delivery makes the card Done. A merge it can't
    /// finish comes back as a question on the card.
    func requestMerge(_ taskID: UUID, into target: String?, squash: Bool, cleanup: Bool) async -> Bool {
        guard let delegate, let task = delegate.codingTaskStore.task(taskID),
              task.stage == .testing, task.mergingAt == nil, let did = task.delegationID else { return false }
        let text = Self.mergeRequest(branch: task.branch ?? "wt/\(task.branchSlug ?? "")",
                                     into: target ?? task.parentBranch, squash: squash, cleanup: cleanup)
        do {
            try await delegate.delegationEngine.steer(
                from: DelegationEngine.boardSessionID, delegationKey: did.uuidString, text: text, by: .user)
        } catch {
            delegate.codingTaskStore.mutate(taskID) {
                $0.lastError = (error as? DelegationRefusal)?.why ?? error.localizedDescription
            }
            return false
        }
        delegate.codingTaskStore.mutate(taskID) { $0.mergingAt = Date(); $0.lastError = nil }
        BACDebug.log("tasks", "“\(task.title)”: asked \(task.assignment?.label ?? "its assignee") to merge")
        return true
    }

    /// What the assignee is asked to do on acceptance.
    nonisolated static func mergeRequest(branch: String, into target: String?,
                                         squash: Bool, cleanup: Bool) -> String {
        let dest = target.map { "into \($0)" }
            ?? "into the branch your own checkout was on when you started this task"
        return "Accepted on the board — merge it. Merge \(branch) \(dest)"
            + (squash ? " as a single squashed commit" : "") + ": commit anything still outstanding in its "
            + "worktree first, resolve any conflicts, and check the result still builds. "
            + (cleanup ? "Then remove the worktree and delete the branch. "
                       : "Keep the worktree and the branch. ")
            + "Deliver again with one line saying where it landed. If you can't merge it, don't deliver: "
            + "ask, saying what's in the way."
    }

    /// Take a task back from its assignee (back to the backlog).
    func recall(_ taskID: UUID) {
        guard let delegate, let task = delegate.codingTaskStore.task(taskID) else { return }
        if let did = task.delegationID {
            Task {
                try? await delegate.delegationEngine.cancel(
                    from: DelegationEngine.boardSessionID, delegationKey: did.uuidString,
                    reason: "The user took this task back on the board.", by: .user)
            }
        }
        delegate.codingTaskStore.mutate(taskID) {
            $0.stage = .backlog
            $0.startedAt = nil
            $0.branchSlug = nil
            $0.delegationID = nil
            $0.assignment = nil
            $0.pendingQuestion = nil
            $0.pendingAskID = nil
            $0.assigneeNote = nil
        }
    }

    // MARK: Housekeeping

    /// Close the requests of tasks that are over, and cancel the ones whose
    /// card is gone — the assignee hears either way.
    func sync() {
        guard let delegate else { return }
        pump()
        let engine = delegate.delegationEngine
        let tasks = delegate.codingTaskStore.tasks
        for d in engine.store.delegations(parent: DelegationEngine.boardSessionID) where d.status.isOpen {
            guard let task = tasks.first(where: { $0.delegationID == d.id }) else {
                Task { try? await engine.cancel(from: DelegationEngine.boardSessionID,
                                                delegationKey: d.id.uuidString,
                                                reason: "The task was removed from the board.", by: .user) }
                continue
            }
            guard task.stage == .done else { continue }
            let accepted = task.merged || task.prOpened == true
            let note = task.merged ? "Merged." : (task.prOpened == true ? "A pull request was opened." : "Closed without merging.")
            Task { try? await engine.close(from: DelegationEngine.boardSessionID,
                                           delegationKey: d.id.uuidString,
                                           verdict: accepted ? "accepted" : "rejected", note: note, by: .user) }
        }
    }
}
#endif
