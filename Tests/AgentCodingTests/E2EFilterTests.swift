import Foundation
import Testing

/// Board finding: an e2e section's gate matched `--filter` against its number
/// only, while `test()` matches test names -- `--filter Landlock` skipped
/// section 34 whole and the run "passed" having tested nothing. The gate now
/// matches the number or any of the section's test names (the harness indexes
/// them from its own source), and a filter that names no test fails at once.
@Suite("e2e: a name filter reaches its section; one that names nothing fails")
struct E2EFilterTests {
    private static let suite = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("ac-e2e.mjs")

    /// The harness's own index: the same pattern, over the same file.
    private func index(_ src: String) throws -> [String: [String]] {
        let re = try NSRegularExpression(pattern: #"\btest\(\s*["`](\d+)\.([^"`\n]*)["`]"#)
        let ns = src as NSString
        var by: [String: [String]] = [:]
        for m in re.matches(in: src, range: NSRange(location: 0, length: ns.length)) {
            let n = ns.substring(with: m.range(at: 1))
            let name = n + "." + ns.substring(with: m.range(at: 2))
            by[n + ".", default: []].append(name)
            if name.contains("${") {
                for d in 0...9 {
                    by[n + ".", default: []].append(
                        name.replacingOccurrences(of: #"\$\{[^}]*\}"#, with: String(d), options: .regularExpression))
                }
            }
        }
        return by
    }

    private func active(_ filter: String, _ prefix: String, _ by: [String: [String]]) throws -> Bool {
        let re = try NSRegularExpression(pattern: filter, options: .caseInsensitive)
        func hit(_ s: String) -> Bool { re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil }
        return hit(prefix) || (by[prefix] ?? []).contains(where: hit)
    }

    @Test("name filters select the section that holds the test; a typo selects none")
    func nameFilters() throws {
        let src = try String(contentsOf: Self.suite, encoding: .utf8)
        let by = try index(src)
        #expect(by.count > 20)
        let sections = by.keys.sorted { Int($0.dropLast())! < Int($1.dropLast())! }
        func selected(_ f: String) throws -> [String] { try sections.filter { try active(f, $0, by) } }
        #expect(try selected("Landlock") == ["34."])
        #expect(try selected("seccomp") == ["34."])
        #expect(try selected(#"^34\."#) == ["34."])
        #expect(try selected(#"^8\."#) == ["8."])
        #expect(try selected("deny-web-POST") == ["27."])
        #expect(try selected("nosuchtestxyz").isEmpty)
        // A name built at run time (`32.${round + 1} …`) is found by its number.
        #expect(try selected(#"32\.2"#) == ["32."])

        // The harness does what this test does.
        #expect(src.contains(#"for (const m of src.matchAll(/\btest\(\s*["`](\d+)\.([^"`\n]*)["`]/g)) {"#))
        #expect(src.contains("return re.test(prefix) || (SECTION_TESTS.get(prefix) || []).some((name) => re.test(name));"))
        #expect(src.contains("matches no test name — nothing would run."))
        #expect(src.contains("bySection.get(key).push(name.replace(/\\$\\{[^}]*\\}/g, String(d)));"))
    }
}
