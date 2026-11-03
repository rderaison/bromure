import Foundation
import Testing
@testable import bromure_ac

/// Adding an imported key never waits on a terminal: a launch hung for 20
/// minutes on an `ssh-add` stopped (SIGTTOU) at a passphrase prompt on the
/// shell the app was started from.
@Suite("Imported SSH keys: ssh-add never prompts")
struct SSHAddNoPromptTests {

    private func tempDir() throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/bac-sshadd-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func run(_ path: String, _ args: [String], env: [String: String]? = nil) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let env { p.environment = env }
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        return p.terminationStatus
    }

    @Test("the askpass gives the passphrase once, then refuses; none at all refuses at once")
    func askpassAnswersOnce() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("askpass.sh")
        try ACAppDelegate.askpassScript(passphrase: "it's secret").write(to: url, atomically: true, encoding: .utf8)
        chmod(url.path, 0o700)
        func ask() throws -> (Int32, String) {
            let p = Process(), out = Pipe()
            p.executableURL = url
            p.standardOutput = out
            try p.run(); p.waitUntilExit()
            return (p.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        }
        #expect(try ask() == (0, "it's secret\n"))
        #expect(try ask().0 != 0)
        #expect(ACAppDelegate.askpassScript(passphrase: nil) == "#!/bin/sh\nexit 1\n")
    }

    @Test("a process that doesn't finish is killed at the deadline")
    func boundedWait() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["30"]
        let t0 = Date()
        #expect(try ACAppDelegate.runBounded(p, seconds: 0.5) == false)
        #expect(Date().timeIntervalSince(t0) < 3)
        #expect(!p.isRunning)
    }

    @Test("ssh-add on an encrypted key, with no passphrase or a wrong one, gives up instead of prompting")
    func encryptedKeyFailsFast() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = dir.appendingPathComponent("id_test").path
        #expect(try run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "right", "-f", key]) == 0)
        let sock = dir.appendingPathComponent("agent.sock").path
        let agent = Process()
        agent.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-agent")
        agent.arguments = ["-D", "-a", sock]
        agent.standardOutput = FileHandle.nullDevice
        agent.standardError = FileHandle.nullDevice
        try agent.run()
        defer { agent.terminate() }
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: sock) { usleep(100_000) }

        for (pass, expectAdded) in [(nil, false), ("wrong", false), ("right", true)] as [(String?, Bool)] {
            let askpass = dir.appendingPathComponent("askpass-\(UUID().uuidString.prefix(6)).sh")
            try ACAppDelegate.askpassScript(passphrase: pass).write(to: askpass, atomically: true, encoding: .utf8)
            chmod(askpass.path, 0o700)
            var env = ProcessInfo.processInfo.environment
            env["SSH_AUTH_SOCK"] = sock
            env["SSH_ASKPASS"] = askpass.path
            env["DISPLAY"] = ":0"
            env["SSH_ASKPASS_REQUIRE"] = "force"
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
            p.arguments = [key]
            p.environment = env
            p.standardInput = FileHandle(forReadingAtPath: "/dev/null")
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            #expect(try ACAppDelegate.runBounded(p, seconds: 10), "ssh-add hung with passphrase \(pass ?? "none")")
            #expect((p.terminationStatus == 0) == expectAdded, "passphrase \(pass ?? "none")")
        }
    }
}
