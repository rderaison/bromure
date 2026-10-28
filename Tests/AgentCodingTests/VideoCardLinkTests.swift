import AppKit
import AVKit
import SwiftUI
import Testing
@testable import bromure_ac

/// Board: "Playing a video in the app causes a crash". SwiftUI's VideoPlayer
/// (the display cards' video) is in the _AVKit_SwiftUI overlay; its
/// VideoPlayerView subclasses AVKit's AVPlayerView. Autolinking linked only
/// the overlay, so AVKit never loaded and building the view aborted the app:
/// "failed to demangle superclass of VideoPlayerView from mangled name
/// 'So12AVPlayerViewC'".
@Suite("Video card")
@MainActor
struct VideoCardLinkTests {
    @Test("AVKit is loaded, so the player view's superclass resolves")
    func avkitLoaded() {
        #expect(NSClassFromString("AVPlayerView") != nil)
    }

    @Test("a VideoPlayer builds in a hosting view")
    func videoPlayerBuilds() {
        let host = NSHostingView(rootView: VideoPlayer(player: AVPlayer(url: URL(fileURLWithPath: "/nonexistent.mp4")))
            .frame(width: 320, height: 180))
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
        host.layoutSubtreeIfNeeded()
        #expect(host.fittingSize.width > 0)
    }

    @Test("the app and the iOS client link the base frameworks of the SwiftUI overlays they use")
    func linked() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let pkg = try String(contentsOf: top.appendingPathComponent("Package.swift"), encoding: .utf8)
        let ac = try #require(pkg.range(of: #"path: "Sources/AgentCoding""#))
        #expect(pkg[ac.upperBound...].prefix(2500).contains(#".linkedFramework("AVKit")"#))
        let gen = try String(contentsOf: top.appendingPathComponent("scripts/gen-ios-project.py"), encoding: .utf8)
        #expect(gen.contains(#"\"-framework\", AVKit, \"-framework\", PhotosUI"#))
        let pbx = try String(contentsOf: top.appendingPathComponent("ios/BromureRemote/BromureRemote.xcodeproj/project.pbxproj"), encoding: .utf8)
        #expect(pbx.components(separatedBy: #""-framework", AVKit, "-framework", PhotosUI"#).count == 3)   // Debug + Release
    }
}
