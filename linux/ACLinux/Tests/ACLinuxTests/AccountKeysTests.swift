import Foundation
import Testing
@testable import ACLinux

/// The account key sync's tick (LinuxAccountKeys): 180 s ±10%, so servers
/// that started together don't all ask bromure.io at once.
@Suite("Account key sync")
struct AccountKeysTests {
    @Test func theTickIsJitteredWithinTenPercent() {
        let waits = (0..<2000).map { _ in LinuxAccountKeys.jittered(180) }
        #expect(waits.allSatisfy { $0 >= 162 && $0 <= 198 })
        #expect(Set(waits.map { Int($0) }).count > 20, "spread out, not one value")
        #expect(waits.contains { $0 < 171 } && waits.contains { $0 > 189 }, "both sides of 180")
    }
}
