import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Which Bromure process has a workspace's VM open. The app and its login
/// agent both stay up and both start workspaces (automations, Start), but
/// each only sees its own `runningSessions`: the other one took a live
/// workspace for stopped and booted it from the profile it loaded at
/// startup -- saving that stale copy first, minted credentials and all
/// (Finding CWE-284, "The other Bromure process's launch rewrites a
/// workspace and drops minted keys"). A booting or running workspace holds
/// an exclusive `flock` on `vm.lease` in its directory; the kernel lets it
/// go when the process dies, so a crashed owner never strands it.
enum WorkspaceLease {
    static let fileName = "vm.lease"
    private static let lock = NSLock()
    private static var held: [UUID: Int32] = [:]

    /// Take the lease for this process; false when another live process
    /// holds it. Already ours: true.
    static func acquire(_ id: UUID, dir: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if held[id] != nil { return true }
        guard let fd = lockedFD(dir) else { return false }
        held[id] = fd
        return true
    }

    /// Give it back (the VM is gone, or its boot failed). No-op if not ours.
    static func release(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if let fd = held.removeValue(forKey: id) { close(fd) }   // closing drops the flock
    }

    static func isHeld(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return held[id] != nil
    }

    /// Another live process has the workspace open.
    static func heldElsewhere(_ id: UUID, dir: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if held[id] != nil { return false }
        guard let fd = lockedFD(dir) else {
            // Couldn't lock: held elsewhere, unless the file can't even be opened
            // (no directory yet -- nothing runs there).
            return FileManager.default.fileExists(atPath: dir.appendingPathComponent(fileName).path)
        }
        close(fd)
        return false
    }

    /// An fd holding the exclusive lock, or nil (held elsewhere, or no file).
    private static func lockedFD(_ dir: URL) -> Int32? {
        let fd = open(dir.appendingPathComponent(fileName).path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
        return fd
    }
}

/// Reboot pins on workspace leases (see `ACAppDelegate.pinLease`), kept on
/// one monotonic clock. The deadline used to be a wall-clock `Date` judged
/// after a monotonic `Task.sleep`: a clock set back past the sleep's slack
/// left an abandoned reboot's pin "live" at its wake, nothing ran again, and
/// the lease stayed for the life of the process -- the other Bromure process
/// refused the workspace until then (Finding CWE-667, "A reboot's lease pin
/// never lapses if the clock steps backward"). A clock set forward made a
/// live pin look lapsed instead. `ContinuousClock` moves with neither.
struct LeasePins {
    typealias Instant = ContinuousClock.Instant
    private var deadlines: [UUID: Instant] = [:]

    /// Pin `id` until `seconds` from `now`; returns the deadline its wake
    /// sleeps to.
    mutating func pin(_ id: UUID, for seconds: Double, now: Instant = .now) -> Instant {
        let until = now.advanced(by: .seconds(seconds))
        deadlines[id] = until
        return until
    }

    /// Pinned and not yet lapsed.
    func isLive(_ id: UUID, now: Instant = .now) -> Bool {
        deadlines[id].map { $0 > now } ?? false
    }

    /// Taken over (a boot acquired) or given up: no pin.
    mutating func clear(_ id: UUID) { deadlines[id] = nil }

    /// The wake for `deadline`: clears the pin when it is still that one (not
    /// re-pinned, not taken over) and says whether it did.
    mutating func lapse(_ id: UUID, deadline: Instant) -> Bool {
        guard deadlines[id] == deadline else { return false }
        deadlines[id] = nil
        return true
    }
}
