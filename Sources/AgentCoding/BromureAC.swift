import ArgumentParser
import Cocoa
import Crypto
import Foundation
import SandboxEngine
import Sparkle
import SwiftUI
@preconcurrency import Virtualization

@main
struct BromureAC: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bromure-ac",
        abstract: "Run Codex / Claude Code in an isolated, persistent VM.",
        subcommands: [Init.self, Run.self, Reset.self],
        // No-arg invocation (double-click in Finder, `open` w/o args,
        // bare `bromure-ac` in a terminal) opens the GUI. CLI users who
        // want headless setup still have `bromure-ac init`.
        defaultSubcommand: Run.self
    )
}

// MARK: - init

struct Init: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Build the Ubuntu base image (one-time, ~10 min)."
    )

    @Flag(name: .long, help: "Force rebuild even if a base image already exists.")
    var force: Bool = false

    func run() throws {
        let imageManager = try makeImageManager()
        if force {
            try? FileManager.default.removeItem(at: imageManager.versionStampURL)
        }
        // Pump the main RunLoop while an async Task does the actual build.
        // We can't `semaphore.wait()` here because `runInstaller` is
        // @MainActor — a sync block of the main thread starves the main
        // actor's executor and the install hangs at the first MainActor hop.
        // Driving the RunLoop instead lets MainActor continuations run.
        var result: Result<Void, Error>?
        Task {
            do {
                try await imageManager.createBaseImage { msg in
                    FileHandle.standardError.write(Data("[init] \(msg)\n".utf8))
                }
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

// MARK: - run

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Boot a session against the base image and open the display window."
    )

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
        MainActor.assumeIsolated {
            FileHandle.standardError.write(Data("[run] launching NSApplication…\n".utf8))
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)

            let delegate = ACAppDelegate(imageManager: imageManager)
            app.delegate = delegate
            app.mainMenu = makeMainMenu(delegate: delegate)

            app.run()
        }
    }
}

/// Minimal menu so ⌘-Q, ⌘-W, etc. work. No File / Edit / View / Help yet —
/// those land in Phase C alongside the profile picker.
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
    let inspectorItem = NSMenuItem(title: L("Trace Inspector…"),
                                   action: #selector(ACAppDelegate.openTraceInspectorAction(_:)),
                                   keyEquivalent: "i")
    inspectorItem.keyEquivalentModifierMask = [.command, .shift]
    inspectorItem.target = delegate
    windowMenu.addItem(inspectorItem)
    return main
}

/// App delegate for `bromure-ac run`. Hosts the profile picker, the
/// create-profile wizard, and (once a profile launches) the
/// VZVirtualMachineView for that session.
@MainActor
final class ACAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let imageManager: UbuntuImageManager
    private let store = ProfileStore()
    private var profiles: [Profile] = []

    /// Snapshot of Terminal.app's default profile captured at app launch.
    /// Cached so changes the user makes to Terminal.app while AC is
    /// running don't surprise them mid-session.
    private let terminalDefaults: TerminalAppDefaults = TerminalAppDefaults.load()

    private var mainWindow: NSWindow?
    private var editorWindow: NSWindow?
    private var sshWindow: NSWindow?
    private var editorEditingProfile: Profile?  // nil = creating

    /// One window per profile. Each window holds N tabs, each tab is a
    /// distinct VM session.
    private var profileWindows: [Profile.ID: TabbedSessionWindow] = [:]

    /// NSEvent monitor that intercepts ⌘T / ⌘W / ⌘1-9 at the
    /// application level — before the responder chain, before VZ's
    /// `capturesSystemKeys` swallows them.
    private var keyMonitor: Any?

    /// Progress model for the in-app `init` flow (first-time setup or
    /// version-bump rebuild).
    private let initProgress = InitProgressModel()

    /// Process-lifetime MITM engine. One instance per app run, holds
    /// the CA + per-profile token swap maps + ssh-agent keystore. Lazy
    /// because CA generation hits disk on first access.
    private lazy var mitmEngine: MitmEngine? = {
        do { return try MitmEngine() }
        catch {
            FileHandle.standardError.write(Data(
                "[mitm] engine init failed: \(error) — sessions will run without proxy\n".utf8))
            return nil
        }
    }()

    /// SPM-resource-bundle path to the in-VM bridge script. Resolved
    /// once and copied into each session's meta share.
    private lazy var bridgeScriptURL: URL? = {
        Bundle.module.url(forResource: "vm-setup/bromure-vm-bridge",
                          withExtension: "py")
    }()

    /// Sparkle auto-updater. Retained strongly — if this deallocates,
    /// scheduled update checks stop firing. Initialised in
    /// applicationDidFinishLaunching. Silently no-ops on dev builds where
    /// SUPublicEDKey isn't populated.
    private var updaterController: SPUStandardUpdaterController?


    init(imageManager: UbuntuImageManager) {
        self.imageManager = imageManager
        super.init()
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        profiles = store.loadAll()

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
        }

        // Force-init the MITM engine so the CA is ready before any
        // session opens (the lazy var would defer this to first launch,
        // adding a perceptible pause on the first session and racing
        // the VM boot path).
        _ = mitmEngine
        if let engine = mitmEngine {
            FileHandle.standardError.write(Data(
                "[mitm] engine ready; CA loaded from \(engine.ca.certificate.subject)\n".utf8))
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 420),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Bromure Agentic Coding"
        window.delegate = self
        window.titlebarAppearsTransparent = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.mainWindow = window

        // Pick the right initial screen: setup if there's no base image
        // yet, otherwise the profile picker.
        if imageManager.hasBaseImage {
            renderPicker()
            if profiles.isEmpty { openEditorWindow(editing: nil) }
        } else {
            renderSetup()
        }
        NSApp.activate(ignoringOtherApps: true)

        // ⌘T / ⌘W / ⌘1-9 must run BEFORE VZVirtualMachineView eats them
        // (it sets capturesSystemKeys = true so menus + window
        // performKeyEquivalent are bypassed). A local monitor fires
        // before any of that, so we can intercept here.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.interceptKey(event) ?? event
        }
    }

    private func interceptKey(_ event: NSEvent) -> NSEvent? {
        // Tolerate the .function modifier (Apple sets it for some keys
        // unexpectedly) — the meaningful test is "is Command held alone
        // among the user-meaningful modifiers".
        let mods = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.function)
        guard mods == [.command] else { return event }

        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        // ⌘H = standard macOS "hide app". Handle here defensively in
        // case responder-chain routing is interfered with elsewhere.
        if chars == "h" {
            NSApp.hide(nil)
            return nil
        }

        // The remaining shortcuts (⌘T / ⌘W / ⌘1-9) only make sense
        // when a session window is up. Without one, defer to the
        // standard responder chain.
        let sessions = NSApp.windows.compactMap { $0 as? TabbedSessionWindow }
        let win = (NSApp.keyWindow as? TabbedSessionWindow)
            ?? sessions.first(where: { $0.isVisible })
        guard let win else { return event }

        switch chars {
        case "t":
            print("[BromureAC] ⌘T → spawn tab in '\(win.profile.name)'")
            spawnNewTab(in: win)
            return nil
        case "w":
            print("[BromureAC] ⌘W → close active tab in '\(win.profile.name)'")
            win.closeTab(at: win.model.activeIndex)
            return nil
        default:
            if let n = Int(chars), (1...9).contains(n),
               win.model.tabs.indices.contains(n - 1) {
                print("[BromureAC] ⌘\(n) → switch tab in '\(win.profile.name)'")
                win.switchTo(index: n - 1)
                return nil
            }
            // Anything else (incl. ⌘Tab, ⌘Q, ⌘Space) falls through to
            // the system. Since the VZ view no longer captures system
            // keys, macOS handles these natively.
            return event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Quit only when literally every window is gone — picker + all
        // session windows. Closing one session shouldn't take the others
        // down with it.
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Nuke our private ssh-agent. The orphaned-process risk is
        // small (it's idle and tiny) but worth tidying up at least
        // for the clean-quit path.
        mitmEngine?.privateAgent.terminate()
    }

    func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow else { return }
        if win === mainWindow {
            mainWindow = nil
            return
        }
        if win === traceInspectorWindow {
            traceInspectorWindow = nil
            return
        }
        if let session = win as? TabbedSessionWindow {
            // Stop the single shared VM. All in-VM kittys die with it.
            // Prefer a clean ACPI poweroff so systemd has a chance to
            // unmount /home (the host-side virtiofs share), flush
            // shell history, etc. If the guest doesn't ack the
            // shutdown within 30s (no acpid, hung process), fall
            // back to a hard stop so we don't leak a VM forever.
            if let vm = session.sandbox?.vm, vm.state == .running {
                let profileName = session.profile.name
                do {
                    try vm.requestStop()
                    FileHandle.standardError.write(Data(
                        "[ac] requested clean poweroff for '\(profileName)'\n".utf8))
                } catch {
                    FileHandle.standardError.write(Data(
                        "[ac] requestStop failed (\(error)) — forcing\n".utf8))
                    vm.stop(completionHandler: { _ in })
                }
                // Watchdog. Captures `vm` strongly inside the Task
                // so it stays alive for the deadline; once the Task
                // completes the ref drops naturally.
                let watchdogVM = vm
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(30))
                    if watchdogVM.state == .running {
                        FileHandle.standardError.write(Data(
                            "[ac] '\(profileName)' didn't poweroff in 30s — forcing stop\n".utf8))
                        watchdogVM.stop(completionHandler: { _ in })
                    }
                }
            }
            // Drop the engine's per-profile state — token map, ssh
            // keys, listener delegates. Otherwise we leak per-session
            // until app quit.
            for key in loadAgentKeys(for: session.profile) {
                removeKeyFromHostAgent(publicKey: key.publicKey)
            }
            mitmEngine?.clearSessionTrace(for: session.profile.id)
            mitmEngine?.unregister(profileID: session.profile.id)
            profileWindows.removeValue(forKey: session.profile.id)
            renderPicker()
            if mainWindow == nil && profileWindows.isEmpty {
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Screen wiring

    private func renderSetup() {
        guard let win = mainWindow else { return }
        win.title = "Bromure Agentic Coding"
        win.setContentSize(NSSize(width: 540, height: 420))
        win.contentView = NSHostingView(rootView: SetupView(onStart: { [weak self] in
            self?.startInit()
        }))
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
        if force {
            try? FileManager.default.removeItem(at: imageManager.versionStampURL)
        }
        initProgress.status = "Preparing…"
        initProgress.consoleLog = ""
        initProgress.error = nil
        initProgress.isRunning = true
        renderInitializing()

        Task { @MainActor in
            do {
                try await imageManager.createBaseImage(
                    progress: { msg in
                        // High-level checkpoints: drive the status pill +
                        // bookmark the console log with a leading marker
                        // so they're easy to find in the firehose.
                        Task { @MainActor in
                            self.initProgress.status = msg
                            self.initProgress.appendLog("\n▶ " + msg + "\n")
                        }
                    },
                    output: { chunk in
                        // Raw guest serial bytes — append as-is so timing
                        // and apt's progress lines look the same as on stderr.
                        Task { @MainActor in
                            self.initProgress.appendLog(chunk)
                        }
                    }
                )
                self.initProgress.isRunning = false
                self.profiles = self.store.loadAll()
                self.renderPicker()
                if self.profiles.isEmpty { self.openEditorWindow(editing: nil) }
            } catch {
                self.initProgress.isRunning = false
                self.initProgress.error = error.localizedDescription
            }
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

    /// Wired to the "Rebuild Base Image…" menu item. Confirms, then
    /// runs `init --force` from inside the GUI — same flow as the
    /// first-time setup, but proactive.
    private var traceInspectorWindow: NSWindow?

    /// Wired to the "Trace Inspector…" menu item (⇧⌘I).
    /// Opens the inspector with no profile pre-filter.
    @objc func openTraceInspectorAction(_ sender: Any?) {
        openTraceInspector(for: nil)
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

    @objc func rebuildBaseImageAction(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Rebuild the base image?"
        alert.informativeText = "Re-runs the full Ubuntu installer (~5–10 min) using the current setup.sh. Existing profiles' disks aren't touched — on next launch each one's drift prompt will offer to reset to the new base."
        alert.addButton(withTitle: "Rebuild")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            startInit(force: true)
        }
    }

    /// Re-render the picker (reflecting current profiles + which sessions
    /// are running). Idempotent; safe to call from anywhere.
    private func renderPicker() {
        guard let win = mainWindow else { return }
        let runningIDs = Set(profileWindows.keys)
        let view = ProfilePickerView(
            profiles: Binding(get: { self.profiles }, set: { self.profiles = $0 }),
            runningProfiles: runningIDs,
            onLaunch:        { self.launch($0) },
            onCreate:        { self.openEditorWindow(editing: nil) },
            onEdit:          { self.openEditorWindow(editing: $0) },
            onReset:         { self.resetProfile($0) },
            onDelete:        { self.deleteProfile($0) },
            onShowPublicKey: { self.openSSHWindow(for: $0) }
        )
        win.contentView = NSHostingView(rootView: view)
    }

    /// editing == nil → create. editing != nil → modify in place.
    private func openEditorWindow(editing: Profile?) {
        if let existing = editorWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        editorEditingProfile = editing

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        win.title = editing == nil ? "New profile" : "Edit profile"
        win.center()
        win.contentView = NSHostingView(rootView: ProfileEditorView(
            profile: editing,
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
                let target = editing ?? Profile(name: "", tool: .claude, authMode: .token)
                if editing == nil {
                    try self.store.save(target)
                }
                return try self.importSSHKey(at: url, passphrase: passphrase,
                                              label: label, for: target)
            },
            onRemoveSSHKey: { [weak self] key in
                guard let self, let editing else { return }
                self.removeImportedSSHKey(key, for: editing)
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
            isRunning: profileWindows[editing.id] != nil,
            onResetDisk: { [weak self] in self?.resetProfile(editing) },
            onResetHome: { [weak self] in self?.resetHomeProfile(editing) }
        )
    }

    private func closeEditorWindow() {
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
        // Editing keeps the original id (already preserved by ProfileEditorView).
        do {
            try store.save(profile)
            try store.prepareHomeDirectory(for: profile, terminalDefaults: terminalDefaults)
            if generateSSH {
                // Agent dir is host-only — never mounted into the VM.
                // The private seed lives here; the public key gets a
                // courtesy copy into the VM's ~/.ssh for reference.
                let agentDir = store.profileDirectory(for: profile)
                    .appendingPathComponent("agent", isDirectory: true)
                let pub = try makeSSHKey(in: agentDir)
                profile.sshPublicKey = pub
                try store.save(profile)
            }
        } catch {
            showError(error, message: editing == nil
                      ? "Couldn't create the profile."
                      : "Couldn't save the profile.")
            return
        }
        profiles = store.loadAll()
        renderPicker()
        closeEditorWindow()
        // Show the SSH key viewer right after a brand-new generation so the
        // user can paste it into GitHub before forgetting.
        if generateSSH, profile.sshPublicKey != nil { openSSHWindow(for: profile) }
    }

    private func resetProfile(_ profile: Profile) {
        if profileWindows[profile.id] != nil {
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
        } catch {
            showError(error, message: "Couldn't reset the disk.")
        }
    }

    /// Wipe the per-profile home directory. Inverse blast-radius from
    /// `resetProfile`: system layer survives, but everything personal
    /// the user accumulated under /home/ubuntu is gone.
    private func resetHomeProfile(_ profile: Profile) {
        if profileWindows[profile.id] != nil {
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
                renderPicker()
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
        alert.messageText = "Delete profile “\(profile.name)”?"
        alert.informativeText = "Removes its disk, settings, and SSH key. The mounted host folder is untouched."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try store.delete(profile)
            profiles = store.loadAll()
            renderPicker()
        } catch {
            showError(error, message: "Couldn't delete the profile.")
        }
    }

    func launch(_ profile: Profile) {
        // If a window is already open for this profile, just focus it.
        if let existing = profileWindows[profile.id] {
            existing.makeKeyAndOrderFront(nil)
            return
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
            alert.messageText = "Base image updated since this profile was created."
            alert.informativeText = "This profile is on base v\(recorded); the current base is v\(current). Reset the profile disk to pick up the new base? (Resetting wipes anything you've installed inside the VM. Your project folder is untouched.)"
            alert.addButton(withTitle: "Reset and launch")
            alert.addButton(withTitle: "Launch as-is")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                try? store.resetDisk(for: profile)
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
        let salt = mitmEngine?.fakeTokenSalt ?? Data(repeating: 0, count: 32)
        let plan = profile.makeTokenPlan(salt: salt)
        try? store.prepareHomeDirectory(for: profile,
                                        terminalDefaults: terminalDefaults,
                                        tokenPlan: plan)

        // Push the plan + ssh keys to the engine before VM start, so
        // the listeners we register after boot have something to swap.
        if let engine = mitmEngine {
            engine.swapper.setMap(plan.tokenMap(), for: profile.id)
            // Tell the trace store what level + session id to record
            // under for traffic from this profile.
            engine.setSessionTrace(
                MitmEngine.SessionTrace(sessionID: UUID(), level: profile.traceLevel),
                for: profile.id)
            let agentKeys = loadAgentKeys(for: profile)
            engine.sshAgent.setKeys(agentKeys, for: profile.id)
            FileHandle.standardError.write(Data(
                "[mitm] session launch for '\(profile.name)': loaded \(agentKeys.count) agent key(s)\n".utf8))
            // Mirror the per-profile key into our private bromure
            // ssh-agent so the in-VM ssh client (via the multiplex)
            // and macOS-side commands both see it.
            for key in agentKeys {
                addKeyToHostAgent(seed: key.seed,
                                  publicKey: key.publicKey,
                                  comment: "bromure-ac:\(profile.name)")
            }
            // Plus any pre-existing keys the user imported via the
            // editor — passphrase-protected ones use the macOS Keychain
            // for the password, fed through SSH_ASKPASS.
            loadImportedSSHKeys(for: profile)
        } else {
            FileHandle.standardError.write(Data(
                "[mitm] session launch for '\(profile.name)': MITM ENGINE IS NIL — nothing will be wired\n".utf8))
        }

        // First session for this profile — create the tabbed window with
        // its single shared VM, then queue the first tab.
        let win = TabbedSessionWindow(profile: profile, acDelegate: self)
        win.delegate = self
        win.center()
        win.makeKeyAndOrderFront(nil)
        win.isReleasedWhenClosed = false
        profileWindows[profile.id] = win
        renderPicker()

        // Show the first tab placeholder immediately. The VM will pick up
        // the spawn-kitty command from the outbox once boot finishes.
        let firstTab = win.appendTab()

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
                    bridgeScriptURL: scriptURL)
            }
            let sandbox = UbuntuSandboxVM(imageManager: imageManager, sessionDisk: sessionDisk)
            do {
                try sandbox.prepare()
                win.vmView.virtualMachine = sandbox.vm
                try await sandbox.start()
            } catch {
                self.showError(error, message: "Couldn't start the VM for “\(profile.name)”.")
                win.close()
                return
            }
            // Register the per-VM vsock listeners on the freshly-booted
            // VM. Done after start so the socket device is live.
            if let engine = self.mitmEngine, let dev = sandbox.socketDevice {
                engine.register(socketDevice: dev, profileID: profile.id)
            }
            if sessionDisk.didCloneOnLastEnsure, let current = currentBaseVersion {
                var p = profile
                p.baseImageVersionAtClone = current
                try? self.store.save(p)
                self.profiles = self.store.loadAll()
                self.renderPicker()
            }
            sandbox.onStopped = { [weak win] _ in
                Task { @MainActor in win?.close() }
            }
            sandbox.onURLOpen = { url in NSWorkspace.shared.open(url) }
            sandbox.onTabClosed = { [weak win] id in
                Task { @MainActor in win?.handleTabClosedFromGuest(id: id) }
            }
            sandbox.onTabTitleUpdate = { [weak win] id, title in
                Task { @MainActor in win?.handleTabTitleUpdate(id: id, title: title) }
            }
            sandbox.onIPUpdate = { [weak win] ip in
                Task { @MainActor in win?.model.ipAddress = ip }
            }
            win.sandbox = sandbox

            // Spawn the first kitty in the freshly-booted VM.
            self.requestSpawnKitty(id: firstTab.id, in: win)

            // NAT-only: watch for the in-guest IP reporter to land an
            // address. If nothing arrives within the timeout, vmnet's
            // shared NAT path is likely wedged — offer to repair via
            // the same NetworkHealer the browser uses.
            if profile.networkMode == .nat {
                self.startNetworkHealerWatch(profile: profile, window: win)
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
                                         window: TabbedSessionWindow) {
        Task { @MainActor [weak self, weak window] in
            // 25 polls × 1s = 25s window. xinitrc reports the address
            // on a 5s loop, so we expect it well within this budget on
            // a healthy install (typically 4-8s after boot).
            for _ in 0..<25 {
                try? await Task.sleep(for: .seconds(1))
                if window == nil { return }
                if window?.model.ipAddress?.isEmpty == false { return }
            }
            guard let self, let window, window.isVisible else { return }
            // Re-check inside the @MainActor isolation in case the IP
            // landed during the last sleep tick.
            if window.model.ipAddress?.isEmpty == false { return }
            await self.presentNetworkHealerPrompt(profile: profile, window: window)
        }
    }

    @MainActor
    private func presentNetworkHealerPrompt(profile: Profile,
                                            window: TabbedSessionWindow) async {
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
            window.close()
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
            // Cancel: just close the wedged session.
            window.close()
        }
    }

    /// Add another tab (= another kitty in the same VM). Wired from the
    /// toolbar "+" button and ⌘T.
    func spawnNewTab(in window: TabbedSessionWindow) {
        let tab = window.appendTab()
        requestSpawnKitty(id: tab.id, in: window)
    }

    /// Tell the in-VM tab agent to launch a kitty whose WM_CLASS encodes
    /// this tab's UUID. Fire-and-forget — the agent picks up the file on
    /// its next 200ms poll.
    func requestSpawnKitty(id: UUID, in window: TabbedSessionWindow) {
        sendCommand("spawn-kitty \(id.uuidString)", in: window)
    }

    /// Tell the in-VM tab agent to raise the kitty matching this UUID.
    /// Requires xdotool inside the guest; silently no-ops if missing.
    func requestRaiseTab(id: UUID, in window: TabbedSessionWindow) {
        sendCommand("raise-kitty \(id.uuidString)", in: window)
    }

    /// Tell the in-VM tab agent to close the kitty matching this UUID.
    func requestCloseTab(id: UUID, in window: TabbedSessionWindow) {
        sendCommand("close-kitty \(id.uuidString)", in: window)
    }

    private func sendCommand(_ command: String, in window: TabbedSessionWindow) {
        guard let outbox = window.sandbox?.sessionDisk?.outboxDirectory else { return }
        let file = outbox.appendingPathComponent("cmd-\(UUID().uuidString).txt")
        try? (command + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private func readCurrentBaseVersion() -> String? {
        try? String(contentsOf: imageManager.versionStampURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private func showError(_ error: Error, message: String) {
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
                         seed: Data(secret))]
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

    /// Add the per-profile key to the user's macOS ssh-agent so the
    /// VM (and macOS Terminal) both see it without the user having
    /// to `ssh-add` anything by hand. Idempotent — re-adding an
    /// already-loaded key is harmless. Removed in `windowWillClose`.
    private func addKeyToHostAgent(seed: Data, publicKey: Data, comment: String) {
        // Target our private bromure ssh-agent specifically — the
        // user's macOS launchd agent might not be running, and we
        // want predictable lifecycle (key gone when bromure-ac quits).
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
/// resource bundle. Resolves first via Bundle.module (the standard SPM
/// path) and falls back to the bundled .app layout that build.sh produces.
private func locateSetupDir() throws -> URL {
    if let url = Bundle.module.url(forResource: "vm-setup", withExtension: nil) {
        return url
    }
    let exec = Bundle.main.bundleURL
    let candidate = exec
        .appendingPathComponent("Contents/Resources/bromure_bromure-ac.bundle/vm-setup")
    if FileManager.default.fileExists(atPath: candidate.path) {
        return candidate
    }
    throw ValidationError("vm-setup directory not found in resource bundle")
}
