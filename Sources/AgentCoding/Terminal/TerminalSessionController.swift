import AppKit
import GhosttyKit

/// Owns the native terminal surfaces for one VM session: (window index) →
/// TerminalSurfaceView, with reattach-on-exit.
///
/// The surface's child is `bromure-ac __attach-window <vm> <idx>` — a byte
/// pump to a grouped tmux client in the guest — so a dead child never means
/// lost state: tmux holds the real windows. A child exit here is a transport
/// event (VM reboot, vsock drop, tmux kill), answered with a respawned
/// surface after a backoff.
@MainActor
final class TerminalSessionController {
    /// Profile/VM this controller serves (the id `__attach-window` resolves).
    let vmID: String
    /// Appearance source for the surfaces; refreshed on profile save.
    private var profile: Profile

    private var views: [Int: TerminalSurfaceView] = [:]
    private var reattachDelays: [Int: TimeInterval] = [:]
    private var observers: [NSObjectProtocol] = []

    /// Called when a surface's title changes (window index, title) — the
    /// pane/grid chrome subscribes.
    var onTitleChange: ((Int, String) -> Void)?

    init(profile: Profile) {
        self.vmID = profile.id.uuidString
        self.profile = profile
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: GhosttyRuntime.childExitedNotification, object: nil,
            queue: .main) { [weak self] note in
            guard let view = note.object as? TerminalSurfaceView else { return }
            Task { @MainActor in self?.childExited(view) }
        })
        observers.append(center.addObserver(
            forName: GhosttyRuntime.closeSurfaceNotification, object: nil,
            queue: .main) { [weak self] note in
            guard let view = note.object as? TerminalSurfaceView else { return }
            Task { @MainActor in self?.remove(view: view) }
        })
        observers.append(center.addObserver(
            forName: GhosttyRuntime.titleChangedNotification, object: nil,
            queue: .main) { [weak self] note in
            guard let view = note.object as? TerminalSurfaceView,
                  let title = note.userInfo?["title"] as? String else { return }
            Task { @MainActor in
                guard let self, self.views[view.windowIndex] === view else { return }
                self.onTitleChange?(view.windowIndex, title)
            }
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// The surface view for a tmux window, creating (and attaching) it on
    /// first use. Returns nil when libghostty is unavailable — callers show
    /// the framebuffer instead.
    func view(forWindow index: Int) -> TerminalSurfaceView? {
        if let existing = views[index] { return existing }
        guard GhosttyRuntime.shared.start() else { return nil }
        guard let view = TerminalSurfaceView(command: Self.attachCommand(vmID: vmID, window: index),
                                             windowIndex: index,
                                             profileID: profile.id) else { return nil }
        if let surface = view.surface {
            GhosttyRuntime.shared.apply(profile: profile, to: surface)
        }
        views[index] = view
        return view
    }

    /// Re-apply appearance after a profile save (font, colors, cursor
    /// shape/blink) to every live surface.
    func applyProfile(_ newProfile: Profile) {
        profile = newProfile
        for (_, view) in views {
            guard let surface = view.surface else { continue }
            GhosttyRuntime.shared.apply(profile: newProfile, to: surface)
        }
    }

    /// Tear down every surface (VM shutdown / pane close).
    func retireAll() {
        for (_, view) in views {
            view.removeFromSuperview()
            view.retire()
        }
        views.removeAll()
        reattachDelays.removeAll()
    }

    /// Drop a single window's surface (tab closed in tmux).
    func retire(window index: Int) {
        guard let view = views.removeValue(forKey: index) else { return }
        view.removeFromSuperview()
        view.retire()
        reattachDelays.removeValue(forKey: index)
    }

    /// Roster reconciliation: retire surfaces whose tmux window is gone.
    func retire(windowsNotIn live: Set<Int>) {
        for index in views.keys where !live.contains(index) {
            retire(window: index)
        }
    }

    // MARK: Reattach

    private func childExited(_ view: TerminalSurfaceView) {
        guard views[view.windowIndex] === view else { return }
        let index = view.windowIndex

        // Only reattach surfaces someone is looking at; a hidden view
        // reattaches lazily on next `view(forWindow:)`.
        let visible = view.window != nil
        let superview = view.superview
        let frame = view.frame

        views.removeValue(forKey: index)
        view.removeFromSuperview()
        view.retire()

        guard visible, let superview else { return }
        let delay = reattachDelays[index] ?? 1.0
        reattachDelays[index] = min(delay * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak superview] in
            guard let self, let superview else { return }
            guard let fresh = self.view(forWindow: index) else { return }
            fresh.frame = frame
            fresh.autoresizingMask = [.width, .height]
            superview.addSubview(fresh)
            // A successful session (child stays up 10s) resets the backoff.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak fresh] in
                guard let self, let fresh, !fresh.processExited else { return }
                self.reattachDelays[index] = 1.0
            }
        }
    }

    private func remove(view: TerminalSurfaceView) {
        guard views[view.windowIndex] === view else { return }
        views.removeValue(forKey: view.windowIndex)
        view.removeFromSuperview()
        view.retire()
    }

    /// The surface child command. Quoted for ghostty's shell-words parsing —
    /// the app path contains spaces ("Bromure Agentic Coding.app").
    static func attachCommand(vmID: String, window: Int) -> String {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        return "'\(exe)' __attach-window '\(vmID)' \(window)"
    }
}
