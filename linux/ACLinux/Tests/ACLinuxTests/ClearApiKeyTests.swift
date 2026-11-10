import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// `bromure-ac mcp`'s `set profile setting apiKey ""` clears the stored
    /// key, as macOS's AppleScript command does; a blank key in a document
    /// keeps it (an export's redacted secrets).
    @Suite("MCP: a blank API key clears it", .serialized)
    @MainActor
    struct ClearApiKeyTests {
        @Test func aBlankKeyClearsWhereADocumentsKeepsIt() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let host = LinuxSessionHost(daemon: d, stateDir: dir + "/state")
            var p = host.store.newProfileFromTemplate(name: "clear-key-\(UUID().uuidString.prefix(8))")
            p.apiKey = "test-placeholder-value"
            p = try host.store.save(p)
            defer { try? FileManager.default.removeItem(at: host.store.profileDirectory(for: p)) }
            host.profiles = host.store.loadAll()

            _ = host.automationUpsertProfile(idOrName: p.id.uuidString, doc: ["apiKey": ""])
            #expect(host.store.loadAll().first { $0.id == p.id }?.apiKey == "test-placeholder-value", "a document's blank key keeps it")

            #expect(Daemon.clearApiKey(host, p.id.uuidString)["ok"] as? Bool == true)
            #expect(host.store.loadAll().first { $0.id == p.id }?.apiKey == nil)
            #expect(Daemon.clearApiKey(host, "no-such-workspace")["ok"] as? Bool == false)
            let mixed = await d.updateProfile(p.id.uuidString, ["_clearApiKey": true, "name": "renamed"])
            #expect(mixed.status == 400, "not half-applied")
            #expect(host.store.loadAll().first { $0.id == p.id }?.name == p.name)
            await d.shutdown()
        }

        /// A suspended workspace's shared folders can't change (its resume
        /// would come back with the old set): the daemon's snapshot says so.
        @Test func aSuspendedWorkspacesFoldersCantChange() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let host = LinuxSessionHost(daemon: d, stateDir: dir + "/state")
            var p = host.store.newProfileFromTemplate(name: "folders-\(UUID().uuidString.prefix(8))")
            p = try host.store.save(p)
            defer { try? FileManager.default.removeItem(at: host.store.profileDirectory(for: p)) }
            #expect(!host.hasSuspendedState(p))
            try FileManager.default.createDirectory(atPath: dir + "/state/vms/" + p.id.uuidString.lowercased() + "/snapshot",
                                                    withIntermediateDirectories: true)
            #expect(host.hasSuspendedState(p))
            let r = host.automationUpsertProfile(idOrName: p.id.uuidString, doc: ["folderPaths": [dir]])
            #expect(r["ok"] as? Bool == false && (r["error"] as? String)?.contains("suspended VM") == true)
            await d.shutdown()
        }
    }
}
