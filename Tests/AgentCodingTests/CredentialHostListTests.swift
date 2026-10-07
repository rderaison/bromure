import Foundation
import Testing
@testable import bromure_ac

/// Issue #39: adding a second host to an "Other API key" credential.
@Suite("Credential host lists")
struct CredentialHostListTests {
    @Test("Typed lists parse whatever the separators; a trailing separator is kept as typing")
    func parse() {
        #expect(HostListField.parse("google.com, postman-echo.com") == ["google.com", "postman-echo.com"])
        #expect(HostListField.parse("google.com,postman-echo.com") == ["google.com", "postman-echo.com"])
        #expect(HostListField.parse("google.com  postman-echo.com") == ["google.com", "postman-echo.com"])
        // Mid-typing: "google.com, " still parses to one host — the field
        // keeps its own text, so the separator survives for the next host.
        #expect(HostListField.parse("google.com, ") == ["google.com"])
        #expect(HostListField.parse("") == [])
    }

    @Test("Every listed host is its own swap scope")
    func scopes() {
        let t = ManualToken(name: "Sec2", realValue: "x", envVarName: "SEC2",
                            hostFilters: ["google.com", "postman-echo.com"])
        #expect(t.effectiveHostScopes == ["google.com", "postman-echo.com"])
    }

    @Test("A legacy single-host field holding a list decodes to every host")
    func legacyList() throws {
        let json = #"{"id":"\#(UUID().uuidString)","name":"Sec2","realValue":"x","envVarName":"SEC2","hostFilter":"google.com, postman-echo.com"}"#
        let t = try JSONDecoder().decode(ManualToken.self, from: Data(json.utf8))
        #expect(t.hostFilters == ["google.com", "postman-echo.com"])
    }
}
