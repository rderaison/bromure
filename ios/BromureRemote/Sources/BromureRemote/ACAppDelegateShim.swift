import Foundation

// MARK: - ACAppDelegate (iOS compile shim)
//
// On macOS, `ACAppDelegate` is the ~9k-line NSApplicationDelegate god object
// that owns the VMs, engines, and windows — none of which exist on the iOS
// fat client (the host runs all of that). The shared client code touches only
// three delegate members that are pure data/serialization helpers, with no VM
// or AppKit dependency, so on iOS we provide just those as a namespace. The
// host-only engines (CodingTaskEngine, ScheduledAutomationEngine) and the
// mac-only mirror window that reference the rest are all `#if os(macOS)`.

enum ACAppDelegate {
    /// Errors surfaced by guest exec / file ops. The fat-client controller
    /// throws these to describe a failed `/vms/{id}/exec` or `/file` round-trip;
    /// the file explorer distinguishes `.vmNotRunning`. Identical shape to the
    /// macOS delegate's nested enum.
    enum GuestExecError: LocalizedError {
        case vmNotRunning
        case connectionFailed
        case commandFailed(exitCode: Int, stderr: String)
        var errorDescription: String? {
            switch self {
            case .vmNotRunning: "The VM isn't running"
            case .connectionFailed: "Couldn't reach the VM's shell agent"
            case .commandFailed(let code, let stderr):
                stderr.isEmpty ? "Command failed (exit \(code))"
                               : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    /// A `docker run` request assembled by the Docker dashboard. The iOS Docker
    /// screen turns it into the `/vms/{id}/docker` run body; the fields match
    /// the macOS delegate's nested struct so `DockerDashboardView` builds it
    /// unchanged.
    struct DockerRunSpec {
        var image: String
        var name: String = ""
        var ports: [String] = []     // "8080:80"
        var env: [String] = []       // "KEY=val"
        var volumes: [String] = []   // "/host:/container"
        /// Pass the workspace's whole environment (API tokens, etc.) through.
        var inheritEnv: Bool = false
        /// Pass just the HTTP(S) proxy vars (covered by inheritEnv when set).
        var inheritProxy: Bool = false
        /// Run with a TTY (-it) in a fresh tmux tab instead of detached (-d).
        var interactive: Bool = false
    }

    /// JSON-dictionary encode a Codable (used to POST a whole `CodingTask` /
    /// `ScheduledAutomation` over the tunnel). Byte-identical to the macOS
    /// static helper, iso8601 dates included.
    static func codableToDict<T: Encodable>(_ value: T) -> [String: Any]? {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(value),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }
}
