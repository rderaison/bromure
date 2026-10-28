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

    // Finding (CWE-362): "Dashboard blur-save still overwrites notes saved
    // while the write is in flight". The implicit save compared with the
    // edit's base once, before an awaited write (a fat client's PUT); notes
    // settings saved meanwhile were overwritten. The base now travels with
    // the write and is checked where it is applied.
    @Test("an implicit notes save over the API is dropped once other notes were stored")
    func hostDropsSuperseded() {
        var doc: [String: Any] = ["comments": "draft"]
        #expect(ACAppDelegate.dropSupersededComments(&doc, stored: "settings", ifStill: "base"))
        #expect(doc["comments"] == nil)
        doc = ["comments": "draft"]
        #expect(!ACAppDelegate.dropSupersededComments(&doc, stored: "base\n\n", ifStill: "base"))   // trailing blanks aside
        #expect(doc["comments"] as? String == "draft")
        // Return / Save: no base, an unconditional write.
        #expect(!ACAppDelegate.dropSupersededComments(&doc, stored: "settings", ifStill: nil))
        #expect(doc["comments"] as? String == "draft")
        #expect(ACAppDelegate.notesStill("a  \n", "a"))
        #expect(!ACAppDelegate.notesStill("a", "b"))
    }

    @Test("the base is checked where the notes are written: locally, on the host, and sent by a fat client")
    func baseTravels() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func src(_ p: String) throws -> String { try String(contentsOf: top.appendingPathComponent(p), encoding: .utf8) }
        let ac = try src("Sources/AgentCoding/BromureAC.swift")
        let set = try #require(ac.range(of: "func setNotes(_ id: Profile.ID, _ text: String, ifStill base: String? = nil)"))
        let write = try #require(ac[set.upperBound...].range(of: "try store.update(p)"))
        #expect(ac[set.upperBound..<write.lowerBound].contains("if let base, !Self.notesStill(p.comments, base) { return .superseded(p.comments) }"))
        let upsert = try #require(ac.range(of: "func automationUpsertProfile(idOrName: String?, doc rawDoc: [String: Any])"))
        let merge = try #require(ac[upsert.upperBound...].range(of: "switch ProfileDocument.merge(doc, over: existing)"))
        #expect(ac[upsert.upperBound..<merge.lowerBound].contains(
            "commentsSuperseded = Self.dropSupersededComments(&doc, stored: existing.comments, ifStill: commentsIfStill)"))
        #expect(ac.contains("if commentsSuperseded { result[\"commentsSuperseded\"] = true }"))
        let fc = try src("Sources/AgentCoding/FatClientController.swift")
        #expect(fc.contains("if let base { doc[\"_commentsIfStill\"] = base }"))
        let v = try src("Sources/AgentCoding/VMDashboard.swift")
        #expect(v.contains("let base = implicit ? notesDraftBase : nil"))
        #expect(v.contains("let outcome = await save(text, base)"))
        let w = try src("Sources/AgentCoding/UnifiedSessionWindow.swift")
        #expect(w.contains("setNotes(id, text, ifStill: base)"))
    }

    // Finding (CWE-362): "A superseded notes save leaves the old card up, and
    // the next Save overwrites the notes that won". The card went back to the
    // profile it held (a fat client's snapshot until its next poll, or one no
    // writer refreshed), and Return / Save -- unconditional -- wrote the old
    // notes over the winners.
    @MainActor
    @Test("the host's answer carries the notes that won, even when the rest of the save failed")
    func supersededCarriesWinner() {
        #expect(RemoteHostController.notesOutcome(status: 200, json: ["ok": true, "commentsSuperseded": true, "comments": "won"])
                == .superseded("won"))
        #expect(RemoteHostController.notesOutcome(status: 200, json: ["ok": false, "error": "x", "commentsSuperseded": true, "comments": "won"])
                == .superseded("won"))
        #expect(RemoteHostController.notesOutcome(status: 200, json: ["ok": true, "comments": "mine"]) == .saved)
        #expect(RemoteHostController.notesOutcome(status: 200, json: ["ok": false, "error": "x"]) == .failed)
        #expect(RemoteHostController.notesOutcome(status: 500, json: [:]) == .failed)
    }

    @Test("the card shows the winners at once, and every store write refreshes an open dashboard")
    func cardShowsWinner() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func src(_ p: String) throws -> String { try String(contentsOf: top.appendingPathComponent(p), encoding: .utf8) }
        let v = try src("Sources/AgentCoding/VMDashboard.swift")
        let won = try #require(v.range(of: "if case .superseded(let won) = outcome {"))
        #expect(v[won.upperBound...].prefix(120).contains("notesSaved = won"))
        let ac = try src("Sources/AgentCoding/BromureAC.swift")
        let setter = try #require(ac.range(of: "    var profiles: [Profile] = [] {"))
        #expect(ac[setter.upperBound...].prefix(1600).contains("unifiedWindow?.refreshVMDashboard()"))
        let upsert = try #require(ac.range(of: "try persistEditedProfile(&toSave, editing: editing, generateSSH: generateSSH, policySource: \"api\")"))
        #expect(ac[upsert.upperBound...].prefix(600).contains(
            "if commentsSuperseded, let editing { r[\"commentsSuperseded\"] = true; r[\"comments\"] = editing.comments }"))
    }
}
