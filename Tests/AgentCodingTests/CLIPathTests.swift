import Foundation
import Testing
@testable import bromure_ac

/// `-v` paths travel over the control socket to the app, whose own cwd is `/`
/// — so the CLI must resolve them to absolute paths before sending.
/// Regression: `workspaces create -v ./` used to store the share as `/`.
@Suite("CLI host-path resolution")
struct CLIPathTests {

    @Test("Relative paths resolve against the CLI's cwd")
    func relative() {
        let cwd = FileManager.default.currentDirectoryPath
        #expect(absoluteHostPath("./") == cwd)
        #expect(absoluteHostPath(".") == cwd)
        #expect(absoluteHostPath("src") == cwd + "/src")
        #expect(absoluteHostPath("./src") == cwd + "/src")
    }

    @Test("Tilde expands to the user's home")
    func tilde() {
        let home = ("~" as NSString).expandingTildeInPath
        #expect(absoluteHostPath("~/project") == home + "/project")
    }

    @Test("Absolute paths pass through, standardized")
    func absolute() {
        #expect(absoluteHostPath("/opt/data") == "/opt/data")
        #expect(absoluteHostPath("/opt/data/") == "/opt/data")
        #expect(absoluteHostPath("/opt/./data") == "/opt/data")
    }
}
