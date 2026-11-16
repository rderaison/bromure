import Foundation
import Testing

/// The phone's Files sheet (session stage, compact room toolbar) is open on
/// its own: located and polling while shown, whatever the shared side-pane
/// flag says. Finding: "Phone session Files sheet opens with an
/// uninitialized explorer".
@Suite("Phone Files sheet")
struct PhoneFilesSheetTests {
    static func src(_ rel: String) throws -> String {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: top.appendingPathComponent(rel), encoding: .utf8)
    }

    @Test("A standalone explorer locates and polls without filePaneOpen")
    func standaloneIsOpen() throws {
        let f = try Self.src("Sources/AgentCoding/FileExplorerViews.swift")
        #expect(f.contains("guard standalone || listModel.filePaneOpen || model.poppedOut else {"))
        #expect(f.contains("standalone || (listModel.filePaneOpen && !listModel.gridSelected) || model.poppedOut"))
        #expect(f.contains("guard showing, contextCwd != nil else { return }"))
        #expect(f.contains("guard !standalone, let tab"))
    }

    @Test("The sheet's pane is standalone; the iPad side pane isn't")
    func sheetPassesStandalone() throws {
        let ws = try Self.src("ios/BromureRemote/Sources/BromureRemote/WorkspaceScreen.swift")
        let button = try #require(ws.range(of: "struct SessionFilesButton: View {"))
        #expect(ws[button.upperBound...].prefix(900).contains("standalone: true)"))
        #expect(ws.contains("standalone: standalone)"))
        let room = try Self.src("ios/BromureRemote/Sources/BromureRemote/RoomScreens.swift")
        #expect(room.contains("SessionFilesButton(controller: controller, profileID: s.profileID, cwd: s.cwd)"))
        #expect(room.contains("SessionFilesPane(controller: controller, profileID: s.profileID, cwd: s.cwd)\n"))
    }
}
