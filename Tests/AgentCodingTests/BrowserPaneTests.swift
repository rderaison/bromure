import BrowserBridges
import Foundation
import SandboxEngine
import Testing
@testable import bromure_ac

@Suite("Browser pane: URL display, readiness, display sizing, MCP retry")
struct BrowserPaneTests {

    // MARK: - B22 URL bar keeps the port

    @Test("host:port is shown for a non-default port")
    func hostWithPortKeepsPort() {
        #expect(NativeTabBarModel.hostWithPort(URL(string: "http://172.27.181.3:8080/")!) == "172.27.181.3:8080")
        #expect(NativeTabBarModel.hostWithPort(URL(string: "https://example.com:8443/a")!) == "example.com:8443")
        #expect(NativeTabBarModel.hostWithPort(URL(string: "https://example.com/a")!) == "example.com")
        // Default ports are noise.
        #expect(NativeTabBarModel.hostWithPort(URL(string: "http://example.com:80/")!) == "example.com")
        #expect(NativeTabBarModel.hostWithPort(URL(string: "https://example.com:443/")!) == "example.com")
        // But :443 on http is not default.
        #expect(NativeTabBarModel.hostWithPort(URL(string: "http://example.com:443/")!) == "example.com:443")
        // IPv6 literal keeps its brackets.
        #expect(NativeTabBarModel.hostWithPort(URL(string: "http://[::1]:3000/")!) == "[::1]:3000")
        #expect(NativeTabBarModel.hostWithPort(URL(string: "about:blank")!) == nil)
    }

    @Test("the URL field shows host:port plus path")
    @MainActor func displayValueKeepsPort() {
        let tab = TabInfo(id: "1", url: "http://172.27.181.3:8080/", active: true)
        #expect(NativeTabBarModel.displayValue(for: tab) == "172.27.181.3:8080")
        let deep = TabInfo(id: "2", url: "http://localhost:3000/app?x=1#top", active: true)
        #expect(NativeTabBarModel.displayValue(for: deep) == "localhost:3000/app?x=1#top")
        let plain = TabInfo(id: "3", url: "https://bromure.io/news", active: true)
        #expect(NativeTabBarModel.displayValue(for: plain) == "bromure.io/news")
    }

    // MARK: - B17 readiness gate

    @Test("ready once the guest connected, or after the grace period")
    func readinessGate() {
        let t0 = Date()
        #expect(!BrowserReadiness.isReady(guestConnected: false, attachedAt: nil, now: t0, grace: 30))
        #expect(!BrowserReadiness.isReady(guestConnected: false, attachedAt: t0, now: t0.addingTimeInterval(5), grace: 30))
        #expect(BrowserReadiness.isReady(guestConnected: true, attachedAt: t0, now: t0, grace: 30))
        #expect(BrowserReadiness.isReady(guestConnected: false, attachedAt: t0, now: t0.addingTimeInterval(31), grace: 30))
    }

    // MARK: - B18 display sizing

    @Test("display target is the even backing size; tiny layouts are ignored")
    func displayTarget() {
        #expect(BrowserDisplaySizing.target(forBacking: CGSize(width: 1411, height: 2401))
                == CGSize(width: 1410, height: 2400))
        #expect(BrowserDisplaySizing.target(forBacking: CGSize(width: 100, height: 800)) == nil)
        #expect(BrowserDisplaySizing.target(forBacking: .zero) == nil)
    }

    @Test("reconfigure only on a real mismatch")
    func displayMismatch() {
        let t = CGSize(width: 1410, height: 2400)
        #expect(!BrowserDisplaySizing.needsReconfigure(current: t, target: t))
        #expect(!BrowserDisplaySizing.needsReconfigure(current: CGSize(width: 1412, height: 2399), target: t))
        #expect(BrowserDisplaySizing.needsReconfigure(current: CGSize(width: 1920, height: 2400), target: t))
    }

    @Test("a pane at least Chromium's minimum width maps 1:1 (no overscan)")
    func displayLayoutWidePane() {
        // 640×700 pt visible area on a retina host, guest DPR 2, 172-row chrome.
        let l = BrowserDisplaySizing.layout(cropperSize: CGSize(width: 640, height: 700),
                                            backingScale: 2, guestScale: 2, deviceInset: 172)
        #expect(l?.overscan == 1)
        #expect(l?.isOverscanned == false)
        // = the VZ view's own backing size (visible area + chrome rows).
        #expect(l?.framebuffer == CGSize(width: 1280, height: 1400 + 172))
        // Exactly the minimum: still 1:1.
        let edge = BrowserDisplaySizing.layout(cropperSize: CGSize(width: 500, height: 700),
                                               backingScale: 2, guestScale: 2, deviceInset: 172)
        #expect(edge?.isOverscanned == false)
        #expect(edge?.framebuffer.width == 1000)
    }

    @Test("a pane narrower than Chromium's minimum overscans so 500 CSS px fit (B18)")
    func displayLayoutNarrowPane() throws {
        // The live repro: a 392 pt pane, DPR 2 — Chromium sat at 500 CSS px
        // on a 392-wide screen and the page's right side was clipped.
        let l = try #require(BrowserDisplaySizing.layout(
            cropperSize: CGSize(width: 392, height: 700),
            backingScale: 2, guestScale: 2, deviceInset: 172))
        #expect(l.isOverscanned)
        #expect(abs(l.overscan - 500.0 / 392.0) < 0.0001)
        // The guest screen is at least Chromium's minimum, in CSS px.
        #expect(l.framebuffer.width / 2 >= BrowserDisplaySizing.chromiumMinCSSWidth)
        #expect(l.framebuffer.width == 1000)
        // Aspect ratio matches the VZ view (visible area + scaled-down chrome
        // clip), so VZ's scale-to-fit fills the view exactly.
        let viewHeightPts = 700 + 172 / (2 * l.overscan)
        let viewAspect = 392 / viewHeightPts
        let fbAspect = l.framebuffer.width / l.framebuffer.height
        #expect(abs(viewAspect - fbAspect) < 0.002)
        #expect(Int(l.framebuffer.height) % 2 == 0)
    }

    @Test("overscan follows host and guest scale")
    func displayOverscanScales() {
        // Non-retina host with a 1× guest: 400 pt → 500 px needed.
        #expect(BrowserDisplaySizing.overscan(viewWidthPoints: 400, backingScale: 1, guestScale: 1) == 1.25)
        #expect(BrowserDisplaySizing.overscan(viewWidthPoints: 800, backingScale: 2, guestScale: 2) == 1)
        // Degenerate inputs never overscan.
        #expect(BrowserDisplaySizing.overscan(viewWidthPoints: 0, backingScale: 2, guestScale: 2) == 1)
        #expect(BrowserDisplaySizing.minPaneWidth >= BrowserDisplaySizing.chromiumMinCSSWidth)
    }

    // MARK: - B17 guest MCP retry policy (bromure-browser-mcp.py)

    private static var browserMCP: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentCoding/Resources/vm-setup/bromure-browser-mcp.py")
    }

    private static var hasPython: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") }

    private func python(_ code: String) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = ["-c", """
            import importlib.util
            s = importlib.util.spec_from_file_location("b", "bromure-browser-mcp.py")
            m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
            """ + "\n" + code]
        proc.currentDirectoryURL = Self.browserMCP.deletingLastPathComponent()
        let out = Pipe(); proc.standardOutput = out; proc.standardError = out
        try proc.run(); proc.waitUntilExit()
        return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("connection refused while booting is waited out; page errors are not",
          .enabled(if: BrowserPaneTests.hasPython))
    func transientClassification() throws {
        let out = try python("""
            import errno, json
            cases = [
              ConnectionRefusedError(errno.ECONNREFUSED, "Connection refused"),
              OSError(errno.EHOSTUNREACH, "No route to host"),
              RuntimeError("no page target"),
              RuntimeError("ws handshake eof"),
              json.JSONDecodeError("x", "", 0),
              RuntimeError("TypeError: x is not a function"),
              RuntimeError("cdp Runtime.evaluate timed out"),
              RuntimeError("no element matches #nope"),
            ]
            print(",".join("1" if m.is_transient_cdp_error(e) else "0" for e in cases))
            """)
        #expect(out == "1,1,1,1,1,0,0,0")
    }

    @Test("the readiness backoff is bounded and grows to a cap",
          .enabled(if: BrowserPaneTests.hasPython))
    func backoffSchedule() throws {
        let out = try python("""
            d = m.backoff_delays()
            print("%s|%.2f|%.2f" % (",".join(str(x) for x in d[:5]), sum(d), max(d)))
            """)
        let parts = out.split(separator: "|").map(String.init)
        #expect(parts.count == 3)
        #expect(parts.first == "0.25,0.5,1.0,2.0,2.0")
        if parts.count == 3 {
            #expect((Double(parts[1]) ?? 99) <= 20.0)
            #expect((Double(parts[1]) ?? 0) >= 15.0)
            #expect(parts[2] == "2.00")
        }
    }

    // MARK: - Browser image resolution (shared vs AC's own)

    @Test("shared image wins unless AC's own copy is newer")
    func imageResolution() {
        typealias I = BrowserImageInstaller
        #expect(I.resolve(sharedComplete: true, sharedVersion: 403, acComplete: true, acVersion: 502) == .downloadedByAC)
        #expect(I.resolve(sharedComplete: true, sharedVersion: 502, acComplete: true, acVersion: 502) == .sharedWithBromureWeb)
        #expect(I.resolve(sharedComplete: true, sharedVersion: 503, acComplete: true, acVersion: 502) == .sharedWithBromureWeb)
        #expect(I.resolve(sharedComplete: true, sharedVersion: nil, acComplete: true, acVersion: 401) == .downloadedByAC)
        #expect(I.resolve(sharedComplete: true, sharedVersion: 403, acComplete: false, acVersion: nil) == .sharedWithBromureWeb)
        #expect(I.resolve(sharedComplete: false, sharedVersion: 999, acComplete: true, acVersion: 100) == .downloadedByAC)
        #expect(I.resolve(sharedComplete: false, sharedVersion: nil, acComplete: false, acVersion: nil) == nil)
    }

    @Test("outdated = older than this build's image version (unstamped counts)")
    func imageOutdated() throws {
        #expect(BrowserImageInstaller.isOutdated(403, current: 502))
        #expect(!BrowserImageInstaller.isOutdated(502, current: 502))
        #expect(!BrowserImageInstaller.isOutdated(503, current: 502))
        #expect(BrowserImageInstaller.isOutdated(nil, current: 502))
        #expect(BrowserImageInstaller.currentVersion == Int(LinuxImageManager.imageVersion))
        // Stamp parsing tolerates the trailing newline.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(BrowserImageInstaller.stampedVersion(in: dir) == nil)
        try "403\n".write(to: dir.appendingPathComponent("image-version"), atomically: true, encoding: .utf8)
        #expect(BrowserImageInstaller.stampedVersion(in: dir) == 403)
    }
}
