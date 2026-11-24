import Foundation
import Testing
@testable import ACLinux

/// The guest agent's systemd unit and launcher exist twice: in the image
/// (setup.sh) and in the agent, which converges a workspace to its copy. A
/// difference would rewrite them on every boot, or boot new images with a
/// unit the agent then replaces.
@Suite("Guest agent unit and launcher")
struct AgentdUnitTests {
    static let vmSetup = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/AgentCoding/Resources/vm-setup").path

    static func agentdConstant(_ name: String) throws -> String {
        let src = try String(contentsOfFile: vmSetup + "/bromure-agentd.py", encoding: .utf8)
        let open = "\(name) = r\"\"\""
        let start = try #require(src.range(of: open)).upperBound
        let end = try #require(src.range(of: "\"\"\"", range: start..<src.endIndex)).lowerBound
        return String(src[start..<end])
    }

    static func heredoc(after line: String, tag: String) throws -> String {
        let src = try String(contentsOfFile: vmSetup + "/setup.sh", encoding: .utf8)
        let start = try #require(src.range(of: line + " <<'\(tag)'\n")).upperBound
        let end = try #require(src.range(of: "\n\(tag)\n", range: start..<src.endIndex)).lowerBound
        return String(src[start..<end]) + "\n"
    }

    @Test func theImageAndTheAgentCarryTheSameUnit() throws {
        let unit = try Self.agentdConstant("_UNIT_CONTENT")
        #expect(try Self.heredoc(after: "cat > /etc/systemd/system/bromure-agentd.service", tag: "EOU") == unit)
        // Started early, stopped at shutdown, through the launcher.
        #expect(unit.contains("DefaultDependencies=no\n") && unit.contains("Conflicts=shutdown.target\n"))
        #expect(unit.contains("ExecStart=/usr/bin/python3 -s /usr/local/lib/bromure/agentd-launch.py\n"))
        #expect(unit.contains("ConditionPathExists=/mnt/bromure-meta/bromure-agentd.py\n"))
    }

    @Test func theImageAndTheAgentCarryTheSameLauncher() throws {
        let launcher = try Self.agentdConstant("_LAUNCHER_CONTENT")
        #expect(try Self.heredoc(after: "cat > /usr/local/lib/bromure/agentd-launch.py", tag: "EOP") == launcher)
    }

    /// The image's prepared cache (prepare_image, at install) is the
    /// launcher's: the same key and the same compile, or every new
    /// workspace's first boot would miss it.
    @Test func thePreparedBytecodeUsesTheLaunchersKey() throws {
        let launcher = try Self.agentdConstant("_LAUNCHER_CONTENT")
        let src = try String(contentsOfFile: Self.vmSetup + "/bromure-agentd.py", encoding: .utf8)
        let start = try #require(src.range(of: "def prepare_image():")).lowerBound
        let prepare = String(src[start...].prefix(6000))
        let key = "key = (hashlib.sha256(src).hexdigest() + \" \" + sys.version).encode()"
        #expect(launcher.contains(key) && prepare.contains(key))
        #expect(launcher.contains("P = \"/mnt/bromure-meta/bromure-agentd.py\"") && launcher.contains("compile(src, P, \"exec\")"))
        #expect(prepare.contains("compile(src, \"/mnt/bromure-meta/bromure-agentd.py\", \"exec\")"))
        #expect(launcher.contains("CACHE = \"/var/cache/bromure-agentd/agentd.bin\"") && prepare.contains("\"agentd.bin\""))
        // postinstall.sh runs it after the catalog steps.
        let post = try String(contentsOfFile: Self.vmSetup + "/postinstall.sh", encoding: .utf8)
        #expect(post.contains("bromure-agentd.py --prepare-image"))
    }

    /// The launcher runs a script as `python3 script` would: as __main__,
    /// with its own __file__; from the cache the second time.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func theLauncherRunsTheAgentAndCachesItsBytecode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("launch-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir + "/cache", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let script = dir + "/agent.py"
        try "import sys\nprint(__name__, __file__ == sys.argv[0], __file__.endswith('agent.py'))\n"
            .write(toFile: script, atomically: true, encoding: .utf8)
        let launcher = try Self.agentdConstant("_LAUNCHER_CONTENT")
            .replacingOccurrences(of: "/mnt/bromure-meta/bromure-agentd.py", with: script)
            .replacingOccurrences(of: "/var/cache/bromure-agentd/agentd.bin", with: dir + "/cache/agentd.bin")
        try launcher.write(toFile: dir + "/launch.py", atomically: true, encoding: .utf8)
        func run() throws -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = ["-s", dir + "/launch.py"]
            let out = Pipe()
            p.standardOutput = out
            try p.run()
            p.waitUntilExit()
            return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        #expect(try run() == "__main__ True True\n", "compiled")
        #expect(FileManager.default.fileExists(atPath: dir + "/cache/agentd.bin"), "and cached")
        #expect(try run() == "__main__ True True\n", "from the cache")
        try "print('changed')\n".write(toFile: script, atomically: true, encoding: .utf8)
        #expect(try run() == "changed\n", "a new source is compiled, not the cached one run")
    }
}
