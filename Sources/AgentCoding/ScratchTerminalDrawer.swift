import AppKit
import SwiftUI

// MARK: - The chat's scratch terminal (/term)
//
// A shell of its own in the session's folder, on the same machine, a
// keystroke away from the conversation: `/term` in the composer (or ⌃`)
// slides it up above the composer; ⌃` or the chevron tucks it away with the
// shell still running (its own guest tmux session — never a tab, never a
// session); ✕ or `exit` ends it. The height is the user's, remembered.

struct ScratchTerminalDrawer: View {
    @ObservedObject var model: BeautifiedSessionModel
    /// The tallest it may grow in this chat.
    let maxHeight: CGFloat
    let onHide: () -> Void

    @AppStorage("chat.scratchTerminalHeight") private var storedHeight: Double = 280
    @State private var dragBase: Double?
    @State private var grabHover = false
    @State private var surface: NSView?

    static let minHeight: Double = 140

    private var height: CGFloat {
        CGFloat(min(max(storedHeight, Self.minHeight), Double(maxHeight)))
    }

    private var folder: String {
        prettyGuestPath(SessionHome.guestPath(model.currentSession?()?.cwd ?? "~"))
    }

    var body: some View {
        VStack(spacing: 0) {
            grabber
            header
            content
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08)))
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.09)))
        .shadow(color: .black.opacity(0.14), radius: 16, y: 4)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .onAppear { surface = model.scratchTerminal?() }
    }

    /// Drag to resize — up grows it.
    private var grabber: some View {
        Capsule()
            .fill(Color.primary.opacity(grabHover || dragBase != nil ? 0.32 : 0.16))
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity)
            .frame(height: 13)
            .contentShape(Rectangle())
            .onHover { inside in
                grabHover = inside
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in
                    let base = dragBase ?? Double(height)
                    dragBase = base
                    storedHeight = min(max(base - Double(v.translation.height), Self.minHeight), Double(maxHeight))
                }
                .onEnded { _ in dragBase = nil })
            .help(NSLocalizedString("Drag to resize", comment: "scratch terminal"))
    }

    private var header: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(model.accent.gradient)
                Image(systemName: "terminal.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 22, height: 22)
            Text(NSLocalizedString("Terminal", comment: "scratch terminal"))
                .font(.system(size: 12.5, weight: .semibold))
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 9.5))
                Text(folder)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .help(folder)
            Spacer(minLength: 8)
            Keycap(text: "⌃`")
            DrawerButton(symbol: "chevron.down",
                         help: NSLocalizedString("Hide — the shell keeps running (⌃`)", comment: "scratch terminal"),
                         action: onHide)
            DrawerButton(symbol: "xmark",
                         help: NSLocalizedString("Close the terminal (ends the shell)", comment: "scratch terminal"),
                         action: { model.closeTerminal() })
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder private var content: some View {
        if let surface {
            InlineTerminalView(terminal: surface)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 20))
                    .foregroundStyle(.tertiary)
                Text(NSLocalizedString("The terminal isn't available right now.", comment: "scratch terminal"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.04))
        }
    }
}

private struct Keycap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.10)))
    }
}

private struct DrawerButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.10 : 0.0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// ⌃` for the chat whose keys these are: a local key monitor that acts only
/// when the focused view sits inside this chat's frame (a room shows several
/// chats in one window — only the one being typed into answers).
@MainActor
final class ChatTerminalHotkey {
    let anchor = ChatFrameAnchor.Box()
    private var monitor: Any?

    /// `action` returns whether it handled the keystroke.
    func install(_ action: @escaping () -> Bool) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            // ` by character (any layout), or the US grave key's code.
            guard e.keyCode == 50 || e.charactersIgnoringModifiers == "`",
                  e.modifierFlags.intersection([.control, .command, .option, .shift]) == .control,
                  let self, self.focusIsInside(e.window) else { return e }
            return action() ? nil : e
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func focusIsInside(_ window: NSWindow?) -> Bool {
        guard let a = anchor.view, let w = a.window, window === w,
              let r = w.firstResponder as? NSView, r.window === w else { return false }
        let frame = a.convert(a.bounds, to: nil)
        let rf = r.convert(r.bounds, to: nil)
        return frame.contains(CGPoint(x: rf.midX, y: rf.midY))
    }

    /// Back to the composer: the editable text view inside this chat.
    func focusComposer() {
        DispatchQueue.main.async { [weak self] in
            guard let a = self?.anchor.view, let w = a.window, let root = w.contentView else { return }
            let frame = a.convert(a.bounds, to: nil)
            func find(_ v: NSView) -> NSTextView? {
                if let t = v as? NSTextView, t.isEditable, !t.isHiddenOrHasHiddenAncestor {
                    let f = t.convert(t.bounds, to: nil)
                    if frame.contains(CGPoint(x: f.midX, y: f.midY)) { return t }
                }
                for s in v.subviews { if let t = find(s) { return t } }
                return nil
            }
            if let t = find(root) { w.makeFirstResponder(t) }
        }
    }
}

/// An inert view spanning the chat, so the hotkey knows its frame.
struct ChatFrameAnchor: NSViewRepresentable {
    final class Box { weak var view: NSView? }
    let box: Box

    private final class Inert: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSView {
        let v = Inert()
        box.view = v
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) { box.view = nsView }
}

// MARK: - Offline render (bromure-ac __shot-term <out.png> [--dark])

extension ScratchTerminalDrawer {
    /// The drawer in a chat, a stand-in where the live surface goes (no VM
    /// offline), rendered to a PNG for a look at the design.
    static func renderSnapshot(to path: String, dark: Bool) -> Never {
        MainActor.assumeIsolated {
            final class Provider: BeautifiedTranscriptProvider {
                var accent: Color { Color(red: 0.36, green: 0.42, blue: 0.95) }
                func activeTabIndex() -> Int? { 0 }
                func execGuest(_ command: String, timeout: Int) async -> String? { nil }
                func isWorking() -> Bool { false }
                func guestFileOp(_ op: [String: Any]) async -> [String: Any]? { nil }
            }
            final class FakeTerminal: NSView {
                override var isFlipped: Bool { true }
                override func draw(_ dirtyRect: NSRect) {
                    NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.13, alpha: 1).setFill()
                    bounds.fill()
                    let font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
                    let lines: [(String, NSColor)] = [
                        ("ubuntu@payments:~/payments-api$ git status -sb", .white),
                        ("## main...origin/main", NSColor.systemGreen),
                        (" M src/server.ts", NSColor.systemRed),
                        ("?? src/retry.ts", NSColor.systemRed),
                        ("ubuntu@payments:~/payments-api$ npm test -- --watch=false", .white),
                        ("  PASS  test/retry.test.ts (1.2 s)", NSColor.systemGreen),
                        ("  Tests: 14 passed, 14 total", .lightGray),
                        ("ubuntu@payments:~/payments-api$ ▋", .white),
                    ]
                    for (i, l) in lines.enumerated() {
                        (l.0 as NSString).draw(at: NSPoint(x: 12, y: 10 + CGFloat(i) * 18),
                                               withAttributes: [.font: font, .foregroundColor: l.1])
                    }
                }
            }
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let m = BeautifiedSessionModel(provider: Provider())
            let fake = FakeTerminal()
            m.scratchTerminal = { fake }
            m.showTerminal()
            let content = VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(verbatim: "Retries now back off exponentially, capped at 30 s, and the flaky test is fixed. Want me to open a pull request?")
                        .font(.system(size: 13.5))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                ScratchTerminalDrawer(model: m, maxHeight: 400, onHide: {})
                Divider().opacity(0.5)
                ChatComposer(placeholder: "Message Claude Code… (or drop files)",
                             text: .constant(""), accent: m.accent, onSend: {})
                    .padding(.horizontal, 12).padding(.vertical, 10)
            }
            .frame(width: 820, height: 560)
            .background(Color.platformWindowBackground)
            let host = NSHostingView(rootView: content)
            host.frame = NSRect(x: 0, y: 0, width: 820, height: 560)
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            let until = Date().addingTimeInterval(2.0)
            while Date() < until {
                if let ev = app.nextEvent(matching: .any, until: Date().addingTimeInterval(0.02),
                                          inMode: .default, dequeue: true) { app.sendEvent(ev) }
                app.updateWindows()
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    print("png=\(path)")
                }
            }
            exit(0)
        }
    }
}
