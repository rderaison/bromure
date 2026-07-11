import Foundation

/// Phase-weighted progress for the browser prebuilt-image install — ONE
/// continuous 0…1 bar across the whole flow:
///
///   catalog fetch (→1%) → disk download (→55%) → sparse expansion
///   (→70%) → vmlinuz/initrd (→76%) → Alpine netboot fetch (→80%) →
///   guest-narrated postinstall tail: fonts, personalisation, catalog
///   steps, fsck (→99%) → ready (100%).
///
/// Consumed by Bromure Web's first-run UI (AppState) and by AC's
/// BrowserImageInstaller (via InitProgressModel), so the weights, the
/// message patterns they key on, and the guest-log narration live in
/// exactly one place — next to the code that emits those messages
/// (LinuxImageManager+Remote / ImageFetch / vm-setup/postinstall.sh).
///
/// `fraction` is monotonic; `status` is a narrated, percentage-free
/// line (the bar is the only percentage).
public final class BrowserInstallProgress {
    public private(set) var fraction: Double = 0
    public private(set) var status: String = ""

    private var expectedSteps = 0
    private var completedSteps = 0
    /// Anchor of the guest-narrated tail segment (nil until the
    /// postinstall phase starts).
    private var tailBase: Double?
    /// Partial console line carried between `.consoleOutput` chunks.
    private var consoleTrailing = ""

    public init() {}

    /// Feed every ProgressEvent from `downloadBaseImage`.
    public func note(_ event: ProgressEvent) {
        switch event {
        case .message(let text):
            noteHostMessage(text)
        case .stepStart(let text):
            status = text + "…"
        case .stepDone:
            break
        case .consoleOutput(let chunk):
            noteConsole(chunk)
        case .download(let received, let total):
            // Byte progress of the Alpine netboot tarball (the postinstall
            // VM's installer) — fills the 78→80% sliver before the tail.
            if total > 0, tailBase == nil, fraction >= 0.77 {
                bump(to: 0.78 + 0.02 * min(1.0, Double(received) / Double(total)))
            }
        case .install:
            break
        }
    }

    /// Host-side progress messages (the `.message` events).
    public func noteHostMessage(_ msg: String) {
        status = Self.strippingTrailingPercent(from: msg)
        let m = msg.lowercased()
        if m.contains("base image ready") || m.contains("packages installed")
            || m.contains("linux image created") {
            bump(to: 1.0)
            return
        }
        if m.hasPrefix("fetching image catalog") {
            bump(to: 0.01)
            return
        }
        // "Downloading Alpine Linux 3.22 + Chromium image (1.5 GB)… 37%"
        if m.hasPrefix("downloading"), m.contains(" image ("), m.hasSuffix("%") {
            if let pct = Self.trailingPercent(of: m) {
                bump(to: 0.55 * pct)
            }
            return
        }
        // The sparse expander's own "Expanding image… 45%" (disk only —
        // the boot artifacts are too small to report progress).
        if m.hasPrefix("expanding image"), m.hasSuffix("%") {
            bump(to: 0.55 + 0.15 * (Self.trailingPercent(of: m) ?? 0.0))
            return
        }
        if m.hasPrefix("downloading vmlinuz") {
            bump(to: 0.70 + 0.03 * (Self.trailingPercent(of: m) ?? 0.0))
            return
        }
        if m.hasPrefix("downloading initrd") {
            bump(to: 0.73 + 0.03 * (Self.trailingPercent(of: m) ?? 0.0))
            return
        }
        if m.hasPrefix("downloading alpine netboot") {
            bump(to: 0.78)
            return
        }
        // "Installing recommended packages (1 step(s)) and personalizing…"
        // or "Personalizing image (fonts, keyboard, locale)…" — anchor the
        // guest-narrated tail segment at the bar's current position.
        if m.hasPrefix("installing recommended packages") || m.hasPrefix("personalizing image") {
            if let n = Self.firstInt(of: m), n > 0 {
                expectedSteps = n
                completedSteps = 0
            }
            tailBase = max(fraction, tailBase ?? 0)
            return
        }
    }

    /// One complete guest console line. postinstall.sh's
    /// `[browser-postinstall*]` log lines narrate the status and advance
    /// the tail segment (fonts → chroot → per-step BEGIN/END → fsck).
    public func noteGuestLine(_ line: String) {
        guard line.contains("[browser-postinstall]")
            || line.contains("[browser-postinstall-chroot]") else { return }
        let base = tailBase ?? fraction
        let span = max(0, 0.99 - base)
        func bumpTail(_ f: Double) { bump(to: base + span * f) }

        if line.contains("mounting installed system") {
            status = String(localized: "Preparing the downloaded image…")
            bumpTail(0.03)
        } else if line.contains("personalising:") {
            status = String(localized: "Personalizing (keyboard, language, fonts)…")
            bumpTail(0.06)
        } else if line.contains("macOS font files") {
            // "copied 213 macOS font files" — surface the count verbatim.
            status = line.replacingOccurrences(of: "[browser-postinstall] ", with: "")
            bumpTail(0.35)
        } else if line.contains("entering alpine chroot") {
            bumpTail(0.40)
        } else if let name = Self.stepName(of: line, marker: "BEGIN step ") {
            status = String(format: String(localized: "Installing %@…"), name)
            let n = max(1, expectedSteps)
            bumpTail(0.40 + (Double(completedSteps) + 0.5) / Double(n) * 0.50)
        } else if let name = Self.stepName(of: line, marker: "END   step ") {
            status = String(format: String(localized: "Installed %@"), name)
            completedSteps += 1
            let n = max(completedSteps, max(1, expectedSteps))
            bumpTail(0.40 + Double(completedSteps) / Double(n) * 0.50)
        } else if line.contains("running final e2fsck") {
            status = String(localized: "Checking filesystem integrity…")
            bumpTail(0.95)
        } else if line.contains("all done") {
            status = String(localized: "Finalizing…")
            bumpTail(1.0)
        }
    }

    /// Raw `.consoleOutput` chunk — split into complete lines (the guest
    /// serial console emits CR/CRLF endings) and narrate each.
    private func noteConsole(_ chunk: String) {
        let normalized = chunk
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var buf = consoleTrailing + normalized
        consoleTrailing = ""
        while let nl = buf.firstIndex(of: "\n") {
            noteGuestLine(String(buf[..<nl]))
            buf = String(buf[buf.index(after: nl)...])
        }
        consoleTrailing = buf
    }

    private func bump(to value: Double) {
        let v = max(0.0, min(1.0, value))
        if v > fraction { fraction = v }
    }

    // MARK: - Parsing helpers

    /// "…foo… 37%" → 0.37. nil when the message doesn't end in a percent.
    static func trailingPercent(of msg: String) -> Double? {
        guard msg.hasSuffix("%") else { return nil }
        let digits = msg.dropLast().reversed().prefix(while: { $0.isNumber })
        guard !digits.isEmpty, let value = Int(String(digits.reversed())) else { return nil }
        return min(1.0, Double(value) / 100.0)
    }

    /// Drop a trailing " NN%" so the status carries no second percentage
    /// next to the bar's.
    public static func strippingTrailingPercent(from msg: String) -> String {
        guard msg.hasSuffix("%") else { return msg }
        var s = msg.dropLast()
        let digitsEnd = s.endIndex
        while let c = s.last, c.isNumber { s = s.dropLast() }
        guard s.endIndex != digitsEnd else { return msg }  // bare "%" — leave it
        while s.last == " " { s = s.dropLast() }
        return String(s)
    }

    /// First run of digits in the message ("(4 step(s)…" → 4).
    private static func firstInt(of msg: String) -> Int? {
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

    /// "…BEGIN step Cloudflare WARP client" → "Cloudflare WARP client".
    private static func stepName(of line: String, marker: String) -> String? {
        guard let r = line.range(of: marker) else { return nil }
        let name = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}
