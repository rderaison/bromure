import Foundation
import Testing
@testable import bromure_ac

/// "Register with …" launch watchdog: the host must keep checking that the
/// login CLI really runs in the throwaway VM (it used to fire one send-keys
/// and give up, leaving a bare `bash` until the 4-minute timeout), and the
/// registration flow must never block the main queue in `runModal`.
@Suite("Registration login launch")
struct RegistrationLaunchTests {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("Login commands are each CLI's dedicated login subcommand")
    func loginCommands() {
        #expect(RegistrationLaunch.loginCommand(for: .claude) == "claude auth login --claudeai")
        #expect(RegistrationLaunch.loginCommand(for: .codex) == "codex login")
        #expect(RegistrationLaunch.loginCommand(for: .grok) == "grok login")
        #expect(RegistrationLaunch.loginCommand(for: .kimi) == "kimi login")
    }

    @Test("Probe output parsing")
    func probeParsing() {
        #expect(RegistrationLaunch.Probe(output: "running\n") == .running)
        #expect(RegistrationLaunch.Probe(output: "shell") == .shell)
        #expect(RegistrationLaunch.Probe(output: "busy:npx\n") == .busy("npx"))
        #expect(RegistrationLaunch.Probe(output: "nosession") == .unreachable)
        #expect(RegistrationLaunch.Probe(output: nil) == .unreachable)
        #expect(RegistrationLaunch.Probe(output: "") == .unreachable)
    }

    @Test("A running login process confirms at once — nothing is typed")
    func runningConfirms() {
        var t = RegistrationLaunch.Tracker()
        #expect(t.next(.running, now: t0) == .confirmed)
        #expect(t.sends == 0)
    }

    @Test("A bare shell gets the command after two idle probes, then confirms")
    func bareShellSends() {
        var t = RegistrationLaunch.Tracker()
        #expect(t.next(.shell, now: t0) == .wait)
        #expect(t.next(.shell, now: t0.addingTimeInterval(2)) == .send)
        #expect(t.sends == 1)
        // Right after the send the pane still reads as a shell: no double type.
        #expect(t.next(.shell, now: t0.addingTimeInterval(4)) == .wait)
        #expect(t.next(.shell, now: t0.addingTimeInterval(6)) == .wait)
        #expect(t.next(.running, now: t0.addingTimeInterval(8)) == .confirmed)
    }

    @Test("A busy pane (bashrc still installing / running) is never typed into")
    func busyWaits() {
        var t = RegistrationLaunch.Tracker()
        for i in 0..<20 {
            #expect(t.next(.busy("npx"), now: t0.addingTimeInterval(Double(i) * 2)) == .wait)
        }
        #expect(t.sends == 0)
        // The old one-shot path gave up here; now an idle shell after the
        // busy stretch still gets the command.
        #expect(t.next(.shell, now: t0.addingTimeInterval(42)) == .wait)
        #expect(t.next(.shell, now: t0.addingTimeInterval(44)) == .send)
    }

    @Test("Unreachable guest early on is waited out, not failed")
    func unreachableWaits() {
        var t = RegistrationLaunch.Tracker()
        #expect(t.next(.unreachable, now: t0) == .wait)
        #expect(t.next(.unreachable, now: t0.addingTimeInterval(30)) == .wait)
        #expect(t.next(.shell, now: t0.addingTimeInterval(32)) == .wait)
        #expect(t.next(.shell, now: t0.addingTimeInterval(34)) == .send)
    }

    @Test("Resends are bounded, then the launch fails with a reason")
    func boundedResends() {
        var t = RegistrationLaunch.Tracker(maxSends: 3, resendAfter: 12, deadline: 600)
        var now = t0
        var sends = 0
        var outcome: RegistrationLaunch.Action = .wait
        for _ in 0..<200 {
            outcome = t.next(.shell, now: now)
            if outcome == .send { sends += 1 }
            if case .fail = outcome { break }
            now = now.addingTimeInterval(2)
        }
        #expect(sends == 3)
        #expect(outcome == .fail(.didNotStart))
    }

    @Test("Deadline: stuck / unreachable reasons")
    func deadlineReasons() {
        var stuck = RegistrationLaunch.Tracker(deadline: 10)
        _ = stuck.next(.busy("python3"), now: t0)
        #expect(stuck.next(.busy("python3"), now: t0.addingTimeInterval(11)) == .fail(.stuck("python3")))

        var gone = RegistrationLaunch.Tracker(deadline: 10)
        _ = gone.next(.unreachable, now: t0)
        #expect(gone.next(.unreachable, now: t0.addingTimeInterval(11)) == .fail(.unreachable))
    }

    @Test("Probe and launch scripts are valid shell for every provider")
    func scriptsParse() throws {
        for p in SubscriptionProvider.allCases {
            for script in [RegistrationLaunch.probeScript(for: p),
                           RegistrationLaunch.launchScript(for: p)] {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/bash")
                proc.arguments = ["-n", "-c", script]
                try proc.run()
                proc.waitUntilExit()
                #expect(proc.terminationStatus == 0, "\(p): \(script)")
            }
            let launch = RegistrationLaunch.launchScript(for: p)
            #expect(launch.contains(RegistrationLaunch.loginCommand(for: p)))
            // Re-sources .bashrc with stdout off the tty, so its own
            // auto-launch (`[ -t 1 ]`) can't start a second login.
            #expect(launch.contains(". ~/.bashrc >/dev/null 2>&1"))
        }
    }

    @Test("The process pattern matches the login CLI but not the probe itself")
    func patternMatching() throws {
        for p in SubscriptionProvider.allCases {
            let re = try NSRegularExpression(pattern: RegistrationLaunch.processPattern(for: p))
            func matches(_ s: String) -> Bool {
                re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
            }
            let cmd = RegistrationLaunch.loginCommand(for: p)
            #expect(matches(cmd), "\(p) native")
            #expect(matches("node /usr/local/bin/\(cmd)"), "\(p) node script")
            #expect(!matches("bash -c " + RegistrationLaunch.probeScript(for: p)), "\(p) self-match")
            #expect(!matches("-bash"), "\(p) shell")
        }
    }

    @Test("Registration never enters a modal loop")
    func noRunModal() throws {
        let src = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentCoding/ClaudeRegistrationCoordinator.swift")
        let text = try String(contentsOf: src, encoding: .utf8)
        let code = text.split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(!code.contains(".runModal("))
        #expect(!code.contains("showError("))
    }
}
