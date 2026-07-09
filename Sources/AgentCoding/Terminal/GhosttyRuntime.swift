import AppKit
import GhosttyKit

/// Process-wide libghostty runtime: one `ghostty_app_t` hosting every native
/// terminal surface (Ghostty.app runs all its tabs/splits the same way).
///
/// Threading: libghostty requires all API calls on the main thread; each
/// surface runs its own IO + renderer threads internally. `wakeup_cb` is the
/// inversion point — libghostty never owns the run loop, it asks us to
/// schedule a tick.
///
/// @unchecked Sendable: main-thread confined by the same convention as the
/// VZ wrappers in this codebase.
final class GhosttyRuntime: @unchecked Sendable {
    static let shared = GhosttyRuntime()

    private(set) var app: ghostty_app_t?
    private var config: ghostty_config_t?

    /// Posted when a surface's child process exits (object = the
    /// TerminalSurfaceView). TerminalSessionController reattaches.
    static let childExitedNotification = Notification.Name("io.bromure.ghostty.childExited")
    /// Posted when a surface requests close (object = the view).
    static let closeSurfaceNotification = Notification.Name("io.bromure.ghostty.closeSurface")
    /// Posted when the guest sets a title (object = the view, userInfo["title"]).
    static let titleChangedNotification = Notification.Name("io.bromure.ghostty.titleChanged")

    /// Weak reference to the `TerminalSurfaceView` behind each surface
    /// userdata pointer. libghostty holds userdata *unretained*, so callbacks
    /// must never resurrect the raw pointer directly: a membership set can't
    /// close the race where the view's last release happens between the check
    /// and the retain (a set entry also goes stale if an owner drops a view
    /// without `retire()`, or lies if the heap reuses the address for a new
    /// view). A weak load is safely nil the moment deallocation begins — on
    /// any thread — so resolving through this map can't retain a dead view.
    /// Locked: registration/dealloc and libghostty callbacks aren't all
    /// main-confined in the failure cases that matter.
    private final class WeakViewBox {
        weak var view: TerminalSurfaceView?
        init(_ view: TerminalSurfaceView) { self.view = view }
    }
    private static let surfaceMapLock = NSLock()
    nonisolated(unsafe) private static var liveSurfaceViews:
        [UnsafeMutableRawPointer: WeakViewBox] = [:]

    static func registerSurfaceUserdata(_ ptr: UnsafeMutableRawPointer,
                                        view: TerminalSurfaceView) {
        surfaceMapLock.lock()
        defer { surfaceMapLock.unlock() }
        liveSurfaceViews[ptr] = WeakViewBox(view)
    }
    static func unregisterSurfaceUserdata(_ ptr: UnsafeMutableRawPointer) {
        surfaceMapLock.lock()
        defer { surfaceMapLock.unlock() }
        liveSurfaceViews.removeValue(forKey: ptr)
    }
    /// The still-alive view behind a surface userdata pointer, or nil once it
    /// has been retired or has begun deallocating. Every callback that gets a
    /// userdata pointer from libghostty must resolve through this.
    static func surfaceView(for ptr: UnsafeMutableRawPointer) -> TerminalSurfaceView? {
        surfaceMapLock.lock()
        defer { surfaceMapLock.unlock() }
        return liveSurfaceViews[ptr]?.view
    }

    private init() {}

    /// Idempotent; returns false (and logs) if libghostty failed to start —
    /// callers fall back to the framebuffer path.
    @MainActor
    @discardableResult
    func start() -> Bool {
        if app != nil { return true }

        // Bundled ghostty resources (shell-integration, themes; terminfo is
        // a sibling). Without this, release builds fall back to exe-relative
        // detection, which never matches our bundle layout.
        if let res = Bundle.main.resourceURL?.appendingPathComponent("ghostty").path,
           FileManager.default.fileExists(atPath: res) {
            setenv("GHOSTTY_RESOURCES_DIR", res, 1)
        }

        // SF Mono ships privately inside Terminal.app — profiles that import
        // the user's Terminal.app appearance name a font other apps can't
        // resolve. Register those faces for this process (no system
        // mutation) so the native surfaces render the same font Terminal
        // does. Must happen before any config references the family.
        Self.registerTerminalAppFonts()

        guard ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS else {
            NSLog("[ghostty] ghostty_init failed — native terminals disabled")
            return false
        }

        let cfg = ghostty_config_new()
        let path = Self.writeGeneratedConfig()
        path.withCString { ghostty_config_load_file(cfg, $0) }
        ghostty_config_finalize(cfg)
        self.config = cfg

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtime.supports_selection_clipboard = false
        runtime.wakeup_cb = { userdata in
            // May fire from any surface thread; the tick must run on main.
            guard let userdata else { return }
            let rt = Unmanaged<GhosttyRuntime>.fromOpaque(userdata).takeUnretainedValue()
            DispatchQueue.main.async {
                guard let app = rt.app else { return }
                ghostty_app_tick(app)
            }
        }
        runtime.action_cb = { app, target, action in
            GhosttyRuntime.handleAction(app: app, target: target, action: action)
        }
        runtime.read_clipboard_cb = { userdata, location, state in
            // `userdata` is the requesting surface's userdata (the view);
            // completion must happen for libghostty to unblock the requester.
            guard location == GHOSTTY_CLIPBOARD_STANDARD,
                  let userdata, let state,
                  let view = GhosttyRuntime.surfaceView(for: userdata),
                  let surface = view.surface else { return false }
            // An image on the clipboard pastes as a *guest file path*: the
            // request completes empty right away (libghostty is blocked on
            // it) and the path arrives as its own paste once the transfer
            // into the guest lands.
            if TerminalImagePaste.beginImagePaste(surfaceUserdata: userdata) {
                "".withCString {
                    ghostty_surface_complete_clipboard_request(surface, $0, state, false)
                }
                return true
            }
            let text = NSPasteboard.general.string(forType: .string) ?? ""
            text.withCString {
                ghostty_surface_complete_clipboard_request(surface, $0, state, false)
            }
            return true
        }
        runtime.confirm_read_clipboard_cb = { userdata, text, state, _ in
            // Paste protection is disabled in our generated config; if a
            // confirmation still arrives, approve it — the "guest" is the
            // user's own tmux session, not an untrusted remote.
            guard let userdata, let state,
                  let view = GhosttyRuntime.surfaceView(for: userdata),
                  let surface = view.surface else { return }
            ghostty_surface_complete_clipboard_request(surface, text, state, true)
        }
        runtime.write_clipboard_cb = { _, location, contents, count, _ in
            guard location == GHOSTTY_CLIPBOARD_STANDARD,
                  let contents, count > 0 else { return }
            // Take the first text/plain entry (OSC 52 and copy-on-select
            // both arrive as plain text).
            for i in 0..<count {
                let entry = contents[i]
                guard let data = entry.data else { continue }
                let mime = entry.mime.map { String(cString: $0) } ?? "text/plain"
                guard mime.hasPrefix("text/") else { continue }
                let text = String(cString: data)
                DispatchQueue.main.async {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                return
            }
        }
        runtime.close_surface_cb = { userdata, _ in
            // userdata here is the *surface's* userdata (the view).
            guard let userdata,
                  let view = GhosttyRuntime.surfaceView(for: userdata) else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: GhosttyRuntime.closeSurfaceNotification, object: view)
            }
        }

        guard let app = ghostty_app_new(&runtime, cfg) else {
            NSLog("[ghostty] ghostty_app_new failed — native terminals disabled")
            return false
        }
        self.app = app

        // Mirror app-level focus so unfocused surfaces throttle rendering.
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, true)
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, false)
        }
        return true
    }

    // MARK: Actions

    private static func handleAction(app: ghostty_app_t?,
                                     target: ghostty_target_s,
                                     action: ghostty_action_s) -> Bool {
        // Resolve the surface's view for surface-targeted actions — but only
        // if the view is still alive. A freed userdata (view torn down while
        // libghostty still held the surface, e.g. during app termination)
        // would crash on the retain of a dangling pointer; the weak map
        // resolves to nil instead.
        var view: TerminalSurfaceView?
        if target.tag == GHOSTTY_TARGET_SURFACE,
           let surface = target.target.surface,
           let userdata = ghostty_surface_userdata(surface) {
            view = surfaceView(for: userdata)
        }

        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE:
            guard let view, let cTitle = action.action.set_title.title else { return false }
            let title = String(cString: cTitle)
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: titleChangedNotification, object: view,
                    userInfo: ["title": title])
            }
            return true

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            guard let view else { return false }
            let code = action.action.child_exited.exit_code
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: childExitedNotification, object: view,
                    userInfo: ["exitCode": Int(code)])
            }
            return true

        case GHOSTTY_ACTION_RING_BELL:
            DispatchQueue.main.async { NSSound.beep() }
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            guard view != nil else { return false }
            let shape = action.action.mouse_shape
            DispatchQueue.main.async {
                switch shape {
                case GHOSTTY_MOUSE_SHAPE_TEXT: NSCursor.iBeam.set()
                case GHOSTTY_MOUSE_SHAPE_POINTER: NSCursor.pointingHand.set()
                case GHOSTTY_MOUSE_SHAPE_CROSSHAIR: NSCursor.crosshair.set()
                default: NSCursor.arrow.set()
                }
            }
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            let u = action.action.open_url
            guard let ptr = u.url, u.len > 0 else { return false }
            let s = String(decoding: UnsafeRawBufferPointer(start: ptr, count: Int(u.len)),
                           as: UTF8.self)
            guard let url = URL(string: s) else { return false }
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            return true

        case GHOSTTY_ACTION_RENDER, GHOSTTY_ACTION_MOUSE_VISIBILITY,
             GHOSTTY_ACTION_MOUSE_OVER_LINK, GHOSTTY_ACTION_CELL_SIZE,
             GHOSTTY_ACTION_COLOR_CHANGE, GHOSTTY_ACTION_PWD,
             GHOSTTY_ACTION_PROGRESS_REPORT:
            // Safe to acknowledge without UI (render is driven internally).
            return true

        default:
            // Window/tab/split management etc. — not ours; the guest tmux is
            // the multiplexer. Returning false tells libghostty "unhandled".
            return false
        }
    }

    // MARK: Config

    /// Register Terminal.app's privately-bundled fonts (SF Mono) with
    /// process scope so CoreText — and therefore ghostty's font discovery —
    /// can resolve them for our surfaces too.
    private static func registerTerminalAppFonts() {
        let dir = URL(fileURLWithPath:
            "/System/Applications/Utilities/Terminal.app/Contents/Resources/Fonts")
        guard let fonts = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return }
        var registered = 0
        for url in fonts where ["otf", "ttf"].contains(url.pathExtension.lowercased()) {
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) {
                registered += 1
            }
        }
        if registered > 0 {
            NSLog("[ghostty] registered %d Terminal.app fonts (SF Mono)", registered)
        }
    }

    /// App-level base config (defaults; no profile yet at app init).
    private static func writeGeneratedConfig() -> String {
        writeConfigFile(named: "config",
                        contents: TerminalAppDefaults.ghosttyConfig(
                            for: nil, terminalDefaults: .load()))
    }

    /// Per-profile configs applied to live surfaces. Retained here because
    /// libghostty may reference the config after update; freed on replace.
    private var profileConfigs: [UUID: ghostty_config_t] = [:]

    /// Apply `profile`'s appearance (font, colors, cursor shape/blink) to a
    /// surface. Called at surface creation and again on profile save, so
    /// appearance edits land live.
    @MainActor
    func apply(profile: Profile, to surface: ghostty_surface_t) {
        let text = TerminalAppDefaults.ghosttyConfig(for: profile,
                                                     terminalDefaults: .load())
        let path = Self.writeConfigFile(named: "config-\(profile.id.uuidString)",
                                        contents: text)
        let cfg = ghostty_config_new()
        path.withCString { ghostty_config_load_file(cfg, $0) }
        ghostty_config_finalize(cfg)
        ghostty_surface_update_config(surface, cfg)
        if let old = profileConfigs[profile.id] { ghostty_config_free(old) }
        profileConfigs[profile.id] = cfg
    }

    private static func writeConfigFile(named name: String, contents: String) -> String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("BromureAC/ghostty", isDirectory: true)
        let url = dir.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try (contents + "\n").write(to: url, atomically: true, encoding: .utf8)
            NSLog("[ghostty] wrote %@", url.path)
        } catch {
            NSLog("[ghostty] config write FAILED at %@: %@", url.path,
                  String(describing: error))
        }
        return url.path
    }
}

