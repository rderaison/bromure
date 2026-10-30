import Darwin
import Foundation

/// Named, immutable builds (BUILD_INSTRUCTIONS.md, "Builds and instances"): one folder per build
/// under `ACSupportDir.buildsRoot` (`<folder>-builds/<name>/`), holding the
/// app bundle and the `build.json` scripts/devbuild.sh wrote next to it.
/// Two symlinks there name roles: `stable` is the build the default state
/// runs on (what `~/.local/bin/bromure-ac` and the Finder alias resolve
/// to), `stable.prev` the one before it, for a rollback. The `build` CLI
/// group is a thin shell over this; nothing here needs the app running.
enum BuildStore {
    /// `build.json` (scripts/devbuild.sh). Extra keys are ignored.
    struct Info: Codable {
        var name: String
        var ref: String?
        var sha: String?
        var shortSha: String?
        var dirty: Bool?
        var builtAt: String?
        var version: String?
        var bundleId: String?
        /// The git worktree it was built in (`.worktrees/<name>` under the
        /// checkout, or one handed in with --from-worktree).
        var worktree: String?
    }

    struct Build {
        let name: String
        /// `<buildsRoot>/<name>/`.
        let url: URL
        /// The app bundle inside.
        let appURL: URL
        let info: Info?
        /// When the folder appeared (the build's time, for ordering).
        let createdAt: Date

        var binaryURL: URL { appURL.appendingPathComponent("Contents/MacOS/bromure-ac") }
        /// `--prod <tag>` builds: cached release builds, kept by `prune`
        /// except for the newest.
        var isProd: Bool { name.hasPrefix("prod-") }
    }

    enum Failure: Error, CustomStringConvertible {
        case missing(String)
        case badName(String)
        case noStable
        case noPrevious
        case io(String)

        var description: String {
            switch self {
            case .missing(let n): return "no build '\(n)' in \(BuildStore.root.path) (scripts/devbuild.sh makes them)"
            case .badName(let n): return "'\(n)' isn't a build name"
            case .noStable: return "no stable build yet (\(BuildStore.root.path)/stable): scripts/devbuild.sh makes the first one stable"
            case .noPrevious: return "nothing to roll back to (\(BuildStore.root.path)/stable.prev)"
            case .io(let s): return s
            }
        }
    }

    static let stableLink = "stable"
    static let prevLink = "stable.prev"
    static let defaultAppName = "Bromure Agentic Coding.app"

    static var root: URL { ACSupportDir.buildsRoot }

    // MARK: Listing

    /// Every build folder, newest first. The role symlinks are not builds.
    static func list() -> [Build] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var builds: [Build] = []
        for n in names where !n.hasPrefix(".") && n != stableLink && n != prevLink {
            let url = root.appendingPathComponent(n, isDirectory: true)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  (attrs[.type] as? FileAttributeType) == .typeDirectory,
                  let app = appURL(in: url) else { continue }
            builds.append(Build(name: n, url: url, appURL: app, info: readInfo(url),
                                createdAt: (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date) ?? .distantPast))
        }
        return builds.sorted { $0.createdAt > $1.createdAt }
    }

    /// The `.app` inside a build folder (or any folder).
    static func appURL(in dir: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let app = names.first(where: { $0.hasSuffix(".app") }) else { return nil }
        return dir.appendingPathComponent(app, isDirectory: true)
    }

    static func readInfo(_ dir: URL) -> Info? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("build.json")) else { return nil }
        return try? JSONDecoder().decode(Info.self, from: data)
    }

    /// Resolve what a command line calls a build: a name under the builds
    /// folder, `stable` or `stable.prev`, a path to an `.app`, or a path to
    /// a folder holding one (a checkout's `.build/…/release`).
    static func build(named raw: String) throws -> Build {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw Failure.badName(raw) }
        if s == stableLink { guard let b = stable else { throw Failure.noStable }; return b }
        if s == prevLink { guard let b = previous else { throw Failure.noPrevious }; return b }
        if s.contains("/") || s.hasPrefix("~") {
            let url = URL(fileURLWithPath: (s as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            let app: URL? = url.pathExtension == "app" ? url : appURL(in: url)
            guard let app, FileManager.default.isExecutableFile(atPath: app.appendingPathComponent("Contents/MacOS/bromure-ac").path) else {
                throw Failure.missing(raw)
            }
            let dir = app.deletingLastPathComponent()
            return Build(name: dir.lastPathComponent, url: dir, appURL: app, info: readInfo(dir), createdAt: Date())
        }
        guard let b = list().first(where: { $0.name == s }) else { throw Failure.missing(raw) }
        return b
    }

    // MARK: Roles

    /// What a role symlink points at, by build name. `stable.prev` was once
    /// a plain file holding the name (the local Makefile wrote it so); that
    /// is read too.
    static func roleTarget(_ link: String) -> String? {
        let url = root.appendingPathComponent(link)
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
            return URL(fileURLWithPath: dest).lastPathComponent
        }
        if let s = try? String(contentsOf: url, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return nil
    }

    static var stableName: String? { roleTarget(stableLink) }
    static var previousName: String? { roleTarget(prevLink) }
    static var stable: Build? { stableName.flatMap { n in list().first { $0.name == n } } }
    static var previous: Build? { previousName.flatMap { n in list().first { $0.name == n } } }

    /// `<buildsRoot>/stable/<app>/Contents/MacOS/bromure-ac`: the CLI path
    /// that follows a promote, for symlinks and launchd plists.
    static var stableBinaryLinkURL: URL {
        let app = stable?.appURL.lastPathComponent ?? defaultAppName
        return root.appendingPathComponent(stableLink).appendingPathComponent(app)
            .appendingPathComponent("Contents/MacOS/bromure-ac")
    }

    /// Point `stable` at a build, remembering the one it replaces in
    /// `stable.prev` (unless it is the same build).
    static func setStable(_ name: String) throws {
        let old = stableName
        if let old, old != name { try setRole(prevLink, to: old) }
        try setRole(stableLink, to: name)
    }

    /// Swap `stable` and `stable.prev`.
    static func rollback() throws -> (from: String, to: String) {
        guard let prev = previousName else { throw Failure.noPrevious }
        guard let cur = stableName else { throw Failure.noStable }
        try setRole(stableLink, to: prev)
        try setRole(prevLink, to: cur)
        return (cur, prev)
    }

    /// A relative symlink (`stable → devbuild-02`), replacing whatever was
    /// there (a symlink, or the Makefile-era file).
    static func setRole(_ link: String, to name: String) throws {
        let url = root.appendingPathComponent(link)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // attributesOfItem doesn't follow symlinks: a dangling link is seen too.
        if (try? fm.attributesOfItem(atPath: url.path)) != nil { try fm.removeItem(at: url) }
        do { try fm.createSymbolicLink(atPath: url.path, withDestinationPath: name) }
        catch { throw Failure.io("can't point \(url.path) at \(name): \(error.localizedDescription)") }
    }

    // MARK: Links that follow stable

    /// `~/.local/bin/bromure-ac`: a symlink through the `stable` symlink, so it
    /// follows a promote by itself.
    static var cliLinkURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/bromure-ac")
    }

    /// `~/Applications/<app display name>.app`: a Finder alias (Spotlight
    /// indexes aliases, not symlinks) to the stable build's bundle. An alias
    /// resolves `stable` when it is made, so a promote remakes it.
    static func aliasURL(for b: Build) -> URL {
        let bundle = Bundle(url: b.appURL)
        let display = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? b.appURL.deletingPathExtension().lastPathComponent
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("\(display).app")
    }

    /// Remake both links for the current stable build. Returns where they are.
    @discardableResult
    static func refreshLinks() throws -> (cli: URL, alias: URL) {
        guard let b = stable else { throw Failure.noStable }
        let fm = FileManager.default
        let cli = cliLinkURL
        try fm.createDirectory(at: cli.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? fm.attributesOfItem(atPath: cli.path)) != nil { try fm.removeItem(at: cli) }
        try fm.createSymbolicLink(atPath: cli.path, withDestinationPath: stableBinaryLinkURL.path)

        let alias = aliasURL(for: b)
        try fm.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? fm.attributesOfItem(atPath: alias.path)) != nil { try fm.removeItem(at: alias) }
        let target = b.appURL.resolvingSymlinksInPath()
        let bookmark = try target.bookmarkData(options: .suitableForBookmarkFile,
                                               includingResourceValuesForKeys: nil, relativeTo: nil)
        try URL.writeBookmarkData(bookmark, to: alias)
        return (cli, alias)
    }

    // MARK: Running instances

    /// Build name → the states with a live instance of it.
    static func runningStates() -> [String: [String]] {
        var out: [String: [String]] = [:]
        for e in StateStore.list() where e.instance.locked {
            guard let info = e.instance.info else { continue }
            out[info.build, default: []].append(e.name)
        }
        return out
    }

    // MARK: Prune

    /// What `prune` removes: every build but `stable`, `stable.prev`, those
    /// with a running instance, and the newest `prod-*` (older release builds
    /// go; they are rebuilt from their tag on demand). Pure, for the tests.
    static func pruneCandidates(_ builds: [Build], stable: String?, previous: String?,
                                running: Set<String>) -> [Build] {
        let newestProd = builds.filter(\.isProd).max { $0.createdAt < $1.createdAt }?.name
        return builds.filter { b in
            b.name != stable && b.name != previous && !running.contains(b.name) && b.name != newestProd
        }
    }

    /// Remove a build: its devbuild worktree first (only one under a
    /// `.worktrees/` folder, which is devbuild's own; a worktree handed in by
    /// hand is left alone), then the folder.
    static func remove(_ b: Build) throws {
        if let wt = b.info?.worktree {
            let url = URL(fileURLWithPath: wt, isDirectory: true)
            if url.deletingLastPathComponent().lastPathComponent == ".worktrees",
               FileManager.default.fileExists(atPath: url.path) {
                removeWorktree(url)
            }
        }
        try FileManager.default.removeItem(at: b.url)
    }

    /// `git worktree remove --force`, run from the checkout the worktree
    /// belongs to (so git forgets it too); a plain removal if git won't.
    private static func removeWorktree(_ wt: URL) {
        if let common = git(["-C", wt.path, "rev-parse", "--git-common-dir"]) {
            let gitDir = URL(fileURLWithPath: common, isDirectory: true, relativeTo: wt).standardizedFileURL
            let repo = gitDir.deletingLastPathComponent()
            if git(["-C", repo.path, "worktree", "remove", "--force", wt.path]) != nil { return }
        }
        try? FileManager.default.removeItem(at: wt)
    }

    /// Run git; its trimmed stdout, or nil on a non-zero exit.
    private static func git(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
