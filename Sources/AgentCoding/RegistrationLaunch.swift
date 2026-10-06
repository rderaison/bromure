import Foundation

/// Starting (and proving we started) the login CLI inside a "Register with …"
/// throwaway VM.
///
/// The guest `.bashrc` auto-launch (`BROMURE_AC_REGISTER=1`) is only a fast
/// path: window 0 of the tmux session can be spawned by agentd before the
/// virtiofs home lands (it then sources the image's stock `.bashrc` and sits
/// at a bare prompt), or the CLI can exit / still be installing. The old host
/// fallback fired ONE `send-keys` 2.5 s after the first roster tick — gated on
/// the pane being a shell — and never looked again, so a pane that was still
/// busy at that instant, or a guest exec that wasn't ready yet, left the
/// registration at a bare `bash` until the 4-minute credential poll timed out.
///
/// Now the host probes repeatedly: is the login process running? is the pane
/// an idle shell? It types the login command (re-sourcing `.bashrc` first, so
/// the proxy / env the CLI needs are present even in a shell that started
/// before the home mount) only after the pane has been an idle shell for two
/// consecutive probes, re-sends a bounded number of times, and gives up with
/// a clear reason the UI can turn into a Retry prompt.
enum RegistrationLaunch {

    /// The CLI's dedicated login subcommand: straight to the browser hand-off,
    /// no TUI wizard in between (nobody is at this terminal).
    static func loginCommand(for provider: SubscriptionProvider) -> String {
        switch provider {
        case .claude: return "claude auth login --claudeai"
        case .codex:  return "codex login"
        case .grok:   return "grok login"
        case .kimi:   return "kimi login"
        }
    }

    /// ERE (`ps -eo args= | grep -E`) matching the running login process (native binary or a
    /// `node …/bin/<tool> login` script). The bracketed first letter keeps the
    /// pattern from matching the probe's own `bash -c` / `grep` command lines.
    static func processPattern(for provider: SubscriptionProvider) -> String {
        switch provider {
        case .claude: return "(^|/)[c]laude auth login"
        case .codex:  return "(^|/)[c]odex login"
        case .grok:   return "(^|/)[g]rok login"
        case .kimi:   return "(^|/)[k]imi login"
        }
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// One line of output: `nosession`, `running`, `shell`, or `busy:<cmd>`.
    static func probeScript(for provider: SubscriptionProvider) -> String {
        let pat = shellQuote(processPattern(for: provider))
        return "if ! tmux has-session -t bromure 2>/dev/null; then echo nosession; exit 0; fi; "
            + "if ps -eo args= 2>/dev/null | grep -qE \(pat); then echo running; exit 0; fi; "
            + "cur=$(tmux display-message -p -t bromure '#{pane_current_command}' 2>/dev/null); "
            + "case \"$cur\" in bash|sh|zsh|dash|fish|-bash|-sh|-zsh) echo shell ;; "
            + "*) echo \"busy:$cur\" ;; esac"
    }

    /// Types the login command into the session's active pane. `.bashrc` is
    /// re-sourced with stdout off a tty, so its own auto-launch (`[ -t 1 ]`)
    /// stays quiet while the proxy + per-session env it exports are applied;
    /// a missing CLI gets the same one-shot install the auto-launch uses.
    static func launchScript(for provider: SubscriptionProvider) -> String {
        let tool = provider.scratchTool.rawValue
        let typed = " [ -r ~/.bashrc ] && . ~/.bashrc >/dev/null 2>&1; "
            + "command -v \(tool) >/dev/null 2>&1 || _bromure_install_tool \(tool); "
            + loginCommand(for: provider)
        return "tmux send-keys -t bromure C-u; "
            + "tmux send-keys -t bromure -l -- \(shellQuote(typed)) && "
            + "tmux send-keys -t bromure Enter"
    }

    enum Probe: Equatable {
        case running
        case shell
        case busy(String)
        /// No tmux session yet, or the guest exec itself failed.
        case unreachable

        init(output: String?) {
            guard let line = output?
                .split(whereSeparator: \.isNewline).last
                .map({ $0.trimmingCharacters(in: .whitespaces) }) else {
                self = .unreachable; return
            }
            switch line {
            case "running": self = .running
            case "shell": self = .shell
            case "nosession", "": self = .unreachable
            default:
                self = line.hasPrefix("busy:") ? .busy(String(line.dropFirst(5))) : .unreachable
            }
        }
    }

    enum Failure: Equatable {
        /// The guest never answered (no tmux session / exec failures).
        case unreachable
        /// We typed the command `maxSends` times and no login process ever ran.
        case didNotStart
        /// The pane stayed busy with something else the whole time.
        case stuck(String)
    }

    enum Action: Equatable {
        case wait
        case send
        case confirmed
        case fail(Failure)
    }

    /// Pure decision logic (unit-tested); the coordinator feeds it one probe
    /// every `probeInterval` seconds.
    struct Tracker {
        var maxSends = 3
        /// Seconds after a send before an idle shell counts as "it didn't
        /// start" and we type it again (covers a slow first node start).
        var resendAfter: TimeInterval = 12
        /// Overall budget from the first probe.
        var deadline: TimeInterval = 120

        private(set) var start: Date?
        private(set) var sends = 0
        private(set) var lastSend: Date?
        private var idleStreak = 0
        private var lastBusy: String?

        init(maxSends: Int = 3, resendAfter: TimeInterval = 12, deadline: TimeInterval = 120) {
            self.maxSends = maxSends
            self.resendAfter = resendAfter
            self.deadline = deadline
        }

        mutating func next(_ probe: Probe, now: Date = Date()) -> Action {
            if start == nil { start = now }
            let elapsed = now.timeIntervalSince(start ?? now)
            switch probe {
            case .running:
                return .confirmed
            case .shell:
                idleStreak += 1
                lastBusy = nil
                let sinceSend = lastSend.map { now.timeIntervalSince($0) } ?? .infinity
                if sends >= maxSends {
                    return sinceSend >= resendAfter ? .fail(.didNotStart) : .wait
                }
                // Two idle probes in a row: the .bashrc auto-launch had its
                // chance (it runs the CLI in the foreground, so the pane would
                // not read as a shell).
                if idleStreak >= 2, sinceSend >= resendAfter {
                    sends += 1
                    lastSend = now
                    idleStreak = 0
                    return .send
                }
                return elapsed > deadline ? .fail(.didNotStart) : .wait
            case .busy(let cmd):
                idleStreak = 0
                lastBusy = cmd
                return elapsed > deadline ? .fail(.stuck(cmd)) : .wait
            case .unreachable:
                idleStreak = 0
                if elapsed > deadline {
                    return .fail(lastBusy.map { .stuck($0) } ?? (sends > 0 ? .didNotStart : .unreachable))
                }
                return .wait
            }
        }
    }

    /// User-facing reason for a failed launch.
    static func failureMessage(_ failure: Failure, provider: SubscriptionProvider) -> String {
        switch failure {
        case .unreachable:
            return String(format: NSLocalizedString(
                "The sign-in machine didn't become ready, so the %@ sign-in couldn't start.",
                comment: "registration launch failure"), provider.displayName)
        case .didNotStart:
            return String(format: NSLocalizedString(
                "The %@ sign-in command didn't start in the sign-in machine.",
                comment: "registration launch failure"), provider.displayName)
        case .stuck(let cmd):
            return String(format: NSLocalizedString(
                "The sign-in machine stayed busy (%@), so the %@ sign-in couldn't start.",
                comment: "registration launch failure; first %@ = process name"),
                cmd.isEmpty ? "?" : cmd, provider.displayName)
        }
    }
}
