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
    /// Asks an answer is being delivered to (`answer`).
    private var answering: Set<UUID> = []
    static let alreadyOnItsWay = NSLocalizedString("Your answer is already on its way.",
                                                   comment: "coding task: a second send of the same answer")

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
        let model = delegate.unifiedWindow?.listModel
        // This host's sessions and its native machines' (Bromure Sidecar).
        let sessions = delegate.allSessionRecords
            .filter { !$0.isDeleted && !$0.isArchived && !$0.isSwitchboard }
            .sorted { SessionHome.lastActivity($0) > SessionHome.lastActivity($1) }
            .prefix(40)
            .map { s -> TaskAssigneeChoices.Session in
                let bucket = model.map { SessionHome.bucket(for: s, in: $0) }
                return .init(id: s.id, label: delegate.delegationEngine.label(s),
                             workspace: delegate.profile(for: s.profileID)?.name
                                ?? delegate.attachedMachines[s.profileID]?.name ?? "",
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
        let worker = assignment.flatMap { $0.kind == .session ? delegate.sessionRecord($0.id) : nil }
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
                // A start still being checked holds its slot too.
                Self.sameAssignee($0.assignment, a) && ($0.stage == .inProgress || $0.isStarting)
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
                          && $0.lastError == nil && !$0.isStarting
                          && $0.unmetDependencies(in: tasks).isEmpty
                          && !$0.title.trimmingCharacters(in: .whitespaces).isEmpty }
                .sorted(by: CodingTask.backlogOrder)   // the Backlog's order: top first
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
        guard let delegate, let s = delegate.sessionRecord(id), !s.isDeleted else { return false }
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
                guard let s = delegate.sessionRecord(assignment.id), !s.isDeleted else {
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
            if let s = delegate.sessionRecord(target) {
                store.mutate(taskID) { $0.profileID = s.profileID }
            }
            // Pull request at delivery is an explicit opt-in (the board's
            // toggle); by default the work comes back for review and lands
            // the way the task's finish preference says once approved.
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
            - When it's done, commit on your branch and hand it back for review: call `deliver` with what \
            changed and how to verify it. Do not merge or push — the user reviews the branch's diff on the \
            board, and when they approve it you'll be asked to land it.
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
            // Landing, or already Needs you (stalled): either way the
            // question is what the user now has to answer.
            let landing = task.stage == .testing
                && (task.landing?.phase == .agentLanding || task.landing?.phase == .needsYou)
            store.mutate(task.id) {
                $0.pendingQuestion = m.text
                $0.pendingAskID = m.id
                // Asked while landing (or after it stalled): it's stuck on
                // something — the question is what the card says now.
                if $0.stage == .testing,
                   $0.landing?.phase == .agentLanding || $0.landing?.phase == .needsYou {
                    $0.landing?.phase = .needsYou
                    $0.landing?.detail = m.text
                }
            }
            // A batch's brief says to ask about the branches that aren't in:
            // the question is about all of its cards.
            if landing { delegate.codingTaskEngine.batchNeedsYou(task.id, m.text) }
        case .report:
            store.mutate(task.id) { $0.assigneeNote = m.text }
        case .deliver where task.stage == .done:
            // Already Done: Bromure saw the landing in git (it looks every
            // few seconds) before the assignee's own report came in. The
            // report is recorded — and ends the landing's grace — but never
            // read as a fresh hand-in: that pulled a landed card back to
            // Review, stuck on "Landing…" for good.
            let landed = task.landing != nil
            store.mutate(task.id) {
                if landed { $0.mergeReport = m.text }
                $0.pendingQuestion = nil
                $0.pendingAskID = nil
            }
            if landed {
                let pr = task.landing?.mode == .pr
                Task {
                    _ = await delegate.codingTaskEngine.reportLanding(
                        task.id, status: pr ? "pr_opened" : "merged", summary: m.text,
                        prURL: CodingTask.pullRequestURL(in: m.text))
                    self.pump()
                }
            }
        case .deliver where task.landing != nil && task.stage == .testing:
            // The assignee landed it, as asked on approval — verified in git
            // when this host can look (its worktree is on one of our
            // machines), recorded as its report otherwise.
            store.mutate(task.id) {
                $0.mergeReport = m.text
                $0.pendingQuestion = nil
                $0.pendingAskID = nil
                if $0.landing?.phase == .needsYou { $0.landing?.phase = .agentLanding }
            }
            let pr = task.landing?.mode == .pr
            Task {
                let r = await delegate.codingTaskEngine.reportLanding(
                    task.id, status: pr ? "pr_opened" : "merged", summary: m.text,
                    prURL: CodingTask.pullRequestURL(in: m.text))
                if !r.ok, let now = delegate.codingTaskStore.task(task.id), now.stage == .testing {
                    let target = now.landingTarget ?? ""
                    delegate.codingTaskStore.mutate(task.id) {
                        $0.landing?.phase = .needsYou
                        $0.landing?.detail = String(format: NSLocalizedString(
                            "%1$@ says it's done, but Bromure doesn't see it in %2$@: %3$@",
                            comment: "task landing"),
                            task.assignment?.label ?? "", target, m.text)
                    }
                    // Git is still looked at: once it's in, the card goes Done.
                    delegate.codingTaskEngine.watchLanding(task.id)
                }
                self.pump()
            }
        case .deliver where task.stage == .testing && task.branch != nil && task.rootRepo != nil:
            // Already in Review, with no landing under way (the user
            // cancelled it while the brief was out): a reply to that brief
            // still lands the card when git shows it in the target the USER
            // approved — never just the parent the agent's machine reports,
            // with no approval at all. Else it's a fresh hand-in, as below.
            Task {
                let engine = delegate.codingTaskEngine
                if let now = store.task(task.id), now.stage == .testing, now.landing == nil,
                   let approved = now.approvedTarget, CodingTaskEngine.isSafeBranchName(approved),
                   await engine.landingVerified(Self.landing(now, into: approved)) == true {
                    store.mutate(task.id) {
                        $0.mergeReport = m.text
                        $0.pendingQuestion = nil
                        $0.pendingAskID = nil
                    }
                    _ = await engine.reportLanding(task.id, status: "merged", summary: m.text, prURL: nil)
                } else {
                    store.mutate(task.id) {
                        $0.deliverySummary = m.text
                        $0.pullRequestURL = CodingTask.pullRequestURL(in: m.text) ?? $0.pullRequestURL
                        $0.pendingQuestion = nil
                        $0.pendingAskID = nil
                    }
                    await self.toReview(task.id, delegation: d)
                }
                self.pump()
            }
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
            if m.text == DelegationEngine.backText {
                // The assignee's session came back: its "gone" failure is moot.
                store.mutate(task.id) { if $0.lastError?.contains(DelegationEngine.goneText(d)) == true { $0.lastError = nil } }
            } else if d.status == .failed || store.task(task.id)?.stage == .inProgress && m.text.hasPrefix("failed") {
                store.mutate(task.id) { $0.lastError = m.text }
            }
        case .brief, .answer, .steer, .cancel:
            break
        }
    }

    /// Delivered: find the worktree the brief named, then Review.
    /// `t` as if landing into `target` (what the verify looks at).
    static func landing(_ t: CodingTask, into target: String) -> CodingTask {
        var t = t
        t.landing = TaskLanding(mode: .merge, target: target, phase: .agentLanding, startedAt: Date())
        return t
    }

    /// Whether a hand-in may (still) put this card in Review: one at work,
    /// or already in Review with no finished landing — never a Done card,
    /// a landed one, or one taken back to the Backlog (Stop). Checked again
    /// inside every write: the worktree lookup before it awaits (a guest
    /// exec), and the card can land or be stopped meanwhile.
    nonisolated static func mayReturnToReview(_ t: CodingTask) -> Bool {
        t.stage == .inProgress || (t.stage == .testing && t.landing?.phase != .landed)
    }

    private func toReview(_ taskID: UUID, delegation d: Delegation) async {
        // A Done card never goes back to Review on a late message.
        guard let delegate, let task = delegate.codingTaskStore.task(taskID), Self.mayReturnToReview(task),
              let slug = task.branchSlug else { return }
        let branch = "wt/\(slug)"
        if let found = await findDelivery(task, branch: branch, childSessionID: d.childSessionID) {
            delegate.codingTaskStore.mutate(taskID) {
                guard Self.mayReturnToReview($0) else { return }
                Self.point(&$0, at: found, branch: branch)
                $0.stage = .testing
                $0.testingAt = Date()
                $0.lastError = nil
            }
            BACDebug.log("tasks", "“\(task.title)”: delivered by \(task.assignment?.label ?? "?") → review (\(found.dir))")
            return
        }
        delegate.codingTaskStore.mutate(taskID) {
            guard Self.mayReturnToReview($0) else { return }
            Self.deliveredWithoutFind(&$0, branch: branch)
        }
    }

    /// A delivery whose look found no worktree: to Review, saying so — unless
    /// the card has its checkout already (the review window's look, or an
    /// earlier delivery's, found it while this one's exec failed): a miss
    /// says nothing about a checkout someone else found.
    nonisolated static func deliveredWithoutFind(_ t: inout CodingTask, branch: String) {
        t.stage = .testing
        t.testingAt = Date()
        t.branch = branch
        if (t.worktreeDir ?? "").isEmpty { t.lastError = noWorktreeText(branch) }
    }

    /// A delivered card in Review whose worktree wasn't found when it came
    /// in is looked for again — the review window asks before it reads the
    /// diff. The lookup at delivery is one exec on the assignee's machine:
    /// a machine out of reach for that moment left the card without a diff
    /// for good. True when the card now points at the worktree.
    @discardableResult
    func relocateDelivery(_ taskID: UUID) async -> Bool {
        guard let delegate, let task = delegate.codingTaskStore.task(taskID), task.awaitsRelocation,
              let slug = task.branchSlug else { return false }
        let branch = "wt/\(slug)"
        let child = task.delegationID
            .flatMap { delegate.delegationEngine.store.delegation(matching: $0.uuidString) }?.childSessionID
        // Looking: the card isn't "no code" until this ends (no one-click
        // Mark Done while the worktree may yet turn up).
        let started = Date()
        delegate.codingTaskStore.mutate(taskID) { $0.locatingSince = started }
        defer {
            delegate.codingTaskStore.mutate(taskID) {
                if $0.locatingSince == started { $0.locatingSince = nil }
            }
        }
        guard let found = await findDelivery(task, branch: branch, childSessionID: child) else { return false }
        var moved = false
        delegate.codingTaskStore.mutate(taskID) {
            // The card may have moved on during the lookup.
            guard $0.awaitsRelocation else { return }
            Self.point(&$0, at: found, branch: branch)
            if $0.lastError == Self.noWorktreeText(branch) { $0.lastError = nil }
            moved = true
        }
        if moved { BACDebug.log("tasks", "“\(task.title)”: found its worktree on a second look (\(found.dir))") }
        return moved
    }

    nonisolated static func noWorktreeText(_ branch: String) -> String {
        String(format: NSLocalizedString(
            "Delivered, but no worktree on branch %@ was found — the diff can't be shown. Read the summary, or send it back.",
            comment: "task assign"), branch)
    }

    struct FoundDelivery {
        var profileID: UUID
        var dir: String
        var root: String
        var parent: String?
    }

    /// The card now points at the worktree found on the assignee's machine.
    nonisolated static func point(_ t: inout CodingTask, at f: FoundDelivery, branch: String) {
        t.profileID = f.profileID
        t.repoPath = f.root
        t.branch = branch
        t.worktreeDir = f.dir
        t.rootRepo = f.root
        // Read from the assignee's machine: a plain branch name only.
        if let p = f.parent, p != branch, CodingTaskEngine.isSafeBranchName(p) { t.parentBranch = p }
    }

    /// Where a delivered branch's worktree is: looked for in the session
    /// that delivered, or — through a room — every session in the room.
    private func findDelivery(_ task: CodingTask, branch: String, childSessionID: UUID?) async -> FoundDelivery? {
        guard let delegate else { return nil }
        var candidates: [AgentSession] = []
        if let id = childSessionID, let s = delegate.sessionRecord(id), !s.isSwitchboard {
            candidates.append(s)
        }
        if let a = task.assignment, a.kind == .room {
            candidates += delegate.allSessionRecords.filter {
                $0.roomID == a.id && !$0.isSwitchboard && !$0.isDeleted
            }
        }
        if let a = task.assignment, a.kind == .switchboard {
            // Any session the Switchboard may have picked, most recent first.
            candidates += delegate.allSessionRecords
                .filter { !$0.isSwitchboard && !$0.isDeleted }
                .sorted { SessionHome.lastActivity($0) > SessionHome.lastActivity($1) }
                .prefix(40)
        }
        // Delegates a member started for it count too (their parents are
        // the candidates).
        let parents = Set(candidates.map(\.id))
        candidates += delegate.allSessionRecords.filter {
            $0.parentSessionID.map(parents.contains) ?? false
        }
        var seen = Set<String>()
        for s in candidates where seen.insert("\(s.profileID)|\(s.cwd)").inserted {
            let m = await delegate.codingTaskEngine.resolveWorktreeMetadata(
                profileID: s.profileID, branch: branch, repoPath: s.cwd)
            guard let dir = m.dir, let root = m.root else { continue }
            return FoundDelivery(profileID: s.profileID, dir: dir, root: root, parent: m.parent)
        }
        return nil
    }

    // MARK: Board → assignee

    /// The user answers the assignee's question from the board.
    /// `askID`: the ask the answer was written for — refused when the
    /// agent has asked again since (nil: whatever is asked now, for callers
    /// that don't say).
    func answer(_ taskID: UUID, askID: UUID? = nil, text: String) async -> Bool {
        guard let delegate, let task = delegate.codingTaskStore.task(taskID),
              task.pendingAskID != nil else { return false }
        guard let ask = Self.answerTarget(task, writtenFor: askID) else {
            delegate.codingTaskStore.mutate(taskID) { $0.lastError = Self.staleAnswerText }
            return false
        }
        // One answer per question in flight: a second Send while the first
        // is still being delivered (its scan, a slow link that gave up on
        // the reply) must not post the answer twice.
        guard answering.insert(ask).inserted else {
            delegate.codingTaskStore.mutate(taskID) {
                $0.lastError = Self.alreadyOnItsWay
            }
            return false
        }
        defer { answering.remove(ask) }
        // What the card said when this try started: only that is this
        // try's to clear once it succeeds.
        let seen = delegate.codingTaskStore.task(taskID).map(AnswerErrorSnapshot.init)
        do {
            try await delegate.delegationEngine.answer(
                from: DelegationEngine.boardSessionID, askKey: ask.uuidString, text: text, by: .user)
        } catch {
            let why = (error as? DelegationRefusal)?.why ?? error.localizedDescription
            delegate.codingTaskStore.mutate(taskID) {
                $0.lastError = why
                $0.answerRefusal = why
            }
            return false
        }
        delegate.codingTaskStore.mutate(taskID) {
            Self.clearAnswered(&$0, ask: ask)
            // The answer went: a refusal of a resend meanwhile isn't news.
            if $0.lastError == Self.alreadyOnItsWay { $0.lastError = nil }
            Self.clearAnswerError(&$0, seen: seen)
        }
        return true
    }

    /// A task's answer-error fields at one moment.
    struct AnswerErrorSnapshot: Equatable {
        var lastError: String?
        var refusal: String?
        init(_ t: CodingTask) { lastError = t.lastError; refusal = t.answerRefusal }
    }

    static let staleAnswerText = NSLocalizedString(
        "The agent asked a new question before your answer went. Read it and answer again.",
        comment: "coding task: an answer for an earlier question")

    /// An answer went: what an earlier try of `answer` put on the card (the
    /// stale-question note, a refused delivery's reason — `answerRefusal`,
    /// saved with the task) is past, and the card would keep saying the
    /// answer didn't go. Any other error (the assignee's own trouble, or
    /// one that replaced the refusal since) stays.
    ///
    /// `seen`: the fields when this try started (nil: as they are now). A
    /// refusal another try stored while this one was being delivered is
    /// that try's news and stays on the card (Finding CWE-362, "A later
    /// task-answer success clears a newer attempt's refusal": each Send runs
    /// on its own, and an older answer finishing last erased the note that
    /// a newer one was withheld).
    static func clearAnswerError(_ task: inout CodingTask, seen: AnswerErrorSnapshot? = nil) {
        let seen = seen ?? AnswerErrorSnapshot(task)
        if let e = task.lastError, e == seen.lastError, e == staleAnswerText || e == seen.refusal {
            task.lastError = nil
        }
        if task.answerRefusal == seen.refusal { task.answerRefusal = nil }
    }

    /// The ask an answer goes to: the one on the card, unless the answer was
    /// written for another (the agent asked again since).
    static func answerTarget(_ task: CodingTask, writtenFor askID: UUID?) -> UUID? {
        guard let ask = task.pendingAskID, askID == nil || askID == ask else { return nil }
        return ask
    }

    /// `ask` was answered: the card's question goes — only if it's still that
    /// one (the agent may have asked again while the answer was on its way).
    static func clearAnswered(_ task: inout CodingTask, ask: UUID) {
        guard task.pendingAskID == ask else { return }
        task.pendingQuestion = nil
        task.pendingAskID = nil
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

    /// An assigned task approved on the board: its assignee lands its own
    /// branch where it did the work (a native machine included) — the
    /// landing brief goes on the same delegation thread, and its next
    /// delivery is checked and makes the card Done. True when it went.
    func steerLanding(_ taskID: UUID, text: String) async -> Bool {
        guard let delegate, let task = delegate.codingTaskStore.task(taskID),
              let did = task.delegationID else { return false }
        do {
            try await delegate.delegationEngine.steer(
                from: DelegationEngine.boardSessionID, delegationKey: did.uuidString, text: text, by: .user)
        } catch {
            delegate.codingTaskStore.mutate(taskID) {
                $0.lastError = (error as? DelegationRefusal)?.why ?? error.localizedDescription
            }
            return false
        }
        BACDebug.log("tasks", "“\(task.title)”: asked \(task.assignment?.label ?? "its assignee") to land it")
        return true
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

    /// Whether a board delegation's session coming back should pick the work
    /// up again: its card still there and not done.
    func wantsRevival(_ d: Delegation) -> Bool {
        Self.wantsRevival(d, tasks: delegate?.codingTaskStore.tasks ?? [])
    }

    nonisolated static func wantsRevival(_ d: Delegation, tasks: [CodingTask]) -> Bool {
        guard let task = tasks.first(where: { $0.delegationID == d.id }) else { return false }
        return task.stage != .done
    }

    /// The board delegations `sync` settles: open ones, and gone ones (their
    /// machine away) — the cancel or close is on the record when it's back.
    nonisolated static func syncs(_ d: Delegation) -> Bool { d.status.isOpen || d.goneFrom != nil }

    /// Whether `sync` closes a done card's delegation now: not while the
    /// landing's grace is on — the assignee's report (its summary on the
    /// card) can still come, even from a session that was away; a close
    /// first refused it. The report, or the grace running out, ends it.
    nonisolated static func closesNow(_ task: CodingTask, inLandingGrace: Bool) -> Bool {
        task.stage == .done && !inLandingGrace
    }

    /// Close the requests of tasks that are over, and cancel the ones whose
    /// card is gone — the assignee hears either way.
    func sync() {
        guard let delegate else { return }
        pump()
        let engine = delegate.delegationEngine
        let tasks = delegate.codingTaskStore.tasks
        // A gone one too (its machine away): left alone, a deleted or finished
        // card's delegation came back to life with its session.
        for d in engine.store.delegations(parent: DelegationEngine.boardSessionID) where Self.syncs(d) {
            guard let task = tasks.first(where: { $0.delegationID == d.id }) else {
                Task { try? await engine.cancel(from: DelegationEngine.boardSessionID,
                                                delegationKey: d.id.uuidString,
                                                reason: "The task was removed from the board.", by: .user) }
                continue
            }
            guard Self.closesNow(task, inLandingGrace: delegate.codingTaskEngine.inLandingGrace(task.id))
            else { continue }
            let note: String
            let accepted: Bool
            switch task.effectiveCompletion {
            case .merged(let target, _, _)?: accepted = true; note = target.isEmpty ? "Merged." : "Merged into \(target)."
            case .prOpened?: accepted = true; note = "A pull request was opened."
            case .markedDone?: accepted = true; note = "Marked done on the board."
            case .closedWithoutMerge?, nil: accepted = false; note = "Closed without merging."
            }
            Task { try? await engine.close(from: DelegationEngine.boardSessionID,
                                           delegationKey: d.id.uuidString,
                                           verdict: accepted ? "accepted" : "rejected", note: note, by: .user) }
        }
    }
}
#endif
