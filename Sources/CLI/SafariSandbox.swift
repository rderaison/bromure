import ArgumentParser
import Cocoa
import Foundation
import SandboxEngine
import SwiftUI
@preconcurrency import Virtualization

@main
struct Bromure: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bromure",
        abstract: "Run a browser in an isolated, ephemeral VM.",
        subcommands: [Launch.self, Init.self, Run.self, Setup.self],
        defaultSubcommand: Launch.self
    )
}

// MARK: - Launch: Open the GUI app (default)

struct Launch: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open Bromure."
    )

    func run() throws {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        if osVersion.majorVersion < 14 {
            print("Error: Bromure requires macOS 14 (Sonoma) or later.")
            print("You are running macOS \(osVersion.majorVersion).\(osVersion.minorVersion).")
            throw ExitCode.failure
        }

        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)

            let state = AppState()
            let delegate = GUIAppDelegate(state: state)
            app.delegate = delegate

            app.run()
            _ = delegate
        }
    }
}

// MARK: - GUI App Delegate

final class GUIAppDelegate: NSObject, NSApplicationDelegate {
    let state: AppState
    var sessions: [BrowserSession] = []
    /// Retired sessions kept alive permanently to prevent VZ dispatch source
    /// use-after-free crashes during dealloc. These are lightweight after cleanup.
    private var retiredSessions: [BrowserSession] = []
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var eulaWindow: NSWindow?
    private var isTerminating = false
    private var pendingURL: URL?

    init(state: AppState) {
        self.state = state
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        NSApp.activate(ignoringOtherApps: true)

        state.onCloseAllSessions = { [weak self] in
            guard let self else { return }
            for session in self.sessions {
                await session.teardown()
                session.window.orderOut(nil)
            }
            self.sessions.removeAll()
            self.state.sessionCount = 0
        }

        showMainWindow()
    }

    // MARK: - URL Handling

    func application(_ application: NSApplication, open urls: [URL]) {
        print("[URL] application(open:) called with \(urls)")
        let webURLs = urls.filter { $0.scheme == "http" || $0.scheme == "https" }
        guard let url = webURLs.first else {
            print("[URL] no http/https URLs found")
            return
        }

        print("[URL] sessions=\(sessions.count), phase=\(state.phase)")
        // Prefer the frontmost (key) window session, fall back to the most recent one
        let activeSession = sessions.first(where: { !$0.closing && $0.window.isKeyWindow })
            ?? sessions.last(where: { !$0.closing })
        if let session = activeSession {
            print("[URL] sending to existing session")
            session.navigateTo(url: url)
        } else if state.phase == .ready {
            print("[URL] opening new browser with URL")
            openNewBrowser(initialURL: url)
        } else {
            print("[URL] storing as pending URL")
            pendingURL = url
            showMainWindow()
        }
    }

    // MARK: - WARP EULA

    func showWarpEULA(onAccepted: @escaping () -> Void) {
        let eulaView = WarpEULAView(
            onAccept: { [weak self] in
                UserDefaults.standard.set(true, forKey: "warpEULAAccepted")
                UserDefaults.standard.set(true, forKey: "vm.enableWarp")
                DispatchQueue.main.async {
                    self?.eulaWindow?.orderOut(nil)
                    onAccepted()
                }
            },
            onDecline: { [weak self] in
                UserDefaults.standard.set(false, forKey: "vm.enableWarp")
                DispatchQueue.main.async {
                    self?.eulaWindow?.orderOut(nil)
                }
            }
        )

        let hostingView = NSHostingView(rootView: eulaView)
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "Cloudflare WARP Terms of Service"
        window.animationBehavior = .none
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.eulaWindow = window
    }

    // MARK: - Windows

    private func showMainWindow() {
        if let mainWindow, mainWindow.isVisible {
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }

        let onNewBrowser: @MainActor () -> Void = { [weak self] in
            self?.openNewBrowser()
        }
        let onNewBrowserWithProfile: @MainActor (Profile) -> Void = { [weak self] profile in
            self?.openNewBrowser(with: profile)
        }
        let onShowWarpEULA: (@escaping () -> Void) -> Void = { [weak self] onAccepted in
            self?.showWarpEULA(onAccepted: onAccepted)
        }
        let mainView = MainView(state: state, onNewBrowser: onNewBrowser, onNewBrowserWithProfile: onNewBrowserWithProfile, onShowWarpEULA: onShowWarpEULA)

        let hostingView = NSHostingView(rootView: mainView)
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = "Bromure"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.mainWindow = window
    }

    @MainActor @objc func showSettings(_ sender: Any?) {
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }

        let settingsView = SettingsView(state: state)
        let hostingView = NSHostingView(rootView: settingsView)

        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hostingView
        window.title = "Settings"
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.settingsWindow = window
    }

    // MARK: - Menu

    private func setupMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Bromure",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Settings...",
                        action: #selector(showSettings(_:)),
                        keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit Bromure",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // File menu
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Browser",
                         action: #selector(newBrowserAction(_:)),
                         keyEquivalent: "n")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Recreate Base Image\u{2026}",
                         action: #selector(recreateBaseImageAction(_:)),
                         keyEquivalent: "")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "Close Window",
                         action: #selector(NSWindow.performClose(_:)),
                         keyEquivalent: "w")
        let fileItem = NSMenuItem()
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // View menu
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Toggle File Drawer",
                         action: #selector(toggleFileDrawerAction(_:)),
                         keyEquivalent: "d")
        let viewItem = NSMenuItem()
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        // Edit menu
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // Window menu
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Bromure",
                           action: #selector(showMainWindowAction(_:)),
                           keyEquivalent: "0")
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Actions

    @MainActor @objc func newBrowserAction(_ sender: Any?) {
        openNewBrowser()
    }

    @MainActor @objc func toggleFileDrawerAction(_ sender: Any?) {
        // Find the active browser session for the key window
        guard let keyWindow = NSApp.keyWindow,
              let session = sessions.first(where: { $0.window === keyWindow }),
              session.hasFileTransfer else { return }
        session.toggleDrawer()
    }

    @MainActor @objc func recreateBaseImageAction(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Recreate base image?"
        alert.informativeText = "This will close all browser windows, delete the current base image, and rebuild it from scratch. This may take several minutes."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Recreate")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            // Kill all running VMs first
            Task { @MainActor in
                for session in sessions {
                    await session.teardown()
                    session.window.orderOut(nil)
                }
                retiredSessions.append(contentsOf: sessions)
                sessions.removeAll()
                state.sessionCount = 0

                state.regenerateImage()
                showMainWindow()
            }
        }
    }

    @objc func showMainWindowAction(_ sender: Any?) {
        showMainWindow()
    }

    @MainActor func openNewBrowser(initialURL: URL? = nil) {
        guard state.pool != nil, state.poolReady else {
            if let url = initialURL { pendingURL = url }
            showMainWindow()
            return
        }
        let config = state.buildDefaultConfig()
        Task { @MainActor in
            guard let warm = await state.pool?.claim(config: config) else {
                if let url = initialURL { self.pendingURL = url }
                self.showMainWindow()
                return
            }
            let session = BrowserSession(warmVM: warm, config: config, initialURL: initialURL)
            session.onClosed = { [weak self] session in
                guard let self else { return }
                self.sessions.removeAll { $0 === session }
                self.state.sessionCount = self.sessions.count
                self.retiredSessions.append(session)
            }
            self.sessions.append(session)
            self.state.sessionCount = self.sessions.count
            session.show()
            if ProcessInfo.processInfo.environment["BROMURE_DEBUG"] == nil {
                self.state.pool?.scheduleWarmUp()
            }
        }
    }

    @MainActor func openNewBrowser(with profile: Profile) {
        guard state.pool != nil, state.poolReady else {
            showMainWindow()
            return
        }
        state.isLaunching = true
        state.profileManager.markUsed(id: profile.id)
        let config = state.buildConfig(for: profile)
        let vtKey = profile.settings.virusTotalEnabled ? profile.settings.virusTotalAPIKey : nil

        // For persistent profiles, ensure the disk image exists
        var profileImageDir: URL?
        var profileDiskKey: String?
        var isFirstBoot = false
        if profile.isPersistent {
            let diskURL = state.profileManager.profileDiskURL(for: profile.id)
            if !ProfileDisk.diskExists(at: diskURL) {
                isFirstBoot = true
                do {
                    try ProfileDisk.createDisk(profileID: profile.id, at: diskURL)
                    print("[Profile] Created persistent disk for '\(profile.name)' at \(diskURL.path)")
                } catch {
                    print("[Profile] Failed to create persistent disk: \(error)")
                }
            }
            if ProfileDisk.diskExists(at: diskURL) {
                profileImageDir = state.profileManager.profileImageDir(for: profile.id)
                if profile.isEncrypted {
                    profileDiskKey = try? ProfileDisk.keyForProfile(id: profile.id)
                }
            }
        }

        // Ask whether to restore previous tabs for persistent profiles with existing data
        var restoreSession = false
        if profile.isPersistent, !isFirstBoot, profileImageDir != nil {
            let alert = NSAlert()
            alert.messageText = "Restore previous tabs?"
            alert.informativeText = "This profile has data from a previous session. Would you like to restore your open tabs?"
            alert.addButton(withTitle: "Restore")
            alert.addButton(withTitle: "Start Fresh")
            alert.alertStyle = .informational
            restoreSession = alert.runModal() == .alertFirstButtonReturn
        }

        Task { @MainActor in
            guard let warm = await state.pool?.claim(
                config: config,
                profileID: profile.id,
                profileImageDir: profileImageDir,
                profileDiskKey: profileDiskKey,
                restoreSession: restoreSession
            ) else {
                self.state.isLaunching = false
                self.showMainWindow()
                return
            }
            let session = BrowserSession(
                warmVM: warm, config: config,
                profile: profile,
                virusTotalAPIKey: vtKey
            )
            session.onClosed = { [weak self] session in
                guard let self else { return }
                self.sessions.removeAll { $0 === session }
                self.state.sessionCount = self.sessions.count
                self.retiredSessions.append(session)
            }
            self.sessions.append(session)
            self.state.sessionCount = self.sessions.count
            session.show()
            self.state.isLaunching = false
            if ProcessInfo.processInfo.environment["BROMURE_DEBUG"] == nil {
                self.state.pool?.scheduleWarmUp()
            }
        }
    }

    // MARK: - App Lifecycle

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateNow }

        // If there are active sessions, confirm before quitting
        if !sessions.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Quit Bromure?"
            let count = sessions.count
            alert.informativeText = count == 1
                ? "There is 1 open browser session. All session data will be lost."
                : "There are \(count) open browser sessions. All session data will be lost."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                return .terminateCancel
            }
        }

        isTerminating = true

        // Detach VZ views synchronously while we're on the real main thread.
        // VZVirtualMachineView.setVirtualMachine requires the main dispatch queue,
        // which @MainActor Tasks don't guarantee.
        for session in sessions {
            session.detachView()
        }

        Task { @MainActor in
            for session in sessions {
                await session.teardown()
            }
            sessions.removeAll()
            await state.pool?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }
}

// MARK: - Browser Session

/// A single browser window backed by a VM.
/// This is a plain Swift class (not NSObject) to avoid VZ dispatch source
/// lifetime issues with ObjC ivar destruction.
final class BrowserSession {
    private var warmVM: VMPool.WarmVM?
    let window: NSWindow
    private var vmView: VZVirtualMachineView?
    var onClosed: ((BrowserSession) -> Void)?
    fileprivate var closing = false
    fileprivate var confirmed = false
    private static var windowCount = 0
    private var delegateHelper: SessionDelegateHelper?
    private var fileTransferBridge: FileTransferBridge?
    private var fileDrawerModel: FileDrawerModel?
    private var splitView: NSSplitView?
    private var drawerHost: NSView?
    fileprivate var hasFileTransfer = false
    private let profile: Profile?

    private var initialURL: URL?

    init(warmVM: VMPool.WarmVM, config: VMConfig, profile: Profile? = nil, initialURL: URL? = nil, virusTotalAPIKey: String? = nil) {
        self.warmVM = warmVM
        self.profile = profile
        self.initialURL = initialURL
        BrowserSession.windowCount += 1

        let vmView = VZVirtualMachineView()
        vmView.virtualMachine = warmVM.vm
        vmView.capturesSystemKeys = true
        vmView.automaticallyReconfiguresDisplay = true
        self.vmView = vmView

        let windowWidth = CGFloat(config.displayWidth) / 2
        let windowHeight = CGFloat(config.displayHeight)

        // If file transfer is enabled, set up the bridge and show drawer alongside VM
        var contentView: NSView = vmView
        if config.enableFileTransfer {
            if let socketDevices = warmVM.vm.socketDevices as? [VZVirtioSocketDevice],
               let socketDevice = socketDevices.first {
                let bridge = MainActor.assumeIsolated { FileTransferBridge(socketDevice: socketDevice) }
                let model = MainActor.assumeIsolated { FileDrawerModel(virusTotalAPIKey: virusTotalAPIKey) }
                MainActor.assumeIsolated { model.attach(bridge: bridge) }
                self.fileTransferBridge = bridge
                self.fileDrawerModel = model

                let drawerView = FileDrawerView(model: model)
                let hostView = NSHostingView(rootView: drawerView)
                hostView.setFrameSize(NSSize(width: 280, height: windowHeight))

                let split = NSSplitView()
                split.isVertical = true
                split.dividerStyle = .thin
                split.addSubview(vmView)
                split.addSubview(hostView)
                split.setHoldingPriority(.defaultLow, forSubviewAt: 0)
                split.setHoldingPriority(.defaultHigh, forSubviewAt: 1)
                self.splitView = split
                self.drawerHost = hostView
                hostView.isHidden = true
                self.hasFileTransfer = true
                contentView = split

            }
        }

        // Wrap content in a border view if profile has a color
        if let profile, let profileColor = profile.color {
            let borderColor = Self.nsColor(for: profileColor)
            let borderWidth: CGFloat = 3

            let borderView = NSView()
            borderView.wantsLayer = true
            borderView.layer?.borderColor = borderColor.cgColor
            borderView.layer?.borderWidth = borderWidth

            borderView.addSubview(contentView)
            contentView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                contentView.topAnchor.constraint(equalTo: borderView.topAnchor, constant: borderWidth),
                contentView.bottomAnchor.constraint(equalTo: borderView.bottomAnchor, constant: -borderWidth),
                contentView.leadingAnchor.constraint(equalTo: borderView.leadingAnchor, constant: borderWidth),
                contentView.trailingAnchor.constraint(equalTo: borderView.trailingAnchor, constant: -borderWidth),
            ])
            contentView = borderView
        }

        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: windowWidth,
                height: windowHeight
            ),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        if let profile {
            window.title = "Bromure \u{2014} \(profile.name)"
        } else {
            window.title = "Bromure \u{2014} Chromium"
        }

        window.contentView = contentView
        window.contentMinSize = NSSize(width: 800, height: 600)
        window.animationBehavior = .none
        self.window = window

        // Add a sidebar toggle button in the titlebar for file transfer
        if hasFileTransfer {
            let accessory = NSTitlebarAccessoryViewController()
            let button = NSButton(
                image: NSImage(systemSymbolName: "sidebar.trailing", accessibilityDescription: "Toggle File Drawer")!,
                target: nil,
                action: #selector(GUIAppDelegate.toggleFileDrawerAction(_:))
            )
            button.bezelStyle = NSButton.BezelStyle.recessed
            button.toolTip = "Toggle File Drawer (⌘D)"
            accessory.view = button
            accessory.layoutAttribute = .trailing
            window.addTitlebarAccessoryViewController(accessory)
        }

        let helper = SessionDelegateHelper(session: self)
        self.delegateHelper = helper
        warmVM.vm.delegate = helper
        window.delegate = helper
    }

    private static func nsColor(for color: ProfileColor) -> NSColor {
        switch color {
        case .blue: return .systemBlue
        case .red: return .systemRed
        case .green: return .systemGreen
        case .orange: return .systemOrange
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .teal: return .systemTeal
        case .gray: return .systemGray
        }
    }

    /// Navigate to a URL in the running Chromium.
    /// Launches chromium-browser with the URL — Chromium opens it in a new tab
    /// of the already-running instance.
    func navigateTo(url: URL) {
        guard let warmVM else {
            print("[URL] navigateTo: no warmVM")
            return
        }
        let urlString = url.absoluteString
        print("[URL] navigateTo: opening \(urlString)")
        // Running chromium-browser again while an instance is already running
        // will open the URL in a new tab of the existing instance.
        let innerCmd = "DISPLAY=:0 chromium-browser " + shellEscape(urlString)
        let cmd = "su chrome -c \(shellEscape(innerCmd)) &"
        warmVM.serialInput.fileHandleForWriting.write(Data((cmd + "\n").utf8))
    }

    /// Detach the VM view and disconnect window delegate.
    /// VZVirtualMachineView and NSWindow both require the real main dispatch queue.
    fileprivate func detachView() {
        guard vmView != nil else { return }
        let work = {
            self.vmView?.virtualMachine = nil
            self.window.contentView = NSView()
            self.window.delegate = nil
            self.vmView = nil
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync { work() }
        }
    }

    /// Stop the VM, close pipes, destroy disk — in that order.
    /// VZVirtualMachine.stop() requires the real main dispatch queue (not @MainActor).
    fileprivate func fullCleanup() async {
        // 0. Sync and unmount persistent profile disk before killing the VM
        if let profile, profile.isPersistent, let input = warmVM?.serialInput.fileHandleForWriting {
            let mountPoint = "/home/chrome/.\(profile.id.uuidString)"
            let syncCmd = "sync && umount \(mountPoint) 2>/dev/null"
            if profile.isEncrypted {
                // Close LUKS volume after unmounting
                let cmd = syncCmd + " && cryptsetup close profile_data 2>/dev/null"
                input.write(Data((cmd + "\n").utf8))
            } else {
                input.write(Data((syncCmd + "\n").utf8))
            }
            // Give it a moment to flush
            try? await Task.sleep(for: .seconds(1))
        }
        // 1. Disconnect delegates so VZ doesn't call back into us
        warmVM?.vm.delegate = nil
        // 2. Stop VM on the main dispatch queue (VZ requirement)
        if let vm = warmVM?.vm, vm.state == .running || vm.state == .paused {
            nonisolated(unsafe) let vm = vm
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async {
                    vm.stop { _ in cont.resume() }
                }
            }
        }
        // 3. Now safe to close pipes — VZ no longer has active dispatch sources
        if let vm = warmVM {
            vm.serialOutput.fileHandleForReading.readabilityHandler = nil
            vm.serialInput.fileHandleForWriting.readabilityHandler = nil
            try? vm.serialOutput.fileHandleForReading.close()
            try? vm.serialOutput.fileHandleForWriting.close()
            try? vm.serialInput.fileHandleForReading.close()
            try? vm.serialInput.fileHandleForWriting.close()
            try? vm.ephemeralDisk.destroy()
        }
        // 4. Release VZ resources
        warmVM = nil
    }

    /// Toggle the file transfer drawer visibility.
    func toggleDrawer() {
        guard let drawerHost, let splitView else { return }
        if drawerHost.isHidden {
            drawerHost.isHidden = false
            var frame = window.frame
            frame.size.width += 280
            window.setFrame(frame, display: true, animate: true)
        } else {
            drawerHost.isHidden = true
            var frame = window.frame
            frame.size.width -= 280
            window.setFrame(frame, display: true, animate: true)
        }
        splitView.adjustSubviews()
    }

    var isDrawerVisible: Bool {
        drawerHost?.isHidden == false
    }

    func show() {
        window.center()
        let offset = CGFloat((BrowserSession.windowCount - 1) % 5) * 25
        if offset > 0 {
            var frame = window.frame
            frame.origin.x += offset
            frame.origin.y -= offset
            window.setFrame(frame, display: false)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Auto-open drawer when a file arrives from the guest
        if let model = fileDrawerModel {
            model.onFileFromGuest = { [weak self] in
                if let self, self.drawerHost?.isHidden == true {
                    self.toggleDrawer()
                }
            }
        }

        if let url = initialURL {
            initialURL = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.navigateTo(url: url)
            }
        }
    }

    func teardown() async {
        guard !closing else { return }
        closing = true
        await MainActor.run {
            fileDrawerModel?.detach()
            fileTransferBridge?.stop()
            fileTransferBridge = nil
            fileDrawerModel = nil
        }
        detachView()
        delegateHelper = nil
        await fullCleanup()
    }
}

/// Thin NSObject bridge for NSWindowDelegate and VZVirtualMachineDelegate.
/// Prevents VZ dispatch source lifecycle from affecting BrowserSession dealloc.
private final class SessionDelegateHelper: NSObject, VZVirtualMachineDelegate, NSWindowDelegate {
    weak var session: BrowserSession?

    init(session: BrowserSession) {
        self.session = session
    }

    // MARK: - VZVirtualMachineDelegate

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        handleVMStopped()
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        handleVMStopped()
    }

    private func handleVMStopped() {
        guard let session, !session.closing else { return }
        session.closing = true
        Task { @MainActor in
            session.detachView()
            session.window.delegate = nil
            await session.fullCleanup()
            session.window.orderOut(nil)
            session.onClosed?(session)
        }
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let session else { return true }
        if session.closing || session.confirmed { return true }
        let alert = NSAlert()
        alert.messageText = "Close this browser?"
        alert.informativeText = "All browsing data in this window will be permanently lost. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: sender) { [weak session] response in
            if response == .alertFirstButtonReturn {
                session?.confirmed = true
                session?.window.close()
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let session, !session.closing else { return }
        session.closing = true
        session.detachView()
        session.window.delegate = nil
        Task { @MainActor in
            await session.fullCleanup()
            session.onClosed?(session)
        }
    }
}

// MARK: - CLI: Init

struct Init: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Create the base image (one-time setup)."
    )

    @Option(name: .long, help: "Guest OS: 'linux' or 'macOS'.")
    var os: String = "linux"

    @Option(name: .long, help: "Disk size in GB.")
    var diskSize: UInt64?

    @Option(name: .long, help: "Custom storage directory.")
    var storageDir: String?

    func run() throws {
        let guestOS = try parseGuestOS(os)
        let dir = storageDir.map { URL(filePath: $0) } ?? VMConfig.defaultStorageDirectory
        let defaultDiskSize: UInt64 = guestOS == .linux ? 4 : 64

        switch guestOS {
        case .linux:
            try initLinux(dir: dir, diskSizeGB: diskSize ?? defaultDiskSize)
        case .macOS:
            try initMacOS(dir: dir, diskSizeGB: diskSize ?? defaultDiskSize)
        }
    }

    private func initLinux(dir: URL, diskSizeGB: UInt64) throws {
        let manager = LinuxImageManager(storageDir: dir)
        if manager.baseImageExists {
            print("Linux base image already exists.")
            return
        }

        print("=== Bromure: Linux Base Image Creation ===")
        let progress = TerminalProgress()
        var taskError: Error?
        var finished = false

        Task {
            do {
                try await manager.createBaseImage(diskSizeGB: diskSizeGB) { event in
                    progress.handle(event)
                }
            } catch { taskError = error }
            finished = true
            CFRunLoopStop(CFRunLoopGetMain())
        }

        while !finished {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        progress.finish()
        if let taskError { throw taskError }
        print("\nDone. Run 'bromure' to launch the app.")
    }

    private func initMacOS(dir: URL, diskSizeGB: UInt64) throws {
        let manager = BaseImageManager(storageDir: dir)
        if manager.baseImageExists {
            print("macOS base image already exists.")
            return
        }

        print("=== Bromure: macOS Base Image Creation ===")
        let progress = TerminalProgress()
        var taskError: Error?
        var finished = false

        Task {
            do {
                try await manager.createBaseImage(diskSizeGB: diskSizeGB) { event in
                    progress.handle(event)
                }
            } catch { taskError = error }
            finished = true
            CFRunLoopStop(CFRunLoopGetMain())
        }

        while !finished {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }
        progress.finish()
        if let taskError { throw taskError }
        print("\nDone. Run 'bromure setup' to complete macOS Setup Assistant.")
    }
}

// MARK: - CLI: Setup (macOS only)

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Boot the macOS base image interactively to complete setup."
    )

    @Option(name: .long, help: "Custom storage directory.")
    var storageDir: String?

    func run() throws {
        let dir = storageDir.map { URL(filePath: $0) } ?? VMConfig.defaultStorageDirectory
        let manager = BaseImageManager(storageDir: dir)

        guard manager.baseImageExists else {
            print("No macOS base image found. Run 'bromure init --os macOS' first.")
            throw ExitCode.failure
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let config = VMConfig()
        let vm = try manager.bootBaseImage(config: config)

        let vmView = VZVirtualMachineView()
        vmView.virtualMachine = vm
        vmView.capturesSystemKeys = true
        vmView.automaticallyReconfiguresDisplay = true

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Bromure \u{2014} Base Image Setup"
        window.contentView = vmView
        window.center()
        window.makeKeyAndOrderFront(nil)

        let delegate = SetupAppDelegate(vm: vm, window: window)
        app.delegate = delegate

        vm.start { result in
            switch result {
            case .success: break
            case .failure(let error):
                print("VM failed to start: \(error.localizedDescription)")
                NSApplication.shared.terminate(nil)
            }
        }

        app.activate(ignoringOtherApps: true)
        app.run()
        _ = delegate
    }
}

final class SetupAppDelegate: NSObject, NSApplicationDelegate, VZVirtualMachineDelegate {
    let vm: VZVirtualMachine
    let window: NSWindow

    init(vm: VZVirtualMachine, window: NSWindow) {
        self.vm = vm
        self.window = window
        super.init()
        vm.delegate = self
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
    }
}

// MARK: - CLI: Run

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Launch a browser directly (CLI mode)."
    )

    @Option(name: .long, help: "Guest OS: 'linux' or 'macOS'.")
    var os: String = "linux"

    @Option(name: .long, help: "Number of CPU cores.")
    var cpus: Int?

    @Option(name: .long, help: "Memory in GB.")
    var memory: UInt64 = 2

    @Option(name: .long, help: "Display width in pixels.")
    var width: Int = 1920

    @Option(name: .long, help: "Display height in pixels.")
    var height: Int = 1080

    @Flag(name: .long, help: "Disable audio.")
    var noAudio: Bool = false

    @Option(name: .long, help: "Custom storage directory.")
    var storageDir: String?

    func run() throws {
        let guestOS = try parseGuestOS(os)
        let dir = storageDir.map { URL(filePath: $0) } ?? VMConfig.defaultStorageDirectory
        let config = VMConfig(
            cpuCount: cpus,
            memorySize: memory * 1024 * 1024 * 1024,
            displayWidth: width,
            displayHeight: height,
            enableAudio: !noAudio
        )

        switch guestOS {
        case .linux:
            try runLinux(config: config, dir: dir)
        case .macOS:
            print("Use 'bromure launch' for macOS VMs.")
            throw ExitCode.failure
        }
    }

    private func runLinux(config: VMConfig, dir: URL) throws {
        try MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)

            let pool = VMPool(config: config, storageDir: dir)
            guard pool.baseImageExists else {
                print("No base image. Run 'bromure init' first.")
                throw ExitCode.failure
            }

            let state = AppState()
            let delegate = GUIAppDelegate(state: state)
            app.delegate = delegate

            app.run()
            _ = delegate
        }
    }
}

// MARK: - Helpers

func parseGuestOS(_ value: String) throws -> GuestOS {
    switch value.lowercased() {
    case "linux": return .linux
    case "macos": return .macOS
    default:
        print("Unknown OS '\(value)'. Use 'linux' or 'macOS'.")
        throw ExitCode.failure
    }
}
