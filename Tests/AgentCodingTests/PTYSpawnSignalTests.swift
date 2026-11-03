import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-670): the apps ignore SIGPIPE (their socket writes want
/// EPIPE), an ignored signal survives exec, and a shell leaves it ignored
/// for what it runs — in an interactive exec shell `yes | head` (or the find
/// shim piped into head) never stopped.
@Suite("PTY spawn: the child gets SIGPIPE back")
struct PTYSpawnSignalTests {
    @Test("a pipeline in a PTY child stops its writer when the reader exits, even with SIGPIPE ignored here")
    func sigpipeRestored() {
        let previous = signal(SIGPIPE, SIG_IGN)
        defer { signal(SIGPIPE, previous) }
        var win = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        let (pid, master) = PTYSpawn.spawn(
            path: "/bin/bash",
            argv: ["/bin/bash", "-c", #"yes | head -c1 >/dev/null; echo "S=${PIPESTATUS[0]}""#],
            env: ["PATH=/usr/bin:/bin"], win: &win)
        #expect(pid > 0)
        guard pid > 0 else { return }
        defer { close(master) }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 1024)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !String(decoding: out, as: UTF8.self).contains("\n") {
            let n = read(master, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        // 141 = 128 + SIGPIPE: `yes` was killed by it, not left writing into
        // EPIPE (which would read 1).
        #expect(String(decoding: out, as: UTF8.self).contains("S=141"))
    }
}
