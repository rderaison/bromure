using System.Text.Json;
using Bromure.AC.Mitm.Aws;
using Bromure.AC.Mitm.Consent;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Direct test of the wire shape the host's AWS credential listener
/// produces. We can't bind an AF_HYPERV listener inside xunit (no
/// VM), but we can drive the same protocol bytes through a
/// MemoryStream and assert the response is the credential_process
/// JSON the AWS SDK expects. The hvsocket transport itself is just
/// a NetworkStream wrapper — the protocol is what matters.
/// </summary>
public class AwsCredentialHvSocketProtocolTests
{
    [Fact]
    public async Task PayloadFlow_KnownProfile_ReturnsCredentialJson()
    {
        var server = new AwsCredentialServer(new ConsentBroker(new AlwaysAllowSessionDialogPresenter()));
        var profile = Guid.NewGuid();
        server.SetCredentials(new AwsCredentials(
            AccessKeyId: "AKIA1234567890EXAMPLE",
            SecretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            SessionToken: "session-tok-abc",
            RequireApproval: false), profile);

        // Direct call mirrors what AwsCredentialHvSocketListener
        // does after parsing the inbound profile-id line.
        using var stream = new MemoryStream();
        await server.WriteCredentialProcessPayloadAsync(stream, profile);
        stream.Position = 0;
        var json = new System.IO.StreamReader(stream).ReadToEnd();
        using var doc = JsonDocument.Parse(json);
        doc.RootElement.GetProperty("Version").GetInt32().Should().Be(1);
        doc.RootElement.GetProperty("AccessKeyId").GetString().Should().Be("AKIA1234567890EXAMPLE");
        // The host vends a FAKE secret, not the real one. AWS would
        // reject this signature; the proxy resigns with the real
        // material before the request leaves the host.
        var vended = doc.RootElement.GetProperty("SecretAccessKey").GetString();
        vended.Should().NotBe("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            "the host MUST NOT echo the real secret back to the guest");
        vended.Should().NotBeNullOrEmpty();
    }

    [Fact]
    public async Task PayloadFlow_UnknownProfile_ReturnsErrorJson()
    {
        var server = new AwsCredentialServer(new ConsentBroker(new AlwaysAllowSessionDialogPresenter()));
        using var stream = new MemoryStream();
        await server.WriteCredentialProcessPayloadAsync(stream, Guid.NewGuid());
        stream.Position = 0;
        var json = new System.IO.StreamReader(stream).ReadToEnd();
        using var doc = JsonDocument.Parse(json);
        doc.RootElement.GetProperty("Version").GetInt32().Should().Be(1);
        doc.RootElement.TryGetProperty("Error", out var err).Should().BeTrue();
        err.GetString().Should().Contain("no AWS credentials configured");
    }

    [Fact]
    public async Task GuestHelper_RoundTripJsonShape_ParsesAsExecCredentialOutput()
    {
        // The credential_process spec the AWS SDK consumes:
        // https://docs.aws.amazon.com/sdkref/latest/guide/feature-process-credentials.html
        // Required: Version=1, AccessKeyId, SecretAccessKey.
        // Optional: SessionToken, Expiration.
        // Our payload omits Expiration so the SDK caches for the
        // calling process's lifetime — the VM is disposable so
        // there's no stale-token risk.
        var server = new AwsCredentialServer(new ConsentBroker(new AlwaysAllowSessionDialogPresenter()));
        var profile = Guid.NewGuid();
        server.SetCredentials(new AwsCredentials(
            "AKIATEST", "secret", "session", false), profile);
        using var stream = new MemoryStream();
        await server.WriteCredentialProcessPayloadAsync(stream, profile);
        var json = System.Text.Encoding.UTF8.GetString(stream.ToArray());
        json.Should().Contain("\"Version\":1");
        json.Should().Contain("\"AccessKeyId\":\"AKIATEST\"");
        // No real secret in the wire payload.
        json.Should().NotContain("\"SecretAccessKey\":\"secret\"");
    }
}
