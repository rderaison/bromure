import ArgumentParser
import Cocoa
import Crypto
import Foundation
import SandboxEngine
import Sparkle
import SwiftUI
@preconcurrency import Virtualization

/// SPM resource bundle, with a fallback for the .app layout. SPM's
/// auto-generated `Bundle.module` looks for the bundle next to
/// `Bundle.main.bundleURL` (the .app root), but codesign requires
/// resources under `Contents/Resources/`. Reading `Bundle.module`
/// directly traps on a fresh-system .app launch — check the resource
/// dir first and only fall back to `Bundle.module` for `swift run`.
let acResourceBundle: Bundle = {
    let bundleName = "bromure_bromure-ac"
    if let resourceURL = Bundle.main.resourceURL,
       let bundle = Bundle(url: resourceURL.appendingPathComponent("\(bundleName).bundle")) {
        return bundle
    }
    return Bundle.module
}()

@main
struct BromureAC: ParsableCommand {
    /// Built from the invocation name (argv[0]). Invoked as `bromure-cli` we
    /// hide the app-internal commands — Image management (init/info/reset, which
    /// can bounce into the in-app GUI setup flow) and the `mcp` stdio server —
    /// and expose no GUI default, so a bare or unknown invocation prints help
    /// instead of trapping while NSApplication tries to start. Invoked as
    /// `bromure-ac` (the app binary and every child it spawns) everything is
    /// available. `commandName` echoes the actual argv[0] so USAGE reads right.
    static var configuration: CommandConfiguration {
        let argv0 = URL(fileURLWithPath: CommandLine.arguments.first ?? "").lastPathComponent
        let name = argv0.isEmpty ? "bromure-ac" : argv0
        let asCLI = (name == "bromure-cli")

        // Qualified: `CommandGroup` is ambiguous here (SwiftUI also defines one).
        var groups: [ArgumentParser.CommandGroup] = []
        if !asCLI {
            groups.append(ArgumentParser.CommandGroup(name: "Image management",
                                       subcommands: [Init.self, Info.self, Reset.self]))
        }
        groups.append(ArgumentParser.CommandGroup(name: "Workspaces", subcommands: [Profiles.self]))
        groups.append(ArgumentParser.CommandGroup(name: "Tracing", subcommands: [Trace.self]))
        groups.append(ArgumentParser.CommandGroup(name: "Local inference", subcommands: [Model.self]))
        groups.append(ArgumentParser.CommandGroup(name: "Enterprise features",
                                   subcommands: [Enroll.self, Unenroll.self, Status.self]))
        groups.append(ArgumentParser.CommandGroup(name: "Integration",
                                   subcommands: asCLI ? [Remote.self] : [MCP.self, Remote.self]))

        // `run` (the GUI) + `__remote-menu` (SSH ForceCommand target) are
        // app-internal; bromure-cli exposes neither and has no GUI default.
        let topLevel: [ParsableCommand.Type] = asCLI ? [] : [Run.self, RemoteMenu.self]
        let defaultCmd: ParsableCommand.Type? = asCLI ? nil : Run.self
        return CommandConfiguration(
            commandName: name,
            abstract: "Run Codex / Claude Code in an isolated, persistent VM.",
            subcommands: topLevel,
            groupedSubcommands: groups,
            defaultSubcommand: defaultCmd)
    }

    /// Strip Apple-internal flags (e.g. -AppleLanguages, -AppleLocale) from
    /// CommandLine.arguments so ArgumentParser doesn't reject them. Without
    /// this, `bromure-ac -AppleLanguages "(fr)"` exits with "Unknown option"
    /// before NSApplication starts. Mirrors the browser entry point.
    static func main() {
        let invokedName = URL(fileURLWithPath: CommandLine.arguments.first ?? "").lastPathComponent
        let args = Array(CommandLine.arguments.dropFirst())
        var filtered: [String] = []
        var skipNext = false
        for arg in args {
            if skipNext { skipNext = false; continue }
            if arg.hasPrefix("-Apple") { skipNext = true; continue }
            filtered.append(arg)
        }
        // Invoked as `bromure-cli` (the /usr/local/bin symlink → this binary)
        // with no subcommand: print help instead of falling through to the GUI
        // default subcommand (Run), which traps when there's no .app bundle to
        // host NSApplication. The .app's own `bromure-ac` binary keeps its GUI
        // default. (Bug#4.)
        if filtered.isEmpty, invokedName == "bromure-cli" {
            filtered = ["help"]
        }
        Self.main(filtered)
    }
}

// MARK: - init

struct Init: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Build the Ubuntu base image (one-time, ~10 min)."
    )

    func run() throws {
        let imageManager = try makeImageManager()
        // The build path keeps the existing image usable until the
        // new one is ready (writes go to .partial files, then atomic
        // swap), so we don't pre-delete the version stamp. `init` is
        // an explicit user verb — if they typed it, they want the
        // image rebuilt — so always pass force=true. The earlier
        // `--force` flag was redundant.
        // Pump the main RunLoop while an async Task does the actual build.
        // We can't `semaphore.wait()` here because `runInstaller` is
        // @MainActor — a sync block of the main thread starves the main
        // actor's executor and the install hangs at the first MainActor hop.
        // Driving the RunLoop instead lets MainActor continuations run.
        var result: Result<Void, Error>?
        Task {
            do {
                try await imageManager.createBaseImage(
                    progress: { msg in
                        FileHandle.standardError.write(Data("[init] \(msg)\n".utf8))
                    },
                    force: true
                )
                result = .success(())
            } catch {
                result = .failure(error)
            }
        }
        while result == nil {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        try result!.get()
        print("Base image ready: \(imageManager.baseDiskURL.path)")
    }
}

// MARK: - info

struct Info: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Show information about the base image (version, size, path)."
    )

    func run() throws {
        let im = try makeImageManager()
        guard im.hasBaseImage else {
            print("No base image yet. Build it with `bromure-ac init`.")
            return
        }
        let version = (try? String(contentsOf: im.versionStampURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        let url = im.baseDiskURL
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        let apparent = (attrs[.size] as? NSNumber)?.int64Value
        let onDisk = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize
        func human(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
        print("Base image")
        print("  version:  \(version)")
        if let apparent { print("  size:     \(human(apparent)) (virtual)") }
        if let onDisk { print("  on disk:  \(human(Int64(onDisk)))") }
        print("  path:     \(url.path)")
    }
}

// MARK: - run

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Boot a session against the base image and open the display window.",
        shouldDisplay: false
    )

    @Flag(name: .long,
          help: "Run as a background agent (no window). Used by the CLI to autostart the VM service.")
    var headless = false

    func run() throws {
        let imageManager = try makeImageManager()
        // No base-image gate here. `ACAppDelegate.applicationDidFinishLaunching`
        // checks `imageManager.hasBaseImage` and routes to the in-app
        // setup flow (SetupView → InitializingView) when missing — same
        // path "Rebuild Base Image…" uses. Bouncing the user back to a
        // CLI invocation would defeat the point of having a GUI.

        // Sync subcommand + MainActor.assumeIsolated matches the browser
        // pattern. NSApplication.run() needs to drive the main RunLoop
        // directly; running it inside an async context (`AsyncParsableCommand`
        // + `MainActor.run`) wedges the run loop and the app never appears.
        let headless = self.headless
        MainActor.assumeIsolated {
            FileHandle.standardError.write(Data(
                "[run] launching NSApplication\(headless ? " (headless agent)" : "")…\n".utf8))
            let app = NSApplication.shared
            app.setActivationPolicy(headless ? .accessory : .regular)

            let delegate = ACAppDelegate(imageManager: imageManager, headless: headless)
            app.delegate = delegate
            app.mainMenu = makeMainMenu(delegate: delegate)

            app.run()
        }
    }
}

/// Minimal app menu so ⌘-Q, ⌘-W, etc. work, plus a standard Edit menu so
/// Cut/Copy/Paste/Select-All function in text fields.
@MainActor
private func makeMainMenu(delegate: ACAppDelegate) -> NSMenu {
    let main = NSMenu()
    let appMenuItem = NSMenuItem()
    main.addItem(appMenuItem)

    let appMenu = NSMenu()
    appMenuItem.submenu = appMenu

    // Prefer the bundle's display name (Info.plist CFBundleDisplayName /
    // CFBundleName) over `processName`, which returns the executable
    // file name ("bromure-ac") rather than the user-facing app name.
    let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
        ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
        ?? ProcessInfo.processInfo.processName
    let L = { (k: String) in NSLocalizedString(k, comment: "") }
    appMenu.addItem(withTitle: String(format: L("About %@"), appName),
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                    keyEquivalent: "")
    appMenu.addItem(NSMenuItem.separator())

    let prefsItem = NSMenuItem(title: L("Preferences…"),
                                action: #selector(ACAppDelegate.openPreferencesAction(_:)),
                                keyEquivalent: ",")
    prefsItem.target = delegate
    appMenu.addItem(prefsItem)

    let remoteItem = NSMenuItem(title: L("Remote Access…"),
                                action: #selector(ACAppDelegate.openRemoteAccessAction(_:)),
                                keyEquivalent: "")
    remoteItem.target = delegate
    appMenu.addItem(remoteItem)

    let rebuildItem = NSMenuItem(title: L("Rebuild Base Image…"),
                                 action: #selector(ACAppDelegate.rebuildBaseImageAction(_:)),
                                 keyEquivalent: "")
    rebuildItem.target = delegate
    appMenu.addItem(rebuildItem)

    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(withTitle: String(format: L("Hide %@"), appName),
                    action: #selector(NSApplication.hide(_:)),
                    keyEquivalent: "h")
    let hideOthers = NSMenuItem(title: L("Hide Others"),
                                action: #selector(NSApplication.hideOtherApplications(_:)),
                                keyEquivalent: "h")
    hideOthers.keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(hideOthers)
    appMenu.addItem(withTitle: L("Show All"),
                    action: #selector(NSApplication.unhideAllApplications(_:)),
                    keyEquivalent: "")
    appMenu.addItem(NSMenuItem.separator())
    appMenu.addItem(withTitle: String(format: L("Quit %@"), appName),
                    action: #selector(NSApplication.terminate(_:)),
                    keyEquivalent: "q")

    // Edit menu — without these items, the responder chain has no
    // Cut/Copy/Paste/Select-All hooks and ⌘V silently fails inside
    // text fields (SecureField especially). Standard idioms; targets
    // are nil so they go to first responder.
    let editMenuItem = NSMenuItem()
    main.addItem(editMenuItem)
    let editMenu = NSMenu(title: L("Edit"))
    editMenuItem.submenu = editMenu
    editMenu.addItem(withTitle: L("Undo"),
                     action: Selector(("undo:")),
                     keyEquivalent: "z")
    let redoItem = NSMenuItem(title: L("Redo"),
                              action: Selector(("redo:")),
                              keyEquivalent: "z")
    redoItem.keyEquivalentModifierMask = [.command, .shift]
    editMenu.addItem(redoItem)
    editMenu.addItem(NSMenuItem.separator())
    editMenu.addItem(withTitle: L("Cut"),
                     action: #selector(NSText.cut(_:)),
                     keyEquivalent: "x")
    editMenu.addItem(withTitle: L("Copy"),
                     action: #selector(NSText.copy(_:)),
                     keyEquivalent: "c")
    editMenu.addItem(withTitle: L("Paste"),
                     action: #selector(NSText.paste(_:)),
                     keyEquivalent: "v")
    editMenu.addItem(withTitle: L("Select All"),
                     action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")

    let windowMenuItem = NSMenuItem()
    main.addItem(windowMenuItem)
    let windowMenu = NSMenu(title: L("Window"))
    windowMenuItem.submenu = windowMenu
    windowMenu.addItem(withTitle: L("Minimize"),
                       action: #selector(NSWindow.performMiniaturize(_:)),
                       keyEquivalent: "m")
    windowMenu.addItem(withTitle: L("Close"),
                       action: #selector(NSWindow.performClose(_:)),
                       keyEquivalent: "w")
    windowMenu.addItem(NSMenuItem.separator())
    let pickerItem = NSMenuItem(title: L("Workspace Manager"),
                                action: #selector(ACAppDelegate.openProfileManagerAction(_:)),
                                keyEquivalent: "0")
    pickerItem.target = delegate
    windowMenu.addItem(pickerItem)
    let inspectorItem = NSMenuItem(title: L("Trace Inspector…"),
                                   action: #selector(ACAppDelegate.openTraceInspectorAction(_:)),
                                   keyEquivalent: "i")
    inspectorItem.keyEquivalentModifierMask = [.command, .shift]
    inspectorItem.target = delegate
    windowMenu.addItem(inspectorItem)

    let metricsItem = NSMenuItem(title: L("Inference Metrics…"),
                                 action: #selector(ACAppDelegate.openInferenceMetricsAction(_:)),
                                 keyEquivalent: "")
    metricsItem.target = delegate
    windowMenu.addItem(metricsItem)

    let approvalsItem = NSMenuItem(title: L("Credential Approvals…"),
                                   action: #selector(ACAppDelegate.openCredentialApprovalsAction(_:)),
                                   keyEquivalent: "")
    approvalsItem.target = delegate
    windowMenu.addItem(approvalsItem)

    let supplyChainLogItem = NSMenuItem(title: L("Security Log…"),
                                        action: #selector(ACAppDelegate.openSupplyChainLogAction(_:)),
                                        keyEquivalent: "")
    supplyChainLogItem.target = delegate
    windowMenu.addItem(supplyChainLogItem)

    let inferenceLogItem = NSMenuItem(title: L("Inference Engine Log…"),
                                      action: #selector(ACAppDelegate.openInferenceLogAction(_:)),
                                      keyEquivalent: "")
    inferenceLogItem.target = delegate
    windowMenu.addItem(inferenceLogItem)
    // The bromure.io Enrollment item is added to the *app* menu (next
    // to Check for Updates…) rather than here — see
    // `ACAppDelegate.installEnrollmentMenuItem(into:)`, called from
    // applicationDidFinishLaunching once the updater item exists.

    // Hand the menu to NSApp so AppKit auto-appends entries for every
    // titled, non-excluded window. Session windows already get
    // meaningful titles (claude / codex / vim / bash / etc.) so they
    // appear here as the user opens them — Picker / Trace Inspector /
    // session windows all routable from one place.
    NSApp.windowsMenu = windowMenu
    return main
}

/// A running VM session, owned by `ACAppDelegate.runningSessions` and keyed
/// by profile id. Decouples VM lifetime from any window: a session keeps
/// running while no window is attached (the persistent-agent / "tmux server"
/// model). The attached window, when present, lives in `profileWindows[id]`.
@MainActor
final class RunningSession {
    let profileID: Profile.ID
    /// Live profile copy; kept in sync when the user saves the editor.
    var profile: Profile
    /// The VM. Strong owner — this is what keeps the VZVirtualMachine alive
    /// independent of any window.
    var sandbox: UbuntuSandboxVM
    /// When the VM booted — surfaced as uptime in `vm ls`.
    let startedAt: Date
    /// Last tab snapshot, captured on detach so a reattaching window can
    /// rebuild its bar against the kittys still running inside the guest.
    var lastTabsSnapshot: SessionDisk.TabsState?
    /// Last IP reported by the guest, mirrored here so a reattaching (or
    /// headless) session can render it without a window.
    var lastIP: String?
    /// The guest's tmux window list (tabs), mirrored from the roster so
    /// `vm ls` / the API can show tabs even while the session is detached.
    /// Each entry is (window index, foreground command, is-active).
    var tabs: [(index: Int, label: String, active: Bool)] = []
    /// Fusion engaged state, mirrored from the engine so a reattaching
    /// window restores the toolbar toggle correctly.
    var fusionEngaged: Bool = false
    /// True once an explicit stop is in flight, so the VM-stopped callback
    /// doesn't double-run teardown.
    var stopping: Bool = false

    init(profileID: Profile.ID, profile: Profile, sandbox: UbuntuSandboxVM) {
        self.profileID = profileID
        self.profile = profile
        self.sandbox = sandbox
        self.startedAt = Date()
    }
}

/// App delegate for `bromure-ac run`. Hosts the profile picker, the
/// create-profile wizard, and (once a profile launches) the
/// VZVirtualMachineView for that session.
@MainActor
final class ACAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let imageManager: UbuntuImageManager
    let store = ProfileStore()
    var profiles: [Profile] = [] {
        didSet {
            // Single funnel: every assignment to `profiles` (load,
            // save, delete, restore) flows through here, so the
            // private-profile set on the cloud emitter and any open
            // session window's streaming indicator stay in lockstep
            // with the latest store state.
            refreshStreamingState()
        }
    }

    /// Snapshot of Terminal.app's default profile captured at app launch.
    /// Cached so changes the user makes to Terminal.app while AC is
    /// running don't surprise them mid-session.
    let terminalDefaults: TerminalAppDefaults = TerminalAppDefaults.load()

    /// Internal so the AppleScript bridge can read window IDs.
    var mainWindow: NSWindow?
    var editorWindow: NSWindow?
    private var sshWindow: NSWindow?
    private var editorEditingProfile: Profile?  // nil = creating

    /// One *attached* window per profile. Each window holds N tabs, all
    /// rendering the same VM. Note this is only the windows currently on
    /// screen — a running VM with no window lives in `runningSessions`.
    ///
    /// Holds only *popped-out* single-VM windows now; panes shown in the
    /// shared `unifiedWindow` are tracked by `panes` instead. Most lookups go
    /// through `pane(for:)`, which spans both hosts.
    private var profileWindows: [Profile.ID: TabbedSessionWindow] = [:]

    /// The shared multi-VM window (unpeel-style: a source-list of every running
    /// VM with its tabs nested, and one framebuffer stage). Created lazily on
    /// the first non-detached launch. Popped-out VMs leave it for their own
    /// `TabbedSessionWindow`.
    var unifiedWindow: UnifiedSessionWindow?

    /// Every `SessionPane` currently displayed somewhere — in `unifiedWindow`
    /// or a popped-out `profileWindows` entry. This is the dispatch target for
    /// guest events (tab list, IP, shortcuts, tint), so it works regardless of
    /// which window draws the pane. nil for a detached/headless session.
    private var panes: [Profile.ID: SessionPane] = [:]

    /// Per-VM auto-clear timers for the `thinking` animation (re-armed on each
    /// model conversation request, fires a few seconds after the last one).
    private var thinkingClearTasks: [Profile.ID: Task<Void, Never>] = [:]

    /// The pane currently showing `id`'s VM, in whichever window hosts it.
    func pane(for id: Profile.ID) -> SessionPane? { panes[id] }

    /// Register a pane as the live UI surface for its profile. Called by every
    /// host (the unified window and popped-out windows) when it starts drawing
    /// a pane.
    func registerPane(_ pane: SessionPane) {
        panes[pane.profile.id] = pane
    }

    /// Drop a pane from the dispatch registry — but only if it's still the
    /// registered one (a re-host may have already replaced it).
    func unregisterPane(_ id: Profile.ID, ifMatches pane: SessionPane? = nil) {
        if let pane, panes[id] !== pane { return }
        panes.removeValue(forKey: id)
    }

    /// True when the profile has a visible UI surface (a hosted pane), whether
    /// in the unified window or a popped-out one. Replaces the old
    /// `profileWindows[id] != nil` "is it on screen" check.
    func isAttached(_ id: Profile.ID) -> Bool { panes[id] != nil }

    /// The window currently drawing `id`'s pane (unified or popped-out), if any.
    func hostWindow(for id: Profile.ID) -> NSWindow? {
        panes[id]?.host?.paneHostWindow
    }

    /// Lazily build the shared unified (multi-VM) window.
    func ensureUnifiedWindow() -> UnifiedSessionWindow {
        if let w = unifiedWindow { return w }
        let w = UnifiedSessionWindow(acDelegate: self)
        w.delegate = self
        w.center()
        w.isReleasedWhenClosed = false
        unifiedWindow = w
        return w
    }

    /// Bring the profile's host window forward and select its pane.
    func revealSession(_ id: Profile.ID) {
        guard let pane = panes[id], let host = pane.host?.paneHostWindow else { return }
        (host as? UnifiedSessionWindow)?.select(profileID: id)
        NSApp.setActivationPolicy(.regular)
        host.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Detach a profile's pane to headless — the VM keeps running, the UI goes
    /// away. Snapshots the tab bar so a later reattach rebuilds it. This is the
    /// "close the window but keep the agent" path of the persistent-agent model.
    func detachSession(_ id: Profile.ID) {
        guard let pane = panes[id] else { return }
        if runningSessions[id] != nil {
            runningSessions[id]?.lastTabsSnapshot = pane.snapshotTabs()
        }
        pane.vmView.virtualMachine = nil
        pane.keyboardBridge = nil
        pane.scrollBridge = nil
        pane.sandbox = nil
        if let unified = pane.host as? UnifiedSessionWindow {
            unified.removePane(id)
        } else if let win = profileWindows[id] {
            profileWindows.removeValue(forKey: id)
            win.orderOut(nil)
        }
        unregisterPane(id, ifMatches: pane)
        refreshSidebar()
        updateStatusMenu()
        updateActivationPolicy()
    }

    /// Close a VM from the sidebar's × / last-tab close: resolve the profile's
    /// close action (prompting for `.ask`) and either detach (background) or
    /// stop the VM (suspend / shutdown).
    func closeVMFromSidebar(_ id: Profile.ID) {
        guard let pane = panes[id] else { return }
        let pref = pane.profile.closeAction
        let action: Profile.CloseAction
        if pref == .ask {
            guard let chosen = promptCloseAction(forName: pane.profile.name) else { return }
            action = chosen
        } else {
            action = pref
        }
        switch action {
        case .background:
            detachSession(id)
        case .suspend, .shutdown:
            requestStopSession(id, action: action)
        case .ask:
            break
        }
    }

    /// Debug: render the unified window's content to a PNG (the app drawing
    /// itself — no Screen Recording permission needed) and dump subview frames.
    /// Lets the layout be verified headlessly.
    func debugRenderUnifiedWindow(to path: String) -> [String: Any] {
        debugRenderWindow(unifiedWindow, to: path)
    }

    func debugRenderWindow(_ win: NSWindow?, to path: String) -> [String: Any] {
        guard let win, let contentView = win.contentView else {
            return ["error": "no such window"]
        }
        // Render the whole window frame view (incl. titlebar + toolbar), not just
        // the content area, so the toolbar controls are captured too.
        let content = contentView.superview ?? contentView
        func frameDict(_ v: NSView) -> [String: Any] {
            ["x": Int(v.frame.minX), "y": Int(v.frame.minY),
             "w": Int(v.frame.width), "h": Int(v.frame.height)]
        }
        var dump: [String: Any] = [
            "windowVisible": win.isVisible,
            "windowFrame": ["w": Int(win.frame.width), "h": Int(win.frame.height)],
            "content": frameDict(content),
            "subviews": content.subviews.map { sv -> [String: Any] in
                var d = frameDict(sv)
                d["class"] = String(describing: type(of: sv))
                return d
            },
        ]
        let bounds = content.bounds
        if bounds.width > 0, bounds.height > 0,
           let rep = content.bitmapImageRepForCachingDisplay(in: bounds) {
            content.cacheDisplay(in: bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
                dump["png"] = path
                dump["pngBytes"] = data.count
            }
        }
        return dump
    }

    /// AppleScript bridge: sessions currently on screen (hosted pane whose
    /// window is visible), spanning the unified window + any pop-outs.
    func scriptVisibleSessions() -> [(profileID: UUID, name: String, windowID: Int, visible: Bool)] {
        runningSessions.values.compactMap { s in
            guard let host = hostWindow(for: s.profileID), host.isVisible else { return nil }
            return (s.profileID, s.profile.name, host.windowNumber, true)
        }
    }

    /// AppleScript bridge: close the on-screen session for a profile. Returns
    /// false when nothing is shown for it.
    @discardableResult
    func scriptCloseSession(_ id: Profile.ID) -> Bool {
        guard isAttached(id) else { return false }
        closeVMFromSidebar(id)
        return true
    }

    /// File browser opened from the unified window's header (per selected VM).
    func openFileBrowserForUnified(_ id: Profile.ID) {
        guard let pane = panes[id] else { return }
        openFileBrowser(profile: pane.profile)
    }

    /// Boot (or focus) the profile with this id — wired to the dropdown.
    func startProfile(_ id: Profile.ID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        launch(profile)
    }

    /// Picker "Stop": power the VM down, honoring `.shutdown` but mapping the
    /// keep-running actions (`.background`/`.ask`) to `.suspend` so Stop always
    /// actually stops.
    func stopProfile(_ id: Profile.ID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        let action: Profile.CloseAction = profile.closeAction == .shutdown ? .shutdown : .suspend
        requestStopSession(id, action: action)
    }

    /// Picker "Restart": power off (clearing saved state) then boot fresh.
    func restartProfile(_ id: Profile.ID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        Task { @MainActor in
            if runningSessions[id] != nil {
                await stopSession(id, action: .shutdown)
            }
            launch(profile)
        }
    }

    /// Picker "Connect/Show": surface a running VM — attaches a window if it's
    /// detached, or brings the existing one to the front.
    func connectProfile(_ id: Profile.ID) {
        guard let session = runningSessions[id] else { return }
        attachWindow(to: session)
    }

    // MARK: - Unified window source list

    /// Rebuild the unified window's profile list (all profiles + run state).
    /// Replaces the old picker render — called wherever the profile set or a
    /// session's state changes. No-op until the unified window exists.
    func refreshSidebar() {
        guard let w = unifiedWindow else { return }
        w.listModel.profileRows = profiles.map { p in
            SessionListModel.ProfileRow(
                id: p.id,
                name: p.name,
                accentHex: p.color.hexInUI,
                state: runState(for: p),
                compromised: SessionDisk.isCompromised(profile: p, store: store))
        }
    }

    /// Coarse run state for a profile, for the source-list badge: a live VM is
    /// running/booting; otherwise a saved snapshot on disk means suspended,
    /// else it's off.
    private func runState(for profile: Profile) -> SessionListModel.RunState {
        if let session = runningSessions[profile.id] {
            switch session.sandbox.state {
            case .running:            return .running
            case .starting, .created: return .booting
            case .stopped, .error:    break   // fall through to the disk check
            }
        }
        let disk = SessionDisk(profile: profile, store: store,
                               baseDiskURL: imageManager.baseDiskURL)
        return disk.hasSavedState ? .suspended : .off
    }

    // Id-based wrappers so the sidebar's ⋯ menu can drive the Profile-typed
    // handlers without holding the Profile itself.
    func sidebarEditProfile(_ id: Profile.ID) {
        if let p = profiles.first(where: { $0.id == id }) { openEditorWindow(editing: p) }
    }
    func sidebarDuplicateProfile(_ id: Profile.ID) {
        if let p = profiles.first(where: { $0.id == id }) { duplicateProfile(p) }
    }
    func sidebarResetProfile(_ id: Profile.ID) {
        if let p = profiles.first(where: { $0.id == id }) { resetProfile(p) }
    }
    func sidebarDeleteProfile(_ id: Profile.ID) {
        if let p = profiles.first(where: { $0.id == id }) { deleteProfile(p) }
    }

    /// The MITM proxy saw a model *conversation* request for this profile — the
    /// agent is working. Flip the VM's `thinking` flag (driving the animated
    /// sidebar dots) and re-arm a timer to clear it once calls stop.
    func noteAgentActivity(_ id: Profile.ID) {
        pane(for: id)?.model.thinking = true
        thinkingClearTasks[id]?.cancel()
        thinkingClearTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.pane(for: id)?.model.thinking = false
            self?.thinkingClearTasks[id] = nil
        }
    }

    /// Pop a VM out of the unified window into its own standalone window. The
    /// pane keeps the same VM (no teardown); it just changes host. Implemented
    /// in the pop-out phase.
    func popOutVM(_ id: Profile.ID) {
        guard let pane = panes[id], pane.host is UnifiedSessionWindow else { return }
        // Move the pane's view out of the unified window first (keeps the VM +
        // dispatch registration; just unmounts the container view).
        unifiedWindow?.removePane(id)
        let win = TabbedSessionWindow(adopting: pane, acDelegate: self)
        win.delegate = self
        win.center()
        win.isReleasedWhenClosed = false
        profileWindows[id] = win
        registerPane(pane)   // host changed; keep dispatch pointed at this pane
        NSApp.setActivationPolicy(.regular)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateStatusMenu()
    }

    /// Re-dock a popped-out VM back into the unified window.
    func redockVM(_ id: Profile.ID) {
        guard let win = profileWindows[id] else { return }
        let pane = win.pane
        profileWindows.removeValue(forKey: id)
        win.releasePaneForRedock()
        win.close()
        let unified = ensureUnifiedWindow()
        unified.addPane(pane)
        NSApp.setActivationPolicy(.regular)
        unified.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        updateStatusMenu()
    }

    /// VM sessions that are *running*, keyed by profile id — the canonical
    /// owner of each `UbuntuSandboxVM`. Distinct from `profileWindows`
    /// (only the *attached* windows): a session can run with no window
    /// attached (detached / headless). The persistent-agent model — where
    /// VMs survive the GUI being closed — hangs off this split.
    var runningSessions: [Profile.ID: RunningSession] = [:]

    /// Profiles created with `vm run --rm`: deleted (profile + disk) when their
    /// VM stops, mirroring `docker run --rm`.
    private var ephemeralProfiles: Set<Profile.ID> = []

    /// The running VM for a profile, or nil if it isn't running. The control
    /// plane (and any window-less caller) resolves a profile's VM through here.
    func sandbox(for id: Profile.ID) -> UbuntuSandboxVM? {
        runningSessions[id]?.sandbox
    }

    /// Register (or update) the running session for a profile. The registry
    /// is the strong owner that keeps the VM alive independent of any window.
    @discardableResult
    func registerSession(_ sandbox: UbuntuSandboxVM, profile: Profile) -> RunningSession {
        if let existing = runningSessions[profile.id] {
            existing.sandbox = sandbox
            existing.profile = profile
            return existing
        }
        let session = RunningSession(profileID: profile.id, profile: profile, sandbox: sandbox)
        runningSessions[profile.id] = session
        updateStatusMenu()
        // Boot completes asynchronously after the launch path's initial render,
        // so refresh the picker now that the VM is actually running (Start →
        // Stop/Restart/Connect).
        refreshSidebar()
        return session
    }

    /// Drop the registry's strong reference to a profile's VM. The VM
    /// deallocates once any in-flight stop/suspend task also releases it
    /// (its `deinit` then detaches the vmnet switch port).
    func unregisterSession(_ id: Profile.ID) {
        runningSessions.removeValue(forKey: id)
        updateStatusMenu()
    }

    /// NSEvent monitor that intercepts ⌘T / ⌘W / ⌘1-9 at the
    /// application level — before the responder chain, before the
    /// VZ view's keyDown forwards them to the guest. Returning nil
    /// from the handler is what consumes the event; see the closure
    /// in applicationDidFinishLaunching for why we don't `?? event`.
    private var keyMonitor: Any?

    /// Progress model for the in-app `init` flow (first-time setup or
    /// version-bump rebuild).
    private let initProgress = InitProgressModel()

    /// Retained handle to the in-flight base-image build Task. Used to
    /// cancel cleanly when the user confirms a close mid-install —
    /// otherwise the Task keeps pushing model updates after the window
    /// is gone and the autorelease pool over-releases on the next tick.
    private var installTask: Task<Void, Never>?
    private var ssoRefreshTasks: [UUID: Task<Void, Never>] = [:]

    /// Strong references to the dispatch sources catching abnormal-
    /// exit signals. Without retaining these the sources deallocate
    /// and we silently drop back to the default disposition (= die).
    private var cleanupSignalSources: [DispatchSourceSignal] = []

    /// Optional HTTP automation server. Started in applicationDidFinishLaunching
    /// when `automation.enabled` (UserDefaults) is true. Defaults to OFF —
    /// the user enables it explicitly via Bromure → Preferences →
    /// Automation, or via `defaults write io.bromure.agentic-coding
    /// automation.enabled -bool true`. Tests/ac-e2e.mjs sets this before
    /// launching the app.
    private var automationServer: ACAutomationServer?
    /// Always-on owner-only Unix control socket for the `bromure-ac` CLI.
    private var controlServer: ACAutomationServer?

    /// Menu-bar item. The only UI surface once every window closes and the
    /// app demotes to `.accessory` — lists running VMs and offers Quit so a
    /// fully-detached agent stays reachable.
    private var statusItem: NSStatusItem?

    /// Process-lifetime MITM engine. One instance per app run, holds
    /// the CA + per-profile token swap maps + ssh-agent keystore. Lazy
    /// because CA generation hits disk on first access.
    lazy var mitmEngine: MitmEngine? = {
        do {
            let e = try MitmEngine()
            // The proxy's conversation-request signal drives the sidebar's
            // animated "thinking" dots.
            e.traceStore.onConversationActivity = { [weak self] pid in
                self?.noteAgentActivity(pid)
            }
            return e
        }
        catch {
            FileHandle.standardError.write(Data(
                "[mitm] engine init failed: \(error) — sessions will run without proxy\n".utf8))
            return nil
        }
    }()

    /// SPM-resource-bundle path to the in-VM bridge script. Resolved
    /// once and copied into each session's meta share.
    lazy var bridgeScriptURL: URL? = {
        acResourceBundle.url(forResource: "vm-setup/bromure-vm-bridge",
                             withExtension: "py")
    }()

    /// SPM-resource-bundle path to the in-VM keyboard agent. Pushed
    /// into the meta share so xinitrc can launch it; the host-side
    /// `KeyboardBridge` then ferries macOS layout changes to it.
    lazy var keyboardAgentURL: URL? = {
        acResourceBundle.url(forResource: "vm-setup/keyboard-agent",
                             withExtension: "py")
    }()

    /// SPM-resource-bundle path to the in-VM scroll agent. Same
    /// pattern: dropped in the meta share, launched from xinitrc,
    /// fed by the host-side `ScrollBridge`.
    private lazy var scrollAgentURL: URL? = {
        acResourceBundle.url(forResource: "vm-setup/scroll-agent",
                             withExtension: "py")
    }()

    /// Build a `ScrollBridge` for a freshly-bound pane, honoring the
    /// `vm.terminalScroll` kill switch (default on). nil → fall back to VZ's
    /// native wheel path. Shared by every pane-binding site (warm boot,
    /// reattach, reboot) so the behavior can't drift between them.
    @MainActor private func makeScrollBridge(for sandbox: UbuntuSandboxVM) -> ScrollBridge? {
        guard let dev = sandbox.socketDevice,
              UserDefaults.standard.object(forKey: "vm.terminalScroll") as? Bool ?? true
        else { return nil }
        return ScrollBridge(socketDevice: dev)
    }

    /// SPM-resource-bundle path to the AWS `credential_process` helper.
    /// Shipped to /mnt/bromure-meta and referenced from the per-profile
    /// ~/.aws/config so the SDK pulls JSON creds from the host on demand.
    lazy var awsCredsHelperURL: URL? = {
        acResourceBundle.url(forResource: "vm-setup/bromure-aws-creds",
                             withExtension: "py")
    }()

    /// SPM-resource-bundle path to the Claude subscription-token agent.
    /// Dropped in the meta share, launched from xinitrc, talks vsock
    /// to host port 8446 (`SubscriptionTokenBridge`).
    lazy var claudeTokenAgentURL: URL? = {
        acResourceBundle.url(forResource: "vm-setup/claude-token-agent",
                             withExtension: "py")
    }()

    /// SPM-resource-bundle path to the Codex / ChatGPT
    /// subscription-token agent. Vsock port 8447, reads/writes
    /// ~/.codex/auth.json.
    lazy var codexTokenAgentURL: URL? = {
        acResourceBundle.url(forResource: "vm-setup/codex-token-agent",
                             withExtension: "py")
    }()

    /// SPM-resource-bundle path to the debug shell agent (vsock 5800).
    /// Dropped in the meta share and launched from xinitrc when the host
    /// runs with BROMURE_DEBUG_CLAUDE set — keeps the surface invisible
    /// in regular user sessions while powering the AutomationServer's
    /// /sessions/{id}/exec endpoint for tests.
    private lazy var shellAgentURL: URL? = {
        acResourceBundle.url(forResource: "vm-setup/shell-agent",
                             withExtension: "py")
    }()

    /// Loopback-callback relay (vsock 5010). Shipped in the meta share and
    /// started from xinitrc; lets OAuth logins inside the VM receive their
    /// 127.0.0.1 redirect callback from the host browser.
    lazy var loopbackRelayAgentURL: URL? = {
        acResourceBundle.url(forResource: "vm-setup/loopback-relay-agent",
                             withExtension: "py")
    }()

    /// Live host→guest loopback forwarders, one per detected OAuth login.
    /// They auto-expire (5 min); we also prune stopped ones on each new login.
    var loopbackForwarders: [LoopbackCallbackForwarder] = []
    /// In-flight "Register with Claude" throwaway session, if any. Held so the
    /// window-close handler can route to its teardown instead of the normal
    /// session cleanup, and to guard against launching two at once.
    var claudeRegistration: ClaudeRegistrationState?

    /// If `url` is an OAuth authorize URL whose `redirect_uri` is a loopback
    /// callback (`http://127.0.0.1:<port>` or `localhost`), return that port —
    /// the signal to bridge the host's loopback into the guest. Otherwise nil.
    /// Resolve a profile's Guardrails policy into the runtime config the MITM
    /// enforces — the kube mode plus the concrete kube API hostnames pulled
    /// from the profile's kubeconfigs.
    /// Build the per-session Fusion config from a profile, or nil if the
    /// profile isn't fusion-configurable (<2 usable providers). Legs = the
    /// selected set intersected with usable providers (falling back to all
    /// usable if the selection is too small); judge falls back to the first
    /// usable provider + engine default model.
    /// Push the profile's routing mode + hybrid policy knobs into the MITM
    /// engine at session launch (vLLM.md §4). The model label (catalog id
    /// or repo) is what the `served-by` trace marker shows.
    func applyRouting(_ engine: MitmEngine, for profile: Profile) {
        engine.setRouting(profile.modelRouting,
                          modelLabel: profile.activeModelID ?? "default",
                          hybrid: HybridConfig(profile: profile),
                          for: profile.id)
    }

    /// Start (or switch) the on-host vllm-mlx engine for a session that
    /// needs local inference — any tool in `.local` mode, or Local/Hybrid
    /// routing. Runs in the background so it warms while the VM boots; the
    /// guest reaches it once ready via the vsock-8446 bridge. No-op when the
    /// profile needs no local model. (Single-engine phase: one model.)
    /// Refresh the engine wheel only when the app version changed since the
    /// last successful refresh — i.e. right after a Sparkle update (which
    /// bumps CFBundleVersion and relaunches) or a fresh install. A new app
    /// build pins a newer engine, so this is when to pull it; gating on the
    /// version avoids re-resolving on every ordinary launch. The stored
    /// version is only advanced on success, so a failed refresh retries.
    @MainActor func refreshEngineIfAppUpdated() {
        let key = "bromure.lastEngineRefreshAppVersion"
        let current = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        guard current != UserDefaults.standard.string(forKey: key) else { return }
        guard EngineProvisioner.shared.isProvisioned else {
            // Nothing installed yet — the first `model install` fetches latest.
            UserDefaults.standard.set(current, forKey: key)
            return
        }
        Task.detached(priority: .background) {
            do {
                try await EngineProvisioner.shared.refreshToLatest()
                UserDefaults.standard.set(current, forKey: key)
                SupplyChainLog.shared.record("[inference] engine refreshed for app \(current)")
            } catch {
                SupplyChainLog.shared.record("[inference] post-update engine refresh failed: \(error)")
            }
        }
    }

    @MainActor func startLocalEngineIfNeeded(for profile: Profile) {
        let ids = profile.distinctLocalModelIDs
        guard !ids.isEmpty else { return }
        // Resolve each selected model to a registry entry (name = repo, so
        // existing model env/config keeps working). estMemGB = its weight
        // footprint for the engine's LRU budget.
        let models: [InferenceModel] = ids.map { id in
            let m = CatalogStore.shared.resolve(id)
            let repo = m?.repo ?? id
            let est = Int((m?.downloadGB ?? 8).rounded(.up))
            return InferenceModel(name: repo, repo: repo, estMemGB: est,
                                  toolParser: m?.toolParser ?? "auto",
                                  reasoningParser: m?.reasoningParser)
        }
        // Budget for parallel models: most of unified memory, leaving room
        // for the OS + the VMs. vllm-mlx evicts idle models LRU under this.
        let budget = max(8, HostMemory.unifiedMemoryGB() - 16)
        let pid = profile.id
        let label = models.first.map { CatalogStore.shared.resolve($0.repo)?.name ?? $0.repo } ?? ""
        // Map the `bromure-local` sentinel → this workspace's active model so the
        // guest agents resolve to it without a restart. Set synchronously (before
        // the engine warms) so a request that races the load still routes right.
        if let activeID = profile.activeModelID,
           let activeRepo = CatalogStore.shared.resolve(activeID)?.repo {
            InferenceRepairProxy.shared.setActiveModel(pid, repo: activeRepo)
        }
        pane(for: pid)?.model.engineStatus = .starting("Starting local engine…")
        Task.detached(priority: .userInitiated) {
            do {
                // Register this workspace's models; the engine serves the UNION
                // of all open workspaces. If an engine is already up for another
                // workspace, this adds our model to it (hot reconfigure) instead
                // of restarting and dropping the others.
                try await InferenceService.shared.setWorkspaceModels(
                    pid, models, memoryBudgetGB: budget)
                await MainActor.run { self.pane(for: pid)?.model.engineStatus = .ready(label) }
                InferenceLog.shared.record(
                    "[inference] engine serving \(models.map(\.repo).joined(separator: ", "))")
            } catch {
                await MainActor.run { self.pane(for: pid)?.model.engineStatus = .failed("\(error)") }
                InferenceLog.shared.record(
                    "[inference] engine start failed: \(error) — see the Inference Engine Log above for the reason")
            }
        }
    }

    func makeFusionConfig(for profile: Profile) -> Fusion.Config? {
        guard profile.fusionConfigurable else { return nil }
        let usable = profile.fusionUsableProviders   // cloud providers with creds
        var legs = Profile.Tool.allCases.filter {
            profile.fusionLegs.contains($0) && usable.contains($0)
        }
        // The local Fusion leg (a model served by the on-host engine).
        let localLegModel: String? = {
            guard let id = profile.fusionLocalLeg, !id.isEmpty else { return nil }
            return CatalogStore.shared.resolve(id)?.repo ?? id
        }()
        // Need ≥2 drafts to fuse (cloud legs + the local leg). If the user
        // under-specified, default to fusing every usable cloud provider.
        if legs.count + (localLegModel != nil ? 1 : 0) < 2 { legs = usable }

        var authModes: [Profile.Tool: Profile.AuthMode] = [:]
        for spec in profile.allToolSpecs { authModes[spec.tool] = spec.authMode }

        // Judge: the local engine, or a chosen cloud provider.
        let judgeLocal = profile.fusionJudgeLocal
        let judgeProvider = (profile.fusionJudgeProvider.flatMap { usable.contains($0) ? $0 : nil })
            ?? usable.first ?? .claude
        let judgeModel: String
        if judgeLocal {
            let id = profile.fusionJudgeModel ?? profile.fusionLocalLeg ?? ""
            judgeModel = CatalogStore.shared.resolve(id)?.repo ?? id
        } else {
            judgeModel = profile.fusionJudgeModel ?? Fusion.defaultJudgeModel
        }

        return Fusion.Config(legs: legs, judgeProvider: judgeProvider,
                             judgeModel: judgeModel, authModes: authModes,
                             legModels: [:], localLegModel: localLegModel, judgeLocal: judgeLocal)
    }

    static func makeGuardrailsConfig(for profile: Profile) -> GuardrailsConfig {
        let kubeHosts = Set(profile.kubeconfigs.compactMap {
            URL(string: $0.serverURL)?.host?.lowercased()
        })
        // Docker registry hosts the profile has creds for. "docker.io" is a
        // user-facing alias for the real Hub endpoints, so expand it.
        var dockerHosts = Set<String>()
        for reg in profile.dockerRegistries {
            let h = reg.host.lowercased()
            if h == "docker.io" || h == "index.docker.io" || h == "registry-1.docker.io" {
                dockerHosts.formUnion(["docker.io", "index.docker.io",
                                       "registry-1.docker.io", "auth.docker.io"])
            } else {
                dockerHosts.insert(h)
            }
        }
        // HTTPS-database guardrails: each configured endpoint contributes its
        // engine + (user-specified) host + per-endpoint mode.
        let databases = profile.httpDatabases.compactMap { db -> GuardrailsConfig.DBGuardrail? in
            let host = db.host.lowercased().trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, db.guardrail != .off else { return nil }
            return GuardrailsConfig.DBGuardrail(engine: db.engine, host: host, mode: db.guardrail)
        }
        let g = profile.guardrails
        return GuardrailsConfig(kubernetes: g.kubernetes, kubeHosts: kubeHosts,
                                aws: g.aws,
                                digitalOcean: g.digitalOcean,
                                docker: g.docker, dockerHosts: dockerHosts,
                                github: g.github, gitlab: g.gitlab, bitbucket: g.bitbucket,
                                databases: databases)
    }

    static func loopbackCallbackPort(from url: URL) -> UInt16? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let redirect = comps.queryItems?.first(where: { $0.name == "redirect_uri" })?.value,
              let rc = URLComponents(string: redirect),
              let host = rc.host?.lowercased(),
              host == "127.0.0.1" || host == "localhost",
              let port = rc.port, port > 0, port <= 65_535 else {
            return nil
        }
        return UInt16(port)
    }

    /// Per-profile shell bridges, populated when the user enables
    /// BROMURE_DEBUG_CLAUDE and a session is launched. The
    /// AutomationServer's `onGetShellConnection` callback reads from
    /// this map.
    private var shellBridges: [Profile.ID: ShellBridge] = [:]

    /// Sparkle auto-updater. Retained strongly — if this deallocates,
    /// scheduled update checks stop firing. Initialised in
    /// applicationDidFinishLaunching. Silently no-ops on dev builds where
    /// SUPublicEDKey isn't populated.
    private var updaterController: SPUStandardUpdaterController?


    /// When true the app launches as a background agent: no picker window, just
    /// the control socket + status item + MITM engine. Used by the CLI's
    /// autostart (`bromure-ac run --headless`).
    let headless: Bool

    init(imageManager: UbuntuImageManager, headless: Bool = false) {
        self.imageManager = imageManager
        self.headless = headless
        super.init()
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        profiles = store.loadAll()
        // Menu-bar item: the persistent surface for reattaching / stopping VMs
        // once all windows close and the app demotes to a background agent.
        setupStatusItem()
        // Always-on Unix control socket for the `bromure-ac` CLI (exec / vm …).
        startControlSocket()

        // Persist the in-process DHCP server's leases so a profile's VM — which
        // already has a stable per-profile MAC (MACBindings) — keeps the same IP
        // across agent restarts, as often as the address stays free.
        let acSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BromureAC", isDirectory: true)
        VMNetSwitch.shared.enablePersistentLeases(
            at: acSupport.appendingPathComponent("dhcp-leases.sqlite"))

        // Offer to install the `bromure-cli` command-line tool (admin prompt).
        // Deferred so the main window appears first; no-op for the headless agent.
        DispatchQueue.main.async { [weak self] in self?.offerCLISymlinkIfNeeded() }

        // Refresh the MLX model catalog from the hosted manifest in the
        // background (vLLM.md §5.1). Non-fatal — falls back to the bundled
        // catalog.json on any network failure, so this never blocks launch.
        Task.detached(priority: .background) { await CatalogStore.shared.refresh() }

        // Surface any model download a previous crash/kill left half-finished as
        // a resumable entry in the Local Models picker (Bug#2). GUI only.
        if !headless {
            Task { @MainActor in ModelDownloadManager.shared.detectInterrupted() }
        }

        // Reap any vllm-mlx engine orphaned by a previous hard kill before we
        // start our own (it can hold tens of GB of unified memory).
        Task.detached(priority: .background) { InferenceService.reapOrphans() }

        // Refresh the engine wheel when the app itself was updated (Sparkle
        // bumps CFBundleVersion + relaunches): a new app build ships a new
        // pinned engine, so pull it then. Gated on the version changing so we
        // don't re-resolve on every ordinary launch. Background + non-fatal.
        refreshEngineIfAppUpdated()

        // Keep the login LaunchAgent in sync, then (headless login agent only)
        // boot any profiles flagged "Start at login".
        reconcileBootLaunchAgent()
        DispatchQueue.main.async { [weak self] in self?.bootFlaggedProfilesAtStartup() }

        // Default SSH key: every new profile inherits this keypair via
        // the user's preferences template. Generate it on first launch
        // (idempotent — `ensureExists` no-ops when the files are
        // already on disk), then make sure the template carries the
        // matching public key so a freshly forked profile shows it in
        // the editor without ticking the "Generate" toggle.
        do {
            try DefaultSSHKey.ensureExists()
            let pub = try DefaultSSHKey.publicKeyText()
            var template = store.loadTemplate()
            if template.sshPublicKey != pub {
                template.sshPublicKey = pub
                try? store.saveTemplate(template)
            }
        } catch {
            FileHandle.standardError.write(Data(
                "[ssh] default key bootstrap failed: \(error)\n".utf8))
        }

        // Sparkle: kick off scheduled update checks against the
        // release-agentic-coding appcast (separate channel from the
        // browser product). Started before the menu so the "Check for
        // Updates…" item has a live target.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // Re-install the main menu now that updaterController is alive
        // so the menu item built in `makeMainMenu` (called via the Run
        // command, before this delegate ran) gets a fresh copy with the
        // updater wired in.
        if let menu = NSApp.mainMenu, let appMenu = menu.item(at: 0)?.submenu {
            installCheckForUpdatesMenuItem(into: appMenu)
            // Slot the bromure.io enrollment item right under Check for
            // Updates… so admins find both deployment-touching items in
            // the same place. Idempotent and safe even when the updater
            // isn't initialised (dev builds): it falls back to inserting
            // just after About.
            installEnrollmentMenuItem(into: appMenu)
        }

        // Start the bromure.io heartbeat right away if this Mac is
        // enrolled. The first ping fires inside the background task
        // (no extra latency on the launch path), and the periodic
        // schedule keeps `last_seen_at` fresh on the admin UI. No-op
        // when not enrolled.
        BACHeartbeat.shared.start()
        // Per-install egress-IP heartbeat — mirrors the Bromure Web
        // Chromium extension, ticks every 60s against
        // analytics.bromure.io/register-ip so install_ips reflects
        // the Mac's current public IP. Also no-ops when not enrolled.
        BACIPRegister.shared.start()
        // Same lifecycle for the cloud event uploader: stand it up
        // once, the emitter itself short-circuits when there's no
        // install identity. Credential hooks + the LLM extractor can
        // call into it from the moment the proxy starts intercepting.
        if BACEnrollmentStore.load() != nil {
            BACEventEmitter.shared.ensureUploader()
        }
        BACEnrollment.onStateChange = { [weak self] in
            // Restart so a fresh enrollment kicks off heartbeats
            // immediately, and an unenroll stops them.
            BACHeartbeat.shared.stop()
            BACIPRegister.shared.stop()
            if BACEnrollmentStore.load() != nil {
                BACHeartbeat.shared.start()
                BACIPRegister.shared.start()
                BACEventEmitter.shared.ensureUploader()
            } else {
                // Drop any buffered events so the next enrollment
                // starts with a clean slate (different install id,
                // different bearer, possibly different workspace).
                BACEventEmitter.shared.reset()
            }
            self?.refreshEnrollmentMenuTitle()
            // Streaming flag flips on enroll/unenroll; refresh
            // every session window's toolbar indicator.
            self?.refreshStreamingState()
        }

        // Wire signal handlers BEFORE the MITM engine spawns its
        // ssh-agent — otherwise an unlucky signal between spawn and
        // handler install would orphan the child. SIGKILL and jetsam
        // are uncatchable; PrivateSSHAgent.reapOrphans() at the next
        // launch handles those.
        installCleanupSignalHandlers()

        // Force-init the MITM engine so the CA is ready before any
        // session opens (the lazy var would defer this to first launch,
        // adding a perceptible pause on the first session and racing
        // the VM boot path).
        _ = mitmEngine
        if let engine = mitmEngine {
            FileHandle.standardError.write(Data(
                "[mitm] engine ready; CA loaded from \(engine.ca.certificate.subject)\n".utf8))
            // Compromise handler — fired by the swapper's AC-backed
            // outbound scan whenever a fake token leaves the VM bound
            // for a host outside the scope it was minted for. Hops to
            // MainActor to pause the VM and present the alert.
            engine.swapper.setCompromiseHandler { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.handleCompromise(event)
                }
            }
            // Warm the trace ring from disk so `bromure-ac trace` shows recent
            // history right after the agent starts, not just live traffic.
            engine.traceStore.reload()
        }

        // Headless agent (CLI autostart): no picker window — the control socket
        // + status item are the only surfaces. Everything else (engine, signal
        // handlers, automation, control socket) still runs.
        if !headless {
        // Pick the right initial home: with a base image, the unified window
        // (the source list of every profile — the standalone picker is gone);
        // before the base image exists, the setup window in `mainWindow`.
        if imageManager.hasBaseImage {
            showUnifiedWindowAsHome()
            if profiles.isEmpty { openEditorWindow(editing: nil) }
            // Stale image — nag (non-blocking) but let the user keep
            // working with the existing base.
            if imageManager.baseImageNeedsUpdate {
                Task { @MainActor in
                    self.promptBaseImageUpdate()
                }
            }
        } else {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false
            )
            window.title = "Bromure Agentic Coding"
            window.delegate = self
            window.titlebarAppearsTransparent = false
            // See TabbedSessionWindow for the same fix: AppKit's window
            // close animator can over-release captured block ivars when
            // SwiftUI tears the contentView down concurrently (most
            // visible when the user closes this window mid-rebuild while
            // the InitProgressModel is still updating).
            window.animationBehavior = .none
            // We hold a strong reference (`self.mainWindow = window`).
            // NSWindow defaults to `isReleasedWhenClosed = true` for
            // non-controller windows, which would autorelease the window
            // on close and double-free it against our strong ref —
            // crashing in the next autorelease pool drain. Disable.
            window.isReleasedWhenClosed = false
            window.center()
            window.makeKeyAndOrderFront(nil)
            self.mainWindow = window
            renderSetup()
            NSApp.activate(ignoringOtherApps: true)
        }
        }   // if !headless

        // ⌘T / ⌘W / ⌘1-9 / ⌘N must run BEFORE VZVirtualMachineView's
        // keyDown forwards them to the guest (where kitty's super+t /
        // super+w mappings would create a kitty-internal tab instead
        // of a host pill, and super+n would reach the agent). A local
        // monitor fires before window /
        // menu / responder-chain dispatch, so this is the earliest
        // hook we have. `interceptKey` returns nil when it has
        // handled the event — propagate that nil so AppKit drops
        // the event. A `?? event` here would silently re-emit the
        // consumed event into normal dispatch, racing the host's
        // performKeyEquivalent against the VZ view's keyDown.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.interceptKey(event)
        }

        startAutomationServerIfNeeded()
        startRemoteAccessIfNeeded()
    }

    // MARK: - Remote access (optional SSH front door)

    /// UserDefaults-backed remote config. Defaults: disabled, port 2222,
    /// bind 0.0.0.0, both auth methods on.
    func remoteAccessConfig() -> RemoteAccessServer.Config {
        let d = UserDefaults.standard
        var c = RemoteAccessServer.Config()
        let p = d.integer(forKey: "remoteAccess.port")
        if p > 0 { c.port = p }
        c.bindAddress = d.string(forKey: "remoteAccess.bindAddress") ?? "0.0.0.0"
        // `object(forKey:) == nil` → key never set → default on.
        c.passwordAuth = d.object(forKey: "remoteAccess.passwordAuth") == nil ? true : d.bool(forKey: "remoteAccess.passwordAuth")
        c.pubkeyAuth = d.object(forKey: "remoteAccess.pubkeyAuth") == nil ? true : d.bool(forKey: "remoteAccess.pubkeyAuth")
        return c
    }

    /// Start the SSH front door iff `remoteAccess.enabled` (default OFF).
    @MainActor func startRemoteAccessIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "remoteAccess.enabled") else { return }
        do {
            try RemoteAccessServer.shared.start(remoteAccessConfig())
            SupplyChainLog.shared.record("[remote] SSH front door started.")
        } catch {
            SupplyChainLog.shared.record("[remote] start failed: \(error.localizedDescription)")
        }
    }

    @MainActor func stopRemoteAccess() {
        RemoteAccessServer.shared.stop()
    }

    /// Apply a config change coming from the CLI (`remote …`) or Preferences.
    /// Persists to UserDefaults, then (re)starts or stops sshd. Returns a
    /// status dict (same shape as `remoteAccessStatus`).
    @MainActor func remoteAccessApply(_ spec: [String: Any]) -> [String: Any] {
        let d = UserDefaults.standard
        if let port = spec["port"] as? Int {
            guard port > 0, port < 65536 else { return ["error": "port must be in 1..65535"] }
            guard port >= 1024 else { return ["error": "port must be ≥ 1024 (non-root can't bind privileged ports)"] }
            d.set(port, forKey: "remoteAccess.port")
        }
        if let bind = spec["bindAddress"] as? String, !bind.isEmpty {
            d.set(bind, forKey: "remoteAccess.bindAddress")
        }
        if let pw = spec["passwordAuth"] as? Bool { d.set(pw, forKey: "remoteAccess.passwordAuth") }
        if let pk = spec["pubkeyAuth"] as? Bool { d.set(pk, forKey: "remoteAccess.pubkeyAuth") }

        if let enabled = spec["enabled"] as? Bool {
            let cfg = remoteAccessConfig()
            guard cfg.passwordAuth || cfg.pubkeyAuth else {
                return ["error": "Enable at least one of password / public-key auth."]
            }
            d.set(enabled, forKey: "remoteAccess.enabled")
            if enabled {
                do { try RemoteAccessServer.shared.start(cfg) }
                catch { return ["error": error.localizedDescription] }
            } else {
                RemoteAccessServer.shared.stop()
            }
        } else if d.bool(forKey: "remoteAccess.enabled") {
            // No enable/disable in this call but we're on → apply live.
            do { try RemoteAccessServer.shared.start(remoteAccessConfig()) }
            catch { return ["error": error.localizedDescription] }
        }
        return remoteAccessStatus()
    }

    /// "<ip>:<port>" a remote client would use: the bound address, or — when
    /// bound to all interfaces (0.0.0.0) — this Mac's primary LAN IPv4.
    @MainActor func remoteReachableAddress() -> String {
        let cfg = remoteAccessConfig()
        let ip = cfg.bindAddress == "0.0.0.0"
            ? (HostNetwork.primaryIPv4() ?? "this Mac's IP") : cfg.bindAddress
        return "\(ip):\(cfg.port)"
    }

    @MainActor func remoteAccessStatus() -> [String: Any] {
        let d = UserDefaults.standard
        let cfg = remoteAccessConfig()
        let server = RemoteAccessServer.shared
        let user = NSUserName()
        let host = cfg.bindAddress == "0.0.0.0"
            ? (HostNetwork.primaryIPv4() ?? "<this-mac-ip>") : cfg.bindAddress
        let keys = server.listAuthorizedKeys().map { k in
            ["type": k.type, "comment": k.comment, "fingerprint": k.fingerprint] as [String: Any]
        }
        return [
            "enabled": d.bool(forKey: "remoteAccess.enabled"),
            "running": server.isRunning,
            "port": cfg.port,
            "bindAddress": cfg.bindAddress,
            "passwordAuth": cfg.passwordAuth,
            "pubkeyAuth": cfg.pubkeyAuth,
            "fingerprint": server.hostKeyFingerprint() ?? "(not generated yet)",
            "user": user,
            "connect": "ssh -p \(cfg.port) \(user)@\(host)",
            "authorizedKeys": keys,
        ]
    }

    @MainActor func remoteAccessAddKey(_ pub: String) -> [String: Any] {
        do {
            try RemoteAccessServer.shared.addAuthorizedKey(pub)
            let added = RemoteAccessServer.shared.listAuthorizedKeys().last
            return ["ok": true, "fingerprint": added?.fingerprint ?? "ok"]
        } catch { return ["error": error.localizedDescription] }
    }

    @MainActor func remoteAccessRemoveKey(_ selector: String) -> [String: Any] {
        do { try RemoteAccessServer.shared.removeAuthorizedKey(selector); return ["ok": true] }
        catch { return ["error": error.localizedDescription] }
    }

    // MARK: - Automation server

    @MainActor func startAutomationServerIfNeeded() {
        let defaults = UserDefaults.standard
        // Default OFF — opt-in to keep the loopback HTTP API hidden
        // until the user enables it (Bromure → Preferences → Automation,
        // or `defaults write io.bromure.agentic-coding automation.enabled
        // -bool true`). The e2e Jenkinsfile sets this before launching.
        guard defaults.bool(forKey: "automation.enabled") else { return }

        if automationServer != nil { stopAutomationServer() }

        let port = UInt16(defaults.integer(forKey: "automation.port"))
        let bindAddr = defaults.string(forKey: "automation.bindAddress") ?? "127.0.0.1"
        let server = ACAutomationServer(port: port > 0 ? port : 9223, bindAddress: bindAddr)
        wireAutomationCallbacks(into: server)
        server.start()
        automationServer = server
    }

    /// Always-on owner-only Unix control socket for the `bromure-ac` CLI.
    /// Independent of `automation.enabled` (which only gates the TCP API) so the
    /// CLI works out of the box. exec / vm operations are allowed here without
    /// the debug flag — the 0600 socket file is the access gate.
    @MainActor func startControlSocket() {
        if controlServer != nil { return }
        let socketURL = store.controlSocketURL
        try? FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let server = ACAutomationServer(unixSocketPath: socketURL.path)
        wireAutomationCallbacks(into: server)
        server.start()
        controlServer = server
    }

    @MainActor func stopAutomationServer() {
        automationServer?.stop()
        automationServer = nil
    }

    /// Wire the shared control-plane callbacks into a server instance (used by
    /// both the opt-in TCP API and the always-on Unix control socket).
    @MainActor private func wireAutomationCallbacks(into server: ACAutomationServer) {
        server.onListProfiles = { [weak self] in
            guard let self else { return [] }
            return self.profiles.map { p in
                let stateStr: String
                switch self.runState(for: p) {
                case .running:   stateStr = "running"
                case .booting:   stateStr = "booting"
                case .suspended: stateStr = "suspended"
                case .off:       stateStr = "off"
                }
                return ACAutomationProfileInfo(
                    id: p.id.uuidString,
                    shortId: Self.shortID(p.id),
                    name: p.name,
                    color: p.color.rawValue,
                    tool: p.tool.rawValue,
                    authMode: p.authMode.rawValue,
                    mcpServerCount: p.mcpServers.count,
                    state: stateStr
                )
            }
        }

        // Sessions = the registry (so detached, window-less VMs are listed too).
        server.onListSessions = { [weak self] in
            guard let self else { return [] }
            return self.runningSessions.values.map { s in
                let host = self.hostWindow(for: s.profileID)
                return ACAutomationSessionInfo(
                    profileID: s.profileID.uuidString,
                    profileName: s.profile.name,
                    windowID: host?.windowNumber ?? 0,
                    visible: host?.isVisible ?? false
                )
            }
        }

        server.onCreateSession = { [weak self] profileNameOrID in
            guard let self else { return nil }
            return await self.automationCreateSession(profileNameOrID: profileNameOrID)
        }

        server.onDestroySession = { [weak self] profileNameOrID in
            guard let self else { return false }
            return await self.automationDestroySession(profileNameOrID: profileNameOrID)
        }

        server.onGetAppState = { [weak self] in
            guard let self else { return [:] }
            return [
                "locale": (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first ?? "system",
                "mainWindowOpen": self.mainWindow?.isVisible ?? false,
                "editorOpen": self.editorWindow?.isVisible ?? false,
                "profileCount": self.profiles.count,
                "sessionCount": self.runningSessions.count,
                "hasBaseImage": self.imageManager.hasBaseImage,
            ]
        }
        server.onUIShot = { [weak self] path, which in
            // The route already dispatches us onto main via `DispatchQueue.main.sync`,
            // so assume isolation rather than nesting another sync (which deadlocks).
            MainActor.assumeIsolated {
                guard let self else { return ["error": "no app"] }
                let window: NSWindow?
                switch which {
                case "picker": window = self.mainWindow
                case "editor": window = self.editorWindow
                default:       window = self.unifiedWindow
                }
                return self.debugRenderWindow(window, to: path)
            }
        }
        // Drive the settings editor over the control socket (doc-screenshot
        // tool) — replaces the old AppleScript bridge so the script needs no
        // scripting terminology, LaunchServices registration, or Screen
        // Recording permission.
        server.onEditorDebug = { [weak self] params in
            MainActor.assumeIsolated {
                guard let self else { return ["error": "no app"] }
                let action = params["action"] as? String ?? ""
                switch action {
                case "ensure-profile":
                    let name = (params["name"] as? String) ?? "Screenshot"
                    if let existing = self.profiles.first(where: { $0.name.lowercased() == name.lowercased() }) {
                        return ["id": existing.id.uuidString, "created": false]
                    }
                    let p = Profile(name: name, tool: .claude, authMode: .token, color: .blue)
                    do {
                        try self.store.save(p)
                        self.profiles = self.store.loadAll()
                        return ["id": p.id.uuidString, "created": true]
                    } catch { return ["error": "create failed: \(error.localizedDescription)"] }
                case "open":
                    let key = (params["profile"] as? String) ?? ""
                    let profile: Profile?
                    if let uuid = UUID(uuidString: key) { profile = self.profiles.first { $0.id == uuid } }
                    else { profile = self.profiles.first { $0.name.lowercased() == key.lowercased() } }
                    guard let profile else { return ["error": "profile not found: \(key)"] }
                    self.openEditorWindow(editing: profile)
                    return ["editorOpen": self.editorWindow?.isVisible ?? false,
                            "windowId": self.editorWindow?.windowNumber ?? 0]
                case "category":
                    let raw = (params["category"] as? String ?? "").lowercased()
                    guard !raw.isEmpty else { return ["error": "category required"] }
                    NotificationCenter.default.post(name: .bromureACSelectEditorCategory, object: raw)
                    return ["ok": true]
                case "close":
                    self.closeEditorWindow()
                    return ["ok": true]
                default:
                    return ["error": "unknown action: \(action)"]
                }
            }
        }

        server.onGetShellConnection = { [weak self] idOrName in
            guard let self else { return nil }
            guard let uuid = self.resolveRunningSessionID(idOrName) else { return nil }
            guard let bridge = self.shellBridges[uuid] else { return nil }
            guard let conn = bridge.dequeueConnection() else { return nil }
            return ACShellProxyConnection(fd: conn.fileDescriptor, conn: conn)
        }

        // docker-style VM control plane.
        server.onListVMs = { [weak self] in self?.automationVMList() ?? [] }
        server.onStopVM = { [weak self] idOrName, action in
            guard let self else { return false }
            return await self.automationStopVM(idOrName: idOrName, action: action)
        }
        server.onAttachVM = { [weak self] idOrName in
            guard let self else { return false }
            return await self.automationAttachVM(idOrName: idOrName)
        }
        server.onCreateVM = { [weak self] spec in
            guard let self else { return nil }
            return await self.automationCreateVM(spec: spec)
        }
        server.onDescribeProfile = { [weak self] key in self?.automationProfileDescribe(key) }
        server.onDeleteProfile = { [weak self] key in
            self?.automationDeleteProfile(key) ?? ["ok": false, "error": "unavailable"]
        }
        server.onListTrace = { [weak self] profileKey in self?.automationTraceList(profileKey) ?? [] }
        server.onClearTrace = { [weak self] in self?.mitmEngine?.traceStore.clear() ?? 0 }
        // Local inference now flows through the MITM (guest → https://bromure.llm
        // → MITM → engine), so the MITM records the trace + drives the thinking
        // indicator exactly like cloud — no separate local trace path (which is
        // why local bodies weren't captured before). We keep this activity hook
        // as a downstream backstop for the "thinking" indicator.
        InferenceRepairProxy.shared.onLocalActivity = { [weak self] pid in
            DispatchQueue.main.async { self?.noteAgentActivity(pid) }
        }
        server.onSetFusion = { [weak self] idOrName, engaged in
            self?.automationSetFusion(idOrName: idOrName, engaged: engaged)
                ?? ["ok": false, "error": "unavailable"]
        }
        server.onSetRouting = { [weak self] idOrName, mode in
            self?.automationSetRouting(idOrName: idOrName, mode: mode)
                ?? ["ok": false, "error": "unavailable"]
        }
        server.onSetHybrid = { [weak self] idOrName, knob, value in
            self?.automationSetHybrid(idOrName: idOrName, knob: knob, value: value)
                ?? ["ok": false, "error": "unavailable"]
        }
        server.onSetModel = { [weak self] idOrName, modelID in
            self?.automationSetModel(idOrName: idOrName, modelID: modelID)
                ?? ["ok": false, "error": "unavailable"]
        }

        // Remote access (optional SSH front door) — owner-only control socket.
        server.onRemoteStatus = { [weak self] in
            MainActor.assumeIsolated { self?.remoteAccessStatus() ?? [:] }
        }
        server.onRemoteApply = { [weak self] spec in
            MainActor.assumeIsolated { self?.remoteAccessApply(spec) ?? ["error": "unavailable"] }
        }
        server.onRemoteAddKey = { [weak self] key in
            MainActor.assumeIsolated { self?.remoteAccessAddKey(key) ?? ["error": "unavailable"] }
        }
        server.onRemoteRemoveKey = { [weak self] sel in
            MainActor.assumeIsolated { self?.remoteAccessRemoveKey(sel) ?? ["error": "unavailable"] }
        }
    }

    /// MITM trace records for `trace …`, optionally filtered to one profile.
    /// Record a per-VM local-inference call (shipped by the engine child's
    /// repair proxy) into the TraceStore, so local LLM calls show up in `trace`
    /// next to cloud calls, tagged with the profile that made them. Respects the
    /// profile's trace level the same way the MITM does.
    @MainActor private func automationIngestLocalTrace(_ event: [String: Any]) {
        guard let pidStr = event["profileID"] as? String, let pid = UUID(uuidString: pidStr),
              let store = mitmEngine?.traceStore,
              let profile = profiles.first(where: { $0.id == pid }),
              profile.traceLevel.recordsActivity else { return }
        let model = event["model"] as? String ?? "?"
        // Local inference is an AI request, so persist its prompt/tools +
        // response at the same trace levels the MITM captures cloud LLM bodies
        // (AI request details / Everything) — otherwise the inspector has only
        // metadata to show.
        let capture = profile.traceLevel == .aiDetails || profile.traceLevel == .all
        let reqBody = capture ? (event["requestBody"] as? Data) : nil
        let resBody = capture ? (event["responseBody"] as? Data) : nil
        let stored = (reqBody?.isEmpty == false) || (resBody?.isEmpty == false)
        let rec = TraceRecord(
            sessionID: pid, profileID: pid,
            host: "local-engine", port: InferenceService.enginePort,
            method: "POST", path: event["path"] as? String ?? "/v1/messages",
            statusCode: (event["status"] as? NSNumber)?.intValue ?? 0,
            requestBytes: (event["requestBytes"] as? NSNumber)?.intValue ?? 0,
            responseBytes: (event["responseBytes"] as? NSNumber)?.intValue ?? 0,
            latencyMs: (event["latencyMs"] as? NSNumber)?.doubleValue ?? 0,
            swaps: [], leaks: [], bodyStored: stored, isConversation: true,
            servedBy: "local-\(model)")
        store.record(rec, requestBody: reqBody, responseBody: resBody)
    }

    /// Newest first; previews only (no secret values).
    @MainActor private func automationTraceList(_ profileKey: String?) -> [[String: Any]] {
        guard let engine = mitmEngine else { return [] }
        let wantID: Profile.ID? = profileKey.flatMap { profileByNameOrID($0)?.id }
        let iso = ISO8601DateFormatter()
        return engine.traceStore.recent.compactMap { rec -> [String: Any]? in
            if let wantID, rec.profileID != wantID { return nil }
            return [
                "id": rec.id.uuidString,
                "time": iso.string(from: rec.timestamp),
                "profileId": rec.profileID.uuidString,
                "profileShort": Self.shortID(rec.profileID),
                "host": rec.host,
                "port": rec.port,
                "method": rec.method,
                "path": rec.path,
                "status": rec.statusCode,
                "requestBytes": rec.requestBytes,
                "responseBytes": rec.responseBytes,
                "latencyMs": rec.latencyMs,
                "swaps": rec.swaps.count,
                "leaks": rec.leaks.map {
                    ["header": $0.header, "preview": $0.valuePreview, "suspicion": $0.suspicion.rawValue]
                },
                "conversation": rec.isConversation,
            ]
        }
    }

    /// Toggle Fusion for a running VM's profile (`vm fusion enable|disable`).
    @MainActor private func automationSetFusion(idOrName: String, engaged: Bool) -> [String: Any] {
        guard let id = resolveRunningSessionID(idOrName), let session = runningSessions[id] else {
            return ["ok": false, "error": "VM not found: \(idOrName)"]
        }
        guard session.profile.fusionConfigurable else {
            return ["ok": false, "error": "Fusion needs at least two usable model credentials on this workspace."]
        }
        setFusionEngaged(engaged, for: session.profile)
        return ["ok": true, "engaged": engaged]
    }

    /// `vm routing cloud|local|hybrid` — set the per-profile backend
    /// routing and push it live to the MITM engine (vLLM.md §4.2).
    @MainActor private func automationSetRouting(idOrName: String, mode: String) -> [String: Any] {
        guard let id = resolveRunningSessionID(idOrName), let session = runningSessions[id] else {
            return ["ok": false, "error": "VM not found: \(idOrName)"]
        }
        guard let routing = Profile.Routing(rawValue: mode.lowercased()) else {
            return ["ok": false, "error": "Routing must be 'cloud', 'local', or 'hybrid'."]
        }
        var profile = session.profile
        profile.modelRouting = routing
        session.profile = profile
        try? store.save(profile)
        if let engine = mitmEngine { applyRouting(engine, for: profile) }
        return ["ok": true, "routing": routing.rawValue]
    }

    /// `vm hybrid budget|ttft|split <value>` — tune the hybrid policy
    /// knobs (vLLM.md §4.3.1) and push them live.
    @MainActor private func automationSetHybrid(idOrName: String, knob: String, value: Double) -> [String: Any] {
        guard let id = resolveRunningSessionID(idOrName), let session = runningSessions[id] else {
            return ["ok": false, "error": "VM not found: \(idOrName)"]
        }
        var profile = session.profile
        switch knob {
        case "budget": profile.hybridCloudTokenBudget = max(0, Int(value))
        case "ttft":   profile.hybridSoftTTFTSeconds = max(0, value)
        case "split":  profile.hybridLocalSplitPercent = max(0, min(100, Int(value)))
        default: return ["ok": false, "error": "Unknown hybrid knob: \(knob)"]
        }
        session.profile = profile
        try? store.save(profile)
        if let engine = mitmEngine { applyRouting(engine, for: profile) }
        return ["ok": true, "knob": knob, "value": value]
    }

    /// `model use <id>` — set the profile's active local model (drives the
    /// served-by marker + which weights the engine loads under local/hybrid).
    @MainActor private func automationSetModel(idOrName: String, modelID: String) -> [String: Any] {
        guard let id = resolveRunningSessionID(idOrName), let session = runningSessions[id] else {
            return ["ok": false, "error": "VM not found: \(idOrName)"]
        }
        guard let model = CatalogStore.shared.resolve(modelID) else {
            return ["ok": false, "error": "Unknown model '\(modelID)'. Try `model catalog`."]
        }
        var profile = session.profile
        profile.activeModelID = model.id
        session.profile = profile
        try? store.save(profile)
        if let engine = mitmEngine { applyRouting(engine, for: profile) }
        // Re-point the sentinel + make the engine serve the new model. The guest
        // keeps its env (ANTHROPIC_MODEL = bromure-local), so the switch takes
        // effect on the next request with no agent restart.
        startLocalEngineIfNeeded(for: profile)
        return ["ok": true, "model": model.id, "repo": model.repo]
    }

    /// Curated, secret-free view of a profile's settings for `profiles describe`.
    @MainActor private func automationProfileDescribe(_ key: String) -> [String: Any]? {
        guard let p = profileByNameOrID(key) else { return nil }
        let iso = ISO8601DateFormatter()
        var d: [String: Any] = [
            "id": p.id.uuidString,
            "shortId": Self.shortID(p.id),
            "name": p.name,
            "color": p.color.rawValue,
            "tool": p.tool.rawValue,
            "authMode": p.authMode.rawValue,
            "apiKeySet": (p.apiKey?.isEmpty == false),
            "memoryGB": p.memoryGB,
            "networkMode": p.networkMode.rawValue,
            "macAddress": MACBindings.shared.macAddress(for: p.id),
            "closeAction": p.closeAction.rawValue,
            "bootAtStartup": p.bootAtStartup,
            "folderPaths": p.folderPaths,
            "mcpServers": p.mcpServers.map { $0.name },
            "sshKeySet": (p.sshPublicKey?.isEmpty == false),
            "importedSSHKeys": p.importedSSHKeys.count,
            "running": runningSessions[p.id] != nil,
            "comments": p.comments,
            "createdAt": iso.string(from: p.createdAt),
        ]
        if let last = p.lastUsedAt { d["lastUsedAt"] = iso.string(from: last) }
        return d
    }

    /// Delete a profile (and its disk + home). Refuses while a VM is running.
    @MainActor private func automationDeleteProfile(_ key: String) -> [String: Any] {
        guard let p = profileByNameOrID(key) else {
            return ["ok": false, "error": "Workspace not found: \(key)"]
        }
        if runningSessions[p.id] != nil {
            return ["ok": false, "error": "Workspace '\(p.name)' has a running VM — `vm kill` it first."]
        }
        do {
            try store.delete(p)
            profiles = store.loadAll()
            refreshSidebar()
            return ["ok": true, "name": p.name]
        } catch {
            return ["ok": false, "error": "Couldn't delete '\(p.name)': \(error.localizedDescription)"]
        }
    }

    /// Snapshot of running VMs for `vm ls`.
    @MainActor private func automationVMList() -> [[String: Any]] {
        let now = Date()
        return runningSessions.values.map { s in
            let stateStr: String
            switch s.sandbox.state {
            case .created:  stateStr = "created"
            case .starting: stateStr = "starting"
            case .running:  stateStr = "running"
            case .stopped:  stateStr = "stopped"
            case .error:    stateStr = "error"
            }
            // 1-based for display; `index` is the tmux window index the CLI
            // passes back to `select-window`.
            let tabs: [[String: Any]] = s.tabs.map { t in
                ["index": t.index, "title": t.label.isEmpty ? "shell" : t.label, "active": t.active]
            }
            let diskURL = store.diskURL(for: s.profile)
            let diskAllocated = (try? diskURL.resourceValues(
                forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0
            return [
                "id": s.profileID.uuidString,
                "shortId": Self.shortID(s.profileID),
                "name": s.profile.name,
                "tool": s.profile.tool.rawValue,
                "state": stateStr,
                "attached": isAttached(s.profileID),
                "uptimeSeconds": Int(now.timeIntervalSince(s.startedAt)),
                "ip": s.lastIP ?? "",
                "mounts": s.profile.folderPaths,
                "tabs": tabs,
                "cpuCount": UbuntuSandboxVM.runtimeCPUs,
                "memoryGB": s.profile.memoryGB,
                "networkMode": s.profile.networkMode.rawValue,
                "macAddress": MACBindings.shared.macAddress(for: s.profileID),
                "diskPath": diskURL.path,
                "diskAllocatedBytes": diskAllocated,
                "baseImageVersion": s.profile.baseImageVersionAtClone ?? "unknown",
                "fusionConfigurable": s.profile.fusionConfigurable,
                "fusionEngaged": mitmEngine?.fusionEngaged(for: s.profileID) ?? false,
            ]
        }
    }

    @MainActor private func automationStopVM(idOrName: String, action: String) async -> Bool {
        guard let id = resolveRunningSessionID(idOrName) else { return false }
        let closeAction: Profile.CloseAction
        switch action.lowercased() {
        case "suspend":            closeAction = .suspend
        default:                   closeAction = .shutdown   // shutdown / kill / stop
        }
        await stopSession(id, action: closeAction)
        return true
    }

    @MainActor private func automationAttachVM(idOrName: String) async -> Bool {
        guard let id = resolveRunningSessionID(idOrName),
              let session = runningSessions[id] else { return false }
        attachWindow(to: session)
        return true
    }

    /// Docker-style 12-char short id for a profile: the UUID's hex with dashes
    /// stripped, lowercased, truncated. Shown by `vm ls` and accepted (as a
    /// prefix) by every `<id|name>` argument.
    static func shortID(_ id: Profile.ID) -> String {
        String(id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
    }

    /// Resolve a CLI-supplied id-or-name to a *running* session's profile id.
    /// Accepts a full UUID, an exact profile name (case-insensitive), or a
    /// unique short-id *prefix* (dash-insensitive) — so the 12-char hex id from
    /// `vm ls` (or any unambiguous prefix of it) works, docker-style.
    @MainActor private func resolveRunningSessionID(_ key: String) -> Profile.ID? {
        if let uuid = UUID(uuidString: key), runningSessions[uuid] != nil { return uuid }
        if let byName = runningSessions.values
            .first(where: { $0.profile.name.lowercased() == key.lowercased() }) {
            return byName.profileID
        }
        let k = key.replacingOccurrences(of: "-", with: "").lowercased()
        guard !k.isEmpty else { return nil }
        let matches = runningSessions.keys.filter {
            $0.uuidString.replacingOccurrences(of: "-", with: "").lowercased().hasPrefix(k)
        }
        return matches.count == 1 ? matches.first : nil
    }

    /// Create (boot) a VM from a control-plane spec — the `vm run` path. Mints
    /// or resolves a profile, applies `-v` mounts, persists it, then drives the
    /// normal `launch` path (so all the engine / token / boot wiring is shared)
    /// and optionally detaches for a headless `-d` run.
    @MainActor private func automationCreateVM(spec: [String: Any]) async -> [String: Any]? {
        // 1. Resolve an existing profile, or mint one on the fly.
        var profile: Profile
        if let ref = spec["profile"] as? String, let existing = profileByNameOrID(ref) {
            profile = existing
        } else {
            let fallback = "cli-" + String(UUID().uuidString.prefix(8)).lowercased()
            let name = (spec["name"] as? String) ?? (spec["profile"] as? String) ?? fallback
            let tool = (spec["tool"] as? String).flatMap { Profile.Tool(rawValue: $0) }
            let auth = (spec["auth"] as? String).flatMap { Profile.AuthMode(rawValue: $0) }
            var p = store.newProfileFromTemplate(name: name, tool: tool, authMode: auth)
            if let key = spec["apiKey"] as? String, !key.isEmpty { p.apiKey = key }
            if let mem = spec["memoryGB"] as? Int, mem > 0 { p.memoryGB = mem }
            profile = p
        }

        // 1b. Refuse to start while a selected local model is still downloading —
        //     booting now would point the agent at an engine that can't load it
        //     yet. Surface a clear error (the /vms route turns this into 409) so
        //     `vm run` prints it instead of hanging until the boot-wait times out.
        if let dl = downloadingModel(for: profile) {
            return ["error": "“\(dl.name)” is still downloading — wait for it to finish, then start “\(profile.name)”."]
        }

        // 2. Apply `-v` mounts (host paths → ~/<basename> in the guest), capped
        //    at the base image's 8 fstab slots.
        if let mounts = spec["mounts"] as? [String], !mounts.isEmpty {
            var paths = profile.folderPaths
            for m in mounts {
                let host = (m as NSString).expandingTildeInPath
                guard FileManager.default.fileExists(atPath: host) else {
                    FileHandle.standardError.write(Data("[vm run] mount not found, skipping: \(host)\n".utf8))
                    continue
                }
                if !paths.contains(host) { paths.append(host) }
            }
            profile.folderPaths = Array(paths.prefix(8))
        }

        // 3. Persist + refresh the in-memory list.
        do { try store.save(profile) }
        catch {
            FileHandle.standardError.write(Data("[vm run] couldn't save profile: \(error)\n".utf8))
            return nil
        }
        profiles = store.loadAll()
        let saved = profiles.first { $0.id == profile.id } ?? profile
        if spec["rm"] as? Bool == true { ephemeralProfiles.insert(saved.id) }

        // 4. Boot via the shared launch path. A headless `-d` run boots
        //    window-less from the start (no pane is ever hosted) so no window
        //    flashes up during boot. If the session is already running, `launch`
        //    detaches it instead.
        let detach = spec["detach"] as? Bool == true
        if runningSessions[saved.id] == nil {
            launch(saved, detached: detach)
        } else if detach {
            detachSession(saved.id)
        }

        // 5. Wait for the VM to register (first boot can take a while).
        var ready = false
        for _ in 0..<600 {   // up to ~60s
            if runningSessions[saved.id] != nil { ready = true; break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard ready else { return nil }

        return [
            "id": saved.id.uuidString,
            "shortId": Self.shortID(saved.id),
            "name": saved.name,
            "tool": saved.tool.rawValue,
            "detached": detach,
        ]
    }

    @MainActor private func automationCreateSession(profileNameOrID: String) async -> ACAutomationSessionInfo? {
        guard let profile = profileByNameOrID(profileNameOrID) else { return nil }
        // If a session is already shown for this profile, just return its info.
        if isAttached(profile.id) {
            let host = hostWindow(for: profile.id)
            return ACAutomationSessionInfo(
                profileID: profile.id.uuidString,
                profileName: profile.name,
                windowID: host?.windowNumber ?? 0,
                visible: host?.isVisible ?? false
            )
        }
        launch(profile)
        // launch() is fire-and-forget; the pane appears asynchronously when the
        // VM pool warms up. Wait up to 30s for it to register so the API caller
        // gets a meaningful response.
        for _ in 0..<300 {
            if isAttached(profile.id) {
                let host = hostWindow(for: profile.id)
                return ACAutomationSessionInfo(
                    profileID: profile.id.uuidString,
                    profileName: profile.name,
                    windowID: host?.windowNumber ?? 0,
                    visible: host?.isVisible ?? false
                )
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    @MainActor private func automationDestroySession(profileNameOrID: String) async -> Bool {
        guard let profile = profileByNameOrID(profileNameOrID) else { return false }
        guard isAttached(profile.id) else { return false }
        closeVMFromSidebar(profile.id)
        // Wait briefly for the close to take effect.
        for _ in 0..<50 {
            if !isAttached(profile.id) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return !isAttached(profile.id)
    }

    @MainActor private func profileByNameOrID(_ key: String) -> Profile? {
        if let uuid = UUID(uuidString: key) { return profiles.first { $0.id == uuid } }
        if let byName = profiles.first(where: { $0.name.lowercased() == key.lowercased() }) {
            return byName
        }
        // Docker-style short-id prefix (dash-insensitive).
        let k = key.replacingOccurrences(of: "-", with: "").lowercased()
        guard !k.isEmpty else { return nil }
        let matches = profiles.filter {
            $0.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().hasPrefix(k)
        }
        return matches.count == 1 ? matches.first : nil
    }

    private func interceptKey(_ event: NSEvent) -> NSEvent? {
        // The meaningful test is "is Command held without any other
        // user-meaningful modifier (shift / option / control)". macOS
        // sets stray bits — capsLock when the LED is on, numericPad on
        // some letter keys with non-US layouts, help / function — that
        // a strict `mods == [.command]` would reject. Filter to just
        // the four modifiers a user expects to combine with Command,
        // then check Command is the only one set.
        let userMods: NSEvent.ModifierFlags = [.command, .shift, .option, .control]
        let mods = event.modifierFlags.intersection(userMods)
        guard mods == [.command] else { return event }

        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        // ⌘H = standard macOS "hide app". Handle here defensively in
        // case responder-chain routing is interfered with elsewhere.
        if chars == "h" {
            NSApp.hide(nil)
            return nil
        }

        // Find the owning session window. keyWindow first, then any visible
        // session — mirrors the Browser monitor's keyWindow fallback so we
        // still own the chord when the VZ view has grabbed focus and AppKit
        // hands us a keyDown with a nil/foreign event.window.
        //
        // NOTE: this monitor is only ONE of the two routes for host-owned
        // chords. When the VM holds keyboard focus the VZ view forwards the
        // chord to the guest before AppKit dispatches keyDown, so this monitor
        // typically never fires for it — Openbox grabs it in the guest and
        // bounces it back via UbuntuSandboxVM.onShortcut instead. This path
        // covers the other case: a native control in the session window holds
        // focus. Both funnel into win.performACShortcut, which debounces.
        let sessions = NSApp.windows.compactMap { $0 as? TabbedSessionWindow }
        let win = (NSApp.keyWindow as? TabbedSessionWindow)
            ?? sessions.first(where: { $0.isVisible })

        // ⌘N opens the picker even with no session window up.
        guard let win else {
            if chars == "n" {
                openProfileManagerAction(nil)
                return nil
            }
            return event
        }

        // When the VM holds keyboard focus, DON'T act here: the chord reaches
        // the guest, Openbox grabs it, and it bounces back via onShortcut →
        // performACShortcut. Acting here too would double-process one press
        // (⌘T → two kittys racing on X startup, ⌘W → two tabs closed) — the
        // bounce's up-to-500ms poll latency is longer than performACShortcut's
        // debounce, so the debounce alone can't dedupe the two paths. Return
        // the event so it flows to the guest and the bounce owns it.
        if win.vmHasKeyboardFocus { return event }

        // Native control in the session window has focus → the chord won't
        // reach the guest, so this is the path that runs it. Host-owned chords
        // (⌘T / ⌘W / ⌘N / ⌘1-9) → consume; every other ⌘ chord is sent on.
        if win.performACShortcut(chars, isRepeat: event.isARepeat) { return nil }
        return event
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Quit only when literally every window is gone — picker + all
        // session windows. Closing one session shouldn't take the others
        // down with it.
        false
    }

    /// ⌘Q (and Quit menu) confirmation. Skip the prompt if no VMs are
    /// running — quitting an idle app should be friction-free.
    ///
    /// With running VMs we return `.terminateLater` and drive an
    /// async drain (clean ACPI poweroff with a force-stop watchdog)
    /// before replying. AppKit holds the termination until we call
    /// `NSApp.reply(toApplicationShouldTerminate:)`. This is the
    /// documented async-shutdown pattern and it fixes the
    /// "NSActivity was ended multiple times" warning Foundation
    /// emits when VZ's framework teardown races our in-flight
    /// `vm.stop()` callbacks: drained-first means VZ ends its
    /// internal activity exactly once, in order.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = runningSessions.values.filter { $0.sandbox.vm?.state == .running }
        if running.isEmpty { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Quit Bromure Agentic Coding?", comment: "")
        let names = running.map { $0.profile.name }.joined(separator: ", ")
        alert.informativeText = String(
            format: NSLocalizedString(
                "%d VM(s) currently running (%@) will be closed according to each workspace's close action.",
                comment: ""),
            running.count, names)
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Quit", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        guard alert.runModal() == .alertFirstButtonReturn else {
            return .terminateCancel
        }

        Task { @MainActor in
            await self.drainRunningVMs()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Stop every running VM in parallel on quit via `stopSession`, honoring
    /// each profile's close action (`.ask` → `.suspend`). Iterates the
    /// registry, so it drains *detached* VMs too — not just windowed ones.
    @MainActor
    private func drainRunningVMs() async {
        let ids = runningSessions.values
            .filter { $0.sandbox.vm?.state == .running }
            .map { $0.profileID }
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                let action = runningSessions[id]?.profile.closeAction ?? .suspend
                group.addTask { @MainActor in await self.stopSession(id, action: action) }
            }
        }
    }

    private static func forceStop(_ vm: VZVirtualMachine) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            vm.stop { _ in cont.resume() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Nuke our private ssh-agent. The orphaned-process risk is
        // small (it's idle and tiny) but worth tidying up at least
        // for the clean-quit path.
        mitmEngine?.privateAgent.terminate()
        // Synchronously kill the local inference engine — a detached
        // Task wouldn't run before the process exits, orphaning vllm-mlx
        // (and its large RAM footprint).
        InferenceService.killIfRunning()
        // Tear down the optional SSH front door so we don't orphan sshd.
        RemoteAccessServer.shared.stop()
    }

    /// Catch the catchable abnormal-termination signals so we still
    /// run ssh-agent cleanup before dying. Without this, anything
    /// other than a user-initiated ⌘Q (which goes through
    /// `applicationWillTerminate`) — a SIGTERM from `kill`, a Ctrl-C
    /// in the terminal launching us, a `pkill`, an enclosing
    /// `launchctl` stop — orphans `/usr/bin/ssh-agent` because the
    /// default disposition just exits the process.
    ///
    /// SIGKILL and macOS jetsam (low-memory kill) are uncatchable;
    /// `PrivateSSHAgent.reapOrphans()` at the next launch is the
    /// safety net for those.
    private func installCleanupSignalHandlers() {
        let catchable: [Int32] = [SIGTERM, SIGINT, SIGHUP]
        for sig in catchable {
            // `signal(sig, SIG_IGN)` first so the default
            // disposition doesn't kill us in the window between this
            // function returning and the dispatch source activating
            // (or in case the source is somehow released early).
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                FileHandle.standardError.write(Data(
                    "[bromure-ac] caught signal \(sig); terminating ssh-agent + engine + exiting\n".utf8))
                self?.mitmEngine?.privateAgent.terminate()
                InferenceService.killIfRunning()
                // Exit with a non-zero code so callers can distinguish
                // signal-driven shutdown from a clean ⌘Q.
                exit(128 + sig)
            }
            src.activate()
            cleanupSignalSources.append(src)
        }
    }

    /// Vetoable close. For VM session windows we always confirm, because
    /// closing tears down the disposable VM and any unsaved guest state
    /// goes with it. The picker / inspector windows close freely.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // The setup/picker window during an in-flight rebuild: the
        // install Task keeps pushing model updates to a SwiftUI view
        // that's about to be torn down — that's been observed to
        // over-release in the autorelease pool. Confirm + cancel the
        // Task; instead of closing the window, swap its contentView
        // back to the picker (or setup, if no image yet) so the user
        // lands somewhere usable rather than on a closed window.
        if sender === mainWindow, let task = installTask {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Cancel base-image rebuild?", comment: "")
            alert.informativeText = NSLocalizedString(
                "The image will be left in an incomplete state. You'll need to re-run the rebuild before launching new sessions.",
                comment: "")
            alert.alertStyle = .warning
            alert.addButton(withTitle: NSLocalizedString("Cancel rebuild", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Keep building", comment: ""))
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            task.cancel()
            self.installTask = nil
            initProgress.stop()
            initProgress.isRunning = false
            if imageManager.hasBaseImage {
                // The previous base image is still usable — drop the installer
                // window and return to the unified home.
                self.mainWindow = nil
                showUnifiedWindowAsHome()
                return true
            }
            renderSetup()
            return false
        }

        guard let session = sender as? TabbedSessionWindow else { return true }
        // Resolve the profile's "When closing the window" preference (.ask is
        // turned into a prompt). nil = the user cancelled → keep the window open.
        guard let action = resolveCloseAction(for: session) else { return false }
        session.closeIntent = action
        return true
    }

    /// Resolve a session window's close action from its profile preference,
    /// prompting when it's `.ask`. Returns nil if the user cancelled.
    @MainActor private func resolveCloseAction(for session: TabbedSessionWindow) -> Profile.CloseAction? {
        let pref = session.profile.closeAction
        guard pref == .ask else { return pref }
        return promptCloseAction(for: session)
    }

    /// Three-way prompt for `.ask` profiles (+ Cancel). Returns the chosen
    /// action, or nil on cancel.
    @MainActor private func promptCloseAction(for session: TabbedSessionWindow) -> Profile.CloseAction? {
        promptCloseAction(forName: session.profile.name)
    }

    @MainActor private func promptCloseAction(forName name: String) -> Profile.CloseAction? {
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("Close “%@”?", comment: ""), name)
        alert.informativeText = NSLocalizedString(
            "Run in the background keeps the VM running so you can reattach later. Suspend saves its state to disk. Shut down powers it off.",
            comment: "")
        alert.addButton(withTitle: NSLocalizedString("Run in the Background", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Suspend", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Shut Down", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .background
        case .alertSecondButtonReturn: return .suspend
        case .alertThirdButtonReturn:  return .shutdown
        default:                       return nil
        }
    }

    // MARK: - `bromure-cli` command-line tool

    /// Offer to symlink `/usr/local/bin/bromure-cli` → this app's binary so the
    /// user can drive Bromure from the terminal. Prompts once; "Don't Ask Again"
    /// is remembered. Skipped for the headless agent and dev (`swift run`) builds.
    @MainActor private func offerCLISymlinkIfNeeded() {
        guard !headless else { return }
        let linkPath = "/usr/local/bin/bromure-cli"
        guard !FileManager.default.fileExists(atPath: linkPath) else { return }
        guard !UserDefaults.standard.bool(forKey: "cliSymlinkDeclined") else { return }
        // Only when running from an installed .app, not a dev `swift run`.
        guard Bundle.main.bundleURL.pathExtension == "app",
              let exe = Bundle.main.executableURL?.path else { return }

        let alert = NSAlert()
        alert.messageText = NSLocalizedString(
            "Install the “bromure-cli” command-line tool?", comment: "")
        alert.informativeText = NSLocalizedString(
            "This creates a symlink at /usr/local/bin/bromure-cli so you can drive Bromure from the terminal (vm, exec, trace, …). It needs your admin password once.",
            comment: "")
        alert.addButton(withTitle: NSLocalizedString("Install", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Not Now", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Don’t Ask Again", comment: ""))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            installCLISymlink(target: exe, at: linkPath)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(true, forKey: "cliSymlinkDeclined")
        default:
            break   // Not Now — offer again next launch
        }
    }

    /// Create the symlink via AppleScript so macOS shows the standard admin
    /// authorization prompt (no embedded privileged helper needed).
    @MainActor private func installCLISymlink(target: String, at linkPath: String) {
        let cmd = "mkdir -p /usr/local/bin && ln -sf \\\"\(target)\\\" \(linkPath)"
        let script = "do shell script \"\(cmd)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            // -128 = the user cancelled the admin prompt; anything else is a real
            // failure worth logging (but never block startup over it).
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            if code != -128 {
                FileHandle.standardError.write(Data(
                    "[cli] symlink install failed: \(error)\n".utf8))
            }
        } else {
            FileHandle.standardError.write(Data(
                "[cli] installed \(linkPath) → \(target)\n".utf8))
        }
    }

    // MARK: - Boot at startup

    /// Install/remove the login LaunchAgent to match whether any profile wants
    /// startup boot. Called at launch and whenever a profile is saved.
    @MainActor func reconcileBootLaunchAgent() {
        BootLaunchAgent.reconcile(
            wantsStartupBoot: profiles.contains { $0.bootAtStartup },
            agentExecutable: Bundle.main.executableURL)
    }

    /// Boot every profile flagged `bootAtStartup`, detached (window-less). Only
    /// the headless login agent does this: the GUI doesn't auto-boot when the
    /// user opens it, and gating to the one process that the LaunchAgent starts
    /// avoids two agents racing to boot the same profile onto the same disk.
    @MainActor private func bootFlaggedProfilesAtStartup() {
        guard headless else { return }
        for profile in profiles where profile.bootAtStartup {
            guard runningSessions[profile.id] == nil else { continue }
            FileHandle.standardError.write(Data(
                "[boot] starting '\(profile.name)' at login\n".utf8))
            // `detached: true` boots window-less and leaves the app in its
            // `.accessory` (menu-bar-only) state — without it the unified window
            // pops up at login and promotes the app to a regular Dock app.
            launch(profile, detached: true)
            detachAfterBoot(profile.id)   // belt-and-suspenders; no window to close now
        }
    }

    /// Once the session for `id` registers, close its (possibly never-shown)
    /// window so the VM runs detached in the background. No-op if already
    /// detached. Used by start-in-background launches and login boots.
    @MainActor private func detachAfterBoot(_ id: Profile.ID) {
        Task { @MainActor in
            for _ in 0..<600 {   // up to ~60s for the first boot to register
                if runningSessions[id] != nil { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if let win = profileWindows[id] { win.close() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow else { return }
        // Registration throwaway window: route to its own teardown (destroys
        // the scratch VM + dir) instead of the normal per-profile session
        // cleanup, which would suspend/save state and could terminate the app.
        if let reg = claudeRegistration, win === reg.window {
            teardownClaudeRegistration(reason: .windowClosed)
            return
        }
        if win === mainWindow {
            mainWindow = nil
            updateActivationPolicy()
            return
        }
        if win === credentialApprovalsWindow {
            credentialApprovalsWindow = nil
            return
        }
        if win === supplyChainLogWindow {
            supplyChainLogWindow = nil
            return
        }
        if win === inferenceLogWindow {
            inferenceLogWindow = nil
            return
        }
        if win === traceInspectorWindow {
            traceInspectorWindow = nil
            return
        }
        if win === enrollmentWindow {
            enrollmentWindow = nil
            return
        }
        if let key = fileBrowserWindows.first(where: { $0.value === win })?.key {
            fileBrowserWindows[key] = nil
            return
        }
        if win === unifiedWindow {
            // Closing the shared window detaches every hosted VM to the
            // background (persistent-agent model): the VMs keep running and are
            // reattachable via the menu bar / `vm attach`. Per-VM stop happens
            // via the sidebar's × control, not by closing the whole window.
            let ids = panes.values
                .filter { $0.host === unifiedWindow }
                .map { $0.profile.id }
            for id in ids { detachSession(id) }
            updateActivationPolicy()
            return
        }
        if let session = win as? TabbedSessionWindow {
            // Re-dock in flight: the pane was already handed back to the unified
            // window. Don't touch the VM — just forget the popped-out window.
            if session.redocking {
                profileWindows.removeValue(forKey: session.profile.id)
                updateActivationPolicy()
                return
            }
            // Always tear down the window UI + snapshot tabs (so a reattaching
            // window rebuilds the bar against the kittys still alive in the
            // guest). Then act on the VM per the resolved close action.
            let id = session.profile.id
            if runningSessions[id] != nil {
                runningSessions[id]?.lastTabsSnapshot = session.snapshotTabs()
            }
            session.vmView.virtualMachine = nil
            session.keyboardBridge = nil
            session.scrollBridge = nil
            session.sandbox = nil
            profileWindows.removeValue(forKey: id)
            unregisterPane(id, ifMatches: session.pane)
            // `.background` (and a programmatic close, closeIntent == nil) leave
            // the VM running, detached. `.suspend` / `.shutdown` stop it via the
            // explicit stop path. `.ask` was already resolved in
            // windowShouldClose, so it never reaches here.
            switch session.closeIntent {
            case .suspend, .shutdown:
                if let action = session.closeIntent, runningSessions[id]?.stopping != true {
                    requestStopSession(id, action: action)
                }
            case .background, .ask, .none:
                break
            }
            session.closeIntent = nil
            refreshSidebar()
            updateStatusMenu()
            updateActivationPolicy()
        }
    }

    // MARK: - Screen wiring

    private func renderSetup() {
        guard let win = mainWindow else { return }
        win.title = "Bromure Agentic Coding"
        // Same ordering trap as renderPicker: must swap content view
        // first, otherwise the InitializingView's autolayout
        // constraints + contentMinSize=560 (set in renderInitializing)
        // pin the window above the 540 we want here. Cancel-during-
        // bake therefore left the welcome screen oversized.
        win.contentView = NSHostingView(rootView: SetupView(onStart: { [weak self] in
            self?.startInit()
        }))
        win.contentMinSize = .zero
        win.setContentSize(NSSize(width: 560, height: 500))
        win.center()
    }

    private func renderInitializing() {
        guard let win = mainWindow else { return }
        win.title = "Bromure Agentic Coding — Setup"
        // Sized to the InitializingView's intrinsic layout (header +
        // status pill + 280pt fixed console + footer + paddings). The
        // user can collapse the console disclosure to shrink further.
        let style = win.styleMask.union(.resizable)
        win.styleMask = style
        win.setContentSize(NSSize(width: 640, height: 480))
        win.contentMinSize = NSSize(width: 560, height: 240)
        win.center()
        win.contentView = NSHostingView(rootView: InitializingView(
            model: initProgress,
            onCancel: { [weak self] in self?.renderSetup() }
        ))
    }

    private func startInit(force: Bool = false) {
        // Note: we do NOT delete the version stamp here even when
        // force == true. The stamp gates whether existing sessions
        // can launch from the old image — wiping it would brick the
        // image the moment the user clicks "Rebuild Now". The build
        // path uses .partial files and only swaps + rewrites the
        // stamp when the new image is fully in place.
        initProgress.reset()
        renderInitializing()

        installTask = Task { @MainActor in
            defer { self.installTask = nil }
            do {
                try await imageManager.createBaseImage(
                    progress: { msg in
                        // High-level checkpoints: drive the status pill +
                        // bookmark the console log with a leading marker
                        // so they're easy to find in the firehose.
                        Task { @MainActor in
                            // Suppress updates after cancellation — the
                            // hosted SwiftUI view is being torn down on
                            // the same run loop tick and we don't want
                            // the observation chain over-releasing.
                            guard self.installTask != nil else { return }
                            self.initProgress.status = msg
                            self.initProgress.recordHostPhase(msg)
                            self.initProgress.appendLog("\n▶ " + msg + "\n")
                        }
                    },
                    output: { chunk in
                        // Raw guest serial bytes — append as-is so timing
                        // and apt's progress lines look the same as on stderr.
                        Task { @MainActor in
                            guard self.installTask != nil else { return }
                            self.initProgress.appendLog(chunk)
                        }
                    },
                    force: force
                )
                self.initProgress.stop()
                self.initProgress.isRunning = false
                FileHandle.standardError.write(Data(
                    "[init] line count: \(self.initProgress.linesSeen)\n".utf8))
                self.profiles = self.store.loadAll()
                // Base image is ready — close the installer window and open the
                // unified home (the standalone picker is gone).
                if let w = self.mainWindow { w.close() }
                self.mainWindow = nil
                self.showUnifiedWindowAsHome()
                if self.profiles.isEmpty { self.openEditorWindow(editing: nil) }
            } catch {
                self.initProgress.stop()
                self.initProgress.isRunning = false
                self.initProgress.error = error.localizedDescription
                // The bake's NAT path can't be repaired mid-flight — we
                // need to tear it down, kickstart vmnet, and start over.
                // Same UX as the session-side network-healer prompt.
                if case UbuntuImageError.noGuestNetwork = error {
                    await self.presentBakeNetworkHealerPrompt(force: force)
                }
            }
        }
    }

    @MainActor
    private func presentBakeNetworkHealerPrompt(force: Bool) async {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString(
            "Network Issue During Base-Image Build", comment: "")
        alert.informativeText = NSLocalizedString(
            "The installer VM didn't get a network address from macOS's shared networking (vmnet). The base-image build needs internet access to download packages.",
            comment: ""
        ) + "\n\n" + NSLocalizedString(
            "Bromure can restart the macOS networking daemons and try the build again. You'll be asked for your password.",
            comment: ""
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Repair and Retry", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            let ok = await NetworkHealer.shared.repair(.both)
            guard ok else {
                let failed = NSAlert()
                failed.messageText = NSLocalizedString(
                    "Network Repair Cancelled", comment: "")
                failed.informativeText = NSLocalizedString(
                    "The repair was cancelled or failed. Try again from the menu.",
                    comment: "")
                failed.alertStyle = .warning
                failed.addButton(withTitle: NSLocalizedString("OK", comment: ""))
                failed.runModal()
                return
            }
            startInit(force: force)
        default:
            return
        }
    }

    /// Insert (or refresh) the "Check for Updates…" item directly
    /// after "About …". Idempotent — drops any prior copy first so
    /// repeat calls don't stack duplicates. No-op if the updater
    /// hasn't been initialised (dev builds without SUPublicEDKey).
    fileprivate func installCheckForUpdatesMenuItem(into appMenu: NSMenu) {
        guard let updater = updaterController else { return }
        appMenu.items
            .filter { ($0.representedObject as? String) == "bromure.checkForUpdates" }
            .forEach { appMenu.removeItem($0) }
        let item = NSMenuItem(
            title: NSLocalizedString("Check for Updates…", comment: ""),
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: "")
        item.target = updater
        item.representedObject = "bromure.checkForUpdates"
        // Slot the item right after "About …". The two slots before it
        // are: 0 = About, 1 = separator (added in makeMainMenu).
        let insertIdx = min(2, appMenu.items.count)
        appMenu.insertItem(item, at: insertIdx)
        appMenu.insertItem(.separator(), at: insertIdx + 1)
    }

    /// Insert (or refresh) the "Enroll in bromure.io…" / "bromure.io
    /// Enrollment…" item directly under "Check for Updates…". When the
    /// updater hasn't been initialised (dev build), fall back to
    /// inserting just after About — the two layouts converge once
    /// `installCheckForUpdatesMenuItem` runs and pushes everyone down.
    /// Idempotent so re-running doesn't stack duplicates.
    fileprivate func installEnrollmentMenuItem(into appMenu: NSMenu) {
        appMenu.items
            .filter { ($0.representedObject as? String) == "bromure.enrollment" }
            .forEach { appMenu.removeItem($0) }
        let title = BACEnrollmentStore.load() == nil
            ? NSLocalizedString("Enroll in bromure.io…", comment: "")
            : NSLocalizedString("bromure.io Enrollment…", comment: "")
        let item = NSMenuItem(
            title: title,
            action: #selector(ACAppDelegate.openEnrollmentAction(_:)),
            keyEquivalent: "")
        item.target = self
        item.representedObject = "bromure.enrollment"
        let updaterIdx = appMenu.items.firstIndex {
            ($0.representedObject as? String) == "bromure.checkForUpdates"
        }
        // Right after Check for Updates… when present; otherwise the
        // slot just after "About + separator". `min` keeps us in
        // bounds on the still-being-built menu.
        let insertIdx: Int
        if let updaterIdx { insertIdx = updaterIdx + 1 }
        else { insertIdx = min(2, appMenu.items.count) }
        appMenu.insertItem(item, at: insertIdx)
    }

    /// Wired to the "Rebuild Base Image…" menu item. Confirms, then
    /// runs `init --force` from inside the GUI — same flow as the
    /// first-time setup, but proactive.
    private var traceInspectorWindow: NSWindow?
    private var inferenceMetricsWindow: NSWindow?
    private var credentialApprovalsWindow: NSWindow?
    private var enrollmentWindow: NSWindow?
    private var preferencesWindow: NSWindow?
    private var remoteAccessWindow: NSWindow?
    private var supplyChainLogWindow: NSWindow?
    private var inferenceLogWindow: NSWindow?
    /// File-browser panels, one per profile (keyed by profile id) so each
    /// session window gets its own, reused on subsequent clicks.
    private var fileBrowserWindows: [UUID: NSWindow] = [:]

    /// Wired to the "Trace Inspector…" menu item (⇧⌘I).
    /// Opens the inspector with no profile pre-filter.
    @objc func openInferenceMetricsAction(_ sender: Any?) {
        if let win = inferenceMetricsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = NSLocalizedString("Inference Metrics", comment: "")
        win.center()
        win.contentView = NSHostingView(rootView: InferenceMetricsView())
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        inferenceMetricsWindow = win
    }

    @objc func openTraceInspectorAction(_ sender: Any?) {
        openTraceInspector(for: nil)
    }

    /// Window menu → "Credential Approvals…". Lists every live consent
    /// grant (5 min / 1 hr / rest of session) with per-row Revoke and a
    /// "Revoke all" reset.
    @objc func openCredentialApprovalsAction(_ sender: Any?) {
        guard let broker = mitmEngine?.consent else { return }
        let names = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0.name) })

        if let win = credentialApprovalsWindow {
            win.contentView = NSHostingView(rootView: CredentialApprovalsView(
                broker: broker, profileNames: names,
                onClose: { [weak self] in self?.credentialApprovalsWindow = nil }))
            win.makeKeyAndOrderFront(nil)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 360),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = NSLocalizedString("Credential Approvals", comment: "")
        win.center()
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: CredentialApprovalsView(
            broker: broker, profileNames: names,
            onClose: { [weak self] in self?.credentialApprovalsWindow = nil }))
        win.makeKeyAndOrderFront(nil)
        credentialApprovalsWindow = win
    }

    /// Window menu → "Supply Chain Log…". A live `tail -f` of every
    /// supply-chain event the MITM proxy emits (socket.dev checks,
    /// OSV checks, age-gate / install-script / 451 actions). One
    /// window app-wide; reopening brings it forward.
    @objc func openSupplyChainLogAction(_ sender: Any?) {
        if let win = supplyChainLogWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 460),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = NSLocalizedString("Security Log", comment: "")
        win.center()
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: SupplyChainLogView(
            onClose: { [weak self] in self?.supplyChainLogWindow = nil }))
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        supplyChainLogWindow = win
    }

    /// Window menu → "Inference Engine Log…". A live tail of the on-device MLX
    /// engine's output (model load, "serving", OOM/crash, load errors) — so
    /// diagnosing a local-model problem doesn't mean digging through Console.
    /// One window app-wide; reopening brings it forward.
    @objc func openInferenceLogAction(_ sender: Any?) {
        if let win = inferenceLogWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 460),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = NSLocalizedString("Inference Engine Log", comment: "")
        win.center()
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: LogConsoleView.inferenceEngine())
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        inferenceLogWindow = win
    }

    /// Window menu → "Enroll in bromure.io…" / "bromure.io Enrollment".
    /// The same menu item swaps between two views depending on state:
    /// the entry sheet when not enrolled, the status panel when
    /// enrolled. Title is refreshed by `refreshEnrollmentMenuTitle()`
    /// whenever state changes.
    @objc func openEnrollmentAction(_ sender: Any?) {
        if let win = enrollmentWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = NSLocalizedString("bromure.io Enrollment", comment: "")
        win.center()
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.contentView = makeEnrollmentContentView(in: win)
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        enrollmentWindow = win
    }

    private func makeEnrollmentContentView(in window: NSWindow) -> NSView {
        if BACEnrollmentStore.load() == nil {
            return NSHostingView(rootView: BACEnrollmentSheet { [weak self, weak window] _ in
                window?.close()
                self?.enrollmentWindow = nil
                self?.refreshEnrollmentMenuTitle()
            })
        }
        return NSHostingView(rootView: BACEnrollmentStatusView { [weak self, weak window] in
            // After unenroll, swap the same window's content to the
            // entry sheet rather than closing — the user almost
            // certainly wanted to re-enroll against a different code
            // or workspace.
            guard let window else { return }
            window.contentView = self?.makeEnrollmentContentView(in: window)
            self?.refreshEnrollmentMenuTitle()
        })
    }

    /// Recompute (a) the private-profile set the cloud emitter
    /// gates on, and (b) the streaming flag every open session
    /// window's toolbar paints. Cheap — runs after profile load,
    /// after a profile save / delete, and after enrollment state
    /// changes. Single source of truth: `profiles` (the loaded
    /// store) + `BACEnrollmentStore.load()`.
    func refreshStreamingState() {
        let privateIDs = Set(profiles.filter { $0.privateMode }.map { $0.id })
        BACEventEmitter.shared.setPrivateProfiles(privateIDs)
        let enrolled = BACEnrollmentStore.load() != nil
        for (profileID, pane) in panes {
            pane.model.streamingActive = enrolled && !privateIDs.contains(profileID)
        }
    }

    /// Update the menu item label so it reflects the current state
    /// without the user having to open the window. Called from the
    /// state-change callback set up in `applicationDidFinishLaunching`.
    func refreshEnrollmentMenuTitle() {
        guard let main = NSApp.mainMenu, let windowMenu = NSApp.windowsMenu else { return }
        for item in windowMenu.items + (main.items.flatMap { $0.submenu?.items ?? [] }) {
            guard item.action == #selector(openEnrollmentAction(_:)) else { continue }
            item.title = BACEnrollmentStore.load() == nil
                ? NSLocalizedString("Enroll in bromure.io…", comment: "")
                : NSLocalizedString("bromure.io Enrollment…", comment: "")
        }
    }

    /// Window menu → "Profile Manager". With a base image this is the unified
    /// window (the home — the standalone picker is gone); before the base
    /// image exists it's the setup window, recreated if the user closed it.
    @objc func openProfileManagerAction(_ sender: Any?) {
        // Promote back to a regular (Dock-visible) app — we may be coming from
        // the status item while running as a background agent.
        NSApp.setActivationPolicy(.regular)
        if imageManager.hasBaseImage {
            showUnifiedWindowAsHome()
            return
        }
        // No base image yet — show (or recreate) the setup window.
        if let win = mainWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title = "Bromure Agentic Coding"
        win.delegate = self
        win.titlebarAppearsTransparent = false
        win.animationBehavior = .none
        win.center()
        win.isReleasedWhenClosed = false
        self.mainWindow = win
        renderSetup()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Open (or focus) the unified window as the app's home, populated with the
    /// full profile list. Replaces the old standalone picker.
    func showUnifiedWindowAsHome() {
        NSApp.setActivationPolicy(.regular)
        let w = ensureUnifiedWindow()
        refreshSidebar()
        // Pick a sensible initial selection so the stage isn't blank: a running
        // attached pane keeps its own; otherwise show the first profile's card.
        if w.selectedID == nil, let first = w.listModel.profileRows.first {
            w.selectRow(first.id)
        }
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Open (or focus) the Trace Inspector window. Pass a profile to
    /// pre-fill the profile filter — used by the session window's
    /// toolbar button so clicking it on a profile's window scopes the
    /// inspector to that profile. Pass nil for the "all profiles" view.
    func openTraceInspector(for profile: Profile?) {
        if let win = traceInspectorWindow {
            // Existing window — re-host with the new filter so the
            // user always lands on the profile they clicked from.
            if let store = mitmEngine?.traceStore {
                win.contentView = NSHostingView(rootView: TraceInspectorView(
                    store: store, profiles: profiles,
                    initialProfileFilter: profile?.id))
            }
            win.makeKeyAndOrderFront(nil)
            return
        }
        guard let store = mitmEngine?.traceStore else { return }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        win.title = NSLocalizedString("Trace Inspector", comment: "")
        win.center()
        win.contentView = NSHostingView(rootView: TraceInspectorView(
            store: store,
            profiles: profiles,
            initialProfileFilter: profile?.id
        ))
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        traceInspectorWindow = win
    }

    /// Open (or re-focus) a Finder-like browser over this profile's VM
    /// filesystem. The guest's /home/ubuntu and any shared folders are
    /// host directories mounted via virtiofs, so the panel just reads
    /// and writes them directly — dragging a file out copies it to the
    /// Mac, dropping one in drops it into the VM.
    /// Title-bar lightning toggle → push the engaged/disengaged state
    /// into the MITM engine so the proxy hot path picks it up live.
    func setFusionEngaged(_ engaged: Bool, for profile: Profile) {
        mitmEngine?.setFusionEngaged(engaged, for: profile.id)
        runningSessions[profile.id]?.fusionEngaged = engaged
        // Keep the attached window's title-bar toggle in sync (e.g. when the
        // change came from the CLI rather than the toggle itself).
        pane(for: profile.id)?.model.fusionEngaged = engaged
    }

    func openFileBrowser(for window: TabbedSessionWindow) {
        openFileBrowser(profile: window.profile)
    }

    func openFileBrowser(profile: Profile) {
        if let win = fileBrowserWindows[profile.id] {
            win.makeKeyAndOrderFront(nil)
            return
        }

        let home = store.homeDirectory(for: profile)
        // The home dir is created during session prep; make sure it
        // exists in case the browser is opened very early in boot.
        try? FileManager.default.createDirectory(
            at: home, withIntermediateDirectories: true)

        var locations: [FileBrowserLocation] = [
            FileBrowserLocation(
                name: NSLocalizedString("Home", comment: ""),
                url: home,
                guestPath: "/home/ubuntu",
                symbol: "house")
        ]
        // Shared folders are symlinked to ~/<basename> inside the guest
        // on first boot — surface them as their guest-side path.
        for path in profile.folderPaths.prefix(8) {
            let base = (path as NSString).lastPathComponent
            locations.append(FileBrowserLocation(
                name: base,
                url: URL(fileURLWithPath: path),
                guestPath: "/home/ubuntu/\(base)",
                symbol: "folder"))
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = String(
            format: NSLocalizedString("Files — %@", comment: "file browser title"),
            profile.name)
        win.center()
        win.animationBehavior = .none
        win.contentView = NSHostingView(rootView: FileBrowserView(
            model: FileBrowserModel(locations: locations)))
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        fileBrowserWindows[profile.id] = win
    }

    @objc func openPreferencesAction(_ sender: Any?) {
        if let win = preferencesWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        win.title = NSLocalizedString("Bromure — Preferences",
                                       comment: "Preferences window title")
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self
        let template = store.loadTemplate()
        win.contentView = NSHostingView(rootView: ProfileEditorView(
            profile: template,
            terminalDefaults: terminalDefaults,
            storageContext: nil,
            onSave: { [weak self] updated, _ in
                guard let self else { return }
                do {
                    try self.store.saveTemplate(updated)
                } catch {
                    self.showError(error,
                                    message: "Couldn't save preferences.")
                    return
                }
                self.preferencesWindow?.close()
                self.preferencesWindow = nil
            },
            onCancel: { [weak self] in
                self?.preferencesWindow?.close()
                self?.preferencesWindow = nil
            },
            claudeAccountSavedAt: { [weak self] in self?.mitmEngine?.claudeSubscriptionStore.record(for: nil)?.savedAt },
            onRegisterClaude: { [weak self] in
                self?.beginSubscriptionRegistration(provider: .claude, scope: .alwaysShared)
            },
            onForgetClaude: { [weak self] in
                try? self?.mitmEngine?.claudeSubscriptionStore.forget(for: nil)
                NotificationCenter.default.post(name: .bromureSubscriptionStoresChanged, object: nil)
            },
            codexAccountSavedAt: { [weak self] in self?.mitmEngine?.codexSubscriptionStore.record(for: nil)?.savedAt },
            onRegisterCodex: { [weak self] in
                self?.beginSubscriptionRegistration(provider: .codex, scope: .alwaysShared)
            },
            onForgetCodex: { [weak self] in
                try? self?.mitmEngine?.codexSubscriptionStore.forget(for: nil)
                NotificationCenter.default.post(name: .bromureSubscriptionStoresChanged, object: nil)
            },
            grokAccountSavedAt: { [weak self] in self?.mitmEngine?.grokSubscriptionStore.record(for: nil)?.savedAt },
            onRegisterGrok: { [weak self] in
                self?.beginSubscriptionRegistration(provider: .grok, scope: .alwaysShared)
            },
            onForgetGrok: { [weak self] in
                try? self?.mitmEngine?.grokSubscriptionStore.forget(for: nil)
                NotificationCenter.default.post(name: .bromureSubscriptionStoresChanged, object: nil)
            },
            onFetchFusionModels: { provider, authMode, apiKey, completion in
                Task {
                    let m = await Fusion.listModels(provider: provider, authMode: authMode,
                                                    apiKey: apiKey, profileID: nil)
                    await MainActor.run { completion(m) }
                }
            }
        ))
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindow = win
    }

    @objc func openRemoteAccessAction(_ sender: Any?) {
        if let win = remoteAccessWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        win.title = NSLocalizedString("Remote Access", comment: "Remote access window title")
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.contentView = NSHostingView(rootView: RemoteAccessSettingsView(
            status: { [weak self] in MainActor.assumeIsolated { self?.remoteAccessStatus() ?? [:] } },
            apply: { [weak self] spec in MainActor.assumeIsolated { self?.remoteAccessApply(spec) ?? ["error": "unavailable"] } },
            addKey: { [weak self] key in MainActor.assumeIsolated { self?.remoteAccessAddKey(key) ?? ["error": "unavailable"] } },
            removeKey: { [weak self] sel in MainActor.assumeIsolated { self?.remoteAccessRemoveKey(sel) ?? ["error": "unavailable"] } }
        ))
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        remoteAccessWindow = win
    }

    @objc func rebuildBaseImageAction(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Rebuild the base image?"
        alert.informativeText = "Re-runs the full Ubuntu installer (~5–10 min) using the current setup.sh. Existing workspaces' disks aren't touched — on next launch each one's drift prompt will offer to reset to the new base."
        alert.addButton(withTitle: "Rebuild")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            startInit(force: true)
        }
    }

    /// Non-blocking nag shown on each launch when the on-disk base
    /// image stamp is older than the app's bundled `imageVersion`.
    /// "Later" dismisses for this launch only — we'll ask again next
    /// time the app starts so the user keeps the option without being
    /// blocked from running stale images.
    private func promptBaseImageUpdate() {
        let alert = NSAlert()
        let installed = imageManager.installedImageVersion ?? "?"
        alert.messageText = NSLocalizedString("Base image update available", comment: "")
        alert.informativeText = String(
            format: NSLocalizedString(
                "Your base image is at version %@ but the app ships version %@. The current image still works — rebuilding (~5–10 min) picks up the latest setup.sh changes (new tools, updated configs).",
                comment: ""),
            installed, UbuntuImageManager.imageVersion)
        alert.addButton(withTitle: NSLocalizedString("Rebuild Now", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Later", comment: ""))
        if alert.runModal() == .alertFirstButtonReturn {
            startInit(force: true)
        }
    }


    /// Deep-copy a profile (new UUID, new MAC) using `ProfileStore.duplicate`.
    /// Includes the system disk + home dir via APFS clonefile, the encrypted
    /// secrets blob, host-only ssh material, and every credential — but
    /// skips the suspended VM state (a snapshot tied to the source's MAC
    /// can't safely resume on the duplicate).
    /// Pick a default name for a brand-new profile that doesn't
    /// collide with any existing profile name. Walks "Default profile",
    /// "Default profile 2", "Default profile 3", … and returns the
    /// first one not currently taken (case-insensitive comparison so
    /// users typing "default profile" don't get an unexpected dupe).
    private func nextDefaultProfileName() -> String {
        let base = NSLocalizedString("Default workspace",
                                      comment: "Placeholder name for a new profile")
        let existing = Set(profiles.map { $0.name.lowercased() })
        if !existing.contains(base.lowercased()) { return base }
        var n = 2
        while existing.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    private func duplicateProfile(_ source: Profile) {
        let copyName = source.name + " " + NSLocalizedString("copy", comment: "")
        do {
            _ = try store.duplicate(source, named: copyName)
        } catch {
            showError(error, message: "Couldn't duplicate “\(source.name)”.")
            return
        }
        profiles = store.loadAll()
        refreshSidebar()
    }

    /// editing == nil → create. editing != nil → modify in place.
    func openEditorWindow(editing: Profile?) {
        // Reuse the open editor ONLY when it's already editing this same
        // profile; for a different profile (or a new-profile draft) tear the
        // old one down and rebuild. The previous guard re-surfaced whatever
        // editor was open regardless of `editing`, so once any profile's
        // Settings had been opened, every later "Settings" click re-showed
        // that same window — and since the editor isn't nil'd on a red-button
        // close, it stuck to the first profile edited this session.
        if let existing = editorWindow {
            if editorEditingProfile?.id == editing?.id {
                existing.makeKeyAndOrderFront(nil)
                return
            }
            closeEditorWindow()
        }
        editorEditingProfile = editing

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        win.title = editing == nil ? "New workspace" : "Edit workspace"
        win.center()
        // For new profiles, hand the editor a draft pre-populated from
        // the user's preferences template (Bromure → Preferences…)
        // and a numbered placeholder name so the user can save
        // immediately without typing one. Existing profiles keep
        // their own values.
        let initialDraft: Profile? = editing
            ?? store.newProfileFromTemplate(name: nextDefaultProfileName())
        win.contentView = NSHostingView(rootView: ProfileEditorView(
            profile: initialDraft,
            isNew: editing == nil,
            terminalDefaults: terminalDefaults,
            storageContext: makeStorageContext(for: editing),
            onSave: { profile, generateSSH in
                self.handleEditorSave(profile: profile, generateSSH: generateSSH, editing: editing)
            },
            onCancel: { self.closeEditorWindow() },
            onImportSSHKey: { [weak self] url, passphrase, label in
                // Import requires a saved profile (we need an id for
                // the on-disk path + keychain account). For new
                // profiles, save once first.
                guard let self else {
                    throw NSError(domain: "BromureAC", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "App not available"])
                }
                let target = editing ?? self.store.newProfileFromTemplate(name: "")
                if editing == nil {
                    try self.store.save(target)
                }
                return try self.importSSHKey(at: url, passphrase: passphrase,
                                              label: label, for: target)
            },
            onRemoveSSHKey: { [weak self] key in
                guard let self, let editing else { return }
                self.removeImportedSSHKey(key, for: editing)
            },
            claudeAccountSavedAt: (editing ?? initialDraft).map { p in
                { [weak self] in
                    self?.mitmEngine?.claudeSubscriptionStore.record(for: p.id)?.savedAt
                        ?? self?.mitmEngine?.claudeSubscriptionStore.record(for: nil)?.savedAt
                }
            },
            onRegisterClaude: (editing ?? initialDraft).map { p in
                { [weak self] in self?.beginSubscriptionRegistration(provider: .claude, scope: .askPerSession(p.id)) }
            },
            onForgetClaude: (editing ?? initialDraft).map { p in
                { [weak self] in
                    try? self?.mitmEngine?.claudeSubscriptionStore.forget(for: p.id)
                    NotificationCenter.default.post(name: .bromureSubscriptionStoresChanged, object: nil)
                }
            },
            codexAccountSavedAt: (editing ?? initialDraft).map { p in
                { [weak self] in
                    self?.mitmEngine?.codexSubscriptionStore.record(for: p.id)?.savedAt
                        ?? self?.mitmEngine?.codexSubscriptionStore.record(for: nil)?.savedAt
                }
            },
            onRegisterCodex: (editing ?? initialDraft).map { p in
                { [weak self] in self?.beginSubscriptionRegistration(provider: .codex, scope: .askPerSession(p.id)) }
            },
            onForgetCodex: (editing ?? initialDraft).map { p in
                { [weak self] in
                    try? self?.mitmEngine?.codexSubscriptionStore.forget(for: p.id)
                    NotificationCenter.default.post(name: .bromureSubscriptionStoresChanged, object: nil)
                }
            },
            grokAccountSavedAt: (editing ?? initialDraft).map { p in
                { [weak self] in
                    self?.mitmEngine?.grokSubscriptionStore.record(for: p.id)?.savedAt
                        ?? self?.mitmEngine?.grokSubscriptionStore.record(for: nil)?.savedAt
                }
            },
            onRegisterGrok: (editing ?? initialDraft).map { p in
                { [weak self] in self?.beginSubscriptionRegistration(provider: .grok, scope: .askPerSession(p.id)) }
            },
            onForgetGrok: (editing ?? initialDraft).map { p in
                { [weak self] in
                    try? self?.mitmEngine?.grokSubscriptionStore.forget(for: p.id)
                    NotificationCenter.default.post(name: .bromureSubscriptionStoresChanged, object: nil)
                }
            },
            onFetchFusionModels: { provider, authMode, apiKey, completion in
                let pid = (editing ?? initialDraft)?.id
                Task {
                    let m = await Fusion.listModels(provider: provider, authMode: authMode,
                                                    apiKey: apiKey, profileID: pid)
                    await MainActor.run { completion(m) }
                }
            }
        ))
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        editorWindow = win
    }

    /// Snapshot of where this profile's data lives + how to nuke it.
    /// Re-read each time the editor opens so sizes / version reflect the
    /// latest state. Closures route to the existing reset handlers,
    /// which own their own confirmation alerts.
    private func makeStorageContext(for editing: Profile?) -> ProfileStorageContext {
        let baseURL = imageManager.baseDiskURL
        let buildDate = (try? FileManager.default.attributesOfItem(
            atPath: imageManager.versionStampURL.path)[.modificationDate]) as? Date
        guard let editing else {
            return ProfileStorageContext(
                baseImageURL: baseURL,
                baseImageVersion: readCurrentBaseVersion(),
                baseImageBuildDate: buildDate,
                profileDiskURL: nil,
                profileHomeURL: nil,
                isRunning: false,
                onResetDisk: {},
                onResetHome: {}
            )
        }
        return ProfileStorageContext(
            baseImageURL: baseURL,
            baseImageVersion: readCurrentBaseVersion(),
            baseImageBuildDate: buildDate,
            profileDiskURL: store.diskURL(for: editing),
            profileHomeURL: store.homeDirectory(for: editing),
            isRunning: isAttached(editing.id),
            onResetDisk: { [weak self] in self?.resetProfile(editing) },
            onResetHome: { [weak self] in self?.resetHomeProfile(editing) }
        )
    }

    func closeEditorWindow() {
        editorWindow?.close()
        editorWindow = nil
        editorEditingProfile = nil
    }

    private func openSSHWindow(for profile: Profile) {
        guard let pub = profile.sshPublicKey else { return }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        win.title = "SSH public key"
        win.center()
        win.contentView = NSHostingView(rootView: SSHKeyView(
            profileName: profile.name,
            publicKey: pub,
            onDone: { self.sshWindow?.close(); self.sshWindow = nil }
        ))
        win.isReleasedWhenClosed = false
        win.makeKeyAndOrderFront(nil)
        sshWindow = win
    }

    // MARK: - Profile actions

    private func handleEditorSave(profile: Profile, generateSSH: Bool, editing: Profile?) {
        var profile = profile
        // Belt-and-braces: trim every secret before persisting. Pasted
        // tokens routinely come with trailing whitespace; embedding
        // either in an HTTP header value at swap time would corrupt
        // the request and trigger a "401 Invalid API key" upstream.
        let trim = { (s: String?) in
            s?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        profile.apiKey = trim(profile.apiKey)
        profile.additionalTools = profile.additionalTools.map { spec in
            var s = spec
            s.apiKey = trim(s.apiKey)
            return s
        }
        profile.gitHTTPSCredentials = profile.gitHTTPSCredentials.map { c in
            var copy = c
            copy.token = c.token.trimmingCharacters(in: .whitespacesAndNewlines)
            return copy
        }
        profile.manualTokens = profile.manualTokens.map { t in
            var copy = t
            copy.realValue = t.realValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return copy
        }

        // Shared-folder edits are incompatible with a suspended VM:
        // virtiofs shares become slot-tagged VZDirectoryShares in the VM
        // config (share-1, share-2, …), and xinitrc — which materializes
        // the symlinks under ~ from /mnt/bromure-meta/shares.txt — only
        // runs on cold boot, not on resume. So changing folderPaths while
        // a saved state exists either crashes the restore or silently
        // ignores the new config. Warn the user and invalidate.
        if let original = editing, original.folderPaths != profile.folderPaths {
            let stateURL = store.profileDirectory(for: profile)
                .appendingPathComponent("vm.state")
            if FileManager.default.fileExists(atPath: stateURL.path) {
                let alert = NSAlert()
                alert.messageText = String(
                    format: NSLocalizedString("Discard suspended VM for “%@”?", comment: ""),
                    profile.name)
                alert.informativeText = NSLocalizedString(
                    "The shared folders changed since this workspace was suspended. The snapshot was saved against the old share set, so it can't be safely resumed with the new one.\n\nSaving will discard the suspended state. The next launch will cold-boot. Files in the per-workspace home directory and on the shared folders themselves are unaffected.",
                    comment: "")
                alert.alertStyle = .warning
                alert.addButton(withTitle: NSLocalizedString("Discard & save", comment: ""))
                alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                try? FileManager.default.removeItem(at: stateURL)
                // tabs.json pairs with the snapshot — without the matching
                // VM, the saved tab UUIDs point at kittys that won't exist
                // on the next cold boot.
                let tabsURL = store.profileDirectory(for: profile)
                    .appendingPathComponent("tabs.json")
                try? FileManager.default.removeItem(at: tabsURL)
            }
        }

        // Editing keeps the original id (already preserved by ProfileEditorView).
        do {
            try store.save(profile)
            try store.prepareHomeDirectory(for: profile, terminalDefaults: terminalDefaults)
            let agentDir = store.profileDirectory(for: profile)
                .appendingPathComponent("agent", isDirectory: true)
            if generateSSH {
                // Agent dir is host-only — never mounted into the VM.
                // The private seed lives here; the public key gets a
                // courtesy copy into the VM's ~/.ssh for reference.
                let pub = try makeSSHKey(in: agentDir)
                profile.sshPublicKey = pub
                try store.save(profile)
            } else if editing == nil,
                      profile.sshPublicKey != nil,
                      !FileManager.default.fileExists(atPath:
                        agentDir.appendingPathComponent("id_ed25519.raw").path) {
                // New profile that inherited the default public key
                // from the preferences template — copy the matching
                // private seed in so the in-process ssh-agent has
                // something to load. No-op when "Generate" was ticked
                // (handled above) or when the user already imported a
                // key (existing raw file).
                try DefaultSSHKey.copy(to: agentDir)
            }
        } catch {
            showError(error, message: editing == nil
                      ? "Couldn't create the workspace."
                      : "Couldn't save the workspace.")
            return
        }
        profiles = store.loadAll()
        refreshSidebar()
        reconcileBootLaunchAgent()   // a saved bootAtStartup change may flip the plist
        // The privateMode toggle and enrollment-gated streaming flag
        // both flow off `profiles`; resync the running session
        // toolbars now so a flip from public → private (or back)
        // doesn't wait for the next launch to take effect.
        refreshStreamingState()
        closeEditorWindow()
        // Show the SSH key viewer right after a brand-new generation so the
        // user can paste it into GitHub before forgetting.
        if generateSSH, profile.sshPublicKey != nil { openSSHWindow(for: profile) }

        // If the user edited a profile that already has a session
        // window open, push the host-side cosmetic bits through live
        // (window title, opacity, accent) and prompt to restart for
        // anything that's baked into the booted VM or its host home
        // dir. Without this, settings appear to "not stick" until the
        // user closes and reopens the session.
        if editing != nil, let win = pane(for: profile.id) {
            let runningProfile = win.profile
            win.applyLiveProfileUpdates(profile)
            // Push env vars, credentials (wire-swap map + guest-side
            // credential files), and guardrail policy into the running
            // MITM engine + live shares — no reboot for these. Only things
            // genuinely baked into the booted VM (memory, mounts, the
            // auto-launched tool, sshd/kube/SSO wiring) fall through to the
            // restart prompt below.
            applyLiveSessionRefresh(from: runningProfile, to: profile,
                                    terminalDefaults: terminalDefaults, window: win)
            let restartItems = restartRequiringChanges(from: runningProfile, to: profile)
            if !restartItems.isEmpty {
                promptRestartForChanges(items: restartItems, window: win)
            }
        }
    }

    /// Per-field categories that change behaviour inside the booted
    /// VM (and therefore need a restart to take effect). Used to
    /// coalesce diffs into a small, user-facing list of bullet points.
    private enum RestartChange: CaseIterable {
        case memory
        case networking
        case sharedFolders
        case primaryTool
        case additionalTools
        case sshPublicKey
        case httpsGitCredentials
        case manualTokens
        case importedSSHKeys
        case environmentVariables
        case traceLevel
        case kubernetes
        case digitalOcean
        case awsCredentials
        case containerRegistries
        case approvalGates
        case keyboardSettings
        case terminalAppearance
        case gitIdentity
    }

    private func restartLabel(for change: RestartChange) -> String {
        switch change {
        case .memory:
            return NSLocalizedString("VM memory", comment: "")
        case .networking:
            return NSLocalizedString("Network mode", comment: "")
        case .sharedFolders:
            return NSLocalizedString("Shared folders", comment: "")
        case .primaryTool:
            return NSLocalizedString("Primary tool / auth mode", comment: "")
        case .additionalTools:
            return NSLocalizedString("Additional tools", comment: "")
        case .sshPublicKey:
            return NSLocalizedString("SSH public key", comment: "")
        case .httpsGitCredentials:
            return NSLocalizedString("HTTPS git credentials", comment: "")
        case .manualTokens:
            return NSLocalizedString("Manual token rules", comment: "")
        case .importedSSHKeys:
            return NSLocalizedString("Imported SSH keys", comment: "")
        case .environmentVariables:
            return NSLocalizedString("Environment variables", comment: "")
        case .traceLevel:
            return NSLocalizedString("Trace level", comment: "")
        case .kubernetes:
            return NSLocalizedString("Kubernetes contexts", comment: "")
        case .digitalOcean:
            return NSLocalizedString("DigitalOcean token", comment: "")
        case .awsCredentials:
            return NSLocalizedString("AWS credentials", comment: "")
        case .containerRegistries:
            return NSLocalizedString("Container registry credentials", comment: "")
        case .approvalGates:
            return NSLocalizedString("Credential approval gates", comment: "")
        case .keyboardSettings:
            return NSLocalizedString("Cursor / keyboard settings", comment: "")
        case .terminalAppearance:
            return NSLocalizedString("Terminal font and colors", comment: "")
        case .gitIdentity:
            return NSLocalizedString("Git author identity", comment: "")
        }
    }

    /// Diff two profiles and return the user-facing categories that
    /// require a VM restart. Cosmetic / host-side fields (name,
    /// color, comments, windowOpacity, closeAction, privateMode,
    /// timestamps, default-token caches, subscription swap state,
    /// `baseImageVersionAtClone`) are intentionally omitted — the
    /// caller has already applied them live or they're consulted at
    /// host-side decision points where re-reading the saved profile
    /// is enough.
    private func restartRequiringChanges(from old: Profile, to new: Profile) -> [String] {
        var changes: [RestartChange] = []
        if old.memoryGB != new.memoryGB { changes.append(.memory) }
        if old.networkMode != new.networkMode
            || old.bridgedInterfaceID != new.bridgedInterfaceID {
            changes.append(.networking)
        }
        if old.folderPaths != new.folderPaths { changes.append(.sharedFolders) }
        // Note: a plain API-key change is NOT here — it's applied live
        // (api_key.env + swap map). Only switching the tool itself or its
        // auth mode needs a restart, since that re-runs the agent
        // auto-launch and the token/subscription wiring.
        if old.tool != new.tool || old.authMode != new.authMode {
            changes.append(.primaryTool)
        }
        if old.additionalTools != new.additionalTools { changes.append(.additionalTools) }
        if old.sshPublicKey != new.sshPublicKey { changes.append(.sshPublicKey) }
        if old.importedSSHKeys != new.importedSSHKeys { changes.append(.importedSSHKeys) }
        // Applied live by applyLiveSessionRefresh — no restart needed:
        //   env vars, guardrails (incl. per-endpoint HTTPS-database modes),
        //   the primary API key, manual tokens, HTTPS git credentials,
        //   DigitalOcean PAT, container-registry creds, git identity, and the
        //   trace level (the proxy re-reads the per-session level live).
        // All of these are header/env/file credentials that re-read live
        // off the meta + home virtiofs shares and the swap map.
        // Kube + AWS keep their prompt: the engine-side client-identity /
        // cluster-CA / exec-poller and AWS-SSO refresh-loop wiring is only
        // set up on cold boot, even though their config files refresh live.
        if old.kubeconfigs != new.kubeconfigs { changes.append(.kubernetes) }
        if old.awsCredentials != new.awsCredentials { changes.append(.awsCredentials) }
        if old.apiKeyRequiresApproval != new.apiKeyRequiresApproval
            || old.digitalOceanTokenRequiresApproval != new.digitalOceanTokenRequiresApproval
            || old.sshKeyRequiresApproval != new.sshKeyRequiresApproval {
            changes.append(.approvalGates)
        }
        if old.cursorShape != new.cursorShape
            || old.keyboardLayoutOverride != new.keyboardLayoutOverride
            || old.keyRepeatDelayMs != new.keyRepeatDelayMs
            || old.keyRepeatRateHz != new.keyRepeatRateHz {
            changes.append(.keyboardSettings)
        }
        if old.useTerminalAppDefaults != new.useTerminalAppDefaults
            || old.customFontFamily != new.customFontFamily
            || old.customFontSize != new.customFontSize
            || old.customBackgroundHex != new.customBackgroundHex
            || old.customForegroundHex != new.customForegroundHex {
            changes.append(.terminalAppearance)
        }
        // Git identity (~/.gitconfig) is rewritten live into the home share.
        return changes.map { restartLabel(for: $0) }
    }

    /// True if an edit touches anything the live refresh re-emits: env
    /// vars, guardrail policy, or any credential (which moves the token
    /// swap map and/or the api_key.env / proxy.env content). Cosmetic
    /// edits (name, color, opacity) return false so the guest doesn't
    /// print a spurious "environment refreshed" line.
    private func sessionRefreshAffectingChange(from old: Profile, to new: Profile) -> Bool {
        old.environmentVariables != new.environmentVariables
            || old.guardrails != new.guardrails
            || old.supplyChain != new.supplyChain
            || old.promptInjection != new.promptInjection
            || old.httpDatabases != new.httpDatabases
            || old.tool != new.tool
            || old.authMode != new.authMode
            || old.apiKey != new.apiKey
            || old.additionalTools != new.additionalTools
            || old.manualTokens != new.manualTokens
            || old.gitHTTPSCredentials != new.gitHTTPSCredentials
            || old.digitalOceanToken != new.digitalOceanToken
            || old.dockerRegistries != new.dockerRegistries
            || old.awsCredentials != new.awsCredentials
            || old.kubeconfigs != new.kubeconfigs
            || old.mcpServers != new.mcpServers
            || old.gitUserName != new.gitUserName
            || old.gitUserEmail != new.gitUserEmail
    }

    /// Apply env-var / credential / guardrail edits to a running session
    /// in place — no reboot. Three live surfaces are refreshed:
    ///
    ///   1. **Guardrail policy** — read live per request, so an
    ///      off→read-only flip lands on the next proxied call.
    ///   2. **The token swap map** — re-minted fakes are a pure function
    ///      of (real value, install salt), so unchanged credentials keep
    ///      the exact fake the running agent already holds; changed/added
    ///      ones get fresh entries.
    ///   3. **Guest-side files** — `proxy.env` / `api_key.env` / MCP
    ///      configs in the meta share *and* the credential files in the
    ///      `bromure-home` virtiofs share (`~/.git-credentials`, docker /
    ///      gh / glab / doctl / aws / kube configs, `~/.gitconfig`). Both
    ///      shares are live-mounted, and the in-VM tools re-read them per
    ///      command, so a `git push` / `docker pull` uses the new value
    ///      immediately. `env.generation` is bumped so open shells
    ///      re-source the env on their next prompt.
    ///
    /// Remaining caveat: the already-running *foreground agent* keeps its
    /// launch-time process environment (Unix env is frozen at exec) until
    /// it restarts, and the engine-side wiring for a handful of credential
    /// types — the kube client-identity / cluster-CA / exec-poller setup,
    /// the AWS-SSO refresh loop, and the ssh-agent key load — is only done
    /// on cold boot. Those categories keep their restart prompt; env vars
    /// and the common file/header credentials do not.
    private func applyLiveSessionRefresh(from old: Profile, to new: Profile,
                                         terminalDefaults: TerminalAppDefaults,
                                         window win: SessionPane) {
        // Fusion config can change without tripping the session-refresh guard
        // below (e.g. editing legs/judge), so reconcile it first and
        // unconditionally. Engagement is the user's per-session choice via the
        // title-bar toggle — we don't auto-engage; we only force-off when the
        // profile is no longer configurable.
        _ = old
        let nowConfigurable = new.fusionConfigurable
        win.model.fusionConfigurable = nowConfigurable
        mitmEngine?.setFusionConfig(makeFusionConfig(for: new), for: new.id)
        if !nowConfigurable {
            win.model.fusionEngaged = false
            mitmEngine?.setFusionEngaged(false, for: new.id)
        }

        // Trace level is consulted live by the proxy on every request, so update
        // the running session's level in place (keeping its session id so the
        // trace grouping isn't fragmented). Done unconditionally — a trace-level
        // change on its own doesn't trip the credential/env guard below.
        if old.traceLevel != new.traceLevel, let engine = mitmEngine {
            let sid = engine.sessionTrace(for: new.id)?.sessionID ?? UUID()
            engine.setSessionTrace(.init(sessionID: sid, level: new.traceLevel), for: new.id)
        }

        // Local model / routing: agents are pinned to the `bromure-local`
        // sentinel, so switching the active model (or routing mode) is a
        // host-side remap — re-point the sentinel + engine and update routing,
        // with no reboot and no agent restart. Done unconditionally (before the
        // guard) since neither field trips the credential/env diff below.
        if old.activeModelID != new.activeModelID || old.modelRouting != new.modelRouting {
            if let engine = mitmEngine { applyRouting(engine, for: new) }
            startLocalEngineIfNeeded(for: new)
        }

        guard sessionRefreshAffectingChange(from: old, to: new) else { return }

        // Guardrail config is consulted live on every proxied request —
        // update it unconditionally so a mode change lands even when no
        // credential moved.
        mitmEngine?.setGuardrailsConfig(Self.makeGuardrailsConfig(for: new), for: new.id)
        // Supply-chain policy follows the same live-update rule.
        mitmEngine?.setSupplyChainPolicy(new.supplyChain, for: new.id)
        // Prompt-injection detection policy — same live-update rule. Enabling
        // a detector kicks a background model download if it's not installed.
        mitmEngine?.setPromptInjectionPolicy(new.promptInjection, for: new.id)
        if new.promptInjection.detectSourceInjection { PromptInjectionModels.ensureInstalledInBackground(.promptGuard) }
        if new.promptInjection.detectRulesInjection { PromptInjectionModels.ensureInstalledInBackground(.claudeMdGuard) }

        var profile = new
        populateMCPBearerTokens(in: &profile)
        let salt = mitmEngine?.fakeTokenSalt ?? Data(repeating: 0, count: 32)
        let plan = self.sessionTokenPlan(for: profile, salt: salt)

        var kubeYAML: String?
        if let engine = mitmEngine {
            // Full map = profile plan + kubeconfig bearer/exec swaps, the
            // same composition the launch path builds.
            var fresh = plan.tokenMap()
            let kubeMat = KubeconfigMaterializer().materialize(
                profile: profile, bromureCAPEM: engine.ca.certificatePEM)
            kubeYAML = kubeMat.yaml
            for swap in kubeMat.bearerSwaps {
                fresh.entries.append(TokenMap.Entry(
                    fake: swap.fakeToken, real: swap.realToken, host: swap.host,
                    consentCredentialID: swap.consentCredentialID,
                    consentDisplayName: swap.consentDisplayName))
            }
            // Merge rather than replace. A *changed* credential mints a new
            // fake, but the still-running agent's process env holds the
            // OLD one; preserving the old entries (whose fakes aren't
            // reissued) lets in-flight work finish on the old value instead
            // of erroring, while new shells pick up the new fake. Same
            // additive pattern the subscription / OAuth coordinators use.
            let freshFakes = Set(fresh.entries.map(\.fake))
            let preserved = engine.swapper.entries(for: profile.id)
                .filter { !freshFakes.contains($0.fake) }
            engine.swapper.setMap(TokenMap(entries: fresh.entries + preserved),
                                  for: profile.id)
        }

        // Rewrite the guest-side credential files into the live home share
        // with fakes. This also overwrites any real-token copy the
        // plan-less editor-save `prepareHomeDirectory` (above) just wrote
        // there, closing that window for a running session.
        try? store.prepareHomeDirectory(for: profile,
                                        terminalDefaults: terminalDefaults,
                                        tokenPlan: plan,
                                        kubeconfigYAML: kubeYAML)

        // Rewrite api_key.env / proxy.env / MCP configs into the stable
        // meta-share dir and bump env.generation for the guest's
        // PROMPT_COMMAND hook.
        do {
            try win.sandbox?.sessionDisk?.refreshMetadataShare(
                profile: profile, tokenPlan: plan)
        } catch {
            NSLog("[bromure-ac] live env refresh failed: \(error)")
        }
    }

    /// Sheet a non-modal alert against the running session window,
    /// listing the changed settings the VM hasn't picked up and
    /// offering a reboot (which routes through `requestReboot`'s
    /// usual soft / hard / cancel chooser). "Later" leaves the VM
    /// alone — the next time it cold-boots it'll inherit the new
    /// values from the saved profile JSON.
    @MainActor
    private func promptRestartForChanges(items: [String], window: SessionPane) {
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString(
                "Restart “%@” to apply these changes?", comment: ""),
            window.profile.name)
        let bullets = items.map { "• " + $0 }.joined(separator: "\n")
        alert.informativeText = String(
            format: NSLocalizedString(
                "These settings are baked into the VM at boot, so the running session won't pick them up until it restarts:\n\n%@",
                comment: ""),
            bullets)
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("Restart Now…", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Later", comment: ""))
        guard let host = window.host?.paneHostWindow else {
            // No window to anchor a sheet (headless) — fall back to a modal.
            if alert.runModal() == .alertFirstButtonReturn { requestReboot(for: window) }
            return
        }
        alert.beginSheetModal(for: host) { [weak self, weak window] response in
            guard response == .alertFirstButtonReturn,
                  let self, let window else { return }
            self.requestReboot(for: window)
        }
    }

    /// Send one `vm.disk_reset` event to the workspace backend so admins
    /// can correlate "this install was reset" with the supply-chain
    /// timeline that precedes / follows it. `BACEventEmitter` already
    /// no-ops when the Mac isn't enrolled or the profile is in private
    /// mode, so this is safe to call unconditionally.
    private func emitDiskResetEvent(profile: Profile, reason: String) {
        var data: [String: AnyJSON] = [
            "reason": .string(reason),
        ]
        if let v = profile.baseImageVersionAtClone {
            data["base_image_version_at_clone"] = .string(v)
        }
        if let v = readCurrentBaseVersion() {
            data["base_image_version_current"] = .string(v)
        }
        BACEventEmitter.shared.emitDetached(
            profileID: profile.id,
            eventType: "vm.disk_reset",
            eventData: data)
    }

    private func resetProfile(_ profile: Profile) {
        if runningSessions[profile.id] != nil {
            showRunningRefusal(profile: profile, what: "system disk")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Reset “\(profile.name)” system disk to base?"
        alert.informativeText = """
        Wipes the per-profile read-write copy of the OS:
        • Anything you `sudo apt install`ed inside the VM
        • Modifications to /etc, /var, /usr, /opt
        • System-wide config edits

        Your home folder is untouched — projects, dotfiles, .ssh keys, \
        npm-global, .cargo, and shell history all survive.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset to base")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try store.resetDisk(for: profile)
            emitDiskResetEvent(profile: profile, reason: "user_requested")
        } catch {
            showError(error, message: "Couldn't reset the disk.")
        }
    }

    /// Wipe the per-profile home directory. Inverse blast-radius from
    /// `resetProfile`: system layer survives, but everything personal
    /// the user accumulated under /home/ubuntu is gone.
    private func resetHomeProfile(_ profile: Profile) {
        if runningSessions[profile.id] != nil {
            showRunningRefusal(profile: profile, what: "home folder")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Erase the home folder for “\(profile.name)”?"
        alert.informativeText = """
        Wipes everything under /home/ubuntu inside the VM:
        • Project clones and files anywhere in your home dir
        • Shell history and .bashrc.local customizations
        • npm-global, ~/.cargo, language-server caches
        • SSH keypair (regenerate from the Credentials pane)

        Bromure-managed files (.bashrc, kitty config, .gitconfig, \
        .git-credentials, gh / glab CLI configs) are rebuilt from your \
        profile settings on next launch. The system disk is untouched.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Erase Home")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try store.resetHome(for: profile)
            // The private SSH key lived only in profiles/<id>/home/.ssh.
            // It's gone now — clear the public key too so the editor's
            // Credentials pane doesn't keep claiming we have a keypair
            // on file. The user can regenerate from the same place.
            if profile.sshPublicKey != nil {
                var p = profile
                p.sshPublicKey = nil
                try? store.save(p)
                profiles = store.loadAll()
                refreshSidebar()
            }
        } catch {
            showError(error, message: "Couldn't erase the home folder.")
        }
    }

    private func showRunningRefusal(profile: Profile, what: String) {
        let alert = NSAlert()
        alert.messageText = "Close “\(profile.name)” first."
        alert.informativeText = "The \(what) is in use by the running VM. Resetting it now would corrupt the live session — close the session window and try again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func deleteProfile(_ profile: Profile) {
        let alert = NSAlert()
        alert.messageText = "Delete workspace “\(profile.name)”?"
        alert.informativeText = "Removes its disk, settings, and SSH key. The mounted host folder is untouched."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try store.delete(profile)
            profiles = store.loadAll()
            refreshSidebar()
        } catch {
            showError(error, message: "Couldn't delete the workspace.")
        }
    }

    /// If any local model this profile would load is still downloading, returns
    /// its display name + repo so callers can refuse to boot. nil once every
    /// selected model is fully present. The single source of truth for the
    /// "don't boot mid-download" guard (GUI `launch` + CLI `vm run`).
    @MainActor func downloadingModel(for profile: Profile) -> (name: String, repo: String)? {
        for modelID in profile.distinctLocalModelIDs {
            let resolved = CatalogStore.shared.resolve(modelID)
            let repo = resolved?.repo ?? modelID
            if ModelDownloadManager.shared.isDownloading(repo: repo) {
                return (resolved?.name ?? repo, repo)
            }
        }
        return nil
    }

    /// Boot (or reveal) a profile's session. When `detached` is true the VM
    /// boots window-less — no pane is hosted, the session runs headless from the
    /// start (the `vm run -d` / login-boot / remote-menu path), reattachable
    /// later.
    func launch(_ profile: Profile, detached: Bool = false) {
        // Already shown → just focus + select it (unless we were asked to detach,
        // in which case drop the window and leave the VM running headless).
        if isAttached(profile.id) {
            if detached { detachSession(profile.id) } else { revealSession(profile.id) }
            return
        }
        // Running but detached (window was closed, VM kept alive). Asked to
        // detach → it already is, nothing to do. Otherwise reattach a fresh
        // window onto the live VM, with its tabs intact.
        if let session = runningSessions[profile.id] {
            if !detached { attachWindow(to: session) }
            return
        }

        // Refuse to boot while any local model this profile needs is still
        // downloading — the agent would come up pointed at an engine that
        // can't load yet, producing a wall of connection errors.
        if let dl = downloadingModel(for: profile) {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Model still downloading", comment: "")
            alert.informativeText = String(
                format: NSLocalizedString(
                    "“%@” is still downloading. Wait for it to finish, then launch “%@”.",
                    comment: ""),
                dl.name, profile.name)
            alert.alertStyle = .warning
            alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
            alert.runModal()
            return
        }

        // Compromised profiles refuse to boot until the user confirms
        // a wipe of the disk + home (the parts the malware could have
        // modified). Tokens, ssh material, and the rest of profile.json
        // are kept — the user wants to keep the profile around. Shared
        // folders are NOT touched (they live outside Bromure's storage
        // and may legitimately hold the user's source); the alert
        // surfaces this so the user knows where to look next.
        if SessionDisk.isCompromised(profile: profile, store: store) {
            if !confirmWipeAndProceed(profile: profile) {
                return
            }
            // Fall through — disk + home are gone, flag is cleared,
            // launch path now treats this like any first launch.
        }

        // Drift check: if the base image has been rebuilt since this
        // profile's disk was cloned, prompt to reset.
        let currentBaseVersion = readCurrentBaseVersion()
        let diskExists = FileManager.default.fileExists(atPath: store.diskURL(for: profile).path)
        if diskExists,
           let recorded = profile.baseImageVersionAtClone,
           let current = currentBaseVersion,
           recorded != current {
            let alert = NSAlert()
            alert.messageText = "Base image updated since this workspace was created."
            alert.informativeText = "This workspace is on base v\(recorded); the current base is v\(current). Reset the workspace disk to pick up the new base? (Resetting wipes anything you've installed inside the VM. Your project folder is untouched.)"
            alert.addButton(withTitle: "Reset and launch")
            alert.addButton(withTitle: "Launch as-is")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                try? store.resetDisk(for: profile)
                emitDiskResetEvent(profile: profile, reason: "base_image_drift")
            case .alertThirdButtonReturn:
                return
            default:
                break
            }
        }

        try? store.touch(profile)

        // Build the per-session token plan up front: real values stay
        // here (and on the host's MITM engine); fakes flow into the VM
        // via prepareHomeDirectory and the meta share. The plan is
        // deterministic in (real value, install salt) so Claude Code
        // doesn't see the fake rotate session-to-session.
        var profile = profile
        populateMCPBearerTokens(in: &profile)
        let salt = mitmEngine?.fakeTokenSalt ?? Data(repeating: 0, count: 32)
        let plan = self.sessionTokenPlan(for: profile, salt: salt)
        // (prepareHomeDirectory call moved below — needs the
        // materialized kubeconfig YAML produced by the engine block.)

        // Push the plan + ssh keys to the engine before VM start, so
        // the listeners we register after boot have something to swap.
        var kubeYAMLForVM: String?
        if let engine = mitmEngine {
            // Materialize the synthetic kubeconfig + extract bearer
            // swaps + client identities + exec contexts.
            let kubeMat = KubeconfigMaterializer().materialize(
                profile: profile, bromureCAPEM: engine.ca.certificatePEM)
            kubeYAMLForVM = kubeMat.yaml

            // Token map = the profile-derived plan + the kubeconfig
            // bearer/exec swap entries.
            var tokenMap = plan.tokenMap()
            for swap in kubeMat.bearerSwaps {
                tokenMap.entries.append(TokenMap.Entry(
                    fake: swap.fakeToken, real: swap.realToken, host: swap.host,
                    consentCredentialID: swap.consentCredentialID,
                    consentDisplayName: swap.consentDisplayName))
            }
            engine.swapper.setMap(tokenMap, for: profile.id)

            // Per-host client identities for upstream mTLS (kubectl
            // → API server).
            for ident in kubeMat.clientIdentities {
                engine.clientIdentities.setIdentity(
                    ident.identity, host: ident.host, profileID: profile.id,
                    consentCredentialID: ident.consentCredentialID,
                    consentDisplayName: ident.consentDisplayName)
            }
            // Per-host CA overrides so the proxy can verify private
            // API-server certs that don't chain to macOS roots.
            for entry in kubeMat.clusterCAs {
                engine.clusterCAs.setCA(
                    pem: entry.caPEM, host: entry.host, profileID: profile.id)
            }
            // Exec-credential poller: refreshes the swap map on a
            // schedule for each context. Cancelled in unregister.
            if !kubeMat.execContexts.isEmpty {
                engine.execPoller.start(kubeMat.execContexts,
                                        profileID: profile.id,
                                        swapper: engine.swapper)
            }
        }
        // Drop the synthetic kubeconfig + every other managed
        // dotfile into the VM's home dir. Done after the engine
        // block so kubeYAMLForVM is materialized.
        try? store.prepareHomeDirectory(for: profile,
                                        terminalDefaults: terminalDefaults,
                                        tokenPlan: plan,
                                        kubeconfigYAML: kubeYAMLForVM)
        // Codex subscription: seed a bogus ~/.codex/auth.json before boot so
        // the guest runs without logging in (host owns the real token).
        seedCodexAuthFile(for: profile)
        seedGrokAuthFile(for: profile)
        if let engine = mitmEngine {
            // Tell the trace store what level + session id to record
            // under for traffic from this profile.
            engine.setSessionTrace(
                MitmEngine.SessionTrace(sessionID: UUID(), level: profile.traceLevel),
                for: profile.id)
            // Profile name lookup for the consent dialog ("Profile X
            // wants to use credential Y").
            let broker = engine.consent
            let pidCopy = profile.id
            let nameCopy = profile.name
            Task.detached { await broker.setProfileName(nameCopy, for: pidCopy) }
            // Same plumbing for the guardrails prompt — "Allow write
            // on <scope> from profile <name>?"
            let gBroker = engine.guardrailsBroker
            Task.detached { await gBroker.setProfileName(nameCopy, for: pidCopy) }
            // And for the supply-chain prompts.
            let scBroker = engine.supplyChainBroker
            Task.detached { await scBroker.setProfileName(nameCopy, for: pidCopy) }
            let agentKeys = loadAgentKeys(for: profile)
            engine.sshAgent.setKeys(agentKeys, for: profile.id)
            // AWS creds: pushed to the host-side server. The guest's
            // ~/.aws/config points at a credential_process helper that
            // gets the real AKID + a fake secret; the host AWSResigner
            // re-signs each AWS request with the real material so the
            // secret never lives in the VM at all. setCredentials clears
            // the slot when the profile has no usable AWS creds.
            if profile.awsCredentials.authMode == .ssoProfile
                || profile.authMode == .bedrock {
                let profileID = profile.id
                let ssoProfileName = profile.awsCredentials.ssoProfileName
                let awsCreds = profile.awsCredentials
                FileHandle.standardError.write(Data(
                    "[sso] resolving credentials for SSO profile '\(ssoProfileName)'\n".utf8))
                Task { [weak engine, weak self] in
                    guard let engine else { return }
                    do {
                        let resolved = try await AWSSSOResolver.resolve(
                            profileName: ssoProfileName,
                            progress: { msg in
                                FileHandle.standardError.write(Data("[sso] \(msg)\n".utf8))
                            }
                        )
                        var creds = awsCreds
                        creds.accessKeyID = resolved.accessKeyID
                        creds.secretAccessKey = resolved.secretAccessKey
                        creds.sessionToken = resolved.sessionToken
                        if creds.region.isEmpty { creds.region = resolved.region }
                        engine.awsCreds.setCredentials(creds, for: profileID)

                        self?.ssoRefreshTasks[profileID] = AWSSSOResolver.startRefreshLoop(
                            profileName: ssoProfileName,
                            initialExpiration: resolved.expiration,
                            onRefresh: { [weak engine] newCreds in
                                var updated = awsCreds
                                updated.accessKeyID = newCreds.accessKeyID
                                updated.secretAccessKey = newCreds.secretAccessKey
                                updated.sessionToken = newCreds.sessionToken
                                engine?.awsCreds.setCredentials(updated, for: profileID)
                                FileHandle.standardError.write(Data(
                                    "[sso] refreshed credentials for '\(ssoProfileName)'\n".utf8))
                            },
                            onError: { error in
                                FileHandle.standardError.write(Data(
                                    "[sso] refresh failed: \(error.localizedDescription)\n".utf8))
                            }
                        )
                    } catch {
                        FileHandle.standardError.write(Data(
                            "[sso] credential resolution failed: \(error.localizedDescription)\n".utf8))
                        engine.awsCreds.setCredentials(awsCreds, for: profileID)
                    }
                }
            } else {
                engine.awsCreds.setCredentials(profile.awsCredentials, for: profile.id)
            }
            FileHandle.standardError.write(Data(
                "[mitm] session launch for '\(profile.name)': loaded \(agentKeys.count) agent key(s)\n".utf8))
            // Mirror the per-profile key into our private bromure
            // ssh-agent so the in-VM ssh client can sign with it
            // through the vsock-bridged agent socket.
            for key in agentKeys {
                addKeyToHostAgent(seed: key.seed,
                                  publicKey: key.publicKey,
                                  comment: "bromure-ac:\(profile.name)")
            }
            // Plus any pre-existing keys the user imported via the
            // editor — passphrase-protected ones use the macOS Keychain
            // for the password, fed through SSH_ASKPASS.
            loadImportedSSHKeys(for: profile)
            // Register approval metadata for imported keys whose flag
            // is on. The agent forwards SIGN_REQUESTs for these to the
            // host's bromure ssh-agent (we don't hold the seed in
            // process), so the broker is consulted just before that
            // forward. Keys without `publicKeyText` (no .pub on import)
            // can't be matched by blob and will sign without a prompt.
            var approvals: [Data: SSHAgentServer.ImportedApproval] = [:]
            for k in profile.importedSSHKeys where k.requireApproval {
                guard let blob = sshPublicKeyBlob(fromOpenSSHText: k.publicKeyText)
                else { continue }
                approvals[blob] = SSHAgentServer.ImportedApproval(
                    label: k.label,
                    consentCredentialID: ConsentCredentialID.sshKey(k.id.uuidString))
            }
            engine.sshAgent.setImportedKeyApprovals(approvals, for: profile.id)
        } else {
            FileHandle.standardError.write(Data(
                "[mitm] session launch for '\(profile.name)': MITM ENGINE IS NIL — nothing will be wired\n".utf8))
        }

        // Create the pane that draws this VM. It's hosted in the shared unified
        // window (the unpeel-style source-list of every running VM) unless this
        // is a detached login-boot — then it boots window-less and the session
        // lives on detached. Promote to a regular app first in case we're
        // launching from a headless/background agent.
        let win = SessionPane(profile: profile, acDelegate: self)
        if detached {
            // Boots window-less: the pane binds the VZ view through boot, then
            // drops once the VM registers, leaving the session running detached.
            // Reattach via the menu-bar item or `vm attach`.
        } else {
            let unified = ensureUnifiedWindow()
            unified.addPane(win)
            NSApp.setActivationPolicy(.regular)
            unified.makeKeyAndOrderFront(nil)
        }
        // Newly-registered window — sync its streaming indicator
        // with the current enrollment + privateMode state.
        refreshStreamingState()
        refreshSidebar()

        // Pre-load saved tabs alongside the saved RAM snapshot. If
        // both exist, the resumed VM already has matching kittys
        // running (each one was started with `--class bromure-<UUID>`)
        // — we rebuild the host's tab bar against those instead of
        // spawning a brand-new kitty on top.
        let probeDisk = SessionDisk(
            profile: profile,
            store: store,
            baseDiskURL: imageManager.baseDiskURL
        )
        let savedTabs: SessionDisk.TabsState? =
            probeDisk.hasSavedState ? probeDisk.loadTabs() : nil

        if let saved = savedTabs, !saved.tabs.isEmpty {
            win.rehydrateTabs(from: saved)
        } else {
            // Fresh boot: show one placeholder pill while VZ + tmux come up.
            // The agent auto-creates tmux window 0; the roster reconciles this
            // placeholder to the real window list within a tick.
            win.model.tabs = [TabsModel.Tab(label: "shell")]
        }

        Task { @MainActor in
            let sessionDisk = SessionDisk(
                profile: profile,
                store: store,
                baseDiskURL: imageManager.baseDiskURL
            )
            sessionDisk.tokenPlan = plan
            if let engine = mitmEngine, let scriptURL = bridgeScriptURL {
                sessionDisk.mitmAssets = SessionDisk.MitmSessionAssets(
                    caCertificatePEM: engine.ca.certificatePEM,
                    bridgeScriptURL: scriptURL,
                    keyboardAgentURL: keyboardAgentURL,
                    scrollAgentURL: scrollAgentURL,
                    awsCredsHelperURL: awsCredsHelperURL,
                    claudeTokenAgentURL: claudeTokenAgentURL,
                    codexTokenAgentURL: codexTokenAgentURL,
                    // Always ship the shell agent now — `exec` is a first-class
                    // CLI verb, gated by the owner-only control socket.
                    shellAgentURL: shellAgentURL,
                    loopbackRelayAgentURL: loopbackRelayAgentURL)
            }
            let sandbox = UbuntuSandboxVM(imageManager: imageManager, sessionDisk: sessionDisk)
            // True only when the resumed snapshot's kittys are still
            // valid — drives spawn-vs-raise at the end of this block.
            var restoredSnapshot = false
            do {
                try sandbox.prepare()
                win.vmView.virtualMachine = sandbox.vm
                // Investigation mode: the saved snapshot was taken with
                // a NIC attached, but `prepare()` just built a config
                // with no network device — VZ would reject `restore`
                // for config drift. Boot fresh from the persisted disk
                // (the home dir + filesystem state are intact) so the
                // user can inspect on-disk artifacts offline.
                if sandbox.hasSavedState {
                    do {
                        try await sandbox.restore()
                        restoredSnapshot = true
                        FileHandle.standardError.write(Data(
                            "[ac] restored '\(profile.name)' from saved state\n".utf8))
                    } catch {
                        // Restore failed — bad snapshot, configuration
                        // drift, or VZ refused. Drop the state file and
                        // do a fresh boot.
                        FileHandle.standardError.write(Data(
                            "[ac] restore failed (\(error)) — booting fresh\n".utf8))
                        sessionDisk.clearSavedState()
                        // VZ leaves the VM in an indeterminate state
                        // after a failed restore; rebuild it.
                        try sandbox.prepare()
                        win.vmView.virtualMachine = sandbox.vm
                        try await sandbox.start()
                        // Restore failed → this is now a fresh boot. Drop the
                        // rehydrated pills; the agent creates tmux window 0 and
                        // the roster repopulates the bar.
                        win.model.tabs = [TabsModel.Tab(label: "shell")]
                        win.model.activeIndex = 0
                    }
                } else {
                    try await sandbox.start()
                }
            } catch {
                self.showError(error, message: "Couldn't start the VM for “\(profile.name)”.")
                self.unifiedWindow?.removePane(profile.id)
                self.unregisterPane(profile.id, ifMatches: win)
                return
            }
            // Register the per-VM vsock listeners on the freshly-booted
            // VM. Done after start so the socket device is live.
            if let engine = self.mitmEngine, let dev = sandbox.socketDevice {
                engine.register(socketDevice: dev, profileID: profile.id)
                engine.setGuardrailsConfig(Self.makeGuardrailsConfig(for: profile), for: profile.id)
                engine.setSupplyChainPolicy(profile.supplyChain, for: profile.id)
                engine.setPromptInjectionPolicy(profile.promptInjection, for: profile.id)
                if profile.promptInjection.detectSourceInjection { PromptInjectionModels.ensureInstalledInBackground(.promptGuard) }
                if profile.promptInjection.detectRulesInjection { PromptInjectionModels.ensureInstalledInBackground(.claudeMdGuard) }
                // Fusion: show the title-bar toggle when configured, but
                // start disengaged — the user clicks the lightning bolt to
                // turn it on for the session.
                win.model.fusionConfigurable = profile.fusionConfigurable
                win.model.fusionEngaged = false
                engine.setFusionEngaged(false, for: profile.id)
                engine.setFusionConfig(self.makeFusionConfig(for: profile), for: profile.id)
                self.applyRouting(engine, for: profile)
                self.startLocalEngineIfNeeded(for: profile)
            }
            // Keyboard layout bridge — pushes the macOS layout into the
            // guest at boot and follows live changes (or pins an
            // override layout when the profile sets one).
            if let dev = sandbox.socketDevice {
                win.keyboardBridge = KeyboardBridge(
                    socketDevice: dev,
                    forcedLayout: profile.keyboardLayoutOverride)
            }
            win.scrollBridge = makeScrollBridge(for: sandbox)
            // Shell-exec bridge (vsock 5800). Always created now — powers
            // `bromure-ac exec` and the control socket's /exec route. The guest
            // ships shell-agent.py unconditionally; the surface is gated by the
            // owner-only control socket, not the debug env var.
            if let dev = sandbox.socketDevice {
                let bridge = ShellBridge(socketDevice: dev)
                self.shellBridges[profile.id] = bridge
            }
            if sessionDisk.didCloneOnLastEnsure, let current = currentBaseVersion {
                var p = profile
                p.baseImageVersionAtClone = current
                try? self.store.save(p)
                self.profiles = self.store.loadAll()
                self.refreshSidebar()
            }
            self.wireSandboxCallbacks(sandbox)
            self.registerSession(sandbox, profile: profile)
            win.sandbox = sandbox

            // No host-driven spawn/raise any more: the guest agent launches
            // the one fullscreen kitty → tmux session at X start (fresh boot),
            // and a restored snapshot already has that session with its windows
            // and last-active window intact. The roster repopulates the bar.

            // NAT-only: watch for the in-guest IP reporter to land an
            // address. If nothing arrives within the timeout, vmnet's
            // shared NAT path is likely wedged — offer to repair via
            // the same NetworkHealer the browser uses.
            if profile.networkMode == .nat {
                self.startNetworkHealerWatch(profile: profile, pane: win)
            }
        }
    }

    /// Per-session network-health watch. Polls the window's reported
    /// IP for ~25s. If the guest hasn't gotten an address by then,
    /// presents a Repair / Continue / Cancel dialog; on Repair runs
    /// `NetworkHealer.shared.repair(.both)` and relaunches the
    /// session against a fresh VM.
    @MainActor
    private func startNetworkHealerWatch(profile: Profile,
                                         pane: SessionPane) {
        Task { @MainActor [weak self, weak pane] in
            // 25 polls × 1s = 25s window. xinitrc reports the address
            // on a 5s loop, so we expect it well within this budget on
            // a healthy install (typically 4-8s after boot).
            for _ in 0..<25 {
                try? await Task.sleep(for: .seconds(1))
                if pane == nil { return }
                if pane?.model.ipAddress?.isEmpty == false { return }
            }
            guard let self, let pane,
                  pane.host?.paneHostWindow?.isVisible == true else { return }
            // Re-check inside the @MainActor isolation in case the IP
            // landed during the last sleep tick.
            if pane.model.ipAddress?.isEmpty == false { return }
            await self.presentNetworkHealerPrompt(profile: profile, pane: pane)
        }
    }

    @MainActor
    private func presentNetworkHealerPrompt(profile: Profile,
                                            pane: SessionPane) async {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Network Issue", comment: "")
        alert.informativeText = NSLocalizedString(
            "The VM didn't get a network address. macOS's shared networking stack (vmnet) may be wedged.",
            comment: ""
        ) + "\n\n" + NSLocalizedString(
            "Bromure can restart the macOS networking daemons. You'll be asked for your password.",
            comment: ""
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Repair Network", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Continue Anyway", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            // Tear down the wedged session before kickstarting — the
            // VM's NIC needs a fresh DHCP exchange after the daemon
            // restart, easier from a clean boot than mid-session.
            detachSession(profile.id)
            let ok = await NetworkHealer.shared.repair(.both)
            if !ok {
                let failed = NSAlert()
                failed.messageText = NSLocalizedString("Network Repair Cancelled", comment: "")
                failed.informativeText = NSLocalizedString(
                    "The repair was cancelled or failed. Try again from the menu.",
                    comment: ""
                )
                failed.alertStyle = .warning
                failed.addButton(withTitle: NSLocalizedString("OK", comment: ""))
                failed.runModal()
                return
            }
            // Fresh launch with kickstarted vmnet.
            launch(profile)
        case .alertSecondButtonReturn:
            // Continue with the broken VM — user opted out of repair.
            return
        default:
            // Cancel: just detach the wedged session (VM keeps running).
            detachSession(profile.id)
        }
    }

    /// Add another tab (= a new tmux window). Wired from the toolbar "+"
    /// button and ⌘T. The roster tick adds the pill — tmux is authoritative.
    func spawnNewTab(in pane: SessionPane) {
        sendCommand("new-tab", in: pane)
    }

    /// Select a tab → tmux select-window at that index (index == bar position).
    func requestSelectTab(index: Int, in pane: SessionPane) {
        sendCommand("select-tab \(index)", in: pane)
    }

    /// Close a tab → tmux kill-window at that index.
    func requestCloseTab(index: Int, in pane: SessionPane) {
        sendCommand("close-tab \(index)", in: pane)
    }

    private func sendCommand(_ command: String, in pane: SessionPane) {
        guard let outbox = pane.sandbox?.sessionDisk?.outboxDirectory else { return }
        let file = outbox.appendingPathComponent("cmd-\(UUID().uuidString).txt")
        try? (command + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// Confirm + execute the wipe of a compromised profile. Returns
    /// true if the user accepted and the wipe ran, false on cancel.
    /// On true, the caller proceeds with the regular launch path —
    /// the disk + home no longer exist, so it'll mint fresh ones.
    @MainActor
    private func confirmWipeAndProceed(profile: Profile) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        if let symbol = NSImage(
            systemSymbolName: "exclamationmark.octagon.fill",
            accessibilityDescription: "Compromised VM warning") {
            let cfg = NSImage.SymbolConfiguration(pointSize: 64, weight: .bold)
                .applying(.init(paletteColors: [.systemRed]))
            alert.icon = symbol.withSymbolConfiguration(cfg)
        }
        alert.messageText = String(
            format: NSLocalizedString("⛔ “%@” is marked as compromised", comment: ""),
            profile.name)
        var info = NSLocalizedString(
            "Bromure refused to boot this VM because the proxy detected an outbound credential leak in a previous session.",
            comment: "")
        info += "\n\n"
        info += NSLocalizedString(
            "To continue, the VM disk image and the persistent home folder must be wiped. Your tokens, ssh keys, and workspace settings are preserved.",
            comment: "")
        // Surface the shared-folder warning. Listing the paths
        // explicitly is cheap and makes "where do I look?" obvious.
        let shares = profile.folderPaths
        if !shares.isEmpty {
            info += "\n\n"
            info += NSLocalizedString(
                "WARNING: shared folders are NOT wiped. Compromised packages or files may still be present in:",
                comment: "")
            info += "\n"
            for path in shares {
                info += "  • \(path)\n"
            }
            info += NSLocalizedString(
                "Inspect those folders before launching anything that re-uses them.",
                comment: "")
        }
        alert.informativeText = info
        alert.addButton(withTitle: NSLocalizedString("Wipe and Launch", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        // Esc → Cancel. Don't let an enter-press auto-confirm a
        // destructive wipe; remove the default keyEquivalent on the
        // first button so the user has to click it explicitly.
        alert.buttons.first?.keyEquivalent = ""
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let session = SessionDisk(
            profile: profile, store: store,
            baseDiskURL: imageManager.baseDiskURL)
        session.wipeForCompromise()
        emitDiskResetEvent(profile: profile, reason: "compromised")
        // Re-render so the badge disappears immediately. (`launch`
        // continues right after this, but the picker behind the
        // session window will reflect the change once focus returns.)
        refreshSidebar()
        return true
    }

    /// True while a compromise alert is up on screen. The swap-time
    /// detector can fire many times back-to-back (one per outbound
    /// request the VM attempts); without this flag we'd stack alerts
    /// behind each other instead of letting the user act once.
    private var compromiseAlertActive: Bool = false

    /// Handle a compromise event: pause the VM immediately so no further
    /// outbound bytes flow, then present the alert. The user picks
    /// Shutdown / Save for Investigation / Continue and we drive the
    /// VM accordingly.
    @MainActor
    func handleCompromise(_ event: CompromiseEvent) {
        if compromiseAlertActive { return }
        // The VM may be detached (no pane, VM still running). A compromise must
        // still pause it and surface the alert, so force a reattach first — that
        // binds a view to the live VM so the user sees the frozen frame.
        if !isAttached(event.profileID),
           let session = runningSessions[event.profileID] {
            attachWindow(to: session)
        }
        guard let window = pane(for: event.profileID),
              let sandbox = window.sandbox,
              let vm = sandbox.vm else { return }
        // Surface the compromised VM (select it in the unified window / bring
        // its pop-out forward) so the frozen frame is actually on screen.
        revealSession(event.profileID)

        compromiseAlertActive = true

        // Pause now — synchronous from the user's perspective. If pause
        // is unavailable (already paused or VM in error state) we just
        // proceed: the proxy already wrote a 451 back to the guest, so
        // the malicious request was blocked regardless.
        Task { @MainActor in
            defer { self.compromiseAlertActive = false }
            if vm.canPause {
                do { try await vm.pause() }
                catch {
                    FileHandle.standardError.write(Data(
                        "[ac] compromise: pause failed (\(error))\n".utf8))
                }
            }
            // Tint goes on AFTER pause so the user sees the
            // last-rendered frame freeze and bloom red, not the
            // tint flash before the framebuffer stops.
            window.setSuspendedTint(true)

            let action = self.presentCompromiseAlert(event: event,
                                                      profileName: window.profile.name)
            switch action {
            case .shutdown:
                // No export, but the disk + home are still presumed
                // contaminated. Mark compromised; the next launch will
                // refuse to boot until the user wipes.
                sandbox.sessionDisk?.markCompromised()
                sandbox.sessionDisk?.clearSavedState()
                vm.stop(completionHandler: { _ in })
                self.detachSession(event.profileID)

            case .saveForInvestigation:
                // Pick a destination folder, then bundle (1) the disk
                // image, (2) a tar.gz of the per-profile home dir,
                // (3) one tar.gz per shared folder. Whether the export
                // succeeds or not, the profile gets the compromised
                // mark — the user has already classified this VM as
                // suspicious and shouldn't be allowed to launch it
                // again without an explicit wipe.
                if let dest = self.askForInvestigationDestination(profileName: window.profile.name),
                   let session = sandbox.sessionDisk {
                    do {
                        try self.exportForInvestigation(
                            session: session,
                            destination: dest)
                        FileHandle.standardError.write(Data(
                            "[ac] investigation export complete → \(dest.path)\n".utf8))
                    } catch {
                        FileHandle.standardError.write(Data(
                            "[ac] investigation export failed: \(error)\n".utf8))
                        self.showError(error,
                                       message: "Couldn't export the VM for investigation. The workspace will still be marked compromised.")
                    }
                }
                sandbox.sessionDisk?.markCompromised()
                sandbox.sessionDisk?.clearSavedState()
                vm.stop(completionHandler: { _ in })
                self.detachSession(event.profileID)

            case .continueAnyway:
                // User accepted the risk. Resume the VM. The proxy
                // already returned 451 for the leaking request — if
                // the VM tries again, the detector fires again and
                // the alert re-opens.
                window.setSuspendedTint(false)
                if vm.state == .paused {
                    do { try await vm.resume() }
                    catch {
                        FileHandle.standardError.write(Data(
                            "[ac] compromise: resume failed (\(error))\n".utf8))
                    }
                }
            }
        }
    }

    /// Modal NSOpenPanel asking the user where to drop the
    /// investigation bundle. Returns nil if the user cancels.
    @MainActor
    private func askForInvestigationDestination(profileName: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("Save Investigation Here", comment: "")
        panel.message = String(
            format: NSLocalizedString(
                "Choose a folder to receive the disk image, home archive, and shared-folder archives for “%@”.",
                comment: ""),
            profileName)
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dir = panel.url else { return nil }
        return dir
    }

    /// Copy the disk + tar-gzip the home dir + tar-gzip each shared
    /// folder into `destination`. Throws on the first hard failure;
    /// the caller surfaces the error and proceeds to mark compromised
    /// regardless. Layout under the destination:
    ///
    ///   destination/
    ///     disk.img
    ///     home.tar.gz
    ///     shares/
    ///       <basename>.tar.gz   (one per profile.folderPaths entry)
    ///
    /// VM is paused on entry, so the disk + home are quiescent — a
    /// straight file copy / tar is consistent with no extra locking.
    private func exportForInvestigation(session: SessionDisk,
                                          destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        // 1. Disk image — straight copy. APFS clonefile would be ideal
        //    when source + dest are on the same volume, but we don't
        //    know the destination volume so the safe move is copyItem,
        //    which uses clonefile under the hood when applicable.
        let diskDst = destination.appendingPathComponent("disk.img")
        if fm.fileExists(atPath: diskDst.path) {
            try fm.removeItem(at: diskDst)
        }
        try fm.copyItem(at: session.diskURL, to: diskDst)

        // 2. Home dir → home.tar.gz. Skip silently if the dir doesn't
        //    exist (e.g. the user reset home recently and never relaunched).
        let homeURL = session.homeDirectory
        if fm.fileExists(atPath: homeURL.path) {
            let homeDst = destination.appendingPathComponent("home.tar.gz")
            try Self.tarGzip(source: homeURL, destination: homeDst)
        }

        // 3. Shared folders → shares/<basename>.tar.gz. Each one is the
        //    user's project dir, so the tarball preserves that. We name
        //    by the dedup'd basename `SessionDisk.SharedFolder.mountName`
        //    — same names the user sees in the welcome banner.
        let shares = session.sharedFolders
        if !shares.isEmpty {
            let sharesDir = destination.appendingPathComponent("shares")
            try fm.createDirectory(at: sharesDir, withIntermediateDirectories: true)
            for share in shares {
                guard fm.fileExists(atPath: share.url.path) else { continue }
                let archive = sharesDir.appendingPathComponent("\(share.mountName).tar.gz")
                try Self.tarGzip(source: share.url, destination: archive)
            }
        }
    }

    /// Shell out to bsdtar (always present on macOS) to produce a
    /// gzip-compressed tarball. We invoke `tar -C parent -czf out base`
    /// so the archive contains a single root entry named after the
    /// source — extracts cleanly into `<basename>/...` rather than
    /// dumping its contents in the cwd.
    private static func tarGzip(source: URL, destination: URL) throws {
        let parent = source.deletingLastPathComponent()
        let base = source.lastPathComponent
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        task.arguments = [
            "-C", parent.path,
            "-czf", destination.path,
            base
        ]
        let errPipe = Pipe()
        task.standardError = errPipe
        try task.run()
        task.waitUntilExit()
        if task.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8) ?? "tar failed (\(task.terminationStatus))"
            throw NSError(domain: "BromureAC.Investigation", code: Int(task.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "tar \(base): \(msg.trimmingCharacters(in: .whitespacesAndNewlines))"])
        }
    }

    /// Modal alert. Big red banner + per-leak detail line. Returns
    /// the user's chosen action.
    @MainActor
    private func presentCompromiseAlert(event: CompromiseEvent,
                                         profileName: String) -> CompromiseAction {
        let alert = NSAlert()
        alert.alertStyle = .critical
        // NSAlert.critical paints a tiny yellow caution badge over the
        // app icon by default, which doesn't read as "stop everything"
        // at a glance. Replace the icon with a 64-pt red
        // exclamationmark.octagon (the macOS "danger" symbol) so the
        // alert visually screams the way the situation deserves.
        if let symbol = NSImage(
            systemSymbolName: "exclamationmark.octagon.fill",
            accessibilityDescription: "VM compromise warning") {
            let cfg = NSImage.SymbolConfiguration(pointSize: 64, weight: .bold)
                .applying(.init(paletteColors: [.systemRed]))
            alert.icon = symbol.withSymbolConfiguration(cfg)
        }
        alert.messageText = NSLocalizedString(
            "This environment may have been compromised",
            comment: "Compromise alert title")
        var info = String(
            format: NSLocalizedString(
                "Bromure detected an outbound attempt to leak a session credential from “%@” to a host it was not minted for. The VM has been paused.",
                comment: ""),
            profileName) + "\n\n"
        info += NSLocalizedString(
            "Detected leaks:", comment: "") + "\n"
        for leak in event.leaks {
            info += String(
                format: NSLocalizedString(
                    "  • %1$@ (%2$@) — expected %3$@, sent to %4$@\n",
                    comment: "Compromise leak detail line: fake preview, credential name, expected host, observed host"),
                leak.fakeTokenPreview,
                leak.credentialDisplayName,
                leak.declaredHost,
                leak.observedHost)
        }
        info += "\n" + NSLocalizedString(
            "Save for Investigation lets you pick a folder where Bromure will copy the disk image and gzipped archives of the home directory and shared folders. The VM's RAM state is discarded. The VM is then shut down and the workspace is marked compromised.",
            comment: "")
        alert.informativeText = info
        // Order: dismissive default first would let an enter-press hide
        // the warning. Make Shut Down the default — it's the safest.
        alert.addButton(withTitle: NSLocalizedString("Shut down", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Save for Investigation", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Continue", comment: ""))
        // Cmd-period / Esc maps to the third button (Continue) by
        // default. Override so an accidental dismiss doesn't resume
        // the compromised VM.
        alert.buttons.last?.keyEquivalent = ""
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .shutdown
        case .alertSecondButtonReturn: return .saveForInvestigation
        case .alertThirdButtonReturn:  return .continueAnyway
        default:                        return .shutdown
        }
    }

    enum CompromiseAction { case shutdown, saveForInvestigation, continueAnyway }

    /// Reboot dialog: soft (graceful guest halt via `poweroff` — NOT
    /// `reboot`, which restarts the VM in place without VZ ever firing
    /// guestDidStop, leaving the relaunch path dead) or hard (host-side
    /// `vm.stop()`). Both clear the saved RAM snapshot first so the
    /// post-stop relaunch is a clean fresh boot, not a restore that
    /// would put us right back where we were.
    @MainActor
    func requestReboot(for window: SessionPane) {
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("Reboot “%@”?", comment: ""),
            window.profile.name)
        alert.informativeText = NSLocalizedString(
            "Soft reboot gracefully halts the VM (filesystems flush, services stop) and boots a fresh one in this window. Hard reboot tears down the VM immediately and starts a fresh one.",
            comment: "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Soft reboot", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Hard reboot", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            window.sandbox?.sessionDisk?.clearSavedState()
            window.rebootRequested = true
            sendCommand("soft-reboot", in: window)
        case .alertSecondButtonReturn:
            window.sandbox?.sessionDisk?.clearSavedState()
            window.rebootRequested = true
            // Host-initiated stop. VZ doesn't fire `guestDidStop` for
            // this path (that callback is reserved for guest-driven
            // halts like `sudo reboot`), so the `onStopped` →
            // `relaunchVM` chain that soft reboot rides on never
            // triggers. Drive the relaunch from the completion
            // handler instead. The `rebootRequested` flag still
            // gates: if VZ does fire `didStopWithError` for some
            // edge case, the delegate path will consume the flag
            // first and we'll no-op here (or vice versa).
            window.sandbox?.vm?.stop(completionHandler: { [weak self, weak window] error in
                if let error {
                    FileHandle.standardError.write(Data(
                        "[ac] hard reboot: stop failed: \(error)\n".utf8))
                }
                Task { @MainActor in
                    guard let self, let window, window.rebootRequested else {
                        return
                    }
                    window.rebootRequested = false
                    self.relaunchVM(in: window)
                }
            })
        default:
            return
        }
    }

    /// Wire the standard set of sandbox callbacks for `win`. Used by
    /// both the initial launch and the post-reboot relaunch — the
    /// reboot path needs identical wiring on the freshly-built
    /// sandbox, and `onStopped` keying off `rebootRequested` is the
    /// hinge that turns "VM stopped" into "rebuild VM in place"
    /// instead of "close window".
    @MainActor
    /// Wire the sandbox's guest-event callbacks. Keyed off the profile id
    /// (resolved from the sandbox's own session disk) rather than a captured
    /// window, so the callbacks keep working while the session is detached
    /// (no window). UI-affecting events look up the attached window lazily and
    /// no-op when there isn't one; state (IP, roster) is mirrored into the
    /// registry so a reattaching window can render it.
    private func wireSandboxCallbacks(_ sandbox: UbuntuSandboxVM) {
        guard let pid = sandbox.sessionDisk?.profile.id else { return }
        sandbox.onStopped = { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // A user-requested reboot rebuilds the VM in the same window.
                if let pane = self.pane(for: pid), pane.rebootRequested {
                    pane.rebootRequested = false
                    self.relaunchVM(in: pane)
                } else {
                    // Real stop (guest poweroff, crash, or our requestStop):
                    // tear the session down and close any attached window.
                    self.handleSessionStopped(profileID: pid)
                }
            }
        }
        sandbox.onURLOpen = { [weak self, weak sandbox] url in
            Task { @MainActor in
                // If this is an OAuth login URL whose redirect_uri points at a
                // guest loopback port, stand up a forwarder so the host
                // browser's callback reaches the in-VM CLI before we open it.
                if let self, let sandbox,
                   let port = Self.loopbackCallbackPort(from: url),
                   let dev = sandbox.socketDevice,
                   let fwd = LoopbackCallbackForwarder(port: port, socketDevice: dev) {
                    self.loopbackForwarders.removeAll { !$0.isRunning }
                    self.loopbackForwarders.append(fwd)
                    FileHandle.standardError.write(Data(
                        "[ac] loopback callback forwarder up on 127.0.0.1:\(port) → guest\n".utf8))
                }
                NSWorkspace.shared.open(url)
            }
        }
        sandbox.onTabList = { [weak self] tabs in
            Task { @MainActor in
                guard let self else { return }
                // Mirror for detached `vm ls` / API, and drive the tab bar.
                self.runningSessions[pid]?.tabs = tabs.map {
                    (index: $0.index, label: $0.label, active: $0.active)
                }
                self.pane(for: pid)?.applyTabList(tabs)
            }
        }
        sandbox.onIPUpdate = { [weak self] ip in
            Task { @MainActor in
                guard let self else { return }
                self.runningSessions[pid]?.lastIP = ip
                self.pane(for: pid)?.model.ipAddress = ip
            }
        }
        sandbox.onShortcut = { [weak self] key in
            // A host-owned chord (⌘T/⌘W/⌘N/⌘1-9) that Openbox grabbed in the
            // guest and bounced back because the VM held keyboard focus. Run
            // the same action the key monitor would — performACShortcut is the
            // shared sink, so the two paths can't drift. No-op when detached.
            Task { @MainActor in self?.pane(for: pid)?.performACShortcut(key) }
        }
    }

    // MARK: - Session lifetime (persistent-agent model)

    /// Tear down a profile's host-side session registrations — the MITM
    /// engine maps, ssh-agent keys, SSO refresh loop, and shell bridge. Moved
    /// out of `windowWillClose` (which now only *detaches*): these must outlive
    /// a mere detach and only drop when the VM actually stops.
    @MainActor
    private func cleanupSessionRegistrations(for profile: Profile) {
        for key in loadAgentKeys(for: profile) {
            removeKeyFromHostAgent(publicKey: key.publicKey)
        }
        ssoRefreshTasks[profile.id]?.cancel()
        ssoRefreshTasks.removeValue(forKey: profile.id)
        mitmEngine?.clearSessionTrace(for: profile.id)
        mitmEngine?.unregister(profileID: profile.id)
        mitmEngine?.claudeSubscriptionStore.unregisterBogusKeys(for: profile.id)
        mitmEngine?.codexSubscriptionStore.unregisterBogusKeys(for: profile.id)
        mitmEngine?.grokSubscriptionStore.unregisterBogusKeys(for: profile.id)
        shellBridges[profile.id]?.stop()
        shellBridges.removeValue(forKey: profile.id)
        // Drop this workspace's local models from the engine's union, unloading
        // any no longer wanted by an open workspace (stops the engine if none
        // remain). The engine keeps serving the others.
        Task { await InferenceService.shared.clearWorkspace(profile.id) }
        InferenceRepairProxy.shared.clearActiveModel(profile.id)
    }

    /// The VM for `profileID` stopped (guest poweroff, crash, or the tail of an
    /// explicit stop). Idempotent: runs per-session teardown once, drops the
    /// registry entry, and closes any attached window.
    @MainActor
    func handleSessionStopped(profileID: Profile.ID) {
        guard let session = runningSessions[profileID] else { return }   // already handled
        cleanupSessionRegistrations(for: session.profile)
        unregisterSession(profileID)
        if let win = profileWindows[profileID] {
            win.vmView.virtualMachine = nil
            win.keyboardBridge = nil
            win.scrollBridge = nil
            win.sandbox = nil
            profileWindows.removeValue(forKey: profileID)
            unregisterPane(profileID, ifMatches: win.pane)
            win.orderOut(nil)
        }
        // Drop the pane regardless of host (unified-window teardown removes its
        // own view in `removePane`, wired in the unified-window phase).
        unifiedWindow?.removePane(profileID)
        unregisterPane(profileID)
        // `vm run --rm`: delete the ephemeral profile + its disk now it stopped.
        if ephemeralProfiles.remove(profileID) != nil,
           let p = profiles.first(where: { $0.id == profileID }) {
            try? store.delete(p)
            profiles = store.loadAll()
        }
        refreshSidebar()
        updateStatusMenu()
        updateActivationPolicy()
    }

    /// Explicitly stop a running session's VM (honoring `action`), then tear it
    /// down. This is the *only* path that powers a VM off — window close is a
    /// detach. Invoked by `vm kill`, the ⌘Q drain, the status-item, and the
    /// guest "all shells exited" signal.
    @MainActor
    func stopSession(_ profileID: Profile.ID, action: Profile.CloseAction) async {
        guard let session = runningSessions[profileID], !session.stopping,
              let vm = session.sandbox.vm else { return }
        let sandbox = session.sandbox
        session.stopping = true
        let name = session.profile.name
        // `.ask` and `.background` both collapse to `.suspend` — a programmatic
        // stop isn't the moment for a modal, and "background" can't survive the
        // agent exiting, so suspend keeps state and the user decides next launch.
        let resolved: Profile.CloseAction = (action == .ask || action == .background) ? .suspend : action
        switch resolved {
        case .suspend:
            sandbox.sessionDisk?.saveTabs(currentTabsSnapshot(for: profileID))
            do {
                try await sandbox.suspend()
                FileHandle.standardError.write(Data("[ac] suspended '\(name)'\n".utf8))
            } catch {
                FileHandle.standardError.write(Data(
                    "[ac] suspend '\(name)' failed (\(error)) — forcing stop\n".utf8))
                sandbox.sessionDisk?.clearSavedState()
                await Self.forceStop(vm)
            }
        case .shutdown:
            sandbox.sessionDisk?.clearSavedState()
            do { try vm.requestStop() }
            catch {
                await Self.forceStop(vm)
                break
            }
            let deadline = Date().addingTimeInterval(15)
            while vm.state == .running && Date() < deadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if vm.state == .running {
                FileHandle.standardError.write(Data(
                    "[ac] '\(name)' didn't poweroff in 15s — forcing stop\n".utf8))
                await Self.forceStop(vm)
            }
        case .ask, .background:
            break   // unreachable: both collapse to .suspend above
        }
        // A clean guest poweroff fires onStopped → handleSessionStopped, but
        // suspend and a forced vm.stop() do NOT — so finish teardown here too.
        // Idempotent: a no-op if onStopped already ran.
        handleSessionStopped(profileID: profileID)
    }

    /// Fire-and-forget `stopSession` for non-async callers (the guest
    /// "all shells exited" path, status item, CLI control plane).
    @MainActor
    func requestStopSession(_ profileID: Profile.ID, action: Profile.CloseAction) {
        Task { @MainActor in await self.stopSession(profileID, action: action) }
    }

    /// Best-effort current tab snapshot for `profileID`: the attached window's
    /// live model when attached, else the last snapshot captured on detach.
    @MainActor
    private func currentTabsSnapshot(for profileID: Profile.ID) -> SessionDisk.TabsState {
        if let pane = pane(for: profileID) { return pane.snapshotTabs() }
        return runningSessions[profileID]?.lastTabsSnapshot
            ?? SessionDisk.TabsState(tabs: [], activeIndex: 0)
    }

    /// Build a window onto an already-running session and bind a fresh
    /// VZVirtualMachineView to its live VM. Used to reattach after a detach
    /// (window closed, VM kept running) and by the control plane's attach.
    @MainActor
    func attachWindow(to session: RunningSession) {
        // Already shown somewhere → focus + select it.
        if isAttached(session.profileID) {
            revealSession(session.profileID)
            return
        }
        let profile = session.profile
        let sandbox = session.sandbox
        // Build a fresh pane onto the already-running VM and host it in the
        // shared unified window.
        let pane = SessionPane(profile: profile, acDelegate: self)
        pane.sandbox = sandbox
        // Bind the fresh view to the already-running VM (the guest keeps
        // rendering into the virtio framebuffer regardless of any host view).
        pane.vmView.virtualMachine = sandbox.vm
        if let dev = sandbox.socketDevice {
            pane.keyboardBridge = KeyboardBridge(
                socketDevice: dev, forcedLayout: profile.keyboardLayoutOverride)
        }
        pane.scrollBridge = makeScrollBridge(for: sandbox)
        // Rebuild the tab bar from the session's cached tmux window list; the
        // live roster keeps it current. tmux is already running in the VM, so
        // there's nothing to spawn or raise.
        if !session.tabs.isEmpty {
            pane.model.tabs = session.tabs.map { TabsModel.Tab(label: $0.label) }
            pane.model.activeIndex = session.tabs.firstIndex(where: { $0.active }) ?? 0
        } else {
            pane.model.tabs = [TabsModel.Tab(label: "shell")]
            pane.model.activeIndex = 0
        }
        // Restore display state from the registry.
        pane.model.ipAddress = session.lastIP
        pane.model.fusionConfigurable = profile.fusionConfigurable
        pane.model.fusionEngaged = session.fusionEngaged
        let unified = ensureUnifiedWindow()
        unified.addPane(pane)
        NSApp.setActivationPolicy(.regular)
        unified.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshStreamingState()
        refreshSidebar()
        updateStatusMenu()
    }

    /// Demote to a background (no Dock icon) agent when no session window or
    /// the picker is visible — VMs keep running. Promoted back to `.regular`
    /// at the window-show sites (`attachWindow`, the picker opener).
    @MainActor
    func updateActivationPolicy() {
        let hasSessionUI = (unifiedWindow?.isVisible == true) || !profileWindows.isEmpty
        if !hasSessionUI && mainWindow == nil {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }

    // MARK: - Status-bar item (reachable while detached / accessory)

    /// Stand up the menu-bar item. Created once in `applicationDidFinishLaunching`.
    /// It's the only UI surface once every window is closed and the app has
    /// demoted to `.accessory`, so it must list running sessions + offer Quit.
    @MainActor
    func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let robot = BromureIcons.image("robot") {
                let icon = robot.copy() as! NSImage
                icon.size = NSSize(width: 18, height: 18)
                icon.isTemplate = true
                button.image = icon
            } else {
                button.image = NSImage(systemSymbolName: "shippingbox",
                                       accessibilityDescription: "Bromure Agentic Coding")
                button.image?.isTemplate = true
            }
        }
        statusItem = item
        updateStatusMenu()
    }

    /// Rebuild the status-item menu from the current `runningSessions`.
    @MainActor
    func updateStatusMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        let sessions = runningSessions.values.sorted { $0.profile.name < $1.profile.name }
        if sessions.isEmpty {
            let none = NSMenuItem(title: NSLocalizedString("No running VMs", comment: ""),
                                  action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for session in sessions {
                let attached = isAttached(session.profileID)
                let title = "\(session.profile.name)\(attached ? "" : " — detached")"
                let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)

                let reattach = NSMenuItem(
                    title: attached
                        ? NSLocalizedString("    Focus window", comment: "")
                        : NSLocalizedString("    Reattach", comment: ""),
                    action: #selector(statusReattach(_:)), keyEquivalent: "")
                reattach.target = self
                reattach.representedObject = session.profileID.uuidString
                menu.addItem(reattach)

                let stop = NSMenuItem(title: NSLocalizedString("    Shut down", comment: ""),
                                      action: #selector(statusStop(_:)), keyEquivalent: "")
                stop.target = self
                stop.representedObject = session.profileID.uuidString
                menu.addItem(stop)
            }
        }
        menu.addItem(.separator())

        // Remote access (embedded SSH front door) — toggle + where to reach it.
        let remoteOn = RemoteAccessServer.shared.isRunning
        let remote = NSMenuItem(title: NSLocalizedString("Remote Access", comment: ""),
                                action: #selector(statusToggleRemoteAccess(_:)), keyEquivalent: "")
        remote.target = self
        remote.state = remoteOn ? .on : .off
        menu.addItem(remote)
        if remoteOn {
            let reach = NSMenuItem(
                title: String(format: NSLocalizedString("    Bromure is reachable at %@", comment: ""),
                              remoteReachableAddress()),
                action: nil, keyEquivalent: "")
            reach.isEnabled = false
            menu.addItem(reach)
        }
        menu.addItem(.separator())

        let picker = NSMenuItem(title: NSLocalizedString("Open Bromure Agentic Coding", comment: ""),
                                action: #selector(openProfileManagerAction(_:)), keyEquivalent: "")
        picker.target = self
        menu.addItem(picker)
        let quit = NSMenuItem(title: NSLocalizedString("Quit", comment: ""),
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quit)
        statusItem.menu = menu
    }

    @MainActor @objc private func statusReattach(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw),
              let session = runningSessions[id] else { return }
        attachWindow(to: session)
    }

    @MainActor @objc private func statusStop(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw) else { return }
        let action = runningSessions[id]?.profile.closeAction ?? .shutdown
        Task { @MainActor in await self.stopSession(id, action: action) }
    }

    /// Toggle the embedded SSH front door from the menu-bar item.
    @MainActor @objc private func statusToggleRemoteAccess(_ sender: NSMenuItem) {
        let result = remoteAccessApply(["enabled": !RemoteAccessServer.shared.isRunning])
        if let err = result["error"] as? String {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Remote Access", comment: "")
            alert.informativeText = err
            alert.runModal()
        }
        updateStatusMenu()
    }

    /// Build a fresh sandbox in `win` after the previous one stopped.
    /// Used post-reboot to replace the dead VM in place without
    /// closing/reopening the host window. Skips drift checks and the
    /// network-healer watch — both are first-launch concerns; the
    /// disk + base image version are unchanged across a reboot.
    @MainActor
    private func relaunchVM(in win: SessionPane) {
        let profile = win.profile
        // Cancel the outgoing sandbox's outbox poller explicitly. A
        // dropped Task keeps running in Swift — without this the old
        // poller would keep racing the new one on the same shared
        // directory and removing closed-* files out from under it.
        win.sandbox?.stopPolling()
        win.vmView.virtualMachine = nil
        // Drop the old VM from the registry (and the window borrow) so it
        // deallocates (its deinit detaches the vmnet switch port). The fresh
        // sandbox is registered below once it's built.
        unregisterSession(profile.id)
        win.sandbox = nil
        win.keyboardBridge = nil
        win.scrollBridge = nil
        win.model.activeIndex = 0
        win.model.ipAddress = nil
        // Placeholder pill while the fresh VM boots; the agent creates tmux
        // window 0 and the roster repopulates the bar.
        win.model.tabs = [TabsModel.Tab(label: "shell")]

        Task { @MainActor in
            // Brief settle before reusing the per-profile shared dirs
            // (meta-share, outbox) while the old VZ virtiofs daemon
            // releases its handles after the previous VM stopped. The
            // black-screen wedge this used to guard against — the
            // cmd-spawn-kitty file landing in a directory the new
            // agent couldn't see — is now fixed at the source:
            // prepareMetadataShare/prepareOutboxDirectory clear their
            // contents in place instead of removing+recreating the
            // directory, so the inode the daemon holds never changes.
            // This delay is kept only as cheap defense-in-depth.
            try? await Task.sleep(for: .milliseconds(500))

            var profile = profile
            self.populateMCPBearerTokens(in: &profile)

            let sessionDisk = SessionDisk(
                profile: profile,
                store: store,
                baseDiskURL: imageManager.baseDiskURL
            )
            let salt = self.mitmEngine?.fakeTokenSalt ?? Data(repeating: 0, count: 32)
            let plan = self.sessionTokenPlan(for: profile, salt: salt)
            sessionDisk.tokenPlan = plan
            self.seedCodexAuthFile(for: profile)
            self.seedGrokAuthFile(for: profile)
            if let engine = self.mitmEngine, let scriptURL = self.bridgeScriptURL {
                sessionDisk.mitmAssets = SessionDisk.MitmSessionAssets(
                    caCertificatePEM: engine.ca.certificatePEM,
                    bridgeScriptURL: scriptURL,
                    keyboardAgentURL: keyboardAgentURL,
                    scrollAgentURL: scrollAgentURL,
                    awsCredsHelperURL: awsCredsHelperURL,
                    claudeTokenAgentURL: claudeTokenAgentURL,
                    codexTokenAgentURL: codexTokenAgentURL,
                    shellAgentURL: self.shellAgentURL,   // always ship (see warm-boot path)
                    loopbackRelayAgentURL: loopbackRelayAgentURL)
            }
            let sandbox = UbuntuSandboxVM(imageManager: imageManager,
                                          sessionDisk: sessionDisk)
            do {
                try sandbox.prepare()
                win.vmView.virtualMachine = sandbox.vm
                try await sandbox.start()
            } catch {
                self.showError(error, message:
                    "Couldn't restart the VM for “\(profile.name)”.")
                win.host?.paneRequestsClose(win)
                return
            }
            if let engine = self.mitmEngine, let dev = sandbox.socketDevice {
                engine.register(socketDevice: dev, profileID: profile.id)
                engine.setGuardrailsConfig(Self.makeGuardrailsConfig(for: profile), for: profile.id)
                engine.setSupplyChainPolicy(profile.supplyChain, for: profile.id)
                engine.setPromptInjectionPolicy(profile.promptInjection, for: profile.id)
                if profile.promptInjection.detectSourceInjection { PromptInjectionModels.ensureInstalledInBackground(.promptGuard) }
                if profile.promptInjection.detectRulesInjection { PromptInjectionModels.ensureInstalledInBackground(.claudeMdGuard) }
                // Fusion: keep the toggle visible when configured, but reset
                // to disengaged on reboot (user re-engages on demand).
                win.model.fusionConfigurable = profile.fusionConfigurable
                win.model.fusionEngaged = false
                engine.setFusionEngaged(false, for: profile.id)
                engine.setFusionConfig(self.makeFusionConfig(for: profile), for: profile.id)
                self.applyRouting(engine, for: profile)
                self.startLocalEngineIfNeeded(for: profile)
            }
            if let dev = sandbox.socketDevice {
                win.keyboardBridge = KeyboardBridge(
                    socketDevice: dev,
                    forcedLayout: profile.keyboardLayoutOverride)
            }
            win.scrollBridge = makeScrollBridge(for: sandbox)
            // Shell-exec bridge — see the matching block on the warm-boot path.
            if let dev = sandbox.socketDevice {
                let bridge = ShellBridge(socketDevice: dev)
                self.shellBridges[profile.id] = bridge
            }
            self.wireSandboxCallbacks(sandbox)
            self.registerSession(sandbox, profile: profile)
            win.sandbox = sandbox
            // The agent launches the kitty → tmux session itself; the roster
            // fills the bar. No host-driven spawn.
        }
    }

    private func readCurrentBaseVersion() -> String? {
        try? String(contentsOf: imageManager.versionStampURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    func showError(_ error: Error, message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .critical
        alert.runModal()
    }

    /// Load the profile's ssh keys from its host-only agent dir.
    /// Returns an empty array if the new-format raw key hasn't been
    /// generated yet — vocally so the user knows they need to
    /// regenerate (the old OpenSSH-format files we used to write
    /// aren't loadable through this path).
    private func loadAgentKeys(for profile: Profile) -> [AgentKey] {
        let dir = store.profileDirectory(for: profile)
            .appendingPathComponent("agent", isDirectory: true)
        let raw = dir.appendingPathComponent("id_ed25519.raw")

        guard FileManager.default.fileExists(atPath: raw.path) else {
            if profile.sshPublicKey != nil {
                FileHandle.standardError.write(Data(
                    "[mitm] profile '\(profile.name)' has an SSH public key on file but no agent/id_ed25519.raw — regenerate via Credentials → SSH key → Regenerate\n".utf8))
            } else {
                FileHandle.standardError.write(Data(
                    "[mitm] profile '\(profile.name)' has no SSH key configured — toggle 'Generate' in Credentials if you want one\n".utf8))
            }
            return []
        }
        guard let rawData = try? Data(contentsOf: raw), rawData.count == 64 else {
            FileHandle.standardError.write(Data(
                "[mitm] profile '\(profile.name)' agent/id_ed25519.raw is malformed (\(((try? Data(contentsOf: raw))?.count) ?? -1) bytes, expected 64) — regenerate\n".utf8))
            return []
        }
        // raw layout: 32-byte seed (private) + 32-byte public.
        let secret = rawData.prefix(32)
        let publicKey = rawData.suffix(32)
        FileHandle.standardError.write(Data(
            "[mitm] loaded 1 agent key from \(raw.path)\n".utf8))
        return [AgentKey(comment: "bromure-ac",
                         publicKey: Data(publicKey),
                         seed: Data(secret),
                         requireApproval: profile.sshKeyRequiresApproval,
                         consentCredentialID: ConsentCredentialID.bromureSSHKey())]
    }

    /// Extract the SSH wire-format public-key blob from an OpenSSH
    /// public-key line (`<keytype> <base64> [comment]`). The base64
    /// payload IS the wire-format blob the SSH client passes to
    /// SIGN_REQUEST as the key identifier, so callers can match it
    /// 1:1 against incoming sign requests.
    ///
    /// Returns nil for empty / malformed input — callers that can't
    /// resolve a blob skip the consent gate (better than refusing to
    /// sign for keys we can't identify).
    private func sshPublicKeyBlob(fromOpenSSHText text: String) -> Data? {
        let line = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let parts = line.split(separator: " ", maxSplits: 2,
                               omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        return Data(base64Encoded: String(parts[1]))
    }

    /// Copy a user-supplied SSH private key into the profile's
    /// host-only `agent/imported/` dir, optionally storing the
    /// passphrase in the macOS keychain. Reads the matching `.pub`
    /// file if present so the editor can show the public key text
    /// without re-deriving it. Returns the metadata to store on the
    /// profile.
    func importSSHKey(at sourceURL: URL,
                      passphrase: String?,
                      label: String,
                      for profile: Profile) throws -> ImportedSSHKey {
        let importedDir = store.profileDirectory(for: profile)
            .appendingPathComponent("agent/imported", isDirectory: true)
        try FileManager.default.createDirectory(
            at: importedDir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])

        // Rename on copy: original filename leaks intent ("work_id_rsa")
        // and could collide. UUID-prefix keeps things scoped + unique.
        let basename = "\(UUID().uuidString)-\(sourceURL.lastPathComponent)"
        let dst = importedDir.appendingPathComponent(basename)
        try FileManager.default.copyItem(at: sourceURL, to: dst)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: dst.path)

        // Pull the matching .pub for display purposes if the user had
        // one alongside (typical: ~/.ssh/id_ed25519 + .pub).
        var pubText = ""
        let candidatePub = sourceURL.deletingPathExtension()
            .appendingPathExtension("pub")
        // ssh keypair convention: the file might be id_ed25519 with no
        // extension and id_ed25519.pub. Try both forms.
        let altPub = URL(fileURLWithPath: sourceURL.path + ".pub")
        for pubURL in [altPub, candidatePub] {
            if let s = try? String(contentsOf: pubURL, encoding: .utf8) {
                pubText = s.trimmingCharacters(in: .whitespacesAndNewlines)
                let pubDst = importedDir.appendingPathComponent(basename + ".pub")
                try? FileManager.default.copyItem(at: pubURL, to: pubDst)
                break
            }
        }

        let trimmed = passphrase?.trimmingCharacters(in: CharacterSet()) ?? ""

        // If we still don't have the public-key text (common for .pem
        // imports), derive it from the private key via `ssh-keygen
        // -y -f <key> -P <passphrase>`. Captures stdout, caches the
        // result on disk so future launches don't re-run ssh-keygen,
        // and unblocks the per-key consent gate (which keys requests
        // by the wire-format public-key blob).
        if pubText.isEmpty {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            // -y: print public-key text from a private file.
            // -P: passphrase. Empty string for unencrypted keys —
            //     ssh-keygen accepts empty -P silently.
            p.arguments = ["-y", "-f", dst.path, "-P", trimmed]
            let outPipe = Pipe()
            p.standardOutput = outPipe
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0,
               let data = try? outPipe.fileHandleForReading.readToEnd(),
               let s = String(data: data, encoding: .utf8) {
                let derived = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !derived.isEmpty {
                    pubText = derived
                    // Cache the derived pub next to the private key so
                    // future launches read it from disk (avoids the
                    // ssh-keygen shell-out and avoids needing the
                    // passphrase again post-import).
                    let pubDst = importedDir.appendingPathComponent(basename + ".pub")
                    try? derived.write(to: pubDst, atomically: true, encoding: .utf8)
                }
            }
        }
        let hasPass = !trimmed.isEmpty
        if hasPass {
            try PassphraseKeychain.set(passphrase: trimmed,
                                       profileID: profile.id,
                                       filename: basename)
        }

        return ImportedSSHKey(
            label: label.isEmpty ? sourceURL.lastPathComponent : label,
            filename: basename,
            publicKeyText: pubText,
            hasPassphrase: hasPass)
    }

    /// Remove an imported key: file + (optional) keychain entry. The
    /// editor calls this when the user clicks the row's minus button.
    func removeImportedSSHKey(_ key: ImportedSSHKey, for profile: Profile) {
        let importedDir = store.profileDirectory(for: profile)
            .appendingPathComponent("agent/imported", isDirectory: true)
        try? FileManager.default.removeItem(
            at: importedDir.appendingPathComponent(key.filename))
        try? FileManager.default.removeItem(
            at: importedDir.appendingPathComponent(key.filename + ".pub"))
        if key.hasPassphrase {
            PassphraseKeychain.delete(profileID: profile.id, filename: key.filename)
        }
    }

    /// Walk the profile's imported keys and ssh-add each one into the
    /// private bromure agent. Called from `launch()` after the auto-
    /// generated key is loaded so multiple keys end up live in the
    /// agent simultaneously.
    private func loadImportedSSHKeys(for profile: Profile) {
        guard let agentSocket = mitmEngine?.privateAgent.socketPath,
              !profile.importedSSHKeys.isEmpty else { return }
        let importedDir = store.profileDirectory(for: profile)
            .appendingPathComponent("agent/imported", isDirectory: true)
        for key in profile.importedSSHKeys {
            let path = importedDir.appendingPathComponent(key.filename).path
            guard FileManager.default.fileExists(atPath: path) else {
                FileHandle.standardError.write(Data(
                    "[mitm] imported key '\(key.label)' missing on disk (\(path))\n".utf8))
                continue
            }
            sshAddImportedKey(path: path,
                              label: key.label,
                              passphrase: key.hasPassphrase
                                  ? PassphraseKeychain.get(profileID: profile.id, filename: key.filename)
                                  : nil,
                              agentSocket: agentSocket)
        }
    }

    /// Run `ssh-add <path>` against our private agent, feeding the
    /// passphrase via the SSH_ASKPASS env-var protocol when one is
    /// known. The askpass script lives in /tmp for the duration of
    /// the call and is unlinked immediately after. SSH_ASKPASS_REQUIRE=force
    /// makes ssh-add use the script even though we're not running
    /// under X11 / a TTY.
    private func sshAddImportedKey(path: String,
                                   label: String,
                                   passphrase: String?,
                                   agentSocket: String) {
        var env = ProcessInfo.processInfo.environment
        env["SSH_AUTH_SOCK"] = agentSocket

        var askpassURL: URL?
        if let pass = passphrase, !pass.isEmpty {
            // Script just echoes the passphrase. Single-quote the value
            // safely; ssh-add doesn't do shell expansion on the result.
            let escaped = pass.replacingOccurrences(of: "'", with: "'\\''")
            let script = "#!/bin/sh\nprintf '%s\\n' '\(escaped)'\n"
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("bromure-ac-askpass-\(UUID().uuidString).sh")
            try? script.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o700)],
                ofItemAtPath: url.path)
            env["SSH_ASKPASS"] = url.path
            // Apple's ssh-add only consults SSH_ASKPASS when DISPLAY is
            // also set, OR when SSH_ASKPASS_REQUIRE=force. Belt-and-
            // braces both.
            env["DISPLAY"] = ":0"
            env["SSH_ASKPASS_REQUIRE"] = "force"
            askpassURL = url
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        p.arguments = [path]
        p.environment = env
        // ssh-add reading from /dev/null prevents it from blocking on
        // tty even when SSH_ASKPASS is missing or fails.
        p.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        p.standardOutput = Pipe()
        let stderr = Pipe()
        p.standardError = stderr
        defer {
            if let u = askpassURL { try? FileManager.default.removeItem(at: u) }
        }
        do {
            try p.run()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                let msg = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
                FileHandle.standardError.write(Data(
                    "[mitm] ssh-add (imported '\(label)') failed (\(p.terminationStatus)): \(msg)\n".utf8))
            } else {
                FileHandle.standardError.write(Data(
                    "[mitm] added imported key '\(label)' from \(path)\n".utf8))
            }
        } catch {
            FileHandle.standardError.write(Data(
                "[mitm] ssh-add (imported '\(label)') launch failed: \(error)\n".utf8))
        }
    }

    /// Add the per-profile key to bromure's private ssh-agent so the
    /// in-VM ssh client can sign with it without the user having to
    /// `ssh-add` anything by hand. Idempotent — re-adding an already-
    /// loaded key is harmless. Removed in `windowWillClose`.
    ///
    /// The user's macOS launchd ssh-agent is intentionally NOT a
    /// target — exposing it to the VM was the source of an earlier
    /// security gap; see `SSHAgentServer` for the full rationale.
    private func addKeyToHostAgent(seed: Data, publicKey: Data, comment: String) {
        // Target our private bromure ssh-agent specifically: it gives
        // us predictable lifecycle (key gone when bromure-ac quits)
        // and keeps the in-VM agent's reachable key set fully under
        // bromure's control.
        guard let sock = mitmEngine?.privateAgent.socketPath else {
            FileHandle.standardError.write(Data(
                "[mitm] skipping ssh-add — private agent not running\n".utf8))
            return
        }
        let pem = OpenSSHKeyFormat.ed25519PEM(
            seed: seed, publicKey: publicKey, comment: comment)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        p.arguments = ["-"]
        var env = ProcessInfo.processInfo.environment
        env["SSH_AUTH_SOCK"] = sock
        // Belt-and-braces: macOS ssh-add uses `--apple-use-keychain`
        // when adding to the system agent — but not setting that means
        // in-memory only, which is exactly what we want for ephemeral
        // session loads.
        p.environment = env
        let stdin = Pipe()
        let stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = Pipe()
        p.standardError = stderr
        do {
            try p.run()
            try stdin.fileHandleForWriting.write(contentsOf: pem)
            try stdin.fileHandleForWriting.close()
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                let msg = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
                FileHandle.standardError.write(Data(
                    "[mitm] ssh-add failed (\(p.terminationStatus)): \(msg)\n".utf8))
            } else {
                FileHandle.standardError.write(Data(
                    "[mitm] added per-profile key to host ssh-agent (\(comment))\n".utf8))
            }
        } catch {
            FileHandle.standardError.write(Data(
                "[mitm] ssh-add launch failed: \(error)\n".utf8))
        }
    }

    /// Remove a key from the host ssh-agent by sending the agent
    /// protocol's REMOVE_IDENTITY message directly — sidesteps
    /// `ssh-add -d` needing a file path. Best-effort.
    private func removeKeyFromHostAgent(publicKey: Data) {
        guard let host = HostAgentClient._bromurePrivate else { return }
        let blob = OpenSSHKeyFormat.ed25519PublicBlob(publicKey: publicKey)
        // SSH_AGENTC_REMOVE_IDENTITY = 18; payload = ssh-string(blob).
        var msg = Data([18])
        var len = UInt32(blob.count).bigEndian
        msg.append(Data(bytes: &len, count: 4))
        msg.append(blob)
        _ = host.request(msg)
    }

    /// Mint a fresh Curve25519 ed25519 keypair into `dir` (the profile's
    /// host-only agent directory). The raw seed + public bytes are
    /// written to `id_ed25519.raw` so the in-process ssh-agent can load
    /// it; an OpenSSH-format public key is written to `id_ed25519.pub`
    /// for display + paste-into-GitHub. **No private key file** is
    /// produced — there's literally no plaintext form to leak.
    private func makeSSHKey(in dir: URL) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: NSNumber(value: 0o700)])

        let key = Curve25519.Signing.PrivateKey()
        let seed = key.rawRepresentation             // 32 bytes
        let pub  = key.publicKey.rawRepresentation   // 32 bytes

        // raw layout: 32 seed + 32 public = 64 bytes. Single file so
        // host-side load is one read; agent-side, the seed reconstructs
        // the full PrivateKey via Curve25519.Signing.PrivateKey(rawRepresentation:).
        var raw = Data()
        raw.append(seed)
        raw.append(pub)
        let rawURL = dir.appendingPathComponent("id_ed25519.raw")
        try raw.write(to: rawURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                             ofItemAtPath: rawURL.path)

        // OpenSSH public key: ssh-ed25519 <base64-blob> <comment>
        // Blob: ssh-string("ssh-ed25519") || ssh-string(public-key)
        let label = "ssh-ed25519"
        var blob = Data()
        blob.append(uint32be(UInt32(label.utf8.count)))
        blob.append(Data(label.utf8))
        blob.append(uint32be(UInt32(pub.count)))
        blob.append(pub)
        let pubText = "ssh-ed25519 \(blob.base64EncodedString()) bromure-ac"
        let pubURL = dir.appendingPathComponent("id_ed25519.pub")
        try pubText.write(to: pubURL, atomically: true, encoding: .utf8)

        // Belt-and-braces: nuke any prior OpenSSH-private-key in the
        // profile's VM-visible home dir. The previous codepath wrote
        // one there; under the new model nothing private should ever
        // sit in /home/ubuntu/.ssh.
        let homeSSH = store.homeDirectory(for: profileFromAgentDir(dir))
            .appendingPathComponent(".ssh", isDirectory: true)
        let stalePriv = homeSSH.appendingPathComponent("id_ed25519")
        try? fm.removeItem(at: stalePriv)
        // Keep id_ed25519.pub in the VM home for the user's reference.
        if fm.fileExists(atPath: homeSSH.path) {
            try? pubText.write(
                to: homeSSH.appendingPathComponent("id_ed25519.pub"),
                atomically: true, encoding: .utf8)
        }

        return pubText
    }

    /// Reverse-derive the profile from the agent dir URL — the agent
    /// dir is `…/profiles/<UUID>/agent`, two levels above. Used only
    /// for the housekeeping step in makeSSHKey.
    private func profileFromAgentDir(_ url: URL) -> Profile {
        let id = url.deletingLastPathComponent().lastPathComponent
        guard let uuid = UUID(uuidString: id),
              let p = profiles.first(where: { $0.id == uuid }) else {
            // Fallback: return a placeholder profile; the cleanup
            // step is best-effort anyway.
            return Profile(name: "", tool: .claude, authMode: .token)
        }
        return p
    }

    /// Build a session token plan, enabling Claude subscription mode when a
    /// shared subscription credential is registered, and register the minted
    /// bogus `ANTHROPIC_API_KEY` so the proxy recognizes it. Use this instead
    /// of calling `profile.makeTokenPlan` directly at session-launch sites.
    private func sessionTokenPlan(for profile: Profile, salt: Data) -> SessionTokenPlan {
        let available = mitmEngine?.claudeSubscriptionStore.hasCredential(for: profile.id) ?? false
        let plan = profile.makeTokenPlan(salt: salt, claudeSubscriptionAvailable: available)
        if let bogus = plan.claudeSubscriptionBogusKey {
            mitmEngine?.claudeSubscriptionStore.registerBogusKey(bogus, for: profile.id)
        }
        return plan
    }

    /// Codex subscription mode: write a bogus `~/.codex/auth.json` into the
    /// profile's (host-side, pre-boot) home dir so the guest runs Codex without
    /// logging in. The bogus access/id JWTs carry a far-future `exp` so the
    /// guest never refreshes; the host owns the real token + refresh and the
    /// proxy swaps the bogus Bearer for the live one on chatgpt.com/openai.com.
    /// No-op unless this profile is Codex+subscription with a registered cred.
    func seedCodexAuthFile(for profile: Profile) {
        guard let engine = mitmEngine,
              profile.allToolSpecs.contains(where: { $0.tool == .codex && $0.authMode == .subscription }),
              let real = engine.codexSubscriptionStore.record(for: profile.id) else { return }
        let saltA = Data("codex-bogus-access:\(profile.id)".utf8)
        let saltR = Data("codex-bogus-refresh:\(profile.id)".utf8)
        let saltI = Data("codex-bogus-id:\(profile.id)".utf8)
        guard let bogusAccess = SubscriptionFakeMint.mintNoRefreshJWTFake(
                realJWT: real.accessToken, salt: saltA),
              let bogusID = SubscriptionFakeMint.mintNoRefreshJWTFake(
                realJWT: real.idToken, salt: saltI) else {
            FileHandle.standardError.write(Data(
                "[codex-sub] seed skipped — stored tokens aren't JWT-shaped\n".utf8))
            return
        }
        let bogusRefresh = SubscriptionFakeMint.mintCodexRefreshFake(real: real.refreshToken, salt: saltR)
        engine.codexSubscriptionStore.registerBogusKey(bogusAccess, for: profile.id)

        var tokens: [String: Any] = [
            "id_token": bogusID, "access_token": bogusAccess, "refresh_token": bogusRefresh,
        ]
        if let accountID = Self.codexAccountID(fromIDToken: real.idToken) {
            tokens["account_id"] = accountID
        }
        let doc: [String: Any] = [
            "OPENAI_API_KEY": NSNull(),
            "tokens": tokens,
            "last_refresh": ISO8601DateFormatter().string(from: Date()),
        ]
        let dir = store.homeDirectory(for: profile).appendingPathComponent(".codex", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("auth.json")
        if let data = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted]) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
        }
    }

    /// Grok subscription mode: write a bogus `~/.grok/auth.json` into the
    /// profile's (host-side, pre-boot) home dir so the guest runs Grok without
    /// logging in. The bogus token carries a far-future `expires_at` so the
    /// guest never refreshes; the host owns refresh and the proxy swaps the
    /// bogus Bearer for the live one on cli-chat-proxy.grok.com.
    func seedGrokAuthFile(for profile: Profile) {
        guard let engine = mitmEngine,
              profile.allToolSpecs.contains(where: { $0.tool == .grok && $0.authMode == .subscription }),
              let real = engine.grokSubscriptionStore.record(for: profile.id) else { return }
        let saltA = Data("grok-bogus-access:\(profile.id)".utf8)
        let saltR = Data("grok-bogus-refresh:\(profile.id)".utf8)
        // Grok's access token is a JWT — mint a JWT-shaped bogus (real claims,
        // far-future exp, fake signature) so grok can decode it locally;
        // an opaque placeholder makes grok treat the session as logged out.
        let bogusAccess = SubscriptionFakeMint.mintNoRefreshJWTFake(
                realJWT: real.accessToken, salt: saltA)
            ?? SessionTokenPlan.deriveFake(
                prefix: "grok-brm-", real: real.accessToken, salt: saltA,
                targetLength: max(40, real.accessToken.count))
        let bogusRefresh = SessionTokenPlan.deriveFake(
            prefix: "grokrt-brm-", real: real.refreshToken, salt: saltR,
            targetLength: max(40, real.refreshToken.count))
        engine.grokSubscriptionStore.registerBogusKey(bogusAccess, for: profile.id)

        // Rebuild grok's scope entry from the captured template (which carries
        // the account-specific fields grok's strict serde requires —
        // auth_mode, team_name, subscription_tier, …) and inject bogus secrets.
        // `expires_at` must be an RFC 3339 STRING (serde rejects a bare epoch
        // integer, making the file unreadable). Push it ~10y out.
        let farFuture = ISO8601DateFormatter().string(
            from: Date().addingTimeInterval(10 * 365 * 24 * 3600))
        var entry: [String: Any] = (real.templateJSON.flatMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        }) ?? [:]
        entry["key"] = bogusAccess
        entry["refresh_token"] = bogusRefresh
        entry["expires_at"] = farFuture
        let doc: [String: Any] = [real.scopeKey: entry]
        let dir = store.homeDirectory(for: profile).appendingPathComponent(".grok", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("auth.json")
        if let data = try? JSONSerialization.data(withJSONObject: doc, options: [.prettyPrinted]) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
        }
    }

    /// Pull `chatgpt_account_id` out of a Codex id-token JWT (best effort).
    static func codexAccountID(fromIDToken jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var s = String(parts[1]).replacingOccurrences(of: "-", with: "+")
                                .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let d = Data(base64Encoded: s),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        if let auth = obj["https://api.openai.com/auth"] as? [String: Any],
           let acct = auth["chatgpt_account_id"] as? String { return acct }
        return obj["chatgpt_account_id"] as? String
    }

    private func populateMCPBearerTokens(in profile: inout Profile) {
        for i in profile.mcpServers.indices {
            guard profile.mcpServers[i].enabled,
                  profile.mcpServers[i].transport == .http,
                  var oauth = profile.mcpServers[i].oauthState else { continue }
            guard !oauth.accessToken.isEmpty else { continue }
            if let exp = oauth.expiresAt, exp.timeIntervalSinceNow < 60,
               oauth.refreshToken != nil {
                let sem = DispatchSemaphore(value: 0)
                Task.detached {
                    do {
                        let refreshed = try await MCPOAuthBroker.refresh(state: oauth)
                        oauth = refreshed
                    } catch { /* keep stale token */ }
                    sem.signal()
                }
                _ = sem.wait(timeout: .now() + 10)
                profile.mcpServers[i].oauthState = oauth
            }
            profile.mcpServers[i].bearerToken = oauth.accessToken
        }
    }
}

/// Big-endian uint32 → Data. Wire-format helper used in the OpenSSH
/// public-key blob.
private func uint32be(_ v: UInt32) -> Data {
    var be = v.bigEndian
    return Data(bytes: &be, count: 4)
}

// MARK: - reset

struct Reset: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Delete the base image so the next `init` starts from scratch."
    )

    @Flag(name: .long, help: "Skip the confirmation prompt.")
    var yes: Bool = false

    func run() throws {
        let imageManager = try makeImageManager()
        if !yes {
            print("This will delete \(imageManager.baseDiskURL.path). Continue? [y/N] ", terminator: "")
            guard let line = readLine(), line.lowercased().hasPrefix("y") else {
                print("Aborted.")
                return
            }
        }
        let fm = FileManager.default
        for url in [imageManager.baseDiskURL, imageManager.efiVarsURL, imageManager.versionStampURL] {
            try? fm.removeItem(at: url)
        }
        print("Base image cleared.")
    }
}

// MARK: - shared

private func makeImageManager() throws -> UbuntuImageManager {
    let dir = try locateSetupDir()
    return UbuntuImageManager(setupDir: dir)
}

/// Locate the vm-setup directory (containing setup.sh) shipped in the SPM
/// resource bundle. `acResourceBundle` handles both the .app layout
/// (Contents/Resources/) and the `swift run` layout.
private func locateSetupDir() throws -> URL {
    if let url = acResourceBundle.url(forResource: "vm-setup", withExtension: nil) {
        return url
    }
    throw ValidationError("vm-setup directory not found in resource bundle")
}
