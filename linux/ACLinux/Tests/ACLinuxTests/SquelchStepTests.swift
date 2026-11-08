import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// Squelch on the Linux proxy (macOS: driveTLS's Squelch step): with the
    /// workspace's Squelch on, a Bash result's noise is cut from a request to
    /// a model before it goes, and counted; off, or to another host, the
    /// request goes as sent.
    @Suite("Squelch on the proxy", .serialized)
    struct SquelchStepTests {
        static func noisy() -> String {
            (0..<150).map { "tests/test_x.py::test_\($0) PASSED" }.joined(separator: "\n") + "\n1 failed, 150 passed\nFAILED tests/test_x.py::test_z\n"
        }

        static func request(host: String) -> Data {
            let body = try! JSONSerialization.data(withJSONObject: [
                "model": "claude-x",
                "messages": [
                    ["role": "user", "content": "run the tests"],
                    ["role": "assistant", "content": [
                        ["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": ["command": "pytest -v"]],
                    ]],
                    ["role": "user", "content": [
                        ["type": "tool_result", "tool_use_id": "toolu_1", "content": noisy()],
                    ]],
                ],
            ], options: [.sortedKeys])
            return Data("POST /v1/messages HTTP/1.1\r\nHost: \(host)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8) + body
        }

        @Test func aBashResultsNoiseIsCutAndCounted() throws {
            let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
            let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
            let pid = UUID()
            SquelchSettings.update([pid: SquelchPolicy(enabled: true)])
            defer { SquelchSettings.update([:]) }
            var trace: RequestReader.Trace? = nil
            var req = Self.request(host: "api.anthropic.com")
            RequestReader.squelchStep(&req, proxy: proxy, profileID: pid, host: "api.anthropic.com", method: "POST", trace: &trace)
            let text = String(decoding: req, as: UTF8.self)
            #expect(!text.contains("test_7 PASSED") && text.contains("FAILED tests/test_x.py::test_z"), "trimmed")
            #expect(text.contains("Content-Length: \(req.count - (req.range(of: Data("\r\n\r\n".utf8))!.upperBound))\r\n"), "re-framed")
            #expect((SquelchLedger.shared.summary(pid)?.total.trimmed ?? 0) >= 1, "counted")

            // Not a model's host: untouched.
            var other = Self.request(host: "example.com")
            let before = other
            RequestReader.squelchStep(&other, proxy: proxy, profileID: pid, host: "example.com", method: "POST", trace: &trace)
            #expect(other == before)
        }

        @Test func squelchOffLeavesTheRequestAsSent() throws {
            let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
            let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
            let pid = UUID()
            SquelchSettings.update([pid: SquelchPolicy(enabled: false)])
            defer { SquelchSettings.update([:]) }
            var trace: RequestReader.Trace? = nil
            var req = Self.request(host: "api.anthropic.com")
            let before = req
            RequestReader.squelchStep(&req, proxy: proxy, profileID: pid, host: "api.anthropic.com", method: "POST", trace: &trace)
            #expect(req == before)
        }
    }
}
