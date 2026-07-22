import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Workspace detail (iOS)
//
// One remote workspace, on a small screen: a segmented switch between the live
// terminals (SwiftTerm over the in-process attach pump), the VM dashboard,
// Docker, and the Files browser — each backed by the reused shared views and
// the mirror controller's tunnel actions.

struct WorkspaceScreen: View {
    let controller: RemoteHostController
    let profileID: Profile.ID
    /// When set, open straight to this tmux window's terminal (used by the
    /// "At a Glance" agents-waiting list and the grid).
    var initialWindow: Int? = nil

    enum Pane: String, CaseIterable, Identifiable {
        case terminals = "Terminals"
        case dashboard = "Info"
        case docker = "Docker"
        case files = "Files"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .terminals: "terminal"
            case .dashboard: "gauge.with.dots.needle.67percent"
            case .docker: "shippingbox"
            case .files: "folder"
            }
        }
    }
    @State private var pane: Pane = .terminals

    private var runState: SessionListModel.RunState { controller.runState(for: profileID) }
    private var isRunning: Bool { runState == .running || runState == .booting }
    private var profileName: String {
        controller.profile(for: profileID)?.name ?? "Workspace"
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $pane) {
                ForEach(availablePanes) { p in
                    Label(p.rawValue, systemImage: p.symbol).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 6)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(profileName)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: isRunning) { _, running in
            if !running && pane != .dashboard { pane = .dashboard }
        }
    }

    private var availablePanes: [Pane] {
        isRunning ? Pane.allCases : [.dashboard]
    }

    @ViewBuilder private var content: some View {
        switch pane {
        case .terminals: TerminalsPane(controller: controller, profileID: profileID,
                                       initialWindow: initialWindow)
        case .dashboard: dashboard
        case .docker:    docker
        case .files:     files
        }
    }

    // MARK: Dashboard

    private var dashboard: some View {
        let spec = controller.specs[profileID] ?? .init()
        let profile = controller.profile(for: profileID)
            ?? Profile(id: profileID, name: profileName, tool: .claude, authMode: .token)
        return VMDashboardView(
            model: controller.tabsModel(for: profileID),
            profile: profile,
            accentHex: profile.color.hexInUI,
            state: runState,
            vCPUs: spec.cpus,
            diskAllocatedBytes: spec.diskAllocatedBytes,
            diskCapacityBytes: spec.diskCapacityBytes,
            startedAt: controller.bootTimes[profileID],
            onNewTerminal: { controller.newTab(profileID) },
            onSuspend: { controller.suspendWorkspace(profileID) },
            onReboot: { controller.restartWorkspace(profileID) },
            onShutdown: { controller.shutdownWorkspace(profileID) },
            onResume: { controller.startWorkspace(profileID) })
    }

    // MARK: Docker

    @ViewBuilder private var docker: some View {
        if let model = controller.tabsModel(for: profileID) {
            DockerDashboardView(
                model: model,
                accentHex: controller.profile(for: profileID)?.color.hexInUI ?? "#3B82F6",
                onRun: { controller.dockerAction(profileID, dockerRunBody($0)) },
                onStart: { controller.dockerAction(profileID, ["action": "start", "id": $0]) },
                onStop: { controller.dockerAction(profileID, ["action": "stop", "id": $0]) },
                onRemove: { controller.dockerAction(profileID, ["action": "remove", "id": $0]) },
                onAttach: { id, _ in controller.dockerAction(profileID, ["action": "attach", "id": id]) },
                onLogs: { controller.dockerAction(profileID, ["action": "logs", "id": $0]) },
                onVolumeCreate: { controller.dockerAction(profileID, ["action": "volume-create", "name": $0]) },
                onVolumeRemove: { controller.dockerAction(profileID, ["action": "volume-remove", "name": $0]) },
                onInstallBinfmt: { controller.dockerAction(profileID, ["action": "binfmt-install"]) },
                onUninstallBinfmt: { controller.dockerAction(profileID, ["action": "binfmt-uninstall"]) })
        } else {
            ContentUnavailableView("Docker unavailable", systemImage: "shippingbox",
                description: Text("Start the workspace to see its containers."))
        }
    }

    private func dockerRunBody(_ spec: ACAppDelegate.DockerRunSpec) -> [String: Any] {
        var b: [String: Any] = ["action": "run", "image": spec.image]
        if !spec.name.isEmpty { b["name"] = spec.name }
        if !spec.ports.isEmpty { b["ports"] = spec.ports }
        if !spec.env.isEmpty { b["env"] = spec.env }
        if !spec.volumes.isEmpty { b["volumes"] = spec.volumes }
        b["inheritEnv"] = spec.inheritEnv
        b["inheritProxy"] = spec.inheritProxy
        b["interactive"] = spec.interactive
        return b
    }

    // MARK: Files

    private var files: some View {
        FilesPane(controller: controller, profileID: profileID,
                  mounts: controller.mounts[profileID] ?? [])
    }
}

// MARK: - Terminals pane

/// The workspace's tmux windows as a picker + one live SwiftTerm surface. Each
/// window index gets its own `AttachSession`, cached so switching tabs doesn't
/// re-handshake.
private struct TerminalsPane: View {
    let controller: RemoteHostController
    let profileID: Profile.ID
    var initialWindow: Int? = nil
    @State private var sessions: [Int: AttachSession] = [:]
    @State private var selectedWindow: Int?
    @State private var didSeedInitial = false
    /// Persisted terminal font size (points), driven by pinch-to-zoom and
    /// shared across every window and relaunch.
    @AppStorage("bromure.terminal.fontSizePt") private var fontSizePt: Double = 13
    /// The user's explicit terminal/reader choice for the current window, or
    /// nil to follow the window's agentic state (an agent window defaults to
    /// the rich reader). Cleared on a window switch so each tab re-evaluates.
    @State private var readerOverride: Bool?

    private var model: TabsModel? { controller.tabsModel(for: profileID) }
    private var tabs: [TabsModel.Tab] { model?.tabs ?? [] }

    private var fontBinding: Binding<CGFloat> {
        Binding(get: { CGFloat(fontSizePt) }, set: { fontSizePt = Double($0) })
    }

    /// The guest working directory backing a window's Claude transcript.
    private func guestCwd(for window: Int) -> String? {
        let tab = tabs.first { $0.index == window }
        let cwd = tab?.cwd ?? tab?.repoRoot
        return (cwd?.isEmpty ?? true) ? nil : cwd
    }

    private var currentTab: TabsModel.Tab? {
        guard let win = effectiveWindow else { return nil }
        return tabs.first { $0.index == win }
    }

    /// "Agentic mode": a coding agent is live in this window (actively working,
    /// waiting on the user, or it's a task worktree). Those default to the rich
    /// reader instead of raw ANSI.
    private func isAgentic(_ tab: TabsModel.Tab?) -> Bool {
        guard let tab else { return false }
        return tab.agentStatus == .working || tab.agentStatus == .needsInput || tab.isWorktree
    }

    private var readerMode: Bool { readerOverride ?? isAgentic(currentTab) }

    var body: some View {
        VStack(spacing: 0) {
            if tabs.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(tabs) { tab in
                            tabChip(tab)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                Divider()
            }
            if let win = effectiveWindow {
                if readerMode {
                    TranscriptReaderView(controller: controller, profileID: profileID,
                                         window: win, guestCwd: guestCwd(for: win))
                        .id("reader-\(profileID)-\(win)")
                } else {
                    TerminalSurface(session: session(for: win), fontSize: fontBinding)
                        .id("\(profileID)-\(win)")
                }
            } else {
                ContentUnavailableView("No terminal", systemImage: "terminal",
                    description: Text("This workspace has no open windows yet."))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { readerOverride = !readerMode } label: {
                    Image(systemName: readerMode ? "terminal" : "doc.richtext")
                }
                .accessibilityLabel(readerMode ? "Show raw terminal" : "Show reader")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { controller.newTab(profileID) } label: {
                    Image(systemName: "plus.rectangle.on.rectangle")
                }
                .accessibilityLabel("New terminal")
            }
        }
        .onAppear {
            // Land on the requested window (a waiting agent / grid cell) once.
            guard !didSeedInitial, let initialWindow else { return }
            didSeedInitial = true
            selectedWindow = initialWindow
            controller.selectTab(profileID, index: initialWindow)
        }
        // Switching windows drops any manual terminal/reader override, so each
        // window re-evaluates the agentic default.
        .onChange(of: effectiveWindow) { _, _ in readerOverride = nil }
    }

    private var effectiveWindow: Int? {
        if let selectedWindow, tabs.contains(where: { $0.index == selectedWindow }) {
            return selectedWindow
        }
        return model?.activeTab?.index ?? tabs.first?.index
    }

    private func session(for window: Int) -> AttachSession {
        if let s = sessions[window] { return s }
        let s = AttachSession(host: controller.host, vmID: profileID.uuidString, windowIndex: window)
        sessions[window] = s
        return s
    }

    @ViewBuilder private func tabChip(_ tab: TabsModel.Tab) -> some View {
        let selected = tab.index == effectiveWindow
        Button {
            selectedWindow = tab.index
            controller.selectTab(profileID, index: tab.index)
        } label: {
            HStack(spacing: 5) {
                AgentStatusDot(status: tab.agentStatus)
                Text(tab.shownLabel.isEmpty ? "shell" : tab.shownLabel)
                    .font(.callout)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule().fill(selected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                _ = controller.gridStore.add(profileID: profileID, windowIndex: tab.index,
                                             label: tab.shownLabel)
                controller.pushGridLayout()
            } label: { Label("Send to Grid", systemImage: "square.grid.2x2") }
            Button(role: .destructive) {
                controller.closeTab(profileID, index: tab.index)
                sessions[tab.index]?.stop()
                sessions[tab.index] = nil
            } label: { Label("Close", systemImage: "xmark") }
        }
    }
}

// MARK: - Terminal surface

/// The live terminal plus a connection veil — so a workspace that hasn't
/// attached yet (or has dropped) reads as "Connecting…" rather than a dead
/// black box you can't type into. Observes the session so the veil clears the
/// moment the pump connects.
private struct TerminalSurface: View {
    @ObservedObject var session: AttachSession
    let fontSize: Binding<CGFloat>

    var body: some View {
        ZStack {
            Color.black
            RemoteTerminalView(session: session, fontSize: fontSize)
            if !session.connected {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(session.lastError ?? "Connecting…")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Transcript reader

/// A read-only, Claude-Code-Desktop-style rendering of the active terminal's
/// live Claude transcript — prose, markdown, thinking, and tool traffic laid
/// out as a conversation instead of raw ANSI. Tails the guest `.jsonl` over the
/// tunnel every couple of seconds (the same command the desktop plan windows
/// use) and reuses the shared `TranscriptItemView`.
private struct TranscriptReaderView: View {
    let controller: RemoteHostController
    let profileID: Profile.ID
    /// The tmux window index this reader mirrors — where a typed message is
    /// sent, so the conversation lands in the right agent tab.
    let window: Int
    let guestCwd: String?
    @State private var items: [TranscriptItem] = []
    @State private var loaded = false
    @State private var draft = ""
    @State private var sending = false
    // Image attach → upload → path, mirroring desktop copy-paste.
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showFileImporter = false
    @State private var uploading = false
    @State private var uploadError: String?

    var body: some View {
        VStack(spacing: 0) {
            transcript
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            composerBar
        }
        .task(id: guestCwd) { await poll() }
    }

    // MARK: Composer + image attach

    private var composerBar: some View {
        VStack(spacing: 4) {
            if let uploadError {
                Text(uploadError).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Type into the agent's session — the message (and any uploaded
            // image path) shows up in the transcript on the next poll, and the
            // agent responds inline.
            HStack(alignment: .bottom, spacing: 8) {
                attachButton
                ChatComposer(placeholder: "Message the agent…", text: $draft,
                             busy: sending, onSend: send)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.platformControlBackground)
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
        .fileImporter(isPresented: $showFileImporter,
                      allowedContentTypes: [.image], allowsMultipleSelection: false,
                      onCompletion: handleFileImport)
    }

    /// An image an agent can read: pick from the photo library, from Files, or
    /// paste from the clipboard. Each uploads into the guest's pastes dir and
    /// drops the resulting guest path into the message — exactly what a
    /// desktop copy-paste of an image does.
    private var attachButton: some View {
        Menu {
            Button { showPhotoPicker = true } label: {
                Label("Photo Library", systemImage: "photo")
            }
            Button { showFileImporter = true } label: {
                Label("Choose File", systemImage: "folder")
            }
            if UIPasteboard.general.hasImages {
                Button { pasteImage() } label: {
                    Label("Paste Image", systemImage: "doc.on.clipboard")
                }
            }
        } label: {
            Group {
                if uploading {
                    ProgressView()
                } else {
                    Image(systemName: "paperclip.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 34, height: 34)
        }
        .disabled(uploading)
        .accessibilityLabel("Attach image")
    }

    @ViewBuilder private var transcript: some View {
        if guestCwd?.isEmpty ?? true {
            unavailable("Not a project folder",
                        "This terminal isn't running in a folder with a Claude session.")
        } else if !loaded {
            ProgressView("Loading transcript…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            unavailable("No transcript",
                        "No Claude session was found for this terminal yet — send a message to get started.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(items) { TranscriptItemView(item: $0) }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Jump to the newest turn when the reader opens…
                .onAppear { scrollToBottom(proxy, animated: false) }
                // …and follow the live tail as new turns arrive.
                .onChange(of: items.count) { _, _ in scrollToBottom(proxy, animated: true) }
            }
            .background(Color.platformWindowBackground)
        }
    }

    @ViewBuilder private func unavailable(_ title: String, _ detail: String) -> some View {
        ContentUnavailableView(title, systemImage: "doc.richtext", description: Text(detail))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Scroll to the last item. The short defer lets the lazy stack realize
    /// freshly-appended rows first, so the target actually exists.
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = items.last?.id else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if animated { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
            else { proxy.scrollTo(last, anchor: .bottom) }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        Task {
            _ = try? await controller.guestExec(
                profileID,
                command: CodingTaskEngine.typeCommand(tabIndex: window, text: text),
                timeout: 20)
            await MainActor.run { draft = ""; sending = false }
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) async {
        defer { Task { @MainActor in photoItem = nil } }
        guard let raw = try? await item.loadTransferable(type: Data.self), !raw.isEmpty else {
            await MainActor.run { uploadError = "Couldn't read the selected photo." }
            return
        }
        // Normalize to PNG so the guest gets a predictable format.
        let png = UIImage(data: raw).flatMap { $0.pngData() }
        await upload([.bitmap(png ?? raw, ext: png != nil ? "png" : "img")])
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, let url = urls.first else { return }
        // Read the bytes while the security scope is open — the upload runs
        // later, off this callback.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            uploadError = "Couldn't read the selected file."
            return
        }
        let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension.lowercased()
        Task { await upload([.bitmap(data, ext: ext)]) }
    }

    private func pasteImage() {
        guard let img = UIPasteboard.general.image, let png = img.pngData() else {
            uploadError = "No image on the clipboard."
            return
        }
        Task { await upload([.bitmap(png, ext: "png")]) }
    }

    /// Chunk the image into the guest's pastes dir (shared with the desktop's
    /// terminal image paste) and append the returned guest path to the draft.
    private func upload(_ sources: [TerminalImagePaste.Source]) async {
        guard !sources.isEmpty, !uploading else { return }
        await MainActor.run { uploading = true; uploadError = nil }
        do {
            let op: TerminalImagePaste.GuestFileOp = {
                try await controller.guestFileOp(profileID, op: $0)
            }
            let paths = try await TerminalImagePaste.upload(sources, via: op)
            await MainActor.run {
                let joined = paths.joined(separator: " ")
                draft += (draft.isEmpty ? "" : " ") + joined + " "
                uploading = false
            }
        } catch {
            await MainActor.run { uploadError = "Upload failed."; uploading = false }
        }
    }

    private func poll() async {
        guard let cwd = guestCwd, !cwd.isEmpty,
              let cmd = CodingTaskEngine.planTranscriptCommand(guestCwd: cwd, since: 0)
        else { loaded = true; return }
        while !Task.isCancelled {
            if let raw = try? await controller.guestExec(profileID, command: cmd, timeout: 15) {
                items = ClaudeTranscriptParser.parse(Data(raw.utf8))
            }
            loaded = true
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}

// MARK: - Files pane

/// The reused `FileBrowserView`, backed by the workspace's guest file op bridge
/// over the tunnel. Integrates with the iOS Files app via `lastDownloaded`
/// (a downloaded/opened file → share sheet → Save to Files).
private struct FilesPane: View {
    let controller: RemoteHostController
    let profileID: Profile.ID
    let mounts: [String]
    /// Built once (not per-render) so the browser keeps its directory + doesn't
    /// re-list on every update. The download share sheet and the upload importer
    /// live inside FileBrowserView (iOS).
    @State private var model: FileBrowserModel?

    var body: some View {
        Group {
            if let model {
                FileBrowserView(model: model)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if model == nil { model = makeModel() } }
    }

    private func makeModel() -> FileBrowserModel {
        var locations: [FileBrowserLocation] = [
            FileBrowserLocation(name: "Home", backing: .guest,
                                guestPath: "/home/ubuntu", symbol: "house")
        ]
        for m in mounts {
            locations.append(FileBrowserLocation(
                name: (m as NSString).lastPathComponent, backing: .guest,
                guestPath: m, symbol: "externaldrive"))
        }
        return FileBrowserModel(
            locations: locations,
            cacheKey: profileID.uuidString,
            guestOp: { op in try await controller.guestFileOp(profileID, op: op) })
    }
}
