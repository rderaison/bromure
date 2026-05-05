using System.IO.Pipes;
using System.Text.Json.Nodes;
using Bromure.SandboxEngine.Vsock;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// End-to-end integration tests for <see cref="SubscriptionTokenBridge"/>
/// and <see cref="CodexTokenBridge"/>. These drive the actual ported
/// wire format through a real named-pipe transport — no guest VM
/// required, but the same protocol bytes that <c>claude-token-agent.py</c>
/// and <c>codex-token-agent.py</c> exchange with the host on macOS.
///
/// <para>If a future change to the bridge breaks wire compatibility with
/// the in-VM Python agents, these tests fail. They're the cheapest
/// way to keep the macOS and Windows hosts byte-compatible at the bridge
/// layer.</para>
/// </summary>
public class TokenBridgeTests
{
    [Fact]
    public async Task SubscriptionTokenBridge_ReadOp_RoundTripsThroughNamedPipe()
    {
        await using var bridge = new VsockBridge();
        var sub = new SubscriptionTokenBridge();
        sub.RegisterOn(bridge);

        var pipeName = $"bromure-ac-vsock-{SubscriptionTokenBridge.Port}";

        // Spin up a tiny "fake agent" that mimics what
        // claude-token-agent.py does inside the guest: accept the
        // newline-delimited JSON op and reply with `ok=true` + tokens.
        var agentTask = RunFakeAgentAsync(pipeName, async (request, writer, ct) =>
        {
            request["op"]?.GetValue<string>().Should().Be("read");
            request["id"]!.GetValue<long>().Should().BeGreaterThan(0);
            await WriteLineAsync(writer, new JsonObject
            {
                ["id"] = request["id"]!.DeepClone(),
                ["ok"] = true,
                ["access"] = "sk-ant-real-access-token",
                ["refresh"] = "sk-ant-real-refresh-token",
            }, ct);
        });

        await sub.WaitConnectedAsync(new CancellationTokenSource(TimeSpan.FromSeconds(5)).Token);

        var tokens = await sub.ReadAsync(new CancellationTokenSource(TimeSpan.FromSeconds(5)).Token);
        tokens.Should().NotBeNull();
        tokens!.Access.Should().Be("sk-ant-real-access-token");
        tokens.Refresh.Should().Be("sk-ant-real-refresh-token");

        await agentTask;
    }

    [Fact]
    public async Task SubscriptionTokenBridge_WriteOp_SendsBrmFakesToAgent()
    {
        await using var bridge = new VsockBridge();
        var sub = new SubscriptionTokenBridge();
        sub.RegisterOn(bridge);

        var pipeName = $"bromure-ac-vsock-{SubscriptionTokenBridge.Port}";
        string? capturedAccess = null;
        string? capturedRefresh = null;

        var agentTask = RunFakeAgentAsync(pipeName, async (request, writer, ct) =>
        {
            request["op"]?.GetValue<string>().Should().Be("write");
            capturedAccess = request["access"]?.GetValue<string>();
            capturedRefresh = request["refresh"]?.GetValue<string>();
            await WriteLineAsync(writer, new JsonObject
            {
                ["id"] = request["id"]!.DeepClone(),
                ["ok"] = true,
            }, ct);
        });

        await sub.WaitConnectedAsync(new CancellationTokenSource(TimeSpan.FromSeconds(5)).Token);
        await sub.WriteAsync("brm-fake-access-aaaa", "brm-fake-refresh-bbbb",
            new CancellationTokenSource(TimeSpan.FromSeconds(5)).Token);

        capturedAccess.Should().Be("brm-fake-access-aaaa");
        capturedRefresh.Should().Be("brm-fake-refresh-bbbb");

        await agentTask;
    }

    [Fact]
    public async Task SubscriptionTokenBridge_AgentReject_SurfacesAsTypedException()
    {
        await using var bridge = new VsockBridge();
        var sub = new SubscriptionTokenBridge();
        sub.RegisterOn(bridge);

        var pipeName = $"bromure-ac-vsock-{SubscriptionTokenBridge.Port}";
        var agentTask = RunFakeAgentAsync(pipeName, async (request, writer, ct) =>
        {
            await WriteLineAsync(writer, new JsonObject
            {
                ["id"] = request["id"]!.DeepClone(),
                ["ok"] = false,
                ["reason"] = "missing brm- prefix",
            }, ct);
        });

        await sub.WaitConnectedAsync(new CancellationTokenSource(TimeSpan.FromSeconds(5)).Token);

        await FluentActions
            .Awaiting(() => sub.WriteAsync("not-prefixed", "also-not-prefixed",
                new CancellationTokenSource(TimeSpan.FromSeconds(5)).Token))
            .Should().ThrowAsync<SubscriptionTokenBridge.AgentRejectedException>()
            .WithMessage("*missing brm- prefix*");

        await agentTask;
    }

    [Fact]
    public async Task CodexTokenBridge_ReadOp_CarriesAllThreeTokens()
    {
        await using var bridge = new VsockBridge();
        var codex = new CodexTokenBridge();
        codex.RegisterOn(bridge);

        var pipeName = $"bromure-ac-vsock-{CodexTokenBridge.Port}";

        var agentTask = RunFakeAgentAsync(pipeName, async (request, writer, ct) =>
        {
            request["op"]?.GetValue<string>().Should().Be("read");
            await WriteLineAsync(writer, new JsonObject
            {
                ["id"] = request["id"]!.DeepClone(),
                ["ok"] = true,
                ["access"] = "real-access",
                ["refresh"] = "real-refresh",
                ["id_token"] = "real-id-token",
            }, ct);
        });

        await codex.WaitConnectedAsync(new CancellationTokenSource(TimeSpan.FromSeconds(5)).Token);

        var tokens = await codex.ReadAsync(new CancellationTokenSource(TimeSpan.FromSeconds(5)).Token);
        tokens.Should().NotBeNull();
        tokens!.Access.Should().Be("real-access");
        tokens.Refresh.Should().Be("real-refresh");
        tokens.IdToken.Should().Be("real-id-token");

        await agentTask;
    }

    /// <summary>
    /// Boots a single-shot pipe client that mimics the guest agent.
    /// One request → one reply, then disconnect. The signature mirrors
    /// the claude-token-agent.py / codex-token-agent.py loop closely
    /// enough to catch wire drift.
    /// </summary>
    private static Task RunFakeAgentAsync(
        string pipeName,
        Func<JsonObject, Stream, CancellationToken, Task> handler)
    {
        return Task.Run(async () =>
        {
            using var client = new NamedPipeClientStream(
                ".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
            await client.ConnectAsync(5000);

            using var ctsLifetime = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            var line = await JsonLine.ReadAsync(client, ct: ctsLifetime.Token);
            line.Should().NotBeNull();
            var request = JsonNode.Parse(line!) as JsonObject
                ?? throw new InvalidOperationException("agent received non-object JSON");
            await handler(request, client, ctsLifetime.Token);
            // Give the host a tick to drain the response before we close.
            await Task.Delay(50, ctsLifetime.Token);
        });
    }

    private static Task WriteLineAsync(Stream w, JsonObject obj, CancellationToken ct)
        => JsonLine.WriteAsync(w, obj.ToJsonString(), ct);
}
