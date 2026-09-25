#if os(macOS)
import Foundation

// MARK: - Switchboard (macOS)
//
// One agent session that keeps track of all the others: what's running,
// what's stuck, what needs the user; it relays their answers and starts,
// resumes or puts away sessions for them (SWITCHBOARD_PLAN.md). Underneath
// it's an ordinary Claude session with a role — its own folder
// (~/.bromure/switchboard, whose CLAUDE.md is its brief) in one of the
// user's workspaces, launched with the `bromure-switchboard` MCP on its
// command line (vsock 5836, SwitchboardMCPServer) so no other session ever
// sees those tools. The host keeps the event log the tools read, wakes the
// Switchboard with a one-line notice when something worth its attention
// happens (the delegation engine's pattern — no long-poll, so a message
// the user types is never stuck behind a blocked tool call), and checks
// every answer the Switchboard types into a blocked session against the
// user's own words in the Switchboard's conversation.

struct SwitchboardEvent {
    enum Kind: String {
        case sessionStarted = "session_started"
        case sessionNeedsYou = "session_needs_you"
        case sessionDone = "session_done"
        case sessionEnded = "session_ended"
        case apiRefused = "api_refused"
    }
    let seq: Int
    let at: Date
    let kind: Kind
    /// nil when the event is about a workspace, not one session.
    let sessionID: UUID?
    let text: String
    /// Worth waking the Switchboard for.
    let notable: Bool
}

@MainActor
final class SwitchboardEngine {
    weak var delegate: ACAppDelegate?
    let sessions: AgentSessionStore
    let sessionEngine: AgentSessionEngine
    var profiles: () -> [Profile] = { [] }
    var listModel: () -> SessionListModel? = { nil }
    /// The user's phone (MessagingConnectorEngine): send on a channel (nil =
    /// whichever is connected); whether any channel is connected.
    var sendToPhone: ((String, ConnectorChannel.Kind?) async -> Bool)?
    var phoneLinked: () -> Bool = { false }
    /// The channel the user last wrote from — where replies go.
    private(set) var lastPhoneChannel: ConnectorChannel.Kind?
    /// STOP from the phone: the Switchboard's act-tools refuse until RESUME.
    /// Decided here, before the model ever sees the message.
    private(set) var paused = false

    /// The Switchboard's folder in the guest; its CLAUDE.md is the brief.
    static let folder = "~/.bromure/switchboard"
    /// The guest-side MCP config (staged in the meta share by SessionDisk)
    /// and the allow rule that lets its tools run without a prompt each.
    static let launchFlags = "--mcp-config \(SessionDisk.switchboardMCPConfigGuestPath) --allowedTools mcp__switchboard"
    /// Notices start with this, so the provenance check can tell them from
    /// what the user typed.
    static let noticePrefix = "[Switchboard]"
    static let kickoff = "You are the Switchboard — your brief is CLAUDE.md in this folder. Start by calling list_sessions and give me a short status (a few lines), then end your turn."
    /// A room's Switchboard opening line.
    static func kickoff(room: String) -> String {
        "You are the Switchboard of the room “\(room)” — your brief is CLAUDE.md in this folder. Start by calling list_sessions and give me a short status of the room (a few lines), then end your turn."
    }
    /// Where a room's Switchboard lives in the guest (its own transcript).
    static func folder(room: AgentRoom) -> String { "~/.bromure/rooms/\(room.slug)" }

    private(set) var events: [SwitchboardEvent] = []
    private var nextSeq = 1
    /// Highest event seq `next_events` has handed out.
    /// Per Switchboard (the global one and each room's): the highest event
    /// seq `next_events` handed it, the newest it was noticed about, when.
    private var consumed: [UUID: Int] = [:]
    private var noticed: [UUID: Int] = [:]
    private var lastNotice: [UUID: Date] = [:]
    /// Room names, for room Switchboards' briefs and scope notes.
    var roomName: (UUID) -> String? = { _ in nil }
    private var lastBuckets: [UUID: SessionBucket] = [:]
    private var primed = false
    /// Sessions the Switchboard acted on or started — their completion is
    /// worth a notice.
    private var touched: Set<UUID> = []
    /// When a session turned "needs you" (the event waits for it to hold),
    /// and the sessions already reported — not reported again until they
    /// have worked in between. An idle agent's status can flap back to
    /// "needs you" with nothing on its screen; each flap used to wake the
    /// Switchboard for nothing.
    private var needsYouSince: [UUID: Date] = [:]
    private var needsYouReported: Set<UUID> = []
    static let needsYouHold: TimeInterval = 8

    private var timer: Timer?
    /// The last refused model call per workspace: host, HTTP status, when.
    private(set) var apiRefusals: [UUID: (host: String, status: Int, at: Date)] = [:]
    static let refusalRepeat: TimeInterval = 10 * 60

    static let eventCap = 400
    static let noticeSpacing: TimeInterval = 20
    /// Answers must quote a message the user typed within this window.
    static let provenanceWindow: TimeInterval = 30 * 60

    init(sessions: AgentSessionStore, sessionEngine: AgentSessionEngine, delegate: ACAppDelegate?) {
        self.sessions = sessions
        self.sessionEngine = sessionEngine
        self.delegate = delegate
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: The Switchboard session

    var switchboard: AgentSession? { SwitchboardGate.switchboard(in: sessions.sessions) }

    /// The Switchboard, started (or brought back) when need be: in
    /// `preferred`'s workspace, else where the user was last active, else
    /// the first workspace. nil when there's no workspace at all.
    /// A room's Switchboard, if it has one.
    func switchboard(room: UUID) -> AgentSession? {
        sessions.sessions.first { $0.isSwitchboard && $0.roomID == room && !$0.isDeleted }
    }

    /// Every Switchboard there is — the global one and the rooms'.
    var allSwitchboards: [AgentSession] {
        sessions.sessions.filter { $0.isSwitchboard && !$0.isDeleted }
    }

    /// Whether `s` is within `me`'s reach: everything for the global
    /// Switchboard, the room's sessions for a room's.
    func inScope(_ s: AgentSession, of me: AgentSession) -> Bool {
        guard let room = me.roomID else { return true }
        return s.roomID == room
    }

    @discardableResult
    func ensureSwitchboard(preferred: UUID? = nil, room: AgentRoom? = nil, remotely: Bool = false) -> UUID? {
        if let room {
            if let c = switchboard(room: room.id) {
                wake(c, remotely: remotely)
                return c.id
            }
            // Where the room's sessions mostly run, else where the user was
            // last active.
            let members = sessions.sessions.filter { $0.roomID == room.id && !$0.isSwitchboard && !$0.isDeleted }
            let counts = Dictionary(grouping: members, by: \.profileID).mapValues(\.count)
            let home = counts.max { $0.value < $1.value }?.key
            let recent = sessions.sessions.filter { !$0.isSwitchboard && !$0.isDeleted }
                .max { SessionHome.lastActivity($0) < SessionHome.lastActivity($1) }
            guard let pid = home ?? recent?.profileID ?? profiles().first?.id else { return nil }
            let id = sessionEngine.start(.init(
                profileID: pid, tool: .claude, cwd: Self.folder(room: room),
                openingMessage: Self.kickoff(room: room.name),
                title: room.name, role: AgentSession.switchboardRole, roomID: room.id), remotely: remotely)
            sessions.mutate(id) { $0.userTitled = true }
            BACDebug.log("switchboard", "room “\(room.name)” Switchboard started in workspace \(pid)")
            return id
        }
        if let c = switchboard {
            wake(c, remotely: remotely)
            return c.id
        }
        let recent = sessions.sessions
            .filter { !$0.isSwitchboard && !$0.isDeleted }
            .max { SessionHome.lastActivity($0) < SessionHome.lastActivity($1) }
        let all = profiles()
        guard let pid = preferred.flatMap({ id in all.first { $0.id == id }?.id })
                ?? recent?.profileID ?? all.first?.id else { return nil }
        let id = sessionEngine.start(.init(
            profileID: pid, tool: .claude, cwd: Self.folder,
            openingMessage: Self.kickoff,
            title: NSLocalizedString("Switchboard", comment: "switchboard session title"),
            role: AgentSession.switchboardRole), remotely: remotely)
        sessions.mutate(id) { $0.userTitled = true }
        BACDebug.log("switchboard", "started in workspace \(pid)")
        return id
    }

    /// Bring a Switchboard back if it's put away or its agent is gone.
    private func wake(_ c: AgentSession, remotely: Bool) {
        if c.isArchived { sessionEngine.unarchive(c.id) }
        let model = listModel()
        let bucket = model.map { SessionHome.bucket(for: c, in: $0) }
        if c.hasEnded || c.agentAlive == false || bucket == .ended || bucket == .asleep {
            sessionEngine.resume(c.id, quietly: true, remotely: remotely)
        }
    }

    /// The shell line that writes the brief into the Switchboard's folder
    /// before its agent starts (AgentSessionEngine.launch). A room's
    /// Switchboard gets the room section on top of the common brief.
    static func briefCommand(guestFolder: String, roomName: String? = nil) -> String {
        let q = "'" + guestFolder.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let text = roomName.map { SwitchboardBrief.text + SwitchboardBrief.roomSection($0) } ?? SwitchboardBrief.text
        let b64 = Data(text.utf8).base64EncodedString()
        return "mkdir -p \(q) && echo \(b64) | base64 -d > \(q)/CLAUDE.md"
    }

    // MARK: Events

    private func tick() {
        guard let model = listModel() else { return }
        var seen: Set<UUID> = []
        for s in sessions.sessions where !s.isSwitchboard && !s.isDeleted && !s.isArchived {
            seen.insert(s.id)
            let b = SessionHome.bucket(for: s, in: model)
            let prev = lastBuckets[s.id]
            lastBuckets[s.id] = b
            if b == .working { needsYouReported.remove(s.id) }
            if b != .needsYou { needsYouSince.removeValue(forKey: s.id) }
            // A "needs you" that has held long enough, not reported yet.
            if primed, b == .needsYou, let since = needsYouSince[s.id],
               Date().timeIntervalSince(since) >= Self.needsYouHold,
               !needsYouReported.contains(s.id) {
                needsYouReported.insert(s.id)
                needsYouSince.removeValue(forKey: s.id)
                append(.sessionNeedsYou, s, "\(label(s)) needs you", notable: true)
            }
            guard primed else { continue }
            guard let prev else {
                if b != .ended && b != .asleep {
                    append(.sessionStarted, s, "\(label(s)) started", notable: false)
                }
                continue
            }
            guard prev != b else { continue }
            switch (prev, b) {
            case (_, .needsYou):
                if !needsYouReported.contains(s.id) { needsYouSince[s.id] = Date() }
            case (.working, .idle):
                append(.sessionDone, s, "\(label(s)) finished its turn", notable: touched.contains(s.id))
            case (.working, .ended), (.idle, .ended), (.needsYou, .ended):
                append(.sessionEnded, s, "\(label(s)) ended", notable: touched.contains(s.id))
            default:
                break
            }
        }
        for id in lastBuckets.keys where !seen.contains(id) { lastBuckets.removeValue(forKey: id) }
        primed = true
        deliverNotice()
    }

    private func append(_ kind: SwitchboardEvent.Kind, _ s: AgentSession?, _ text: String, notable: Bool) {
        events.append(SwitchboardEvent(seq: nextSeq, at: Date(), kind: kind, sessionID: s?.id,
                                     text: text, notable: notable))
        nextSeq += 1
        if events.count > Self.eventCap { events.removeFirst(events.count - Self.eventCap) }
        BACDebug.log("switchboard", "event: \(text)")
    }

    /// The Switchboard just looked at everything (list_sessions): what was
    /// pending is no longer news, so no notice wakes it for that.
    func markAllSeen(for me: AgentSession) {
        consumed[me.id] = max(consumed[me.id] ?? 0, nextSeq - 1)
        noticed[me.id] = max(noticed[me.id] ?? 0, consumed[me.id] ?? 0)
    }

    /// An event `me` should hear about: any for the global Switchboard;
    /// for a room's, those about its sessions.
    private func concerns(_ e: SwitchboardEvent, _ me: AgentSession) -> Bool {
        guard me.roomID != nil else { return true }
        guard let sid = e.sessionID, let s = sessions.session(sid) else { return false }
        return inScope(s, of: me)
    }

    /// A model host refused a call from `profileID`'s machine: the key is
    /// wrong, revoked, or out of credit (401/403/402). The proxy knows the
    /// workspace, not the tab, so the session is named when only one of
    /// that workspace's sessions was working; otherwise the workspace is.
    /// Once per workspace per 10 minutes (per status), so a retry loop
    /// doesn't flood the Switchboard.
    func noteAPIResult(profileID: UUID, host: String, status: Int) {
        guard [401, 402, 403].contains(status) else { return }
        if let last = apiRefusals[profileID], last.status == status,
           Date().timeIntervalSince(last.at) < Self.refusalRepeat {
            apiRefusals[profileID] = (host, status, last.at)
            return
        }
        apiRefusals[profileID] = (host, status, Date())
        let why: String
        switch status {
        case 401: why = "rejected its API key"
        case 402: why = "refused it for billing (out of credit?)"
        default:  why = "denied it access (forbidden — wrong key or plan?)"
        }
        let working = sessions.sessions.filter {
            $0.profileID == profileID && !$0.isDeleted && !$0.isArchived
                && (bucket($0) == .working || $0.isLaunching)
        }
        let ws = workspaceName(profileID)
        if working.count == 1, let s = working.first {
            append(.apiRefused, s, "\(host) \(why) for \(label(s)) (HTTP \(status), workspace \(ws))",
                   notable: true)
        } else {
            append(.apiRefused, nil, "\(host) \(why) for a session in workspace “\(ws)” (HTTP \(status))",
                   notable: true)
        }
    }

    /// The refusal a session's workspace had in the last 10 minutes, as a
    /// line for list_sessions.
    func recentRefusal(for s: AgentSession) -> String? {
        guard let r = apiRefusals[s.profileID],
              Date().timeIntervalSince(r.at) < Self.refusalRepeat else { return nil }
        return "model calls from its workspace are being refused: HTTP \(r.status) from \(r.host)"
    }

    /// Events after `cursor` (default: what `next_events` hasn't handed out
    /// yet), waiting up to `timeout` for one when there's none.
    func nextEvents(for me: AgentSession, after cursor: Int?, timeout: TimeInterval) async -> [SwitchboardEvent] {
        let from = cursor ?? consumed[me.id] ?? 0
        let deadline = Date().addingTimeInterval(min(max(timeout, 0), 60))
        while true {
            let got = events.filter { $0.seq > from && concerns($0, me) }
            if !got.isEmpty {
                let page = Array(got.prefix(50))
                consumed[me.id] = max(consumed[me.id] ?? 0, page.last!.seq)
                return page
            }
            if Date() >= deadline { return [] }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    /// Wake the Switchboard with one line when events worth its attention
    /// are waiting and its prompt is free. Nothing is typed while it's
    /// mid-turn (it reads events when it acts anyway), asleep, or asking
    /// the user something.
    private func deliverNotice() {
        for c in allSwitchboards { deliverNotice(to: c) }
    }

    private func deliverNotice(to c: AgentSession) {
        guard !c.isLaunching, !c.hasEnded, c.agentAlive == true,
              let w = c.windowIndex, let delegate else { return }
        let pending = events.filter { $0.seq > (consumed[c.id] ?? 0) && $0.notable && concerns($0, c) }
        guard let newest = pending.last, newest.seq > (noticed[c.id] ?? 0) else { return }
        if let last = lastNotice[c.id], Date().timeIntervalSince(last) < Self.noticeSpacing { return }
        let status = delegate.pane(for: c.profileID)?.model.tabs.first { $0.index == w }?.agentStatus
        guard status == nil || status == .done else { return }
        let head = pending.count == 1 ? pending[0].text
            : "\(pending.count) events, latest: \(newest.text)"
        let line = "\(Self.noticePrefix) \(head) — call next_events."
        noticed[c.id] = newest.seq
        lastNotice[c.id] = Date()
        Task {
            _ = try? await delegate.guestExec(
                profileID: c.profileID,
                command: CodingTaskEngine.typeCommand(tabIndex: w, text: line), timeout: 15)
        }
    }

    // MARK: The phone

    static func phoneLabel(_ kind: ConnectorChannel.Kind) -> String {
        kind == .signal ? "Signal" : "WhatsApp"
    }

    /// A message from the user's phone (already checked to be theirs).
    /// STOP / RESUME are handled right here; anything else is typed into
    /// the Switchboard as "[Signal] …" — a turn the user said, as far as the
    /// provenance check goes — starting or waking the Switchboard if need be.
    func phoneMessage(_ kind: ConnectorChannel.Kind, _ text: String) {
        lastPhoneChannel = kind
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/.!"))
        if word == "stop" {
            paused = true
            BACDebug.log("switchboard", "paused from \(Self.phoneLabel(kind))")
            if let c = switchboard, let w = c.windowIndex, c.agentAlive == true, let delegate {
                Task { _ = try? await delegate.guestExec(profileID: c.profileID,
                                                         command: "tmux send-keys -t bromure:\(w) Escape", timeout: 10) }
            }
            Task { _ = await sendToPhone?("Paused — I won't act on any session. Send RESUME to continue.", kind) }
            return
        }
        if word == "resume" {
            paused = false
            BACDebug.log("switchboard", "resumed from \(Self.phoneLabel(kind))")
            Task { _ = await sendToPhone?("Resumed.", kind) }
            return
        }
        // One line: a newline would submit the prompt half-way.
        let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " / ")
        let line = "[\(Self.phoneLabel(kind))] " + String(flat.prefix(1500))
        // An existing Switchboard is woken by exactly one resume — the one that
        // carries the message. (ensureSwitchboard would resume it too, and two
        // relaunches typed at once interleave their keystrokes on one line.)
        let existing = switchboard
        if let e = existing, e.isArchived { sessionEngine.unarchive(e.id) }
        guard let id = existing?.id ?? ensureSwitchboard(), let c = sessions.session(id) else {
            Task { _ = await sendToPhone?("There's no workspace to run the Switchboard in.", kind) }
            return
        }
        if existing == nil {
            deliverAfterLaunch(id, line)
        } else if let w = c.windowIndex, !c.hasEnded, c.agentAlive == true, !c.isLaunching, let delegate {
            // Typed even mid-turn: the agent queues it for its next turn.
            Task {
                _ = try? await delegate.guestExec(profileID: c.profileID,
                                                  command: CodingTaskEngine.typeCommand(tabIndex: w, text: line),
                                                  timeout: 15)
            }
        } else if c.isLaunching {
            deliverAfterLaunch(id, line)
        } else {
            sessionEngine.resume(id, message: line, quietly: true)
        }
    }

    /// A Switchboard just being started: type the message once its agent runs.
    private func deliverAfterLaunch(_ id: UUID, _ line: String) {
        Task { [weak self] in
            for _ in 0..<120 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, let c = self.sessions.session(id) else { return }
                if let w = c.windowIndex, c.agentAlive == true, !c.isLaunching, let delegate = self.delegate {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    _ = try? await delegate.guestExec(profileID: c.profileID,
                                                      command: CodingTaskEngine.typeCommand(tabIndex: w, text: line),
                                                      timeout: 15)
                    return
                }
            }
        }
    }

    /// Reply on the phone (the channel the user last wrote from).
    func messageUser(_ text: String) async -> String? {
        guard phoneLinked() else {
            return "No phone is connected (File › Infrastructure › Signal / WhatsApp Connector). Answer in this conversation instead."
        }
        guard let send = sendToPhone, await send(text, lastPhoneChannel) else {
            return "The message didn't go out — the connector may be stopped or the account disconnected."
        }
        return nil
    }

    // MARK: Addressing sessions

    /// What the Switchboard and the user call a session: its @nickname when it
    /// has one, else a slug of its title (made unique).
    func handles() -> [UUID: String] {
        var out: [UUID: String] = [:]
        var taken: Set<String> = []
        let list = sessions.sessions.filter { !$0.isSwitchboard && !$0.isDeleted }
            .sorted { $0.createdAt < $1.createdAt }
        for s in list {
            if let n = s.nickname, !n.isEmpty { out[s.id] = n; taken.insert(n.lowercased()) }
        }
        for s in list where out[s.id] == nil {
            let words = s.title.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .prefix(3).joined(separator: "-")
            let base = words.isEmpty ? s.tool.rawValue : words
            var h = base
            var n = 2
            while taken.contains(h) { h = "\(base)-\(n)"; n += 1 }
            taken.insert(h)
            out[s.id] = h
        }
        return out
    }

    func label(_ s: AgentSession) -> String {
        "“\(handles()[s.id] ?? s.title)”"
    }

    /// For `me`: a session in its room by any key; one outside the room only
    /// when named exactly (@nickname, handle, id or title) — a room's
    /// Switchboard reaches beyond its room only when told to by name.
    func resolve(_ key: String, for me: AgentSession) -> AgentSession? {
        guard let s = resolve(key) else { return nil }
        return s
    }

    /// A session by id, handle, @nickname or exact title.
    func resolve(_ key: String) -> AgentSession? {
        let k = key.trimmingCharacters(in: .whitespaces)
        let bare = k.hasPrefix("@") ? String(k.dropFirst()) : k
        let candidates = sessions.sessions.filter { !$0.isSwitchboard && !$0.isDeleted }
        if let id = UUID(uuidString: bare), let s = candidates.first(where: { $0.id == id }) { return s }
        let hs = handles()
        if let s = candidates.first(where: { hs[$0.id]?.lowercased() == bare.lowercased() }) { return s }
        if let s = candidates.first(where: { $0.nickname?.lowercased() == bare.lowercased() }) { return s }
        return candidates.first { $0.title.lowercased() == bare.lowercased() }
    }

    func bucket(_ s: AgentSession) -> SessionBucket? {
        listModel().map { SessionHome.bucket(for: s, in: $0) }
    }

    func workspaceName(_ id: UUID) -> String {
        profiles().first { $0.id == id }?.name ?? ""
    }

    func markTouched(_ id: UUID) { touched.insert(id) }

    // MARK: Reading sessions

    /// The parsed conversation, freshest source first (the live file, else
    /// the local copy).
    func transcript(_ s: AgentSession) async -> [TranscriptItem] {
        var raw: Data?
        if let live = await delegate?.fetchSessionTranscript(s), !live.isEmpty {
            raw = Data(live.utf8)
        } else {
            raw = sessionEngine.transcripts.load(s.id)
        }
        guard let raw else { return [] }
        return AgentTranscript.parse(raw, agent: s.tool.rawValue)
    }

    /// The last lines on the session's screen — what a permission prompt or
    /// a TUI dialog looks like, which no transcript records.
    func screen(_ s: AgentSession, lines: Int = 40) async -> String? {
        guard let w = s.windowIndex, !s.hasEnded, let delegate else { return nil }
        let out = try? await delegate.guestExec(
            profileID: s.profileID,
            // awk drops the blank rows under the last line of output.
            command: "tmux capture-pane -p -J -t bromure:\(w) 2>/dev/null "
                + "| awk 'NF{n=NR} {l[NR]=$0} END{for(i=1;i<=n;i++)print l[i]}' | tail -n \(lines)",
            timeout: 10)
        return out?.trimmingCharacters(in: .newlines)
    }

    /// What a session is waiting on: its AskUserQuestion (with numbered
    /// options) when one is standing — nothing the user said came after
    /// it — and its screen, which shows any other prompt.
    func pending(_ s: AgentSession) async -> [String: Any] {
        var o: [String: Any] = [:]
        let items = await transcript(s)
        if let q = Self.standingQuestion(items) {
            o["question"] = q.question
            o["options"] = q.options.enumerated().map { "\($0.offset + 1)) \($0.element.label)"
                + ($0.element.description.isEmpty ? "" : " — \($0.element.description)") }
            if q.multiSelect { o["multi_select"] = true }
        }
        o["screen"] = await screen(s, lines: 30) ?? "(no live screen)"
        return o
    }

    /// The question the agent is waiting on: its last AskUserQuestion when
    /// nothing but thinking follows it (an answer lands as a tool result,
    /// then the agent speaks again).
    static func standingQuestion(_ items: [TranscriptItem]) -> TranscriptQuestion? {
        guard let qi = items.lastIndex(where: { if case .question = $0.kind { return true }; return false }),
              case .question(let q) = items[qi].kind,
              !items[items.index(after: qi)...].contains(where: {
                  if case .thinking = $0.kind { return false }; return true })
        else { return nil }
        return q
    }

    /// Recent turns as plain text, newest last, capped at `maxChars`.
    static func render(_ items: [TranscriptItem], turns: Int, maxChars: Int) -> String {
        var lines: [String] = []
        for it in items {
            switch it.kind {
            case .userText(let t): lines.append("USER: " + t)
            case .assistantText(let t): lines.append("AGENT: " + t)
            case .toolUse(let name, let summary, _): lines.append("[\(name)] \(summary)")
            case .toolResult(let tool, let content, let isError) where isError:
                lines.append("[\(tool) failed] " + String(content.prefix(300)))
            case .question(let q):
                let opts = q.options.enumerated().map { "\($0.offset + 1)) \($0.element.label)" }
                lines.append("QUESTION: \(q.question) " + opts.joined(separator: " "))
            case .todo(let title, let rows):
                lines.append("[plan] \(title) (\(rows.count) items)")
            default: break
            }
        }
        // Keep the last `turns` user/agent exchanges' worth of lines.
        var picked: [String] = []
        var userTurns = 0
        for l in lines.reversed() {
            picked.append(l)
            if l.hasPrefix("USER: ") { userTurns += 1; if userTurns >= turns { break } }
        }
        var text = picked.reversed().joined(separator: "\n")
        if text.count > maxChars { text = "…" + String(text.suffix(maxChars)) }
        return text
    }

    /// The last thing the agent said, one line — the "what it's doing".
    static func lastWords(_ items: [TranscriptItem]) -> String? {
        for it in items.reversed() {
            if case .assistantText(let t) = it.kind {
                let one = t.split(whereSeparator: \.isNewline).first.map(String.init) ?? t
                return String(one.prefix(160))
            }
        }
        return nil
    }

    // MARK: Acting on sessions

    enum ActError: Error { case refused(String) }

    /// Say `text` to a session: typed when it's live, through a resume when
    /// it's asleep or ended. Anything beyond one short line goes to a file in
    /// its inbox, with a one-line pointer typed (a newline would submit the
    /// prompt half-way).
    func send(_ s: AgentSession, _ text: String) async throws {
        guard let delegate else { throw ActError.refused("No host.") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ActError.refused("Nothing to send.") }
        markTouched(s.id)
        var line = trimmed
        if trimmed.contains("\n") || trimmed.count > 400 {
            let dir = "/home/ubuntu/.bromure/inbox/switchboard-\(Int(Date().timeIntervalSince1970))"
            let b64 = Data(trimmed.utf8).base64EncodedString()
            _ = try await delegate.guestExec(
                profileID: s.profileID,
                command: "mkdir -p \(dir) && echo \(b64) | base64 -d > \(dir)/message.md", timeout: 20)
            line = "A message from the user (relayed by the Switchboard) is in \(dir)/message.md — read it and act on it."
        }
        let live = s.windowIndex != nil && !s.hasEnded && s.agentAlive != false
            && (bucket(s).map { $0 != .asleep && $0 != .ended } ?? true)
        if live, let w = s.windowIndex {
            _ = try await delegate.guestExec(
                profileID: s.profileID,
                command: CodingTaskEngine.typeCommand(tabIndex: w, text: line), timeout: 15)
        } else {
            sessionEngine.resume(s.id, message: line, quietly: true)
        }
    }

    /// Named keys the Switchboard may press: enough to answer a TUI prompt,
    /// nothing that can smuggle arbitrary text or escape sequences.
    static let allowedKeys: Set<String> = [
        "Enter", "Escape", "Tab", "BTab", "Space", "BSpace", "Up", "Down", "Left", "Right",
        "C-c", "y", "n", "a", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
    ]

    func press(_ s: AgentSession, _ keys: [String]) async throws {
        guard let delegate, let w = s.windowIndex, !s.hasEnded else {
            throw ActError.refused("That session has no live tab to type into.")
        }
        let bad = keys.filter { !Self.allowedKeys.contains($0) }
        guard bad.isEmpty, !keys.isEmpty, keys.count <= 12 else {
            throw ActError.refused("Keys must be 1–12 of: " + Self.allowedKeys.sorted().joined(separator: " "))
        }
        markTouched(s.id)
        let cmd = keys.map { "tmux send-keys -t bromure:\(w) \($0)" }.joined(separator: " && sleep 0.15 && ")
        _ = try await delegate.guestExec(profileID: s.profileID, command: cmd, timeout: 15)
    }

    // MARK: Provenance

    /// An answer typed into a blocked session, keys pressed at one of its
    /// prompts, a session put away — the Switchboard may only do these for
    /// the user, never because a session's output asked it to. So the
    /// action must quote the user's own words: a message they typed into
    /// the Switchboard's conversation in the last half hour (not a notice
    /// the host typed, not the opening brief). nil = verified; else why not.
    func verifyProvenance(_ quote: String?, for c: AgentSession) async -> String? {
        guard let quote = quote.map(Self.normalized), quote.count >= 4 else {
            return "on_behalf_of is required: quote the words of the user's message that asks for this (at least a few words, verbatim)."
        }
        let items = await transcript(c)
        let now = Date()
        let userLines = items.compactMap { it -> String? in
            guard case .userText(let t) = it.kind else { return nil }
            if let at = it.timestamp, now.timeIntervalSince(at) > Self.provenanceWindow { return nil }
            let n = Self.normalized(t)
            // Host-typed lines are never the user: notices and the kickoffs.
            if n.hasPrefix(Self.normalized(Self.noticePrefix))
                || n.hasPrefix("you are the switchboard") { return nil }
            return n
        }
        if userLines.contains(where: { $0.contains(quote) }) { return nil }
        return "on_behalf_of doesn't match anything the user said to you in the last 30 minutes. Only act on a blocked session when the user asked — quote their words verbatim — otherwise ask them first."
    }

    static func normalized(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "’", with: "'")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
    }
}
#endif
