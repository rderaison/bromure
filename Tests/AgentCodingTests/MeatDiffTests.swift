import Foundation
import Testing
@testable import bromure_ac

@Suite("Meat diff parsing")
struct MeatDiffTests {
    @Test("parses a git diff into files, counts and gutters")
    func parseDiff() throws {
        let d = MeatDiff.parse("""
        Preserve CommonMark thematic-break lines during smart typography.

        diff --git a/mdv/SmartTypography.swift b/mdv/SmartTypography.swift
        index abc..def 100644
        --- a/mdv/SmartTypography.swift
        +++ b/mdv/SmartTypography.swift
        @@ -36,6 +36,11 @@ func smartenMarkdown(_ source: String) -> String {
             if looksLikeThematicBreakLine(trimmed) {
        +        return source
        +    }
        -    let old = 1
        @@ -72,6 +93,7 @@ func other() {
             if codeRun > 0 {
        """)
        #expect(d.summary.hasPrefix("Preserve CommonMark"))
        let f = try #require(d.files.first)
        #expect(f.path == "mdv/SmartTypography.swift")
        #expect(f.directory == "mdv/")
        #expect(f.basename == "SmartTypography.swift")
        #expect(f.added == 2)
        #expect(f.removed == 1)
        // Gutters: context carries both numbers, an addition only the new side.
        let ctx = try #require(f.lines.first { $0.kind == .context })
        #expect(ctx.oldNumber == 36 && ctx.newNumber == 36)
        let add = try #require(f.lines.first { $0.kind == .added })
        #expect(add.oldNumber == nil && add.newNumber == 37)
        // Both hunk headers survive as their own rows.
        #expect(f.lines.filter { $0.kind == .hunk }.count == 2)
    }

    @Test("multiple files, and the reduction caption")
    func multiFile() {
        let full = MeatDiff.parse("""
        diff --git a/a.swift b/a.swift
        +++ b/a.swift
        @@ -1,1 +1,3 @@
        +one
        +two
        diff --git a/b.swift b/b.swift
        +++ b/b.swift
        @@ -1,1 +1,2 @@
        +three
        diff --git a/c.swift b/c.swift
        +++ b/c.swift
        @@ -1,1 +1,2 @@
        +four
        """)
        let abridged = MeatDiff.parse("""
        diff --git a/a.swift b/a.swift
        +++ b/a.swift
        @@ -1,1 +1,3 @@
        +one
        """)
        #expect(full.files.count == 3)
        #expect(full.changedLines == 4)
        let r = MeatReduction.between(abridged: abridged, full: full)
        #expect(r.caption == "kept 1/4 changed lines in 1/3 files")
    }

    @Test("empty input is empty, not a crash")
    func emptyInput() {
        #expect(MeatDiff.parse("").files.isEmpty)
        #expect(MeatDiff.parse("meat: no diff to read").files.isEmpty)
    }
}
