using System.Globalization;
using Bromure.AC.Mitm.SigV4;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class SigV4SignerTests
{
    /// <summary>
    /// AWS "get-vanilla" reference vector from
    /// https://docs.aws.amazon.com/general/latest/gr/signature-v4-test-suite.html
    /// — the canonical-request, string-to-sign, and final signature are
    /// reproduced verbatim in the trailing comments of SigV4Signer.cs.
    ///
    /// If this test ever drifts, the canonical-path encoding, header
    /// canonicalisation, or key-derivation chain has regressed and AWS
    /// will start rejecting our re-signed Bedrock requests with
    /// InvalidSignatureException. Don't relax the assertion — fix the
    /// signer.
    /// </summary>
    [Fact]
    public void GetVanilla_MatchesAwsReferenceSignature()
    {
        var date = DateTime.SpecifyKind(
            DateTime.ParseExact("20150830T123600Z", "yyyyMMdd'T'HHmmss'Z'",
                CultureInfo.InvariantCulture), DateTimeKind.Utc);

        var output = SigV4Signer.Sign(
            request: new SigV4Signer.Request(
                Method: "GET",
                Path: "/",
                Query: "",
                Headers: new[]
                {
                    ("Host", "example.amazonaws.com"),
                    ("X-Amz-Date", "20150830T123600Z"),
                },
                Body: ReadOnlyMemory<byte>.Empty),
            credentials: new SigV4Signer.Credentials(
                AccessKeyId: "AKIDEXAMPLE",
                SecretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
            scope: new SigV4Signer.Scope("20150830", "us-east-1", "service"),
            date: date);

        output.Authorization.Should().Be(
            "AWS4-HMAC-SHA256 "
            + "Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, "
            + "SignedHeaders=host;x-amz-date, "
            + "Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31");
        output.SignedHeaders.Should().Be("host;x-amz-date");
        output.AmzDate.Should().Be("20150830T123600Z");
    }

    [Fact]
    public void CanonicalPath_S3IsLeftIntact()
    {
        // S3's canonical path is special-cased per the spec.
        SigV4Signer.CanonicalPath("/foo/bar:baz", "s3").Should().Be("/foo/bar:baz");
    }

    [Fact]
    public void CanonicalPath_BedrockColonsGetEncoded()
    {
        // This is the actual case the macOS source comments out: Bedrock
        // model IDs carry literal `:` and we need them encoded as %3A in
        // the canonical request.
        var path = "/model/global.anthropic.claude-sonnet-4-5-20250929-v1:0/converse";
        var canonical = SigV4Signer.CanonicalPath(path, "bedrock");
        canonical.Should().Contain("%3A");
        canonical.Should().NotContain(":");
    }

    [Fact]
    public void CanonicalQueryString_SortsByKeyThenValue()
    {
        var input = "b=2&a=2&a=1";
        SigV4Signer.CanonicalQueryString(input).Should().Be("a=1&a=2&b=2");
    }

    [Fact]
    public void CanonicalHeaderValue_CollapsesInternalWhitespace()
    {
        SigV4Signer.CanonicalHeaderValue("  hello   world  ").Should().Be("hello world");
    }

    [Fact]
    public void CanonicalHeaderValue_PreservesQuotedRuns()
    {
        SigV4Signer.CanonicalHeaderValue("foo \"a   b\" bar").Should().Be("foo \"a   b\" bar");
    }
}
