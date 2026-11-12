import Foundation
import Testing
@testable import bromure_ac

/// A fat client runs the workspace's browser itself, so it needs the
/// workspace's browser settings. Its `/state` mirror carried none of them:
/// a workspace turned off on the host still opened (and kept) a browser on
/// the client, with uploads/downloads/camera/microphone at the client's
/// defaults. Finding: "Remote browser ignores the workspace's Browser off
/// setting" (CWE-863).
@Suite("Fat-client browser settings")
@MainActor
struct FatClientBrowserSettingsTests {
    private func row(_ id: UUID, _ p: Profile) -> [String: Any] {
        var r: [String: Any] = ["id": id.uuidString, "name": "W", "tool": "claude", "authMode": "token", "state": "running"]
        r.merge(ACAppDelegate.browserRowFields(p)) { _, new in new }
        return r
    }

    @Test("the host's row carries the browser settings into the mirror")
    func mirrored() {
        let c = RemoteHostController(host: RemoteHost(name: "t", address: "127.0.0.1", port: 1, user: "nobody"))
        let id = UUID()
        var p = Profile(name: "W", tool: .claude, authMode: .token)
        p.browserDisabled = true
        p.browserPersistent = true
        p.browserAllowUploads = false
        p.browserAllowDownloads = false
        p.browserWebcam = true
        p.browserMicrophone = true
        c.applyPushedSnapshot(["workspaces": [row(id, p)], "vms": []])
        let m = c.profile(for: id)
        #expect(m?.browserDisabled == true)
        #expect(m?.browserPersistent == true)
        #expect(m?.browserAllowUploads == false)
        #expect(m?.browserAllowDownloads == false)
        #expect(m?.browserWebcam == true)
        #expect(m?.browserMicrophone == true)
    }

    @Test("turning the browser off (or on) on the host tells the window, once")
    func transitionsAreSignalled() {
        let c = RemoteHostController(host: RemoteHost(name: "t", address: "127.0.0.1", port: 1, user: "nobody"))
        let id = UUID()
        var seen: [(UUID, Bool?)] = []
        c.onBrowserSettingsChanged = { seen.append(($0, c.profile(for: $0)?.browserDisabled)) }
        var p = Profile(name: "W", tool: .claude, authMode: .token)
        c.applyPushedSnapshot(["workspaces": [row(id, p)], "vms": []])
        #expect(seen.isEmpty, "a first sighting is no change")
        p.browserDisabled = true
        c.applyPushedSnapshot(["workspaces": [row(id, p)], "vms": []])
        #expect(seen.count == 1)
        #expect(seen.first?.0 == id)
        #expect(seen.first?.1 == true, "the mirror already holds the new value")
        c.applyPushedSnapshot(["workspaces": [row(id, p)], "vms": []])
        #expect(seen.count == 1, "the same snapshot again: no change")
        p.browserDisabled = false
        p.browserAllowDownloads = false
        c.applyPushedSnapshot(["workspaces": [row(id, p)], "vms": []])
        #expect(seen.count == 2)
    }

    @Test("an older host that doesn't send them: the defaults")
    func olderHost() {
        let c = RemoteHostController(host: RemoteHost(name: "t", address: "127.0.0.1", port: 1, user: "nobody"))
        let id = UUID()
        c.applyPushedSnapshot(["workspaces": [["id": id.uuidString, "name": "W", "tool": "claude",
                                               "authMode": "token", "state": "off"]], "vms": []])
        let m = c.profile(for: id)
        #expect(m?.browserDisabled == false)
        #expect(m?.browserAllowUploads == true)
        #expect(m?.browserAllowDownloads == true)
        #expect(m?.browserWebcam == false)
    }

    @Test("the window closes the pane, the browser and the relay when it's turned off")
    func windowTearsDown() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/AgentCoding/FatClientController.swift"), encoding: .utf8)
        #expect(src.contains("controller.onBrowserSettingsChanged = { [weak self] id in"))
        guard let r = src.range(of: "private func browserSettingsChanged(for id: Profile.ID) {") else {
            Issue.record("no browserSettingsChanged"); return
        }
        let body = String(src[r.upperBound...].prefix(700))
        #expect(body.contains("setBrowserOpen(id, false)"))
        #expect(body.contains("browserControllers[id]?.stop()"))
        #expect(body.contains("browserRelays[id]?.stop()"))
    }
}
