import Foundation
import Testing
@testable import bromure_ac

/// The finding (CWE-400): a filesystem-restricted agent may write the outbox's
/// `urls/` relay folder, and the host listed it whole on every heavy tick,
/// opening 8 URLs and leaving the rest: a flood of url-*.txt made each poll's
/// work and memory grow with the backlog, and held a real sign-in URL back
/// for as long as it lasted. Listings are now bounded, and past a high-water
/// mark the excess is removed unopened, so the backlog drains.
@Suite("The outbox's URL relay can't be flooded", .serialized)
@MainActor
struct OutboxFloodTests {
    private func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("flood-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func count(_ dir: URL) -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: dir.path).count) ?? 0
    }

    @Test("a listing stops at its bound, skips . and .., and is nil for no folder")
    func boundedListing() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        for i in 0..<500 { FileManager.default.createFile(atPath: dir.appendingPathComponent("f\(i)").path, contents: nil) }
        let some = try #require(UbuntuSandboxVM.listing(dir, max: 100))
        #expect(some.count == 100)
        #expect(!some.contains(".") && !some.contains(".."))
        #expect(Set(some).count == 100)
        #expect(UbuntuSandboxVM.listing(dir, max: 10_000)?.count == 500)
        #expect(UbuntuSandboxVM.listing(dir.appendingPathComponent("none"), max: 10) == nil)
    }

    @Test("a flood in the relay drains with bounded work; a few URLs still all open, 8 a tick")
    func floodDrains() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let relay = dir.appendingPathComponent(SessionDisk.outboxURLRelayFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: relay, withIntermediateDirectories: true)
        let flood = 300
        for i in 0..<flood {
            try "https://example.com/\(i)".write(to: relay.appendingPathComponent("url-\(i).txt"),
                                                atomically: false, encoding: .utf8)
        }
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let vm = UbuntuSandboxVM(imageManager: UbuntuImageManager(storageDir: tmp, setupDir: tmp))
        var opened = 0
        vm.onURLOpen = { _ in opened += 1 }
        let scanner = UbuntuSandboxVM.OutboxScanner(outbox: dir)
        func heavyTick() async { for _ in 0..<12 { for apply in await scanner.tick() { apply(vm) } } }

        // One heavy tick: the relay's listing is bounded (256), over the
        // high-water mark, so 8 open and the rest of the listed are dropped.
        await heavyTick()
        #expect(opened == 8)
        #expect(count(relay) == flood - UbuntuSandboxVM.maxRelayEntriesPerTick)
        // What's left is under the mark: nothing more is dropped, 8 a tick.
        let left = count(relay)
        #expect(left <= UbuntuSandboxVM.urlBacklogHighWater)
        await heavyTick()
        #expect(opened == 16)
        #expect(count(relay) == left - 8)
        while count(relay) > 0 { await heavyTick() }
        #expect(opened == 8 + left)
    }

    /// The review: names that aren't url-*.txt counted toward the relay's
    /// window, and a listing restarted at the top each tick: 256 of them
    /// kept a real sign-in URL out of every tick. They're skipped while
    /// reading, and each tick resumes where the last stopped.
    @Test("junk in the relay, or a flood of the outbox, never hides a URL or a status for good")
    func junkCantHide() async throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let relay = dir.appendingPathComponent(SessionDisk.outboxURLRelayFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: relay, withIntermediateDirectories: true)
        for i in 0..<5000 {
            FileManager.default.createFile(atPath: relay.appendingPathComponent("junk-\(i)").path, contents: nil)
            FileManager.default.createFile(atPath: dir.appendingPathComponent("junk-\(i).dat").path, contents: nil)
        }
        try "https://example.com/login".write(to: relay.appendingPathComponent("url-1.txt"), atomically: false, encoding: .utf8)
        try "working".write(to: dir.appendingPathComponent("agent-status-2.txt"), atomically: false, encoding: .utf8)
        let tmp = try tempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
        let vm = UbuntuSandboxVM(imageManager: UbuntuImageManager(storageDir: tmp, setupDir: tmp))
        var urls: [URL] = [], statuses = 0
        vm.onURLOpen = { urls.append($0) }
        vm.onAgentStatus = { _, _ in statuses += 1 }
        let scanner = UbuntuSandboxVM.OutboxScanner(outbox: dir)
        // 5000 junk names: the relay's 4096 a tick and the outbox's 2048 a
        // tick reach every one within 3 heavy ticks.
        for _ in 0..<(12 * 4) { for apply in await scanner.tick() { apply(vm) } }
        #expect(urls == [URL(string: "https://example.com/login")!])
        #expect(statuses == 1)
        // The junk itself is left alone (never deleted through a folder the
        // guest controls).
        #expect(count(relay) == 5000)

        // A slice resumes where the last stopped, and starts over at the end.
        let cursor = UbuntuSandboxVM.DirCursor()
        var seen = Set<String>()
        for _ in 0..<3 { seen.formUnion(cursor.next(relay, examine: 2000, keep: 2000) ?? []) }
        #expect(seen.count == 5000)          // url-1.txt was taken above
        #expect(cursor.next(relay, examine: 10, keep: 10)?.count == 10)   // reopened at the top
    }

    @Test("the scan and the boot cleanup read the outbox through the bounded listing")
    func wired() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let src = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/UbuntuSandboxVM.swift"), encoding: .utf8)
        #expect(!src.contains("contentsOfDirectory"))
        #expect(src.contains("outboxCursor.next(outbox, examine: VM.maxOutboxEntriesPerTick,"))
        #expect(src.contains("relayCursor.next(relay, examine: VM.maxRelayNamesPerTick,"))
        #expect(src.contains("Self.listing(outbox, max: Self.maxOutboxEntriesPerTick)"))
    }
}
