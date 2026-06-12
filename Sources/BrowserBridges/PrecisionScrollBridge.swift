import AppKit
import Foundation
@preconcurrency import Virtualization

private let scrollBridgeDebug = ProcessInfo.processInfo.environment["BROMURE_DEBUG"] != nil
@inline(__always) private func sbLog(_ msg: @autoclosure () -> String) {
    if scrollBridgeDebug { print(msg()) }
}

/// Streams precise trackpad scroll deltas from the host to the guest's
/// precision-scroll-agent (vsock 5820), which re-injects them as
/// high-resolution wheel events via a uinput virtual device.
///
/// VZ's USB digitizer quantizes scrolling to whole wheel clicks, which
/// is the single most VM-feeling part of the experience — macOS
/// trackpads produce pixel-precise deltas with momentum. This bridge
/// carries those NSEvent deltas; the guest applies them ~1:1 (1 host
/// point ≈ 1 guest CSS px) with momentum preserved. `vm.scrollGain`
/// scales magnitude; the guest negates dy so natural-scroll direction
/// matches native macOS.
///
/// Connection model: connect on init, retry with a short backoff while
/// the guest agent boots, lazily reconnect after errors. Callers check
/// ``isConnected`` per event and fall back to the legacy VZ wheel path
/// while the bridge is down, so scrolling always works.
@MainActor
public final class PrecisionScrollBridge {
    public static let vsockPort: UInt32 = 5820

    private weak var socketDevice: VZVirtioSocketDevice?
    private var currentConn: VZVirtioSocketConnection?
    private var currentFD: Int32 = -1
    private var connecting = false
    private var retryCount = 0
    private static let maxRetries = 30  // ~90s of 3s retries covers slow boots

    public private(set) var isConnected = false

    public init(socketDevice: VZVirtioSocketDevice) {
        self.socketDevice = socketDevice
        connect()
    }

    public func stop() {
        currentConn = nil
        currentFD = -1
        isConnected = false
    }

    /// Send one scroll event. Deltas are in macOS points (precise
    /// trackpad deltas), natural-scrolling already applied by the OS.
    /// `vm.scrollGain` (default 1.0) scales them before they leave the
    /// host — the guest converts points to hi-res wheel units at 120/53
    /// (Chromium's px-per-notch), so gain 1.0 targets 1 host point =
    /// 1 guest CSS px. Tunable live: defaults write io.bromure.app
    /// vm.scrollGain -float 1.2
    public func sendScroll(dx rawDX: Double, dy rawDY: Double) {
        guard currentFD >= 0 else {
            connect()
            return
        }
        let gain = UserDefaults.standard.object(forKey: "vm.scrollGain") as? Double ?? 1.0
        let dx = rawDX * gain, dy = rawDY * gain
        var line = "{\"dx\":\(dx),\"dy\":\(dy)}\n"
        let n = line.withUTF8 { buf -> Int in
            guard let base = buf.baseAddress else { return -1 }
            return Darwin.write(currentFD, base, buf.count)
        }
        if n <= 0 {
            sbLog("[ScrollBridge] write failed; will reconnect")
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
                    sbLog("[ScrollBridge] connected (fd=\(conn.fileDescriptor))")
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
