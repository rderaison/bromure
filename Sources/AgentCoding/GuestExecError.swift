import Foundation

/// Errors from `guestExec`: the macOS app's and the Linux daemon's (ACAppDelegate
/// keeps the name as a typealias).
enum GuestExecError: LocalizedError {
    case vmNotRunning
    /// The workspace is powered off — nothing to talk to until it boots.
    case vmOff
    /// The workspace is suspended (RAM saved to disk) — resume it first.
    case vmSuspended
    case connectionFailed
    case commandFailed(exitCode: Int, stderr: String)
    var errorDescription: String? {
        switch self {
        case .vmNotRunning: "The VM isn't running"
        case .vmOff: "The VM is off"
        case .vmSuspended: "The VM is suspended"
        case .connectionFailed: "Couldn't reach the VM's shell agent"
        case .commandFailed(let code, let stderr):
            stderr.isEmpty ? "Command failed (exit \(code))"
                           : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
