import Foundation

// The host side of a delegation (see AgentDelegation.swift for the words
// and the records). The engine starts the child session, moves each message
// between the two ends — scanned, audited, and only ever within the pair —
// and gets it heard: a blocked `wait` on the recipient's side is resumed at
// once; otherwise a one-line notice is typed at the recipient's prompt when
// it is idle, held until it is, or handed to a resume when the agent has
// ended. It also watches over the children: one that ends without
// delivering fails its delegation, and the parent hears about it.

struct DelegationRefusal: Error, CustomStringConvertible {
    let why: String
    init(_ why: String) { self.why = why }
    var description: String { why }
}

@MainActor
final class DelegationEngine {
    let store: DelegationStore
    let sessions: AgentSessionStore
    private let sessionEngine: AgentSessionEngine
    private weak var delegate: ACAppDelegate?

    /// Scans a text crossing between agents; a non-nil return is the snippet
    /// that tripped the detector and the message is withheld. Injected so
    /// the tests run without the model.
    var scan: @MainActor (String) async -> String? = { text in
        await PromptInjectionClassifier.shared.detect(spans: [(id: nil, content: text)])
    }
    /// Every message, delivered or withheld, goes to the Security Timeline
    /// (and the cloud audit for enrolled installs).
    var audit: @MainActor (UUID, [String: AnyJSON]) -> Void = { pid, data in
        BACEventEmitter.shared.emitDetached(profileID: pid, eventType: "agent.delegation", eventData: data)
    }

    /// A child may delegate in turn, this deep.
    static let maxDepth = 3
    /// Open delegations one session may have at once.
    static let maxOpenChildren = 8
    static let defaultWait: TimeInterval = 50
    static let waitCap: TimeInterval = 600

    private var waiters: [UUID: [Waiter]] = [:]
    /// For the debug hooks: what the host still owes each session, and why
    /// its prompt read busy.
    var debugState: [String: Any] {
        var held: [String: Any] = [:]
        for sid in recipientsOwed() {
            let s = sessions.session(sid)
            held[sid.uuidString] = ["count": store.unnoticed(for: sid).count,
                                    "idle": s.map(isIdle) ?? false,
                                    "status": s.flatMap(tabStatus)?.rawValue ?? "none"]
        }
        return ["unnoticed": held, "waiting": waiters.filter { !$0.value.isEmpty }.keys.map(\.uuidString)]
    }
    private var ticker: Task<Void, Never>?

    init(store: DelegationStore, sessions: AgentSessionStore,
         sessionEngine: AgentSessionEngine, delegate: ACAppDelegate?) {
        self.store = store
        self.sessions = sessions
        self.sessionEngine = sessionEngine
        self.delegate = delegate
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await self?.tick()
            }
        }
    }

    deinit { ticker?.cancel() }

    // MARK: Delegating

    /// Start a child session for `parentID` with the brief as its opening
    /// message — a worktree off the parent's folder unless told otherwise —
    /// and record the delegation. Refuses past the depth and fan-out limits,
    /// and a brief the scan flags.
    @discardableResult
    func delegate(from parentID: UUID, title: String, brief: String, contract: String?,
                  scope: [String], tool: Profile.Tool?, worktree: Bool?) async throws -> Delegation {
        guard let parent = sessions.session(parentID) else {
            throw DelegationRefusal("Your session isn't known to Bromure.")
        }
        let title = DelegationNotice.oneLine(title, max: 80)
        let brief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !brief.isEmpty else {
            throw DelegationRefusal("A delegation needs a title and a brief.")
        }
        guard depth(of: parentID) < Self.maxDepth else {
            throw DelegationRefusal("Delegations can't nest deeper than \(Self.maxDepth) levels — do this part yourself.")
        }
        let open = store.delegations(parent: parentID).filter { $0.status.isOpen }.count
        guard open < Self.maxOpenChildren else {
            throw DelegationRefusal("You already have \(open) open delegations — close or cancel some first.")
        }
        let scope = scope.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let scanned = [brief, contract ?? ""].joined(separator: "\n")
        if let snippet = await scan(scanned) {
            audit(parent.profileID, auditData(title: title, kind: .brief, from: .parent, to: .child,
                                              text: brief, blocked: snippet))
            throw DelegationRefusal("The brief was withheld: it reads like a prompt injection (“\(DelegationNotice.oneLine(snippet, max: 120))”). Say what to do in plain terms.")
        }
        let tool = tool ?? parent.tool
        let opening = DelegationNotice.opening(title: title, brief: brief, contract: contract,
                                               scope: scope, parentTitle: parent.title)
        // A worktree by default — when there is a repository to branch. A
        // plain folder runs the delegate in place rather than failing the
        // delegation on a technicality; an explicit worktree: true still
        // insists (and fails with the reason).
        let useWorktree: Bool
        if let worktree {
            useWorktree = worktree
        } else if SessionHome.hasFolder(parent) {
            useWorktree = await isGitRepository(parent)
        } else {
            useWorktree = false
        }
        let childID: UUID?
        if useWorktree {
            childID = sessionEngine.startWorktree(from: parentID, name: title, tool: tool, message: opening)
        } else {
            childID = sessionEngine.start(.init(profileID: parent.profileID, tool: tool, cwd: parent.cwd,
                                                openingMessage: opening, title: title))
        }
        guard let childID else {
            throw DelegationRefusal("Your session has no folder to branch a worktree from — pass worktree: false to run the delegate in the same folder.")
        }
        var d = Delegation(profileID: parent.profileID, parentSessionID: parentID, childSessionID: childID,
                           title: title, brief: brief, contract: contract, scope: scope)
        var briefMessage = DelegationMessage(kind: .brief, from: .parent, to: .child, text: brief)
        briefMessage.readAt = briefMessage.at      // the child opens with it
        d.messages = [briefMessage]
        store.upsert(d)
        sessions.mutate(childID) { $0.parentSessionID = parentID; $0.delegationID = d.id }
        audit(parent.profileID, auditData(title: title, kind: .brief, from: .parent, to: .child, text: brief))
        BACDebug.log("delegation", "“\(parent.title)” delegated “\(title)” (\(tool.rawValue)\(useWorktree ? ", worktree" : ""))")
        return d
    }

    /// Is the session's folder inside a git checkout? Unknowable without
    /// the machine (no delegate, in tests): then no.
    private func isGitRepository(_ s: AgentSession) async -> Bool {
        guard let delegate else { return false }
        let path = ScheduledAutomationEngine.guestPath(s.cwd)
        let q = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let out = (try? await delegate.guestExec(
            profileID: s.profileID,
            command: "git -C \(q) rev-parse --is-inside-work-tree 2>/dev/null", timeout: 15)) ?? ""
        return out.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// How many delegators sit above a session.
    func depth(of sessionID: UUID) -> Int {
        var n = 0
        var cursor = sessions.session(sessionID)?.parentSessionID
        while let p = cursor, n < 16 {
            n += 1
            cursor = sessions.session(p)?.parentSessionID
        }
        return n
    }

    // MARK: Messages

    /// The delegation `key` names, as long as `sessionID` is the `party`
    /// asked for — anything else reads as not found.
    func delegation(_ key: String, as party: DelegationMessage.Party, for sessionID: UUID) throws -> Delegation {
        guard let d = store.delegation(matching: key), d.party(of: sessionID) == party else {
            throw DelegationRefusal("No delegation “\(key)” of yours.")
        }
        return d
    }

    /// Record a message and get it to the other end. Throws when the
    /// delegation is closed, the kind isn't the party's to send, or the scan
    /// withholds it (the message stays on the record, marked blocked).
    @discardableResult
    func post(_ delegationID: UUID, from: DelegationMessage.Party, kind: DelegationMessage.Kind,
              text: String, answering: UUID? = nil) async throws -> DelegationMessage {
        guard let d = store.delegation(delegationID) else { throw DelegationRefusal("Unknown delegation.") }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DelegationRefusal("Nothing to say.") }
        guard d.status.isOpen || kind == .note else {
            throw DelegationRefusal("Delegation “\(d.title)” is \(d.status.rawValue).")
        }
        let to: DelegationMessage.Party
        switch (from, kind) {
        case (.child, .ask), (.child, .report), (.child, .deliver): to = .parent
        case (.parent, .answer), (.parent, .steer), (.parent, .cancel),
             (.user, .answer), (.user, .steer), (.user, .cancel): to = .child
        case (.host, .note): to = .parent
        default: throw DelegationRefusal("A \(from.rawValue) can't send a \(kind.rawValue).")
        }
        var m = DelegationMessage(kind: kind, from: from, to: to, text: text, answers: answering)
        if from != .host, let snippet = await scan(text) {
            m.blocked = snippet
            store.mutate(delegationID) { $0.messages.append(m) }
            audit(d.profileID, auditData(title: d.title, kind: kind, from: from, to: to, text: text, blocked: snippet))
            BACDebug.log("delegation", "withheld a \(kind.rawValue) from \(from.rawValue) on “\(d.title)”")
            throw DelegationRefusal("Your message was withheld: it reads like a prompt injection (“\(DelegationNotice.oneLine(snippet, max: 120))”). Rephrase it as plain facts about the work.")
        }
        store.mutate(delegationID) { d in
            d.messages.append(m)
            switch kind {
            case .ask: d.status = .waitingForParent
            case .answer, .steer: if d.status == .waitingForParent || d.status == .starting { d.status = .working }
            case .deliver: d.status = .delivered
            case .cancel: d.status = .cancelled
            case .report: if d.status == .starting { d.status = .working }
            case .brief, .note: break
            }
        }
        audit(d.profileID, auditData(title: d.title, kind: kind, from: from, to: to, text: text))
        let recipient = to == .parent ? d.parentSessionID : d.childSessionID
        if let fresh = store.delegation(delegationID) { notify(recipient, fresh, m) }
        return m
    }

    /// The parent (or the user, for it) answers a child's question.
    @discardableResult
    func answer(from parentID: UUID, askKey: String, text: String,
                by party: DelegationMessage.Party = .parent) async throws -> DelegationMessage {
        let mine = store.delegations(parent: parentID)
        guard let (d, ask) = store.message(matching: askKey, in: mine), ask.kind == .ask else {
            throw DelegationRefusal("No question “\(askKey)” waiting for you.")
        }
        return try await post(d.id, from: party, kind: .answer, text: text, answering: ask.id)
    }

    func steer(from parentID: UUID, delegationKey: String, text: String,
               by party: DelegationMessage.Party = .parent) async throws {
        let d = try delegation(delegationKey, as: .parent, for: parentID)
        try await post(d.id, from: party, kind: .steer, text: text)
    }

    /// Stop the child: the record says why, its session is ended.
    func cancel(from parentID: UUID, delegationKey: String, reason: String,
                by party: DelegationMessage.Party = .parent) async throws {
        let d = try delegation(delegationKey, as: .parent, for: parentID)
        guard d.status.isOpen else { throw DelegationRefusal("Delegation “\(d.title)” is already \(d.status.rawValue).") }
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let why = trimmedReason.isEmpty ? "no longer needed" : trimmedReason
        var m = DelegationMessage(kind: .cancel, from: party, to: .child, text: why)
        m.readAt = m.at
        store.mutate(d.id) { $0.messages.append(m); $0.status = .cancelled }
        audit(d.profileID, auditData(title: d.title, kind: .cancel, from: party, to: .child, text: why))
        wake(d.childSessionID)
        retireChild(d)
        BACDebug.log("delegation", "“\(d.title)” cancelled: \(why)")
    }

    /// The parent closes a delivered delegation with its verdict; the child
    /// hears it and its session ends.
    func close(from parentID: UUID, delegationKey: String, verdict: String, note: String?,
               by party: DelegationMessage.Party = .parent) async throws {
        let d = try delegation(delegationKey, as: .parent, for: parentID)
        guard d.status.isOpen else { throw DelegationRefusal("Delegation “\(d.title)” is already \(d.status.rawValue).") }
        let v = verdict.lowercased() == "rejected" ? "rejected" : "accepted"
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = "Delivery \(v)." + (trimmedNote.isEmpty ? "" : " " + trimmedNote)
        var m = DelegationMessage(kind: .note, from: party, to: .child, text: text)
        m.readAt = m.at
        store.mutate(d.id) { $0.messages.append(m); $0.status = .done; $0.verdict = v }
        audit(d.profileID, auditData(title: d.title, kind: .note, from: party, to: .child, text: text))
        wake(d.childSessionID)
        retireChild(d)
        BACDebug.log("delegation", "“\(d.title)” closed: \(v)")
    }

    /// The delegation is over: the child's agent ends and its session is
    /// put away (the Archived fold, readable as ever) rather than left
    /// under Ended.
    private func retireChild(_ d: Delegation) {
        guard let child = sessions.session(d.childSessionID), !child.isDeleted, !child.isArchived else { return }
        sessionEngine.archive(d.childSessionID)
    }

    // MARK: Inbox

    /// What's waiting for a session, taken (marked read).
    func inbox(for sessionID: UUID, in delegationID: UUID? = nil) -> [(Delegation, DelegationMessage)] {
        let items = store.unread(for: sessionID, in: delegationID)
        store.markRead(items.map { $0.1.id })
        return items
    }

    /// Block until something is waiting for the session (in one delegation,
    /// or any of its), at most `timeout`; what arrived, taken. Empty on a
    /// timeout.
    func wait(for sessionID: UUID, in delegationID: UUID? = nil,
              timeout: TimeInterval) async -> [(Delegation, DelegationMessage)] {
        let now = inbox(for: sessionID, in: delegationID)
        if !now.isEmpty { return now }
        let waiter = Waiter()
        waiters[sessionID, default: []].append(waiter)
        let t = min(max(timeout, 1), Self.waitCap)
        let timer = Task { [weak waiter] in
            try? await Task.sleep(nanoseconds: UInt64(t * 1_000_000_000))
            waiter?.resume()
        }
        await waiter.wait()
        timer.cancel()
        waiters[sessionID]?.removeAll { $0 === waiter }
        return inbox(for: sessionID, in: delegationID)
    }

    private func wake(_ sessionID: UUID) {
        guard let ws = waiters[sessionID], !ws.isEmpty else { return }
        for w in ws { w.resume() }
    }

    // MARK: Getting heard

    /// Kinds that interrupt: typed at the recipient's prompt once it can
    /// take them. A report waits to be read; the brief opens the child; a
    /// cancel ends it.
    static func interrupts(_ kind: DelegationMessage.Kind) -> Bool {
        switch kind {
        case .ask, .answer, .deliver, .steer, .note: return true
        case .brief, .report, .cancel: return false
        }
    }

    /// A notice is held while the recipient is mid-turn — but not past
    /// this: agents queue typed text for their next turn, and a status
    /// that never came back to "done" mustn't hold a message forever. A
    /// TUI question up (needsInput) holds it as long as it takes.
    static let holdWhileWorking: TimeInterval = 90

    /// A message reached the record; make sure its recipient hears it. A
    /// waiter takes it at once. Otherwise anything that interrupts is typed
    /// as a one-line notice — now if the prompt can take it, on a later
    /// tick if not, through a resume if the agent has ended.
    private func notify(_ sessionID: UUID, _ d: Delegation, _ m: DelegationMessage) {
        if let ws = waiters[sessionID], !ws.isEmpty {
            for w in ws { w.resume() }
            return
        }
        guard Self.interrupts(m.kind) else { return }
        deliverNotices(to: sessionID)
    }

    /// Type every notice the session is owed, as one line, if its prompt
    /// can take it now. The messages stay unread — the notice points at
    /// read_inbox for the full text.
    private func deliverNotices(to sessionID: UUID) {
        let items = store.unnoticed(for: sessionID).filter { Self.interrupts($0.1.kind) }
        guard !items.isEmpty, let s = sessions.session(sessionID), let delegate, !s.isDeleted else { return }
        if s.isLaunching { return }
        let lines = items.map { d, m in
            m.to == .parent ? DelegationNotice.toParent(m, in: d) : DelegationNotice.toChild(m, in: d)
        }
        let line = lines.count == 1 ? lines[0] : lines.joined(separator: DelegationNoticeRow.joiner)
        if s.windowIndex == nil || s.hasEnded || s.agentAlive == false {
            // The agent is gone: a resume brings it back with the notice —
            // an ended delegate picks its work back up on a steer.
            store.markNoticed(items.map { $0.1.id })
            BACDebug.log("delegation", "resuming “\(s.title)” with \(items.count) notice(s)")
            sessionEngine.resume(sessionID, message: line)
            return
        }
        guard let w = s.windowIndex else { return }
        let status = tabStatus(s)
        let oldest = items.map { $0.1.at }.min() ?? Date()
        let canType = status == nil || status == .done
            || (status == .working && Date().timeIntervalSince(oldest) > Self.holdWhileWorking)
        guard canType else { return }
        store.markNoticed(items.map { $0.1.id })
        Task {
            _ = try? await delegate.guestExec(
                profileID: s.profileID,
                command: CodingTaskEngine.typeCommand(tabIndex: w, text: line), timeout: 15)
        }
    }

    /// The prompt is free: no turn under way, no TUI question up.
    private func isIdle(_ s: AgentSession) -> Bool {
        guard s.windowIndex != nil, delegate != nil else { return false }
        let status = tabStatus(s)
        return status == nil || status == .done
    }

    private func tabStatus(_ s: AgentSession) -> AgentStatus? {
        guard let w = s.windowIndex, let delegate else { return nil }
        return delegate.pane(for: s.profileID)?.model.tabs.first { $0.index == w }?.agentStatus
    }

    /// Sessions the host still owes a notice.
    private func recipientsOwed() -> Set<UUID> {
        var out: Set<UUID> = []
        for d in store.delegations {
            for m in d.messages
            where m.readAt == nil && m.noticedAt == nil && m.isDelivered && Self.interrupts(m.kind) {
                out.insert(m.to == .parent ? d.parentSessionID : d.childSessionID)
            }
        }
        return out
    }

    /// Every few seconds: type what a busy prompt couldn't take, and look
    /// after the children.
    func tick() {
        for sid in recipientsOwed() { deliverNotices(to: sid) }
        watchChildren()
    }

    /// A child that bound its tab is working. One that never started
    /// failed, and so did one whose session was deleted. One whose agent
    /// ended without delivering stays open — its parent hears once, and a
    /// steer or an answer resumes the agent right where it was.
    private func watchChildren() {
        for d in store.delegations where d.status.isOpen {
            guard let child = sessions.session(d.childSessionID), !child.isDeleted else {
                fail(d, "the delegate's session was deleted"); continue
            }
            if d.status == .starting {
                if child.windowIndex != nil, !child.isLaunching {
                    store.mutate(d.id) { $0.status = .working }
                } else if let err = child.lastError, child.windowIndex == nil, !child.isLaunching {
                    fail(d, err)
                }
                continue
            }
            guard d.status != .delivered, child.windowIndex == nil, !child.isLaunching else { continue }
            let since = child.endedAt ?? child.lastSeenAt ?? child.createdAt
            guard Date().timeIntervalSince(since) > 8, (d.childEndedNotedAt ?? .distantPast) < since else { continue }
            store.mutate(d.id) { $0.childEndedNotedAt = Date() }
            BACDebug.log("delegation", "“\(d.title)”: the delegate ended without delivering")
            Task { [weak self] in
                _ = try? await self?.post(d.id, from: .host, kind: .note,
                                          text: "the delegate's agent ended without delivering — steer it (it picks the work back up) or cancel")
            }
        }
    }

    private func fail(_ d: Delegation, _ why: String) {
        store.mutate(d.id) { $0.status = .failed; $0.failure = why }
        BACDebug.log("delegation", "“\(d.title)” failed: \(why)")
        retireChild(d)
        Task { [weak self] in
            guard let self, let fresh = self.store.delegation(d.id) else { return }
            _ = try? await self.post(fresh.id, from: .host, kind: .note, text: "failed — \(why)")
        }
    }

    // MARK: Audit

    private func auditData(title: String, kind: DelegationMessage.Kind, from: DelegationMessage.Party,
                           to: DelegationMessage.Party, text: String, blocked: String? = nil) -> [String: AnyJSON] {
        var d: [String: AnyJSON] = [
            "delegation": .string(title),
            "kind": .string(kind.rawValue),
            "from": .string(from.rawValue),
            "to": .string(to.rawValue),
            "text": .string(DelegationNotice.oneLine(text, max: 200)),
            "verdict": .string(blocked == nil ? "clean" : "blocked"),
        ]
        if let blocked { d["snippet"] = .string(DelegationNotice.oneLine(blocked, max: 200)) }
        return d
    }

    /// One-shot continuation a `wait` parks on; resumed by a message or the
    /// timer, whichever comes first, never twice.
    private final class Waiter {
        private var continuation: CheckedContinuation<Void, Never>?
        private var done = false
        func wait() async {
            await withCheckedContinuation { c in
                if done { c.resume() } else { continuation = c }
            }
        }
        func resume() {
            guard !done else { return }
            done = true
            continuation?.resume()
            continuation = nil
        }
    }
}
