import AppKit
import Foundation
@preconcurrency import Virtualization

/// Carries trackpad/wheel scroll from the macOS host into the guest's
/// `scroll-agent.py` (vsock 5008), which drives the tmux scrollback
/// directly (copy-mode) via the tmux CLI.
///
/// Why this exists: the terminal runs kitty attached to a tmux session,
/// and tmux lives in kitty's *alternate screen*. If a wheel event reaches
/// kitty, `alternate_scroll` translates it to arrow keys (which walk the
/// shell's command history) because tmux's mouse mode is deliberately OFF
/// — that keeps kitty's own click-drag selection + ⌘C working. So instead
/// of letting VZ inject the wheel into the guest, `FramebufferView`
/// *consumes* the scroll and hands the deltas here; the guest scrolls the
/// tmux history without ever touching the mouse layer. Net result: the
/// wheel scrolls the window, and selection/copy stay exactly as they were.
///
/// Connection model mirrors the keyboard/precision-scroll bridges: connect
/// on init, retry with a short backoff while the guest agent boots, lazily
/// reconnect after a write error. `FramebufferView` checks ``isConnected``
/// per event and falls back to VZ's default wheel path while the bridge is
/// down, so scrolling is never wholly dead (it just shows the old arrow-key
/// behavior until the agent comes up).
///
/// Kill switch: `defaults write io.bromure.agentic-coding vm.terminalScroll -bool NO`
/// stops the bridge from being created, restoring VZ's native wheel path.
@MainActor
final class ScrollBridge {
    static let vsockPort: UInt32 = 5008

    private weak var socketDevice: VZVirtioSocketDevice?
    private var currentConn: VZVirtioSocketConnection?
    private var currentFD: Int32 = -1
    private var connecting = false
    private var retryCount = 0
    private static let maxRetries = 30  // ~90s of 3s retries covers slow boots

    /// Sub-line scroll carried over between events so slow trackpad drags
    /// still accumulate to whole lines instead of being rounded away.
    private var accumulated: Double = 0

    private(set) var isConnected = false

    init(socketDevice: VZVirtioSocketDevice) {
        self.socketDevice = socketDevice
        connect()
    }

    func stop() {
        currentConn = nil
        currentFD = -1
        isConnected = false
    }

    /// Feed one scroll event's vertical delta (macOS points; natural-scroll
    /// direction already applied by the OS, so `> 0` means "reveal older
    /// output" = scroll up into history). Accumulates points into whole
    /// lines and emits `up N` / `down N` lines to the guest. `vm.scrollLines`
    /// (points per line, default 8) tunes sensitivity live.
    func handleScroll(deltaY: Double) {
        guard currentFD >= 0 else {
            connect()
            return
        }
        let pointsPerLine = UserDefaults.standard.object(forKey: "vm.scrollLines") as? Double ?? 8.0
        accumulated += deltaY
        let lines = Int((accumulated / max(1.0, pointsPerLine)).rounded(.towardZero))
        guard lines != 0 else { return }
        accumulated -= Double(lines) * pointsPerLine
        let direction = lines > 0 ? "up" : "down"
        let n = min(abs(lines), 200)
        var line = "\(direction) \(n)\n"
        let wrote = line.withUTF8 { buf -> Int in
            guard let base = buf.baseAddress else { return -1 }
            return Darwin.write(currentFD, base, buf.count)
        }
        if wrote <= 0 {
            stop()
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
