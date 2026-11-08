import Foundation
import NIOConcurrencyHelpers
import NIOPosix
import SandboxEngine
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// Squelch on a model provider's WebSocket (macOS: WSContentGuard's
    /// Squelch, and squelchingTransform on the OpenShell pump): a Codex turn's
    /// noisy shell output is trimmed before it goes up; the model's messages
    /// are read for its calls.
    @Suite("Squelch on WebSockets", .serialized)
    struct SquelchWebSocketTests {
        static let noisy = (0..<150).map { "tests/test_x.py::test_\($0) PASSED" }.joined(separator: "\n")
            + "\n1 failed, 150 passed\nFAILED tests/test_x.py::test_z\n"

        static func turn() -> Data {
            let header = "Chunk ID: 9f2a\nWall time: 3.2 seconds\nProcess exited with code 1\nOriginal token count: 2100\nOutput:\n"
            return try! JSONSerialization.data(withJSONObject: [
                "type": "response.create", "model": "gpt-5",
                "input": [
                    ["type": "function_call", "call_id": "call_a", "name": "exec_command", "arguments": #"{"cmd":"pytest -v"}"#],
                    ["type": "function_call_output", "call_id": "call_a", "output": header + noisy],
                ],
            ], options: [.sortedKeys])
        }

        @Test func squelchAloneMakesTheGuardAndTrimsATurn() async throws {
            let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
            let proxy = try MitmProxy(caDirectory: URL(fileURLWithPath: dir + "/mitm", isDirectory: true))
            let pid = UUID()
            #expect(WSPromptGuard.make(proxy: proxy, profileID: pid, host: "chatgpt.com", local: false) == nil, "nothing on: opaque")
            SquelchSettings.update([pid: SquelchPolicy(enabled: true)])
            defer { SquelchSettings.update([:]) }
            let g = try #require(WSPromptGuard.make(proxy: proxy, profileID: pid, host: "chatgpt.com", local: false,
                                                    conversation: "conv-1"))
            #expect(g.squelchLearns)
            guard case .forward(let out?) = await g.client(Self.turn()) else { Issue.record("not trimmed"); return }
            let text = String(decoding: out, as: UTF8.self)
            #expect(!text.contains("test_7 PASSED") && text.contains("FAILED tests/test_x.py::test_z"))
            #expect(SquelchLedger.shared.conversation(pid, "conv-1") != nil, "counted under the socket's conversation")
        }

        @Test func theServerSideLearnsFromWholeMessages() throws {
            let loop = MultiThreadedEventLoopGroup.singleton.next()
            let learned = NIOLockedValueBox<[Data]>([])
            let server = WSServerSide(loop: loop, write: { _ in }, learn: { d in learned.withLockedValue { $0.append(d) } })
            let event = Data(#"{"type":"response.output_item.done","item":{"type":"function_call","call_id":"c9"}}"#.utf8)
            let frame = WSFrame.encode(opcode: WSFrame.text, payload: event, masked: false)
            // Split across reads: learned once, whole.
            let out1 = try #require(server.feed(frame.prefix(10)))
            let out2 = try #require(server.feed(frame.dropFirst(10)))
            #expect(out1 + out2 == frame, "relayed as it came")
            #expect(learned.withLockedValue { $0 } == [event])
        }

        @Test func thePumpsTransformTrimsFirst() {
            let pid = UUID()
            SquelchSettings.update([pid: SquelchPolicy(enabled: true)])
            defer { SquelchSettings.update([:]) }
            var thenSaw: String?
            let t = RequestReader.squelchingTransform(then: { thenSaw = $0; return .unchanged }, profileID: pid, conversation: nil)
            guard case .replaced(let out) = t(String(decoding: Self.turn(), as: UTF8.self)) else { Issue.record("not trimmed"); return }
            #expect(!out.contains("test_7 PASSED") && thenSaw == out, "the policy's rewrite runs on the trimmed text")
            #expect(RequestReader.squelchApplies(host: "chatgpt.com", profileID: pid, local: false))
            #expect(!RequestReader.squelchApplies(host: "example.com", profileID: pid, local: false))
        }
    }
}
