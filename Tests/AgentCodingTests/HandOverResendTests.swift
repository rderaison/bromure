import Foundation
import Testing
@testable import bromure_ac

// "Ask <session> to fix it" (and Start a Fix) failed at once with "the server
// didn't answer" when the pooled connection under it had died while idle;
// sending it again worked. A request that's safe to send twice is now resent
// once by itself when it got no answer.
@Suite("Fat client: unanswered hand-overs are resent once")
struct HandOverResendTests {
    final class Counter { var n = 0 }

    @Test("no answer, then an answer: resent once, the answer kept")
    func resendsOnce() {
        let c = Counter()
        let r: Int? = RemoteHostController.sendResendingUnanswered(true, label: "t", delay: 0) {
            c.n += 1; return c.n == 1 ? nil : 200
        }
        #expect(r == 200)
        #expect(c.n == 2)
    }

    @Test("still no answer after the resend: nil, and no third try")
    func givesUp() {
        let c = Counter()
        let r: Int? = RemoteHostController.sendResendingUnanswered(true, label: "t", delay: 0) { c.n += 1; return nil }
        #expect(r == nil)
        #expect(c.n == 2)
    }

    @Test("not safe to send twice, or answered: sent once")
    func sentOnce() {
        let c = Counter()
        let a: Int? = RemoteHostController.sendResendingUnanswered(false, label: "t", delay: 0) { c.n += 1; return nil }
        #expect(a == nil && c.n == 1)
        let d = Counter()
        let b: Int? = RemoteHostController.sendResendingUnanswered(true, label: "t", delay: 0) { d.n += 1; return 400 }
        #expect(b == 400 && d.n == 1)
    }

    @Test("the hand-overs that are safe to send twice resend; the Switchboard doesn't")
    func wiring() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/FatClientController.swift"), encoding: .utf8)
        for route in ["/fix\",", "/session\","] {
            let at = try #require(src.range(of: route))
            #expect(src[at.upperBound...].prefix(200).contains("retryUnanswered: true"), "\(route) isn't resent")
        }
        let sb = try #require(src.range(of: "/switchboard\","))
        #expect(!src[sb.upperBound...].prefix(200).contains("retryUnanswered"))
    }
}
