import Foundation
import Testing
@testable import bromure_ac

/// Board report: select a finding, then change a filter (status, severity,
/// search, repository) so it leaves the rows. The panel went, but the
/// selection stayed: the table stayed compact (Repository and Seen folded
/// away, no panel beside it), and the panel came back when a later filter
/// showed the finding again.
@Suite("macOS Findings: the selection follows the rows")
struct FindingsSelectionTests {
    let a = UUID(), b = UUID(), c = UUID()

    @Test("only a finding the rows show is selected for the panel and the compact table")
    func shown() {
        #expect(HubFindingsTab.shownSelection(a, in: [a, b]) == a)
        #expect(HubFindingsTab.shownSelection(a, in: [b, c]) == nil)
        #expect(HubFindingsTab.shownSelection(nil, in: [a]) == nil)
    }

    @Test("a selected finding that leaves the rows is deselected, so it doesn't come back later")
    func leaves() {
        #expect(HubFindingsTab.selectionAfterChange(a, old: [a, b], new: [b]) == nil)
        #expect(HubFindingsTab.selectionAfterChange(a, old: [a, b], new: [b, a]) == a)
        #expect(HubFindingsTab.selectionAfterChange(nil, old: [a], new: []) == nil)
    }

    @Test("a jump to a finding not among the rows yet (the mirror catching up) stays selected")
    func pendingJump() {
        #expect(HubFindingsTab.selectionAfterChange(c, old: [a], new: [a, b]) == c)
        #expect(HubFindingsTab.selectionAfterChange(c, old: [], new: [a, c]) == c)
    }
}
