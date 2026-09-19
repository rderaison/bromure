#if canImport(AppKit)
import AppKit
#endif
import SwiftUI

// MARK: - Session-first stage views (macOS)
//
// What the stage shows for the selected session:
//   • SessionHeaderView — the strip above every session surface: name, status,
//                         the (agent, workspace, folder) chips, Resume when the
//                         agent is gone, and — under the hood — the machine
//                         shortcuts (terminal is the surface itself; files,
//                         containers, machine one click each).
//   • SessionLaunchView — the chat surface while the session is on its way.
//   • SessionRestView   — an ended or asleep session: what happened, the last
//                         conversation when it can be read, and Resume.
//   • NewSessionView    — "New session": workspace, agent, where, opening
//                         message. Start.

struct SessionStageActions {
    var resume: (UUID) -> Void = { _ in }
    var close: (UUID) -> Void = { _ in }
    var rename: (UUID, String) -> Void = { _, _ in }
    /// Resume and say this — wakes the machine and the agent if need be.
    var resumeWith: (UUID, String) -> Void = { _, _ in }
    var forget: (UUID) -> Void = { _ in }
    /// Put the conversation away: ends the agent, moves the row to the
    /// Archived fold. Still readable; resuming brings it back.
    var archive: (UUID) -> Void = { _ in }
    var unarchive: (UUID) -> Void = { _ in }
    /// Delete the session: ends the agent (asking first when it's running),
    /// drops the record and its transcript copy. The folder on the machine
    /// stays.
    var delete: (UUID) -> Void = { _ in }
    var represent: (UUID) -> Void = { _ in }
    var showFiles: () -> Void = {}
    var showContainers: (UUID) -> Void = { _ in }
    var showMachine: (UUID) -> Void = { _ in }
    var toggleUnderTheHood: () -> Void = {}
}

// MARK: - Small chrome

struct SessionStatusPill: View {
    let bucket: SessionBucket
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(bucket.tint).frame(width: 7, height: 7)
            Text(bucket.title).font(.system(size: 12, weight: .semibold))
            if let detail, !detail.isEmpty {
                Text("· " + detail).font(.system(size: 12)).opacity(0.85)
            }
        }
        .foregroundStyle(bucket.tint)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Capsule().fill(bucket.tint.opacity(0.12)))
        .fixedSize()
    }
}

struct InfoChip<Leading: View>: View {
    let text: String
    var mono = false
    @ViewBuilder let leading: () -> Leading

    var body: some View {
        HStack(spacing: 5) {
            leading()
            Text(text)
                .font(mono ? .system(size: 11.5, design: .monospaced) : .system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .frame(maxWidth: 200)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }
}

private struct WorkspaceSquare: View {
    let accentHex: String
    var size: CGFloat = 8
    var body: some View {
        RoundedRectangle(cornerRadius: 2).fill(Color(hex: accentHex)).frame(width: size, height: size)
    }
}

/// The folder as the user thinks of it: "~/clock", never /home/ubuntu/clock.
func prettyGuestPath(_ path: String) -> String {
    let home = "/home/ubuntu"
    if path == home || path == "~" || path.isEmpty { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
}

// MARK: - Header

struct SessionHeaderView: View {
    var store: AgentSessionStore
    @Bindable var model: SessionListModel
    let actions: SessionStageActions
    @State private var renaming = false
    @State private var draftTitle = ""

    private var session: AgentSession? { model.selectedSessionID.flatMap { store.session($0) } }

    private func workspaceName(_ id: UUID) -> String {
        model.profileRows.first { $0.id == id }?.name ?? ""
    }
    private func accentHex(_ id: UUID) -> String {
        model.profileRows.first { $0.id == id }?.accentHex ?? "#888888"
    }

    var body: some View {
        if let s = session {
            let bucket = SessionHome.bucket(for: s, in: model)
            let live = SessionHome.liveTabPosition(for: s, in: model)
            let gone = SessionHome.isGone(s, in: model)
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        if renaming {
                            TextField("", text: $draftTitle, onCommit: {
                                actions.rename(s.id, draftTitle); renaming = false
                            })
                            .textFieldStyle(.plain)
                            .font(.system(size: 16, weight: .semibold))
                            .platformExitCommand { renaming = false }
                        } else {
                            Text(s.title)
                                .font(.system(size: 16, weight: .semibold))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .onTapGesture(count: 2) {
                                    guard !gone else { return }
                                    draftTitle = s.title; renaming = true
                                }
                                .help(gone ? "" : NSLocalizedString("Double-click to rename", comment: "session header"))
                        }
                        // One quiet line: status · agent · machine · folder.
                        HStack(spacing: 7) {
                            HStack(spacing: 5) {
                                if let st = SessionHome.dot(for: s, in: model) {
                                    AgentStatusDot(status: st).scaleEffect(1.15)   // breathes while working
                                } else {
                                    Circle().fill(bucket.tint).frame(width: 7, height: 7)
                                }
                                Text(SessionHome.goneReason(s, in: model) ?? statusText(s, bucket: bucket))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(bucket.tint)
                            }
                            .fixedSize()
                            metaDot
                            HStack(spacing: 5) {
                                AgentAvatar(tool: s.tool, size: 13)
                                Text(s.tool.displayName)
                            }
                            .fixedSize()
                            if !workspaceName(s.profileID).isEmpty {
                                metaDot
                                HStack(spacing: 5) {
                                    WorkspaceSquare(accentHex: accentHex(s.profileID), size: 7)
                                    Text(workspaceName(s.profileID))
                                }
                                .fixedSize()
                                .contentShape(Rectangle())
                                .onTapGesture { actions.showMachine(s.profileID) }
                                .help(NSLocalizedString("The machine this session runs on — click for its details", comment: "session header"))
                            }
                            metaDot
                            HStack(spacing: 4) {
                                Image(systemName: "folder").font(.system(size: 10.5))
                                Text(prettyGuestPath(s.cwd))
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .truncationMode(.middle)
                            }
                            if let url = s.cloneURL, !url.isEmpty {
                                metaDot
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.down.circle").font(.system(size: 10.5))
                                    Text(CodingTask.shortRepoURL(url))
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .truncationMode(.middle)
                                }
                                .help(url)
                            }
                        }
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    // Picking the conversation back up is one quiet glyph; the
                    // composer below says the rest.
                    if !gone, bucket == .ended || bucket == .asleep {
                        Button {
                            actions.resume(s.id)
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help(bucket == .asleep
                              ? NSLocalizedString("Wake up and continue where it left off", comment: "session header")
                              : NSLocalizedString("Resume where it left off", comment: "session header"))
                    }
                    Menu {
                        if !gone {
                            Button(NSLocalizedString("Rename…", comment: "session menu")) {
                                draftTitle = s.title; renaming = true
                            }
                            if s.isArchived {
                                Button(NSLocalizedString("Unarchive", comment: "session menu")) { actions.unarchive(s.id) }
                            } else {
                                // Putting a live conversation away stops its agent
                                // — say so in the item itself.
                                Button(s.windowIndex != nil && !s.hasEnded
                                       ? NSLocalizedString("End & Archive", comment: "session menu")
                                       : NSLocalizedString("Archive", comment: "session menu")) {
                                    actions.archive(s.id)
                                }
                            }
                            if s.windowIndex != nil {
                                Button(NSLocalizedString("End session", comment: "session menu")) { actions.close(s.id) }
                            }
                        } else if s.isArchived {
                            Button(NSLocalizedString("Unarchive", comment: "session menu")) { actions.unarchive(s.id) }
                        }
                        Divider()
                        Button(NSLocalizedString("Delete session", comment: "session menu"), role: .destructive) {
                            actions.delete(s.id)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .platformBorderlessMenuStyle()
                    .menuIndicator(.hidden)
                    .frame(width: 26)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, model.underTheHood ? 8 : 12)

                if model.underTheHood {
                    // The machine, one click each: the terminal is already the
                    // surface; files, containers and the VM itself sit here.
                    HStack(spacing: 6) {
                        Image(systemName: "terminal")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(NSLocalizedString("Terminal", comment: "under the hood"))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        if let branch = SessionHome.liveTab(for: s, in: model)?.worktreeBranch {
                            InfoChip(text: branch, mono: true) {
                                Image(systemName: "arrow.triangle.branch").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        hoodButton("Files", system: "folder", help: NSLocalizedString("The folder's files and changes", comment: "")) { actions.showFiles() }
                        hoodButton("Containers", system: "shippingbox", help: NSLocalizedString("Docker containers on this machine", comment: "")) { actions.showContainers(s.profileID) }
                        hoodButton("Machine", system: "desktopcomputer", help: NSLocalizedString("CPU, memory, disk, ports, power", comment: "")) { actions.showMachine(s.profileID) }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.platformWindowBackground)
            .overlay(alignment: .bottom) { Divider().opacity(0.6) }
            .onChange(of: live) { _, _ in actions.represent(s.id) }
            .onChange(of: bucket) { _, _ in actions.represent(s.id) }
        }
    }

    private func hoodButton(_ title: String, system: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(NSLocalizedString(title, comment: "under the hood"), systemImage: system)
                .font(.system(size: 11.5, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(help)
    }

    private var metaDot: some View {
        Text("·").foregroundStyle(.tertiary)
    }

    private func statusText(_ s: AgentSession, bucket: SessionBucket) -> String {
        let detail: String?
        switch bucket {
        case .working: detail = s.isLaunching ? NSLocalizedString("starting", comment: "pill") : nil
        case .idle:    detail = SessionHome.elapsed(since: s.lastSeenAt)
        case .ended:   detail = SessionHome.elapsed(since: s.endedAt).map {
            // "3 min ago" — but never "just now ago".
            $0 == NSLocalizedString("just now", comment: "elapsed")
                ? $0 : String(format: NSLocalizedString("%@ ago", comment: "pill"), $0) }
        default:       detail = nil
        }
        let title = bucket == .ended && s.isArchived
            ? NSLocalizedString("Archived", comment: "session status") : bucket.title
        return detail.map { title + " · " + $0 } ?? title
    }
}

// MARK: - Launch surface

/// The chat before the agent's tab exists: the opening message as the first
/// turn, a live cue for what is happening, the composer parked.
struct SessionLaunchView: View {
    var store: AgentSessionStore
    @Bindable var model: SessionListModel
    let sessionID: UUID
    let accent: Color
    let actions: SessionStageActions
    @State private var draft = ""

    private var session: AgentSession? { store.session(sessionID) }

    private func phase(for s: AgentSession) -> String {
        switch SessionHome.workspaceState(of: s, in: model) {
        case .off, .suspended: return NSLocalizedString("Waking up…", comment: "session launch")
        case .booting:         return NSLocalizedString("Almost there…", comment: "session launch")
        case .running:
            if s.cloneURL != nil {
                return String(format: NSLocalizedString("Checking out the repository and starting %@…", comment: "session launch"), s.tool.displayName)
            }
            return String(format: NSLocalizedString("Starting %@…", comment: "session launch"), s.tool.displayName)
        }
    }

    var body: some View {
        if let s = session {
            let live = SessionHome.liveTabPosition(for: s, in: model)
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if let msg = s.openingMessage, !msg.isEmpty {
                            TranscriptItemView(item: TranscriptItem(id: 0, kind: .userText(msg), timestamp: nil))
                        }
                        HStack(spacing: 10) {
                            AgentAvatar(tool: s.tool, size: 22)
                            ProgressView().controlSize(.small)
                            Text(phase(for: s))
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                Divider().opacity(0.5)
                ChatComposer(
                    placeholder: String(format: NSLocalizedString("%@ is starting — you can talk to it in a moment…", comment: "session launch"), s.tool.displayName),
                    text: $draft, disabled: true, accent: accent, onSend: {})
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .background(Color.platformTextBackground)
            .onChange(of: live) { _, new in if new != nil { actions.represent(s.id) } }
            .onChange(of: s.launchingSince) { _, _ in actions.represent(s.id) }
            .onChange(of: s.lastError) { _, _ in actions.represent(s.id) }
        }
    }
}

// MARK: - Ended / asleep surface

/// A session with no live tab: why, the last conversation when the
/// workspace can be read, and the way back in.
struct SessionRestView: View {
    var store: AgentSessionStore
    @Bindable var model: SessionListModel
    let sessionID: UUID
    let accent: Color
    let actions: SessionStageActions
    /// Raw transcript of the agent's last conversation in the folder (nil
    /// when the workspace can't be read).
    let fetchTranscript: (AgentSession) async -> String?
    /// The conversation as last copied to this Mac — readable with the
    /// machine asleep.
    let cachedTranscript: (AgentSession) -> Data?
    /// Ask `fetchTranscript` for asleep sessions too (a fat client: the
    /// server answers from its own copy).
    var fetchWhenAsleep = false

    private enum Load { case idle, loading, loaded([TranscriptItem]), unavailable }
    @State private var load: Load = .idle
    @State private var draft = ""
    @State private var sending = false

    private var session: AgentSession? { store.session(sessionID) }

    var body: some View {
        if let s = session {
            let bucket = SessionHome.bucket(for: s, in: model)
            let live = SessionHome.liveTabPosition(for: s, in: model)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let err = s.lastError, !err.isEmpty { errorCard(err) }
                        transcript(s, bucket: bucket)
                    }
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
                }
                Divider().opacity(0.5)
                if let why = SessionHome.goneReason(s, in: model) {
                    // Nothing to send to: the machine or the folder is gone.
                    HStack(spacing: 6) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(String(format: NSLocalizedString("%@. The conversation stays readable here; delete the session when you're done with it.", comment: "session rest gone"), why))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                } else {
                    // The way back in is the same as ever: say something.
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: s.isArchived ? "archivebox"
                                  : bucket == .asleep ? "moon.zzz" : "flag.checkered")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(s.isArchived
                                 ? NSLocalizedString("Archived. Your next message brings it back and carries on from here.", comment: "session rest")
                                 : bucket == .asleep
                                 ? NSLocalizedString("Asleep. Your next message wakes it up and carries on from here.", comment: "session rest")
                                 : NSLocalizedString("This session ended. Your next message carries on from here.", comment: "session rest"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 6)
                        ChatComposer(
                            placeholder: String(format: NSLocalizedString("Message %@…", comment: "session rest composer"), s.tool.displayName),
                            text: $draft, busy: sending, accent: accent,
                            onSend: { send(s) })
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
            .background(Color.platformTextBackground)
            .task(id: s.id) { await loadTranscript(s, bucket: bucket) }
            .onChange(of: live) { _, new in if new != nil { actions.represent(s.id) } }
            .onChange(of: s.launchingSince) { _, _ in actions.represent(s.id) }
            .onChange(of: bucket) { _, _ in actions.represent(s.id) }
        }
    }

    private func send(_ s: AgentSession) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        draft = ""
        actions.resumeWith(s.id, text)
    }

    /// The local copy first — instantly, machine on or off — then the live
    /// file when the workspace can still be read.
    private func loadTranscript(_ s: AgentSession, bucket: SessionBucket) async {
        load = .loading
        let agent = s.tool.rawValue
        if let cached = cachedTranscript(s), !cached.isEmpty {
            let items = await Task.detached(priority: .userInitiated) {
                AgentTranscript.parse(cached, agent: agent)
            }.value
            load = items.isEmpty ? .unavailable : .loaded(items)
        }
        guard bucket == .ended || fetchWhenAsleep, let raw = await fetchTranscript(s), !raw.isEmpty else {
            if case .loading = load { load = .unavailable }
            return
        }
        let items = await Task.detached(priority: .userInitiated) {
            AgentTranscript.parse(Data(raw.utf8), agent: agent)
        }.value
        if !items.isEmpty { load = .loaded(items) } else if case .loading = load { load = .unavailable }
    }

    private func errorCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.10)))
    }

    @ViewBuilder
    private func transcript(_ s: AgentSession, bucket: SessionBucket) -> some View {
        switch load {
        case .idle, .unavailable:
            if let msg = s.openingMessage, !msg.isEmpty {
                TranscriptItemView(item: TranscriptItem(id: 0, kind: .userText(msg), timestamp: nil))
            }
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(NSLocalizedString("Reading the conversation…", comment: "session rest"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .loaded(let items):
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(items) { TranscriptItemView(item: $0) }
            }
        }
    }
}

// MARK: - New session

/// "New session": the message is the hero — type, press Return, done. The
/// choices that shape it (agent, machine, where) ride along the bottom of
/// the composer as chips, pre-filled from last time, each one click away.
struct NewSessionView: View {
    let profiles: [Profile]
    let runningIDs: Set<UUID>
    /// Folders earlier sessions in a workspace ran in, most recent first.
    let recentFolders: (UUID) -> [String]
    let onStart: (AgentSessionRequest) -> Void
    let onCancel: () -> Void
    /// No machine yet: the new-workspace flow.
    let onNewMachine: () -> Void

    private enum Where: String, CaseIterable, Identifiable {
        case home, folder, repository
        var id: String { rawValue }
        var title: String {
            switch self {
            case .home:       return NSLocalizedString("New folder", comment: "new session where")
            case .folder:     return NSLocalizedString("A folder", comment: "new session where")
            case .repository: return NSLocalizedString("A repository", comment: "new session where")
            }
        }
    }

    @State private var profileID: UUID
    @State private var tool: Profile.Tool
    @State private var place: Where
    @State private var folder: String
    @State private var repoURL: String = ""
    @State private var derivedFolder: String?
    @State private var message = ""
    @State private var machinePopover = false
    @State private var agentPopover = false
    @State private var wherePopover = false
    @FocusState private var messageFocused: Bool

    static let lastProfileKey = "sessions.lastProfileID"
    static let lastToolKey = "sessions.lastTool"

    /// A wide stage gets a wide margin; a phone keeps every point.
    private static var sidePadding: CGFloat {
        #if os(macOS)
        return 32
        #else
        return 16
        #endif
    }

    private static var footnote: String {
        #if os(macOS)
        return NSLocalizedString("Runs in an isolated machine of its own. Nothing on your Mac is touched.", comment: "new session footnote")
        #else
        return NSLocalizedString("Runs in an isolated machine of its own on your Mac, not on this device.", comment: "new session footnote (mobile)")
        #endif
    }

    init(profiles: [Profile], runningIDs: Set<UUID>, recentFolders: @escaping (UUID) -> [String],
         onStart: @escaping (AgentSessionRequest) -> Void,
         onCancel: @escaping () -> Void,
         onNewMachine: @escaping () -> Void = {}) {
        self.profiles = profiles
        self.runningIDs = runningIDs
        self.recentFolders = recentFolders
        self.onStart = onStart
        self.onCancel = onCancel
        self.onNewMachine = onNewMachine
        let remembered = UserDefaults.standard.string(forKey: Self.lastProfileKey)
            .flatMap { UUID(uuidString: $0) }
        let pid = remembered.flatMap { id in profiles.first { $0.id == id }?.id }
            ?? profiles.first { runningIDs.contains($0.id) }?.id
            ?? profiles.first?.id
            ?? UUID()
        let profile = profiles.first { $0.id == pid }
        let available = profile?.allToolSpecs.map(\.tool) ?? []
        let rememberedTool = UserDefaults.standard.string(forKey: Self.lastToolKey).flatMap(Profile.Tool.init(rawValue:))
        _profileID = State(initialValue: pid)
        _tool = State(initialValue: rememberedTool.flatMap { available.contains($0) ? $0 : nil }
                      ?? profile?.tool ?? .claude)
        _place = State(initialValue: .home)
        _folder = State(initialValue: "")
    }

    private var selectedProfile: Profile? { profiles.first { $0.id == profileID } }
    private var availableTools: [Profile.Tool] { selectedProfile?.allToolSpecs.map(\.tool) ?? [] }

    private var effectiveFolder: String {
        switch place {
        case .home: return "~"
        case .folder:
            let f = folder.trimmingCharacters(in: .whitespaces)
            return f.isEmpty ? "~" : f
        case .repository:
            let f = folder.trimmingCharacters(in: .whitespaces)
            if !f.isEmpty { return f }
            return CodingTask.repoName(fromCloneURL: repoURL).map { "~/" + $0 } ?? ""
        }
    }

    private var canStart: Bool {
        guard selectedProfile != nil, availableTools.contains(tool) else { return false }
        if place == .repository {
            return !repoURL.trimmingCharacters(in: .whitespaces).isEmpty
                && !effectiveFolder.isEmpty && effectiveFolder != "~"
        }
        return true
    }

    private var whereLabel: String {
        switch place {
        case .home:
            return NSLocalizedString("New folder", comment: "new session where")
        case .folder:
            let f = folder.trimmingCharacters(in: .whitespaces)
            return f.isEmpty ? NSLocalizedString("A folder", comment: "new session where") : f
        case .repository:
            let u = repoURL.trimmingCharacters(in: .whitespaces)
            return u.isEmpty ? NSLocalizedString("A repository", comment: "new session where") : CodingTask.shortRepoURL(u)
        }
    }

    private var placeholderText: String {
        String(format: NSLocalizedString("Ask for anything — or just press Return to open %@.", comment: "new session message"),
               tool.displayName)
    }

    private func start() {
        guard canStart else { return }
        UserDefaults.standard.set(profileID.uuidString, forKey: Self.lastProfileKey)
        UserDefaults.standard.set(tool.rawValue, forKey: Self.lastToolKey)
        onStart(AgentSessionRequest(
            profileID: profileID, tool: tool, cwd: effectiveFolder,
            cloneURL: place == .repository ? repoURL.trimmingCharacters(in: .whitespaces) : nil,
            openingMessage: message))
    }

    /// The one question, then the composer — a new chat, not a form. The
    /// session is named after the first words typed and renamed by the agent
    /// once it has understood the task.
    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 22) {
                    Spacer(minLength: max(24, geo.size.height * 0.24))
                    Text(profiles.isEmpty
                         ? NSLocalizedString("Let's set up a machine first.", comment: "new session greeting")
                         : NSLocalizedString("What can I help you with?", comment: "new session greeting"))
                        .font(.system(size: 30, weight: .semibold))
                        .tracking(-0.3)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.8)
                        .padding(.bottom, 2)
                    if profiles.isEmpty {
                        firstMachineCard
                    } else {
                        composer
                        recentRow
                        Text(Self.footnote)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    Spacer(minLength: 48)
                }
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geo.size.height)
                .padding(.horizontal, Self.sidePadding)
            }
        }
        .background(Color.platformWindowBackground)
        .platformExitCommand(onCancel)
        .onAppear {
            messageFocused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { messageFocused = true }
        }
        .onChange(of: profileID) { _, _ in
            if !availableTools.contains(tool), let primary = selectedProfile?.tool { tool = primary }
        }
        .onChange(of: repoURL) { _, new in
            guard let name = CodingTask.repoName(fromCloneURL: new) else { return }
            let f = folder.trimmingCharacters(in: .whitespaces)
            if f.isEmpty || f == derivedFolder { folder = "~/" + name; derivedFolder = folder }
        }
    }

    // MARK: The composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(placeholderText, text: $message, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .lineSpacing(4)
                .lineLimit(3...14)
                .focused($messageFocused)
                .onSubmit(start)
                .padding(.horizontal, 4)
                .padding(.top, 4)
            HStack(spacing: 8) {
                ChipStrip {
                ComposerChip(help: NSLocalizedString("The agent that runs this session", comment: "new session chip"),
                             action: { agentPopover.toggle() }) {
                    AgentAvatar(tool: tool, size: 16)
                    Text(tool.displayName)
                }
                .popover(isPresented: $agentPopover, arrowEdge: .bottom) { agentList.platformCompactPopover() }

                ComposerChip(help: runningIDs.contains(profileID)
                                ? NSLocalizedString("The machine it runs on — running", comment: "new session chip")
                                : NSLocalizedString("The machine it runs on — asleep, wakes up when you start", comment: "new session chip"),
                             action: { machinePopover.toggle() }) {
                    WorkspaceSquare(accentHex: selectedProfile?.color.hexInUI ?? "#888888", size: 9)
                    Text(selectedProfile?.name ?? NSLocalizedString("Machine", comment: "new session"))
                    if runningIDs.contains(profileID) {
                        Circle().fill(Color.green).frame(width: 5, height: 5)
                    }
                }
                .popover(isPresented: $machinePopover, arrowEdge: .bottom) { machineList.platformCompactPopover() }

                ComposerChip(help: NSLocalizedString("Where it works: a fresh folder, one of yours, or a repository to check out", comment: "new session chip"),
                             action: { wherePopover.toggle() }) {
                    Image(systemName: place == .repository ? "arrow.down.circle" : "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    // Hugs its text, truncating only past 220pt.
                    Text(whereLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 220)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .popover(isPresented: $wherePopover, arrowEdge: .bottom) { whereEditor.platformCompactPopover() }
                }

                Spacer(minLength: 8)
                #if os(macOS)
                Text(NSLocalizedString("⏎ start   ⌥⏎ newline", comment: "new session hint"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.quaternary)
                    .lineLimit(1)
                #endif
                Button(action: start) {
                    HStack(spacing: 6) {
                        // Touch screens get the familiar arrow-only send pill;
                        // the label would cost the third chip its room.
                        #if os(macOS)
                        Text(NSLocalizedString("Start", comment: "new session"))
                            .font(.system(size: 12.5, weight: .semibold))
                        #endif
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .frame(height: 28)
                    .background(Capsule().fill(canStart ? Color.accentColor : Color.secondary.opacity(0.28)))
                }
                .fixedSize()   // never squeezed by the chip strip beside it
                .buttonStyle(.plain)
                .accessibilityLabel(NSLocalizedString("Start", comment: "new session"))
                .disabled(!canStart)
                .keyboardShortcut(.return, modifiers: .command)
                .help(NSLocalizedString("Start the session (⏎)", comment: "new session"))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.platformTextBackground)
            .shadow(color: .black.opacity(0.08), radius: 16, y: 5))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(messageFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.10),
                          lineWidth: messageFocused ? 1.5 : 1))
        .animation(.easeOut(duration: 0.12), value: messageFocused)
    }

    /// Folders earlier sessions on this machine ran in — one click to work
    /// there again.
    @ViewBuilder
    private var recentRow: some View {
        let recent = Array(recentFolders(profileID).prefix(4))
        if !recent.isEmpty {
            ChipStrip {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Text(NSLocalizedString("Recent", comment: "new session recent"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .padding(.trailing, 2)
                ForEach(recent, id: \.self) { p in
                    let picked = place == .folder && folder == p
                    Button {
                        if picked { place = .home; folder = "" } else { place = .folder; folder = p }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder").font(.system(size: 10))
                            Text(p)
                                .font(.system(size: 11.5, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .foregroundStyle(picked ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .frame(maxWidth: 200)
                        .background(Capsule().fill(picked ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(picked
                          ? NSLocalizedString("Working in this folder — click to start in a new folder instead", comment: "new session recent")
                          : NSLocalizedString("Work in this folder again", comment: "new session recent"))
                }
                Spacer(minLength: 0)
            }
            }
        }
    }

    /// Nothing to run on yet.
    private var firstMachineCard: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "desktopcomputer")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString("Set up your first machine", comment: "new session first machine"))
                    .font(.system(size: 15, weight: .semibold))
                Text(NSLocalizedString("An isolated Linux machine with the agents and keys you choose. Sessions run inside it — nothing on your Mac is touched.", comment: "new session first machine"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onNewMachine) {
                    Label(NSLocalizedString("Create a machine", comment: "new session first machine"), systemImage: "plus")
                        .padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Color.platformTextBackground)
            .shadow(color: .black.opacity(0.08), radius: 16, y: 5))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.10)))
    }

    // MARK: Agent

    private var agentList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Profile.Tool.allCases, id: \.self) { t in
                let available = availableTools.contains(t)
                let selected = t == tool
                Button {
                    tool = t; agentPopover = false
                } label: {
                    HStack(spacing: 10) {
                        AgentAvatar(tool: t, size: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.displayName)
                                .font(.system(size: 13, weight: selected ? .semibold : .medium))
                            Text(available
                                 ? NSLocalizedString("Ready", comment: "new session agent")
                                 : NSLocalizedString("Not set up on this machine", comment: "new session agent"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if selected {
                            Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(selected ? Color.accentColor.opacity(0.14) : .clear))
                    .opacity(available ? 1 : 0.45)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!available)
                .help(available ? "" : NSLocalizedString("Set this agent up in the machine's settings (Agents) to use it here.", comment: "new session agent"))
            }
        }
        .padding(6)
        .frame(width: 300)
    }

    // MARK: Machine

    private var machineList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(profiles) { p in
                    let running = runningIDs.contains(p.id)
                    Button {
                        profileID = p.id; machinePopover = false
                    } label: {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color(hex: p.color.hexInUI).opacity(running ? 0.9 : 0.35))
                                .frame(width: 26, height: 26)
                                .overlay(Image(systemName: "desktopcomputer")
                                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name).font(.system(size: 13, weight: p.id == profileID ? .semibold : .medium))
                                Text(p.allToolSpecs.map { $0.tool.displayName }.joined(separator: " · "))
                                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if p.id == profileID {
                                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                            } else if running {
                                Circle().fill(Color.green).frame(width: 6, height: 6)
                            }
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(p.id == profileID ? Color.accentColor.opacity(0.14) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
        }
        .frame(width: 320)
        .frame(maxHeight: min(440, CGFloat(profiles.count) * 46 + 12))
    }

    // MARK: Where

    private var whereEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $place) {
                ForEach(Where.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch place {
            case .home:
                Text(NSLocalizedString("A fresh folder of its own in the machine's home, named after your message.", comment: "new session where"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .folder:
                HStack(spacing: 8) {
                    pathField(prompt: "~/my-project")
                    let recent = recentFolders(profileID).filter { $0 != folder }
                    if !recent.isEmpty {
                        Menu {
                            ForEach(recent, id: \.self) { p in Button(p) { folder = p } }
                        } label: {
                            Label(NSLocalizedString("Recent", comment: "new session where"), systemImage: "clock")
                        }
                        .platformBorderlessMenuStyle()
                        .fixedSize()
                    }
                }
                Text(NSLocalizedString("A folder inside the machine — created if it doesn't exist yet.", comment: "new session where"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .repository:
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("https://github.com/org/repo.git", text: $repoURL)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.platformTextBackground))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.12)))
                HStack(spacing: 8) {
                    Text(NSLocalizedString("into", comment: "new session where")).font(.system(size: 12)).foregroundStyle(.secondary)
                    pathField(prompt: "~/repo")
                }
                Text(NSLocalizedString("Checked out with the machine's git credentials or SSH key. If the folder already holds the repository, it's used as is.", comment: "new session where"))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(NSLocalizedString("Done", comment: "")) { wherePopover = false }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .platformPopoverWidth(420)
    }

    private func pathField(prompt: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(prompt, text: $folder)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.platformTextBackground))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.12)))
    }
}

/// The composer's row of chips: inline on a wide stage, a horizontal
/// scroller on a phone so three chips never fight for 350 points.
private struct ChipStrip<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if os(macOS)
        content()
        #else
        // Wins the width contest against the trailing Spacer, so the chips
        // only scroll when the composer is genuinely too narrow (a phone).
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { content() }
        }
        .layoutPriority(1)
        #endif
    }
}

/// A choice riding along the composer's bottom edge: what it is now, a
/// chevron, a popover to change it.
private struct ComposerChip<Content: View>: View {
    let help: String
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                content()
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Capsule().fill(Color.primary.opacity(hovering ? 0.10 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
