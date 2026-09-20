import Foundation

// The host side of a delegation (see AgentDelegation.swift for the words
// and the records). The engine starts the child session, moves each message
// between the two ends — scanned, audited, and only ever within the pair —
// and gets it heard: a blocked `wait` on the recipient's side is resumed at
// once; otherwise a one-line notice is typed at the recipient's prompt when
// it is idle, held until it is, or handed to a resume when the agent has
// ended. It also watches over the children: one that ends without
// delivering fails its delegation, and the parent hears about it.
//
// Sessions reach each other across workspaces on this host — every one by
// default; a workspace's settings can name the only ones its agents may
// reach. Machines share no filesystem, so files a message carries are
// copied by the host into the recipient's inbox.

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
    /// The workspaces: their names, and each one's reach policy.
    var profiles: @MainActor () -> [Profile] = { [] }

    /// A child may delegate in turn, this deep.
    static let maxDepth = 3
    /// Open delegations one session may have at once.
    static let maxOpenChildren = 8
    static let defaultWait: TimeInterval = 50
    static let waitCap: TimeInterval = 600
    /// Files a message may carry between machines: this many, this big
    /// all together.
    static let transferMaxFiles = 20
    static let transferCap: Int64 = 64 * 1024 * 1024
    static let transferChunk = 6 * 1024 * 1024
    /// Where the host lands files on the recipient's machine.
    static let inboxBase = "/home/ubuntu/.bromure/inbox"

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

    // MARK: Reach

    /// May agents in workspace `from` reach sessions in workspace `to`?
    /// Open by default; a workspace's `agentReach` names the only ones.
    func canReach(from: UUID, to: UUID) -> Bool {
        if from == to { return true }
        guard let p = profiles().first(where: { $0.id == from }), let only = p.agentReach else { return true }
        return only.contains(to)
    }

    func workspaceName(_ id: UUID) -> String {
        profiles().first { $0.id == id }?.name ?? ""
    }

    /// The sessions `me` may talk to: not put away, in a workspace the
    /// policy allows — asleep or ended ones included (a message wakes them).
    func reachableSessions(from me: AgentSession) -> [AgentSession] {
        sessions.sessions.filter { s in
            s.id != me.id && !s.isArchived && !s.isDeleted && s.folderMissing != true
                && canReach(from: me.profileID, to: s.profileID)
        }
    }

    /// "@nick", "nick", or an id prefix → the peer, among the reachable.
    func resolvePeer(_ key: String, from me: AgentSession) throws -> AgentSession {
        let raw = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let nick = DelegationNotice.normalizeNickname(raw)?.lowercased()
        let candidates = reachableSessions(from: me)
        if let nick, let s = candidates.first(where: { $0.nickname?.lowercased() == nick }) { return s }
        if raw.count >= 6 {
            let k = raw.lowercased()
            let hits = candidates.filter { $0.id.uuidString.lowercased().hasPrefix(k) }
            if hits.count == 1 { return hits[0] }
        }
        if let nick, let other = sessions.sessions.first(where: { $0.nickname?.lowercased() == nick && !$0.isDeleted }) {
            if other.id == me.id { throw DelegationRefusal("@\(other.nickname ?? nick) is you.") }
            if other.isArchived { throw DelegationRefusal("@\(other.nickname ?? nick) is archived — the user has to bring it back first.") }
            throw DelegationRefusal("@\(other.nickname ?? nick) is in workspace “\(workspaceName(other.profileID))”, which this workspace's settings don't let you reach.")
        }
        throw DelegationRefusal("No session named “\(raw)” — list_peers shows who you can reach.")
    }

    /// The workspace `key` names (name or id), reachable from `me`.
    func resolveWorkspace(_ key: String, from me: AgentSession) throws -> Profile {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = profiles()
        let hit = all.first { $0.id.uuidString.lowercased() == k }
            ?? all.first { $0.name.lowercased() == k }
            ?? { () -> Profile? in
                let c = all.filter { $0.name.lowercased().hasPrefix(k) }
                return c.count == 1 ? c[0] : nil
            }()
        guard let hit else { throw DelegationRefusal("No workspace named “\(key)” — list_peers names the ones you can reach.") }
        guard canReach(from: me.profileID, to: hit.id) else {
            throw DelegationRefusal("Workspace “\(hit.name)” isn't reachable from this one — its settings say which workspaces agents here may reach.")
        }
        return hit
    }

    /// How a session is named in the other end's notices.
    func label(_ s: AgentSession) -> String {
        if let n = s.nickname, !n.isEmpty { return "@" + n }
        return "“" + DelegationNotice.oneLine(s.title, max: 60) + "”"
    }

    // MARK: Delegating

    /// Start a child session for `parentID` with the brief as its opening
    /// message — a worktree off the parent's folder unless told otherwise,
    /// or a fresh folder in another workspace — and record the delegation.
    /// Files come along into the child's inbox. Refuses past the depth and
    /// fan-out limits, and a brief the scan flags.
    @discardableResult
    func delegate(from parentID: UUID, title: String, brief: String, contract: String?,
                  scope: [String], tool: Profile.Tool?, worktree: Bool?,
                  workspace: String? = nil, files: [String] = []) async throws -> Delegation {
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
        let target = try workspace.map { try resolveWorkspace($0, from: parent) }
        let targetProfileID = target?.id ?? parent.profileID
        let elsewhere = targetProfileID != parent.profileID
        let tool = tool ?? parent.tool

        var d = Delegation(profileID: parent.profileID, parentSessionID: parentID, childSessionID: parentID,
                           title: title, brief: brief, contract: contract, scope: scope)
        // Files first: they must be on the child's machine before it reads
        // its brief.
        var landed: [String] = []
        if !files.isEmpty {
            landed = try await transfer(files, from: parent, toProfile: targetProfileID,
                                        inbox: DelegationNotice.shortID(d.id))
        }
        let opening = DelegationNotice.opening(title: title, brief: brief, contract: contract,
                                               scope: scope, parentTitle: label(parent), files: landed)
        // A worktree by default — when there is a repository to branch. A
        // plain folder runs the delegate in place rather than failing the
        // delegation on a technicality; an explicit worktree: true still
        // insists (and fails with the reason). Another workspace has no
        // folder of the parent's to branch: the child gets one of its own.
        let useWorktree: Bool
        if elsewhere {
            useWorktree = false
        } else if let worktree {
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
            childID = sessionEngine.start(.init(profileID: targetProfileID, tool: tool,
                                                cwd: elsewhere ? "~" : parent.cwd,
                                                openingMessage: opening, title: title))
        }
        guard let childID else {
            throw DelegationRefusal("Your session has no folder to branch a worktree from — pass worktree: false to run the delegate in the same folder.")
        }
        d.childSessionID = childID
        d.parentLabel = label(parent)
        d.childLabel = "“\(title)”"
        var briefMessage = DelegationMessage(kind: .brief, from: .parent, to: .child, text: brief,
                                             files: landed.isEmpty ? nil : landed)
        briefMessage.readAt = briefMessage.at      // the child opens with it
        d.messages = [briefMessage]
        store.upsert(d)
        sessions.mutate(childID) { $0.parentSessionID = parentID; $0.delegationID = d.id }
        audit(parent.profileID, auditData(title: title, kind: .brief, from: .parent, to: .child, text: brief))
        BACDebug.log("delegation", "“\(parent.title)” delegated “\(title)” (\(tool.rawValue)\(useWorktree ? ", worktree" : "")\(elsewhere ? ", in \(target?.name ?? "")" : ""))")
        return d
    }

    /// Ask a session that already exists — a peer by nickname, here or in
    /// a reachable workspace — for something. The text reaches it as a
    /// notice (files in its inbox); its `deliver` is the reply.
    @discardableResult
    func request(from parentID: UUID, to key: String, text: String, files: [String] = []) async throws -> Delegation {
        guard let me = sessions.session(parentID) else {
            throw DelegationRefusal("Your session isn't known to Bromure.")
        }
        let peer = try resolvePeer(key, from: me)
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DelegationRefusal("Nothing to ask.") }
        let open = store.delegations(parent: parentID).filter { $0.status.isOpen }.count
        guard open < Self.maxOpenChildren else {
            throw DelegationRefusal("You already have \(open) open delegations and requests — close some first.")
        }
        if let snippet = await scan(text) {
            audit(me.profileID, auditData(title: DelegationNotice.oneLine(text, max: 60), kind: .brief,
                                          from: .parent, to: .child, text: text, blocked: snippet))
            throw DelegationRefusal("Your request was withheld: it reads like a prompt injection (“\(DelegationNotice.oneLine(snippet, max: 120))”). Say what you need in plain terms.")
        }
        var d = Delegation(profileID: me.profileID, parentSessionID: me.id, childSessionID: peer.id,
                           title: DelegationNotice.oneLine(text, max: 60), brief: text, kind: .request)
        d.parentLabel = label(me)
        d.childLabel = label(peer)
        d.status = .working
        var landed: [String] = []
        if !files.isEmpty {
            landed = try await transfer(files, from: me, toProfile: peer.profileID,
                                        inbox: DelegationNotice.shortID(d.id))
        }
        let m = DelegationMessage(kind: .brief, from: .parent, to: .child, text: text,
                                  files: landed.isEmpty ? nil : landed)
        d.messages = [m]
        store.upsert(d)
        audit(me.profileID, auditData(title: d.title, kind: .brief, from: .parent, to: .child, text: text))
        BACDebug.log("delegation", "\(label(me)) asked \(label(peer)): \(DelegationNotice.oneLine(text, max: 80))")
        notify(peer.id, d, m)
        return d
    }

    /// Is the session's folder inside a git checkout? Unknowable without
    /// the machine (no delegate, in tests): then no.
    private func isGitRepository(_ s: AgentSession) async -> Bool {
        guard let delegate else { return false }
        let path = ScheduledAutomationEngine.guestPath(s.cwd)
        let out = (try? await delegate.guestExec(
            profileID: s.profileID,
            command: "git -C \(Self.q(path)) rev-parse --is-inside-work-tree 2>/dev/null", timeout: 15)) ?? ""
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

    /// The delegation a child-side tool means: the one named, or the only
    /// open one the session is the child of.
    func childDelegation(_ key: String?, for sessionID: UUID) throws -> Delegation {
        if let key, !key.isEmpty { return try delegation(key, as: .child, for: sessionID) }
        let open = store.openAsChild(sessionID)
        // One still waiting on a delivery is the one meant; a delivered
        // one only when it's the only one left (a follow-up after a steer).
        let undelivered = open.filter { $0.status != .delivered }
        if undelivered.count == 1 { return undelivered[0] }
        switch open.count {
        case 0: throw DelegationRefusal("You aren't anyone's delegate right now — nobody to answer.")
        case 1: return open[0]
        default:
            let list = open.map { "\(DelegationNotice.shortID($0.id)) (\($0.isRequest ? "request from " + ($0.parentLabel ?? "?") : "delegation “\($0.title)”"))" }
                .joined(separator: ", ")
            throw DelegationRefusal("Which one? Pass delegation_id: \(list).")
        }
    }

    /// Record a message and get it to the other end. Throws when the
    /// delegation is closed, the kind isn't the party's to send, or the scan
    /// withholds it (the message stays on the record, marked blocked).
    /// Files are copied into the recipient's inbox first.
    @discardableResult
    func post(_ delegationID: UUID, from: DelegationMessage.Party, kind: DelegationMessage.Kind,
              text: String, answering: UUID? = nil, files: [String] = []) async throws -> DelegationMessage {
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
        if !files.isEmpty,
           let sender = sessions.session(to == .parent ? d.childSessionID : d.parentSessionID),
           let recipient = sessions.session(to == .parent ? d.parentSessionID : d.childSessionID) {
            m.files = try await transfer(files, from: sender, toProfile: recipient.profileID,
                                         inbox: DelegationNotice.shortID(d.id))
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

    func steer(from parentID: UUID, delegationKey: String, text: String, files: [String] = [],
               by party: DelegationMessage.Party = .parent) async throws {
        let d = try delegation(delegationKey, as: .parent, for: parentID)
        try await post(d.id, from: party, kind: .steer, text: text, files: files)
    }

    /// Stop the child: the record says why; a delegate's session is put
    /// away (a peer's is its own business).
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
        if d.isRequest {
            // The peer hears it stopped, and goes on with its own life.
            if let fresh = store.delegation(d.id) {
                store.mutate(d.id) { $0.messages[$0.messages.count - 1].readAt = nil }
                notify(d.childSessionID, fresh, m)
            }
        } else {
            retireChild(d)
        }
        BACDebug.log("delegation", "“\(d.title)” cancelled: \(why)")
    }

    /// The parent closes a delivered delegation with its verdict; the child
    /// hears it and, for a delegate, its session ends.
    func close(from parentID: UUID, delegationKey: String, verdict: String, note: String?,
               by party: DelegationMessage.Party = .parent) async throws {
        let d = try delegation(delegationKey, as: .parent, for: parentID)
        guard d.status.isOpen else { throw DelegationRefusal("Delegation “\(d.title)” is already \(d.status.rawValue).") }
        let v = verdict.lowercased() == "rejected" ? "rejected" : "accepted"
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = (d.isRequest ? "Request closed (\(v))." : "Delivery \(v).") + (trimmedNote.isEmpty ? "" : " " + trimmedNote)
        var m = DelegationMessage(kind: .note, from: party, to: .child, text: text)
        m.readAt = m.at
        store.mutate(d.id) { $0.messages.append(m); $0.status = .done; $0.verdict = v }
        audit(d.profileID, auditData(title: d.title, kind: .note, from: party, to: .child, text: text))
        wake(d.childSessionID)
        if !d.isRequest { retireChild(d) }
        BACDebug.log("delegation", "“\(d.title)” closed: \(v)")
    }

    /// The delegation is over: the child's agent ends and its session is
    /// put away (the Archived fold, readable as ever) rather than left
    /// under Ended. A request's peer is left alone.
    private func retireChild(_ d: Delegation) {
        guard !d.isRequest,
              let child = sessions.session(d.childSessionID), !child.isDeleted, !child.isArchived else { return }
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

    // MARK: Files between machines

    /// Copy files (a folder travels as a tarball) from `from`'s machine
    /// into `inbox` on `toProfile`'s: ~/.bromure/inbox/<id>/<name>. Paths
    /// relative to the sender's folder are resolved there; "~" is its home.
    /// Returns the paths as the recipient sees them. On one machine it is a
    /// plain copy. The recipient's workspace is started if it's off.
    func transfer(_ paths: [String], from: AgentSession, toProfile: UUID, inbox: String) async throws -> [String] {
        guard let delegate else { throw DelegationRefusal("Files can't travel without the machines.") }
        guard paths.count <= Self.transferMaxFiles else {
            throw DelegationRefusal("At most \(Self.transferMaxFiles) files per message — send a folder, or an archive.")
        }
        guard await sessionEngine.ensureUp(toProfile) else {
            throw DelegationRefusal("The recipient's workspace didn't start in time.")
        }
        let dest = "\(Self.inboxBase)/\(inbox)"
        _ = try await delegate.guestExec(profileID: toProfile, command: "mkdir -p \(Self.q(dest))", timeout: 15)
        var out: [String] = []
        var total: Int64 = 0
        for raw in paths {
            let src = Self.resolve(raw, cwd: from.cwd)
            let name = (src as NSString).lastPathComponent
            guard !name.isEmpty, name != ".", name != ".." else { throw DelegationRefusal("Can't send “\(raw)”.") }
            let target = dest + "/" + name
            let probe = ((try? await delegate.guestExec(
                profileID: from.profileID,
                command: "if [ -d \(Self.q(src)) ]; then echo dir; elif [ -f \(Self.q(src)) ]; then stat -c %s \(Self.q(src)); else echo missing; fi",
                timeout: 15)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !probe.isEmpty, probe != "missing" else {
                throw DelegationRefusal("No such file on your machine: \(raw)")
            }
            if from.profileID == toProfile {
                _ = try await delegate.guestExec(profileID: toProfile,
                                                 command: "cp -a \(Self.q(src)) \(Self.q(target))", timeout: 120)
                out.append(target)
                continue
            }
            if probe == "dir" {
                let tgz = "/tmp/bromure-xfer-\(DelegationNotice.shortID(UUID())).tgz"
                let parent = (src as NSString).deletingLastPathComponent
                _ = try await delegate.guestExec(
                    profileID: from.profileID,
                    command: "tar -C \(Self.q(parent)) -czf \(Self.q(tgz)) \(Self.q(name))", timeout: 180)
                total += try await copyFile(from: from.profileID, path: tgz, to: toProfile, path: target + ".tgz",
                                            budgetLeft: Self.transferCap - total)
                _ = try? await delegate.guestExec(profileID: from.profileID, command: "rm -f \(Self.q(tgz))", timeout: 10)
                _ = try await delegate.guestExec(
                    profileID: toProfile,
                    command: "tar -xzf \(Self.q(target + ".tgz")) -C \(Self.q(dest)) && rm -f \(Self.q(target + ".tgz"))",
                    timeout: 180)
            } else {
                total += try await copyFile(from: from.profileID, path: src, to: toProfile, path: target,
                                            budgetLeft: Self.transferCap - total)
            }
            out.append(target)
        }
        BACDebug.log("delegation", "moved \(out.count) file(s), \(total) bytes, into \(dest)")
        return out
    }

    /// One file, chunk by chunk through the host; the bytes moved.
    private func copyFile(from srcProfile: UUID, path src: String, to dstProfile: UUID, path dst: String,
                          budgetLeft: Int64) async throws -> Int64 {
        guard let delegate else { throw DelegationRefusal("Files can't travel without the machines.") }
        var offset: Int64 = 0
        var first = true
        while true {
            let resp = try await delegate.guestFileOp(
                profileID: srcProfile,
                op: ["op": "read", "path": src, "offset": offset, "length": Self.transferChunk], timeout: 60)
            guard let b64 = resp["data"] as? String, let data = Data(base64Encoded: b64) else {
                throw DelegationRefusal("Couldn't read \(src) on your machine.")
            }
            let size = (resp["size"] as? Int64) ?? Int64((resp["size"] as? Int) ?? 0)
            guard size <= budgetLeft else {
                throw DelegationRefusal("\(src) is \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) — up to \(ByteCountFormatter.string(fromByteCount: Self.transferCap, countStyle: .file)) travels per message.")
            }
            if first || !data.isEmpty {
                _ = try await delegate.guestFileOp(
                    profileID: dstProfile,
                    op: ["op": "write", "path": dst, "data": b64, "append": !first], timeout: 60)
            }
            offset += Int64(data.count)
            first = false
            if (resp["eof"] as? Bool) == true || data.isEmpty { break }
        }
        return offset
    }

    /// A path as the sender means it: absolute as is, "~" its home, else
    /// under its folder.
    static func resolve(_ raw: String, cwd: String) -> String {
        let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.hasPrefix("/") { return p }
        if p.hasPrefix("~") { return ScheduledAutomationEngine.guestPath(p) }
        let base = ScheduledAutomationEngine.guestPath(cwd)
        var rel = p
        while rel.hasPrefix("./") { rel.removeFirst(2) }
        return base + "/" + rel
    }

    static func q(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: Getting heard

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
        guard DelegationNotice.interrupts(m.kind, request: d.isRequest) else { return }
        deliverNotices(to: sessionID)
    }

    /// Type every notice the session is owed, as one line, if its prompt
    /// can take it now. The messages stay unread — the notice points at
    /// read_inbox for the full text.
    private func deliverNotices(to sessionID: UUID) {
        let items = store.unnoticed(for: sessionID).filter { DelegationNotice.interrupts($0.1.kind, request: $0.0.isRequest) }
        guard !items.isEmpty, let s = sessions.session(sessionID), let delegate, !s.isDeleted else { return }
        if s.isLaunching { return }
        let lines = items.map { d, m in
            m.to == .parent ? DelegationNotice.toParent(m, in: d) : DelegationNotice.toChild(m, in: d)
        }
        let line = lines.count == 1 ? lines[0] : lines.joined(separator: DelegationNoticeRow.joiner)
        if s.windowIndex == nil || s.hasEnded || s.agentAlive == false {
            // The agent is gone: a resume brings it back with the notice —
            // an ended delegate picks its work back up on a steer, a peer
            // that was asleep wakes to the request.
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
            where m.readAt == nil && m.noticedAt == nil && m.isDelivered
                && DelegationNotice.interrupts(m.kind, request: d.isRequest) {
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
    /// steer or an answer resumes the agent right where it was. A request's
    /// peer is nobody's to watch: it lives its own life.
    private func watchChildren() {
        for d in store.delegations where d.status.isOpen {
            guard let child = sessions.session(d.childSessionID), !child.isDeleted else {
                fail(d, d.isRequest ? "the peer's session was deleted" : "the delegate's session was deleted"); continue
            }
            if d.isRequest { continue }
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
