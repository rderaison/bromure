import Foundation
import ServiceManagement

// MARK: - Privileged daemon install (SMAppService)

/// Registers the root tunnel daemon (`FatClientTunnelDaemon`) as a launchd daemon
/// via SMAppService. The first registration surfaces an approval toggle in System
/// Settings › General › Login Items; the app can't grant it, so callers fall back
/// to SOCKS/PAC until it's enabled.
enum FatClientTunnelInstaller {
    static let plistName = "io.bromure.fatclient-tunnel.plist"

    enum State {
        case enabled
        case requiresApproval
        case notRegistered
    }

    static var state: State {
        switch SMAppService.daemon(plistName: plistName).status {
        case .enabled:          return .enabled
        case .requiresApproval: return .requiresApproval
        default:                return .notRegistered
        }
    }

    enum RegisterOutcome: Equatable {
        case enabled
        case requiresApproval
        /// `register()` threw — nothing was added to Login Items, so waiting
        /// for an approval would wait forever. Carries the OS error text.
        case failed(String)
    }

    /// Registers the daemon if it's never been done; otherwise reports the
    /// current state. A thrown `register()` is surfaced (not swallowed) —
    /// callers must not send the user to Login Items in that case.
    @discardableResult
    static func ensureRegistered() -> RegisterOutcome {
        let svc = SMAppService.daemon(plistName: plistName)
        switch svc.status {
        case .enabled:
            return .enabled
        case .requiresApproval:
            FatClientLog.log("tunnel: daemon needs approval — System Settings › General › Login Items")
            return .requiresApproval
        default:
            do {
                try svc.register()
                FatClientLog.log("tunnel: daemon register requested (status=\(svc.status.rawValue))")
            } catch {
                FatClientLog.log("tunnel: SMAppService register failed: \(error)")
                return .failed(error.localizedDescription)
            }
            return svc.status == .enabled ? .enabled : .requiresApproval
        }
    }

    /// Take the user to the approval toggle (System Settings › General ›
    /// Login Items) — the one step the app cannot do for them.
    static func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Remove the daemon registration (feature turned off everywhere).
    static func unregister() {
        let svc = SMAppService.daemon(plistName: plistName)
        guard svc.status != .notRegistered else { return }
        svc.unregister { error in
            if let error {
                FatClientLog.log("tunnel: unregister failed: \(error)")
            } else {
                FatClientLog.log("tunnel: daemon unregistered")
            }
        }
    }
}
