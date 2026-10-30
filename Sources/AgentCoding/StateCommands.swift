import ArgumentParser
import Foundation

// MARK: - `bromure-ac state …`
//
// States: the data sets a build can run on (BUILD_INSTRUCTIONS.md, "States").
// `--state <name>` on any command picks one; these manage them. None of
// this talks to a running app: it reads and writes the state directories
// and their settings suites directly.

struct StateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "state",
        abstract: "Manage states: the data sets (workspaces, settings, secrets, images) a build runs on.",
        discussion: """
            The default state, "work", is the app's own folder: what a Dock launch opens. Any other \
            state is a folder under \(ACSupportDir.statesRoot.path) with its own settings; run a build on one \
            with `--state <name>` (or BROMURE_STATE=<name>, BROMURE_STATE_DIR=<dir>). Copies are APFS clones: \
            instant and free until written.
            """,
        subcommands: [StateList.self, StateCreate.self, StateRemove.self, StatePath.self,
                      StateSnapshot.self, StateSnapshots.self, StateRestore.self, StatePrune.self,
                      StateSchedule.self],
        defaultSubcommand: StateList.self)
}

struct StateList: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List states: path, size, the instance running on it.")

    @Flag(name: .long, help: "Machine-readable JSON.")
    var json = false

    @Flag(name: .long, help: "Skip the sizes (walks every file; a second or two for a large state).")
    var noSize = false

    func run() throws {
        let entries = StateStore.list()
        if json {
            var rows: [[String: Any]] = []
            for e in entries {
                var row: [String: Any] = [
                    "name": e.name, "path": e.url.path, "default": e.isDefault,
                    "settingsDomain": e.settingsDomain, "running": e.instance.locked,
                ]
                if let i = e.instance.info, e.instance.locked {
                    row["pid"] = Int(i.pid); row["build"] = i.build; row["mode"] = i.mode
                    if let p = i.automationPort { row["automationPort"] = p }
                }
                if let m = e.metadata {
                    if let c = m.clonedFrom { row["clonedFrom"] = c }
                    if let a = m.assetsFrom { row["assetsFrom"] = a }
                    row["createdAt"] = ISO8601DateFormatter().string(from: m.createdAt)
                }
                if !noSize {
                    let s = StateStore.sizes(of: e.url)
                    row["apparentBytes"] = s.apparent; row["allocatedBytes"] = s.allocated
                }
                let snaps = StateStore.snapshots(of: e)
                row["snapshots"] = snaps.count
                if let last = snaps.last { row["lastSnapshotAt"] = ISO8601DateFormatter().string(from: last.takenAt) }
                row["hourlySnapshots"] = StateStore.scheduleInstalled(for: e)
                rows.append(row)
            }
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            return
        }
        print(row("STATE", "SIZE", "RUNNING", "SNAPSHOT", "PATH"))
        for e in entries {
            let size = noSize ? "-" : StateStore.human(StateStore.sizes(of: e.url).allocated)
            var running = "-"
            if e.instance.locked {
                if let i = e.instance.info {
                    running = "pid \(i.pid) · \(i.build) · \(i.mode)"
                    if let p = i.automationPort, p > 0 { running += " · :\(p)" }
                } else {
                    running = "yes"
                }
            }
            var name = e.name
            if e.isDefault { name += " (default)" }
            let snaps = StateStore.snapshots(of: e)
            var snapshot = "-"
            if let last = snaps.last {
                snapshot = "\(Self.age(last.takenAt)) ago (\(snaps.count))"
            }
            if StateStore.scheduleInstalled(for: e) { snapshot += " ⟳" }
            print(row(name, size, running, snapshot, e.url.path))
            if let m = e.metadata {
                var notes: [String] = []
                if let c = m.clonedFrom { notes.append("cloned from \(c)\(m.live == true ? " (live)" : "")") }
                if let a = m.assetsFrom { notes.append("assets from \(a)") }
                if let b = m.createdBy { notes.append("by \(b)") }
                if !notes.isEmpty { print("  " + notes.joined(separator: ", ")) }
            }
        }
    }
}

extension StateList {
    /// Fixed-width columns (String(format: "%-18s") can't take Swift strings).
    static func pad(_ s: String, _ w: Int) -> String { s.count >= w ? s : s + String(repeating: " ", count: w - s.count) }
    func row(_ a: String, _ b: String, _ c: String, _ d: String, _ e: String) -> String {
        "\(Self.pad(a, 18)) \(Self.pad(b, 10)) \(Self.pad(c, 34)) \(Self.pad(d, 14)) \(e)"
    }

    /// "3m", "5h", "2d".
    static func age(_ d: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(d))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

struct StateCreate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a state: with work's assets (default), empty, with another state's assets, or a full clone.",
        discussion: """
            By default the new state gets the default state's assets: the base image, the stock image, the \
            download caches, the browser image and the local models are cloned (zero bytes, instant), so it \
            needs no download and no `init`, and starts with no workspaces, no settings and no secrets. \
            `--assets-from <state>` takes them from another state; `--empty` takes none (a fresh install). \
            `--from <state>` clones everything, settings included; its workspaces share their keychain \
            keys with the original's. A running source is refused unless `--live` (a crash-consistent \
            copy; saved RAM images are left out, so its workspaces cold-boot).
            """)

    @Argument(help: "The new state's name (one path component).")
    var name: String

    @Option(name: .long, help: "Clone this state in full (data + settings).")
    var from: String?

    @Option(name: .customLong("assets-from"), help: "Clone this state's images, caches and models instead of work's.")
    var assetsFrom: String?

    @Flag(name: .long, help: "No assets at all: a fresh install that has to download or build its images.")
    var empty = false

    @Flag(name: .long, help: "With --from: clone the source even while it runs.")
    var live = false

    func validate() throws {
        if from != nil, assetsFrom != nil { throw ValidationError("--from and --assets-from are exclusive.") }
        if empty, from != nil || assetsFrom != nil { throw ValidationError("--empty takes no source.") }
        if live, from == nil { throw ValidationError("--live only applies to --from.") }
    }

    /// The state whose assets the new one starts with: `--assets-from`, else
    /// the default state when it exists (a Mac that never ran the app has
    /// nothing to clone), else none.
    private func assetSource() throws -> StateStore.Entry? {
        if empty { return nil }
        if let assetsFrom { return try StateStore.existing(assetsFrom) }
        return try? StateStore.existing(ACSupportDir.defaultStateName)
    }

    func run() throws {
        let by = "\(ACInstance.buildName) \(ACInstance.bundleVersion ?? "")".trimmingCharacters(in: .whitespaces)
        do {
            let created: StateStore.Entry
            if let from {
                let src = try StateStore.existing(from)
                let t0 = Date()
                created = try StateStore.clone(src, as: name, live: live, createdBy: by)
                print("Cloned '\(src.name)' → '\(created.name)' in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s: \(created.url.path)")
            } else {
                let src = try assetSource()
                created = try StateStore.create(named: name, assetsFrom: src, createdBy: by)
                print("Created '\(created.name)'\(src.map { " with the assets of '\($0.name)'" } ?? " (empty)"): \(created.url.path)")
            }
            print("Run a build on it with: bromure-ac --state \(created.name) …  (or BROMURE_STATE=\(created.name))")
        } catch let e as StateStore.Failure {
            throw ValidationError(e.description)
        }
    }
}

struct StateRemove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm", abstract: "Delete a state and its settings. Never the default one, never a running one.")

    @Argument(help: "State name.")
    var name: String

    @Flag(name: [.customShort("f"), .long], help: "Skip the confirmation prompt.")
    var force = false

    func run() throws {
        do {
            let e = try StateStore.existing(name)
            if e.isDefault { throw StateStore.Failure.isDefault(e.name) }
            if e.instance.locked { throw StateStore.Failure.running(e.name, e.instance.info) }
            if !force {
                let size = StateStore.human(StateStore.sizes(of: e.url).allocated)
                FileHandle.standardError.write(Data(
                    "Delete state '\(e.name)' (\(size) at \(e.url.path)) and its settings? [y/N] ".utf8))
                let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                guard answer == "y" || answer == "yes" else { print("Aborted."); return }
            }
            try StateStore.remove(e)
            print("Deleted state '\(e.name)'. Keychain items were left alone (a clone shares them).")
        } catch let e as StateStore.Failure {
            throw ValidationError(e.description)
        }
    }
}

struct StatePath: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "path", abstract: "Print a state's directory (for scripts).")

    @Argument(help: "State name; default: the state this command runs on.")
    var name: String?

    func run() throws {
        if let name {
            do { print(try StateStore.existing(name).url.path) }
            catch let e as StateStore.Failure { throw ValidationError(e.description) }
        } else {
            print(ACSupportDir.url.path)
        }
    }
}

// MARK: Snapshots

struct StateSnapshot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Snapshot a state: an APFS clone of it under the states folder's .snapshots (instant).",
        discussion: """
            A running state is asked to sync first (every running guest runs `sync`, the host flushes \
            its stores) and its saved RAM images are left out, since its VMs have moved past them. \
            Unlabelled snapshots are the scheduled kind and are thinned by `state prune`; a labelled one \
            (`--label pre-devbuild-02`) stays until removed.
            """)

    @Argument(help: "State name.")
    var state: String

    @Option(name: .long, help: "A label after the time stamp (one word).")
    var label: String?

    @Flag(name: .long, help: "Apply the retention policy afterwards (what the hourly schedule does).")
    var prune = false

    func run() throws {
        do {
            let e = try StateStore.existing(state)
            let t0 = Date()
            let s = try StateStore.snapshot(e, label: label)
            print("Snapshot \(s.name) of '\(e.name)' in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s\(e.instance.locked ? " (running: synced, RAM images left out)" : ""): \(s.url.path)")
            if prune {
                let dropped = try StateStore.prune(e)
                if !dropped.isEmpty { print("Pruned \(dropped.count): \(dropped.map(\.name).joined(separator: ", "))") }
            }
        } catch let e as StateStore.Failure { throw ValidationError(e.description) }
    }
}

struct StateSnapshots: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshots", abstract: "List a state's snapshots, oldest first.")

    @Argument(help: "State name.")
    var state: String

    @Flag(name: .long, help: "Machine-readable JSON.")
    var json = false

    func run() throws {
        do {
            let e = try StateStore.existing(state)
            let snaps = StateStore.snapshots(of: e)
            if json {
                let rows: [[String: Any]] = snaps.map { s in
                    var r: [String: Any] = ["name": s.name, "path": s.url.path,
                                            "takenAt": ISO8601DateFormatter().string(from: s.takenAt), "automatic": s.isAutomatic]
                    if let l = s.label { r["label"] = l }
                    return r
                }
                print(String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]), as: UTF8.self))
                return
            }
            if snaps.isEmpty { print("No snapshots of '\(e.name)'."); return }
            for s in snaps {
                print("\(StateList.pad(s.name, 44)) \(StateList.pad(StateList.age(s.takenAt), 6)) ago  \(s.isAutomatic ? "scheduled" : "kept (\(s.label!))")")
            }
            let policy = StateStore.RetentionPolicy.fromSettings()
            let drop = StateStore.snapshotsToDrop(snaps, policy: policy, now: Date())
            print("\(snaps.count) snapshot(s); `state prune \(e.name)` would drop \(drop.count) (keep all <\(Int(policy.keepAllHours))h, hourly <\(Int(policy.hourlyDays))d, daily <\(Int(policy.dailyDays))d).")
        } catch let e as StateStore.Failure { throw ValidationError(e.description) }
    }
}

struct StateRestore: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Put a snapshot back (the state must not be running); the replaced data is kept as a pre-restore snapshot.")

    @Argument(help: "State name.")
    var state: String

    @Argument(help: "Snapshot name (see `state snapshots`), or `latest`.")
    var snapshot: String

    @Option(name: .long, help: "Restore only this path inside the state, e.g. profiles/<workspace uuid>.")
    var only: String?

    @Flag(name: [.customShort("f"), .long], help: "Skip the confirmation prompt.")
    var force = false

    func run() throws {
        do {
            let e = try StateStore.existing(state)
            if e.instance.locked { throw StateStore.Failure.running(e.name, e.instance.info) }
            let snaps = StateStore.snapshots(of: e)
            guard let s = snapshot == "latest" ? snaps.last : snaps.first(where: { $0.name == snapshot }) else {
                throw StateStore.Failure.missing("snapshot \(snapshot) of \(e.name)")
            }
            if !force {
                FileHandle.standardError.write(Data(
                    "Restore \(only.map { "'\($0)' of " } ?? "")'\(e.name)' from \(s.name) (\(StateList.age(s.takenAt)) ago)? The current data is kept as a pre-restore snapshot. [y/N] ".utf8))
                let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
                guard answer == "y" || answer == "yes" else { print("Aborted."); return }
            }
            try StateStore.restore(e, from: s, only: only)
            print("Restored \(only ?? "'\(e.name)'") from \(s.name). The replaced data is the newest `pre-restore` snapshot.")
        } catch let e as StateStore.Failure { throw ValidationError(e.description) }
    }
}

struct StatePrune: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prune",
        abstract: "Thin a state's scheduled snapshots: keep all <24h, hourly <7d, daily <30d (settings snapshots.*).")

    @Argument(help: "State name.")
    var state: String

    @Flag(name: .long, help: "Show what would go; remove nothing.")
    var dryRun = false

    func run() throws {
        do {
            let e = try StateStore.existing(state)
            let policy = StateStore.RetentionPolicy.fromSettings()
            if dryRun {
                let drop = StateStore.snapshotsToDrop(StateStore.snapshots(of: e), policy: policy, now: Date())
                print(drop.isEmpty ? "Nothing to prune." : "Would drop \(drop.count): \(drop.map(\.name).joined(separator: ", "))")
                return
            }
            let dropped = try StateStore.prune(e, policy: policy)
            print(dropped.isEmpty ? "Nothing to prune." : "Pruned \(dropped.count): \(dropped.map(\.name).joined(separator: ", "))")
        } catch let e as StateStore.Failure { throw ValidationError(e.description) }
    }
}

struct StateSchedule: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "schedule",
        abstract: "Hourly snapshots of a state: a per-user LaunchAgent running `state snapshot <state> --prune`.",
        discussion: "The agent runs the `stable` build's CLI, so it follows a promote. `install` loads it now; `remove` unloads and deletes it; `status` says which.")

    @Argument(help: "install | remove | status")
    var action: String

    @Argument(help: "State name (default: work).")
    var state: String = ACSupportDir.defaultStateName

    func run() throws {
        do {
            let e = try StateStore.existing(state)
            switch action {
            case "install":
                try StateStore.installSchedule(for: e)
                print("Hourly snapshots of '\(e.name)' installed: \(StateStore.schedulePlistURL(for: e).path)")
            case "remove":
                StateStore.removeSchedule(for: e)
                print("Hourly snapshots of '\(e.name)' removed.")
            case "status":
                print(StateStore.scheduleInstalled(for: e) ? "installed (\(StateStore.scheduleLabel(for: e)))" : "not installed")
            default:
                throw ValidationError("action must be install, remove or status")
            }
        } catch let e as StateStore.Failure { throw ValidationError(e.description) }
    }
}
