using Bromure.AC.Mitm.Consent;
using Bromure.AC.Mitm.Pki;
using Bromure.AC.Mitm.Swap;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Coverage for the K8s ExecCredentialPoller. Master audit gap #8:
/// EKS / GKE / AKS default to exec-plugin auth; without this poller
/// every kubectl request 401s after the initial token expires.
/// </summary>
public class ExecCredentialPollerTests
{
    [Fact]
    public void ParseToken_ExtractsStatusToken()
    {
        const string json = "{\"apiVersion\":\"client.authentication.k8s.io/v1\",\"kind\":\"ExecCredential\",\"status\":{\"token\":\"k8s-token-abc-123\"}}";
        ExecCredentialPoller.ParseToken(json).Should().Be("k8s-token-abc-123");
    }

    [Fact]
    public void ParseToken_HandlesExpirationTimestampShape()
    {
        const string json = """
            {
              "kind": "ExecCredential",
              "apiVersion": "client.authentication.k8s.io/v1beta1",
              "status": {
                "expirationTimestamp": "2026-05-21T13:00:00Z",
                "token": "eks-bearer-deadbeef"
              }
            }
            """;
        ExecCredentialPoller.ParseToken(json).Should().Be("eks-bearer-deadbeef");
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("{}")]
    [InlineData("{\"status\":{}}")]
    [InlineData("{\"status\":\"not-an-object\"}")]
    [InlineData("{\"status\":{\"token\":\"\"}}")]
    [InlineData("{\"status\":{\"token\":42}}")]
    [InlineData("[]")]
    [InlineData("not json")]
    public void ParseToken_GarbageReturnsNull(string json)
    {
        ExecCredentialPoller.ParseToken(json).Should().BeNull();
    }

    [Fact]
    public async Task RunExecAsync_NonZeroExitCode_ReturnsNull()
    {
        // `cmd /c exit 1` is the simplest cross-version Windows way
        // to produce a non-zero exit. The poller treats this as a
        // miss and keeps the prior token in the swap map.
        var result = await ExecCredentialPoller.RunExecAsync(
            command: "cmd.exe",
            args: new[] { "/c", "exit 1" },
            ct: CancellationToken.None);
        result.Should().BeNull();
    }

    [Fact]
    public async Task RunExecAsync_NonExistentCommand_ReturnsNullDoesNotThrow()
    {
        var result = await ExecCredentialPoller.RunExecAsync(
            command: "this-program-definitely-does-not-exist.exe",
            args: Array.Empty<string>(),
            ct: CancellationToken.None);
        result.Should().BeNull();
    }

    [Fact]
    public async Task RunExecAsync_PrintsValidJson_ReturnsToken()
    {
        // Write a minimal ExecCredential JSON to a temp file then
        // shell out to `cmd /c type <file>` so the poller's process
        // pipeline gets exercised end-to-end. Avoids the cmd-quoting
        // headache of trying to pipe JSON directly through `echo`.
        var tmp = Path.Combine(Path.GetTempPath(),
            "bromure-exec-test-" + Guid.NewGuid().ToString("N") + ".json");
        var json = "{\"status\":{\"token\":\"shell-roundtrip-tok\"}}";
        await File.WriteAllTextAsync(tmp, json);
        try
        {
            var result = await ExecCredentialPoller.RunExecAsync(
                command: "cmd.exe",
                args: new[] { "/c", "type", tmp },
                ct: CancellationToken.None);
            result.Should().Be("shell-roundtrip-tok");
        }
        finally
        {
            try { File.Delete(tmp); } catch (IOException) { }
        }
    }

    [Fact]
    public async Task StopForProfile_CancelsAllPollersForThatProfile()
    {
        await using var poller = new ExecCredentialPoller();
        var swapper = new TokenSwapper(new AlwaysAllowConsentBroker());
        var profile = Guid.NewGuid();

        // Use a non-existent command so the loop bails on each
        // iteration without consuming real resources.
        poller.Start(new[]
        {
            new KubeconfigMaterializer.ExecContext(
                EntryId: Guid.NewGuid(),
                Host: "eks.example.com",
                FakeToken: "fake-1",
                Command: "this-program-definitely-does-not-exist.exe",
                Args: Array.Empty<string>(),
                RefreshSeconds: 60),
            new KubeconfigMaterializer.ExecContext(
                EntryId: Guid.NewGuid(),
                Host: "gke.example.com",
                FakeToken: "fake-2",
                Command: "this-program-definitely-does-not-exist.exe",
                Args: Array.Empty<string>(),
                RefreshSeconds: 60),
        }, profile, swapper);

        // Cancel them all. No assertion beyond "doesn't throw" — the
        // test exists to make sure StopForProfile clears bookkeeping
        // so the next session for the same profile can re-Start.
        poller.StopForProfile(profile);
        poller.StopForProfile(profile);   // idempotent
    }
}
