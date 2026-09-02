import Foundation
import Testing
@testable import bromure_ac

/// Depi secure-registry integration: host recognition, Bearer-key
/// injection, the auth-failure response the guest's npm sees, and
/// the `packageFilter` (None / socket.dev / Depi) policy plumbing
/// including legacy-profile decoding.
@Suite("Depi registry re-route")
struct DepiTests {

    // MARK: - Host recognition / classification

    @Test("shouldRoute matches npm registry hosts and the Depi host")
    func shouldRoute() {
        #expect(DepiRegistry.shouldRoute(host: "registry.npmjs.org"))
        #expect(DepiRegistry.shouldRoute(host: "something.npmjs.org"))
        #expect(DepiRegistry.shouldRoute(host: "depi-npm-proxy.landh.tech"))
        #expect(!DepiRegistry.shouldRoute(host: "pypi.org"))
        #expect(!DepiRegistry.shouldRoute(host: "registry.yarnpkg.com"))
        #expect(!DepiRegistry.shouldRoute(host: "landh.tech"))
    }

    @Test("Depi host classifies as npm — metadata")
    func depiHostMetadata() {
        guard case let .metadata(eco, pkg)? = SupplyChainRegistry.classify(
                host: "depi-npm-proxy.landh.tech", path: "/left-pad") else {
            Issue.record("expected .metadata")
            return
        }
        #expect(eco == .npm)
        #expect(pkg == "left-pad")
    }

    @Test("Depi host classifies as npm — artifact")
    func depiHostArtifact() {
        // Depi rewrites packument dist.tarball URLs to point at
        // itself, so the guest's tarball fetches arrive addressed to
        // the Depi host with npm's exact path shape.
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
        let out = DepiRegistry.authorize(rawRequest: raw, apiKey: "du_test123")
        let text = String(decoding: out, as: UTF8.self)
        #expect(text.contains("Authorization: Bearer du_test123\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }

    @Test("authorize replaces a guest Authorization header instead of leaking it")
    func authorizeReplaces() {
        let raw = Data("GET /left-pad HTTP/1.1\r\nHost: registry.npmjs.org\r\nAuthorization: Bearer npm_guestToken\r\n\r\nBODY".utf8)
        let out = DepiRegistry.authorize(rawRequest: raw, apiKey: "du_test123")
        let text = String(decoding: out, as: UTF8.self)
        #expect(text.contains("Authorization: Bearer du_test123"))
        #expect(!text.contains("npm_guestToken"))
        #expect(text.hasSuffix("BODY"))   // body untouched
    }

    // MARK: - Auth-failure response

    @Test("authFailureResponse keeps the status and explains the fix")
    func authFailureBody() {
        let resp = String(decoding: DepiRegistry.authFailureResponse(status: 401),
                          as: UTF8.self)
        #expect(resp.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        #expect(resp.contains("X-Bromure-Block: depi-auth"))
        #expect(resp.contains("Depi registry rejected the configured API key"))
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
        #expect(!p.depiActive)
    }

    @Test("depiActive requires both the selection and a key")
    func depiActiveGate() {
        var p = SupplyChainPolicy()
        p.packageFilter = .depi
        #expect(!p.depiActive)             // no key yet
        p.depiAPIKey = "du_x"
        #expect(p.depiActive)
        #expect(!p.socketActive)            // mutually exclusive
        p.packageFilter = .socketDev
        #expect(!p.depiActive)             // key kept, provider deselected
    }

    @Test("Selecting Depi turns socket.dev off even with key + toggles set")
    func exclusivity() {
        let p = SupplyChainPolicy(packageFilter: .depi,
                                  socketAPIKey: "sk",
                                  socketBlockCompromised: true,
                                  depiAPIKey: "du_x")
        #expect(p.depiActive)
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

    @Test("Depi selection + key round-trips through Codable")
    func depiRoundTrip() throws {
        let p = SupplyChainPolicy(packageFilter: .depi, depiAPIKey: "du_secret")
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(SupplyChainPolicy.self, from: data)
        #expect(back == p)
        #expect(back.depiActive)
    }

    @Test("Pre-rename profile JSON (\"delpi\" / \"delpiAPIKey\") still loads as .depi")
    func legacyDepiSpellingDecodes() throws {
        // A profile written before the Delpi→Depi rename: the on-disk enum value
        // is "delpi" and the key lives under "delpiAPIKey". Both must still load
        // (the case rawValue and CodingKey are pinned to the old spelling).
        let json = #"{"packageFilter":"delpi","delpiAPIKey":"du_secret"}"#
        let p = try JSONDecoder().decode(SupplyChainPolicy.self, from: Data(json.utf8))
        #expect(p.packageFilter == .depi)
        #expect(p.depiAPIKey == "du_secret")
        #expect(p.depiActive)
        // Re-encoding keeps the on-disk spelling stable (no silent migration).
        let obj = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(p)) as? [String: Any]
        #expect(obj?["packageFilter"] as? String == "delpi")
        #expect(obj?["delpiAPIKey"] as? String == "du_secret")
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

    @Test("isActive: Depi alone doesn't count as an enforcement layer")
    func isActiveWithoutDepi() {
        // The re-route is a routing decision the proxy makes on
        // depiActive directly; the enforcement hot path shouldn't
        // engage for it when every other layer is off.
        let p = SupplyChainPolicy(ageGateEnabled: false,
                                  packageFilter: .depi,
                                  depiAPIKey: "du_x")
        #expect(p.depiActive)
        #expect(!p.isActive)
    }
}
