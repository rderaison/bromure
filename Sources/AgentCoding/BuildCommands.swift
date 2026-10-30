import ArgumentParser
import Foundation

// MARK: - `bromure-ac build …`
//
// The immutable builds under <folder>-builds/ and the two roles among them:
// `stable`, the build the default state runs on (what ~/.local/bin/bromure-ac
// and the Finder alias resolve to), and `stable.prev`, the one before it.
// Builds are made by scripts/devbuild.sh, which needs the checkout; these
// verbs only manage what it produced.

struct BuildCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Manage the immutable builds: ls, promote, rollback, prune, link.",
        discussion: """
            `promote <build>` makes a build the stable one: the default state is snapshotted with the new \
            build's own CLI (label pre-<build>), its instance quits with every workspace suspended, `stable` \
            and `stable.prev` are repointed, `~/.local/bin/bromure-ac` and the Finder alias refreshed, and \
            the new build opened on work. `rollback` swaps stable and stable.prev the same way. `prune` \
            removes every other build (and its devbuild worktree) except those with a running instance \
            and the newest prod-* one.
            """,
        subcommands: [BuildList.self, BuildPromote.self, BuildRollback.self, BuildPrune.self, BuildLink.self],
        defaultSubcommand: BuildList.self)
}

struct BuildList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "Every build, newest first: version, commit, ref, age, role, the states running it.")

    @Flag(name: .long, help: "Machine-readable JSON.")
    var json = false

    func run() throws {
        let builds = BuildStore.list()
        let stable = BuildStore.stableName, prev = BuildStore.previousName
        let running = BuildStore.runningStates()
        if json {
            let rows: [[String: Any]] = builds.map { b in
                var r: [String: Any] = ["name": b.name, "path": b.url.path, "app": b.appURL.path,
                                        "createdAt": ISO8601DateFormatter().string(from: b.createdAt),
                                        "stable": b.name == stable, "previous": b.name == prev,
                                        "running": running[b.name] ?? []]
                if let i = b.info {
                    if let v = i.version { r["version"] = v }
                    if let s = i.sha { r["sha"] = s }
                    if let x = i.ref { r["ref"] = x }
                    if let d = i.dirty { r["dirty"] = d }
                    if let w = i.worktree { r["worktree"] = w }
                }
                return r
            }
            print(String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
            return
        }
        if builds.isEmpty { print("No builds in \(BuildStore.root.path) (scripts/devbuild.sh <name> makes one)."); return }
        print(Self.row("BUILD", "VERSION", "COMMIT", "REF", "AGE", "ROLE", "RUNNING ON"))
        for b in builds {
            var role: [String] = []
            if b.name == stable { role.append("stable") }
            if b.name == prev { role.append("prev") }
            let sha = (b.info?.shortSha ?? b.info?.sha.map { String($0.prefix(8)) } ?? "-") + (b.info?.dirty == true ? "+" : "")
            print(Self.row(b.name, b.info?.version ?? "-", sha, b.info?.ref ?? "-",
                           StateList.age(b.createdAt), role.isEmpty ? "-" : role.joined(separator: ","),
                           (running[b.name] ?? []).joined(separator: ", ")))
        }
    }

    static func row(_ a: String, _ b: String, _ c: String, _ d: String, _ e: String, _ f: String, _ g: String) -> String {
        "\(StateList.pad(a, 22)) \(StateList.pad(b, 9)) \(StateList.pad(c, 10)) \(StateList.pad(d, 28)) \(StateList.pad(e, 5)) \(StateList.pad(f, 12)) \(g)"
    }
}

struct BuildPromote: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "promote",
        abstract: "Make a build the stable one: snapshot work, quit it (VMs suspended), repoint stable, relink, reopen.")

    @Argument(help: "Build name (see `build ls`).")
    var build: String

    @Flag(name: .long, help: "Don't reopen work afterwards.")
    var noOpen = false

    func run() throws {
        do {
            let b = try BuildStore.build(named: build)
            guard b.url.deletingLastPathComponent().standardizedFileURL.path == BuildStore.root.standardizedFileURL.path else {
                throw ValidationError("'\(build)' isn't a build under \(BuildStore.root.path); only those can be stable")
            }
            let work = try Instances.state(ACSupportDir.defaultStateName)
            let old = BuildStore.stableName

            // The snapshot is taken by the build that will read the data
            // next: the current stable may predate `state snapshot`.
            if FileManager.default.fileExists(atPath: work.url.path) {
                print("==> snapshot of work with \(b.name)'s CLI")
                try Self.exec(b.binaryURL, ["state", "snapshot", work.name, "--label", "pre-\(b.name)"])
            }
            if let h = Instances.health(work) {
                print("==> quitting work (pid \(h["pid"] ?? "?"), VMs suspended)")
                try Instances.stop(state: work, vms: "suspend")
            }
            try BuildStore.setStable(b.name)
            print("==> stable: \(old ?? "(none)") → \(b.name)\(old.map { $0 != b.name ? "  (stable.prev → \($0))" : "" } ?? "")")
            let links = try BuildStore.refreshLinks()
            print("==> \(links.cli.path) and \(links.alias.lastPathComponent) follow it")
            if !noOpen {
                print("==> opening work on \(b.name)")
                let h = try Instances.start(state: work, build: b, mode: .gui, extraEnv: [], direct: false)
                print("pid \(h["pid"] ?? "?") · build \(h["build"] ?? "?")")
            }
        } catch let e as BuildStore.Failure { throw ValidationError(e.description) }
        catch let e as Instances.Failure { throw ValidationError(e.description) }
    }

    /// Run a build's CLI to completion, its output on ours.
    static func exec(_ bin: URL, _ args: [String]) throws {
        fflush(stdout)   // our lines before the child's when stdout is a pipe
        let p = Process()
        p.executableURL = bin
        p.arguments = args
        do { try p.run() } catch { throw ValidationError("can't run \(bin.path): \(error.localizedDescription)") }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw ValidationError("\(bin.lastPathComponent) \(args.joined(separator: " ")) exited \(p.terminationStatus)")
        }
    }
}

struct BuildRollback: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rollback",
        abstract: "Swap stable and stable.prev: quit work (VMs suspended), repoint, relink, reopen. Data is untouched.")

    @Flag(name: .long, help: "Don't reopen work afterwards.")
    var noOpen = false

    func run() throws {
        do {
            guard BuildStore.previous != nil else { throw BuildStore.Failure.noPrevious }
            let work = try Instances.state(ACSupportDir.defaultStateName)
            if let h = Instances.health(work) {
                print("==> quitting work (pid \(h["pid"] ?? "?"), VMs suspended)")
                try Instances.stop(state: work, vms: "suspend")
            }
            let swapped = try BuildStore.rollback()
            print("==> stable: \(swapped.from) → \(swapped.to)  (stable.prev → \(swapped.from))")
            try BuildStore.refreshLinks()
            print("work's data was not touched; to go back to the pre-promote data too:")
            print("    bromure-ac state snapshots work   # then: bromure-ac state restore work <pre-… snapshot>")
            if !noOpen, let b = BuildStore.stable {
                print("==> opening work on \(b.name)")
                try Instances.start(state: work, build: b, mode: .gui, extraEnv: [], direct: false)
            }
        } catch let e as BuildStore.Failure { throw ValidationError(e.description) }
        catch let e as Instances.Failure { throw ValidationError(e.description) }
    }
}

struct BuildPrune: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prune",
        abstract: "Remove every build but stable, stable.prev, those with a running instance and the newest prod-*; their devbuild worktrees go too.")

    @Flag(name: .long, help: "Show what would go; remove nothing.")
    var dryRun = false

    func run() throws {
        let running = Set(BuildStore.runningStates().keys)
        let drop = BuildStore.pruneCandidates(BuildStore.list(), stable: BuildStore.stableName,
                                              previous: BuildStore.previousName, running: running)
        if drop.isEmpty { print("Nothing to prune."); return }
        for b in drop {
            let wt = b.info?.worktree.map { " (+ worktree \($0))" } ?? ""
            if dryRun { print("would remove \(b.name)\(wt)"); continue }
            do {
                try BuildStore.remove(b)
                print("removed \(b.name)\(wt)")
            } catch {
                throw ValidationError("removing \(b.name): \(error.localizedDescription)")
            }
        }
    }
}

struct BuildLink: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "link",
        abstract: "Remake ~/.local/bin/bromure-ac and the Finder alias in ~/Applications for the stable build (promote does this).")

    func run() throws {
        do {
            let links = try BuildStore.refreshLinks()
            print("\(links.cli.path) → \(BuildStore.stableBinaryLinkURL.path)")
            print("\(links.alias.path) → \(BuildStore.stable?.appURL.path ?? "?")")
        } catch let e as BuildStore.Failure { throw ValidationError(e.description) }
    }
}
