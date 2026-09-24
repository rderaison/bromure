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
    }

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
            cwd = "~/" + Self.syntheticFolderName(message: named ?? message, tool: req.tool)
        }
        let title = req.title?.trimmingCharacters(in: .whitespaces).nonEmpty
            ?? (message?.nonEmpty).map(AgentSession.title(fromMessage:))
            ?? AgentSession.defaultTitle(tool: req.tool, cwd: cwd)
        var s = AgentSession(profileID: req.profileID, tool: req.tool, title: title,
                             cwd: cwd, cloneURL: req.cloneURL?.nonEmpty,
                             openingMessage: message?.nonEmpty)
        s.launchingSince = Date()
        store.upsert(s)
        BACDebug.log("sessions", "start “\(title)” (\(req.tool.rawValue) in \(cwd))")
        launch(s.id, prompt: message ?? "", flags: "", attachments: req.attachments, remotely: remotely)
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
                       message: String?, remotely: Bool = false) -> UUID? {
        guard let parent = store.session(parentID), SessionHome.hasFolder(parent) else { return nil }
        let title = name.trimmingCharacters(in: .whitespaces).nonEmpty
            ?? String(format: NSLocalizedString("Worktree of %@", comment: "session title"), parent.title)
        let message = message?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        var s = AgentSession(profileID: parent.profileID, tool: tool, title: title,
                             cwd: parent.cwd, openingMessage: message)
        s.worktreeOf = parentID
        s.userTitled = true          // the worktree's name is the session's name
        s.launchingSince = Date()
        store.upsert(s)
        BACDebug.log("sessions", "start worktree “\(title)” off “\(parent.title)” (\(tool.rawValue))")
        launch(s.id, prompt: message ?? "", flags: "", worktreeSlug: Self.worktreeSlug(title),
               remotely: remotely)
        return s.id
    }

    /// A filesystem/branch-safe slug from a free-form name — the same rule
    /// the kanban's worktrees use.
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

    /// "hello-260915-1830": a few words of the message (or the agent's name)
    /// plus a timestamp, so folders never collide and still read at a glance.
    static func syntheticFolderName(message: String?, tool: Profile.Tool, now: Date = Date()) -> String {
        let words = (message ?? "").lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { !$0.isEmpty }
        var slug = ""
        for w in words {
            let next = slug.isEmpty ? w : slug + "-" + w
            if next.count > 28 { break }
            slug = next
        }
        if slug.isEmpty { slug = tool.rawValue }
        let f = DateFormatter()
        f.dateFormat = "yyMMdd-HHmm"
        return slug + "-" + f.string(from: now)
    }

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
        store.mutate(id) { $0.lastError = nil; $0.archivedAt = nil }
        BACDebug.log("sessions", "resume “\(s.title)”\(message == nil ? "" : " with a message")")
        Task { [weak self] in
            guard let self else { return }
            guard await self.ensureUp(s.profileID, quietly: quietly, remotely: remotely) else {
                self.store.mutate(id) { $0.lastError = NSLocalizedString(
                    "The workspace did not start in time", comment: "session resume") }
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
                if alive {
                    // Alive: the conversation is simply back on stage. Only
                    // something the user actually said gets typed.
                    if let message {
                        _ = try? await delegate.guestExec(
                            profileID: s.profileID,
                            command: CodingTaskEngine.typeCommand(tabIndex: w, text: message),
                            timeout: 15)
                    }
                } else {
                    // The agent exited, its shell is still there: relaunch
                    // in place so the conversation history is right at hand.
                    let cmd = ([s.tool.rawValue] + Self.resumeFlags(for: s).split(separator: " ").map(String.init))
                        .joined(separator: " ")
                    _ = try? await delegate.guestExec(
                        profileID: s.profileID,
                        command: "tmux send-keys -t bromure:\(w) -l '\(cmd)'; sleep 0.2; "
                            + "tmux send-keys -t bromure:\(w) Enter",
                        timeout: 15)
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
                if !alive, let message { self.deliverWhenAlive(id, message) }
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
        launch(id, prompt: inline ? (message ?? "") : "", flags: Self.resumeFlags(for: s), alreadyUp: true)
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
                    _ = try? await delegate.guestExec(
                        profileID: s.profileID,
                        command: CodingTaskEngine.typeCommand(tabIndex: w, text: text), timeout: 15)
                    return
                }
            }
        }
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
            let guestPath = ScheduledAutomationEngine.guestPath(s.cwd)
            let q = "'" + guestPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
            if let worktreeSlug {
                // The folder must be a git checkout; say so now rather than
                // waiting for a tab that never comes.
                let top = (try? await delegate.guestExec(
                    profileID: s.profileID,
                    command: "git -C \(q) rev-parse --show-toplevel 2>/dev/null", timeout: 15)) ?? ""
                guard !top.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
                    args: [guestPath, worktreeSlug, display, s.tool.rawValue, prompt] + self.backgroundArg(id)) else {
                    fail(NSLocalizedString("Couldn't reach the workspace — is it running?", comment: "task start"))
                    return
                }
                BACDebug.log("sessions", "“\(s.title)”: worktree-create sent (baseline \(baseline))")
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
            guard delegate.automationWorktreeCommand(
                profileNameOrID: s.profileID.uuidString, action: "agent-tab",
                args: [guestPath, display, s.tool.rawValue, prompt, flags] + self.backgroundArg(id)) else {
                fail(NSLocalizedString("Couldn't reach the workspace — is it running?", comment: "task start"))
                return
            }
            BACDebug.log("sessions", "“\(s.title)”: agent-tab sent (baseline \(baseline))")
        }
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
    let transcripts = SessionTranscriptCache()
    private var lastSnapshotAt: [UUID: Date] = [:]
    private var snapshotting: Set<UUID> = []

    /// Copy the session's transcript from the machine (while it's alive, on
    /// a timer; and once more when the agent goes away).
    private func snapshot(_ s: AgentSession) {
        guard let delegate, !snapshotting.contains(s.id) else { return }
        snapshotting.insert(s.id)
        lastSnapshotAt[s.id] = Date()
        Task { [weak self] in
            defer { self?.snapshotting.remove(s.id) }
            guard let raw = await delegate.fetchSessionTranscript(s), !raw.isEmpty else { return }
            self?.transcripts.save(s.id, Data(raw.utf8))
        }
    }
    private static let snapshotEvery: TimeInterval = 30

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
            + "tmux list-panes -s -t bromure -F '#{window_index} #{pane_tty} #{pane_title}' 2>/dev/null "
            + "| while read -r i t title; do \(window.isEmpty ? "" : "[ \"$i\" = \(window) ] || continue; ")"
            + "[ \"$title\" = \"$h\" ] && title=''; "
            + "a=$(ps -t \"${t#/dev/}\" -o args= 2>/dev/null "
            + "| grep -v -E '\(shellNames)' "
            + "| grep -E -o -m1 '\(agentNames)' "
            + "| head -1); "
            + AgentSessionLocator.pinnedTranscriptBlock(window: "$i", into: "tp")
            + "tid=\"${tp##*/}\"; tid=\"${tid%.jsonl}\"; "
            + "printf '%s\\t%s\\t%s\\t%s\\n' \"$i\" \"${a:-none}\" \"$tid\" \"$title\"; done"
    }

    struct ProbeLine: Equatable {
        let index: Int
        let alive: Bool
        var transcriptID: String? = nil
        let title: String
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
    static func resumeFlags(for s: AgentSession) -> String {
        if s.tool == .claude, let id = s.agentTranscriptID, isTranscriptID(id) {
            return "--resume \(id)"
        }
        return s.tool.resumeFlags
    }

    /// Apply one probe line to the session bound to that window.
    private func apply(_ p: ProbeLine, to s: AgentSession) {
        let wasAlive = s.agentAlive
        store.setLiveness(s.id, alive: p.alive)
        if p.alive, let title = SessionHome.cleanAgentTitle(p.title, agent: s.tool.rawValue, cwd: s.cwd) {
            store.setAgentTitle(s.id, title)
        }
        if p.alive, let tid = p.transcriptID { store.setTranscriptID(s.id, tid) }
        // Keep the local copy fresh while it runs; take its last words when
        // it stops.
        let now = Date()
        if p.alive {
            if now.timeIntervalSince(lastSnapshotAt[s.id] ?? .distantPast) > Self.snapshotEvery { snapshot(s) }
        } else if wasAlive == true {
            snapshot(s)
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
            apply(p, to: s)
        }
        return p.alive
    }

    /// Ask each running workspace which of its tabs has an agent in the
    /// foreground group of its tty (one shell round-trip per workspace,
    /// every few seconds). tmux's own `pane_current_command` can't tell:
    /// an agent under an interpreter (omp under bun) reads as "bash".
    func probeLiveness(entries: [SessionListModel.VMEntry]) {
        guard let delegate else { return }
        probeFolders(entries: entries)
        probeChanges(entries: entries)
        // An archived or deleted session whose tab is back (its workspace
        // was asleep when it was put away, and just woke): both meant "end
        // it". A deleted one keeps its binding until the roster drops the
        // tab — that's what purges it.
        for s in store.sessions where (s.isArchived || s.isDeleted) && s.windowIndex != nil {
            guard let entry = entries.first(where: { $0.id == s.profileID }), entry.model.rosterLive,
                  let tab = entry.model.tabs.first(where: { $0.index == s.windowIndex })
            else { continue }
            // Kill only a tab that is provably this session's: bound in the
            // boot the probe sees now (after a fresh boot the index belongs
            // to whatever opened since — a new session's tab, once) and,
            // when we named it, still carrying that name.
            guard let boot = bootIDs[s.profileID], s.bootID == boot else { continue }
            if let mine = s.launchDisplay, let d = tab.display, !d.isEmpty, d != mine { continue }
            if s.isDeleted {
                killTabIfShown(s)
            } else {
                BACDebug.log("sessions", "archived “\(s.title)” is back — ending it")
                close(s.id)
            }
        }
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
                for s in self.store.sessions where s.profileID == profileID {
                    guard s.windowIndex != nil else { continue }
                    // A binding from an earlier boot is unbound, not probed.
                    if let boot, !self.store.checkBoot(s.id, bootID: boot) { continue }
                    guard let w = s.windowIndex, let p = lines[w] else { continue }
                    self.apply(p, to: s)
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
