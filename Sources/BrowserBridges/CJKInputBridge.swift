import AppKit
import Carbon
import Foundation
import SandboxEngine
import Virtualization

/// Debug logging gated behind BROMURE_DEBUG_CJK environment variable.
private let cjkDebug = ProcessInfo.processInfo.environment["BROMURE_DEBUG_CJK"] != nil

/// Bridges CJK input from macOS native IME to the guest VM via CDP.
///
/// When a CJK input source is active on the host, this bridge takes over
/// keyboard input by making a hidden NSTextInputClient view the first
/// responder (and refusing to resign). All keyboard events flow through
/// the standard `keyDown` → `interpretKeyEvents` → NSTextInputClient path,
/// giving us the full macOS IME experience.
///
/// Text is delivered to the guest browser via Chrome DevTools Protocol:
///   - Composition updates → `Input.imeSetComposition`
///   - Committed text      → `Input.insertText`
///   - Passthrough keys    → `Input.dispatchKeyEvent`
///
/// This avoids fighting VZVirtualMachineView for keyboard events entirely.
public final class CJKInputBridge {
    private static let vsockPort: UInt32 = 5007

    private weak var socketDevice: VZVirtioSocketDevice?
    private var inputView: CJKInputView?
    private var observation: NSObjectProtocol?
    private var debounceTimer: Timer?
    private(set) public var isCJKActive = false

    public init(socketDevice: VZVirtioSocketDevice) {
        self.socketDevice = socketDevice
        isCJKActive = Self.detectCJKInputSource()

        observation = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleInputSourceCheck()
        }
    }

    deinit { stop() }

    public func stop() {
        debounceTimer?.invalidate()
        debounceTimer = nil
        if let obs = observation {
            DistributedNotificationCenter.default().removeObserver(obs)
            observation = nil
        }
        deactivate()
        inputView?.removeFromSuperview()
        inputView = nil
    }

    /// Install the CJK input view in the VM window.
    public func install(in window: NSWindow, vmView: VZVirtualMachineView) {
        let view = CJKInputView(vmView: vmView, window: window)
        view.onSendMessage = { [weak self] message in
            self?.sendMessage(message)
        }
        view.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        window.contentView?.addSubview(view)
        self.inputView = view

        if isCJKActive {
            activate()
        }
    }

    // MARK: - Input source change handling

    private func scheduleInputSourceCheck() {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            self?.handleInputSourceChanged()
        }
    }

    private func handleInputSourceChanged() {
        let wasActive = isCJKActive
        isCJKActive = Self.detectCJKInputSource()
        guard isCJKActive != wasActive else { return }
        if isCJKActive {
            activate()
        } else {
            deactivate()
        }
    }

    private func activate() {
        guard let view = inputView, let window = view.window else { return }
        view.isActive = true
        // Take first responder — the view will refuse to resign while active,
        // so VZVirtualMachineView cannot steal it back.
        window.makeFirstResponder(view)
        if cjkDebug { print("[CJKInputBridge] activated — first responder locked") }
    }

    private func deactivate() {
        guard let view = inputView, let window = view.window else { return }
        view.isActive = false
        // Allow VZVirtualMachineView to reclaim first responder
        window.makeFirstResponder(view.vmView)
        if cjkDebug { print("[CJKInputBridge] deactivated — first responder released to VM") }
    }

    // MARK: - CJK detection

    static func detectCJKInputSource() -> Bool {
        let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        guard let idRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return false
        }
        let sourceID = unsafeBitCast(idRef, to: CFString.self) as String

        let cjkPrefixes = [
            "com.apple.inputmethod.SCIM",     // Simplified Chinese
            "com.apple.inputmethod.TCIM",     // Traditional Chinese
            "com.apple.inputmethod.Kotoeri",  // Japanese
            "com.apple.inputmethod.Korean",   // Korean
        ]
        return cjkPrefixes.contains { sourceID.hasPrefix($0) }
    }

    // MARK: - Message delivery to guest

    private func sendMessage(_ message: [String: String]) {
        guard let device = socketDevice else { return }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        if cjkDebug { print("[CJKInputBridge] → \(jsonString)") }
        device.connect(toPort: Self.vsockPort) { result in
            switch result {
            case .success(let conn):
                let data = Array(jsonString.utf8)
                data.withUnsafeBufferPointer { buf in
                    if let base = buf.baseAddress {
                        _ = Darwin.write(conn.fileDescriptor, base, buf.count)
                    }
                }
                Darwin.close(conn.fileDescriptor)
            case .failure(let error):
                if cjkDebug { print("[CJKInputBridge] vsock send failed: \(error)") }
            }
        }
    }
}

// MARK: - CJK Input View

/// NSView that implements NSTextInputClient for CJK IME composition.
///
/// When active, this view locks itself as first responder (refuses to resign),
/// preventing VZVirtualMachineView from stealing keyboard events. All input
/// flows through the standard keyDown → interpretKeyEvents → IME path.
///
/// Keys the IME doesn't consume (backspace, arrows, etc.) are forwarded to
/// the guest browser via CDP Input.dispatchKeyEvent.
final class CJKInputView: NSView, NSTextInputClient {
    weak var vmView: VZVirtualMachineView?
    weak var targetWindow: NSWindow?
    var onSendMessage: (([String: String]) -> Void)?
    var isActive = false

    private var markedString: NSAttributedString?
    /// The event currently being processed by interpretKeyEvents.
    private var currentEvent: NSEvent?
    /// Set by insertText during interpretKeyEvents so we can check the result.
    private var lastInsertedText: String?

    init(vmView: VZVirtualMachineView, window: NSWindow) {
        self.vmView = vmView
        self.targetWindow = window
        super.init(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    /// Control first responder to keep keyboard events while allowing mouse clicks.
    /// When CJK is active, refuse resignation UNLESS it's triggered by a mouse click
    /// (which VZ needs to process). In that case, allow but immediately reclaim.
    override func resignFirstResponder() -> Bool {
        guard isActive else { return super.resignFirstResponder() }

        // Allow resignation for mouse clicks so VZ can process them
        if let event = NSApp.currentEvent, event.type == .leftMouseDown || event.type == .rightMouseDown {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isActive else { return }
                self.window?.makeFirstResponder(self)
            }
            return true
        }

        // Block all other resignation attempts (VZ trying to steal focus)
        return false
    }

    // MARK: - Keyboard event handling

    override func keyDown(with event: NSEvent) {
        if cjkDebug { print("[CJKInputView] keyDown: keyCode=\(event.keyCode) chars=\(event.charactersIgnoringModifiers?.debugDescription ?? "nil") hasMarked=\(markedString != nil)") }
        currentEvent = event
        lastInsertedText = nil
        interpretKeyEvents([event])

        // If insertText was called with pure ASCII, the IME didn't compose —
        // forward the original key to the guest via CDP.
        if let text = lastInsertedText, text.allSatisfy({ $0.isASCII }) {
            forwardKeyToGuest(event)
        }
        currentEvent = nil
    }

    override func keyUp(with event: NSEvent) {
        // Forward all keyUp events to the guest so it sees balanced down/up pairs.
        // Without this, modifier state and key repeat break in the browser.
        forwardKeyUpToGuest(event)
    }

    /// Forward a keyDown event to the guest via CDP Input.dispatchKeyEvent.
    /// Sends rawKeyDown, then a char event if the key produces text (needed
    /// for Enter to submit forms, etc.).
    private func forwardKeyToGuest(_ event: NSEvent) {
        guard let (key, code, vkCode) = Self.cdpKeyInfo(for: event) else { return }

        var modifiers: [String: String] = [:]
        if event.modifierFlags.contains(.shift) { modifiers["shift"] = "1" }
        if event.modifierFlags.contains(.control) { modifiers["ctrl"] = "1" }
        if event.modifierFlags.contains(.option) { modifiers["alt"] = "1" }
        if event.modifierFlags.contains(.command) { modifiers["meta"] = "1" }

        let text: String? = {
            if let chars = event.characters, chars.count == 1, chars.first!.isASCII {
                return chars
            }
            return nil
        }()

        // 1. rawKeyDown
        var msg: [String: String] = [
            "type": "rawKeyDown",
            "key": key,
            "code": code,
            "vk": "\(vkCode)",
        ]
        msg.merge(modifiers) { $1 }
        onSendMessage?(msg)

        // 2. char event (needed for Enter → form submit, space → scroll, etc.)
        if let text, !text.isEmpty {
            var charMsg: [String: String] = [
                "type": "char",
                "key": key,
                "code": code,
                "vk": "\(vkCode)",
                "text": text,
            ]
            charMsg.merge(modifiers) { $1 }
            onSendMessage?(charMsg)
        }
    }

    private func forwardKeyUpToGuest(_ event: NSEvent) {
        guard let (key, code, vkCode) = Self.cdpKeyInfo(for: event) else { return }
        onSendMessage?(["type": "keyUp", "key": key, "code": code, "vk": "\(vkCode)"])
    }

    // MARK: - NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text: String
        if let s = string as? String {
            text = s
        } else if let s = string as? NSAttributedString {
            text = s.string
        } else {
            return
        }
        markedString = nil
        lastInsertedText = text
        if cjkDebug { print("[CJKInputView] insertText: \"\(text)\"") }

        // Only send non-ASCII (composed) text. ASCII passthrough is handled
        // by forwardKeyToGuest in keyDown.
        if !text.allSatisfy({ $0.isASCII }) {
            onSendMessage?(["type": "commit", "text": text])
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let s = string as? NSAttributedString {
            markedString = s
        } else if let s = string as? String {
            markedString = NSAttributedString(string: s)
        }
        let text = markedString?.string ?? ""
        if cjkDebug { print("[CJKInputView] setMarkedText: \"\(text)\"") }
        if !text.isEmpty {
            onSendMessage?(["type": "compose", "text": text])
        }
    }

    func unmarkText() {
        // Some IMEs (notably Japanese) confirm text by calling unmarkText()
        // without insertText(). The marked text IS the final committed text.
        if let text = markedString?.string, !text.isEmpty {
            if cjkDebug { print("[CJKInputView] unmarkText: committing \"\(text)\"") }
            lastInsertedText = text
            if !text.allSatisfy({ $0.isASCII }) {
                onSendMessage?(["type": "commit", "text": text])
            }
        }
        markedString = nil
    }

    func selectedRange() -> NSRange {
        NSRange(location: 0, length: 0)
    }

    func markedRange() -> NSRange {
        if let s = markedString {
            return NSRange(location: 0, length: s.length)
        }
        return NSRange(location: NSNotFound, length: 0)
    }

    func hasMarkedText() -> Bool {
        markedString != nil
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let vmView, let window = vmView.window else {
            return NSRect(x: NSEvent.mouseLocation.x, y: NSEvent.mouseLocation.y - 30, width: 0, height: 20)
        }
        let mouse = NSEvent.mouseLocation
        let viewScreen = vmView.convert(vmView.bounds, to: nil)
        let windowScreen = window.convertToScreen(viewScreen)

        if windowScreen.contains(mouse) {
            return NSRect(x: mouse.x, y: mouse.y - 30, width: 0, height: 20)
        }
        return NSRect(x: windowScreen.midX, y: windowScreen.midY, width: 0, height: 20)
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }

    override func doCommand(by selector: Selector) {
        // Called for keys the IME doesn't consume (backspace, arrows, Enter, etc.)
        // Forward these to the guest via CDP.
        if cjkDebug { print("[CJKInputView] doCommand(by: \(selector))") }
        if let event = currentEvent {
            forwardKeyToGuest(event)
        }
    }

    // MARK: - Key mapping (key, code, windowsVirtualKeyCode)

    /// Map NSEvent keyCode to CDP (key, code, windowsVirtualKeyCode).
    static func cdpKeyInfo(for event: NSEvent) -> (String, String, Int)? {
        // (CDP key name, CDP code, Windows virtual key code)
        switch event.keyCode {
        case 36: return ("Enter",      "Enter",       13)
        case 48: return ("Tab",        "Tab",          9)
        case 51: return ("Backspace",  "Backspace",    8)
        case 53: return ("Escape",     "Escape",      27)
        case 117: return ("Delete",    "Delete",      46)
        case 123: return ("ArrowLeft", "ArrowLeft",   37)
        case 124: return ("ArrowRight","ArrowRight",  39)
        case 125: return ("ArrowDown", "ArrowDown",   40)
        case 126: return ("ArrowUp",   "ArrowUp",     38)
        case 115: return ("Home",      "Home",        36)
        case 119: return ("End",       "End",         35)
        case 116: return ("PageUp",    "PageUp",      33)
        case 121: return ("PageDown",  "PageDown",    34)
        case 49: return (" ",          "Space",       32)
        default:
            if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
                let upper = chars.uppercased()
                let vk = Int(upper.unicodeScalars.first?.value ?? 0)
                return (chars, "Key\(upper)", vk)
            }
            return nil
        }
    }
}
