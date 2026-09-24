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
    /// The remote hosts a fat client here is connected to: their sessions
    /// are peers too, reached through the tunnel.
    var remoteLinks: @MainActor () -> [RemoteDelegationLink] = { [] }
    /// How this host is called on the far side ("@dev on Renaud's Mac").
    var hostLabel: @MainActor () -> String = { Host.current().localizedName ?? "a client" }

    /// Files a remote parent uploaded for a record here, waiting for the
    /// message they belong to (send / steer / answer).
    private var pendingRemoteFiles: [UUID: [String]] = [:]
    /// Files a remote peer attached, once copied onto the local parent's
    /// machine: message id → local paths (the record's paths are the far
    /// host's).
    private var remoteLanded: [UUID: [String]] = [:]
    private var landing: Set<UUID> = []

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
                self?.tick()
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

    // MARK: Peers on other hosts

    /// A peer, here or on a remote host reached through a fat client.
    enum ResolvedPeer {
        case local(AgentSession)
        case remote(RemoteDelegationLink, AgentSession)
    }

    /// Remote hosts are reachable while the workspace's policy is "every
    /// workspace"; a workspace that names the only ones stays on this host.
    func remotePeersAllowed(from me: AgentSession) -> Bool {
        profiles().first(where: { $0.id == me.profileID })?.agentReach == nil
    }

    /// The remote sessions `me` may talk to, per host.
    func remotePeers(from me: AgentSession) -> [(RemoteDelegationLink, AgentSession)] {
        guard remotePeersAllowed(from: me) else { return [] }
        var out: [(RemoteDelegationLink, AgentSession)] = []
        for link in remoteLinks() {
            for s in link.remoteSessions.sessions where !s.isArchived && !s.isDeleted && s.folderMissing != true {
                out.append((link, s))
            }
        }
        return out
    }

    /// "@nick" or an id prefix → the peer, here first, then on the remote
    /// hosts. The refusals say why when the name exists but is out of reach.
    func resolveAnyPeer(_ key: String, from me: AgentSession) throws -> ResolvedPeer {
        do { return .local(try resolvePeer(key, from: me)) } catch let local {
            let raw = key.trimmingCharacters(in: .whitespacesAndNewlines)
            let nick = DelegationNotice.normalizeNickname(raw)?.lowercased()
            let candidates = remotePeers(from: me)
            if let nick, let hit = candidates.first(where: { $0.1.nickname?.lowercased() == nick }) {
                return .remote(hit.0, hit.1)
            }
            if raw.count >= 6 {
                let hits = candidates.filter { $0.1.id.uuidString.lowercased().hasPrefix(raw.lowercased()) }
                if hits.count == 1 { return .remote(hits[0].0, hits[0].1) }
            }
            if let nick, !remotePeersAllowed(from: me),
               let far = remoteLinks().first(where: { l in l.remoteSessions.sessions.contains { $0.nickname?.lowercased() == nick && !$0.isDeleted } }) {
                throw DelegationRefusal("@\(nick) is on “\(far.hostName)” — this workspace's settings keep its agents to the workspaces they name, so other hosts are out of reach.")
            }
            throw local
        }
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
        let resolved = try resolveAnyPeer(key, from: me)
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DelegationRefusal("Nothing to ask.") }
        let open = delegationsAsParent(parentID).filter { $0.0.status.isOpen }.count
        guard open < Self.maxOpenChildren else {
            throw DelegationRefusal("You already have \(open) open delegations and requests — close some first.")
        }
        if let snippet = await scan(text) {
            audit(me.profileID, auditData(title: DelegationNotice.oneLine(text, max: 60), kind: .brief,
                                          from: .parent, to: .child, text: text, blocked: snippet))
            throw DelegationRefusal("Your request was withheld: it reads like a prompt injection (“\(DelegationNotice.oneLine(snippet, max: 120))”). Say what you need in plain terms.")
        }
        guard case .local(let peer) = resolved else {
            if case .remote(let link, let peer) = resolved {
                return try await requestRemote(from: me, link: link, peer: peer, text: text, files: files)
            }
            throw DelegationRefusal("No such peer.")
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

    /// A request to a session on another host: the record is opened THERE
    /// (where the peer's tools run), files go up through the tunnel into
    /// the peer's inbox, then the host hands the brief to the peer. What
    /// comes back arrives in that host's mirror; `remoteMirrorChanged`
    /// picks it up.
    private func requestRemote(from me: AgentSession, link: RemoteDelegationLink, peer: AgentSession,
                               text: String, files: [String]) async throws -> Delegation {
        let to = peer.nickname.map { "@" + $0 } ?? peer.id.uuidString
        let id: UUID
        do {
            id = try await link.remoteRequest(parentSessionID: me.id, parentLabel: label(me),
                                              parentHost: hostLabel(), to: to, text: text)
        } catch {
            throw DelegationRefusal("“\(link.hostName)” didn't take the request: \(error.localizedDescription)")
        }
        do {
            for path in files { try await uploadToRemote(link, delegation: id, from: me, path: path) }
            try await link.remoteCommand(delegation: id, action: "send", body: [:])
        } catch let r as DelegationRefusal {
            _ = try? await link.remoteCommand(delegation: id, action: "cancel", body: ["reason": "the files couldn't be sent"])
            throw r
        } catch {
            _ = try? await link.remoteCommand(delegation: id, action: "cancel", body: ["reason": "the files couldn't be sent"])
            throw DelegationRefusal("“\(link.hostName)” didn't take the request: \(error.localizedDescription)")
        }
        audit(me.profileID, auditData(title: DelegationNotice.oneLine(text, max: 60), kind: .brief,
                                      from: .parent, to: .child, text: text))
        BACDebug.log("delegation", "\(label(me)) asked \(label(peer)) on “\(link.hostName)”: \(DelegationNotice.oneLine(text, max: 80))")
        // The record as the mirror will show it; until the next poll, a
        // stand-in with the same id so the caller can wait on it.
        if let d = link.remoteDelegations.delegation(id) { return d }
        var d = Delegation(profileID: me.profileID, parentSessionID: me.id, childSessionID: peer.id,
                           title: DelegationNotice.oneLine(text, max: 60), brief: text, kind: .request)
        d.id = id
        d.status = .working
        d.parentLabel = label(me)
        d.childLabel = label(peer)
        return d
    }

    /// A file (a folder as a tarball) from `from`'s machine into the peer's
    /// inbox on a remote host, chunk by chunk through the tunnel.
    private func uploadToRemote(_ link: RemoteDelegationLink, delegation id: UUID,
                                from: AgentSession, path raw: String) async throws {
        guard let delegate else { throw DelegationRefusal("Files can't travel without the machines.") }
        let src = Self.resolve(raw, cwd: from.cwd)
        let name = (src as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { throw DelegationRefusal("Can't send “\(raw)”.") }
        let probe = ((try? await delegate.guestExec(
            profileID: from.profileID,
            command: "if [ -d \(Self.q(src)) ]; then echo dir; elif [ -f \(Self.q(src)) ]; then stat -c %s \(Self.q(src)); else echo missing; fi",
            timeout: 15)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !probe.isEmpty, probe != "missing" else { throw DelegationRefusal("No such file on your machine: \(raw)") }
        var readPath = src
        var sendName = name
        var extract = false
        if probe == "dir" {
            readPath = "/tmp/bromure-xfer-\(DelegationNotice.shortID(UUID())).tgz"
            sendName = name + ".tgz"
            extract = true
            _ = try await delegate.guestExec(
                profileID: from.profileID,
                command: "tar -C \(Self.q((src as NSString).deletingLastPathComponent)) -czf \(Self.q(readPath)) \(Self.q(name))",
                timeout: 180)
        }
        defer {
            if extract {
                Task { _ = try? await delegate.guestExec(profileID: from.profileID, command: "rm -f \(Self.q(readPath))", timeout: 10) }
            }
        }
        var offset: Int64 = 0
        var first = true
        while true {
            let resp = try await delegate.guestFileOp(
                profileID: from.profileID,
                op: ["op": "read", "path": readPath, "offset": offset, "length": Self.remoteChunk], timeout: 60)
            guard let b64 = resp["data"] as? String, let data = Data(base64Encoded: b64) else {
                throw DelegationRefusal("Couldn't read \(raw) on your machine.")
            }
            let size = (resp["size"] as? Int64) ?? Int64((resp["size"] as? Int) ?? 0)
            guard size <= Self.transferCap else {
                throw DelegationRefusal("\(raw) is \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) — up to \(ByteCountFormatter.string(fromByteCount: Self.transferCap, countStyle: .file)) travels per message.")
            }
            if first || !data.isEmpty {
                try await link.remoteUpload(delegation: id, name: sendName, data: data, append: !first, extract: extract)
            }
            offset += Int64(data.count)
            first = false
            if (resp["eof"] as? Bool) == true || data.isEmpty { break }
        }
    }

    /// Chunks through the tunnel: base64 on the wire, well under the API's
    /// body limit.
    static let remoteChunk = 4 * 1024 * 1024

    // MARK: Serving a remote parent (this host holds the record)

    /// A fat client's session asks one of ours: the record opens here with
    /// the parent marked remote, holding the brief until `sendRemote`.
    @discardableResult
    func requestFromRemote(parentSessionID: UUID, parent: RemoteParty, to key: String, text: String) async throws -> Delegation {
        let raw = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let nick = DelegationNotice.normalizeNickname(raw)?.lowercased()
        let candidates = sessions.sessions.filter { !$0.isArchived && !$0.isDeleted && $0.folderMissing != true }
        var peer = candidates.first { nick != nil && $0.nickname?.lowercased() == nick }
        if peer == nil, raw.count >= 6 {
            let hits = candidates.filter { $0.id.uuidString.lowercased().hasPrefix(raw.lowercased()) }
            if hits.count == 1 { peer = hits[0] }
        }
        guard let peer else { throw DelegationRefusal("No session named “\(raw)” here.") }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw DelegationRefusal("Nothing to ask.") }
        if let snippet = await scan(text) {
            audit(peer.profileID, auditData(title: DelegationNotice.oneLine(text, max: 60), kind: .brief,
                                            from: .parent, to: .child, text: text, blocked: snippet))
            throw DelegationRefusal("The request was withheld: it reads like a prompt injection (“\(DelegationNotice.oneLine(snippet, max: 120))”).")
        }
        var d = Delegation(profileID: peer.profileID, parentSessionID: parentSessionID, childSessionID: peer.id,
                           title: DelegationNotice.oneLine(text, max: 60), brief: text, kind: .request)
        d.parentRemote = parent
        d.parentLabel = "\(parent.label) on \(parent.host)"
        d.childLabel = label(peer)
        d.status = .starting
        store.upsert(d)
        BACDebug.log("delegation", "\(d.parentLabel ?? "?") is asking \(label(peer)) (request \(DelegationNotice.shortID(d.id)))")
        return d
    }

    /// A chunk of a file the remote parent sends for `delegationID`, into
    /// the peer's inbox; `extract` unpacks a tarball once complete.
    func receiveRemoteFile(delegationID: UUID, name: String, data: Data, append: Bool, extract: Bool) async throws {
        guard let d = store.delegation(delegationID), d.parentRemote != nil,
              let peer = sessions.session(d.childSessionID), let delegate else {
            throw DelegationRefusal("Unknown request.")
        }
        let safe = (name as NSString).lastPathComponent
        guard !safe.isEmpty, safe != ".", safe != "..", !name.contains("/") else { throw DelegationRefusal("Bad file name.") }
        guard await sessionEngine.ensureUp(peer.profileID, quietly: true) else {
            throw DelegationRefusal("The peer's workspace didn't start in time.")
        }
        let dest = "\(Self.inboxBase)/\(DelegationNotice.shortID(d.id))"
        let target = dest + "/" + safe
        if !append {
            _ = try await delegate.guestExec(profileID: peer.profileID, command: "mkdir -p \(Self.q(dest))", timeout: 15)
        }
        let soFar = (pendingRemoteFiles[delegationID] ?? []).reduce(Int64(0)) { $0 + Int64($1.utf8.count) }
        _ = soFar
        _ = try await delegate.guestFileOp(
            profileID: peer.profileID,
            op: ["op": "write", "path": target, "data": data.base64EncodedString(), "append": append], timeout: 60)
        if extract, data.count < Self.remoteChunk {
            // The last chunk of a tarball: unpack it where it landed.
            _ = try await delegate.guestExec(
                profileID: peer.profileID,
                command: "tar -xzf \(Self.q(target)) -C \(Self.q(dest)) && rm -f \(Self.q(target))", timeout: 180)
            let unpacked = dest + "/" + String(safe.dropLast(4))
            if !(pendingRemoteFiles[delegationID] ?? []).contains(unpacked) {
                pendingRemoteFiles[delegationID, default: []].append(unpacked)
            }
        } else if !extract, !(pendingRemoteFiles[delegationID] ?? []).contains(target) {
            pendingRemoteFiles[delegationID, default: []].append(target)
        }
    }

    /// The remote parent's brief is complete (files and all): hand it to the peer.
    func sendRemote(delegationID: UUID) throws {
        guard let d = store.delegation(delegationID), d.parentRemote != nil, d.status == .starting else {
            throw DelegationRefusal("Unknown request, or already sent.")
        }
        let landed = pendingRemoteFiles.removeValue(forKey: delegationID) ?? []
        let m = DelegationMessage(kind: .brief, from: .parent, to: .child, text: d.brief,
                                  files: landed.isEmpty ? nil : landed)
        store.mutate(d.id) { $0.messages.append(m); $0.status = .working }
        audit(d.profileID, auditData(title: d.title, kind: .brief, from: .parent, to: .child, text: d.brief))
        if let fresh = store.delegation(d.id) { notify(d.childSessionID, fresh, m) }
    }

    /// What a remote parent may do to its record here, by verb.
    func remoteCommand(delegationID: UUID, action: String, body: [String: Any]) async throws -> [String: Any] {
        guard let d = store.delegation(delegationID), d.parentRemote != nil else {
            throw DelegationRefusal("Unknown request.")
        }
        let parentID = d.parentSessionID
        let key = d.id.uuidString
        switch action {
        case "send":
            try sendRemote(delegationID: d.id)
        case "answer":
            guard let ask = body["ask_id"] as? String, let text = body["text"] as? String else {
                throw DelegationRefusal("ask_id and text are required")
            }
            let landed = pendingRemoteFiles.removeValue(forKey: d.id) ?? []
            let mine = store.delegations(parent: parentID)
            guard let (dd, askMsg) = store.message(matching: ask, in: mine), askMsg.kind == .ask, dd.id == d.id else {
                throw DelegationRefusal("No question “\(ask)” waiting for you.")
            }
            try await post(d.id, from: .parent, kind: .answer, text: text, answering: askMsg.id, landed: landed)
        case "steer":
            guard let text = body["text"] as? String else { throw DelegationRefusal("text is required") }
            let landed = pendingRemoteFiles.removeValue(forKey: d.id) ?? []
            try await post(d.id, from: .parent, kind: .steer, text: text, landed: landed)
        case "close":
            try await close(from: parentID, delegationKey: key,
                            verdict: body["verdict"] as? String ?? "accepted", note: body["note"] as? String)
        case "cancel":
            try await cancel(from: parentID, delegationKey: key, reason: body["reason"] as? String ?? "")
            pendingRemoteFiles[d.id] = nil
        case "read":
            let ids = ((body["ids"] as? [String]) ?? []).compactMap(UUID.init(uuidString:))
                .filter { id in d.messages.contains { $0.id == id && $0.to == .parent } }
            store.markRead(ids)
        case "noticed":
            let ids = ((body["ids"] as? [String]) ?? []).compactMap(UUID.init(uuidString:))
                .filter { id in d.messages.contains { $0.id == id && $0.to == .parent } }
            store.markNoticed(ids)
        default:
            throw DelegationRefusal("Unknown action “\(action)”.")
        }
        return ["ok": true, "status": store.delegation(d.id)?.status.rawValue ?? ""]
    }

    /// A chunk of a file the peer attached to a message for its remote
    /// parent, read off the peer's machine — only paths a message names.
    func readRemoteFile(delegationID: UUID, path: String, offset: Int64, length: Int) async throws -> [String: Any] {
        guard let d = store.delegation(delegationID), d.parentRemote != nil,
              let peer = sessions.session(d.childSessionID), let delegate else {
            throw DelegationRefusal("Unknown request.")
        }
        guard d.messages.contains(where: { $0.to == .parent && ($0.files ?? []).contains(path) }) else {
            throw DelegationRefusal("Not a file of this request.")
        }
        return try await delegate.guestFileOp(
            profileID: peer.profileID,
            op: ["op": "read", "path": path, "offset": offset, "length": min(max(length, 1), Self.remoteChunk)],
            timeout: 60)
    }

    // MARK: What a remote peer sent, landing here

    /// The mirror of a remote host changed: anything addressed to a session
    /// of ours — a peer's reply, an ask — is taken from there. Files it
    /// names are copied onto the parent's machine first; then waiters wake
    /// and the notice is typed, exactly as for a local record.
    func remoteMirrorChanged(_ link: RemoteDelegationLink) {
        for d in link.remoteDelegations.delegations where sessions.session(d.parentSessionID) != nil {
            var owed = false
            for m in d.messages where m.to == .parent && m.readAt == nil && m.isDelivered {
                if let files = m.files, !files.isEmpty, remoteLanded[m.id] == nil {
                    guard !landing.contains(m.id) else { continue }
                    landing.insert(m.id)
                    Task { [weak self] in
                        guard let self else { return }
                        let local = await self.landRemoteFiles(link, d, m)
                        self.remoteLanded[m.id] = local
                        self.landing.remove(m.id)
                        self.remoteMirrorChanged(link)
                    }
                    continue
                }
                owed = true
            }
            if owed { wake(d.parentSessionID) }
        }
        for sid in Set(link.remoteDelegations.delegations.filter { sessions.session($0.parentSessionID) != nil }.map(\.parentSessionID)) {
            deliverNotices(to: sid)
        }
    }

    /// Copy the files a remote peer attached onto the parent's machine, into
    /// the parent's inbox for that request; the local paths (the far ones
    /// where a copy failed, so nothing is silently lost).
    private func landRemoteFiles(_ link: RemoteDelegationLink, _ d: Delegation, _ m: DelegationMessage) async -> [String] {
        guard let delegate, let parent = sessions.session(d.parentSessionID), let files = m.files else { return m.files ?? [] }
        let dest = "\(Self.inboxBase)/\(DelegationNotice.shortID(d.id))"
        guard await sessionEngine.ensureUp(parent.profileID, quietly: true),
              (try? await delegate.guestExec(profileID: parent.profileID, command: "mkdir -p \(Self.q(dest))", timeout: 15)) != nil
        else { return files }
        var out: [String] = []
        for far in files {
            let name = (far as NSString).lastPathComponent
            let target = dest + "/" + name
            var offset: Int64 = 0
            var first = true
            var ok = true
            while true {
                guard let chunk = try? await link.remoteDownload(delegation: d.id, path: far, offset: offset, length: Self.remoteChunk) else { ok = false; break }
                if first || !chunk.data.isEmpty {
                    guard (try? await delegate.guestFileOp(
                        profileID: parent.profileID,
                        op: ["op": "write", "path": target, "data": chunk.data.base64EncodedString(), "append": !first],
                        timeout: 60)) != nil else { ok = false; break }
                }
                offset += Int64(chunk.data.count)
                first = false
                if chunk.eof || chunk.data.isEmpty { break }
            }
            out.append(ok ? target : far)
            BACDebug.log("delegation", ok ? "landed \(name) from “\(link.hostName)” (\(offset) bytes)" : "couldn't land \(name) from “\(link.hostName)”")
        }
        return out
    }

    /// A message with the files as this host sees them.
    private func localized(_ m: DelegationMessage) -> DelegationMessage {
        guard let local = remoteLanded[m.id] else { return m }
        var m = m
        m.files = local
        return m
    }

    /// Every delegation a session is the parent of — here, and on the
    /// remote hosts (with the host's name).
    func delegationsAsParent(_ sessionID: UUID) -> [(Delegation, String?)] {
        var out: [(Delegation, String?)] = store.delegations(parent: sessionID).map { ($0, nil) }
        for link in remoteLinks() {
            out += link.remoteDelegations.delegations(parent: sessionID).map { ($0, link.hostName) }
        }
        return out.sorted { $0.0.createdAt < $1.0.createdAt }
    }

    /// A delegation `key` names with `sessionID` as its parent: here, or on
    /// a remote host (which the link then acts on).
    func parentHandle(_ key: String, for sessionID: UUID) throws -> (Delegation, RemoteDelegationLink?) {
        if let d = store.delegation(matching: key), d.party(of: sessionID) == .parent { return (d, nil) }
        for link in remoteLinks() {
            if let d = link.remoteDelegations.delegation(matching: key), d.parentSessionID == sessionID {
                return (d, link)
            }
        }
        throw DelegationRefusal("No delegation “\(key)” of yours.")
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
              text: String, answering: UUID? = nil, files: [String] = [],
              landed: [String] = []) async throws -> DelegationMessage {
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
        if !files.isEmpty, let sender = sessions.session(to == .parent ? d.childSessionID : d.parentSessionID) {
            if let recipient = sessions.session(to == .parent ? d.parentSessionID : d.childSessionID) {
                m.files = try await transfer(files, from: sender, toProfile: recipient.profileID,
                                             inbox: DelegationNotice.shortID(d.id))
            } else {
                // The other end is on another host: it fetches the files off
                // the sender's machine through its tunnel — the record names
                // them as they are here.
                m.files = files.map { Self.resolve($0, cwd: sender.cwd) }
            }
        }
        // Files a remote parent already landed here for this message.
        if !landed.isEmpty { m.files = (m.files ?? []) + landed }
        store.mutate(delegationID) { d in
            // A child that speaks has read its brief (a request's, typed as a
            // notice) — it mustn't come back out of its inbox as news.
            if from == .child {
                for i in d.messages.indices where d.messages[i].kind == .brief && d.messages[i].readAt == nil {
                    d.messages[i].readAt = Date()
                }
            }
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
        if let (d, ask) = store.message(matching: askKey, in: mine), ask.kind == .ask {
            return try await post(d.id, from: party, kind: .answer, text: text, answering: ask.id)
        }
        // A question from a peer on another host: answered there.
        for link in remoteLinks() {
            let theirs = link.remoteDelegations.delegations(parent: parentID)
            if let (d, ask) = link.remoteDelegations.message(matching: askKey, in: theirs), ask.kind == .ask {
                try await remoteAct(link, d, action: "answer", body: ["ask_id": ask.id.uuidString, "text": text])
                var m = DelegationMessage(kind: .answer, from: party, to: .child, text: text, answers: ask.id)
                m.readAt = m.at
                return m
            }
        }
        throw DelegationRefusal("No question “\(askKey)” waiting for you.")
    }

    func steer(from parentID: UUID, delegationKey: String, text: String, files: [String] = [],
               by party: DelegationMessage.Party = .parent) async throws {
        let (d, link) = try parentHandle(delegationKey, for: parentID)
        if let link {
            guard let me = sessions.session(parentID) else { throw DelegationRefusal("Your session isn't known to Bromure.") }
            for path in files { try await uploadToRemote(link, delegation: d.id, from: me, path: path) }
            try await remoteAct(link, d, action: "steer", body: ["text": text])
            return
        }
        try await post(d.id, from: party, kind: .steer, text: text, files: files)
    }

    /// A parent-side verb on a record another host holds; the mirror is
    /// nudged so the panel doesn't lag a poll.
    private func remoteAct(_ link: RemoteDelegationLink, _ d: Delegation, action: String, body: [String: Any]) async throws {
        do {
            try await link.remoteCommand(delegation: d.id, action: action, body: body)
        } catch let r as DelegationRefusal {
            throw r
        } catch {
            throw DelegationRefusal("“\(link.hostName)” refused: \(error.localizedDescription)")
        }
        BACDebug.log("delegation", "\(action) on “\(d.title)” at “\(link.hostName)”")
    }

    /// Stop the child: the record says why; a delegate's session is put
    /// away (a peer's is its own business).
    func cancel(from parentID: UUID, delegationKey: String, reason: String,
                by party: DelegationMessage.Party = .parent) async throws {
        let (d, link) = try parentHandle(delegationKey, for: parentID)
        if let link {
            try await remoteAct(link, d, action: "cancel", body: ["reason": reason])
            link.remoteDelegations.mutate(d.id) { $0.status = .cancelled }
            return
        }
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
        let (d, link) = try parentHandle(delegationKey, for: parentID)
        if let link {
            var body: [String: Any] = ["verdict": verdict]
            if let note { body["note"] = note }
            try await remoteAct(link, d, action: "close", body: body)
            link.remoteDelegations.mutate(d.id) { $0.status = .done; $0.verdict = verdict.lowercased() == "rejected" ? "rejected" : "accepted" }
            return
        }
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

    /// What's waiting for a session, taken (marked read) — here, and in the
    /// records remote hosts hold for it (their files once landed).
    func inbox(for sessionID: UUID, in delegationID: UUID? = nil) -> [(Delegation, DelegationMessage)] {
        var items = store.unread(for: sessionID, in: delegationID)
        store.markRead(items.map { $0.1.id })
        for link in remoteLinks() {
            let theirs = link.remoteDelegations.unread(for: sessionID, in: delegationID)
                .filter { $0.0.parentSessionID == sessionID }
                .filter { ($0.1.files ?? []).isEmpty || remoteLanded[$0.1.id] != nil }
            guard !theirs.isEmpty else { continue }
            // Taken in the mirror now (so the next look doesn't repeat them)
            // and on the host as soon as it answers.
            link.remoteDelegations.markRead(theirs.map { $0.1.id })
            for (d, ids) in Dictionary(grouping: theirs, by: { $0.0.id }).mapValues({ $0.map { $0.1.id.uuidString } }) {
                Task { _ = try? await link.remoteCommand(delegation: d, action: "read", body: ["ids": ids]) }
            }
            items += theirs.map { ($0.0, localized($0.1)) }
        }
        return items.sorted { $0.1.at < $1.1.at }
    }

    /// Block until something is waiting for the session (in one delegation,
    /// or any of its), at most `timeout`; what arrived, taken. Empty on a
    /// timeout.
    func wait(for sessionID: UUID, in delegationID: UUID? = nil,
              timeout: TimeInterval) async -> [(Delegation, DelegationMessage)] {
        let now = inbox(for: sessionID, in: delegationID)
        if !now.isEmpty { return now }
        let t = min(max(timeout, 1), Self.waitCap)
        let deadline = Date().addingTimeInterval(t)
        // A wake with nothing to take (a message another waiter of this
        // session already took — a `request` still running alongside this
        // `wait`; one for a delegation this call isn't watching) is not a
        // timeout: keep waiting for what's left of the budget.
        while true {
            let waiter = Waiter()
            waiters[sessionID, default: []].append(waiter)
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { waiters[sessionID]?.removeAll { $0 === waiter }; return [] }
            let timer = Task { [weak waiter] in
                try? await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000))
                waiter?.resume()
            }
            await waiter.wait()
            timer.cancel()
            waiters[sessionID]?.removeAll { $0 === waiter }
            let got = inbox(for: sessionID, in: delegationID)
            if !got.isEmpty || Date() >= deadline { return got }
        }
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
        guard await sessionEngine.ensureUp(toProfile, quietly: true) else {
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
    /// A TUI question up (needsInput) holds a notice longer — typing into a
    /// dialog could answer it — but not forever: a status that never came
    /// back (a hook that misfired, a dialog nobody will answer) was holding
    /// messages for hours. Past this the line is typed anyway; it queues.
    static let holdWhileNeedsInput: TimeInterval = 600

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
        let now = Date()
        var items = store.unnoticed(for: sessionID, now: now, interrupts: DelegationNotice.interrupts)
        // What remote hosts hold for a session of ours (as its parent),
        // once any files have landed here.
        var remote: [(RemoteDelegationLink, Delegation, DelegationMessage)] = []
        for link in remoteLinks() {
            for (d, m) in link.remoteDelegations.unnoticed(for: sessionID, now: now, interrupts: DelegationNotice.interrupts)
            where d.parentSessionID == sessionID
                && ((m.files ?? []).isEmpty || remoteLanded[m.id] != nil) {
                remote.append((link, d, localized(m)))
                items.append((d, localized(m)))
            }
        }
        items.sort { $0.1.at < $1.1.at }
        guard !items.isEmpty, let s = sessions.session(sessionID), let delegate, !s.isDeleted else { return }
        if s.isLaunching { return }
        let lines = items.map { d, m in
            m.to == .parent ? DelegationNotice.toParent(m, in: d) : DelegationNotice.toChild(m, in: d)
        }
        let line = lines.count == 1 ? lines[0] : lines.joined(separator: DelegationNoticeRow.joiner)
        func markNoticed() {
            store.markNoticed(items.map { $0.1.id })
            for (link, d, m) in remote {
                link.remoteDelegations.markNoticed([m.id])
                Task { _ = try? await link.remoteCommand(delegation: d.id, action: "noticed", body: ["ids": [m.id.uuidString]]) }
            }
        }
        if s.windowIndex == nil || s.hasEnded || s.agentAlive == false {
            // The agent is gone: a resume brings it back with the notice —
            // an ended delegate picks its work back up on a steer, a peer
            // that was asleep wakes to the request.
            markNoticed()
            BACDebug.log("delegation", "resuming “\(s.title)” with \(items.count) notice(s)")
            sessionEngine.resume(sessionID, message: line, quietly: true)
            return
        }
        // Typed only into a tab the liveness probe has seen this agent in:
        // unknown (nil) is the app just launched, or a machine just booted
        // with the session still holding an index from its last boot — a
        // tab somebody else may have opened since. The next tick retries.
        guard let w = s.windowIndex, s.agentAlive == true else { return }
        let status = tabStatus(s)
        // How long the oldest owed message has waited since it was posted
        // or last noticed — the hold is per attempt, not per message.
        let waited = items.map { now.timeIntervalSince($0.1.noticedAt ?? $0.1.at) }.max() ?? 0
        let canType = status == nil || status == .done
            || (status == .working && waited > Self.holdWhileWorking)
            || (status == .needsInput && waited > Self.holdWhileNeedsInput)
        guard canType else { return }
        markNoticed()
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

    /// Sessions the host still owes a notice — a first one, or a repeat
    /// for a message still unread (see `DelegationStore.owesNotice`).
    private func recipientsOwed() -> Set<UUID> {
        var out: Set<UUID> = []
        let now = Date()
        for d in store.delegations {
            for m in d.messages
            where DelegationStore.owesNotice(m, interrupts: DelegationNotice.interrupts(m.kind, request: d.isRequest), now: now) {
                out.insert(m.to == .parent ? d.parentSessionID : d.childSessionID)
            }
        }
        return out
    }

    /// Every few seconds: type what a busy prompt couldn't take, look after
    /// the children, and take what remote hosts hold for our sessions.
    func tick() {
        for sid in recipientsOwed() { deliverNotices(to: sid) }
        for link in remoteLinks() { remoteMirrorChanged(link) }
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
