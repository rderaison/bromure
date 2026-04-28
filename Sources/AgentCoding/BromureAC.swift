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
private let acResourceBundle: Bundle = {
    let bundleName = "bromure_bromure-ac"
    if let resourceURL = Bundle.main.resourceURL,
       let bundle = Bundle(url: resourceURL.appendingPathComponent("\(bundleName).bundle")) {
        return bundle
    }
    return Bundle.module
}()

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
        // The build path keeps the existing image usable until the
        // new one is ready (writes go to .partial files, then atomic
        // swap), so we don't pre-delete the version stamp.
        // Pump the main RunLoop while an async Task does the actual build.
        // We can't `semaphore.wait()` here because `runInstaller` is
        // @MainActor — a sync block of the main thread starves the main
        // actor's executor and the install hangs at the first MainActor hop.
        // Driving the RunLoop instead lets MainActor continuations run.
        var result: Result<Void, Error>?
        let forceFlag = force
        Task {
            do {
                try await imageManager.createBaseImage(
                    progress: { msg in
                        FileHandle.standardError.write(Data("[init] \(msg)\n".utf8))
                    },
                    force: forceFlag
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
    let pickerItem = NSMenuItem(title: L("Profile Manager"),
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

    let approvalsItem = NSMenuItem(title: L("Credential Approvals…"),
                                   action: #selector(ACAppDelegate.openCredentialApprovalsAction(_:)),
                                   keyEquivalent: "")
    approvalsItem.target = delegate
    windowMenu.addItem(approvalsItem)

    // Hand the menu to NSApp so AppKit auto-appends entries for every
    // titled, non-excluded window. Session windows already get
    // meaningful titles (claude / codex / vim / bash / etc.) so they
    // appear here as the user opens them — Picker / Trace Inspector /
    // session windows all routable from one place.
    NSApp.windowsMenu = windowMenu
    return main
}

/// App delegate for `bromure-ac run`. Hosts the profile picker, the
/// create-profile wizard, and (once a profile launches) the
/// VZVirtualMachineView for that session.
@MainActor
final class ACAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let imageManager: UbuntuImageManager
    let store = ProfileStore()
    var profiles: [Profile] = []

    /// Snapshot of Terminal.app's default profile captured at app launch.
    /// Cached so changes the user makes to Terminal.app while AC is
    /// running don't surprise them mid-session.
    private let terminalDefaults: TerminalAppDefaults = TerminalAppDefaults.load()

    /// Internal so the AppleScript bridge can read window IDs.
    var mainWindow: NSWindow?
    var editorWindow: NSWindow?
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

    /// Retained handle to the in-flight base-image build Task. Used to
    /// cancel cleanly when the user confirms a close mid-install —
    /// otherwise the Task keeps pushing model updates after the window
    /// is gone and the autorelease pool over-releases on the next tick.
    private var installTask: Task<Void, Never>?

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
        acResourceBundle.url(forResource: "vm-setup/bromure-vm-bridge",
                             withExtension: "py")
    }()

    /// SPM-resource-bundle path to the in-VM keyboard agent. Pushed
    /// into the meta share so xinitrc can launch it; the host-side
    /// `KeyboardBridge` then ferries macOS layout changes to it.
    private lazy var keyboardAgentURL: URL? = {
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

    /// SPM-resource-bundle path to the AWS `credential_process` helper.
    /// Shipped to /mnt/bromure-meta and referenced from the per-profile
    /// ~/.aws/config so the SDK pulls JSON creds from the host on demand.
    private lazy var awsCredsHelperURL: URL? = {
        acResourceBundle.url(forResource: "vm-setup/bromure-aws-creds",
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

        // Pick the right initial screen: setup if there's no base image
        // yet, otherwise the profile picker.
        if imageManager.hasBaseImage {
            renderPicker()
            if profiles.isEmpty { openEditorWindow(editing: nil) }
            // Stale image — nag (non-blocking) but let the user keep
            // working with the existing base.
            if imageManager.baseImageNeedsUpdate {
                Task { @MainActor in
                    self.promptBaseImageUpdate()
                }
            }
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

    /// ⌘Q (and Quit menu) confirmation. Skip the prompt if no VMs are
    /// running — quitting an idle app should be friction-free.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let runningSessions = profileWindows.values.filter {
            $0.sandbox?.vm?.state == .running
        }
        if runningSessions.isEmpty { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Quit Bromure Agentic Coding?", comment: "")
        let names = runningSessions.map { $0.profile.name }.joined(separator: ", ")
        alert.informativeText = String(
            format: NSLocalizedString(
                "%d VM(s) currently running (%@) will shut down and any running processes will be stopped.",
                comment: ""),
            runningSessions.count, names)
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Quit", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Nuke our private ssh-agent. The orphaned-process risk is
        // small (it's idle and tiny) but worth tidying up at least
        // for the clean-quit path.
        mitmEngine?.privateAgent.terminate()
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
                renderPicker()
                resizeMainWindowForPicker()
            } else {
                renderSetup()
            }
            return false
        }

        guard let session = sender as? TabbedSessionWindow else { return true }
        return decideSessionClose(for: session)
    }

    /// Branch on the profile's `closeAction` setting. Sets
    /// `session.pendingCloseAction` so `windowWillClose` can dispatch
    /// without prompting the user a second time.
    private func decideSessionClose(for session: TabbedSessionWindow) -> Bool {
        switch session.profile.closeAction {
        case .suspend:
            session.pendingCloseAction = .suspend
            return true
        case .shutdown:
            return confirmShutdown(for: session)
        case .ask:
            return askCloseAction(for: session)
        }
    }

    /// Two-button "Are you sure?" used when the profile is set to shut
    /// down on close. Default button is Cancel so an accidental ⌘W +
    /// Enter doesn't blow the VM away.
    private func confirmShutdown(for session: TabbedSessionWindow) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("Shut down session “%@”?", comment: ""),
            session.profile.name)
        alert.informativeText = NSLocalizedString(
            "The VM will shut down and any running processes will be stopped.",
            comment: "")
        alert.alertStyle = .warning
        let closeButton = alert.addButton(withTitle: NSLocalizedString("Shut down", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        closeButton.keyEquivalent = ""
        if alert.runModal() == .alertFirstButtonReturn {
            session.pendingCloseAction = .shutdown
            return true
        }
        return false
    }

    /// Three-button picker used when the profile is set to ask. Suspend
    /// is the primary action (matches the suspend-by-default vibe of
    /// the rest of the app).
    private func askCloseAction(for session: TabbedSessionWindow) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("Close session “%@”?", comment: ""),
            session.profile.name)
        alert.informativeText = NSLocalizedString(
            "Suspend keeps the VM's state on disk so it resumes instantly next time. Shut down powers it off cleanly.",
            comment: "")
        alert.alertStyle = .informational
        alert.addButton(withTitle: NSLocalizedString("Suspend", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Shut down", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            session.pendingCloseAction = .suspend
            return true
        case .alertSecondButtonReturn:
            session.pendingCloseAction = .shutdown
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let win = notification.object as? NSWindow else { return }
        if win === mainWindow {
            mainWindow = nil
            return
        }
        if win === credentialApprovalsWindow {
            credentialApprovalsWindow = nil
        }
        if win === traceInspectorWindow {
            traceInspectorWindow = nil
            return
        }
        if let session = win as? TabbedSessionWindow {
            // Stop the single shared VM. All in-VM kittys die with it.
            // The profile's `closeAction` (resolved in windowShouldClose
            // → session.pendingCloseAction) decides whether to suspend
            // (pause + save RAM to disk for instant resume) or to do a
            // clean ACPI poweroff.
            let profileName = session.profile.name
            if let sandbox = session.sandbox, let vm = sandbox.vm,
               vm.state == .running {
                switch session.pendingCloseAction {
                case .suspend:
                    // Persist the host's tab UUIDs + active index
                    // alongside the RAM snapshot, so restore can
                    // rebuild the bar against the kittys that are
                    // still running inside the resumed VM. Done
                    // BEFORE pause so the model can't drift mid-save.
                    sandbox.sessionDisk?.saveTabs(session.snapshotTabs())
                    Task { @MainActor in
                        do {
                            try await sandbox.suspend()
                            FileHandle.standardError.write(Data(
                                "[ac] suspended '\(profileName)' to disk\n".utf8))
                        } catch {
                            FileHandle.standardError.write(Data(
                                "[ac] suspend failed (\(error)) — forcing stop\n".utf8))
                            // Suspended state may be partial / corrupt;
                            // wipe so next launch boots fresh.
                            sandbox.sessionDisk?.clearSavedState()
                            vm.stop(completionHandler: { _ in })
                        }
                    }
                case .shutdown:
                    // A previously-suspended profile being shut down
                    // explicitly: drop the saved snapshot so the next
                    // launch is fresh.
                    sandbox.sessionDisk?.clearSavedState()
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
        // Same ordering trap as renderPicker: must swap content view
        // first, otherwise the InitializingView's autolayout
        // constraints + contentMinSize=560 (set in renderInitializing)
        // pin the window above the 540 we want here. Cancel-during-
        // bake therefore left the welcome screen oversized.
        win.contentView = NSHostingView(rootView: SetupView(onStart: { [weak self] in
            self?.startInit()
        }))
        win.contentMinSize = .zero
        win.setContentSize(NSSize(width: 540, height: 420))
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
                self.renderPicker()
                // Resize AFTER the picker hosting view is in place.
                // Resizing while the InitializingView is still
                // contentView is defeated by its autolayout
                // constraints — the window snaps back to the
                // installer's 640×480 the instant `renderPicker`
                // triggers a layout pass.
                self.resizeMainWindowForPicker()
                if self.profiles.isEmpty { self.openEditorWindow(editing: nil) }
            } catch {
                self.initProgress.stop()
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
    private var credentialApprovalsWindow: NSWindow?

    /// Wired to the "Trace Inspector…" menu item (⇧⌘I).
    /// Opens the inspector with no profile pre-filter.
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

    /// Window menu → "Profile Manager". Brings the picker forward, or
    /// recreates it if the user closed the window earlier in the
    /// session (windowWillClose nils out `mainWindow`).
    @objc func openProfileManagerAction(_ sender: Any?) {
        if let win = mainWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 420),
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
        if imageManager.hasBaseImage {
            renderPicker()
        } else {
            renderSetup()
        }
        win.makeKeyAndOrderFront(nil)
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

    /// Restore the main window to the picker's natural size after a
    /// screen that resized it (currently only `renderInitializing`,
    /// which sets 640×480 + a tighter min size for the install
    /// console). Cold start with an existing image creates the
    /// window at 540×420 already, so picker rendering there doesn't
    /// hit this path.
    private func resizeMainWindowForPicker() {
        guard let win = mainWindow else { return }
        win.contentMinSize = .zero
        win.setContentSize(NSSize(width: 540, height: 420))
        win.center()
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
            onShowPublicKey: { self.openSSHWindow(for: $0) },
            onDuplicate:     { self.duplicateProfile($0) }
        )
        win.contentView = NSHostingView(rootView: view)
    }

    /// Deep-copy a profile (new UUID, new MAC) using `ProfileStore.duplicate`.
    /// Includes the system disk + home dir via APFS clonefile, the encrypted
    /// secrets blob, host-only ssh material, and every credential — but
    /// skips the suspended VM state (a snapshot tied to the source's MAC
    /// can't safely resume on the duplicate).
    private func duplicateProfile(_ source: Profile) {
        let copyName = source.name + " " + NSLocalizedString("copy", comment: "")
        do {
            _ = try store.duplicate(source, named: copyName)
        } catch {
            showError(error, message: "Couldn't duplicate “\(source.name)”.")
            return
        }
        profiles = store.loadAll()
        renderPicker()
    }

    /// editing == nil → create. editing != nil → modify in place.
    func openEditorWindow(editing: Profile?) {
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
                    "The shared folders changed since this profile was suspended. The snapshot was saved against the old share set, so it can't be safely resumed with the new one.\n\nSaving will discard the suspended state. The next launch will cold-boot. Files in the per-profile home directory and on the shared folders themselves are unaffected.",
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
            let agentKeys = loadAgentKeys(for: profile)
            engine.sshAgent.setKeys(agentKeys, for: profile.id)
            // AWS creds: pushed to the host-side server. The guest's
            // ~/.aws/config points at a credential_process helper that
            // gets the real AKID + a fake secret; the host AWSResigner
            // re-signs each AWS request with the real material so the
            // secret never lives in the VM at all. setCredentials clears
            // the slot when the profile has no usable AWS creds.
            engine.awsCreds.setCredentials(profile.awsCredentials, for: profile.id)
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

        // First session for this profile — create the tabbed window with
        // its single shared VM, then queue the first tab.
        let win = TabbedSessionWindow(profile: profile, acDelegate: self)
        win.delegate = self
        win.center()
        win.makeKeyAndOrderFront(nil)
        win.isReleasedWhenClosed = false
        profileWindows[profile.id] = win
        renderPicker()

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
            // Fresh boot or no saved tabs: queue the placeholder up
            // immediately so the user sees something while VZ boots.
            win.appendTab()
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
                    awsCredsHelperURL: awsCredsHelperURL)
            }
            let sandbox = UbuntuSandboxVM(imageManager: imageManager, sessionDisk: sessionDisk)
            // True only when the resumed snapshot's kittys are still
            // valid — drives spawn-vs-raise at the end of this block.
            var restoredSnapshot = false
            do {
                try sandbox.prepare()
                win.vmView.virtualMachine = sandbox.vm
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
                        // Rehydrated tabs reference kittys that don't
                        // exist on a fresh boot — wipe the model and
                        // queue a fresh placeholder for the spawn path.
                        win.model.tabs.removeAll()
                        win.model.activeIndex = 0
                        win.appendTab()
                    }
                } else {
                    try await sandbox.start()
                }
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
            // Keyboard layout bridge — pushes the macOS layout into the
            // guest at boot and follows live changes (or pins an
            // override layout when the profile sets one).
            if let dev = sandbox.socketDevice {
                win.keyboardBridge = KeyboardBridge(
                    socketDevice: dev,
                    forcedLayout: profile.keyboardLayoutOverride)
            }
            if sessionDisk.didCloneOnLastEnsure, let current = currentBaseVersion {
                var p = profile
                p.baseImageVersionAtClone = current
                try? self.store.save(p)
                self.profiles = self.store.loadAll()
                self.renderPicker()
            }
            self.wireSandboxCallbacks(sandbox, win: win)
            win.sandbox = sandbox

            // Restored snapshots already have kittys running with
            // matching `--class bromure-<UUID>` markers — just raise
            // the previously-active one. Fresh boots (and restore
            // failures that fell back to fresh boot, where the model
            // was reset) need an actual spawn.
            if let target = win.model.activeTab ?? win.model.tabs.first {
                if restoredSnapshot {
                    self.requestRaiseTab(id: target.id, in: win)
                } else {
                    self.requestSpawnKitty(id: target.id, in: win)
                }
            }

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

    /// Reboot dialog: soft (`sudo reboot` inside the guest) or hard
    /// (host-side `vm.stop()`). Both clear the saved RAM snapshot
    /// first so the post-stop relaunch path is a clean fresh boot,
    /// not a restore that would put us right back where we were.
    @MainActor
    func requestReboot(for window: TabbedSessionWindow) {
        let alert = NSAlert()
        alert.messageText = String(
            format: NSLocalizedString("Reboot “%@”?", comment: ""),
            window.profile.name)
        alert.informativeText = NSLocalizedString(
            "Soft reboot runs `sudo reboot` inside the VM (graceful — filesystems flush, services stop). Hard reboot tears down the VM immediately and starts a fresh one.",
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
    private func wireSandboxCallbacks(_ sandbox: UbuntuSandboxVM,
                                      win: TabbedSessionWindow) {
        sandbox.onStopped = { [weak win, weak self] _ in
            Task { @MainActor in
                guard let win, let self else { return }
                if win.rebootRequested {
                    win.rebootRequested = false
                    self.relaunchVM(in: win)
                } else {
                    win.close()
                }
            }
        }
        sandbox.onURLOpen = { url in NSWorkspace.shared.open(url) }
        sandbox.onTabClosed = { [weak win] id in
            Task { @MainActor in win?.handleTabClosedFromGuest(id: id) }
        }
        sandbox.onTabRoster = { [weak win] alive in
            Task { @MainActor in win?.reconcileTabRoster(alive: alive) }
        }
        sandbox.onTabTitleUpdate = { [weak win] id, title in
            Task { @MainActor in win?.handleTabTitleUpdate(id: id, title: title) }
        }
        sandbox.onIPUpdate = { [weak win] ip in
            Task { @MainActor in win?.model.ipAddress = ip }
        }
    }

    /// Build a fresh sandbox in `win` after the previous one stopped.
    /// Used post-reboot to replace the dead VM in place without
    /// closing/reopening the host window. Skips drift checks and the
    /// network-healer watch — both are first-launch concerns; the
    /// disk + base image version are unchanged across a reboot.
    @MainActor
    private func relaunchVM(in win: TabbedSessionWindow) {
        let profile = win.profile
        // Cancel the outgoing sandbox's outbox poller explicitly. A
        // dropped Task keeps running in Swift — without this the old
        // poller would keep racing the new one on the same shared
        // directory and removing closed-* files out from under it.
        win.sandbox?.stopPolling()
        win.vmView.virtualMachine = nil
        win.sandbox = nil
        win.keyboardBridge = nil
        win.model.tabs.removeAll()
        win.model.activeIndex = 0
        win.model.ipAddress = nil
        let firstTab = win.appendTab()

        Task { @MainActor in
            // Brief settle before reusing the per-profile shared dirs
            // (meta-share, outbox). The old VZ virtiofs daemon needs
            // a moment to release its handles after the previous VM
            // stopped; without this delay, the wipe-and-recreate in
            // prepareMetadataShare/prepareOutboxDirectory has been
            // observed to leave the new VM's first kitty wedged on
            // a black screen — the cmd-spawn-kitty file lands in a
            // directory the new agent doesn't see yet.
            try? await Task.sleep(for: .milliseconds(500))

            let sessionDisk = SessionDisk(
                profile: profile,
                store: store,
                baseDiskURL: imageManager.baseDiskURL
            )
            let salt = mitmEngine?.fakeTokenSalt ?? Data(repeating: 0, count: 32)
            let plan = profile.makeTokenPlan(salt: salt)
            sessionDisk.tokenPlan = plan
            if let engine = mitmEngine, let scriptURL = bridgeScriptURL {
                sessionDisk.mitmAssets = SessionDisk.MitmSessionAssets(
                    caCertificatePEM: engine.ca.certificatePEM,
                    bridgeScriptURL: scriptURL,
                    keyboardAgentURL: keyboardAgentURL,
                    awsCredsHelperURL: awsCredsHelperURL)
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
                win.close()
                return
            }
            if let engine = self.mitmEngine, let dev = sandbox.socketDevice {
                engine.register(socketDevice: dev, profileID: profile.id)
            }
            if let dev = sandbox.socketDevice {
                win.keyboardBridge = KeyboardBridge(
                    socketDevice: dev,
                    forcedLayout: profile.keyboardLayoutOverride)
            }
            self.wireSandboxCallbacks(sandbox, win: win)
            win.sandbox = sandbox
            self.requestSpawnKitty(id: firstTab.id, in: win)
        }
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
