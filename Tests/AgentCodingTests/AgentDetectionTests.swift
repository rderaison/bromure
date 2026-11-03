import Foundation
import Testing
@testable import bromure_ac

/// Board: "New session doesn't work in fat-client mode" — Start on a
/// Sidecar did nothing. The Sidecar refused every start with "Claude Code
/// isn't installed on this Mac": at launch its login-shell scan was killed
/// on its timeout, printed nothing, and every agent was recorded missing.
/// (The fat client dropped the refusal; it now shows it.)
@Suite("Sidecar agent scan: a scan that didn't finish calls nothing missing")
struct AgentDetectionTests {
    private func fakeBin(_ agents: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, body) in agents {
            let f = dir.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body + "\n").write(to: f, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        }
        return dir
    }

    /// The scan script in a shell, killed after `killAfter` like the
    /// Sidecar's timeout does.
    private func runScan(_ ids: [String], bin: URL, killAfter: TimeInterval) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", AgentDetection.script(ids, extraBins: [])]
        p.environment = ["PATH": bin.path + ":/usr/bin:/bin", "HOME": NSHomeDirectory()]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        DispatchQueue.global().asyncAfter(deadline: .now() + killAfter) {
            if p.isRunning { p.terminate() }
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test("a complete scan finds what's there and calls the rest missing")
    func completeScan() throws {
        let bin = try fakeBin(["claude": "echo '2.1.296 (Claude Code)'"])
        let scan = AgentDetection.parse(try runScan(["claude", "kimi"], bin: bin, killAfter: 20))
        #expect(scan.complete)
        #expect(scan.found["claude"]?.path == bin.appendingPathComponent("claude").path)
        #expect(scan.found["claude"]?.version == "2.1.296 (Claude Code)")
        #expect(AgentDetection.missing(["claude", "kimi"], scan: scan, onDisk: [:]) == ["kimi"])
    }

    @Test("a --version that hangs: the shell is killed, the path is kept, nothing is missing")
    func killedScan() throws {
        let bin = try fakeBin(["claude": "exec sleep 30"])
        let out = try runScan(["claude", "kimi"], bin: bin, killAfter: 1.5)
        let scan = AgentDetection.parse(out)
        #expect(!scan.complete)
        #expect(scan.found["claude"]?.path == bin.appendingPathComponent("claude").path)
        #expect(scan.found["claude"]?.version == nil)
        #expect(AgentDetection.missing(["claude", "kimi"], scan: scan, onDisk: [:]).isEmpty)
        // The launch-time case: a shell that printed nothing at all.
        #expect(AgentDetection.missing(["claude"], scan: AgentDetection.parse(""), onDisk: [:]).isEmpty)
    }

    @Test("an installer's folder counts without a shell; rc noise is ignored")
    func onDiskAndNoise() throws {
        let bin = try fakeBin(["claude": "true"])
        let disk = AgentDetection.onDisk(["claude", "codex"], dirs: ["$HOME/nowhere", bin.path], home: NSHomeDirectory())
        #expect(disk == ["claude": bin.appendingPathComponent("claude").path])
        // A folder named like an agent is searchable, not an agent; a symlink
        // to a real binary (the installers' layout) is one.
        let other = try fakeBin([:])
        try FileManager.default.createDirectory(at: other.appendingPathComponent("codex"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: other.appendingPathComponent("kimi"),
                                                   withDestinationURL: bin.appendingPathComponent("claude"))
        #expect(AgentDetection.onDisk(["codex", "kimi"], dirs: [other.path], home: NSHomeDirectory())
                == ["kimi": other.appendingPathComponent("kimi").path])
        var scan = AgentDetection.parse("Welcome!\n@@P@@ broken\n\(AgentDetection.endMarker)\n")
        #expect(scan.complete && scan.found.isEmpty)
        #expect(AgentDetection.missing(["claude", "codex"], scan: scan, onDisk: disk) == ["codex"])
        scan = AgentDetection.parse("@@V@@claude|1.0@@\n")   // a version with no path: nothing
        #expect(scan.found.isEmpty)
    }

    /// Finding: "Unfinished Sidecar agent scan leaves Manage Agents spinning
    /// on Checking" — a scan killed on its timeout latched the window's one
    /// chance to preselect Claude, with no verdict to go on.
    @Test("a scan that didn't finish preselects nothing and leaves the choice to the next")
    func preselection() {
        let killed = AgentDetection.parse("@@P@@codex|/opt/homebrew/bin/codex@@\n")
        #expect(!killed.complete)
        let missing = AgentDetection.missing(["claude", "codex"], scan: killed, onDisk: [:])
        #expect(AgentDetection.preselection(complete: killed.complete, missing: missing) == nil)
        let done = AgentDetection.parse("@@P@@codex|/opt/homebrew/bin/codex@@\n\(AgentDetection.endMarker)\n")
        #expect(AgentDetection.preselection(complete: done.complete,
                                            missing: AgentDetection.missing(["claude", "codex"], scan: done, onDisk: [:])) == ["claude"])
        #expect(AgentDetection.preselection(complete: true, missing: ["codex"]) == [])
    }

    @Test("a refused start says why")
    func startFailureWords() {
        let why = "Claude Code isn't installed on this Mac. Install it from Manage Agents… in the Bromure Sidecar menu."
        #expect(RemoteHostController.startFailure(status: 400, json: ["error": why]) == why)
        #expect(RemoteHostController.startFailure(status: 502, json: [:]).contains("502"))
        #expect(RemoteHostController.startFailure(status: nil, json: [:]).contains("didn't answer"))
    }
}
