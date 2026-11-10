import Foundation

/// A cluster machine's boot dying on filesystem errors, read from its
/// serial console (macOS: UbuntuSandboxVM's console scanner, which feeds
/// onBootFilesystemFailure). Here the console is Firecracker's stdout,
/// appended to the VM's serial.log: the scan reads what this boot added.
// @port-skip linux-only: the console scanner of UbuntuSandboxVM, over a log file
enum BootConsoleScan {
    /// The line (or the unterminated tail) that says the boot's fsck failed.
    // @port UbuntuSandboxVM.static fsBootFailureMatch(in: String) h=86dfacb51fadb0cd @592b5699
    static func fsBootFailureMatch(in line: String) -> String? {
        let patterns = [
            "UNEXPECTED INCONSISTENCY",          // e2fsck: preen can't fix, wants -y
            "RUN fsck MANUALLY",
            "fsck failed with exit status",      // systemd-fsck summary line
            "Failed to check file system",
            "You are in emergency mode",
            "Give root password for maintenance",
            "root account is locked",            // Ubuntu: sulogin with no root pw
        ]
        guard patterns.contains(where: { line.contains($0) }) else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.suffix(200))
    }

    /// The daemon-log form of one guest console line, or nil to keep it
    /// out (it stays in the VM's serial log): only trouble -- systemd
    /// FAILED units, kernel panics and oopses, OOM kills, emergency mode,
    /// fsck failures -- ANSI colour stripped, `[guest <name>]` first.
    // @port UbuntuSandboxVM.static consoleLineForAppLog(_: String, name: String) h=73bf638297235b22 @132bb730
    static func consoleLineForAppLog(_ raw: String, name: String) -> String? {
        let line = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        let markers = ["FAILED", "Kernel panic", "Oops:", "BUG:", "Out of memory",
                       "oom-kill", "emergency mode", "Emergency", "end Kernel panic"]
        guard markers.contains(where: { line.contains($0) }) || fsBootFailureMatch(in: line) != nil else { return nil }
        return "[guest \(name)] \(line)"
    }

    /// Follows a VM's serial log while `alive` says so, each trouble line
    /// (consoleLineForAppLog) to `emit` (macOS: the console reader's echo
    /// into the app log).
    // @port-skip linux-only: the console reader of UbuntuSandboxVM.prepare, over a log file
    static func echoTrouble(path: String, name: String, poll: Duration = .seconds(1),
                            alive: @Sendable () async -> Bool, emit: @Sendable (String) -> Void) async {
        var at: UInt64 = 0
        var buffer = Data()
        while !Task.isCancelled, await alive() {
            if let h = FileHandle(forReadingAtPath: path) {
                let size = (try? h.seekToEnd()) ?? 0
                if size < at { at = 0; buffer.removeAll() }
                if size > at {
                    try? h.seek(toOffset: at)
                    let data = (try? h.read(upToCount: Int(min(size - at, 1 << 20)))) ?? Data()
                    at += UInt64(data.count)
                    buffer.append(data)
                }
                try? h.close()
            }
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                if let out = consoleLineForAppLog(line, name: name) { emit(out) }
            }
            if buffer.count > 64 << 10 { buffer.removeAll() }   // a line that never ends
            try? await Task.sleep(for: poll)
        }
    }

    /// Scans `path` from `offset` until a match (returned), or `keepGoing`
    /// says stop (nil), or `timeout`. Each line is checked, and the
    /// partial tail too: the emergency prompts end without a newline.
    /// A file that shrank (recreated) is read from its start.
    // @port-skip linux-only: the console scanner of UbuntuSandboxVM, over a log file
    static func scan(path: String, from offset: UInt64, timeout: Duration = .seconds(240),
                     poll: Duration = .milliseconds(250),
                     keepGoing: @Sendable () async -> Bool) async -> String? {
        var at = offset
        var buffer = Data()
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if let h = FileHandle(forReadingAtPath: path) {
                let size = (try? h.seekToEnd()) ?? 0
                if size < at { at = 0; buffer.removeAll() }
                if size > at {
                    try? h.seek(toOffset: at)
                    let data = (try? h.read(upToCount: Int(min(size - at, 1 << 20)))) ?? Data()
                    at += UInt64(data.count)
                    buffer.append(data)
                }
                try? h.close()
            }
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...nl)
                if let m = fsBootFailureMatch(in: line) { return m }
            }
            if !buffer.isEmpty {
                if let m = fsBootFailureMatch(in: String(decoding: buffer, as: UTF8.self)) { return m }
                if buffer.count > 4096 { buffer.removeFirst(buffer.count - 512) }
            }
            guard await keepGoing() else { return nil }
            try? await Task.sleep(for: poll)
        }
        return nil
    }
}
