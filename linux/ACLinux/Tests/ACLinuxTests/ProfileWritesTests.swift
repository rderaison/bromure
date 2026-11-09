import Foundation
import Testing
@testable import ACLinux

/// Every read-modify-write of a saved workspace is one write: none is lost
/// to another made meanwhile, from the daemon's actor or the main actor.
/// (Plain fields: the store puts secrets in the process-wide vault, which
/// another suite reconfigures.)
@Suite("Profile writes")
struct ProfileWritesTests {
    @Test func concurrentEditsAllLand() async throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let root = URL(fileURLWithPath: dir, isDirectory: true)
        let p = try ProfileStore(rootDir: root).save(Profile(name: "rmw", tool: .claude, authMode: .token))
        let id = p.id
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<24 {
                g.addTask { @Sendable in
                    let add = { (p: inout Profile) -> Bool in p.supplyChain.reputationAllowlist.append("npm:pkg-\(i)"); return true }
                    // Half from the main actor (a client's PUT, a refreshed
                    // token's save), half from elsewhere (the daemon's routes).
                    if i % 2 == 0 {
                        await MainActor.run { _ = try? ProfileWrites.edit(id, store: ProfileStore(rootDir: root), add) }
                    } else {
                        _ = try? ProfileWrites.edit(id, store: ProfileStore(rootDir: root), add)
                    }
                }
            }
        }
        let back = try #require(ProfileStore(rootDir: root).loadAll().first { $0.id == id })
        #expect(Set(back.supplyChain.reputationAllowlist) == Set((0..<24).map { "npm:pkg-\($0)" }), "every edit kept")
    }

    @Test func anEditStartsFromTheStoredCopy() throws {
        let dir = try shortTempDir(); defer { try? FileManager.default.removeItem(atPath: dir) }
        let store = ProfileStore(rootDir: URL(fileURLWithPath: dir, isDirectory: true))
        var stale = try store.save(Profile(name: "fresh", tool: .claude, authMode: .token))
        // Saved since the copy above was loaded.
        var now = stale
        now.egressRules = "allow example.com"
        _ = try store.update(now)
        let saved = try ProfileWrites.edit(stale.id, store: store) { $0.squelch.enabled.toggle(); return true }
        #expect(saved?.egressRules == "allow example.com", "the other write stays")
        stale.squelch.enabled.toggle()
        #expect(saved?.squelch.enabled == stale.squelch.enabled, "this one lands")
        #expect(try ProfileWrites.edit(UUID(), store: store) { _ in true } == nil, "an unknown workspace: nothing")
    }
}
