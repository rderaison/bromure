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
        subcommands: [Launch.self, Init.self, Run.self, Setup.self, Test.self],
        defaultSubcommand: Launch.self
    )

    /// Strip Apple-internal flags (e.g. -AppleLanguages, -AppleLocale) from
    /// CommandLine.arguments so ArgumentParser doesn't reject them.
    /// This lets `bromure -AppleLanguages "(fr)"` work for locale testing.
    static func main() {
        // Strip Apple-internal flags (e.g. -AppleLanguages, -AppleLocale) so
        // ArgumentParser doesn't reject them. Lets `bromure -AppleLanguages "(fr)"` work.
        let args = Array(CommandLine.arguments.dropFirst()) // drop argv[0]
        var filtered: [String] = []
        var skipNext = false
        for arg in args {
            if skipNext { skipNext = false; continue }
            if arg.hasPrefix("-Apple") { skipNext = true; continue }
            filtered.append(arg)
        }
        Self.main(filtered)
    }
}

// MARK: - Launch: Open the GUI app (default)

struct Launch: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Open Bromure."
    )

    func run() throws {
        // Copy localization .lproj directories from the SPM module bundle into
        // the main app bundle's Resources so SwiftUI's Text() can find them.
        // In release builds, build.sh handles this; this covers debug builds.
        Self.installLocalizations()

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

    /// SPM resource bundle, checking Contents/Resources/ for app bundles.
    /// SPM's auto-generated accessor checks Bundle.main.bundleURL (the .app root),
    /// but codesign requires resources in Contents/Resources/.
    private static let resourceBundle: Bundle = {
        let bundleName = "bromure_bromure"
        if let resourceURL = Bundle.main.resourceURL,
           let bundle = Bundle(url: resourceURL.appendingPathComponent("\(bundleName).bundle")) {
            return bundle
        }
        return Bundle.module
    }()

    /// Copy .lproj directories from SPM's Bundle.module into Bundle.main's
    /// Resources directory so SwiftUI's Text() localization works.
    /// In release builds build.sh does this at build time; this handles debug.
    private static func installLocalizations() {
        let moduleBundle = Self.resourceBundle
        guard let mainResources = Bundle.main.resourceURL else { return }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: moduleBundle.bundleURL,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in contents where url.pathExtension == "lproj" {
            let dest = mainResources.appendingPathComponent(url.lastPathComponent)
            if !fm.fileExists(atPath: dest.path) {
                try? fm.copyItem(at: url, to: dest)
            }
        }
    }
}

// MARK: - GUI App Delegate

final class GUIAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
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

        state.onPoolReady = { [weak self] in
            guard let self, let url = self.pendingURL else { return }
            self.pendingURL = nil
            // Re-enter the normal URL handling flow now that the pool is ready
            self.application(NSApp, open: [url])
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

        let profiles = state.profileManager.allProfiles

        // If there's more than one profile, ask the user which one to use.
        // If there's a running session for the chosen profile, route the URL
        // to it; otherwise spin up a new VM.
        if profiles.count > 1, state.phase == .ready {
            guard let chosen = promptProfileForURL(url, profiles: profiles) else {
                print("[URL] user cancelled profile picker")
                return
            }
            // Prefer an active session that already uses this profile
            let existingSession = sessions.first(where: { !$0.closing && $0.profile?.id == chosen.id })
            if let session = existingSession {
                print("[URL] sending to existing session for profile '\(chosen.name)'")
                session.navigateTo(url: url)
            } else {
                print("[URL] opening new browser for profile '\(chosen.name)' with URL")
                openNewBrowser(with: chosen, initialURL: url)
            }
            return
        }

        // Single profile or no profiles — use original behaviour
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

    // MARK: - Profile Picker for URL

    /// Shows a modal dialog asking which profile to use when opening a URL.
    /// Returns the chosen profile, or nil if the user cancels.
    private func promptProfileForURL(_ url: URL, profiles: [Profile]) -> Profile? {
        let urlString = url.absoluteString
        let truncatedURL = urlString.count > 60
            ? String(urlString.prefix(57)) + "..."
            : urlString

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Choose a profile", comment: "")
        alert.informativeText = String(format: NSLocalizedString("Which profile should open %@?", comment: ""), truncatedURL)
        alert.addButton(withTitle: NSLocalizedString("Open", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        alert.alertStyle = .informational

        let containerWidth: CGFloat = 400

        // Profile picker popup
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: containerWidth, height: 25), pullsDown: false)
        for profile in profiles {
            let colorDot = profile.color.map { Self.colorDot(for: $0) } ?? ""
            popup.addItem(withTitle: "\(colorDot)\(profile.name)")
        }

        // Full URL label (small, grey, multiline).
        // URLs have no natural word-break points, so insert zero-width spaces
        // after slashes, dots, hyphens, and query/fragment delimiters to let
        // NSTextField wrap at those positions.
        let breakableURL = urlString.flatMap { c -> [Character] in
            if "/.-?&=#".contains(c) { return [c, "\u{200B}"] }
            return [c]
        }
        // Measure how tall the URL text will be
        let urlFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let urlAttr = NSAttributedString(string: String(breakableURL), attributes: [.font: urlFont])
        let measuredHeight = urlAttr.boundingRect(
            with: NSSize(width: containerWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height

        let lineHeight = urlFont.boundingRectForFont.height
        let maxURLHeight = ceil(lineHeight * 10)
        let urlHeight = min(ceil(measuredHeight) + 4, maxURLHeight)

        // Use a scrollable text view for the URL so NSAlert respects the height
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: urlHeight))
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: urlHeight))
        textView.string = String(breakableURL)
        textView.font = urlFont
        textView.textColor = .secondaryLabelColor
        textView.isEditable = false
        textView.isSelectable = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = measuredHeight > maxURLHeight
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        // Container with explicit frame-based layout
        let totalHeight = popup.frame.height + 8 + urlHeight
        let container = NSView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: totalHeight))

        scrollView.frame.origin = .zero
        popup.frame.origin = NSPoint(x: 0, y: urlHeight + 8)

        container.addSubview(popup)
        container.addSubview(scrollView)

        alert.accessoryView = container
        // Force the alert to lay out with the accessory view's size
        alert.layout()

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let index = popup.indexOfSelectedItem
        guard index >= 0, index < profiles.count else { return nil }
        return profiles[index]
    }

    /// Returns a colored circle character for a profile color.
    private static func colorDot(for color: ProfileColor) -> String {
        switch color {
        case .blue:   return "🔵 "
        case .red:    return "🔴 "
        case .green:  return "🟢 "
        case .orange: return "🟠 "
        case .purple: return "🟣 "
        case .pink:   return "🩷 "
        case .teal:   return "🩵 "
        case .gray:   return "⚪ "
        }
    }

    // MARK: - Cross-Profile URL Opening

    /// Handles a request from a guest VM to open a URL in a different profile.
    @MainActor private func handleOpenInProfile(url: URL) {
        let profiles = state.profileManager.allProfiles
        guard !profiles.isEmpty, state.phase == .ready else { return }

        if profiles.count == 1 {
            // Only one profile — open directly if there's no session for it yet
            let profile = profiles[0]
            let existingSession = sessions.first(where: { !$0.closing && $0.profile?.id == profile.id })
            if let session = existingSession {
                session.navigateTo(url: url)
            } else {
                openNewBrowser(with: profile, initialURL: url)
            }
            return
        }

        guard let chosen = promptProfileForURL(url, profiles: profiles) else { return }
        let existingSession = sessions.first(where: { !$0.closing && $0.profile?.id == chosen.id })
        if let session = existingSession {
            session.navigateTo(url: url)
        } else {
            openNewBrowser(with: chosen, initialURL: url)
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
        window.title = NSLocalizedString("Cloudflare WARP Terms of Service", comment: "")
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

        window.isReleasedWhenClosed = false
        window.delegate = self
        self.mainWindow = window
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === mainWindow {
            mainWindow = nil
        }
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
        window.title = NSLocalizedString("Settings", comment: "")
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.settingsWindow = window
    }

    // MARK: - Menu

    private func setupMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: NSLocalizedString("About Bromure", comment: ""),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: NSLocalizedString("Settings...", comment: ""),
                        action: #selector(showSettings(_:)),
                        keyEquivalent: ",")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: NSLocalizedString("Quit Bromure", comment: ""),
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // File menu
        let fileMenu = NSMenu(title: NSLocalizedString("File", comment: ""))
        fileMenu.addItem(withTitle: NSLocalizedString("New Browser", comment: ""),
                         action: #selector(newBrowserAction(_:)),
                         keyEquivalent: "n")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: NSLocalizedString("Recreate Base Image\u{2026}", comment: ""),
                         action: #selector(recreateBaseImageAction(_:)),
                         keyEquivalent: "")
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: NSLocalizedString("Close Window", comment: ""),
                         action: #selector(NSWindow.performClose(_:)),
                         keyEquivalent: "w")
        let fileItem = NSMenuItem()
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // View menu
        let viewMenu = NSMenu(title: NSLocalizedString("View", comment: ""))
        viewMenu.addItem(withTitle: NSLocalizedString("Toggle File Drawer", comment: ""),
                         action: #selector(toggleFileDrawerAction(_:)),
                         keyEquivalent: "d")
        let viewItem = NSMenuItem()
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        // Edit menu
        let editMenu = NSMenu(title: NSLocalizedString("Edit", comment: ""))
        editMenu.addItem(withTitle: NSLocalizedString("Cut", comment: ""), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: NSLocalizedString("Copy", comment: ""), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: NSLocalizedString("Paste", comment: ""), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: NSLocalizedString("Select All", comment: ""), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // Window menu
        let windowMenu = NSMenu(title: NSLocalizedString("Window", comment: ""))
        windowMenu.addItem(withTitle: NSLocalizedString("Minimize", comment: ""), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: NSLocalizedString("Bromure", comment: ""),
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

    @MainActor @objc func toggleWarpAction(_ sender: Any?) {
        guard let keyWindow = NSApp.keyWindow,
              let session = sessions.first(where: { $0.window === keyWindow }) else { return }
        session.toggleWarp()
    }

    @MainActor @objc func toggleWebcamEffectsAction(_ sender: Any?) {
        guard let keyWindow = NSApp.keyWindow,
              let session = sessions.first(where: { $0.window === keyWindow }),
              session.hasWebcam else { return }
        session.showEffectsPanel()
    }

    @MainActor @objc func recreateBaseImageAction(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Recreate base image?", comment: "")
        alert.informativeText = NSLocalizedString("This will close all browser windows, delete the current base image, and rebuild it from scratch. This may take several minutes.", comment: "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Recreate", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
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
        var config = state.buildDefaultConfig()
        if let initialURL {
            config.homePage = initialURL.absoluteString
        }
        Task { @MainActor in
            guard let warm = await state.pool?.claim(config: config) else {
                if let url = initialURL { self.pendingURL = url }
                self.showMainWindow()
                return
            }
            let session = BrowserSession(warmVM: warm, config: config)
            session.onClosed = { [weak self] session in
                guard let self else { return }
                self.sessions.removeAll { $0 === session }
                self.state.sessionCount = self.sessions.count
                self.retiredSessions.append(session)
            }
            session.onOpenInProfile = { [weak self] url in
                self?.handleOpenInProfile(url: url)
            }
            self.sessions.append(session)
            self.state.sessionCount = self.sessions.count
            session.show()
            if ProcessInfo.processInfo.environment["BROMURE_DEBUG"] == nil {
                self.state.pool?.scheduleWarmUp()
            }
        }
    }

    @MainActor func openNewBrowser(with profile: Profile, initialURL: URL? = nil) {
        guard state.pool != nil, state.poolReady else {
            if let url = initialURL { pendingURL = url }
            showMainWindow()
            return
        }

        // Persistent profiles can only have one session (they can't share the filesystem).
        // If one is already running, focus its window instead of starting a new VM.
        if profile.isPersistent,
           let existing = sessions.first(where: { $0.profile?.id == profile.id && !$0.closing }) {
            existing.window.makeKeyAndOrderFront(nil)
            if existing.window.isMiniaturized { existing.window.deminiaturize(nil) }
            if let url = initialURL {
                existing.navigateTo(url: url)
            }
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
            alert.messageText = NSLocalizedString("Restore previous tabs?", comment: "")
            alert.informativeText = NSLocalizedString("This profile has data from a previous session. Would you like to restore your open tabs?", comment: "")
            alert.addButton(withTitle: NSLocalizedString("Restore", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Start Fresh", comment: ""))
            alert.alertStyle = .informational
            restoreSession = alert.runModal() == .alertFirstButtonReturn
        }

        // Switch system default audio devices before claiming VM
        // (VZHostAudioInputStreamSource/Sink use system defaults)
        if config.enableMicrophone, let micID = config.microphoneDeviceID {
            MediaDevices.setDefaultAudioInput(deviceID: micID)
        }
        if let speakerID = config.speakerDeviceID {
            MediaDevices.setDefaultAudioOutput(deviceID: speakerID)
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
                initialURL: initialURL,
                virusTotalAPIKey: vtKey,
                blockThreats: profile.settings.blockThreats,
                blockUnscannable: profile.settings.blockUnscannable
            )
            session.onClosed = { [weak self] session in
                guard let self else { return }
                self.sessions.removeAll { $0 === session }
                self.state.sessionCount = self.sessions.count
                self.retiredSessions.append(session)
            }
            session.onOpenInProfile = { [weak self] url in
                self?.handleOpenInProfile(url: url)
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
            alert.messageText = NSLocalizedString("Quit Bromure?", comment: "")
            let count = sessions.count
            alert.informativeText = count == 1
                ? NSLocalizedString("There is 1 open browser session. All session data will be lost.", comment: "")
                : String(format: NSLocalizedString("There are %lld open browser sessions. All session data will be lost.", comment: ""), count)
            alert.alertStyle = .warning
            alert.addButton(withTitle: NSLocalizedString("Quit", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
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
    var onOpenInProfile: ((URL) -> Void)?
    fileprivate var closing = false
    fileprivate var confirmed = false
    private static var windowCount = 0
    private var delegateHelper: SessionDelegateHelper?
    private var fileTransferBridge: FileTransferBridge?
    private var fileDrawerModel: FileDrawerModel?
    private var linkSenderBridge: LinkSenderBridge?
    private var filePickerBridge: FilePickerBridge?
    private var webcamBridge: WebcamBridge?
    private var warpBridge: WarpBridge?
    private var warpButton: NSButton?
    private var effectsPanel: NSWindow?
    private var effectsAccessory: NSTitlebarAccessoryViewController?
    private var splitView: NSSplitView?
    private var drawerHost: NSView?
    fileprivate var hasFileTransfer = false
    fileprivate var hasWebcam = false
    fileprivate let profile: Profile?
    private var webcamEffects: WebcamEffects
    private var webcamDeviceID: String?

    private var initialURL: URL?

    init(warmVM: VMPool.WarmVM, config: VMConfig, profile: Profile? = nil, initialURL: URL? = nil, virusTotalAPIKey: String? = nil, blockThreats: Bool = false, blockUnscannable: Bool = false) {
        self.warmVM = warmVM
        self.profile = profile
        self.initialURL = initialURL
        self.webcamEffects = config.webcamEffects
        self.webcamDeviceID = config.webcamDeviceID
        BrowserSession.windowCount += 1

        let vmView = VZVirtualMachineView()
        vmView.virtualMachine = warmVM.vm
        vmView.capturesSystemKeys = true
        vmView.automaticallyReconfiguresDisplay = true
        self.vmView = vmView

        let windowWidth = CGFloat(config.displayWidth) / 2
        let windowHeight = CGFloat(config.displayHeight)

        // Wrap vmView in a drop target that accepts file drags from macOS.
        let dropTarget = VMDropTargetView(vmView: vmView, displayWidth: config.displayWidth, displayHeight: config.displayHeight)

        // If file transfer is enabled, set up the bridge and show drawer alongside VM
        var contentView: NSView = dropTarget
        if config.enableFileTransfer {
            if let socketDevices = warmVM.vm.socketDevices as? [VZVirtioSocketDevice],
               let socketDevice = socketDevices.first {
                let bridge = MainActor.assumeIsolated { FileTransferBridge(socketDevice: socketDevice) }
                let model = MainActor.assumeIsolated { FileDrawerModel(virusTotalAPIKey: virusTotalAPIKey, blockThreats: blockThreats, blockUnscannable: blockUnscannable) }
                MainActor.assumeIsolated { model.attach(bridge: bridge) }
                self.fileTransferBridge = bridge
                self.fileDrawerModel = model

                let drawerView = FileDrawerView(model: model)
                let hostView = NSHostingView(rootView: drawerView)
                hostView.setFrameSize(NSSize(width: 280, height: windowHeight))

                let split = NSSplitView()
                split.isVertical = true
                split.dividerStyle = .thin
                split.addSubview(dropTarget)
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
            window.title = String(format: NSLocalizedString("Bromure — %@", comment: ""), profile.name)
        } else {
            window.title = NSLocalizedString("Bromure — Chromium", comment: "")
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

        // Set up link sender bridge (vsock port 5300) for cross-profile URL opening.
        // Reuse the socket device from file transfer, or grab it fresh.
        let linkSocketDevice: VZVirtioSocketDevice? = {
            if let socketDevices = warmVM.vm.socketDevices as? [VZVirtioSocketDevice] {
                return socketDevices.first
            }
            return nil
        }()
        if config.enableLinkSender, let dev = linkSocketDevice {
            let bridge = MainActor.assumeIsolated { LinkSenderBridge(socketDevice: dev) }
            MainActor.assumeIsolated {
                bridge.onOpenInProfile = { [weak self] url in
                    self?.onOpenInProfile?(url)
                }
            }
            self.linkSenderBridge = bridge
        }

        // Set up file picker bridge (vsock port 5600) for host-side file upload dialogs.
        // Uses the existing FileTransferBridge (port 5100) to send the actual file data.
        if config.enableFileTransfer, let dev = linkSocketDevice {
            let fpBridge = MainActor.assumeIsolated { FilePickerBridge(socketDevice: dev) }
            MainActor.assumeIsolated {
                fpBridge.onSendFile = { [weak self] url in
                    self?.fileTransferBridge?.sendFile(url: url)
                }
            }
            self.filePickerBridge = fpBridge

            // Wire drag hover: notify guest extension so it can highlight dropzones
            dropTarget.onDragEnter = { [weak self] guestX, guestY in
                MainActor.assumeIsolated {
                    self?.filePickerBridge?.sendDragEnter(guestX: guestX, guestY: guestY)
                }
            }
            dropTarget.onDragMove = { [weak self] guestX, guestY in
                MainActor.assumeIsolated {
                    self?.filePickerBridge?.sendDragMove(guestX: guestX, guestY: guestY)
                }
            }
            dropTarget.onDragExit = { [weak self] in
                MainActor.assumeIsolated {
                    self?.filePickerBridge?.sendDragExit()
                }
            }

            // Wire drag-and-drop: send files via port 5100, metadata via port 5600
            dropTarget.onDrop = { [weak self] urls, guestX, guestY in
                MainActor.assumeIsolated {
                    guard let self, let fpBridge = self.filePickerBridge else { return }
                    for url in urls {
                        self.fileTransferBridge?.sendFile(url: url)
                    }
                    fpBridge.sendDrop(files: urls, guestX: guestX, guestY: guestY)
                }
            }
        }

        // Set up webcam bridge (vsock port 5400) for camera sharing.
        if config.enableWebcam, let dev = linkSocketDevice {
            let bridge = MainActor.assumeIsolated { WebcamBridge(socketDevice: dev, cameraID: config.webcamDeviceID, quality: config.webcamQuality, effects: config.webcamEffects) }
            self.webcamBridge = bridge
            self.hasWebcam = true

            // Show/hide effects button when guest starts/stops using the camera
            MainActor.assumeIsolated {
                bridge.onStreamingChanged = { [weak self] streaming in
                    MainActor.assumeIsolated {
                        self?.setEffectsButtonVisible(streaming)
                    }
                }
            }
        }

        // Set up WARP bridge (vsock port 5700) for dynamic VPN control.
        // Only created when VPN is enabled in the profile — when disabled,
        // no button, no agent interaction, full isolation.
        if config.enableWarp, let dev = linkSocketDevice {
            let bridge = MainActor.assumeIsolated { WarpBridge(socketDevice: dev) }
            self.warpBridge = bridge

            // VPN toggle button in the titlebar
            let vpnButton = NSButton(
                image: NSImage(systemSymbolName: "powerplug", accessibilityDescription: "VPN Status")!,
                target: nil,
                action: #selector(GUIAppDelegate.toggleWarpAction(_:))
            )
            vpnButton.bezelStyle = NSButton.BezelStyle.recessed
            vpnButton.toolTip = "VPN: checking\u{2026}"
            vpnButton.contentTintColor = .secondaryLabelColor
            self.warpButton = vpnButton

            let vpnAccessory = NSTitlebarAccessoryViewController()
            vpnAccessory.view = vpnButton
            vpnAccessory.layoutAttribute = .trailing
            window.addTitlebarAccessoryViewController(vpnAccessory)

            // React to state changes
            MainActor.assumeIsolated {
                bridge.onStateChanged = { [weak self] state in
                    MainActor.assumeIsolated {
                        self?.updateWarpButton(state: state)
                    }
                }
            }
        }

        let helper = SessionDelegateHelper(session: self)
        self.delegateHelper = helper
        warmVM.vm.delegate = helper
        window.delegate = helper
    }

    /// Update the VPN titlebar button to reflect the current WARP state.
    private func updateWarpButton(state: WarpState) {
        guard let button = warpButton else { return }
        switch state {
        case .connected:
            button.image = NSImage(systemSymbolName: "powerplug.fill", accessibilityDescription: "VPN Connected")
            button.contentTintColor = .systemGreen
            button.toolTip = "VPN: Connected — click to disconnect"
        case .connecting:
            button.image = NSImage(systemSymbolName: "powerplug.fill", accessibilityDescription: "VPN Connecting")
            button.contentTintColor = .systemOrange
            button.toolTip = "VPN: Connecting\u{2026}"
        case .disconnected:
            button.image = NSImage(systemSymbolName: "powerplug", accessibilityDescription: "VPN Disconnected")
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = "VPN: Disconnected — click to connect"
        case .notInstalled:
            button.image = NSImage(systemSymbolName: "powerplug", accessibilityDescription: "VPN Not Available")
            button.contentTintColor = .systemRed
            button.toolTip = "VPN: WARP not installed in this VM"
            button.isEnabled = false
        case .error(let msg):
            button.image = NSImage(systemSymbolName: "powerplug", accessibilityDescription: "VPN Error")
            button.contentTintColor = .systemOrange
            button.toolTip = "VPN Error: \(msg)"
        case .unknown:
            button.image = NSImage(systemSymbolName: "powerplug", accessibilityDescription: "VPN Status")
            button.contentTintColor = .secondaryLabelColor
            button.toolTip = "VPN: checking\u{2026}"
        }
    }

    /// Called by the app delegate when the VPN button is clicked.
    func toggleWarp() {
        MainActor.assumeIsolated {
            warpBridge?.toggle()
        }
    }

    /// Add or remove the camera effects titlebar button.
    private func setEffectsButtonVisible(_ visible: Bool) {
        if visible {
            guard effectsAccessory == nil else { return }
            let button = NSButton(
                image: NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Camera Effects")!,
                target: nil,
                action: #selector(GUIAppDelegate.toggleWebcamEffectsAction(_:))
            )
            button.bezelStyle = NSButton.BezelStyle.recessed
            button.toolTip = "Camera Effects"
            let accessory = NSTitlebarAccessoryViewController()
            accessory.view = button
            accessory.layoutAttribute = .trailing
            window.addTitlebarAccessoryViewController(accessory)
            self.effectsAccessory = accessory
        } else {
            if let accessory = effectsAccessory {
                accessory.removeFromParent()
                self.effectsAccessory = nil
            }
        }
    }

    /// Show or bring forward the camera effects panel for this session.
    func showEffectsPanel() {
        // Reuse existing panel to avoid context leaks
        if let panel = effectsPanel {
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let effectsView = LiveWebcamEffectsView(
            effects: webcamEffects,
            webcamDeviceID: webcamDeviceID,
            onEffectsChanged: { [weak self] newEffects in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.webcamEffects = newEffects
                    self.webcamBridge?.updateEffects(newEffects)
                }
            },
            onDismiss: { [weak self] in
                self?.effectsPanel?.orderOut(nil)
            }
        )

        let hostView = NSHostingView(rootView: effectsView)
        hostView.setFrameSize(NSSize(width: 620, height: 680))

        // Use NSWindow (not NSPanel with .utilityWindow) so that
        // NSOpenPanel from .fileImporter can present properly.
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 680),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Camera Effects"
        win.contentView = hostView
        win.animationBehavior = .none
        win.level = .floating
        win.hidesOnDeactivate = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        self.effectsPanel = win
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
    /// Launches chromium-browser with the URL — Chromium detects the existing
    /// instance via its singleton lock and opens the URL in a new tab.
    /// For persistent profiles the --user-data-dir must match the running
    /// instance, otherwise Chromium looks in the default dir, finds no lock,
    /// and starts a separate process.
    func navigateTo(url: URL) {
        guard let warmVM else {
            print("[URL] navigateTo: no warmVM")
            return
        }
        let urlString = url.absoluteString
        print("[URL] navigateTo: opening \(urlString)")

        var chromiumArgs = shellEscape(urlString)
        if let profile, profile.isPersistent {
            let userDataDir = "/home/chrome/.\(profile.id.uuidString)"
            chromiumArgs = "--user-data-dir=\(userDataDir) " + chromiumArgs
        }

        let innerCmd = "DISPLAY=:0 chromium-browser " + chromiumArgs
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
            linkSenderBridge?.stop()
            linkSenderBridge = nil
            filePickerBridge?.stop()
            filePickerBridge = nil
            warpBridge?.stop()
            warpBridge = nil
            webcamBridge?.stop()
            webcamBridge = nil
            effectsPanel?.orderOut(nil)
            effectsPanel = nil
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
        alert.messageText = NSLocalizedString("Close this browser?", comment: "")
        alert.informativeText = NSLocalizedString("All browsing data in this window will be permanently lost. This cannot be undone.", comment: "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("Close", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
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
        if manager.hasImageFiles {
            print("Removing existing Linux base image...")
            let fm = FileManager.default
            try? fm.removeItem(at: manager.linuxDiskURL)
            try? fm.removeItem(at: manager.linuxKernelURL)
            try? fm.removeItem(at: manager.linuxInitrdURL)
            try? fm.removeItem(at: manager.imageVersionURL)
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
            print("Removing existing macOS base image...")
            let fm = FileManager.default
            try? fm.removeItem(at: VMConfig.baseImageURL(in: dir))
            try? fm.removeItem(at: VMConfig.baseAuxURL(in: dir))
            try? fm.removeItem(at: VMConfig.baseMetadataURL(in: dir))
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
        window.title = NSLocalizedString("Bromure — Base Image Setup", comment: "")
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

// MARK: - CLI: Test

struct Test: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run integration tests inside a VM."
    )

    @Option(name: .long, help: "Custom storage directory.")
    var storageDir: String?

    @Option(name: .long, help: "Test scenario: 'defaults', 'privacy', 'proxy', 'media', or 'all'.")
    var scenario: String = "all"

    @Option(name: .long, help: "Timeout in seconds for the test suite.")
    var timeout: Int = 120

    func run() throws {
        try MainActor.assumeIsolated {
            let dir = storageDir.map { URL(filePath: $0) } ?? VMConfig.defaultStorageDirectory
            let imageManager = LinuxImageManager(storageDir: dir)
            guard imageManager.baseImageExists else {
                print("No base image. Run 'bromure init' first.")
                throw ExitCode.failure
            }

            let scenarios = buildScenarios()
            var allPassed = true
            var totalPass = 0
            var totalFail = 0
            var finished = false
            var taskError: Error?

            Task {
                do {
                    for (name, config) in scenarios {
                        print("\n\u{2501}\u{2501}\u{2501} Scenario: \(name) \u{2501}\u{2501}\u{2501}")
                        let result = try await self.runScenario(name: name, config: config, storageDir: dir, timeout: self.timeout)
                        totalPass += result.pass
                        totalFail += result.fail
                        if result.fail > 0 { allPassed = false }
                    }
                } catch {
                    taskError = error
                }
                finished = true
                CFRunLoopStop(CFRunLoopGetMain())
            }

            while !finished {
                RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
            }

            if let taskError {
                print("\nTest run failed: \(taskError.localizedDescription)")
                throw ExitCode.failure
            }

            print("\n\u{2501}\u{2501}\u{2501} Results \u{2501}\u{2501}\u{2501}")
            print("Total: \(totalPass) passed, \(totalFail) failed")
            if !allPassed { throw ExitCode.failure }
        }
    }

    // MARK: - Scenario Definitions

    private func buildScenarios() -> [(String, VMConfig)] {
        // Parameter order must match VMConfig.init:
        // cpuCount, memorySize, displayWidth, displayHeight, pixelsPerInch,
        // enableAudio, audioVolume, enableWarp, forceDarkMode, enableAdBlocking,
        // swapCmdCtrl, homePage, enableGPU, enableWebGL, blockMalwareSites,
        // enableFileTransfer, phishingWarning, enableClipboardSharing, enableLinkSender,
        // enableWebcam, enableMicrophone, ..., rootCAs, ...,
        // proxyHost, proxyPort, proxyUsername, proxyPassword, blockDownloads,
        // testSuite, ..., locale
        let all: [(String, VMConfig)] = [
            ("defaults", VMConfig(
                testSuite: true
            )),
            ("dark-mode", VMConfig(
                forceDarkMode: true,
                testSuite: true
            )),
            ("gpu-off", VMConfig(
                enableGPU: false,
                enableWebGL: false,
                testSuite: true
            )),
            ("audio-off", VMConfig(
                enableAudio: false,
                testSuite: true
            )),
            ("audio-50pct", VMConfig(
                audioVolume: 50,
                testSuite: true
            )),
            ("clipboard-on", VMConfig(
                enableClipboardSharing: true,
                testSuite: true
            )),
            ("file-transfer", VMConfig(
                enableFileTransfer: true,
                blockDownloads: false,
                testSuite: true
            )),
            ("downloads-blocked", VMConfig(
                enableFileTransfer: true,
                blockDownloads: true,
                testSuite: true
            )),
            ("privacy", VMConfig(
                enableAdBlocking: true,
                blockMalwareSites: true,
                phishingWarning: true,
                testSuite: true
            )),
            ("proxy", VMConfig(
                proxyHost: "proxy.example.com",
                proxyPort: 8080,
                proxyUsername: "user",
                proxyPassword: "pass",
                testSuite: true
            )),
            ("link-sender", VMConfig(
                enableLinkSender: true,
                testSuite: true
            )),
            ("custom-cas", VMConfig(
                rootCAs: ["-----BEGIN CERTIFICATE-----\nTEST\n-----END CERTIFICATE-----"],
                testSuite: true
            )),
            ("locale-fr", VMConfig(
                homePage: "https://www.google.fr",
                testSuite: true,
                locale: "fr_FR"
            )),
        ]

        if scenario == "all" { return all }
        return all.filter { $0.0 == scenario }
    }

    // MARK: - Scenario Runner

    private struct ScenarioResult {
        let pass: Int
        let fail: Int
        let output: [String]
    }

    @MainActor
    private func runScenario(name: String, config: VMConfig, storageDir: URL, timeout: Int) async throws -> ScenarioResult {
        let pool = VMPool(config: config, storageDir: storageDir)
        guard pool.baseImageExists else {
            throw SandboxError.baseImageNotFound
        }

        // Boot VM and attach collector to the serial waiter's observer
        // BEFORE claiming, so we capture test output that arrives immediately
        let collector = TestOutputCollector()
        try await pool.warmUp()

        // Attach observer to the waiter — every chunk fed to waiter also goes to collector
        if let waiter = pool.currentWarmVM?.serialWaiter {
            waiter.observer = { text in
                collector.feed(text)
            }
        }

        guard let warm = await pool.claim(config: config) else {
            throw SandboxError.vmStartFailed("Failed to claim VM for test scenario '\(name)'")
        }

        // Wait for test suite to complete or timeout
        await warm.serialWaiter.waitFor("TEST_SUITE_DONE", timeout: TimeInterval(timeout))

        // Parse results
        let lines = collector.lines
        var passCount = 0
        var failCount = 0

        for line in lines {
            if line.hasPrefix("PASS:") {
                passCount += 1
            } else if line.hasPrefix("FAIL:") {
                failCount += 1
                print("  \u{2718} \(line)")
            } else if line.hasPrefix("TEST_SUITE_DONE:") {
                let parts = line.split(separator: ":")
                for part in parts {
                    if part.hasPrefix("pass=") {
                        passCount = Int(part.dropFirst(5)) ?? passCount
                    } else if part.hasPrefix("fail=") {
                        failCount = Int(part.dropFirst(5)) ?? failCount
                    }
                }
            }
        }

        let symbol = failCount == 0 ? "\u{2714}" : "\u{2718}"
        print("  \(symbol) \(name): \(passCount) passed, \(failCount) failed")

        // Stop the VM
        if warm.vm.state == .running {
            try? await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                DispatchQueue.main.async {
                    warm.vm.stop { error in
                        if let error { cont.resume(throwing: error) }
                        else { cont.resume() }
                    }
                }
            }
        }

        return ScenarioResult(pass: passCount, fail: failCount, output: lines)
    }
}

/// Collects PASS/FAIL/TEST_SUITE_DONE lines from serial output.
private final class TestOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    private var _lines: [String] = []

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        // Flush any remaining partial line in the buffer
        if !buffer.isEmpty {
            let line = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("PASS:") || line.hasPrefix("FAIL:") || line.hasPrefix("TEST_SUITE") {
                _lines.append(line)
            }
            buffer = ""
        }
        return _lines
    }

    func feed(_ text: String) {
        lock.lock()
        // Normalize CR+LF to LF
        buffer += text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // Extract complete lines
        while let newlineIndex = buffer.firstIndex(of: "\n") {
            let line = String(buffer[buffer.startIndex..<newlineIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("PASS:") || line.hasPrefix("FAIL:") || line.hasPrefix("TEST_SUITE") {
                _lines.append(line)
            }
            buffer = String(buffer[buffer.index(after: newlineIndex)...])
        }
        lock.unlock()
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

// MARK: - Drag-and-drop onto VM view

/// Wraps VZVirtualMachineView to accept file drags from macOS Finder.
/// Normal mouse/keyboard events pass through to VZVirtualMachineView because
/// AppKit's drag system walks up the view hierarchy when the child doesn't
/// register for dragged types.
private final class VMDropTargetView: NSView {
    private let displayWidth: Int
    private let displayHeight: Int
    var onDrop: (([URL], Int, Int) -> Void)?
    var onDragEnter: ((Int, Int) -> Void)?
    var onDragMove: ((Int, Int) -> Void)?
    var onDragExit: (() -> Void)?

    /// Throttle draggingUpdated to avoid flooding the vsock channel.
    private var lastMoveTime: CFAbsoluteTime = 0
    private static let moveThrottleInterval: CFAbsoluteTime = 0.05 // 50ms

    init(vmView: NSView, displayWidth: Int, displayHeight: Int) {
        self.displayWidth = displayWidth
        self.displayHeight = displayHeight
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])

        vmView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(vmView)
        NSLayoutConstraint.activate([
            vmView.topAnchor.constraint(equalTo: topAnchor),
            vmView.bottomAnchor.constraint(equalTo: bottomAnchor),
            vmView.leadingAnchor.constraint(equalTo: leadingAnchor),
            vmView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func guestCoordinates(from sender: NSDraggingInfo) -> (Int, Int) {
        let pt = convert(sender.draggingLocation, from: nil)
        let guestX = Int(pt.x * CGFloat(displayWidth) / bounds.width)
        let guestY = Int((bounds.height - pt.y) * CGFloat(displayHeight) / bounds.height)
        return (guestX, guestY)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let (x, y) = guestCoordinates(from: sender)
        onDragEnter?(x, y)
        lastMoveTime = CFAbsoluteTimeGetCurrent()
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastMoveTime >= Self.moveThrottleInterval {
            let (x, y) = guestCoordinates(from: sender)
            onDragMove?(x, y)
            lastMoveTime = now
        }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragExit?()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else { return false }

        let (guestX, guestY) = guestCoordinates(from: sender)
        onDrop?(urls, guestX, guestY)
        return true
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
