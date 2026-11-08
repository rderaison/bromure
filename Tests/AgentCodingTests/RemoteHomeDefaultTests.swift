import Foundation
import Testing
@testable import bromure_ac

/// Finding: the editor that creates a workspace on a REMOTE Mac showed the
/// home size this Mac's free space would give (8 GB under 64 GB free, 16 from
/// 128 GB), while the server sizes the home from ITS free space when the VM
/// first boots. The editor showed 8 and the server made 16, or showed 16 and
/// the server made 8 (ENOSPC in the guest sooner than shown). The server now
/// says its default — per workspace in its storage reply, and for a new one
/// at GET /storage/defaults — and remote editors show that.
@Suite("A remote workspace's home size default is the server's")
struct RemoteHomeDefaultTests {
    @Test("the editor's default: the one it was given, else the server's, else this Mac's")
    func precedence() {
        var measured = 0
        let local = { () -> Int in measured += 1; return 8 }
        #expect(ProfileEditorView.homeDefault(given: 16, server: 12, local: local) == 16)
        #expect(ProfileEditorView.homeDefault(given: nil, server: 16, local: local) == 16)
        // This Mac's disk isn't consulted for a remote workspace at all.
        #expect(measured == 0)
        // A local workspace (or an older server that can't say): this Mac's.
        #expect(ProfileEditorView.homeDefault(given: nil, server: nil, local: local) == 8)
        #expect(measured == 1)
    }

    @Test("this Mac's default is the size its own SessionDisk gives a new home")
    func localDefault() {
        let expected = SessionDisk.resolvedHomeImageGB(
            freeBytes: SessionDisk.freeBytes(near: ProfileStore().profilesDirectory))
        #expect(SessionDisk.newHomeDefaultGB() == expected)
        #expect((8...1024).contains(expected))
    }

    @Test("the server says its default, and both remote editors show it")
    func wiring() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        func src(_ p: String) throws -> String {
            try String(contentsOf: top.appendingPathComponent(p), encoding: .utf8)
        }
        let server = try src("Sources/AgentCoding/AutomationServer.swift")
        #expect(server.contains(#"case ("GET", "/storage/defaults"):"#))
        #expect(server.contains(#"["homeImageGB": SessionDisk.newHomeDefaultGB()]"#))
        #expect(server.contains(#""defaultHomeGB": SessionDisk.newHomeDefaultGB(),"#))
        let fat = try src("Sources/AgentCoding/FatClientController.swift")
        #expect(fat.contains(#"c.defaultHomeGB = resp.json["defaultHomeGB"] as? Int"#))
        #expect(fat.contains("newHomeDefaultGB: newHomeDefaultGB)"))
        let ios = try src("ios/BromureRemote/Sources/BromureRemote/WorkspaceEditor.swift")
        #expect(ios.contains("newHomeDefaultGB: state.newHomeDefaultGB)"))
        // The editor no longer measures this Mac for every workspace.
        let editor = try src("Sources/AgentCoding/ProfileViews.swift")
        #expect(editor.contains("HomeSizeBounds(existingGB: existing, defaultGB: defaultHomeGB)"))
        #expect(!editor.contains("defaultGB: Self.defaultHomeGB"))
    }
}
