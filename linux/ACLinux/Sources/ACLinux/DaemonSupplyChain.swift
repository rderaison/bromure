import Foundation

// A workspace's trusted packages on a Linux server (macOS:
// SupplyChainOverrides.swift): the override prompt's "Always allow" saved in
// the workspace's reputation allowlist, and in force at once.
extension Daemon {
    /// Trust `entry` (`ecosystem:name`) despite reputation verdicts in a
    /// workspace: saved with the profile and in force at once. True when
    /// it's on the list now.
    // partial: no open editor or notification to tell (no windows on a server)
    // @port ACAppDelegate.allowSupplyChainPackage(_: String, profileID: UUID) h=98521040aaa6cdff @5b243e2e
    @discardableResult
    func allowSupplyChainPackage(_ entry: String, profileID: UUID) -> Bool {
        let store = ProfileStore()
        guard var p = store.loadAll().first(where: { $0.id == profileID }) else { return false }
        if p.supplyChain.reputationAllowlist.contains(where: { $0.lowercased() == entry.lowercased() }) { return true }
        p.supplyChain.reputationAllowlist.append(entry)
        do { try store.update(p) } catch {
            FileHandle.standardError.write(Data("bromure-ac daemon: supply chain: couldn't save the allowlist for \(p.name): \(error)\n".utf8))
            return false
        }
        // A running workspace's proxy takes it now; a stopped one's at launch.
        if live.keys.contains(where: { UUID(uuidString: $0) == profileID }) {
            mitm?.setSupplyChainPolicy(p.supplyChain, for: profileID)
        }
        return true
    }

    /// The override prompt's "Always allow" lands here (the broker is an
    /// actor of its own).
    // @port ACAppDelegate.wireSupplyChainOverrides(_: SupplyChainConsentBroker) h=18a4856ade76cceb @5b243e2e
    func wireSupplyChainOverrides(_ broker: SupplyChainConsentBroker) {
        Task {
            await broker.setPersistOverride { [weak self] profileID, entry in
                Task { await self?.allowSupplyChainPackage(entry, profileID: profileID) }
            }
        }
    }
}
