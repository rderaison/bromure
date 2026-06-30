import Foundation
import Testing
@testable import bromure_ac

/// `SigV4Signer` is pure signing math with no HTTP I/O. We pin it to
/// AWS's published "get-vanilla" reference vector (reproduced in the
/// source file's trailing comment) and exercise the canonicalization
/// helpers that the Bedrock path depends on.
@Suite("SigV4 signer")
struct SigV4SignerTests {

    /// 2015-08-30T12:36:00Z — the reference vector's signing instant.
    private var vanillaDate: Date {
        var c = DateComponents()
        c.year = 2015; c.month = 8; c.day = 30
        c.hour = 12; c.minute = 36; c.second = 0
        c.timeZone = TimeZone(identifier: "UTC")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    @Test("get-vanilla reference vector reproduces the AWS-published signature")
    func getVanilla() {
        let req = SigV4Signer.Request(
            method: "GET", path: "/", query: "",
            headers: [("Host", "example.amazonaws.com"),
                      ("X-Amz-Date", "20150830T123600Z")],
            body: Data())
        let creds = SigV4Signer.Credentials(
            accessKeyID: "AKIDEXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
        let scope = SigV4Signer.Scope(date: "20150830", region: "us-east-1", service: "service")

        let out = SigV4Signer.sign(request: req, credentials: creds,
                                   scope: scope, date: vanillaDate)

        #expect(out.signedHeaders == "host;x-amz-date")
        #expect(out.amzDate == "20150830T123600Z")
        #expect(out.payloadHash ==
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(out.authorization ==
            "AWS4-HMAC-SHA256 " +
            "Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, " +
            "SignedHeaders=host;x-amz-date, " +
            "Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }

    @Test("unsignedPayload swaps the payload hash for the sentinel")
    func unsignedPayload() {
        let req = SigV4Signer.Request(
            method: "PUT", path: "/", query: "",
            headers: [("Host", "example.amazonaws.com"),
                      ("X-Amz-Date", "20150830T123600Z")],
            body: Data("some body".utf8))
        let creds = SigV4Signer.Credentials(accessKeyID: "AKIDEXAMPLE",
                                            secretAccessKey: "secret")
        let scope = SigV4Signer.Scope(date: "20150830", region: "us-east-1", service: "s3")
        let out = SigV4Signer.sign(request: req, credentials: creds,
                                   scope: scope, date: vanillaDate,
                                   unsignedPayload: true)
        #expect(out.payloadHash == "UNSIGNED-PAYLOAD")
    }

    // MARK: - helpers

    @Test("hexSHA256 of empty data is the canonical empty-string digest")
    func hexSHA256Empty() {
        #expect(SigV4Signer.hexSHA256(Data()) ==
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test("isoBasic formats UTC in compact ISO-8601")
    func isoBasicFormat() {
        #expect(SigV4Signer.isoBasic(vanillaDate) == "20150830T123600Z")
    }

    @Test("uriEncodeSegment percent-encodes reserved bytes, keeps unreserved")
    func uriEncode() {
        #expect(SigV4Signer.uriEncodeSegment("abcXYZ0-9_.~") == "abcXYZ0-9_.~")
        #expect(SigV4Signer.uriEncodeSegment("a:b") == "a%3Ab")
        #expect(SigV4Signer.uriEncodeSegment("a b") == "a%20b")
        // `%` itself is encoded → produces SigV4's double-encoding.
        #expect(SigV4Signer.uriEncodeSegment("%20") == "%2520")
        #expect(SigV4Signer.uriEncodeSegment("/") == "%2F")
    }

    @Test("canonicalPath re-encodes colons for non-S3 (Bedrock model IDs)")
    func canonicalPathBedrock() {
        #expect(SigV4Signer.canonicalPath("/model/foo:0/invoke", service: "bedrock") ==
            "/model/foo%3A0/invoke")
        // Leading/trailing slash structure survives.
        #expect(SigV4Signer.canonicalPath("/", service: "bedrock") == "/")
    }

    @Test("canonicalPath passes S3 paths through untouched")
    func canonicalPathS3() {
        #expect(SigV4Signer.canonicalPath("/my:key/with space", service: "s3") ==
            "/my:key/with space")
        #expect(SigV4Signer.canonicalPath("/my:key", service: "S3") == "/my:key")
    }

    @Test("empty path canonicalizes to /")
    func canonicalPathEmpty() {
        #expect(SigV4Signer.canonicalPath("", service: "bedrock") == "/")
    }

    @Test("canonicalQueryString sorts by key then value")
    func canonicalQuery() {
        #expect(SigV4Signer.canonicalQueryString("b=2&a=1") == "a=1&b=2")
        #expect(SigV4Signer.canonicalQueryString("a=2&a=1") == "a=1&a=2")
        #expect(SigV4Signer.canonicalQueryString("") == "")
        // A key with no value keeps the trailing `=`.
        #expect(SigV4Signer.canonicalQueryString("z") == "z=")
    }

    @Test("canonicalHeaderValue trims and collapses internal whitespace")
    func canonicalHeader() {
        #expect(SigV4Signer.canonicalHeaderValue("   foo    bar  ") == "foo bar")
        #expect(SigV4Signer.canonicalHeaderValue("single") == "single")
        // Whitespace inside double quotes is preserved.
        #expect(SigV4Signer.canonicalHeaderValue("\"a   b\"") == "\"a   b\"")
    }
}
