import Foundation
import Testing
@testable import bromure_ac

@Suite("The main thread never waits on the disk for the state it shows")
@MainActor
struct FileFactsTests {
    final class Clock: @unchecked Sendable { var now: TimeInterval = 100 }
    final class Reads: @unchecked Sendable {
        let lock = NSLock(); var paths: [String] = []
        func add(_ p: String) { lock.lock(); paths.append(p); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return paths.count }
    }
    /// Lets the main queue deliver what the background read found.
    private func settle(_ f: FileFacts) async { f.drain(); for _ in 0..<20 { await Task.yield() }; try? await Task.sleep(nanoseconds: 20_000_000) }

    @Test("nothing known at first, without waiting; then what was read")
    func firstReadIsInTheBackground() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("facts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("home.img")
        try Data(repeating: 1, count: 12_345).write(to: file)
        let f = FileFacts()
        #expect(f.facts(file) == nil)
        await settle(f)
        let got = try #require(f.facts(file))
        #expect(got.exists && got.size == 12_345 && got.allocated >= 12_345)
        #expect(f.facts(dir.appendingPathComponent("gone.img")) == nil)
        await settle(f)
        #expect(f.facts(dir.appendingPathComponent("gone.img")) == FileFacts.Facts(exists: false))
    }

    @Test("a stalled volume holds one read per file, however often it's asked; old facts are read again")
    func oneReadAtATime() async {
        let clock = Clock(), reads = Reads(), gate = DispatchSemaphore(value: 0)
        let f = FileFacts(clock: { clock.now }, reader: { p in reads.add(p); gate.wait(); return .init(exists: true, size: 7) })
        let url = URL(fileURLWithPath: "/stalled/home.img")
        for _ in 0..<50 { #expect(f.facts(url) == nil) }   // asked over and over while the read hangs
        gate.signal()
        await settle(f)
        #expect(reads.count == 1)
        #expect(f.facts(url)?.size == 7)
        clock.now += FileFacts.maxAge - 1
        _ = f.facts(url)
        #expect(reads.count == 1)                           // still fresh
        clock.now += 2
        gate.signal()
        #expect(f.facts(url)?.size == 7)                    // old: shown while it's read again
        await settle(f)
        #expect(reads.count == 2)
    }

    @Test("the state snapshot's workspace list and VM list read no file themselves")
    func snapshotPathsUseTheCache() throws {
        let top = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let ac = try String(contentsOf: top.appendingPathComponent("Sources/AgentCoding/BromureAC.swift"), encoding: .utf8)
        func body(_ sig: String) throws -> Substring {
            let r = try #require(ac.range(of: sig))
            let rest = ac[r.upperBound...]
            return rest[..<(rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex)]
        }
        for sig in ["@MainActor func automationWorkspaceList() -> [[String: Any]] {",
                    "@MainActor private func automationVMList() -> [[String: Any]] {",
                    "static func homeImageBytes(_ url: URL) -> Any {",
                    "func vmDashboardData(for id: Profile.ID) -> (diskAllocated: Int64, diskCapacity: Int64, startedAt: Date?) {"] {
            let b = try body(sig)
            for disk in ["resourceValues(", "attributesOfItem(", "fileExists(", "contentsOfDirectory(", "isCompromised("] {
                #expect(!b.contains(disk), Comment(rawValue: "\(sig.prefix(50)) calls \(disk)"))
            }
        }
        #expect(try body("@MainActor func automationWorkspaceList() -> [[String: Any]] {").contains("runState(for: p, cached: true)"))
    }
}
