import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// /state's workspace rows carry what macOS's do: a fat client of a Linux
    /// server shows each workspace's color, agent, notes, storage, shield and
    /// credentials, and offers only the agents it can run.
    @Suite("Workspace rows as macOS's", .serialized)
    struct WorkspaceRowTests {
        @Test func aRowCarriesTheWorkspacesFields() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let store = ProfileStore()
            var p = Profile(name: "rows-\(UUID().uuidString.prefix(6))", tool: .claude, authMode: .token)
            p.comments = "my notes"
            p.color = .green
            p.customFontSize = 13
            p.additionalTools = [Profile.ToolSpec(tool: .codex, authMode: .subscription)]
            p = try store.save(p)
            defer { try? FileManager.default.removeItem(at: store.profileDirectory(for: p)) }
            var rec = RepairMarksTests.stopped(p.id.uuidString.lowercased())
            rec.name = p.name
            try await d.registerForTesting(rec)
            let rows = await d.workspaceRows([rec])
            guard case .object(let o)? = rows.first else { Issue.record("no row"); return }
            #expect(o["tool"]?.stringValue == "claude" && o["authMode"]?.stringValue == "token")
            #expect(o["color"]?.stringValue == "green" && o["accentHex"]?.stringValue?.isEmpty == false)
            #expect(o["comments"]?.stringValue == "my notes")
            #expect(o["fontSize"]?.numberValue == 13)
            #expect(o["hasGitHubToken"] == .bool(false) && o["hasLinearToken"] == .bool(false))
            guard case .array(let extra)? = o["additionalTools"], case .array(_)? = o["readyTools"] else {
                Issue.record("tools"); return
            }
            #expect(extra.count == 1 && extra.first?["tool"]?.stringValue == "codex")
            #expect(o["homeImageBytes"] == .null, "no home image yet")
            #expect(o["sandboxed"] != nil && o["diskCapacityBytes"] != nil)
            await d.shutdown()
        }
    }
}

extension DaemonGlobalSuites {
    /// The new-session folder browser on a stopped workspace: its shared
    /// folders are read from this server (macOS: from the Mac), and the home
    /// lists them; GET /squelch answers as macOS's.
    @Suite("Stopped workspace folders, Squelch stats", .serialized)
    struct StoppedFoldersTests {
        @Test func aStoppedWorkspacesSharedFoldersAreBrowsable() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let share = dir + "/proj"
            for sub in ["src", "docs", ".git"] {
                try FileManager.default.createDirectory(atPath: share + "/" + sub, withIntermediateDirectories: true)
            }
            try Data().write(to: URL(fileURLWithPath: share + "/README"))
            let store = ProfileStore()
            var p = Profile(name: "folders-\(UUID().uuidString.prefix(6))", tool: .claude, authMode: .token)
            p.folderPaths = [share]
            p = try store.save(p)
            defer { try? FileManager.default.removeItem(at: store.profileDirectory(for: p)) }
            let mount = try #require(SessionDisk.sharedFolders(p.folderPaths).first?.mountName)
            #expect(await d.listGuestFolders(p, path: "~/" + mount) == ["docs", "src"], "no dotfolders, no files")
            #expect(await d.listGuestFolders(p, path: "/mnt/bromure-share-1/src") == [])
            #expect(await d.listGuestFolders(p, path: "~") == [mount], "the home lists its shares (no home image yet)")
            #expect(Daemon.hostShareDirectory(guestPath: "/home/ubuntu/elsewhere", shares: SessionDisk.sharedFolders(p.folderPaths)) == nil)

            let r = try #require(await d.workspaceRoute("GET", "/squelch", .null))
            #expect(r.status == 200)
            #expect(r.body["workspaces"]?[p.id.uuidString]?["name"]?.stringValue == p.name)
            #expect(r.body["workspaces"]?[p.id.uuidString]?["enabled"] != nil)
            await d.shutdown()
        }
    }
}
