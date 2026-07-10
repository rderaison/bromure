import Foundation
import Testing
@testable import bromure_ac

/// The ext4 home-image model: profile stamping + back-compat decoding,
/// the home-seed staging (manifest + payloads the guest agent applies),
/// and SessionDisk's sparse-image / attach-mode plumbing.
@Suite("Home storage (ext4 image model)")
struct HomeStorageTests {

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("home-storage-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // Same date strategy ProfileStore uses on disk (its iso8601 helpers
    // are private to Profile.swift).
    private var encoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }
    private var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    // MARK: Profile model

    @Test("New profiles default to the ext4 home model")
    func newProfileIsExt4() {
        let p = Profile(name: "ws", tool: .claude, authMode: .token)
        #expect(p.homeModel == .ext4)
    }

    @Test("Pre-upgrade JSON (no homeModel key) decodes as virtiofs")
    func oldJSONDecodesVirtiofs() throws {
        var p = Profile(name: "legacy", tool: .claude, authMode: .token)
        p.homeModel = .ext4   // will be stripped from the JSON below
        var obj = try JSONSerialization.jsonObject(
            with: encoder.encode(p)) as! [String: Any]
        obj.removeValue(forKey: "homeModel")
        // Profiles that declined the offer while it was once-only carry
        // this retired key; it must decode fine (and be ignored — the
        // offer now re-arms every launch).
        obj["homeUpgradeDeclined"] = true
        let data = try JSONSerialization.data(withJSONObject: obj)
        let decoded = try decoder.decode(Profile.self, from: data)
        #expect(decoded.homeModel == .virtiofs)
    }

    @Test("homeModel round-trips through Codable")
    func roundTrip() throws {
        var p = Profile(name: "ws", tool: .codex, authMode: .subscription)
        p.homeModel = .ext4
        let decoded = try decoder.decode(Profile.self, from: encoder.encode(p))
        #expect(decoded.homeModel == .ext4)
    }

    // MARK: SessionDisk

    @Test("homeAttachMode follows the profile + migrate flag")
    func attachMode() throws {
        let root = try tempDir()
        let store = ProfileStore(rootDir: root)
        var p = Profile(name: "ws", tool: .claude, authMode: .token)

        p.homeModel = .virtiofs
        let legacy = SessionDisk(profile: p, store: store,
                                 baseDiskURL: root.appendingPathComponent("base.img"))
        #expect(legacy.homeAttachMode == .virtiofs)
        legacy.migrateHomeThisBoot = true
        #expect(legacy.homeAttachMode == .migrate)

        p.homeModel = .ext4
        let modern = SessionDisk(profile: p, store: store,
                                 baseDiskURL: root.appendingPathComponent("base.img"))
        #expect(modern.homeAttachMode == .ext4)
    }

    @Test("ensureHomeImageExists creates a sparse image (apparent GiB, ~0 allocated)")
    func sparseImage() throws {
        let root = try tempDir()
        let store = ProfileStore(rootDir: root)
        let p = Profile(name: "ws", tool: .claude, authMode: .token)
        let disk = SessionDisk(profile: p, store: store,
                               baseDiskURL: root.appendingPathComponent("base.img"))
        try disk.ensureHomeImageExists()

        let attrs = try FileManager.default.attributesOfItem(atPath: disk.homeImageURL.path)
        let apparent = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        #expect(apparent == Int64(SessionDisk.resolvedHomeImageGB()) * 1024 * 1024 * 1024)

        let values = try disk.homeImageURL.resourceValues(
            forKeys: [.totalFileAllocatedSizeKey])
        let allocated = Int64(values.totalFileAllocatedSize ?? 0)
        #expect(allocated < 1024 * 1024, "sparse image should allocate ~nothing")

        // Idempotent: a second call must not touch (or truncate) the image.
        try disk.ensureHomeImageExists()
        let again = try FileManager.default.attributesOfItem(atPath: disk.homeImageURL.path)
        #expect((again[.size] as? NSNumber)?.int64Value == apparent)
    }

    @Test("resetHome deletes the home image alongside the legacy dir")
    func resetHomeRemovesImage() throws {
        let root = try tempDir()
        let store = ProfileStore(rootDir: root)
        let p = Profile(name: "ws", tool: .claude, authMode: .token)
        let disk = SessionDisk(profile: p, store: store,
                               baseDiskURL: root.appendingPathComponent("base.img"))
        try disk.ensureHomeImageExists()
        #expect(FileManager.default.fileExists(atPath: disk.homeImageURL.path))
        try store.resetHome(for: p)
        #expect(!FileManager.default.fileExists(atPath: disk.homeImageURL.path))
    }

    @Test("Duplicating a workspace clones the ext4 home image (CoW, still sparse)")
    func duplicateClonesHomeImage() throws {
        let root = try tempDir()
        let store = ProfileStore(rootDir: root)
        let p = Profile(name: "ws", tool: .claude, authMode: .token)
        let disk = SessionDisk(profile: p, store: store,
                               baseDiskURL: root.appendingPathComponent("base.img"))
        try disk.ensureHomeImageExists()
        // A pre-migration backup must NOT travel to the duplicate.
        try FileManager.default.createDirectory(
            at: store.homeBackupDirectory(for: p), withIntermediateDirectories: true)

        let copy = try store.duplicate(p, named: "ws copy")
        let dstImg = store.homeImageURL(for: copy)
        #expect(FileManager.default.fileExists(atPath: dstImg.path))

        // Same apparent size as the source…
        let srcAttrs = try FileManager.default.attributesOfItem(
            atPath: store.homeImageURL(for: p).path)
        let dstAttrs = try FileManager.default.attributesOfItem(atPath: dstImg.path)
        #expect((dstAttrs[.size] as? NSNumber)?.int64Value
                == (srcAttrs[.size] as? NSNumber)?.int64Value)
        // …and still sparse: the clone shares extents, it doesn't inflate.
        let allocated = Int64((try dstImg.resourceValues(
            forKeys: [.totalFileAllocatedSizeKey])).totalFileAllocatedSize ?? 0)
        #expect(allocated < 1024 * 1024)

        #expect(!FileManager.default.fileExists(
            atPath: store.homeBackupDirectory(for: copy).path))
    }

    @Test("Bootstrap home carries the managed .bash_profile")
    func bootstrapHome() throws {
        let root = try tempDir()
        let store = ProfileStore(rootDir: root)
        let p = Profile(name: "ws", tool: .claude, authMode: .token)
        try store.prepareBootstrapHomeDirectory(for: p)
        let content = try String(
            contentsOf: store.bootstrapHomeDirectory(for: p)
                .appendingPathComponent(".bash_profile"),
            encoding: .utf8)
        // The two load-bearing jobs: agentd bootstrap + hostname apply.
        #expect(content.contains("bromure-agentd"))
        #expect(content.contains("hostname.txt"))
    }

    // MARK: Home seed

    private func manifest(in seedDir: URL) throws -> [String] {
        try String(contentsOf: seedDir.appendingPathComponent("manifest.tsv"),
                   encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    @Test("Seed stages managed dotfiles + manifest for a plain profile")
    func seedBasics() throws {
        let root = try tempDir()
        let store = ProfileStore(rootDir: root)
        var p = Profile(name: "ws", tool: .claude, authMode: .token)
        p.sshPublicKey = "ssh-ed25519 AAAA bromure-ac"
        let seedDir = root.appendingPathComponent("seed")

        try store.writeHomeSeedFiles(for: p, into: seedDir,
                                     terminalDefaults: .fallback)
        try store.finalizeHomeSeed(for: p, seedDir: seedDir)

        let files = seedDir.appendingPathComponent("files")
        for rel in [".bashrc", ".bash_profile", ".profile", ".npmrc",
                    ".tmux.conf", ".bashrc.local", ".ssh/id_ed25519.pub"] {
            #expect(FileManager.default.fileExists(
                atPath: files.appendingPathComponent(rel).path), "missing \(rel)")
        }

        let lines = try manifest(in: seedDir)
        #expect(lines.contains("o\t644\t.bashrc"))
        #expect(lines.contains("m\t644\t.bashrc.local"))
        #expect(lines.contains("D\t700\t.ssh"))
        // Tombstones + always-on cleanup.
        #expect(lines.contains("d\t-\t.xinitrc"))
        #expect(lines.contains("d\t-\t.ssh/id_ed25519"))
        #expect(lines.contains(where: { $0.hasPrefix("p\t-\t.aws/credentials\t") }))
        // No git creds configured → the cleanup entry (not the file).
        #expect(lines.contains("d\t-\t.git-credentials"))
        #expect(!FileManager.default.fileExists(
            atPath: files.appendingPathComponent(".git-credentials").path))

        // Claude-settings merge spec: claude workspace → usesClaude, no bedrock.
        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf:
            seedDir.appendingPathComponent("claude-settings.spec.json"))) as! [String: Any]
        #expect(spec["usesClaude"] as? Bool == true)
        #expect(spec["bedrockEnv"] == nil)
    }

    @Test("Seed with git credentials stages .git-credentials 600 and skips its cleanup")
    func seedWithGitCreds() throws {
        let root = try tempDir()
        let store = ProfileStore(rootDir: root)
        var p = Profile(name: "ws", tool: .claude, authMode: .token)
        p.gitHTTPSCredentials = [
            GitHTTPSCredential(host: "github.com", username: "u", token: "tok")
        ]
        let seedDir = root.appendingPathComponent("seed")
        try store.writeHomeSeedFiles(for: p, into: seedDir,
                                     terminalDefaults: .fallback)
        try store.finalizeHomeSeed(for: p, seedDir: seedDir)

        let lines = try manifest(in: seedDir)
        #expect(lines.contains("o\t600\t.git-credentials"))
        #expect(!lines.contains("d\t-\t.git-credentials"))
        #expect(lines.contains("o\t600\t.config/gh/hosts.yml"))
        #expect(lines.contains("o\t644\t.gitconfig"))
    }

    @Test("Seed regeneration clears stale payloads in place")
    func seedRegenerationDropsStale() throws {
        let root = try tempDir()
        let store = ProfileStore(rootDir: root)
        var p = Profile(name: "ws", tool: .claude, authMode: .token)
        p.gitHTTPSCredentials = [
            GitHTTPSCredential(host: "github.com", username: "u", token: "tok")
        ]
        let seedDir = root.appendingPathComponent("seed")
        try store.writeHomeSeedFiles(for: p, into: seedDir, terminalDefaults: .fallback)
        try store.finalizeHomeSeed(for: p, seedDir: seedDir)

        // The user removes the credential; the next seed must drop the
        // payload and emit the cleanup entry instead.
        p.gitHTTPSCredentials = []
        try store.writeHomeSeedFiles(for: p, into: seedDir, terminalDefaults: .fallback)
        try store.finalizeHomeSeed(for: p, seedDir: seedDir)

        let files = seedDir.appendingPathComponent("files")
        #expect(!FileManager.default.fileExists(
            atPath: files.appendingPathComponent(".git-credentials").path))
        let lines = try manifest(in: seedDir)
        #expect(lines.contains("d\t-\t.git-credentials"))
        #expect(lines.contains(where: { $0.hasPrefix("p\t-\t.gitconfig\t") }))
    }

    @Test("Bedrock profile ships its env in the claude-settings spec")
    func seedBedrockSpec() throws {
        let root = try tempDir()
        let store = ProfileStore(rootDir: root)
        var p = Profile(name: "ws", tool: .claude, authMode: .bedrock)
        p.bedrockEnabled = true
        p.bedrockModelID = "anthropic.claude-3"
        p.awsCredentials.region = "eu-west-3"
        let seedDir = root.appendingPathComponent("seed")
        try store.writeHomeSeedFiles(for: p, into: seedDir, terminalDefaults: .fallback)
        try store.finalizeHomeSeed(for: p, seedDir: seedDir)

        let spec = try JSONSerialization.jsonObject(with: Data(contentsOf:
            seedDir.appendingPathComponent("claude-settings.spec.json"))) as! [String: Any]
        let env = spec["bedrockEnv"] as? [String: String]
        #expect(env?["CLAUDE_CODE_USE_BEDROCK"] == "1")
        #expect(env?["AWS_REGION"] == "eu-west-3")
        #expect(env?["ANTHROPIC_MODEL"] == "anthropic.claude-3")
    }
}
