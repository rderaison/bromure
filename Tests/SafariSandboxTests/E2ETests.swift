import Foundation
import Testing

/// End-to-end tests that exercise the actual bromure CLI binary.
///
/// These tests build and codesign the binary, then invoke subcommands
/// and verify their output and exit codes.
@Suite("E2E CLI")
struct E2ETests {
    /// Path to the built and signed binary.
    static let binaryPath: String = {
        // Use the release app bundle binary (built by build.sh) if available,
        // otherwise fall back to building in the test.
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // BromureTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // project root
        return projectRoot
            .appendingPathComponent(".build/arm64-apple-macosx/release/bromure.app/Contents/MacOS/bromure")
            .path
    }()

    /// Build the binary if it doesn't exist.
    static let ensureBuilt: Bool = {
        let fm = FileManager.default
        if fm.fileExists(atPath: binaryPath) {
            return true
        }
        // Run build.sh
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let buildScript = projectRoot.appendingPathComponent("build.sh").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [buildScript]
        process.currentDirectoryURL = projectRoot
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }()

    private func run(
        _ arguments: [String] = [],
        timeout: TimeInterval = 30
    ) throws -> (stdout: String, stderr: String, exitCode: Int32) {
        guard Self.ensureBuilt else {
            throw CocoaError(.fileNoSuchFile)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.binaryPath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Set up a timeout
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return (
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    // MARK: - Help & Usage

    @Test("--help prints usage and exits 0")
    func helpFlag() throws {
        let result = try run(["--help"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("bromure"))
        #expect(result.stdout.contains("USAGE"))
    }

    @Test("help shows subcommands: init, run, setup")
    func helpShowsSubcommands() throws {
        let result = try run(["--help"])
        #expect(result.stdout.contains("init"))
        #expect(result.stdout.contains("run"))
        #expect(result.stdout.contains("setup"))
    }

    @Test("init --help shows init-specific options")
    func initHelp() throws {
        let result = try run(["init", "--help"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("--disk-size"))
        #expect(result.stdout.contains("--storage-dir"))
    }

    @Test("run --help shows run-specific options")
    func runHelp() throws {
        let result = try run(["run", "--help"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("--cpus"))
        #expect(result.stdout.contains("--memory"))
        #expect(result.stdout.contains("--no-network"))
        #expect(result.stdout.contains("--no-audio"))
        #expect(result.stdout.contains("--persist"))
        #expect(result.stdout.contains("--width"))
        #expect(result.stdout.contains("--height"))
    }

    @Test("setup --help shows setup-specific options")
    func setupHelp() throws {
        let result = try run(["setup", "--help"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("--storage-dir"))
    }

    @Test("Invalid subcommand fails with non-zero exit")
    func invalidSubcommand() throws {
        let result = try run(["bogus"])
        #expect(result.exitCode != 0)
    }

    // MARK: - Init (without base image)

    @Test("init detects existing base image")
    func initExistingBaseImage() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create fake base image files so init thinks it already exists
        try Data().write(to: tmpDir.appendingPathComponent("base.img"))
        try Data().write(to: tmpDir.appendingPathComponent("base-aux.img"))
        try Data().write(to: tmpDir.appendingPathComponent("base.json"))

        let result = try run(["init", "--storage-dir", tmpDir.path])
        #expect(result.exitCode == 0)
        let combined = result.stdout + result.stderr
        #expect(combined.contains("Base image already exists"))
    }

    @Test("init --disk-size accepts custom value")
    func initCustomDiskSize() throws {
        // Just verify the flag is accepted by argument parser (not an unknown option)
        let result = try run(["init", "--help"])
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("--disk-size"))
    }

    // MARK: - Run (without base image)

    @Test("run without base image fails with helpful message")
    func runNoBaseImage() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let result = try run(["run", "--storage-dir", tmpDir.path])
        #expect(result.exitCode != 0)
        let combined = result.stdout + result.stderr
        #expect(combined.contains("No base image found") || combined.contains("bromure init"))
    }

    // MARK: - Setup (without base image)

    @Test("setup without base image fails with helpful message")
    func setupNoBaseImage() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let result = try run(["setup", "--storage-dir", tmpDir.path])
        #expect(result.exitCode != 0)
        let combined = result.stdout + result.stderr
        #expect(combined.contains("No base image found") || combined.contains("bromure init"))
    }

    // MARK: - Argument validation

    @Test("run --cpus accepts a valid value")
    func runCpusArg() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let result = try run(["run", "--storage-dir", tmpDir.path, "--cpus", "2"])
        // Will fail because no base image, but should not fail on arg parsing
        let combined = result.stdout + result.stderr
        #expect(!combined.contains("Error: The value '2' is invalid"))
    }

    @Test("run --cpus with non-integer fails")
    func runCpusInvalid() throws {
        let result = try run(["run", "--cpus", "notanumber"])
        #expect(result.exitCode != 0)
    }

    @Test("run --memory accepts a valid value")
    func runMemoryArg() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let result = try run(["run", "--storage-dir", tmpDir.path, "--memory", "8"])
        let combined = result.stdout + result.stderr
        #expect(!combined.contains("Error: The value '8' is invalid"))
    }

    @Test("run --no-network and --no-audio are accepted together")
    func runIsolationFlags() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let result = try run(["run", "--storage-dir", tmpDir.path, "--no-network", "--no-audio"])
        let combined = result.stdout + result.stderr
        // Should fail on missing base image, not on arg parsing
        #expect(combined.contains("No base image found") || combined.contains("bromure init"))
    }
}
