import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-400): "Host loads unbounded agent-tool jsonl from the guest
/// outbox". The outbox poll read every agent-tool-*.jsonl whole each ~480 ms
/// (and every status .txt), though the guest — a compromised workload
/// included — writes that directory; and the truncate after a read dropped a
/// line the hook appended meanwhile.
@Suite("Guest outbox: nothing is read whole")
struct OutboxBoundsTests {
    func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    func append(_ url: URL, _ s: String) throws {
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try FileHandle(forWritingTo: url); defer { try? h.close() }
        try h.seekToEnd(); try h.write(contentsOf: Data(s.utf8))
    }

    @Test("new complete lines come a window at a time from the saved offset; a partial line waits")
    func incremental() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("agent-tool-1.jsonl")
        var log = UbuntuSandboxVM.ToolLog()
        try append(f, "{\"a\":1}\n{\"a\":2}\n{\"a\":")
        #expect(log.read(f).count == 2)
        #expect(log.read(f).isEmpty)                       // the partial line waits
        try append(f, "3}\n")
        #expect(log.read(f).map { String(decoding: $0, as: UTF8.self) } == ["{\"a\":3}"])
    }

    @Test("a flooded backlog is skipped, not loaded; an oversized line is dropped")
    func flood() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("agent-tool-2.jsonl")
        var log = UbuntuSandboxVM.ToolLog()
        try Data(repeating: 0x41, count: UbuntuSandboxVM.ToolLog.backlogCap + 10).write(to: f)
        #expect(log.read(f).isEmpty)                       // skipped to the end, never loaded…
        #expect(log.retired != nil)                         // …and, being large, retired
        try append(f, "{\"ok\":1}\n")
        #expect(log.read(f).count == 1)                    // later lines still arrive

        let g = d.appendingPathComponent("agent-tool-3.jsonl")
        var log2 = UbuntuSandboxVM.ToolLog()
        try append(g, String(repeating: "x", count: 9000) + "\n{\"small\":1}\n")
        #expect(log2.read(g).map { String(decoding: $0, as: UTF8.self) } == ["{\"small\":1}"])
    }

    @Test("a fully read large log is renamed away, and a line appended to it meanwhile still arrives")
    func rotationKeepsInFlightAppend() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let f = d.appendingPathComponent("agent-tool-4.jsonl")
        var log = UbuntuSandboxVM.ToolLog()
        let line = "{\"pad\":\"" + String(repeating: "p", count: 4000) + "\"}\n"
        var n = 0
        while (try? FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int) ?? 0
                <= UbuntuSandboxVM.ToolLog.rotateAt { try append(f, line); n += 1 }
        var got = 0
        while got < n { let l = log.read(f); if l.isEmpty { break }; got += l.count }
        #expect(got == n)
        // Rotated: the live name is free for the hook, the old file retired.
        #expect(!FileManager.default.fileExists(atPath: f.path))
        let retired = try #require(log.retired?.url)
        // A hook that had the old file open finishes its append there.
        try append(retired, "{\"late\":1}\n")
        try append(f, "{\"new\":1}\n")                     // and the next one creates a new file
        let next = log.read(f).map { String(decoding: $0, as: UTF8.self) }
        #expect(next == ["{\"late\":1}", "{\"new\":1}"])
        #expect(!FileManager.default.fileExists(atPath: retired.path))
    }

    @Test("a status text file over the cap isn't read")
    func boundedText() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let small = d.appendingPathComponent("ports.txt"), big = d.appendingPathComponent("docker.txt")
        try "22 tcp\n".write(to: small, atomically: true, encoding: .utf8)
        try Data(repeating: 0x41, count: UbuntuSandboxVM.maxOutboxTextFile + 1).write(to: big)
        #expect(UbuntuSandboxVM.boundedText(small) == "22 tcp\n")
        #expect(UbuntuSandboxVM.boundedText(big) == nil)
    }
}
