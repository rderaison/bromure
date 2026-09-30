import Foundation

/// An agent session, as a fat client decodes it (`AgentSession`, JSON with
/// ISO-8601 dates): the same keys, the subset this host fills in. Unknown
/// extras (`transcriptPath`) are ignored by the client.
struct HostSession: Codable, Equatable {
    var id: UUID
    var profileID: UUID
    var tool: String
    var title: String
    var cwd: String
    var cloneURL: String?
    var openingMessage: String?
    var createdAt: Date
    var windowIndex: Int?
    var launchingSince: Date?
    var endedAt: Date?
    var lastSeenAt: Date?
    var agentSeenAt: Date?
    var agentAlive: Bool?
    var resumedAt: Date?
    var userTitled: Bool?
    var launchDisplay: String?
    var archivedAt: Date?
    var deletedAt: Date?
    var nickname: String?
    var agentTranscriptID: String?
    /// Delegation (records kept by the Bromure AC that serves the MCP): the
    /// session that started this one as its delegate, and their delegation.
    var parentSessionID: UUID?
    var delegationID: UUID?
    /// A branch session (Worktrees.swift): the session it branched from,
    /// its branch, the branch it came from and the main checkout — and what
    /// the last probe read, and a merge under way (the shapes Bromure AC's
    /// BranchInfo / BranchMerge decode).
    var worktreeOf: UUID?
    var worktreeBranch: String?
    var branchParent: String?
    var branchRoot: String?
    var branchInfo: BranchInfo?
    var branchMerge: BranchMerge?
    var folderMissing: Bool?
    /// The review window's comments on this session's changes, and which
    /// files were marked viewed (at which diff) — Bromure AC's shapes, kept
    /// here because a server's copy of this record is rewritten from it.
    var reviewComments: [ReviewComment]?
    var reviewViewed: [String: String]?
    /// The transcript the agent's hook last reported (host-only).
    var transcriptPath: String?
}

struct BranchInfo: Codable, Equatable {
    var ahead: Int
    var behind: Int
    var changed: Int
    var checkedAt: Date
}

struct BranchMerge: Codable, Equatable {
    var target: String
    var squash: Bool
    var removeAfter: Bool
    var startedAt: Date
    /// requested / merging / conflicts / merged / failed
    var phase: String
    var detail: String?
    var askedBy: UUID?
}

/// Bromure AC's ReviewComment, over the wire.
struct ReviewComment: Codable, Equatable {
    var id: UUID
    var text: String
    var file: String?
    var line: Int?
    var createdAt: Date
    var sentAt: Date?
}

/// Owns the sessions and keeps them bound to tmux windows. A window we open
/// carries `@bromure_session = <id>`, so a binding survives index reuse and
/// app restarts (the tmux server outlives the app). An agent the user starts
/// by hand in the `bromure` session is adopted the same way.
final class SessionEngine: @unchecked Sendable {
    static let shared = SessionEngine()

    /// The one pseudo-machine this host presents ("This Mac").
    let hostID: UUID
    static let tools = ["claude", "codex", "grok", "kimi", "omp"]

    private let queue = DispatchQueue(label: "agent-host.sessions")
    private var sessions: [HostSession] = []
    private var lastWindows: [Tmux.Window] = []
    private var lastAgents: [Int: String] = [:]   // window index → running tool
    private var lastPrompting: Set<Int> = []
    private var lastRefresh = Date.distantPast
    private var tmuxUp = false

    /// Posted on the main queue when the session list changes.
    static let didChange = Notification.Name("AgentHostSessionsDidChange")

    private init() {
        if let s = try? String(contentsOf: AgentHostPaths.hostIDFile, encoding: .utf8),
           let id = UUID(uuidString: s.trimmingCharacters(in: .whitespacesAndNewlines)) {
            hostID = id
        } else {
            hostID = UUID()
            try? hostID.uuidString.write(to: AgentHostPaths.hostIDFile, atomically: true, encoding: .utf8)
        }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: AgentHostPaths.sessionsFile),
           let list = try? dec.decode([HostSession].self, from: data) {
            sessions = list
        }
    }

    // MARK: Snapshot

    struct Snapshot {
        var sessions: [HostSession]
        var windows: [Tmux.Window]
        var agents: [Int: String]
        /// Agents on a screen that waits for the user before any hook ran
        /// (Claude's folder-trust dialog runs before its hooks exist).
        var prompting: Set<Int>
        var tmuxUp: Bool
    }

    /// Sessions reconciled against the live windows — at most every half
    /// second, however many clients poll.
    func snapshot() -> Snapshot {
        queue.sync {
            if Date().timeIntervalSince(lastRefresh) > 0.5 { refreshLocked() }
            return Snapshot(sessions: sessions, windows: lastWindows, agents: lastAgents,
                            prompting: lastPrompting, tmuxUp: tmuxUp)
        }
    }

    func session(_ id: UUID) -> HostSession? {
        queue.sync { sessions.first { $0.id == id } }
    }

    private func refreshLocked() {
        lastRefresh = Date()
        guard let windows = Tmux.listWindows() else {
            tmuxUp = false
            lastWindows = []
            lastAgents = [:]
            lastPrompting = []
            return
        }
        tmuxUp = true
        let agents = Self.runningAgents(in: windows)
        lastWindows = windows
        lastAgents = agents
        lastPrompting = Set(windows.filter { agents[$0.index] != nil && $0.status.isEmpty && Self.waitsOnUser($0.index) }
            .map(\.index))
        reconcileLocked(windows: windows, agents: agents)
    }

    private func reconcileLocked(windows: [Tmux.Window], agents: [Int: String]) {
        let before = sessions
        let now = Date()
        let byID = Dictionary(windows.map { ($0.sessionID, $0) }, uniquingKeysWith: { a, _ in a })
        for i in sessions.indices {
            var s = sessions[i]
            if let w = byID[s.id.uuidString] {
                let tool = agents[w.index]
                s.windowIndex = w.index
                s.endedAt = nil
                s.lastSeenAt = now
                s.agentAlive = tool != nil
                if tool != nil { s.agentSeenAt = now; s.launchingSince = nil }
                if !w.agentSessionID.isEmpty { s.agentTranscriptID = w.agentSessionID }
                if !w.transcriptPath.isEmpty { s.transcriptPath = w.transcriptPath }
                if s.launchDisplay == nil { s.launchDisplay = w.title }
                // Give up on "starting" after a minute: the tab is a shell.
                if let since = s.launchingSince, now.timeIntervalSince(since) > 60 { s.launchingSince = nil }
            } else if s.windowIndex != nil || s.launchingSince != nil {
                s.windowIndex = nil
                s.launchingSince = nil
                s.agentAlive = false
                if s.endedAt == nil { s.endedAt = now }
            }
            sessions[i] = s
        }
        // A deleted session goes once its tab is gone.
        sessions.removeAll { $0.deletedAt != nil && $0.windowIndex == nil }

        // Adopt agents running in windows nobody claims (started by hand in
        // the `bromure` session, or by `bromure-sidecar claude`).
        for w in windows where w.sessionID.isEmpty {
            guard let tool = agents[w.index] else { continue }
            var s = HostSession(id: UUID(), profileID: hostID, tool: tool,
                                title: Self.defaultTitle(tool: tool, cwd: w.cwd),
                                cwd: w.cwd, createdAt: now)
            s.windowIndex = w.index
            s.agentAlive = true
            s.agentSeenAt = now
            s.lastSeenAt = now
            s.launchDisplay = w.title
            Tmux.setWindowOption(w.index, "@bromure_session", s.id.uuidString)
            sessions.append(s)
            AgentHostLog.log("sessions: adopted \(tool) in window \(w.index) (\(w.cwd))")
        }
        if sessions != before { saveLocked(); notify() }
    }

    /// Which agent runs in each window: the pane's process tree searched for
    /// a known agent binary. The pane's foreground command name is no good —
    /// Claude's native build runs as `…/claude/versions/2.1.3`.
    static func runningAgents(in windows: [Tmux.Window]) -> [Int: String] {
        let r = HostProcess.run(executable: "/bin/ps", args: ["-A", "-o", "pid=,ppid=,args="],
                                env: ["PATH": "/usr/bin:/bin"], timeout: 5)
        var children: [Int32: [Int32]] = [:]
        var argsOf: [Int32: String] = [:]
        for line in r.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 2, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
            children[ppid, default: []].append(pid)
            argsOf[pid] = parts.count > 2 ? String(parts[2]) : ""
        }
        var out: [Int: String] = [:]
        for w in windows where w.panePID > 0 {
            var stack = [w.panePID]
            var seen = Set<Int32>()
            search: while let pid = stack.popLast() {
                guard seen.insert(pid).inserted else { continue }
                if pid != w.panePID, let tool = agentTool(argsOf[pid] ?? "") {
                    out[w.index] = tool
                    break search
                }
                stack += children[pid] ?? []
            }
        }
        return out
    }

    /// The agent a command line runs, if any: its program (first word, or
    /// the script an interpreter runs) named after a known agent, or
    /// Claude's versioned native binary.
    static func agentTool(_ args: String) -> String? {
        let words = args.split(separator: " ").map(String.init)
        guard let first = words.first else { return nil }
        if first.contains("/claude/versions/") { return "claude" }
        let candidates = [first] + (["node", "bun"].contains((first as NSString).lastPathComponent)
                                    ? Array(words.dropFirst().prefix(1)) : [])
        for c in candidates {
            let base = (c as NSString).lastPathComponent
            if tools.contains(base) { return base }
            if c.contains("/claude-code/") { return "claude" }
        }
        return nil
    }

    /// A picker on screen ("Enter to confirm", Claude's trust dialog).
    static func waitsOnUser(_ idx: Int) -> Bool {
        let screen = Tmux.run(["capture-pane", "-p", "-J", "-t", "\(Tmux.session):\(idx)"], timeout: 3).out
        return screen.contains("Enter to confirm") || screen.contains("trust this folder")
    }

    static func defaultTitle(tool: String, cwd: String) -> String {
        let name = tool.prefix(1).uppercased() + tool.dropFirst()
        let folder = (cwd as NSString).lastPathComponent
        return folder.isEmpty ? name : "\(name) in \(folder)"
    }

    // MARK: Commands

    struct StartRequest {
        var tool: String
        var cwd: String
        var cloneURL: String?
        var message: String?
        var attachments: [[String: Any]] = []
        /// More arguments for the agent (the terminal launcher's own).
        var extraArgs: [String] = []
    }

    /// Start an agent in a new window; its session id and window index.
    func start(_ req: StartRequest) -> Result<(id: UUID, window: Int), HostError> {
        guard Self.tools.contains(req.tool) else { return .failure(.bad("unknown agent \(req.tool)")) }
        if AgentInstaller.isKnownMissing(req.tool) {
            let name = AgentSpec.spec(req.tool)?.name ?? req.tool
            return .failure(.bad("\(name) isn't installed on this Mac. Install it from Manage Agents… in the Bromure Sidecar menu."))
        }
        let dir = Self.expand(req.cwd)
        var isDir: ObjCBool = false
        let clone = req.cloneURL.flatMap { $0.isEmpty ? nil : $0 }
        if clone == nil {
            guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else {
                return .failure(.bad("No folder \(dir) on this Mac"))
            }
        } else {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        var message = req.message ?? ""
        let staged = Self.stage(req.attachments)
        if !staged.isEmpty {
            message += (message.isEmpty ? "" : "\n\n") + staged.joined(separator: "\n")
        }
        let id = UUID()
        let title = Self.title(for: message, tool: req.tool, cwd: dir)
        let inner = Self.launchCommand(tool: req.tool, message: message.isEmpty ? nil : message,
                                       resume: nil, cloneURL: clone, extraArgs: req.extraArgs)
        guard let idx = Tmux.newWindow(cwd: dir, name: req.tool, command: Self.wrap(inner),
                                       options: ["@display": title, "@bromure_session": id.uuidString])
        else { return .failure(.failed("Couldn't open a tmux window")) }
        var s = HostSession(id: id, profileID: hostID, tool: req.tool, title: title,
                            cwd: dir, createdAt: Date())
        s.cloneURL = clone
        s.openingMessage = req.message
        s.windowIndex = idx
        s.launchingSince = Date()
        s.launchDisplay = title
        queue.sync {
            sessions.append(s)
            saveLocked()
            lastRefresh = .distantPast
        }
        notify()
        AgentHostLog.log("sessions: started \(req.tool) \(id) in window \(idx) (\(dir))")
        return .success((id, idx))
    }

    func command(_ id: UUID, _ action: String, _ body: [String: Any]) -> Result<[String: Any], HostError> {
        guard var s = session(id) else { return .failure(.notFound("unknown session")) }
        let live = s.windowIndex
        switch action {
        case "resume":
            let message = (body["message"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let live {
                if let message { DispatchQueue.global().async { Tmux.type(live, message) } }
            } else {
                let inner = Self.launchCommand(tool: s.tool, message: message,
                                               resume: s.agentTranscriptID ?? "", cloneURL: nil)
                guard let idx = Tmux.newWindow(cwd: s.cwd, name: s.tool, command: Self.wrap(inner),
                                               options: ["@display": s.title, "@bromure_session": s.id.uuidString])
                else { return .failure(.failed("Couldn't open a tmux window")) }
                s.windowIndex = idx
                s.launchingSince = Date()
                s.resumedAt = Date()
                s.endedAt = nil
            }
            s.archivedAt = nil
        case "send":
            guard let text = body["text"] as? String, !text.isEmpty else { return .failure(.bad("text required")) }
            guard let live else { return command(id, "resume", ["message": text]) }
            DispatchQueue.global().async { Tmux.type(live, text) }
        case "keys":
            let keys = (body["keys"] as? [String]) ?? []
            guard let live, !keys.isEmpty, keys.count <= 12 else { return .failure(.bad("keys required on a live session")) }
            DispatchQueue.global().async { Tmux.sendKeys(live, keys) }
        case "close":
            if let live { Tmux.killWindow(live) }
            s.windowIndex = nil
            s.agentAlive = false
            s.endedAt = Date()
        case "archive":
            if let live { Tmux.killWindow(live) }
            s.windowIndex = nil
            s.agentAlive = false
            if s.endedAt == nil { s.endedAt = Date() }
            s.archivedAt = Date()
        case "unarchive":
            s.archivedAt = nil
        case "delete":
            if let live { Tmux.killWindow(live) }
            s.windowIndex = nil
            s.deletedAt = Date()
        case "forget":
            if let live { Tmux.killWindow(live) }
            queue.sync {
                sessions.removeAll { $0.id == id }
                saveLocked()
            }
            notify()
            return .success(["ok": true])
        case "rename":
            guard let t = (body["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !t.isEmpty else { return .failure(.bad("title required")) }
            s.title = t
            s.userTitled = true
            if let live { Tmux.setWindowOption(live, "@display", t) }
        case "worktree":
            // {name, tool?, message?, initGit?, base?}: a new session on a
            // branch of this one's folder.
            var name = ((body["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                // No name: after the message's first words.
                let words = ((body["message"] as? String) ?? "").split(whereSeparator: \.isWhitespace).prefix(6)
                name = words.isEmpty ? "branch" : words.joined(separator: " ")
            }
            return startWorktree(from: s, name: name, tool: (body["tool"] as? String) ?? s.tool,
                                 message: body["message"] as? String,
                                 initGit: body["initGit"] as? Bool ?? false, base: body["base"] as? String)
                .map { ["ok": true, "id": $0.id.uuidString, "window": $0.window] }
        case "branch-request":
            // An agent asks to merge (worktree_merge): it waits for the user.
            guard s.worktreeBranch != nil else { return .failure(.bad("not a branch session")) }
            if let p = s.branchMerge?.phase, p == "merging" || p == "conflicts" {
                return .failure(.bad("a merge is already under way"))
            }
            s.branchMerge = BranchMerge(target: (body["into"] as? String) ?? s.branchParent ?? "main",
                                        squash: body["squash"] as? Bool ?? false, removeAfter: true,
                                        startedAt: Date(), phase: "requested",
                                        askedBy: (body["askedBy"] as? String).flatMap(UUID.init(uuidString:)))
        case "branch-merge":
            guard s.worktreeBranch != nil else { return .failure(.bad("not a branch session")) }
            let into = (body["into"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? s.branchMerge?.target ?? s.branchParent ?? "main"
            s.branchMerge = BranchMerge(target: into, squash: body["squash"] as? Bool ?? false,
                                        removeAfter: body["removeAfter"] as? Bool ?? true,
                                        startedAt: Date(), phase: "merging", askedBy: s.branchMerge?.askedBy)
            let snapshot = s
            DispatchQueue.global().async { self.merge(snapshot) }
        case "branch-decline":
            guard let m = s.branchMerge, m.phase == "requested" else { return .success(["ok": true]) }
            s.branchMerge = nil
            let asker = m.askedBy.flatMap { self.session($0) } ?? s
            let msg = "The user declined merging '\(s.worktreeBranch ?? "")' into '\(m.target)' for now. Don't ask again unless they bring it up."
            DispatchQueue.global().async { _ = self.command(asker.id, "resume", ["message": msg]) }
        case "branch-pr":
            guard let branch = s.worktreeBranch else { return .failure(.bad("not a branch session")) }
            let into = (body["into"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? s.branchParent ?? "main"
            let msg = Worktrees.pullRequestPrompt(branch: branch, into: into)
            DispatchQueue.global().async { _ = self.command(id, "resume", ["message": msg]) }
        case "branch-discard":
            // The checkout, the branch and the session.
            guard let branch = s.worktreeBranch else { return .failure(.bad("not a branch session")) }
            if let live { Tmux.killWindow(live) }
            if let root = s.branchRoot { DispatchQueue.global().async { Worktrees.remove(root: root, branch: branch) } }
            s.windowIndex = nil
            s.deletedAt = Date()
        case "branch-keep":
            // Nothing reopens branches at boot here: keeping is the default.
            return .success(["ok": true])
        case "review":
            // The review window's comments (Bromure AC's verbs): add / remove /
            // viewed, and send — the drafts go to the agent as one message.
            switch body["op"] as? String {
            case "add":
                let text = ((body["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return .failure(.bad("text required")) }
                s.reviewComments = (s.reviewComments ?? []) + [ReviewComment(
                    id: UUID(), text: text, file: body["file"] as? String, line: body["line"] as? Int,
                    createdAt: Date(), sentAt: nil)]
            case "remove":
                guard let cid = (body["comment"] as? String).flatMap(UUID.init(uuidString:)) else {
                    return .failure(.bad("comment required"))
                }
                s.reviewComments?.removeAll { $0.id == cid }
                if s.reviewComments?.isEmpty == true { s.reviewComments = nil }
            case "viewed":
                guard let path = body["path"] as? String else { return .failure(.bad("path required")) }
                var v = s.reviewViewed ?? [:]
                v[path] = body["fingerprint"] as? String
                s.reviewViewed = v.isEmpty ? nil : v
            case "send":
                let drafts = (s.reviewComments ?? []).filter { $0.sentAt == nil }
                guard !drafts.isEmpty else { return .success(["ok": true, "sent": 0]) }
                let now = Date(), ids = Set(drafts.map(\.id))
                s.reviewComments = s.reviewComments?.map { c in
                    var c = c
                    if ids.contains(c.id) { c.sentAt = now }
                    return c
                }
                let message = Self.reviewMessage(drafts)
                let saved = s
                queue.sync {
                    if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i] = saved }
                    saveLocked()
                }
                notify()
                DispatchQueue.global().async { _ = self.command(id, "resume", ["message": message]) }
                return .success(["ok": true, "sent": drafts.count])
            default:
                return .failure(.bad("op must be add, remove, viewed or send"))
            }
        case "delegation-link":
            s.parentSessionID = (body["parentSessionID"] as? String).flatMap(UUID.init(uuidString:))
            s.delegationID = (body["delegationID"] as? String).flatMap(UUID.init(uuidString:))
        case "nickname":
            let n = ((body["nickname"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            s.nickname = n.isEmpty ? nil : n
        default:
            return .failure(.notSupported("\(action) isn't available on a native machine"))
        }
        let updated = s
        queue.sync {
            if let i = sessions.firstIndex(where: { $0.id == id }) { sessions[i] = updated }
            saveLocked()
            lastRefresh = .distantPast
        }
        notify()
        return .success(["ok": true])
    }

    /// The session's transcript (Claude's JSONL): the path its hook reported,
    /// else the newest one in the folder's project directory.
    func transcript(_ id: UUID) -> Data? {
        guard let s = session(id) else { return nil }
        let fm = FileManager.default
        var path = s.transcriptPath
        if path == nil || !fm.fileExists(atPath: path!) {
            let enc = String(s.cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
            let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects/\(enc)")
            if let id = s.agentTranscriptID, fm.fileExists(atPath: dir.appendingPathComponent("\(id).jsonl").path) {
                path = dir.appendingPathComponent("\(id).jsonl").path
            } else {
                let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]))?
                    .filter { $0.pathExtension == "jsonl" } ?? []
                path = files.max {
                    let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return a < b
                }?.path
            }
        }
        guard let path, let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        // The tail, like bromure-ac's host-held history (24 MB).
        let cap: UInt64 = 24 << 20
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > cap ? size - cap : 0)
        return try? h.readToEnd()
    }

    // MARK: Branches

    /// A session on a new branch of `parent`'s folder (Worktrees.make), its
    /// agent started there with `message`.
    func startWorktree(from parent: HostSession, name: String, tool: String, message: String?,
                       initGit: Bool, base: String?) -> Result<(id: UUID, window: Int), HostError> {
        guard Self.tools.contains(tool) else { return .failure(.bad("unknown agent \(tool)")) }
        let made: Worktrees.Made
        switch Worktrees.make(from: parent.cwd, name: name, initGit: initGit, base: base, tool: tool) {
        case .success(let m): made = m
        case .failure(let e): return .failure(e)
        }
        let id = UUID()
        let msg = message.flatMap { $0.isEmpty ? nil : $0 }
        let inner = Self.launchCommand(tool: tool, message: msg, resume: nil, cloneURL: nil)
        guard let idx = Tmux.newWindow(cwd: made.dir, name: tool, command: Self.wrap(inner), options: [
            "@display": name, "@bromure_session": id.uuidString,
            "@worktree": made.branch, "@parent_branch": made.parent, "@root_repo": made.root,
        ]) else { return .failure(.failed("Couldn't open a tmux window")) }
        var s = HostSession(id: id, profileID: hostID, tool: tool, title: name, cwd: made.dir, createdAt: Date())
        s.openingMessage = msg
        s.windowIndex = idx
        s.launchingSince = Date()
        s.launchDisplay = name
        s.userTitled = true
        s.worktreeOf = parent.id
        s.worktreeBranch = made.branch
        s.branchParent = made.parent
        s.branchRoot = made.root
        queue.sync {
            sessions.append(s)
            saveLocked()
            lastRefresh = .distantPast
        }
        notify()
        AgentHostLog.log("sessions: branch \(made.branch) of “\(parent.title)” → window \(idx)")
        return .success((id, idx))
    }

    /// The Branches window's "Open in a session": an agent in a branch's
    /// checkout nobody looks after, known as that branch.
    func openBranch(dir: String, branch: String, parent: String, root: String, display: String,
                    tool: String) -> Result<(id: UUID, window: Int), HostError> {
        guard dir.hasPrefix(NSHomeDirectory() + "/.bromure/worktrees/") else { return .failure(.bad("Not a Bromure worktree")) }
        let r = start(.init(tool: tool, cwd: dir))
        guard case .success(let made) = r else { return r }
        for (k, v) in ["@worktree": branch, "@parent_branch": parent, "@root_repo": root,
                       "@display": display.isEmpty ? branch : display] where !v.isEmpty {
            Tmux.setWindowOption(made.window, k, v)
        }
        update(made.id) {
            $0.title = display.isEmpty ? branch : display
            $0.userTitled = true
            $0.worktreeBranch = branch
            $0.branchParent = parent.isEmpty ? nil : parent
            $0.branchRoot = root.isEmpty ? nil : root
        }
        return r
    }

    /// The Branches window's "Discard": with its session, or just the
    /// checkout and the branch.
    func discardWorktree(root: String, branch: String, session: UUID?) {
        if let session, self.session(session)?.worktreeBranch == branch {
            _ = command(session, "branch-discard", [:])
            return
        }
        guard !root.isEmpty, branch.hasPrefix("wt/") else { return }
        Worktrees.remove(root: root, branch: branch)
        AgentHostLog.log("sessions: discarded left-behind \(branch)")
    }

    private func update(_ id: UUID, _ change: (inout HostSession) -> Void) {
        queue.sync {
            guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
            let before = sessions[i]
            change(&sessions[i])
            if sessions[i] != before { saveLocked() }
        }
        notify()
    }

    /// The merge the user asked for: on its own when the branch is clean,
    /// else the session's agent finishes it (watched by the branch loop).
    private func merge(_ s: HostSession) {
        guard let branch = s.worktreeBranch, let root = s.branchRoot, let m = s.branchMerge else { return }
        let outcome = Worktrees.tryMerge(root: root, branch: branch, into: m.target, source: s.cwd, squash: m.squash)
        AgentHostLog.log("sessions: merge \(branch) → \(m.target): \(outcome)")
        if outcome == .merged { landed(s.id); return }
        update(s.id) { $0.branchMerge?.phase = "conflicts" }
        _ = command(s.id, "resume", ["message": Worktrees.mergePrompt(branch: branch, into: m.target,
                                                                      squash: m.squash, why: outcome)])
    }

    /// The branch is in: tell whoever asked, and tidy up as asked.
    private func landed(_ id: UUID) {
        guard let s = session(id), let m = s.branchMerge else { return }
        update(id) { $0.branchMerge?.phase = "merged"; $0.branchInfo = nil }
        if let asker = m.askedBy, asker != id, session(asker) != nil {
            _ = command(asker, "resume", ["message": "'\(s.worktreeBranch ?? "")' (session “\(s.title)”) is merged into '\(m.target)'."])
        }
        guard m.removeAfter, let branch = s.worktreeBranch, let root = s.branchRoot else { return }
        if let w = s.windowIndex { Tmux.killWindow(w) }
        Worktrees.remove(root: root, branch: branch)
        update(id) {
            $0.windowIndex = nil
            $0.agentAlive = false
            $0.folderMissing = true
            if $0.endedAt == nil { $0.endedAt = Date() }
            $0.archivedAt = Date()
        }
    }

    /// Every few seconds: merges finishing; every 20 s: each open branch's
    /// ahead / behind / uncommitted counts.
    func startBranchLoop() {
        Thread.detachNewThread { [weak self] in
            var tick = 0
            while let self {
                Thread.sleep(forTimeInterval: 5)
                tick += 1
                let all = self.queue.sync { self.sessions }
                for s in all {
                    guard let branch = s.worktreeBranch, let root = s.branchRoot, s.deletedAt == nil else { continue }
                    if let m = s.branchMerge, m.phase == "merging" || m.phase == "conflicts" {
                        if Worktrees.landed(root: root, branch: branch, target: m.target, squash: m.squash) {
                            self.landed(s.id)
                        } else if Date().timeIntervalSince(m.startedAt) > 30 * 60 {
                            self.update(s.id) {
                                $0.branchMerge?.phase = "failed"
                                $0.branchMerge?.detail = "The merge hasn't landed after 30 minutes — ask the agent where it stands."
                            }
                        }
                        continue
                    }
                    guard tick % 4 == 0, s.branchMerge?.phase != "merged", s.folderMissing != true else { continue }
                    if let p = Worktrees.probe(dir: s.cwd, parent: s.branchParent),
                       let data = try? JSONSerialization.data(withJSONObject: p.info) {
                        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
                        let info = try? dec.decode(BranchInfo.self, from: data)
                        self.update(s.id) {
                            let changed = $0.branchInfo.map { o in
                                o.ahead != info?.ahead || o.behind != info?.behind || o.changed != info?.changed } ?? true
                            if changed { $0.branchInfo = info }
                            if $0.branchRoot == nil { $0.branchRoot = p.root }
                            if $0.branchParent == nil { $0.branchParent = p.parent }
                        }
                    } else if !FileManager.default.fileExists(atPath: s.cwd) {
                        self.update(s.id) { $0.folderMissing = true }
                    }
                }
            }
        }
    }

    /// Bromure AC's AgentSessionEngine.reviewMessage, word for word.
    static func reviewMessage(_ comments: [ReviewComment]) -> String {
        var lines = [comments.count == 1
            ? "A review comment on your changes — address it, then reply briefly with what you changed:"
            : "Review comments on your changes — address each one, then reply briefly with what you changed:"]
        lines.append("")
        for (i, c) in comments.enumerated() {
            let at: String
            switch (c.file, c.line) {
            case let (f?, l?): at = "`\(f)` line \(l): "
            case let (f?, nil): at = "`\(f)`: "
            default: at = ""
            }
            lines.append("\(i + 1). \(at)\(c.text)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Launch commands

    /// The agent's command line. Claude gets our hooks through `--settings`
    /// (merged over the user's own settings — theirs are never touched).
    static func launchCommand(tool: String, message: String?, resume: String?, cloneURL: String?,
                              extraArgs: [String] = []) -> String {
        var cmd: String
        switch tool {
        case "claude":
            cmd = "claude --settings \(shellQuote(AgentHostPaths.claudeSettings.path))"
                // `=` form: the flag takes several values and would swallow
                // the prompt that follows as another config file.
                + " " + shellQuote("--mcp-config=" + AgentHostPaths.claudeMCPConfig.path)
            if let resume { cmd += resume.isEmpty ? " --continue" : " --resume \(shellQuote(resume))" }
        case "codex":
            cmd = resume == nil ? "codex" : (resume!.isEmpty ? "codex resume --last" : "codex resume \(shellQuote(resume!))")
        default:
            cmd = tool
        }
        for a in extraArgs { cmd += " \(shellQuote(a))" }
        if let message { cmd += " \(shellQuote(HostExec.mapHome(message)))" }
        if let cloneURL {
            let folder = ((cloneURL as NSString).lastPathComponent as NSString).deletingPathExtension
            cmd = "git clone \(shellQuote(cloneURL)) && cd \(shellQuote(folder)) && \(cmd)"
        }
        return cmd
    }

    /// Run `inner` under the user's interactive login shell (their PATH,
    /// nvm, …), leaving a shell in the tab when the agent exits.
    static func wrap(_ inner: String) -> String {
        let sh = Tmux.userShell
        return "exec \(shellQuote(sh)) -l -i -c \(shellQuote(inner + "; exec \(shellQuote(sh)) -l"))"
    }

    static func title(for message: String, tool: String, cwd: String) -> String {
        let first = message.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !first.isEmpty else { return defaultTitle(tool: tool, cwd: cwd) }
        return first.count > 60 ? String(first.prefix(57)) + "…" : first
    }

    static func expand(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.isEmpty || path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        if path.hasPrefix("/home/ubuntu") { return home + String(path.dropFirst("/home/ubuntu".count)) }
        if path.hasPrefix("/") { return path }
        return home + "/" + path
    }

    /// Files dropped on a client's new-session screen ({name, data, folder?}),
    /// written to ~/.bromure/drops; their paths.
    static func stage(_ attachments: [[String: Any]]) -> [String] {
        guard !attachments.isEmpty else { return [] }
        let fm = FileManager.default
        try? fm.createDirectory(at: AgentHostPaths.dropsDir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        var paths: [String] = []
        for (i, a) in attachments.enumerated() {
            guard let name = (a["name"] as? String).map({ ($0 as NSString).lastPathComponent }),
                  !name.isEmpty, let b64 = a["data"] as? String, let data = Data(base64Encoded: b64)
            else { continue }
            let dest = AgentHostPaths.dropsDir.appendingPathComponent("\(stamp)_\(i)_\(name)")
            if a["folder"] as? Bool == true {
                let tar = dest.appendingPathExtension("tar")
                guard (try? data.write(to: tar)) != nil else { continue }
                try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
                _ = HostProcess.run(executable: "/usr/bin/tar", args: ["-xf", tar.path, "-C", dest.path],
                                    env: ["PATH": "/usr/bin:/bin"], timeout: 60)
                try? fm.removeItem(at: tar)
            } else {
                guard (try? data.write(to: dest)) != nil else { continue }
            }
            paths.append(dest.path)
        }
        return paths
    }

    // MARK: Persistence

    private func saveLocked() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(sessions) {
            try? data.write(to: AgentHostPaths.sessionsFile, options: .atomic)
        }
    }

    private func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: Self.didChange, object: nil) }
    }
}

enum HostError: Error {
    case bad(String), notFound(String), failed(String), notSupported(String)
    var status: Int {
        switch self {
        case .bad: return 400
        case .notFound: return 404
        case .failed: return 500
        case .notSupported: return 501
        }
    }
    var message: String {
        switch self {
        case .bad(let m), .notFound(let m), .failed(let m), .notSupported(let m): return m
        }
    }
}
