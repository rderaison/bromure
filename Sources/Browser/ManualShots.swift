import AppKit
import SwiftUI
import SandboxEngine
import BrowserBridges

/// `bromure __shot-ui <shot> <out.png> [light|dark]` — renders one of the
/// app's windows offscreen, title bar included, for the user manual
/// (`scripts/take-web-manual-screenshots.sh`), then exits.
///
/// Standalone: no app delegate, automation server, VMs or profile store.
/// App preferences are masked with defaults in the argument domain (never
/// written), and every profile shown is a demo built here, so nothing of
/// the user's appears and it's safe to run beside a live Bromure. Language:
/// pass `-AppleLanguages "(fr)"` like any launch.
enum ManualShots {
    static let shots: [String] =
        ["setup-welcome", "setup-progress", "setup-error", "starting", "new-profile",
         "enrollment", "phishing-consent", "warp-eula", "trace-viewer"]
        + SettingsCategory.allCases.map { "profile-\(fileName($0))" }
        + appPanes.map { "settings-\($0.file)" }

    /// App Settings panes: file-name suffix → the pane's English name.
    static let appPanes: [(file: String, pane: String)] = [
        ("general", "General"), ("hardware", "Hardware"), ("input", "Input"),
        ("display", "Display"), ("network", "Network"), ("automation", "Automation"),
        ("managed", "Managed Profile"), ("storage", "Storage"),
    ]

    static func fileName(_ c: SettingsCategory) -> String {
        switch c {
        case .general: "general"
        case .performance: "performance"
        case .media: "media"
        case .fileTransfer: "file-transfer"
        case .hostIsolation: "host-isolation"
        case .network: "network-isolation"
        case .privacy: "privacy"
        case .extensions: "extensions"
        case .vpnAds: "vpn-ads"
        case .enterprise: "enterprise"
        case .advanced: "advanced"
        }
    }

    static func run(_ args: [String]) -> Never {
        guard args.count >= 2, shots.contains(args[0]) else {
            FileHandle.standardError.write(Data(
                "usage: bromure __shot-ui <shot> <out.png> [light|dark]\nshots: \(shots.joined(separator: " "))\n".utf8))
            exit(2)
        }
        let (shot, path) = (args[0], args[1])
        let dark = args.count > 2 && args[2] == "dark"
        MainActor.assumeIsolated {
            maskPreferences()
            // First touch of NSApp: make it the always-active subclass.
            let app = ShotApplication.shared
            app.setActivationPolicy(.accessory)
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            guard let window = makeWindow(shot) else { exit(1) }
            // Key and active, so it renders the way it looks in use (live
            // traffic lights, undimmed sidebar) — offscreen, out of the way.
            window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            pump(1.5)
            exit(write(window, to: path) ? 0 : 1)
        }
        exit(1)  // unreachable: the render above always exits
    }

    // MARK: - Windows

    @MainActor
    private static func makeWindow(_ shot: String) -> NSWindow? {
        switch shot {
        case "setup-welcome", "setup-progress", "setup-error", "starting":
            let kind = ["setup-welcome": "welcome", "setup-progress": "rebuild",
                        "setup-error": "error", "starting": "starting"][shot]!
            let state = AppState(previewStorage: scratchDir())
            _ = state.applySetupPreview(kind)
            // Let the canned state settle (error/launch flip after 0.3 s)
            // before the view first lays out.
            pump(0.5)
            let host = hosting(MainView(state: state))
            host.safeAreaRegions = []
            let w = window(host, title: "Bromure", style: [.titled, .closable, .miniaturizable, .fullSizeContentView])
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            return w

        case "new-profile":
            let form = NewProfileForm(initialName: "Work", initialColor: .blue, onCreate: { _, _ in }, onCancel: {})
            return window(hosting(form),
                          title: NSLocalizedString("New Profile", comment: ""), style: [.titled, .closable])

        case "enrollment":
            let view = EnrollmentView(state: AppState(previewStorage: scratchDir()),
                                      deviceName: "MacBook Pro", onDone: {})
            return window(hosting(view),
                          title: NSLocalizedString("Enroll in Enterprise Management", comment: "Enrollment window title bar"),
                          style: [.titled, .closable])

        case "phishing-consent":
            let host = PhishingAnalysisBridge.defaultServerBaseURL.host ?? "bromure.io"
            let view = PhishingConsentView(serverHost: host, onAccept: {}, onDecline: {})
            return window(hosting(view),
                          title: NSLocalizedString("AI Phishing Detection", comment: ""), style: [.titled])

        case "warp-eula":
            let view = WarpEULAView(onAccept: {}, onDecline: {})
            return window(hosting(view),
                          title: NSLocalizedString("Cloudflare WARP Terms of Service", comment: ""), style: [.titled])

        case "trace-viewer":
            let events = demoTrace()
            let view = TraceView(events: events, sessionName: "Work",
                                 availableHostnames: Array(Set(events.compactMap(\.hostname))).sorted())
            return window(hosting(view), title: "Session Recording \u{2014} Work",
                          style: [.titled, .closable, .resizable, .miniaturizable],
                          size: NSSize(width: 1100, height: 470))

        case let s where s.hasPrefix("profile-"):
            guard let category = SettingsCategory.allCases.first(where: { "profile-\(fileName($0))" == s })
            else { return nil }
            var draft = demoProfile()
            if category == .extensions {
                // Show the pane's controls, not just its off switch.
                draft.settings.extensionsEnabled = true
                draft.settings.userExtensions = [CuratedExtensions.all[0]]
            }
            let view = ProfileSettingsView(draft: draft, profileDiskExists: false,
                                           onSave: { _ in }, onCancel: {}, initialCategory: category)
            let title = String(format: NSLocalizedString("Profile Settings \u{2014} %@", comment: ""), "Work")
            return window(hosting(view), title: title,
                          style: [.titled, .closable, .resizable], size: NSSize(width: 680, height: 560))

        case let s where s.hasPrefix("settings-"):
            guard let pane = appPanes.first(where: { "settings-\($0.file)" == s }) else { return nil }
            if pane.file == "automation" {
                // Show the server's settings and reference, not just its off switch.
                var mask = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
                mask["automation.enabled"] = true
                UserDefaults.standard.setVolatileDomain(mask, forName: UserDefaults.argumentDomain)
            }
            return window(hosting(SettingsView(state: nil, initialPane: pane.pane)),
                          title: NSLocalizedString("Settings", comment: ""), style: [.titled, .closable])

        default:
            return nil
        }
    }

    /// Host `view` as it looks in the key window of the active app.
    @MainActor
    private static func hosting(_ view: some View) -> NSHostingView<AnyView> {
        NSHostingView(rootView: AnyView(view.environment(\.controlActiveState, .key)))
    }

    /// A window around `host`, sized to `size` or to SwiftUI's fitting size.
    @MainActor
    private static func window(_ host: NSView, title: String, style: NSWindow.StyleMask,
                               size: NSSize? = nil) -> NSWindow {
        let fit = size ?? host.fittingSize
        let w = ShotWindow(contentRect: NSRect(origin: .zero, size: fit), styleMask: style,
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.title = title
        w.contentView = host
        w.setContentSize(fit)
        return w
    }

    /// An offscreen window can't become key for real, and a non-key window
    /// draws inactive (grey traffic lights, dimmed sidebar). Claim it is.
    /// Since macOS 14 a background process can't activate itself either, and
    /// AppKit draws the frame from its private active-appearance checks, so
    /// answer those too (renders only — this window never meets a user).
    private final class ShotWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
        @objc func _hasActiveAppearance() -> Bool { true }
        @objc func _hasActiveAppearanceIgnoringKeyFocus() -> Bool { true }
        @objc func _hasKeyAppearance() -> Bool { true }
        @objc func _hasMainAppearance() -> Bool { true }
    }

    /// AppKit controls (checkboxes, switches, default buttons) draw in the
    /// accent colour only while the app is active.
    private final class ShotApplication: NSApplication {
        override var isActive: Bool { true }
    }

    // MARK: - Demo data

    /// The manual's demo profile: "Work", blue, persistent, otherwise the
    /// same settings File › New Profile… gives a new profile.
    private static func demoProfile() -> Profile {
        var settings = ProfileSettings()
        settings.persistent = true
        settings.enableClipboardSharing = true
        settings.enableLinkSender = true
        settings.keychainPasskeys = true
        settings.keychainPasswords = true
        settings.homePage = "https://bromure.io/hello"
        return Profile(name: "Work", color: .blue, settings: settings)
    }

    /// A page load on a demo site: document, assets, an API call, a form post.
    private static func demoTrace() -> [TraceEvent] {
        let t0 = 1_780_000_000.0
        func ev(_ i: Int, _ at: Double, _ method: String, _ url: String, _ status: Int?,
                _ dur: Double, _ mime: String, error: String? = nil) -> TraceEvent {
            var e = TraceEvent(id: "demo-\(i)", timestamp: t0 + at, method: method, url: url,
                               statusCode: status, duration: dur)
            e.mimeType = mime
            e.hostname = URL(string: url)?.host
            e.tabId = 1
            e.documentUrl = "https://shop.example.com/"
            e.errorText = error
            e.requestHeaders = ["Accept": "*/*", "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"]
            e.responseHeaders = status.map { _ in ["Content-Type": mime, "Cache-Control": "max-age=300"] }
            return e
        }
        return [
            ev(0, 0.000, "GET", "https://shop.example.com/", 200, 0.182, "text/html"),
            ev(1, 0.201, "GET", "https://shop.example.com/assets/app.css", 200, 0.064, "text/css"),
            ev(2, 0.204, "GET", "https://shop.example.com/assets/app.js", 200, 0.121, "application/javascript"),
            ev(3, 0.210, "GET", "https://fonts.example-cdn.net/inter.woff2", 200, 0.090, "font/woff2"),
            ev(4, 0.352, "GET", "https://shop.example.com/img/hero.webp", 200, 0.233, "image/webp"),
            ev(5, 0.418, "GET", "https://api.shop.example.com/v1/cart", 200, 0.071, "application/json"),
            ev(6, 0.431, "GET", "https://api.shop.example.com/v1/recommendations", 304, 0.048, "application/json"),
            ev(7, 0.502, "GET", "https://metrics.example-ads.com/pixel.gif", nil, 0.012, "image/gif",
               error: "net::ERR_NAME_NOT_RESOLVED"),
            ev(8, 2.874, "POST", "https://shop.example.com/account/login", 302, 0.144, "text/html"),
            ev(9, 3.030, "GET", "https://shop.example.com/account", 200, 0.166, "text/html"),
            ev(10, 3.215, "GET", "https://api.shop.example.com/v1/orders?limit=10", 200, 0.098, "application/json"),
            ev(11, 3.240, "GET", "https://api.shop.example.com/v1/profile/avatar", 404, 0.041, "application/json"),
        ]
    }

    // MARK: - Plumbing

    /// Every preference the Settings window reads, at its default, in the
    /// argument domain: it outranks the user's saved values and is never
    /// persisted.
    private static func maskPreferences() {
        var mask = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        let defaults: [String: Any] = [
            "vm.memoryGB": 2, "vm.cpuCount": 0, "vm.swapCmdCtrl": true, "vm.appearance": "system",
            "vm.dnsServers": "", "vm.networkMode": "nat", "vm.bridgedInterface": "",
            "vm.extraKernelOptions": VMConfig.defaultExtraKernelOptions,
            "vm.energyMode": EnergyMode.default.rawValue,
            "phishingAnalysis.serverURL": PhishingAnalysisBridge.defaultServerBaseURL.absoluteString,
            "automation.enabled": false, "automation.port": 9222, "automation.bindAddress": "127.0.0.1",
            "links.defaultProfileID": "", AppState.launchProfileKey: "",
        ]
        mask.merge(defaults) { current, _ in current }
        UserDefaults.standard.setVolatileDomain(mask, forName: UserDefaults.argumentDomain)
    }

    private static func scratchDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure-shot-ui-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    /// Draw the whole window — the frame view, so the title bar comes along
    /// — into a 2× bitmap and write it as PNG.
    @MainActor
    private static func write(_ window: NSWindow, to path: String) -> Bool {
        guard let frameView = window.contentView?.superview else { return false }
        let bounds = frameView.bounds
        guard bounds.width > 0, bounds.height > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return false }
        rep.size = bounds.size
        frameView.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}
