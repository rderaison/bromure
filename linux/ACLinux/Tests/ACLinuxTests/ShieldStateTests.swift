import Foundation
import Testing
@testable import ACLinux

/// The list's shield (macOS: refreshShieldState): a workspace with no
/// active egress policy runs unsandboxed.
@Suite("Shield state")
struct ShieldStateTests {
    @Test func aWorkspaceWithoutAnActivePolicyIsUnsandboxed() {
        let open = Profile(name: "open", tool: .claude, authMode: .token)
        var ruled = Profile(name: "ruled", tool: .claude, authMode: .token)
        ruled.egressRules = "deny all"
        #expect(!open.restrictsEgress && ruled.restrictsEgress)
        #expect(LinuxSessionHost.unsandboxedIDs([open, ruled]) == [open.id])
    }
}
