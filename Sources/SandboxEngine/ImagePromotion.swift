import Foundation

/// Replaces a set of live image files (disk, kernel, initrd -- or base.img
/// and its EFI store) with staged ones as one unit, surviving a crash.
///
/// The live files are set aside as `<name>.previous`, the staged ones moved
/// in, then the backups dropped. An error midway puts the old files back
/// in-process; a kill, crash or power loss can't, so a journal written
/// first records what's being replaced, and `recover` -- run when an image
/// manager is made, i.e. on the next launch -- rolls an interrupted
/// promotion back to the previous image. Without it, a kill between
/// setting the live files aside and moving the new ones in left no live
/// image at all: startup sees none and asks for setup, the old one
/// stranded under `.previous` until the next promotion deletes it
/// (Finding "Interrupted local promotion leaves no bootable live image",
/// CWE-459).
///
/// A promotion holds an exclusive `flock` on the journal's lock file, so a
/// second process sharing the directory (Bromure Agentic Coding boots Bromure
/// Web's image) never rolls back a promotion still under way.
public enum ImagePromotion {
    static let journalName = ".promotion.json"
    static let lockName = ".promotion.lock"

    struct Entry: Codable, Equatable {
        /// The live file's name in the directory.
        var live: String
        /// It existed when the promotion began (so it has, or will have, a
        /// `.previous` backup).
        var hadLive: Bool
    }

    static func backup(_ live: URL) -> URL { live.appendingPathExtension("previous") }

    /// Moves each `from` over its `to` (all in `dir`) as one unit.
    public static func promote(_ pairs: [(from: URL, to: URL)], in dir: URL) throws {
        let fm = FileManager.default
        let lock = try Lock(dir)
        defer { lock.release() }
        // An earlier crash's leftovers first, under the lock.
        recoverLocked(in: dir)
        let journal = dir.appendingPathComponent(journalName)
        guard !fm.fileExists(atPath: journal.path) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: journal.path])
        }
        for (_, live) in pairs { try? fm.removeItem(at: backup(live)) }

        let entries = pairs.map { Entry(live: $0.to.lastPathComponent, hadLive: fm.fileExists(atPath: $0.to.path)) }
        try JSONEncoder().encode(entries).write(to: journal, options: .atomic)
        sync(journal)

        var setAside: [(live: URL, backup: URL)] = []
        var promoted: [URL] = []
        do {
            for (_, live) in pairs where fm.fileExists(atPath: live.path) {
                try fm.moveItem(at: live, to: backup(live))
                setAside.append((live, backup(live)))
            }
            for (from, live) in pairs {
                try fm.moveItem(at: from, to: live)
                promoted.append(live)
            }
        } catch {
            // Roll back by the journal, as a later launch would. Any restore
            // that fails keeps the journal (and its backups) for that launch.
            _ = recoverLocked(in: dir)
            throw error
        }
        // Committed: the new files are all live. Removing the journal is the
        // commit point; if it can't go, a later recovery would roll back a
        // promotion the caller believes done, so roll back now and fail.
        sync(dir)
        do {
            try fm.removeItem(at: journal)
        } catch {
            _ = recoverLocked(in: dir)
            throw error
        }
        sync(dir)
        for (_, backup) in setAside { try? fm.removeItem(at: backup) }
    }

    /// One file over another in a single rename(2): the destination is
    /// replaced atomically, never missing -- unlike removing it first.
    public static func replace(_ from: URL, over to: URL) throws {
        guard rename(from.path, to.path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: to.path,
                                                          NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
        }
    }

    /// Rolls an interrupted promotion in `dir` back to the previous image.
    /// Nothing to do without a journal; skipped while another process (or
    /// this one) is promoting. If a restore fails, the journal stays and
    /// `isPending` stays true, so the files aren't booted and the next
    /// launch retries.
    public static func recover(in dir: URL) {
        guard isPending(in: dir),
              let lock = try? Lock(dir, wait: false) else { return }
        defer { lock.release() }
        if !recoverLocked(in: dir) {
            NSLog("Bromure: image promotion rollback in %@ incomplete; will retry at next launch", dir.path)
        }
    }

    /// A promotion is under way, or one that was interrupted hasn't been
    /// fully rolled back: the live files may be a mix of old and new, and
    /// must be neither booted nor deleted as "no prior image".
    public static func isPending(in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(journalName).path)
    }

    /// Each file with a backup gets it back; one that had none and didn't
    /// exist before is the new image's (or nothing) and goes; one that
    /// existed and has no backup was never set aside -- still the old one.
    ///
    /// The journal is removed only once every entry is restored. If any
    /// restore fails, the journal and the remaining backups stay, so a later
    /// launch retries; entries already restored are no-ops on that retry.
    /// Returns whether the rollback completed.
    @discardableResult
    static func recoverLocked(in dir: URL) -> Bool {
        let fm = FileManager.default
        let journal = dir.appendingPathComponent(journalName)
        guard fm.fileExists(atPath: journal.path) else { return true }
        // Unreadable (it's written atomically, so not expected): kept, and
        // its backups with it, rather than dropped unrestored.
        guard let data = try? Data(contentsOf: journal),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return false }
        var complete = true
        for e in entries where !e.live.isEmpty && !e.live.contains("/") {
            let live = dir.appendingPathComponent(e.live)
            let prev = backup(live)
            if fm.fileExists(atPath: prev.path) {
                // One rename(2) puts the backup over whatever is live (the
                // new file, or nothing): never a moment with neither.
                do { try replace(prev, over: live) } catch { complete = false }
            } else if !e.hadLive, fm.fileExists(atPath: live.path) {
                do { try fm.removeItem(at: live) } catch { complete = false }
            }
        }
        sync(dir)
        guard complete else { return false }
        do { try fm.removeItem(at: journal) } catch { return false }
        sync(dir)
        return true
    }

    /// fsync, so the journal (and the renames it guards) are on disk in
    /// order: a power loss can't keep a rename and lose the journal.
    private static func sync(_ url: URL) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        _ = fsync(fd)
        close(fd)
    }

    private struct Lock {
        let fd: Int32
        init(_ dir: URL, wait: Bool = true) throws {
            fd = open(dir.appendingPathComponent(lockName).path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
            if flock(fd, LOCK_EX | (wait ? 0 : LOCK_NB)) != 0 {
                close(fd)
                throw CocoaError(.fileLocking)
            }
        }
        func release() { flock(fd, LOCK_UN); close(fd) }
    }
}
