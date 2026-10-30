import Foundation

/// Per-profile UI preferences (remembered dialog decisions).
///
/// Stored in UserDefaults rather than in `Profile.settings` so that managed
/// profiles — whose `settings` is part of a signed manifest — can remember
/// decisions without invalidating the signature. The same store backs
/// unmanaged profiles for symmetry.
public enum ProfilePrefs {
    /// The store. Bromure AC points it at its per-state settings (a decision
    /// remembered for a workspace belongs to the state the workspace is in).
    public static var defaults: UserDefaults = .standard

    public enum RestoreDecision: String {
        case restore
        case fresh
    }

    private static func key(_ id: UUID, _ suffix: String) -> String {
        "profilePrefs.\(id.uuidString.lowercased()).\(suffix)"
    }

    public static func restoreTabsDecision(for id: UUID) -> RestoreDecision? {
        guard let raw = defaults.string(forKey: key(id, "restoreTabs")) else {
            return nil
        }
        return RestoreDecision(rawValue: raw)
    }

    public static func setRestoreTabsDecision(_ decision: RestoreDecision?, for id: UUID) {
        let k = key(id, "restoreTabs")
        if let decision {
            defaults.set(decision.rawValue, forKey: k)
        } else {
            defaults.removeObject(forKey: k)
        }
    }

    public static func skipCloseConfirm(for id: UUID) -> Bool {
        defaults.bool(forKey: key(id, "skipCloseConfirm"))
    }

    public static func setSkipCloseConfirm(_ skip: Bool, for id: UUID) {
        let k = key(id, "skipCloseConfirm")
        if skip {
            defaults.set(true, forKey: k)
        } else {
            defaults.removeObject(forKey: k)
        }
    }

    /// Drop every remembered decision for a profile. Called when a profile
    /// is deleted (unmanaged) or revoked by the control plane (managed).
    public static func clear(for id: UUID) {
        defaults.removeObject(forKey: key(id, "restoreTabs"))
        defaults.removeObject(forKey: key(id, "skipCloseConfirm"))
    }
}
