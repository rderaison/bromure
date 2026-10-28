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
    @Test("a fat client's settings document leaves out notes and a Squelch policy it didn't edit")
    func remoteDoc() throws {
        var opened = Self.profile(notes: "A", squelch: false)
        opened.squelch.enabled = false
        var edited = opened
        edited.memoryGB = 8
        var doc = try #require(ACAppDelegate.codableToDict(edited))
        doc["comments"] = "A"; doc["squelch"] = ["enabled": false]
        RemoteHostController.dropUnedited(&doc, edited: edited, opened: opened)
        #expect(doc["comments"] == nil)          // the host keeps the dashboard's
        #expect(doc["squelch"] == nil)           // and the sidebar's switch
        #expect(doc["memoryGB"] as? Int == 8)

        edited.comments = "C"
        edited.squelch.enabled = true
        var mine = try #require(ACAppDelegate.codableToDict(edited))
        RemoteHostController.dropUnedited(&mine, edited: edited, opened: opened)
        #expect(mine["comments"] as? String == "C")
        #expect((mine["squelch"] as? [String: Any])?["enabled"] as? Bool == true)

        // Back to the default policy: sent whole, not left out ("unchanged").
        var on = opened; on.squelch.enabled = true
        var off = on; off.squelch.enabled = false
        var back = try #require(ACAppDelegate.codableToDict(off))
        #expect(back["squelch"] == nil)          // the encoder omits it
        RemoteHostController.dropUnedited(&back, edited: off, opened: on)
        #expect((back["squelch"] as? [String: Any]) != nil)
    }

    @Test("the iOS sheet applies the same rule")
    func iosWired() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ios = try String(contentsOf: top.appendingPathComponent("ios/BromureRemote/Sources/BromureRemote/WorkspaceEditor.swift"), encoding: .utf8)
        #expect(ios.contains("if editing != nil, let original { RemoteHostController.dropUnedited(&doc, edited: edited, opened: original) }"))
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
