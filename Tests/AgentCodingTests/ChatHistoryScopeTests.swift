import Foundation
import SwiftUI
import Testing
@testable import bromure_ac

/// Board: "When I start a new codex session in a new folder, I see the
/// transcript of a random previous session" (fat client on ark). The
/// downloaded-history cache and the warm chats were keyed by host,
/// workspace and tmux WINDOW: a session closed, the next one opened in the
/// same window index, and its chat came up on the previous session's
/// conversation — for as long as a new Codex has no rollout of its own
/// (its first prompt, half a minute in).
@Suite("Chat history belongs to its session, not its window", .serialized)
@MainActor
struct ChatHistoryScopeTests {
    private final class Provider: BeautifiedTranscriptProvider {
        let key: String?
        let file: Data?
        init(key: String?, file: Data?) { self.key = key; self.file = file }
        var accent: Color { .blue }
        var historyCacheKey: String? { key }
        func activeTabIndex() -> Int? { 2 }
        func isWorking() -> Bool { false }
        func guestFileOp(_ op: [String: Any]) async -> [String: Any]? { nil }
        func execGuest(_ command: String, timeout: Int) async -> String? {
            if command.contains("capture-pane") { return "" }
            if command.contains("pane_current_path") { return "/home/ubuntu/codex-new\n0\n" }
            // No transcript yet: what a fresh Codex reads before its rollout.
            guard let file, command.hasPrefix("f=\"\";") else { return "" }
            let path = "/home/ubuntu/.claude/projects/-home-ubuntu-old/old.jsonl"
            return "\(path)\n\n\(file.count)\n0\n\(file.count)\n" + String(decoding: file, as: UTF8.self)
        }
    }

    private static let old = Data((#"{"type":"user","message":{"role":"user","content":"the previous session's question"},"timestamp":"2026-10-20T16:24:00Z"}"# + "\n"
        + #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"the previous session's answer"}]},"timestamp":"2026-10-20T16:24:01Z"}"# + "\n").utf8)

    private func run(_ provider: Provider, until: (BeautifiedSessionModel) -> Bool) async -> BeautifiedSessionModel {
        let m = BeautifiedSessionModel(provider: provider)
        m.start()
        let deadline = Date().addingTimeInterval(4)
        while !until(m), Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        return m
    }

    @Test("a new session in a reused window doesn't open on the previous session's conversation")
    func newSessionInReusedWindow() async throws {
        let host = RemoteHostController(host: RemoteHost(name: "t", address: "127.0.0.1", port: 1, user: "nobody"))
        let ws = UUID(), closed = UUID(), fresh = UUID()
        let keyClosed = RemoteTranscriptProvider(controller: host, workspaceID: ws, windowIndex: 2,
                                                 sessionID: closed, accent: .blue).historyCacheKey
        let keyFresh = RemoteTranscriptProvider(controller: host, workspaceID: ws, windowIndex: 2,
                                                sessionID: fresh, accent: .blue).historyCacheKey
        #expect(keyClosed != nil && keyClosed != keyFresh)
        #expect(keyClosed == RemoteTranscriptProvider(controller: host, workspaceID: ws, windowIndex: 2,
                                                      sessionID: closed, accent: .blue).historyCacheKey)
        #expect(RemoteHostWindow.warmChatKey(ws, 2, closed) != RemoteHostWindow.warmChatKey(ws, 2, fresh))

        // The closed session's chat downloads its conversation and leaves.
        let a = await run(Provider(key: keyClosed, file: Self.old)) { !$0.items.isEmpty }
        #expect(!a.items.isEmpty)
        a.stop()
        // The next session in window 2, before it has a transcript: nothing.
        let b = await run(Provider(key: keyFresh, file: nil)) { !$0.items.isEmpty }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(b.items.isEmpty, "\(b.items.count) items from the previous session")
        b.stop()
        // The closed session's own chat, shown again, still opens on its history.
        let again = await run(Provider(key: keyClosed, file: nil)) { !$0.items.isEmpty }
        #expect(!again.items.isEmpty)
        again.stop()
    }
}
