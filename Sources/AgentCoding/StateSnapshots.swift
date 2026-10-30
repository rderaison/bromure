import Foundation

/// Snapshots of a state (BUILD_INSTRUCTIONS.md, "States"): APFS clones of the
/// whole state directory under `<states root>/.snapshots/<state>/<time>[-label]/`,
/// instant to take and to restore, kept by a retention policy.
///
/// Why not APFS local snapshots (`tmutil localsnapshot`): whole volume, 24 h
/// retention the system controls, a restore needs a snapshot mount and a
/// full copy back. Per-state clone trees are instant both ways, selective
/// (one workspace can be restored alone), and under our policy. FileVault
/// and the keychain make them as protected as the live state.
extension StateStore {
    /// A snapshot directory's name: `2026-10-25T08-22-12` or `…-pre-devbuild-02`.
    struct Snapshot: Equatable {
        let url: URL
        let takenAt: Date
        /// The label after the time, if any (`pre-restore`, a user's).
        let label: String?
        var name: String { url.lastPathComponent }
        /// Labelled snapshots are kept until removed by hand; pruning only
        /// thins the unlabelled, scheduled ones.
        var isAutomatic: Bool { label == nil }
    }

    /// What `prune` keeps among the automatic snapshots: everything younger
    /// than `keepAllHours`, one per hour younger than `hourlyDays`, one per
    /// day younger than `dailyDays`, nothing older. Settings keys
    /// `snapshots.keepAllHours`, `snapshots.hourlyDays`, `snapshots.dailyDays`
    /// override the defaults (24 h, 7 d, 30 d).
    struct RetentionPolicy: Equatable {
        var keepAllHours: Double = 24
        var hourlyDays: Double = 7
        var dailyDays: Double = 30

        static func fromSettings(_ d: UserDefaults = ACDefaults.standard) -> RetentionPolicy {
            var p = RetentionPolicy()
            if d.object(forKey: "snapshots.keepAllHours") != nil { p.keepAllHours = d.double(forKey: "snapshots.keepAllHours") }
            if d.object(forKey: "snapshots.hourlyDays") != nil { p.hourlyDays = d.double(forKey: "snapshots.hourlyDays") }
            if d.object(forKey: "snapshots.dailyDays") != nil { p.dailyDays = d.double(forKey: "snapshots.dailyDays") }
            return p
        }
    }

    static var snapshotsRoot: URL { ACSupportDir.statesRoot.appendingPathComponent(".snapshots", isDirectory: true) }

    static func snapshotsDirectory(for state: Entry) -> URL {
        snapshotsRoot.appendingPathComponent(state.name, isDirectory: true)
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        return f
    }()

    /// Parse a snapshot directory name; nil for anything that isn't one.
    static func parseSnapshotName(_ name: String, url: URL) -> Snapshot? {
        guard name.count >= 19, let date = stampFormatter.date(from: String(name.prefix(19))) else { return nil }
        let rest = name.dropFirst(19)
        let label: String? = rest.hasPrefix("-") && rest.count > 1 ? String(rest.dropFirst()) : nil
        if !rest.isEmpty && label == nil { return nil }
        return Snapshot(url: url, takenAt: date, label: label)
    }

    /// The snapshots of a state, oldest first.
    static func snapshots(of state: Entry) -> [Snapshot] {
        let dir = snapshotsDirectory(for: state)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.compactMap { parseSnapshotName($0, url: dir.appendingPathComponent($0, isDirectory: true)) }
            .sorted { $0.takenAt < $1.takenAt }
    }

    /// Clone the state into a new snapshot. A running state is asked to sync
    /// first (`POST /app/sync`: `sync` in every running guest, the host-side
    /// stores flushed) and its saved RAM images are left out, since a VM that
    /// runs now has moved past them. `label` must be a single path component.
    @discardableResult
    static func snapshot(_ state: Entry, label: String? = nil, now: Date = Date()) throws -> Snapshot {
        if let label, ACSupportDir.validStateName(label) == nil || label.contains(" ") {
            throw Failure.badName(label)
        }
        let dir = snapshotsDirectory(for: state)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var name = stampFormatter.string(from: now)
        if let label { name += "-\(label)" }
        let dst = dir.appendingPathComponent(name, isDirectory: true)
        if FileManager.default.fileExists(atPath: dst.path) { throw Failure.exists(name) }

        let running = state.instance.locked
        if running { syncRunningInstance(state) }
        let tmp = dir.appendingPathComponent(".\(name).partial", isDirectory: true)
        try? FileManager.default.removeItem(at: tmp)
        do {
            try cloneTree(from: state.url, to: tmp, relative: "") { rel in
                if neverCloned.contains(rel) || rel == "logs" { return true }
                if running, rel.hasPrefix("profiles/"), rel.hasSuffix("/vm.state") { return true }
                return false
            }
            try FileManager.default.moveItem(at: tmp, to: dst)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
        return Snapshot(url: dst, takenAt: now, label: label)
    }

    /// Best effort: the instance flushes what it can before the clone.
    static func syncRunningInstance(_ state: Entry) {
        let client = ControlClient(socketPath: state.url.appendingPathComponent("control.sock").path)
        _ = try? client.request("POST", "/app/sync", body: [:])
    }

    /// Put a snapshot back. The state must not be running. The whole state
    /// is swapped (a rename, instant) and the replaced tree kept as a
    /// `pre-restore` snapshot; with `only` (a path inside the state, e.g.
    /// `profiles/<uuid>`), just that subtree is swapped, the replaced one
    /// kept under the `pre-restore` snapshot at the same path.
    static func restore(_ state: Entry, from snapshot: Snapshot, only: String? = nil, now: Date = Date()) throws {
        if state.instance.locked { throw Failure.running(state.name, state.instance.info) }
        let fm = FileManager.default
        let keepName = stampFormatter.string(from: now) + "-pre-restore"
        let keep = snapshotsDirectory(for: state).appendingPathComponent(keepName, isDirectory: true)
        if let only {
            let rel = only.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !rel.isEmpty, !rel.contains(".."), rel != "logs" else { throw Failure.badName(only) }
            let src = snapshot.url.appendingPathComponent(rel)
            guard fm.fileExists(atPath: src.path) else { throw Failure.missing("\(snapshot.name)/\(rel)") }
            let live = state.url.appendingPathComponent(rel)
            let kept = keep.appendingPathComponent(rel)
            try fm.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: live.path) { try fm.moveItem(at: live, to: kept) }
            try fm.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
            try cloneTree(from: src, to: live, relative: rel) { _ in false }
        } else {
            // Whole state: keep the instance files and logs out of the swap
            // (they are the live directory's, not data), then rename.
            try fm.createDirectory(at: keep.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: state.url, to: keep)
            do {
                try cloneTree(from: snapshot.url, to: state.url, relative: "") { _ in false }
                // The replaced tree's logs come back: they belong to the state, not the data.
                let logs = keep.appendingPathComponent("logs")
                if fm.fileExists(atPath: logs.path) { try? fm.moveItem(at: logs, to: state.url.appendingPathComponent("logs")) }
                for n in [ACInstance.infoFileName, ACInstance.lockFileName, "control.sock"] {
                    try? fm.removeItem(at: keep.appendingPathComponent(n))
                }
            } catch {
                // Put the live tree back rather than leave the state missing.
                try? fm.removeItem(at: state.url)
                try? fm.moveItem(at: keep, to: state.url)
                throw error
            }
        }
    }

    /// Which automatic snapshots a policy drops, given their times and
    /// `now`. Pure, for the tests: keeps all within `keepAllHours`, the
    /// newest per hour within `hourlyDays`, the newest per day within
    /// `dailyDays`, none beyond.
    static func snapshotsToDrop(_ snapshots: [Snapshot], policy: RetentionPolicy, now: Date) -> [Snapshot] {
        let automatic = snapshots.filter(\.isAutomatic).sorted { $0.takenAt > $1.takenAt }   // newest first
        var keep = Set<URL>()
        var hourSlots = Set<Int>(), daySlots = Set<Int>()
        for s in automatic {
            let age = now.timeIntervalSince(s.takenAt)
            if age < policy.keepAllHours * 3600 { keep.insert(s.url); continue }
            if age < policy.hourlyDays * 86400 {
                let slot = Int(s.takenAt.timeIntervalSince1970 / 3600)
                if hourSlots.insert(slot).inserted { keep.insert(s.url) }
                continue
            }
            if age < policy.dailyDays * 86400 {
                let slot = Int(s.takenAt.timeIntervalSince1970 / 86400)
                if daySlots.insert(slot).inserted { keep.insert(s.url) }
                continue
            }
        }
        return automatic.filter { !keep.contains($0.url) }
    }

    /// Apply the policy: remove what it drops. Returns what was removed.
    @discardableResult
    static func prune(_ state: Entry, policy: RetentionPolicy = .fromSettings(), now: Date = Date()) throws -> [Snapshot] {
        let drop = snapshotsToDrop(snapshots(of: state), policy: policy, now: now)
        for s in drop { try FileManager.default.removeItem(at: s.url) }
        return drop
    }

    /// Remove one snapshot by name.
    static func removeSnapshot(_ state: Entry, named name: String) throws {
        guard let s = snapshots(of: state).first(where: { $0.name == name }) else { throw Failure.missing(name) }
        try FileManager.default.removeItem(at: s.url)
    }

    // MARK: Hourly schedule

    /// A per-user LaunchAgent that runs `state snapshot <state>` (then
    /// prune) every hour, through the `stable` symlink so it follows a
    /// promote. `bromure-ac state schedule install|remove <state>`.
    static func scheduleLabel(for state: Entry) -> String {
        "io.bromure.agentic-coding.snapshot.\(ACSupportDir.name).\(state.name)"
    }
    static func schedulePlistURL(for state: Entry) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(scheduleLabel(for: state)).plist")
    }

    static func installSchedule(for state: Entry, everySeconds: Int = 3600) throws {
        let stable = ACSupportDir.buildsRoot.appendingPathComponent("stable/Bromure Agentic Coding.app/Contents/MacOS/bromure-ac")
        let exe = FileManager.default.fileExists(atPath: stable.path) ? stable.path
            : (Bundle.main.executableURL?.path ?? CommandLine.arguments[0])
        let plist: [String: Any] = [
            "Label": scheduleLabel(for: state),
            "ProgramArguments": [exe, "state", "snapshot", state.name, "--prune"],
            "StartInterval": everySeconds,
            "RunAtLoad": false,
            "StandardOutPath": state.logsURL.appendingPathComponent("snapshot.log").path,
            "StandardErrorPath": state.logsURL.appendingPathComponent("snapshot.log").path,
        ]
        let url = schedulePlistURL(for: state)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state.logsURL, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: url)
        launchctl(["bootout", "gui/\(getuid())/\(scheduleLabel(for: state))"])
        launchctl(["bootstrap", "gui/\(getuid())", url.path])
    }

    static func removeSchedule(for state: Entry) {
        launchctl(["bootout", "gui/\(getuid())/\(scheduleLabel(for: state))"])
        try? FileManager.default.removeItem(at: schedulePlistURL(for: state))
    }

    static func scheduleInstalled(for state: Entry) -> Bool {
        FileManager.default.fileExists(atPath: schedulePlistURL(for: state).path)
    }

    private static func launchctl(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}

extension StateStore.Entry {
    /// Where this state's logs go (the same rule as `ACSupportDir.logsURL`).
    var logsURL: URL {
        isDefault
            ? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/\(url.lastPathComponent)", isDirectory: true)
            : url.appendingPathComponent("logs", isDirectory: true)
    }
}
