import AppKit
import GhosttyKit

/// One libghostty terminal surface: a Metal-rendered NSView whose child
/// process is the `__attach-window` pump to a guest tmux window.
///
/// libghostty owns the pty, the child process, and the renderer thread; this
/// view's job is geometry (size/scale), focus/occlusion, and translating
/// NSEvents into `ghostty_surface_*` calls. Modeled on the reference
/// implementation in Ghostty.app's SurfaceView_AppKit.
final class TerminalSurfaceView: NSView {
    private(set) var surface: ghostty_surface_t?
    /// tmux window index this view is attached to (grid cell identity).
    let windowIndex: Int
    /// Profile (VM) this surface serves — image pastes upload into this
    /// guest. nil disables image paste (surface without VM context).
    let profileID: Profile.ID?
    /// Remote host id when this surface mirrors a workspace on another Mac
    /// (fat client). nil = a local VM. Image pastes route their guest file
    /// ops through this host's tunnel controller instead of the local bridge.
    let remoteHost: UUID?
    /// Guest title (from OSC / tmux), updated via the runtime's action fan-out.
    private(set) var title: String = ""

    /// Live image-paste chip, if any (subview; the hierarchy owns it).
    /// Weak so a faded-out chip nils itself away.
    weak var pasteThumbnail: PasteThumbnailOverlay?

    /// Retire-don't-free: freeing a surface while its renderer thread is
    /// mid-present races (upstream teardown bugs); we drop it from the view
    /// hierarchy immediately but delay the free.
    private static let retireDelay: TimeInterval = 0.5

    /// Accumulates insertText output during keyDown's interpretKeyEvents
    /// round-trip so the key event carries the translated text.
    private var keyTextAccumulator: [String]?

    /// Live IME composition (the underlined preedit), if any. Tracked so a
    /// commit (`insertText`) clears it — AppKit's contract is that
    /// insertText *replaces* marked text, it doesn't send unmarkText first.
    private var preeditText: String?

    init?(command: String, workingDirectory: String? = nil, windowIndex: Int,
          profileID: Profile.ID? = nil, remoteHost: UUID? = nil) {
        guard let app = GhosttyRuntime.shared.app else { return nil }
        self.windowIndex = windowIndex
        self.profileID = profileID
        self.remoteHost = remoteHost
        super.init(frame: .zero)

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()))
        let userdataPtr = Unmanaged.passUnretained(self).toOpaque()
        cfg.userdata = userdataPtr
        cfg.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)
        cfg.context = GHOSTTY_SURFACE_CONTEXT_WINDOW

        let created: ghostty_surface_t? = command.withCString { cCmd in
            cfg.command = cCmd
            if let workingDirectory {
                return workingDirectory.withCString { cWd in
                    cfg.working_directory = cWd
                    return ghostty_surface_new(app, &cfg)
                }
            }
            return ghostty_surface_new(app, &cfg)
        }
        guard let created else { return nil }
        self.surface = created
        // Mark this view's userdata live so `GhosttyRuntime.handleAction` will
        // resolve actions targeting it — and stop resolving once it's gone.
        self.userdataPtr = userdataPtr
        GhosttyRuntime.registerSurfaceUserdata(userdataPtr, view: self)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Our surface-userdata pointer (== the address of `self`), registered with
    /// the runtime's live set for the view's lifetime.
    private var userdataPtr: UnsafeMutableRawPointer?

    deinit {
        if let userdataPtr { GhosttyRuntime.unregisterSurfaceUserdata(userdataPtr) }
        // Deallocating with a live surface means an owner dropped this view
        // without retire(): the ghostty surface (and its renderer, holding
        // our now-dangling nsview pointer) leaks and keeps running. Can't
        // free here — deinit isn't guaranteed on-main and the API is
        // main-only — so leave a breadcrumb for the crash report instead.
        if surface != nil {
            NSLog("[ghostty] BUG: TerminalSurfaceView(window %d) deallocated without retire()",
                  windowIndex)
        }
    }

    /// Detach and schedule the surface free. Idempotent. The view must not
    /// receive further events after this (callers remove it from the
    /// hierarchy first).
    func retire() {
        guard let s = surface else { return }
        surface = nil
        // Stop resolving actions to this view immediately — the surface free is
        // delayed below, and any action in that window must be ignored.
        if let userdataPtr { GhosttyRuntime.unregisterSurfaceUserdata(userdataPtr) }
        ghostty_surface_set_focus(s, false)
        ghostty_surface_set_occlusion(s, false)
        // Delayed free, and keep `self` alive with it: libghostty holds our
        // pointer as surface userdata until the free completes.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retireDelay) { [self] in
            ghostty_surface_free(s)
            _ = self   // extend lifetime past the free
        }
    }

    var processExited: Bool {
        guard let surface else { return true }
        return ghostty_surface_process_exited(surface)
    }

    // MARK: Geometry

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateScale()
        updateSurfaceSize()
        // One-shot metrics log per mount: cell width ≈ 2× the glyph raster
        // is the signature of a content-scale mismatch (blurry + gapped
        // text); a wild cell width means font resolution failed.
        if let surface, window != nil {
            let s = ghostty_surface_size(surface)
            NSLog("[ghostty] surface metrics: %dx%d cells, %dx%d px, cell %dx%d px, scale %.1f",
                  Int(s.columns), Int(s.rows), Int(s.width_px), Int(s.height_px),
                  Int(s.cell_width_px), Int(s.cell_height_px),
                  Double(window?.backingScaleFactor ?? 0))
        }
    }

    override func layout() {
        super.layout()
        updateSurfaceSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateScale()
        updateSurfaceSize()
    }

    private func updateScale() {
        guard let surface, let window else { return }
        let scale = window.backingScaleFactor
        ghostty_surface_set_content_scale(surface, scale, scale)
    }

    private func updateSurfaceSize() {
        guard let surface else { return }
        let backing = convertToBacking(bounds.size)
        guard backing.width > 0, backing.height > 0 else { return }
        ghostty_surface_set_size(surface, UInt32(backing.width), UInt32(backing.height))
    }

    /// The caret cell in view coordinates (bottom-left origin, points),
    /// straight from libghostty's IME point. Shared by the IME candidate
    /// window and the paste-thumbnail chip; nil once the surface is gone.
    var caretRect: NSRect? {
        guard let surface, let window else { return nil }
        var x: Double = 0, y: Double = 0, w: Double = 0, h: Double = 0
        ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        let cellHeightPoints = Double(ghostty_surface_size(surface).cell_height_px)
            / Double(window.backingScaleFactor)
        return NSRect(x: x, y: Double(frame.height) - y,
                      width: w, height: max(h, cellHeightPoints))
    }

    // MARK: Focus

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let surface { ghostty_surface_set_focus(surface, true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok, let surface { ghostty_surface_set_focus(surface, false) }
        return ok
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .inVisibleRect,
                      .activeInKeyWindow],
            owner: self))
        super.updateTrackingAreas()
    }

    /// First click both focuses and registers with the surface — without
    /// this, the click that raises the window is swallowed and a selection
    /// drag starts from a stale anchor.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The session windows are movable-by-background; without this a
    /// selection drag on the (non-opaque) surface drags the whole window.
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseEntered(with event: NSEvent) {
        mouseMoved(with: event)   // seed the surface's cursor position
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let surface else { return }

        // Typing walks over a lingering paste thumbnail — dismiss it.
        pasteThumbnail?.keystrokeDismiss()

        // Route through the input context so dead keys and basic IME
        // composition produce insertText; the translated text rides on the
        // ghostty key event (same shape as the reference implementation).
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        interpretKeyEvents([event])
        let text = keyTextAccumulator?.joined() ?? ""

        // While the IME is composing, the key event must be marked as such
        // (and carries no text) or ghostty would also encode the raw
        // keystroke underneath the preedit.
        sendKey(event: event, action: GHOSTTY_ACTION_PRESS, surface: surface,
                text: text, composing: preeditText != nil)
    }

    override func keyUp(with event: NSEvent) {
        guard let surface else { return }
        sendKey(event: event, action: GHOSTTY_ACTION_RELEASE, surface: surface, text: "")
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface else { return }
        // Modifier-only transitions: press when the key's flag is now set.
        let pressed: Bool
        switch Int(event.keyCode) {
        case kVK_Shift, kVK_RightShift: pressed = event.modifierFlags.contains(.shift)
        case kVK_Control, kVK_RightControl: pressed = event.modifierFlags.contains(.control)
        case kVK_Option, kVK_RightOption: pressed = event.modifierFlags.contains(.option)
        case kVK_Command, kVK_RightCommand: pressed = event.modifierFlags.contains(.command)
        case kVK_CapsLock: pressed = event.modifierFlags.contains(.capsLock)
        default: return
        }
        sendKey(event: event,
                action: pressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE,
                surface: surface, text: "")
    }

    private func sendKey(event: NSEvent, action: ghostty_input_action_e,
                         surface: ghostty_surface_t, text: String,
                         composing: Bool = false) {
        var key = ghostty_input_key_s()
        key.action = action
        key.mods = Self.mods(event.modifierFlags)
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.keycode = UInt32(event.keyCode)
        key.composing = composing
        key.unshifted_codepoint = 0
        if event.type == .keyDown || event.type == .keyUp,
           let chars = event.charactersIgnoringModifiers,
           let scalar = chars.unicodeScalars.first {
            key.unshifted_codepoint = scalar.value
        }
        if text.isEmpty {
            _ = ghostty_surface_key(surface, key)
        } else {
            text.withCString {
                key.text = $0
                _ = ghostty_surface_key(surface, key)
            }
        }
    }

    static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
        return ghostty_input_mods_e(mods)
    }

    // MARK: Mouse

    private func send(button: ghostty_input_mouse_button_e,
                      state: ghostty_input_mouse_state_e, event: NSEvent) {
        guard let surface else { return }
        ghostty_surface_mouse_button(surface, state, button, Self.mods(event.modifierFlags))
    }

    override func mouseDown(with event: NSEvent) { send(button: GHOSTTY_MOUSE_LEFT, state: GHOSTTY_MOUSE_PRESS, event: event) }
    override func mouseUp(with event: NSEvent) { send(button: GHOSTTY_MOUSE_LEFT, state: GHOSTTY_MOUSE_RELEASE, event: event) }
    override func rightMouseDown(with event: NSEvent) { send(button: GHOSTTY_MOUSE_RIGHT, state: GHOSTTY_MOUSE_PRESS, event: event) }
    override func rightMouseUp(with event: NSEvent) { send(button: GHOSTTY_MOUSE_RIGHT, state: GHOSTTY_MOUSE_RELEASE, event: event) }
    override func otherMouseDown(with event: NSEvent) { send(button: GHOSTTY_MOUSE_MIDDLE, state: GHOSTTY_MOUSE_PRESS, event: event) }
    override func otherMouseUp(with event: NSEvent) { send(button: GHOSTTY_MOUSE_MIDDLE, state: GHOSTTY_MOUSE_RELEASE, event: event) }

    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        // View-local position, (0,0) top-left, in points.
        let pos = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, pos.x, frame.height - pos.y,
                                  Self.mods(event.modifierFlags))
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    /// Accumulated trackpad magnification; each ±0.25 of pinch steps the
    /// font size once, mirroring ⌘+/⌘-.
    private var pinchAccumulator: CGFloat = 0

    override func magnify(with event: NSEvent) {
        guard let surface else { return }
        if event.phase == .began { pinchAccumulator = 0 }
        pinchAccumulator += event.magnification
        let step: CGFloat = 0.25
        while pinchAccumulator >= step {
            pinchAccumulator -= step
            "increase_font_size:1".withCString {
                _ = ghostty_surface_binding_action(surface, $0, UInt("increase_font_size:1".utf8.count))
            }
        }
        while pinchAccumulator <= -step {
            pinchAccumulator += step
            "decrease_font_size:1".withCString {
                _ = ghostty_surface_binding_action(surface, $0, UInt("decrease_font_size:1".utf8.count))
            }
        }
    }

    override func smartMagnify(with event: NSEvent) {
        // Two-finger double-tap: reset zoom.
        guard let surface else { return }
        "reset_font_size".withCString {
            _ = ghostty_surface_binding_action(surface, $0, UInt("reset_font_size".utf8.count))
        }
    }

    /// Private key sequences the guest tmux routes per pane state (bromure-
    /// agentd `create_session`): a mouse-tracking pane (claude, vim +mouse)
    /// gets a synthetic SGR wheel event, an alt-screen pane without mouse
    /// (less) gets arrow keys, a plain shell scrolls tmux history via
    /// copy-mode. The attach client pins this surface to the alternate
    /// screen, so ghostty has no scrollback of its own — left alone it fakes
    /// arrow keys for the wheel, which pages the shell's command history
    /// instead of the terminal text.
    ///
    /// These sequences are also the safety net for the mouse-captured branch
    /// above: tmux flaps the client tty's mouse modes off/on around every
    /// redraw, so `ghostty_surface_mouse_captured` can read false mid-gesture
    /// while the pane app is tracking the mouse. Ticks that fall through land
    /// here and still reach the app as wheel events via the guest binding.
    ///
    /// Sent as a `text:` binding action (zig string-literal escapes), which
    /// writes raw bytes to the pty. NOT `ghostty_surface_text` — that is the
    /// clipboard-paste path, and with bracketed paste on (readline at any
    /// shell prompt) it wraps the bytes in \e[200~..\e[201~, making tmux
    /// paste "[1000001~" literally instead of matching the User0/1 keys.
    private static let tmuxScrollUpSeq = "\\x1b[1000001~"
    private static let tmuxScrollDownSeq = "\\x1b[1000002~"
    /// Sub-line remainder of precise (trackpad) scrolling, carried across
    /// events so slow drags still accumulate into whole lines.
    private var scrollLineRemainder: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }

        // A guest TUI that requested mouse tracking gets real wheel reports —
        // tmux forwards those to the pane, so the app scrolls natively.
        if ghostty_surface_mouse_captured(surface) {
            var x = event.scrollingDeltaX
            var y = event.scrollingDeltaY
            let precision = event.hasPreciseScrollingDeltas
            if precision { x *= 2; y *= 2 }   // matches the reference feel

            // scroll_mods packed struct: bit 0 = precision, bits 1-3 = momentum.
            var mods: Int32 = precision ? 1 : 0
            let momentum: Int32
            switch event.momentumPhase {
            case .began: momentum = 1
            case .stationary: momentum = 2
            case .changed: momentum = 3
            case .ended: momentum = 4
            case .cancelled: momentum = 5
            case .mayBegin: momentum = 6
            default: momentum = 0
            }
            mods |= momentum << 1
            ghostty_surface_mouse_scroll(surface, x, y, mods)
            return
        }

        // Otherwise scroll the tmux history: one injected sequence per line.
        var lines: CGFloat
        if event.hasPreciseScrollingDeltas {
            let scale = window?.backingScaleFactor ?? 2.0
            let cellPoints = max(CGFloat(ghostty_surface_size(surface).cell_height_px) / scale, 1)
            scrollLineRemainder += event.scrollingDeltaY / cellPoints
            lines = scrollLineRemainder.rounded(.towardZero)
            scrollLineRemainder -= lines
        } else {
            lines = event.scrollingDeltaY * 3   // classic 3 lines per detent
        }
        let count = min(Int(abs(lines)), 40)
        guard count > 0 else { return }
        let seq = lines > 0 ? Self.tmuxScrollUpSeq : Self.tmuxScrollDownSeq
        let action = "text:" + String(repeating: seq, count: count)
        action.withCString {
            _ = ghostty_surface_binding_action(surface, $0, UInt(action.utf8.count))
        }
    }
}

// MARK: - NSTextInputClient (dead keys / basic IME)

extension TerminalSurfaceView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        switch string {
        case let s as String: text = s
        case let a as NSAttributedString: text = a.string
        default: return
        }
        // A commit replaces any live composition — clear the preedit or the
        // underlined text stays on screen forever.
        if preeditText != nil {
            preeditText = nil
            if let surface { ghostty_surface_preedit(surface, nil, 0) }
        }
        if keyTextAccumulator != nil {
            // Mid-keyDown: ride the key event (correct encoding of e.g.
            // ctrl/alt-modified text happens in libghostty).
            keyTextAccumulator?.append(text)
        } else if let surface {
            // IME commit outside a keyDown (e.g. input method panel).
            text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) }
        }
    }

    override func doCommand(by selector: Selector) {
        // Intentionally empty: unhandled commands (arrows, delete, …) are
        // encoded from the raw key event by libghostty; invoking responder
        // actions here would double-handle them.
    }

    // Marked text (IME composition): ghostty renders the preedit inline
    // (underlined); we track it so commits and cancellations clear it.
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard let surface else { return }
        let text: String
        switch string {
        case let s as String: text = s
        case let a as NSAttributedString: text = a.string
        default: return
        }
        if text.isEmpty {
            preeditText = nil
            ghostty_surface_preedit(surface, nil, 0)
        } else {
            preeditText = text
            text.withCString { ghostty_surface_preedit(surface, $0, UInt(text.utf8.count)) }
        }
    }

    func unmarkText() {
        preeditText = nil
        guard let surface else { return }
        ghostty_surface_preedit(surface, nil, 0)
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange {
        guard let preeditText else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: preeditText.utf16.count)
    }
    func hasMarkedText() -> Bool { preeditText != nil }
    func attributedSubstring(forProposedRange range: NSRange,
                             actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    /// Where the IME should place its candidate window: the caret cell,
    /// converted to bottom-left screen coords.
    func firstRect(forCharacterRange range: NSRange,
                   actualRange: NSRangePointer?) -> NSRect {
        guard let window, let rect = caretRect else { return .zero }
        return window.convertToScreen(convert(rect, to: nil))
    }
    func characterIndex(for point: NSPoint) -> Int { 0 }
}

// Virtual keycodes for flagsChanged (Carbon's kVK_* without importing Carbon).
private let kVK_CapsLock = 0x39
private let kVK_Shift = 0x38
private let kVK_RightShift = 0x3C
private let kVK_Control = 0x3B
private let kVK_RightControl = 0x3E
private let kVK_Option = 0x3A
private let kVK_RightOption = 0x3D
private let kVK_Command = 0x37
private let kVK_RightCommand = 0x36
