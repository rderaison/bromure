import AppKit
import Foundation

extension ACAppDelegate {
    /// Trust `entry` (`ecosystem:name`) despite reputation verdicts in a
    /// workspace: saved with the profile and in force at once (GitHub issue
    /// #54 — a blocked package the user trusts, without turning the whole
    /// supply-chain check off). True when it's on the list now.
    @MainActor @discardableResult
    func allowSupplyChainPackage(_ entry: String, profileID: UUID) -> Bool {
        guard var p = profiles.first(where: { $0.id == profileID }) else { return false }
        if p.supplyChain.reputationAllowlist.contains(where: { $0.lowercased() == entry.lowercased() }) { return true }
        p.supplyChain.reputationAllowlist.append(entry)
        do { try store.update(p) } catch {
            NSLog("[bromure-ac] supply chain: couldn't save the allowlist for \(p.name): \(error)")
            return false
        }
        if let i = profiles.firstIndex(where: { $0.id == profileID }) { profiles[i] = p }
        // The running session's and pane's (launch-time) copies get just the
        // supply-chain policy, as a firewall edit patches just the rules.
        runningSessions[profileID]?.profile.supplyChain = p.supplyChain
        pane(for: profileID)?.profile.supplyChain = p.supplyChain
        mitmEngine?.setSupplyChainPolicy(p.supplyChain, for: profileID)
        NotificationCenter.default.post(name: .bromureSupplyChainAllowlistChanged, object: profileID,
                                        userInfo: ["entry": entry])
        return true
    }

    /// The override prompt's "Always allow" lands here (the broker is an
    /// actor off the main thread).
    func wireSupplyChainOverrides(_ broker: SupplyChainConsentBroker) {
        Task {
            await broker.setPersistOverride { profileID, entry in
                Task { @MainActor in
                    (NSApp.delegate as? ACAppDelegate)?.allowSupplyChainPackage(entry, profileID: profileID)
                }
            }
        }
    }
}
