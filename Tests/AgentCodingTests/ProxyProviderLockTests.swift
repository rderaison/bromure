import Foundation
import Testing
@testable import bromure_ac

// The proxy's static providers are replaced at every session's register
// while other sessions' connections read them. Unlocked, a read in the
// middle of a replace could free the replaced closure twice (a crash).

@Suite("Proxy provider lock", .serialized)
struct ProxyProviderLockTests {
    final class Engine: @unchecked Sendable { let engaged = Bool.random() }

    @Test("a provider replaced as register does, read meanwhile from other threads")
    func replacedWhileRead() async {
        let saved = HTTPMitmConnection.fusionEngagedProvider
        defer { HTTPMitmConnection.fusionEngagedProvider = saved }
        let stop = Date().addingTimeInterval(2)
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<8 {
                g.addTask {
                    let id = UUID()
                    while Date() < stop { _ = HTTPMitmConnection.fusionEngagedProvider?(id) }
                }
            }
            g.addTask {
                while Date() < stop {
                    let e = Engine()
                    HTTPMitmConnection.fusionEngagedProvider = { [weak e] _ in e?.engaged ?? false }
                }
            }
        }
        let e = Engine()
        HTTPMitmConnection.fusionEngagedProvider = { _ in e.engaged }
        #expect(HTTPMitmConnection.fusionEngagedProvider?(UUID()) == e.engaged, "the last one set is what's read")
    }
}
