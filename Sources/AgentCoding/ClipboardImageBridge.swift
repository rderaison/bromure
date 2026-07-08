import AppKit
import Foundation
@preconcurrency import Virtualization

/// Ferries images copied on the macOS host into the guest's X11 CLIPBOARD
/// selection so Claude Code's Ctrl+V image ingestion works inside the VM.
///
/// VZ's SPICE agent (`sharesClipboard`) syncs plain text only, so images
/// need their own channel: whenever the host pasteboard gains an image,
/// the PNG is written into the session's meta share and a
/// "clipboard-image" command is sent to the guest's keyboard-agent
/// (vsock 5006), which publishes the file as `image/png` on the CLIPBOARD
/// selection via xclip. The generated kitty.conf (TerminalAppDefaults)
/// turns ⌘V into Ctrl+V when the guest clipboard holds an image, and the
/// TUI agent pulls the PNG back with its own `xclip -o`.
///
/// Staleness is handled by X selection ownership: the next host *text*
/// copy makes spice-vdagent re-grab the selection, displacing the xclip
/// child, so an old image can never shadow newer text.
///
/// NSPasteboard has no change notification — polling `changeCount` is the
/// sanctioned pattern. The timer only reads the cheap counter (content is
/// touched on change only) and only while the app is active; a copy made
/// in another app is picked up by the `didBecomeActive` check before the
/// user can press ⌘V. The 0.3s period keeps the "⇧⌘⌃4 screenshot while
/// Bromure is frontmost, then immediately ⌘V" flow ahead of the paste.
final class ClipboardImageBridge {
    private static let vsockPort: UInt32 = 5006
    /// Filename inside the meta share — keyboard-agent reads the twin
    /// guest path /mnt/bromure-meta/clipboard.png.
    static let fileName = "clipboard.png"
    /// Refuse anything bigger — a runaway pasteboard object (huge TIFF
    /// from a pro app) would stall virtiofs and xclip for no plausible
    /// paste. Screenshots are a few MB.
    static let maxBytes = 32 << 20

    private weak var socketDevice: VZVirtioSocketDevice?
    private let metaDirectory: URL
    private var timer: Timer?
    private var observation: NSObjectProtocol?
    /// changeCount of the last pasteboard state we finished with —
    /// delivered, or decided to skip. Left unset on vsock connect
    /// failure so the next tick retries; that covers the boot window
    /// before the guest agent is listening (the file write is
    /// idempotent, so retrying is free).
    private var handledChangeCount: Int?
    /// DEBUG: last changeCount whose vsock failure was logged, so the
    /// 0.3s retry loop reports each pasteboard state once, not per tick.
    private var failureLoggedCount: Int?

    init(socketDevice: VZVirtioSocketDevice, metaDirectory: URL) {
        self.socketDevice = socketDevice
        self.metaDirectory = metaDirectory
        print("[ClipboardImageBridge] started, meta share: \(metaDirectory.path)")

        observation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.checkPasteboard()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard NSApp.isActive else { return }
            self?.checkPasteboard()
        }
        // An image copied before the session opened should be pasteable
        // right away.
        checkPasteboard()
    }

    deinit {
        stop()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let obs = observation {
            NotificationCenter.default.removeObserver(obs)
            observation = nil
        }
    }

    private func checkPasteboard() {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != handledChangeCount else { return }

        let types = (pb.types ?? []).map(\.rawValue).joined(separator: ", ")
        // Finder file copies carry a fileURL (plus icon bitmaps) — those
        // belong to the drag-into-FileBrowserView path, not the clipboard.
        if pb.types?.contains(.fileURL) == true {
            print("[ClipboardImageBridge] change #\(count): fileURL copy, skipping (types: \(types))")
            handledChangeCount = count
            return
        }
        guard let png = Self.pngData(from: pb) else {
            // Text-only or empty: spice-vdagent owns that sync.
            print("[ClipboardImageBridge] change #\(count): no image, spice owns it (types: \(types))")
            handledChangeCount = count
            return
        }
        guard png.count <= Self.maxBytes else {
            print("[ClipboardImageBridge] skipping \(png.count)-byte pasteboard image (cap \(Self.maxBytes))")
            handledChangeCount = count
            return
        }
        do {
            // Atomic (write + rename) so the guest can never read a
            // half-written file through virtiofs.
            try png.write(to: metaDirectory.appendingPathComponent(Self.fileName),
                          options: .atomic)
            print("[ClipboardImageBridge] change #\(count): wrote \(png.count)-byte PNG to \(Self.fileName)")
        } catch {
            // Meta share missing/unwritable — session is torn down or
            // broken; don't spin on every tick.
            print("[ClipboardImageBridge] change #\(count): PNG write FAILED: \(error)")
            handledChangeCount = count
            return
        }
        guard let device = socketDevice else {
            print("[ClipboardImageBridge] change #\(count): socket device gone, cannot notify guest")
            return
        }
        device.connect(toPort: Self.vsockPort) { [weak self] result in
            switch result {
            case .success(let conn):
                let cmd = Array("clipboard-image".utf8)
                cmd.withUnsafeBufferPointer { buf in
                    if let base = buf.baseAddress {
                        _ = Darwin.write(conn.fileDescriptor, base, buf.count)
                    }
                }
                Darwin.close(conn.fileDescriptor)
                print("[ClipboardImageBridge] change #\(count): sent clipboard-image to guest agent (vsock \(Self.vsockPort))")
                self?.handledChangeCount = count
            case .failure(let error):
                // Guest agent not up yet — the timer retries.
                if self?.failureLoggedCount != count {
                    self?.failureLoggedCount = count
                    print("[ClipboardImageBridge] change #\(count): vsock \(Self.vsockPort) connect failed (will retry): \(error)")
                }
            }
        }
    }

    /// Best PNG rendition of the pasteboard's image, if any. Screenshots
    /// publish PNG directly; apps that only offer TIFF get converted.
    static func pngData(from pb: NSPasteboard) -> Data? {
        if let png = pb.data(forType: .png) { return png }
        if let tiff = pb.data(forType: .tiff) { return pngData(fromTIFF: tiff) }
        return nil
    }

    static func pngData(fromTIFF tiff: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
