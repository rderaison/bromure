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
    /// Set when this screen is a SESSION's stage (MobileSessionScreen), not the
    /// machine: the agent the session runs ("claude", "codex", …). The screen
    /// then shows that one window only, opening on the beautified reader — no
    /// pane picker, no tabs for the machine's other windows — the same thing
    /// the desktop's sessions-first stage shows. "Terminal" in the session's
    /// menu still opens the whole machine.
    var sessionTool: String? = nil
    /// The session's folder, for a tab whose cwd the roster hasn't reported.
    var sessionCwd: String? = nil
    private var isSessionStage: Bool { sessionTool != nil }

    /// Bridges the workspace's browser MCP (an agent's `browser_navigate`) and
    /// the manual port browser to one shared WKWebView + loopback tunnel. Its
    /// relay runs for the life of this screen (started in `.onAppear`).
    @StateObject private var browserBridge: MobileBrowserBridge

    init(controller: RemoteHostController, profileID: Profile.ID, initialWindow: Int? = nil,
         sessionTool: String? = nil, sessionCwd: String? = nil) {
        self.controller = controller
        self.profileID = profileID
        self.initialWindow = initialWindow
        self.sessionTool = sessionTool
        self.sessionCwd = sessionCwd
        _browserBridge = StateObject(
            wrappedValue: MobileBrowserBridge(controller: controller, profileID: profileID))
    }

    enum Pane: String, CaseIterable, Identifiable {
        case terminals = "Terminals"
        case dashboard = "Info"
        case web = "Web"
        case docker = "Docker"
        case files = "Files"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .terminals: "terminal"
            case .dashboard: "gauge.with.dots.needle.67percent"
            case .web: "globe"
            case .docker: "shippingbox"
            case .files: "folder"
            }
        }
    }
    @State private var pane: Pane = .terminals
    /// Debounces the not-running → Info fallback (see the `isRunning` onChange):
    /// a transient snapshot dip must not yank a live terminal to the dashboard.
    @State private var stopFallback: Task<Void, Never>?
    /// The repo file pane beside the terminals (iPad, regular width) — the
    /// same `FileExplorerPane` + IDE-style auto-open the macOS window uses.
    /// Open state lives on the shared listModel (`filePaneOpen`), which the
    /// pane would flip on repo enter/leave via `onAutoSetOpen` -- ignored on
    /// iOS, where only the toolbar button opens it.
    @State private var fileExplorer = FileExplorerModel()
    /// Compact height = the phone is on its side. A terminal is the one pane
    /// that wants every one of those few hundred points, so landscape drops the
    /// pane picker and the tab strip and hands the whole area to the surface.
    /// Rotating back brings them straight back; the nav bar stays either way
    /// (it carries Back and the reader / new-terminal actions).
    @Environment(\.verticalSizeClass) private var vSize
    /// Regular width (iPad) keeps the pills compact and leading-aligned like a
    /// toolbar; compact width (phone) lets the selected pill flex to fill.
    @Environment(\.horizontalSizeClass) private var hSize
    private var terminalFullBleed: Bool { vSize == .compact && pane == .terminals }

    private var runState: SessionListModel.RunState { controller.runState(for: profileID) }
    private var isRunning: Bool { runState == .running || runState == .booting }
    private var profileName: String {
        controller.profile(for: profileID)?.name ?? "Workspace"
    }

    var body: some View {
        VStack(spacing: 0) {
            if !terminalFullBleed && !isSessionStage {
                panePicker
                Divider()
            }

            // Everything below is a mirror of the remote's last known state. If
            // the poll has stopped answering, say so HERE: the tab strip, the
            // dashboard and the docker list all keep rendering their last good
            // values, which otherwise read as current. That is how a rebooted
            // workspace ends up "having more tabs on the phone than on the
            // desktop" — the phone is showing what was true before the link
            // dropped, with nothing on screen to admit it.
            if !controller.connected && controller.hasSnapshot {
                staleBanner
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .modifier(MachineTitle(title: profileName, enabled: !isSessionStage))
        .onChange(of: isRunning) { _, running in
            FatClientLog.log("workspace \(profileID.uuidString.prefix(8)) isRunning=\(running) "
                + "state=\(runState) connected=\(controller.connected) "
                + "hasRow=\(controller.profile(for: profileID) != nil)")
            if running {
                stopFallback?.cancel(); stopFallback = nil
                return
            }
            // Fall back to the dashboard only on a GENUINE, SUSTAINED stop. A
            // transient/partial snapshot after a link blip can briefly report the
            // workspace as not-running (or drop its row), which would otherwise
            // yank the user off a live terminal to Info mid-session — the "it
            // switched to Info by itself" bug. Debounce so a dip that recovers
            // within a few polls never triggers the switch.
            stopFallback?.cancel()
            stopFallback = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                // A session's stage has no pane picker to come back with; the
                // session screen itself moves on once the window is gone.
                guard !Task.isCancelled, !isRunning, pane != .dashboard, !isSessionStage else { return }
                FatClientLog.log("workspace \(profileID.uuidString.prefix(8)) "
                    + "stayed not-running 3s — falling back to Info")
                pane = .dashboard
            }
        }
        // Serve the browser MCP for this workspace while its screen is open.
        .onAppear { [controller] in
            browserBridge.start()
            // The file pane resolves "the active tab's repo" through the
            // shared listModel selection, exactly like the macOS windows.
            controller.listModel.selectedID = profileID
            fileExplorer.execProvider = { [weak controller] id, command, timeout in
                guard let controller else { throw ACAppDelegate.GuestExecError.vmNotRunning }
                return try await controller.guestExec(id, command: command, timeout: timeout)
            }
            // Reading the workspace clears any "an agent needs your input"
            // notification for it — the user has now seen the state, so the OS
            // banner is redundant (the in-app tab badges still show what's
            // pending). The server-side event stays open until answered.
            PushManager.shared.markWorkspaceRead(
                server: controller.host.peerDeviceID,
                profile: profileID.uuidString)
        }
        .toolbar {
            // Constant item count (iOS 26 leaves ghost buttons behind removed
            // toolbar items) — render nothing when the pane doesn't apply.
            ToolbarItem(placement: .primaryAction) {
                if hSize != .regular, isSessionStage, isRunning, let cwd = sessionCwd {
                    // The phone has no room beside the chat: the session's
                    // files come up as a sheet.
                    SessionFilesButton(controller: controller, profileID: profileID, cwd: cwd)
                } else if hSize == .regular && pane == .terminals && isRunning {
                    Button {
                        withAnimation(.snappy(duration: 0.25)) {
                            controller.listModel.filePaneOpen.toggle()
                        }
                    } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .accessibilityLabel(controller.listModel.filePaneOpen
                                        ? "Hide repository files" : "Show repository files")
                }
            }
        }
        // An agent opened a page (browser_navigate) — bring the Web pane forward.
        .onChange(of: browserBridge.showTick) { _, _ in
            if isRunning, !isSessionStage { withAnimation(.snappy(duration: 0.28)) { pane = .web } }
        }
    }

    private var availablePanes: [Pane] {
        isRunning ? Pane.allCases : [.dashboard]
    }

    /// Modern expandable-pill picker: every pane shows its icon; the selected
    /// one expands to also show its label with an accent fill. Fits four panes
    /// on a narrow phone without the flat stock segmented look.
    private var panePicker: some View {
        HStack(spacing: 8) {
            ForEach(availablePanes) { p in
                let selected = pane == p
                Button {
                    withAnimation(.snappy(duration: 0.28)) { pane = p }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: p.symbol).font(.system(size: 14, weight: .semibold))
                        if selected || hSize != .compact {
                            Text(p.rawValue).font(.subheadline.weight(.semibold))
                                .fixedSize().lineLimit(1)
                        }
                    }
                    .padding(.horizontal, selected ? 15 : 12)
                    .padding(.vertical, 9)
                    // Compact: the selected pill flexes so four pills fill a
                    // phone's width. Regular: every pill is labeled and hugs
                    // its content — a giant stretched capsule reads wrong.
                    .frame(maxWidth: selected && hSize == .compact ? .infinity : nil)
                    .background(
                        Capsule().fill(selected ? Color.accentColor
                                                : Color.secondary.opacity(0.14)))
                    .foregroundStyle(selected ? Color.white : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            if hSize != .compact { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// "What you're looking at may be out of date" — deliberately a strip
    /// rather than an overlay, so the stale content stays usable (a terminal
    /// already attached keeps its own connection) while it's clearly labelled.
    private var staleBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
            Text("Reconnecting — this view may be out of date")
                .font(.caption)
            Spacer()
            ProgressView().controlSize(.mini)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.15))
    }

    @ViewBuilder private var content: some View {
        ZStack {
            // The terminals pane stays mounted whichever tab is selected. Its
            // surfaces hold live exec streams, so tearing them down to glance at
            // the dashboard means paying a full re-attach on the way back — a
            // blank terminal that repaints late and has lost the keyboard. That
            // was the "switch to Info and back to grab the focus" workaround.
            if isRunning {
                HStack(spacing: 0) {
                    TerminalsPane(controller: controller, profileID: profileID,
                                  initialWindow: initialWindow,
                                  sessionTool: sessionTool,
                                  sessionCwd: sessionCwd,
                                  hidesTabStrip: terminalFullBleed || isSessionStage,
                                  isVisible: pane == .terminals)
                    // Regular width only: the repo file pane rides beside the
                    // terminal, macOS-style. It stays mounted at width 0 while
                    // closed so its repo-transition watcher can auto-open it.
                    if hSize == .regular {
                        FileExplorerPane(
                            model: fileExplorer,
                            listModel: controller.listModel,
                            // Never by itself on iOS: the pane takes a third
                            // of the screen, so only the toolbar button opens
                            // (or closes) it.
                            onAutoSetOpen: { _ in },
                            // A session's stage browses the session's folder.
                            pinnedContext: sessionCwd.map { (profileID, $0) })
                            .frame(width: controller.listModel.filePaneOpen ? 320 : 0)
                            .clipped()
                    }
                }
                .opacity(pane == .terminals ? 1 : 0)
                .allowsHitTesting(pane == .terminals)
            }
            switch pane {
            case .terminals: EmptyView()
            case .dashboard: dashboard
            case .web:       WebBrowserPane(controller: controller, profileID: profileID,
                                            bridge: browserBridge)
            case .docker:    docker
            case .files:     files
            }
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
    /// A session's stage (see WorkspaceScreen.sessionTool): the window is the
    /// session's agent, so it opens on the reader straight away and stays
    /// pinned to `initialWindow`.
    var sessionTool: String? = nil
    var sessionCwd: String? = nil
    #if os(visionOS)
    /// Pops a terminal tab out into its own pinnable window (VisionScenes).
    @Environment(\.openWindow) private var openWindow
    #endif
    /// Landscape: the tab chips go away with the pane picker so the surface
    /// gets the full height (WorkspaceScreen.terminalFullBleed).
    var hidesTabStrip = false
    /// False while another pane (Info / Docker / Files) is on top. The pane
    /// stays mounted either way — see WorkspaceScreen.content — so this is what
    /// keeps a hidden surface from holding the keyboard.
    var isVisible = true
    /// Cache of one live AttachSession per window. Held in a REFERENCE type, not
    /// a @State dictionary: `session(for:)` lazily creates entries during view
    /// body evaluation, and mutating @State there is undefined behaviour —
    /// SwiftUI didn't persist the writes, so every render minted fresh sessions
    /// that never stayed connected (typing hit a dead socket, fd -1). Mutating a
    /// class the @State merely *references* is safe and the entries persist.
    @State private var store = SessionCache()
    final class SessionCache { var map: [Int: AttachSession] = [:] }
    /// Last-loaded Claude transcript per window, kept across reader ↔ terminal
    /// toggles so re-opening the reader shows the conversation instantly instead
    /// of the slow "Loading transcript…" while it re-tails the guest jsonl.
    @State private var transcripts = TranscriptStore()
    @MainActor final class TranscriptStore {
        var items: [Int: [TranscriptItem]] = [:]
        var everLoaded: Set<Int> = []
        /// The incremental reader per window: a remount continues from
        /// what's held instead of re-reading the file.
        private var feeds: [Int: TranscriptFeed] = [:]
        func feed(_ window: Int) -> TranscriptFeed {
            if let f = feeds[window] { return f }
            let f = TranscriptFeed()
            feeds[window] = f
            return f
        }
    }
    /// Every window shown in this pane so far. Their surfaces stay mounted (and
    /// their streams attached) so switching back is instant instead of a fresh
    /// exec + tmux attach + repaint. Pruned when a window closes remotely.
    @State private var mounted: [Int] = []
    @State private var selectedWindow: Int?
    @State private var didSeedInitial = false
    /// Persisted terminal font size (points), driven by pinch-to-zoom and
    /// shared across every window and relaunch.
    @AppStorage("bromure.terminal.fontSizePt") private var fontSizePt: Double = 13
    /// The user's explicit terminal/reader choice for the current window, or
    /// nil to follow the window's agentic state (an agent window defaults to
    /// the rich reader). Cleared on a window switch so each tab re-evaluates.
    @State private var readerOverride: Bool?
    /// Windows for which a Claude transcript has been detected — gates the
    /// auto-reader default (see `readerMode`).
    @State private var transcriptPresent: Set<Int> = []
    /// Software-keyboard frame in screen coordinates, .zero when hidden. The
    /// terminal opts out of SwiftUI's automatic keyboard avoidance and insets
    /// itself by the measured overlap instead — see `keyboardOverlap`.
    @State private var keyboardFrame: CGRect = .zero
    /// Bumped whenever the layout flips (rotation), asking the live terminal to
    /// take first responder again — the keyboard is dismissed across the
    /// transition and nothing else asks for it back.
    @State private var focusTick = 0

    private var model: TabsModel? { controller.tabsModel(for: profileID) }
    private var tabs: [TabsModel.Tab] { model?.tabs ?? [] }

    /// Epoch floor for transcript/pending-question reads: this workspace's boot
    /// time. A guest reboot (`shutdown -r`) can leave a stale `pq-<cwd>.json`
    /// pending-question dump on the persistent home — Claude was killed mid
    /// question before its Stop hook swept it — and `planTranscriptCommand`
    /// otherwise appends it as a live question (a phantom the TUI isn't asking).
    /// Filtering by boot time drops anything written before this boot; 0 (no
    /// filter) until the boot time is known.
    private var transcriptSince: Int {
        controller.bootTimes[profileID].map { max(0, Int($0.timeIntervalSince1970)) } ?? 0
    }

    private var fontBinding: Binding<CGFloat> {
        Binding(get: { CGFloat(fontSizePt) }, set: { fontSizePt = Double($0) })
    }

    /// The guest working directory backing a window's Claude transcript.
    private func guestCwd(for window: Int) -> String? {
        let tab = tabs.first { $0.index == window }
        var cwd = tab?.cwd ?? tab?.repoRoot
        if cwd?.isEmpty ?? true, window == initialWindow, let s = sessionCwd, s != "~" { cwd = s }
        return (cwd?.isEmpty ?? true) ? nil : cwd
    }

    private var currentTab: TabsModel.Tab? {
        guard let win = effectiveWindow else { return nil }
        return tabs.first { $0.index == win }
    }

    /// "Agentic mode": this window is a coding agent — live (working / waiting
    /// on the user), a task worktree, or simply an agent tab sitting idle.
    /// Those default to the rich reader instead of raw ANSI.
    ///
    /// The label check is what carries an IDLE agent: its status is `.done` and
    /// it may not be a worktree, but the tab is named for the tool it runs —
    /// bare (`claude`) before the agent sets a session title, and
    /// `"Fix the branding (claude)"` after. The same resolution badges the
    /// desktop sidebar, so both clients agree on what counts as an agent.
    @MainActor private func isAgentic(_ tab: TabsModel.Tab?) -> Bool {
        guard let tab else { return false }
        if sessionTool != nil, tab.index == initialWindow { return true }
        if tab.agentStatus == .working || tab.agentStatus == .needsInput || tab.isWorktree {
            return true
        }
        return BromureIcons.agentKind(forLabel: tab.shownLabel) != nil
    }

    /// WHICH agent this tab runs ("claude" / "codex" / "grok" / "kimi" / …) —
    /// the reader's locator + parser hint. nil (plain shell, or a worktree
    /// whose label hasn't resolved yet) makes the locator search every
    /// store and the parser sniff the format, so the reader still works.
    @MainActor private func agentKind(_ tab: TabsModel.Tab?) -> String? {
        tab.flatMap { BromureIcons.agentKind(forLabel: $0.shownLabel) }
            ?? (tab?.index == initialWindow ? sessionTool : nil)
    }

    /// Non-agent tabs are always the raw terminal (and get no toggle). An agent
    /// tab defaults to the reader ONLY once a transcript actually exists — a
    /// freshly-typed `claude` sitting on its "Claude can make mistakes…" splash
    /// has no transcript yet, and auto-opening the reader there just showed "No
    /// transcript". So detect the transcript first (a background presence poll),
    /// then flip. The toggle still overrides either way.
    @MainActor private var readerMode: Bool {
        guard isAgentic(currentTab) else { return false }
        if let readerOverride { return readerOverride }
        // A session's stage opens on the reader, like the desktop's.
        if sessionTool != nil, effectiveWindow == initialWindow { return true }
        return effectiveWindow.map { transcriptPresent.contains($0) } ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            // Shown for a single tab too: the strip is how you see what the
            // workspace has open, and it's where "Send to Grid" / Close live.
            if !tabs.isEmpty && !hidesTabStrip {
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
                ZStack {
                    // One live surface per visited window, only the current one
                    // shown. Switching tabs is then a visibility change, not a
                    // teardown: the stream stays up and the scrollback is
                    // already painted when you come back.
                    //
                    // The terminal opts out of SwiftUI's automatic avoidance and
                    // insets by the measured overlap instead (default avoidance
                    // left the last rows under the keyboard in landscape). Note the
                    // .ignoresSafeArea(.keyboard) is on the ZStack OUTSIDE the
                    // GeometryReader, so geo.frame stays anchored to the screen
                    // bottom. The reader (sibling below) uses the same pattern with
                    // its own ignoresSafeArea wrapper.
                    ZStack {
                        ForEach(mounted, id: \.self) { w in
                            let active = w == win && !readerMode && isVisible
                            GeometryReader { geo in
                                TerminalSurface(session: session(for: w),
                                                fontSize: fontBinding,
                                                focusTick: focusTick,
                                                isActive: active,
                                                bottomInset: keyboardOverlap(with: geo.frame(in: .global)))
                            }
                            .background(Color.black)
                            .opacity(active ? 1 : 0)
                            .allowsHitTesting(active)
                        }
                    }
                    .ignoresSafeArea(.keyboard, edges: .bottom)

                    if readerMode {
                        // The composer is inset by the MEASURED keyboard overlap
                        // (incl. the QuickType predictive bar) — same as the
                        // terminal — so its send/attach row never hides behind it.
                        // .ignoresSafeArea(.keyboard) MUST wrap the GeometryReader
                        // (not just the inner VStack): on iOS 26 a GeometryReader
                        // outside it is itself avoided to the keyboard top, so
                        // geo.frame.maxY collapses to the keyboard's minY and the
                        // measured overlap goes to 0 (composer ends up behind the
                        // keyboard). Wrapping here keeps geo at the screen bottom.
                        GeometryReader { geo in
                            TranscriptReaderView(controller: controller, profileID: profileID,
                                                 window: win, guestCwd: guestCwd(for: win),
                                                 agent: agentKind(currentTab),
                                                 since: transcriptSince, store: transcripts,
                                                 bottomInset: keyboardOverlap(with: geo.frame(in: .global)))
                        }
                        .id("reader-\(profileID)-\(win)-\(agentKind(currentTab) ?? "?")")
                        .ignoresSafeArea(.keyboard, edges: .bottom)
                    }
                }
            } else {
                ContentUnavailableView("No terminal", systemImage: "terminal",
                    description: Text("This workspace has no open windows yet."))
            }
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            keyboardFrame = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey]
                             as? NSValue)?.cgRectValue ?? .zero
        }
        .onReceive(NotificationCenter.default.publisher(
            for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardFrame = .zero
        }
        // A terminal's link dropped or came back — almost always a guest reboot,
        // which rebuilds tmux with a different window set. Force the mirror to
        // re-poll NOW: the fresh roster drives syncMounted, which prunes surfaces
        // for windows that no longer exist and re-homes the view onto a live one
        // (a surface left attached to a dead window index just eats keystrokes).
        // Then re-grab keyboard focus for whatever surface ends up active.
        .onReceive(NotificationCenter.default.publisher(for: .bromureTerminalLinkChanged)) { note in
            guard (note.userInfo?["host"] as? UUID) == controller.host.id else { return }
            controller.foregroundKick()
            focusTick += 1
        }
        // Anything that changes WHICH surface should own the keyboard asks the
        // newly-active one to take it: a rotation (which dismisses the keyboard
        // and drops first responder), a tab switch, leaving the reader, and
        // coming back from another pane. Without this the terminal is on screen
        // but dead until tapped — the focus complaint.
        .onChange(of: hidesTabStrip) { _, _ in focusTick += 1 }
        .onChange(of: readerMode) { _, _ in focusTick += 1 }
        .onChange(of: isVisible) { _, visible in if visible { focusTick += 1 } }
        .onChange(of: effectiveWindow) { _, _ in
            syncMounted()
            readerOverride = nil   // each window re-evaluates the reader default
            focusTick += 1
        }
        // Prune surfaces for windows that closed remotely.
        .onChange(of: tabs.map(\.index)) { _, _ in syncMounted() }
        .onAppear { syncMounted() }
        .toolbar {
            #if os(visionOS)
            // Pop the current terminal out into its own pinnable window. The
            // tab chips' long-press menu has the same command, but press-and-
            // hold is clumsy with eye tracking — this is the one-look,
            // one-pinch path. (Same constant-slot rule as below: render
            // nothing rather than dropping the item.)
            ToolbarItem(placement: .primaryAction) {
                if let win = effectiveWindow {
                    Button {
                        openWindow(id: "terminal", value: TerminalWindowValue(
                            hostID: controller.host.id,
                            profileID: profileID,
                            windowIndex: win,
                            workspaceName: controller.profile(for: profileID)?.name ?? "?",
                            windowLabel: currentTab?.shownLabel ?? "",
                            accentHex: controller.profile(for: profileID)?.color.hexInUI ?? "#888888"))
                    } label: {
                        Image(systemName: "rectangle.badge.plus")
                    }
                    .help("Open this terminal as its own window")
                    .accessibilityLabel("Open this terminal as its own window")
                }
            }
            #endif
            // Keep the toolbar-item COUNT constant. Conditionally adding/removing
            // a ToolbarItem (as this did for the reader toggle) leaves a ghost
            // glass circle behind on iOS 26 — the stray button the user saw. So
            // the toggle is always the same slot, rendering nothing on a
            // non-agent tab where a reader makes no sense.
            ToolbarItem(placement: .primaryAction) {
                if isAgentic(currentTab) {
                    Button { readerOverride = !readerMode } label: {
                        Image(systemName: readerMode ? "terminal" : "doc.richtext")
                    }
                    .accessibilityLabel(readerMode ? "Show raw terminal" : "Show reader")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                if sessionTool == nil {
                Button {
                    controller.newTab(profileID)
                    // Drop the pinned window so the pane follows the roster's
                    // active tab — which the guest has just made the new one.
                    // Without this the new terminal is created but never shown
                    // (the pin survives from the last chip tapped), which reads
                    // as "the + button does nothing".
                    selectedWindow = nil
                    readerOverride = nil
                } label: {
                    Image(systemName: "plus.rectangle.on.rectangle")
                }
                .accessibilityLabel("New terminal")
                }
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
        // Watch the current agent window for a transcript; once one exists, the
        // reader default flips on (issue #8). Runs while the terminal is shown
        // and stops the moment it finds one — the reader then polls itself.
        .task(id: presencePollKey) { await pollTranscriptPresence() }
    }

    private var presencePollKey: String {
        let win = effectiveWindow ?? -1
        // The agent kind re-keys the poll: a label that resolves after the
        // fact ("claude" → "Fix the tests (codex)") must rebuild the store
        // locator, or the poll keeps watching the wrong session store.
        return "\(win)-\(isAgentic(currentTab))-\(agentKind(currentTab) ?? "?")-"
            + "\(effectiveWindow.flatMap { guestCwd(for: $0) } ?? "")"
    }

    private func pollTranscriptPresence() async {
        let agent = agentKind(currentTab)
        guard let win = effectiveWindow, isAgentic(currentTab),
              !transcriptPresent.contains(win),
              let cwd = guestCwd(for: win), !cwd.isEmpty,
              let cmd = CodingTaskEngine.planTranscriptCommand(guestCwd: cwd, since: transcriptSince,
                                                               agent: agent)
        else { return }
        while !Task.isCancelled {
            if let raw = try? await controller.guestExec(profileID, command: cmd, timeout: 15) {
                let parsed = AgentTranscript.parse(Data(raw.utf8), agent: agent)
                if !parsed.isEmpty {
                    transcripts.items[win] = parsed          // seed the reader's cache
                    transcripts.everLoaded.insert(win)
                    transcriptPresent.insert(win)            // → reader default flips on
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private var effectiveWindow: Int? {
        // A session's stage shows its own window only — never another
        // session's that happens to be the machine's active tab.
        if sessionTool != nil, let initialWindow {
            return tabs.contains(where: { $0.index == initialWindow }) ? initialWindow : nil
        }
        if let selectedWindow, tabs.contains(where: { $0.index == selectedWindow }) {
            return selectedWindow
        }
        return model?.activeTab?.index ?? tabs.first?.index
    }

    /// Keep `mounted` in step with the roster: add the window being shown, drop
    /// any that closed remotely (and tear down their sessions — nothing else
    /// will, now that the surfaces outlive a tab switch).
    private func syncMounted() {
        let live = Set(tabs.map(\.index))
        // Prune only against a POPULATED roster. A poll blip that momentarily
        // reports zero/partial tabs must not stop a live session — that killed
        // the active terminal's stream, and typing then dropped (fd -1).
        if !live.isEmpty {
            for w in mounted where !live.contains(w) {
                store.map[w]?.stop()
                store.map[w] = nil
                // Drop this index's reader/transcript caches too. tmux indices are
                // reused (closing the last tab frees the highest index, which the
                // next new-window takes), and these caches are index-keyed — a
                // reused index must not inherit the previous occupant's rich-mode
                // transcript or auto-reader state.
                transcripts.items[w] = nil
                transcripts.everLoaded.remove(w)
                transcriptPresent.remove(w)
            }
            mounted.removeAll { !live.contains($0) }
            // Re-arm any surface that ended on a CLEAN exit but whose window is
            // back in the roster — a guest reboot rebuilt tmux on the same index,
            // so the parked session must reconnect instead of sitting dead. A
            // ctrl-D that truly closed the window leaves it OUT of `live`, so it
            // was pruned above and is never revived (no resurrection).
            for w in mounted where live.contains(w) {
                store.map[w]?.reviveIfExited()
            }
        }
        if let win = effectiveWindow, !mounted.contains(win) { mounted.append(win) }
    }

    /// How much of `container` (screen coordinates) the keyboard covers. Zero
    /// when it's hidden, off-screen, or below the surface entirely — an
    /// undocked/floating iPad keyboard therefore costs the terminal nothing.
    private func keyboardOverlap(with container: CGRect) -> CGFloat {
        guard keyboardFrame.height > 0 else { return 0 }
        // How much the keyboard covers the container's bottom. This ONLY works if
        // `container` (geo.frame(in:.global)) reaches the real screen bottom — i.e.
        // the GeometryReader must sit INSIDE .ignoresSafeArea(.keyboard). On iOS 26,
        // a GeometryReader that is NOT inside ignoresSafeArea is itself avoided up
        // to the keyboard top, so container.maxY == kbd.minY and this collapses to
        // 0. Both call sites wrap their GeometryReader in .ignoresSafeArea(.keyboard)
        // so container.maxY is the screen bottom and this is the keyboard height.
        return max(0, container.maxY - keyboardFrame.minY)
    }

    private func session(for window: Int) -> AttachSession {
        if let s = store.map[window] { return s }
        let s = AttachSession(host: controller.host, vmID: profileID.uuidString, windowIndex: window)
        // ctrl-D / clean shell exit → drop this tab at once (the guest already
        // closed the window), instead of waiting for the roster poll.
        s.onCleanExit = { [weak controller, profileID] in
            controller?.dropTabLocally(profileID, index: window)
        }
        store.map[window] = s   // mutates the class, not @State — safe in body
        return s
    }

    @ViewBuilder private func tabChip(_ tab: TabsModel.Tab) -> some View {
        let selected = tab.index == effectiveWindow
        Button {
            selectedWindow = tab.index
            controller.selectTab(profileID, index: tab.index)
        } label: {
            HStack(spacing: 6) {
                AgentStatusDot(status: tab.agentStatus)
                Text(tab.shownLabel.isEmpty ? "shell" : tab.shownLabel)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(selected ? Color.accentColor.opacity(0.16)
                                        : Color.secondary.opacity(0.10)))
            .overlay(
                Capsule().strokeBorder(selected ? Color.accentColor.opacity(0.5) : .clear,
                                       lineWidth: 1))
            .foregroundStyle(selected ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.plain)
        .contextMenu {
            #if os(visionOS)
            // The spatial superpower: this terminal as its own window, pinned
            // wherever the user puts it.
            Button {
                openWindow(id: "terminal", value: TerminalWindowValue(
                    hostID: controller.host.id,
                    profileID: profileID,
                    windowIndex: tab.index,
                    workspaceName: controller.profile(for: profileID)?.name ?? "?",
                    windowLabel: tab.shownLabel,
                    accentHex: controller.profile(for: profileID)?.color.hexInUI ?? "#888888"))
            } label: { Label("Open as Window", systemImage: "rectangle.badge.plus") }
            #endif
            Button {
                _ = controller.gridStore.add(profileID: profileID, windowIndex: tab.index,
                                             label: tab.shownLabel)
                controller.pushGridLayout()
            } label: { Label("Send to Grid", systemImage: "square.grid.2x2") }
            Button(role: .destructive) {
                let closing = tab.index
                // Re-home to a live sibling BEFORE tearing the session down. If
                // the closed tab is the one on screen, stopping its session flips
                // connected=false while everConnected is still true, so its still-
                // active surface would show the "Reconnecting…" veil until the next
                // poll drops the tab (~1 poll). Re-homing now makes that surface
                // inactive+unmounted, so a live sibling shows at once — no veil.
                if effectiveWindow == closing,
                   let pos = tabs.firstIndex(where: { $0.index == closing }) {
                    selectedWindow = (tabs[(pos + 1)...].first ?? tabs[..<pos].last)?.index
                }
                mounted.removeAll { $0 == closing }
                controller.closeTab(profileID, index: closing)
                store.map[closing]?.stop()
                store.map[closing] = nil
            } label: { Label("Close", systemImage: "xmark") }
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
    /// Canonical agent kind of the tool this tab runs — locator + parser
    /// hint; nil searches every session store and sniffs the format.
    let agent: String?
    /// Epoch floor (this workspace's boot time) so a pre-reboot pending-question
    /// dump or an older session's transcript isn't tailed as if it were live —
    /// see TerminalsPane.transcriptSince.
    let since: Int
    /// Shared across reader remounts so a toggle doesn't re-tail from scratch.
    let store: TerminalsPane.TranscriptStore
    /// Measured keyboard overlap (TerminalsPane.keyboardOverlap) the composer is
    /// inset by. SwiftUI's automatic avoidance lifts by the keyboard height MINUS
    /// its QuickType predictive bar, which left the send/attach row tucked behind
    /// the keyboard; the measured frame includes the predictive bar. Same
    /// mechanism the terminal surface uses.
    let bottomInset: CGFloat
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
    /// How much of the held conversation is laid out (TranscriptWindow).
    @State private var renderLimit = TranscriptWindow.step
    @State private var renderChars = TranscriptWindow.charStep
    @State private var loadingEarlier = false
    @FocusState private var composing: Bool

    var body: some View {
        // Transcript fills; the composer is pinned beneath it and the WHOLE stack
        // is inset up by the measured keyboard overlap. We opt out of SwiftUI's
        // automatic keyboard avoidance (which omitted the QuickType predictive
        // bar, leaving the send/attach row behind it) and inset explicitly —
        // exactly how the terminal surface handles the keyboard. The matching
        // .ignoresSafeArea(.keyboard) lives on the GeometryReader at the call site
        // (it must wrap the geo, or on iOS 26 the measured overlap collapses to 0).
        VStack(spacing: 0) {
            transcript
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            composerBar
        }
        .padding(.bottom, bottomInset)
        .onAppear {
            // Show the cached conversation instantly; the poll refreshes it.
            if items.isEmpty { items = store.items[window] ?? [] }
            if store.everLoaded.contains(window) { loaded = true }
        }
        // Re-key on `since` as well as the cwd: a reboot bumps the boot-time
        // floor, and the poll must rebuild its command to stop tailing the
        // pre-reboot pending-question dump (poll() captures `since` once).
        // The agent kind re-keys it too — the call site remounts on a kind
        // change anyway (its .id carries the kind), so this is belt and
        // braces for a future caller that doesn't.
        .task(id: "\(guestCwd ?? "")\u{1f}\(since)\u{1f}\(agent ?? "?")") { await poll() }
    }

    // MARK: Composer + image attach

    private var composerBar: some View {
        VStack(spacing: 4) {
            Divider()   // safeAreaInset composer — separate it from the transcript
            if let uploadError {
                Text(uploadError).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }
            // Type into the agent's session — the message (and any uploaded
            // image path) shows up in the transcript on the next poll, and the
            // agent responds inline. Full-width field; attach + send ride a
            // slim bar beneath it so the text area is as large as possible.
            VStack(alignment: .leading, spacing: 8) {
                TextField("Message the agent…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .lineLimit(1...8)
                    .frame(minHeight: 24)
                    .focused($composing)
                HStack(spacing: 18) {
                    if composing {
                        // Put the keyboard away (Return makes a new line).
                        Button { composing = false } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Hide Keyboard")
                    }
                    Spacer()
                    attachButton
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(sendable ? Color.accentColor
                                                       : Color.secondary.opacity(0.4))
                    }
                    .disabled(!sendable)
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.platformTextBackground))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.primary.opacity(0.12)))
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
                    Image(systemName: "paperclip")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 30, height: 30)
        }
        .disabled(uploading)
        .accessibilityLabel("Attach image")
    }

    @ViewBuilder private var transcript: some View {
        if guestCwd?.isEmpty ?? true {
            unavailable("Not a project folder",
                        "This terminal isn't running in a folder with an agent session.")
        } else if !loaded {
            ProgressView("Loading transcript…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            unavailable("No transcript",
                        "No agent session was found for this terminal yet — send a message to get started.")
        } else {
            let all = answeredItems
            let shown = TranscriptWindow.visible(all, limit: renderLimit, chars: renderChars)
            TailFollowingScroll(
                changeKey: items.count,
                earlier: TranscriptWindow.earlier(
                    all: all, shown: shown, feed: store.feed(window), loading: loadingEarlier,
                    widen: { renderLimit += TranscriptWindow.step; renderChars += TranscriptWindow.charStep },
                    load: { await loadEarlier() })
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    TranscriptRowsView(items: shown, working: working && openQuestions.isEmpty)
                        // A picture the agent shows (display MCP) is read off its machine.
                        .environment(\.displayFileReader, DisplayFileReader.chunked { op in
                            try? await controller.guestFileOp(profileID, op: op)
                        })
                    // The question the agent is asking RIGHT NOW gets the
                    // interactive card — pick the options here and Submit
                    // sends the picker's key sequence into the session, the
                    // same path the desktop plan window uses. Without it the
                    // phone could see a multiple-choice question but had no
                    // way to answer one.
                    if !openQuestions.isEmpty {
                        TranscriptQuestionBatchCard(
                            questions: openQuestions,
                            onSubmit: { keys in
                                let ok = await submitAnswerKeys(keys)
                                if ok { await refreshNow() }   // clear the card promptly
                                return ok
                            })
                            // Keyed by the question TEXTS: consecutive
                            // rounds land at the same item indices (both
                            // live only in the pq dump), and an index-based
                            // id would keep the previous round's picks.
                            .id(openQuestions.map(\.question).joined(separator: "\u{1f}"))
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Opens on the newest turn and follows the live tail -- through
            // the keyboard's resize too -- until you scroll up to read.
            .background(Color.platformWindowBackground)
        }
    }

    @ViewBuilder private func unavailable(_ title: String, _ detail: String) -> some View {
        ContentUnavailableView(title, systemImage: "doc.richtext", description: Text(detail))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Live question batch
    //
    // A pending AskUserQuestion only exists in the guest's `pq-<cwd>.json` dump
    // (Claude Code writes the assistant turn to the transcript only once the
    // turn completes), and the tail appends it LAST. So the trailing run of
    // question items is the batch still being asked; anything before it was
    // already answered and stays a static card. Same rule the desktop plan
    // window uses.

    private var openQuestionItems: [TranscriptItem] {
        var batch: [TranscriptItem] = []
        for item in items.reversed() {
            if case .question = item.kind { batch.append(item) } else { break }
        }
        return batch.reversed()
    }

    private var openQuestions: [TranscriptQuestion] {
        openQuestionItems.compactMap {
            if case .question(let q) = $0.kind { q } else { nil }
        }
    }

    /// Everything except the batch being asked right now.
    private var answeredItems: [TranscriptItem] {
        let openIDs = Set(openQuestionItems.map(\.id))
        return items.filter { !openIDs.contains($0.id) }
    }

    /// Type the picker's key sequence into this window's agent. The picker must
    /// be ON SCREEN first: keys sent early land in the chat input and cancel the
    /// tool call ("user declined"), so wait for it exactly as the desktop does.
    private func submitAnswerKeys(_ keys: [String]) async -> Bool {
        guard !keys.isEmpty else { return false }
        let probe = CodingTaskEngine.pickerVisibleCommand(tabIndex: window)
        var visible = false
        for _ in 0..<15 {
            if (try? await controller.guestExec(profileID, command: probe, timeout: 8)) != nil {
                visible = true
                break
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        guard visible else { return false }
        return (try? await controller.guestExec(
            profileID,
            command: CodingTaskEngine.answerKeysCommand(tabIndex: window, keys: keys),
            timeout: 60)) != nil
    }

    private var sendable: Bool {
        !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        Task {
            // Guarded: nothing is typed unless the agent holds the tab (a
            // bare shell would run it) — the draft stays then.
            // Held too: a menu or approval dialog is up in the tab, and a
            // digit or Return would answer it — the draft stays, as it does
            // when typing didn't go through.
            var execError: String?
            let out = await PaneTypeGuard.runType(target: .index(window), text: text) {
                do { return try await controller.guestExec(profileID, command: $0, timeout: 20) }
                catch { execError = "\(error)"; return nil }
            }
            // Every outcome says what happened: the draft used to stay put
            // with no word for anything but a dialog, which read as "Send
            // does nothing" (a refusal, a timeout, an Enter the agent
            // didn't take).
            let outcome = ComposerOutcome.of(out)
            FatClientLog.log("composer win=\(window): \(outcome) chars=\(text.count)"
                + (execError.map { " execError=\($0)" } ?? "")
                + " out=\(String((out ?? "").suffix(160)).replacingOccurrences(of: "\n", with: "⏎"))")
            await MainActor.run {
                // Typed — or typed into the agent's box, where it now sits.
                if outcome == .typed || outcome == .unconfirmed { draft = "" }
                uploadError = outcome.message
                sending = false
            }
            await refreshNow()   // reflect the sent message immediately
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

    /// The guest command for one read of this tab's transcript.
    private var chunkCommand: TranscriptFeed.Command? {
        guard let cwd = guestCwd, !cwd.isEmpty else { return nil }
        let since = since, agent = agent
        return { known, offset, bytes, earlier in
            CodingTaskEngine.transcriptChunkCommand(guestCwd: cwd, since: since, agent: agent,
                                                    knownPath: known, knownOffset: offset,
                                                    bytes: bytes, earlier: earlier)
        }
    }

    private func exec(_ cmd: String) async -> String? {
        try? await controller.guestExec(profileID, command: cmd, timeout: 20)
    }

    private func poll() async {
        FatClientLog.log("reader win=\(window) poll start cwd=\(guestCwd ?? "nil") "
            + "agent=\(agent ?? "?")")
        guard let cmd = chunkCommand else {
            FatClientLog.log("reader win=\(window) no cwd/cmd → loaded")
            loaded = true; store.everLoaded.insert(window); return
        }
        let feed = store.feed(window)
        var first = true
        while !Task.isCancelled {
            let read = await feed.refresh(agent: agent, command: cmd, exec: exec)
            if first {
                FatClientLog.log("reader win=\(window) read \(read == nil ? "FAILED/timeout" : "OK \(read!.count) items")")
            }
            if let read, read != items {
                items = read
                store.items[window] = read          // survive a reader remount
            }
            loaded = true
            store.everLoaded.insert(window)
            first = false
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    /// One immediate transcript refresh — used right after sending a message or
    /// answering a question so the reader reflects it without waiting out the
    /// 2 s poll.
    private func refreshNow() async {
        guard let cmd = chunkCommand,
              let read = await store.feed(window).refresh(agent: agent, command: cmd, exec: exec)
        else { return }
        if read != items { items = read; store.items[window] = read }
    }

    /// Earlier conversation from the file, put in front.
    private func loadEarlier() async {
        guard let cmd = chunkCommand, !loadingEarlier else { return }
        loadingEarlier = true
        defer { loadingEarlier = false }
        let feed = store.feed(window)
        if await feed.loadEarlier(agent: agent, command: cmd, exec: exec) {
            items = feed.items
            store.items[window] = feed.items
        }
    }

    /// The agent is at work in this tab: its current step (or "Thinking…")
    /// shows live, as on the desktop.
    private var working: Bool {
        guard let s = controller.sessionStore.sessions.first(where: {
            $0.profileID == profileID && $0.windowIndex == window && !$0.hasEnded
        }) else { return false }
        return SessionHome.bucket(for: s, in: controller.listModel) == .working
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

/// The machine's name as the navigation title — only on the machine's own
/// screen: on a session's stage the session screen owns the title.
private struct MachineTitle: ViewModifier {
    let title: String
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        } else {
            content
        }
    }
}

// MARK: - A session's files

/// The repo file pane for one session -- its machine and folder -- with its
/// own explorer model. Beside the conversation on a regular width, in a
/// sheet on the phone (`SessionFilesButton`).
struct SessionFilesPane: View {
    let controller: RemoteHostController
    let profileID: Profile.ID
    let cwd: String
    @State private var model = FileExplorerModel()

    var body: some View {
        FileExplorerPane(model: model, listModel: controller.listModel,
                         onAutoSetOpen: { _ in },
                         pinnedContext: (profileID, cwd))
            .onAppear { [controller] in
                model.execProvider = { [weak controller] id, command, timeout in
                    guard let controller else { throw ACAppDelegate.GuestExecError.vmNotRunning }
                    return try await controller.guestExec(id, command: command, timeout: timeout)
                }
            }
    }
}

/// The phone's way to a session's files: a toolbar button and its sheet.
struct SessionFilesButton: View {
    let controller: RemoteHostController
    let profileID: Profile.ID
    let cwd: String
    @State private var shown = false

    var body: some View {
        Button { shown = true } label: { Image(systemName: "folder") }
            .accessibilityLabel("Files")
            .sheet(isPresented: $shown) {
                NavigationStack {
                    SessionFilesPane(controller: controller, profileID: profileID, cwd: cwd)
                        .navigationTitle("Files")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { shown = false } }
                        }
                }
                .presentationDetents([.medium, .large])
            }
    }
}

// MARK: - What a composer send did

/// A guarded type's verdict (`PaneTypeGuard.runType`), as the composer
/// reports it. Only `typed` is sent; `unconfirmed` sits in the agent's
/// input box. Same reading as the desktop chat's (`ChatQueueStore.Outcome`).
enum ComposerOutcome: Equatable, CustomStringConvertible {
    case typed, unconfirmed, held, dropped, unreachable, failed
    case refused(PaneRefusal)

    static func of(_ out: String?) -> ComposerOutcome {
        guard let out else { return .unreachable }
        if let r = PaneTypeGuard.refusal(in: out) { return .refused(r) }
        if PaneTypeGuard.held(in: out) { return .held }
        if PaneTypeGuard.typed(in: out) { return .typed }
        if PaneTypeGuard.dropped(in: out) { return .dropped }
        return PaneTypeGuard.unconfirmed(in: out) ? .unconfirmed : .failed
    }

    var description: String {
        switch self {
        case .typed: "typed"
        case .unconfirmed: "unconfirmed"
        case .held: "held"
        case .dropped: "dropped"
        case .unreachable: "unreachable"
        case .failed: "failed"
        case .refused(let r): "refused(\(r.rawValue))"
        }
    }

    /// The line under the composer; nil when it went through.
    var message: String? {
        switch self {
        case .typed:
            return nil
        case .unconfirmed:
            return NSLocalizedString("Not delivered — it's in the agent's input box but its Return didn't take. Show the terminal and press Return there.",
                                     comment: "iOS composer: typed, but the agent never took the Enter")
        case .held:
            return NSLocalizedString("Not sent — the agent is asking you something. Answer it first, then send again.",
                                     comment: "iOS composer: held while the agent shows a dialog")
        case .dropped:
            return NSLocalizedString("Not delivered — the agent didn't take it. Send it again.",
                                     comment: "iOS composer: the agent dropped the text")
        case .unreachable:
            return NSLocalizedString("Couldn't reach the machine — check the session before sending again.",
                                     comment: "iOS composer: the exec failed or timed out")
        case .failed:
            return NSLocalizedString("Not sent — typing it into the session failed. Send it again.",
                                     comment: "iOS composer: the typing command failed")
        case .refused(.shell):
            return NSLocalizedString("Not sent — the agent isn't in front in its terminal right now (it may have exited, or be running a command). Try again in a moment.",
                                     comment: "iOS composer: no agent holds the tab")
        case .refused:
            return NSLocalizedString("Not sent — this session's terminal window is gone or changed.",
                                     comment: "iOS composer: the window is gone or someone else's")
        }
    }
}

// MARK: - A transcript that follows its tail

/// The "earlier" control at a transcript's top: widen the rows on show,
/// or fetch the conversation before what's held.
struct TailEarlier {
    let label: String
    let loading: Bool
    /// The first row on show: kept where it is once rows land above it.
    let anchor: Int?
    let action: @MainActor () async -> Void
}

/// A chat's scroll view that stays on the latest message -- the iOS twin of
/// the desktop's `TailFollow` (BeautifiedSessionView). The rows are EAGER
/// (the desktop's fix: a lazy stack left the view blank once a row -- a
/// long answer -- outgrew the viewport, and its estimated heights sent
/// the tail past the end), so callers bound what they hand it with
/// `TranscriptWindow`. Once at the tail it keeps following through layout
/// drift until the user drags it away; scrolling back down to the end
/// picks the tail up again. New turns only pull the view down while it
/// follows, never while you read above.
struct TailFollowingScroll<Content: View>: View {
    /// Changes when rows arrive (the item count).
    let changeKey: Int
    var earlier: TailEarlier? = nil
    @ViewBuilder let content: () -> Content

    /// A reference: flipping it must not re-render the transcript.
    private final class Follow {
        var sticky = true
        var lastUserScroll = Date.distantPast
        var tailY: CGFloat?
        /// A snap budget: layout drift can report many times a second, and
        /// each snap is a layout pass -- the watchdog catches what's skipped.
        var lastSnap = Date.distantPast
        var userRecent: Bool { Date().timeIntervalSince(lastUserScroll) < 0.6 }
    }
    @State private var follow = Follow()
    @State private var viewport: CGFloat = 0
    private static var space: String { "tail-follow-scroll" }
    private static var tailID: String { "tail-follow-end" }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    if let earlier { earlierButton(earlier, proxy) }
                    content()
                    Color.clear.frame(height: 1).id(Self.tailID)
                        .onGeometryChange(for: CGFloat.self, of: { $0.frame(in: .named(Self.space)).minY }) { y in
                            tailMoved(y, proxy)
                        }
                }
                // A short chat sits at the bottom by FILLING the viewport, not
                // by the scroll anchor (which draws it low but hit-tests it
                // top-aligned -- the desktop's dead-buttons bug).
                .frame(maxWidth: .infinity, minHeight: max(0, viewport), alignment: .bottom)
            }
            .coordinateSpace(name: Self.space)
            // The opening offset only: anchoring every size change to the
            // bottom fought the follower (and a reader above).
            .modifier(InitialBottomAnchor())
            // A drag on the conversation puts the keyboard away -- and with
            // it back come the bars that step aside while typing.
            .scrollDismissesKeyboard(.interactively)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { h in
                viewport = h
                if let y = follow.tailY { tailMoved(y, proxy) }   // the keyboard, a rotation
            }
            // The user's own drag decides: toward older turns lets go.
            .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { v in
                follow.lastUserScroll = Date()
                if v.translation.height > 2 { follow.sticky = false }
            })
            .onAppear { snap(proxy) }
            .onChange(of: changeKey) { _, _ in if follow.sticky { snap(proxy) } }
            // The watchdog: a layout pass that reported nothing new still
            // gets corrected (the desktop's "stuck blank" fix).
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if follow.sticky, !follow.userRecent, !atBottom(follow.tailY) { snap(proxy) }
                }
            }
        }
    }

    private func earlierButton(_ e: TailEarlier, _ proxy: ScrollViewProxy) -> some View {
        Button {
            follow.sticky = false
            follow.lastUserScroll = Date()
            Task { @MainActor in
                await e.action()
                // Keep the reading position: the first row stays put.
                if let a = e.anchor { DispatchQueue.main.async { proxy.scrollTo(a, anchor: .top) } }
            }
        } label: {
            HStack(spacing: 6) {
                if e.loading { ProgressView().controlSize(.small) }
                Label(e.label, systemImage: "arrow.up.circle")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .disabled(e.loading)
    }

    /// The end marker sits at the bottom edge (within the content's padding).
    private func atBottom(_ y: CGFloat?) -> Bool {
        guard let y, viewport > 0 else { return false }
        return y <= viewport + 2 && y >= viewport - 40
    }

    private func tailMoved(_ y: CGFloat, _ proxy: ScrollViewProxy) {
        follow.tailY = y
        guard viewport > 0 else { return }
        if follow.sticky {
            // Not the user: the end moved because rows were measured.
            if !follow.userRecent, !atBottom(y) { snap(proxy) }
        } else if y <= viewport + 2, !follow.userRecent {
            // Scrolled (or flung) back down to the end: follow again.
            follow.sticky = true
        }
    }

    private func snap(_ proxy: ScrollViewProxy) {
        guard Date().timeIntervalSince(follow.lastSnap) > 0.15 else { return }
        follow.lastSnap = Date()
        DispatchQueue.main.async { proxy.scrollTo(Self.tailID, anchor: .bottom) }
    }
}

/// Opens at the bottom; on iOS 18+ only the opening offset is anchored.
private struct InitialBottomAnchor: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, visionOS 2.0, *) {
            content.defaultScrollAnchor(.bottom, for: .initialOffset)
        } else {
            content.defaultScrollAnchor(.bottom)
        }
    }
}

// MARK: - What a transcript lays out

/// The newest rows, bounded by count and by text -- the desktop's render
/// window (`BeautifiedSessionView.renderWindow`): eager rows stay cheap
/// because only a few screens of text are laid out; "Show earlier
/// messages" widens it.
enum TranscriptWindow {
    static let step = 200
    static let charStep = 30_000

    static func visible(_ items: [TranscriptItem], limit: Int, chars: Int) -> [TranscriptItem] {
        var n = 0, total = 0
        for item in items.reversed() {
            if n >= limit || (n >= 2 && total >= chars) { break }
            n += 1
            total += min(item.approximateLength, 6_000)
        }
        return Array(items.suffix(n))
    }

    /// The control above the rows: more of what's held, else earlier
    /// conversation from the file; nil when it's all on show.
    @MainActor
    static func earlier(all: [TranscriptItem], shown: [TranscriptItem], feed: TranscriptFeed,
                        loading: Bool, widen: @escaping @MainActor () -> Void,
                        load: @escaping @MainActor () async -> Void) -> TailEarlier? {
        let hidden = all.count - shown.count
        guard hidden > 0 || feed.canLoadEarlier else { return nil }
        let label = loading
            ? NSLocalizedString("Loading earlier conversation…", comment: "beautified history")
            : hidden > 0
            ? NSLocalizedString("Show earlier messages", comment: "beautified history")
            : NSLocalizedString("Load earlier conversation", comment: "beautified history")
        return TailEarlier(label: label, loading: loading, anchor: shown.first?.id) {
            if hidden > 0 { widen() } else { await load(); widen() }
        }
    }
}

// MARK: - A transcript read incrementally

/// One transcript file read the way the desktop's chat reads it
/// (`CodingTaskEngine.transcriptChunkCommand`): a first window from the
/// end, then only the bytes appended since, and earlier history on
/// demand. The old reader re-tailed the last 300 KB every poll -- which
/// tool output fills, so a phone showed only the last few messages and
/// had no way to reach the rest.
@MainActor
final class TranscriptFeed {
    static let windowBytes = 1_000_000

    private var path: String?
    private var data = Data()
    private var base = 0
    private var end = 0
    private var pq = Data()
    private var generation = 0
    private(set) var items: [TranscriptItem] = []
    var canLoadEarlier: Bool { path != nil && base > 0 }

    /// Builds the guest command: known path, offset, window bytes, earlier.
    typealias Command = (String?, Int, Int, Bool) -> String?
    typealias Exec = (String) async -> String?

    private struct Fetch { let path: String; let pq: Data; let start: Int; let end: Int; let chunk: Data }

    /// Header = 5 lines (path, pending question, size, start, end), then
    /// the bytes. nil for empty output (no transcript file).
    private static func parse(_ raw: String) -> Fetch? {
        let d = Data(raw.utf8)
        var cuts: [Int] = []
        var i = d.startIndex
        while cuts.count < 5, i < d.endIndex, let nl = d[i...].firstIndex(of: 0x0A) {
            cuts.append(nl)
            i = nl + 1
        }
        guard cuts.count == 5 else { return nil }
        func field(_ k: Int) -> Data { Data(d[(k == 0 ? d.startIndex : cuts[k - 1] + 1)..<cuts[k]]) }
        func int(_ k: Int) -> Int? { Int(String(decoding: field(k), as: UTF8.self).trimmingCharacters(in: .whitespaces)) }
        let path = String(decoding: field(0), as: UTF8.self)
        guard !path.isEmpty, let start = int(3), let end = int(4) else { return nil }
        return Fetch(path: path, pq: field(1), start: start, end: end, chunk: Data(d[(cuts[4] + 1)...]))
    }

    /// The new bytes since the last read. nil when the read failed (keep
    /// what's on show); otherwise the conversation.
    func refresh(agent: String?, command: Command, exec: Exec) async -> [TranscriptItem]? {
        let knownPath = path, knownEnd = end
        guard let cmd = command(knownPath, knownEnd, Self.windowBytes, false), let raw = await exec(cmd) else { return nil }
        // Another read (a send's refresh beside the poll) landed meanwhile:
        // this one's bytes are already held, or would be appended twice.
        guard path == knownPath, end == knownEnd else { return items }
        var changed = false
        if let f = Self.parse(raw) {
            if f.pq != pq { pq = f.pq; changed = true }
            if path == f.path, f.start == end {
                if !f.chunk.isEmpty { data.append(f.chunk); end = f.end; changed = true }
            } else {
                // First read, another file, or too far behind: start over.
                path = f.path; data = f.chunk; base = f.start; end = f.end
                changed = true
            }
        } else if path != nil || !items.isEmpty {
            path = nil; data = Data(); pq = Data(); base = 0; end = 0
            changed = true
        }
        if changed { await reparse(agent: agent) }
        return items
    }

    /// The conversation before what's held, put in front. False when
    /// nothing came (or the history moved meanwhile).
    @discardableResult
    func loadEarlier(agent: String?, command: Command, exec: Exec) async -> Bool {
        guard let held = path, base > 0, let cmd = command(held, base, Self.windowBytes, true),
              let raw = await exec(cmd), let f = Self.parse(raw),
              f.path == path, f.end == base, !f.chunk.isEmpty
        else { return false }
        data = f.chunk + data
        base = f.start
        await reparse(agent: agent)
        return true
    }

    private func reparse(agent: String?) async {
        generation &+= 1
        let gen = generation
        var input = data
        if !pq.isEmpty { input.append(0x0A); input.append(pq); input.append(0x0A) }
        let parsed = await Task.detached(priority: .userInitiated) {
            AgentTranscript.parse(input, agent: agent)
        }.value
        // A later read parsed newer history meanwhile: it wins.
        guard gen == generation else { return }
        TranscriptMarkdownCache.prewarm(parsed)
        items = parsed
    }
}
