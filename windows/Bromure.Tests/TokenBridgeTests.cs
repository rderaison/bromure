using System.Net;
using System.Net.Sockets;
using System.Text.Json.Nodes;
using Bromure.SandboxEngine.Vsock;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// End-to-end integration tests for <see cref="SubscriptionTokenBridge"/>
/// and <see cref="CodexTokenBridge"/>. Audit 07 #3 fix: the bridge
/// transport switched from Windows Named Pipes to AF_HYPERV — xunit
/// can't bind an AF_HYPERV listener (no VM peer), so we drive the
/// bridge's registered handler directly via the
/// <c>VsockBridge.TestInvokeAsync</c> seam over a loopback TCP
/// socket pair. Same JSON ping-pong as before; the transport step
/// is the only thing that changed.
/// </summary>
public class TokenBridgeTests
{
    [Fact]
    public async Task SubscriptionTokenBridge_ReadOp_RoundTripsThroughHandler()
    {
        await using var bridge = new VsockBridge();
        var sub = new SubscriptionTokenBridge();
        sub.RegisterOn(bridge);
        var vmId = Guid.NewGuid();

        var agentTask = RunFakeAgentAsync(bridge, SubscriptionTokenBridge.Port, vmId,
            async (request, writer, ct) =>
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

        await sub.WaitConnectedAsync(vmId, new CancellationTokenSource(TimeSpan.FromSeconds(5)).Token);
        var tokens = await sub.ReadAsync(vmId, new CancellationTokenSource(TimeSpan.FromSeconds(5)).Token);
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
        var vmId = Guid.NewGuid();

        string? capturedAccess = null;
        string? capturedRefresh = null;
        var agentTask = RunFakeAgentAsync(bridge, SubscriptionTokenBridge.Port, vmId,
            async (request, writer, ct) =>
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

        await sub.WaitConnectedAsync(vmId, new CancellationTokenSource(TimeSpan.FromSeconds(5)).Token);
        await sub.WriteAsync(
            vmId,
            "sk-ant-oat01-brm-fake-access",
            "sk-ant-ort01-brm-fake-refresh",
            new CancellationTokenSource(TimeSpan.FromSeconds(5)).Token);
        capturedAccess.Should().Be("sk-ant-oat01-brm-fake-access");
        capturedRefresh.Should().Be("sk-ant-ort01-brm-fake-refresh");

        await agentTask;
    }

    [Fact]
    public async Task SubscriptionTokenBridge_AgentReject_SurfacesAsTypedException()
    {
        await using var bridge = new VsockBridge();
        var sub = new SubscriptionTokenBridge();
        sub.RegisterOn(bridge);
        var vmId = Guid.NewGuid();

        var agentTask = RunFakeAgentAsync(bridge, SubscriptionTokenBridge.Port, vmId,
            async (request, writer, ct) =>
            {
                await WriteLineAsync(writer, new JsonObject
                {
                    ["id"] = request["id"]!.DeepClone(),
                    ["ok"] = false,
                    ["reason"] = "no credentials file present",
                }, ct);
            });

        await sub.WaitConnectedAsync(vmId, new CancellationTokenSource(TimeSpan.FromSeconds(5)).Token);
        var ex = await Record.ExceptionAsync(() =>
            sub.ReadAsync(vmId, new CancellationTokenSource(TimeSpan.FromSeconds(5)).Token));
        ex.Should().NotBeNull();
        ex!.Message.Should().Contain("no credentials");

        await agentTask;
    }

    [Fact]
    public async Task CodexTokenBridge_ReadOp_RoundTripsThroughHandler()
    {
        await using var bridge = new VsockBridge();
        var codex = new CodexTokenBridge();
        codex.RegisterOn(bridge);
        var vmId = Guid.NewGuid();

        var agentTask = RunFakeAgentAsync(bridge, CodexTokenBridge.Port, vmId,
            async (request, writer, ct) =>
            {
                request["op"]?.GetValue<string>().Should().Be("read");
                await WriteLineAsync(writer, new JsonObject
                {
                    ["id"] = request["id"]!.DeepClone(),
                    ["ok"] = true,
                    ["access"] = "eyJ-access",
                    ["refresh"] = "rt-refresh",
                    ["id_token"] = "eyJ-id",
                }, ct);
            });

        await codex.WaitConnectedAsync(vmId, new CancellationTokenSource(TimeSpan.FromSeconds(5)).Token);
        var tokens = await codex.ReadAsync(vmId, new CancellationTokenSource(TimeSpan.FromSeconds(5)).Token);
        tokens.Should().NotBeNull();
        tokens!.Access.Should().Be("eyJ-access");
        tokens.Refresh.Should().Be("rt-refresh");
        tokens.IdToken.Should().Be("eyJ-id");

        await agentTask;
    }

    /// <summary>
    /// Spin up a loopback TCP socket pair, hand one end to the
    /// bridge via the TestInvokeAsync seam, and run the JSON
    /// ping-pong on the other end mimicking the in-VM Python agent.
    /// </summary>
    private static async Task RunFakeAgentAsync(
        VsockBridge bridge, uint port, Guid sourceVmId,
        Func<JsonObject, Stream, CancellationToken, Task> handler)
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var tcpPort = ((IPEndPoint)listener.LocalEndpoint).Port;
        var connectTask = listener.AcceptTcpClientAsync();
        using var client = new TcpClient();
        await client.ConnectAsync(IPAddress.Loopback, tcpPort);
        using var server = await connectTask;
        listener.Stop();

        // Hand the BRIDGE side to the registered handler — that's
        // the "guest connection" from the bridge's perspective.
        var bridgeSide = client.GetStream();
        var agentSide = server.GetStream();

        // Run the bridge handler on the bridgeSide; the test
        // continues to drive the agentSide.
        using var ctsLifetime = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        _ = Task.Run(() => bridge.TestInvokeAsync(port, bridgeSide, sourceVmId, ctsLifetime.Token));

        // Read one request, hand it to the test handler, write
        // back the response.
        var line = await JsonLine.ReadAsync(agentSide, ct: ctsLifetime.Token);
        if (line is null) throw new InvalidOperationException("no request arrived");
        var request = JsonNode.Parse(line) as JsonObject
            ?? throw new InvalidOperationException("agent received non-object JSON");
        await handler(request, agentSide, ctsLifetime.Token);
        await Task.Delay(50, ctsLifetime.Token);
    }

    private static Task WriteLineAsync(Stream w, JsonObject obj, CancellationToken ct)
        => JsonLine.WriteAsync(w, obj.ToJsonString(), ct);
}
