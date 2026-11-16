import Foundation
import Testing

/// Every phone destination the iPad layout can show goes through state
/// that publishes the fold focus -- boards, the Grid, workspace and native
/// machine cards, the waiting-agent card -- and is restored on the phone.
/// Finding: "Phone workspace and board links do not update fold handoff
/// focus".
@Suite("Phone: fold focus for every destination")
struct PhoneFoldFocusLinksTests {
    static func src() throws -> String {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: top.appendingPathComponent(
            "ios/BromureRemote/Sources/BromureRemote/HostMirrorScreen.swift"), encoding: .utf8)
    }

    @Test("The host screen has no inline links; its destinations publish and restore focus")
    func destinationsPublishFocus() throws {
        let s = try Self.src()
        // HostMirrorScreen's body ends where GridScreen starts (its cells
        // push a window of the grid, which stays the grid's focus).
        let host = try #require(s.range(of: "struct HostMirrorScreen: View {"))
        let grid = try #require(s.range(of: "struct GridScreen: View {"))
        let body = s[host.lowerBound..<grid.lowerBound]
        #expect(!body.contains("NavigationLink {"))
        #expect(!body.contains("NavigationLink { "))
        for (opened, focus) in [("coding", "coding"), ("automations", "automations"), ("grid", "grid")] {
            #expect(body.contains("case .\(opened): publishFocus(.\(focus))"))
            #expect(body.contains("case .\(focus): openBoard = .\(opened)"))
        }
        #expect(body.contains("deepWorkspace = WorkspaceDeepLink(profileID: row.id, window: nil)"))
        #expect(body.contains("deepWorkspace = WorkspaceDeepLink(profileID: agent.profileID, window: agent.windowIndex)"))
        #expect(body.contains("publishFocus(.workspace(link.profileID))"))
    }
}
