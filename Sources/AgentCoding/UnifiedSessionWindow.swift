import AppKit
import SandboxEngine
import SwiftUI
@preconcurrency import Virtualization

// MARK: - Sidebar list model

/// Drives the unpeel-style source-list. One `VMEntry` per running VM hosted in
/// the unified window; each entry carries the pane's live `TabsModel` so the
/// nested tab rows update in place.
@MainActor
@Observable
final class SessionListModel {
    @MainActor
    @Observable
    final class VMEntry: Identifiable {
        let id: Profile.ID
        var name: String
        var accentHex: String
        /// The pane's tab model — shared by reference, so tab labels / active
        /// index / thinking state refresh the sidebar rows live.
        let model: TabsModel
        init(id: Profile.ID, name: String, accentHex: String, model: TabsModel) {
            self.id = id
            self.name = name
            self.accentHex = accentHex
            self.model = model
        }
    }

    var entries: [VMEntry] = []
    var selectedID: Profile.ID?
}

/// Coarse per-tab activity derived from the foreground program tmux reports as
/// the window label — honest signal from data we already have, no guest change.
enum TabActivity {
    case agent      // a coding agent is in the foreground
    case shell      // an idle shell / other program

    private static let agentBinaries: Set<String> = [
        "claude", "codex", "grok", "aider", "goose", "amp", "opencode",
        "gemini", "cursor", "llm", "ollama", "node", "python", "python3",
    ]

    init(label: String) {
        let head = label.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "/" }).first.map(String.init) ?? ""
        self = Self.agentBinaries.contains(head) ? .agent : .shell
    }
}

// MARK: - Unified window

/// The shared, unpeel-style window: a left source-list of every running VM with
/// its tabs nested underneath, and a single framebuffer stage on the right
/// showing the selected tab's VM. Hosts many `SessionPane`s at once and is the
/// default home for sessions (popped-out VMs leave it for a `TabbedSessionWindow`).
@MainActor
final class UnifiedSessionWindow: NSWindow, SessionPaneHost {
    weak var acDelegate: ACAppDelegate?
    let listModel = SessionListModel()

    private var hostedPanes: [SessionPane] = []
    private(set) var selectedID: Profile.ID?

    /// Where the selected pane's framebuffer container is mounted.
    private let paneSlot: NSView
    /// Shown when no VM is hosted.
    private let emptyStateHost: NSHostingView<EmptyStageView>
    private var sidebarHost: NSHostingView<SessionSidebar>!
    private var toolbarDelegate: UnifiedToolbarDelegate?

    init(acDelegate: ACAppDelegate) {
        self.acDelegate = acDelegate
        self.paneSlot = NSView()
        self.emptyStateHost = NSHostingView(rootView: EmptyStageView())

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 860),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = "Bromure"
        titleVisibility = .hidden
        // A standard (non-full-size) titlebar keeps the stage header below the
        // traffic-light strip so its buttons stay clickable; the split view
        // fills everything beneath it.
        isMovableByWindowBackground = false
        animationBehavior = .none

        // ---- Sidebar (left) ----
        let sidebar = SessionSidebar(
            model: listModel,
            onSelectTab: { [weak self] id, idx in self?.selectTab(profileID: id, index: idx) },
            onNewTab:    { [weak self] id in self?.newTab(profileID: id) },
            onCloseTab:  { [weak self] id, idx in self?.closeTab(profileID: id, index: idx) },
            onSelectVM:  { [weak self] id in self?.select(profileID: id) },
            onDetachVM:  { [weak self] id in self?.acDelegate?.popOutVM(id) },
            onCloseVM:   { [weak self] id in self?.acDelegate?.closeVMFromSidebar(id) },
            startableProfiles: { [weak self] in self?.acDelegate?.startableProfileList() ?? [] },
            onStartProfile: { [weak self] id in self?.acDelegate?.startProfile(id) },
            onOpenPicker: { [weak self] in self?.acDelegate?.openProfileManagerAction(nil) })
        let sidebarHost = NSHostingView(rootView: sidebar)
        sidebarHost.translatesAutoresizingMaskIntoConstraints = false
        self.sidebarHost = sidebarHost

        // ---- Stage (right): just the framebuffer slot. The per-VM controls
        // live in the window toolbar now, so the framebuffer fills full height.
        let stage = NSView()
        stage.translatesAutoresizingMaskIntoConstraints = false
        stage.wantsLayer = true
        stage.layer?.backgroundColor = NSColor.black.cgColor
        paneSlot.translatesAutoresizingMaskIntoConstraints = false
        emptyStateHost.translatesAutoresizingMaskIntoConstraints = false
        stage.addSubview(paneSlot)
        stage.addSubview(emptyStateHost)
        NSLayoutConstraint.activate([
            paneSlot.topAnchor.constraint(equalTo: stage.topAnchor),
            paneSlot.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            paneSlot.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            paneSlot.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            emptyStateHost.topAnchor.constraint(equalTo: paneSlot.topAnchor),
            emptyStateHost.leadingAnchor.constraint(equalTo: paneSlot.leadingAnchor),
            emptyStateHost.trailingAnchor.constraint(equalTo: paneSlot.trailingAnchor),
            emptyStateHost.bottomAnchor.constraint(equalTo: paneSlot.bottomAnchor),
        ])

        // ---- Layout: fixed-width sidebar | divider | framebuffer stage ----
        // Plain Auto Layout (no NSSplitView) so the framebuffer deterministically
        // fills everything to the right of a fixed 264pt sidebar — Mail.app shape.
        let root = NSView()
        sidebarHost.translatesAutoresizingMaskIntoConstraints = false
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(sidebarHost)
        root.addSubview(divider)
        root.addSubview(stage)
        NSLayoutConstraint.activate([
            sidebarHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebarHost.topAnchor.constraint(equalTo: root.topAnchor),
            sidebarHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebarHost.widthAnchor.constraint(equalToConstant: 264),

            divider.leadingAnchor.constraint(equalTo: sidebarHost.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            stage.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            stage.topAnchor.constraint(equalTo: root.topAnchor),
            stage.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            stage.trailingAnchor.constraint(equalTo: root.trailingAnchor),
        ])
        contentView = root

        // ---- Window toolbar: per-selected-VM controls + IP ----
        let toolbarBar = UnifiedToolbarBar(
            model: listModel,
            onFiles:     { [weak self] id in self?.acDelegate?.openFileBrowserForUnified(id) },
            onReboot:    { [weak self] id in if let p = self?.pane(id) { self?.acDelegate?.requestReboot(for: p) } },
            onTrace:     { [weak self] id in if let p = self?.pane(id) { self?.acDelegate?.openTraceInspector(for: p.profile) } },
            onSettings:  { [weak self] id in if let p = self?.pane(id) { self?.acDelegate?.openEditorWindow(editing: p.profile) } },
            onDetach:    { [weak self] id in self?.acDelegate?.popOutVM(id) },
            onToggleFusion: { [weak self] id, on in if let p = self?.pane(id) { self?.acDelegate?.setFusionEngaged(on, for: p.profile) } })
        let tbDelegate = UnifiedToolbarDelegate(rootView: toolbarBar)
        self.toolbarDelegate = tbDelegate
        let bar = NSToolbar(identifier: "io.bromure.ac.unified")
        bar.delegate = tbDelegate
        bar.displayMode = .iconOnly
        bar.showsBaselineSeparator = false
        bar.allowsUserCustomization = false
        toolbarStyle = .unified
        self.toolbar = bar

        updateEmptyState()
    }

    // MARK: Hosting

    private func pane(_ id: Profile.ID) -> SessionPane? {
        hostedPanes.first { $0.profile.id == id }
    }

    /// Add a pane to the sidebar + select it. Idempotent on profile id.
    func addPane(_ pane: SessionPane, select selectIt: Bool = true) {
        if hostedPanes.contains(where: { $0.profile.id == pane.profile.id }) { return }
        pane.host = self
        hostedPanes.append(pane)
        listModel.entries.append(SessionListModel.VMEntry(
            id: pane.profile.id,
            name: pane.profile.name,
            accentHex: pane.profile.color.hexInUI,
            model: pane.model))
        acDelegate?.registerPane(pane)
        if selectIt || selectedID == nil {
            select(profileID: pane.profile.id)
        }
        updateEmptyState()
    }

    /// Remove a profile's pane from the sidebar + stage. Does NOT touch the VM.
    func removePane(_ id: Profile.ID) {
        guard let idx = hostedPanes.firstIndex(where: { $0.profile.id == id }) else { return }
        let pane = hostedPanes.remove(at: idx)
        if pane.containerView.superview === paneSlot { pane.containerView.removeFromSuperview() }
        if pane.host === self { pane.host = nil }
        listModel.entries.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = nil
            // Select a neighbour if any remain.
            if let next = hostedPanes.first {
                select(profileID: next.profile.id)
            } else {
                listModel.selectedID = nil
                mountSelected(nil)
            }
        }
        updateEmptyState()
    }

    var isHostingAnyPane: Bool { !hostedPanes.isEmpty }

    func hostsPane(for id: Profile.ID) -> Bool { pane(id) != nil }

    /// Select a VM: show its framebuffer in the stage and focus it.
    func select(profileID id: Profile.ID) {
        guard let pane = pane(id) else { return }
        selectedID = id
        listModel.selectedID = id
        mountSelected(pane)
    }

    private func mountSelected(_ pane: SessionPane?) {
        for sub in paneSlot.subviews where sub !== emptyStateHost { sub.removeFromSuperview() }
        guard let pane else { updateEmptyState(); return }
        let v = pane.containerView
        v.translatesAutoresizingMaskIntoConstraints = false
        paneSlot.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: paneSlot.topAnchor),
            v.bottomAnchor.constraint(equalTo: paneSlot.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: paneSlot.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: paneSlot.trailingAnchor),
        ])
        makeFirstResponder(pane.vmView)
        updateEmptyState()
    }

    private func updateEmptyState() {
        emptyStateHost.isHidden = !hostedPanes.isEmpty
    }

    // MARK: Tab actions (forward to the pane)

    func selectTab(profileID id: Profile.ID, index: Int) {
        if selectedID != id { select(profileID: id) }
        pane(id)?.switchTo(index: index)
    }
    func newTab(profileID id: Profile.ID) {
        if selectedID != id { select(profileID: id) }
        if let p = pane(id) { acDelegate?.spawnNewTab(in: p) }
    }
    func closeTab(profileID id: Profile.ID, index: Int) {
        pane(id)?.closeTab(at: index)
    }

    // MARK: - SessionPaneHost

    var paneHostWindow: NSWindow? { self }

    func paneRequestsClose(_ pane: SessionPane) {
        // Last tab closed (or relaunch failure) → run the profile's close
        // pipeline for this VM, then drop the pane.
        acDelegate?.closeVMFromSidebar(pane.profile.id)
    }

    func paneDidUpdateProfile(_ pane: SessionPane) {
        if let entry = listModel.entries.first(where: { $0.id == pane.profile.id }) {
            entry.name = pane.profile.name
            entry.accentHex = pane.profile.color.hexInUI
        }
    }

    // MARK: - Shortcut routing (selected pane)

    private func selectedPane() -> SessionPane? {
        guard let id = selectedID else { return hostedPanes.first }
        return pane(id) ?? hostedPanes.first
    }

    func handleACShortcut(_ event: NSEvent) -> Bool {
        let userMods: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        guard event.modifierFlags.intersection(userMods) == [.command] else { return false }
        guard let pane = selectedPane() else { return false }
        if pane.vmHasKeyboardFocus { return false }
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        return pane.performACShortcut(chars, isRepeat: event.isARepeat)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleACShortcut(event) { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleACShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Sidebar SwiftUI

private struct SessionSidebar: View {
    @Bindable var model: SessionListModel
    let onSelectTab: (Profile.ID, Int) -> Void
    let onNewTab: (Profile.ID) -> Void
    let onCloseTab: (Profile.ID, Int) -> Void
    let onSelectVM: (Profile.ID) -> Void
    let onDetachVM: (Profile.ID) -> Void
    let onCloseVM: (Profile.ID) -> Void
    /// Live list of profiles that can be started, evaluated when the dropdown opens.
    let startableProfiles: () -> [(id: Profile.ID, name: String, accentHex: String)]
    let onStartProfile: (Profile.ID) -> Void
    let onOpenPicker: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sessions")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.7)
                Spacer()
            }
            .padding(.leading, 16)
            .padding(.trailing, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(model.entries) { entry in
                        VMSection(
                            entry: entry,
                            isSelectedVM: model.selectedID == entry.id,
                            onSelectTab: onSelectTab,
                            onNewTab: onNewTab,
                            onCloseTab: onCloseTab,
                            onSelectVM: onSelectVM,
                            onDetachVM: onDetachVM,
                            onCloseVM: onCloseVM)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            Divider().opacity(0.5)
            NewSessionButton(
                startableProfiles: startableProfiles,
                onStartProfile: onStartProfile,
                onOpenPicker: onOpenPicker)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.ultraThinMaterial)
    }
}

/// "New session" dropdown — pick a profile to boot, or open the manager.
private struct NewSessionButton: View {
    let startableProfiles: () -> [(id: Profile.ID, name: String, accentHex: String)]
    let onStartProfile: (Profile.ID) -> Void
    let onOpenPicker: () -> Void

    var body: some View {
        Menu {
            let profiles = startableProfiles()
            if profiles.isEmpty {
                Text("All profiles are already running")
            } else {
                Section("Start a session") {
                    ForEach(profiles, id: \.id) { p in
                        Button(p.name) { onStartProfile(p.id) }
                    }
                }
            }
            Divider()
            Button("Manage profiles…") { onOpenPicker() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle.fill").font(.system(size: 15))
                Text("New session").font(.system(size: 13, weight: .medium))
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .foregroundStyle(.secondary)
    }
}

/// One VM (profile) and its nested tab rows — the source-list hierarchy.
private struct VMSection: View {
    @Bindable var entry: SessionListModel.VMEntry
    let isSelectedVM: Bool
    let onSelectTab: (Profile.ID, Int) -> Void
    let onNewTab: (Profile.ID) -> Void
    let onCloseTab: (Profile.ID, Int) -> Void
    let onSelectVM: (Profile.ID) -> Void
    let onDetachVM: (Profile.ID) -> Void
    let onCloseVM: (Profile.ID) -> Void

    @State private var hovering = false

    private var status: VMRowStatus {
        if entry.model.tabs.isEmpty { return .booting }
        return entry.model.ipAddress == nil ? .booting : .running
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Profile (VM) header
            HStack(spacing: 8) {
                VMIcon(accentHex: entry.accentHex, status: status)
                Text(entry.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(isSelectedVM ? .primary : .secondary)
                Spacer(minLength: 4)
                if hovering {
                    IconButton(system: "rectangle.portrait.and.arrow.right", help: "Pop out to its own window") {
                        onDetachVM(entry.id)
                    }
                    IconButton(system: "xmark", help: "Close this VM") {
                        onCloseVM(entry.id)
                    }
                }
                IconButton(system: "plus", help: "New tab (⌘T)") { onNewTab(entry.id) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelectedVM ? Color(hex: entry.accentHex).opacity(0.16)
                                       : (hovering ? Color.primary.opacity(0.04) : .clear)))
            .overlay(alignment: .leading) {
                if isSelectedVM {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(hex: entry.accentHex))
                        .frame(width: 3, height: 18)
                        .offset(x: -5)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onSelectVM(entry.id) }

            // Nested tab rows, indented with a hierarchy guide line.
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(entry.model.tabs.enumerated()), id: \.element.id) { idx, tab in
                    TabRow(
                        label: tab.label,
                        agentKind: BromureIcons.agentKind(forLabel: tab.label),
                        thinking: entry.model.thinking,
                        isActive: idx == entry.model.activeIndex && isSelectedVM,
                        accentHex: entry.accentHex,
                        onSelect: { onSelectTab(entry.id, idx) },
                        onClose: { onCloseTab(entry.id, idx) })
                }
            }
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 1)
                    .padding(.leading, 17)
                    .padding(.vertical, 4)
            }
        }
        .padding(.bottom, 5)
        .onHover { hovering = $0 }
    }
}

private enum VMRowStatus { case booting, running, suspended }

/// The profile's robot tile with a status badge.
private struct VMIcon: View {
    let accentHex: String
    let status: VMRowStatus
    @State private var pulse = false
    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(Color(hex: accentHex).opacity(0.18))
            .frame(width: 24, height: 24)
            .overlay(
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: accentHex)))
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.4))
                    .opacity(status == .booting && pulse ? 0.4 : 1)
                    .offset(x: 3, y: 3)
            }
            .onAppear {
                if status == .booting {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
                }
            }
    }
    private var statusColor: Color {
        switch status {
        case .booting: return .orange
        case .running: return .green
        case .suspended: return .gray
        }
    }
}

private struct TabRow: View {
    let label: String
    let agentKind: String?
    let thinking: Bool
    let isActive: Bool
    let accentHex: String
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    private var isAgent: Bool { agentKind != nil }

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if isAgent && thinking {
                    ThinkingDots(color: Color(hex: accentHex))
                } else if isAgent {
                    SVGIcon(name: "robot", fallbackSymbol: "sparkles", size: 13)
                        .foregroundStyle(isActive ? Color(hex: accentHex) : .secondary)
                } else {
                    Image(systemName: "terminal")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 14)

            Text(label.isEmpty ? "shell" : label)
                .font(.system(size: 12, weight: isActive ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isActive ? .primary : .secondary)
            Spacer(minLength: 2)
            if hovering {
                IconButton(system: "xmark", help: "Close tab (⌘W)", size: 9) { onClose() }
            }
        }
        .padding(.leading, 26)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.primary.opacity(0.08) : (hovering ? Color.primary.opacity(0.04) : .clear)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}

/// unpeel-style staggered "typing" dots shown while the agent is working.
private struct ThinkingDots: View {
    var color: Color = .secondary
    @State private var anim = false
    var body: some View {
        HStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(color)
                    .frame(width: 4, height: 4)
                    .scaleEffect(anim ? 1.0 : 0.45)
                    .opacity(anim ? 1.0 : 0.4)
                    .animation(.easeInOut(duration: 0.5).repeatForever().delay(Double(i) * 0.16), value: anim)
            }
        }
        .onAppear { anim = true }
        .help("Working…")
    }
}

private struct IconButton: View {
    let system: String
    let help: String
    var size: CGFloat = 11
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .background(hovering ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Window toolbar (per-selected-VM controls + IP)

private let unifiedToolbarItemID = NSToolbarItem.Identifier("io.bromure.ac.unified.controls")

@MainActor
final class UnifiedToolbarDelegate: NSObject, NSToolbarDelegate {
    private let rootView: UnifiedToolbarBar
    init(rootView: UnifiedToolbarBar) { self.rootView = rootView }

    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, unifiedToolbarItemID]
    }
    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, unifiedToolbarItemID]
    }
    func toolbar(_ t: NSToolbar,
                 itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id == unifiedToolbarItemID else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        let host = FlexibleHostingView(rootView: rootView)
        host.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(host)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 28),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        item.view = container
        item.visibilityPriority = .high
        return item
    }
}

/// The toolbar's trailing control cluster for the selected VM.
struct UnifiedToolbarBar: View {
    @Bindable var model: SessionListModel
    let onFiles: (Profile.ID) -> Void
    let onReboot: (Profile.ID) -> Void
    let onTrace: (Profile.ID) -> Void
    let onSettings: (Profile.ID) -> Void
    let onDetach: (Profile.ID) -> Void
    let onToggleFusion: (Profile.ID, Bool) -> Void

    private var entry: SessionListModel.VMEntry? {
        model.entries.first { $0.id == model.selectedID }
    }

    var body: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            if let entry {
                if let ip = entry.model.ipAddress { ToolbarIP(ip: ip) }
                if entry.model.streamingActive { StreamingDot() }
                if let status = entry.model.engineStatus { EngineBadge(status: status) }
                FusionToggle(model: entry.model) { on in onToggleFusion(entry.id, on) }
                HeaderIcon(system: "folder", help: "Browse files") { onFiles(entry.id) }
                HeaderIcon(system: "arrow.clockwise.circle", help: "Reboot the VM") { onReboot(entry.id) }
                HeaderIcon(system: "doc.text.magnifyingglass", help: "Inspect trace (⇧⌘I)") { onTrace(entry.id) }
                HeaderIcon(system: "gearshape", help: "Edit profile") { onSettings(entry.id) }
                HeaderIcon(system: "rectangle.portrait.and.arrow.right", help: "Pop out to its own window") { onDetach(entry.id) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
    }
}

/// Monospace IP pill in the toolbar; click to copy.
private struct ToolbarIP: View {
    let ip: String
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ip, forType: .string)
            copied = true
            Task { try? await Task.sleep(nanoseconds: 1_200_000_000); copied = false }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "network").font(.system(size: 10))
                Text(copied ? "Copied" : ip).font(.system(.caption, design: .monospaced))
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("VM IP — click to copy")
    }
}

private struct HeaderIcon: View {
    let system: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 24)
                .background(hovering ? Color.primary.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct FusionToggle: View {
    @Bindable var model: TabsModel
    let onToggle: (Bool) -> Void
    var body: some View {
        Button {
            guard model.fusionConfigurable else { return }
            model.fusionEngaged.toggle()
            onToggle(model.fusionEngaged)
        } label: {
            Image(systemName: model.fusionConfigurable ? "bolt.fill" : "bolt")
                .font(.system(size: 13))
                .foregroundStyle(!model.fusionConfigurable ? Color.secondary
                    : (model.fusionEngaged ? .yellow : Color(nsColor: .darkGray)))
                .frame(width: 26, height: 24)
        }
        .buttonStyle(.plain)
        .disabled(!model.fusionConfigurable)
        .help(model.fusionConfigurable
            ? (model.fusionEngaged ? "Fusion engaged — click to disengage" : "Fusion available — click to engage")
            : "Enable at least two models to use Fusion")
    }
}

private struct StreamingDot: View {
    @State private var pulse = false
    var body: some View {
        Circle().fill(.red).frame(width: 8, height: 8)
            .opacity(pulse ? 1 : 0.5)
            .help("Session metadata is being sent to bromure.io")
            .onAppear { withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { pulse.toggle() } }
    }
}

private struct EngineBadge: View {
    let status: TabsModel.EngineStatus
    var body: some View {
        switch status {
        case .starting(let d):
            HStack(spacing: 4) { ProgressView().controlSize(.small).scaleEffect(0.7); Image(systemName: "cpu").foregroundStyle(.secondary) }.help(d)
        case .ready(let m):
            Image(systemName: "cpu.fill").foregroundStyle(.green).help("Local model ready — \(m)")
        case .failed(let e):
            Image(systemName: "cpu").foregroundStyle(.orange).help("Local engine failed: \(e)")
        }
    }
}

private struct EmptyStageView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.secondary)
            Text("No VM selected")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Start a session with ⌘N")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.001))
    }
}
