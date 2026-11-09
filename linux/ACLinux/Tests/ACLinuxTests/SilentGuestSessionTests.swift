import Foundation
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// Under DaemonGlobalSuites: another suite's daemon (its liveness tick)
    /// sets the process-wide silent set (LinuxSessionHost.unresponsive).
    @Suite("A silent guest's sessions")
    @MainActor
    struct SilentGuestSessionTests {
        /// A running workspace whose guest went silent: its sessions read as
        /// asleep, not as what they last said (macOS: GuestLivenessStore).
        @Test func aSilentGuestsSessionsAreAsleep() async throws {
            let (h, d, dir) = try await SessionListModelTests.host()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let p = Profile(name: "silent", tool: .claude, authMode: .local)
            LinuxSessionHost.running.withLockedValue { $0.insert(p.id) }
            defer { LinuxSessionHost.running.withLockedValue { _ = $0.remove(p.id) } }
            let roster = TabsModel()
            roster.rosterLive = true
            h.refreshSidebar(workspaces: [.init(id: p.id, name: "silent", accentHex: "#000000", model: roster)], profiles: [p], machines: [])
            let s = SessionListModelTests.session(p.id)
            #expect(SessionHome.bucket(for: s, in: h.listModel) != .asleep, "up, its roster live")
            LinuxSessionHost.unresponsive.withLockedValue { $0.insert(p.id) }
            defer { LinuxSessionHost.unresponsive.withLockedValue { _ = $0.remove(p.id) } }
            #expect(SessionHome.bucket(for: s, in: h.listModel) == .asleep, "its guest silent")
            await d.shutdown()
        }
    }
}
