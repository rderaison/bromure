import Foundation
import SandboxEngine

/// Renders ProgressEvent updates as a terminal progress bar / spinner.
final class TerminalProgress {
    private let stream: UnsafeMutablePointer<FILE>
    private let isTTY: Bool
    private var spinnerFrame = 0
    private var lastLineLength = 0
    private let spinnerChars: [Character] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    init(stream: UnsafeMutablePointer<FILE> = stderr) {
        self.stream = stream
        self.isTTY = isatty(fileno(stream)) != 0
    }

    /// Handle a progress event from the engine.
    func handle(_ event: ProgressEvent) {
        switch event {
        case .message(let text):
            finishLine()
            writeLine("  \(text)")

        case .stepStart(let text):
            overwrite("  \(spinner()) \(text)...")

        case .stepDone(let text):
            finishLine()
            writeLine("  \u{2714} \(text)")

        case .download(let received, let total):
            if received == 0 && total == 0 {
                overwrite("  \(spinner()) Downloading macOS IPSW — connecting...")
            } else if total > 0 {
                let receivedMB = Double(received) / 1_000_000
                let totalMB = Double(total) / 1_000_000
                let pct = Double(received) / Double(total)
                let bar = renderBar(fraction: pct, width: 30)
                overwrite("  \(bar) \(Int(pct * 100))%  \(String(format: "%.0f", receivedMB))/\(String(format: "%.0f", totalMB)) MB")
            } else {
                let receivedMB = Double(received) / 1_000_000
                overwrite("  \(spinner()) \(String(format: "%.0f", receivedMB)) MB downloaded")
            }

        case .install(let fraction):
            let bar = renderBar(fraction: fraction, width: 30)
            overwrite("  \(bar) Installing: \(Int(fraction * 100))%")

        case .consoleOutput:
            break // only displayed in GUI
        }
    }

    /// Call when the operation is fully complete to ensure the cursor is on a new line.
    func finish() {
        finishLine()
    }

    // MARK: - Rendering

    private func renderBar(fraction: Double, width: Int) -> String {
        let filled = Int(fraction * Double(width))
        let empty = width - filled
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: empty)
        return "[\(bar)]"
    }

    private func spinner() -> Character {
        let ch = spinnerChars[spinnerFrame % spinnerChars.count]
        spinnerFrame += 1
        return ch
    }

    private func overwrite(_ text: String) {
        if isTTY {
            // Clear current line and write new content
            let clearLen = max(lastLineLength, text.count)
            fputs("\r\(text)\(String(repeating: " ", count: max(0, clearLen - text.count)))", stream)
            fflush(stream)
            lastLineLength = text.count
        }
        // In non-TTY mode, overwrite events are silent (only stepDone prints)
    }

    private func writeLine(_ text: String) {
        fputs("\(text)\n", stream)
        fflush(stream)
        lastLineLength = 0
    }

    private func finishLine() {
        if isTTY && lastLineLength > 0 {
            fputs("\r\(String(repeating: " ", count: lastLineLength))\r", stream)
            fflush(stream)
            lastLineLength = 0
        }
    }
}

/// A simple spinner for indeterminate operations (like booting a VM).
final class TerminalSpinner {
    private let stream: UnsafeMutablePointer<FILE>
    private let isTTY: Bool
    private let message: String
    private let frames: [String] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private var timer: DispatchSourceTimer?
    private var frameIndex = 0

    init(_ message: String, stream: UnsafeMutablePointer<FILE> = stderr) {
        self.message = message
        self.stream = stream
        self.isTTY = isatty(fileno(stream)) != 0
    }

    func start() {
        guard isTTY else {
            fputs("  \(message)...\n", stream)
            fflush(stream)
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(80))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let frame = self.frames[self.frameIndex % self.frames.count]
            fputs("\r  \(frame) \(self.message)...", self.stream)
            fflush(self.stream)
            self.frameIndex += 1
        }
        self.timer = timer
        timer.resume()
    }

    func stop(success: Bool = true) {
        timer?.cancel()
        timer = nil

        if isTTY {
            let icon = success ? "\u{2714}" : "\u{2718}"
            let clearLen = message.count + 10
            fputs("\r\(String(repeating: " ", count: clearLen))\r", stream)
            fputs("  \(icon) \(message)\n", stream)
            fflush(stream)
        } else if !success {
            fputs("  \u{2718} \(message)\n", stream)
            fflush(stream)
        }
    }
}
