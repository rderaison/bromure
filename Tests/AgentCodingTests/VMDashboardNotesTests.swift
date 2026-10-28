import Foundation
import Testing
@testable import bromure_ac

@Suite("VM dashboard notes")
struct VMDashboardNotesTests {
    private static func src(_ path: String) throws -> String {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: top.appendingPathComponent(path), encoding: .utf8)
    }

    /// A pane keeps the profile it booted with (`SessionPane.profile` is
    /// never reassigned), so a refresh that preferred it turned a running
    /// workspace's dashboard back to its notes, name and color from before
    /// the save, right after the save.
    @Test("the dashboard refresh shows the saved profile, not the pane's boot copy")
    func refreshUsesSavedProfile() throws {
        let w = try Self.src("Sources/AgentCoding/UnifiedSessionWindow.swift")
        let start = try #require(w.range(of: "func refreshVMDashboard() {"))
        let body = w[start.upperBound...].prefix(700)
        #expect(body.contains("let profile = acDelegate?.profile(for: id) else { return }"))
        #expect(!body.contains("pane(id)?.profile"))
        // Opening it again (after a save, from the sidebar) too.
        let open = try #require(w.range(of: "func showVMDashboard(_ id: Profile.ID, editingNotes: Bool = false) {"))
        let built = w[open.upperBound...].prefix(1600)
        #expect(built.contains("profile: profile,"))
        #expect(!built.contains("p?.profile"))
    }

    /// A draft open when the dashboard goes away is saved, not dropped.
    @Test("leaving the dashboard saves the notes being edited")
    func teardownSaves() throws {
        let v = try Self.src("Sources/AgentCoding/VMDashboard.swift")
        let card = try #require(v.range(of: "private var notesCard: some View {"))
        let editor = try #require(v.range(of: "@ViewBuilder private var notesEditor: some View {"))
        #expect(v[card.upperBound..<editor.lowerBound].contains(".onDisappear { commitNotes(implicit: true) }"))
    }

    /// A save that fails (the store, the remote) must not leave the
    /// dashboard showing notes that were never saved.
    @Test("a failed notes save is reported back to the dashboard")
    func failedSaveReported() throws {
        let v = try Self.src("Sources/AgentCoding/VMDashboard.swift")
        #expect(v.contains("var onSaveNotes: (@MainActor (String, String?) async -> NotesSave)? = nil"))
        #expect(v.contains("guard outcome != .saved, notesSaved == text else { return }"))
        #expect(v.contains("if outcome == .failed, notesDraft == nil { notesDraft = text; notesDraftBase = notesText }"))
        let f = try Self.src("Sources/AgentCoding/FatClientController.swift")
        #expect(f.contains("guard let r = try? await c.saveProfileDoc(id, doc) else { return .failed }"))
    }

    @Test("the tooltip carries the notes' first five lines, at most 300 characters")
    func excerpt() {
        var row = SessionListModel.ProfileRow(id: UUID(), name: "w", accentHex: "#888888", state: .off, compromised: false)
        #expect(row.notesExcerpt == "")
        row.notes = "  \n\n "
        #expect(row.notesExcerpt == "")
        row.notes = "# Title\nline"
        #expect(row.notesExcerpt == "# Title\nline")
        row.notes = (1...7).map { "l\($0)" }.joined(separator: "\n")
        #expect(row.notesExcerpt == "l1\nl2\nl3\nl4\nl5…")
        row.notes = String(repeating: "x", count: 400)
        #expect(row.notesExcerpt == String(repeating: "x", count: 300) + "…")
    }

    @Test("the notes card's strings are in every locale")
    func localized() throws {
        for loc in ["en", "fr", "de", "es", "pt", "ja", "zh-Hans", "zh-Hant"] {
            let s = try Self.src("Sources/AgentCoding/\(loc).lproj/Localizable.strings")
            for key in ["Notes", "Return saves · Shift-Return adds a line · Esc cancels",
                        "Save the notes (Return)", "Edit the notes as markdown", "(empty)", "Save", "Edit"] {
                #expect(s.contains("\n\"\(key)\" = "), "\(loc): \(key)")
            }
        }
    }
}
