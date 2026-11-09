import Foundation
import Testing
@testable import ACLinux

@Suite("/proc reads")
struct ProcFSTests {
    @Test func readsAProcessArgvAndSaysNilOnceItIsGone() throws {
        let me = getpid()
        let argv = try #require(ProcFS.argv(me))
        #expect(argv.first?.hasSuffix(CommandLine.arguments[0].split(separator: "/").last.map(String.init) ?? "") == true, "\(argv)")
        #expect(ProcFS.text("/proc/\(me)/comm")?.isEmpty == false)
        // A process that exited (and was reaped): nothing to read.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/true")
        try p.run(); p.waitUntilExit()
        #expect(ProcFS.argv(p.processIdentifier) == nil)
        #expect(ProcFS.read("/proc/self/cmdline", limit: 3)?.count == 3, "capped")
    }
}
