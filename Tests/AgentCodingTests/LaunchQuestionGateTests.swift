import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-362): two starts of one workspace (a double-clicked Start,
/// a control-socket start the modal pumps) both put the base-image upgrade
/// question up; the second "Yes" was told "wasn't upgraded — start it again
/// to be asked again" while the first's upgrade was booting (or after its
/// "No" was saved). One question per workspace now: the second start asks
/// nothing and boots nothing.
@Suite("Launch questions: one per workspace")
struct LaunchQuestionGateTests {
    @Test("a second start while the question is up doesn't ask; another workspace does")
    func gate() {
        var g = ACAppDelegate.LaunchQuestionGate()
        let a = UUID(), b = UUID()
        let first = g.begin(a)
        let doubleClick = g.begin(a)    // no second question
        let other = g.begin(b)          // another workspace: its own question
        g.end(a)
        let afterAnswer = g.begin(a)    // answered: the next start may ask again
        #expect(first && !doubleClick && other && afterAnswer)
    }
}
