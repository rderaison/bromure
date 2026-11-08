import Foundation
import Testing
@testable import bromure_ac

/// Finding: the Switchboard wrote what it hands a session (a finding's brief,
/// a long message) to /home/ubuntu/.bromure/inbox on the session's machine.
/// On an attached Mac that runs through its hostExec, where there is no
/// /home/ubuntu: mkdir failed and nothing was delivered. The inbox is now the
/// one under the Mac's reported home, and the pointer names that same path.
@Suite("Switchboard inbox on the session's machine")
struct SwitchboardInboxTests {
    @Test("a VM's inbox is the ubuntu one; an attached Mac's is under the home it reports")
    func base() {
        #expect(SwitchboardEngine.inboxBase(attached: false, reportedHome: nil) == "/home/ubuntu/.bromure/inbox")
        #expect(SwitchboardEngine.inboxBase(attached: false, reportedHome: "/Users/sam") == "/home/ubuntu/.bromure/inbox")
        #expect(SwitchboardEngine.inboxBase(attached: true, reportedHome: "/Users/sam") == "/Users/sam/.bromure/inbox")
        #expect(SwitchboardEngine.inboxBase(attached: true, reportedHome: "/Users/sam/") == "/Users/sam/.bromure/inbox")
        // Not reported (yet), or not a path: refused, never /home/ubuntu.
        #expect(SwitchboardEngine.inboxBase(attached: true, reportedHome: nil) == nil)
        #expect(SwitchboardEngine.inboxBase(attached: true, reportedHome: "sam") == nil)
    }

    @Test("the write lands at the path the pointer names, even in a home with a space and a quote")
    func writeCommand() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("inbox test \(UUID().uuidString.prefix(6)) it's").path
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let base = try #require(SwitchboardEngine.inboxBase(attached: true, reportedHome: home))
        let dir = base + "/finding-abcd1234"
        let text = "# brief\nline two — ünïcode\n"
        let cmd = SwitchboardEngine.inboxWriteCommand(dir: dir, name: "finding.md",
                                                base64: Data(text.utf8).base64EncodedString())
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", cmd]
        try sh.run()
        sh.waitUntilExit()
        #expect(sh.terminationStatus == 0)
        #expect(try String(contentsOfFile: dir + "/finding.md", encoding: .utf8) == text)
    }
}
