import Foundation
import Testing
@testable import ACLinux

/// A stand-in swapped for its real credential is on the Security Timeline
/// whatever the trace level (main: the token-swap events go out before the
/// trace gate; tracing is off by default, and behind the gate the
/// Security window's credential brokering stayed at 0).
@Suite("Token-swap events without a trace")
struct SwapEventTests {
    static func swapRows(_ pid: UUID) async -> [SecurityTimeline.Event] {
        await MainActor.run {
            SecurityTimeline.shared.allEvents.filter {
                $0.profileID == pid && $0.engine == NSLocalizedString("Credential brokering", comment: "Security Timeline engine")
                    && $0.condition.hasSuffix("→ api.example.test")
            }
        }
    }

    @Test func aForwardedSwapIsRecordedUntraced() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
        let pid = UUID()
        let fake = "brm-standin-for-the-swap-event-test"
        proxy.swapper.setMap(TokenMap(entries: [TokenMap.Entry(fake: fake, real: "the-real-value-for-the-test",
                                                               host: "api.example.test")]), for: pid)
        #expect(proxy.traceSession(for: pid) == nil, "no trace")
        var trace: RequestReader.Trace?
        let req = Data("GET /v1/things?x=1 HTTP/1.1\r\nHost: api.example.test\r\nAuthorization: Bearer \(fake)\r\n\r\n".utf8)
        let plan = await RequestReader.rewrite(req, proxy: proxy, profileID: pid, host: "api.example.test", port: 443,
                                               tls: true, session: proxy.strictSession(of: pid), trace: &trace)
        guard case .forward(let out, _, _, _, _, _, _, _, _, _, _, _) = plan else { Issue.record("\(plan)"); return }
        #expect(String(decoding: out, as: UTF8.self).contains("the-real-value-for-the-test"))
        var rows: [SecurityTimeline.Event] = []
        for _ in 0..<300 {
            rows = await Self.swapRows(pid)
            if !rows.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(rows.count == 1, "\(rows)")
        #expect(!"\(rows)".contains("the-real-value-for-the-test"), "previews only")

        // No stand-in in it: nothing to record.
        let plain = Data("GET / HTTP/1.1\r\nHost: api.example.test\r\n\r\n".utf8)
        _ = await RequestReader.rewrite(plain, proxy: proxy, profileID: pid, host: "api.example.test", port: 443,
                                        tls: true, session: proxy.strictSession(of: pid), trace: &trace)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await Self.swapRows(pid).count == 1)
    }
}
