import ArgumentParser
import Cocoa
import Foundation
import SandboxEngine
import Sparkle
import SwiftUI
@preconcurrency import Virtualization

@main
struct Bromure: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bromure",
        abstract: "Run a browser in an isolated, ephemeral VM.",
        subcommands: [Launch.self, Init.self, Run.self, Setup.self, Test.self, MCP.self, Enroll.self, Unenroll.self, ListEnrollments.self],
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
    private var diagnosticWindow: NSWindow?
    private var eulaWindow: NSWindow?
    private var consentWindow: NSWindow?
    private var enrollmentWindow: NSWindow?
    /// Sparkle auto-updater. Retained strongly — if this deallocates, scheduled
    /// update checks stop firing. Initialised in applicationDidFinishLaunching.
    private var updaterController: SPUStandardUpdaterController?
    private var isTerminating = false
    private var pendingURL: URL?
    private var automationServer: AutomationServer?
    private var icloudPasswordsBridge: ICloudPasswordsBridge?
    private var icloudPasswordsConnecting = false

    init(state: AppState) {
        self.state = state
    }

    /// Lazily connect to iCloud Passwords when first needed.
    /// Returns the bridge if connected, nil otherwise.
    @MainActor func getOrConnectICloudPasswords(window: NSWindow?) async -> ICloudPasswordsBridge? {
        if let bridge = icloudPasswordsBridge { return bridge }
        guard !icloudPasswordsConnecting else { return nil }
        guard ICloudPasswordsBridge.isAvailable else { return nil }

        icloudPasswordsConnecting = true
        let bridge = ICloudPasswordsBridge()
        let ok = await bridge.connect(window: window)
        icloudPasswordsConnecting = false

        if ok {
            icloudPasswordsBridge = bridge
            return bridge
        }
        return nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Sparkle must be started before we wire up the menu so the menu item
        // has a live target. The standard controller begins its first check
        // after SUScheduledCheckInterval; immediate checks come from the menu.
        // Silently no-op when SUPublicEDKey is not populated (dev builds) —
        // Sparkle logs the reason internally and refuses updates.
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        setupMenu()
        NSApp.activate(ignoringOtherApps: true)

        // Start watching for host network changes so bridged-mode VMs can
        // renew their DHCP lease when Wi-Fi roams or Ethernet switches.
        HostNetworkWatcher.shared.start()

        // Managed-profile sync: initial fetch on launch, periodic refresh
        // every 15 min while the app is running. No-op if not enrolled.
        state.startManagedSync()

        // Live mTLS rotation: when the sync pipeline issues a fresh leaf
        // for a managed profile, push the new cert+key+CA into every
        // open session for that profile so long-running VMs don't have
        // to restart to pick it up. Also invalidates the host-side
        // SecIdentity cache used by CloudTraceUploader so its own mTLS
        // connections to analytics.bromure.io start using the new leaf
        // on the next handshake.
        ManagedProfileSync.onProfileMTLSRenewed = { [weak self] profileId in
            Task { @MainActor in self?.handleMTLSRenewed(profileId: profileId) }
        }

        // Re-sync whenever the app becomes active (user comes back from a
        // different app or unlocks the machine).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            Task { @MainActor in self?.state.syncManagedProfiles(trigger: "activate") }
        }

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

        state.onShowEnrollment = { [weak self] in
            self?.showEnrollmentAction(nil)
        }

        // Start automation server if enabled
        startAutomationServerIfNeeded()

        // Observe automation toggle for dynamic start/stop
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let enabled = UserDefaults.standard.bool(forKey: "automation.enabled")
                if enabled && self.automationServer == nil {
                    self.startAutomationServerIfNeeded()
                } else if !enabled && self.automationServer != nil {
                    self.stopAutomationServer()
                }
            }
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

        // If the user has pinned a default profile for external links, use it
        // directly and skip the chooser. The stored value is a UUID string; if
        // it no longer matches (profile was deleted), fall through to the
        // regular flow so the chooser still appears when applicable.
        let defaultID = UserDefaults.standard.string(forKey: "links.defaultProfileID") ?? ""
        if !defaultID.isEmpty, state.phase == .ready,
           let chosen = profiles.first(where: { $0.id.uuidString == defaultID }) {
            let existingSession = sessions.first(where: { !$0.closing && $0.profile?.id == chosen.id })
            if let session = existingSession {
                print("[URL] default profile '\(chosen.name)' → existing session")
                session.navigateTo(url: url)
            } else {
                print("[URL] default profile '\(chosen.name)' → new browser")
                openNewBrowser(with: chosen, initialURL: url)
            }
            return
        }

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

        // Single profile or no profiles
        let singleProfile = profiles.count == 1 ? profiles.first : nil
        let activeSession = sessions.first(where: { !$0.closing && $0.window.isKeyWindow })
            ?? sessions.last(where: { !$0.closing })
        if let session = activeSession {
            print("[URL] sending to existing session")
            session.navigateTo(url: url)
        } else if state.phase == .ready, let profile = singleProfile {
            print("[URL] opening new browser for single profile '\(profile.name)' with URL")
            openNewBrowser(with: profile, initialURL: url)
        } else if state.phase == .ready {
            print("[URL] opening new browser with URL (no profiles)")
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

    /// Called by ManagedProfileSync after a fresh leaf cert has landed
    /// on disk + keychain for the given managed profile. Purges the
    /// host-side SecIdentity cache so the next CloudTraceUploader
    /// handshake uses the new leaf, then pushes the new material over
    /// vsock to every live session for this profile.
    @MainActor private func handleMTLSRenewed(profileId: UUID) {
        AnalyticsMTLSIdentity.purge(profileId: profileId)
        guard let material = ManagedProfileStore.shared.mtlsMaterial(profileId: profileId) else {
            return
        }
        for session in sessions where !session.closing && session.profile?.id == profileId {
            session.pushMTLSUpdate(
                certPem: material.certPem,
                keyPem: material.keyPem,
                caPem: material.caPem,
            )
        }
    }

    /// Handles a request from the corporate-guard extension to open an
    /// out-of-policy URL in a private Bromure profile. Unlike
    /// `handleOpenInProfile`, we never prompt — the whole point of the
    /// feature is silent redirection. Picks the first non-persistent
    /// profile (preferring one named "Private Browsing" if there are
    /// multiple candidates), navigates an existing session for that
    /// profile if one is open, or spawns a new one otherwise. If the
    /// user has no ephemeral profile configured we silently drop the
    /// request rather than falling back to a persistent profile —
    /// leaking external traffic into a persistent profile would defeat
    /// the purpose.
    @MainActor private func handleOpenExternalInPrivate(url: URL) {
        guard state.phase == .ready else { return }
        let profiles = state.profileManager.allProfiles
        let ephemeral = profiles.filter { !$0.settings.persistent }
        guard !ephemeral.isEmpty else { return }
        let chosen = ephemeral.first(where: { $0.name == "Private Browsing" }) ?? ephemeral[0]

        let existingSession = sessions.first(where: { !$0.closing && $0.profile?.id == chosen.id })
        if let session = existingSession {
            session.navigateTo(url: url)
        } else {
            openNewBrowser(with: chosen, initialURL: url)
        }
    }

    // MARK: - Phishing Consent

    func showPhishingConsent(onAccepted: @escaping () -> Void) {
        let serverURLString = UserDefaults.standard.string(forKey: PhishingAnalysisBridge.serverURLKey)
            ?? PhishingAnalysisBridge.defaultServerBaseURL.absoluteString
        let serverHost = URL(string: serverURLString)?.host ?? serverURLString

        let consentView = PhishingConsentView(
            serverHost: serverHost,
            onAccept: { [weak self] in
                UserDefaults.standard.set(true, forKey: "phishingConsentAccepted")
                DispatchQueue.main.async {
                    self?.consentWindow?.orderOut(nil)
                    self?.consentWindow = nil
                    onAccepted()
                }
            },
            onDecline: { [weak self] in
                DispatchQueue.main.async {
                    self?.consentWindow?.orderOut(nil)
                    self?.consentWindow = nil
                }
            }
        )

        let hostingView = NSHostingView(rootView: consentView)
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.title = NSLocalizedString("AI Phishing Detection", comment: "")
        window.animationBehavior = .none
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.consentWindow = window
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
        let onShowPhishingConsent: (@escaping () -> Void) -> Void = { [weak self] onAccepted in
            self?.showPhishingConsent(onAccepted: onAccepted)
        }
        let mainView = MainView(state: state, onNewBrowser: onNewBrowser, onNewBrowserWithProfile: onNewBrowserWithProfile, onShowWarpEULA: onShowWarpEULA, onShowPhishingConsent: onShowPhishingConsent)

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
        if let updaterController {
            let checkItem = NSMenuItem(
                title: NSLocalizedString("Check for Updates\u{2026}", comment: ""),
                action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                keyEquivalent: ""
            )
            checkItem.target = updaterController
            appMenu.addItem(checkItem)
            appMenu.addItem(NSMenuItem.separator())
        }
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
        fileMenu.addItem(withTitle: NSLocalizedString("Open Trace\u{2026}", comment: ""),
                         action: #selector(openTraceFileAction(_:)),
                         keyEquivalent: "o")
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
        viewMenu.addItem(NSMenuItem.separator())
        viewMenu.addItem(withTitle: NSLocalizedString("VM Services", comment: ""),
                         action: #selector(showVsockDiagnosticAction(_:)),
                         keyEquivalent: "")
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

    @MainActor @objc func openTraceFileAction(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = NSLocalizedString("Open a saved session recording", comment: "")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url),
              let events = try? JSONDecoder().decode([TraceEvent].self, from: data) else {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Invalid Trace File", comment: "")
            alert.informativeText = NSLocalizedString("The file could not be read as a Bromure session recording.", comment: "")
            alert.alertStyle = .warning
            alert.runModal()
            return
        }

        let name = url.deletingPathExtension().lastPathComponent
        let hostnames = Array(Set(events.compactMap(\.hostname))).sorted()
        let traceView = TraceView(events: events, sessionName: name, availableHostnames: hostnames)
        let hostView = NSHostingView(rootView: traceView)
        hostView.setFrameSize(NSSize(width: 1200, height: 700))

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Session Recording \u{2014} \(name)"
        win.contentView = hostView
        win.contentMinSize = NSSize(width: 800, height: 400)
        win.animationBehavior = .none
        win.center()
        win.makeKeyAndOrderFront(nil)
        win.isReleasedWhenClosed = false
    }

    @MainActor @objc func toggleTraceRecordingAction(_ sender: Any?) {
        guard let keyWindow = NSApp.keyWindow,
              let session = sessions.first(where: { $0.window === keyWindow }) else { return }
        session.toggleTraceRecording()
    }

    @MainActor @objc func showTraceAction(_ sender: Any?) {
        guard let keyWindow = NSApp.keyWindow,
              let session = sessions.first(where: { $0.window === keyWindow }),
              session.traceBridge != nil else { return }
        session.showTraceViewer()
    }

    @MainActor @objc func toggleWebcamEffectsAction(_ sender: Any?) {
        guard let keyWindow = NSApp.keyWindow,
              let session = sessions.first(where: { $0.window === keyWindow }),
              session.hasWebcam else { return }
        session.showEffectsPanel()
    }

    @MainActor @objc func showEnrollmentAction(_ sender: Any?) {
        if let win = enrollmentWindow, win.isVisible {
            win.makeKeyAndOrderFront(nil)
            return
        }
        let view = EnrollmentView(state: state) { [weak self] in
            self?.enrollmentWindow?.close()
            self?.enrollmentWindow = nil
        }
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false,
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.title = NSLocalizedString("Enroll in Enterprise Management",
                                         comment: "Enrollment window title bar")
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.enrollmentWindow = window
    }

    @MainActor @objc func showVsockDiagnosticAction(_ sender: Any?) {
        if let existing = diagnosticWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let view = VsockDiagnosticView { [weak self] in
            self?.sessions.map { $0.vsockDiagnostic() } ?? []
        }
        let host = NSHostingView(rootView: view)
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = NSLocalizedString("VM Services", comment: "")
        win.isReleasedWhenClosed = false
        win.contentView = host
        win.center()
        win.makeKeyAndOrderFront(nil)
        diagnosticWindow = win
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

    @MainActor private func showSessionError() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Cannot open browser", comment: "")
        alert.informativeText = NSLocalizedString("Too many browser sessions are open. Close some windows and try again.", comment: "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.runModal()
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
                self.showSessionError()
                return
            }
            let networkReady = warm.networkReady
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
            session.onOpenExternalInPrivate = { [weak self] url in
                self?.handleOpenExternalInPrivate(url: url)
            }
            self.sessions.append(session)
            self.state.sessionCount = self.sessions.count
            session.show()
            if !networkReady {
                Self.showNetworkWarning()
            }
            if ProcessInfo.processInfo.environment["BROMURE_DEBUG"] == nil {
                self.state.pool?.scheduleWarmUp()
            }
        }
    }

    @MainActor func openNewBrowser(with profile: Profile, initialURL: URL? = nil) {
        // Re-fetch the profile from the manager to pick up any settings changes
        // that occurred between the UI capture and now (e.g. settings panel save).
        let profile = state.profileManager.profile(withID: profile.id) ?? profile

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
        var config = state.buildConfig(for: profile)
        // Override homepage so xinitrc launches Chromium with the URL using
        // all proper flags, instead of a bare navigateTo after the fact.
        if let initialURL { config.homePage = initialURL.absoluteString }
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
                self.showSessionError()
                return
            }
            let networkReady = warm.networkReady
            let session = BrowserSession(
                warmVM: warm, config: config,
                profile: profile,
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
            session.onOpenExternalInPrivate = { [weak self] url in
                self?.handleOpenExternalInPrivate(url: url)
            }
            self.sessions.append(session)
            self.state.sessionCount = self.sessions.count
            session.show()
            self.state.isLaunching = false
            if !networkReady {
                Self.showNetworkWarning()
            }
            if ProcessInfo.processInfo.environment["BROMURE_DEBUG"] == nil {
                self.state.pool?.scheduleWarmUp()
            }
        }
    }

    // MARK: - Network Warning

    private static func showNetworkWarning() {
        let defaults = UserDefaults.standard
        let networkMode = defaults.string(forKey: "vm.networkMode") ?? "nat"
        if networkMode == "bridged" { return }

        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Network Issue", comment: "")
        alert.informativeText = NSLocalizedString(
            "The VM could not obtain an IP address via DHCP. "
            + "Browsing will not work in this session.\n\n"
            + "Try switching to Bridge mode in Settings → Network for more reliable connectivity.",
            comment: ""
        )
        alert.alertStyle = .warning
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.runModal()
    }

    // MARK: - Automation

    @MainActor func startAutomationServerIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "automation.enabled") else { return }

        // Stop existing server to avoid bind conflicts on restart
        if automationServer != nil {
            stopAutomationServer()
        }

        let port = UInt16(defaults.integer(forKey: "automation.port"))
        let bindAddr = defaults.string(forKey: "automation.bindAddress") ?? "127.0.0.1"
        let server = AutomationServer(port: port > 0 ? port : 9222, bindAddress: bindAddr)

        server.onListSessions = { [weak self] in
            guard let self else { return [] }
            return self.sessions.compactMap { session in
                guard !session.closing, session.cdpBridge != nil else { return nil }
                return AutomationSessionInfo(
                    id: session.id.uuidString,
                    profileName: session.profile?.name ?? "Anonymous",
                    profileID: session.profile?.id.uuidString,
                    cdpURL: "ws://\(server.bindAddress):\(server.port)/cdp/\(session.id.uuidString)"
                )
            }
        }

        server.onListProfiles = { [weak self] in
            guard let self else { return [] }
            return self.state.profileManager.allProfiles
                .filter { $0.settings.allowAutomation }
                .map { p in
                    AutomationProfileInfo(
                        id: p.id.uuidString,
                        name: p.name,
                        isPersistent: p.isPersistent,
                        color: p.color?.rawValue
                    )
                }
        }

        server.onCreateSession = { [weak self] profileName, profileID, url, restore in
            guard let self else { return nil }
            return await self.automationCreateSession(profileName: profileName, profileID: profileID, url: url, restore: restore)
        }

        server.onDestroySession = { [weak self] sessionID in
            guard let self else { return false }
            return await self.automationDestroySession(id: sessionID)
        }

        server.onGetCDPConnection = { [weak self] sessionID in
            guard let self else { return nil }
            guard let session = self.sessions.first(where: { $0.id.uuidString == sessionID }) else { return nil }
            // Resume BEFORE dequeue: if the VM is suspended the guest cdp-agent
            // can't refill the connection pool, so the dequeue would return nil
            // and we'd never wake anyone up. Always kick the VM awake when
            // the automation API asks for a connection.
            let autoSuspend = session.autoSuspend
            autoSuspend?.resumeForAPIRequest()
            guard let conn = session.cdpBridge?.dequeueConnection() else { return nil }
            return CDPProxyConnection(
                fd: conn.fileDescriptor,
                conn: conn,
                onClientActivity: { [weak autoSuspend] in
                    Task { @MainActor in autoSuspend?.resumeForAPIRequest() }
                }
            )
        }

        server.onGetShellConnection = { [weak self] sessionID in
            guard let self else { return nil }
            guard let session = self.sessions.first(where: { $0.id.uuidString == sessionID }) else { return nil }
            let autoSuspend = session.autoSuspend
            autoSuspend?.resumeForAPIRequest()
            guard let conn = session.shellBridge?.dequeueConnection() else { return nil }
            return ShellProxyConnection(
                fd: conn.fileDescriptor,
                conn: conn,
                onClientActivity: { [weak autoSuspend] in
                    Task { @MainActor in autoSuspend?.resumeForAPIRequest() }
                }
            )
        }

        server.onGetTrace = { [weak self] sessionID, filters in
            guard let self else { return [] }
            guard let session = self.sessions.first(where: { $0.id.uuidString == sessionID }),
                  let bridge = session.traceBridge else { return [] }

            // Build a TraceFilter from query parameters
            var filter = TraceFilter.all
            if let h = filters["hostname"] { filter.hostnames = [h] }
            if let m = filters["method"] { filter.methods = [m.uppercased()] }
            if let u = filters["url"] { filter.searchText = u }
            if let b = filters["body"] { filter.bodyContent = b }
            if let tf = filters["timeFrom"], let v = Double(tf) {
                let base = bridge.store.queryEvents(filter: .all).first?.timestamp ?? 0
                filter.timeStart = base + v
            }
            if let tt = filters["timeTo"], let v = Double(tt) {
                let base = bridge.store.queryEvents(filter: .all).first?.timestamp ?? 0
                filter.timeEnd = base + v
            }
            if let tab = filters["tabId"], let v = Int(tab) { filter.tabId = v }
            if let s = filters["status"] {
                if s.hasSuffix("xx"), let digit = Int(String(s.first ?? "0")) {
                    filter.statusCategories = [digit]
                }
            }

            let events = bridge.store.queryEvents(filter: filter)
            return events.map { event -> [String: Any] in
                var d: [String: Any] = [
                    "id": event.id,
                    "timestamp": event.timestamp,
                    "method": event.method,
                    "url": event.url,
                ]
                if let h = event.hostname { d["hostname"] = h }
                if let sc = event.statusCode { d["statusCode"] = sc }
                if let dur = event.duration { d["duration"] = dur }
                if let mt = event.mimeType { d["mimeType"] = mt }
                if let rh = event.requestHeaders { d["requestHeaders"] = rh }
                if let rsp = event.responseHeaders { d["responseHeaders"] = rsp }
                if let pd = event.postData { d["postData"] = pd }
                if let rb = event.responseBody { d["responseBody"] = String(rb.prefix(10000)) }
                if let err = event.errorText { d["error"] = err }
                if let du = event.documentUrl { d["documentUrl"] = du }
                if let nt = event.navType { d["navType"] = nt }
                if let ff = event.formFields {
                    d["formFields"] = ff.map { ["name": $0.name, "type": $0.type, "value": $0.value] }
                }
                return d
            }
        }

        server.onGetAppState = { [weak self] in
            guard let self else { return [:] }
            let phase: String
            switch self.state.phase {
            case .checking: phase = "checking"
            case .needsSetup: phase = "needsSetup"
            case .initializing(let status, _): phase = "initializing: \(status)"
            case .warmingUp: phase = "warmingUp"
            case .ready: phase = "ready"
            case .error(let msg): phase = "error: \(msg)"
            }
            let sessions = self.sessions.compactMap { s -> [String: Any]? in
                guard !s.closing else { return nil }
                return [
                    "id": s.id.uuidString,
                    "profile": s.profile?.name ?? "Anonymous",
                    "hasCDP": s.cdpBridge != nil,
                    "hasShell": s.shellBridge != nil,
                ]
            }
            return [
                "phase": phase,
                "poolReady": self.state.poolReady,
                "sessionCount": self.state.sessionCount,
                "baseImageExists": self.state.pool?.baseImageExists ?? false,
                "sessions": sessions,
                "profiles": self.state.profileManager.allProfiles.map { ["id": $0.id.uuidString, "name": $0.name] },
                "debugEnabled": true,
            ]
        }

        server.start()
        self.automationServer = server
    }

    @MainActor func stopAutomationServer() {
        automationServer?.stop()
        automationServer = nil
    }

    @MainActor
    private func automationCreateSession(profileName: String?, profileID: String?, url: String?, restore: Bool = false) async -> AutomationSessionInfo? {
        // Find the profile
        let profile: Profile?
        if let profileID, let uuid = UUID(uuidString: profileID) {
            profile = state.profileManager.profile(withID: uuid)
        } else if let profileName {
            profile = state.profileManager.allProfiles.first { $0.name.lowercased() == profileName.lowercased() }
        } else {
            profile = nil
        }

        guard let profile else {
            print("[Automation] Profile not found: \(profileName ?? profileID ?? "nil")")
            return nil
        }

        guard profile.settings.allowAutomation else {
            print("[Automation] Profile '\(profile.name)' does not allow automation")
            return nil
        }

        guard state.pool != nil, state.poolReady else {
            print("[Automation] Pool not ready")
            return nil
        }

        // Persistent profiles can only have one session
        if profile.isPersistent,
           let existing = sessions.first(where: { $0.profile?.id == profile.id && !$0.closing }) {
            if let url, let parsed = URL(string: url) {
                existing.navigateTo(url: parsed)
            }
            if existing.cdpBridge != nil, let server = automationServer {
                return AutomationSessionInfo(
                    id: existing.id.uuidString,
                    profileName: profile.name,
                    profileID: profile.id.uuidString,
                    cdpURL: "ws://\(server.bindAddress):\(server.port)/cdp/\(existing.id.uuidString)"
                )
            }
            return nil
        }

        state.profileManager.markUsed(id: profile.id)
        var config = state.buildConfig(for: profile)
        // Force automation on regardless of profile setting
        config.enableAutomation = true
        if let url { config.homePage = url }

        // For persistent profiles, ensure disk exists
        var profileImageDir: URL?
        var profileDiskKey: String?
        if profile.isPersistent {
            let diskURL = state.profileManager.profileDiskURL(for: profile.id)
            if !ProfileDisk.diskExists(at: diskURL) {
                do {
                    try ProfileDisk.createDisk(profileID: profile.id, at: diskURL)
                } catch {
                    print("[Automation] Failed to create persistent disk: \(error)")
                }
            }
            if ProfileDisk.diskExists(at: diskURL) {
                profileImageDir = state.profileManager.profileImageDir(for: profile.id)
                if profile.isEncrypted {
                    profileDiskKey = try? ProfileDisk.keyForProfile(id: profile.id)
                }
            }
        }

        guard let warm = await state.pool?.claim(
            config: config,
            profileID: profile.id,
            profileImageDir: profileImageDir,
            profileDiskKey: profileDiskKey,
            restoreSession: restore
        ) else {
            print("[Automation] Failed to claim VM")
            return nil
        }

        let session = BrowserSession(warmVM: warm, config: config, profile: profile)
        session.onClosed = { [weak self] session in
            guard let self else { return }
            self.sessions.removeAll { $0 === session }
            self.state.sessionCount = self.sessions.count
            self.retiredSessions.append(session)
        }
        session.onOpenInProfile = { [weak self] url in
            self?.handleOpenInProfile(url: url)
        }
        session.onOpenExternalInPrivate = { [weak self] url in
            self?.handleOpenExternalInPrivate(url: url)
        }
        self.sessions.append(session)
        self.state.sessionCount = self.sessions.count
        session.show()
        // Shorter warm-up delay for automation — sessions are created/destroyed rapidly
        state.pool?.scheduleWarmUp(delay: .seconds(3))

        guard let server = automationServer else {
            print("[Automation] Session created but no automation server")
            return nil
        }

        // Return immediately — don't block on CDP readiness.
        // The client (Puppeteer, MCP server) retries the CDP connection on its own.
        // The vsock pool fills within a few seconds after Chrome starts.
        let baseURL = "ws://\(server.bindAddress):\(server.port)/cdp/\(session.id.uuidString)"

        // Try to resolve the full WS endpoint if CDP is already ready (instant for warm VMs)
        var fullWSURL = baseURL
        if let cdp = session.cdpBridge, cdp.isReady {
            fullWSURL = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    let resolved = Self.resolveBrowserWSEndpoint(cdp: cdp, baseURL: baseURL)
                    cont.resume(returning: resolved)
                }
            }
        }

        return AutomationSessionInfo(
            id: session.id.uuidString,
            profileName: profile.name,
            profileID: profile.id.uuidString,
            cdpURL: fullWSURL
        )
    }

    /// Fetch /json/version from Chromium via a vsock connection and extract
    /// the webSocketDebuggerUrl, rewriting it to go through our proxy.
    /// Runs on a background queue (blocking I/O).
    private static func resolveBrowserWSEndpoint(cdp: CDPBridge, baseURL: String) -> String {
        // Dequeue a vsock connection and send an HTTP request
        guard let conn = DispatchQueue.main.sync(execute: { cdp.dequeueConnection() }) else {
            print("[Automation] No vsock connection for /json/version")
            return baseURL
        }
        let fd = conn.fileDescriptor
        let request = "GET /json/version HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
        guard let reqData = request.data(using: .utf8) else { return baseURL }
        let sendOK = reqData.withUnsafeBytes { buf -> Bool in
            var sent = 0
            while sent < buf.count {
                let w = Darwin.write(fd, buf.baseAddress! + sent, buf.count - sent)
                if w <= 0 { return false }
                sent += w
            }
            return true
        }
        guard sendOK else { return baseURL }

        // Read response (small JSON, well under 4KB)
        var response = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        for _ in 0..<20 { // up to 20 reads, ~80KB max
            let n = Darwin.read(fd, &buf, buf.count)
            if n <= 0 { break }
            response.append(contentsOf: buf[0..<n])
            // Check if we got the full response (Connection: close means EOF)
            if n < buf.count { break }
        }
        _ = conn // keep alive until done

        // Parse: skip HTTP headers, find JSON body
        guard let str = String(data: response, encoding: .utf8),
              let bodyStart = str.range(of: "\r\n\r\n") else { return baseURL }
        let jsonStr = String(str[bodyStart.upperBound...])
        guard let jsonData = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let wsURL = json["webSocketDebuggerUrl"] as? String,
              let wsPath = URL(string: wsURL)?.path else { return baseURL }

        // Rewrite: ws://127.0.0.1:9222/devtools/browser/GUID → baseURL/devtools/browser/GUID
        return baseURL + wsPath
    }

    @MainActor
    private func automationDestroySession(id: String) async -> Bool {
        guard let session = sessions.first(where: { $0.id.uuidString == id }) else {
            return false
        }
        await session.teardown()
        session.window.orderOut(nil)
        sessions.removeAll { $0 === session }
        state.sessionCount = sessions.count
        retiredSessions.append(session)
        return true
    }

    /// Restart a session with updated profile settings.
    @MainActor func restartSession(_ session: BrowserSession, profile: Profile) async {
        // Close the old session
        await session.teardown()
        session.window.orderOut(nil)
        sessions.removeAll { $0 === session }
        retiredSessions.append(session)

        // Open a new one
        _ = await automationCreateSession(profileName: profile.name, profileID: profile.id.uuidString, url: nil)
    }

    // MARK: - App Lifecycle

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateNow }

        // Skip confirmation when quit is triggered by AppleScript or automation.
        // NSAppleEventManager indicates a scripting-initiated quit.
        let isScriptedQuit = NSAppleEventManager.shared().currentAppleEvent?.eventClass == UInt32(kCoreEventClass)
            && NSAppleEventManager.shared().currentAppleEvent?.eventID == UInt32(kAEQuitApplication)

        // If there are active sessions, confirm before quitting (unless scripted)
        if !sessions.isEmpty && !isScriptedQuit {
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
    let id = UUID()
    private var warmVM: VMPool.WarmVM?
    let window: NSWindow
    private var vmView: VZVirtualMachineView?
    var onClosed: ((BrowserSession) -> Void)?
    var onOpenInProfile: ((URL) -> Void)?
    var onOpenExternalInPrivate: ((URL) -> Void)?
    fileprivate var closing = false
    fileprivate var confirmed = false
    private static var windowCount = 0
    private var delegateHelper: SessionDelegateHelper?
    private var fileTransferBridge: FileTransferBridge?
    private var credentialBridge: CredentialBridge?
    private var fileDrawerModel: FileDrawerModel?
    private var linkSenderBridge: LinkSenderBridge?
    private var corporateGuardBridge: CorporateGuardBridge?
    private var mtlsReloadBridge: MTLSReloadBridge?
    private var filePickerBridge: FilePickerBridge?
    private var webcamBridge: WebcamBridge?
    private var phishingAnalysisBridge: PhishingAnalysisBridge?
    private var warpBridge: WarpBridge?
    private var wireGuardBridge: WireGuardBridge?
    private var ikev2Bridge: IKEv2Bridge?
    private var networkRefreshBridge: NetworkRefreshBridge?
    private(set) var cdpBridge: CDPBridge?
    private(set) var shellBridge: ShellBridge?
    private(set) var traceBridge: TraceBridge?
    private var cloudTraceUploader: CloudTraceUploader?
    fileprivate var cloudTraceEnforced: Bool = false
    private var keyboardBridge: KeyboardBridge?
    private var cjkInputBridge: CJKInputBridge?
    private var gestureBridge: GestureBridge?
    private(set) var autoSuspend: VMAutoSuspend?
    private var traceWindow: NSWindow?
    private var traceRecordButton: NSButton?
    private var managedRecordingBanner: NSTitlebarAccessoryViewController?
    private var warpButton: NSButton?
    private var warpPulseTimer: Timer?
    private var effectsPanel: NSWindow?
    private var effectsAccessory: NSTitlebarAccessoryViewController?
    private var splitView: NSSplitView?
    private var drawerHost: NSView?
    fileprivate var hasFileTransfer = false
    fileprivate var hasWebcam = false
    let profile: Profile?
    private var webcamEffects: WebcamEffects
    private var webcamDeviceID: String?

    init(warmVM: VMPool.WarmVM, config: VMConfig, profile: Profile? = nil, virusTotalAPIKey: String? = nil, blockThreats: Bool = false, blockUnscannable: Bool = false) {
        self.warmVM = warmVM
        self.profile = profile
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
        if profile?.settings.blockScreenCapture == true {
            window.sharingType = .none
        }
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

        // Credential bridge — when passkeys or passwords are enabled
        if (config.enablePasskeys || config.enablePasswords), let dev = linkSocketDevice {
            let credBridge = MainActor.assumeIsolated {
                let bridge = CredentialBridge(socketDevice: dev, window: window)
                bridge.enablePasskeys = config.enablePasskeys
                bridge.enablePasswords = config.enablePasswords
                bridge.onKillSession = { [weak self] in
                    guard let self else { return }
                    self.confirmed = true
                    self.window.close()
                }
                if config.enablePasswords {
                    bridge.onConnectICloudPasswords = { [weak self] in
                        let delegate = NSApp.delegate as? GUIAppDelegate
                        return await delegate?.getOrConnectICloudPasswords(window: self?.window)
                    }
                }
                return bridge
            }
            self.credentialBridge = credBridge
        }

        // Phishing analysis bridge — when phishing guard is enabled
        if config.phishingWarning, let dev = linkSocketDevice {
            let bridge = MainActor.assumeIsolated { PhishingAnalysisBridge(socketDevice: dev) }
            self.phishingAnalysisBridge = bridge
        }

        if config.enableLinkSender, let dev = linkSocketDevice {
            let bridge = MainActor.assumeIsolated { LinkSenderBridge(socketDevice: dev) }
            MainActor.assumeIsolated {
                bridge.onOpenInProfile = { [weak self] url in
                    self?.onOpenInProfile?(url)
                }
            }
            self.linkSenderBridge = bridge
        }

        // Corporate-guard bridge (vsock port 5310). Always stand this up
        // when we have a vsock device — the listener is idle until the
        // guest-side extension dials in, so the cost of having it
        // unconditionally present is a couple of bytes of memory.
        // That saves us from having to thread a "is this a managed
        // session with corporateGuard configured" bit all the way down
        // here from the control plane.
        if let dev = linkSocketDevice {
            let bridge = MainActor.assumeIsolated { CorporateGuardBridge(socketDevice: dev) }
            MainActor.assumeIsolated {
                bridge.onOpenExternal = { [weak self] url in
                    self?.onOpenExternalInPrivate?(url)
                }
            }
            self.corporateGuardBridge = bridge
        }

        // mTLS-reload bridge (vsock port 5320). Also unconditional — only
        // the guest-side agent knows whether to dial in, and it only
        // starts when config-agent ran install_managed_mtls. The
        // listener sits idle for non-managed sessions.
        if let dev = linkSocketDevice {
            let bridge = MainActor.assumeIsolated { MTLSReloadBridge(socketDevice: dev) }
            self.mtlsReloadBridge = bridge
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

        // Set up VPN bridge for dynamic VPN control.
        // Only created when a VPN is enabled in the profile — when disabled,
        // no button, no agent interaction, full isolation.
        if config.vpnMode != .none, let dev = linkSocketDevice {
            // VPN toggle button in the titlebar (shared by WARP and WireGuard)
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

            if config.vpnMode == .cloudflareWarp {
                // WARP bridge on vsock port 5700
                let bridge = MainActor.assumeIsolated { WarpBridge(socketDevice: dev) }
                self.warpBridge = bridge
                MainActor.assumeIsolated {
                    bridge.onStateChanged = { [weak self] state in
                        MainActor.assumeIsolated { self?.updateWarpButton(state: state) }
                    }
                }
            } else if config.vpnMode == .wireGuard {
                // WireGuard bridge on vsock port 5701
                let bridge = MainActor.assumeIsolated { WireGuardBridge(socketDevice: dev) }
                self.wireGuardBridge = bridge
                MainActor.assumeIsolated {
                    bridge.onStateChanged = { [weak self] state in
                        MainActor.assumeIsolated { self?.updateWarpButton(state: state) }
                    }
                }
            } else if config.vpnMode == .ikev2 {
                // IKEv2 bridge on vsock port 5702
                let bridge = MainActor.assumeIsolated { IKEv2Bridge(socketDevice: dev) }
                self.ikev2Bridge = bridge
                MainActor.assumeIsolated {
                    bridge.onStateChanged = { [weak self] state in
                        MainActor.assumeIsolated { self?.updateWarpButton(state: state) }
                    }
                }
            }
        }

        // Set up CDP bridge for automation (Puppeteer/Playwright access).
        if config.enableAutomation, let dev = linkSocketDevice {
            let bridge = MainActor.assumeIsolated { CDPBridge(socketDevice: dev) }
            self.cdpBridge = bridge
        }

        // Network refresh bridge (vsock port 5703) — always attached so the
        // guest agent has something to connect to. Registered with the host
        // NWPathMonitor watcher only in bridged mode, where DHCP renewal on
        // host network changes actually matters (NAT mode is handled by vmnet).
        if let dev = linkSocketDevice {
            let bridge = MainActor.assumeIsolated { NetworkRefreshBridge(socketDevice: dev) }
            self.networkRefreshBridge = bridge
            if warmVM.bootedNetworkMode != "nat" {
                MainActor.assumeIsolated {
                    HostNetworkWatcher.shared.register(bridge)
                }
            }
        }

        // Set up shell bridge for debug command execution (BROMURE_DEBUG_CLAUDE only).
        if config.enableAutomation,
           ProcessInfo.processInfo.environment["BROMURE_DEBUG_CLAUDE"] != nil,
           let dev = linkSocketDevice {
            let bridge = MainActor.assumeIsolated { ShellBridge(socketDevice: dev) }
            self.shellBridge = bridge
        }

        // On a managed profile, any non-disabled traceLevel means cloud
        // trace: the session streams to the org's analytics endpoint, can't
        // be stopped, and never writes to disk. The manifest's traceLevel
        // is the only knob — there's no separate `cloudTrace` block.
        let managed = profile.flatMap { ManagedProfileStore.shared.profile(id: $0.id) }
        let managedTraceLevel = (managed == nil) ? .disabled : (profile?.settings.traceLevel ?? .disabled)
        let enforced = managedTraceLevel != .disabled
        let cloudPolicy: CloudTracePolicy = enforced
            ? CloudTracePolicy(
                enabled: true,
                endpoint: CloudTracePolicy.defaultEndpoint,
                level: managedTraceLevel.cloudLevel,
            )
            : .disabled
        self.cloudTraceEnforced = enforced

        // Set up trace bridge for HTTP trace capture.
        if (config.traceLevel != .disabled || enforced), let dev = linkSocketDevice {
            // Enforced tracing always starts recording; user-tracing respects
            // the per-profile auto-start preference.
            let autoStart = enforced || (profile?.settings.traceAutoStart ?? true)
            let bridge = MainActor.assumeIsolated {
                // Enforced recording is upload-only: keep events in memory so
                // they can flow to the cloud uploader without ever touching
                // disk. No local SQLite file, no WAL, no shm.
                let b = TraceBridge(socketDevice: dev, inMemory: enforced)
                if !autoStart { b.isRecording = false }
                return b
            }
            self.traceBridge = bridge

            // Wire the cloud uploader before anything has a chance to publish.
            // We install a compound onNewEvent handler so the existing trace
            // viewer (which reads from `store` directly) keeps working and
            // the uploader gets the same event stream.
            if enforced,
               let mp = managed,
               let identity = InstallIdentityStore.load(installId: mp.installId) {
                let ctx = CloudTraceUploader.SessionContext(
                    sessionId: UUID().uuidString,
                    profileId: mp.id,
                    installId: mp.installId,
                    orgSlug: mp.orgSlug,
                    userEmail: identity.userEmail,
                )
                if let uploader = CloudTraceUploader(ctx: ctx, policy: cloudPolicy) {
                    self.cloudTraceUploader = uploader
                    MainActor.assumeIsolated {
                        let existing = bridge.onNewEvent
                        bridge.onNewEvent = { event in
                            existing?(event)
                            uploader.ingest(event)
                        }
                    }
                }
            }

            // Record/pause button — uses a composed image with a red dot when recording
            let recording = autoStart
            let recordBtn = NSButton(
                image: Self.traceButtonImage(recording: recording),
                target: nil,
                action: #selector(GUIAppDelegate.toggleTraceRecordingAction(_:))
            )
            recordBtn.bezelStyle = NSButton.BezelStyle.recessed
            recordBtn.contentTintColor = enforced ? .systemRed
                : (recording ? .systemRed : .secondaryLabelColor)
            if enforced {
                recordBtn.isEnabled = false
                recordBtn.toolTip = String(
                    format: NSLocalizedString(
                        "Recording is enforced by your organization (%@).",
                        comment: "Tooltip on disabled trace toggle when cloud trace is policy-enforced",
                    ),
                    managed?.orgSlug ?? "",
                )
            } else {
                recordBtn.toolTip = recording
                    ? NSLocalizedString("Recording \u{2014} click to pause",
                                        comment: "Trace record button tooltip, recording")
                    : NSLocalizedString("Paused \u{2014} click to start recording",
                                        comment: "Trace record button tooltip, paused")
            }
            self.traceRecordButton = recordBtn

            let recordAccessory = NSTitlebarAccessoryViewController()
            recordAccessory.view = recordBtn
            recordAccessory.layoutAttribute = .trailing
            window.addTitlebarAccessoryViewController(recordAccessory)

            // Policy banner (leading titlebar accessory): persistent, visible,
            // explicit about who the data is going to. Only shown when cloud
            // trace is enforced — not for opt-in local tracing.
            if enforced, let mp = managed {
                let banner = Self.makeManagedRecordingBanner(orgSlug: mp.orgSlug)
                let accessory = NSTitlebarAccessoryViewController()
                accessory.view = banner
                accessory.layoutAttribute = .leading
                window.addTitlebarAccessoryViewController(accessory)
                self.managedRecordingBanner = accessory
            }

            // View trace button — opt-in local tracing only. Policy-enforced
            // recording hides the viewer entirely (no graph, no export): the
            // data belongs to the org, not the user, and mustn't surface in
            // the session window.
            if !enforced {
                let viewBtn = NSButton(
                    image: NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Session Recording")!,
                    target: nil,
                    action: #selector(GUIAppDelegate.showTraceAction(_:))
                )
                viewBtn.bezelStyle = NSButton.BezelStyle.recessed
                viewBtn.toolTip = NSLocalizedString("View trace",
                                                    comment: "Trace viewer button tooltip")
                let viewAccessory = NSTitlebarAccessoryViewController()
                viewAccessory.view = viewBtn
                viewAccessory.layoutAttribute = .trailing
                window.addTitlebarAccessoryViewController(viewAccessory)
            }
        }

        // Set up keyboard bridge for dynamic layout matching.
        if config.matchKeyboardLayout, let dev = linkSocketDevice {
            self.keyboardBridge = MainActor.assumeIsolated { KeyboardBridge(socketDevice: dev) }
        }

        // Set up CJK input bridge for native macOS IME composition.
        if let dev = linkSocketDevice, let vmView = self.vmView {
            let bridge = MainActor.assumeIsolated { CJKInputBridge(socketDevice: dev) }
            MainActor.assumeIsolated { bridge.install(in: window, vmView: vmView) }
            self.cjkInputBridge = bridge
        }

        // Pinch-to-zoom: forward trackpad magnify gestures to Chromium as
        // synthetic Ctrl+wheel events (VZ's USB pointing device drops them).
        if let dev = linkSocketDevice {
            let bridge = MainActor.assumeIsolated { GestureBridge(socketDevice: dev) }
            self.gestureBridge = bridge
            MainActor.assumeIsolated {
                dropTarget.onMagnify = { [weak bridge] delta, guestX, guestY in
                    bridge?.sendPinchZoom(magnification: delta, guestX: guestX, guestY: guestY)
                }
            }
        }

        // Auto-suspend on idle — whether idle actually triggers a suspend is
        // decided by the user's Energy Mode setting, read live each tick so
        // the user can flip modes in Settings without restarting sessions.
        self.autoSuspend = MainActor.assumeIsolated {
            VMAutoSuspend(
                vm: warmVM.vm,
                window: window,
                networkFilter: warmVM.networkFilter,
                isMicrophoneEnabled: config.enableMicrophone,
                modeProvider: {
                    EnergyMode(storageValue: UserDefaults.standard.string(forKey: "vm.energyMode") ?? "")
                }
            )
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
            stopWarpPulse()
            button.image = NSImage(systemSymbolName: "powerplug.fill", accessibilityDescription: "VPN Connected")
            button.contentTintColor = .systemGreen
            button.alphaValue = 1.0
            button.toolTip = "VPN: Connected — click to disconnect"
        case .connecting:
            button.image = NSImage(systemSymbolName: "powerplug.fill", accessibilityDescription: "VPN Connecting")
            button.contentTintColor = .systemOrange
            startWarpPulse()
            button.toolTip = "VPN: Connecting\u{2026}"
        case .disconnected:
            stopWarpPulse()
            button.image = NSImage(systemSymbolName: "powerplug", accessibilityDescription: "VPN Disconnected")
            button.contentTintColor = .secondaryLabelColor
            button.alphaValue = 1.0
            button.toolTip = "VPN: Disconnected — click to connect"
        case .notInstalled:
            stopWarpPulse()
            button.image = NSImage(systemSymbolName: "powerplug", accessibilityDescription: "VPN Not Available")
            button.contentTintColor = .systemRed
            button.alphaValue = 1.0
            button.toolTip = "VPN: WARP not installed in this VM"
            button.isEnabled = false
        case .error(let msg):
            stopWarpPulse()
            button.image = NSImage(systemSymbolName: "powerplug", accessibilityDescription: "VPN Error")
            button.contentTintColor = .systemOrange
            button.alphaValue = 1.0
            button.toolTip = "VPN Error: \(msg)"
            // Show an alert so the user notices the error
            if let window = button.window {
                let alert = NSAlert()
                alert.messageText = "VPN Connection Failed"
                alert.informativeText = msg
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.beginSheetModal(for: window)
            }
        case .unknown:
            stopWarpPulse()
            button.image = NSImage(systemSymbolName: "powerplug", accessibilityDescription: "VPN Status")
            button.contentTintColor = .secondaryLabelColor
            button.alphaValue = 1.0
            button.toolTip = "VPN: checking\u{2026}"
        }
    }

    private func startWarpPulse() {
        guard warpPulseTimer == nil else { return }
        warpPulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self, let button = self.warpButton else { return }
            DispatchQueue.main.async {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.5
                    button.animator().alphaValue = button.alphaValue > 0.5 ? 0.3 : 1.0
                }
            }
        }
    }

    private func stopWarpPulse() {
        warpPulseTimer?.invalidate()
        warpPulseTimer = nil
    }

    /// Called by the app delegate when the VPN button is clicked.
    func toggleWarp() {
        MainActor.assumeIsolated {
            warpBridge?.toggle()
            wireGuardBridge?.toggle()
            ikev2Bridge?.toggle()
        }
    }

    /// Toggle trace recording on/off. No-op when cloud trace is enforced by
    /// managed policy — in that case the record button is disabled upstream
    /// too, but we guard here as well to stay safe against stray callers.
    func toggleTraceRecording() {
        MainActor.assumeIsolated {
            guard !cloudTraceEnforced, let bridge = traceBridge else { return }
            bridge.isRecording.toggle()
            // Update button appearance
            if let btn = traceRecordButton {
                btn.image = Self.traceButtonImage(recording: bridge.isRecording)
                btn.contentTintColor = bridge.isRecording ? .systemRed : .secondaryLabelColor
                btn.toolTip = bridge.isRecording
                    ? NSLocalizedString("Recording \u{2014} click to pause",
                                        comment: "Trace record button tooltip, recording")
                    : NSLocalizedString("Paused \u{2014} click to start recording",
                                        comment: "Trace record button tooltip, paused")
            }
        }
    }

    /// Whether trace is currently recording.
    var isTraceRecording: Bool {
        MainActor.assumeIsolated { traceBridge?.isRecording ?? false }
    }

    /// Build the leading-titlebar banner that advertises mandatory corporate
    /// recording. Red-tinted, persistent, and impossible to miss — that's the
    /// point. Click-through opens a popover explaining what's captured.
    private static func makeManagedRecordingBanner(orgSlug: String) -> NSView {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 28))
        let icon = NSImageView(image: NSImage(
            systemSymbolName: "eye.fill",
            accessibilityDescription: "Session is being recorded")!)
        icon.contentTintColor = .systemRed
        icon.imageScaling = .scaleProportionallyDown
        icon.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: String(
            format: NSLocalizedString("Recording — shared with %@",
                                      comment: "Titlebar banner text on managed recording sessions"),
            orgSlug,
        ))
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .systemRed
        label.translatesAutoresizingMaskIntoConstraints = false
        label.toolTip = NSLocalizedString(
            "Every request in this window is recorded and sent to your organization's infosec team. This is required by your administrator and cannot be turned off.",
            comment: "Titlebar banner tooltip explaining managed recording",
        )

        host.addSubview(icon)
        host.addSubview(label)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        return host
    }

    /// Build the trace button image: the base symbol with a red recording dot overlay when active.
    private static func traceButtonImage(recording: Bool) -> NSImage {
        let symbolName = recording ? "record.circle.fill" : "record.circle"
        let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Toggle Recording")!
        guard recording else { return base }

        // Composite the base symbol with a small red dot in the top-right corner
        let size = NSSize(width: 18, height: 18)
        let composed = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            let dotSize: CGFloat = 6
            let dotRect = NSRect(x: rect.maxX - dotSize - 1, y: rect.maxY - dotSize - 1,
                                 width: dotSize, height: dotSize)
            NSColor.systemRed.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        composed.isTemplate = false
        return composed
    }

    /// Show the trace viewer window.
    func showTraceViewer() {
        MainActor.assumeIsolated {
            if let existing = traceWindow, existing.isVisible {
                existing.makeKeyAndOrderFront(nil)
                return
            }
            guard let traceBridge else { return }
            let name = profile?.name ?? "Session"
            let events = traceBridge.traceEvents
            let hostnames = traceBridge.store.distinctHostnames()

            let traceView = TraceView(
                events: events,
                sessionName: name,
                availableHostnames: hostnames,
                onExport: { [weak self] in self?.exportTrace(traceBridge.traceEvents) },
                onExportDB: { [weak self] in self?.exportTraceDB() },
                onClear: { [weak traceBridge] in traceBridge?.clearTrace() },
                onShowFlowGraph: { [weak traceBridge, weak self] in
                    guard let traceBridge else { return }
                    showFlowGraphWindow(
                        events: traceBridge.traceEvents,
                        sessionName: self?.profile?.name ?? "Session"
                    )
                }
            )

            let hostView = NSHostingView(rootView: traceView)
            hostView.setFrameSize(NSSize(width: 1200, height: 700))

            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            win.title = "Session Recording \u{2014} \(name)"
            win.contentView = hostView
            win.contentMinSize = NSSize(width: 800, height: 400)
            win.animationBehavior = .none
            win.isReleasedWhenClosed = false
            win.center()
            win.makeKeyAndOrderFront(nil)
            self.traceWindow = win

            // No live-update via onNewEvent — the trace viewer reads from
            // the SQLite store on demand. Updating the SwiftUI view on every
            // event causes use-after-free crashes when the window is closed
            // while events are still arriving.
            traceBridge.onNewEvent = nil
        }
    }

    private func exportTraceDB() {
        MainActor.assumeIsolated {
            guard let traceBridge else { return }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.database]
            panel.nameFieldStringValue = "trace-\(profile?.name ?? "session").sqlite"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try? traceBridge.store.exportDatabase(to: url)
        }
    }

    private func exportTrace(_ events: [TraceEvent]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "trace-\(profile?.name ?? "session").json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? JSONEncoder().encode(events) else { return }
        try? data.write(to: url)
    }

    /// Prompt to save trace data before closing the session.
    /// Returns true if the caller should proceed with closing.
    fileprivate func promptSaveTraceIfNeeded() -> Bool {
        MainActor.assumeIsolated {
            // Policy-enforced recording has no user-facing local save path —
            // the trace is shipped to the org, not to the user's disk.
            if cloudTraceEnforced { return true }
            guard let traceBridge, !traceBridge.traceEvents.isEmpty else { return true }
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Save session recording?", comment: "")
            alert.informativeText = String(format: NSLocalizedString("This session captured %lld HTTP requests. Save the recording before closing?", comment: ""), traceBridge.traceEvents.count)
            alert.alertStyle = .informational
            alert.addButton(withTitle: NSLocalizedString("Save\u{2026}", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Discard", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                exportTrace(traceBridge.traceEvents)
                return true
            } else if response == .alertSecondButtonReturn {
                return true
            }
            return false // Cancel
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
    /// Push a freshly-issued managed-profile mTLS bundle into the guest
    /// over the MTLSReloadBridge. No-op if the session has no bridge
    /// (pre-managed-profile code paths) or the guest agent hasn't
    /// dialed in yet.
    @MainActor func pushMTLSUpdate(certPem: String, keyPem: String, caPem: String) {
        mtlsReloadBridge?.push(certPem: certPem, keyPem: keyPem, caPem: caPem)
    }

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
    /// Write a command to the VM's serial pipe. Returns false if the VM is
    /// already dead (pipe broken). Guards against the ObjC NSFileHandle exception
    /// that crashes when writing to a closed pipe.
    private func serialWrite(_ cmd: String) -> Bool {
        guard let vm = warmVM?.vm, vm.state == .running || vm.state == .paused,
              let input = warmVM?.serialInput.fileHandleForWriting else {
            print("[BrowserSession] serialWrite skipped — VM not running")
            return false
        }
        let fd = input.fileDescriptor
        let data = Array((cmd + "\n").utf8)
        let written = data.withUnsafeBufferPointer { buf -> Int in
            guard let base = buf.baseAddress else { return -1 }
            return Darwin.write(fd, base, buf.count)
        }
        if written < 0 {
            print("[BrowserSession] serialWrite failed — pipe broken")
            return false
        }
        return true
    }

    fileprivate func fullCleanup() async {
        // 0. Sync and unmount persistent profile disk before killing the VM
        if let profile, profile.isPersistent {
            let mountPoint = "/home/chrome/.\(profile.id.uuidString)"
            let syncCmd = "sync && umount \(mountPoint) 2>/dev/null"
            if profile.isEncrypted {
                let cmd = syncCmd + " && cryptsetup close profile_data 2>/dev/null"
                if serialWrite(cmd) {
                    try? await Task.sleep(for: .seconds(1))
                }
            } else {
                if serialWrite(syncCmd) {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        // 0.5. Release DHCP lease so vmnet reclaims the address promptly
        if serialWrite("doas udhcpc -R -i eth0 2>/dev/null") {
            try? await Task.sleep(for: .milliseconds(500))
        }
        // 0.6. Release MAC address back to the pool for reuse
        if let mac = warmVM?.macAddress {
            MACAddressPool.shared.release(mac)
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

    }

    func teardown() async {
        guard !closing else { return }
        closing = true
        await MainActor.run {
            fileDrawerModel?.detach()
            fileTransferBridge?.stop()
            credentialBridge?.stop()
            phishingAnalysisBridge?.stop()
            fileTransferBridge = nil
            credentialBridge = nil
            phishingAnalysisBridge = nil
            fileDrawerModel = nil
            linkSenderBridge?.stop()
            linkSenderBridge = nil
            filePickerBridge?.stop()
            filePickerBridge = nil
            warpBridge?.stop()
            warpBridge = nil
            wireGuardBridge?.stop()
            wireGuardBridge = nil
            if let nrb = networkRefreshBridge {
                HostNetworkWatcher.shared.unregister(nrb)
                nrb.stop()
            }
            networkRefreshBridge = nil
            webcamBridge?.stop()
            webcamBridge = nil
            cdpBridge?.stop()
            cdpBridge = nil
            shellBridge?.stop()
            shellBridge = nil
            traceBridge?.stop()
            traceBridge = nil
            // Flush the cloud uploader on the way out. Blocks up to 5s so
            // the last batch of events still makes it to analytics even if
            // the user slams the window shut right after a sensitive action.
            cloudTraceUploader?.close()
            cloudTraceUploader = nil
            keyboardBridge?.stop()
            keyboardBridge = nil
            cjkInputBridge?.stop()
            cjkInputBridge = nil
            autoSuspend?.stop()
            autoSuspend = nil
            traceWindow?.orderOut(nil)
            traceWindow = nil
            effectsPanel?.orderOut(nil)
            effectsPanel = nil
        }
        detachView()
        delegateHelper = nil
        await fullCleanup()
    }

    // MARK: - Vsock Diagnostics

    /// Returns the current vsock service status for this session.
    @MainActor func vsockDiagnostic() -> SessionDiagnostic {
        let name = profile?.name ?? "Ephemeral"
        var services: [VsockServiceStatus] = []

        // Config agent (port 5000) — transient during claim, not tracked here.

        services.append(VsockServiceStatus(
            id: "\(id)-filetransfer",
            name: "File Transfer",
            port: 5100,
            state: fileTransferBridge.map { $0.isConnected ? .connected : .listening } ?? .disabled
        ))

        services.append(VsockServiceStatus(
            id: "\(id)-credentials",
            name: "Credentials",
            port: 5201,
            state: credentialBridge.map { $0.isConnected ? .connected : .listening } ?? .disabled
        ))

        services.append(VsockServiceStatus(
            id: "\(id)-linksender",
            name: "Link Sender",
            port: 5300,
            state: linkSenderBridge.map { $0.isConnected ? .connected : .listening } ?? .disabled
        ))

        services.append(VsockServiceStatus(
            id: "\(id)-webcam",
            name: "Webcam",
            port: 5400,
            state: webcamBridge.map { $0.isConnected ? .connected : .listening } ?? .disabled
        ))

        services.append(VsockServiceStatus(
            id: "\(id)-keyboard",
            name: "Keyboard Layout",
            port: 5006,
            state: keyboardBridge != nil ? .connected : .disabled
        ))

        services.append(VsockServiceStatus(
            id: "\(id)-cjkinput",
            name: "CJK Input",
            port: 5007,
            state: cjkInputBridge.map { $0.isCJKActive ? .connected : .listening } ?? .disabled
        ))

        services.append(VsockServiceStatus(
            id: "\(id)-cdp",
            name: "CDP Automation",
            port: 5200,
            state: cdpBridge.map { $0.isReady ? .connected : .listening } ?? .disabled
        ))

        services.append(VsockServiceStatus(
            id: "\(id)-filepicker",
            name: "File Picker",
            port: 5600,
            state: filePickerBridge.map { $0.isConnected ? .connected : .listening } ?? .disabled
        ))

        services.append(VsockServiceStatus(
            id: "\(id)-warp",
            name: "WARP VPN",
            port: 5700,
            state: warpBridge.map { $0.isAgentConnected ? .connected : .listening } ?? .disabled
        ))

        services.append(VsockServiceStatus(
            id: "\(id)-wireguard",
            name: "WireGuard VPN",
            port: 5701,
            state: wireGuardBridge.map { $0.isAgentConnected ? .connected : .listening } ?? .disabled
        ))

        services.append(VsockServiceStatus(
            id: "\(id)-shell",
            name: "Shell",
            port: 5800,
            state: shellBridge.map { $0.isReady ? .connected : .listening } ?? .disabled
        ))

        services.append(VsockServiceStatus(
            id: "\(id)-trace",
            name: "HTTP Trace",
            port: 5900,
            state: traceBridge.map { $0.isConnected ? .connected : .listening } ?? .disabled
        ))

        services.append(VsockServiceStatus(
            id: "\(id)-netrefresh",
            name: "Network Refresh",
            port: 5703,
            state: networkRefreshBridge.map { $0.isAgentConnected ? .connected : .listening } ?? .disabled
        ))

        services.append(VsockServiceStatus(
            id: "\(id)-phishing",
            name: "Phishing Analysis",
            port: 5950,
            state: phishingAnalysisBridge.map { $0.isConnected ? .connected : .listening } ?? .disabled
        ))

        return SessionDiagnostic(id: id, name: name, services: services)
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
        Task { @MainActor [weak session] in
            guard let session, !session.closing else { return }
            session.closing = true
            session.window.orderOut(nil)
            session.detachView()
            session.window.delegate = nil
            await session.fullCleanup()
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
            guard response == .alertFirstButtonReturn, let session else { return }
            // If trace has data, offer to save before closing
            if session.promptSaveTraceIfNeeded() {
                session.confirmed = true
                session.window.close()
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard let session, !session.closing else { return }
        session.closing = true
        // Hide immediately so the user doesn't see a blank window during cleanup.
        session.window.orderOut(nil)
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
        let defaultDiskSize: UInt64 = guestOS == .linux ? 4608 : 64 * 1024

        switch guestOS {
        case .linux:
            try initLinux(dir: dir, diskSizeMB: diskSize.map { $0 * 1024 } ?? defaultDiskSize)
        case .macOS:
            try initMacOS(dir: dir, diskSizeMB: diskSize.map { $0 * 1024 } ?? defaultDiskSize)
        }
    }

    private func initLinux(dir: URL, diskSizeMB: UInt64) throws {
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
                try await manager.createBaseImage(diskSizeMB: diskSizeMB) { event in
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

    private func initMacOS(dir: URL, diskSizeMB: UInt64) throws {
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
                try await manager.createBaseImage(diskSizeMB: diskSizeMB) { event in
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
    /// Fires on each trackpad pinch tick. `magnification` is the per-event
    /// delta (positive = pinch-out = zoom in), coords are guest display-space.
    var onMagnify: ((Double, Int, Int) -> Void)?

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

        // Pinch-to-zoom: VZ's USB pointing device has no gesture channel, so
        // catch pinches here and forward each tick via GestureBridge. The
        // recognizer lives on the parent (rather than the VZ view) because
        // gesture recognizers on an NSView receive events from any subview.
        let magnify = NSMagnificationGestureRecognizer(target: self, action: #selector(handleMagnify(_:)))
        addGestureRecognizer(magnify)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func guestCoordinates(for point: NSPoint) -> (Int, Int) {
        let guestX = Int(point.x * CGFloat(displayWidth) / bounds.width)
        let guestY = Int((bounds.height - point.y) * CGFloat(displayHeight) / bounds.height)
        return (guestX, guestY)
    }

    private func guestCoordinates(from sender: NSDraggingInfo) -> (Int, Int) {
        guestCoordinates(for: convert(sender.draggingLocation, from: nil))
    }

    @objc private func handleMagnify(_ recognizer: NSMagnificationGestureRecognizer) {
        switch recognizer.state {
        case .began:
            recognizer.magnification = 0
        case .changed:
            let delta = Double(recognizer.magnification)
            // Reset so the next .changed reads as a pure delta, not cumulative.
            recognizer.magnification = 0
            guard abs(delta) > 0.0001 else { return }
            let (gx, gy) = guestCoordinates(for: recognizer.location(in: self))
            onMagnify?(delta, gx, gy)
        default:
            break
        }
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
