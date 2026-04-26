import AppKit
import Foundation
@preconcurrency import Virtualization

/// Forwards macOS `NSEvent.scrollWheel` deltas into the Linux guest as
/// X11 Button4/Button5 clicks via vsock + xdotool.
///
/// `VZUSBScreenCoordinatePointingDeviceConfiguration` is a plain USB
/// HID absolute pointer; it doesn't forward wheel reports, so the
/// terminal in the guest sees no scroll input. This bridge captures
/// host scroll events on the VM window, coalesces them at ~60 Hz, and
/// pushes a tick count to a guest agent that issues
/// `xdotool click --repeat N 4` (up) or `5` (down).
public final class ScrollBridge {
    public static let vsockPort: UInt32 = 5008

    /// Pixels of accumulated scrollingDeltaY per emitted "tick". The
    /// trackpad reports continuous deltas; we threshold to align with
    /// the terminal's per-line scroll. ~24 px is roughly one line at
    /// 14 pt with display-scale 2.
    private static let pixelsPerTick: CGFloat = 24
    private static let minSendInterval: CFAbsoluteTime = 1.0 / 60.0

    private weak var socketDevice: VZVirtioSocketDevice?
    private weak var window: NSWindow?
    private var monitor: Any?

    private var pendingPixels: CGFloat = 0
    private var lastSendTime: CFAbsoluteTime = 0
    private var pendingFlush: DispatchWorkItem?

    /// True when the user has macOS's natural-scrolling preference
    /// enabled (the default). Captured at construction so the bridge
    /// doesn't re-read system prefs on every event tick. Toggle takes
    /// effect on next session launch — same lifetime as the browser
    /// already uses for `VMConfig.detectNaturalScrolling()`.
    private let naturalScrolling: Bool

    public init(socketDevice: VZVirtioSocketDevice, window: NSWindow) {
        self.socketDevice = socketDevice
        self.window = window
        self.naturalScrolling = VMConfig.detectNaturalScrolling()

        let windowID = ObjectIdentifier(window)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self,
                  let evWin = event.window,
                  ObjectIdentifier(evWin) == windowID
            else { return event }
            // hasPreciseScrollingDeltas == true on trackpads (delta in
            // pixels). false on classic mouse wheels (delta in lines).
            // Either way scrollingDeltaY's sign is what we care about;
            // mouse-wheel "lines" are scaled by AppKit before we get
            // here so the magnitude is reasonable.
            self.handle(deltaY: event.scrollingDeltaY)
            return nil  // consume — don't double-forward via VZ HID
        }
    }

    deinit {
        if let monitor = monitor { NSEvent.removeMonitor(monitor) }
    }

    private func handle(deltaY: CGFloat) {
        pendingPixels += deltaY
        let now = CFAbsoluteTimeGetCurrent()
        let sinceLast = now - lastSendTime
        if sinceLast >= Self.minSendInterval {
            flush()
        } else if pendingFlush == nil {
            let delay = Self.minSendInterval - sinceLast
            let work = DispatchWorkItem { [weak self] in self?.flush() }
            pendingFlush = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func flush() {
        pendingFlush?.cancel()
        pendingFlush = nil
        let pixels = pendingPixels
        guard abs(pixels) >= 1 else { return }
        let ticks = Int(abs(pixels) / Self.pixelsPerTick)
        guard ticks > 0 else { return }
        pendingPixels = 0
        lastSendTime = CFAbsoluteTimeGetCurrent()

        // Map host delta → guest X11 wheel button.
        //
        // `scrollingDeltaY` reflects the gesture in user-space:
        //  - Natural scrolling ON: swipe up → +deltaY
        //    (user wants content to move up = see what's below)
        //    → Button5 (X11 "scroll down" wheel)
        //  - Natural scrolling OFF: wheel up / two-finger swipe up
        //    → +deltaY (user wants content to move down = see above)
        //    → Button4 (X11 "scroll up" wheel)
        // So the sign-to-button mapping flips with the natural-scroll
        // preference. We took a snapshot at init via the same
        // `VMConfig.detectNaturalScrolling()` the browser uses for
        // its install-time setup, so the behaviour stays consistent
        // across both apps.
        let direction: String
        if naturalScrolling {
            direction = pixels > 0 ? "down" : "up"
        } else {
            direction = pixels > 0 ? "up" : "down"
        }
        sendMessage("\(direction) \(ticks)\n")
    }

    private func sendMessage(_ line: String) {
        guard let device = socketDevice else { return }
        device.connect(toPort: Self.vsockPort) { result in
            guard case .success(let conn) = result else { return }
            let bytes = Array(line.utf8)
            bytes.withUnsafeBufferPointer { buf in
                if let base = buf.baseAddress {
                    _ = Darwin.write(conn.fileDescriptor, base, buf.count)
                }
            }
            Darwin.close(conn.fileDescriptor)
        }
    }
}
