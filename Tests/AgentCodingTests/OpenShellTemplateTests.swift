import Foundation
import Testing
@testable import bromure_ac

/// Board report: a workspace given OpenShell's "Insert template" filesystem
/// policy never became usable. Reproduced on a real guest (@linux-dev): the
/// session starts, but under any filesystem policy the outbox wasn't
/// writable, so bromure-open (and xdg-open, $BROWSER) failed and no agent
/// could open a URL on the Mac, its sign-in page included. The relay now has
/// a folder of its own the sandbox grants, and nothing else in the outbox.
@Suite("Under an OpenShell filesystem policy, agents can still open URLs on the Mac")
struct OpenShellTemplateTests {
    private static let setup = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/AgentCoding/Resources/vm-setup")
    private func text(_ name: String) throws -> String {
        try String(contentsOf: Self.setup.appendingPathComponent(name), encoding: .utf8)
    }
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("osh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test("the host relays a URL from the outbox's urls/ folder, and takes nothing else from it")
    @MainActor func hostReadsRelayFolder() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let urls = dir.appendingPathComponent(SessionDisk.outboxURLRelayFolder)
        try FileManager.default.createDirectory(at: urls, withIntermediateDirectories: true)
        try "https://example.com/login\n".write(to: urls.appendingPathComponent("url-1-2-ab.txt"), atomically: true, encoding: .utf8)
        // Named like the outbox's own one-shots: not the relay's to deliver.
        try "".write(to: urls.appendingPathComponent("home-migrated.txt"), atomically: true, encoding: .utf8)
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let vm = UbuntuSandboxVM(imageManager: UbuntuImageManager(storageDir: tmp, setupDir: tmp))
        var opened: [URL] = [], migrated = 0
        vm.onURLOpen = { opened.append($0) }
        vm.onHomeMigrated = { migrated += 1 }
        let scanner = UbuntuSandboxVM.OutboxScanner(outbox: dir)
        for _ in 0..<24 { for apply in await scanner.tick() { apply(vm) } }
        #expect(opened == [URL(string: "https://example.com/login")!])
        #expect(migrated == 0)
        #expect(!FileManager.default.fileExists(atPath: urls.appendingPathComponent("url-1-2-ab.txt").path))
        #expect(FileManager.default.fileExists(atPath: urls.appendingPathComponent("home-migrated.txt").path))
    }

    /// FileManager's contentsOfDirectory already refuses a symlinked folder;
    /// the scanner checks it's a real one too, so this never rests on that.
    @Test("a urls/ the guest made a symlink isn't followed onto the Mac")
    @MainActor func symlinkedRelayIgnored() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let mac = try tempDir(); defer { try? FileManager.default.removeItem(at: mac) }
        let victim = mac.appendingPathComponent("url-keep.txt")
        try "https://example.com/not-the-guests\n".write(to: victim, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent(SessionDisk.outboxURLRelayFolder),
                                                   withDestinationURL: mac)
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let vm = UbuntuSandboxVM(imageManager: UbuntuImageManager(storageDir: tmp, setupDir: tmp))
        var opened: [URL] = []
        vm.onURLOpen = { opened.append($0) }
        let scanner = UbuntuSandboxVM.OutboxScanner(outbox: dir)
        for _ in 0..<24 { for apply in await scanner.tick() { apply(vm) } }
        #expect(opened.isEmpty)
        #expect(FileManager.default.fileExists(atPath: victim.path), "a file on the Mac was consumed")
    }

    @Test("bromure-open writes into urls/ when the host made it, else the outbox as before")
    func scriptUsesRelayFolder() throws {
        let sh = try text("setup.sh")
        let body = try #require(sh.components(separatedBy: "cat > /usr/local/bin/bromure-open <<'EOO'\n").last?
            .components(separatedBy: "\nEOO\n").first)
        let outbox = try tempDir(); defer { try? FileManager.default.removeItem(at: outbox) }
        let script = outbox.deletingLastPathComponent().appendingPathComponent("bromure-open-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: script) }
        try body.replacingOccurrences(of: "OUTBOX=/mnt/bromure-outbox", with: "OUTBOX=\(outbox.path)")
            .write(to: script, atomically: true, encoding: .utf8)
        func run() throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [script.path, "https://example.com"]
            try p.run(); p.waitUntilExit()
            #expect(p.terminationStatus == 0)
        }
        try run()   // no urls/ yet: the outbox, as before
        #expect(try FileManager.default.contentsOfDirectory(atPath: outbox.path).filter { $0.hasPrefix("url-") }.count == 1)
        let urls = outbox.appendingPathComponent("urls")
        try FileManager.default.createDirectory(at: urls, withIntermediateDirectories: true)
        try run()
        #expect(try FileManager.default.contentsOfDirectory(atPath: urls.path).filter { $0.hasPrefix("url-") }.count == 1)
    }

    @Test("agentd keeps bromure-open in step, the sandbox grants only urls/, the template lets Python run in parallel")
    func wiring() throws {
        let sh = try text("setup.sh")
        let body = try #require(sh.components(separatedBy: "cat > /usr/local/bin/bromure-open <<'EOO'\n").last?
            .components(separatedBy: "\nEOO\n").first)
        // agentd's copy is the image's, byte for byte.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-c", """
            import importlib.util
            s = importlib.util.spec_from_file_location("agentd", "bromure-agentd.py")
            m = importlib.util.module_from_spec(s); s.loader.exec_module(m)
            import sys; sys.stdout.write(m._BROMURE_OPEN)
            """]
        p.currentDirectoryURL = Self.setup
        let pipe = Pipe(); p.standardOutput = pipe
        try p.run()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(out == body + "\n")
        let agentd = try text("bromure-agentd.py")
        let tasks = try #require(agentd.range(of: "_run_once(\"bromure-open\", task_bromure_open)"))
        let strict = try #require(agentd.range(of: "_run_once(\"strict\", task_strict_sandbox)"))
        #expect(tasks.lowerBound < strict.lowerBound, "it needs sudo, which strict takes away")
        let task = try #require(agentd.range(of: "def task_bromure_open():"))
        let tb = agentd[task.upperBound...].prefix(1400)
        #expect(!tb.contains("\"/tmp"), "staged where a sandboxed agent can write")
        #expect(tb.contains("input=_BROMURE_OPEN"))
        let sandboxd = try text("bromure-sandboxd")
        #expect(sandboxd.contains(#"("/mnt/bromure-outbox/urls", "#))
        #expect(!sandboxd.contains(#"("/mnt/bromure-outbox", "#))
        let editor = try String(contentsOf: Self.setup.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("OpenShellPolicyEditor.swift"), encoding: .utf8)
        #expect(editor.contains("read_write: [/home/ubuntu, /tmp, /dev/null, /dev/shm]"))
        #expect(editor.contains("/dev/urandom, /dev/random, /dev/zero"))
        let disk = try String(contentsOf: Self.setup.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("SessionDisk.swift"), encoding: .utf8)
        #expect(disk.contains("tmp.appendingPathComponent(Self.outboxURLRelayFolder, isDirectory: true)"))
    }
}
