import AppKit
import Foundation
import SandboxEngine
@preconcurrency import Virtualization

private let scrollBridgeDebug = ProcessInfo.processInfo.environment["BROMURE_DEBUG"] != nil
@inline(__always) private func sbLog(_ msg: @autoclosure () -> String) {
    if scrollBridgeDebug { print(msg()) }
}

/// Streams precise trackpad scroll deltas from the host into the guest
/// browser.
///
/// Three transports, tried in this order:
///
/// * **direct** (default): one persistent DevTools WebSocket from the host
///   into Chromium (``CDPWheelInjector``), each NSEvent dispatched as
///   `Input.dispatchMouseEvent(mouseWheel)` at the cursor on the active
///   tab's target. Chromium applies those deltas *exactly and
///   immediately*: 60 pt → 60 px in the next frame, sub-pixel amounts
///   accumulate, no wheel animator. That is what macOS itself does with
///   trackpad deltas (the OS already animates momentum), so the page
///   tracks the finger the way Safari does.
///
/// * **cdp** (`vm.precisionScrollTransport = cdp`, and the fallback while
///   the direct socket comes up): the same DevTools event, but sent as a
///   `{"type":"wheel"}` message to the guest's input agent (vsock 5007, one
///   connection per message — the path pinch-to-zoom uses). Correct, but
///   the connect-per-event cycle bunches events when the guest is busy.
///
/// * **uinput** (`vm.precisionScrollTransport = uinput`, last resort): the
///   original path — a persistent connection to the precision-scroll agent
///   (vsock 5820) that re-injects deltas as hi-res wheel events through a
///   virtual mouse. Measured on the Ubuntu image, libinput + Chromium turn
///   that into *wheel ticks*: deltas under ~120 units are dropped or
///   mis-accumulated, and every event is eased over ~150 ms by Chromium's
///   smooth-scroll animator on top of the OS momentum curve — the floaty,
///   laggy feel. It still beats VZ's USB wheel (whole clicks only), so it
///   stays as the fallback while the CDP agent boots.
///
/// Callers check ``canSend`` per event and fall back to the legacy VZ wheel
/// path while neither transport is up, so scrolling always works.
@MainActor
public final class PrecisionScrollBridge {
    public static let vsockPort: UInt32 = 5820
    /// cjk-input-agent.py — the generic "inject Chromium input via CDP"
    /// endpoint (shared with `GestureBridge`).
    public static let cdpInputPort: UInt32 = 5007

    public enum Transport: String {
        /// Persistent DevTools socket from the host (``CDPWheelInjector``),
        /// falling back to `cdp`, then `uinput`.
        case direct
        /// Guest input agent, one vsock connection per event.
        case cdp
        case uinput
    }

    /// Direct transport. Set by the session once its CDP bridge exists.
    public var injector: CDPWheelInjector?
    /// CDP target id of the page under the window's active tab (native
    /// tab bar). nil = no tab list yet → the agent/uinput paths.
    public var activeTargetId: (() -> String?)?

    private weak var socketDevice: VZVirtioSocketDevice?
    private var currentConn: VZVirtioSocketConnection?
    private var currentFD: Int32 = -1
    private var connecting = false
    private var retryCount = 0
    private static let maxRetries = 30  // ~90s of 3s retries covers slow boots

    /// uinput transport connected.
    public private(set) var isConnected = false

    /// The active transport. Read once at init from
    /// `vm.precisionScrollTransport` ("cdp" | "uinput"; default cdp).
    public let transport: Transport

    /// CDP transport: false until the first message is accepted by the
    /// guest agent, and again after a failed connect (agent restarting).
    /// While false, events go to the uinput path if that is up.
    public private(set) var cdpReady = false
    private var cdpConnectFailures = 0
    private var cdpProbeScheduled = false

    /// Where a scroll lands when the caller has no cursor position (the
    /// automation `/scroll` endpoint): guest device pixels of the visible
    /// area's centre, minus the native-chrome inset. Set by the session.
    public var defaultPoint: (() -> (x: Double, y: Double))?

    public init(socketDevice: VZVirtioSocketDevice) {
        self.socketDevice = socketDevice
        let raw = UserDefaults.standard.string(forKey: "vm.precisionScrollTransport") ?? "direct"
        self.transport = Transport(rawValue: raw) ?? .direct
        // The uinput path connects regardless: it is the fallback while the
        // CDP agent is still starting (and the whole path when selected).
        connect()
        if transport != .uinput { probeCDP() }
    }

    public func stop() {
        currentConn = nil
        currentFD = -1
        isConnected = false
        cdpReady = false
        injector?.stop()
        injector = nil
    }

    /// True when at least one transport can take the event right now.
    public var canSend: Bool {
        directReady || (transport != .uinput && cdpReady) || isConnected
    }

    private var directReady: Bool {
        transport == .direct && injector?.isReady == true && activeTargetId?() != nil
    }

    /// Send one scroll event at a cursor position. Deltas are in macOS
    /// points (precise trackpad deltas), natural-scrolling already applied
    /// by the OS; `x`/`y` are guest device pixels relative to the page
    /// viewport (the caller subtracts the native-chrome inset).
    /// `vm.scrollGain` (default 1.0) scales the deltas before they leave
    /// the host. Tunable live: defaults write io.bromure.app vm.scrollGain
    /// -float 1.2
    public func sendScroll(dx rawDX: Double, dy rawDY: Double,
                           x: Double, y: Double,
                           shift: Bool = false, ctrl: Bool = false, alt: Bool = false) {
        let gain = UserDefaults.standard.object(forKey: "vm.scrollGain") as? Double ?? 1.0
        let dx = rawDX * gain, dy = rawDY * gain
        if directReady, let injector, let targetId = activeTargetId?() {
            // Device px → CSS px (Chromium runs at the host's display scale).
            let dpr = Double(max(VMConfig.resolvedDisplayScale(), 1))
            var mods = 0
            if alt { mods |= 1 }
            if ctrl { mods |= 2 }
            if shift { mods |= 8 }
            injector.wheel(targetId: targetId, x: x / dpr, y: y / dpr,
                           dx: -dx, dy: -dy, modifiers: mods)
            return
        }
        if transport != .uinput && cdpReady {
            sendCDP(dx: dx, dy: dy, x: x, y: y, shift: shift, ctrl: ctrl, alt: alt)
            return
        }
        sendUinput(dx: dx, dy: dy)
    }

    /// Cursor-less variant (automation): lands at ``defaultPoint``.
    public func sendScroll(dx: Double, dy: Double) {
        let p = defaultPoint?() ?? (x: 400, y: 300)
        sendScroll(dx: dx, dy: dy, x: p.x, y: p.y)
    }

    // MARK: - CDP transport

    /// One vsock connection at a time, in order. The guest agent accepts
    /// with a backlog of 1 and handles one message per connection, so
    /// firing 120 concurrent connects a second overflows it (refused
    /// connects, reordered arrivals → bunched, uneven frames). While a
    /// send is in flight, further events fold into `pending` (deltas
    /// summed, latest position/modifiers kept); the next connection
    /// carries the sum. Chromium sums per frame anyway, so nothing is
    /// lost and the queue never grows beyond one message.
    private var cdpInFlight = false
    private var pending: (dx: Double, dy: Double, x: Double, y: Double,
                          shift: Bool, ctrl: Bool, alt: Bool)?

    private func sendCDP(dx: Double, dy: Double, x: Double, y: Double,
                         shift: Bool, ctrl: Bool, alt: Bool) {
        if cdpInFlight {
            if var p = pending {
                p.dx += dx; p.dy += dy; p.x = x; p.y = y
                p.shift = shift; p.ctrl = ctrl; p.alt = alt
                pending = p
            } else {
                pending = (dx, dy, x, y, shift, ctrl, alt)
            }
            return
        }
        // CDP wheel: positive deltaY scrolls the page down, the opposite
        // of NSEvent's natural-scrolling sign.
        var msg: [String: Any] = [
            "type": "wheel",
            "x": x, "y": y,
            "deltaX": -dx, "deltaY": -dy,
        ]
        if shift { msg["shift"] = "1" }
        if ctrl { msg["ctrl"] = "1" }
        if alt { msg["alt"] = "1" }
        guard let device = socketDevice,
              let data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        cdpInFlight = true
        // VZVirtioSocketDevice.connect must run on the main queue (we are);
        // the completion fires on an arbitrary queue and does the write.
        device.connect(toPort: Self.cdpInputPort) { [weak self] result in
            var ok = false
            if case .success(let conn) = result {
                data.withUnsafeBytes { buf in
                    if let base = buf.baseAddress {
                        _ = Darwin.write(conn.fileDescriptor, base, buf.count)
                    }
                }
                Darwin.close(conn.fileDescriptor)
                ok = true
            }
            DispatchQueue.main.async { self?.cdpSendFinished(ok: ok) }
        }
    }

    private func cdpSendFinished(ok: Bool) {
        cdpInFlight = false
        if ok {
            cdpConnectFailures = 0
        } else {
            cdpFailed()
        }
        if let p = pending, cdpReady {
            pending = nil
            sendCDP(dx: p.dx, dy: p.dy, x: p.x, y: p.y, shift: p.shift, ctrl: p.ctrl, alt: p.alt)
        } else if !cdpReady, let p = pending {
            // Agent gone mid-gesture: hand the remainder to uinput.
            pending = nil
            sendUinput(dx: p.dx, dy: p.dy)
        }
    }

    /// A refused connect. One can be a transient (agent restarting under
    /// resilient-launch); three in a row means it's down: drop to the
    /// uinput path and re-probe every second.
    private func cdpFailed() {
        cdpConnectFailures += 1
        guard cdpConnectFailures >= 3 else { return }
        if cdpReady {
            sbLog("[ScrollBridge] CDP input agent unreachable; falling back to uinput")
        }
        cdpReady = false
        probeCDP()
    }

    /// Connect once to see whether the guest input agent is up; an empty
    /// connection is fine (the agent ignores empty reads). Retries every
    /// second while the guest boots.
    private func probeCDP() {
        guard !cdpProbeScheduled, transport != .uinput, !cdpReady,
              let device = socketDevice else { return }
        cdpProbeScheduled = true
        device.connect(toPort: Self.cdpInputPort) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.cdpProbeScheduled = false
                switch result {
                case .success(let conn):
                    Darwin.close(conn.fileDescriptor)
                    self.cdpReady = true
                    self.cdpConnectFailures = 0
                    sbLog("[ScrollBridge] CDP input agent ready")
                case .failure:
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                        self?.probeCDP()
                    }
                }
            }
        }
    }

    // MARK: - uinput transport

    private func sendUinput(dx: Double, dy: Double) {
        guard currentFD >= 0 else {
            connect()
            return
        }
        var line = "{\"dx\":\(dx),\"dy\":\(dy)}\n"
        let n = line.withUTF8 { buf -> Int in
            guard let base = buf.baseAddress else { return -1 }
            return Darwin.write(currentFD, base, buf.count)
        }
        if n <= 0 {
            sbLog("[ScrollBridge] write failed; will reconnect")
            currentConn = nil
            currentFD = -1
            isConnected = false
            connect()
        }
    }

    private func connect() {
        guard !connecting, !isConnected, retryCount < Self.maxRetries,
              let device = socketDevice else { return }
        connecting = true
        retryCount += 1
        device.connect(toPort: Self.vsockPort) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.connecting = false
                switch result {
                case .success(let conn):
                    self.currentConn = conn
                    self.currentFD = conn.fileDescriptor
                    self.isConnected = true
                    self.retryCount = 0
                    sbLog("[ScrollBridge] uinput agent connected (fd=\(conn.fileDescriptor))")
                case .failure:
                    // Agent not up yet (boot) — retry quietly.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                        self?.connect()
                    }
                }
            }
        }
    }
}
