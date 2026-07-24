import Foundation
import SwiftUI
import UIKit
import SwiftTerm

extension Notification.Name {
    /// Posted when the app returns to the foreground after being backgrounded
    /// long enough that its sockets likely died — drives an immediate reconnect
    /// of the terminals and the mirror poll instead of waiting for a TCP
    /// timeout on a blocking read.
    static let bromureDidForeground = Notification.Name("io.bromure.remote.didForeground")
    /// Posted (userInfo `["host": UUID]`) when a workspace terminal's exec
    /// stream drops or comes back — most often a guest `reboot`/`shutdown -r`,
    /// which leaves the HOST reachable (so the mirror poll keeps succeeding and
    /// never flags a reconnect) while the guest's tmux is torn down and rebuilt
    /// with a fresh, usually smaller, window set. Drives an immediate roster
    /// re-poll so the tab strip and the attached sessions reconcile against the
    /// new window set instead of the pre-reboot one — otherwise the phone keeps
    /// showing windows that no longer exist AND a surface stays attached to a
    /// now-dead window index that silently swallows keystrokes.
    static let bromureTerminalLinkChanged = Notification.Name("io.bromure.remote.terminalLinkChanged")
}
#if canImport(Darwin)
import Darwin
#endif

// MARK: - In-process terminal attach (iOS)
//
// The iOS replacement for the macOS libghostty surface + `__attach-window`
// child process. There is no child process and no pty on iOS: this runs the
// framed PTY pump (the exact `[type][len]` codec in PTYFrame, ControlClient.swift)
// IN-PROCESS, feeding a SwiftTerm `TerminalView` directly. Output frames →
// `terminal.feed`; SwiftTerm keystrokes/resize → data/resize frames back over
// the tunnel. Consent is `guiConsent: true` (surfaces as a /state decision
// prompt), so nothing is ever drawn into this terminal by the server.

/// Drives one attached terminal session: opens the interactive exec stream over
/// the tunnel, pumps frames to/from a SwiftTerm view, and reconnects with
/// backoff when the stream ends while the view is still on screen (a VM reboot,
/// a dropped link). Mirrors `TerminalSessionController`'s reconnect logic, minus
/// the Ghostty/child-process machinery.
///
/// Concurrency: the pump runs on a background `Thread`; the fd + its lifecycle
/// flags are plain lock-guarded state (NOT actor-isolated) so the pump can
/// touch them directly. Only the published UI state is hopped to the main actor.
final class AttachSession: ObservableObject, @unchecked Sendable {
    let host: RemoteHost
    let vmID: String
    let windowIndex: Int

    /// Published so the SwiftUI veil can show "reconnecting…". Written on main.
    @Published private(set) var connected = false
    /// True once the stream has connected at least once, so the veil can say
    /// "Reconnecting…" on a drop vs "Connecting…" on first open.
    @Published private(set) var everConnected = false
    @Published private(set) var lastError: String?

    /// Bound once from the SwiftUI representable; read on main to feed output.
    private weak var terminalView: TerminalView?

    private let stateLock = NSLock()
    private var streamFD: Int32 = -1
    /// A pump loop is live (running or between reconnect attempts). Guards
    /// against `attach` starting a second one — see `attach`.
    private var pumping = false
    private var stopped = false
    private var reattachDelay: TimeInterval = 1.0
    private var lastConnectAt = Date.distantPast
    /// Last-known terminal geometry, captured on the main actor and read by the
    /// pump thread on connect (SwiftTerm's `TerminalView` is main-actor bound).
    private var cols = 80
    private var rows = 24
    /// Serializes writes to the stream fd (keystrokes/resize vs. the pump's EOF).
    private let writeLock = NSLock()

    private var fgObserver: NSObjectProtocol?
    private var pathObserver: NSObjectProtocol?

    init(host: RemoteHost, vmID: String, windowIndex: Int) {
        self.host = host
        self.vmID = vmID
        self.windowIndex = windowIndex
        // Reconnect the moment the app comes back to the foreground.
        fgObserver = NotificationCenter.default.addObserver(
            forName: .bromureDidForeground, object: nil, queue: .main) { [weak self] _ in
            self?.reconnectNow()
        }
        // …and the moment the network path changes (WiFi switch, VPN drop): the
        // stream's socket is bound to the vanished route, so reconnect at once.
        pathObserver = NotificationCenter.default.addObserver(
            forName: .bromureP2PPathChanged, object: nil, queue: .main) { [weak self] _ in
            self?.reconnectNow()
        }
    }

    deinit {
        if let fgObserver { NotificationCenter.default.removeObserver(fgObserver) }
        if let pathObserver { NotificationCenter.default.removeObserver(pathObserver) }
    }

    /// Force the pump to reconnect now. After the app was suspended the socket
    /// may be dead, but a blocking `read` won't notice until TCP times out —
    /// closing the fd unblocks it, so `onStreamEnded` reattaches immediately.
    /// Also resets the backoff and, if no pump is alive (it died or is asleep
    /// mid-backoff after a long suspension), starts a fresh one — otherwise
    /// coming back into a terminal after a long background just sat there dead.
    func reconnectNow() {
        stateLock.lock()
        let done = stopped
        reattachDelay = 1.0          // don't wait out a grown backoff
        let running = pumping
        let haveView = terminalView != nil
        stateLock.unlock()
        guard !done else { return }
        closeFD()                    // wake a blocked read → reconnect
        if !running && haveView { DispatchQueue.main.async { [weak self] in self?.startPump() } }
    }

    /// Bind the SwiftUI-hosted terminal. Idempotent: if a pump is already
    /// running (the session is cached and reused across view recreations), just
    /// re-point at the new view and force a repaint — do NOT start a second
    /// pump. A second pump would open a second stream and, when either ends,
    /// `closeFD` would clobber `streamFD` to -1, silently dropping every
    /// keystroke (`writeFrame`'s `guard fd >= 0`). That was the "typing goes
    /// nowhere / fd0" bug.
    @MainActor func attach(to view: TerminalView) {
        terminalView = view
        let term = view.getTerminal()
        stateLock.lock()
        cols = term.cols; rows = term.rows; stopped = false
        let running = pumping
        stateLock.unlock()
        if running {
            // Existing pump now feeds this (possibly fresh, blank) view — nudge
            // a resize so tmux repaints the current screen into it.
            resize(cols: term.cols, rows: term.rows)
        } else {
            startPump()
        }
    }

    /// Drop the view binding without touching the stream — the session is cached
    /// and a new view may re-attach. Only clears if `view` is still the bound
    /// one, so a recreate that already re-attached isn't unbound.
    @MainActor func detach(_ view: TerminalView) {
        if terminalView === view { terminalView = nil }
    }

    func stop() {
        stateLock.lock(); stopped = true; pumping = false; stateLock.unlock()
        closeFD()
    }

    // MARK: Input from SwiftTerm (main actor → frames)

    func send(_ data: ArraySlice<UInt8>) {
        writeFrame(PTYFrame.data, Array(data))
    }

    func resize(cols: Int, rows: Int) {
        stateLock.lock(); self.cols = cols; self.rows = rows; stateLock.unlock()
        writeFrame(PTYFrame.resize, PTYFrame.resizePayload(cols: cols, rows: rows))
    }

    private func writeFrame(_ type: UInt8, _ payload: [UInt8]) {
        writeLock.lock(); defer { writeLock.unlock() }
        stateLock.lock(); let fd = streamFD; stateLock.unlock()
        guard fd >= 0 else { return }
        PTYFrame.send(fd, type, payload)
    }

    // MARK: Pump

    private func startPump() {
        stateLock.lock()
        pumping = true
        let sinceLast = Date().timeIntervalSince(lastConnectAt)
        let delay = reattachDelay
        lastConnectAt = Date()
        let c = cols, r = rows
        stateLock.unlock()
        let host = self.host, vmID = self.vmID, win = self.windowIndex
        let t = Thread { [weak self] in
            self?.pumpLoop(host: host, vmID: vmID, window: win, cols: c, rows: r)
        }
        t.stackSize = 1 << 20
        // A quick reconnect spins under backoff so a hard-failing VM doesn't
        // hot-loop; the first attach starts immediately.
        if sinceLast < 0.5 && delay > 1.0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { t.start() }
        } else {
            t.start()
        }
    }

    /// Runs off the main actor: open the stream, then read frames until EOF/exit.
    private func pumpLoop(host: RemoteHost, vmID: String, window: Int, cols: Int, rows: Int) {
        let client = RemoteTransport.client(for: host, interactive: true)
        // Resolve the VM by id like the macOS attachLoop: a booting workspace
        // isn't in /vms yet, so best-effort match and fall back to the raw id.
        var resolvedVM = vmID
        if let vms = (try? client.request("GET", "/vms"))?.json["vms"] as? [[String: Any]],
           let match = vms.first(where: { ($0["id"] as? String) == vmID }) {
            resolvedVM = (match["id"] as? String) ?? vmID
        }
        let body: [String: Any] = ["command": "", "interactive": true,
                                   "cols": cols, "rows": rows,
                                   "view": UUID().uuidString, "window": window,
                                   "guiConsent": true]
        let fd: Int32
        do {
            fd = try client.openStream(
                "POST", "/vms/\(ControlClient.encodeSegment(resolvedVM))/exec", body: body)
        } catch {
            let msg = error.localizedDescription
            DispatchQueue.main.async { [weak self] in self?.onStreamEnded(error: msg) }
            return
        }
        stateLock.lock(); streamFD = fd; stateLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onConnected() }

        var inbuf = [UInt8](); inbuf.reserveCapacity(1 << 16)
        var rbuf = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = rbuf.withUnsafeMutableBufferPointer { Darwin.read(fd, $0.baseAddress!, $0.count) }
            if n <= 0 { break }
            inbuf.append(contentsOf: rbuf[0..<n])
            var out: [UInt8] = []
            var exited = false
            PTYFrame.drain(&inbuf) { type, payload in
                if type == PTYFrame.data, !payload.isEmpty {
                    out.append(contentsOf: payload)
                } else if type == PTYFrame.exit {
                    exited = true
                }
            }
            if !out.isEmpty {
                DispatchQueue.main.async { [weak self] in self?.feed(out) }
            }
            if exited { break }
        }
        closeFD()
        DispatchQueue.main.async { [weak self] in self?.onStreamEnded(error: nil) }
    }

    private func closeFD() {
        stateLock.lock()
        let fd = streamFD
        streamFD = -1
        stateLock.unlock()
        if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
    }

    // MARK: Main-actor callbacks

    @MainActor private func feed(_ bytes: [UInt8]) {
        terminalView?.feed(byteArray: bytes[...])
    }

    @MainActor private func onConnected() {
        let wasReconnect = everConnected   // a drop we just recovered from, not first open
        connected = true
        everConnected = true
        lastError = nil
        stateLock.lock(); reattachDelay = 1.0; stateLock.unlock()
        // Push our current geometry so the guest tmux repaints at our size.
        if let tv = terminalView {
            let term = tv.getTerminal()
            resize(cols: term.cols, rows: term.rows)
        }
        // Came back after a drop (typically a guest reboot): the roster the
        // phone holds is likely stale. Ask the workspace screen to re-poll and
        // reconcile now (see .bromureTerminalLinkChanged).
        if wasReconnect {
            NotificationCenter.default.post(name: .bromureTerminalLinkChanged,
                                            object: nil, userInfo: ["host": host.id])
        }
    }

    @MainActor private func onStreamEnded(error: String?) {
        connected = false
        lastError = error
        // The link just dropped — nudge a roster re-poll so a shrinking window
        // set (a guest reboot closing windows) is noticed promptly rather than
        // on the next lazy tick, and stale windows stop being shown/attached.
        if everConnected {
            NotificationCenter.default.post(name: .bromureTerminalLinkChanged,
                                            object: nil, userInfo: ["host": host.id])
        }
        stateLock.lock()
        let done = stopped
        // Reconnect with capped backoff; a run that lasted a while resets it.
        if Date().timeIntervalSince(lastConnectAt) > 10 { reattachDelay = 1.0 }
        else { reattachDelay = min(reattachDelay * 2, 30) }
        stateLock.unlock()
        // No view bound (mid-recreate) or explicitly stopped → the pump is over.
        // Mark it not-pumping so a later attach starts a fresh one.
        guard !done, terminalView != nil else {
            stateLock.lock(); pumping = false; stateLock.unlock()
            return
        }
        startPump()
    }
}

// MARK: - Terminal surface + reconnect veil

/// The live terminal plus a "Connecting…/Reconnecting…" veil driven by the
/// session's published `connected` state — so returning to a terminal after a
/// dropped link shows an animated status instead of a frozen, dead screen.
struct TerminalSurface: View {
    @ObservedObject var session: AttachSession
    let fontSize: Binding<CGFloat>
    let focusTick: Int
    let isActive: Bool
    let bottomInset: CGFloat

    var body: some View {
        ZStack {
            RemoteTerminalView(session: session, fontSize: fontSize,
                               focusTick: focusTick, isActive: isActive)
                .padding(.bottom, bottomInset)
            if !session.connected {
                ReconnectVeil(text: session.everConnected ? "Reconnecting…" : "Connecting…")
            }
        }
    }
}

/// A translucent status overlay with an animated pulse — the reconnect
/// affordance the terminal was missing.
private struct ReconnectVeil: View {
    let text: String
    @State private var pulse = false
    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 10) {
                ProgressView().tint(.white)
                Text(text).font(.callout.weight(.semibold)).foregroundStyle(.white)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.15)))
            .scaleEffect(pulse ? 1.0 : 0.97)
            .opacity(pulse ? 1.0 : 0.75)
            .padding(.bottom, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.35))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - SwiftUI terminal

/// A SwiftTerm `TerminalView` bridged into SwiftUI, wired to an `AttachSession`.
/// The view owns rendering, scrollback, selection, and IME; the session owns
/// the byte transport. This is the iOS analog of the macOS `TerminalSurfaceView`.
///
/// `interactive` distinguishes the two ways a terminal appears on the phone: a
/// full workspace terminal (keyboard, selection, pinch-to-zoom font) versus a
/// live-but-untouchable grid preview (display only, so a tap falls through to
/// the cell's "focus" navigation instead of moving the cursor).
struct RemoteTerminalView: UIViewRepresentable {
    @ObservedObject var session: AttachSession
    /// When false the surface is a passive preview: no keyboard, no pinch, and
    /// touches pass through so an enclosing button can take the tap.
    var interactive: Bool = true
    /// Live, persisted font size for interactive surfaces; pinch writes here.
    /// Nil for previews, which use `fixedFontSize`.
    var fontSize: Binding<CGFloat>? = nil
    /// The (non-zoomable) point size used when `fontSize` is nil.
    var fixedFontSize: CGFloat = 13
    /// Any change asks the surface to take first responder again. A rotation
    /// dismisses the keyboard and drops focus, and `makeUIView` (where focus is
    /// first requested) does not run again for a view that merely re-laid out.
    var focusTick: Int = 0
    /// The surface the user is actually looking at. Sibling surfaces for the
    /// workspace's other windows stay mounted (so switching back is instant) but
    /// must never hold the keyboard or answer a focus tick — otherwise typing
    /// goes to a terminal that isn't on screen.
    var isActive: Bool = true

    static let minFont: CGFloat = 8
    static let maxFont: CGFloat = 28
    static func monoFont(_ size: CGFloat) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private var currentSize: CGFloat { fontSize?.wrappedValue ?? fixedFontSize }

    func makeCoordinator() -> Coordinator { Coordinator(view: self) }

    func makeUIView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        tv.terminalDelegate = context.coordinator
        tv.backgroundColor = .black
        tv.font = Self.monoFont(currentSize)
        context.coordinator.bind(tv)
        session.attach(to: tv)
        tv.isHidden = interactive && !isActive   // inactive surfaces start ineligible
        if interactive {
            let pinch = UIPinchGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handlePinch(_:)))
            // Never let the pinch swallow a single-finger tap — SwiftTerm's own
            // tap-to-focus (becomeFirstResponder) must keep working.
            pinch.cancelsTouchesInView = false
            pinch.delaysTouchesBegan = false
            tv.addGestureRecognizer(pinch)
            // Focus is driven by updateUIView (which always runs right after
            // this, with justActivated == true), so it grabs the keyboard once
            // the view is actually in the window — not here, where the view has
            // no window yet and becomeFirstResponder would no-op.
        } else {
            // A preview: let taps reach the SwiftUI navigation behind it.
            tv.isUserInteractionEnabled = false
        }
        return tv
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        context.coordinator.parent = self
        let target = Self.monoFont(currentSize)
        if uiView.font.pointSize != target.pointSize { uiView.font = target }
        guard interactive else { return }
        // Hide the UIView itself when inactive — not just via SwiftUI .opacity,
        // which leaves it fully first-responder-eligible. A truly hidden view
        // can't hold or take the keyboard (UIKit refuses becomeFirstResponder),
        // so only the ONE visible surface can ever own it. This is the
        // structural half of the fix.
        if uiView.isHidden == isActive { uiView.isHidden = !isActive }
        if isActive {
            // Auto-focus on an explicit signal only: this surface just became
            // active, or focusTick bumped (tab switch, rotation, reader closed,
            // pane returned). NOT on every render — that would fight SwiftTerm's
            // keyboard-dismiss button, snapping it back the instant it's hidden.
            let c = context.coordinator
            if c.justActivated || c.lastFocusTick != focusTick {
                c.justActivated = false
                c.lastFocusTick = focusTick
                c.keepFocused(uiView)
            }
        } else {
            context.coordinator.justActivated = true   // arm for the next activation
            context.coordinator.stopKeepingFocus()
            if uiView.isFirstResponder { uiView.resignFirstResponder() }
        }
    }

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        // Do NOT stop the session here. It's cached per window and reused across
        // view recreations (the mounted-surface design), so stopping on view
        // teardown killed the live stream — the next keystroke hit a closed
        // socket and was dropped (the "typing does nothing / fd0" bug). Just
        // unbind this view; the cache owns the session's lifecycle (syncMounted
        // prunes and stops a window that actually closed; Close does it too).
        coordinator.session.detach(uiView)
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        var parent: RemoteTerminalView
        var session: AttachSession { parent.session }
        private weak var view: TerminalView?
        private var pinchBaseSize: CGFloat = 13
        /// Supersedes stale focus loops. Every `keepFocused`/`stopKeepingFocus`
        /// bumps it; an in-flight retry whose captured generation no longer
        /// matches stops — so a loop from a PREVIOUS visit can't fire
        /// `becomeFirstResponder()` on this now-hidden surface and steal the
        /// keyboard from the visible one (surfaces stay mounted).
        private var focusGen = 0
        /// Last focusTick acted on — a change means an explicit "take focus now".
        var lastFocusTick = 0
        /// True until this surface's first focus attempt after becoming active,
        /// so a fresh activation always (re)grabs the keyboard even if focusTick
        /// didn't change. Reset to true whenever the surface goes inactive.
        var justActivated = true

        init(view: RemoteTerminalView) { self.parent = view }
        func bind(_ v: TerminalView) { view = v }

        /// Make this (active, visible) surface first responder so the terminal
        /// is ready to type into without a tap. A no-op once it holds focus. The
        /// view may not be in the window yet at call time (mid tab-switch), so
        /// poll a few times until becomeFirstResponder lands.
        func keepFocused(_ v: TerminalView) {
            if v.isFirstResponder { return }
            focusGen &+= 1
            retryFocus(v, gen: focusGen, attempts: 20)
        }

        /// Cancel any pending focus retry (this surface is no longer active).
        func stopKeepingFocus() { focusGen &+= 1 }

        private func retryFocus(_ v: TerminalView, gen: Int, attempts: Int) {
            guard attempts > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak v, weak self] in
                guard let self, let v, gen == self.focusGen else { return }
                // Superseded (went inactive) or hidden → stop; a hidden terminal
                // must never claim the keyboard.
                if v.isHidden { return }
                if v.window != nil, v.becomeFirstResponder() { return }
                self.retryFocus(v, gen: gen, attempts: attempts - 1)
            }
        }

        /// Pinch scales the font live and persists it through the binding, so
        /// the size sticks across tab switches and relaunches.
        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            guard let binding = parent.fontSize else { return }
            switch g.state {
            case .began:
                pinchBaseSize = binding.wrappedValue
            case .changed, .ended:
                let scaled = (pinchBaseSize * g.scale).rounded()
                let clamped = min(RemoteTerminalView.maxFont,
                                  max(RemoteTerminalView.minFont, scaled))
                view?.font = RemoteTerminalView.monoFont(clamped)
                if clamped != binding.wrappedValue { binding.wrappedValue = clamped }
            default:
                break
            }
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            session.send(data)
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            session.resize(cols: newCols, rows: newRows)
        }

        // Unused delegate hooks — the guest owns title/dir/scroll semantics.
        func scrolled(source: TerminalView, position: Double) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func clipboardCopy(source: TerminalView, content: Data) {
            if let s = String(data: content, encoding: .utf8) {
                platformCopyToPasteboard(s)
            }
        }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
        func bell(source: TerminalView) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    }
}
