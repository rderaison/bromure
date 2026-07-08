import Foundation
import Testing
@testable import bromure_ac

/// Delpi secure-registry integration: host recognition, Bearer-key
/// injection, the auth-failure response the guest's npm sees, and
/// the `packageFilter` (None / socket.dev / Delpi) policy plumbing
/// including legacy-profile decoding.
@Suite("Delpi registry re-route")
struct DelpiTests {

    // MARK: - Host recognition / classification

    @Test("shouldRoute matches npm registry hosts and the Delpi host")
    func shouldRoute() {
        #expect(DelpiRegistry.shouldRoute(host: "registry.npmjs.org"))
        #expect(DelpiRegistry.shouldRoute(host: "something.npmjs.org"))
        #expect(DelpiRegistry.shouldRoute(host: "depi-npm-proxy.landh.tech"))
        #expect(!DelpiRegistry.shouldRoute(host: "pypi.org"))
        #expect(!DelpiRegistry.shouldRoute(host: "registry.yarnpkg.com"))
        #expect(!DelpiRegistry.shouldRoute(host: "landh.tech"))
    }

    @Test("Delpi host classifies as npm — metadata")
    func delpiHostMetadata() {
        guard case let .metadata(eco, pkg)? = SupplyChainRegistry.classify(
                host: "depi-npm-proxy.landh.tech", path: "/left-pad") else {
            Issue.record("expected .metadata")
            return
        }
        #expect(eco == .npm)
        #expect(pkg == "left-pad")
    }

    @Test("Delpi host classifies as npm — artifact")
    func delpiHostArtifact() {
        // Delpi rewrites packument dist.tarball URLs to point at
        // itself, so the guest's tarball fetches arrive addressed to
        // the Delpi host with npm's exact path shape.
        guard case let .artifact(eco, pkg, ver)? = SupplyChainRegistry.classify(
                host: "depi-npm-proxy.landh.tech",
                path: "/left-pad/-/left-pad-1.3.0.tgz") else {
            Issue.record("expected .artifact")
            return
        }
        #expect(eco == .npm)
        #expect(pkg == "left-pad")
        #expect(ver == "1.3.0")
    }

    // MARK: - Bearer-key injection

    @Test("authorize adds a Bearer header when none is present")
    func authorizeAdds() {
        let raw = Data("GET /left-pad HTTP/1.1\r\nHost: registry.npmjs.org\r\nAccept: */*\r\n\r\n".utf8)
        let out = DelpiRegistry.authorize(rawRequest: raw, apiKey: "du_test123")
        let text = String(decoding: out, as: UTF8.self)
        #expect(text.contains("Authorization: Bearer du_test123\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }

    @Test("authorize replaces a guest Authorization header instead of leaking it")
    func authorizeReplaces() {
        let raw = Data("GET /left-pad HTTP/1.1\r\nHost: registry.npmjs.org\r\nAuthorization: Bearer npm_guestToken\r\n\r\nBODY".utf8)
        let out = DelpiRegistry.authorize(rawRequest: raw, apiKey: "du_test123")
        let text = String(decoding: out, as: UTF8.self)
        #expect(text.contains("Authorization: Bearer du_test123"))
        #expect(!text.contains("npm_guestToken"))
        #expect(text.hasSuffix("BODY"))   // body untouched
    }

    // MARK: - Auth-failure response

    @Test("authFailureResponse keeps the status and explains the fix")
    func authFailureBody() {
        let resp = String(decoding: DelpiRegistry.authFailureResponse(status: 401),
                          as: UTF8.self)
        #expect(resp.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        #expect(resp.contains("X-Bromure-Block: delpi-auth"))
        #expect(resp.contains("Delpi registry rejected the configured API key"))
        #expect(resp.contains("Supply Chain settings"))
        // Content-Length must match the actual body.
        let parts = resp.components(separatedBy: "\r\n\r\n")
        #expect(parts.count == 2)
        let declared = resp.components(separatedBy: "\r\n")
            .first { $0.hasPrefix("Content-Length:") }?
            .dropFirst("Content-Length:".count)
            .trimmingCharacters(in: .whitespaces)
        #expect(declared == String(parts[1].utf8.count))
    }

    // MARK: - packageFilter policy plumbing

    @Test("Default policy: no provider, nothing active")
    func defaultPolicy() {
        let p = SupplyChainPolicy()
        #expect(p.packageFilter == SupplyChainPolicy.PackageFilter.none)
        #expect(!p.socketActive)
        #expect(!p.delpiActive)
    }

    @Test("delpiActive requires both the selection and a key")
    func delpiActiveGate() {
        var p = SupplyChainPolicy()
        p.packageFilter = .delpi
        #expect(!p.delpiActive)             // no key yet
        p.delpiAPIKey = "du_x"
        #expect(p.delpiActive)
        #expect(!p.socketActive)            // mutually exclusive
        p.packageFilter = .socketDev
        #expect(!p.delpiActive)             // key kept, provider deselected
    }

    @Test("Selecting Delpi turns socket.dev off even with key + toggles set")
    func exclusivity() {
        let p = SupplyChainPolicy(packageFilter: .delpi,
                                  socketAPIKey: "sk",
                                  socketBlockCompromised: true,
                                  delpiAPIKey: "du_x")
        #expect(p.delpiActive)
        #expect(!p.socketActive)
    }

    @Test("Legacy profile JSON (socket key, no packageFilter) infers socket.dev")
    func legacyDecodeInference() throws {
        let json = #"{"socketAPIKey":"sk_legacy","socketBlockCompromised":true}"#
        let p = try JSONDecoder().decode(SupplyChainPolicy.self, from: Data(json.utf8))
        #expect(p.packageFilter == .socketDev)
        #expect(p.socketActive)
    }

    @Test("Explicit packageFilter=none survives decoding despite a stored socket key")
    func explicitNoneDecode() throws {
        let json = #"{"packageFilter":"none","socketAPIKey":"sk_legacy","socketBlockCompromised":true}"#
        let p = try JSONDecoder().decode(SupplyChainPolicy.self, from: Data(json.utf8))
        #expect(p.packageFilter == SupplyChainPolicy.PackageFilter.none)
        #expect(!p.socketActive)
    }

    @Test("Unknown packageFilter value degrades to the legacy inference")
    func unknownFilterDecode() throws {
        let json = #"{"packageFilter":"futureProvider","socketAPIKey":"sk"}"#
        let p = try JSONDecoder().decode(SupplyChainPolicy.self, from: Data(json.utf8))
        #expect(p.packageFilter == .socketDev)
    }

    @Test("Delpi selection + key round-trips through Codable")
    func delpiRoundTrip() throws {
        let p = SupplyChainPolicy(packageFilter: .delpi, delpiAPIKey: "du_secret")
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(SupplyChainPolicy.self, from: data)
        #expect(back == p)
        #expect(back.delpiActive)
    }

    @Test("Explicit None with a socket key round-trips (encoder pins the choice)")
    func noneWithKeyRoundTrip() throws {
        let p = SupplyChainPolicy(packageFilter: SupplyChainPolicy.PackageFilter.none,
                                  socketAPIKey: "sk",
                                  socketBlockCompromised: true)
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(SupplyChainPolicy.self, from: data)
        #expect(back.packageFilter == SupplyChainPolicy.PackageFilter.none)
        #expect(!back.socketActive)
    }

    @Test("Legacy-inferable socket selection stays byte-stable (no packageFilter key)")
    func legacyEncodeSparse() throws {
        let p = SupplyChainPolicy(socketAPIKey: "sk", socketBlockCompromised: true)
        #expect(p.packageFilter == .socketDev)   // inferred by init
        let data = try JSONEncoder().encode(p)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("packageFilter"))
    }

    @Test("isActive: Delpi alone doesn't count as an enforcement layer")
    func isActiveWithoutDelpi() {
        // The re-route is a routing decision the proxy makes on
        // delpiActive directly; the enforcement hot path shouldn't
        // engage for it when every other layer is off.
        let p = SupplyChainPolicy(ageGateEnabled: false,
                                  packageFilter: .delpi,
                                  delpiAPIKey: "du_x")
        #expect(p.delpiActive)
        #expect(!p.isActive)
    }
}
