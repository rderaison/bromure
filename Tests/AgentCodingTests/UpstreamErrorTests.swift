import Foundation
import Testing
@testable import bromure_ac

/// When the MITM's upstream leg can't complete a request — most importantly a
/// TLS handshake the HOST rejects because it doesn't trust the upstream's CA —
/// the proxy must turn the failure into a plain-English HTTP error the guest
/// can read, and flag the trust cases so they're recorded on the Security
/// Timeline. The bare connection close that used to happen surfaced as a
/// cryptic `EOF` in docker/curl/git with no way to tell why.
@Suite("Upstream error diagnosis")
struct UpstreamErrorTests {

    private func urlError(_ code: Int) -> Error {
        NSError(domain: NSURLErrorDomain, code: code)
    }

    @Test("Untrusted / unknown-root certs are classified as trust failures")
    func untrustedIsTrust() {
        for code in [NSURLErrorServerCertificateUntrusted,
                     NSURLErrorServerCertificateHasUnknownRoot] {
            let d = describeUpstreamError(urlError(code), host: "registry.ny.secl.io")
            #expect(d.isTrust)
            #expect(d.reason.contains("registry.ny.secl.io"))
            #expect(d.reason.lowercased().contains("does not trust"))
            // The guest-facing body tells the operator where to fix it (the host).
            #expect(d.body.contains("keychain"))
            #expect(d.body.contains("registry.ny.secl.io"))
        }
    }

    @Test("Expired / not-yet-valid certs are trust failures too")
    func badDateIsTrust() {
        for code in [NSURLErrorServerCertificateHasBadDate,
                     NSURLErrorServerCertificateNotYetValid] {
            let d = describeUpstreamError(urlError(code), host: "h")
            #expect(d.isTrust)
            #expect(d.reason.contains("expired") || d.reason.contains("not yet valid"))
        }
    }

    @Test("A generic secure-connection failure is a trust failure")
    func secureConnFailedIsTrust() {
        let d = describeUpstreamError(urlError(NSURLErrorSecureConnectionFailed), host: "h")
        #expect(d.isTrust)
    }

    @Test("Connectivity failures are NOT trust failures (no keychain advice)")
    func connectivityNotTrust() {
        for code in [NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
                     NSURLErrorCannotConnectToHost, NSURLErrorTimedOut,
                     NSURLErrorNetworkConnectionLost] {
            let d = describeUpstreamError(urlError(code), host: "example.com")
            #expect(!d.isTrust)
            #expect(!d.body.contains("keychain"))       // don't misdirect to a cert fix
            #expect(d.reason.contains("example.com"))
        }
    }

    @Test("A non-URL error still yields a readable reason")
    func nonURLError() {
        struct Boom: Error {}
        let d = describeUpstreamError(Boom(), host: "h")
        #expect(!d.isTrust)
        #expect(!d.reason.isEmpty)
        #expect(d.body.contains("could not complete"))
    }

    @Test("The insecure-bypass hint appears only for a trust failure when the profile allows it")
    func insecureHintGating() {
        // Trust failure + allowed → the hint (and header name) is offered.
        let allowed = describeUpstreamError(
            urlError(NSURLErrorServerCertificateUntrusted),
            host: "self-signed.example", allowInsecureHint: true)
        #expect(allowed.body.contains("X-bromure-insecure"))

        // Trust failure but NOT allowed → never teach the bypass.
        let notAllowed = describeUpstreamError(
            urlError(NSURLErrorServerCertificateUntrusted),
            host: "self-signed.example", allowInsecureHint: false)
        #expect(!notAllowed.body.contains("X-bromure-insecure"))

        // A non-trust failure never gets the hint even when allowed (the header
        // wouldn't help a DNS/connect error).
        let connErr = describeUpstreamError(
            urlError(NSURLErrorCannotConnectToHost),
            host: "self-signed.example", allowInsecureHint: true)
        #expect(!connErr.body.contains("X-bromure-insecure"))
    }
}
