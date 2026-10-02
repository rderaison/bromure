import Foundation
import Testing
@testable import bromure_ac

@Suite("Task titles")
struct TaskTitleTests {
    @Test("a task without a title is named after its description")
    func namedFromDescription() {
        var t = CodingTask(profileID: UUID(), tool: .claude)
        t.details = "Please fix the flaky login test on CI. It times out on slow runners.\\nMore notes."
        #expect(TaskEditorSheet.titled(t).title == "Fix the flaky login test on CI")
        // A title of its own wins.
        t.title = "Login flake"
        #expect(TaskEditorSheet.titled(t).title == "Login flake")
        // Neither: nothing to name it after (the editor won't save it).
        let empty = CodingTask(profileID: UUID(), tool: .claude)
        #expect(TaskEditorSheet.titled(empty).title.isEmpty)
    }
}
