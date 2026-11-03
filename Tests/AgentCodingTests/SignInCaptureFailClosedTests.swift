import Foundation
import Testing
@testable import bromure_ac

/// A captured sign-in's token reply the host doesn't keep (its sign-in ended
/// as the exchange landed, the store write failed, a reply it couldn't read)
/// carried the real credential on to the guest: `reply ?? upstream`. Seen on
/// the Linux server's proxy, whose relay didn't decode a compressed reply;
/// the macOS path had the same fall-through.
@Suite("A sign-in's token reply the host didn't keep never reaches the guest")
struct SignInCaptureFailClosedTests {
    private static func src(_ p: String) throws -> String {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: top.appendingPathComponent(p), encoding: .utf8)
    }

    @Test("an unkept 200 is refused; only a non-200 passes through")
    func unkeptTokenReplyRefused() throws {
        let p = try Self.src("Sources/AgentCoding/Mitm/HTTPProxy.swift")
        let start = try #require(p.range(of: "var reply = await capture.handle(status, body)"))
        let block = p[start.upperBound...].prefix(1200)
        let guardRange = try #require(block.range(of: "if reply == nil, status == 200 {"))
        let write = try #require(block.range(of: "try tls.write(reply ?? upstream)"))
        #expect(guardRange.lowerBound < write.lowerBound)
        #expect(block.contains("\"error\": \"bromure_not_kept\""))
    }
}
