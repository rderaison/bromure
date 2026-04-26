import Foundation
@preconcurrency import Virtualization

/// Sends keyboard layout changes from the macOS host to a running VM.
///
/// On construction (and whenever the host layout changes) connects to
/// vsock port 5006 in the guest and writes the X11 layout name. The
/// guest's keyboard-agent.py applies it with `setxkbmap`.
///
/// Two modes:
///  - **Auto** (`forcedLayout == nil`) — detect macOS's current layout
///    and observe `TISNotifySelectedKeyboardInputSourceChanged` for
///    live updates.
///  - **Forced** (`forcedLayout != nil`) — push the supplied layout
///    once and skip the observer entirely.
public final class KeyboardBridge {
    private static let vsockPort: UInt32 = 5006

    private weak var socketDevice: VZVirtioSocketDevice?
    private var observation: NSObjectProtocol?
    private var debounceTimer: Timer?
    private var lastSentLayout: String?

    public init(socketDevice: VZVirtioSocketDevice, forcedLayout: String? = nil) {
        self.socketDevice = socketDevice

        if let forced = forcedLayout, !forced.isEmpty {
            lastSentLayout = forced
            sendLayout(forced)
            return
        }

        // Send the current layout immediately so the VM matches on first use
        let initial = VMConfig.detectKeyboardLayout()
        lastSentLayout = initial
        sendLayout(initial)

        // Observe macOS keyboard layout changes
        observation = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.scheduleLayoutUpdate()
        }
    }

    deinit {
        stop()
    }

    /// Stop observing keyboard layout changes.
    public func stop() {
        debounceTimer?.invalidate()
        debounceTimer = nil
        if let obs = observation {
            DistributedNotificationCenter.default().removeObserver(obs)
            observation = nil
        }
    }

    /// Debounce rapid-fire notifications (e.g. switching to Japanese fires
    /// multiple events). Only send after 200ms of quiet.
    private func scheduleLayoutUpdate() {
        debounceTimer?.invalidate()
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
            guard let self else { return }
            let layout = VMConfig.detectKeyboardLayout()
            // Don't re-send if unchanged
            guard layout != self.lastSentLayout else { return }
            self.lastSentLayout = layout
            print("[KeyboardBridge] layout changed to: \(layout)")
            self.sendLayout(layout)
        }
    }

    private func sendLayout(_ layout: String) {
        guard let device = socketDevice else { return }
        device.connect(toPort: Self.vsockPort) { result in
            switch result {
            case .success(let conn):
                let data = Array(layout.utf8)
                data.withUnsafeBufferPointer { buf in
                    if let base = buf.baseAddress {
                        _ = Darwin.write(conn.fileDescriptor, base, buf.count)
                    }
                }
                Darwin.close(conn.fileDescriptor)
            case .failure:
                // Guest keyboard-agent may not be running yet — ignore silently
                break
            }
        }
    }
}
