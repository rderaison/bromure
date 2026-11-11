import Foundation
import Testing

/// A forward's resolver (forward / forward-udp / browser-mcp /
/// delegation-mcp) dials off the event loop and hands its fd back later. When
/// the SSH channel closed in between, channelInactive's teardown had already
/// run with no fd to close, and wireResolvedFD adopted the late fd anyway:
/// nothing ever closed it. A client retrying a refused or short-lived forward
/// leaked one socket per try (the Linux server hit its 1024-fd limit with ~800
/// of them). A late fd is now closed at once.
@Suite("A resolver fd that arrives after the channel closed is closed, not adopted")
struct ResolvedFDAfterCloseTests {
    @Test("wireResolvedFD checks the channel is still active before adopting the fd")
    func guardsInactiveChannel() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/RemoteSSHHandlers.swift"), encoding: .utf8)
        let fn = try #require(src.range(of: "private func wireResolvedFD(channel: Channel, wantReply: Bool, fd: Int32) {"))
        let body = String(src[fn.upperBound...].prefix(1200))
        let check = try #require(body.range(of: "guard channel.isActive else {\n            Darwin.close(fd)\n            return\n        }"))
        let adopt = try #require(body.range(of: "self.master = fd"))
        #expect(check.upperBound <= adopt.lowerBound, "the check must come before the fd is adopted")
    }
}
