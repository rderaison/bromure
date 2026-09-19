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
    private weak var delegate: ACAppDelegate?
    let store: AgentSessionStore

    private var pendingBoots: Set<UUID> = []
    private static let bootTimeout: TimeInterval = 180
    private static let bootPollInterval: UInt64 = 3_000_000_000

    init(store: AgentSessionStore, delegate: ACAppDelegate?) {
        self.store = store
        self.delegate = delegate
    }

    /// The platform-neutral request lives with the model (AgentSessions.swift)
    /// so the shared new-session screen can build one on every platform.
    typealias NewSessionRequest = AgentSessionRequest

    /// Create the session record and launch it. The record is on screen
    /// immediately (the chat surface with the opening message); the tab
    /// binds to it as soon as the workspace reports it.
    @discardableResult
    func start(_ req: NewSessionRequest) -> UUID {
        let message = req.openingMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        var cwd = req.cwd.trimmingCharacters(in: .whitespaces)
        // No folder named: every session gets a fresh one of its own in the
        // home, named after the message — never the shared home itself.
        if cwd.isEmpty || cwd == "~" || cwd == "~/" {
            cwd = "~/" + Self.syntheticFolderName(message: message, tool: req.tool)
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
        launch(s.id, prompt: message ?? "", flags: "")
        return s.id
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
    func resume(_ id: UUID, message: String? = nil) {
        guard let s = store.session(id), let delegate else { return }
        if s.folderMissing == true {
            store.mutate(id) { $0.lastError = NSLocalizedString(
                "The folder no longer exists on the machine.", comment: "session resume") }
            return
        }
        let message = message?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        store.mutate(id) { $0.lastError = nil }
        BACDebug.log("sessions", "resume “\(s.title)”\(message == nil ? "" : " with a message")")
        Task { [weak self] in
            guard let self else { return }
            guard await self.ensureUp(s.profileID) else {
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
                    let cmd = ([s.tool.rawValue] + s.tool.resumeFlags.split(separator: " ").map(String.init))
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
                }
                if !alive, let message { self.deliverWhenAlive(id, message) }
                return
            }
            // Tab gone (or workspace was rebooted): a fresh tab in the same
            // folder, resuming the last conversation there.
            self.store.mutate(id) {
                $0.windowIndex = nil
                $0.endedAt = nil
                $0.launchingSince = Date()
                $0.launchBaselineIndex = nil
                $0.resumedAt = Date()
                $0.agentAlive = nil
            }
            // Claude and Oh My Pi take the message on the command line next
            // to their resume flag; Codex and Kimi don't, so it's typed once
            // they're up.
            let inline = message != nil && (s.tool == .claude || s.tool == .omp)
            self.launch(id, prompt: inline ? (message ?? "") : "", flags: s.tool.resumeFlags, alreadyUp: true)
            if !inline, let message { self.deliverWhenAlive(id, message) }
        }
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

    // MARK: Launch

    private func launch(_ id: UUID, prompt: String, flags: String, alreadyUp: Bool = false) {
        Task { [weak self] in
            guard let self, let delegate = self.delegate, let s = self.store.session(id) else { return }
            @MainActor func fail(_ reason: String) {
                self.store.mutate(id) { $0.launchingSince = nil; $0.lastError = reason }
            }
            if !alreadyUp {
                guard await self.ensureUp(s.profileID) else {
                    fail(NSLocalizedString("The workspace did not start in time", comment: "session start"))
                    return
                }
            }
            let guestPath = ScheduledAutomationEngine.guestPath(s.cwd)
            let q = "'" + guestPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
            // Remember which tabs were there, so the new one can be told
            // apart — the roster may lag right after a boot, so ask tmux.
            var baseline = delegate.pane(for: s.profileID)?.model.tabs.map(\.index).max() ?? -1
            if let out = try? await delegate.guestExec(
                profileID: s.profileID,
                command: "tmux list-windows -t bromure -F '#{window_index}' 2>/dev/null | sort -n | tail -1",
                timeout: 8), let n = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) {
                baseline = max(baseline, n)
            }
            let display = s.title
            self.store.mutate(id) { $0.launchBaselineIndex = baseline; $0.launchDisplay = display }
            guard delegate.automationWorktreeCommand(
                profileNameOrID: s.profileID.uuidString, action: "agent-tab",
                args: [guestPath, display, s.tool.rawValue, prompt, flags]) else {
                fail(NSLocalizedString("Couldn't reach the workspace — is it running?", comment: "task start"))
                return
            }
            BACDebug.log("sessions", "“\(s.title)”: agent-tab sent (baseline \(baseline))")
        }
    }

    // MARK: Liveness

    private var probing: Set<UUID> = []
    private var lastProbeAt: [UUID: Date] = [:]

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
    /// One line per window: `index<TAB>agent-or-none<TAB>pane title`. The
    /// title is what the agent set on its terminal (OSC 2) — Claude Code and
    /// Oh My Pi both write a summary of the conversation there.
    private static func probeCommand(window: String) -> String {
        // A fresh shell's title is the hostname until the agent speaks up —
        // never a session name.
        "h=$(hostname 2>/dev/null); "
            + "tmux list-panes -s -t bromure -F '#{window_index} #{pane_tty} #{pane_title}' 2>/dev/null "
            + "| while read -r i t title; do \(window.isEmpty ? "" : "[ \"$i\" = \(window) ] || continue; ")"
            + "[ \"$title\" = \"$h\" ] && title=''; "
            + "a=$(ps -t \"${t#/dev/}\" -o args= 2>/dev/null "
            + "| grep -v -E '\(shellNames)' "
            + "| grep -E -o -m1 '\(agentNames)' "
            + "| head -1); printf '%s\\t%s\\t%s\\n' \"$i\" \"${a:-none}\" \"$title\"; done"
    }

    private struct ProbeLine { let index: Int; let alive: Bool; let title: String }
    private static func parseProbe(_ out: String) -> [ProbeLine] {
        out.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 2, let idx = Int(parts[0]) else { return nil }
            return ProbeLine(index: idx, alive: parts[1] != "none",
                             title: parts.count == 3 ? String(parts[2]) : "")
        }
    }

    /// Apply one probe line to the session bound to that window.
    private func apply(_ p: ProbeLine, to s: AgentSession) {
        let wasAlive = s.agentAlive
        store.setLiveness(s.id, alive: p.alive)
        if p.alive, let title = SessionHome.cleanAgentTitle(p.title, agent: s.tool.rawValue, cwd: s.cwd) {
            store.setAgentTitle(s.id, title)
        }
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
        if let s = store.session(profileID: profileID, windowIndex: window) { apply(p, to: s) }
        return p.alive
    }

    /// Ask each running workspace which of its tabs has an agent in the
    /// foreground group of its tty (one shell round-trip per workspace,
    /// every few seconds). tmux's own `pane_current_command` can't tell:
    /// an agent under an interpreter (omp under bun) reads as "bash".
    func probeLiveness(entries: [SessionListModel.VMEntry]) {
        guard let delegate else { return }
        probeFolders(entries: entries)
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
                for s in self.store.sessions where s.profileID == profileID {
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

    /// The workspace is reachable — booting or resuming it first when it
    /// isn't (the interactive start, alerts and all: this is the user's own
    /// click, not an unattended automation).
    private func ensureUp(_ profileID: UUID) async -> Bool {
        guard let delegate else { return false }
        if (try? await delegate.guestExec(profileID: profileID, command: "true", timeout: 5)) != nil {
            return true
        }
        if !pendingBoots.contains(profileID) {
            pendingBoots.insert(profileID)
            delegate.startProfile(profileID)
        }
        defer { pendingBoots.remove(profileID) }
        let deadline = Date().addingTimeInterval(Self.bootTimeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: Self.bootPollInterval)
            if (try? await delegate.guestExec(profileID: profileID, command: "true", timeout: 5)) != nil {
                return true
            }
        }
        return false
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
#endif
