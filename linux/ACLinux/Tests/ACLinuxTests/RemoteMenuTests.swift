import Foundation
import NIOConcurrencyHelpers
import Testing
@testable import ACLinux

/// The shared remote menu (`__remote-menu`, RemoteMenu.swift) on Linux: its
/// client over this daemon's control socket, and the macOS helpers it uses.
@Suite("Remote menu", .serialized)
struct RemoteMenuTests {
    /// The menu reads Foundation documents as macOS's ControlClient hands
    /// them over: integers as Int, bodies sent as JSON.
    @Test func theClientSpeaksMacOSDocuments() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let seen = NIOLockedValueBox<(String, String, JSONValue)?>(nil)
        let srv = try await ControlServer.start(path: dir + "/c.sock") { req in
            seen.withLockedValue { $0 = (req.method, req.path, req.body) }
            if req.path == "/health" { return ControlResponse(200, ["ok": true]) }
            return ControlResponse(201, ["profiles": .array([.object(["name": "w", "cpus": 4])]), "ratio": .number(0.5)])
        }
        let c = RemoteMenuClient(socketPath: dir + "/c.sock")
        #expect(c.isAgentRunning())
        try c.ensureAgentRunning()
        let r = try c.request("POST", "/profiles", body: ["name": "w", "cpus": 4, "on": true])
        #expect(r.status == 201)
        let first = (r.json["profiles"] as? [[String: Any]])?.first
        #expect(first?["name"] as? String == "w" && first?["cpus"] as? Int == 4, "\(r.json)")
        #expect(r.json["ratio"] as? Double == 0.5)
        let got = try #require(seen.withLockedValue { $0 })
        #expect(got.0 == "POST" && got.1 == "/profiles")
        #expect(got.2 == .object(["name": "w", "cpus": 4, "on": true]), "\(got.2)")
        await srv.close()
        // No daemon: not running, and ensureAgentRunning says how to start it.
        #expect(!c.isAgentRunning())
        #expect(throws: ControlClient.ClientError.self) { try c.ensureAgentRunning() }
    }

    /// Nothing is sent to a "socket" that isn't one (a file squatting the
    /// path); a real one of this user's, served by this user, is used.
    @Test func theClientRefusesWhatIsntThisUsersSocket() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        try Data("x".utf8).write(to: URL(fileURLWithPath: dir + "/c.sock"))
        #expect(throws: ControlClient.ClientError.self) { _ = try ControlClient.connect(to: dir + "/c.sock") }
        do { _ = try ControlClient.connect(to: dir + "/c.sock") }
        catch { #expect("\(error)".contains("not a socket"), "\(error)") }
        try FileManager.default.removeItem(atPath: dir + "/c.sock")
        let srv = try await ControlServer.start(path: dir + "/c.sock") { _ in ControlResponse(200, ["ok": true]) }
        close(try ControlClient.connect(to: dir + "/c.sock"))
        // Through a symlink (the daemon's <state>/control.sock): the socket it reaches counts.
        try FileManager.default.createSymbolicLink(atPath: dir + "/link.sock", withDestinationPath: dir + "/c.sock")
        close(try ControlClient.connect(to: dir + "/link.sock"))
        await srv.close()
    }

    @Test func hostListsSplitOnCommasAndWhitespace() {
        #expect(HostListField.parse("a.com, b.org\tc.net\n d.io,,") == ["a.com", "b.org", "c.net", "d.io"])
        #expect(HostListField.parse("  ").isEmpty)
    }

    /// $VISUAL edits an owner-only temp copy; no change is nil, an invalid
    /// edit throws, a valid one comes back parsed.
    @Test func editingInTheEditor() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let prior = ProcessInfo.processInfo.environment["VISUAL"]
        defer { if let prior { setenv("VISUAL", prior, 1) } else { unsetenv("VISUAL") } }
        let scratch = dir + "/run/editor"
        try FileManager.default.createDirectory(atPath: dir + "/run", withIntermediateDirectories: true)
        func edit(_ doc: [String: Any]) throws -> [String: Any]? { try editJSONInEditor(doc, scratchDir: scratch) }
        func editor(_ name: String, _ body: String) throws -> String {
            let path = dir + "/" + name
            try "#!/bin/sh\nstat -c %a \"$1\" > \(dir)/mode\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
            chmod(path, 0o755)
            return path
        }
        setenv("VISUAL", try editor("same", "true"), 1)
        #expect(try edit(["a": 1]) == nil, "no change")
        #expect(try String(contentsOfFile: dir + "/mode", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "600")
        setenv("VISUAL", try editor("edit", "printf '{\"a\": 2}' > \"$1\""), 1)
        #expect(try edit(["a": 1])?["a"] as? Int == 2)
        setenv("VISUAL", try editor("bad", "printf 'nope' > \"$1\""), 1)
        #expect(throws: (any Error).self) { try edit(["a": 1]) }
        setenv("VISUAL", try editor("fail", "exit 3"), 1)
        #expect(throws: (any Error).self) { try edit(["a": 1]) }
        // Every edit's file is gone afterwards; the directory is owner-only.
        #expect(try FileManager.default.contentsOfDirectory(atPath: scratch).isEmpty)
        #expect((try FileManager.default.attributesOfItem(atPath: scratch)[.posixPermissions] as? Int) == 0o700)
    }

    /// A file a dropped session left (its process gone) is swept at the next
    /// edit; a live process's is kept.
    @Test func staleEditFilesAreSwept() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let scratch = dir + "/editor"
        let mine = try EditorScratch.create(contents: Data("{}".utf8), in: scratch)
        #expect((try FileManager.default.attributesOfItem(atPath: mine.path)[.posixPermissions] as? Int) == 0o600)
        // A pid that can't be running: past the kernel's pid_max.
        let dead = scratch + "/bromure-workspace-2147483646-x.json"
        try Data("{}".utf8).write(to: URL(fileURLWithPath: dead))
        let next = try EditorScratch.create(contents: Data("{}".utf8), in: scratch)
        #expect(!FileManager.default.fileExists(atPath: dead), "the dead session's file swept")
        #expect(FileManager.default.fileExists(atPath: mine.path), "this live process's kept")
        try? FileManager.default.removeItem(at: next)
    }
}
