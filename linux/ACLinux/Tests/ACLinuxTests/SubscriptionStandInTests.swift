import Foundation
import Testing
@testable import ACLinux

/// Grok's and Kimi's stand-in files in the home seed (macOS:
/// seedGrokAuthFile / seedKimiAuthFile, through the shared
/// SubscriptionStandInFiles): the captured shape, stand-ins the proxy
/// knows, never the real values; nothing for a workspace not on a
/// subscription.
@Suite("Subscription stand-in files")
struct SubscriptionStandInTests {
    /// A JWT-shaped value (header.payload.signature), as Grok's access token is.
    static func jwt(_ sub: String) -> String {
        func b64(_ s: String) -> String {
            Data(s.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        return b64(#"{"alg":"RS256","typ":"JWT"}"#) + "." + b64(#"{"sub":"\#(sub)","exp":4102444800}"#) + "." + b64("real-signature-\(sub)")
    }

    @Test func grokAndKimiStandInsAreSeeded() async throws {
        let (d, _, dir) = try await DaemonRepairGateTests.daemon()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let mitm = try #require(await d.mitm)
        let realGrok = Self.jwt("grok-user"), realKimi = "kimi-REAL-access-" + UUID().uuidString
        let grok = Profile(name: "g", tool: .grok, authMode: .subscription)
        let template = try JSONSerialization.data(withJSONObject: ["auth_mode": "oidc", "team_name": "t", "key": realGrok])
        try mitm.grokStore.setOverride(GrokSubscriptionRecord(accessToken: realGrok, refreshToken: "grok-REAL-refresh",
                                                              expiresAt: Date().addingTimeInterval(3600), savedAt: Date(),
                                                              templateJSON: template), for: grok.id)
        let kimi = Profile(name: "k", tool: .kimi, authMode: .subscription)
        try mitm.kimiStore.setOverride(KimiSubscriptionRecord(accessToken: realKimi, refreshToken: "kimi-REAL-refresh",
                                                              expiresAt: Date().addingTimeInterval(3600), savedAt: Date(),
                                                              credentialName: "managed"), for: kimi.id)
        let home = URL(fileURLWithPath: dir + "/home", isDirectory: true)

        await d.seedGrokAuthFile(for: grok, homeRoot: home)
        let grokFile = home.appendingPathComponent(".grok/auth.json")
        let grokText = try String(contentsOf: grokFile, encoding: .utf8)
        let doc = try #require(try JSONSerialization.jsonObject(with: Data(grokText.utf8)) as? [String: [String: Any]])
        let entry = try #require(doc.values.first)
        let key = try #require(entry["key"] as? String)
        #expect(key != realGrok && key.split(separator: ".").count == 3, "a JWT-shaped stand-in")
        #expect(mitm.grokStore.profileForBogusKey(key) == grok.id, "the proxy knows it")
        #expect(entry["team_name"] as? String == "t", "the captured shape kept")
        #expect(!grokText.contains("REAL") && !grokText.contains("real-signature"), "no real value")
        let mode = try FileManager.default.attributesOfItem(atPath: grokFile.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)

        await d.seedKimiAuthFile(for: kimi, homeRoot: home)
        let kimiFile = home.appendingPathComponent(".kimi-code/credentials/managed.json")
        let kimiText = try String(contentsOf: kimiFile, encoding: .utf8)
        let creds = try #require(try JSONSerialization.jsonObject(with: Data(kimiText.utf8)) as? [String: Any])
        let access = try #require(creds["access_token"] as? String)
        #expect(access != realKimi && mitm.kimiStore.profileForBogusKey(access) == kimi.id)
        #expect(!kimiText.contains("REAL"), "no real value")

        // The launch's staging (and a live refresh's) writes them into the
        // home seed's files/.
        let meta = URL(fileURLWithPath: dir + "/meta", isDirectory: true)
        try FileManager.default.createDirectory(at: meta, withIntermediateDirectories: true)
        try await d.writeCredentialFiles(grok, plan: nil, registration: false, meta: meta, kubeYAML: nil)
        #expect(FileManager.default.fileExists(atPath: meta.path + "/home-seed/files/.grok/auth.json"))
        try await d.writeCredentialFiles(kimi, plan: nil, registration: false, meta: meta, kubeYAML: nil)
        #expect(FileManager.default.fileExists(atPath: meta.path + "/home-seed/files/.kimi-code/credentials/managed.json"))

        // Not on a subscription (an API key), or no login stored: nothing.
        let other = URL(fileURLWithPath: dir + "/other", isDirectory: true)
        await d.seedGrokAuthFile(for: Profile(name: "g2", tool: .grok, authMode: .token), homeRoot: other)
        await d.seedKimiAuthFile(for: Profile(name: "k2", tool: .kimi, authMode: .subscription), homeRoot: other)
        #expect(!FileManager.default.fileExists(atPath: other.path))
        await d.shutdown()
    }
}
