import AppKit
import Foundation
import Virtualization

/// Forwards macOS trackpad pinch-to-zoom gestures into the guest browser.
///
/// `VZUSBScreenCoordinatePointingDeviceConfiguration` — the pointing device
/// used for Linux guests — is a plain USB HID pointer and silently drops
/// gesture events, so a native trackpad pinch never reaches Chromium.
///
/// This bridge catches host-side `NSMagnificationGestureRecognizer` deltas
/// and ships them over vsock to Chromium's CDP endpoint, where they're
/// dispatched as synthetic Ctrl+wheel events. That matches what Chromium
/// itself synthesises for trackpad pinch on native macOS, so it works for
/// both browser page zoom and apps like Google Maps that listen for `wheel`
/// events with `ctrlKey=true`.
///
/// Shares vsock port 5007 and the `cjk-input-agent.py` guest-side agent:
/// despite the name, that agent is already the generic "inject Chromium
/// input via CDP" endpoint, so wheel injection is a natural extension.
///
/// Smoothness fix: events are coalesced to a 60 Hz cap on the host so
/// ProMotion displays (120 Hz gesture callbacks) don't oversaturate the
/// per-message vsock + CDP round-trip.
///
/// Call `sendPinchZoom(...)` from the main thread only — both because the
/// coalescing state is unguarded and because `VZVirtioSocketDevice.connect`
/// asserts it's invoked on the main dispatch queue. Gesture recognizer
/// callbacks already satisfy this.
public final class GestureBridge {
    private static let vsockPort: UInt32 = 5007
    /// Magnification delta → wheel deltaY pixels. Smaller values make zoom
    /// progression smoother (more sub-step wheel events accumulate into each
    /// Chromium zoom tick) at the cost of a slower pinch. Tuned for a
    /// native-feeling responsiveness without overshoot.
    private static let deltaScale: Double = 150.0
    /// Minimum interval between vsock sends. 60 Hz is plenty for Chromium's
    /// zoom accumulator and keeps us comfortably under what the per-message
    /// vsock + CDP round-trip can sustain.
    private static let minSendInterval: CFAbsoluteTime = 1.0 / 60.0

    private weak var socketDevice: VZVirtioSocketDevice?

    // Coalescing state — mutated only on the main thread.
    private var pendingMagnification: Double = 0
    private var lastGuestX: Int = 0
    private var lastGuestY: Int = 0
    private var lastSendTime: CFAbsoluteTime = 0
    private var pendingFlush: DispatchWorkItem?

    public init(socketDevice: VZVirtioSocketDevice) {
        self.socketDevice = socketDevice
    }

    /// Accumulate a gesture-recognizer tick. Positive `magnification` =
    /// pinch-out (zoom in). Coalesced + flushed at ≤ 60 Hz.
    public func sendPinchZoom(magnification: Double, guestX: Int, guestY: Int) {
        pendingMagnification += magnification
        lastGuestX = guestX
        lastGuestY = guestY

        let now = CFAbsoluteTimeGetCurrent()
        let sinceLast = now - lastSendTime
        if sinceLast >= Self.minSendInterval {
            flush()
        } else if pendingFlush == nil {
            // Schedule a single trailing flush so the last deltas of a
            // rapid burst aren't left stranded in the buffer.
            let delay = Self.minSendInterval - sinceLast
            let work = DispatchWorkItem { [weak self] in
                self?.flush()
            }
            pendingFlush = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func flush() {
        pendingFlush?.cancel()
        pendingFlush = nil
        let delta = pendingMagnification
        guard abs(delta) > 0.0001 else { return }
        pendingMagnification = 0
        lastSendTime = CFAbsoluteTimeGetCurrent()
        let deltaY = -delta * Self.deltaScale
        sendMessage([
            "type": "wheel",
            "x": String(lastGuestX),
            "y": String(lastGuestY),
            "deltaX": "0",
            "deltaY": String(deltaY),
            "ctrl": "1",
        ])
    }

    private func sendMessage(_ message: [String: String]) {
        guard let device = socketDevice else { return }
        guard let jsonData = try? JSONSerialization.data(withJSONObject: message),
              let jsonString = String(data: jsonData, encoding: .utf8) else { return }
        // VZVirtioSocketDevice.connect must be called on the main queue; the
        // completion handler fires on an arbitrary queue and is where we do
        // the actual write. Since sendMessage is only called from the main
        // thread (see class-level contract), we're already on the right
        // queue and can call connect directly.
        device.connect(toPort: Self.vsockPort) { result in
            guard case .success(let conn) = result else { return }
            let bytes = Array(jsonString.utf8)
            bytes.withUnsafeBufferPointer { buf in
                if let base = buf.baseAddress {
                    _ = Darwin.write(conn.fileDescriptor, base, buf.count)
                }
            }
            Darwin.close(conn.fileDescriptor)
        }
    }
}
