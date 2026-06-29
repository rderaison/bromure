import Foundation

/// Presents consent prompts inside a workspace's tmux when the session is being
/// driven over SSH/CLI (no GUI to host an NSAlert). The MITM consent brokers
/// route through this in remote mode; GUI-fronted sessions keep their NSAlert.
///
/// FAIL-SAFE: any failure — exec error, timeout, dismissed popup, garbled answer
/// — returns nil, and every broker maps nil to DENY. A glitch can never silently
/// auto-allow a credential or a flagged request.
public enum RemoteConsent {
    /// Run a command in the workspace's VM and return its stdout (nil on
    /// failure). Set by the app (shell-bridge exec). Blocking — invoked off the
    /// main actor by `choose`.
    nonisolated(unsafe) public static var execInVM:
        (@Sendable (_ profileID: UUID, _ command: String, _ timeoutSeconds: Int) -> String?)?
    /// True when the session has no GUI window (SSH/CLI/headless) and should be
    /// prompted in tmux instead of via NSAlert.
    nonisolated(unsafe) public static var isRemoteSession:
        (@Sendable (_ profileID: UUID) -> Bool)?

    /// Whether this profile's session should use the tmux popup path.
    public static func isActive(for profileID: UUID) -> Bool {
        let remote = isRemoteSession?(profileID) ?? false
        let active = remote && execInVM != nil
        FileHandle.standardError.write(Data(
            "[consent] route pid=\(profileID.uuidString.prefix(8)) remote=\(remote) exec=\(execInVM != nil) → \(active ? "tmux popup" : "GUI alert")\n".utf8))
        return active
    }

    /// Show `title` + `message` + a numbered menu in the workspace's `bromure`
    /// tmux popup; return the chosen 0-based index, or nil (timeout / dismissed /
    /// failure — caller treats as deny). Blocking; call off the main actor.
    public static func choose(profileID: UUID, title: String, message: String,
                              choices: [String], timeoutSeconds: Int = 120) -> Int? {
        guard let exec = execInVM, !choices.isEmpty else { return nil }
        let cmd = popupCommand(title: title, message: message,
                               choices: choices, timeoutSeconds: timeoutSeconds)
        // Give the exec a little longer than the in-popup wait so the guest-side
        // timeout fires first (clean deny) rather than the transport cutting off.
        guard let out = exec(profileID, cmd, timeoutSeconds + 15) else { return nil }
        guard let n = Int(out.trimmingCharacters(in: .whitespacesAndNewlines)),
              n >= 1, n <= choices.count else { return nil }
        return n - 1
    }

    /// A self-contained shell one-liner the host runs in the VM. It renders a
    /// tmux popup (a base64-embedded bash script — no fragile multi-layer
    /// quoting), waits for a single-digit choice, and echoes it to stdout. The
    /// host's exec blocks on the poll loop until the user answers or the in-popup
    /// timeout fires, so the chosen digit comes back as stdout.
    private static func popupCommand(title: String, message: String,
                                     choices: [String], timeoutSeconds: Int) -> String {
        var menu = ""
        for (i, c) in choices.enumerated() {
            menu += "printf '  %s\\n' \(sq("\(i + 1)) \(c)"))\n"
        }
        // The bash script the popup runs. $1 is the result file. `read -t` bounds
        // the wait so an unattended popup self-dismisses (→ empty file → deny).
        let script = """
        #!/usr/bin/env bash
        RF="$1"
        clear
        printf '%s\\n\\n' \(sq(title))
        printf '%s\\n\\n' \(sq(message))
        \(menu)printf '\\nChoice [1-\(choices.count)] (Enter/timeout = deny): '
        read -rsn1 -t \(timeoutSeconds) k || k=""
        printf '%s' "$k" > "$RF"
        """
        let b64 = Data(script.utf8).base64EncodedString()
        // base64 keeps the script opaque to the outer host→exec→bash layer, so
        // only the in-VM bash parses it. Poll the result file, print it, clean up.
        return """
        RF=$(mktemp); SF=$(mktemp); printf %s '\(b64)' | base64 -d > "$SF"; \
        tmux display-popup -t bromure -w 75% -h 60% -E "bash \\"$SF\\" \\"$RF\\"" >/dev/null 2>&1; \
        for _ in $(seq 1 \(timeoutSeconds * 2 + 4)); do [ -s "$RF" ] && break; sleep 0.5; done; \
        cat "$RF" 2>/dev/null; rm -f "$RF" "$SF"
        """
    }

    /// Single-quote for safe embedding in a bash command.
    private static func sq(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
