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
            represent: { _ in },
            showFiles: onLinux,
            showContainers: { _ in onLinux() },
            showMachine: { _ in onLinux() },
            toggleUnderTheHood: onLinux)
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

    @State private var showLinux = false
    @State private var renaming = false
    @State private var draftTitle = ""
    @State private var confirmEnd = false

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
        } else if !s.hasEnded, SessionHome.liveTab(for: s, in: model) != nil {
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
        Menu {
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
            if s.windowIndex != nil {
                Button(role: .destructive) { confirmEnd = true } label: {
                    Label("End session", systemImage: "stop.circle")
                }
            }
            if s.hasEnded {
                Button(role: .destructive) {
                    controller.sessionCommand(s.id, "forget")
                    onForget()
                } label: { Label("Forget this session", systemImage: "trash") }
            }
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
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    HStack(spacing: 5) {
                        if let st = SessionHome.dot(for: s, in: model) {
                            AgentStatusDot(status: st).scaleEffect(1.15)
                        } else {
                            Circle().fill(bucket.tint).frame(width: 7, height: 7)
                        }
                        Text(statusText(s, bucket: bucket))
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
                    Text("·").foregroundStyle(.tertiary)
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color(hex: MobileSessions.accentHex(model, s)))
                            .frame(width: 6, height: 6)
                        Text(MobileSessions.workspaceName(model, s))
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
            if bucket == .ended || bucket == .asleep {
                Button {
                    actions.resume(s.id)
                } label: {
                    Label(bucket == .asleep ? "Wake up" : "Resume", systemImage: "play.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.platformWindowBackground)
        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
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
                        cloneURL: req.cloneURL, message: req.openingMessage)
                    starting = false
                    if let id { onStarted(id) } else { failed = true }
                }
            },
            onCancel: onCancel,
            onNewMachine: { workspaceEdit = .new })
        .disabled(starting)
        .overlay {
            if starting {
                ProgressView("Starting…")
                    .padding(18)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.regularMaterial))
            }
        }
        .navigationTitle("New session")
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

/// The phone dashboard's "Sessions" block: grouped cards — Needs you,
/// Working, Ready, Asleep, then Ended folded away — with the new-session
/// button in its header.
struct MobileSessionsSection: View {
    let controller: RemoteHostController
    let onSelect: (UUID) -> Void
    let onNew: () -> Void
    @State private var showEnded = false

    private var model: SessionListModel { controller.listModel }

    var body: some View {
        let groups = SessionHome.grouped(controller.sessionStore.sessions, in: model)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Sessions").font(.headline)
                Spacer()
                Button(action: onNew) {
                    Image(systemName: "plus").font(.body)
                }
                .accessibilityLabel("New session")
            }
            if controller.sessionStore.sessions.isEmpty {
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
            } else {
                ForEach(SessionBucket.allCases) { bucket in
                    if let list = groups[bucket], !list.isEmpty {
                        if bucket == .ended {
                            Button { withAnimation(.easeOut(duration: 0.18)) { showEnded.toggle() } } label: {
                                HStack(spacing: 5) {
                                    bucketLabel(bucket, count: list.count)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.tertiary)
                                        .rotationEffect(.degrees(showEnded ? 90 : 0))
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if showEnded {
                                ForEach(list) { card($0, bucket: bucket) }
                            }
                        } else {
                            bucketLabel(bucket, count: list.count)
                            ForEach(list) { card($0, bucket: bucket) }
                        }
                    }
                }
            }
        }
    }

    private func bucketLabel(_ bucket: SessionBucket, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(bucket.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(bucket == .needsYou ? Color.red : Color.secondary)
                .textCase(.uppercase)
                .tracking(0.5)
            Text("\(count)")
                .font(.caption2.weight(.semibold)).monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 4)
    }

    private func card(_ s: AgentSession, bucket: SessionBucket) -> some View {
        Button { onSelect(s.id) } label: {
            HStack(spacing: 12) {
                AgentAvatar(tool: s.tool, size: 34, status: SessionHome.dot(for: s, in: model))
                    .opacity(s.hasEnded ? 0.55 : 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.title).font(.body.weight(.semibold)).lineLimit(1)
                        .foregroundStyle(.primary)
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color(hex: MobileSessions.accentHex(model, s)))
                            .frame(width: 6, height: 6)
                        Text(MobileSessions.workspaceName(model, s)).lineLimit(1)
                        Text("·").foregroundStyle(.tertiary)
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
                    .foregroundStyle(bucket == .needsYou ? Color.red.opacity(0.55) : Color.secondary.opacity(0.5))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(bucket == .needsYou ? Color.red.opacity(0.09)
                                          : Color(uiColor: .secondarySystemGroupedBackground)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(bucket == .needsYou ? Color.red.opacity(0.3) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - The list (iPad / visionOS sidebar)

/// Sidebar sections for a `List(selection:)`: one per non-empty bucket,
/// Ended collapsible, each row tagged with its `PadSelection`. Sits above
/// the boards and workspaces so a session is the first thing to pick.
struct PadSessionSections: View {
    let controller: RemoteHostController
    @State private var showEnded = false

    private var model: SessionListModel { controller.listModel }

    var body: some View {
        let groups = SessionHome.grouped(controller.sessionStore.sessions, in: model)
        Section {
            Label("New Session…", systemImage: "plus")
                .foregroundStyle(.tint)
                .tag(PadSelection.newSession)
            if controller.sessionStore.sessions.isEmpty {
                Text(controller.hasSnapshot ? "No sessions yet." : "Loading sessions…")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } header: {
            Text("Sessions")
        }
        ForEach(SessionBucket.allCases) { bucket in
            if let list = groups[bucket], !list.isEmpty {
                if bucket == .ended {
                    Section(isExpanded: $showEnded) {
                        ForEach(list) { row($0).tag(PadSelection.session($0.id)) }
                    } header: {
                        Text(bucket.title)
                    }
                } else {
                    Section {
                        ForEach(list) { row($0).tag(PadSelection.session($0.id)) }
                    } header: {
                        HStack(spacing: 6) {
                            Text(bucket.title)
                            if bucket == .needsYou {
                                Text("\(list.count)")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.red))
                                    .foregroundStyle(.white)
                                    .textCase(nil)
                            }
                        }
                    }
                }
            }
        }
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
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color(hex: MobileSessions.accentHex(model, s)))
                        .frame(width: 6, height: 6)
                    Text(MobileSessions.workspaceName(model, s))
                    Text("·").foregroundStyle(.tertiary)
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
