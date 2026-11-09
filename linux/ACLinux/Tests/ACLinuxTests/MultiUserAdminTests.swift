import Testing
@testable import ACLinux

@Suite("Multi-user admin")
struct MultiUserAdminTests {
    /// A user's runtime dir is /run/bromure-ac/<name>: never one of the
    /// shared ones, nor a name the system's tools would take for an option.
    @Test func reservedNamesAreRefused() {
        for bad in ["", "sock", "root", "bromure", "-x", "Upper", "a/b", "..", String(repeating: "a", count: 33)] {
            #expect(!MultiUserAdmin.validName(bad), "\(bad)")
        }
        for good in ["alice", "bob_2", "c-d", "socks"] { #expect(MultiUserAdmin.validName(good), "\(good)") }
    }
}
