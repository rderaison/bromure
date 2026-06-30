import Foundation
import Testing
@testable import bromure_ac

/// Host-scope matching for token swaps. `hostMatchesScope` is the
/// strict exact-or-subdomain check the swap path uses; the documented
/// security invariant is that it is NOT a substring match, so
/// `openai.com.evil.com` must never match scope `openai.com`.
/// `hostMatchesScopeFamily` is the relaxed sibling check used only by
/// compromise detection.
@Suite("Token swap host scoping")
struct TokenSwapHostScopeTests {

    // MARK: - strict hostMatchesScope

    @Test("Exact host matches its scope")
    func exactMatch() {
        #expect(TokenSwapper.hostMatchesScope(host: "openai.com", scope: "openai.com"))
        #expect(TokenSwapper.hostMatchesScope(host: "api.anthropic.com", scope: "api.anthropic.com"))
    }

    @Test("Subdomain matches its parent scope")
    func subdomainMatch() {
        #expect(TokenSwapper.hostMatchesScope(host: "api.openai.com", scope: "openai.com"))
        #expect(TokenSwapper.hostMatchesScope(host: "a.b.c.openai.com", scope: "openai.com"))
    }

    @Test("Matching is case-insensitive on both sides")
    func caseInsensitive() {
        #expect(TokenSwapper.hostMatchesScope(host: "OPENAI.COM", scope: "openai.com"))
        #expect(TokenSwapper.hostMatchesScope(host: "Api.OpenAI.com", scope: "OPENAI.COM"))
    }

    @Test("Substring-suffix attack does NOT match (the documented guard)")
    func substringAttackBlocked() {
        // The whole point of the guard: a VM CONNECTing to
        // openai.com.evil.com must not get the real OpenAI key injected.
        #expect(!TokenSwapper.hostMatchesScope(host: "openai.com.evil.com", scope: "openai.com"))
        #expect(!TokenSwapper.hostMatchesScope(host: "api.anthropic.com.attacker.net",
                                               scope: "api.anthropic.com"))
    }

    @Test("A host that merely ends in the scope label-set without a dot boundary does not match")
    func noFalsePrefixMatch() {
        // "notopenai.com" ends with "openai.com" as a substring but the
        // boundary check requires a literal "." before the scope.
        #expect(!TokenSwapper.hostMatchesScope(host: "notopenai.com", scope: "openai.com"))
        #expect(!TokenSwapper.hostMatchesScope(host: "myopenai.com", scope: "openai.com"))
    }

    @Test("Unrelated host does not match")
    func unrelated() {
        #expect(!TokenSwapper.hostMatchesScope(host: "evil.com", scope: "openai.com"))
        #expect(!TokenSwapper.hostMatchesScope(host: "anthropic.com", scope: "openai.com"))
    }

    // MARK: - relaxed hostMatchesScopeFamily

    @Test("Family match accepts a sibling subdomain under the same parent")
    func familySibling() {
        // mcp-tools.anthropic.com is a sibling of api.anthropic.com:
        // strip one label off the scope → anthropic.com → suffix match.
        #expect(TokenSwapper.hostMatchesScopeFamily(host: "mcp-tools.anthropic.com",
                                                    scope: "api.anthropic.com"))
        #expect(TokenSwapper.hostMatchesScopeFamily(host: "console.anthropic.com",
                                                    scope: "api.anthropic.com"))
    }

    @Test("Family match accepts the parent domain itself")
    func familyParent() {
        #expect(TokenSwapper.hostMatchesScopeFamily(host: "anthropic.com",
                                                    scope: "api.anthropic.com"))
    }

    @Test("Family match still satisfies a plain exact / subdomain hit")
    func familyExact() {
        #expect(TokenSwapper.hostMatchesScopeFamily(host: "api.anthropic.com",
                                                    scope: "api.anthropic.com"))
        #expect(TokenSwapper.hostMatchesScopeFamily(host: "a.api.anthropic.com",
                                                    scope: "api.anthropic.com"))
    }

    @Test("Family match refuses to collapse below three labels (no TLD-wide match)")
    func familyRefusesTLDCollapse() {
        // scope "example.com" has only 2 labels; stripping would give
        // "com" → must refuse, so an unrelated .com host never matches.
        #expect(!TokenSwapper.hostMatchesScopeFamily(host: "evil.com", scope: "example.com"))
        #expect(!TokenSwapper.hostMatchesScopeFamily(host: "other.org", scope: "example.com"))
    }

    @Test("Family match still blocks the substring-suffix attack")
    func familySubstringAttackBlocked() {
        #expect(!TokenSwapper.hostMatchesScopeFamily(host: "api.anthropic.com.evil.com",
                                                     scope: "api.anthropic.com"))
    }

    @Test("Two-label scope under family still matches its own subdomains")
    func familyTwoLabelSubdomain() {
        // example.com (2 labels): the strict pre-check handles real
        // subdomains, the family strip is what's refused.
        #expect(TokenSwapper.hostMatchesScopeFamily(host: "www.example.com", scope: "example.com"))
        #expect(TokenSwapper.hostMatchesScopeFamily(host: "example.com", scope: "example.com"))
    }
}
