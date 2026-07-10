import Foundation
import Testing
@testable import bromure_ac

/// Covers the secret-preservation merge behind the headless `PUT /profiles/{id}`
/// update: a profile document round-tripped through describe/export comes back
/// with blank secrets, so the update must keep the stored secret unless the
/// caller supplied a replacement. This mirrors `automationUpsertProfile`'s
/// extract → overlay → apply step exactly.
@Suite("Profile secret preservation on headless update")
struct ProfileSecretPreservationTests {

    /// Reproduce the update merge: `existing` is the on-disk (secret-bearing)
    /// profile; `incoming` is the edited document. Returns the profile that
    /// would be saved.
    private func merged(existing: Profile, incoming: Profile) -> Profile {
        var incoming = incoming
        var existingCopy = existing
        let existingSecrets = ProfileSecrets.extract(stripping: &existingCopy)
        var incomingCopy = incoming
        let incomingSecrets = ProfileSecrets.extract(stripping: &incomingCopy)
        var merged = existingSecrets
        merged.overlay(with: incomingSecrets)
        merged.apply(to: &incoming)
        return incoming
    }

    @Test("Blank secrets in the edit keep the stored values")
    func blankKeepsSecrets() {
        var existing = Profile(name: "ws", tool: .claude, authMode: .token, apiKey: "sk-ant-REAL")
        existing.digitalOceanToken = "do-REAL"
        existing.linearToken = "lin_api_REAL"
        existing.awsCredentials.secretAccessKey = "aws-REAL"

        // The edited document changed a non-secret field but left secrets blank
        // (as describe/export hands them back).
        var incoming = existing
        incoming.apiKey = nil
        incoming.digitalOceanToken = ""
        incoming.linearToken = ""
        incoming.awsCredentials.secretAccessKey = ""
        incoming.memoryGB = 16   // the actual edit

        let out = merged(existing: existing, incoming: incoming)
        #expect(out.apiKey == "sk-ant-REAL")
        #expect(out.digitalOceanToken == "do-REAL")
        #expect(out.linearToken == "lin_api_REAL")
        #expect(out.awsCredentials.secretAccessKey == "aws-REAL")
        #expect(out.memoryGB == 16)
    }

    @Test("A supplied secret replaces the stored one")
    func suppliedReplacesSecret() {
        let existing = Profile(name: "ws", tool: .claude, authMode: .token, apiKey: "sk-ant-OLD")
        var incoming = existing
        incoming.apiKey = "sk-ant-NEW"

        let out = merged(existing: existing, incoming: incoming)
        #expect(out.apiKey == "sk-ant-NEW")
    }

    @Test("Git HTTPS tokens preserve per-credential by id")
    func gitTokenPreservedById() {
        var existing = Profile(name: "ws", tool: .claude, authMode: .token)
        let cred = GitHTTPSCredential(host: "github.com", username: "me", token: "ghp-REAL")
        existing.gitHTTPSCredentials = [cred]

        // Same credential id, blank token (round-tripped).
        var incoming = existing
        incoming.gitHTTPSCredentials = [{
            var c = cred; c.token = ""; return c
        }()]

        let out = merged(existing: existing, incoming: incoming)
        #expect(out.gitHTTPSCredentials.first?.token == "ghp-REAL")
    }
}
