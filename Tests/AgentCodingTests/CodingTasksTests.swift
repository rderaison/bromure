import Foundation
import Testing
@testable import bromure_ac

@Suite("Coding tasks")
struct CodingTasksTests {

    @Test("Task prompt carries title, details, and the commit directive")
    func prompt() {
        let task = CodingTask(title: "Fix the leak",
                              details: "## Context\nThe pool leaks fds.",
                              profileID: UUID())
        let p = CodingTaskEngine.prompt(for: task)
        #expect(p.hasPrefix("Fix the leak\n\n## Context"))
        #expect(p.contains("COMMIT all of your work"))
        #expect(p.contains("do not merge into any other branch"))
    }

    @Test("Feedback prompt lists unsent comments with file scopes")
    func feedback() {
        let comments = [
            ReviewComment(text: "Rename this", file: "src/pool.c"),
            ReviewComment(text: "Add a test"),
        ]
        let p = CodingTaskEngine.feedbackPrompt(comments: comments)
        #expect(p.contains("- [src/pool.c] Rename this"))
        #expect(p.contains("- Add a test"))
        #expect(p.contains("commit"))
    }

    @Test("Tasks decode without optional fields (forward compat)")
    func decodeCompat() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"t","details":"","profileID":
         "\(UUID().uuidString)","repoPath":"~","tool":"claude","stage":"backlog",
         "comments":[],"createdAt":"2026-07-01T09:00:00Z","merged":false}
        """
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        let task = try d.decode(CodingTask.self, from: Data(json.utf8))
        #expect(task.stage == .backlog)
        #expect(task.branch == nil)
    }
}

@Suite("Task diff parser")
struct TaskDiffParserTests {

    @Test("Unified diff splits into files with counted +/- lines")
    func basics() {
        let raw = """
        diff --git a/src/a.c b/src/a.c
        index 111..222 100644
        --- a/src/a.c
        +++ b/src/a.c
        @@ -1,3 +1,4 @@
         context
        -old line
        +new line
        +added line
        diff --git a/README.md b/README.md
        new file mode 100644
        --- /dev/null
        +++ b/README.md
        @@ -0,0 +1 @@
        +hello
        """
        let files = TaskDiffParser.parse(raw)
        #expect(files.count == 2)
        guard files.count == 2 else { return }
        #expect(files[0].path == "src/a.c")
        #expect(files[0].added == 2)
        #expect(files[0].removed == 1)
        #expect(files[0].lines.first?.kind == .hunk)
        #expect(files[1].path == "README.md")
        #expect(files[1].added == 1)
    }

    @Test("Header noise (index/mode/rename/binary) never becomes diff lines")
    func noise() {
        let raw = """
        diff --git a/x b/x
        old mode 100644
        new mode 100755
        Binary files a/x and b/x differ
        """
        let files = TaskDiffParser.parse(raw)
        #expect(files.count == 1)
        #expect(files.first?.lines.isEmpty == true)
    }

    @Test("Review data splits marker-delimited guest output")
    func reviewData() {
        let raw = """
        ===LOG===
        abc1234 add feature
        ===STATUS===
        ?? notes.txt
         M src/a.c
        ===DIFF===
        diff --git a/src/a.c b/src/a.c
        @@ -1 +1 @@
        -a
        +b
        """
        let data = TaskReviewData.parse(raw)
        #expect(data.logLines == ["abc1234 add feature"])
        #expect(data.statusLines.count == 2)
        #expect(data.files.count == 1)
        #expect(data.files.first?.added == 1)
    }
}
