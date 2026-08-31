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
    /// Fat-client: when set, surfaces attach to a workspace on a REMOTE
    /// bromure-ac over SSH (`__attach-window --remote <hostID> …`) instead of
    /// the local control socket. Everything else is identical.
    private let remoteHost: UUID?

    private var views: [Int: TerminalSurfaceView] = [:]
    private var reattachDelays: [Int: TimeInterval] = [:]
    private var observers: [NSObjectProtocol] = []

    /// Stable per-controller token: window `i`'s guest tmux view session is
    /// named `view-v<token>w<i>`, the same across reattaches, so the
    /// size-authority pass below can address each surface's tmux client
    /// from the host.
    private let viewToken = UUID().uuidString.prefix(8).lowercased()
    private var authorityTimer: Timer?
    private var authorityAssertScheduled = false
    /// Last pushed authority vector + when — the grid/pane refresh loops call
    /// `view(forWindow:)` every poll, so unchanged states are only re-pushed
    /// by the (forced) periodic tick, not per poll.
    private var lastAuthority: [Int: Bool] = [:]
    private var lastAuthorityPush = Date.distantPast

    /// Called when a surface's title changes (window index, title) — the
    /// pane/grid chrome subscribes.
    var onTitleChange: ((Int, String) -> Void)?

    init(profile: Profile, remoteHost: UUID? = nil) {
        self.vmID = profile.id.uuidString
        self.profile = profile
        self.remoteHost = remoteHost
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
        startSizeAuthorityEngineIfNeeded()
        if let existing = views[index] {
            // A cached surface being (re)mounted — e.g. a tab switch moving it
            // into the key window — generates no window/app notification, so
            // re-evaluate size authority here.
            scheduleSizeAuthorityAssert()
            return existing
        }
        guard GhosttyRuntime.shared.start() else { return nil }
        guard let view = TerminalSurfaceView(command: attachCommand(window: index),
                                             windowIndex: index,
                                             profileID: profile.id,
                                             remoteHost: remoteHost) else { return nil }
        if let surface = view.surface {
            GhosttyRuntime.shared.apply(profile: profile, to: surface)
        }
        views[index] = view
        // The guest attach lands a beat later (vsock, or SSH for the fat
        // client) — flag the fresh tmux client as soon as it exists; the
        // periodic tick heals anything these one-shots miss.
        for delay: TimeInterval in [1.5, 4, 10] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.assertSizeAuthority(force: true)
            }
        }
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
        authorityTimer?.invalidate()
        authorityTimer = nil
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
    ///
    /// A PEER (P2P) host needs extra plumbing: it is never persisted to
    /// hosts.json, and its loopback endpoint (the P2P shim) is owned by THIS
    /// process's broker — a subprocess can resolve neither. So the peer
    /// identity, live endpoint and login user ride the command line. Queried
    /// per spawn: a reattach after the path self-heals picks up the fresh
    /// shim port.
    func attachCommand(window: Int) -> String {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let viewArg = " --view '\(viewName(forWindow: window))'"
        guard let remoteHost else {
            return "'\(exe)' __attach-window\(viewArg) '\(vmID)' \(window)"
        }
        var cmd = "'\(exe)' __attach-window --remote '\(remoteHost.uuidString)'" + viewArg
        if let host = RemoteHostController.liveHosts[remoteHost],
           let pid = host.peerDeviceID,
           let ep = P2PBroker.shared.cachedEndpoint(forPeer: pid) {
            cmd += " --remote-peer '\(pid)' --remote-endpoint '\(ep.host):\(ep.port)'"
                + " --remote-user '\(host.user)'"
        }
        cmd += " '\(vmID)' \(window)"
        return cmd
    }

    // MARK: Size authority

    // Only the surface the user is actually working in may drive the shared
    // tmux window's size. Every native surface attaches its tmux client with
    // the `ignore-size` flag (see `sizePassive` in __attach-window); this
    // pass grants `!ignore-size` to views that are in the key window of the
    // active app on a machine with recent local input, and re-flags the rest
    // passive. tmux then sizes each shared window to the one unflagged
    // client, so a relayout or reattach on the idle side (native window vs
    // fat client) can never resize the window out from under the active one.
    //
    // Fail-safe by construction: when NO unflagged client exists (both sides
    // idle, or the exec channel is down), tmux ignores the flag entirely
    // (resize.c ignore_client_size) and behaves exactly as before. The pass
    // is level-based — desired state is re-asserted every tick rather than
    // edge-triggered — so missed grants and freshly reattached clients heal
    // within one tick.

    /// The guest tmux session name for a window's surface (matches the
    /// sanitization in bromure-agentd's `_view_attach_command`).
    private func viewName(forWindow index: Int) -> String { "v\(viewToken)w\(index)" }

    private func startSizeAuthorityEngineIfNeeded() {
        guard authorityTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            Task { @MainActor in self.assertSizeAuthority(force: true) }
        }
        timer.tolerance = 5
        authorityTimer = timer
        let center = NotificationCenter.default
        for name: Notification.Name in [NSWindow.didBecomeKeyNotification,
                                        NSWindow.didResignKeyNotification,
                                        NSApplication.didBecomeActiveNotification,
                                        NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor in self?.scheduleSizeAuthorityAssert() }
            })
        }
    }

    /// Coalesce event bursts (key-window + app-active fire together) into one
    /// pass shortly after things settle.
    private func scheduleSizeAuthorityAssert() {
        guard !authorityAssertScheduled else { return }
        authorityAssertScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            self.authorityAssertScheduled = false
            self.assertSizeAuthority()
        }
    }

    /// Seconds since any keyboard/mouse input on THIS Mac. An unattended
    /// server keeps its session window key and its app active, so key-window
    /// alone can't mean "actively used" — require a human to have touched the
    /// machine recently.
    private static func secondsSinceLocalInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.hidSystemState,
                                                eventType: CGEventType(rawValue: ~0)!)
    }

    private func isActivelyUsed(_ view: TerminalSurfaceView) -> Bool {
        guard NSApp.isActive, let win = view.window, win.isKeyWindow else { return false }
        return Self.secondsSinceLocalInput() < 180
    }

    /// `force` (the periodic tick + post-attach one-shots) re-pushes even an
    /// unchanged vector, healing reattached clients that came up with stale
    /// flags; unforced calls are cheap no-ops unless the desired state moved.
    private func assertSizeAuthority(force: Bool = false) {
        guard !views.isEmpty else { return }
        let desired = views.mapValues { isActivelyUsed($0) }
        if !force, desired == lastAuthority,
           Date().timeIntervalSince(lastAuthorityPush) < 15 { return }
        lastAuthority = desired
        lastAuthorityPush = Date()
        var parts: [String] = []
        for index in views.keys {
            let session = "view-\(viewName(forWindow: index))"
            if desired[index] == true {
                // Grant, then a same-size `refresh-client -C`: setting client
                // flags alone doesn't run tmux's recalculate_sizes, -C does —
                // so the window snaps to this client without waiting for a
                // real resize or keystroke.
                parts.append(
                    "set -- $(tmux list-clients -t '\(session)'"
                    + " -F '#{client_tty} #{client_width} #{client_height}'"
                    + " 2>/dev/null | head -1)"
                    + "; [ -n \"$1\" ] && tmux refresh-client -t \"$1\" -f '!ignore-size'"
                    + " && tmux refresh-client -t \"$1\" -C \"${2}x${3}\"")
            } else {
                parts.append(
                    "set -- $(tmux list-clients -t '\(session)' -F '#{client_tty}'"
                    + " 2>/dev/null | head -1)"
                    + "; [ -n \"$1\" ] && tmux refresh-client -t \"$1\" -f ignore-size")
            }
        }
        runInGuest(parts.joined(separator: "; ") + "; true")
    }

    /// Run a shell command in the workspace's guest over this side's own
    /// channel: the vsock shell bridge locally, POST /vms/{id}/exec over the
    /// tunnel for a fat-client mirror. Fire-and-forget — the level-based
    /// re-assert makes lost commands harmless.
    private func runInGuest(_ command: String) {
        if let remoteHost {
            let vmID = self.vmID
            let live = RemoteHostController.liveHosts[remoteHost]
            let hostID = remoteHost
            Task.detached(priority: .utility) {
                let client: ControlClient? = live.map { RemoteTransport.client(for: $0) }
                    ?? RemoteTransport.client(hostID: hostID)
                _ = try? client?.request(
                    "POST", "/vms/\(ControlClient.encodeSegment(vmID))/exec",
                    body: ["command": command, "timeout": 10])
            }
        } else if let delegate = NSApp.delegate as? ACAppDelegate {
            let pid = profile.id
            Task { _ = try? await delegate.guestExec(profileID: pid, command: command, timeout: 10) }
        }
    }
}
