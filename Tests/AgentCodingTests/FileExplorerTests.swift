import Foundation
import AppKit
import Testing
@testable import bromure_ac

@Suite("FileExplorer parsing")
@MainActor
struct FileExplorerTests {

    // MARK: Porcelain status

    @Test("Porcelain XY pairs map to the right statuses")
    func porcelainPairs() {
        #expect(GitFileStatus(porcelain: " M") == .modified)
        #expect(GitFileStatus(porcelain: "M ") == .modified)
        #expect(GitFileStatus(porcelain: "MM") == .modified)
        #expect(GitFileStatus(porcelain: "T ") == .modified)
        #expect(GitFileStatus(porcelain: "A ") == .added)
        #expect(GitFileStatus(porcelain: "??") == .untracked)
        #expect(GitFileStatus(porcelain: " D") == .deleted)
        #expect(GitFileStatus(porcelain: "D ") == .deleted)
        #expect(GitFileStatus(porcelain: "R ") == .renamed)
        #expect(GitFileStatus(porcelain: "UU") == .conflicted)
        #expect(GitFileStatus(porcelain: "AA") == .conflicted)
        #expect(GitFileStatus(porcelain: "DD") == .conflicted)
        #expect(GitFileStatus(porcelain: "  ") == nil)
        #expect(GitFileStatus(porcelain: "X") == nil)
    }

    @Test("status --porcelain -z stream parses, including rename origin tokens")
    func porcelainStream() {
        // " M a.txt" ␀ "?? new file.txt" ␀ "R  new.txt" ␀ "old.txt" ␀ " D gone"
        let raw = " M a.txt\u{0}?? new file.txt\u{0}R  new.txt\u{0}old.txt\u{0} D gone\u{0}"
        let statuses = FileExplorerModel.parsePorcelain(raw)
        #expect(statuses["a.txt"] == .modified)
        #expect(statuses["new file.txt"] == .untracked)     // spaces survive -z
        #expect(statuses["new.txt"] == .renamed)
        #expect(statuses["old.txt"] == nil)                 // origin token skipped
        #expect(statuses["gone"] == .deleted)
        #expect(statuses.count == 4)
    }

    @Test("Statuses map to the folder on show: inside a repo, and repos nested under it")
    func statusMapping() {
        // The home isn't a repository; project/ under it is (unfolded).
        let nested = FileExplorerModel.mapStatuses(root: "/home/ubuntu", sections: [
            ("", ""),
            ("/home/ubuntu/project", " M src/a.swift\u{0}?? README.md\u{0}"),
        ])
        #expect(nested.statuses["project/src/a.swift"] == .modified)
        #expect(nested.statuses["project/README.md"] == .untracked)
        #expect(nested.statuses.count == 2)
        #expect(nested.origins["project/src/a.swift"]?.repo == "/home/ubuntu/project")
        #expect(nested.origins["project/src/a.swift"]?.path == "src/a.swift")

        // A subfolder of a repository on show: only what's under it, relative.
        let inside = FileExplorerModel.mapStatuses(root: "/home/ubuntu/project/src", sections: [
            ("/home/ubuntu/project", " M src/a.swift\u{0}?? README.md\u{0}"),
        ])
        #expect(inside.statuses == ["a.swift": .modified])
        #expect(inside.origins["a.swift"]?.path == "src/a.swift")

        // The repository itself on show, plus a second one nested in it.
        let same = FileExplorerModel.mapStatuses(root: "/home/ubuntu/project", sections: [
            ("/home/ubuntu/project", " M src/a.swift\u{0}"),
            ("/home/ubuntu/project/vendor/lib", "?? new.c\u{0}"),
        ])
        #expect(same.statuses["src/a.swift"] == .modified)
        #expect(same.statuses["vendor/lib/new.c"] == .untracked)

        // Repositories elsewhere say nothing about this folder.
        let other = FileExplorerModel.mapStatuses(root: "/home/ubuntu/project", sections: [
            ("/opt/elsewhere", " M x\u{0}"),
        ])
        #expect(other.statuses.isEmpty)
    }

    // MARK: Tree building

    @Test("Tree nests, sorts dirs first, and unions deleted files from status")
    func treeBuilding() {
        let paths = ["b.txt", "Sources/App/main.swift", "Sources/z.swift", "a.txt"]
        let statuses: [String: GitFileStatus] = [
            "Sources/App/main.swift": .modified,
            "Removed/gone.swift": .deleted,   // not in ls-files — staged delete
        ]
        let roots = FileNode.tree(paths: paths, statuses: statuses)

        // Top level: Removed/, Sources/ (dirs first, alphabetical), a.txt, b.txt
        #expect(roots.map(\.name) == ["Removed", "Sources", "a.txt", "b.txt"])

        let sources = roots[1]
        #expect(sources.isDirectory)
        #expect(sources.containsChanges)                    // main.swift is dirty below
        #expect(sources.children.map(\.name) == ["App", "z.swift"])

        let app = sources.children[0]
        #expect(app.containsChanges)
        #expect(app.children.first?.status == .modified)

        let removed = roots[0]
        #expect(removed.children.first?.status == .deleted) // unioned in
        #expect(roots[2].status == nil)                     // a.txt clean
        #expect(roots[2].containsChanges == false)          // files never carry the dir dot
    }

    // MARK: Unified diff

    @Test("DiffDocument computes kinds, counts, and gutter line numbers")
    func diffParsing() {
        let diff = """
        diff --git a/file.txt b/file.txt
        index 83db48f..bf269f4 100644
        --- a/file.txt
        +++ b/file.txt
        @@ -1,3 +1,4 @@
         line one
        -line two
        +line 2
        +line 2.5
         line three
        """
        let doc = DiffDocument(unifiedDiff: diff)
        #expect(doc.additions == 2)
        #expect(doc.deletions == 1)

        let kinds = doc.lines.map(\.kind)
        #expect(kinds == [.meta, .meta, .meta, .meta, .hunk,
                          .context, .deletion, .addition, .addition, .context])

        // "line one" is old 1 / new 1; the deletion consumes old 2; the two
        // additions take new 2 and 3; trailing context lands old 3 / new 4.
        let context1 = doc.lines[5]
        #expect(context1.oldLine == 1 && context1.newLine == 1)
        let deletion = doc.lines[6]
        #expect(deletion.oldLine == 2 && deletion.newLine == nil)
        let addition1 = doc.lines[7]
        #expect(addition1.oldLine == nil && addition1.newLine == 2)
        let context2 = doc.lines[9]
        #expect(context2.oldLine == 3 && context2.newLine == 4)
    }

    @Test("Empty diff yields an empty document")
    func emptyDiff() {
        let doc = DiffDocument(unifiedDiff: "")
        #expect(doc.lines.isEmpty)
        #expect(doc.additions == 0 && doc.deletions == 0)
    }

    // MARK: Helpers

    @Test("NUL-separated listing decodes")
    func nulSplit() {
        let data = Data("a.txt\u{0}dir/b bis.txt\u{0}".utf8)
        let files = FileExplorerModel.nulSeparatedStrings(data[...])
        #expect(files == ["a.txt", "dir/b bis.txt"])
    }

    @Test("Language mapping covers the common cases and falls back to nil")
    func languageMapping() {
        #expect(FileExplorerModel.language(forExtension: "swift") == "swift")
        #expect(FileExplorerModel.language(forExtension: "py") == "python")
        #expect(FileExplorerModel.language(forExtension: "yml") == "yaml")
        #expect(FileExplorerModel.language(forExtension: "weird") == nil)
    }

    // MARK: Vendored Highlightr

    @Test("Vendored Highlightr finds its resources, themes, and highlights")
    func highlightrSmoke() {
        let highlightr = Highlightr()
        #expect(highlightr != nil)   // nil = highlight.min.js not found — resource bundle regression
        let attributed = highlightr?.highlight("let x = 42", as: "swift", fastRender: true)
        #expect((attributed?.length ?? 0) > 0)
        #expect(highlightr?.setTheme(to: "atom-one-dark") == true)
        #expect(highlightr?.theme.themeBackgroundColor != nil)
    }

    /// Code that stresses the span walker: non-ASCII and astral characters
    /// (UTF-16 offsets ≠ Character counts), literal `<` / `&` the markup
    /// escapes, and nested spans (an interpolation inside a string).
    static let highlightSamples: [(code: String, lang: String)] = [
        ("let café = \"naïve 👩‍💻 \\(a < b && c > d)\" // é\nif x<y { print(\"<tag> & &amp;\") }", "swift"),
        ("def f(x):\n    return x < 1 and \"日本語 😀\" or f'{x!r}' # <b>", "python"),
        ("<div class=\"a\">&lt;ü&gt; <span>🙂</span></div>", "xml"),
    ]

    @Test("Highlightr keeps the code's text exactly, whatever it contains")
    func highlightrRoundTrips() throws {
        let highlightr = try #require(Highlightr())
        for (code, lang) in Self.highlightSamples {
            let attributed = try #require(highlightr.highlight(code, as: lang, fastRender: true))
            #expect(attributed.string == code, "\(lang)")
            // Highlighted, not one flat run.
            var colors = Set<String>()
            attributed.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: attributed.length)) { v, _, _ in
                if let v { colors.insert("\(v)") }
            }
            #expect(colors.count > 1, "\(lang)")
        }
    }
}
