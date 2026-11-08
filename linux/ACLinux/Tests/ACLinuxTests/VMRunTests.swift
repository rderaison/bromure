import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// `vm run` (POST /vms, macOS: automationCreateVM): a workspace named or
    /// minted, `-v` mounts as its shared folders (8 at most), `--rm` ones
    /// deleted once stopped or never booted; and the shared folders as the
    /// VM's share-<N> slots with their shares.txt.
    @Suite("vm run: workspaces, mounts, --rm", .serialized)
    struct VMRunTests {
        static func withStore(_ body: (Daemon, String) async throws -> Void) async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let prior = ProfileStore.defaultRootDir
            ProfileStore.defaultRootDir = URL(fileURLWithPath: dir + "/state/profiles", isDirectory: true)
            defer { ProfileStore.defaultRootDir = prior }
            // Nothing here ever boots.
            Daemon.launchHookForTesting.withLockedValue { $0 = { _ in throw CancellationError() } }
            defer { Daemon.launchHookForTesting.withLockedValue { $0 = nil } }
            try await body(d, dir)
            await d.shutdown()
        }

        static func folders(_ dir: String, _ names: [String]) throws -> [String] {
            try names.map { n in
                let p = dir + "/host/" + n
                try FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
                return p
            }
        }

        static func saved(_ r: Result<(Profile, VMRecord?, Bool), Daemon.VMRunRefusal>) -> (Profile, VMRecord?)? {
            if case .success(let w) = r { return (w.0, w.1) }
            return nil
        }

        @Test func aWorkspaceIsNamedOrMintedWithItsMounts() async throws {
            try await Self.withStore { d, dir in
                // A workspace id no workspace has: deleted, 404.
                let gone = UUID().uuidString
                let r404 = await d.createVMRoute(.object(["profile": .string(gone)]))
                #expect(r404.status == 404 && r404.body["notFound"] == .bool(true), "\(r404.body)")
                #expect(ProfileStore().loadAll().isEmpty, "nothing minted under a deleted one's id")

                let host = try Self.folders(dir, ["project", "lib"])
                let minted = await d.vmRunWorkspace(.object([
                    "name": "minted", "tool": "codex", "auth": "token", "apiKey": "test-api-key-value",
                    "memoryGB": 4, "mounts": .array([.string(host[0]), .string(dir + "/host/missing"), .string(host[0])]),
                ]))
                let (p, rec) = try #require(Self.saved(minted))
                #expect(rec == nil, "a new workspace: no VM yet")
                #expect(p.name == "minted" && p.tool == .codex && p.authMode == .token && p.memoryGB == 4)
                #expect(p.apiKey == "test-api-key-value")
                #expect(p.folderPaths == [host[0]], "a missing mount is skipped, a repeated one taken once")
                #expect(ProfileStore().loadAll().contains { $0.id == p.id }, "saved")

                // An on-the-fly name already a VM's: refused.
                guard case .failure(let clash) = await d.vmRunWorkspace(.object(["name": "k8s-r-1"])) else {
                    Issue.record("a clashing name was taken"); return
                }
                #expect(clash.response.status == 409)

                // The existing workspace by name: its VM, its mounts added, 8 at most.
                var vm = RepairMarksTests.stopped(p.id.uuidString.lowercased())
                vm.name = "minted"
                try await d.registerForTesting(vm)
                let more = try Self.folders(dir, (1...9).map { "f\($0)" })
                let again = await d.vmRunWorkspace(.object(["profile": "minted", "mounts": .array(more.map(JSONValue.string))]))
                let (q, qrec) = try #require(Self.saved(again))
                #expect(q.id == p.id && qrec?.id == vm.id)
                #expect(q.folderPaths == [host[0]] + more.prefix(7), "capped at the image's 8 slots")
                // Its boot failed: an existing workspace stays.
                let failed = await d.createVMRoute(.object(["profile": "minted"]))
                #expect(failed.status >= 300)
                #expect(ProfileStore().loadAll().contains { $0.id == p.id })

                // A new workspace whose VM didn't come about goes with it.
                let lost = await d.createVMRoute(.object(["name": "lost"]))
                #expect(lost.status >= 300)
                #expect(!ProfileStore().loadAll().contains { $0.name == "lost" })
            }
        }

        @Test func anRmWorkspaceGoesOnceStoppedOrNeverBooted() async throws {
            try await Self.withStore { d, _ in
                let store = ProfileStore()
                // Marked this daemon's; another live process's isn't taken.
                let (p, _) = try #require(Self.saved(await d.vmRunWorkspace(.object(["name": "eph", "rm": true]))))
                #expect(store.isEphemeral(p) && store.ephemeralOwner(p) == getpid())
                let theirs = try store.save(Profile(name: "theirs", tool: .claude, authMode: .token))
                store.markEphemeral(theirs, owner: getppid())
                guard case .failure(let busy) = await d.vmRunWorkspace(.object(["profile": .string(theirs.name), "rm": true])) else {
                    Issue.record("another live process's --rm workspace was taken"); return
                }
                #expect(busy.response.status == 500)
                #expect(store.ephemeralOwner(theirs) == getppid(), "never re-marked")
                #expect(store.loadAll().filter { $0.name == "theirs" }.count == 1, "the workspace, not a new one by its name")

                // A stopped one goes; an unmarked one stays.
                let key = p.id.uuidString.lowercased()
                var vm = RepairMarksTests.stopped(key)
                vm.name = "eph"
                try await d.registerForTesting(vm)
                let kept = try store.save(Profile(name: "kept", tool: .claude, authMode: .token))
                var keptVM = RepairMarksTests.stopped(kept.id.uuidString.lowercased())
                keptVM.name = "kept"
                try await d.registerForTesting(keptVM)
                await d.dropAbandonedEphemeral(p.id)
                await d.dropAbandonedEphemeral(kept.id)
                let gone = await d.registry.find(key) == nil
                #expect(!store.loadAll().contains { $0.id == p.id } && gone, "deleted, VM and all")
                #expect(store.loadAll().contains { $0.id == kept.id })

                // One that never booted is over too.
                let never = await d.createVMRoute(.object(["name": "never", "rm": true]))
                #expect(never.status >= 300)
                #expect(!store.loadAll().contains { $0.name == "never" })
            }
        }

        /// A sign-in VM or a rescue machine isn't a workspace to run: refused
        /// as unknown, nothing saved or marked for it; a --rm mark on its
        /// id never deletes it.
        @Test func signInAndRescueVMsAreNotWorkspaces() async throws {
            try await Self.withStore { d, _ in
                let store = ProfileStore()
                var signIn = RepairMarksTests.stopped()
                signIn.name = "register-claude-1234abcd"
                signIn.registration = true
                try await d.registerForTesting(signIn)
                var rescue = RepairMarksTests.stopped()
                rescue.name = "rescue-1"
                rescue.rescueFor = UUID().uuidString.lowercased()
                try await d.registerForTesting(rescue)
                for name in [signIn.name, rescue.name, signIn.id] {
                    guard case .failure(let r) = await d.vmRunWorkspace(.object(["profile": .string(name), "rm": true])) else {
                        Issue.record("\(name) was run as a workspace"); continue
                    }
                    #expect(r.response.status == 404 && r.response.body["notFound"] == .bool(true))
                }
                #expect(store.loadAll().isEmpty, "nothing saved for them")
                // A mark under a sign-in VM's id doesn't make its stop delete it.
                var p = Profile(name: "under-sign-in", tool: .claude, authMode: .token)
                p.id = try #require(UUID(uuidString: signIn.id))
                p = try store.save(p)
                store.markEphemeral(p)
                await d.dropAbandonedEphemeral(p.id)
                #expect(await d.registry.find(signIn.id) != nil && store.loadAll().contains { $0.id == p.id })
            }
        }

        /// A --rm workspace shut down while suspended goes then (macOS: its
        /// session's end deletes it, a suspend's included).
        @Test func aSuspendedRmWorkspaceShutDownGoes() async throws {
            try await Self.withStore { d, _ in
                let store = ProfileStore()
                let (p, _) = try #require(Self.saved(await d.vmRunWorkspace(.object(["name": "eph-s", "rm": true]))))
                var vm = RepairMarksTests.stopped(p.id.uuidString.lowercased())
                vm.name = "eph-s"
                vm.state = .suspended
                try await d.registerForTesting(vm)
                let r = await d.deleteVM(vm, action: "shutdown")
                #expect(r.status == 200)
                let gone = await d.registry.find(vm.id) == nil
                #expect(gone && !store.loadAll().contains { $0.id == p.id }, "deleted, VM and all")
            }
        }

        @Test func atStartTheStoppedOnesOfAGoneDaemonGo() async throws {
            try await Self.withStore { d, _ in
                let store = ProfileStore()
                func workspace(_ name: String, owner: pid_t) async throws -> Profile {
                    let p = try store.save(Profile(name: name, tool: .claude, authMode: .token))
                    store.markEphemeral(p, owner: owner)
                    var vm = RepairMarksTests.stopped(p.id.uuidString.lowercased())
                    vm.name = name
                    try await d.registerForTesting(vm)
                    return p
                }
                let orphan = try await workspace("orphan", owner: 0)
                let mine = try await workspace("mine", owner: getpid())
                let other = try await workspace("other", owner: getppid())
                await d.sweepStoppedEphemeral()
                let left = Set(store.loadAll().map(\.id))
                #expect(!left.contains(orphan.id), "its owner is gone")
                #expect(left.contains(mine.id) && left.contains(other.id), "a live process's stays")
            }
        }

        @Test func sharedFoldersAreTheVMsShares() async throws {
            try await Self.withStore { d, dir in
                let host = try Self.folders(dir, ["app", "a/src", "b/src"])
                var p = Profile(name: "shares", tool: .claude, authMode: .token)
                p.folderPaths = host
                p = try ProfileStore().save(p)
                var vm = RepairMarksTests.stopped(p.id.uuidString.lowercased())
                vm.name = "shares"
                try await d.registerForTesting(vm)
                #expect(await d.shareFolders(vm) == host)
                let meta = dir + "/meta-shares"
                try FileManager.default.createDirectory(atPath: meta, withIntermediateDirectories: true)
                try await d.writeSharesFile(vm, meta: meta)
                #expect(try String(contentsOfFile: meta + "/shares.txt", encoding: .utf8) == "1 app\n2 src\n3 src-2\n")
                try FileManager.default.createDirectory(atPath: dir + "/image", withIntermediateDirectories: true)
                try "console=ttyS0\n".write(toFile: dir + "/image/cmdline", atomically: true, encoding: .utf8)
                #expect(try await d.machineConfig(vm).shares.map(\.tag) == ["bromure-meta", "bromure-outbox", "share-1", "share-2", "share-3"])

                // A managed machine's folders are its own, and no shares.txt.
                var managed = RepairMarksTests.stopped()
                managed.folders = [host[0]]
                #expect(await d.shareFolders(managed) == [host[0]])
                let meta2 = dir + "/meta-managed"
                try FileManager.default.createDirectory(atPath: meta2, withIntermediateDirectories: true)
                try await d.writeSharesFile(managed, meta: meta2)
                #expect(!FileManager.default.fileExists(atPath: meta2 + "/shares.txt"))
            }
        }
    }
}
