import Foundation
import Testing
@testable import bromure_ac

// `guardedTypeCommand` against a real tmux: a private server (its own socket
// dir), a "bromure" session whose window 0 shows a picker and window 1 a bare
// prompt. Skipped when tmux isn't installed.

@Suite("Guarded typing into agent tabs")
struct GuardedTypeTests {

    private static func tmuxPath() -> String? {
        let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux",
                          NSHomeDirectory() + "/Library/Application Support/BromureNative/bin/tmux"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @discardableResult
    private static func sh(_ command: String, env: [String: String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        var e = ProcessInfo.processInfo.environment
        e.removeValue(forKey: "TMUX")
        for (k, v) in env { e[k] = v }
        p.environment = e
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    @Test("holds while a picker is open; types and presses Enter at a bare prompt")
    func holdsOnMenus() throws {
        guard let tmux = Self.tmuxPath() else { return }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gt-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = (tmux as NSString).deletingLastPathComponent
        let env = ["TMUX_TMPDIR": dir.path, "PATH": "\(bin):/usr/bin:/bin", "LC_ALL": "en_US.UTF-8"]
        defer { Self.sh("tmux kill-server", env: env) }

        let picker = "printf 'Try auto mode?\\n\\n❯ 1. Yes, set it up\\n  2. Not now\\n\\nEnter to confirm · Esc to cancel\\n'; exec cat"
        Self.sh("tmux new-session -d -s bromure -x 100 -y 20 \"\(picker)\" && tmux new-window -t bromure:1 'exec cat'", env: env)
        Thread.sleep(forTimeInterval: 0.5)

        let text = "[Delegation notice] @peer asks: 1. hello"
        let held = Self.sh(CodingTaskEngine.guardedTypeCommand(tabIndex: 0, text: text), env: env)
        #expect(held.contains(CodingTaskEngine.typeHeldMarker))
        #expect(!Self.sh("tmux capture-pane -p -t bromure:0", env: env).contains("Delegation notice"))

        let typed = Self.sh(CodingTaskEngine.guardedTypeCommand(tabIndex: 1, text: text), env: env)
        #expect(!typed.contains(CodingTaskEngine.typeHeldMarker))
        Thread.sleep(forTimeInterval: 0.3)
        // cat echoes the line once as typed and once more after Enter.
        let pane = Self.sh("tmux capture-pane -p -t bromure:1", env: env)
        #expect(pane.components(separatedBy: "Delegation notice").count - 1 == 2)
    }
}
