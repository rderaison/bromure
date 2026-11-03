import Foundation

/// Workspaces whose boot `launch` has started but not finished. Between the
/// two, the disk is being cloned, prepared and opened by
/// Virtualization.framework, yet the VM isn't in `runningSessions` until
/// `registerSession` — so a delete, reset or revert that only looked there
/// pulled the images out from under a booting VM. Begun before `launch`
/// returns, ended when the boot registers or fails.
@MainActor final class BootsInFlight {
    private var ids: Set<UUID> = []
    /// A stop asked for while the boot had no session to stop yet: the VM
    /// it registers is stopped the way asked (`take` at registration).
    private var pendingStops: [UUID: Profile.CloseAction] = [:]

    /// Marks a boot under way; false when one already is (one boot per disk).
    func begin(_ id: UUID) -> Bool { ids.insert(id).inserted }
    /// The boot is over (registered or failed): a stop it never served goes.
    func end(_ id: UUID) {
        ids.remove(id)
        pendingStops[id] = nil
    }
    func contains(_ id: UUID) -> Bool { ids.contains(id) }

    /// Remembers a stop for a boot under way; false when there is none.
    func deferStop(_ id: UUID, action: Profile.CloseAction) -> Bool {
        guard ids.contains(id) else { return false }
        pendingStops[id] = action
        return true
    }
    func takeStop(_ id: UUID) -> Profile.CloseAction? { pendingStops.removeValue(forKey: id) }

    /// The workspace's disk and home are open, or about to be.
    func diskInUse(_ id: UUID, running: Bool) -> Bool { running || ids.contains(id) }
}
