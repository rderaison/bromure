import Foundation
import Testing
@testable import bromure_ac

/// Board: "Switching to linux view isn't remembered". The Linux pill flips a
/// session between its chat and its terminal, in place, and the choice holds.
@Suite("A session can stay on its terminal", .serialized)
@MainActor
struct SessionTerminalViewTests {
    private func withClean(_ body: () -> Void) {
        let d = UserDefaults.standard
        let keys = [SessionTerminalPreference.key, "ui.beautifiedTranscript"]
        let saved = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } } }
        keys.forEach { d.removeObject(forKey: $0) }
        body()
    }

    private func pane() -> SessionPane {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("session-terminal-\(UUID().uuidString)", isDirectory: true)
        let delegate = ACAppDelegate(
            imageManager: UbuntuImageManager(storageDir: tmp, setupDir: tmp), headless: true)
        return SessionPane(profile: Profile(name: "t", tool: .claude, authMode: .subscription, homeModel: .virtiofs),
                           acDelegate: delegate)
    }

    private func roster(_ windows: [Int], active: Int) -> [GuestTab] {
        windows.map { GuestTab(index: $0, active: $0 == active, label: "claude") }
    }

    @Test("a session is a chat until the user asks otherwise, whatever the machine tabs' default says")
    func defaultIsChat() {
        withClean {
            #expect(SessionTerminalPreference.enabled == false)
            UserDefaults.standard.set(false, forKey: "ui.beautifiedTranscript")
            #expect(SessionTerminalPreference.enabled == false)
            SessionTerminalPreference.enabled = true
            #expect(SessionTerminalPreference.enabled == true)
            #expect(UserDefaults.standard.bool(forKey: "ui.beautifiedTranscript") == false)
        }
    }

    @Test("the terminal shows only when preferred and there is a tab; a launch keeps its page")
    func whenItShows() {
        #expect(SessionTerminalPreference.showsTerminal(prefers: true, tabLive: true, launching: false))
        #expect(!SessionTerminalPreference.showsTerminal(prefers: false, tabLive: true, launching: false))
        #expect(!SessionTerminalPreference.showsTerminal(prefers: true, tabLive: false, launching: false))
        #expect(!SessionTerminalPreference.showsTerminal(prefers: true, tabLive: true, launching: true))
    }

    @Test("flipping the surface changes the stage's plan, or the pill would do nothing")
    func flipReplans() {
        let id = UUID()
        #expect(SessionTerminalPreference.liveKey(terminal: true, profileID: id, tab: 2)
                != SessionTerminalPreference.liveKey(terminal: false, profileID: id, tab: 2))
        #expect(SessionTerminalPreference.liveKey(terminal: true, profileID: id, tab: 2)
                == SessionTerminalPreference.liveKey(terminal: true, profileID: id, tab: 2))
    }

    @Test("a pane on stage mounts the terminal instead of the chat, and flips back")
    func paneFlips() {
        withClean {
            let p = pane()
            p.applyTabList(roster([1, 2], active: 1))
            p.sessionOnStage = true
            #expect(p.beautifiedModel != nil)
            p.sessionTerminalWindow = 1
            p.updateNativeTerminalMount()
            #expect(p.beautifiedModel == nil, "the chat is still mounted over the terminal")
            p.sessionTerminalWindow = nil
            p.updateNativeTerminalMount()
            #expect(p.beautifiedModel != nil)
            p.sessionOnStage = false
            p.setViewMode(.terminal, persist: false)
            p.retireNativeTerminals()
        }
    }

    @Test("a session's terminal doesn't follow the guest's active tab, and a roster tick never brings the chat back")
    func terminalIsPinned() {
        withClean {
            let p = pane()
            p.applyTabList(roster([1, 2, 4], active: 4))
            p.sessionTerminalWindow = 4
            p.sessionOnStage = true
            #expect(p.beautifiedModel == nil)
            p.applyTabList(roster([1, 2, 4], active: 1))
            #expect(p.model.activeTab?.index == 4)
            #expect(p.beautifiedModel == nil)
            // A window before it closes: the same one, at its new position.
            p.applyTabList(roster([1, 4], active: 1))
            #expect(p.model.activeTab?.index == 4)
            p.retireNativeTerminals()
        }
    }

    @Test("leaving the stage forgets the session's window, so the machine's tab follows the guest again")
    func leavingForgets() {
        withClean {
            let p = pane()
            p.applyTabList(roster([1, 2], active: 2))
            p.sessionTerminalWindow = 2
            p.sessionOnStage = true
            p.sessionOnStage = false
            #expect(p.sessionTerminalWindow == nil)
            p.setViewMode(.terminal, persist: false)
            p.applyTabList(roster([1, 2], active: 1))
            #expect(p.model.activeTab?.index == 1)
            p.retireNativeTerminals()
        }
    }
}
