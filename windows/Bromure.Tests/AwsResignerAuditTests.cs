using System.Text;
using System.Text.Json.Nodes;
using Bromure.AC.Mitm.Aws;
using Bromure.AC.Mitm.SigV4;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Audit-event coverage for the AWS resigner. Master audit gap #4
/// flagged the missing credential.aws_sign emission — these tests
/// pin the wire layout and the masked-AKID format so a regression
/// can't silently drop the audit trail.
/// </summary>
public class AwsResignerAuditTests
{
    [Fact]
    public void MaskAccessKey_KeepsPrefixAndSuffix_DropsMiddle()
    {
        var masked = AwsResigner.MaskAccessKey("AKIAIOSFODNN7EXAMPLE");
        masked.Should().StartWith("AKIA");
        masked.Should().EndWith("MPLE");
        masked.Should().NotContain("IOSFODNN7EXA",
            "the secret-relevant middle of the AKID must be redacted");
    }

    [Fact]
    public async Task ResignAsync_EmitsCredentialAwsSignWithMaskedAkid()
    {
        var sink = new InMemoryCredServer(
            new AwsCredentials(
                AccessKeyId: "AKIAIOSFODNN7EXAMPLE",
                SecretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
                SessionToken: "",
                RequireApproval: false));
        var resigner = new AwsResigner(sink);

        Guid? capturedProfile = null;
        string? capturedType = null;
        JsonObject? capturedData = null;
        resigner.SetCloudEventSink((pid, type, data) =>
        {
            capturedProfile = pid;
            capturedType = type;
            capturedData = data;
        });

        var profileId = Guid.NewGuid();
        var raw = BuildSignedRequest(
            host: "ec2.us-east-1.amazonaws.com",
            method: "GET", path: "/?Action=DescribeInstances",
            originalAkid: "ASIABROMUREFAKEFAKE0",
            region: "us-east-1", service: "ec2");

        var outcome = await resigner.ResignAsync(raw, "ec2.us-east-1.amazonaws.com", profileId);

        outcome.Should().BeOfType<AwsResigner.Outcome.Resigned>();
        capturedProfile.Should().Be(profileId);
        capturedType.Should().Be("credential.aws_sign");
        capturedData.Should().NotBeNull();
        capturedData!["method"]!.GetValue<string>().Should().Be("GET");
        capturedData["host"]!.GetValue<string>().Should().Be("ec2.us-east-1.amazonaws.com");
        // Path is captured as the URI path portion only — the query
        // string is parsed separately by the SigV4 canonicaliser.
        capturedData["path"]!.GetValue<string>().Should().Be("/");
        capturedData["service"]!.GetValue<string>().Should().Be("ec2");
        capturedData["region"]!.GetValue<string>().Should().Be("us-east-1");
        capturedData["access_key_masked"]!.GetValue<string>().Should()
            .Be(AwsResigner.MaskAccessKey("AKIAIOSFODNN7EXAMPLE"));
    }

    [Fact]
    public async Task ResignAsync_NoSinkSet_DoesNotThrow()
    {
        // Audit emission is best-effort — when no sink is wired
        // (tests, headless boot), the resigner must still resign.
        var sink = new InMemoryCredServer(
            new AwsCredentials("AKIAIOSFODNN7EXAMPLE", "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "", false));
        var resigner = new AwsResigner(sink);
        var raw = BuildSignedRequest(
            host: "s3.amazonaws.com",
            method: "GET", path: "/bucket/key",
            originalAkid: "ASIABROMUREFAKEFAKE0",
            region: "us-east-1", service: "s3");
        (await resigner.ResignAsync(raw, "s3.amazonaws.com", Guid.NewGuid()))
            .Should().BeOfType<AwsResigner.Outcome.Resigned>();
    }

    private static byte[] BuildSignedRequest(string host, string method, string path,
        string originalAkid, string region, string service)
    {
        // We only need a request that the resigner will *parse* — the
        // signature is replaced anyway. Minimum SigV4 shape: method,
        // path, host header, fake auth header with the right scope.
        var date = "20260521T120000Z";
        var scope = $"{date[..8]}/{region}/{service}/aws4_request";
        var auth = $"AWS4-HMAC-SHA256 Credential={originalAkid}/{scope}, SignedHeaders=host;x-amz-date, Signature=deadbeef";
        var sb = new StringBuilder();
        sb.Append($"{method} {path} HTTP/1.1\r\n");
        sb.Append($"Host: {host}\r\n");
        sb.Append($"X-Amz-Date: {date}\r\n");
        sb.Append($"X-Amz-Content-SHA256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\r\n");
        sb.Append($"Authorization: {auth}\r\n");
        sb.Append("Content-Length: 0\r\n");
        sb.Append("\r\n");
        return Encoding.ASCII.GetBytes(sb.ToString());
    }

    private sealed class InMemoryCredServer : IAwsCredentialServer
    {
        private readonly AwsCredentials _creds;
        public InMemoryCredServer(AwsCredentials creds) => _creds = creds;
        public Task<SigningMaterial> SigningMaterialAsync(Guid profileId, string scopeHint, CancellationToken ct)
            => Task.FromResult<SigningMaterial>(new SigningMaterial.Material(
                new SigV4Signer.Credentials(_creds.AccessKeyId, _creds.SecretAccessKey, _creds.SessionToken)));
    }
}
