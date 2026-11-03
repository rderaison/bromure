import Foundation
import Testing
@testable import bromure_ac

/// Finding (CWE-284): "1Password refresh collapses shared OpenShell
/// placeholders and blanks the other credential". With OpenShell credential
/// placeholders every credential exporting one env var shares one fake
/// (`openshell:resolve:env:VAR`). The refresher replaced EVERY entry with
/// that fake and host by one entry holding its secret (blank while `op` ran):
/// the other credential's secret was gone, the survivor kept the first
/// entry's consent and paths, and two `op://` values on the fake overwrote
/// each other on every tick. It now writes only its own reference's entries,
/// in place.
@Suite("1Password refresh: one credential's entries only")
struct OnePasswordSharedPlaceholderTests {
    static let fake = "openshell:resolve:env:GITHUB_TOKEN"

    @Test("a literal and two op:// credentials on one placeholder each keep their own value, consent, paths and order")
    @MainActor func sharedPlaceholder() async throws {
        let swapper = TokenSwapper(consent: ConsentBroker())
        let pid = UUID()
        swapper.setMap(TokenMap(entries: [
            TokenMap.Entry(fake: Self.fake, real: "ghp_literal", host: "api.github.com",
                           consentCredentialID: "manual:lit", paths: ["/user"]),
            TokenMap.Entry(fake: Self.fake, real: "op://vault/a/token", host: "api.github.com",
                           consentCredentialID: "manual:a", paths: ["/repos/a/**"]),
            TokenMap.Entry(fake: Self.fake, real: "op://vault/b/token", host: "api.github.com",
                           consentCredentialID: "manual:b", paths: ["/repos/b/**"]),
        ]), for: pid)
        let loop = OnePasswordRefresher(read: { ref in ref == "op://vault/a/token" ? "secret-a" : "secret-b" })
        let refs = OnePasswordRefresher.refs(in: swapper.entries(for: pid))
        #expect(refs.count == 2)

        // Started: only the op:// entries are blanked; the literal still works.
        loop.start(profileID: pid, refs: refs, swapper: swapper)
        var now = swapper.entries(for: pid)
        #expect(now.count == 3)
        #expect(now[0].real == "ghp_literal" && now[0].consentCredentialID == "manual:lit")

        for _ in 0..<200 where swapper.entries(for: pid).contains(where: { $0.real.isEmpty }) {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        loop.stop(profileID: pid)
        now = swapper.entries(for: pid)
        #expect(now.map(\.real) == ["ghp_literal", "secret-a", "secret-b"])
        #expect(now.map(\.consentCredentialID) == ["manual:lit", "manual:a", "manual:b"])
        #expect(now.map(\.paths) == [["/user"], ["/repos/a/**"], ["/repos/b/**"]])
        #expect(now.map(\.resolvedFrom) == [nil, "op://vault/a/token", "op://vault/b/token"])

        // A restart (a live push) leaves resolved secrets, and blanks nothing else.
        loop.start(profileID: pid, refs: refs, swapper: swapper)
        loop.stop(profileID: pid)
        #expect(swapper.entries(for: pid).map(\.real) == ["ghp_literal", "secret-a", "secret-b"])
    }

    @Test("the live merge carries an op:// value's own secret, not another credential's on the same fake")
    func liveMergeOwnSecret() {
        let current = [
            TokenMap.Entry(fake: Self.fake, real: "ghp_literal", host: "github.com"),
            TokenMap.Entry(fake: Self.fake, real: "secret-a", host: "github.com", resolvedFrom: "op://vault/a/token"),
        ]
        let fresh = [
            TokenMap.Entry(fake: Self.fake, real: "ghp_literal", host: "github.com"),
            TokenMap.Entry(fake: Self.fake, real: "op://vault/a/token", host: "github.com"),
        ]
        let merged = TokenMap.liveMerge(fresh: fresh, current: current).entries
        #expect(merged.map(\.real) == ["ghp_literal", "secret-a"])
    }

    @Test("an entry a live save dropped isn't brought back by a late read")
    @MainActor func droppedEntryStaysGone() async throws {
        let swapper = TokenSwapper(consent: ConsentBroker())
        let pid = UUID()
        swapper.setMap(TokenMap(entries: [
            TokenMap.Entry(fake: Self.fake, real: "op://vault/a/token", host: "github.com"),
        ]), for: pid)
        let refs = OnePasswordRefresher.refs(in: swapper.entries(for: pid))
        swapper.setMap(TokenMap(entries: [TokenMap.Entry(fake: Self.fake, real: "ghp_literal", host: "github.com")]), for: pid)
        let loop = OnePasswordRefresher(read: { _ in "secret-a" })
        loop.start(profileID: pid, refs: refs, swapper: swapper)
        try await Task.sleep(nanoseconds: 100_000_000)
        loop.stop(profileID: pid)
        #expect(swapper.entries(for: pid).map(\.real) == ["ghp_literal"])
    }
}
