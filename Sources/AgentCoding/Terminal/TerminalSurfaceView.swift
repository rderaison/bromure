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
    /// Guest title (from OSC / tmux), updated via the runtime's action fan-out.
    private(set) var title: String = ""

    /// Retire-don't-free: freeing a surface while its renderer thread is
    /// mid-present races (upstream teardown bugs); we drop it from the view
    /// hierarchy immediately but delay the free.
    private static let retireDelay: TimeInterval = 0.5

    /// Accumulates insertText output during keyDown's interpretKeyEvents
    /// round-trip so the key event carries the translated text.
    private var keyTextAccumulator: [String]?

    init?(command: String, workingDirectory: String? = nil, windowIndex: Int) {
        guard let app = GhosttyRuntime.shared.app else { return nil }
        self.windowIndex = windowIndex
        super.init(frame: .zero)

        var cfg = ghostty_surface_config_new()
        cfg.platform_tag = GHOSTTY_PLATFORM_MACOS
        cfg.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(self).toOpaque()))
        cfg.userdata = Unmanaged.passUnretained(self).toOpaque()
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
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Detach and schedule the surface free. Idempotent. The view must not
    /// receive further events after this (callers remove it from the
    /// hierarchy first).
    func retire() {
        guard let s = surface else { return }
        surface = nil
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

        // Route through the input context so dead keys and basic IME
        // composition produce insertText; the translated text rides on the
        // ghostty key event (same shape as the reference implementation).
        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }
        interpretKeyEvents([event])
        let text = keyTextAccumulator?.joined() ?? ""

        sendKey(event: event, action: GHOSTTY_ACTION_PRESS, surface: surface, text: text)
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
                         surface: ghostty_surface_t, text: String) {
        var key = ghostty_input_key_s()
        key.action = action
        key.mods = Self.mods(event.modifierFlags)
        key.consumed_mods = GHOSTTY_MODS_NONE
        key.keycode = UInt32(event.keyCode)
        key.composing = false
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

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
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

    // Marked text (IME composition) — minimal: we don't render inline
    // preedit in phase 1; composition still works via the IME's own panel.
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard let surface else { return }
        let text: String
        switch string {
        case let s as String: text = s
        case let a as NSAttributedString: text = a.string
        default: return
        }
        text.withCString { ghostty_surface_preedit(surface, $0, UInt(text.utf8.count)) }
    }

    func unmarkText() {
        guard let surface else { return }
        ghostty_surface_preedit(surface, nil, 0)
    }

    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { false }
    func attributedSubstring(forProposedRange range: NSRange,
                             actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func firstRect(forCharacterRange range: NSRange,
                   actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(bounds, to: nil))
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
