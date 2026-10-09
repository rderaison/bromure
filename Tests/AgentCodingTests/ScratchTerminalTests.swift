import AppKit
import Foundation
import SwiftUI
import Testing
@testable import bromure_ac

@Suite("Scratch terminal (/term)")
@MainActor
struct ScratchTerminalTests {

    private final class NullProvider: BeautifiedTranscriptProvider {
        var accent: Color { .blue }
        func activeTabIndex() -> Int? { 0 }
        func execGuest(_ command: String, timeout: Int) async -> String? { commands.append(command); return "" }
        func isWorking() -> Bool { false }
        func guestFileOp(_ op: [String: Any]) async -> [String: Any]? { nil }
        var commands: [String] = []
    }

    @Test("/term opens the drawer instead of reaching the agent; the palette offers it first")
    func intercept() {
        let m = BeautifiedSessionModel(provider: NullProvider())
        #expect(!m.paletteSlashCommands.contains { $0.name == "term" })   // no terminal here
        m.scratchTerminal = { NSView() }
        #expect(m.paletteSlashCommands.first?.name == "term")
        m.composerText = "/term"
        m.send()
        #expect(m.terminalShown)
        #expect(m.terminalAlive)
        #expect(m.composerText.isEmpty)
        m.hideTerminal()
        #expect(!m.terminalShown && m.terminalAlive)   // hidden, still running
        #expect(BeautifiedSessionModel.isTerminalCommand("/Terminal"))
        #expect(!BeautifiedSessionModel.isTerminalCommand("/term ls"))
    }

    @Test("tmux leaves the mouse to the terminal: a drag selects natively and the selection stays")
    func mouseOff() {
        // tmux's mouse took a drag as its own copy-mode selection and
        // dropped it on release — nothing left to ⌘C.
        let cmd = VMAttachWindow.scratchCommand(session: "scratch-x", cwd: "~")
        #expect(cmd.contains("set-option mouse off"))
        #expect(!cmd.contains("mouse on"))
    }

    @Test("the guest command lands in the folder, falls back to the home, and survives odd names")
    func guestCommand() throws {
        let name = TerminalSessionController.scratchSession("AB12cd34w3")
        #expect(name == "scratch-ab12cd34w3")
        let cmd = VMAttachWindow.scratchCommand(session: name, cwd: "~/it's a dir")
        #expect(cmd.contains("new-session -A -s 'scratch-ab12cd34w3'"))
        // The folder part, run for real: an existing dir is kept, a missing one → $HOME.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("st-\(UUID().uuidString.prefix(6))")
        let odd = tmp.appendingPathComponent("it's a dir")
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        func landing(_ c: String) -> String {
            let prefix = c.components(separatedBy: "exec tmux")[0]
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-c", prefix + "printf %s \"$d\""]
            p.environment = ["HOME": tmp.path]
            let out = Pipe(); p.standardOutput = out
            try? p.run(); p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        #expect(landing(cmd) == odd.path)
        #expect(landing(VMAttachWindow.scratchCommand(session: name, cwd: "/no/such/dir")) == tmp.path)
        #expect(landing(VMAttachWindow.scratchCommand(session: name, cwd: "~")) == tmp.path)
    }
}
