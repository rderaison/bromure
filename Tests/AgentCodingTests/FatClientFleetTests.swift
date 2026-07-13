import Foundation
import Testing
@testable import bromure_ac

@Suite("FatClientFleet")
struct FatClientFleetTests {
    private let hostA = UUID()
    private let hostB = UUID()
    private let hostC = UUID()

    @Test("canonical zeroes host bits")
    func canon() {
        #expect(FleetRouter.canonical("192.168.64.5/24") == "192.168.64.0/24")
        #expect(FleetRouter.canonical("10.1.2.3/8") == "10.0.0.0/8")
        #expect(FleetRouter.canonical("nonsense") == nil)
    }

    @Test("single remote routes literally")
    func single() {
        let routes = FleetRouter.assign(
            remotes: [.init(hostID: hostA, cidr: "192.168.64.0/24")], localInUse: [])
        #expect(routes.count == 1)
        #expect(routes[0].aliased == false)
        #expect(routes[0].localCIDR == "192.168.64.0/24")
    }

    @Test("first-come keeps literal, collider is aliased")
    func collision() {
        let routes = FleetRouter.assign(remotes: [
            .init(hostID: hostA, cidr: "192.168.64.0/24"),
            .init(hostID: hostB, cidr: "192.168.64.0/24"),   // same subnet → alias
            .init(hostID: hostC, cidr: "192.168.63.0/24"),   // free → literal
        ], localInUse: [])
        #expect(routes[0].aliased == false && routes[0].localCIDR == "192.168.64.0/24")
        #expect(routes[1].aliased == true && routes[1].localCIDR == "100.64.1.0/24")
        #expect(routes[2].aliased == false && routes[2].localCIDR == "192.168.63.0/24")
    }

    @Test("a subnet already used locally forces an alias")
    func localCollision() {
        let routes = FleetRouter.assign(
            remotes: [.init(hostID: hostA, cidr: "192.168.64.10/24")],
            localInUse: ["192.168.64.0/24"])   // B's own vmnet
        #expect(routes[0].aliased == true)
        #expect(routes[0].localCIDR == "100.64.1.0/24")
    }

    @Test("alias octets are distinct and skip locally-used 100.64 space")
    func aliasOctets() {
        let routes = FleetRouter.assign(remotes: [
            .init(hostID: hostA, cidr: "192.168.64.0/24"),
            .init(hostID: hostB, cidr: "192.168.64.0/24"),
            .init(hostID: hostC, cidr: "192.168.64.0/24"),
        ], localInUse: ["100.64.1.0/24"])   // alias octet 1 taken locally
        #expect(routes[0].aliased == false)
        #expect(routes[1].localCIDR == "100.64.2.0/24")   // skips 1
        #expect(routes[2].localCIDR == "100.64.3.0/24")
    }

    @Test("tunnel aliasToRemote maps the alias back to the remote net")
    func aliasToRemote() {
        // Aliased route: a local process hit 100.64.2.7 → dial the remote's real 192.168.64.7.
        #expect(FatClientTunnel.aliasToRemote("100.64.2.7", remoteCIDR: "192.168.64.0/24") == "192.168.64.7")
        // Literal route (remoteCIDR nil) → unchanged.
        #expect(FatClientTunnel.aliasToRemote("192.168.64.7", remoteCIDR: nil) == "192.168.64.7")
    }

    @Test("remap is identity for literal, host-preserving swap for aliased")
    func remap() {
        let literal = FleetRouter.Route(hostID: hostA, remoteCIDR: "192.168.64.0/24",
                                        localCIDR: "192.168.64.0/24", aliased: false)
        #expect(FleetRouter.remap(address: "192.168.64.7", route: literal) == "192.168.64.7")

        let aliased = FleetRouter.Route(hostID: hostB, remoteCIDR: "192.168.64.0/24",
                                        localCIDR: "100.64.2.0/24", aliased: true)
        #expect(FleetRouter.remap(address: "192.168.64.7", route: aliased) == "100.64.2.7")
        // Out-of-subnet address isn't remapped (returns nil).
        #expect(FleetRouter.remap(address: "10.0.0.1", route: aliased) == nil)
    }
}
