#if os(macOS)
import AppKit
import Foundation

// MARK: - Agent session engine (macOS)
//
// Starts, resumes and closes agent sessions on the workspaces' VMs. The user
// never sees any of this: "start" boots the workspace when it's asleep,
// clones a repository when asked, and opens an interactive agent tab in the
// chosen folder through the guest's `agent-tab` action; "resume" reopens the
// agent's last conversation in the same folder (in the old tab when it's
// still there, else in a fresh one).

extension Profile.Tool {
    /// CLI flags that reopen the agent's most recent conversation in the
    /// current folder. Empty = the tool has no resume mode we know of; a
    /// plain relaunch starts fresh there.
    var resumeFlags: String {
        switch self {
        case .claude: return "--continue"
        case .codex:  return "resume --last"
        case .kimi:   return "-c"
        case .omp:    return "--continue"
        case .grok:   return ""
        }
    }
}

@MainActor
final class AgentSessionEngine {
    weak var delegate: ACAppDelegate?
    let store: AgentSessionStore

    private var pendingBoots: Set<UUID> = []
    private static let bootTimeout: TimeInterval = 180
    private static let bootPollInterval: UInt64 = 3_000_000_000

    init(store: AgentSessionStore, delegate: ACAppDelegate?) {
        self.store = store
        self.delegate = delegate
        // A session that leaves the store takes its transcript copy along.
        store.onRemove = { [weak self] id in self?.transcripts.remove(id) }
        // A merge that was being followed when the app quit.
        DispatchQueue.main.async { [weak self] in self?.resumeMergeWatches() }
    }

    // Worktree sessions (SessionBranches.swift).
    var branchProbing: Set<UUID> = []
    var branchProbeAt: [UUID: Date] = [:]
    var mergeWatching: Set<UUID> = []
    /// Sessions to `git init` their folder for before branching.
    var initGitBeforeBranching: Set<UUID> = []
    /// Branch sessions asked to start from another branch than the
    /// folder's current one: session → base branch (read once at launch).
    var worktreeBase: [UUID: String] = [:]

    /// The platform-neutral request lives with the model (AgentSessions.swift)
    /// so the shared new-session screen can build one on every platform.
    typealias NewSessionRequest = AgentSessionRequest

    /// Create the session record and launch it. The record is on screen
    /// immediately (the chat surface with the opening message); the tab
    /// binds to it as soon as the workspace reports it.
    /// `remotely`: a fat client asked (over the control socket) — the boot
    /// this may need routes its decision prompts to that client.
    @discardableResult
    func start(_ req: NewSessionRequest, remotely: Bool = false) -> UUID {
        let message = req.openingMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        var cwd = req.cwd.trimmingCharacters(in: .whitespaces)
        // No folder named: every session gets a fresh one of its own in the
        // home, named after the title when there is one (a delegate's brief
        // opens with boilerplate), else the message — never the shared home
        // itself.
        if cwd.isEmpty || cwd == "~" || cwd == "~/" {
            let named = req.title?.trimmingCharacters(in: .whitespaces).nonEmpty
            // Two blank sessions in the same minute got the same folder
            // ("claude-260928-1830"): one chat then read the other's
            // transcript (a fresh agent isn't pinned to its own until its
            // first prompt), and a wake-up's --continue resumed it for real.
            let base = "~/" + Self.syntheticFolderName(message: named ?? message, tool: req.tool)
            let taken = Set(store.sessions.filter { $0.profileID == req.profileID && !$0.isDeleted }.map(\.cwd))
            cwd = base
            var n = 2
            while taken.contains(cwd) { cwd = "\(base)-\(n)"; n += 1 }
        }
        let title = req.title?.trimmingCharacters(in: .whitespaces).nonEmpty
            ?? (message?.nonEmpty).map(AgentSession.title(fromMessage:))
            ?? AgentSession.defaultTitle(tool: req.tool, cwd: cwd)
        var s = AgentSession(profileID: req.profileID, tool: req.tool, title: title,
                             cwd: cwd, cloneURL: req.cloneURL?.nonEmpty,
                             openingMessage: message?.nonEmpty)
        s.role = req.role
        s.roomID = req.roomID
        s.instructions = req.instructions?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        s.launchingSince = Date()
        store.upsert(s)
        BACDebug.log("sessions", "start “\(title)” (\(req.tool.rawValue) in \(cwd))"
                     + (s.instructions == nil ? "" : " with instructions"))
        // Grok has no way to take them for an interactive session: they open
        // its first message instead (the session's own message stays clean).
        var prompt = message ?? ""
        if req.tool == .grok, let text = s.instructions {
            prompt = Self.openingWithInstructions(text, message: prompt)
        }
        launch(s.id, prompt: prompt, flags: "", attachments: req.attachments, remotely: remotely)
        return s.id
    }

    /// Stage the files dropped on the new-session composer in the machine
    /// (same folder and naming as a drop in the chat, so the chat shows their
    /// thumbnails), and give back their guest paths. Best effort: a file that
    /// fails to land is left out, the rest still reach the agent.
    private func stageAttachments(_ files: [DroppedFile], sessionID: UUID,
                                  profileID: UUID, delegate: ACAppDelegate) async -> [String] {
        guard !files.isEmpty else { return [] }
        func op(_ dict: [String: Any]) async -> Bool {
            (try? await delegate.guestFileOp(profileID: profileID, op: dict, timeout: 60)) != nil
        }
        guard await op(["op": "mkdir", "path": GuestDrop.baseDir]) else { return [] }
        let stamp = GuestDrop.stamp()
        var paths: [String] = []
        for (i, f) in files.enumerated() {
            let path = GuestDrop.path(index: i, name: "\(stamp)_\(f.name)")
            // A folder: its contents at `path` (see `FolderUpload`).
            if f.folder != nil || f.packedFolder {
                let fileOp: FolderUpload.FileOp = { try await delegate.guestFileOp(profileID: profileID, op: $0, timeout: 600) }
                do {
                    if let folder = f.folder { try await FolderUpload.upload(folder, into: path, op: fileOp) }
                    else { try await FolderUpload.unpack(f.data, into: path, op: fileOp) }
                    paths.append(path)
                } catch {
                    BACDebug.log("sessions", "folder attachment \(f.name) failed: \(error)")
                }
                continue
            }
            var ok = true
            for w in GuestDrop.writeOps(guestPath: path, data: f.data) where !(await op(w)) { ok = false; break }
            guard ok else { continue }
            if f.isImage { DropImageStore.store(f.data, for: path) }
            paths.append(path)
        }
        BACDebug.log("sessions", "staged \(paths.count)/\(files.count) attachment(s) for \(sessionID)")
        return paths
    }

    /// A new session in a git worktree branched off `parentID`'s folder at
    /// its current commit: the record is on screen at once (launching), the
    /// guest's worktree-create makes the branch + checkout and opens the
    /// agent's tab, and the binder takes the worktree's path and branch
    /// from that tab. nil when the parent has no folder to branch.
    @discardableResult
    func startWorktree(from parentID: UUID, name: String, tool: Profile.Tool,
                       message: String?, initGit: Bool = false, base: String? = nil,
                       remotely: Bool = false) -> UUID? {
        guard let parent = store.session(parentID), SessionHome.hasFolder(parent) else { return nil }
        let message = message?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        // No name: the message says what it's for.
        let title = name.trimmingCharacters(in: .whitespaces).nonEmpty
            ?? message.map { AgentSession.title(fromMessage: $0) }?.nonEmpty
            ?? String(format: NSLocalizedString("Worktree of %@", comment: "session title"), parent.title)
        var s = AgentSession(profileID: parent.profileID, tool: tool, title: title,
                             cwd: parent.cwd, openingMessage: message)
        s.worktreeOf = parentID
        s.userTitled = true          // the worktree's name is the session's name
        s.launchingSince = Date()
        store.upsert(s)
        if initGit { initGitBeforeBranching.insert(s.id) }
        if let base, !base.isEmpty { worktreeBase[s.id] = base }
        BACDebug.log("sessions", "start worktree “\(title)” off “\(parent.title)” (\(tool.rawValue))")
        launch(s.id, prompt: message ?? "", flags: "", worktreeSlug: Self.worktreeSlug(title),
               remotely: remotely)
        return s.id
    }

    /// A filesystem/branch-safe slug from a free-form name — the same rule
    /// the kanban's worktrees use.
    static func worktreeSlug(_ name: String) -> String { AgentSession.worktreeSlug(name) }

    /// "shell-command-1003-1204": the gist of the message — at most two
    /// words, filler and verbs like "run"/"please"/"this" dropped — plus the
    /// date, so folders stay short, never collide (the caller numbers a
    /// repeat) and still read at a glance. The agent's name when the message
    /// says nothing.
    static func syntheticFolderName(message: String?, tool: Profile.Tool, now: Date = Date()) -> String {
        let words = (message ?? "").lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 1 && !folderNameFiller.contains($0) && !$0.allSatisfy(\.isNumber) }
        var slug = ""
        for w in words.prefix(2) {
            let next = slug.isEmpty ? w : slug + "-" + w
            if next.count > 20 { break }
            slug = next
        }
        if slug.isEmpty { slug = tool.rawValue }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMdd-HHmm"
        return slug + "-" + f.string(from: now)
    }

    /// Words that never name what a session is about.
    static let folderNameFiller: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "to", "of", "for", "in", "on", "at", "by",
        "with", "and", "or", "but", "from", "into", "about", "as", "is", "are", "be", "it", "its",
        "please", "pls", "can", "could", "would", "will", "you", "your", "me", "my", "i", "we", "our",
        "us", "let", "lets", "just", "now", "then", "some", "any", "all", "so", "do", "does", "did",
        "run", "make", "create", "write", "help", "want", "need", "use", "using", "try", "go", "get",
        "hi", "hello", "hey", "exact", "exactly", "following", "here", "there", "what", "how", "why",
    ]

    /// Reopen the agent's last conversation: in its tab when the tab is
    /// still there (a nudge if the agent is alive, the resume command if it
    /// exited), else a fresh tab in the same folder with the resume flags.
    /// Reopen the agent's last conversation — and say `message`, when there
    /// is one, the moment the agent can hear it: right away if it's alive,
    /// else once the relaunch has it running.
    /// `remotely`: a fat client asked — see `start`.
    func resume(_ id: UUID, message: String? = nil, quietly: Bool = false, remotely: Bool = false) {
        guard let s = store.session(id), let delegate else { return }
        if s.folderMissing == true {
            store.mutate(id) { $0.lastError = NSLocalizedString(
                "The folder no longer exists on the machine.", comment: "session resume") }
            return
        }
        let message = message?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        // Picking it back up is what brings an archived conversation back.
        // And it is under way from this moment: while the machine wakes (a
        // fresh boot, often) the session reads "Waking up…" over its
        // conversation — not "Finished" because the boot dropped its tab
        // (see `AgentSessionStore.checkBoot`), not a bare launch screen.
        let wasLaunching = s.isLaunching
        store.mutate(id) {
            $0.lastError = nil; $0.archivedAt = nil
            if $0.launchingSince == nil { $0.launchingSince = Date(); $0.launchBaselineIndex = nil }
        }
        BACDebug.log("sessions", "resume “\(s.title)”\(message == nil ? "" : " with a message")")
        /// The resume didn't open a tab of its own (the agent was there, or
        /// it was relaunched in its tab): no launch to wait for.
        func settled() {
            guard !wasLaunching else { return }
            store.mutate(id) { if $0.launchBaselineIndex == nil { $0.launchingSince = nil } }
        }
        Task { [weak self] in
            guard let self else { return }
            guard await self.ensureUp(s.profileID, quietly: quietly, remotely: remotely) else {
                self.store.mutate(id) {
                    $0.lastError = NSLocalizedString("The workspace did not start in time", comment: "session resume")
                    if !wasLaunching { $0.launchingSince = nil; $0.launchBaselineIndex = nil }
                }
                return
            }
            if let w = s.windowIndex, let tab = delegate.pane(for: s.profileID)?.model.tabs
                .first(where: { $0.index == w }) {
                // Alive or not? A probe's verdict when there is one; before
                // the first probe (the app just launched) ask the guest now —
                // typing a relaunch command into a LIVE agent would send it
                // as a message.
                let alive: Bool
                if let known = s.agentAlive {
                    alive = known
                } else {
                    alive = await self.probeAlive(profileID: s.profileID, window: w)
                        ?? SessionHome.agentRunning(s, in: tab)
                }
                // The probe may just have found the binding stale (the tab
                // went with an earlier boot): that index is somebody else's
                // now — open a fresh tab instead of typing into it.
                if self.store.session(id)?.windowIndex != w {
                    self.relaunchInFreshTab(id, s, message: message)
                    return
                }
                settled()
                let inlineMessage = s.tool == .claude || s.tool == .omp
                if alive {
                    // Alive: the conversation is simply back on stage. Only
                    // something the user actually said gets typed.
                    if let message {
                        // Its own task: a dialog up in the tab can hold it a while.
                        let pid = s.profileID
                        let target = Self.paneTarget(self.store.session(id) ?? s) ?? .index(w)
                        Task { _ = await CodingTaskEngine.typeWhenFree(delegate, profileID: pid, target: target, text: message) }
                    }
                } else {
                    // The agent exited, its shell is still there: relaunch
                    // in place so the conversation history is right at hand.
                    let resume = Self.resumeFlags(for: s, sharedFolder: sharesFolder(s))
                    self.noteKimiRun(id, flags: resume)
                    let words: [String] = [s.tool.rawValue, resume, Self.roleFlags(for: s)]
                    var cmd = words.filter { !$0.isEmpty }.joined(separator: " ")
                    // Claude and Oh My Pi take the message on the command
                    // line: typing it once the agent "looks alive" raced the
                    // resumed conversation loading — text typed before its
                    // input box is up is lost.
                    if let message, inlineMessage {
                        cmd += " '" + message.replacingOccurrences(of: "'", with: "'\\''") + "'"
                    }
                    // The Switchboard's brief is rewritten on every launch —
                    // an in-place relaunch too, so an app update reaches it.
                    if s.isSwitchboard {
                        _ = try? await delegate.guestExec(
                            profileID: s.profileID,
                            command: SwitchboardEngine.briefCommand(
                                guestFolder: ScheduledAutomationEngine.guestPath(s.cwd),
                                roomName: delegate.agentRoomStore.room(s.roomID)?.name),
                            timeout: 15)
                    }
                    // Into the session's own window, and only while its shell
                    // (not an agent, which would take it as a message) is up.
                    let target = Self.paneTarget(self.store.session(id) ?? s, foreground: .shell)
                        ?? .index(w, foreground: .shell)
                    let out = (try? await delegate.guestExec(
                        profileID: s.profileID,
                        command: CodingTaskEngine.shellLineCommand(target: target, line: cmd),
                        timeout: 15)) ?? ""
                    if let r = PaneTypeGuard.refusal(in: out) {
                        if r == .agent {
                            // It came back on its own: just the message, if any.
                            BACDebug.log("sessions", "“\(s.title)”: agent is up in tab \(w) — no relaunch")
                            if let message, let t = Self.paneTarget(self.store.session(id) ?? s) {
                                _ = await CodingTaskEngine.typeWhenFree(delegate, profileID: s.profileID,
                                                                        target: t, text: message)
                            }
                            return
                        }
                        BACDebug.log("sessions", "relaunch of “\(s.title)” in tab \(w) refused (\(r.rawValue)) — fresh tab instead")
                        self.store.unbind(id)
                        self.relaunchInFreshTab(id, s, message: message)
                        return
                    }
                }
                // A fresh start of the agent in the tab: the "exited" verdict
                // waits until it has been seen running again, and the status
                // the crash left behind (a nonzero exit reads as "needs
                // input") is cleared until the agent reports again.
                tab.agentStatus = .done
                self.store.mutate(id) {
                    $0.endedAt = nil; $0.lastSeenAt = Date()
                    $0.resumedAt = Date(); $0.agentAlive = nil
                    $0.changesSeenAt = nil
                }
                if !alive, !inlineMessage, let message { self.deliverWhenAlive(id, message) }
                return
            }
            self.relaunchInFreshTab(id, s, message: message)
        }
    }

    /// Tab gone (or workspace was rebooted): a fresh tab in the same
    /// folder, resuming the last conversation there.
    private func relaunchInFreshTab(_ id: UUID, _ s: AgentSession, message: String?) {
        store.mutate(id) {
            $0.windowIndex = nil
            $0.endedAt = nil
            $0.launchingSince = Date()
            $0.launchBaselineIndex = nil
            $0.resumedAt = Date()
            $0.agentAlive = nil
            $0.changesSeenAt = nil
        }
        // Claude and Oh My Pi take the message on the command line next
        // to their resume flag; Codex and Kimi don't, so it's typed once
        // they're up.
        let inline = message != nil && (s.tool == .claude || s.tool == .omp)
        launch(id, prompt: inline ? (message ?? "") : "", flags: Self.resumeFlags(for: s, sharedFolder: sharesFolder(s)), alreadyUp: true)
        if !inline, let message { deliverWhenAlive(id, message) }
    }

    /// The agent sat at its sign-in screen; the host now holds the account
    /// and the workspace env carries the stand-in key. Drop that tab and
    /// start the agent again in a fresh one on the new env: a conversation
    /// that had begun is resumed, one that never started gets its opening
    /// message for real.
    func relaunchAfterSignIn(_ id: UUID) {
        guard let s = store.session(id), let delegate else { return }
        store.mutate(id) { $0.needsSignIn = nil; $0.lastError = nil }
        BACDebug.log("sessions", "relaunch “\(s.title)” after sign-in")
        Task { [weak self] in
            // Codex reads its login from a file the host writes at boot: put
            // the fresh stand-in in before it starts again, or it comes back
            // on the stale one and asks to sign in all over.
            if s.tool == .codex { await delegate.pushCodexAuth(profileID: s.profileID) }
            if s.tool == .claude { await delegate.pushClaudeStandIn(profileID: s.profileID) }
            if let w = s.windowIndex {
                _ = try? await delegate.guestExec(
                    profileID: s.profileID,
                    command: "tmux kill-window -t bromure:\(w) 2>/dev/null; true", timeout: 10)
            }
            guard let self else { return }
            if s.agentSeenAt != nil {
                self.store.mutate(id) { $0.windowIndex = nil }
                self.resume(id)
            } else {
                self.store.mutate(id) {
                    $0.windowIndex = nil; $0.endedAt = nil
                    $0.launchingSince = Date(); $0.launchBaselineIndex = nil
                    $0.resumedAt = Date(); $0.agentAlive = nil
                }
                self.launch(id, prompt: s.openingMessage ?? "", flags: "", alreadyUp: true)
            }
        }
    }

    /// Type `text` into the session's tab as soon as its agent is seen
    /// running (a relaunch takes a few seconds; a wake-up, a minute).
    private func deliverWhenAlive(_ id: UUID, _ text: String) {
        Task { [weak self] in
            let deadline = Date().addingTimeInterval(Self.bootTimeout + 60)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, let s = self.store.session(id) else { return }
                guard let w = s.windowIndex, let delegate = self.delegate else { continue }
                if await self.probeAlive(profileID: s.profileID, window: w) == true {
                    // A beat for the TUI to draw its prompt before the text lands.
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    // Still this session's tab? (The probe may just have
                    // found the binding stale.) Then into ITS window only —
                    // its stamped id and launch name, an agent in front.
                    guard let now = self.store.session(id), now.windowIndex == w,
                          let target = Self.paneTarget(now) else { continue }
                    let r = await CodingTaskEngine.typeWhenFreeResult(delegate, profileID: s.profileID,
                                                                      target: target, text: text)
                    if case .refused(let why) = r {
                        BACDebug.log("sessions", "message for “\(s.title)” NOT typed: \(why.rawValue)")
                        self.store.mutate(id) {
                            $0.lastError = NSLocalizedString(
                                "The message wasn't typed: the session's tab no longer shows its agent. Resume the session to try again.",
                                comment: "session deliver refused")
                        }
                    }
                    return
                }
            }
        }
    }

    /// Where text typed for session `s` may go: its window (by the id the
    /// probe stamped, else its index), still carrying the name we launched
    /// it under, with — by default — an agent in the foreground.
    static func paneTarget(_ s: AgentSession, foreground: PaneTarget.Foreground = .agent) -> PaneTarget? {
        guard let w = s.windowIndex else { return nil }
        var t = PaneTarget(ref: s.windowID.map { .windowID($0) } ?? .index(w), foreground: foreground)
        t.expectDisplay = s.launchDisplay
        return t
    }

    /// End the session: close its tab (the agent with it). The record stays
    /// under Ended so it can be resumed later.
    func close(_ id: UUID) {
        guard let s = store.session(id), let delegate else { return }
        if let w = s.windowIndex, let pane = delegate.pane(for: s.profileID) {
            delegate.requestCloseTab(index: w, in: pane)
        }
        store.mutate(id) { $0.windowIndex = nil; $0.endedAt = Date(); $0.launchingSince = nil }
    }

    func rename(_ id: UUID, to title: String) {
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        store.mutate(id) { $0.title = t; $0.userTitled = true }
    }

    /// Put the conversation away: the agent stops (now, if its tab is at
    /// hand; else the moment the workspace shows the tab again — see
    /// `probeLiveness`), the record moves to the Archived fold, readable as
    /// ever. Resume brings it back.
    func archive(_ id: UUID) {
        guard let s = store.session(id) else { return }
        BACDebug.log("sessions", "archive “\(s.title)”")
        if s.windowIndex != nil, delegate?.pane(for: s.profileID) != nil { close(id) }
        store.mutate(id) { $0.launchingSince = nil }
        store.setArchived(id, true)
    }

    func unarchive(_ id: UUID) {
        guard let s = store.session(id) else { return }
        BACDebug.log("sessions", "unarchive “\(s.title)”")
        store.setArchived(id, false)
        // Back from an archived room: the room comes back too (its other
        // sessions stay put away).
        if let rid = s.roomID { delegate?.agentRoomStore.setArchived(rid, false) }
    }

    /// Delete the session. No tab and no launch under way: the record (and
    /// its transcript copy) goes at once. Otherwise it's hidden and marked;
    /// its tab is killed — now, or when the machine wakes and shows it
    /// again (`probeLiveness`) — and the record is purged once the roster
    /// no longer lists the tab, so the dying tab can't be adopted as a
    /// session of its own in the meantime.
    func delete(_ id: UUID) {
        guard let s = store.session(id) else { return }
        BACDebug.log("sessions", "delete “\(s.title)”")
        if s.windowIndex == nil, s.launchingSince == nil {
            store.remove(id)
            return
        }
        store.setDeleted(id)
        killTabIfShown(store.session(id) ?? s)
    }

    /// Kill a deleted session's tab when its workspace is up — once per
    /// binding; the roster catching up is what ends the record.
    private var killSent: Set<String> = []
    private func killTabIfShown(_ s: AgentSession) {
        guard let w = s.windowIndex, let delegate, let pane = delegate.pane(for: s.profileID) else { return }
        let key = "\(s.id.uuidString)#\(w)"
        guard !killSent.contains(key) else { return }
        killSent.insert(key)
        delegate.requestCloseTab(index: w, in: pane)
    }

    // MARK: Launch

    /// `worktreeSlug`: branch the folder into a worktree (the guest's
    /// worktree-create) instead of opening the agent in it (agent-tab).
    private func launch(_ id: UUID, prompt: String, flags: String, alreadyUp: Bool = false,
                        worktreeSlug: String? = nil, attachments: [DroppedFile] = [],
                        remotely: Bool = false) {
        noteKimiRun(id, flags: flags)
        Task { [weak self] in
            guard let self, let delegate = self.delegate, let s = self.store.session(id) else { return }
            @MainActor func fail(_ reason: String) {
                self.store.mutate(id) { $0.launchingSince = nil; $0.lastError = reason }
            }
            if !alreadyUp {
                // A delegate's workspace is booted by an agent, not by a
                // click: quietly, with the user's stage left where it is.
                let quietly = self.store.session(id)?.parentSessionID != nil
                guard await self.ensureUp(s.profileID, quietly: quietly, remotely: remotely) else {
                    fail(NSLocalizedString("The workspace did not start in time", comment: "session start"))
                    return
                }
            }
            // Dropped files land in the machine before the agent starts, and
            // ride along as paths — the same shape a drop in the chat sends,
            // so the opening turn shows their thumbnails too.
            var prompt = prompt
            let staged = await self.stageAttachments(attachments, sessionID: id,
                                                     profileID: s.profileID, delegate: delegate)
            if !staged.isEmpty {
                prompt = prompt.isEmpty ? staged.joined(separator: " ") : prompt + " " + staged.joined(separator: " ")
                let echoed = prompt
                self.store.mutate(id) { $0.openingMessage = echoed }
            }
            // Kimi takes no opening message on its command line but in its
            // one-shot `--prompt` mode, which exits when the turn ends — the
            // session went "Finished" after one answer. Start it
            // interactively and type the message once it's up (as a resume
            // already does).
            let typeOnceUp = Self.typesOpeningMessage(s.tool) && !prompt.isEmpty ? prompt : nil
            if typeOnceUp != nil { prompt = "" }
            let guestPath = ScheduledAutomationEngine.guestPath(s.cwd)
            let q = "'" + guestPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
            if let worktreeSlug {
                // The folder must be a git checkout; say so now rather than
                // waiting for a tab that never comes.
                let top = (try? await delegate.guestExec(
                    profileID: s.profileID,
                    command: "git -C \(q) rev-parse --show-toplevel 2>/dev/null", timeout: 15)) ?? ""
                if top.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   self.initGitBeforeBranching.remove(id) != nil {
                    // Asked for: make the folder a repository first.
                    _ = await self.initGitRepository(profileID: s.profileID, cwd: s.cwd)
                }
                let topNow = top.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? ((try? await delegate.guestExec(
                        profileID: s.profileID,
                        command: "git -C \(q) rev-parse --show-toplevel 2>/dev/null", timeout: 15)) ?? "")
                    : top
                guard !topNow.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    fail(String(format: NSLocalizedString("%@ isn't a git repository — a worktree needs one.", comment: "session start"),
                                prettyGuestPath(guestPath)))
                    return
                }
                // …with a commit to branch from. A folder Bromure made for a
                // session is a bare `git init` (unborn HEAD): give it an
                // empty root commit rather than have `worktree add` fail on
                // "invalid reference: HEAD". The identity fallback only
                // applies when the machine has none configured.
                func headCommit() async -> String {
                    ((try? await delegate.guestExec(
                        profileID: s.profileID,
                        command: "git -C \(q) rev-parse --verify -q HEAD 2>/dev/null; true", timeout: 15)) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if await headCommit().isEmpty {
                    _ = try? await delegate.guestExec(
                        profileID: s.profileID,
                        command: "git -C \(q) commit -q --allow-empty -m 'Initial commit' 2>/dev/null "
                            + "|| git -C \(q) -c user.name=Bromure -c user.email=bromure@localhost "
                            + "commit -q --allow-empty -m 'Initial commit' 2>/dev/null; true",
                        timeout: 20)
                    guard await !headCommit().isEmpty else {
                        fail(String(format: NSLocalizedString("%@ has no commit to branch from yet.", comment: "session start"),
                                    prettyGuestPath(guestPath)))
                        return
                    }
                    BACDebug.log("sessions", "“\(s.title)”: gave \(guestPath) its root commit")
                }
                let display = s.title
                let baseline = await self.tabBaseline(profileID: s.profileID, delegate: delegate)
                self.store.mutate(id) { $0.launchBaselineIndex = baseline; $0.launchDisplay = display }
                guard delegate.automationWorktreeCommand(
                    profileNameOrID: s.profileID.uuidString, action: "create",
                    args: [guestPath, worktreeSlug, display, s.tool.rawValue, prompt,
                           self.backgroundArg(id).first ?? "", self.worktreeBase.removeValue(forKey: id) ?? ""]) else {
                    fail(NSLocalizedString("Couldn't reach the workspace — is it running?", comment: "task start"))
                    return
                }
                BACDebug.log("sessions", "“\(s.title)”: worktree-create sent (baseline \(baseline))")
                self.watchEarlyExit(id, display: display)
                if let typeOnceUp { self.deliverWhenAlive(id, typeOnceUp) }
                return
            }
            if let url = s.cloneURL, !url.isEmpty {
                let qu = "'" + url.replacingOccurrences(of: "'", with: "'\\''") + "'"
                BACDebug.log("sessions", "“\(s.title)”: cloning \(url) → \(s.cwd)")
                do {
                    _ = try await delegate.guestExec(
                        profileID: s.profileID,
                        command: "bash -c '" + CodingTaskEngine.cloneRepoCommand(quotedPath: q, quotedURL: qu)
                            .replacingOccurrences(of: "'", with: "'\\''") + "'",
                        timeout: 900)
                } catch {
                    fail(String(format: NSLocalizedString("Couldn't clone %@ — %@", comment: "task start"),
                                url, error.localizedDescription))
                    return
                }
            } else if s.isSwitchboard {
                // The Switchboard's folder holds its brief, rewritten on every
                // launch so an app update's brief reaches it. No repository:
                // it works on sessions, not on files.
                _ = try? await delegate.guestExec(
                    profileID: s.profileID,
                    command: SwitchboardEngine.briefCommand(
                        guestFolder: guestPath, roomName: delegate.agentRoomStore.room(s.roomID)?.name),
                    timeout: 15)
            } else {
                // A folder that doesn't exist yet is created — and starts as
                // a git repository, so the agent's work is versioned from the
                // first edit (branches, diffs, the kanban's worktrees all
                // assume one). A folder that already exists is left as it is.
                _ = try? await delegate.guestExec(
                    profileID: s.profileID,
                    command: "if [ ! -d \(q) ]; then mkdir -p \(q) && "
                        + "(git -C \(q) init -q -b main 2>/dev/null || git -C \(q) init -q); fi",
                    timeout: 15)
            }
            let baseline = await self.tabBaseline(profileID: s.profileID, delegate: delegate)
            let display = s.title
            self.store.mutate(id) { $0.launchBaselineIndex = baseline; $0.launchDisplay = display }
            // The session's instructions, from a file rewritten on every
            // launch (a resume gives them again). Before the resume flags:
            // Codex resumes through a subcommand.
            var instructionFlags = ""
            if let text = s.instructions?.nonEmpty {
                let path = Self.instructionsGuestPath(s.id)
                let dir = (path as NSString).deletingLastPathComponent
                let body = Data(Self.instructionsFile(text, tool: s.tool).utf8).base64EncodedString()
                if (try? await delegate.guestFileOp(profileID: s.profileID, op: ["op": "mkdir", "path": dir], timeout: 15)) != nil,
                   (try? await delegate.guestFileOp(profileID: s.profileID,
                                                    op: ["op": "write", "path": path, "data": body], timeout: 15)) != nil {
                    instructionFlags = Self.instructionFlags(tool: s.tool, text: text, path: path,
                                                             resuming: !flags.isEmpty)
                } else {
                    BACDebug.log("sessions", "“\(s.title)”: couldn't write its instructions to \(path)")
                }
            }
            let allFlags = [instructionFlags, flags, Self.roleFlags(for: s)]
                .filter { !$0.isEmpty }.joined(separator: " ")
            guard delegate.automationWorktreeCommand(
                profileNameOrID: s.profileID.uuidString, action: "agent-tab",
                args: [guestPath, display, s.tool.rawValue, prompt, allFlags] + self.backgroundArg(id)) else {
                fail(NSLocalizedString("Couldn't reach the workspace — is it running?", comment: "task start"))
                return
            }
            BACDebug.log("sessions", "“\(s.title)”: agent-tab sent (baseline \(baseline))")
            self.watchEarlyExit(id, display: display)
            if let typeOnceUp { self.deliverWhenAlive(id, typeOnceUp) }
        }
    }

    /// Agents whose opening message is typed into the running TUI instead
    /// of riding on the launch command: Kimi's only command-line prompt is
    /// its one-shot mode (`kimi --prompt`, exits after the turn).
    nonisolated static func typesOpeningMessage(_ tool: Profile.Tool) -> Bool { tool == .kimi }

    /// The agent dying as it starts (a bad flag, a resume with nothing to
    /// resume, a config error): the launcher says so in the tab and drops
    /// to a shell, and the session sat on "Starting…". Watch the new tab —
    /// found by its name, straight from tmux — until the agent is seen
    /// running, and end the launch with the agent's own words if it dies.
    private func watchEarlyExit(_ id: UUID, display: String) {
        let q = "'" + display.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let screen = "for w in $(tmux list-windows -t bromure -F '#{window_index}' 2>/dev/null); do "
            + "[ \"$(tmux show-options -wqv -t bromure:$w @display)\" = \(q) ] && tmux capture-pane -p -J -t bromure:$w; "
            + "done; true"
        Task { [weak self] in
            let deadline = Date().addingTimeInterval(AgentSessionStore.launchTimeout)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, let s = self.store.session(id), let delegate = self.delegate else { return }
                // Up and running: the chat watches it from here. Ended or
                // failed some other way: nothing left to watch.
                if s.agentAlive == true { return }
                guard s.isLaunching || s.windowIndex != nil else { return }
                guard let out = try? await delegate.guestExec(profileID: s.profileID, command: screen, timeout: 8),
                      let reason = Self.earlyExitReason(out, tool: s.tool.rawValue) else { continue }
                BACDebug.log("sessions", "“\(s.title)”: \(s.tool.rawValue) died starting — \(reason)")
                self.store.mutate(id) {
                    $0.launchingSince = nil
                    $0.lastError = String(format: NSLocalizedString("%@ stopped as it started: %@", comment: "session launch"),
                                          s.tool.displayName, reason)
                }
                return
            }
        }
    }

    /// What a launcher's tab says when its agent died: the line the agent
    /// printed before the launcher's "<tool> exited with status N" (or that
    /// line itself when the agent said nothing). nil while it hasn't died.
    /// `tool` nil: whichever agent the tab ran.
    nonisolated static func earlyExitReason(_ screen: String, tool: String? = nil) -> String? {
        // The launcher colors its line; a captured screen can keep the
        // codes, or what's left of them ("33[31m").
        let lines = screen.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: #"(\x{1b}|\\?0?33)?\[[0-9;]*m"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        let marker = tool.map { "[bromure-ac] \($0) exited with status" }
        guard let i = lines.lastIndex(where: { l in
            if let marker { return l.contains(marker) }
            return l.range(of: #"\[bromure-ac\] \S+ exited with status"#, options: .regularExpression) != nil
        }) else { return nil }
        // What the agent printed since the launcher started it; an error
        // line wins over what follows it ("See log: …").
        let start = lines[..<i].lastIndex(where: { $0.contains("[bromure-ac] starting") }).map { $0 + 1 } ?? 0
        let printed = lines[start..<i].filter { !$0.isEmpty && !$0.contains("[bromure-ac]") }
        let errorish = #"(?i)\b(error|failed|fatal|not found|no such|cannot|can't|invalid|no conversation|no model)\b"#
        let said = printed.last(where: { $0.range(of: errorish, options: .regularExpression) != nil }) ?? printed.last
        let exitLine = lines[i]
        let reason = said ?? exitLine.replacingOccurrences(of: "[bromure-ac] ", with: "")
        return reason.count > 200 ? String(reason.prefix(200)) + "…" : reason
    }

    /// A delegate's tab opens behind the current one: another agent
    /// started it, and the user is looking at that agent, not at it. Read
    /// at launch time — the delegation engine links the child right after
    /// starting it.
    private func backgroundArg(_ id: UUID) -> [String] {
        store.session(id)?.parentSessionID != nil ? ["background"] : []
    }

    /// Which tabs are there before a launch, so the new one can be told
    /// apart — the roster may lag right after a boot, so ask tmux too.
    private func tabBaseline(profileID: UUID, delegate: ACAppDelegate) async -> Int {
        var baseline = delegate.pane(for: profileID)?.model.tabs.map(\.index).max() ?? -1
        if let out = try? await delegate.guestExec(
            profileID: profileID,
            command: "tmux list-windows -t bromure -F '#{window_index}' 2>/dev/null | sort -n | tail -1",
            timeout: 8), let n = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) {
            baseline = max(baseline, n)
        }
        return baseline
    }

    // MARK: Liveness

    private var probing: Set<UUID> = []
    private var lastProbeAt: [UUID: Date] = [:]
    /// Each workspace's guest boot as the last probe read it.
    private var bootIDs: [UUID: String] = [:]

    // MARK: Local transcript copies

    /// Each session's conversation as last read from the machine, so an
    /// asleep session still reads back in full.
    let transcripts = SessionTranscriptCache.shared
    private var lastSnapshotAt: [UUID: Date] = [:]
    private var snapshotting: Set<UUID> = []
    /// Where each session's last snapshot read stopped: the file and the
    /// offset the next read continues from.
    private var snapshotCursor: [UUID: (path: String, end: Int)] = [:]
    /// A session's first snapshot (no cursor yet): this much of the file's
    /// end, aligned to a record — the copy may already hold what's before.
    static let snapshotFirstBytes = 8_000_000

    /// Copy the session's transcript from the machine (while it's alive, on
    /// a timer; and once more when the agent goes away). Incremental: whole
    /// records from where the last read stopped, in the file the tab's own
    /// agent named — a byte window of the tail used to REPLACE the history
    /// whenever it no longer overlapped what was held (one browser
    /// screenshot fills 300 KB).
    private func snapshot(_ s: AgentSession) {
        guard let delegate, !snapshotting.contains(s.id) else { return }
        snapshotting.insert(s.id)
        lastSnapshotAt[s.id] = Date()
        Task { [weak self] in
            defer { self?.snapshotting.remove(s.id) }
            guard let self else { return }
            // An attached Mac's agent: the one-shot tail (the chunk reader
            // needs python3, which a plain Mac may not have). The cache
            // keeps whole records and merges, so this can't shrink it.
            if delegate.attachedMachines[s.profileID] != nil {
                guard let raw = await delegate.fetchSessionTranscript(s), !raw.isEmpty else { return }
                self.transcripts.save(s.id, Data(raw.utf8))
                return
            }
            var known = self.snapshotCursor[s.id]
            // Kimi's store is keyed by folder, not by tab: "the newest journal
            // in the folder" (floor 0) was the PREVIOUS conversation there
            // until this launch's own appeared — Kimi only creates it at the
            // first prompt — and the copy took that conversation in, then
            // the real one after it (B72). Read the session's pinned journal;
            // until there is one, only a journal begun by this run.
            var since = 0
            var pin = TranscriptPin()
            // The tab's own Kimi session, learned from this read: by the id
            // its process names, or as the journal this run began.
            var learnsID = false
            if s.tool == .kimi {
                if let id = s.agentTranscriptID, AgentSessionLocator.isKimiSessionID(id) {
                    pin.kimiSession = id
                    if let k = known, AgentSessionLocator.kimiSessionID(inPath: k.path) != id { known = nil }
                } else {
                    guard let w = s.windowIndex,
                          let fp = AgentSessionLocator.parseFloorProbe(try? await delegate.guestExec(
                            profileID: s.profileID, command: AgentSessionLocator.floorProbeCommand(window: w),
                            timeout: 8)),
                          fp.since > 0 || fp.kimiSession != nil else { return }   // never unfloored
                    since = fp.since
                    // How the agent started: as the engine launched it, else
                    // (a tab started by hand, adopted; the app restarted
                    // under it) as its command line says.
                    let fresh = self.kimiFreshRun[s.id] ?? (fp.kimiSession == nil && !fp.resumed)
                    // A fresh start: a journal begun before the agent was is
                    // another conversation's, however recently it was written.
                    // A resume reattaches an older one, so mtime alone there —
                    // never one another session owns (two Kimi tabs in one
                    // folder: the second was adopted with the first's
                    // conversation and title).
                    pin = .kimiUnpinned(argsSession: fp.kimiSession, resumed: !fresh, since: fp.since,
                                        exclude: self.store.kimiSessionsClaimed(profileID: s.profileID,
                                                                                besides: s.id))
                    if let id = pin.kimiSession {
                        since = 0
                        if let k = known, AgentSessionLocator.kimiSessionID(inPath: k.path) != id { known = nil }
                    }
                    learnsID = pin.kimiSession != nil || pin.kimiCreatedSince != nil
                        || self.kimiFreshRun[s.id] != nil
                }
            }
            guard let cmd = CodingTaskEngine.transcriptChunkCommand(
                    guestCwd: ScheduledAutomationEngine.guestPath(s.cwd), since: since,
                    agent: s.tool.rawValue, pinnedWindow: s.windowIndex, pin: pin,
                    knownPath: known?.path, knownOffset: known?.end ?? -1,
                    bytes: Self.snapshotFirstBytes, earlier: false),
                  let out = try? await delegate.guestExec(profileID: s.profileID, command: cmd, timeout: 30),
                  let f = TranscriptFetch.parse(Data(out.utf8)) else { return }
            // This run's journal: from now on the session reads it by id (and
            // a resume reopens it by id, never "the last one here").
            var newConversation = false
            if s.tool == .kimi, learnsID, s.agentTranscriptID.map(AgentSessionLocator.isKimiSessionID) != true,
               let id = AgentSessionLocator.kimiSessionID(inPath: f.path),
               !self.store.kimiSessionsClaimed(profileID: s.profileID, besides: s.id).contains(id) {
                self.store.setTranscriptID(s.id, id)
                // Begun by this run (the creation floor held): the session's
                // next conversation, carried on after what the copy holds.
                newConversation = pin.kimiCreatedSince != nil && f.start == 0
            }
            let continues = newConversation
                || (known.map { $0.path == f.path && $0.end == f.start } ?? false)
            self.snapshotCursor[s.id] = (f.path, f.end)
            if s.tool == .kimi { self.noteJournal(s.id, f.chunk, continues: continues && !newConversation) }
            guard !f.chunk.isEmpty else { return }
            if continues {
                self.transcripts.append(s.id, f.chunk)
            } else {
                self.transcripts.save(s.id, f.chunk)
            }
        }
    }
    private static let snapshotEvery: TimeInterval = 30
    /// Kimi sessions by how their agent last started: true = a new
    /// conversation (no resume flags), false = resumed. Unknown (the app
    /// restarted under a running agent) reads as resumed.
    private var kimiFreshRun: [UUID: Bool] = [:]

    /// Note how a Kimi session's agent is (re)started. A fresh start is a
    /// new conversation: whatever the session was pinned to is not it.
    private func noteKimiRun(_ id: UUID, flags: String) {
        guard store.session(id)?.tool == .kimi else { return }
        let fresh = !flags.split(separator: " ").contains { $0 == "-c" || $0 == "--continue" || $0 == "-S" || $0 == "--session" }
        kimiFreshRun[id] = fresh
        if fresh, store.session(id)?.agentTranscriptID != nil {
            store.mutate(id) { $0.agentTranscriptID = nil }
        }
    }
    private static let kimiSnapshotEvery: TimeInterval = 3

    /// The end of each Kimi session's journal (what `KimiTranscriptParser.
    /// turnInProgress` reads), kept from the snapshots' increments.
    private var journalTail: [UUID: Data] = [:]
    private static let journalTailBytes = 256_000

    /// Kimi: whether its journal says a turn is under way — the sidebar and
    /// header follow it (`AgentSession.transcriptWorking`).
    private func noteJournal(_ id: UUID, _ chunk: Data, continues: Bool) {
        var tail = continues ? (journalTail[id] ?? Data()) : Data()
        tail.append(chunk)
        if tail.count > Self.journalTailBytes { tail = Data(tail.suffix(Self.journalTailBytes)) }
        journalTail[id] = tail
        // A turn left open from before the agent was last (re)started was
        // interrupted (killed, the app relaunched and the session resumed):
        // not work under way.
        store.setTranscriptWorking(id, KimiTranscriptParser.turnInProgress(
            tail, notBefore: store.session(id)?.resumedAt))
    }

    /// The conversation to read back: the local copy, with what the
    /// machine's file says now merged in when it can be read. The live
    /// read is "the newest transcript in the folder" (it may be another
    /// session's), so it only counts when it shares records with the copy.
    func readableTranscript(_ s: AgentSession) async -> Data? {
        let cached = transcripts.load(s.id)
        guard let delegate, let live = await delegate.fetchSessionTranscript(s), !live.isEmpty else { return cached }
        guard let cached, !cached.isEmpty else { return Data(live.utf8) }
        return SessionTranscriptCache.merge(history: cached, incoming: Data(live.utf8), mode: .overlapOnly) ?? cached
    }

    /// The tty process probe, one window: is an agent in its foreground?
    /// nil when the guest can't be asked.
    static let agentNames = "(claude|codex|kimi|grok|omp|aider|goose|amp|opencode|gemini|cursor)"
    private static let shellNames = "^-?(bash|sh|zsh|dash|login|tmux)( |$)"
    /// One line per window: `index<TAB>agent-or-none<TAB>transcript id<TAB>
    /// pane title`. The title is what the agent set on its terminal (OSC 2)
    /// — Claude Code and Oh My Pi both write a summary of the conversation
    /// there. The transcript id is the file the agent's own hook named for
    /// this window (agent-status.sh; Claude only), sans path and extension:
    /// what a resume targets.
    static func probeCommand(window: String) -> String {
        // A fresh shell's title is the hostname until the agent speaks up —
        // never a session name. The boot id leads (its own `boot` line):
        // window indices are only meaningful within one boot.
        "printf 'boot\\t%s\\n' \"$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)\"; "
            + "h=$(hostname 2>/dev/null); "
            + "tmux list-panes -s -t bromure -F '#{window_index} #{window_id} #{pane_tty} #{pane_title}' 2>/dev/null "
            + "| while read -r i wid t title; do \(window.isEmpty ? "" : "[ \"$i\" = \(window) ] || continue; ")"
            // The window's stable id (its own line): an index is reused the
            // moment its tab closes, the id never is.
            + "printf 'win\\t%s\\t%s\\n' \"$i\" \"$wid\"; "
            + "[ \"$title\" = \"$h\" ] && title=''; "
            + "a=$(ps -t \"${t#/dev/}\" -o args= 2>/dev/null "
            + "| grep -v -E '\(shellNames)' "
            + "| grep -E -o -m1 '\(agentNames)' "
            + "| head -1); "
            + AgentSessionLocator.pinnedTranscriptBlock(window: "$i", into: "tp")
            // Pinned at SessionStart before anything was said: no
            // conversation to resume by that id yet.
            + "[ -f \"$tp\" ] || tp=\"\"; "
            + "tid=\"${tp##*/}\"; tid=\"${tid%.jsonl}\"; "
            + "printf '%s\\t%s\\t%s\\t%s\\n' \"$i\" \"${a:-none}\" \"$tid\" \"$title\"; done"
    }

    struct ProbeLine: Equatable {
        let index: Int
        let alive: Bool
        var transcriptID: String? = nil
        let title: String
    }
    /// index → tmux window id, from the probe's `win` lines.
    nonisolated static func parseWindowIDs(_ out: String) -> [Int: String] {
        var ids: [Int: String] = [:]
        for line in out.split(whereSeparator: \.isNewline) where line.hasPrefix("win\t") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3, let i = Int(parts[1]) else { continue }
            let id = parts[2].trimmingCharacters(in: .whitespaces)
            if PaneTypeGuard.isWindowID(id), ids[i] == nil { ids[i] = id }
        }
        return ids
    }

    /// What becomes of an archived or deleted session's binding when the
    /// probe shows a tab at its index. Only a tab PROVABLY its own — same
    /// boot, same tmux window id as stamped while it was live, the name we
    /// gave it, and not a board task's live tab — is ended; anything else is
    /// a newcomer at the old index (a task resumed after Stop & Return to
    /// Backlog reuses the index and the title) and the session just lets go.
    enum ArchivedTabVerdict: Equatable { case end, unbind, wait }

    nonisolated static func archivedTabVerdict(sessionBoot: String?, probeBoot: String?,
                                   sessionWindowID: String?, probeWindowID: String?,
                                   sessionDisplay: String?, tabDisplay: String?,
                                   taskOwned: Bool) -> ArchivedTabVerdict {
        guard let probeBoot, let probeWindowID else { return .wait }
        guard sessionBoot == probeBoot else { return .unbind }
        if let mine = sessionDisplay, let d = tabDisplay, !d.isEmpty, d != mine { return .unbind }
        if taskOwned { return .unbind }
        guard let sessionWindowID, sessionWindowID == probeWindowID else { return .unbind }
        return .end
    }

    /// The guest boot id the probe leads with (nil from an older probe, or
    /// when the guest couldn't read it).
    static func parseBootID(_ out: String) -> String? {
        for line in out.split(whereSeparator: \.isNewline) where line.hasPrefix("boot\t") {
            let id = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            return id.isEmpty ? nil : id
        }
        return nil
    }

    static func parseProbe(_ out: String) -> [ProbeLine] {
        out.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard parts.count >= 2, let idx = Int(parts[0]) else { return nil }
            // Older guests answer with three fields (no transcript id).
            let tid = parts.count == 4 ? String(parts[2]) : ""
            let title = parts.count == 4 ? String(parts[3]) : (parts.count == 3 ? String(parts[2]) : "")
            return ProbeLine(index: idx, alive: parts[1] != "none",
                             transcriptID: Self.isTranscriptID(tid) ? tid : nil, title: title)
        }
    }

    /// A Claude session id as the transcript file is named: a UUID.
    static func isTranscriptID(_ s: String) -> Bool {
        s.count == 36 && UUID(uuidString: s) != nil
    }

    /// How the agent picks its conversation back up: by id when we know
    /// which conversation is this session's — two agents in one folder (a
    /// delegate beside its delegator) would otherwise `--continue` into
    /// each other's — else the tool's own "the latest".
    /// Flags a session's role adds to every launch of its agent (the
    /// Switchboard's MCP config), on top of any resume flags.
    /// Where a session's instructions live in its machine.
    static func instructionsGuestPath(_ id: UUID) -> String {
        "/home/ubuntu/.bromure/instructions/\(id.uuidString).md"
    }

    /// The instructions file for `tool`: the text itself, or for Kimi an
    /// agent file that keeps its default prompt (`${base_prompt}`) and adds
    /// the text after it (the body is a template: a literal "${" is broken up).
    static func instructionsFile(_ text: String, tool: Profile.Tool) -> String {
        guard tool == .kimi else { return text + "\n" }
        return "---\ndescription: Session instructions from Bromure\n---\n${base_prompt}\n\n"
            + text.replacingOccurrences(of: "${", with: "$ {") + "\n"
    }

    /// The launch flags that add the instructions to the agent's system
    /// prompt. Never a space in them: the launcher word-splits flags.
    /// Claude and Oh My Pi read the file; Codex takes the text as a config
    /// value; Kimi takes an agent file, on a fresh start only (it can't be
    /// combined with a resume). Grok: none — see `openingWithInstructions`.
    static func instructionFlags(tool: Profile.Tool, text: String, path: String, resuming: Bool) -> String {
        switch tool {
        case .claude: return "--append-system-prompt-file \(path)"
        case .omp:    return "--append-system-prompt \(path)"
        case .codex:  return "-c developer_instructions=" + tomlSpacelessString(text)
        case .kimi:   return resuming ? "" : "--agent-file \(path)"
        case .grok:   return ""
        }
    }

    /// A TOML basic string with everything but letters, digits and a few
    /// safe marks escaped (`\uXXXX`): no spaces for the launcher to split
    /// on, nothing for the shell to glob.
    static func tomlSpacelessString(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            if u.isASCII, u.properties.isAlphabetic || ("0"..."9").contains(Character(u)) || "-_.,:".unicodeScalars.contains(u) {
                out.unicodeScalars.append(u)
            } else if u.value <= 0xFFFF {
                out += String(format: "\\u%04X", u.value)
            } else {
                out += String(format: "\\U%08X", u.value)
            }
        }
        return out + "\""
    }

    /// Grok's first message when the session has instructions.
    static func openingWithInstructions(_ text: String, message: String) -> String {
        // Agent-facing, like the rest of what the agent is told: not localized.
        let body = "Instructions for this whole session:\n\n" + text
        return message.isEmpty ? body : body + "\n\n---\n\n" + message
    }

    static func roleFlags(for s: AgentSession) -> String {
        [s.isSwitchboard ? SwitchboardEngine.launchFlags(for: s.tool) : "", autonomyFlags(for: s.tool)]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// How an agent runs in a workspace: on its own, the VM (and the host's
    /// egress policy) being the sandbox. Claude gets there through its auto
    /// mode (settings.json); Codex has no such mode — without this it asked
    /// to approve every command, and its own sandbox fought the VM's.
    static func autonomyFlags(for tool: Profile.Tool) -> String {
        tool == .codex ? "--dangerously-bypass-approvals-and-sandbox" : ""
    }

    /// `sharedFolder`: another session works in the same folder. With no
    /// transcript id of its own, the agent's "continue the last one here"
    /// would pick up THAT session's conversation — start fresh instead.
    static func resumeFlags(for s: AgentSession, sharedFolder: Bool = false) -> String {
        if s.tool == .claude, let id = s.agentTranscriptID, isTranscriptID(id) {
            return "--resume \(id)"
        }
        // Kimi: its own session, by id — `-c` takes the folder's latest,
        // which may be another session's.
        if s.tool == .kimi, let id = s.agentTranscriptID, AgentSessionLocator.isKimiSessionID(id) {
            return "-S \(id)"
        }
        return sharedFolder ? "" : s.tool.resumeFlags
    }

    /// Whether another (not deleted) session on the same machine works in
    /// `s`'s folder.
    func sharesFolder(_ s: AgentSession) -> Bool {
        store.sessions.contains {
            $0.id != s.id && !$0.isDeleted && $0.profileID == s.profileID && $0.cwd == s.cwd
        }
    }

    /// Apply one probe line to the session bound to that window.
    private func apply(_ p: ProbeLine, to s: AgentSession) {
        let wasAlive = s.agentAlive
        store.setLiveness(s.id, alive: p.alive)
        if p.alive, let title = AgentSession.title(fromAgent: p.title, of: s) {
            store.setAgentTitle(s.id, title)
        }
        if p.alive, let tid = p.transcriptID { store.setTranscriptID(s.id, tid) }
        // Keep the local copy fresh while it runs; take its last words when
        // it stops.
        let now = Date()
        if p.alive {
            // Kimi's turn state is read off its journal (its hooks leave
            // "Ready" up while it works): at the probe's cadence, not 30 s.
            let every = s.tool == .kimi ? Self.kimiSnapshotEvery : Self.snapshotEvery
            if now.timeIntervalSince(lastSnapshotAt[s.id] ?? .distantPast) > every { snapshot(s) }
        } else {
            if wasAlive == true { snapshot(s) }
            journalTail[s.id] = nil
            store.setTranscriptWorking(s.id, nil)
        }
    }

    func probeAlive(profileID: UUID, window: Int) async -> Bool? {
        guard let delegate,
              let out = try? await delegate.guestExec(profileID: profileID,
                                                       command: Self.probeCommand(window: String(window)),
                                                       timeout: 10) else { return nil }
        guard let p = Self.parseProbe(out).first(where: { $0.index == window }) else { return nil }
        if let s = store.session(profileID: profileID, windowIndex: window) {
            if let boot = Self.parseBootID(out) {
                bootIDs[profileID] = boot
                // The session's tab went with an earlier boot: whatever
                // runs at this index now isn't its agent.
                guard store.checkBoot(s.id, bootID: boot) else { return nil }
            }
            // Same boot, but another window at the index: ours was closed.
            if let wid = Self.parseWindowIDs(out)[window],
               !store.checkWindow(s.id, windowID: wid) { return nil }
            apply(p, to: s)
        }
        return p.alive
    }

    /// Ask each running workspace which of its tabs has an agent in the
    /// foreground group of its tty (one shell round-trip per workspace,
    /// every few seconds). tmux's own `pane_current_command` can't tell:
    /// an agent under an interpreter (omp under bun) reads as "bash".
    /// Sessions that ended more than `autoArchiveAfter` ago are put away
    /// (Archived: still readable, back with one message) so the list stays
    /// about what's alive. At most once a minute; never a room's member
    /// or a Switchboard.
    static let autoArchiveAfter: TimeInterval = 3 * 86400
    private var lastSweep = Date.distantPast
    private func sweepEnded(now: Date = Date()) {
        guard now.timeIntervalSince(lastSweep) > 60 else { return }
        lastSweep = now
        for s in store.sessions where !s.isArchived && !s.isDeleted && !s.isSwitchboard && s.roomID == nil
            && s.hasEnded && now.timeIntervalSince(s.endedAt ?? now) > Self.autoArchiveAfter {
            store.setArchived(s.id, true)
        }
    }

    func probeLiveness(entries: [SessionListModel.VMEntry]) {
        guard let delegate else { return }
        sweepEnded()
        probeFolders(entries: entries)
        probeChanges(entries: entries)
        probeBranches(entries: entries)
        // An archived or deleted session whose tab is back (its workspace
        // was asleep when it was put away, and just woke): both meant "end
        // it". A deleted one keeps its binding until the roster drops the
        // tab — that's what purges it.
        // (Decided in the probe below, on that probe's fresh window ids —
        // see `reapArchived`.)
        let now = Date()
        for entry in entries {
            let bound = store.sessions.filter { $0.profileID == entry.id && $0.windowIndex != nil }
            guard !bound.isEmpty, !probing.contains(entry.id),
                  now.timeIntervalSince(lastProbeAt[entry.id] ?? .distantPast) > 4 else { continue }
            probing.insert(entry.id)
            lastProbeAt[entry.id] = now
            let profileID = entry.id
            Task { [weak self] in
                defer { self?.probing.remove(profileID) }
                let cmd = Self.probeCommand(window: "")
                guard let out = try? await delegate.guestExec(profileID: profileID, command: cmd, timeout: 10),
                      let self else { return }
                let lines = Dictionary(Self.parseProbe(out).map { ($0.index, $0) },
                                       uniquingKeysWith: { a, _ in a })
                let boot = Self.parseBootID(out)
                if let boot { self.bootIDs[profileID] = boot }
                let windowIDs = Self.parseWindowIDs(out)
                self.reapArchived(entry: entry, boot: boot, windowIDs: windowIDs)
                for s in self.store.sessions where s.profileID == profileID {
                    guard s.windowIndex != nil, !s.isArchived, !s.isDeleted else { continue }
                    // A binding from an earlier boot is unbound, not probed.
                    if let boot, !self.store.checkBoot(s.id, bootID: boot) { continue }
                    guard let w = s.windowIndex else { continue }
                    // Another window at the index (ours closed): unbound too.
                    if let wid = windowIDs[w], !self.store.checkWindow(s.id, windowID: wid) { continue }
                    guard let p = lines[w] else { continue }
                    self.apply(p, to: s)
                }
            }
        }
    }

    /// An archived or deleted session whose tab is back (its workspace was
    /// asleep when it was put away, and just woke): both meant "end it" —
    /// but only a tab provably its own (`archivedTabVerdict`), judged on
    /// the probe just taken, never a cached one: a tab killed and replaced
    /// at the same index between two probes is a newcomer. A deleted one
    /// keeps its binding until the roster drops the tab — that's what
    /// purges it.
    private func reapArchived(entry: SessionListModel.VMEntry, boot: String?, windowIDs: [Int: String]) {
        let profileID = entry.id
        guard let delegate, entry.model.rosterLive else { return }
        for s in store.sessions where s.profileID == profileID && (s.isArchived || s.isDeleted) {
            guard let w = s.windowIndex, let tab = entry.model.tabs.first(where: { $0.index == w })
            else { continue }
            let owned = tab.worktreeBranch.map {
                delegate.codingTaskEngine.ownsLiveTab(profileID: profileID, branch: $0)
            } ?? false
            switch Self.archivedTabVerdict(sessionBoot: s.bootID, probeBoot: boot,
                                           sessionWindowID: s.windowID, probeWindowID: windowIDs[w],
                                           sessionDisplay: s.launchDisplay, tabDisplay: tab.display,
                                           taskOwned: owned) {
            case .wait:
                continue
            case .unbind:
                BACDebug.log("sessions", "\(s.isDeleted ? "deleted" : "archived") “\(s.title)”: tab \(w) is someone else's now — letting go")
                store.unbind(s.id)
            case .end:
                if s.isDeleted {
                    killTabIfShown(s)
                } else {
                    BACDebug.log("sessions", "archived “\(s.title)” is back — ending it")
                    close(s.id)
                }
            }
        }
    }

    // MARK: Folders

    private var lastFolderProbeAt: [UUID: Date] = [:]
    private var folderProbing: Set<UUID> = []
    private static let folderProbeEvery: TimeInterval = 30

    /// Every so often, ask each running workspace whether the folders its
    /// sessions live in are still there. A deleted folder greys the session
    /// out — readable, not resumable — until it shows up again.
    func probeFolders(entries: [SessionListModel.VMEntry]) {
        guard let delegate else { return }
        let now = Date()
        for entry in entries {
            let mine = store.sessions.filter { $0.profileID == entry.id && !$0.isLaunching && $0.cwd != "~" }
            let paths = Array(Set(mine.map { SessionHome.guestPath($0.cwd) })).sorted()
            guard !paths.isEmpty, !folderProbing.contains(entry.id),
                  now.timeIntervalSince(lastFolderProbeAt[entry.id] ?? .distantPast) > Self.folderProbeEvery
            else { continue }
            folderProbing.insert(entry.id)
            lastFolderProbeAt[entry.id] = now
            let profileID = entry.id
            let quoted = paths.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                .joined(separator: " ")
            let cmd = "for p in \(quoted); do if [ -d \"$p\" ]; then printf '1\\t%s\\n' \"$p\"; "
                + "else printf '0\\t%s\\n' \"$p\"; fi; done"
            Task { [weak self] in
                defer { self?.folderProbing.remove(profileID) }
                guard let out = try? await delegate.guestExec(profileID: profileID, command: cmd, timeout: 10),
                      let self else { return }
                var exists: [String: Bool] = [:]
                for line in out.split(whereSeparator: \.isNewline) {
                    let parts = line.split(separator: "\t", maxSplits: 1)
                    guard parts.count == 2 else { continue }
                    exists[String(parts[1])] = parts[0] == "1"
                }
                guard !exists.isEmpty else { return }
                for s in self.store.sessions where s.profileID == profileID {
                    guard let there = exists[SessionHome.guestPath(s.cwd)] else { continue }
                    // Flip only on a change: gone → back, or here → gone.
                    if (s.folderMissing == true) == there {
                        self.store.mutate(s.id) { $0.folderMissing = there ? nil : true }
                    }
                }
            }
        }
    }

    // MARK: Changes in the folder

    private var lastChangesProbeAt: [UUID: Date] = [:]
    private var changesProbing: Set<UUID> = []
    private static let changesProbeEvery: TimeInterval = 10

    /// Every so often, ask each running workspace whether the folders of
    /// its live sessions carry changes: uncommitted work when the folder is
    /// in a git repository (untracked files included, ignored ones not),
    /// else any file written since the session began — this run of it, a
    /// resume starts over. Hidden folders and node_modules don't count:
    /// agents keep their own state in dotfolders, and dependency trees
    /// churn. The windows pop the Files pane the first time a session
    /// reads dirty; a folder that reads clean again (a commit) re-arms it.
    func probeChanges(entries: [SessionListModel.VMEntry]) {
        guard let delegate else { return }
        let now = Date()
        for entry in entries {
            let live = store.sessions.filter {
                $0.profileID == entry.id && $0.windowIndex != nil && !$0.isArchived && !$0.isDeleted
            }
            guard !live.isEmpty, !changesProbing.contains(entry.id),
                  now.timeIntervalSince(lastChangesProbeAt[entry.id] ?? .distantPast) > Self.changesProbeEvery
            else { continue }
            changesProbing.insert(entry.id)
            lastChangesProbeAt[entry.id] = now
            let profileID = entry.id
            let cmd = Self.changesProbeCommand(live.map { s in
                (key: s.id.uuidString, path: SessionHome.guestPath(s.cwd),
                 since: max(s.createdAt, s.resumedAt ?? .distantPast))
            })
            Task { [weak self] in
                defer { self?.changesProbing.remove(profileID) }
                guard let out = try? await delegate.guestExec(profileID: profileID, command: cmd, timeout: 20),
                      let self else { return }
                let verdicts = Self.parseChangesProbe(out)
                for s in self.store.sessions where s.profileID == profileID {
                    guard let dirty = verdicts[s.id.uuidString] else { continue }
                    if dirty, s.changesSeenAt == nil {
                        BACDebug.log("sessions", "“\(s.title)”: changes in \(s.cwd)")
                        self.store.mutate(s.id) { $0.changesSeenAt = Date() }
                    } else if !dirty, s.changesSeenAt != nil {
                        self.store.mutate(s.id) { $0.changesSeenAt = nil }
                    }
                }
            }
        }
    }

    /// One line per target: `key<TAB>1` when its folder carries changes,
    /// `key<TAB>` when it reads clean — or can't be read at all (a missing
    /// folder is no reason to pop anything). Inside a repository git has
    /// the say (`status` on the folder's subtree); elsewhere the first file
    /// newer than `since` settles it, hidden folders and node_modules
    /// pruned, with a cap so a huge tree can't hold the probe up.
    static func changesProbeCommand(_ targets: [(key: String, path: String, since: Date)]) -> String {
        targets.map { t in
            let q = "'" + t.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let epoch = Int(t.since.timeIntervalSince1970)
            return "p=\(q); if git -C \"$p\" rev-parse --is-inside-work-tree >/dev/null 2>&1; then "
                + "r=$(git -C \"$p\" status --porcelain -- . 2>/dev/null | head -c1); else "
                + "r=$(timeout 8 find \"$p\" -mindepth 1 \\( -name '.*' -o -name node_modules \\) -prune "
                + "-o -type f -newermt '@\(epoch)' -print -quit 2>/dev/null); fi; "
                + "printf '%s\\t%s\\n' '\(t.key)' \"${r:+1}\""
        }.joined(separator: "; ")
    }

    /// Key → dirty, for every line the probe answered.
    static func parseChangesProbe(_ out: String) -> [String: Bool] {
        var verdicts: [String: Bool] = [:]
        for line in out.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = parts.first, !key.isEmpty else { continue }
            verdicts[String(key)] = parts.count == 2 && parts[1] == "1"
        }
        return verdicts
    }

    /// The workspace is reachable — booting or resuming it first when it
    /// isn't. The interactive start, alerts and all, when this is the user's
    /// own click; `quietly` for what an agent set off (a delegate elsewhere,
    /// a peer woken for a notice): no prompts, and the booted workspace
    /// stays off the stage — the user is looking at something else;
    /// `remotely` for a fat client's click: the start's prompts go to that
    /// client (`PendingPromptBroker`), never a modal on this Mac. Time the
    /// client spends on such a prompt doesn't count against the boot.
    func ensureUp(_ profileID: UUID, quietly: Bool = false, remotely: Bool = false) async -> Bool {
        guard let delegate else { return false }
        if (try? await delegate.guestExec(profileID: profileID, command: "true", timeout: 5)) != nil {
            return true
        }
        if !pendingBoots.contains(profileID) {
            pendingBoots.insert(profileID)
            if quietly {
                delegate.startProfileQuietly(profileID)
            } else if remotely {
                delegate.startProfileRemotely(profileID)
            } else {
                delegate.startProfile(profileID)
            }
        }
        defer { pendingBoots.remove(profileID) }
        var deadline = Date().addingTimeInterval(Self.bootTimeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: Self.bootPollInterval)
            if remotely, PendingPromptBroker.shared.hasPending(profileID: profileID) {
                deadline = Date().addingTimeInterval(Self.bootTimeout)
            }
            if (try? await delegate.guestExec(profileID: profileID, command: "true", timeout: 5)) != nil {
                return true
            }
            // A quiet start that hit a gate nobody's there to answer says so
            // at once rather than after the timeout.
            if quietly, delegate.unattendedLaunchRefusal(profileID) != nil { return false }
        }
        return false
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
#endif
