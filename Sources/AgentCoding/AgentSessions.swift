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
    /// Added to the agent's system prompt (nil = none).
    var instructions: String? = nil
}

/// A worktree session's branch, as the last check read it.
struct BranchInfo: Codable, Equatable, Sendable {
    /// Commits on the branch the parent doesn't have.
    var ahead: Int
    /// Commits on the parent since the branch was made.
    var behind: Int
    /// Files with uncommitted changes in the checkout.
    var changed: Int
    var checkedAt: Date

    var isEmpty: Bool { ahead == 0 && changed == 0 }
}

/// What a folder is, git-wise, as the New Branch sheet needs to know:
/// a repository (on which branch, with which others to start from), one
/// without a commit yet, or none. `includes`: what the repository's
/// .worktreeinclude copies into every new checkout.
struct GitFolderState: Equatable, Sendable {
    enum Kind: String, Sendable { case repo, noCommits, notRepo }
    var kind: Kind
    var branch: String?
    var branches: [String] = []
    var includes: [String] = []
    var isRepo: Bool { kind == .repo }

    /// The guest command's output (see AgentSessionEngine.gitState).
    static func parse(_ out: String) -> GitFolderState? {
        var state: GitFolderState?
        var section = ""
        for raw in out.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            switch line {
            case "===BRANCHES===": section = "b"; continue
            case "===INCLUDE===": section = "i"; continue
            default: break
            }
            if state == nil {
                if line == "none" { return GitFolderState(kind: .notRepo) }
                if line == "empty" { state = GitFolderState(kind: .noCommits) }
                else if line.hasPrefix("repo") {
                    let b = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                    state = GitFolderState(kind: .repo, branch: b.isEmpty || b == "HEAD" ? nil : b)
                }
                continue
            }
            if section == "b" { state?.branches.append(line) }
            if section == "i" { state?.includes.append(line) }
        }
        return state
    }

    /// Over the fat-client wire.
    var json: [String: Any] {
        var o: [String: Any] = ["kind": kind.rawValue, "repo": isRepo, "branches": branches, "includes": includes]
        if let branch { o["branch"] = branch }
        return o
    }

    init(kind: Kind, branch: String? = nil, branches: [String] = [], includes: [String] = []) {
        self.kind = kind; self.branch = branch; self.branches = branches; self.includes = includes
    }

    init?(json j: [String: Any]) {
        if let k = (j["kind"] as? String).flatMap(Kind.init(rawValue:)) { kind = k }
        else if let repo = j["repo"] as? Bool {
            // An older server: repo, or "" for no commit yet.
            kind = repo ? .repo : ((j["branch"] as? String) == "" ? .noCommits : .notRepo)
        } else { return nil }
        branch = (j["branch"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        branches = j["branches"] as? [String] ?? []
        includes = j["includes"] as? [String] ?? []
    }
}

/// One worktree on the machine.
struct WorktreeEntry: Identifiable, Equatable, Sendable {
    var id: String { dir }
    var dir: String
    var root: String
    var branch: String
    var parent: String
    var ahead: Int
    var changed: Int
    var lastCommit: Date?
    /// The name it was started under (the registry's display).
    var display: String

    var isEmpty: Bool { ahead == 0 && changed == 0 }

    /// Lists every worktree under ~/.bromure/worktrees: one tab-separated
    /// line each — dir, root, branch, parent, ahead, changed, last commit
    /// (epoch), display.
    static let guestCommand = """
    for d in "$HOME"/.bromure/worktrees/*/*/; do d="${d%/}"; [ -e "$d/.git" ] || continue; \
    cd "$d" 2>/dev/null || continue; \
    r=$(git worktree list --porcelain 2>/dev/null | head -1 | cut -c10-); \
    b=$(git rev-parse --abbrev-ref HEAD 2>/dev/null); \
    reg="$(dirname "$d")/.registry"; p=""; disp=""; \
    [ -f "$reg" ] && p=$(awk -F"$(printf '\\037')" -v b="$b" '$1==b{print $2}' "$reg" | tail -1) \
    && disp=$(awk -F"$(printf '\\037')" -v b="$b" '$1==b{print $3}' "$reg" | tail -1); \
    [ -n "$p" ] || p=$(git -C "$r" rev-parse --abbrev-ref HEAD 2>/dev/null); \
    a=$(git rev-list --count "$p..HEAD" 2>/dev/null || echo 0); \
    c=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' '); \
    t=$(git log -1 --format=%ct 2>/dev/null || echo 0); \
    printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "$d" "$r" "$b" "$p" "$a" "$c" "$t" "$disp"; \
    done; true
    """

    static func parse(_ out: String) -> [WorktreeEntry] {
        out.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 8, !f[0].isEmpty, !f[2].isEmpty else { return nil }
            let t = TimeInterval(f[6]) ?? 0
            return WorktreeEntry(dir: f[0], root: f[1], branch: f[2], parent: f[3],
                                 ahead: Int(f[4]) ?? 0, changed: Int(f[5]) ?? 0,
                                 lastCommit: t > 0 ? Date(timeIntervalSince1970: t) : nil,
                                 display: f[7])
        }
    }

    /// The session working on it, if any: same machine, same branch.
    func session(in sessions: [AgentSession], profileID: UUID) -> AgentSession? {
        sessions.filter { $0.profileID == profileID && $0.worktreeBranch == branch && !$0.isDeleted }
            .max { ($0.lastSeenAt ?? .distantPast) < ($1.lastSeenAt ?? .distantPast) }
    }
}

/// What the New Branch sheet asks for.
struct NewBranchRequest: Sendable {
    /// Empty = named after the message.
    var name: String
    var tool: Profile.Tool
    var message: String?
    /// Make the folder a repository first when it isn't one.
    var initGit: Bool
    /// The branch to start from (nil = the folder's current commit).
    var base: String?
}

/// A merge of a worktree session's branch, from the click to its landing.
struct BranchMerge: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        /// An agent asked to merge (worktree_merge); the user says yes or no.
        case requested
        case merging, conflicts, merged, failed

        /// A phase this build doesn't know reads as stalled, not as an
        /// undecodable session.
        init(from decoder: Decoder) throws {
            self = Phase(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .failed
        }
    }
    var target: String
    var squash: Bool
    /// Remove the checkout and the branch once it's in.
    var removeAfter: Bool
    var startedAt: Date
    var phase: Phase
    var detail: String?
    /// The session whose agent asked for it (worktree_merge) — told how it
    /// went.
    var askedBy: UUID?
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
    /// The agent's own transcript says a turn is under way (Kimi's journal
    /// records turn boundaries; its hooks alone left "Ready" up while it
    /// worked). nil: not known / not read for this agent.
    var transcriptWorking: Bool?
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
    /// The branch it was made from ("main") — where a merge goes by
    /// default — and the repository it's a checkout of.
    var branchParent: String?
    var branchRoot: String?
    /// What the branch holds, as the last check read it.
    var branchInfo: BranchInfo?
    /// A merge started from the session, followed until it lands.
    var branchMerge: BranchMerge?
    /// Review comments on the session's changes (the review window): kept
    /// until sent to the agent, then shown as sent.
    var reviewComments: [ReviewComment]?
    /// Files marked viewed in the review window: path → fingerprint of the
    /// diff that was seen (a later change to the file clears the mark).
    var reviewViewed: [String: String]?
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
    /// Added to the agent's system prompt on every launch, resumes
    /// included (picked on the New session screen). nil = none.
    var instructions: String?

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

    /// The session this one came from: its delegator, else the session its
    /// worktree branched off. The sidebar nests it there.
    static func origin(of s: AgentSession) -> UUID? { s.parentSessionID ?? s.worktreeOf }

    /// A filesystem/branch-safe slug from a free-form name — the same rule
    /// the kanban's worktrees use ("Login fix" → "login-fix", branch
    /// `wt/login-fix`).
    static func worktreeSlug(_ name: String) -> String {
        var out = ""
        var lastDash = false
        for ch in name.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch); lastDash = false
            } else if !lastDash {
                out.append("-"); lastDash = true
            }
        }
        let trimmed = String(out.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "worktree" : trimmed
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

    /// Whether `title` is one Bromure made up for `s` — the generic
    /// "<Agent> in <folder>", or its first request — rather than the agent's
    /// own name for the conversation or the user's.
    static func isPlaceholderTitle(_ title: String, of s: AgentSession, firstPrompt: String?) -> Bool {
        title.isEmpty || title == defaultTitle(tool: s.tool, cwd: s.cwd)
            || (firstPrompt.map { title == AgentSession.title(fromMessage: $0) || isCutPrompt(title, of: $0) } ?? false)
    }

    /// Whether `title` is just the start of `prompt`, cut short — what Kimi
    /// shows as its terminal title ("Count slowly from 1 to 30: for e").
    static func isCutPrompt(_ title: String, of prompt: String) -> Bool {
        var t = title.trimmingCharacters(in: .whitespaces)
        for mark in ["…", "..."] where t.hasSuffix(mark) { t = String(t.dropLast(mark.count)) }
        let p = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count >= 8 && t.count < p.count
            && p.lowercased().hasPrefix(t.lowercased().trimmingCharacters(in: .whitespaces))
    }

    /// The session's name from the title its agent shows (its terminal
    /// title): `SessionHome.cleanAgentTitle`, except that an agent echoing
    /// the opening request cut short gets the same first-request title
    /// every agent gets — one titling path, whatever the agent.
    static func title(fromAgent raw: String, of s: AgentSession, firstPrompt: String? = nil) -> String? {
        guard let t = SessionHome.cleanAgentTitle(raw, agent: s.tool.rawValue, cwd: s.cwd) else { return nil }
        let prompt = [s.openingMessage, firstPrompt].compactMap { $0 }.first { !$0.isEmpty }
        if let p = prompt, isCutPrompt(t, of: p) || isCutPrompt(raw, of: p) {
            return title(fromMessage: p)
        }
        return t
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
        // Once: sessions named by cutting their first message (before the
        // title rule) get a real title. Renamed ones are left alone.
        let key = "sessions.retitled.v1"
        if !UserDefaults.standard.bool(forKey: key) {
            UserDefaults.standard.set(true, forKey: key)
            if retitleFromOpeningMessages() > 0 { save() }
        }
    }

    /// Re-title sessions whose title is just their opening message cut
    /// short (never renamed by the user). Returns how many changed.
    @discardableResult
    func retitleFromOpeningMessages() -> Int {
        var n = 0
        for i in sessions.indices where sessions[i].userTitled != true {
            guard let msg = sessions[i].openingMessage, !msg.isEmpty else { continue }
            let title = sessions[i].title
            let bare = title.trimmingCharacters(in: CharacterSet(charactersIn: "….").union(.whitespaces))
            let first = msg.split(whereSeparator: \.isNewline).first.map(String.init) ?? msg
            guard bare.count >= 3, first.lowercased().hasPrefix(bare.lowercased()) else { continue }
            let better = AgentSession.title(fromMessage: msg)
            guard !better.isEmpty, better != title else { continue }
            sessions[i].title = better
            n += 1
        }
        return n
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

    /// Better names for sessions still called "<Agent> in <folder>": the
    /// agent's own title for the conversation (Claude generates one), else
    /// its first request. Never over a name the user gave, or one the agent
    /// chose; a first-request title gives way to the agent's once it exists.
    func adoptTranscriptTitles(_ ids: [UUID], lookup: (UUID) -> (agentTitle: String?, firstPrompt: String?)?) {
        for id in ids {
            guard let s = session(id), s.userTitled != true, let found = lookup(id) else { continue }
            guard AgentSession.isPlaceholderTitle(s.title, of: s, firstPrompt: found.firstPrompt) else { continue }
            let better = found.agentTitle
                ?? found.firstPrompt.map { AgentSession.title(fromMessage: $0) }
            guard let better, !better.isEmpty, better != s.title else { continue }
            mutate(id) { $0.title = better }
        }
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
    /// `reclaim`: take the name from the archived session holding it
    /// (the user said yes to `checkNickname`'s question).
    func setNickname(_ id: UUID, _ raw: String?, reclaim: Bool = false) -> String? {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else {
            return NSLocalizedString("Unknown session.", comment: "nickname")
        }
        guard let raw, let nick = DelegationNotice.normalizeNickname(raw) else {
            sessions[i].nickname = nil
            save()
            return nil
        }
        if let j = holder(of: nick, besides: id) {
            guard reclaim, sessions[j].isArchived else {
                switch checkNickname(id, raw) {
                case .refused(let why), .reclaim(let why): return why
                case .ok: return nil
                }
            }
            sessions[j].nickname = nil
        }
        sessions[i].nickname = nick
        save()
        return nil
    }

    enum NicknameVerdict: Equatable {
        case ok
        /// Another live session has it.
        case refused(String)
        /// An archived session has it: the question to put to the user.
        case reclaim(String)
    }

    /// Whether `id` may take `raw`, without taking it — the sheet asks
    /// before it sets (a fat client asks its mirror, so a refusal shows at
    /// once instead of the name silently not taking).
    func checkNickname(_ id: UUID, _ raw: String) -> NicknameVerdict {
        guard let nick = DelegationNotice.normalizeNickname(raw), let j = holder(of: nick, besides: id)
        else { return .ok }
        let other = sessions[j]
        guard other.isArchived else {
            return .refused(String(format: NSLocalizedString("@%@ is already “%@”.", comment: "nickname"), nick, other.title))
        }
        let when = DateFormatter.localizedString(from: other.lastSeenAt ?? other.createdAt,
                                                 dateStyle: .medium, timeStyle: .none)
        return .reclaim(String(format: NSLocalizedString(
            "@%@ was used by archived session “%@”, last on %@. Reuse it for this session?",
            comment: "nickname: taking it from an archived session"), nick, other.title, when))
    }

    private func holder(of nick: String, besides id: UUID) -> Int? {
        sessions.firstIndex { $0.id != id && !$0.isDeleted && $0.nickname?.lowercased() == nick.lowercased() }
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
    /// this one. False when the session is no longer bound here. A session
    /// being resumed is only unbound: the boot is the resume's own doing,
    /// and its relaunch is on the way — it never "finished".
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
        if !sessions[i].isLaunching { sessions[i].endedAt = now }
        sessions[i].agentAlive = nil
        save()
        return false
    }

    /// What the agent's transcript says about its turn (see
    /// `AgentSession.transcriptWorking`). Persisted only on change.
    func setTranscriptWorking(_ id: UUID, _ working: Bool?) {
        guard let i = sessions.firstIndex(where: { $0.id == id }),
              sessions[i].transcriptWorking != working else { return }
        sessions[i].transcriptWorking = working
        save()
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
                if !s.isLaunching { sessions[i].endedAt = now }   // a resume under way
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
                               let better = AgentSession.title(fromAgent: raw, of: s),
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
                            if !s.isLaunching { s.endedAt = now }   // a resume under way
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
                        if s.worktreeOf != nil || tab.isWorktree {
                            if let c = tab.cwd, !c.isEmpty { s.cwd = c }
                            if let b = tab.worktreeBranch, !b.isEmpty { s.worktreeBranch = b }
                            if let p = tab.parentBranch, !p.isEmpty { s.branchParent = p }
                            if let r = tab.rootRepo, !r.isEmpty { s.branchRoot = r }
                        }
                    } else if let since = s.launchingSince,
                              now.timeIntervalSince(since) > Self.launchTimeout {
                        s.launchingSince = nil
                        s.lastError = NSLocalizedString(
                            "The agent never showed up. The workspace may run an older in-VM agent — reboot it (Virtual Machines › ⋯ › Reboot) and try again.",
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
            s.transcriptWorking = nil
            // A title an earlier build took from the terminal with its
            // glyphs still on ("π ⁘ folder"): clean it, or fall back.
            if s.userTitled != true, s.title.hasPrefix("π") || s.title.hasPrefix("✳") {
                s.title = SessionHome.cleanAgentTitle(s.title, agent: s.tool.rawValue, cwd: s.cwd)
                    ?? s.openingMessage.flatMap { $0.isEmpty ? nil : AgentSession.title(fromMessage: $0) }
                    ?? AgentSession.defaultTitle(tool: s.tool, cwd: s.cwd)
            } else if s.userTitled != true, !s.title.hasSuffix("…") {
                // An agent suffix ("… - grok") or a folder cut short
                // ("run-this-exact-shell-...") an earlier build kept. A
                // title ending in "…" is our own first-request cut: kept.
                let tidy = AgentSession.title(fromAgent: s.title, of: s)
                    ?? s.openingMessage.flatMap { $0.isEmpty ? nil : AgentSession.title(fromMessage: $0) }
                if let tidy, tidy != s.title, s.title.hasSuffix("...") || tidy.count < s.title.count {
                    s.title = tidy
                }
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
        // Both pick up again with a message — one word for both, everywhere
        // (sidebar, room cells, the stage): a machine asleep or an agent that
        // stopped, the user's next message carries on.
        case .asleep, .ended: return NSLocalizedString("Paused", comment: "session bucket")
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

    // MARK: Branch sessions

    /// A session on a branch of its own (a git worktree).
    nonisolated static func isBranch(_ s: AgentSession) -> Bool {
        !(s.worktreeBranch ?? "").isEmpty
    }

    /// Archiving or deleting it asks what becomes of the branch: it's a
    /// branch session, and its work hasn't been merged.
    nonisolated static func branchNeedsWord(_ s: AgentSession) -> Bool {
        isBranch(s) && s.branchMerge?.phase != .merged
    }

    /// "3 commits · 5 uncommitted files · 2 behind", "no changes yet"; nil
    /// before the machine was first asked.
    nonisolated static func branchSummary(_ s: AgentSession) -> String? {
        guard let i = s.branchInfo else { return nil }
        if i.isEmpty { return NSLocalizedString("no changes yet", comment: "branch status") }
        var parts: [String] = []
        if i.ahead > 0 {
            parts.append(i.ahead == 1 ? NSLocalizedString("1 commit", comment: "branch status")
                         : String(format: NSLocalizedString("%d commits", comment: "branch status"), i.ahead))
        }
        if i.changed > 0 {
            parts.append(i.changed == 1 ? NSLocalizedString("1 uncommitted file", comment: "branch status")
                         : String(format: NSLocalizedString("%d uncommitted files", comment: "branch status"), i.changed))
        }
        if i.behind > 0 {
            parts.append(String(format: NSLocalizedString("%d behind", comment: "branch status"), i.behind))
        }
        return parts.joined(separator: " · ")
    }

    /// The session header's height: its strip, plus the merge-request
    /// banner while an agent's request waits for an answer.
    nonisolated static func headerHeight(_ s: AgentSession?, base: CGFloat) -> CGFloat {
        base + (s?.branchMerge?.phase == .requested ? 51 : 0)
    }

    /// Where a merge stands, in words — nil when none is under way or done.
    nonisolated static func mergeLine(_ s: AgentSession) -> String? {
        guard let m = s.branchMerge else { return nil }
        switch m.phase {
        case .requested: return String(format: NSLocalizedString("Asks to merge into %@", comment: "branch status"), m.target)
        case .merging:   return String(format: NSLocalizedString("Merging into %@…", comment: "branch status"), m.target)
        case .conflicts: return String(format: NSLocalizedString("Merging into %@ — the agent is finishing it", comment: "branch status"), m.target)
        case .merged:    return String(format: NSLocalizedString("Merged into %@", comment: "branch status"), m.target)
        case .failed:    return NSLocalizedString("Merge stalled", comment: "branch status")
        }
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
            // A merged branch's checkout was removed on purpose: say what happened.
            if let m = s.branchMerge, m.phase == .merged { return mergeLine(s) }
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

    /// The sessions in the order the sidebar shows them — each room's
    /// members first, then the loose ones by state with delegates under
    /// their delegator (finished ones, folded away, left out): what ⌘1–9
    /// number and ⌥⌘↑/↓ walk.
    @MainActor
    static func sidebarOrder(_ sessions: [AgentSession], rooms: [AgentRoom], in model: SessionListModel) -> [AgentSession] {
        let list = orderedAll(sessions, in: model)
        let live = rooms.filter { !$0.isArchived }
        let roomIDs = Set(live.map(\.id))
        var out: [AgentSession] = []
        for r in live { out += SessionSectionsView.nested(list.filter { $0.roomID == r.id }).map(\.session) }
        let loose = list.filter { $0.roomID.map { !roomIDs.contains($0) } ?? true }
        for b in SessionBucket.allCases where b != .ended {
            out += SessionSectionsView.nested(loose.filter { bucket(for: $0, in: model) == b }).map(\.session)
        }
        return out
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
        model.sessionEntry(profileID)?.model.rosterLive ?? false
    }

    /// The session's live tab, when its workspace is attached, its roster
    /// is real, and the tab is still there.
    @MainActor
    static func liveTab(for s: AgentSession, in model: SessionListModel) -> TabsModel.Tab? {
        guard let w = s.windowIndex,
              let entry = model.sessionEntry(s.profileID),
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

    /// A (re)launched agent the liveness probe hasn't judged yet — within a
    /// minute of the resume. "Starting…", whatever the tab's label says.
    static func isStartingUp(_ s: AgentSession, now: Date = Date()) -> Bool {
        guard s.agentAlive == nil, let resumed = s.resumedAt else { return false }
        return now.timeIntervalSince(resumed) < startingGrace
    }
    static let startingGrace: TimeInterval = 60

    @MainActor
    static func workspaceState(of s: AgentSession, in model: SessionListModel) -> SessionListModel.RunState {
        model.profileRows.first { $0.id == s.profileID }?.state ?? .off
    }

    @MainActor
    static func bucket(for s: AgentSession, in model: SessionListModel) -> SessionBucket {
        if isGone(s, in: model) { return .ended }
        #if os(macOS)
        if let demo = DemoMode.bucket(for: s.id) { return demo }   // manual screenshots
        #endif
        if s.isLaunching { return .working }
        if s.needsSignIn == true, !s.hasEnded, liveTab(for: s, in: model) != nil { return .needsYou }
        if s.hasEnded { return .ended }
        let ws = workspaceState(of: s, in: model)
        guard ws == .running || ws == .booting else { return .asleep }
        // Up, but tmux hasn't reported yet (a boot, a resume): still asleep
        // as far as the session can tell — not "Ended" for a few seconds.
        guard rosterLive(for: s.profileID, in: model) else { return .asleep }
        // The agent died starting (see `watchEarlyExit`): the user has to
        // look, not wait on a "working" that will never come.
        let failedStart = !(s.lastError ?? "").isEmpty
        guard let tab = liveTab(for: s, in: model) else {
            // Running workspace, tab not in the roster.
            return failedStart ? .needsYou : .ended
        }
        if !agentRunning(s, in: tab) {
            // A shell: the agent exited (resume) — or hasn't started yet.
            if failedStart { return .needsYou }
            return agentExited(s, in: model) ? .ended : .working
        }
        // Just relaunched, no probe verdict yet: still starting. The tab's
        // label flickers between the shell and the agent while it loads,
        // and reading Ready/Working off it flapped (Ready → Working → Ready).
        if isStartingUp(s) { return .working }
        switch tab.agentStatus {
        case .needsInput: return .needsYou
        case .working:    return .working
        // Its hooks say done, its transcript says a turn is running (Kimi).
        case .done:       return s.transcriptWorking == true ? .working : .idle
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
        let twins = among.filter { $0.id != s.id && $0.title == s.title && !$0.isDeleted }
        guard !twins.isEmpty else { return s.title }
        if let nick = s.nickname, !nick.isEmpty { return s.title + " · @" + nick }
        let folder = (s.cwd as NSString).lastPathComponent
        if !folder.isEmpty, folder != "~", folder != "ubuntu", !folderEchoesTitle(folder, s.title) {
            return s.title + " · " + folder
        }
        // The machine, when that's what differs; else when it started.
        if let ws = model.profileRows.first(where: { $0.id == s.profileID })?.name,
           !twins.allSatisfy({ $0.profileID == s.profileID }) {
            return s.title + " · " + ws
        }
        return s.title + " · " + s.createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// A folder made from the title ("hello-260920-1412" for "Hello") says
    /// nothing the title doesn't.
    static func folderEchoesTitle(_ folder: String, _ title: String) -> Bool {
        func squash(_ s: String) -> String { s.lowercased().filter { $0.isLetter } }
        let f = squash(folder), t = squash(title)
        guard !f.isEmpty, !t.isEmpty else { return false }
        return f.hasPrefix(String(t.prefix(12))) || t.hasPrefix(f)
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
            if let tab = liveTab(for: s, in: model), !agentRunning(s, in: tab) || isStartingUp(s) {
                return NSLocalizedString("Starting…", comment: "session status")
            }
            return NSLocalizedString("Working…", comment: "session status")
        case .idle:
            return NSLocalizedString("Ready", comment: "session status")
        case .asleep:
            // A workspace on its way up (booting, or attached with tmux not
            // yet heard from) is waking, not asleep.
            let ws = workspaceState(of: s, in: model)
            let attached = model.sessionEntry(s.profileID) != nil
            if ws == .booting || (ws == .running && attached) {
                return NSLocalizedString("Waking up…", comment: "session status")
            }
            return NSLocalizedString("Paused", comment: "session status")
        case .ended:
            // Resumable (a gone one said why above): paused, like a machine
            // asleep — "Finished" read as "can't go on".
            return s.isArchived
                ? NSLocalizedString("Archived", comment: "session status")
                : NSLocalizedString("Paused", comment: "session status")
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
        let agentNames: Set<String> = [agent, "claude code", "codex", "kimi code", "oh my pi", "omp", "grok", "grok build", "bash", "shell", "tmux"]
        if agentNames.contains(lower) { return nil }
        // The agent's name tacked on ("… - grok", "codex · resume"): a
        // title of the conversation never carries the program's name.
        for name in agentNames {
            for sep in [" - ", " – ", " — ", " | ", " · "] {
                if lower.hasSuffix(sep + name) { t = String(t.dropLast(sep.count + name.count)) }
                if lower.hasPrefix(name + sep) { return nil }   // "claude · resume": a launch, not a title
            }
        }
        t = t.trimmingCharacters(in: .whitespaces)
        // Cut by the agent ("Countin…", "run-this-exact-shell-..."): end on
        // a whole word.
        var truncated = false
        for mark in ["…", "..."] where t.hasSuffix(mark) {
            t = String(t.dropLast(mark.count)).trimmingCharacters(in: .whitespaces)
            truncated = true
        }
        guard !t.isEmpty else { return nil }
        if let cwd, !cwd.isEmpty {
            let folder = (SessionHome.guestPath(cwd) as NSString).lastPathComponent.lowercased()
            // The folder's name, whole or cut short (Codex shows its first
            // 20 characters): a place, not a title.
            if t.lowercased() == folder || (truncated && folder.hasPrefix(t.lowercased())) { return nil }
        }
        if truncated { return wordCut(t, limit: t.count, cutPartialWord: true) }
        return t.count > 60 ? wordCut(t, limit: 60) : t
    }

    /// `text` cut to at most `limit` characters on a word boundary, with
    /// "…". `cutPartialWord`: the text was already cut mid-word by someone
    /// else — drop its last (partial) word even when it fits.
    static func wordCut(_ text: String, limit: Int, cutPartialWord: Bool = false) -> String {
        var cut = String(text.prefix(limit))
        if cutPartialWord || text.count > limit,
           let sp = cut.lastIndex(where: { $0 == " " }),
           cut.distance(from: cut.startIndex, to: sp) >= 12 {
            cut = String(cut[..<sp])
        }
        let trimmed = cut.trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",;:-–—"))
            .trimmingCharacters(in: .whitespaces)
        return trimmed + "…"
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
        guard model.switchboardAvailable else { return false }
        // B20: steady, not by live count — it used to pop in when a second
        // session went live, pushing the whole list down mid-click. Shown
        // once there is any session to keep track of (or a Switchboard).
        if switchboard(in: sessions) != nil { return true }
        return sessions.contains { !$0.isSwitchboard && !$0.isArchived && !$0.isDeleted }
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
///
/// Two writers feed it: the beautified view (the history it holds, every
/// few seconds) and the engine's snapshot (what the file gained since the
/// last one). Neither may ever make the copy SHORTER: what comes in is cut
/// to whole JSONL records (a byte-capped read starts mid-line), stripped of
/// image payloads (a browser screenshot is ~0.5 MB of base64 per record —
/// one used to push the whole conversation out of a 300 KB window), and
/// MERGED record by record into what's held. Nothing held is ever dropped.
/// Work happens on a serial queue off the main thread; `load` waits for it.
final class SessionTranscriptCache: @unchecked Sendable {
    private let dir: URL
    /// One queue for every instance: the engine's copy and a view's reader
    /// see each other's writes in order.
    private static let queue = DispatchQueue(label: "io.bromure.ac.transcript-cache", qos: .utility)
    /// The app's copy (the engine's, and what launch screens read back).
    static let shared = SessionTranscriptCache()

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

    /// Merge `data` (a transcript, whole or a window of it) into the copy.
    /// Records it shares with the copy anchor it; a window that shares none
    /// is added only when it reads as the conversation's continuation (its
    /// records are no older than the copy's last) — another conversation's
    /// tail must not land in this one.
    func save(_ id: UUID, _ data: Data) { write(id, data, mode: .related) }

    /// `data` is known to continue the copy (the engine read the same file
    /// on from where it left off): add what's new, no age check.
    func append(_ id: UUID, _ data: Data) { write(id, data, mode: .continuation) }

    func load(_ id: UUID) -> Data? {
        let u = url(id)
        return Self.queue.sync { try? Data(contentsOf: u) }
    }

    /// The app's copy of `id`, read off the main thread (a chat's seed).
    static func loadDetached(_ id: UUID) async -> Data? {
        await Task.detached(priority: .userInitiated) { shared.load(id) }.value
    }

    func remove(_ id: UUID) {
        let u = url(id)
        Self.queue.async { [weak self] in
            try? FileManager.default.removeItem(at: u)
            self?.rawMemo[id] = nil
        }
    }

    /// Wait for the writes queued so far (tests).
    func flush() { Self.queue.sync {} }

    /// What the last save of `id` was handed, raw: the view hands the same
    /// growing buffer every few seconds, so only what it gained since needs
    /// cutting into records (and its images stripped). Queue-confined.
    private struct RawMemo { var count: Int; var head: Data; var tail: Data }
    private var rawMemo: [UUID: RawMemo] = [:]

    private func write(_ id: UUID, _ data: Data, mode: MergeMode) {
        guard !data.isEmpty else { return }
        let u = url(id)
        let dir = self.dir
        Self.queue.async { [weak self] in
            guard let self else { return }
            // The same buffer as last time, grown: only the growth is new.
            var incoming = data
            let tracked = mode == .related
            var mode = mode
            if tracked, let m = self.rawMemo[id], data.count >= m.count, m.count > 0,
               data.prefix(m.head.count) == m.head,
               data[data.startIndex + m.count - m.tail.count ..< data.startIndex + m.count] == m.tail {
                if data.count == m.count { return }
                let rest = data[(data.startIndex + m.count)...]
                // Only when the old buffer ended on a record boundary.
                if m.tail.last == 0x0A { incoming = Data(rest); mode = .continuation }
            }
            let old = try? Data(contentsOf: u)
            guard let merged = Self.merge(history: old ?? Data(), incoming: incoming, mode: mode) else {
                // Refused (or nothing in it): its growth must not pass as a
                // continuation next time either.
                if tracked { self.rawMemo[id] = nil }
                return
            }
            if tracked {
                self.rawMemo[id] = RawMemo(count: data.count, head: Data(data.prefix(64)),
                                           tail: Data(data.suffix(64)))
            }
            if let old, old == merged { return }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? merged.write(to: u, options: .atomic)
            var v = u
            var rv = URLResourceValues()
            rv.isExcludedFromBackup = true
            try? v.setResourceValues(rv)
        }
    }

    // MARK: Records

    enum MergeMode: Equatable {
        /// `incoming` continues the history: new records are appended.
        case continuation
        /// Related by content: anchored on shared records; with none shared,
        /// appended only when no older than the history's end.
        case related
        /// Only merged when it shares a record with the history (a read of
        /// "the newest file in the folder", which may be another session's).
        case overlapOnly
    }

    /// `history` with `incoming`'s new records merged in, both cut to whole,
    /// image-stripped records. Never loses a record of `history`. nil when
    /// `incoming` holds no record or was refused (see `MergeMode`).
    static func merge(history: Data, incoming: Data, mode: MergeMode) -> Data? {
        let new = records(incoming)
        guard !new.isEmpty else { return nil }
        let old = records(history)
        if old.isEmpty { return join(new) }
        // Another Kimi journal — a start record the copy doesn't hold — is
        // a different conversation, whatever it shares with the copy (its
        // tool-discovery lines carry no time and repeat byte for byte in
        // every session, so they "anchored" one conversation into another).
        // Never spliced in by a related/overlap read (B72); a session that
        // really starts a new conversation hands it over as a continuation
        // (the engine, on pinning it).
        if mode != .continuation, let started = kimiJournalStarts(old),
           let incoming = kimiJournalStarts(new), !incoming.isSubset(of: started) {
            return nil
        }
        let keysOld = old.map(key)
        var posOld: [RecordKey: Int] = [:]
        for (i, k) in keysOld.enumerated() where posOld[k] == nil { posOld[k] = i }
        // Unseen records go after the last shared one before them (after
        // the whole copy, past the last shared one); those in front of the
        // first shared one go before it (a "load earlier" window reaches
        // further back than the copy).
        var before: [Int: [Data]] = [:]
        var after: [Int: [Data]] = [:]
        var leading: [Data] = []
        var anchor: Int?
        var seen = Set<RecordKey>()
        for r in new {
            let k = key(r)
            guard seen.insert(k).inserted else { continue }
            if let p = posOld[k] {
                if anchor == nil, !leading.isEmpty { before[p, default: []] += leading; leading = [] }
                anchor = p
            } else if let a = anchor {
                after[a, default: []].append(r)
            } else {
                leading.append(r)
            }
        }
        var tailAppend: [Data] = []
        // What follows the last shared record is the newest: after
        // everything held, not wedged in front of records the read didn't
        // carry.
        if let a = anchor { tailAppend = after.removeValue(forKey: a) ?? [] }
        if anchor == nil, !leading.isEmpty {
            // Nothing in common.
            switch mode {
            case .overlapOnly:
                return nil
            case .related:
                if let tNew = firstTimestamp(leading), let tOld = lastTimestamp(old), tNew < tOld {
                    return nil
                }

            case .continuation:
                break
            }
            tailAppend = leading
        }
        var out: [Data] = []
        out.reserveCapacity(old.count + new.count)
        for (i, r) in old.enumerated() {
            if let b = before[i] { out += b }
            out.append(r)
            if let a = after[i] { out += a }
        }
        out += tailAppend
        return join(out)
    }

    /// Records are told apart by Claude's `uuid` when they carry one, else
    /// by their bytes (other agents' files are append-only too).
    enum RecordKey: Hashable { case uuid(String), line(Data) }

    private static let uuidMarker = Data("\"uuid\":\"".utf8)
    static func key(_ r: Data) -> RecordKey {
        if let m = r.range(of: uuidMarker), let end = r[m.upperBound...].firstIndex(of: 0x22),
           end > m.upperBound, end - m.upperBound <= 64 {
            return .uuid(String(decoding: r[m.upperBound..<end], as: UTF8.self))
        }
        return .line(r)
    }

    private static func join(_ rs: [Data]) -> Data {
        var out = Data()
        out.reserveCapacity(rs.reduce(0) { $0 + $1.count + 1 })
        for r in rs { out.append(r); out.append(0x0A) }
        return out
    }

    /// Lines longer than this are parsed for image payloads; base64 strings
    /// longer than `imageStringThreshold` are replaced.
    static let lineScanThreshold = 8_192
    static let imageStringThreshold = 4_096
    /// What an image stripped from a tool result reads as in the chat.
    static let imagePlaceholder = "[image omitted]"

    /// `data` as whole JSONL records: a first line that isn't a whole JSON
    /// object (a read that began mid-record) is dropped, so is an unfinished
    /// last one; image payloads are stripped.
    static func records(_ data: Data) -> [Data] {
        var lines: [Data] = []
        var start = data.startIndex
        while start < data.endIndex {
            let nl = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[start..<nl]
            if line.contains(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D }) {
                lines.append(Data(line))
            }
            start = nl < data.endIndex ? data.index(after: nl) : data.endIndex
        }
        let endsWhole = data.last == 0x0A
        var out: [Data] = []
        out.reserveCapacity(lines.count)
        for (i, line) in lines.enumerated() {
            let edge = i == 0 || (i == lines.count - 1 && !endsWhole)
            if line.count > lineScanThreshold || edge {
                switch stripped(line) {
                case .some(let s): out.append(s)
                case .none: if !edge { out.append(line) }   // not JSON: a cut record at an edge goes
                }
            } else {
                out.append(line)
            }
        }
        return out
    }

    /// The record with its image payloads replaced, the record itself when
    /// it has none, nil when it isn't a whole JSON object.
    static func stripped(_ line: Data) -> Data? {
        let trimmed = line.drop { $0 == 0x20 || $0 == 0x09 }
        guard trimmed.first == UInt8(ascii: "{"),
              let obj = try? JSONSerialization.jsonObject(with: Data(trimmed)) as? [String: Any]
        else { return nil }
        guard line.count > lineScanThreshold else { return line }
        var changed = false
        let out = strip(obj, inToolResult: false, changed: &changed)
        guard changed, JSONSerialization.isValidJSONObject(out),
              let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return line }
        return data
    }

    private static func strip(_ v: Any, inToolResult: Bool, changed: inout Bool) -> Any {
        if let d = v as? [String: Any] {
            // Claude's image block: {"type":"image","source":{"type":"base64","data":…}}.
            if d["type"] as? String == "image", let src = d["source"] as? [String: Any],
               let b64 = src["data"] as? String, b64.utf8.count > imageStringThreshold {
                changed = true
                if inToolResult { return ["type": "text", "text": imagePlaceholder] }
                var s = src
                s["data"] = ""
                var o = d
                o["source"] = s
                o["omitted"] = true
                return o
            }
            let isResult = d["type"] as? String == "tool_result"
            var o: [String: Any] = [:]
            for (k, x) in d {
                o[k] = strip(x, inToolResult: inToolResult || (isResult && k == "content"), changed: &changed)
            }
            return o
        }
        if let a = v as? [Any] {
            return a.map { strip($0, inToolResult: inToolResult, changed: &changed) }
        }
        if let s = v as? String, s.utf8.count > imageStringThreshold, looksBase64(s) {
            changed = true
            return imagePlaceholder
        }
        return v
    }

    /// Base64 (optionally a `data:…;base64,` URL): no spaces, nothing but
    /// the alphabet in its first few hundred characters.
    static func looksBase64(_ s: String) -> Bool {
        var u = Substring(s)
        if u.hasPrefix("data:"), let comma = u.firstIndex(of: ","), u[..<comma].hasSuffix(";base64") {
            u = u[u.index(after: comma)...]
        }
        var n = 0
        for c in u.utf8.prefix(512) {
            let ok = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57)
                || c == 43 || c == 47 || c == 61 || c == 45 || c == 95
            if !ok { return false }
            n += 1
        }
        return n >= 64
    }

    private static func timestamp(_ r: Data) -> Date? {
        if r.range(of: Data("\"timestamp\"".utf8)) != nil,
           let obj = try? JSONSerialization.jsonObject(with: r) as? [String: Any],
           let t = obj["timestamp"] as? String {
            return isoFractional.date(from: t) ?? isoPlain.date(from: t)
        }
        // Kimi's journal: epoch milliseconds, `time` on each op and
        // `created_at` on its start record.
        guard r.range(of: Data("\"time\"".utf8)) != nil || r.range(of: Data("\"created_at\"".utf8)) != nil,
              let obj = try? JSONSerialization.jsonObject(with: r) as? [String: Any],
              let ms = (obj["time"] as? NSNumber) ?? (obj["created_at"] as? NSNumber),
              ms.doubleValue > 1e12 else { return nil }
        return Date(timeIntervalSince1970: ms.doubleValue / 1000)
    }

    private static let kimiStartMarker = Data("\"type\":\"metadata\"".utf8)
    /// The start records (`created_at`, ms) of the Kimi journals in `rs` —
    /// one per conversation; nil when `rs` holds none.
    static func kimiJournalStarts(_ rs: [Data]) -> Set<Int64>? {
        var out = Set<Int64>()
        for r in rs where r.count < 4096 && r.range(of: kimiStartMarker) != nil {
            guard let obj = try? JSONSerialization.jsonObject(with: r) as? [String: Any],
                  obj["type"] as? String == "metadata", obj["protocol_version"] != nil,
                  let at = obj["created_at"] as? NSNumber else { continue }
            out.insert(at.int64Value)
        }
        return out.isEmpty ? nil : out
    }
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()
    private static func firstTimestamp(_ rs: [Data]) -> Date? {
        for r in rs.prefix(50) { if let t = timestamp(r) { return t } }
        return nil
    }
    private static func lastTimestamp(_ rs: [Data]) -> Date? {
        for r in rs.reversed().prefix(50) { if let t = timestamp(r) { return t } }
        return nil
    }
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

/// A native machine: a plain Mac attached to this app (Bromure Agent Host)
/// whose agents run directly on it — no VM, no sandbox, none of the
/// isolation the virtual machines give. Everything it hosts carries this
/// cue, so an unsandboxed agent is never mistaken for a sandboxed one.
enum NativeMachine {
    static let sectionTitle = NSLocalizedString("Native Machines", comment: "sidebar section")
    static let sectionNarrowTitle = NSLocalizedString("Native", comment: "sidebar section, when narrow")
    static let notSandboxed = NSLocalizedString("Not sandboxed", comment: "native machine")
    static func help(_ machine: String) -> String {
        String(format: NSLocalizedString("Runs natively on %@ — not in a sandboxed VM. Its agents can reach everything on that Mac.",
                                         comment: "native machine"), machine)
    }
    static let tint = Color.orange
}

/// The cue itself: a small shield with a slash.
struct NativeMachineBadge: View {
    var size: CGFloat = 10
    var body: some View {
        Image(systemName: "shield.slash.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(NativeMachine.tint)
    }
}

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
    /// ⌘ held: its ⌘1–9 number, in place of the time.
    var shortcut: Int? = nil
    /// Found by what was said: the words around the match, instead of the status.
    var snippet: String? = nil
    /// The last reply, shown on hover.
    var preview: String? = nil
    /// Runs on a native machine (not sandboxed): its ring is dashed orange,
    /// with the badge.
    var native = false
    @State private var hovering = false

    private var mergeTint: Color? {
        switch session.branchMerge?.phase {
        case .requested?: return .orange
        case .merging?: return .accentColor
        case .conflicts?: return .orange
        case .merged?: return .green
        case .failed?: return .red
        case nil: return nil
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            // The machine is the ring's colour (its name in the tooltip):
            // the row's width goes to the title, not to a repeated name.
            // The status dot sits on top of the ring, not under it.
            ZStack(alignment: .bottomTrailing) {
                AgentAvatar(tool: session.tool, size: 28)
                    .padding(2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(native ? NativeMachine.tint
                                          : workspaceName.isEmpty ? Color.clear : Color(hex: accentHex).opacity(0.85),
                                          style: StrokeStyle(lineWidth: 1.5, dash: native ? [3, 2] : [])))
                if let dot {
                    AgentStatusDot(status: dot).scaleEffect(1.25)
                }
            }
            .overlay(alignment: .topLeading) {
                if native {
                    NativeMachineBadge(size: 9)
                        .padding(1.5)
                        .background(Circle().fill(Color.acSidebar))
                        .offset(x: -4, y: -4)
                }
            }
            .opacity(session.hasEnded ? 0.6 : 1)
            .help(native ? NativeMachine.help(workspaceName) : workspaceName)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title ?? session.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .medium))
                        .foregroundStyle(session.hasEnded && !selected ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if let shortcut {
                        Text("⌘\(shortcut)")
                            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.12)))
                    } else if let when {
                        Text(when)
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 5) {
                    if let nick = session.nickname, !nick.isEmpty {
                        Text("@" + nick)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.accentColor)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                    if let snippet {
                        Text(snippet)
                            .italic()
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else if SessionHome.isBranch(session) {
                        // A branch: its glyph, and where its work stands
                        // (a merge under way says so, in its colour).
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(mergeTint ?? Color.secondary)
                        if let merge = SessionHome.mergeLine(session) {
                            Text(merge)
                                .foregroundStyle(mergeTint ?? Color.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        } else {
                            Text([statusLine, SessionHome.branchSummary(session)].compactMap { $0 }
                                    .joined(separator: " · "))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    } else {
                        Text(statusLine)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
            .help(preview ?? "")
        }
        .padding(.leading, 8 + CGFloat(min(depth, 3)) * 16)
        .padding(.trailing, 10)
        .frame(height: 48)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.16)
                               : (hovering ? Color.primary.opacity(0.05) : .clear)))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.35) : .clear, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .opacity(gone ? 0.5 : 1)
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
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
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(tint.gradient)
                    .frame(width: 30, height: 30)
                    .overlay(Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white))
                    .shadow(color: tint.opacity(0.35), radius: 3, y: 1)
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
        .frame(height: 48)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(selected ? tint.opacity(0.16)
                           : (hovering ? Color.primary.opacity(0.05) : .clear)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
            .strokeBorder(dropTargeted ? tint : (selected ? tint.opacity(0.35) : .clear),
                          lineWidth: dropTargeted ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
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
    /// Sessions whose conversation mentions the search, with the words around it.
    var contentSearch: (String) -> [UUID: String] = { _ in [:] }
    /// A session's last reply, for its row's tooltip.
    var lastReply: (UUID) -> String? = { _ in nil }
    @AppStorage("sessions.listExpanded") private var expanded = true
    /// Rooms folded in the sidebar (their members hidden) — remembered
    /// across launches, on this Mac and in a fat client alike (room ids are
    /// unique across machines).
    @AppStorage("sessions.foldedRooms") private var foldedRoomsRaw = ""
    private var foldedRooms: Set<UUID> {
        Set(foldedRoomsRaw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }
    private func toggleFold(_ id: UUID) {
        var s = foldedRooms
        if s.contains(id) { s.remove(id) } else { s.insert(id) }
        foldedRoomsRaw = s.map(\.uuidString).sorted().joined(separator: ",")
    }
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
    /// Opened for a moment because the selection went into it (not saved:
    /// the fold stays closed next time).
    @State private var archivedRevealed = false
    /// The Ended group, folded unless opened (or searched).
    @AppStorage("sessions.endedExpanded") private var endedExpanded = false
    /// The session a "New worktree…" sheet is open for.
    @State private var worktreeFor: AgentSession?
    /// The session a "Nickname…" sheet is open for.
    @State private var nicknameFor: AgentSession?

    /// ⌘1–9, by session (what the shortcuts jump to).
    private var shortcutNumbers: [UUID: Int] {
        var out: [UUID: Int] = [:]
        for (i, s) in SessionHome.sidebarOrder(store.sessions, rooms: rooms, in: model).prefix(9).enumerated() { out[s.id] = i + 1 }
        return out
    }

    /// Sessions found by what was said in them (not their name), with the words.
    private var contentHits: [UUID: String] {
        let q = filter.trimmingCharacters(in: .whitespaces)
        return q.count >= 3 ? contentSearch(q) : [:]
    }

    private var matching: [AgentSession] {
        var sessions = store.sessions
        let q = filter.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            let bare = q.hasPrefix("@") ? String(q.dropFirst()) : q
            let hits = contentHits
            sessions = sessions.filter {
                $0.title.localizedCaseInsensitiveContains(q)
                    || ($0.openingMessage ?? "").localizedCaseInsensitiveContains(q)
                    || $0.cwd.localizedCaseInsensitiveContains(q)
                    || (!bare.isEmpty && ($0.nickname ?? "").localizedCaseInsensitiveContains(bare))
                    || hits[$0.id] != nil
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
                // Paused is one group: the sessions whose machine sleeps show,
                // the ones whose agent stopped fold away behind its caret.
                ForEach(SessionBucket.allCases.filter { $0 != .ended }) { bucket in
                    let group = loose.filter { SessionHome.bucket(for: $0, in: model) == bucket }
                    let stopped = bucket == .asleep
                        ? loose.filter { SessionHome.bucket(for: $0, in: model) == .ended } : []
                    if !group.isEmpty || !stopped.isEmpty {
                        let folded = !stopped.isEmpty && !endedExpanded && filter.isEmpty
                        SessionGroupHeader(bucket: bucket, count: group.count + stopped.count,
                                           foldable: !stopped.isEmpty, folded: folded) {
                            withAnimation(.easeInOut(duration: 0.15)) { endedExpanded.toggle() }
                        }
                        ForEach(Self.nested(folded ? group : group + stopped), id: \.session.id) {
                            row($0.session, depth: $0.depth)
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
                let openArchived = archivedExpanded || archivedRevealed || !filter.isEmpty
                SidebarSectionHeader(title: NSLocalizedString("Archived", comment: "sidebar section"),
                                     expanded: openArchived,
                                     count: put.count + putRooms.count,
                                     help: NSLocalizedString("Conversations you put away — still readable, back with one message", comment: "sidebar"),
                                     onTitle: { withAnimation(.easeInOut(duration: 0.15)) {
                                         if archivedRevealed { archivedRevealed = false; archivedExpanded = false }
                                         else { archivedExpanded.toggle() }
                                     } })
                if openArchived {
                    ForEach(putRooms) { roomBlock($0, SessionHome.archived(matching)) }
                    let orphans = put.filter { SessionHome.isGone($0, in: model) }
                    ForEach(put.filter { !SessionHome.isGone($0, in: model) }) { row($0) }
                    if !orphans.isEmpty { orphanCleanup(orphans) }
                }
            }
        }
        .onAppear { revealSelectedArchived(model.selectedSessionID) }
        .onChange(of: model.selectedSessionID) { _, id in revealSelectedArchived(id) }
        .sheet(item: $nicknameFor) { s in
            NicknameSheet(session: s, check: { actions.checkNickname(s.id, $0) }) { actions.setNickname(s.id, $0, $1) }
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
            NewWorktreeSheet(parent: parent, gitState: actions.gitState) { req in
                actions.newWorktree(parent.id, req)
            }
        }
    }

    /// The selection just landed on an archived session: open the fold so
    /// its row is on screen. One-shot — folding it back by hand sticks
    /// until the selection moves into the fold again.
    private func revealSelectedArchived(_ id: UUID?) {
        guard let id, let s = store.session(id), s.isArchived, !s.isDeleted else {
            // The selection left the fold: it closes again if it was only revealed.
            if archivedRevealed { withAnimation(.easeInOut(duration: 0.15)) { archivedRevealed = false } }
            return
        }
        guard !archivedExpanded else { return }
        withAnimation(.easeInOut(duration: 0.15)) { archivedRevealed = true }
    }

    /// Sessions whose machine or folder is gone: nothing to reopen them on. One line
    /// offers to clear them instead of a column of ghosts.
    private func orphanCleanup(_ orphans: [AgentSession]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "trash")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(orphans.count == 1
                 ? NSLocalizedString("1 session whose machine or folder is gone", comment: "sidebar cleanup")
                 : String(format: NSLocalizedString("%d sessions whose machine or folder is gone", comment: "sidebar cleanup"), orphans.count))
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button(NSLocalizedString("Delete", comment: "sidebar cleanup")) {
                for o in orphans { actions.delete(o.id) }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11.5, weight: .medium))
            .help(NSLocalizedString("Their machines are gone — delete these conversations", comment: "sidebar cleanup"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    static func origin(of s: AgentSession) -> UUID? { AgentSession.origin(of: s) }

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
            for c in list where Self.origin(of: c) == s.id { walk(c, depth + 1) }
        }
        for s in list where Self.origin(of: s).map({ !ids.contains($0) }) ?? true { walk(s, 0) }
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
            onSelect: {
                onSelect(s.id)
                // Found by its words: the chat scrolls to them.
                if contentHits[s.id] != nil, !s.title.localizedCaseInsensitiveContains(filter) {
                    let q = filter
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        NotificationCenter.default.post(name: .bromureFindInChat, object: q)
                    }
                }
            },
            title: SessionHome.distinctTitle(s, among: store.sessions, in: model),
            shortcut: model.commandHeld ? shortcutNumbers[s.id] : nil,
            snippet: filter.isEmpty || s.title.localizedCaseInsensitiveContains(filter) ? nil : contentHits[s.id],
            preview: lastReply(s.id),
            native: model.machineIDs.contains(s.profileID))
        .overlay {
            if dropSession == s.id {
                RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2)
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
                    Button(NSLocalizedString("New Branch…", comment: "session menu")) { worktreeFor = s }
                }
                if SessionHome.isBranch(s) {
                    BranchMenuItems(session: s, actions: actions)
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
                    toggleFold(r.id)
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
