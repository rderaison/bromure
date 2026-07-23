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

    /// Bridges the workspace's browser MCP (an agent's `browser_navigate`) and
    /// the manual port browser to one shared WKWebView + loopback tunnel. Its
    /// relay runs for the life of this screen (started in `.onAppear`).
    @StateObject private var browserBridge: MobileBrowserBridge

    init(controller: RemoteHostController, profileID: Profile.ID, initialWindow: Int? = nil) {
        self.controller = controller
        self.profileID = profileID
        self.initialWindow = initialWindow
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
    /// Compact height = the phone is on its side. A terminal is the one pane
    /// that wants every one of those few hundred points, so landscape drops the
    /// pane picker and the tab strip and hands the whole area to the surface.
    /// Rotating back brings them straight back; the nav bar stays either way
    /// (it carries Back and the reader / new-terminal actions).
    @Environment(\.verticalSizeClass) private var vSize
    private var terminalFullBleed: Bool { vSize == .compact && pane == .terminals }

    private var runState: SessionListModel.RunState { controller.runState(for: profileID) }
    private var isRunning: Bool { runState == .running || runState == .booting }
    private var profileName: String {
        controller.profile(for: profileID)?.name ?? "Workspace"
    }

    var body: some View {
        VStack(spacing: 0) {
            if !terminalFullBleed {
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
        .navigationTitle(profileName)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: isRunning) { _, running in
            if !running && pane != .dashboard { pane = .dashboard }
        }
        // Serve the browser MCP for this workspace while its screen is open.
        .onAppear { browserBridge.start() }
        // An agent opened a page (browser_navigate) — bring the Web pane forward.
        .onChange(of: browserBridge.showTick) { _, _ in
            if isRunning { withAnimation(.snappy(duration: 0.28)) { pane = .web } }
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
                        if selected {
                            Text(p.rawValue).font(.subheadline.weight(.semibold))
                                .fixedSize().lineLimit(1)
                        }
                    }
                    .padding(.horizontal, selected ? 15 : 12)
                    .padding(.vertical, 9)
                    .frame(maxWidth: selected ? .infinity : nil)
                    .background(
                        Capsule().fill(selected ? Color.accentColor
                                                : Color.secondary.opacity(0.14)))
                    .foregroundStyle(selected ? Color.white : Color.secondary)
                }
                .buttonStyle(.plain)
            }
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
                TerminalsPane(controller: controller, profileID: profileID,
                              initialWindow: initialWindow,
                              hidesTabStrip: terminalFullBleed,
                              isVisible: pane == .terminals)
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
    final class TranscriptStore {
        var items: [Int: [TranscriptItem]] = [:]
        var everLoaded: Set<Int> = []
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
        let cwd = tab?.cwd ?? tab?.repoRoot
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
        if tab.agentStatus == .working || tab.agentStatus == .needsInput || tab.isWorktree {
            return true
        }
        return BromureIcons.agentKind(forLabel: tab.shownLabel) != nil
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
                    // Keyboard handling is on THIS container only — the terminal
                    // opts out of SwiftUI's automatic avoidance and insets by the
                    // measured overlap instead (default avoidance left the last
                    // rows under the keyboard in landscape). The reader is a
                    // sibling below, deliberately OUTSIDE this, so it keeps the
                    // normal avoidance its text field needs.
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
                        // Normal keyboard avoidance: the composer lifts above the
                        // keyboard so you can see what you type.
                        TranscriptReaderView(controller: controller, profileID: profileID,
                                             window: win, guestCwd: guestCwd(for: win),
                                             since: transcriptSince, store: transcripts)
                            .id("reader-\(profileID)-\(win)")
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
        return "\(win)-\(isAgentic(currentTab))-\(effectiveWindow.flatMap { guestCwd(for: $0) } ?? "")"
    }

    private func pollTranscriptPresence() async {
        guard let win = effectiveWindow, isAgentic(currentTab),
              !transcriptPresent.contains(win),
              let cwd = guestCwd(for: win), !cwd.isEmpty,
              let cmd = CodingTaskEngine.planTranscriptCommand(guestCwd: cwd, since: transcriptSince)
        else { return }
        while !Task.isCancelled {
            if let raw = try? await controller.guestExec(profileID, command: cmd, timeout: 15) {
                let parsed = ClaudeTranscriptParser.parse(Data(raw.utf8))
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
            }
            mounted.removeAll { !live.contains($0) }
        }
        if let win = effectiveWindow, !mounted.contains(win) { mounted.append(win) }
    }

    /// How much of `container` (screen coordinates) the keyboard covers. Zero
    /// when it's hidden, off-screen, or below the surface entirely — an
    /// undocked/floating iPad keyboard therefore costs the terminal nothing.
    private func keyboardOverlap(with container: CGRect) -> CGFloat {
        guard keyboardFrame.height > 0 else { return 0 }
        return max(0, container.maxY - keyboardFrame.minY)
    }

    private func session(for window: Int) -> AttachSession {
        if let s = store.map[window] { return s }
        let s = AttachSession(host: controller.host, vmID: profileID.uuidString, windowIndex: window)
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
            Button {
                _ = controller.gridStore.add(profileID: profileID, windowIndex: tab.index,
                                             label: tab.shownLabel)
                controller.pushGridLayout()
            } label: { Label("Send to Grid", systemImage: "square.grid.2x2") }
            Button(role: .destructive) {
                controller.closeTab(profileID, index: tab.index)
                store.map[tab.index]?.stop()
                store.map[tab.index] = nil
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
    /// Epoch floor (this workspace's boot time) so a pre-reboot pending-question
    /// dump or an older session's transcript isn't tailed as if it were live —
    /// see TerminalsPane.transcriptSince.
    let since: Int
    /// Shared across reader remounts so a toggle doesn't re-tail from scratch.
    let store: TerminalsPane.TranscriptStore
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
        transcript
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The composer as a bottom safe-area inset (the Messages pattern):
            // this pins it correctly ABOVE the keyboard INCLUDING the QuickType
            // suggestion bar, so what you type is never hidden behind it.
            .safeAreaInset(edge: .bottom, spacing: 0) { composerBar }
            .onAppear {
                // Show the cached conversation instantly; the poll refreshes it.
                if items.isEmpty { items = store.items[window] ?? [] }
                if store.everLoaded.contains(window) { loaded = true }
            }
            // Re-key on `since` as well as the cwd: a reboot bumps the boot-time
            // floor, and the poll must rebuild its command to stop tailing the
            // pre-reboot pending-question dump (poll() captures `since` once).
            .task(id: "\(guestCwd ?? "")\u{1f}\(since)") { await poll() }
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
                HStack(spacing: 18) {
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
                        ForEach(answeredItems) { TranscriptItemView(item: $0) }
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

    /// Scroll to the last item. The short defer lets the lazy stack realize
    /// freshly-appended rows first, so the target actually exists.
    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let last = items.last?.id else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if animated { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
            else { proxy.scrollTo(last, anchor: .bottom) }
        }
    }

    private var sendable: Bool {
        !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    private func poll() async {
        guard let cwd = guestCwd, !cwd.isEmpty,
              let cmd = CodingTaskEngine.planTranscriptCommand(guestCwd: cwd, since: since)
        else { loaded = true; store.everLoaded.insert(window); return }
        while !Task.isCancelled {
            if let raw = try? await controller.guestExec(profileID, command: cmd, timeout: 15) {
                let parsed = ClaudeTranscriptParser.parse(Data(raw.utf8))
                items = parsed
                store.items[window] = parsed          // survive a reader remount
            }
            loaded = true
            store.everLoaded.insert(window)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    /// One immediate transcript refresh — used right after sending a message or
    /// answering a question so the reader reflects it without waiting out the
    /// 2 s poll (the "nothing happens until I toggle" complaint: a toggle just
    /// forced this same fresh read).
    private func refreshNow() async {
        guard let cwd = guestCwd, !cwd.isEmpty,
              let cmd = CodingTaskEngine.planTranscriptCommand(guestCwd: cwd, since: since),
              let raw = try? await controller.guestExec(profileID, command: cmd, timeout: 15)
        else { return }
        let parsed = ClaudeTranscriptParser.parse(Data(raw.utf8))
        await MainActor.run { items = parsed; store.items[window] = parsed }
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
