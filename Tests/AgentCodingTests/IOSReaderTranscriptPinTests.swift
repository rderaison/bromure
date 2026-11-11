import Foundation
import Testing
@testable import bromure_ac

/// The iOS reader (session stage, terminal reader, room cells) reads the
/// selected session's own conversation -- by id, else the file its window's
/// agent named -- never the folder's newest. Finding: "iOS session reader
/// can show another session's conversation".
@Suite("iOS reader: transcript pins")
struct IOSReaderTranscriptPinTests {
    static func src(_ rel: String) throws -> String {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: top.appendingPathComponent(rel), encoding: .utf8)
    }

    @Test("A conversation pin reads that file only, empty until it exists")
    func conversationPin() {
        let id = "019a1b2c-3d4e-7f60-8a9b-0c1d2e3f4a5b"
        let pin = TranscriptPin.conversation(tool: "codex", id: id)
        let cmd = AgentSessionLocator.locatePrefix(path: "/home/ubuntu/proj", since: 0, agent: "codex",
                                                   pinnedWindow: 3, pin: pin)
        #expect(cmd.contains(AgentSessionLocator.codexPinnedFragment(id: id, into: "f") + "[ -z \"$f\" ] && pe=1; "))
        // The folder's newest only runs when neither found nor pending.
        #expect(cmd.contains("if [ -z \"$f\" ] && [ -z \"$pe\" ]; then "))
    }

    @Test("Without a conversation id the window's own file is the pin")
    func windowPin() {
        let cmd = AgentSessionLocator.locatePrefix(path: "/home/ubuntu/proj", since: 0, agent: "claude",
                                                   pinnedWindow: 4, pin: TranscriptPin())
        #expect(cmd.contains(AgentSessionLocator.pinnedPick(window: 4, since: 0)))
    }

    @Test("The fat client's locator, the iOS reader, its presence poll and room cells all pass the pins")
    func iosPassesPins() throws {
        let tasks = try Self.src("Sources/AgentCoding/CodingTasks.swift")
        let iosShim = try #require(tasks.range(of: "#else"))
        let shim = tasks[iosShim.upperBound...]
        #expect(shim.components(separatedBy: "AgentSessionLocator.locatePrefix(path: path, since: since, agent: agent,\n                                                   pinnedWindow: pinnedWindow, pin: pin)").count == 3)
        let ws = try Self.src("ios/BromureRemote/Sources/BromureRemote/WorkspaceScreen.swift")
        #expect(ws.contains("controller.sessionStore.chatTranscriptPin(for: s, profileID: profileID)"))
        #expect(ws.contains("pin: transcriptPin(for: win),"))
        #expect(ws.contains("agent: agent, pinnedWindow: win,\n                                                               pin: transcriptPin(for: win))"))
        #expect(ws.contains("pinnedWindow: window, pin: pin,"))
        let room = try Self.src("ios/BromureRemote/Sources/BromureRemote/RoomScreens.swift")
        #expect(room.contains("agent: agent, pinnedWindow: w, pin: pin,"))
    }
}
