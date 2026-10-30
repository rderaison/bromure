import Foundation
import Testing
import ACLinux

/// Is the guest CID baked into a saved state? Suspend under one CID, restore
/// under another, and see which CID agentd dials from.
@Suite("Restore under a different vsock CID", .serialized, .enabled(if: Env.ready))
struct CIDChangeTests {
    @Test("the restored guest picks up the new CID (vhost-vsock transport reset re-reads guest_cid)")
    func restoreWithNewCID() async throws {
        let ws = try BootTests.Workspace(machine: .microvm)
        defer { ws.cleanUp() }
        let listener = try await VsockListener.shared(port: agentPort)
        let first = ConnQueue(await listener.connections(from: ws.cid))
        let vm = QEMUMachine(config: ws.config)
        try await vm.start()
        try #require(await next(first, timeout: .seconds(60)) != nil)
        let state = ws.dir + "/vm.state"
        try await vm.suspend(to: state)
        await listener.forget(cid: ws.cid)

        var moved = ws.config
        moved.vsockCID = try CIDAllocator.shared.allocate()
        defer { CIDAllocator.shared.release(moved.vsockCID) }
        let oldConns = ConnQueue(await listener.connections(from: ws.cid))
        let newConns = ConnQueue(await listener.connections(from: moved.vsockCID))
        let vm2 = QEMUMachine(config: moved)
        try await vm2.restore(from: state)
        let viaNew = await next(newConns, timeout: .seconds(20))
        let viaOld = await next(oldConns, timeout: .seconds(1))
        print("CIDCHANGE suspended as \(ws.cid), restored as \(moved.vsockCID): dial from new CID \(viaNew != nil), from old CID \(viaOld != nil)")
        #expect(viaNew != nil, "agentd never dialed from the new CID")
        #expect(viaOld == nil)
        await vm2.kill()
        await listener.forget(cid: moved.vsockCID)
        await listener.forget(cid: ws.cid)
    }
}
