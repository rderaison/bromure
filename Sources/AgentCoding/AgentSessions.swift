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
    /// Files dropped on the new-session composer: staged in the machine
    /// once it's up, their guest paths appended to the opening message.
    var attachments: [DroppedFile] = []
    /// `AgentSession.role` of the new session (nil = an ordinary one).
    var role: String? = nil
    /// The room the new session joins (nil = none).
    var roomID: UUID? = nil
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
    /// The guest boot its tab was seen in (the kernel's boot_id, read by
    /// the liveness probe). Window indices start over when the machine
    /// boots fresh, so a binding from another boot names somebody else's
    /// tab — see `AgentSessionStore.checkBoot`.
    var bootID: String?
    /// What the session is for, beyond "an agent in a folder". nil = an
    /// ordinary session; "switchboard" = the one that watches and drives the
    /// others (Switchboard.swift) — never listed with them.
    var role: String?
    /// The room it belongs to (Rooms: a named set of sessions with a
    /// Switchboard of its own). nil = not in a room.
    var roomID: UUID?

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

    static let switchboardRole = "switchboard"
    var isSwitchboard: Bool { role == Self.switchboardRole }

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

    /// "Fix the login redirect loop" from a multi-line opening message: the
    /// first line, its first sentence when that's a real one, polite
    /// preambles dropped ("Please", "Can you", "I want you to"), cut on a
    /// word at ~56 characters — a sidebar row, not the whole ask.
    static func title(fromMessage text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        var clean = first.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
        // Its first sentence, when the line runs on past one.
        if let end = clean.firstIndex(where: { ".?!".contains($0) }),
           clean.index(after: end) < clean.endIndex, clean[clean.index(after: end)] == " " {
            let sentence = String(clean[...end]).trimmingCharacters(in: .whitespaces)
            if sentence.count >= 12 { clean = sentence }
        }
        for preamble in ["please ", "can you ", "could you ", "would you ", "i want you to ",
                         "i'd like you to ", "i would like you to ", "hey, ", "hi, ", "ok, ", "okay, "] {
            if clean.lowercased().hasPrefix(preamble), clean.count > preamble.count + 8 {
                clean = String(clean.dropFirst(preamble.count))
            }
        }
        clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: " .?!"))
        if let f = clean.first { clean = f.uppercased() + clean.dropFirst() }
        let limit = 56
        if clean.count <= limit { return clean }
        var cut = String(clean.prefix(limit))
        if let sp = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: sp) > 24 {
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
    /// The liveness probe read the guest's boot id. A session bound in an
    /// earlier boot lost its tab with that boot — the index it holds now
    /// belongs to whatever opened since (a new session, a relaunch), and
    /// trusting it typed notices into that agent and showed its transcript.
    /// Unbind it (Ended, resumable); a binding without a boot yet takes
    /// this one. False when the session is no longer bound here.
    @discardableResult
    func checkBoot(_ id: UUID, bootID: String, now: Date = Date()) -> Bool {
        guard !bootID.isEmpty, let i = sessions.firstIndex(where: { $0.id == id }),
              sessions[i].windowIndex != nil else { return false }
        if sessions[i].bootID == nil {
            sessions[i].bootID = bootID
            save()
            return true
        }
        guard sessions[i].bootID != bootID else { return true }
        sessions[i].windowIndex = nil
        sessions[i].bootID = nil
        sessions[i].endedAt = now
        sessions[i].agentAlive = nil
        save()
        return false
    }

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
                    // the new tab carrying the session's name (see
                    // `launchTab`). Window indices are per machine: another
                    // workspace's session on index 1 says nothing about
                    // this one's tab 1.
                    let bound = Set(sessions.filter { $0.profileID == entry.id }.compactMap { $0.windowIndex })
                    let candidates = tabs.filter { t in
                        t.index > baseline && !bound.contains(t.index) && t.containerID == nil
                    }
                    let soleLaunch = !sessions.contains { o in
                        o.id != s.id && o.profileID == entry.id && o.windowIndex == nil
                            && o.launchingSince != nil && o.launchBaselineIndex != nil
                    }
                    if let tab = Self.launchTab(for: s, in: candidates, soleLaunch: soleLaunch) {
                        s.windowIndex = tab.index
                        s.bootID = nil   // stamped by the next probe
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
            let pending = sessions.filter {
                $0.profileID == entry.id && $0.windowIndex == nil
                    && $0.launchingSince != nil && $0.launchBaselineIndex != nil
            }
            for tab in tabs where !bound.contains(tab.index) && tab.containerID == nil {
                // A tab a waiting launch may still claim — named for it, or
                // not named yet — is that launch's, not a stranger to adopt.
                if pending.contains(where: { Self.mayBeLaunchTab(tab, of: $0) }) { continue }
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
                    sessions[i].bootID = nil
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

    /// The tab a launch opened, among the unowned tabs past its baseline:
    /// the one carrying its launch name (the guest sets @display on the
    /// window it opens), in the session's folder first when two share the
    /// name. A tab named for anything else is another launch's — two
    /// launches racing on one machine (a new session while a notice resumes
    /// a sleeping peer) used to swap tabs through a "first agent tab past
    /// the baseline" fallback, and each session showed, and was typed
    /// into, the other's agent. A tab not named yet (the roster caught it
    /// between new-window and set-option) is ours only when no other
    /// launch is waiting on the machine.
    static func launchTab(for s: AgentSession, in candidates: [TabsModel.Tab],
                          soleLaunch: Bool) -> TabsModel.Tab? {
        let name = s.launchDisplay ?? s.title
        let named = candidates.filter { $0.display == name }
        let mine = SessionHome.guestPath(s.cwd)
        if let tab = named.first(where: { $0.cwd.map(SessionHome.guestPath) == mine }) ?? named.first {
            return tab
        }
        guard soleLaunch else { return nil }
        let unnamed = candidates.filter { ($0.display ?? "").isEmpty }
        return unnamed.first { BromureIcons.agentKind(forLabel: $0.shownLabel) == s.tool.rawValue }
            ?? unnamed.first
    }

    /// Whether `tab` may yet turn out to be `launch`'s: past its baseline,
    /// and named for it or not named at all.
    static func mayBeLaunchTab(_ tab: TabsModel.Tab, of launch: AgentSession) -> Bool {
        guard let baseline = launch.launchBaselineIndex, tab.index > baseline else { return false }
        let d = tab.display ?? ""
        return d.isEmpty || d == (launch.launchDisplay ?? launch.title)
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
        let sessions = sessions.filter { !$0.isArchived && !$0.isDeleted && !$0.isSwitchboard }
        let groups = grouped(sessions.filter { !isGone($0, in: model) }, in: model)
        let gone = sessions.filter { isGone($0, in: model) }
            .sorted { lastActivity($0) > lastActivity($1) }
        return SessionBucket.allCases.flatMap { groups[$0] ?? [] } + gone
    }

    /// The put-away sessions, most recently archived first.
    static func archived(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.filter { $0.isArchived && !$0.isDeleted && !$0.isSwitchboard }
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

    /// The session's title — plus, when another of `among` has the very
    /// same one, what tells them apart: its @nickname, else its folder, else
    /// its machine ("Delegation MCP tool request · dtest-peer").
    @MainActor
    static func distinctTitle(_ s: AgentSession, among: [AgentSession], in model: SessionListModel) -> String {
        guard among.contains(where: { $0.id != s.id && $0.title == s.title && !$0.isDeleted }) else { return s.title }
        if let nick = s.nickname, !nick.isEmpty { return s.title + " · @" + nick }
        let folder = (s.cwd as NSString).lastPathComponent
        if !folder.isEmpty, folder != "~", folder != "ubuntu" { return s.title + " · " + folder }
        if let ws = model.profileRows.first(where: { $0.id == s.profileID })?.name { return s.title + " · " + ws }
        return s.title
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
        let groups = grouped(sessions.filter { !$0.isArchived && !$0.isDeleted && !$0.isSwitchboard }, in: model)
        return SessionBucket.allCases.filter { $0 != .ended }.flatMap { groups[$0] ?? [] }
    }

    /// The session the home screen opens on: the remembered one if it's
    /// still around, else the most pressing bucket's newest (never one that
    /// was put away).
    @MainActor
    static func initialSession(in store: AgentSessionStore, model: SessionListModel,
                               remembered: UUID?) -> AgentSession? {
        if let id = remembered, let s = store.session(id), !s.hasEnded, !s.isArchived, !s.isDeleted { return s }
        let groups = grouped(store.sessions.filter { !$0.isArchived && !$0.isDeleted && !$0.isSwitchboard }, in: model)
        for b in SessionBucket.allCases {
            if let s = groups[b]?.first { return s }
        }
        return nil
    }
}

// MARK: - Rooms

/// A named set of sessions — a project, a feature, a firefight — with a
/// Switchboard of its own that keeps track of those sessions only. Borrowed
/// from the Rooms window manager: pick a room and it's all that's in front
/// of you; nothing outside it is closed, just out of the way. Membership
/// lives on the session (`AgentSession.roomID`).
struct AgentRoom: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var colorHex: String
    var createdAt: Date
    /// The grid the room shows, "<columns>x<rows>" (nil: sized to fit).
    var layout: String?
    /// Put away with all its sessions: the room sits in the Archived fold.
    var archivedAt: Date?
    var isArchived: Bool { archivedAt != nil }

    init(id: UUID = UUID(), name: String, colorHex: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.createdAt = createdAt
    }

    /// Room tiles, handed out in turn.
    static let palette = ["#6366F1", "#10B981", "#F59E0B", "#EC4899", "#06B6D4",
                          "#8B5CF6", "#EF4444", "#84CC16"]

    /// "Payments v2" → "payments-v2": the room Switchboard's folder name.
    var slug: String {
        let s = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let joined = String(s).split(separator: "-").joined(separator: "-")
        return joined.isEmpty ? String(id.uuidString.prefix(8)).lowercased() : String(joined.prefix(40))
    }
}

@MainActor
@Observable
final class AgentRoomStore {
    private(set) var rooms: [AgentRoom] = []
    private let fileURL: URL
    private let isMirror: Bool

    init(fileURL: URL? = nil) {
        isMirror = false
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("BromureAC", isDirectory: true)
            .appendingPathComponent("rooms.json")
        load()
    }

    init(mirror: Bool) {
        isMirror = mirror
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("rooms-mirror.json")
    }

    func room(_ id: UUID?) -> AgentRoom? {
        guard let id else { return nil }
        return rooms.first { $0.id == id }
    }

    /// A new room, its name made unique ("Payments", "Payments 2", …).
    @discardableResult
    func create(name raw: String) -> AgentRoom {
        let base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted = base.isEmpty ? NSLocalizedString("New Room", comment: "room default name") : base
        var name = wanted
        var n = 2
        let taken = Set(rooms.map { $0.name.lowercased() })
        while taken.contains(name.lowercased()) { name = "\(wanted) \(n)"; n += 1 }
        let color = AgentRoom.palette[rooms.count % AgentRoom.palette.count]
        let r = AgentRoom(name: name, colorHex: color)
        rooms.append(r)
        save()
        return r
    }

    func rename(_ id: UUID, to raw: String) {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = rooms.firstIndex(where: { $0.id == id }) else { return }
        rooms[i].name = name
        save()
    }

    func setArchived(_ id: UUID, _ archived: Bool) {
        guard let i = rooms.firstIndex(where: { $0.id == id }), rooms[i].isArchived != archived else { return }
        rooms[i].archivedAt = archived ? Date() : nil
        save()
    }

    /// Rooms on show, and the put-away ones.
    var activeRooms: [AgentRoom] { rooms.filter { !$0.isArchived } }
    var archivedRooms: [AgentRoom] { rooms.filter(\.isArchived) }

    func setLayout(_ id: UUID, _ layout: String?) {
        guard let i = rooms.firstIndex(where: { $0.id == id }), rooms[i].layout != layout else { return }
        rooms[i].layout = layout
        save()
    }

    func setColor(_ id: UUID, _ hex: String) {
        guard let i = rooms.firstIndex(where: { $0.id == id }) else { return }
        rooms[i].colorHex = hex
        save()
    }

    func remove(_ id: UUID) {
        rooms.removeAll { $0.id == id }
        save()
    }

    func applyMirror(_ list: [AgentRoom]) {
        if list != rooms { rooms = list }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        rooms = (try? dec.decode([AgentRoom].self, from: data)) ?? []
    }

    private func save() {
        guard !isMirror else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(rooms) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// A room's grid: columns × rows per page; more sessions than that go to
/// further pages, each a tab.
struct RoomLayout: Hashable {
    let cols: Int
    let rows: Int
    var size: Int { cols * rows }
    var string: String { "\(cols)x\(rows)" }

    static let all: [RoomLayout] = [.init(cols: 1, rows: 1), .init(cols: 2, rows: 1), .init(cols: 2, rows: 2),
                                    .init(cols: 3, rows: 2), .init(cols: 3, rows: 3), .init(cols: 4, rows: 4)]

    init(cols: Int, rows: Int) { self.cols = cols; self.rows = rows }

    init?(_ string: String) {
        let p = string.split(separator: "x").compactMap { Int($0) }
        guard p.count == 2, (1...6).contains(p[0]), (1...6).contains(p[1]) else { return nil }
        self.init(cols: p[0], rows: p[1])
    }

    /// The smallest layout that shows `n` sessions at once (4×4 beyond).
    static func fitting(_ n: Int) -> RoomLayout {
        all.first { $0.size >= n } ?? all.last!
    }

    /// Chunked into pages of `size`.
    func pages<T>(_ items: [T]) -> [[T]] {
        stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }
}

/// What a room's row and header say about it.
enum RoomTally {
    /// The room's sessions, its own Switchboard left out. An archived room
    /// keeps its (archived) sessions; a live one shows only live ones.
    static func members(_ room: AgentRoom, in sessions: [AgentSession]) -> [AgentSession] {
        sessions.filter {
            $0.roomID == room.id && !$0.isSwitchboard && !$0.isDeleted && (room.isArchived || !$0.isArchived)
        }
    }

    static func switchboard(of room: AgentRoom, in sessions: [AgentSession]) -> AgentSession? {
        sessions.first { $0.isSwitchboard && $0.roomID == room.id && !$0.isDeleted }
    }

    /// "1 need you · 2 working", or how many sessions are in it.
    @MainActor
    static func summary(_ room: AgentRoom, _ sessions: [AgentSession], in model: SessionListModel) -> String {
        let list = members(room, in: sessions)
        guard !list.isEmpty else {
            return NSLocalizedString("Empty — drag sessions here", comment: "room row")
        }
        let active = SwitchboardGate.summary(list, in: model)
        if active != NSLocalizedString("Keeps track of your sessions", comment: "switchboard summary") { return active }
        return list.count == 1
            ? NSLocalizedString("1 session", comment: "room row")
            : String(format: NSLocalizedString("%d sessions", comment: "room row"), list.count)
    }

    /// The most pressing state among the room's sessions, for its dot.
    @MainActor
    static func dot(_ room: AgentRoom, _ sessions: [AgentSession], in model: SessionListModel) -> AgentStatus? {
        let buckets = members(room, in: sessions).map { SessionHome.bucket(for: $0, in: model) }
        if buckets.contains(.needsYou) { return .needsInput }
        if buckets.contains(.working) { return .working }
        if buckets.contains(.idle) { return .done }
        return nil
    }
}

// MARK: - Switchboard visibility

/// When the Switchboard earns a place in the list. It is a session like any
/// other underneath, but it only makes sense with several conversations to
/// keep track of: with one (or none) in flight the user is already looking
/// at the only thing that matters, and a second prompt would just be noise.
/// So the row appears once two or more sessions are in flight — or while
/// the Switchboard itself has something going on (a turn under way, a
/// question for the user), so what it's doing never vanishes mid-way.
enum SwitchboardGate {
    /// Sessions in flight: launching, working, ready or waiting on the
    /// user — not asleep, ended or put away.
    @MainActor
    static func activeCount(_ sessions: [AgentSession], in model: SessionListModel) -> Int {
        sessions.filter { s in
            guard !s.isSwitchboard, !s.isArchived, !s.isDeleted else { return false }
            switch SessionHome.bucket(for: s, in: model) {
            case .needsYou, .working, .idle: return true
            case .asleep, .ended: return false
            }
        }.count
    }

    /// The global Switchboard — the one that isn't a room's.
    static func switchboard(in sessions: [AgentSession]) -> AgentSession? {
        sessions.first { $0.isSwitchboard && !$0.isDeleted && $0.roomID == nil }
    }

    @MainActor
    static func isVisible(_ sessions: [AgentSession], in model: SessionListModel) -> Bool {
        if activeCount(sessions, in: model) >= 2 { return true }
        guard let c = switchboard(in: sessions) else { return false }
        let b = SessionHome.bucket(for: c, in: model)
        return b == .working || b == .needsYou
    }

    /// "2 working · 1 needs you" — what the row says under its name.
    @MainActor
    static func summary(_ sessions: [AgentSession], in model: SessionListModel) -> String {
        var counts: [SessionBucket: Int] = [:]
        for s in sessions where !s.isSwitchboard && !s.isArchived && !s.isDeleted {
            counts[SessionHome.bucket(for: s, in: model), default: 0] += 1
        }
        var parts: [String] = []
        if let n = counts[.needsYou], n > 0 {
            parts.append(String(format: NSLocalizedString("%d need you", comment: "switchboard summary"), n))
        }
        if let n = counts[.working], n > 0 {
            parts.append(String(format: NSLocalizedString("%d working", comment: "switchboard summary"), n))
        }
        if let n = counts[.idle], n > 0 {
            parts.append(String(format: NSLocalizedString("%d ready", comment: "switchboard summary"), n))
        }
        return parts.isEmpty
            ? NSLocalizedString("Keeps track of your sessions", comment: "switchboard summary")
            : parts.joined(separator: " · ")
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
        let old = try? Data(contentsOf: u)
        if let old, old.count == data.count, old == data { return }
        // Two writers feed this: the beautified view (the whole history it
        // holds) and the engine's periodic snapshot (a short tail). A shorter
        // snapshot must not throw away the history — splice it in where its
        // first whole line already sits; only an unrelated transcript replaces.
        var merged = data
        if let old, old.count > data.count, let spliced = Self.splice(history: old, tail: data) {
            merged = spliced
            if merged == old { return }
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? merged.write(to: u, options: .atomic)
        var v = u
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? v.setResourceValues(rv)
    }

    /// `history` with `tail` laid over its end: the tail's first complete
    /// line is found (last occurrence) in the history and everything from
    /// there is replaced by the tail. nil when the tail doesn't belong to
    /// this history.
    static func splice(history: Data, tail: Data) -> Data? {
        // The tail may start mid-line (a byte-cap cut): the first COMPLETE
        // line is the one after the first newline — unless the tail starts
        // at a line boundary, when its first line is already whole.
        guard let nl = tail.firstIndex(of: 0x0A) else { return nil }
        let lineStart: Data.Index
        if let last = history.last, last == 0x0A, history.count > tail.count,
           history[(history.endIndex - tail.count)...] == tail {
            return history   // an exact suffix: nothing new
        }
        lineStart = tail.index(after: nl)
        guard lineStart < tail.endIndex,
              let nl2 = tail[lineStart...].firstIndex(of: 0x0A) else { return nil }
        let probe = tail[lineStart...nl2]
        guard probe.count > 16, let r = history.range(of: probe, options: .backwards) else { return nil }
        var out = Data(history[..<r.lowerBound])
        out.append(tail[lineStart...])
        return out
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
    /// The title to show when it differs from the session's own (another
    /// session has the same one).
    var title: String? = nil
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
                    Text(title ?? session.title)
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
            .fill(selected ? Color.acSelection
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

/// The Switchboard's row: a baton instead of an avatar, a one-line tally of
/// the sessions it watches, and the status dot of its own conversation.
struct SwitchboardRowView: View {
    let summary: String
    let dot: AgentStatus?
    /// A Switchboard session exists (else a click starts one).
    let started: Bool
    let selected: Bool
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "wand.and.rays")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.accentColor.opacity(0.14)))
                if let dot {
                    Circle()
                        .fill(dot == .needsInput ? SessionBucket.needsYou.tint
                              : dot == .working ? SessionBucket.working.tint
                              : SessionBucket.idle.tint)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString("Switchboard", comment: "switchboard row"))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(started ? summary
                             : NSLocalizedString("Ask about all your sessions at once", comment: "switchboard row"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(selected ? Color.acSelection
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
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help(NSLocalizedString("The Switchboard keeps track of every session: ask what's going on, answer them, start new work", comment: "switchboard row"))
    }
}

/// A room in the session list: a colored tile, its name and what its
/// sessions are up to; a caret folds its members away.
struct RoomRowView: View {
    let room: AgentRoom
    let summary: String
    let dot: AgentStatus?
    let folded: Bool
    let hasMembers: Bool
    let selected: Bool
    let dropTargeted: Bool
    let onSelect: () -> Void
    let onFold: () -> Void
    @State private var hovering = false

    static func colorName(_ hex: String) -> String {
        switch hex {
        case "#6366F1": return NSLocalizedString("Indigo", comment: "room color")
        case "#10B981": return NSLocalizedString("Green", comment: "room color")
        case "#F59E0B": return NSLocalizedString("Amber", comment: "room color")
        case "#EC4899": return NSLocalizedString("Pink", comment: "room color")
        case "#06B6D4": return NSLocalizedString("Cyan", comment: "room color")
        case "#8B5CF6": return NSLocalizedString("Violet", comment: "room color")
        case "#EF4444": return NSLocalizedString("Red", comment: "room color")
        case "#84CC16": return NSLocalizedString("Lime", comment: "room color")
        default: return hex
        }
    }

    var body: some View {
        let tint = Color(hex: room.colorHex)
        HStack(spacing: 9) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(tint.gradient)
                    .frame(width: 26, height: 26)
                    .overlay(Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white))
                if let dot {
                    Circle()
                        .fill(dot == .needsInput ? SessionBucket.needsYou.tint
                              : dot == .working ? SessionBucket.working.tint
                              : SessionBucket.idle.tint)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                        .offset(x: 2, y: 2)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(room.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if hasMembers {
                Button(action: onFold) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(folded ? 0 : 90))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovering || folded ? 1 : 0.35)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 44)
        .background(RoundedRectangle(cornerRadius: 7)
            .fill(selected ? Color.acSelection
                           : (hovering ? Color.primary.opacity(0.04) : .clear)))
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 7).strokeBorder(tint, lineWidth: 2)
            }
        }
        .overlay(alignment: .leading) {
            if selected {
                RoundedRectangle(cornerRadius: 2)
                    .fill(tint)
                    .frame(width: 3)
                    .padding(.vertical, 9)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .help(NSLocalizedString("Open the room: all its sessions side by side, with its own Switchboard", comment: "room row"))
    }
}

/// A state group's label in the session list ("NEEDS YOU · 2"), tinted
/// by the state; the Ended one folds.
struct SessionGroupHeader: View {
    let bucket: SessionBucket
    let count: Int
    let foldable: Bool
    let folded: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(bucket.tint).frame(width: 6, height: 6)
            Text(bucket.title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            if foldable {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(folded ? 0 : 90))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 3)
        .contentShape(Rectangle())
        .onTapGesture { if foldable { onToggle() } }
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
    /// The rooms, shown above the loose sessions (host window only).
    var rooms: [AgentRoom] = []
    @AppStorage("sessions.listExpanded") private var expanded = true
    /// Rooms folded in the sidebar (their members hidden).
    @State private var foldedRooms: Set<UUID> = []
    /// The room a drag hovers.
    @State private var dropRoom: UUID?
    /// The session a drag hovers (dropping groups the two into a room).
    @State private var dropSession: UUID?
    /// The room naming sheet: new (with an optional session to move in) or rename.
    @State private var roomSheet: RoomSheet?

    private struct RoomSheet: Identifiable {
        let id = UUID()
        var renaming: AgentRoom?
        var withSession: UUID?
    }
    @AppStorage("sessions.archivedExpanded") private var archivedExpanded = false
    /// The Ended group, folded unless opened (or searched).
    @AppStorage("sessions.endedExpanded") private var endedExpanded = false
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
    private var roomIDs: Set<UUID> { Set(activeRooms.map(\.id)) }
    /// Sessions in no (existing) room.
    private func loose(_ list: [AgentSession]) -> [AgentSession] {
        let ids = roomIDs
        return list.filter { $0.roomID.map { !ids.contains($0) } ?? true }
    }
    /// Put-away sessions — those of an archived room show under its row.
    private var archived: [AgentSession] {
        let ids = Set(archivedRooms.map(\.id))
        return SessionHome.archived(matching).filter { $0.roomID.map { !ids.contains($0) } ?? true }
    }
    private var activeRooms: [AgentRoom] { rooms.filter { !$0.isArchived } }
    private var archivedRooms: [AgentRoom] { rooms.filter(\.isArchived) }

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
            SidebarSectionHeader(title: NSLocalizedString("Sessions", comment: "sidebar section"),
                                 expanded: open,
                                 badges: [(needsYou, SessionBucket.needsYou.tint)],
                                 count: list.count,
                                 help: NSLocalizedString("Your conversations with agents — click to fold the list", comment: "sidebar"),
                                 onTitle: { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } },
                                 topPadding: 8)

            if open {
                if filter.isEmpty, SwitchboardGate.isVisible(store.sessions, in: model) {
                    switchboardRow
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                if list.isEmpty && activeRooms.isEmpty { emptyHint }
                ForEach(activeRooms) { roomBlock($0, list) }
                // Grouped by state: what needs you first, ended folded away.
                let loose = loose(list)
                ForEach(SessionBucket.allCases) { bucket in
                    let group = loose.filter { SessionHome.bucket(for: $0, in: model) == bucket }
                    if !group.isEmpty {
                        let folded = bucket == .ended && !endedExpanded && filter.isEmpty
                        SessionGroupHeader(bucket: bucket, count: group.count,
                                           foldable: bucket == .ended, folded: folded) {
                            withAnimation(.easeInOut(duration: 0.15)) { endedExpanded.toggle() }
                        }
                        if !folded {
                            ForEach(Self.nested(group), id: \.session.id) { row($0.session, depth: $0.depth) }
                        }
                    }
                }
            }

            let put = archived
            let putRooms = archivedRooms
            if !put.isEmpty || !putRooms.isEmpty {
                // Put away, not gone: the fold opens on a click or a search
                // — and once, by itself, when the selection moves into it
                // (see `revealSelectedArchived`), so the caret still folds
                // it away with an archived session on stage.
                let openArchived = archivedExpanded || !filter.isEmpty
                SidebarSectionHeader(title: NSLocalizedString("Archived", comment: "sidebar section"),
                                     expanded: openArchived,
                                     count: put.count + putRooms.count,
                                     help: NSLocalizedString("Conversations you put away — still readable, back with one message", comment: "sidebar"),
                                     onTitle: { withAnimation(.easeInOut(duration: 0.15)) { archivedExpanded.toggle() } })
                if openArchived {
                    ForEach(putRooms) { roomBlock($0, SessionHome.archived(matching)) }
                    ForEach(put) { row($0) }
                }
            }
        }
        .onAppear { revealSelectedArchived(model.selectedSessionID) }
        .onChange(of: model.selectedSessionID) { _, id in revealSelectedArchived(id) }
        .sheet(item: $nicknameFor) { s in
            NicknameSheet(session: s) { actions.setNickname(s.id, $0) }
        }
        .sheet(item: $roomSheet) { sheet in
            if let r = sheet.renaming {
                RoomNameSheet(title: NSLocalizedString("Rename Room", comment: "room sheet"),
                              action: NSLocalizedString("Rename", comment: "room sheet"),
                              initial: r.name) { actions.renameRoom(r.id, $0) }
            } else {
                RoomNameSheet(title: NSLocalizedString("New Room", comment: "room sheet"),
                              action: NSLocalizedString("Create", comment: "room sheet")) {
                    actions.newRoom($0, sheet.withSession)
                }
            }
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
            onSelect: { onSelect(s.id) },
            title: SessionHome.distinctTitle(s, among: store.sessions, in: model))
        .overlay {
            if dropSession == s.id {
                RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .draggable(s.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            // Another session dropped on this one: the two share a room
            // (this one's, or a new one).
            let ids = items.compactMap(UUID.init(uuidString:)).filter { $0 != s.id }
            guard !gone, !s.isArchived, !ids.isEmpty else { return false }
            for id in ids { actions.groupSessions(id, s.id) }
            return true
        } isTargeted: { inside in
            dropSession = inside ? s.id : (dropSession == s.id ? nil : dropSession)
        }
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
                if !s.isArchived { roomMenu(s) }
                Divider()
                Button(String(format: NSLocalizedString("“%@” Settings…", comment: "session menu: machine settings"),
                              workspaceName(s.profileID))) { actions.editMachine(s.profileID) }
                if s.windowIndex != nil, !s.hasEnded {
                    Button(NSLocalizedString("Open in Linux Terminal", comment: "session menu")) { actions.openLinux(s.id) }
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

    /// The Switchboard, pinned above the sessions it keeps track of — see
    /// `SwitchboardGate` for when it shows at all.
    private var switchboardRow: some View {
        let c = SwitchboardGate.switchboard(in: store.sessions)
        return SwitchboardRowView(
            summary: SwitchboardGate.summary(store.sessions, in: model),
            dot: c.flatMap { SessionHome.dot(for: $0, in: model) },
            started: c != nil,
            selected: c.map { model.selectedSessionID == $0.id } ?? false,
            onSelect: actions.openSwitchboard)
    }

    // MARK: Rooms

    /// "Move to Room" for a session's context menu.
    @ViewBuilder
    private func roomMenu(_ s: AgentSession) -> some View {
        Menu(NSLocalizedString("Move to Room", comment: "session menu")) {
            ForEach(activeRooms) { r in
                Button(r.name) { actions.moveToRoom(s.id, r.id) }
                    .disabled(s.roomID == r.id)
            }
            if !activeRooms.isEmpty { Divider() }
            Button(NSLocalizedString("New Room…", comment: "session menu")) {
                roomSheet = RoomSheet(withSession: s.id)
            }
        }
        if let rid = s.roomID, roomIDs.contains(rid) {
            Button(NSLocalizedString("Remove from Room", comment: "session menu")) { actions.moveToRoom(s.id, nil) }
        }
    }

    /// A room: its row (click → the room's grid), then its members nested
    /// under it unless folded. Sessions dropped on it move in.
    @ViewBuilder
    private func roomBlock(_ r: AgentRoom, _ list: [AgentSession]) -> some View {
        let members = list.filter { $0.roomID == r.id }
        let folded = foldedRooms.contains(r.id) && filter.isEmpty
        RoomRowView(
            room: r,
            summary: RoomTally.summary(r, store.sessions, in: model),
            dot: RoomTally.dot(r, store.sessions, in: model),
            folded: folded,
            hasMembers: !members.isEmpty,
            selected: model.selectedRoomID == r.id,
            dropTargeted: dropRoom == r.id,
            onSelect: { actions.openRoom(r.id) },
            onFold: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if foldedRooms.contains(r.id) { foldedRooms.remove(r.id) } else { foldedRooms.insert(r.id) }
                }
            })
        .dropDestination(for: String.self) { items, _ in
            let ids = items.compactMap(UUID.init(uuidString:))
            for id in ids { actions.moveToRoom(id, r.id) }
            return !ids.isEmpty
        } isTargeted: { inside in
            dropRoom = inside ? r.id : (dropRoom == r.id ? nil : dropRoom)
        }
        .contextMenu {
            Button(NSLocalizedString("New Session in Room", comment: "room menu")) { actions.newSessionInRoom(r.id) }
            Divider()
            Button(NSLocalizedString("Rename…", comment: "room menu")) { roomSheet = RoomSheet(renaming: r) }
            Menu(NSLocalizedString("Color", comment: "room menu")) {
                ForEach(AgentRoom.palette, id: \.self) { hex in
                    Button {
                        actions.setRoomColor(r.id, hex)
                    } label: {
                        Label(RoomRowView.colorName(hex),
                              systemImage: r.colorHex == hex ? "checkmark.circle.fill" : "circle.fill")
                    }
                }
            }
            Divider()
            if r.isArchived {
                Button(NSLocalizedString("Unarchive Room", comment: "room menu")) { actions.unarchiveRoom(r.id) }
            } else {
                Button(NSLocalizedString("Archive Room", comment: "room menu")) { actions.archiveRoom(r.id) }
            }
            Button(NSLocalizedString("Ungroup Room", comment: "room menu")) { actions.ungroupRoom(r.id) }
            Divider()
            Button(NSLocalizedString("Delete Room…", comment: "room menu"), role: .destructive) { actions.deleteRoom(r.id) }
        }
        if !folded {
            ForEach(Self.nested(members), id: \.session.id) { row($0.session, depth: $0.depth + 1) }
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
