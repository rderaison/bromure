#if os(visionOS)
import SwiftUI

// MARK: - visionOS aux scenes
//
// The spatial shell's extra window types. The main window is the same split
// shell the iPad runs (PadHostMirror); these are what the spatial canvas adds:
//
//  - `PinnedTerminalWindow` — ONE workspace terminal as its own window. Opened
//    from a grid tile's pop-out, a terminal tab's context menu, or "Pin All".
//    The user drags it anywhere in the room and it stays there; the window is
//    identified by its `TerminalWindowValue`, so scene restoration brings the
//    same terminal back after a relaunch (for saved hosts).
//  - `GridStageWindow` — the grid as a dedicated stage window of live
//    terminals, so it can be pinned wall-sized while the main shell does other
//    work.
//
// Both are separate SwiftUI scenes: they reach the live mirror through
// `HostControllerStore.shared.claim/release`, which refcounts the controller
// so pinned windows survive the main shell leaving the host (and the last
// closed window tears the connection down).

/// Identifies one workspace terminal window. The display metadata rides along
/// so a restored window can draw its chrome before the mirror has state.
struct TerminalWindowValue: Codable, Hashable {
    var hostID: UUID
    var profileID: UUID
    var windowIndex: Int
    var workspaceName: String
    var windowLabel: String
    var accentHex: String
}

/// Identifies a grid stage window (one per host).
struct GridWindowValue: Codable, Hashable {
    var hostID: UUID
    var hostName: String
}

// MARK: - Pinned terminal window

struct PinnedTerminalWindow: View {
    let value: TerminalWindowValue

    @State private var controller: RemoteHostController?
    @State private var session: AttachSession?
    /// The host isn't reachable from this scene (a bromure.io peer that isn't
    /// open in the main shell) — show the pointer instead of a dead spinner.
    @State private var unresolvable = false
    @State private var focusTick = 0
    /// Pinned windows share one persisted font size (pinch still zooms live).
    @AppStorage("pinnedTerminalFontSize") private var fontSize = 14.0
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let session {
                VStack(spacing: 0) {
                    header
                    TerminalSurface(
                        session: session,
                        fontSize: Binding(get: { CGFloat(fontSize) },
                                          set: { fontSize = Double($0) }),
                        focusTick: focusTick,
                        isActive: true,
                        bottomInset: 0)
                        .background(Color.black)
                }
            } else if unresolvable {
                ContentUnavailableView {
                    Label(value.workspaceName, systemImage: "server.rack")
                } description: {
                    Text("This terminal's server isn't connected. Open it in the main Bromure window, then pop the terminal back out.")
                } actions: {
                    Button("Open Main Window") { openWindow(id: "main") }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(title)
        .onAppear { resolve() }
        .onDisappear { teardown() }
        // Coming back from a long app-level sleep: nudge focus so the keyboard
        // reattaches to this window's terminal without a tap.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { focusTick &+= 1 }
        }
    }

    private var title: String {
        value.windowLabel.isEmpty ? value.workspaceName
                                  : "\(value.workspaceName) — \(value.windowLabel)"
    }

    /// Live mirrored status when available; the carried metadata otherwise.
    private var liveTab: TabsModel.Tab? {
        controller?.tabsModel(for: value.profileID)?.tabs
            .first { $0.index == value.windowIndex }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: accentHex)).frame(width: 9, height: 9)
            Text(controller?.profile(for: value.profileID)?.name ?? value.workspaceName)
                .font(.callout.weight(.semibold)).lineLimit(1)
            if let tab = liveTab {
                Text(tab.shownLabel.isEmpty ? "shell" : tab.shownLabel)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                AgentStatusDot(status: tab.agentStatus)
            } else if !value.windowLabel.isEmpty {
                Text(value.windowLabel)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let c = controller, !c.connected {
                Label("Reconnecting…", systemImage: "wifi.exclamationmark")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
    }

    private var accentHex: String {
        controller?.profile(for: value.profileID)?.color.hexInUI ?? value.accentHex
    }

    private func resolve() {
        guard session == nil, !unresolvable else { return }
        guard let c = HostControllerStore.shared.claim(value.hostID) else {
            unresolvable = true
            return
        }
        c.start()
        controller = c
        let s = AttachSession(host: c.host, vmID: value.profileID.uuidString,
                              windowIndex: value.windowIndex)
        // The guest closed this window (ctrl-D / exit): the terminal is gone,
        // so the pinned window follows it out.
        s.onCleanExit = {
            dismissWindow(id: "terminal", value: value)
        }
        session = s
    }

    private func teardown() {
        session?.stop()
        session = nil
        if controller != nil {
            HostControllerStore.shared.release(value.hostID)
            controller = nil
        }
        unresolvable = false
    }
}

// MARK: - Grid stage window

struct GridStageWindow: View {
    let value: GridWindowValue

    @State private var controller: RemoteHostController?
    @State private var unresolvable = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let controller {
                NavigationStack {
                    VisionGridScreen(controller: controller, standalone: true)
                }
            } else if unresolvable {
                ContentUnavailableView {
                    Label(value.hostName, systemImage: "server.rack")
                } description: {
                    Text("This server isn't connected. Open it in the main Bromure window, then reopen the grid.")
                } actions: {
                    Button("Open Main Window") { openWindow(id: "main") }
                }
            } else {
                ProgressView()
            }
        }
        .onAppear {
            guard controller == nil, !unresolvable else { return }
            if let c = HostControllerStore.shared.claim(value.hostID) {
                c.start()
                controller = c
            } else {
                unresolvable = true
            }
        }
        .onDisappear {
            if controller != nil {
                HostControllerStore.shared.release(value.hostID)
                controller = nil
            }
            unresolvable = false
        }
    }
}
#endif
