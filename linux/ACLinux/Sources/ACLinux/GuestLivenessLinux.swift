import Foundation

/// The workspaces whose guest has gone silent, as macOS's GuestLivenessStore
/// answers the session engine: on a server, the set DaemonLiveness keeps
/// from the guests' heartbeats (LinuxSessionHost.unresponsive). No
/// force-reboot action here (that's the client's banner; it reboots through
/// the reboot route).
@MainActor
final class GuestLivenessStore {
    static let shared = GuestLivenessStore()

    // @port GuestLivenessStore.isUnresponsive(_: Profile.ID) h=a7bfd3a17bf5e7a0 @46ee4044
    func isUnresponsive(_ id: Profile.ID) -> Bool { LinuxSessionHost.unresponsive.withLockedValue { $0.contains(id) } }
}
