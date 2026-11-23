import Foundation

/// The image install's progress, as macOS's setup window computes it
/// (InitProgressModel, SetupViews.swift): 0…1, never going back.
///
/// The local bake is line-driven: each installer console line moves the bar
/// by 1/`expectedTotalLines`, up to `progressCeiling`, and "Base image
/// ready" ends it. The download path maps its phases (the download 0→60%,
/// the expansion 60→80%) and each finished postinstall step (the guest's
/// "END   step" line) over the rest. The CLI draws it (bromure-ac's
/// ProgressBar); macOS's model is SwiftUI state, this is its accounting.
// partial: no console pane (the CLI's --verbose echoes the console) and no browser-image mode (Bromure Web's installer isn't on the server)
public final class InstallProgress: @unchecked Sendable {
    private let lock = NSLock()

    /// 0…1, monotonic.
    public private(set) var progress: Double = 0.0
    /// The latest host step, its trailing percentage stripped (the bar
    /// shows the one percentage).
    public private(set) var status = "Preparing…"
    /// Every console line seen (calibrates `expectedTotalLines`).
    public private(set) var linesSeen = 0

    /// Lines a full bake prints, calibrated on macOS (≈7056 on a fresh
    /// debootstrap + apt + npm chain), with a margin.
    var expectedTotalLines = 7500
    /// Line-driven progress stops here, so the end always has some way to go.
    static let progressCeiling = 0.97

    private var expectedPostinstallSteps = 0
    private var completedPostinstallSteps = 0
    private var postinstallBase: Double?
    private var trailing = ""

    // @port-skip linux-only: InitProgressModel's initial state is its property defaults
    public init() {}

    /// Back to the start, for another run.
    // partial: the line-count accounting and phases only (no console log, no browser mode, no proxy-unreachable callback)
    // @port InitProgressModel.reset() h=75a75bfff20e313b @84e171b88
    public func reset() {
        lock.withLock {
            status = "Preparing…"
            progress = 0
            linesSeen = 0
            trailing = ""
            expectedPostinstallSteps = 0
            completedPostinstallSteps = 0
            postinstallBase = nil
            expectedTotalLines = 7500
        }
    }

    /// The bar to at least `value`, within 0…1.
    // @port InitProgressModel.bumpProgress(to: Double) h=86645979e8acdb25 @84e171b88
    public func bumpProgress(to value: Double) {
        lock.withLock { bump(value) }
    }

    // @port-skip linux-only: bumpProgress under the caller's lock
    private func bump(_ value: Double) {
        let v = max(0.0, min(1.0, value))
        if v > progress { progress = v }
    }

    /// A host step: the status, and its phase on the bar.
    // partial: no console bookmark (the CLI prints the step itself)
    // @port InitProgressModel.noteHostProgress(_: String) h=438275164fe24d8c @84e171b88
    public func noteHostProgress(_ msg: String) {
        lock.withLock {
            status = Self.strippingTrailingPercent(from: msg)
            recordHostPhase(msg)
        }
    }

    /// The local bake's bookends and the download path's phases.
    // @port InitProgressModel.recordHostPhase(_: String) h=517a36078f41ca22 @84e171b88
    private func recordHostPhase(_ msg: String) {
        let m = msg.lowercased()
        if m.contains("base image already at") || m.contains("base image ready")
            || m.contains("packages installed") {
            bump(1.0)
            return
        }
        // "Downloading Ubuntu 24.04 image (2.9 GB)… 37%" → 0…0.60.
        if m.hasPrefix("downloading"), m.contains("image"), m.hasSuffix("%") {
            if let pct = Self.trailingPercent(of: m) { bump(0.60 * pct) }
            return
        }
        if m.hasPrefix("verifying checksum") {
            bump(0.60)
            return
        }
        // "Expanding image…" / "Expanding image… 45%" → 0.60…0.80.
        if m.hasPrefix("expanding image") {
            bump(0.60 + 0.20 * (Self.trailingPercent(of: m) ?? 0.0))
            return
        }
        if m.hasPrefix("reusing the saved") {
            bump(0.80)
            return
        }
        // "Installing recommended packages (4 step(s)…": the last segment
        // starts where the bar is; each "END   step" line advances it.
        if m.hasPrefix("installing recommended packages") {
            if let n = Self.firstInt(of: m), n > 0 {
                expectedPostinstallSteps = n
                completedPostinstallSteps = 0
                postinstallBase = progress
            }
            return
        }
    }

    /// The installer's console output: each line moves the bar.
    // partial: counts and steps only (no console log kept, no browser narration, no proxy-unreachable callback)
    // @port InitProgressModel.appendLog(_: String) h=af9030da567d058f @84e171b88
    public func appendLog(_ chunk: String) {
        lock.withLock {
            let normalized = chunk
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            var buf = trailing + normalized
            trailing = ""
            while let nl = buf.firstIndex(of: "\n") {
                let line = buf[..<nl]
                linesSeen += 1
                if expectedPostinstallSteps > 0, line.contains(" END   step ") {
                    completedPostinstallSteps += 1
                    let base = postinstallBase ?? 0
                    let span = max(0, 0.99 - base)
                    let done = min(completedPostinstallSteps, expectedPostinstallSteps)
                    bump(base + span * Double(done) / Double(expectedPostinstallSteps))
                }
                bump(min(Double(linesSeen) / Double(expectedTotalLines), Self.progressCeiling))
                buf = String(buf[buf.index(after: nl)...])
            }
            trailing = buf
        }
    }

    /// "…foo… 37%" → 0.37; nil without a trailing percentage.
    // @port InitProgressModel.static trailingPercent(of: String) h=9538413941d6151d @84e171b88
    static func trailingPercent(of msg: String) -> Double? {
        guard msg.hasSuffix("%") else { return nil }
        let digits = msg.dropLast().reversed().prefix(while: { $0.isNumber })
        guard !digits.isEmpty, let v = Int(String(digits.reversed())) else { return nil }
        return min(1.0, Double(v) / 100.0)
    }

    /// The first run of digits ("(4 step(s)…" → 4).
    // @port InitProgressModel.static firstInt(of: String) h=9860df1685b79355 @84e171b88
    static func firstInt(of msg: String) -> Int? {
        var current = ""
        for ch in msg {
            if ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                break
            }
        }
        return Int(current)
    }

    /// Without a trailing " NN%".
    // @port InitProgressModel.static strippingTrailingPercent(from: String) h=0f4ed0debc367d76 @84e171b88
    static func strippingTrailingPercent(from msg: String) -> String {
        guard msg.hasSuffix("%") else { return msg }
        var s = msg.dropLast()
        let digitsEnd = s.endIndex
        while let c = s.last, c.isNumber { s = s.dropLast() }
        guard s.endIndex != digitsEnd else { return msg }
        while s.last == " " { s = s.dropLast() }
        return String(s)
    }

    /// The CLI's bar line for a terminal `width` columns wide (never
    /// wrapping): `[#######.......]  42.3%  03:12  status`.
    // @port-skip linux-only: the CLI's bar (macOS: SwiftUI's ProgressView)
    public static func line(progress: Double, elapsed: TimeInterval, status: String, width: Int) -> String {
        let cells = max(10, min(30, width / 4))
        let p = max(0, min(1, progress))
        let filled = Int((p * Double(cells)).rounded(.down))
        let bar = "[" + String(repeating: "#", count: filled) + String(repeating: ".", count: cells - filled) + "]"
        let secs = Int(elapsed)
        let clock = secs >= 3600 ? String(format: "%d:%02d:%02d", secs / 3600, secs / 60 % 60, secs % 60)
                                 : String(format: "%02d:%02d", secs / 60, secs % 60)
        let full = "\(bar) \(String(format: "%5.1f%%", p * 100))  \(clock)  \(status)"
        return full.count < width ? full : String(full.prefix(max(1, width - 1)))
    }

}
