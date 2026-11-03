import Foundation
import NIOConcurrencyHelpers

// Stand-ins for the bits of bromure-ac the shared SSH server sources
// (_shared/RemoteAccessServer.swift, _shared/RemoteSSHHandlers.swift) reach
// for, as Sources/AgentHost/Shims.swift provides them for the agent host.

/// Where the shared server finds the control socket (and, beside it, its
/// `remote/` key directory). The daemon sets it before starting the server.
// @port-skip linux-only: stand-in for the macOS ProfileStore's control socket path
struct ProfileStore {
    static let controlSocket = NIOLockedValueBox<URL?>(nil)
    // @port-skip linux-only: stand-in
    var controlSocketURL: URL {
        Self.controlSocket.withLockedValue { $0 }
            ?? URL(fileURLWithPath: (ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] ?? NSTemporaryDirectory())
                + "/bromure-ac/control.sock")
    }
}

/// The server's audit breadcrumbs go to the daemon's log.
// @port-skip linux-only: stand-in for the macOS MITM supply-chain log
final class SupplyChainLog: Sendable {
    static let shared = SupplyChainLog()
    // @port-skip linux-only: stand-in
    func record(_ line: String) { FileHandle.standardError.write(Data("bromure-ac daemon: \(line)\n".utf8)) }
}
