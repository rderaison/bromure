import Foundation
import Testing
@testable import bromure_ac

@Suite("States: clone, metadata, guards")
struct StateStoreTests {
    func tempDir() -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("brm-state-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test("cloneTree copies a tree file by file, honours exclusions, skips sockets, keeps symlinks")
    func cloneTree() throws {
        let fm = FileManager.default
        let src = tempDir(), dst = tempDir().appendingPathComponent("copy", isDirectory: true)
        defer { try? fm.removeItem(at: src); try? fm.removeItem(at: dst.deletingLastPathComponent()) }

        try fm.createDirectory(at: src.appendingPathComponent("profiles/A"), withIntermediateDirectories: true)
        try Data("disk".utf8).write(to: src.appendingPathComponent("profiles/A/disk.img"))
        try Data("ram".utf8).write(to: src.appendingPathComponent("profiles/A/vm.state"))
        try Data("base".utf8).write(to: src.appendingPathComponent("base.img"))
        try Data("lock".utf8).write(to: src.appendingPathComponent(ACInstance.lockFileName))
        try fm.createSymbolicLink(atPath: src.appendingPathComponent("link").path, withDestinationPath: "base.img")
        // A socket, as the running app leaves behind.
        let sockPath = src.appendingPathComponent("control.sock").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { p in
            p.withMemoryRebound(to: CChar.self, capacity: 104) { strlcpy($0, sockPath, 104) }
        }
        _ = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        close(fd)

        try StateStore.cloneTree(from: src, to: dst, relative: "") { rel in
            StateStore.neverCloned.contains(rel) || rel.hasSuffix("/vm.state")
        }

        #expect(try String(contentsOf: dst.appendingPathComponent("base.img"), encoding: .utf8) == "base")
        #expect(try String(contentsOf: dst.appendingPathComponent("profiles/A/disk.img"), encoding: .utf8) == "disk")
        #expect(!fm.fileExists(atPath: dst.appendingPathComponent("profiles/A/vm.state").path))
        #expect(!fm.fileExists(atPath: dst.appendingPathComponent(ACInstance.lockFileName).path))
        #expect(!fm.fileExists(atPath: dst.appendingPathComponent("control.sock").path))
        #expect(try fm.destinationOfSymbolicLink(atPath: dst.appendingPathComponent("link").path) == "base.img")

        // The copy is independent: writing to it leaves the source alone.
        try Data("changed".utf8).write(to: dst.appendingPathComponent("base.img"))
        #expect(try String(contentsOf: src.appendingPathComponent("base.img"), encoding: .utf8) == "base")
    }

    @Test("Metadata round-trips")
    func metadata() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = StateStore.Metadata(name: "repro-7", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                                    createdBy: "devbuild-02 5.4.1", clonedFrom: "work", assetsFrom: nil, live: true)
        try StateStore.writeMetadata(m, to: dir)
        #expect(StateStore.readMetadata(dir) == m)
    }

    @Test("Sizes add up the regular files")
    func sizes() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(count: 10_000).write(to: dir.appendingPathComponent("a"))
        try Data(count: 5_000).write(to: dir.appendingPathComponent("b"))
        let s = StateStore.sizes(of: dir)
        #expect(s.apparent == 15_000)
        #expect(s.allocated >= 15_000)
    }

    @Test("The asset list names what a fresh state would otherwise download or bake")
    func assets() {
        for n in ["base.img", "stock.img", "efivars.bin", "browser", "Models", "provisioner-vmlinuz"] {
            #expect(StateStore.assetNames.contains(n), "\(n)")
        }
        for n in ["profiles", "traces", "transcripts", "models.enc", "sessions.json", "control.sock"] {
            #expect(!StateStore.assetNames.contains(n), "\(n)")
        }
        #expect(StateStore.isAssetCacheDir("ubuntu-26.04"))
        #expect(!StateStore.isAssetCacheDir("profiles"))
    }

    @Test("Settings copy from one domain to another and leave the source alone")
    func settingsCopy() {
        let a = "io.bromure.test.state.\(UUID().uuidString.prefix(8))"
        let b = "io.bromure.test.state.\(UUID().uuidString.prefix(8))"
        defer {
            UserDefaults.standard.removePersistentDomain(forName: a)
            UserDefaults.standard.removePersistentDomain(forName: b)
        }
        UserDefaults.standard.setPersistentDomain(["automation.port": 9999, "x": "y"], forName: a)
        StateStore.copySettings(from: a, to: b)
        let copied = UserDefaults.standard.persistentDomain(forName: b)
        #expect(copied?["automation.port"] as? Int == 9999)
        #expect(copied?["x"] as? String == "y")
        #expect(UserDefaults.standard.persistentDomain(forName: a)?["x"] as? String == "y")
    }

    @Test("Names: 'work' and the default folder can't be created; hidden names are refused")
    func names() {
        for bad in ["work", ACSupportDir.name, ".snapshots", "a/b", ""] {
            #expect(throws: StateStore.Failure.self, "\(bad)") { try StateStore.create(named: bad) }
        }
    }

    /// Keychain sharing rule (plan §4): a clone's workspaces share their
    /// LUKS keys with the original's, so removing a workspace in one state
    /// must never delete a key. Today nothing in the app calls
    /// `ProfileDisk.deleteDisk` (the only key-deleting path); this keeps it
    /// that way, or forces whoever adds one to gate it on the default state.
    @Test("No workspace removal path deletes a keychain key")
    func noKeyDeletion() throws {
        let dir = ACDefaultsTests.sourcesDir
        var offenders: [String] = []
        for f in ACDefaultsTests.swiftFiles() {
            let text = try String(contentsOf: f, encoding: .utf8)
            if text.contains("ProfileDisk.deleteDisk(") { offenders.append(f.lastPathComponent) }
        }
        #expect(offenders.isEmpty, "ProfileDisk.deleteDisk deletes the workspace's LUKS key, shared with every clone of the state (\(dir.path)): \(offenders)")
    }
}
