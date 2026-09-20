import Foundation
import Observation
import SwiftUI

// MARK: - Agent sessions (the unit the home screen is built around)
//
// A session is one conversation with a coding agent: an agent (Claude Code,
// Codex, …) running in a folder of a workspace. Underneath it is a tmux
// window in that workspace's VM — the machinery the home screen hides. This
// file is platform-neutral: the model, the store that remembers sessions
// across launches and reconciles them with the live tab rosters, the
// grouping the sidebar shows, and the shared row/section views. The macOS
// engine that starts/resumes sessions lives in AgentSessionEngine.swift.

/// What the new-session screen hands to whoever starts sessions: the local
/// engine on macOS, the mirror controller (→ the server's engine) on a
/// fat client.
struct AgentSessionRequest {
    var profileID: UUID
    var tool: Profile.Tool
    /// Guest folder ("~" = home). With `cloneURL`, the clone target.
    var cwd: String = "~"
    var cloneURL: String? = nil
    var openingMessage: String? = nil
    /// Optional explicit name; else derived from the message / folder.
    var title: String? = nil
}

struct AgentSession: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var profileID: UUID
    var tool: Profile.Tool
    /// What the user calls it: the opening message's first line, the name
    /// the agent gave its session, or "<Agent> in <folder>".
    var title: String
    /// Guest path the agent runs in ("~" conventions).
    var cwd: String
    var cloneURL: String?
    var openingMessage: String?
    var createdAt: Date
    /// tmux window index of the live tab; nil once the tab is gone.
    var windowIndex: Int?
    /// Set while a start/resume is in flight (boot, clone, tab creation),
    /// with the highest window index seen at launch so the new tab can be
    /// told apart from the ones already there.
    var launchingSince: Date?
    var launchBaselineIndex: Int?
    var endedAt: Date?
    var lastSeenAt: Date?
    var lastError: String?
    /// When an agent was last seen RUNNING in the tab. A tab that is a bare
    /// shell only counts as "the agent exited" once it has run here before
    /// — while the tool is still installing/starting it's just starting.
    var agentSeenAt: Date?
    /// Latest liveness probe of the tab's tty (an agent process is in the
    /// foreground group). Authoritative over the roster label, which reads
    /// "bash" for agents that run under an interpreter (omp under bun).
    var agentAlive: Bool?
    /// When the session was last resumed — restarts the starting grace.
    var resumedAt: Date?
    /// The opening message has been echoed into the live chat once.
    var openingShown: Bool?
    /// The user named this session by hand — the agent's own title never
    /// overrides it.
    var userTitled: Bool?
    /// The name the tab was given when WE opened it (`@display`). A tab at
    /// the same index carrying another name is somebody else's — the
    /// machine rebooted and the indices started over.
    var launchDisplay: String?
    /// A probe found the folder gone from the machine: the session can be
    /// read and forgotten, nothing else.
    var folderMissing: Bool?
    /// The agent is sitting at its sign-in screen (the beautified view saw
    /// it) — surfaced as "needs you" until the host signs in for it.
    var needsSignIn: Bool?
    /// The user put the conversation away: it leaves the session list for
    /// the Archived fold, still readable, and comes back the moment it is
    /// resumed. Archiving ends the agent (a running one, or one found
    /// running later).
    var archivedAt: Date?
    /// The user deleted it. Hidden everywhere at once; the record itself
    /// stays until its tab is gone from the roster (killed now, or when
    /// the machine wakes), so the dying tab isn't adopted as a stranger.
    var deletedAt: Date?
    /// Started as a git worktree off another session's folder. `cwd` is
    /// that folder until the tab binds — the guest picks the worktree's
    /// path and branch (unique suffixes and all), and the binder takes
    /// both from the tab.
    var worktreeOf: UUID?
    /// The worktree's branch ("wt/<slug>"), once the tab reported it.
    var worktreeBranch: String?
    /// Changes were noticed in the session's folder during this run of it:
    /// uncommitted work git reports when the folder is in a repository,
    /// else a file written since the session began. Set when first
    /// noticed, cleared once the folder reads clean again (a commit) and
    /// on a resume — the Files pane pops up for each batch.
    var changesSeenAt: Date?
    /// Started by another session's agent as its delegate (see
    /// AgentDelegation.swift): listed under that session, and the
    /// delegation the two share.
    var parentSessionID: UUID?
    var delegationID: UUID?
    /// The name agents and the composer reach this session by ("@nick"):
    /// set by the user, unique on this host, stored without the "@".
    var nickname: String?
    /// The agent's own id for this conversation (Claude: the transcript
    /// file's name), as its hook reported it while it ran — what a resume
    /// targets, so two agents in one folder never pick up each other's.
    var agentTranscriptID: String?

    init(id: UUID = UUID(), profileID: UUID, tool: Profile.Tool, title: String,
         cwd: String = "~", cloneURL: String? = nil, openingMessage: String? = nil,
         createdAt: Date = Date(), windowIndex: Int? = nil) {
        self.id = id
        self.profileID = profileID
        self.tool = tool
        self.title = title
        self.cwd = cwd
        self.cloneURL = cloneURL
        self.openingMessage = openingMessage
        self.createdAt = createdAt
        self.windowIndex = windowIndex
    }

    var isLaunching: Bool { launchingSince != nil }
    var hasEnded: Bool { endedAt != nil && windowIndex == nil }
    var isArchived: Bool { archivedAt != nil }
    var isDeleted: Bool { deletedAt != nil }
    /// A session the store made from a tab it found (no launch of ours, no
    /// words of the user's): the kind that can be twinned by a bad roster,
    /// and dropped again without losing anything.
    var isPlainAdoptee: Bool {
        launchDisplay == nil && openingMessage == nil && cloneURL == nil && userTitled != true
    }

    /// "Fix the login redirect loop" from a multi-line opening message.
    static func title(fromMessage text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        let clean = first.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        if clean.count <= 72 { return clean }
        var cut = String(clean.prefix(72))
        if let sp = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: sp) > 30 {
            cut = String(cut[..<sp])
        }
        return cut.trimmingCharacters(in: .punctuationCharacters) + "…"
    }

    /// "Claude Code in clock" — for sessions nobody named.
    static func defaultTitle(tool: Profile.Tool, cwd: String) -> String {
        let folder = (cwd as NSString).lastPathComponent
        if folder.isEmpty || folder == "~" || cwd == "/home/ubuntu" {
            return String(format: NSLocalizedString("%@ session", comment: "session title"), tool.displayName)
        }
        return String(format: NSLocalizedString("%@ in %@", comment: "session title"), tool.displayName, folder)
    }
}

// MARK: - Store

/// Sessions the user has (or had): persisted so the list survives an app
/// restart, reconciled every couple of seconds against the workspaces' live
/// tab rosters, and completed with agent tabs that were started some other
/// way (the terminal, a kanban run).
@MainActor
@Observable
final class AgentSessionStore {
    private(set) var sessions: [AgentSession] = []
    private let fileURL: URL
    /// Sessions whose tab was never found are given up after this long.
    static let launchTimeout: TimeInterval = 180

    /// A mirror holds another instance's sessions (a fat client's view of
    /// the server's): fed by `applyMirror`, never read from or written to disk.
    private let isMirror: Bool

    init(fileURL: URL? = nil) {
        isMirror = false
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.fileURL = appSupport
                .appendingPathComponent("BromureAC", isDirectory: true)
                .appendingPathComponent("sessions.json")
        }
        load()
    }

    init(mirror: Bool) {
        isMirror = mirror
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("sessions-mirror.json")
    }

    /// Replace the whole list with the server's (a fat client's poll). Twins
    /// an older server may still carry (see `twins(in:)`) are left out of
    /// the mirror — the server's own copy is its business.
    func applyMirror(_ list: [AgentSession]) {
        let drop = Self.twins(in: list).drop
        let list = drop.isEmpty ? list : list.filter { !drop.contains($0.id) }
        guard list != sessions else { return }
        sessions = list
    }

    func session(_ id: UUID) -> AgentSession? { sessions.first { $0.id == id } }

    func upsert(_ s: AgentSession) {
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s }
        else { sessions.insert(s, at: 0) }
        save()
    }

    func mutate(_ id: UUID, _ change: (inout AgentSession) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[i])
        save()
    }

    func remove(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        onRemove?(id)
        save()
    }

    /// Told whenever a session leaves the store (a forget, a dropped twin),
    /// so what hangs off it elsewhere — its transcript copy — goes too.
    var onRemove: ((UUID) -> Void)?

    /// Put a session away (or take it back out). Archiving is a flag: the
    /// engine ends the agent, the list moves the row to the Archived fold.
    func setArchived(_ id: UUID, _ archived: Bool, now: Date = Date()) {
        guard let i = sessions.firstIndex(where: { $0.id == id }),
              sessions[i].isArchived != archived else { return }
        sessions[i].archivedAt = archived ? now : nil
        save()
    }

    /// Give a session the name agents and the composer reach it by
    /// ("@nick"); nil or nothing usable clears it. Refuses a name another
    /// session holds — the reason, else nil.
    @discardableResult
    func setNickname(_ id: UUID, _ raw: String?) -> String? {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else {
            return NSLocalizedString("Unknown session.", comment: "nickname")
        }
        guard let raw, let nick = DelegationNotice.normalizeNickname(raw) else {
            sessions[i].nickname = nil
            save()
            return nil
        }
        if let other = sessions.first(where: {
            $0.id != id && !$0.isDeleted && $0.nickname?.lowercased() == nick.lowercased()
        }) {
            return String(format: NSLocalizedString("@%@ is already “%@”.", comment: "nickname"), nick, other.title)
        }
        sessions[i].nickname = nick
        save()
        return nil
    }

    /// The conversation id the agent's hook reported for this session.
    func setTranscriptID(_ id: UUID, _ tid: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }), sessions[i].agentTranscriptID != tid else { return }
        sessions[i].agentTranscriptID = tid
        save()
    }

    /// The session called "@nick", if any (case-insensitive).
    func session(nickname: String) -> AgentSession? {
        guard let nick = DelegationNotice.normalizeNickname(nickname)?.lowercased() else { return nil }
        return sessions.first { !$0.isDeleted && $0.nickname?.lowercased() == nick }
    }

    /// Mark a session deleted: gone from every list now, purged once its
    /// tab is (see `purgeDeleted`).
    func setDeleted(_ id: UUID, now: Date = Date()) {
        guard let i = sessions.firstIndex(where: { $0.id == id }), !sessions[i].isDeleted else { return }
        sessions[i].deletedAt = now
        save()
    }

    /// Deleted sessions whose tab is gone (or never came) leave the store.
    @discardableResult
    private func purgeDeleted() -> Bool {
        let gone = sessions.filter { $0.isDeleted && $0.windowIndex == nil && $0.launchingSince == nil }
        guard !gone.isEmpty else { return false }
        sessions.removeAll { s in gone.contains { $0.id == s.id } }
        for s in gone { onRemove?(s.id) }
        return true
    }

    /// Record a liveness probe result. In memory every tick; persisted only
    /// when the verdict flips, so the poll doesn't rewrite the file every
    /// few seconds.
    func setLiveness(_ id: UUID, alive: Bool, now: Date = Date()) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        if alive {
            deadSince[id] = nil
        } else {
            // Two strikes: one probe that finds nothing (a busy guest, a
            // truncated ps) must not flip a live chat into "Ended" and back.
            let first = deadSince[id] ?? now
            deadSince[id] = first
            if now.timeIntervalSince(first) < Self.deadGrace, sessions[i].agentAlive != false { return }
        }
        let changed = sessions[i].agentAlive != alive
        sessions[i].agentAlive = alive
        if alive { sessions[i].agentSeenAt = now }
        if changed { save() }
    }

    /// How long a probe has to keep finding no agent before the verdict is
    /// "exited"; and how long a tab may be missing from the roster before
    /// the session is "ended" (a roster still loading shows nothing at all).
    static let deadGrace: TimeInterval = 6
    static let missingGrace: TimeInterval = 8
    private var deadSince: [UUID: Date] = [:]
    private var missingSince: [UUID: Date] = [:]

    /// The session bound to a workspace's tmux window, if any.
    func session(profileID: UUID, windowIndex: Int) -> AgentSession? {
        sessions.first { $0.profileID == profileID && $0.windowIndex == windowIndex }
    }

    /// Bring the store in line with what the workspaces actually show:
    /// bind a launching session to its new tab, mark sessions whose tab went
    /// away as ended, adopt agent tabs nobody registered, refresh titles.
    /// Only ATTACHED workspaces (with a live roster) are judged — a
    /// suspended workspace's sessions are asleep, not gone.
    func reconcile(entries: [SessionListModel.VMEntry], now: Date = Date()) {
        var changed = false
        for entry in entries {
            let tabs = entry.model.tabs
            // A running workspace always has its shell window: an empty
            // roster is one that hasn't loaded yet (right after a launch or
            // a reattach) — judging it would end every session it hosts.
            // Likewise the pills a resume paints from its suspend snapshot
            // (labels only, all at index 0) and a fresh boot's placeholder:
            // adopting those once made a session at window 0 out of EVERY
            // saved pill. Only the guest's own roster counts.
            guard !tabs.isEmpty, entry.model.rosterLive else { continue }
            let indices = Set(tabs.map(\.index))
            // 0. Stale bindings: after a reboot the window indices start over,
            // so a session's index may now be another tab (one we opened
            // under a different name). Unbind first, so the launch waiting
            // for that very tab can claim it below.
            for i in sessions.indices where sessions[i].profileID == entry.id {
                let s = sessions[i]
                guard let w = s.windowIndex, let tab = tabs.first(where: { $0.index == w }) else { continue }
                var stale = false
                if let mine = s.launchDisplay, let d = tab.display, !d.isEmpty, d != mine { stale = true }
                // No launch name to compare (an adopted or older session): a
                // tab that works in another folder isn't this session's.
                // The home itself is exempt — an agent started there may
                // move to a scratch folder of its own.
                let home = SessionHome.guestPath("~")
                let mineCwd = SessionHome.guestPath(s.cwd)
                if !stale, s.launchDisplay == nil, mineCwd != home,
                   let tc = tab.cwd, !tc.isEmpty, SessionHome.guestPath(tc) != mineCwd {
                    stale = true
                }
                guard stale else { continue }
                sessions[i].windowIndex = nil
                sessions[i].endedAt = now
                sessions[i].agentAlive = nil
                changed = true
            }
            // 1. Sessions of this workspace with a tab: still there?
            for i in sessions.indices where sessions[i].profileID == entry.id {
                var s = sessions[i]
                if let w = s.windowIndex {
                    if indices.contains(w) {
                        missingSince[s.id] = nil
                        if s.endedAt != nil { s.endedAt = nil }
                        s.lastSeenAt = now
                        if let tab = tabs.first(where: { $0.index == w }) {
                            if Self.agentRunning(s, in: tab) { s.agentSeenAt = now }
                            if s.userTitled != true, let raw = Self.agentTitle(from: tab),
                               let better = SessionHome.cleanAgentTitle(raw, agent: s.tool.rawValue, cwd: s.cwd),
                               better != s.title {
                                s.title = better   // the agent named its session
                            }
                        }
                    } else {
                        // Gone for good, or a roster that's mid-refresh? Give
                        // it a moment before calling the session ended.
                        let first = missingSince[s.id] ?? now
                        missingSince[s.id] = first
                        if now.timeIntervalSince(first) >= Self.missingGrace {
                            missingSince[s.id] = nil
                            s.windowIndex = nil
                            s.endedAt = now
                        }
                    }
                } else if s.launchingSince != nil, let baseline = s.launchBaselineIndex {
                    // 2. A launch waiting for its tab — only once the tab
                    // command is out (the baseline is set then; before that
                    // the workspace's own shell would be mistaken for it):
                    // the new tab carrying the session's name, else the
                    // first new agent tab past the baseline nobody owns.
                    // Window indices are per machine: another workspace's
                    // session on index 1 says nothing about this one's tab 1.
                    let bound = Set(sessions.filter { $0.profileID == entry.id }.compactMap { $0.windowIndex })
                    let candidates = tabs.filter { t in
                        t.index > baseline && !bound.contains(t.index) && t.containerID == nil
                    }
                    if let tab = candidates.first(where: { $0.display == s.title })
                        ?? candidates.first(where: {
                            BromureIcons.agentKind(forLabel: $0.shownLabel) == s.tool.rawValue })
                        ?? candidates.first {
                        s.windowIndex = tab.index
                        s.launchingSince = nil
                        s.launchBaselineIndex = nil
                        s.endedAt = nil
                        s.lastError = nil
                        s.lastSeenAt = now
                        // A worktree session: the guest chose the folder
                        // and the branch — the tab knows both.
                        if s.worktreeOf != nil {
                            if let c = tab.cwd, !c.isEmpty { s.cwd = c }
                            if let b = tab.worktreeBranch, !b.isEmpty { s.worktreeBranch = b }
                        }
                    } else if let since = s.launchingSince,
                              now.timeIntervalSince(since) > Self.launchTimeout {
                        s.launchingSince = nil
                        s.lastError = NSLocalizedString(
                            "The agent never showed up. The workspace may run an older in-VM agent — restart it (Virtual Machines › ⋯ › Restart) and try again.",
                            comment: "session launch")
                    }
                }
                if s != sessions[i] { sessions[i] = s; changed = true }
            }
            // 3. Agent tabs nobody registered (started from a terminal, a
            // kanban run, an automation): they're sessions too — unless the
            // tab is a session of ours that lost its binding (a roster
            // hiccup, a relaunch): that one gets its tab back, no twin.
            let bound = Set(sessions.filter { $0.profileID == entry.id }.compactMap { $0.windowIndex })
            for tab in tabs where !bound.contains(tab.index) && tab.containerID == nil {
                guard let kind = BromureIcons.agentKind(forLabel: tab.label)
                        ?? BromureIcons.agentKind(forLabel: tab.shownLabel),
                      let tool = Profile.Tool(rawValue: kind) else { continue }
                let cwd = tab.cwd ?? "~"
                // The agent's own name for it, minus its glyphs ("π > tmp"
                // is not a title) — else the plain "<Agent> in <folder>".
                let title = Self.agentTitle(from: tab)
                    .flatMap { SessionHome.cleanAgentTitle($0, agent: kind, cwd: cwd) }
                    ?? AgentSession.defaultTitle(tool: tool, cwd: cwd)
                let guestCwd = SessionHome.guestPath(cwd)
                if let i = sessions.firstIndex(where: { cand in
                    guard cand.profileID == entry.id, cand.windowIndex == nil,
                          cand.launchingSince == nil, cand.tool == tool else { return false }
                    // The tab still carries the name we opened it under…
                    if let d = tab.display, !d.isEmpty, d == cand.launchDisplay { return true }
                    // …or it reads exactly like the session, in the same folder.
                    return cand.title == title && SessionHome.guestPath(cand.cwd) == guestCwd
                }) {
                    sessions[i].windowIndex = tab.index
                    sessions[i].endedAt = nil
                    sessions[i].lastError = nil
                    sessions[i].lastSeenAt = now
                    changed = true
                    continue
                }
                var s = AgentSession(profileID: entry.id, tool: tool, title: title,
                                     cwd: cwd, windowIndex: tab.index)
                s.lastSeenAt = now
                sessions.append(s)
                changed = true
            }
        }
        if dedupeTwins(now: now) { changed = true }
        if purgeDeleted() { changed = true }
        if changed {
            sessions.sort { activity($0) > activity($1) }
            save()
        }
    }

    /// Two sessions on one tmux window: one is a twin. Which one, and what
    /// becomes of it — see `twins(in:)`. True when anything changed.
    @discardableResult
    private func dedupeTwins(now: Date = Date()) -> Bool {
        let (drop, unbind) = Self.twins(in: sessions)
        guard !drop.isEmpty || !unbind.isEmpty else { return false }
        for i in sessions.indices where unbind.contains(sessions[i].id) {
            sessions[i].windowIndex = nil
            sessions[i].endedAt = now
            sessions[i].agentAlive = nil
            sessions[i].launchingSince = nil
        }
        sessions.removeAll { drop.contains($0.id) }
        for id in drop { onRemove?(id) }
        return true
    }

    /// Sessions bound to the same window of the same workspace can't both be
    /// right. The one to keep is the one that carries the most of the user
    /// (a launch of ours, an opening message, a name they gave it), else the
    /// oldest. Of the rest, plain adoptees are dropped — they hold nothing
    /// a tab doesn't (a bad roster once minted six of them for one window);
    /// anything richer is unbound instead, so it shows as Ended and can be
    /// resumed or forgotten by hand.
    static func twins(in list: [AgentSession]) -> (drop: Set<UUID>, unbind: Set<UUID>) {
        var byWindow: [String: [AgentSession]] = [:]
        for s in list {
            guard let w = s.windowIndex else { continue }
            byWindow["\(s.profileID.uuidString)#\(w)", default: []].append(s)
        }
        var drop = Set<UUID>(), unbind = Set<UUID>()
        for group in byWindow.values where group.count > 1 {
            let ranked = group.sorted { a, b in
                let ra = a.isPlainAdoptee ? 0 : 1, rb = b.isPlainAdoptee ? 0 : 1
                if ra != rb { return ra > rb }
                return a.createdAt < b.createdAt
            }
            for s in ranked.dropFirst() {
                if s.isPlainAdoptee { drop.insert(s.id) } else { unbind.insert(s.id) }
            }
        }
        return (drop, unbind)
    }

    /// The name an agent gave its session, as the guest folds it into the
    /// roster label ("<title> (claude)"); nil when the label is just the
    /// program name. (`display` is what WE named the tab — never a source.)
    static func agentTitle(from tab: TabsModel.Tab) -> String? {
        let label = tab.label.trimmingCharacters(in: .whitespaces)
        guard label.hasSuffix(")"), let open = label.lastIndex(of: "(") else { return nil }
        let title = label[..<open].trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    /// The agent named its session (its terminal title, read by the
    /// liveness probe): take it unless the user named the session by hand.
    /// The beautified view's verdict on whether the tab shows a sign-in
    /// screen. Persisted only on change, like liveness.
    func setNeedsSignIn(_ id: UUID, _ needs: Bool) {
        guard let i = sessions.firstIndex(where: { $0.id == id }),
              (sessions[i].needsSignIn == true) != needs else { return }
        sessions[i].needsSignIn = needs ? true : nil
        save()
    }

    func setAgentTitle(_ id: UUID, _ title: String) {
        guard let i = sessions.firstIndex(where: { $0.id == id }),
              sessions[i].userTitled != true, sessions[i].title != title else { return }
        sessions[i].title = title
        save()
    }

    private func activity(_ s: AgentSession) -> Date {
        s.lastSeenAt ?? s.endedAt ?? s.createdAt
    }

    // MARK: Persistence

    private struct FilePayload: Codable { var sessions: [AgentSession] }

    private func load() {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? d.decode(FilePayload.self, from: data) else { return }
        // A launch can't survive a restart; whatever it made is adopted. A
        // liveness verdict is only as fresh as the last probe.
        sessions = payload.sessions.map { s in
            var s = s
            if s.launchingSince != nil { s.launchingSince = nil; s.launchBaselineIndex = nil }
            s.agentAlive = nil
            // A title an earlier build took from the terminal with its
            // glyphs still on ("π ⁘ folder"): clean it, or fall back.
            if s.userTitled != true, s.title.hasPrefix("π") || s.title.hasPrefix("✳") {
                s.title = SessionHome.cleanAgentTitle(s.title, agent: s.tool.rawValue, cwd: s.cwd)
                    ?? s.openingMessage.flatMap { $0.isEmpty ? nil : AgentSession.title(fromMessage: $0) }
                    ?? AgentSession.defaultTitle(tool: s.tool, cwd: s.cwd)
            }
            return s
        }
        // Twins an earlier build left behind go now, before anything shows;
        // so does anything deleted whose tab is gone.
        let tidied = dedupeTwins()
        if purgeDeleted() || tidied { save() }
    }

    /// Is an agent running in the session's tab? The tty probe when we have
    /// one, else the roster label.
    @MainActor
    static func agentRunning(_ s: AgentSession, in tab: TabsModel.Tab) -> Bool {
        s.agentAlive ?? (BromureIcons.agentKind(forLabel: tab.label) != nil)
    }

    private func save() {
        guard !isMirror else { return }
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? e.encode(FilePayload(sessions: sessions)) else { return }
        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        var url = fileURL
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? url.setResourceValues(rv)
    }
}

// MARK: - Grouping

/// Where a session sits in the sidebar, in display order: by what it needs
/// from the user, never by which machine it runs on.
enum SessionBucket: Int, CaseIterable, Identifiable {
    case needsYou, working, idle, asleep, ended
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .needsYou: return NSLocalizedString("Needs you", comment: "session bucket")
        case .working:  return NSLocalizedString("Working", comment: "session bucket")
        case .idle:     return NSLocalizedString("Ready", comment: "session bucket")
        case .asleep:   return NSLocalizedString("Asleep", comment: "session bucket")
        case .ended:    return NSLocalizedString("Ended", comment: "session bucket")
        }
    }

    var tint: Color {
        switch self {
        case .needsYou: return .red
        case .working:  return .orange
        case .idle:     return .green
        case .asleep:   return .secondary
        case .ended:    return .secondary
        }
    }

    var badged: Bool { self == .needsYou }
}

enum SessionHome {
    /// Absolute guest path for a session cwd ("~" conventions), for
    /// comparing a session against a tab's reported cwd. Platform-neutral
    /// twin of the macOS automation engine's helper.
    nonisolated static func guestPath(_ path: String) -> String {
        let home = "/home/ubuntu"
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") { return home + String(trimmed.dropFirst(1)) }
        if trimmed.hasPrefix("/") { return trimmed }
        return home + "/" + trimmed
    }

    /// The session works in a folder of its own (not the bare home) — what
    /// a git worktree can branch off.
    nonisolated static func hasFolder(_ s: AgentSession) -> Bool {
        guestPath(s.cwd) != guestPath("~")
    }

    /// The session's machine was deleted, or its folder is gone from the
    /// machine: it can be read and forgotten, nothing else.
    @MainActor
    static func isGone(_ s: AgentSession, in model: SessionListModel) -> Bool {
        goneReason(s, in: model) != nil
    }

    /// Why a session is gone, for the status line — nil when it isn't.
    @MainActor
    static func goneReason(_ s: AgentSession, in model: SessionListModel) -> String? {
        // No machines known at all (a mirror before its first snapshot) is
        // not the same as this machine being gone.
        if !model.profileRows.isEmpty, !model.profileRows.contains(where: { $0.id == s.profileID }) {
            return NSLocalizedString("Machine removed", comment: "session status")
        }
        if s.folderMissing == true {
            return NSLocalizedString("Folder removed", comment: "session status")
        }
        return nil
    }

    /// Every session in sidebar order: what needs you, then working, ready,
    /// asleep, ended — and the gone ones last. Archived ones live in their
    /// own fold (`archived(_:in:)`).
    @MainActor
    static func orderedAll(_ sessions: [AgentSession], in model: SessionListModel) -> [AgentSession] {
        let sessions = sessions.filter { !$0.isArchived && !$0.isDeleted }
        let groups = grouped(sessions.filter { !isGone($0, in: model) }, in: model)
        let gone = sessions.filter { isGone($0, in: model) }
            .sorted { lastActivity($0) > lastActivity($1) }
        return SessionBucket.allCases.flatMap { groups[$0] ?? [] } + gone
    }

    /// The put-away sessions, most recently archived first.
    static func archived(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.filter { $0.isArchived && !$0.isDeleted }
            .sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    }

    /// An agent is running in the session's tab right now — what makes
    /// ending or deleting it worth a second look.
    @MainActor
    static func isAgentLive(_ s: AgentSession, in model: SessionListModel) -> Bool {
        guard let tab = liveTab(for: s, in: model) else { return false }
        return agentRunning(s, in: tab)
    }

    /// The workspace is attached AND its tab roster is the guest's own (not
    /// a boot placeholder or the pills painted from a suspend snapshot).
    @MainActor
    static func rosterLive(for profileID: UUID, in model: SessionListModel) -> Bool {
        model.entries.first { $0.id == profileID }?.model.rosterLive ?? false
    }

    /// The session's live tab, when its workspace is attached, its roster
    /// is real, and the tab is still there.
    @MainActor
    static func liveTab(for s: AgentSession, in model: SessionListModel) -> TabsModel.Tab? {
        guard let w = s.windowIndex,
              let entry = model.entries.first(where: { $0.id == s.profileID }),
              entry.model.rosterLive else { return nil }
        return entry.model.tabs.first { $0.index == w }
    }

    /// Position of the live tab in its pane's roster (what selectTab wants).
    @MainActor
    static func liveTabPosition(for s: AgentSession, in model: SessionListModel) -> Int? {
        guard let w = s.windowIndex,
              let entry = model.entries.first(where: { $0.id == s.profileID }),
              entry.model.rosterLive else { return nil }
        return entry.model.tabs.firstIndex { $0.index == w }
    }

    /// The tab is there but the agent process is gone (a bare shell): the
    /// conversation can be resumed in place.
    @MainActor
    static func agentExited(_ s: AgentSession, in model: SessionListModel) -> Bool {
        guard let tab = liveTab(for: s, in: model), !agentRunning(s, in: tab) else { return false }
        // Only a probe's verdict ends a session. Before the first probe (the
        // app just launched) the tab's label alone proves nothing — agents
        // under an interpreter read as "bash" — so an idle agent must not
        // flash "Ended" until the probe has had its say.
        guard s.agentAlive == false else { return false }
        // A bare shell where the agent HAS run since the last (re)start: it
        // exited. One where it hasn't run yet is still installing/starting —
        // give it five minutes from the (re)start.
        let started = max(s.createdAt, s.resumedAt ?? .distantPast)
        if let seen = s.agentSeenAt, seen >= started { return true }
        return Date().timeIntervalSince(started) > 300
    }

    /// Is an agent running in the session's tab? The tty probe result when
    /// there is one (authoritative — omp runs under bun and tmux reports the
    /// pane's foreground command as "bash"), else the raw roster label —
    /// never the pretty display name a session tab carries.
    @MainActor
    static func agentRunning(_ s: AgentSession, in tab: TabsModel.Tab) -> Bool {
        AgentSessionStore.agentRunning(s, in: tab)
    }

    @MainActor
    static func workspaceState(of s: AgentSession, in model: SessionListModel) -> SessionListModel.RunState {
        model.profileRows.first { $0.id == s.profileID }?.state ?? .off
    }

    @MainActor
    static func bucket(for s: AgentSession, in model: SessionListModel) -> SessionBucket {
        if isGone(s, in: model) { return .ended }
        if s.isLaunching { return .working }
        if s.needsSignIn == true, !s.hasEnded, liveTab(for: s, in: model) != nil { return .needsYou }
        if s.hasEnded { return .ended }
        let ws = workspaceState(of: s, in: model)
        guard ws == .running || ws == .booting else { return .asleep }
        // Up, but tmux hasn't reported yet (a boot, a resume): still asleep
        // as far as the session can tell — not "Ended" for a few seconds.
        guard rosterLive(for: s.profileID, in: model) else { return .asleep }
        guard let tab = liveTab(for: s, in: model) else {
            // Running workspace, tab not in the roster.
            return .ended
        }
        if !agentRunning(s, in: tab) {
            // A shell: the agent exited (resume) — or hasn't started yet.
            return agentExited(s, in: model) ? .ended : .working
        }
        switch tab.agentStatus {
        case .needsInput: return .needsYou
        case .working:    return .working
        case .done:       return .idle
        }
    }

    @MainActor
    static func dot(for s: AgentSession, in model: SessionListModel) -> AgentStatus? {
        switch bucket(for: s, in: model) {
        case .needsYou: return .needsInput
        case .working:  return .working
        case .idle:     return .done
        case .asleep, .ended: return nil
        }
    }

    /// One line under the title.
    @MainActor
    static func statusLine(for s: AgentSession, in model: SessionListModel, now: Date = Date()) -> String {
        if s.isLaunching {
            switch workspaceState(of: s, in: model) {
            case .off, .suspended: return NSLocalizedString("Waking up…", comment: "session status")
            case .booting:         return NSLocalizedString("Almost there…", comment: "session status")
            case .running:         return NSLocalizedString("Starting…", comment: "session status")
            }
        }
        if let why = goneReason(s, in: model) { return why }
        if let e = s.lastError, !e.isEmpty { return NSLocalizedString("Couldn't start", comment: "session status") }
        // Short, so it fits beside the machine's name in a narrow sidebar.
        switch bucket(for: s, in: model) {
        case .needsYou:
            return s.needsSignIn == true
                ? NSLocalizedString("Sign in needed", comment: "session status")
                : NSLocalizedString("Needs you", comment: "session status")
        case .working:
            if let tab = liveTab(for: s, in: model), !agentRunning(s, in: tab) {
                return NSLocalizedString("Starting…", comment: "session status")
            }
            return NSLocalizedString("Working…", comment: "session status")
        case .idle:
            return NSLocalizedString("Ready", comment: "session status")
        case .asleep:
            // A workspace on its way up (booting, or attached with tmux not
            // yet heard from) is waking, not asleep.
            let ws = workspaceState(of: s, in: model)
            let attached = model.entries.contains { $0.id == s.profileID }
            if ws == .booting || (ws == .running && attached) {
                return NSLocalizedString("Waking up…", comment: "session status")
            }
            return NSLocalizedString("Asleep", comment: "session status")
        case .ended:
            return s.isArchived
                ? NSLocalizedString("Archived", comment: "session status")
                : NSLocalizedString("Ended", comment: "session status")
        }
    }

    static func elapsed(since date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return NSLocalizedString("just now", comment: "elapsed") }
        if s < 3600 { return String(format: NSLocalizedString("%d min", comment: "elapsed"), s / 60) }
        if s < 86400 { return String(format: NSLocalizedString("%d h", comment: "elapsed"), s / 3600) }
        return String(format: NSLocalizedString("%d d", comment: "elapsed"), s / 86400)
    }

    /// An agent's terminal title as a session name, or nil when it isn't
    /// one: Claude Code writes "✳ Fixing the login flow", Oh My Pi "π > Build
    /// the site" (or "π ! …" when it needs you), and both fall back to the
    /// folder or their own name before they have anything to say.
    static func cleanAgentTitle(_ raw: String, agent: String, cwd: String?) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        // Shell defaults: "ubuntu@host: ~/proj", a bare path.
        if t.contains("@") || t.hasPrefix("/") || t.hasPrefix("~") { return nil }
        // Oh My Pi's mark ("π > title", "π ! title", "π ⁘ title") — the pi
        // is a letter, so it goes first, by name.
        t = t.replacingOccurrences(of: #"^[πΠ]\s*"#, with: "", options: .regularExpression)
        // Then every glyph, spinner or status mark before the first letter
        // or digit ("✳ title", "◐ title", "> title", "⁘ title").
        guard let first = t.firstIndex(where: { $0.isLetter || $0.isNumber }) else { return nil }
        t = String(t[first...])
        t = t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let lower = t.lowercased()
        guard !lower.isEmpty else { return nil }
        let agentNames: Set<String> = [agent, "claude code", "codex", "kimi code", "oh my pi", "omp", "bash", "shell", "tmux"]
        if agentNames.contains(lower) { return nil }
        if let cwd, !cwd.isEmpty {
            let folder = (SessionHome.guestPath(cwd) as NSString).lastPathComponent.lowercased()
            if lower == folder { return nil }
        }
        if t.count > 60 { t = String(t.prefix(60)).trimmingCharacters(in: .whitespaces) }
        return t
    }

    /// The sidebar's trailing timestamp: "now", "3m", "2h", "5d".
    static func elapsedCompact(since date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return NSLocalizedString("now", comment: "elapsed compact") }
        if s < 3600 { return String(format: NSLocalizedString("%dm", comment: "elapsed compact"), s / 60) }
        if s < 86400 { return String(format: NSLocalizedString("%dh", comment: "elapsed compact"), s / 3600) }
        return String(format: NSLocalizedString("%dd", comment: "elapsed compact"), s / 86400)
    }

    /// When the session last did something — what the row's timestamp shows.
    static func lastActivity(_ s: AgentSession) -> Date {
        s.lastSeenAt ?? s.endedAt ?? s.resumedAt ?? s.createdAt
    }

    @MainActor
    static func grouped(_ sessions: [AgentSession], in model: SessionListModel) -> [SessionBucket: [AgentSession]] {
        var out: [SessionBucket: [AgentSession]] = [:]
        for s in sessions { out[bucket(for: s, in: model), default: []].append(s) }
        return out
    }

    /// The sidebar's order (ended and archived ones, folded away, excluded)
    /// — what ⌘1–9 count.
    @MainActor
    static func ordered(_ sessions: [AgentSession], in model: SessionListModel) -> [AgentSession] {
        let groups = grouped(sessions.filter { !$0.isArchived && !$0.isDeleted }, in: model)
        return SessionBucket.allCases.filter { $0 != .ended }.flatMap { groups[$0] ?? [] }
    }

    /// The session the home screen opens on: the remembered one if it's
    /// still around, else the most pressing bucket's newest (never one that
    /// was put away).
    @MainActor
    static func initialSession(in store: AgentSessionStore, model: SessionListModel,
                               remembered: UUID?) -> AgentSession? {
        if let id = remembered, let s = store.session(id), !s.hasEnded, !s.isArchived, !s.isDeleted { return s }
        let groups = grouped(store.sessions.filter { !$0.isArchived && !$0.isDeleted }, in: model)
        for b in SessionBucket.allCases {
            if let s = groups[b]?.first { return s }
        }
        return nil
    }
}

// MARK: - Transcript cache

/// A local copy of each session's conversation, refreshed while the agent
/// is alive, so the session reads back with the machine asleep — nothing
/// to boot just to see what was said.
final class SessionTranscriptCache {
    private let dir: URL

    init(directory: URL? = nil) {
        if let directory {
            dir = directory
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask).first!
            dir = appSupport
                .appendingPathComponent("BromureAC", isDirectory: true)
                .appendingPathComponent("transcripts", isDirectory: true)
        }
    }

    private func url(_ id: UUID) -> URL { dir.appendingPathComponent(id.uuidString + ".jsonl") }

    func save(_ id: UUID, _ data: Data) {
        guard !data.isEmpty else { return }
        let u = url(id)
        if let old = try? Data(contentsOf: u), old.count == data.count, old == data { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: u, options: .atomic)
        var v = u
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? v.setResourceValues(rv)
    }

    func load(_ id: UUID) -> Data? { try? Data(contentsOf: url(id)) }

    func remove(_ id: UUID) { try? FileManager.default.removeItem(at: url(id)) }
}

// MARK: - Agent avatar

/// The agent's mark on a tinted rounded square — the same identity everywhere
/// (sidebar rows, session header, pickers). Status dot optional.
struct AgentAvatar: View {
    let tool: Profile.Tool
    var size: CGFloat = 26
    var status: AgentStatus? = nil

    static func tint(for tool: Profile.Tool) -> Color {
        switch tool {
        case .claude: return Color(hex: "#D97757")
        case .codex:  return Color(hex: "#2B2B2E")
        case .grok:   return Color(hex: "#4B5563")
        case .kimi:   return Color(hex: "#4F46E5")
        case .omp:    return Color(hex: "#0E9F6E")
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(Self.tint(for: tool))
                .frame(width: size, height: size)
                .overlay {
                    SVGIcon(name: tool.rawValue, fallbackSymbol: "sparkle", size: size * 0.58)
                        .foregroundStyle(.white)
                }
            if let status {
                AgentStatusDot(status: status)
                    .scaleEffect(size >= 24 ? 1.25 : 1)
                    .offset(x: 2, y: 2)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Row + sections

struct SessionRowView: View {
    let session: AgentSession
    let workspaceName: String
    let accentHex: String
    let dot: AgentStatus?
    let statusLine: String
    /// "3m" — when it last did something; nil while starting.
    var when: String? = nil
    /// Machine or folder gone: dimmed, still readable.
    var gone = false
    /// A delegate: indented under its delegator, this many levels down.
    var depth = 0
    let selected: Bool
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            if depth > 0 {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            AgentAvatar(tool: session.tool, size: 26, status: dot)
                .opacity(session.hasEnded ? 0.55 : 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if let when {
                        Text(when)
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 4) {
                    if let nick = session.nickname, !nick.isEmpty {
                        Text("@" + nick)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                        Text("·").foregroundStyle(.tertiary)
                    }
                    if !workspaceName.isEmpty {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color(hex: accentHex))
                            .frame(width: 6, height: 6)
                        Text(workspaceName)
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(statusLine)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 10 + CGFloat(min(depth, 3)) * 14)
        .padding(.trailing, 8)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(selected ? Color.accentColor.opacity(0.16)
                           : (hovering ? Color.primary.opacity(0.04) : .clear)))
        .overlay(alignment: .leading) {
            if selected {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 3)
                    .padding(.vertical, 9)
            }
        }
        .contentShape(Rectangle())
        .opacity(gone ? 0.5 : 1)
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}

/// The session list: one "Sessions" section holding every session — what
/// needs you first, then working, ready, asleep, ended, and last the ones
/// whose machine or folder is gone — and, under it, an "Archived" fold for
/// the ones put away (closed by default). The carets fold each list away;
/// a search always shows its matches.
struct SessionSectionsView: View {
    var store: AgentSessionStore
    @Bindable var model: SessionListModel
    var filter: String = ""
    let onSelect: (UUID) -> Void
    /// What a row's context menu can do (archive, end, delete).
    var actions = SessionStageActions()
    @AppStorage("sessions.listExpanded") private var expanded = true
    @AppStorage("sessions.archivedExpanded") private var archivedExpanded = false
    /// The session a "New worktree…" sheet is open for.
    @State private var worktreeFor: AgentSession?
    /// The session a "Nickname…" sheet is open for.
    @State private var nicknameFor: AgentSession?

    private var matching: [AgentSession] {
        var sessions = store.sessions
        let q = filter.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            let bare = q.hasPrefix("@") ? String(q.dropFirst()) : q
            sessions = sessions.filter {
                $0.title.localizedCaseInsensitiveContains(q)
                    || ($0.openingMessage ?? "").localizedCaseInsensitiveContains(q)
                    || $0.cwd.localizedCaseInsensitiveContains(q)
                    || (!bare.isEmpty && ($0.nickname ?? "").localizedCaseInsensitiveContains(bare))
            }
        }
        return sessions
    }

    private var sessions: [AgentSession] { SessionHome.orderedAll(matching, in: model) }
    private var archived: [AgentSession] { SessionHome.archived(matching) }

    private func workspaceName(_ id: UUID) -> String {
        model.profileRows.first { $0.id == id }?.name ?? ""
    }
    private func accentHex(_ id: UUID) -> String {
        model.profileRows.first { $0.id == id }?.accentHex ?? "#888888"
    }

    var body: some View {
        let list = sessions
        let needsYou = list.filter { SessionHome.bucket(for: $0, in: model) == .needsYou }.count
        let open = expanded || !filter.isEmpty
        VStack(alignment: .leading, spacing: 1) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Text(NSLocalizedString("Sessions", comment: "sidebar section"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.7)
                    if needsYou > 0 {
                        SidebarAttentionBadge(count: needsYou, tint: SessionBucket.needsYou.tint)
                    }
                    Spacer()
                    if !list.isEmpty {
                        Text("\(list.count)")
                            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
            .padding(.trailing, 8)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .help(NSLocalizedString("Your conversations with agents — click to fold the list", comment: "sidebar"))

            if open {
                if list.isEmpty { emptyHint }
                ForEach(Self.nested(list), id: \.session.id) { row($0.session, depth: $0.depth) }
            }

            let put = archived
            if !put.isEmpty {
                // Put away, not gone: the fold opens on a click or a search
                // — and once, by itself, when the selection moves into it
                // (see `revealSelectedArchived`), so the caret still folds
                // it away with an archived session on stage.
                let openArchived = archivedExpanded || !filter.isEmpty
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { archivedExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: openArchived ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 10)
                        Text(NSLocalizedString("Archived", comment: "sidebar section"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.7)
                        Spacer()
                        Text("\(put.count)")
                            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
                .padding(.trailing, 8)
                .padding(.top, 10)
                .padding(.bottom, 4)
                .help(NSLocalizedString("Conversations you put away — still readable, back with one message", comment: "sidebar"))
                if openArchived {
                    ForEach(put) { row($0) }
                }
            }
        }
        .onAppear { revealSelectedArchived(model.selectedSessionID) }
        .onChange(of: model.selectedSessionID) { _, id in revealSelectedArchived(id) }
        .sheet(item: $nicknameFor) { s in
            NicknameSheet(session: s) { actions.setNickname(s.id, $0) }
        }
        .sheet(item: $worktreeFor) { parent in
            NewWorktreeSheet(parent: parent) { name, tool, message in
                actions.newWorktree(parent.id, name, tool, message)
            }
        }
    }

    /// The selection just landed on an archived session: open the fold so
    /// its row is on screen. One-shot — folding it back by hand sticks
    /// until the selection moves into the fold again.
    private func revealSelectedArchived(_ id: UUID?) {
        guard let id, !archivedExpanded,
              let s = store.session(id), s.isArchived, !s.isDeleted else { return }
        withAnimation(.easeInOut(duration: 0.15)) { archivedExpanded = true }
    }

    /// The list with each delegate placed right under its delegator (as
    /// deep as the chain goes), when the delegator is listed; a delegate
    /// whose delegator isn't stands on its own.
    static func nested(_ list: [AgentSession]) -> [(session: AgentSession, depth: Int)] {
        let ids = Set(list.map(\.id))
        var out: [(session: AgentSession, depth: Int)] = []
        var seen: Set<UUID> = []
        func walk(_ s: AgentSession, _ depth: Int) {
            guard seen.insert(s.id).inserted else { return }
            out.append((s, depth))
            for c in list where c.parentSessionID == s.id { walk(c, depth + 1) }
        }
        for s in list where s.parentSessionID.map({ !ids.contains($0) }) ?? true { walk(s, 0) }
        for s in list where !seen.contains(s.id) { walk(s, 0) }   // a cycle, somehow
        return out
    }

    private func row(_ s: AgentSession, depth: Int = 0) -> some View {
        let gone = SessionHome.isGone(s, in: model)
        return SessionRowView(
            session: s,
            workspaceName: workspaceName(s.profileID),
            accentHex: accentHex(s.profileID),
            dot: SessionHome.dot(for: s, in: model),
            statusLine: SessionHome.statusLine(for: s, in: model),
            when: s.isLaunching ? nil : SessionHome.elapsedCompact(since: SessionHome.lastActivity(s)),
            gone: gone,
            depth: depth,
            selected: model.selectedSessionID == s.id,
            onSelect: { onSelect(s.id) })
        .contextMenu {
            // The header's ⋯ menu, one right-click away — minus Rename,
            // which is the title itself.
            if !gone {
                if s.isArchived {
                    Button(NSLocalizedString("Unarchive", comment: "session menu")) { actions.unarchive(s.id) }
                } else {
                    Button(s.windowIndex != nil && !s.hasEnded
                           ? NSLocalizedString("End & Archive", comment: "session menu")
                           : NSLocalizedString("Archive", comment: "session menu")) {
                        actions.archive(s.id)
                    }
                }
                if s.windowIndex != nil, !s.hasEnded {
                    Button(NSLocalizedString("End session", comment: "session menu")) { actions.close(s.id) }
                }
                Divider()
                Button(NSLocalizedString("Nickname…", comment: "session menu")) { nicknameFor = s }
                if SessionHome.hasFolder(s) {
                    Button(NSLocalizedString("New worktree…", comment: "session menu")) { worktreeFor = s }
                }
            } else if s.isArchived {
                Button(NSLocalizedString("Unarchive", comment: "session menu")) { actions.unarchive(s.id) }
            }
            Divider()
            Button(NSLocalizedString("Delete session", comment: "session menu"), role: .destructive) {
                actions.delete(s.id)
            }
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(filter.isEmpty
                 ? NSLocalizedString("No sessions yet", comment: "session sidebar empty")
                 : NSLocalizedString("No matching sessions", comment: "session sidebar empty"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            if filter.isEmpty {
                Text(NSLocalizedString("Start one: pick an agent, say what you're after, and go.",
                                       comment: "session sidebar empty"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
