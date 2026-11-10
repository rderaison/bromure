import Foundation

/// Every read-modify-write of a saved workspace in the daemon, on one
/// executor: the stored copy is loaded, changed and written under one
/// process-wide lock, with no await between the load and the write. macOS
/// gets this from running them all on the main actor; the daemon's run on
/// its actor and on the main actor both. Without it a route that loaded the
/// workspace before a launch saved its refreshed MCP token would write the
/// spent one back.
enum ProfileWrites {
    /// Recursive: a locked edit may save through a helper that locks too.
    private nonisolated(unsafe) static let lock = NSRecursiveLock()

    /// `body` under the lock (it must not suspend: it is synchronous).
    // @port-skip linux-only: macOS serializes these on the main actor
    static func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// After a write that can add or change a workspace: what macOS's
    /// profiles.didSet does that a server needs (the private-mode set kept
    /// out of bromure.io: Daemon.refreshStreamingState). Set by the daemon.
    nonisolated(unsafe) static var onChange: (@Sendable () -> Void)?

    /// A write under the lock (a new workspace saved, one changed), then
    /// the change said (onChange): every daemon write goes through here or
    /// `edit`, as macOS's go through its profiles array.
    // @port-skip linux-only: the daemon's one funnel for profile writes (macOS: ACAppDelegate.profiles.didSet)
    @discardableResult
    static func write<T>(_ body: () throws -> T) rethrows -> T {
        let r = try locked(body)
        onChange?()
        return r
    }

    /// The stored workspace `id` (secrets merged), changed by `change` and
    /// saved when it says so (false: nothing to write). nil when there is no
    /// such workspace; the saved copy otherwise (the stored one when unchanged).
    // @port ACAppDelegate.saveField(of: Profile.ID, _: (inoutProfile)->Void) h=2d4a7c788902c948 @d3ebbda2
    @discardableResult
    static func edit(_ id: UUID, store: ProfileStore, _ change: (inout Profile) throws -> Bool) throws -> Profile? {
        let saved: Profile? = try locked {
            guard var p = store.loadAll().first(where: { $0.id == id }) else { return nil }
            guard try change(&p) else { return p }
            return try store.update(p)
        }
        onChange?()
        return saved
    }
}
