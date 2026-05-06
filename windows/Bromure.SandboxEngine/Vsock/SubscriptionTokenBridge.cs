// macos-source: Sources/AgentCoding/SubscriptionTokenBridge.swift @ 7ef3f5dcd1e3
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Bromure.SandboxEngine.Vsock;

/// <summary>
/// Host side of the Claude subscription-token swap channel — direct
/// port of <c>SubscriptionTokenBridge.swift</c>. Listens on vsock port
/// 8446 (the same port number the in-VM <c>claude-token-agent.py</c>
/// dials), exposes two RPCs:
///
/// <list type="bullet">
///   <item><c>read()</c>      — pulls the current accessToken+refreshToken
///                              from <c>~/.claude/.credentials.json</c>.</item>
///   <item><c>write(access, refresh)</c> — overwrites both with brm-prefixed fakes.</item>
/// </list>
///
/// <b>Security invariant.</b> The host NEVER sends real cleartext token
/// values to the VM. Only fakes flow host→VM. Only reals flow VM→host.
/// There is no RPC for "host hands me a real token." Same as macOS.
/// </summary>
public sealed class SubscriptionTokenBridge : IAsyncDisposable
{
    public const uint Port = 8446;

    private readonly ILogger _log;
    private readonly object _gate = new();
    private Stream? _connection;
    private TaskCompletionSource<bool>? _connected;
    private long _idSeq;
    private readonly Dictionary<long, TaskCompletionSource<JsonObject>> _pending = new();

    public bool IsConnected
    {
        get { lock (_gate) return _connection is not null; }
    }

    public SubscriptionTokenBridge(ILogger? log = null) => _log = log ?? NullLogger.Instance;

    /// <summary>Register on <paramref name="bridge"/>. Idempotent on the bridge side.</summary>
    public void RegisterOn(VsockBridge bridge)
    {
        bridge.Listen(Port, HandleConnectionAsync);
    }

    private async Task HandleConnectionAsync(Stream conn, CancellationToken ct)
    {
        lock (_gate)
        {
            _connection = conn;
            _connected?.TrySetResult(true);
            _connected = null;
        }
        try
        {
            while (!ct.IsCancellationRequested)
            {
                var line = await JsonLine.ReadAsync(conn, ct: ct).ConfigureAwait(false);
                if (line is null) break;
                JsonObject? response;
                try { response = JsonNode.Parse(line) as JsonObject; }
                catch (JsonException)
                {
                    _log.LogWarning("Discarding malformed JSON from agent: {Line}", line);
                    continue;
                }
                if (response is null) continue;

                if (response["id"]?.GetValue<long>() is long id)
                {
                    TaskCompletionSource<JsonObject>? tcs;
                    lock (_gate) _pending.Remove(id, out tcs);
                    tcs?.TrySetResult(response);
                }
            }
        }
        catch (IOException) { }
        finally
        {
            lock (_gate)
            {
                _connection = null;
                foreach (var p in _pending.Values) p.TrySetException(new BridgeNotConnectedException());
                _pending.Clear();
            }
        }
    }

    /// <summary>Wait until the agent dials in (matches the macOS bridge's behavior).</summary>
    public Task WaitConnectedAsync(CancellationToken ct = default)
    {
        lock (_gate)
        {
            if (_connection is not null) return Task.CompletedTask;
            _connected ??= new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            return _connected.Task.WaitAsync(ct);
        }
    }

    public async Task<Tokens?> ReadAsync(CancellationToken ct = default)
    {
        var response = await RpcAsync(new JsonObject { ["op"] = "read" }, ct).ConfigureAwait(false);
        if (response["ok"]?.GetValue<bool>() != true)
        {
            throw new AgentRejectedException(
                response["reason"]?.GetValue<string>() ?? "unknown reason");
        }
        var access = response["access"]?.GetValue<string>();
        var refresh = response["refresh"]?.GetValue<string>();
        if (access is null || refresh is null) return null;
        return new Tokens(access, refresh);
    }

    public async Task WriteAsync(string access, string refresh, CancellationToken ct = default)
    {
        var response = await RpcAsync(new JsonObject
        {
            ["op"] = "write",
            ["access"] = access,
            ["refresh"] = refresh,
        }, ct).ConfigureAwait(false);
        if (response["ok"]?.GetValue<bool>() != true)
        {
            throw new AgentRejectedException(
                response["reason"]?.GetValue<string>() ?? "unknown reason");
        }
    }

    private async Task<JsonObject> RpcAsync(JsonObject payload, CancellationToken ct)
    {
        Stream conn;
        long id;
        TaskCompletionSource<JsonObject> tcs = new(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (_gate)
        {
            if (_connection is null) throw new BridgeNotConnectedException();
            conn = _connection;
            id = ++_idSeq;
            _pending[id] = tcs;
        }
        payload["id"] = id;
        await JsonLine.WriteAsync(conn, payload.ToJsonString(), ct).ConfigureAwait(false);
        using var reg = ct.Register(() =>
        {
            lock (_gate) _pending.Remove(id);
            tcs.TrySetCanceled(ct);
        });
        return await tcs.Task.ConfigureAwait(false);
    }

    public ValueTask DisposeAsync()
    {
        lock (_gate)
        {
            foreach (var p in _pending.Values)
            {
                p.TrySetException(new BridgeNotConnectedException());
            }
            _pending.Clear();
            _connection = null;
        }
        return ValueTask.CompletedTask;
    }

    public sealed record Tokens(string Access, string Refresh);

    public sealed class BridgeNotConnectedException : Exception
    {
        public BridgeNotConnectedException() : base("Claude token agent isn't connected yet") { }
    }
    public sealed class AgentRejectedException : Exception
    {
        public AgentRejectedException(string reason) : base($"VM agent refused the request: {reason}") { }
    }
}
