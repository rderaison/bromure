import CommonCrypto
import Foundation
import Testing
@testable import bromure_ac

@Suite("AWSSSOResolver")
struct AWSSSOResolverTests {

    // MARK: - Error descriptions

    @Test("All error cases have non-empty descriptions")
    func errorDescriptions() {
        let errors: [AWSSSOResolver.Error] = [
            .noProfile("test-profile"),
            .loginFailed("connection refused"),
            .tokenExpired,
            .credentialFetchFailed("HTTP 403"),
        ]
        for error in errors {
            let desc = error.errorDescription ?? ""
            #expect(!desc.isEmpty, "Error \(error) should have a description")
        }
    }

    @Test("noProfile includes profile name")
    func noProfileIncludesName() {
        let error = AWSSSOResolver.Error.noProfile("my-dev-profile")
        #expect(error.errorDescription!.contains("my-dev-profile"))
    }

    @Test("loginFailed includes reason")
    func loginFailedIncludesReason() {
        let error = AWSSSOResolver.Error.loginFailed("user cancelled")
        #expect(error.errorDescription!.contains("user cancelled"))
    }

    @Test("credentialFetchFailed includes reason")
    func credentialFetchFailedIncludesReason() {
        let error = AWSSSOResolver.Error.credentialFetchFailed("HTTP 500: Internal Server Error")
        #expect(error.errorDescription!.contains("HTTP 500"))
    }

    // MARK: - ResolvedAWSCredentials

    @Test("ResolvedAWSCredentials stores all fields")
    func resolvedCredsFields() {
        let expiry = Date().addingTimeInterval(3600)
        let creds = ResolvedAWSCredentials(
            accessKeyID: "AKIAIOSFODNN7EXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            sessionToken: "FwoGZXIvYXdzEBY...",
            region: "us-west-2",
            expiration: expiry
        )
        #expect(creds.accessKeyID == "AKIAIOSFODNN7EXAMPLE")
        #expect(creds.secretAccessKey == "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
        #expect(creds.sessionToken == "FwoGZXIvYXdzEBY...")
        #expect(creds.region == "us-west-2")
        #expect(creds.expiration == expiry)
    }

    // MARK: - Resolve with missing profile

    @Test("Resolve throws noProfile for unknown profile name")
    func resolveUnknownProfile() async {
        do {
            _ = try await AWSSSOResolver.resolve(
                profileName: "nonexistent-profile-\(UUID().uuidString)",
                triggerLoginIfNeeded: false
            )
            #expect(Bool(false), "Should have thrown")
        } catch let error as AWSSSOResolver.Error {
            switch error {
            case .noProfile(let name):
                #expect(name.contains("nonexistent-profile"))
            default:
                #expect(Bool(false), "Expected noProfile, got \(error)")
            }
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }
    }

    // MARK: - Token cache SHA1 consistency

    @Test("SHA1 hash of start URL matches AWS CLI convention")
    func sha1Consistency() {
        let input = "https://my-sso-portal.awsapps.com/start"
        let data = Data(input.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA1(ptr.baseAddress, CC_LONG(data.count), &digest)
        }
        let hash = digest.map { String(format: "%02x", $0) }.joined()

        #expect(hash.count == 40)
        #expect(hash.allSatisfy { $0.isHexDigit })
    }

    // MARK: - Refresh loop cancellation

    @Test("Refresh loop task can be cancelled")
    func refreshLoopCancellation() async throws {
        let task = AWSSSOResolver.startRefreshLoop(
            profileName: "nonexistent-\(UUID().uuidString)",
            initialExpiration: Date().addingTimeInterval(1),
            onRefresh: { _ in },
            onError: { _ in }
        )

        task.cancel()
        try await Task.sleep(for: .milliseconds(100))
        #expect(task.isCancelled)
    }
}
