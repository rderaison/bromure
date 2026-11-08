import Foundation
import Testing
@testable import bromure_ac

/// Board report: under a strict OpenShell policy the beautified session
/// didn't work: tabs never left "idle", tasks never finished, and lineage
/// lost the agent's reasoning. The agents' hooks (agent-status.sh) run inside
/// the sandbox, which could write only the outbox's urls/ folder, so every
/// status, tool-call line and owed-note mark was refused. The hooks now have a
/// folder of their own, agent/, which the sandbox grants and the host reads
/// for those files only.
@Suite("Under an OpenShell filesystem policy, the agents' hooks still reach the host")
struct OpenShellAgentHookTests {
    private static let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.top.appendingPathComponent(path), encoding: .utf8)
    }
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("osh-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test("the hook writes its status, tool calls and owed mark into agent/ when the host made it")
    func hookUsesAgentFolder() throws {
        let fm = FileManager.default
        let root = try tempDir(); defer { try? fm.removeItem(at: root) }
        let seed = root.appendingPathComponent("seed")
        try ProfileStore(rootDir: root).writeHomeSeedFiles(for: Profile(name: "ws", tool: .claude, authMode: .token),
                                                           into: seed, terminalDefaults: .fallback)
        let body = try String(contentsOf: seed.appendingPathComponent("files/.bromure/agent-status.sh"), encoding: .utf8)
        #expect(body.contains(#"[ -d "$d/agent" ] && d="$d/agent""#))
        let outbox = root.appendingPathComponent("outbox")
        let agent = outbox.appendingPathComponent(SessionDisk.outboxAgentFolder)
        try fm.createDirectory(at: agent, withIntermediateDirectories: true)
        let installed = try PolicyNoteDeliveryTests.installHook(
            body.replacingOccurrences(of: "d=/mnt/bromure-outbox", with: "d=\(outbox.path)"),
            root: root, meta: root.appendingPathComponent("meta"))
        let bin = root.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try "#!/bin/sh\necho 3\n".write(to: bin.appendingPathComponent("tmux"), atomically: true, encoding: .utf8)
        chmod(bin.appendingPathComponent("tmux").path, 0o755)
        let home = root.appendingPathComponent("home")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [installed.hook.path, "working"]
        proc.environment = ["HOME": home.path, "TMUX_PANE": "%1", "PATH": bin.path + ":/usr/bin:/bin"]
        let input = Pipe()
        proc.standardInput = input; proc.standardOutput = Pipe()
        try proc.run()
        input.fileHandleForWriting.write(Data(
            #"{"hook_event_name":"PreToolUse","session_id":"s-1","tool_name":"Bash","tool_use_id":"t1","tool_input":{"command":"curl x"}}"#.utf8))
        try input.fileHandleForWriting.close()
        proc.waitUntilExit()

        let status = try String(contentsOf: agent.appendingPathComponent("agent-status-3.txt"), encoding: .utf8)
        #expect(status.hasPrefix("working\n"))
        let tool = try String(contentsOf: agent.appendingPathComponent("agent-tool-3.jsonl"), encoding: .utf8)
        #expect(tool.contains(#""tool_use_id":"t1""#))
        // Nothing in the outbox itself (the sandbox can't write there).
        let rootFiles = try fm.contentsOfDirectory(atPath: outbox.path).filter { $0 != SessionDisk.outboxAgentFolder }
        #expect(rootFiles.isEmpty)
    }

    @Test("the host takes a status and tool calls from agent/, and nothing else")
    @MainActor func hostReadsAgentFolder() async throws {
        let fm = FileManager.default
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        let agent = dir.appendingPathComponent(SessionDisk.outboxAgentFolder)
        try fm.createDirectory(at: agent, withIntermediateDirectories: true)
        try "done\ns-1".write(to: agent.appendingPathComponent("agent-status-4.txt"), atomically: true, encoding: .utf8)
        try #"{"tool_use_id":"t9"}"#.appending("\n")
            .write(to: agent.appendingPathComponent("agent-tool-4.jsonl"), atomically: true, encoding: .utf8)
        // Named like the outbox's own signals: not the hooks' to send.
        try "https://example.com/x".write(to: agent.appendingPathComponent("url-1.txt"), atomically: true, encoding: .utf8)
        try "".write(to: agent.appendingPathComponent("home-migrated.txt"), atomically: true, encoding: .utf8)
        let tmp = try tempDir(); defer { try? fm.removeItem(at: tmp) }
        let vm = UbuntuSandboxVM(imageManager: UbuntuImageManager(storageDir: tmp, setupDir: tmp))
        var statuses: [(Int, String)] = [], tools: [(Data, Int?)] = [], opened: [URL] = [], migrated = 0
        vm.onAgentStatus = { statuses.append(($0, $1)) }
        vm.onAgentToolCall = { tools.append(($0, $1)) }
        vm.onURLOpen = { opened.append($0) }
        vm.onHomeMigrated = { migrated += 1 }
        let scanner = UbuntuSandboxVM.OutboxScanner(outbox: dir)
        for _ in 0..<24 { for apply in await scanner.tick().all { apply(vm) } }
        #expect(statuses.count == 1 && statuses.first?.0 == 4 && statuses.first?.1 == "done\ns-1")
        #expect(tools.count == 1 && tools.first?.1 == 4)
        #expect(opened.isEmpty && migrated == 0)
        #expect(!fm.fileExists(atPath: agent.appendingPathComponent("agent-status-4.txt").path))
        #expect(fm.fileExists(atPath: agent.appendingPathComponent("url-1.txt").path))
        #expect(fm.fileExists(atPath: agent.appendingPathComponent("home-migrated.txt").path))
    }

    @Test("an agent/ the guest made a symlink isn't followed onto the Mac")
    @MainActor func symlinkedAgentFolderIgnored() async throws {
        let fm = FileManager.default
        let dir = try tempDir(); defer { try? fm.removeItem(at: dir) }
        let mac = try tempDir(); defer { try? fm.removeItem(at: mac) }
        let victim = mac.appendingPathComponent("agent-status-1.txt")
        try "working".write(to: victim, atomically: true, encoding: .utf8)
        try fm.createSymbolicLink(at: dir.appendingPathComponent(SessionDisk.outboxAgentFolder), withDestinationURL: mac)
        let tmp = try tempDir(); defer { try? fm.removeItem(at: tmp) }
        let vm = UbuntuSandboxVM(imageManager: UbuntuImageManager(storageDir: tmp, setupDir: tmp))
        var statuses = 0
        vm.onAgentStatus = { _, _ in statuses += 1 }
        let scanner = UbuntuSandboxVM.OutboxScanner(outbox: dir)
        for _ in 0..<24 { for apply in await scanner.tick().all { apply(vm) } }
        #expect(statuses == 0)
        #expect(fm.fileExists(atPath: victim.path), "a file on the Mac was consumed")
    }

    @Test("the sandbox grants agent/ (not the outbox), the host makes it and clears it at boot")
    func wired() throws {
        let sandboxd = try source("Sources/AgentCoding/Resources/vm-setup/bromure-sandboxd")
        #expect(sandboxd.contains(#"("/mnt/bromure-outbox/agent", "#))
        #expect(!sandboxd.contains(#"("/mnt/bromure-outbox", "#))
        let disk = try source("Sources/AgentCoding/SessionDisk.swift")
        #expect(disk.contains("tmp.appendingPathComponent(Self.outboxAgentFolder, isDirectory: true)"))
        let vm = try source("Sources/AgentCoding/UbuntuSandboxVM.swift")
        #expect(vm.contains("agentCursor.next(agentDir, examine: VM.maxRelayNamesPerTick,"))
        #expect(vm.contains("Self.listing(agentDir, max: Self.maxOutboxEntriesPerTick)"))
        #expect(UbuntuSandboxVM.isAgentHookFile("agent-status-2.txt"))
        #expect(UbuntuSandboxVM.isAgentHookFile("agent-tool-2.jsonl"))
        #expect(!UbuntuSandboxVM.isAgentHookFile(".agent-status-2.tmp"))
        #expect(!UbuntuSandboxVM.isAgentHookFile("url-1.txt"))
        #expect(!UbuntuSandboxVM.isAgentHookFile("agent-tool-2.jsonl.retired"))
    }
}
