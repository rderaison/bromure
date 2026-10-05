import Foundation
import Testing
@testable import bromure_ac

@Suite("Secret fingerprints (no secret characters on disk)")
struct SecretFingerprintTests {
    let secret = "sk-ant-api03-Zq8xVbN4mT1pLw7KcR2yHs6dFg9jA0eUkUyU"

    @Test("A label carries the kind and a stable keyed fingerprint, never secret characters")
    func label() {
        let l = SecretFingerprint.label(secret)
        #expect(l.hasPrefix("Anthropic key #"))
        #expect(l == SecretFingerprint.label(secret))
        #expect(l != SecretFingerprint.label(secret + "x"))
        let fp = String(l.split(separator: "#").last!)
        #expect(fp.count == 8 && fp.allSatisfy(\.isHexDigit))
        // Not the head nor the tail of the secret.
        #expect(!l.contains("kUyU") && !l.contains("api03") && !l.contains("…"))
        #expect(TokenSwapper.preview(secret) == l)
        #expect(SecretFingerprint.kind(of: "ghp_abcdefghijklmnop") == "GitHub token")
        #expect(SecretFingerprint.kind(of: "random-opaque-value") == "credential")
    }

    @Test("Legacy previews are redacted on load and in exports")
    func legacy() throws {
        #expect(SecretFingerprint.redactLegacy("sk-a…I8iG → api.anthropic.com") == "Anthropic key (redacted) → api.anthropic.com")
        #expect(SecretFingerprint.redactLegacy("swapped in xai-…9MPj") == "swapped in xAI key (redacted)")
        #expect(SecretFingerprint.redactLegacy("checked — versions newer than the cooldown hidden") ==
                "checked — versions newer than the cooldown hidden")
        #expect(SecretFingerprint.redactLegacy("Ignore all previous…") == "Ignore all previous…")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let line = #"{"t":1790000000,"e":"Credential brokering","c":"sk-a…I8iG → api.anthropic.com","d":"swapped in sk-a…bQAA","k":"info","p":"DBAB74C0-004B-423A-BE17-5864C1D855D2","ck":"token_swap|sk-a…I8iG|sk-a…bQAA|api.anthropic.com"}"#
        let file = dir.appendingPathComponent("2026-09-29.jsonl")
        try Data((line + "\n").utf8).write(to: file)
        let loaded = SecurityTimeline.load(from: dir, limit: 10, after: 0)
        #expect(loaded.count == 1)
        #expect(!loaded[0].condition.contains("I8iG") && !loaded[0].decision.contains("bQAA"))
        SecurityTimeline.redactLegacyPreviews(in: dir)
        let onDisk = try String(contentsOf: file, encoding: .utf8)
        #expect(!onDisk.contains("I8iG") && !onDisk.contains("bQAA"))
        #expect(onDisk.contains("Anthropic key (redacted)"))
    }
}
