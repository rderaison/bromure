import ACLinux
import Foundation
import Glibc

/// The image install's progress in the terminal, macOS's setup-window bar in
/// ASCII: each host step printed as a line, and under them one line redrawn
/// in place, `[#######.......]  42.3%  03:12  Installer: running setup.sh…`.
/// The percentage is macOS's (InstallProgress); the clock ticks every second,
/// so a quiet step (debootstrap unpacking) is visibly still going.
///
/// Only on a terminal and without --verbose (which echoes the console);
/// otherwise the steps are plain lines, as before.
// @port-skip linux-only: the CLI's rendering of InitProgressModel (macOS: SwiftUI's ProgressView in InitializingView)
final class ProgressBar: @unchecked Sendable {
    let model = InstallProgress()
    private let verbose: Bool
    private let drawing: Bool
    private let lock = NSLock()
    private var started = Date()
    private var lastDraw = Date.distantPast
    private var timer: DispatchSourceTimer?

    // @port-skip linux-only: see ProgressBar
    init(verbose: Bool) {
        self.verbose = verbose
        let term = ProcessInfo.processInfo.environment["TERM"] ?? ""
        drawing = !verbose && isatty(STDERR_FILENO) == 1 && term != "dumb"
        guard drawing else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.redraw(force: true) }
        timer = t
        t.resume()
    }

    // @port-skip linux-only: see ProgressBar
    deinit { timer?.cancel() }

    /// A host step (`tag`: [bake], [install]).
    // @port-skip linux-only: see ProgressBar
    func step(_ tag: String, _ msg: String) {
        model.noteHostProgress(msg)
        lock.withLock {
            if drawing { Self.write("\r\u{1B}[2K") }
            Self.write("[\(tag)] \(msg)\n")
            if drawing { draw() }
        }
    }

    /// The installer's console: counted, echoed with --verbose.
    // @port-skip linux-only: see ProgressBar
    func output(_ d: Data) {
        model.appendLog(String(decoding: d, as: UTF8.self))
        if verbose { FileHandle.standardError.write(d) }
        redraw(force: false)
    }

    /// Another run (the local bake after a failed download): the bar from 0.
    // @port-skip linux-only: see ProgressBar
    func restart() {
        model.reset()
        lock.withLock { started = Date() }
    }

    /// The end: the bar full when it worked, and the line left as it is.
    // @port-skip linux-only: see ProgressBar
    func finish(ok: Bool) {
        timer?.cancel()
        timer = nil
        guard drawing else { return }
        if ok { model.bumpProgress(to: 1.0) }
        lock.withLock { draw(); Self.write("\n") }
    }

    // @port-skip linux-only: see ProgressBar
    private func redraw(force: Bool) {
        guard drawing else { return }
        lock.withLock {
            guard force || Date().timeIntervalSince(lastDraw) >= 0.25 else { return }
            draw()
        }
    }

    /// Under the lock.
    // @port-skip linux-only: see ProgressBar
    private func draw() {
        lastDraw = Date()
        Self.write("\r\u{1B}[2K" + InstallProgress.line(progress: model.progress, elapsed: Date().timeIntervalSince(started),
                                             status: model.status, width: Self.columns()))
    }

    // @port-skip linux-only: see ProgressBar
    static func columns() -> Int {
        var ws = winsize()
        if ioctl(STDERR_FILENO, UInt(TIOCGWINSZ), &ws) == 0, ws.ws_col > 0 { return Int(ws.ws_col) }
        return 80
    }

    // @port-skip linux-only: see ProgressBar
    private static func write(_ s: String) { FileHandle.standardError.write(Data(s.utf8)) }
}
