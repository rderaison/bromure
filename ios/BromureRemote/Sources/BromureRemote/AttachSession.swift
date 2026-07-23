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
    @Published private(set) var lastError: String?

    /// Bound once from the SwiftUI representable; read on main to feed output.
    private weak var terminalView: TerminalView?

    private let stateLock = NSLock()
    private var streamFD: Int32 = -1
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

    init(host: RemoteHost, vmID: String, windowIndex: Int) {
        self.host = host
        self.vmID = vmID
        self.windowIndex = windowIndex
        // Reconnect the moment the app comes back to the foreground.
        fgObserver = NotificationCenter.default.addObserver(
            forName: .bromureDidForeground, object: nil, queue: .main) { [weak self] _ in
            self?.reconnectNow()
        }
    }

    deinit {
        if let fgObserver { NotificationCenter.default.removeObserver(fgObserver) }
    }

    /// Force the pump to reconnect now. After the app was suspended the socket
    /// may be dead, but a blocking `read` won't notice until TCP times out —
    /// closing the fd unblocks it, so `onStreamEnded` reattaches immediately.
    func reconnectNow() {
        stateLock.lock(); let done = stopped; stateLock.unlock()
        guard !done else { return }
        closeFD()
    }

    /// Bind the SwiftUI-hosted terminal and start pumping. Main actor.
    @MainActor func attach(to view: TerminalView) {
        terminalView = view
        let term = view.getTerminal()
        stateLock.lock(); cols = term.cols; rows = term.rows; stopped = false; stateLock.unlock()
        startPump()
    }

    func stop() {
        stateLock.lock(); stopped = true; stateLock.unlock()
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
        connected = true
        lastError = nil
        stateLock.lock(); reattachDelay = 1.0; stateLock.unlock()
        // Push our current geometry so the guest tmux repaints at our size.
        if let tv = terminalView {
            let term = tv.getTerminal()
            resize(cols: term.cols, rows: term.rows)
        }
    }

    @MainActor private func onStreamEnded(error: String?) {
        connected = false
        lastError = error
        stateLock.lock()
        let done = stopped
        // Reconnect with capped backoff; a run that lasted a while resets it.
        if Date().timeIntervalSince(lastConnectAt) > 10 { reattachDelay = 1.0 }
        else { reattachDelay = min(reattachDelay * 2, 30) }
        stateLock.unlock()
        guard !done, terminalView != nil else { return }
        startPump()
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
        if interactive {
            let pinch = UIPinchGestureRecognizer(
                target: context.coordinator,
                action: #selector(Coordinator.handlePinch(_:)))
            // Never let the pinch swallow a single-finger tap — SwiftTerm's own
            // tap-to-focus (becomeFirstResponder) must keep working.
            pinch.cancelsTouchesInView = false
            pinch.delaysTouchesBegan = false
            tv.addGestureRecognizer(pinch)
            // Pop the keyboard once the surface actually lands in a window, so
            // an interactive terminal is ready to type into without a tap. Only
            // the surface on screen: a sibling mounted for another window must
            // not steal it out from under the visible one.
            if isActive { context.coordinator.keepFocused(tv) }
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
        if isActive {
            // The visible terminal owns the keyboard. Keep it — reclaim first
            // responder if lost to a sibling teardown, the reader closing, or a
            // rotation. A terminal has no "dismiss keyboard" affordance, so
            // simply following visibility is right; going inactive (switching
            // tab / pane / into the reader) is what releases it. This is
            // self-healing: every render re-checks, so a transient active →
            // inactive → active flip during a transition can't strand it
            // keyboard-less, which the previous focusTick-only trigger did.
            context.coordinator.keepFocused(uiView)
        } else {
            context.coordinator.stopKeepingFocus()
            if uiView.isFirstResponder { uiView.resignFirstResponder() }
        }
    }

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        coordinator.session.stop()
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

        init(view: RemoteTerminalView) { self.parent = view }
        func bind(_ v: TerminalView) { view = v }

        /// Ensure this (active, visible) surface is first responder, retrying
        /// until it lands in the window and takes it. A no-op once it already
        /// holds focus, so calling it on every render is cheap.
        func keepFocused(_ v: TerminalView) {
            if v.isFirstResponder { return }
            focusGen &+= 1
            retryFocus(v, gen: focusGen, attempts: 40)
        }

        /// Stop any pending focus retry (this surface is no longer active).
        func stopKeepingFocus() { focusGen &+= 1 }

        private func retryFocus(_ v: TerminalView, gen: Int, attempts: Int) {
            guard attempts > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak v, weak self] in
                guard let self, let v else { return }
                // Superseded (this surface went inactive, or a newer attempt
                // started) → stop, so a hidden terminal can't claim the keyboard.
                guard gen == self.focusGen else { return }
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
