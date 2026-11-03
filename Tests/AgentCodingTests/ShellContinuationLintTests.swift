import Foundation
import Testing

/// Finding (CWE-670): "Boot-test comment eats the workdir mkdir, so Landlock
/// never grants it". A comment placed after a backslash-continued line ends
/// the command there: bash drops the backslash-newline, the `#` comments out
/// the rest, and the next line runs on its own (`"$WORK/workdir"` → 127, the
/// directory never made). `bash -n` doesn't see it. No shell script in the
/// repository may continue a command into a comment line.
@Suite("Shell scripts: no command continued into a comment")
struct ShellContinuationLintTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static func isShellScript(_ url: URL) -> Bool {
        if ["sh", "bash"].contains(url.pathExtension) { return true }
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let head = String(decoding: h.readData(ofLength: 128), as: UTF8.self)
        guard head.hasPrefix("#!"), let first = head.split(separator: "\n").first else { return false }
        return first.hasSuffix("/sh") || first.hasSuffix("/bash") || first.contains("env bash")
            || first.contains("env sh") || first.contains("/bash ") || first.contains("/sh ")
    }

    /// The (1-based) number of every continued line (an odd run of trailing
    /// backslashes) whose next line is a comment or blank: either ends the
    /// command there and runs the line after it on its own.
    static func offenders(in text: String) -> [Int] {
        let lines = text.components(separatedBy: "\n")
        var out: [Int] = []
        for i in 0..<max(0, lines.count - 1) {
            let line = lines[i].trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let lead = line.drop(while: { $0 == " " || $0 == "\t" })
            let slashes = line.reversed().prefix { $0 == "\\" }.count
            guard !lead.hasPrefix("#"), slashes % 2 == 1 else { continue }
            let next = lines[i + 1].trimmingCharacters(in: .whitespaces)
            if next.isEmpty || next.hasPrefix("#") { out.append(i + 1) }
        }
        return out
    }

    @Test("the check catches the finding's shape and leaves ordinary continuations alone")
    func detector() {
        let bad = """
            mkdir -p "$WORK/meta" \\
                # a comment
                "$WORK/workdir"
            """
        #expect(Self.offenders(in: bad) == [1])
        // A blank line after the continuation, and an odd run of backslashes.
        #expect(Self.offenders(in: "mkdir -p a \\\n\n    b\n") == [1])
        #expect(Self.offenders(in: "echo x\\\\\\\n# c\nb\n") == [1])
        // An even run is a literal backslash, not a continuation.
        #expect(Self.offenders(in: "echo x\\\\\n# c\n").isEmpty)
        let good = """
            # a comment above
            mkdir -p "$WORK/meta" \\
                     "$WORK/workdir"
            #   EXAMPLE=1 \\
            #   ./run.sh
            """
        #expect(Self.offenders(in: good).isEmpty)
    }

    @Test("no shell script in the repository continues a command into a comment")
    func repository() throws {
        let skip: Set<String> = [".git", ".build", "vendor", "node_modules", ".swiftpm", "DerivedData", ".claude"]
        var found: [String] = []
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: Self.root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey]) else {
            Issue.record("can't walk \(Self.root.path)"); return
        }
        var scanned = 0
        for case let url as URL in walk {
            if skip.contains(url.lastPathComponent) { walk.skipDescendants(); continue }
            // Another checkout nested in this one (a git worktree): not this tree's scripts.
            if url != Self.root, fm.fileExists(atPath: url.appendingPathComponent(".git").path) {
                walk.skipDescendants(); continue
            }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  Self.isShellScript(url), let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            let rel = url.path.replacingOccurrences(of: Self.root.path + "/", with: "")
            found += Self.offenders(in: text).map { "\(rel):\($0)" }
        }
        #expect(scanned > 10, "only \(scanned) shell scripts found")
        #expect(found.isEmpty, "a command continued into a comment: \(found.joined(separator: ", "))")
    }
}
