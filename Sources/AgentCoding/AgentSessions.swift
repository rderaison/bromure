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

    init(fileURL: URL? = nil) {
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
        save()
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
            guard !tabs.isEmpty else { continue }
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
                let home = ScheduledAutomationEngine.guestPath("~")
                let mineCwd = ScheduledAutomationEngine.guestPath(s.cwd)
                if !stale, s.launchDisplay == nil, mineCwd != home,
                   let tc = tab.cwd, !tc.isEmpty, ScheduledAutomationEngine.guestPath(tc) != mineCwd {
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
                    let bound = Set(sessions.compactMap { $0.windowIndex })
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
                    } else if let since = s.launchingSince,
                              now.timeIntervalSince(since) > Self.launchTimeout {
                        s.launchingSince = nil
                        s.lastError = NSLocalizedString(
                            "The agent never showed up. The workspace may run an older in-VM agent — restart it (Machines › ⋯ › Restart) and try again.",
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
                let title = Self.agentTitle(from: tab) ?? AgentSession.defaultTitle(tool: tool, cwd: cwd)
                let guestCwd = ScheduledAutomationEngine.guestPath(cwd)
                if let i = sessions.firstIndex(where: { cand in
                    guard cand.profileID == entry.id, cand.windowIndex == nil,
                          cand.launchingSince == nil, cand.tool == tool else { return false }
                    // The tab still carries the name we opened it under…
                    if let d = tab.display, !d.isEmpty, d == cand.launchDisplay { return true }
                    // …or it reads exactly like the session, in the same folder.
                    return cand.title == title && ScheduledAutomationEngine.guestPath(cand.cwd) == guestCwd
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
        if changed {
            sessions.sort { activity($0) > activity($1) }
            save()
        }
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
    }

    /// Is an agent running in the session's tab? The tty probe when we have
    /// one, else the roster label.
    @MainActor
    static func agentRunning(_ s: AgentSession, in tab: TabsModel.Tab) -> Bool {
        s.agentAlive ?? (BromureIcons.agentKind(forLabel: tab.label) != nil)
    }

    private func save() {
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
    /// The session's live tab, when its workspace is attached and the tab
    /// is still there.
    @MainActor
    static func liveTab(for s: AgentSession, in model: SessionListModel) -> TabsModel.Tab? {
        guard let w = s.windowIndex,
              let entry = model.entries.first(where: { $0.id == s.profileID }) else { return nil }
        return entry.model.tabs.first { $0.index == w }
    }

    /// Position of the live tab in its pane's roster (what selectTab wants).
    @MainActor
    static func liveTabPosition(for s: AgentSession, in model: SessionListModel) -> Int? {
        guard let w = s.windowIndex,
              let entry = model.entries.first(where: { $0.id == s.profileID }) else { return nil }
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
        if s.isLaunching { return .working }
        if s.hasEnded { return .ended }
        let ws = workspaceState(of: s, in: model)
        guard ws == .running || ws == .booting else { return .asleep }
        guard let tab = liveTab(for: s, in: model) else {
            // Running workspace, tab not (yet) in the roster.
            return model.entries.contains { $0.id == s.profileID } ? .ended : .asleep
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
        if let e = s.lastError, !e.isEmpty { return NSLocalizedString("Couldn't start", comment: "session status") }
        // Short, so it fits beside the machine's name in a narrow sidebar.
        switch bucket(for: s, in: model) {
        case .needsYou:
            return NSLocalizedString("Needs you", comment: "session status")
        case .working:
            if let tab = liveTab(for: s, in: model), !agentRunning(s, in: tab) {
                return NSLocalizedString("Starting…", comment: "session status")
            }
            return NSLocalizedString("Working…", comment: "session status")
        case .idle:
            return NSLocalizedString("Ready", comment: "session status")
        case .asleep:
            return NSLocalizedString("Asleep", comment: "session status")
        case .ended:
            return NSLocalizedString("Ended", comment: "session status")
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
            let folder = (ScheduledAutomationEngine.guestPath(cwd) as NSString).lastPathComponent.lowercased()
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

    /// The sidebar's order (ended ones, folded away, excluded) — what ⌘1–9 count.
    @MainActor
    static func ordered(_ sessions: [AgentSession], in model: SessionListModel) -> [AgentSession] {
        let groups = grouped(sessions, in: model)
        return SessionBucket.allCases.filter { $0 != .ended }.flatMap { groups[$0] ?? [] }
    }

    /// The session the home screen opens on: the remembered one if it's
    /// still around, else the most pressing bucket's newest.
    @MainActor
    static func initialSession(in store: AgentSessionStore, model: SessionListModel,
                               remembered: UUID?) -> AgentSession? {
        if let id = remembered, let s = store.session(id), !s.hasEnded { return s }
        let groups = grouped(store.sessions, in: model)
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
    let selected: Bool
    let onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
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
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color(hex: accentHex))
                        .frame(width: 6, height: 6)
                    Text(workspaceName)
                    Text("·").foregroundStyle(.tertiary)
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
        .padding(.leading, 10)
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
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}

/// The grouped session list: Needs you / Working / Ready / Asleep / Ended.
/// Empty buckets don't render; Ended starts collapsed.
struct SessionSectionsView: View {
    var store: AgentSessionStore
    @Bindable var model: SessionListModel
    var filter: String = ""
    let onSelect: (UUID) -> Void
    @State private var endedExpanded = false

    private var groups: [SessionBucket: [AgentSession]] {
        var sessions = store.sessions
        let q = filter.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            sessions = sessions.filter {
                $0.title.localizedCaseInsensitiveContains(q)
                    || ($0.openingMessage ?? "").localizedCaseInsensitiveContains(q)
                    || $0.cwd.localizedCaseInsensitiveContains(q)
            }
        }
        return SessionHome.grouped(sessions, in: model)
    }

    private func workspaceName(_ id: UUID) -> String {
        model.profileRows.first { $0.id == id }?.name ?? ""
    }
    private func accentHex(_ id: UUID) -> String {
        model.profileRows.first { $0.id == id }?.accentHex ?? "#888888"
    }

    var body: some View {
        let groups = groups
        VStack(alignment: .leading, spacing: 1) {
            if groups.isEmpty { emptyHint }
            ForEach(SessionBucket.allCases) { bucket in
                if let list = groups[bucket], !list.isEmpty {
                    section(bucket, list)
                }
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
        .padding(.top, 16)
    }

    @ViewBuilder
    private func section(_ bucket: SessionBucket, _ list: [AgentSession]) -> some View {
        let collapsible = bucket == .ended
        // A collapsed section never hides the session on stage.
        let expanded = !collapsible || endedExpanded
            || list.contains { $0.id == model.selectedSessionID }
        VStack(alignment: .leading, spacing: 1) {
            Button {
                if collapsible { withAnimation(.easeInOut(duration: 0.15)) { endedExpanded.toggle() } }
            } label: {
                HStack(spacing: 6) {
                    Text(bucket.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .tracking(0.7)
                    if bucket.badged {
                        SidebarAttentionBadge(count: list.count, tint: bucket.tint)
                    } else if collapsible {
                        Text("\(list.count)")
                            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if collapsible {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!collapsible)
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .padding(.top, 14)
            .padding(.bottom, 4)

            if expanded {
                ForEach(list) { s in
                    SessionRowView(
                        session: s,
                        workspaceName: workspaceName(s.profileID),
                        accentHex: accentHex(s.profileID),
                        dot: SessionHome.dot(for: s, in: model),
                        statusLine: SessionHome.statusLine(for: s, in: model),
                        when: s.isLaunching ? nil : SessionHome.elapsedCompact(since: SessionHome.lastActivity(s)),
                        selected: model.selectedSessionID == s.id,
                        onSelect: { onSelect(s.id) })
                }
            }
        }
    }
}
