import SwiftUI

// MARK: - Sessions home (iPhone · iPad · visionOS)
//
// The mobile counterpart of the desktop's sessions-first stage
// (RemoteHostWindow on macOS): a session — an agent, in a folder, on a
// machine — is what the user picks; the workspace/tmux plumbing stays one
// tap away ("Linux"). Everything reads the same `RemoteHostController`
// mirror (`sessionStore`) and drives the server through its session API
// (`startSession` / `sessionCommand` / `fetchSessionTranscript`). Gated on
// `controller.supportsSessions`, so an older server without the endpoints
// keeps the workspace-first shell exactly as before.

@MainActor
enum MobileSessions {
    /// The desktop's `SessionStageActions`, minus the side panes a phone
    /// doesn't have: every "show the machine" gesture opens the workspace
    /// screen (terminal, files, containers, info) instead.
    static func actions(_ controller: RemoteHostController,
                        onForget: @escaping () -> Void,
                        onLinux: @escaping () -> Void) -> SessionStageActions {
        SessionStageActions(
            resume: { controller.sessionCommand($0, "resume") },
            close: { controller.sessionCommand($0, "close") },
            rename: { id, title in controller.sessionCommand(id, "rename", body: ["title": title]) },
            resumeWith: { id, text in controller.sessionCommand(id, "resume", body: ["message": text]) },
            forget: { id in controller.sessionCommand(id, "forget"); onForget() },
            archive: { controller.sessionCommand($0, "archive") },
            unarchive: { controller.sessionCommand($0, "unarchive") },
            delete: { id in controller.sessionCommand(id, "delete"); onForget() },
            gitState: { await controller.sessionGitState($0) },
            mergeBranch: { id, into, squash, removeAfter in
                var body: [String: Any] = ["squash": squash, "removeAfter": removeAfter]
                if let into { body["into"] = into }
                controller.sessionCommand(id, "branch-merge", body: body)
            },
            branchPullRequest: { controller.sessionCommand($0, "branch-pr") },
            discardBranch: { id in controller.sessionCommand(id, "branch-discard"); onForget() },
            declineMerge: { controller.sessionCommand($0, "branch-decline") },
            represent: { _ in },
            showMachine: { _ in onLinux() })
    }

    /// Folders earlier sessions on a machine ran in, most recent first.
    static func recentFolders(_ controller: RemoteHostController, profileID: UUID) -> [String] {
        var seen: [String] = []
        for s in controller.sessionStore.sessions where s.profileID == profileID && s.cwd != "~" {
            let p = prettyGuestPath(s.cwd)
            if !seen.contains(p) { seen.append(p) }
            if seen.count >= 6 { break }
        }
        return seen
    }

    static func runningIDs(_ controller: RemoteHostController) -> Set<UUID> {
        Set(controller.listModel.profileRows
            .filter { $0.state == .running || $0.state == .booting }
            .map(\.id))
    }

    static func accent(_ controller: RemoteHostController, _ s: AgentSession) -> Color {
        Color(hex: controller.profile(for: s.profileID)?.color.hexInUI ?? "#3B82F6")
    }

    static func workspaceName(_ model: SessionListModel, _ s: AgentSession) -> String {
        model.profileRows.first { $0.id == s.profileID }?.name ?? ""
    }

    static func accentHex(_ model: SessionListModel, _ s: AgentSession) -> String {
        model.profileRows.first { $0.id == s.profileID }?.accentHex ?? "#888888"
    }

    /// "3m" — when the session last did something; nil while starting.
    static func when(_ s: AgentSession) -> String? {
        s.isLaunching ? nil : SessionHome.elapsedCompact(since: SessionHome.lastActivity(s))
    }
}

// MARK: - One session

/// A session's stage: launching → the progress card; live → a compact
/// identity strip over the workspace's terminal/reader (the mobile chat);
/// asleep or ended → the transcript with a composer that wakes it up.
struct MobileSessionScreen: View {
    let controller: RemoteHostController
    let sessionID: UUID
    /// After "Forget": the iPhone pops back home, the iPad clears its column.
    var onForget: () -> Void = {}
    /// A session this one spawned (a worktree off its folder): show it.
    var onOpen: (UUID) -> Void = { _ in }

    @State private var showLinux = false
    @State private var renaming = false
    @State private var draftTitle = ""
    @State private var confirmEnd = false
    @State private var confirmDelete = false
    @State private var worktreeSheet = false
    /// The session's machine settings (the workspace editor).
    @State private var machineSettings = false

    private var model: SessionListModel { controller.listModel }
    private var session: AgentSession? { controller.sessionStore.session(sessionID) }

    var body: some View {
        Group {
            if let s = session {
                stage(s)
            } else {
                waiting
            }
        }
        .navigationTitle(session?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let s = session {
                ToolbarItem(placement: .primaryAction) { menu(s) }
            }
        }
        .onAppear(perform: select)
        .onChange(of: sessionID) { _, _ in select() }
        .onChange(of: controller.revision) { _, _ in
            // A session's folder resolves after launch (a clone target, a
            // fresh folder): keep the shared context in step.
            if let s = session, model.selectedSessionCwd != s.cwd {
                model.selectedSessionCwd = s.cwd
                model.selectedSessionProfileID = s.profileID
            }
        }
        .navigationDestination(isPresented: $showLinux) {
            if let s = session {
                WorkspaceScreen(controller: controller, profileID: s.profileID,
                                initialWindow: s.windowIndex)
            }
        }
        .sheet(isPresented: $worktreeSheet) {
            if let s = session {
                NewWorktreeSheet(parent: s, gitState: { await controller.sessionGitState($0) }) { req in
                    Task {
                        if let id = await controller.startWorktreeSession(
                            from: s.id, name: req.name, tool: req.tool, message: req.message, initGit: req.initGit, base: req.base) {
                            onOpen(id)
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
        }
        .sheet(isPresented: $machineSettings) {
            if let s = session {
                WorkspaceEditorSheet(controller: controller, editing: s.profileID) { machineSettings = false }
            }
        }
        .alert("Rename session", isPresented: $renaming) {
            TextField("Name", text: $draftTitle)
            Button("Rename") {
                let t = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { controller.sessionCommand(sessionID, "rename", body: ["title": t]) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("End this session?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End session", role: .destructive) { controller.sessionCommand(sessionID, "close") }
        } message: {
            Text("The agent stops. The conversation stays readable here, and you can pick it back up later.")
        }
        .confirmationDialog("Delete this session?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete session", role: .destructive) {
                controller.sessionCommand(sessionID, "delete")
                onForget()
            }
        } message: {
            Text("The agent stops and the session leaves the list. Its folder stays on the machine.")
        }
    }

    private func select() {
        model.selectedSessionID = sessionID
        model.selectedSessionProfileID = session?.profileID
        model.selectedSessionCwd = session?.cwd
    }

    @ViewBuilder private func stage(_ s: AgentSession) -> some View {
        let accent = MobileSessions.accent(controller, s)
        let actions = MobileSessions.actions(controller, onForget: onForget, onLinux: { showLinux = true })
        if s.isLaunching {
            SessionLaunchView(store: controller.sessionStore, model: model, sessionID: s.id,
                              accent: accent, actions: actions)
        } else if !s.hasEnded, !SessionHome.isGone(s, in: model), SessionHome.liveTab(for: s, in: model) != nil {
            VStack(spacing: 0) {
                MobileSessionHeader(controller: controller, session: s, actions: actions)
                // The workspace screen opens on the session's tmux window; an
                // agent window defaults to its rich transcript reader — the
                // mobile chat — with the raw terminal one toggle away.
                WorkspaceScreen(controller: controller, profileID: s.profileID,
                                initialWindow: s.windowIndex)
                    .id("\(s.id.uuidString)#\(s.windowIndex ?? -1)")
            }
        } else {
            VStack(spacing: 0) {
                MobileSessionHeader(controller: controller, session: s, actions: actions)
                SessionRestView(
                    store: controller.sessionStore, model: model, sessionID: s.id,
                    accent: accent, actions: actions,
                    fetchTranscript: { s in
                        await controller.fetchSessionTranscript(s.id)
                            .map { String(decoding: $0, as: UTF8.self) }
                    },
                    cachedTranscript: { _ in nil },
                    fetchWhenAsleep: true)
            }
        }
    }

    /// The mirror learns about a just-started session on its next poll.
    private var waiting: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(controller.connected ? "Waking up…" : "Connecting…")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func menu(_ s: AgentSession) -> some View {
        let gone = SessionHome.isGone(s, in: model)
        return Menu {
            if !gone {
                if s.windowIndex != nil, !s.hasEnded {
                    Button { showLinux = true } label: {
                        Label("Linux", systemImage: "terminal")
                    }
                }
                if s.hasEnded || SessionHome.bucket(for: s, in: model) == .asleep {
                    Button { controller.sessionCommand(s.id, "resume") } label: {
                        Label(s.hasEnded ? "Resume" : "Wake up and continue", systemImage: "play.fill")
                    }
                }
                Button { draftTitle = s.title; renaming = true } label: {
                    Label("Rename…", systemImage: "pencil")
                }
                if SessionHome.hasFolder(s) {
                    Button { worktreeSheet = true } label: {
                        Label("New worktree…", systemImage: "arrow.triangle.branch")
                    }
                }
                if !MobileSessions.workspaceName(model, s).isEmpty {
                    Button { machineSettings = true } label: {
                        Label(String(format: NSLocalizedString("“%@” Settings…", comment: "session menu: machine settings"),
                                     MobileSessions.workspaceName(model, s)), systemImage: "gearshape")
                    }
                }
                if s.isArchived {
                    Button { controller.sessionCommand(s.id, "unarchive") } label: {
                        Label("Unarchive", systemImage: "tray.and.arrow.up")
                    }
                } else {
                    Button { controller.sessionCommand(s.id, "archive") } label: {
                        Label(s.windowIndex != nil && !s.hasEnded ? "End & Archive" : "Archive",
                              systemImage: "archivebox")
                    }
                }
                if s.windowIndex != nil {
                    Button(role: .destructive) { confirmEnd = true } label: {
                        Label("End session", systemImage: "stop.circle")
                    }
                }
            } else if s.isArchived {
                Button { controller.sessionCommand(s.id, "unarchive") } label: {
                    Label("Unarchive", systemImage: "tray.and.arrow.up")
                }
            }
            Divider()
            Button(role: .destructive) {
                if SessionHome.isAgentLive(s, in: model) { confirmDelete = true }
                else { controller.sessionCommand(s.id, "delete"); onForget() }
            } label: { Label("Delete session", systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("Session actions")
    }
}

/// One quiet strip under the navigation bar: status · agent · machine, then
/// the folder. The title itself is the navigation bar's.
struct MobileSessionHeader: View {
    let controller: RemoteHostController
    let session: AgentSession
    let actions: SessionStageActions

    private var model: SessionListModel { controller.listModel }

    var body: some View {
        let s = session
        let bucket = SessionHome.bucket(for: s, in: model)
        let gone = SessionHome.isGone(s, in: model)
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    HStack(spacing: 5) {
                        if let st = SessionHome.dot(for: s, in: model) {
                            AgentStatusDot(status: st).scaleEffect(1.15)
                        } else {
                            Circle().fill(bucket.tint).frame(width: 7, height: 7)
                        }
                        Text(SessionHome.goneReason(s, in: model) ?? statusText(s, bucket: bucket))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(bucket.tint)
                    }
                    .fixedSize()
                    Text("·").foregroundStyle(.tertiary)
                    HStack(spacing: 4) {
                        AgentAvatar(tool: s.tool, size: 12)
                        Text(s.tool.displayName)
                    }
                    .fixedSize()
                    if !MobileSessions.workspaceName(model, s).isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        HStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Color(hex: MobileSessions.accentHex(model, s)))
                                .frame(width: 6, height: 6)
                            Text(MobileSessions.workspaceName(model, s))
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                HStack(spacing: 4) {
                    Image(systemName: "folder").font(.system(size: 9.5))
                    Text(prettyGuestPath(s.cwd))
                        .font(.system(size: 11, design: .monospaced))
                        .truncationMode(.middle)
                    if let url = s.cloneURL, !url.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Image(systemName: "arrow.down.circle").font(.system(size: 9.5))
                        Text(CodingTask.shortRepoURL(url))
                            .font(.system(size: 11, design: .monospaced))
                            .truncationMode(.middle)
                    }
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 6)
            // Picking the conversation back up is one quiet glyph; the
            // composer below says the rest.
            if !gone, bucket == .ended || bucket == .asleep {
                Button {
                    actions.resume(s.id)
                } label: {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(bucket == .asleep ? "Wake up and continue" : "Resume")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.platformWindowBackground)
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
        .opacity(gone ? 0.6 : 1)
    }

    private func statusText(_ s: AgentSession, bucket: SessionBucket) -> String {
        let detail: String?
        switch bucket {
        case .working: detail = s.isLaunching ? NSLocalizedString("starting", comment: "pill") : nil
        case .idle:    detail = SessionHome.elapsed(since: s.lastSeenAt)
        case .ended:   detail = SessionHome.elapsed(since: s.endedAt).map {
            String(format: NSLocalizedString("%@ ago", comment: "pill"), $0) }
        default:       detail = nil
        }
        return detail.map { bucket.title + " · " + $0 } ?? bucket.title
    }
}

// MARK: - New session

/// "What can I help you with?" — the shared hero composer, wired to the
/// server's engine through the mirror. The session shows up in the store
/// with the next poll; the caller opens it then.
struct MobileNewSessionScreen: View {
    let controller: RemoteHostController
    let onStarted: (UUID) -> Void
    let onCancel: () -> Void
    /// Started from a room: the session joins it.
    var room: UUID? = nil

    @State private var workspaceEdit: WorkspaceEdit?
    @State private var starting = false
    @State private var failed = false

    var body: some View {
        NewSessionView(
            profiles: controller.profiles,
            runningIDs: MobileSessions.runningIDs(controller),
            recentFolders: { MobileSessions.recentFolders(controller, profileID: $0) },
            onStart: { req in
                guard !starting else { return }
                starting = true
                Task { @MainActor in
                    let id = await controller.startSession(
                        profileID: req.profileID, tool: req.tool, cwd: req.cwd,
                        cloneURL: req.cloneURL, message: req.openingMessage,
                        attachments: req.attachments, room: room)
                    starting = false
                    if let id { onStarted(id) } else { failed = true }
                }
            },
            onCancel: onCancel,
            onNewMachine: { workspaceEdit = .new },
            listFolders: { await controller.listSessionFolders(profileID: $0, path: $1) })
        .disabled(starting)
        .overlay {
            if starting {
                ProgressView("Starting…")
                    .padding(18)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.regularMaterial))
            }
        }
        .navigationTitle(room.flatMap { controller.roomStore.room($0)?.name }
            .map { String(format: NSLocalizedString("New session in “%@”", comment: "room new session banner"), $0) }
            ?? NSLocalizedString("New session", comment: "mobile"))
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn't start the session", isPresented: $failed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(controller.lastError ?? "The server didn't answer. Check the connection and try again.")
        }
        .sheet(item: $workspaceEdit) { edit in
            WorkspaceEditorSheet(controller: controller, editing: edit.editingID) {
                workspaceEdit = nil
            }
        }
    }
}

// MARK: - The list (phone dashboard)

/// The phone dashboard's "Sessions" block: one list — what needs you first,
/// then working, ready, asleep, ended, and last the ones whose machine or
/// folder is gone (dimmed) — with a caret to fold it and the new-session
/// button in its header.
struct MobileSessionsSection: View {
    let controller: RemoteHostController
    let onSelect: (UUID) -> Void
    let onNew: () -> Void
    /// A room card tapped (or a room just made): open it.
    var onSelectRoom: (UUID) -> Void = { _ in }
    /// "New Session in Room".
    var onNewInRoom: (UUID) -> Void = { _ in }
    @State private var newRoomFor: AgentSession?
    @State private var renamingRoom: AgentRoom?
    @State private var deletingRoom: AgentRoom?
    @AppStorage("sessions.listExpanded") private var expanded = true
    @AppStorage("sessions.archivedExpanded") private var archivedExpanded = false
    @AppStorage("sessions.endedExpanded") private var endedExpanded = false
    /// A long-press Delete on a session whose agent is running asks first.
    @State private var pendingDelete: AgentSession?
    /// A long-press "New worktree…": the session to branch off.
    @State private var pendingWorktree: AgentSession?

    private var model: SessionListModel { controller.listModel }

    /// A state's label over its cards ("NEEDS YOU · 2"); Ended folds.
    private func bucketLabel(_ bucket: SessionBucket, count: Int, folded: Bool?) -> some View {
        Button {
            if folded != nil { withAnimation(.easeOut(duration: 0.18)) { endedExpanded.toggle() } }
        } label: {
            HStack(spacing: 6) {
                Circle().fill(bucket.tint).frame(width: 7, height: 7)
                Text(bucket.title.uppercased())
                    .font(.caption2.weight(.semibold)).kerning(0.5)
                    .foregroundStyle(.secondary)
                Text("\(count)").font(.caption2.weight(.semibold)).monospacedDigit().foregroundStyle(.tertiary)
                Spacer()
                if let folded {
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(folded ? 0 : 90))
                }
            }
            .padding(.top, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(folded == nil)
    }

    var body: some View {
        let all = SessionHome.orderedAll(controller.sessionStore.sessions, in: model)
        let needsYou = all.filter { SessionHome.bucket(for: $0, in: model) == .needsYou }.count
        let list = MobileRooms.loose(all, controller)
        let rooms = controller.roomStore.activeRooms
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text("Sessions").font(.headline).foregroundStyle(.primary)
                        if needsYou > 0 {
                            Text("\(needsYou)")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.red))
                                .foregroundStyle(.white)
                                .accessibilityLabel("\(needsYou) sessions need you")
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expanded ? "Hide sessions" : "Show sessions")
                Spacer()
                if !list.isEmpty {
                    Text("\(list.count)")
                        .font(.caption.weight(.medium)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Button(action: onNew) {
                    Image(systemName: "plus").font(.body)
                }
                .accessibilityLabel("New session")
            }
            if expanded {
                // Rooms first: a card each, their sessions inside.
                ForEach(rooms) { r in
                    MobileRoomCard(controller: controller, room: r) { onSelectRoom(r.id) }
                        .contextMenu {
                            RoomMenu(controller: controller, room: r, onNewSession: onNewInRoom,
                                     onRename: { renamingRoom = $0 }, onDelete: { deletingRoom = $0 })
                        }
                        .dropDestination(for: String.self) { items, _ in
                            let ids = items.compactMap(UUID.init(uuidString:))
                            for id in ids { MobileRooms.move(controller, id, to: r.id) }
                            return !ids.isEmpty
                        }
                }
                if list.isEmpty && rooms.isEmpty {
                    emptyCard
                } else {
                    // Grouped by state, Ended folded away.
                    ForEach(SessionBucket.allCases) { bucket in
                        let group = list.filter { SessionHome.bucket(for: $0, in: model) == bucket }
                        if !group.isEmpty {
                            let folded = bucket == .ended && !endedExpanded
                            bucketLabel(bucket, count: group.count, folded: bucket == .ended ? folded : nil)
                            if !folded { ForEach(group) { card($0) } }
                        }
                    }
                }
            }
            let put = MobileRooms.looseArchived(controller)
            let putRooms = controller.roomStore.archivedRooms
            if !put.isEmpty || !putRooms.isEmpty {
                // Put away, not gone: folded by default.
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { archivedExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text("Archived").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        Text("\(put.count + putRooms.count)")
                            .font(.caption.weight(.medium)).monospacedDigit()
                            .foregroundStyle(.tertiary)
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(archivedExpanded ? 90 : 0))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(archivedExpanded ? "Hide archived sessions" : "Show archived sessions")
                if archivedExpanded {
                    ForEach(putRooms) { r in
                        MobileRoomCard(controller: controller, room: r) { onSelectRoom(r.id) }
                            .opacity(0.75)
                            .contextMenu {
                                RoomMenu(controller: controller, room: r, onNewSession: onNewInRoom,
                                         onRename: { renamingRoom = $0 }, onDelete: { deletingRoom = $0 })
                            }
                    }
                    ForEach(put) { card($0) }
                }
            }
        }
        .sheet(item: $pendingWorktree) { s in
            NewWorktreeSheet(parent: s, gitState: { await controller.sessionGitState($0) }) { req in
                Task {
                    if let id = await controller.startWorktreeSession(
                        from: s.id, name: req.name, tool: req.tool, message: req.message, initGit: req.initGit, base: req.base) {
                        onSelect(id)
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .confirmationDialog("Delete this session?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible) {
            Button("Delete session", role: .destructive) {
                if let s = pendingDelete { controller.sessionCommand(s.id, "delete") }
                pendingDelete = nil
            }
        } message: {
            Text("The agent stops and the session leaves the list. Its folder stays on the machine.")
        }
        .modifier(RoomPrompts(controller: controller, newRoomFor: $newRoomFor,
                              renaming: $renamingRoom, deleting: $deletingRoom,
                              onCreated: onSelectRoom))
    }

    /// Long-press: the same choices as the session's own menu.
    @ViewBuilder private func rowMenu(_ s: AgentSession) -> some View {
        let gone = SessionHome.isGone(s, in: model)
        if !gone {
            if SessionHome.hasFolder(s) {
                Button { pendingWorktree = s } label: {
                    Label("New worktree…", systemImage: "arrow.triangle.branch")
                }
            }
            if s.isArchived {
                Button { controller.sessionCommand(s.id, "unarchive") } label: {
                    Label("Unarchive", systemImage: "tray.and.arrow.up")
                }
            } else {
                Button { controller.sessionCommand(s.id, "archive") } label: {
                    Label(s.windowIndex != nil && !s.hasEnded ? "End & Archive" : "Archive",
                          systemImage: "archivebox")
                }
            }
            if s.windowIndex != nil, !s.hasEnded {
                Button { controller.sessionCommand(s.id, "close") } label: {
                    Label("End session", systemImage: "stop.circle")
                }
            }
            RoomSessionMenu(controller: controller, session: s, onNewRoom: { newRoomFor = $0 })
        }
        Divider()
        Button(role: .destructive) {
            if SessionHome.isAgentLive(s, in: model) { pendingDelete = s }
            else { controller.sessionCommand(s.id, "delete") }
        } label: { Label("Delete session", systemImage: "trash") }
    }

    private var emptyCard: some View {
        Button(action: onNew) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15)).frame(width: 42, height: 42)
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .medium)).foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("What can I help you with?").font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(controller.hasSnapshot ? "Start your first session." : "Loading sessions…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
    }

    private func card(_ s: AgentSession) -> some View {
        let bucket = SessionHome.bucket(for: s, in: model)
        let gone = SessionHome.isGone(s, in: model)
        let urgent = bucket == .needsYou
        return Button { onSelect(s.id) } label: {
            HStack(spacing: 12) {
                AgentAvatar(tool: s.tool, size: 34, status: SessionHome.dot(for: s, in: model))
                    .opacity(s.hasEnded ? 0.55 : 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.title).font(.body.weight(.semibold)).lineLimit(1)
                        .foregroundStyle(.primary)
                    HStack(spacing: 5) {
                        if !MobileSessions.workspaceName(model, s).isEmpty {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Color(hex: MobileSessions.accentHex(model, s)))
                                .frame(width: 6, height: 6)
                            Text(MobileSessions.workspaceName(model, s)).lineLimit(1)
                            Text("·").foregroundStyle(.tertiary)
                        }
                        Text(SessionHome.statusLine(for: s, in: model))
                            .lineLimit(1).truncationMode(.tail)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if let when = MobileSessions.when(s) {
                    Text(when).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(urgent ? Color.red.opacity(0.55) : Color.secondary.opacity(0.5))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(urgent ? Color.red.opacity(0.09)
                             : Color(uiColor: .secondarySystemGroupedBackground)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(urgent ? Color.red.opacity(0.3) : .clear, lineWidth: 1))
            .opacity(gone ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .contextMenu { rowMenu(s) }
        .draggable(s.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            // Another session dropped on this one: the two share a room.
            let ids = items.compactMap(UUID.init(uuidString:)).filter { $0 != s.id }
            guard controller.supportsRooms, !ids.isEmpty else { return false }
            for id in ids {
                Task {
                    let r = await controller.roomCommand(nil, "group",
                                                         body: ["dragged": id.uuidString, "onto": s.id.uuidString])
                    if let rid = (r?["id"] as? String).flatMap(UUID.init(uuidString:)) { onSelectRoom(rid) }
                }
            }
            return true
        }
    }
}

// MARK: - The list (iPad / visionOS sidebar)

/// One collapsible "Sessions" section for a `List(selection:)`: the
/// new-session row, then every session in sidebar order (gone ones dimmed,
/// last), each row tagged with its `PadSelection`.
struct PadSessionSections: View {
    let controller: RemoteHostController
    /// A session a row spawned (a worktree off its folder): select it.
    var onOpen: (UUID) -> Void = { _ in }
    /// A room just made (from a row's menu or a drop): select it.
    var onOpenRoom: (UUID) -> Void = { _ in }
    /// "New Session in Room".
    var onNewInRoom: (UUID) -> Void = { _ in }
    @State private var newRoomFor: AgentSession?
    @State private var renamingRoom: AgentRoom?
    @State private var deletingRoom: AgentRoom?
    @AppStorage("sessions.listExpanded") private var expanded = true
    @AppStorage("sessions.archivedExpanded") private var archivedExpanded = false
    /// A right-click / long-press Delete on a running agent asks first.
    @State private var pendingDelete: AgentSession?
    /// A right-click / long-press "New worktree…": the session to branch off.
    @State private var pendingWorktree: AgentSession?

    private var model: SessionListModel { controller.listModel }

    var body: some View {
        let all = SessionHome.orderedAll(controller.sessionStore.sessions, in: model)
        let needsYou = all.filter { SessionHome.bucket(for: $0, in: model) == .needsYou }.count
        let put = MobileRooms.looseArchived(controller)
        let putRooms = controller.roomStore.archivedRooms
        sessionsSection(MobileRooms.loose(all, controller), needsYou: needsYou)
        if !put.isEmpty || !putRooms.isEmpty {
            // Put away, not gone: folded by default.
            Section(isExpanded: $archivedExpanded) {
                ForEach(putRooms) { r in
                    PadRoomRow(controller: controller, room: r)
                        .opacity(0.75)
                        .tag(PadSelection.room(r.id))
                        .contextMenu {
                            RoomMenu(controller: controller, room: r, onNewSession: onNewInRoom,
                                     onRename: { renamingRoom = $0 }, onDelete: { deletingRoom = $0 })
                        }
                }
                ForEach(put) { s in
                    row(s).tag(PadSelection.session(s.id)).contextMenu { rowMenu(s) }
                }
            } header: {
                HStack(spacing: 6) {
                    Text("Archived")
                    Spacer()
                    Text("\(put.count + putRooms.count)")
                        .font(.footnote.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
        }
    }

    private func sessionsSection(_ list: [AgentSession], needsYou: Int) -> some View {
        Section(isExpanded: $expanded) {
            Label("New Session…", systemImage: "plus")
                .foregroundStyle(.tint)
                .tag(PadSelection.newSession)
                // The rows' "New worktree…" presents its sheet here too.
                .sheet(item: $pendingWorktree) { s in
                    NewWorktreeSheet(parent: s, gitState: { await controller.sessionGitState($0) }) { req in
                        Task {
                            if let id = await controller.startWorktreeSession(
                                from: s.id, name: req.name, tool: req.tool, message: req.message, initGit: req.initGit, base: req.base) {
                                onOpen(id)
                            }
                        }
                    }
                    .presentationDetents([.medium, .large])
                }
                // The rows' Delete asks here when the agent is running (a
                // row inside the list can present; the Section can't).
                .confirmationDialog("Delete this session?", isPresented: Binding(
                    get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                    titleVisibility: .visible) {
                    Button("Delete session", role: .destructive) {
                        if let s = pendingDelete { controller.sessionCommand(s.id, "delete") }
                        pendingDelete = nil
                    }
                } message: {
                    Text("The agent stops and the session leaves the list. Its folder stays on the machine.")
                }
            if list.isEmpty && controller.roomStore.activeRooms.isEmpty {
                Text(controller.hasSnapshot ? "No sessions yet." : "Loading sessions…")
                    .font(.callout).foregroundStyle(.secondary)
            }
            // Rooms first; their sessions live inside them.
            ForEach(controller.roomStore.activeRooms) { r in
                PadRoomRow(controller: controller, room: r)
                    .tag(PadSelection.room(r.id))
                    .contextMenu {
                        RoomMenu(controller: controller, room: r, onNewSession: onNewInRoom,
                                 onRename: { renamingRoom = $0 }, onDelete: { deletingRoom = $0 })
                    }
                    .dropDestination(for: String.self) { items, _ in
                        let ids = items.compactMap(UUID.init(uuidString:))
                        for id in ids { MobileRooms.move(controller, id, to: r.id) }
                        return !ids.isEmpty
                    }
            }
            .modifier(RoomPrompts(controller: controller, newRoomFor: $newRoomFor,
                                  renaming: $renamingRoom, deleting: $deletingRoom,
                                  onCreated: onOpenRoom))
            ForEach(list) { s in
                row(s)
                    .opacity(SessionHome.isGone(s, in: model) ? 0.5 : 1)
                    .tag(PadSelection.session(s.id))
                    .contextMenu { rowMenu(s) }
                    .draggable(s.id.uuidString)
                    .dropDestination(for: String.self) { items, _ in
                        let ids = items.compactMap(UUID.init(uuidString:)).filter { $0 != s.id }
                        guard controller.supportsRooms, !ids.isEmpty else { return false }
                        for id in ids {
                            Task {
                                let r = await controller.roomCommand(
                                    nil, "group", body: ["dragged": id.uuidString, "onto": s.id.uuidString])
                                if let rid = (r?["id"] as? String).flatMap(UUID.init(uuidString:)) { onOpenRoom(rid) }
                            }
                        }
                        return true
                    }
            }
        } header: {
            HStack(spacing: 6) {
                Text("Sessions")
                if needsYou > 0 {
                    Text("\(needsYou)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.red))
                        .foregroundStyle(.white)
                        .textCase(nil)
                }
                Spacer()
                if !list.isEmpty {
                    Text("\(list.count)")
                        .font(.footnote.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
            }
        }
    }

    /// Right-click / long-press: the same choices as the session's own menu.
    @ViewBuilder private func rowMenu(_ s: AgentSession) -> some View {
        let gone = SessionHome.isGone(s, in: model)
        if !gone {
            if SessionHome.hasFolder(s) {
                Button { pendingWorktree = s } label: {
                    Label("New worktree…", systemImage: "arrow.triangle.branch")
                }
            }
            if s.isArchived {
                Button { controller.sessionCommand(s.id, "unarchive") } label: {
                    Label("Unarchive", systemImage: "tray.and.arrow.up")
                }
            } else {
                Button { controller.sessionCommand(s.id, "archive") } label: {
                    Label(s.windowIndex != nil && !s.hasEnded ? "End & Archive" : "Archive",
                          systemImage: "archivebox")
                }
            }
            if s.windowIndex != nil, !s.hasEnded {
                Button { controller.sessionCommand(s.id, "close") } label: {
                    Label("End session", systemImage: "stop.circle")
                }
            }
            RoomSessionMenu(controller: controller, session: s, onNewRoom: { newRoomFor = $0 })
        }
        Divider()
        Button(role: .destructive) {
            if SessionHome.isAgentLive(s, in: model) { pendingDelete = s }
            else { controller.sessionCommand(s.id, "delete") }
        } label: { Label("Delete session", systemImage: "trash") }
    }

    private func row(_ s: AgentSession) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(s.title).lineLimit(1)
                    Spacer(minLength: 0)
                    if let when = MobileSessions.when(s) {
                        Text(when).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 4) {
                    if !MobileSessions.workspaceName(model, s).isEmpty {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color(hex: MobileSessions.accentHex(model, s)))
                            .frame(width: 6, height: 6)
                        Text(MobileSessions.workspaceName(model, s))
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(SessionHome.statusLine(for: s, in: model))
                        .lineLimit(1).truncationMode(.tail)
                }
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(1)
            }
        } icon: {
            AgentAvatar(tool: s.tool, size: 24, status: SessionHome.dot(for: s, in: model))
                .opacity(s.hasEnded ? 0.55 : 1)
        }
    }
}
