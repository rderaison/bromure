import AppKit
import AVKit
import SwiftUI
import Testing
@testable import bromure_ac

/// Finding (CWE-670): "Inline video restarts because each redraw builds a
/// new AVPlayer". The card built `AVPlayer(url:)` in its body; the chat
/// re-renders on every transcript poll (0.4-1.2 s), and each one swapped in
/// a fresh player -- a playing video back at zero, paused.
@Suite("Video card player")
@MainActor
struct VideoCardPlayerTests {
    private func playerView(in v: NSView) -> AVPlayerView? {
        if let p = v as? AVPlayerView { return p }
        for s in v.subviews { if let p = playerView(in: s) { return p } }
        return nil
    }

    private func settle() async {
        for _ in 0..<20 { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    @Test("re-rendering the card keeps its player")
    func playerSurvivesRedraws() async throws {
        let path = "/tmp/bromure-test-\(UUID().uuidString).mp4"
        _ = DisplayMediaCache.store(video: Data([0, 0, 0, 0]), for: path, ext: "mp4")
        let host = NSHostingView(rootView: MediaView(path: path, expanded: false))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        await settle()
        let first = try #require(playerView(in: host)?.player, "no player shown")
        for _ in 0..<3 {
            host.rootView = MediaView(path: path, expanded: false)   // a transcript poll's redraw
            host.layoutSubtreeIfNeeded()
            await settle()
            #expect(playerView(in: host)?.player === first)
        }
    }

    @Test("no player is built in a body")
    func notInBody() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let s = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/DisplayCards.swift"), encoding: .utf8)
        #expect(!s.contains("VideoPlayer(player: AVPlayer("))
        #expect(s.contains("if url != videoURL || player == nil {"))
        #expect(s.contains("player = AVPlayer(url: url)"))
    }
}
