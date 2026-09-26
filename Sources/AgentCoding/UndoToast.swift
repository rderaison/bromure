#if os(macOS)
import AppKit
import SwiftUI

// MARK: - Undo toast
//
// Putting a session away, ending it, taking it out of a room — done at once,
// no dialog, with a few seconds to take it back: "Archived “Fix login” ·
// Undo" floats at the bottom of the window. A new toast replaces the last.

struct UndoToastView: View {
    let message: String
    /// nil: nothing to take back — just the word that it's done.
    let onUndo: (() -> Void)?
    let onClose: () -> Void
    @State private var shown = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(message)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            if let onUndo {
                Button {
                    onUndo()
                    onClose()
                } label: {
                    Text(NSLocalizedString("Undo", comment: "undo toast"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("z", modifiers: .command)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
        .scaleEffect(shown ? 1 : 0.94)
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { shown = true } }
    }
}

/// Shows one toast at a time at the bottom of a window.
@MainActor
final class UndoToastHost {
    private var host: NSView?
    private var timer: Timer?
    private weak var window: NSWindow?

    init(window: NSWindow) { self.window = window }

    func show(_ message: String, undo: (() -> Void)?) {
        close()
        guard let content = window?.contentView else { return }
        let view = NSHostingView(rootView: UndoToastView(message: message, onUndo: undo,
                                                          onClose: { [weak self] in self?.close() }))
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -96),
            view.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -80),
        ])
        host = view
        timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        timer?.invalidate()
        timer = nil
        host?.removeFromSuperview()
        host = nil
    }

    /// "“Fix the login loop”" — a title short enough for a toast.
    static func quoted(_ title: String) -> String {
        let t = title.count > 40 ? String(title.prefix(40)) + "…" : title
        return "“" + t + "”"
    }
}
#endif
