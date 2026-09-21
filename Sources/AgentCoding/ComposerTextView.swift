#if os(macOS)
import AppKit
import SwiftUI

// The chat composer's text area on macOS. SwiftUI's vertical TextField
// keeps the field editor's text container at the width it had when
// editing began: open the browser or Files pane beside a chat while
// typing and the text runs off the field's edge; start typing while the
// pane is open, close it, and the text keeps to half the field. A real
// NSTextView whose container tracks its width re-wraps on every resize.

/// Grows with its text from one line to `maxLines`, then scrolls. Return
/// submits; Option-Return and Shift-Return insert a newline. Reports the
/// height it wants through `height` (the host frames it to that), and its
/// focus through `focused` (the host's accent border).
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var font: NSFont = .systemFont(ofSize: 13.5)
    var lineSpacing: CGFloat = 3
    var maxLines: Int = 12
    var disabled = false
    /// Take the keyboard when the view lands in its window — if nothing
    /// more specific than an ancestor holds it (a search field elsewhere
    /// in the window keeps it).
    var autofocus = false
    @Binding var height: CGFloat
    @Binding var focused: Bool
    var onKey: ((ComposerKey) -> Bool)? = nil
    var onSubmit: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let textView = ComposerNSTextView(font: font, lineSpacing: lineSpacing)
        textView.delegate = coordinator
        textView.placeholder = placeholder
        textView.isEditable = !disabled
        textView.string = text
        textView.onKey = { [weak coordinator] key in coordinator?.parent.onKey?(key) ?? false }
        textView.onSubmit = { [weak coordinator] in coordinator?.parent.onSubmit() }
        textView.onFocusChange = { [weak coordinator] focused in coordinator?.setFocused(focused) }
        let scroll = ComposerScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.verticalScrollElasticity = .none
        // A new width (a pane opened or closed beside the chat): the
        // container has already tracked it; the height may now differ.
        scroll.onLayout = { [weak coordinator] in coordinator?.remeasure() }
        scroll.onAttach = { [weak coordinator] in coordinator?.focusIfFree() }
        coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let textView = coordinator.textView else { return }
        textView.placeholder = placeholder
        textView.isEditable = !disabled
        // A programmatic change (the palette completing a command, a send
        // clearing the field) — never an echo of what was just typed.
        if !coordinator.pushingText, textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            coordinator.remeasure()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: ComposerNSTextView?
        /// Set while the typed text is pushed to the binding, so the update
        /// pass that follows doesn't write it back into the view.
        var pushingText = false

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            pushingText = true
            parent.text = textView.string
            pushingText = false
            remeasure()
        }

        func setFocused(_ focused: Bool) {
            guard parent.focused != focused else { return }
            parent.focused = focused
        }

        private var focusedOnAttach = false

        /// First time in a window, with `autofocus`: take the keyboard
        /// unless a view that isn't one of our ancestors has it. Deferred a
        /// turn so the host's own first-responder pass has run.
        func focusIfFree() {
            guard parent.autofocus, !focusedOnAttach, let textView, textView.window != nil else { return }
            focusedOnAttach = true
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let window = textView.window else { return }
                let free: Bool
                switch window.firstResponder {
                case nil: free = true
                case let w as NSWindow: free = w === window
                case let v as NSView: free = textView.isDescendant(of: v)
                default: free = false
                }
                if free { window.makeFirstResponder(textView) }
            }
        }

        /// The height the text wants at the current width: one line at
        /// least, `maxLines` at most. Pushed to the binding when it moves —
        /// off the current pass, since layout can land mid-update.
        func remeasure() {
            guard let textView, let layout = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layout.ensureLayout(for: container)
            let line = layout.defaultLineHeight(for: parent.font) + parent.lineSpacing
            let used = layout.usedRect(for: container).height
            let wanted = ceil(min(max(used, line), line * CGFloat(parent.maxLines))
                              + textView.textContainerInset.height * 2)
            guard abs(wanted - parent.height) > 0.5 else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, abs(wanted - self.parent.height) > 0.5 else { return }
                self.parent.height = wanted
            }
        }
    }
}

/// The scroll view around the composer's text: tells the coordinator when
/// it was laid out, which is when its width may have changed.
final class ComposerScrollView: NSScrollView {
    var onLayout: () -> Void = {}
    var onAttach: () -> Void = {}
    override func layout() {
        super.layout()
        onLayout()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onAttach() }
    }
}

/// Plain-text editing tuned for prompts: no smart quotes or dashes (code
/// goes through here), a placeholder while empty, and the key routing the
/// composer's contract asks for.
final class ComposerNSTextView: NSTextView {
    var placeholder = "" { didSet { needsDisplay = true } }
    var onKey: ((ComposerKey) -> Bool)?
    var onSubmit: () -> Void = {}
    var onFocusChange: (Bool) -> Void = { _ in }

    init(font: NSFont, lineSpacing: CGFloat) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        self.font = font
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        defaultParagraphStyle = style
        typingAttributes = [.font: font, .paragraphStyle: style, .foregroundColor: NSColor.labelColor]
        textColor = .labelColor
        drawsBackground = false
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFontPanel = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isContinuousSpellCheckingEnabled = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainerInset = NSSize(width: 0, height: 2)
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, let font else { return }
        let origin = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0),
                             y: textContainerOrigin.y)
        (placeholder as NSString).draw(
            at: origin,
            withAttributes: [.font: font, .foregroundColor: NSColor.placeholderTextColor])
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange(false) }
        return ok
    }

    override func doCommand(by selector: Selector) {
        switch selector {
        case #selector(insertNewline(_:)):
            if onKey?(.enter) == true { return }
            onSubmit()
        case #selector(insertNewlineIgnoringFieldEditor(_:)), #selector(insertLineBreak(_:)):
            insertText("\n", replacementRange: selectedRange())
        case #selector(moveUp(_:)):
            if onKey?(.up) == true { return }
            super.doCommand(by: selector)
        case #selector(moveDown(_:)):
            if onKey?(.down) == true { return }
            super.doCommand(by: selector)
        case #selector(insertTab(_:)):
            if onKey?(.tab) == true { return }
            window?.selectNextKeyView(nil)
        case #selector(insertBacktab(_:)):
            window?.selectPreviousKeyView(nil)
        case #selector(cancelOperation(_:)):
            if onKey?(.escape) == true { return }
            super.doCommand(by: selector)
        default:
            super.doCommand(by: selector)
        }
    }
}
#endif
