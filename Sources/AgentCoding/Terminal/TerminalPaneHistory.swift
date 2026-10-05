import AppKit

// MARK: - Copy Pane History
//
// A terminal tab's surface is pinned to the alternate screen (the guest tmux
// owns the scrollback), so a selection in it only ever reaches the visible
// rows. Copy Pane History asks tmux for the window's whole history instead
// (`capture-pane -S -`), written to a file in the guest and read back over
// the file channel — a long history is far past what an exec's stdout or an
// argv should carry — then put on the pasteboard.

/// The guest commands and text handling behind Copy Pane History.
enum PaneHistory {
    /// The pane a surface for tmux window `window` shows.
    static func target(window: Int) -> String { "bromure:\(window)" }

    /// A fresh guest file to capture into.
    static func capturePath(token: String = UUID().uuidString.lowercased()) -> String {
        "/tmp/bromure-pane-history-\(token).txt"
    }

    private static func q(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Capture the window's whole history (`-S -`), wrapped lines joined
    /// (`-J`), into `path`; prints the file's size.
    static func captureCommand(window: Int, path: String) -> String {
        "tmux capture-pane -p -J -S - -t \(q(target(window: window))) > \(q(path)) 2>/dev/null"
            + " && wc -c < \(q(path))"
    }

    static func readCommand(path: String) -> String { "cat \(q(path))" }

    static func cleanupCommand(path: String) -> String { "rm -f \(q(path))" }

    /// The capture as it goes on the pasteboard: the blank rows below the
    /// last output (the unused part of the screen) dropped.
    static func normalized(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let n = text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        return text.hasSuffix("\n") ? n : n + 1
    }

    /// "Copied 1 line" / "Copied 1,204 lines".
    static func copiedMessage(lines: Int) -> String {
        if lines == 1 { return NSLocalizedString("Copied 1 line", comment: "copy pane history toast") }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return String(format: NSLocalizedString("Copied %@ lines", comment: "copy pane history toast"),
                      f.string(from: NSNumber(value: lines)) ?? "\(lines)")
    }

    /// The most a capture is read back (tmux's default history is far less).
    static let maxBytes = 64 * 1024 * 1024
    static let readChunk = 4 * 1024 * 1024

    typealias Exec = (String) async throws -> String
    typealias FileOp = ([String: Any]) async throws -> [String: Any]

    /// The window's whole history, or nil when the guest can't be reached.
    static func capture(window: Int, exec: Exec, fileOp: FileOp) async -> String? {
        let path = capturePath()
        guard (try? await exec(captureCommand(window: window, path: path))) != nil else {
            _ = try? await exec(cleanupCommand(path: path))
            return nil
        }
        let text = await read(path, exec: exec, fileOp: fileOp)
        _ = try? await exec(cleanupCommand(path: path))
        return text
    }

    private static func read(_ path: String, exec: Exec, fileOp: FileOp) async -> String? {
        var data = Data()
        var readByFile = true
        while data.count < maxBytes {
            guard let r = try? await fileOp(["op": "read", "path": path, "offset": data.count, "length": readChunk]),
                  r["error"] == nil,
                  let chunk = (r["data"] as? String).flatMap({ Data(base64Encoded: $0) }) else {
                readByFile = false
                break
            }
            data.append(chunk)
            if (r["eof"] as? Bool) ?? true || chunk.isEmpty { break }
        }
        if readByFile { return String(decoding: data, as: UTF8.self) }
        // No file channel (a machine that runs commands only): its stdout.
        return try? await exec(readCommand(path: path))
    }
}

extension TerminalSurfaceView {
    /// Copy the whole history of the tmux window this surface shows.
    @objc func copyPaneHistory(_ sender: Any?) {
        guard let profileID, let delegate = NSApp.delegate as? ACAppDelegate else { NSSound.beep(); return }
        let window = windowIndex
        guard window >= 0 else { NSSound.beep(); return }
        let exec: PaneHistory.Exec
        let fileOp: PaneHistory.FileOp
        if let remoteHost, let controller = delegate.remoteController(forHost: remoteHost) {
            exec = { try await controller.guestExec(profileID, command: $0, timeout: 30) }
            fileOp = { try await controller.guestFileOp(profileID, op: $0, timeout: 60) }
        } else {
            exec = { try await delegate.guestExec(profileID: profileID, command: $0, timeout: 30) }
            fileOp = { try await delegate.guestFileOp(profileID: profileID, op: $0, timeout: 60) }
        }
        Task { @MainActor [weak self] in
            guard let raw = await PaneHistory.capture(window: window, exec: exec, fileOp: fileOp) else {
                NSSound.beep()
                self?.showToast(NSLocalizedString("Couldn't read the terminal's history", comment: "copy pane history toast"))
                return
            }
            let text = PaneHistory.normalized(raw)
            platformCopyToPasteboard(text)
            self?.showToast(PaneHistory.copiedMessage(lines: PaneHistory.lineCount(text)))
        }
    }

    /// The terminal's own menu, on a right-click the pane's app isn't
    /// tracking (see `rightMouseDown`).
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: NSLocalizedString("Copy Pane History", comment: "terminal menu"),
                     action: #selector(copyPaneHistory(_:)), keyEquivalent: "").target = self
        return menu
    }

    /// A short note floated at the top of the terminal (never takes input).
    func showToast(_ text: String) {
        subviews.first(where: { $0 is TerminalToast })?.removeFromSuperview()
        let toast = TerminalToast(text: text)
        toast.setFrameOrigin(NSPoint(x: max(8, (bounds.width - toast.frame.width) / 2),
                                     y: max(8, bounds.height - toast.frame.height - 12)))
        toast.autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        toast.alphaValue = 0
        addSubview(toast)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; toast.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak toast] in
            guard let toast else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; toast.animator().alphaValue = 0 },
                                                completionHandler: { toast.removeFromSuperview() })
        }
    }
}

/// The pill `showToast` floats over a terminal.
private final class TerminalToast: NSView {
    init(text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.sizeToFit()
        let pad = NSSize(width: 14, height: 7)
        super.init(frame: NSRect(x: 0, y: 0, width: label.frame.width + pad.width * 2,
                                 height: label.frame.height + pad.height * 2))
        wantsLayer = true
        layer?.cornerRadius = frame.height / 2
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        label.setFrameOrigin(NSPoint(x: pad.width, y: pad.height))
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
