import Foundation
import ServiceManagement

// MARK: - Privileged daemon install (SMAppService)

/// Registers the root tunnel daemon (`FatClientTunnelDaemon`) as a launchd daemon
/// via SMAppService. The first registration surfaces an approval toggle in System
/// Settings › General › Login Items; the app can't grant it, so callers fall back
/// to SOCKS/PAC until it's enabled.
enum FatClientTunnelInstaller {
    static let plistName = "io.bromure.fatclient-tunnel.plist"

    /// True once the daemon is registered AND enabled (running). Attempts a
    /// registration if it's never been done; otherwise reports the current state.
    @discardableResult
    static func ensureRegistered() -> Bool {
        let svc = SMAppService.daemon(plistName: plistName)
        switch svc.status {
        case .enabled:
            return true
        case .requiresApproval:
            FatClientLog.log("tunnel: daemon needs approval — System Settings › General › Login Items")
            return false
        default:
            do {
                try svc.register()
                FatClientLog.log("tunnel: daemon register requested (status=\(svc.status.rawValue))")
            } catch {
                FatClientLog.log("tunnel: SMAppService register failed: \(error)")
            }
            return svc.status == .enabled
        }
    }
}
