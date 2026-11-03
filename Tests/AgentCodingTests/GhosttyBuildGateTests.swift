import Foundation
import Testing

/// libghostty's Sentry/Breakpad handler took over every bromure-ac crash
/// (silent _exit(1), a minidump of process memory on disk), so it's built
/// with -Dsentry=false — and that only holds if every build path asks
/// tools/build-ghostty.sh, whose stamp (commit + flags) tells a stale
/// framework from a current one. A "folder exists" gate let warm checkouts
/// and restored caches keep the Sentry build.
@Suite("GhosttyKit build gate")
struct GhosttyBuildGateTests {

    private var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ path: String) throws -> String {
        try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }

    @Test("build.sh and package.sh always run build-ghostty.sh, never gated on the folder")
    func alwaysChecked() throws {
        for script in ["build.sh", "package.sh"] {
            let text = try read(script)
            #expect(text.contains("\"$SCRIPT_DIR/tools/build-ghostty.sh\""), "\(script) doesn't run build-ghostty.sh")
            #expect(!text.contains("-d \"$SCRIPT_DIR/vendor/GhosttyKit.xcframework\""),
                    "\(script) skips build-ghostty.sh when the framework folder exists")
        }
    }

    @Test("build-ghostty.sh builds without Sentry and stamps the flags with the commit")
    func sentryOffAndStamped() throws {
        let text = try read("tools/build-ghostty.sh")
        #expect(text.contains("-Dsentry=false"))
        #expect(text.contains("WANT=\"$COMMIT $BUILD_FLAGS\""))
        #expect(text.contains("[ \"$(cat \"$STAMP\")\" = \"$WANT\" ]"))
        #expect(text.contains("echo \"$WANT\" > \"$STAMP\""))
    }
}
