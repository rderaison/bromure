import Foundation
import FoundationNetworking
import Testing
@testable import ACLinux

extension DaemonGlobalSuites {
    /// Amazon Bedrock as a workspace's engine (macOS: startLocalEngineIfNeeded
    /// and the engine's awsSigner): with no pasted key, the repair proxy signs
    /// with the workspace's AWS credentials; with one, it's a bearer.
    @Suite("Bedrock engine", .serialized)
    struct BedrockTests {
        static func bedrock(_ key: String?) -> Profile {
            var p = Profile(name: "b", tool: .claude, authMode: .local)
            p.localEngineURL = "https://bedrock-runtime.eu-west-1.amazonaws.com/openai/v1"
            p.localEngineAPIKey = key
            p.activeModelID = "anthropic.claude-test"
            return p
        }

        @Test func noKeySignsWithTheWorkspacesAWSKeys() async throws {
            let (d, _, dir) = try await DaemonRepairGateTests.daemon()
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let p = Self.bedrock(nil)
            guard !p.distinctLocalModelIDs.isEmpty else {
                Issue.record("the test profile names no local model: \(p.distinctLocalModelIDs)"); return
            }
            await d.startLocalEngineIfNeeded(for: p)
            let config = try #require(InferenceRepairProxy.shared.externalEngine(for: p.id))
            #expect(config.auth == .sigV4(profileID: p.id, region: "eu-west-1"))
            // Signed with the workspace's keys, through the credential server.
            let mitm = try #require(await d.mitm)
            // Built at run time: no key-shaped literal in the source.
            let akid = "AKIA" + "TESTBEDROCK00001"
            mitm.awsCreds.setCredentials(AWSCredentials(accessKeyID: akid, secretAccessKey: "test-secret-not-real",
                                                        region: "eu-west-1"), for: p.id)
            Daemon.installBedrockSigner(mitm.awsCreds)
            defer { ExternalEngine.awsSigner = nil }
            var req = URLRequest(url: URL(string: "https://bedrock-runtime.eu-west-1.amazonaws.com/openai/v1/chat/completions")!)
            req.httpMethod = "POST"
            req.httpBody = Data("{}".utf8)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            ExternalEngine.authorize(&req, config: config)
            let auth = req.value(forHTTPHeaderField: "Authorization") ?? ""
            #expect(auth.hasPrefix("AWS4-HMAC-SHA256 Credential=\(akid)/") && auth.contains("/eu-west-1/bedrock/"), "\(auth)")
            // A pasted key: a bearer, no signing.
            let keyed = Self.bedrock("bedrock-key-test")
            await d.startLocalEngineIfNeeded(for: keyed)
            #expect(InferenceRepairProxy.shared.externalEngine(for: keyed.id)?.auth == .bearer)
            InferenceRepairProxy.shared.setExternalEngine(p.id, nil)
            InferenceRepairProxy.shared.setExternalEngine(keyed.id, nil)
            await d.shutdown()
        }
    }
}
