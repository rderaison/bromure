@testable import ACLinux
import Foundation
import Testing

/// Where the CLI looks for its daemon: the override, its own daemon's
/// socket, else a multi-user server's socket unit for this user.
@Suite("CLI daemon socket")
struct ClientSocketPathTests {
    let own = "/run/user/1000/bromure-ac/control.sock"
    let multi = "/run/bromure-ac/sock/alice.sock"

    @Test func theOverrideWins() {
        #expect(DaemonConfig.clientSocketPath(override: "/x.sock", own: own, multiUser: multi, exists: { _ in true }) == "/x.sock")
    }

    @Test func itsOwnDaemonFirst() {
        #expect(DaemonConfig.clientSocketPath(override: nil, own: own, multiUser: multi, exists: { _ in true }) == own)
    }

    @Test func aMultiUserServersSocketUnit() {
        #expect(DaemonConfig.clientSocketPath(override: nil, own: own, multiUser: multi, exists: { $0 == multi }) == multi)
    }

    @Test func neitherIsItsOwn() {
        #expect(DaemonConfig.clientSocketPath(override: nil, own: own, multiUser: multi, exists: { _ in false }) == own)
        #expect(DaemonConfig.clientSocketPath(override: nil, own: own, multiUser: nil, exists: { _ in false }) == own)
    }

    @Test func aMissingFileIsRecognized() {
        #expect(Daemon.isFileMissing(CocoaError(.fileReadNoSuchFile)))
        #expect(Daemon.isFileMissing(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))))
        #expect(!Daemon.isFileMissing(CocoaError(.fileReadNoPermission)))
    }
}
