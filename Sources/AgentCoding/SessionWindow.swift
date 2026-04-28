import AppKit
import SandboxEngine
import SwiftUI
@preconcurrency import Virtualization

// MARK: - Tabs model

/// Observable model backing a TabbedSessionWindow. Each tab represents a
/// separate kitty process inside the SAME VM — switching tabs just
/// raises that tab's kitty window via the outbox-driven guest agent.
@MainActor
@Observable
final class TabsModel {
    @MainActor
    @Observable
    final class Tab: Identifiable {
        let id: UUID
        // @Observable makes per-property changes drive SwiftUI redraws,
        // so updating `label` from the title-poll path live-refreshes
        // the pill without us having to replace the array slot.
        var label: String
        init(label: String, id: UUID = UUID()) {
            self.label = label
            self.id = id
        }
    }

    var tabs: [Tab] = []
    var activeIndex: Int = 0
    var accentHex: String = "#3B82F6"
    /// Most recent VM IP reported by the guest's xinitrc loop. Surfaced
    /// in the toolbar; click to copy.
    var ipAddress: String?

    var activeTab: Tab? {
        tabs.indices.contains(activeIndex) ? tabs[activeIndex] : nil
    }
}

// MARK: - Window

/// One window per profile, holding multiple kitty *processes inside the
/// same VM* as macOS-native tabs in the unified titlebar. The shared
/// VZVirtualMachineView is the contentView; tab clicks are forwarded to
/// the in-VM agent (via the bromure-outbox channel) which raises the
/// matching kitty window.
@MainActor
final class TabbedSessionWindow: NSWindow {
    let profile: Profile
    let model = TabsModel()
    weak var acDelegate: ACAppDelegate?
    private var toolbarChromeDelegate: TabsToolbarDelegate?

    /// The single shared VM display — all kittys for this window render
    /// into this view because they all live in the same X session.
    let vmView: VZVirtualMachineView

    /// The single sandbox backing this whole window. Set by ACAppDelegate
    /// after the VM finishes starting; nil while booting.
    var sandbox: UbuntuSandboxVM?

    /// Keyboard-layout bridge that ferries macOS layout changes into
    /// the guest's setxkbmap. Owned by the window so its observer
    /// lifetime matches the VM session. nil when no socket device is
    /// available yet.
    var keyboardBridge: KeyboardBridge?

    /// What `windowShouldClose` decided to do with the VM. Read by
    /// `windowWillClose` so it can pause+save vs. requestStop without
    /// re-prompting the user.
    enum PendingCloseAction { case suspend, shutdown }
    var pendingCloseAction: PendingCloseAction = .shutdown

    /// When true, the next `sandbox.onStopped` shouldn't close the
    /// window — instead, relaunch a fresh VM in the same window. Set
    /// by the toolbar's Reboot action; cleared inside the relaunch
    /// path. Distinguishes user-requested reboot from a real shutdown.
    var rebootRequested: Bool = false

    init(profile: Profile, acDelegate: ACAppDelegate) {
        self.profile = profile
        self.acDelegate = acDelegate

        let view = VZVirtualMachineView()
        // capturesSystemKeys = false means macOS handles ⌘Tab, ⌘H,
        // ⌘Space, ⌘Q etc. at the WindowServer level instead of
        // routing them to the guest. We lose F-key forwarding into
        // the VM, but agent-coding workflows almost never use F-keys
        // and ⌘Tab is constant — that trade-off is the right one.
        view.capturesSystemKeys = false
        view.automaticallyReconfiguresDisplay = true
        self.vmView = view

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        title = profile.name
        titleVisibility = .hidden
        titlebarAppearsTransparent = false
        toolbarStyle = .unified
        model.accentHex = profile.color.hexInUI

        // Wrap the VZ view in a plain NSView container. We apply the
        // user's opacity to the *container's* layer, not the VZ view
        // itself — touching VZVirtualMachineView's own wantsLayer /
        // layer.opacity has been observed to crash AppKit's window
        // transform animator (see the animationBehavior comment
        // below). The container takes the layer alpha cleanly; the
        // VZ framebuffer renders into the container at full opacity
        // and inherits the alpha when composited. The titlebar paints
        // separately via the window chrome and is unaffected.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = .clear
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        contentView = container

        // Disable AppKit's default window animations. AppKit's
        // _NSWindowTransformAnimation has been observed to over-release
        // its block ivar inside the autorelease pool drain when the
        // contentView is a layer-hosted VZVirtualMachineView (crash:
        // `objc_release` from `-[NSConcretePointerArray dealloc]` on
        // the main thread during `CA::Context::commit_transaction`).
        // Disabling the implicit animation skips that animator path
        // entirely. The browser sets the same flag for the same reason.
        animationBehavior = .none

        // Apply the requested opacity to the wrapper layer, not the
        // window's alphaValue — that way only the framebuffer area
        // (below the toolbar) blends with whatever's behind, and the
        // titlebar / toolbar stays fully opaque. The window must
        // still be non-opaque + clear-background for the alpha to
        // actually composite against the desktop instead of an opaque
        // window backing.
        let opacity = min(1.0, max(0.3, profile.windowOpacity))
        container.layer?.opacity = Float(opacity)
        if opacity < 1.0 {
            isOpaque = false
            backgroundColor = .clear
        }

        let delegate = TabsToolbarDelegate(
            model: model,
            sharedFolderPaths: profile.folderPaths,
            onSelect: { [weak self] in self?.switchTo(index: $0) },
            onClose:  { [weak self] in self?.closeTab(at: $0) },
            onNew:    { [weak self] in
                guard let self else { return }
                self.acDelegate?.spawnNewTab(in: self)
            },
            onInspectTrace: { [weak self] in
                guard let self else { return }
                self.acDelegate?.openTraceInspector(for: self.profile)
            },
            onReboot: { [weak self] in
                guard let self else { return }
                self.acDelegate?.requestReboot(for: self)
            })
        toolbarChromeDelegate = delegate

        let bar = NSToolbar(identifier: "io.bromure.ac.tabs")
        bar.delegate = delegate
        bar.displayMode = .iconOnly
        bar.showsBaselineSeparator = false
        bar.allowsUserCustomization = false
        bar.autosavesConfiguration = false
        self.toolbar = bar
    }

    /// Called by ACAppDelegate when the in-VM agent reports the
    /// foreground process for a kitty tab. Updates the matching
    /// pill's label live (Terminal.app behaviour).
    func handleTabTitleUpdate(id: UUID, title: String) {
        guard let i = model.tabs.firstIndex(where: { $0.id == id }) else { return }
        model.tabs[i].label = title
    }

    /// Add a tab placeholder to the model. Caller follows up by sending a
    /// spawn-kitty command to the in-VM agent for this tab's UUID.
    @discardableResult
    func appendTab() -> TabsModel.Tab {
        let tab = TabsModel.Tab(label: "Session \(model.tabs.count + 1)")
        model.tabs.append(tab)
        model.activeIndex = model.tabs.count - 1
        return tab
    }

    /// Rebuild the tab bar from a saved-state snapshot. Used on
    /// restore so the host's tab UUIDs match the kittys still
    /// running inside the resumed VM (each kitty was started with
    /// `--class bromure-<UUID>`). Called BEFORE the VM is up — the
    /// raise-active-tab command goes out separately once it is.
    func rehydrateTabs(from state: SessionDisk.TabsState) {
        model.tabs = state.tabs.map { TabsModel.Tab(label: $0.label, id: $0.id) }
        model.activeIndex = max(0, min(state.activeIndex, model.tabs.count - 1))
    }

    /// Capture the current tab model into a snapshot for persistence.
    func snapshotTabs() -> SessionDisk.TabsState {
        SessionDisk.TabsState(
            tabs: model.tabs.map {
                SessionDisk.TabSnapshot(id: $0.id, label: $0.label)
            },
            activeIndex: model.activeIndex
        )
    }

    func switchTo(index: Int) {
        guard model.tabs.indices.contains(index) else { return }
        model.activeIndex = index
        if let tab = model.activeTab {
            acDelegate?.requestRaiseTab(id: tab.id, in: self)
        }
    }

    func closeTab(at index: Int) {
        guard model.tabs.indices.contains(index) else { return }
        let tab = model.tabs.remove(at: index)
        acDelegate?.requestCloseTab(id: tab.id, in: self)
        if model.tabs.isEmpty {
            // Last-tab ⌘W is "I'm done with this session" — same
            // intent as Ctrl+D inside kitty. Force shutdown
            // regardless of profile.closeAction; suspending an empty
            // X session is wasteful and can leave a snapshot whose
            // restore goes straight back to a black screen.
            pendingCloseAction = .shutdown
            close()
            return
        }
        let newIndex = max(0, min(index - 1, model.tabs.count - 1))
        switchTo(index: newIndex)
    }

    /// Tab whose kitty exited inside the VM (e.g. user hit Ctrl+D).
    /// Idempotent: if the tab was already removed by an explicit ⌘W,
    /// this no-ops.
    func handleTabClosedFromGuest(id: UUID) {
        guard let idx = model.tabs.firstIndex(where: { $0.id == id }) else { return }
        model.tabs.remove(at: idx)
        if model.activeIndex >= model.tabs.count {
            model.activeIndex = max(0, model.tabs.count - 1)
        }
        if model.tabs.isEmpty {
            // Guest-side end-of-session: the user closed every kitty
            // from inside the VM (Ctrl+D, `exit`, kitty crash). That
            // signals "I'm done" — suspending RAM here would just
            // freeze a do-nothing X session and on restore we'd end
            // up with no usable terminal anyway. Force shutdown,
            // bypass the profile's normal closeAction, and skip the
            // confirmation prompt (the user already confirmed by
            // killing their last shell).
            pendingCloseAction = .shutdown
            close()
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Match the relaxed-modifier test in ACAppDelegate.interceptKey:
        // capsLock / numericPad / help / function leak in unrelated
        // bits that a strict `== [.command]` would reject, leaving ⌘T
        // and ⌘W appearing to work intermittently.
        let userMods: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let mods = event.modifierFlags.intersection(userMods)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if mods == [.command] {
            switch chars {
            case "t":
                acDelegate?.spawnNewTab(in: self)
                return true
            case "w":
                closeTab(at: model.activeIndex)
                return true
            default:
                if let n = Int(chars), (1...9).contains(n),
                   model.tabs.indices.contains(n - 1) {
                    switchTo(index: n - 1)
                    return true
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Toolbar delegate

private let tabsToolbarItemID = NSToolbarItem.Identifier("io.bromure.ac.tabsItem")

@MainActor
final class TabsToolbarDelegate: NSObject, NSToolbarDelegate {
    let model: TabsModel
    let sharedFolderPaths: [String]
    let onSelect: (Int) -> Void
    let onClose:  (Int) -> Void
    let onNew:    () -> Void
    let onInspectTrace: () -> Void
    let onReboot: () -> Void

    init(model: TabsModel,
         sharedFolderPaths: [String],
         onSelect: @escaping (Int) -> Void,
         onClose:  @escaping (Int) -> Void,
         onNew:    @escaping () -> Void,
         onInspectTrace: @escaping () -> Void,
         onReboot: @escaping () -> Void) {
        self.model = model
        self.sharedFolderPaths = sharedFolderPaths
        self.onSelect = onSelect
        self.onClose = onClose
        self.onNew = onNew
        self.onInspectTrace = onInspectTrace
        self.onReboot = onReboot
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [tabsToolbarItemID]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [tabsToolbarItemID]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier id: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard id == tabsToolbarItemID else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        let host = FlexibleHostingView(rootView: TabsBar(
            model: model,
            sharedFolderPaths: sharedFolderPaths,
            onSelect: onSelect,
            onClose:  onClose,
            onNew:    onNew,
            onInspectTrace: onInspectTrace,
            onReboot: onReboot
        ))
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 30),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        item.view = container
        item.visibilityPriority = .high
        item.label = ""
        item.paletteLabel = "Tabs"
        return item
    }
}

/// NSHostingView that hides its width from AppKit so NSToolbar doesn't
/// size the toolbar item to the SwiftUI content's intrinsic width.
final class FlexibleHostingView<Content: View>: NSHostingView<Content> {
    override var intrinsicContentSize: NSSize {
        let inner = super.intrinsicContentSize
        return NSSize(width: NSView.noIntrinsicMetric, height: inner.height)
    }
}

// MARK: - Tab bar SwiftUI (capsule layout, browser-style)

private struct TabsBar: View {
    let model: TabsModel
    let sharedFolderPaths: [String]
    let onSelect: (Int) -> Void
    let onClose:  (Int) -> Void
    let onNew:    () -> Void
    let onInspectTrace: () -> Void
    let onReboot: () -> Void

    @State private var foldersPopoverShown = false

    var body: some View {
        HStack(spacing: 6) {
            // Outer capsule pill containing the tab strip — matches the
            // browser's "outer grey capsule" idiom.
            HStack(spacing: 4) {
                ForEach(Array(model.tabs.enumerated()), id: \.element.id) { idx, tab in
                    TabCapsule(
                        label: tab.label,
                        isActive: idx == model.activeIndex,
                        accentHex: model.accentHex,
                        onSelect: { onSelect(idx) },
                        onClose:  { onClose(idx) }
                    )
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.gray.opacity(0.18)))

            Button(action: onNew) {
                Image(systemName: "plus")
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.borderless)
            .help("New tab (⌘T)")

            Spacer(minLength: 8)

            if let ip = model.ipAddress {
                IPChip(ip: ip)
            } else {
                Text("…")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .help("Waiting for VM to report its IP")
            }

            // Shared folders — only present when the profile actually
            // mounts something into the VM. Click reveals a popover
            // listing each host folder; click a row to open in Finder.
            if !sharedFolderPaths.isEmpty {
                Button {
                    foldersPopoverShown.toggle()
                } label: {
                    Image(systemName: "folder")
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(.borderless)
                .help(NSLocalizedString("Shared folders mounted in the VM", comment: ""))
                .popover(isPresented: $foldersPopoverShown, arrowEdge: .bottom) {
                    SharedFoldersList(paths: sharedFolderPaths)
                }
            }

            // Reboot — opens a confirm dialog (soft via `sudo reboot`
            // inside the guest, hard via `vm.stop()` on the host).
            Button(action: onReboot) {
                Image(systemName: "arrow.clockwise.circle")
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.borderless)
            .help(NSLocalizedString("Reboot the VM", comment: ""))

            // Trace inspector — opens the global window pre-filtered
            // to this profile. Mirrors the browser's per-window
            // inspector affordance.
            Button(action: onInspectTrace) {
                Image(systemName: "doc.text.magnifyingglass")
                    .frame(width: 24, height: 22)
            }
            .buttonStyle(.borderless)
            .help(NSLocalizedString("Inspect this profile's session trace (⇧⌘I)", comment: ""))
        }
    }
}

/// Popover content listing the host paths the VM has mounted via
/// virtiofs. Each row opens the folder in Finder when clicked.
private struct SharedFoldersList: View {
    let paths: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(NSLocalizedString("Shared folders", comment: ""))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)
            Divider()
            VStack(spacing: 0) {
                ForEach(paths, id: \.self) { path in
                    SharedFolderRow(path: path)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 320)
    }
}

private struct SharedFolderRow: View {
    let path: String
    @State private var hovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text((path as NSString).lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(abbreviated(path))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(hovering ? Color.gray.opacity(0.12) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(path)
    }

    private func abbreviated(_ p: String) -> String {
        (p as NSString).abbreviatingWithTildeInPath
    }
}

/// Small monospace pill showing the VM's IPv4. Click to copy.
private struct IPChip: View {
    let ip: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ip, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copied = false
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "network")
                    .font(.system(size: 10))
                Text(copied ? "Copied" : ip)
                    .font(.system(.caption, design: .monospaced))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.gray.opacity(0.15)))
        }
        .buttonStyle(.borderless)
        .help("VM IP — click to copy")
    }
}

private struct TabCapsule: View {
    let label: String
    let isActive: Bool
    let accentHex: String
    let onSelect: () -> Void
    let onClose:  () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .lineLimit(1)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .background(hovering ? Color.gray.opacity(0.2) : .clear, in: Circle())
            }
            .buttonStyle(.borderless)
            .opacity(isActive || hovering ? 1 : 0.55)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(
                isActive
                ? Color(nsColor: .textBackgroundColor)
                : (hovering ? Color.gray.opacity(0.10) : .clear)
            )
        )
        .overlay(
            Capsule().strokeBorder(
                isActive ? Color(hex: accentHex).opacity(0.55) : .clear,
                lineWidth: 1.5
            )
        )
        .contentShape(Capsule())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}

// MARK: - Helpers

extension ProfileColor {
    /// Hex form for use in the AppKit/SwiftUI mix.
    var hexInUI: String {
        switch self {
        case .blue:   "#3B82F6"
        case .red:    "#EF4444"
        case .green:  "#22C55E"
        case .orange: "#F97316"
        case .purple: "#A855F7"
        case .pink:   "#EC4899"
        case .teal:   "#14B8A6"
        case .gray:   "#6B7280"
        }
    }
}
