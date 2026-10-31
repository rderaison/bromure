import Foundation

/// The meta-share pieces that make an ext4 home usable: the home seed
/// (`meta/home-seed/`, applied by agentd's apply_home_seed), the generation
/// counters the guest polls, and the outbox. macOS: ProfileStore's seed
/// staging and SessionDisk's meta/outbox preparation.
///
/// The seed here is the PROFILE-INDEPENDENT part of macOS's: the managed
/// dotfiles (`HomeSeedContent`, generated from ProfileStore) and the .npmrc
/// prefix. Credentials, SSH, kube/aws/doctl configs and the agent tools'
/// files need a workspace profile, which Linux doesn't have yet.
// @port-skip linux-only: container of the SessionDisk/ProfileStore seed ports
enum HomeSeed {
    /// Relpaths applied create-if-missing (ProfileStore.seedIfMissing).
    static let seedIfMissing: Set<String> = [".bashrc.local"]
    /// Relpaths chmod 600 / 755, and directories created 0700 (ProfileStore).
    static let seed600: Set<String> = [
        ".git-credentials", ".kube/config", ".config/doctl/config.yaml",
        ".aws/config", ".docker/config.json", ".config/gh/hosts.yml",
        ".config/glab-cli/config.yml", ".codex/auth.json", ".grok/auth.json",
        ".kimi-code/credentials/kimi-code.json", ".claude/.credentials.json",
    ]
    static let seed755: Set<String> = [".bromure/agent-status.sh"]
    static let seedDir700: Set<String> = [
        ".kube", ".aws", ".claude", ".docker", ".ssh", ".codex", ".grok",
        ".kimi-code", ".kimi-code/credentials",
    ]
    static let managedSentinel = "# Managed by Bromure Agentic Coding."

    /// Stages the managed dotfiles into `<seedDir>/files`, clearing the
    /// previous seed in place (never `seedDir` itself: virtiofs inode rule).
    // partial: only the profile-independent files (no credentials, SSH key, kube/aws/doctl/gh/glab configs, agent auth or hooks, imported config); no terminal defaults
    // @port ProfileStore.writeHomeSeedFiles(for: Profile, into: URL, terminalDefaults: TerminalAppDefaults, tokenPlan: SessionTokenPlan?, kubeconfigYAML: String?) h=6281cbd04e0d3c52 @98afa768
    static func writeHomeSeedFiles(into seedDir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: seedDir, withIntermediateDirectories: true)
        for entry in (try? fm.contentsOfDirectory(at: seedDir, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: entry)
        }
        let files = seedDir.appendingPathComponent("files", isDirectory: true)
        try fm.createDirectory(at: files, withIntermediateDirectories: true)
        // populateManagedHome's profile-independent writes, seedMode: true.
        func put(_ text: String, _ rel: String) throws {
            try text.write(to: files.appendingPathComponent(rel), atomically: true, encoding: .utf8)
        }
        try put(HomeSeedContent.bashrcContent, ".bashrc")
        try put(HomeSeedContent.bashProfileContent, ".bash_profile")
        try put(HomeSeedContent.profileContent, ".profile")
        try put("prefix=/home/ubuntu/.npm-global\n"
                + HomeSeedContent.agentCLIPackages.map { "allow-scripts[]=\($0)\n" }.joined(), ".npmrc")
        try put(HomeSeedContent.bashrcLocalSeed, ".bashrc.local")
        try fm.createDirectory(at: files.appendingPathComponent(".npm-global", isDirectory: true),
                               withIntermediateDirectories: true)
        try put(HomeSeedContent.tmuxConf, ".tmux.conf")
    }

    /// Emits `manifest.tsv` (walking `files/`) and `claude-settings.spec.json`.
    // partial: no imported config files (all managed files are rewritten); the spec has usesClaude false and the CLI's theme (dark), no auto-mode environment or Bedrock env (no profile)
    // @port ProfileStore.finalizeHomeSeed(for: Profile, seedDir: URL, anthropicEnvKey: String?, bedrockBearerFake: String?) h=d0e1bf265ac0184a @98afa768
    static func finalizeHomeSeed(seedDir: URL) throws {
        let fm = FileManager.default
        let files = seedDir.appendingPathComponent("files", isDirectory: true)
        var dirLines: [String] = [], fileLines: [String] = []
        var present: Set<String> = []
        let rootPath = files.standardizedFileURL.path
        if let walker = fm.enumerator(at: files, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in walker {
                let full = url.standardizedFileURL.path
                guard full.hasPrefix(rootPath + "/") else { continue }
                let rel = String(full.dropFirst(rootPath.count + 1))
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false {
                    dirLines.append("D\t\(seedDir700.contains(rel) ? "700" : "755")\t\(rel)")
                } else {
                    present.insert(rel)
                    let mode = seedIfMissing.contains(rel) ? "m" : "o"
                    let perms = seed600.contains(rel) ? "600" : seed755.contains(rel) ? "755" : "644"
                    fileLines.append("\(mode)\t\(perms)\t\(rel)")
                }
            }
        }
        var cleanup = ["d\t-\t.xinitrc", "d\t-\t.bromure-tab-agent.sh", "d\t-\t.ssh/id_ed25519",
                       "p\t-\t.aws/credentials\t\(managedSentinel)"]
        if !present.contains(".git-credentials") { cleanup.append("d\t-\t.git-credentials") }
        if !present.contains(".gitconfig") { cleanup.append("p\t-\t.gitconfig\t\(managedSentinel)") }
        if !present.contains(".aws/config") { cleanup.append("p\t-\t.aws/config\t\(managedSentinel)") }
        if !present.contains(".docker/config.json") { cleanup.append("j\t-\t.docker/config.json\t_bromureManaged") }
        if !present.contains(".claude/.credentials.json") {
            cleanup.append("j\t-\t.claude/.credentials.json\t_bromureManaged")
        }
        let manifest = (dirLines.sorted() + fileLines.sorted() + cleanup).joined(separator: "\n") + "\n"
        try manifest.write(to: seedDir.appendingPathComponent("manifest.tsv"), atomically: true, encoding: .utf8)
        let spec: [String: Any] = ["usesClaude": false, "claudeTheme": "dark"]
        try JSONSerialization.data(withJSONObject: spec, options: [.prettyPrinted, .sortedKeys])
            .write(to: seedDir.appendingPathComponent("claude-settings.spec.json"), options: .atomic)
    }

    // @port SessionDisk.ensureEnvGeneration(in: URL) h=7931e227d88b0ea9 @25ad3a88
    static func ensureEnvGeneration(in dir: URL) {
        ensureGenerationCounter(named: "env.generation", in: dir)
    }

    /// Creates a counter at 1 if missing; never overwrites (a resume keeps
    /// the dir, and rewriting would signal a refresh that didn't happen).
    // @port SessionDisk.ensureGenerationCounter(named: String, in: URL) h=5dcfff4ac408190e @25ad3a88
    static func ensureGenerationCounter(named name: String, in dir: URL) {
        let url = dir.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? "1\n".write(to: url, atomically: true, encoding: .utf8)
    }

    // @port SessionDisk.bumpGenerationCounter(named: String, in: URL) h=1c3f6cdf67ca13c0 @25ad3a88
    static func bumpGenerationCounter(named name: String, in dir: URL) {
        let url = dir.appendingPathComponent(name)
        let current = (try? String(contentsOf: url, encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        try? "\(current + 1)\n".write(to: url, atomically: true, encoding: .utf8)
    }

    /// The outbox: world-writable (the guest's uids write to it through plain
    /// DAC), reused in place; emptied on a fresh boot, kept on a restore minus
    /// the one-shot event files. The mode is set with chmod after mkdir, so
    /// the umask can't narrow it.
    // partial: the path comes from the daemon's VM directory, not a profile directory
    // @port SessionDisk.prepareOutboxDirectory(forRestore: Bool) h=b3a6d4f2b0328c55 @25ad3a88
    static func prepareOutboxDirectory(_ dir: URL, forRestore: Bool) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard chmod(dir.path, 0o777) == 0 else { throw MachineError.io("chmod \(dir.path)", errno) }
        if forRestore { purgeStaleEvents(in: dir) } else { clearContents(of: dir) }
    }

    // @port SessionDisk.purgeStaleEvents(in: URL) h=b67a06cfe2cd3954 @25ad3a88
    static func purgeStaleEvents(in dir: URL) {
        for entry in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            let name = entry.lastPathComponent
            if name.hasPrefix("closed-") || name.hasPrefix("diag-") || name.hasPrefix("shortcut-") || name == "reboot-intent" {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    // @port SessionDisk.clearContents(of: URL) h=f7c68ec435c57e1d @25ad3a88
    static func clearContents(of dir: URL) {
        for entry in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: entry)
        }
    }
}
