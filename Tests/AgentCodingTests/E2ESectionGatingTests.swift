import Foundation
import Testing

/// Board finding: Jenkins runs Tests/ac-e2e.mjs once per section with
/// `--filter "^N\."`. `test()` skips assertions that don't match, but a
/// section's own setup -- a probe workspace and session, a VM boot -- runs
/// outside it. Section 34 (OpenShell) had been gated already; sections 6, 8
/// and 15 still booted a probe VM in every stage (the CI log's
/// "'ACE2E_CLI_Probe' didn't poweroff in 15s" during the egress stage).
@Suite("e2e: a section's VM setup runs only when that section does")
struct E2ESectionGatingTests {
    private static let suite = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("ac-e2e.mjs")

    @Test("every VM section is gated by its own filter; skip lines name --no-sessions only for it")
    func gated() throws {
        let src = try String(contentsOf: Self.suite, encoding: .utf8)
        let lines = src.components(separatedBy: "\n")
        // Every section gate on --no-sessions also checks the section filter.
        let gates = lines.filter { $0.contains("if (!SKIP_SESSIONS") }
        #expect(gates.count >= 12)   // 6, 8, 10, 24, 27-34
        for g in gates { #expect(g.contains("sectionActive(\""), "ungated: \(g)") }
        // The probe sections in particular.
        for n in ["6", "8", "10", "27", "34"] {
            #expect(src.contains("if (!SKIP_SESSIONS && sectionActive(\"\(n).\")) {"), "section \(n)")
        }
        #expect(src.contains("let cliVMable = !SKIP_SESSIONS && sectionActive(\"15.\");"))
        // "(skipped via --no-sessions)" at a section's top level only when it was.
        for (i, l) in lines.enumerated() where l.hasPrefix("    console.log(\"\\n--- ") && l.contains("(skipped via --no-sessions)") {
            #expect(lines[i - 1] == "  } else if (SKIP_SESSIONS) {", "line \(i + 1): \(lines[i - 1])")
        }
    }
}
