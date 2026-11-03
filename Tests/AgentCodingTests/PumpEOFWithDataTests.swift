import Foundation
import Testing

/// Linux's libdispatch doesn't fire a read source again for an EOF that came
/// in together with the data. The server bridge read one chunk per event, so a
/// control reply written and closed at once (every /state poll) never had its
/// EOF read: no exit-status, no close, the channel and its control-socket fd
/// lived until the SSH connection ended (the Linux server reached its fd limit
/// in about an hour). macOS's kqueue re-delivers the EOF, which hid it there,
/// so the guard is on the shape: every pumped fd reads until it would block,
/// the pump pauses, or the fd ends.
@Suite("A pumped fd's EOF that arrives with its data still closes the channel")
struct PumpEOFWithDataTests {
    @Test("the PTY, control and forward pumps share one read loop")
    func readsToEOF() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/RemoteSSHHandlers.swift"), encoding: .utf8)
        let fn = try #require(src.range(of: "private func pumpReadable(_ fd: Int32, channel: Channel, pid: pid_t) {"))
        let body = String(src[fn.upperBound...].prefix(900))
        #expect(body.contains("while !pumpPaused, !draining {"))
        #expect(body.contains("finishAfterDrain(channel: channel, pid: pid, master: fd)"))
        // No handler reads a single chunk on its own any more.
        #expect(src.components(separatedBy: "pumpReadable(").count - 1 == 4)   // the helper + 3 sources
        #expect(!src.contains("let n = LibC.read(masterFD, &buf, buf.count)"))
        #expect(!src.contains("let n = LibC.read(sockFD, &buf, buf.count)"))
    }
}
