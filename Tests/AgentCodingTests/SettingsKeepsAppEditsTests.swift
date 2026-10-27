import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-362): "Saving workspace settings overwrites notes edited on
/// the VM dashboard". The settings window's draft is as old as the window;
/// its Save wrote that draft's notes (and Squelch switch) over the ones the
/// dashboard (the sidebar) saved meanwhile.
@Suite("Settings save keeps the app's edits")
struct SettingsKeepsAppEditsTests {
    private static func profile(notes: String, squelch: Bool) -> Profile {
        var p = Profile(name: "ws", tool: .claude, authMode: .token)
        p.comments = notes
        p.squelch.enabled = squelch
        return p
    }

    @Test("notes and Squelch the editor left alone are the stored ones; edited ones win")
    func localSave() {
        let opened = Self.profile(notes: "A", squelch: false)
        var stored = opened
        stored.comments = "B"            // the dashboard's save
        stored.squelch.enabled = true    // the sidebar's switch

        var draft = opened
        draft.memoryGB = 8               // another setting changed
        draft.adoptAppEdits(from: stored, opened: opened)
        #expect(draft.comments == "B")
        #expect(draft.squelch.enabled)
        #expect(draft.memoryGB == 8)

        var edited = opened
        edited.comments = "C"
        edited.squelch.enabled = false
        edited.adoptAppEdits(from: stored, opened: opened)
        #expect(edited.comments == "C")
        #expect(edited.squelch.enabled)  // left alone: stored
    }

    @Test("the save path applies the rule before writing")
    func localSaveWired() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ac = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/BromureAC.swift"), encoding: .utf8)
        let fn = try #require(ac.range(of: "func persistEditedProfile(_ profile: inout Profile, editing: Profile?,"))
        let save = try #require(ac[fn.upperBound...].range(of: "try store.saveEdited(&profile)"))
        #expect(ac[fn.upperBound..<save.lowerBound].contains("if let opened = editing { profile.adoptAppEdits(from: current, opened: opened) }"))
    }

    @MainActor
    @Test("a fat client's settings document leaves out notes it didn't edit and sends the host's Squelch switch")
    func remoteDoc() throws {
        let opened = Self.profile(notes: "A", squelch: false)
        var now = opened
        now.comments = "B"; now.squelch.enabled = true    // the host's, as last listed
        var edited = opened
        edited.memoryGB = 8
        var doc = try #require(ACAppDelegate.codableToDict(edited))
        #expect(doc["comments"] as? String == "A")
        RemoteHostWindow.dropUnedited(&doc, edited: edited, opened: opened, now: now)
        #expect(doc["comments"] == nil)
        #expect((doc["squelch"] as? [String: Any])?["enabled"] as? Bool == true)

        edited.comments = "C"; edited.squelch.enabled = true
        var mine = try #require(ACAppDelegate.codableToDict(edited))
        RemoteHostWindow.dropUnedited(&mine, edited: edited, opened: opened, now: now)
        #expect(mine["comments"] as? String == "C")
    }

    /// The other way round: a dashboard draft left open while settings saved
    /// other notes must not write itself over them when the focus or the
    /// dashboard goes away; an untouched draft follows the new notes.
    @Test("the dashboard's implicit save never writes over notes saved since the edit began")
    func dashboardImplicitSave() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let v = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/VMDashboard.swift"), encoding: .utf8)
        #expect(v.contains("if implicit, notesDraftBase != notesText { return }"))
        #expect(v.contains(".onDisappear { commitNotes(implicit: true) }"))
        #expect(v.contains("if !notesEditorFocused { commitNotes(implicit: true) }"))
        #expect(v.contains("if notesDraft != nil, notesDraft == notesDraftBase {"))
    }
}
