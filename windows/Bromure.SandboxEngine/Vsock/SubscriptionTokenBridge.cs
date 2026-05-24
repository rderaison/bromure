// macos-source: Sources/AgentCoding/SubscriptionTokenBridge.swift @ 7ef3f5dcd1e3
using System.Collections.Concurrent;
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
/// <b>Multi-VM multiplexing.</b> When several sessions run
/// concurrently, the host accepts connections from each VM on the
/// same port 8446 — the AF_HYPERV peer GUID is the routing key.
/// State per VM lives in a <see cref="ConcurrentDictionary{TKey,TValue}"/>,
/// and the public API takes a <c>vmId</c> on every call. The macOS
/// port uses one bridge per VZVirtioSocketDevice (intrinsically
/// per-VM); on Windows HCS has a single hvsocket listener per port,
/// so multiplexing has to live here.
///
/// <b>Security invariant.</b> The host NEVER sends real cleartext token
/// values to the VM. Only fakes flow host→VM. Only reals flow VM→host.
/// There is no RPC for "host hands me a real token." Same as macOS.
/// </summary>
public sealed class SubscriptionTokenBridge : IAsyncDisposable
{
    public const uint Port = 8446;

    private readonly ILogger _log;
    private readonly ConcurrentDictionary<Guid, VmState> _byVm = new();

    public SubscriptionTokenBridge(ILogger? log = null) => _log = log ?? NullLogger.Instance;

    public bool IsConnected(Guid vmId)
        => _byVm.TryGetValue(vmId, out var s) && s.IsConnected;

    /// <summary>Register on <paramref name="bridge"/>. Idempotent on the bridge side.</summary>
    public void RegisterOn(VsockBridge bridge)
    {
        bridge.Listen(Port, HandleConnectionAsync);
    }

    private VmState GetOrAdd(Guid vmId) => _byVm.GetOrAdd(vmId, _ => new VmState());

    private async Task HandleConnectionAsync(Stream conn, Guid sourceVmId, CancellationToken ct)
    {
        var state = GetOrAdd(sourceVmId);
        lock (state.Gate)
        {
            state.Connection = conn;
            state.Connected?.TrySetResult(true);
            state.Connected = null;
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
                    _log.LogWarning("Discarding malformed JSON from agent (vm={Vm}): {Line}", sourceVmId, line);
                    continue;
                }
                if (response is null) continue;

                // Defensive: GetValue<long>() throws InvalidOperationException
                // when the field isn't a JSON number (string, float, object).
                // A bad agent message must NOT kill the read loop — that
                // would hang every pending RPC and silently break autoseed.
                if (TryGetLong(response["id"]) is long id)
                {
                    TaskCompletionSource<JsonObject>? tcs;
                    lock (state.Gate) state.Pending.Remove(id, out tcs);
                    tcs?.TrySetResult(response);
                }
            }
        }
        catch (IOException) { }
        finally
        {
            lock (state.Gate)
            {
                state.Connection = null;
                foreach (var p in state.Pending.Values) p.TrySetException(new BridgeNotConnectedException());
                state.Pending.Clear();
            }
        }
    }

    /// <summary>Wait until the agent on <paramref name="vmId"/> dials in.</summary>
    public Task WaitConnectedAsync(Guid vmId, CancellationToken ct = default)
    {
        var state = GetOrAdd(vmId);
        lock (state.Gate)
        {
            if (state.Connection is not null) return Task.CompletedTask;
            state.Connected ??= new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            return state.Connected.Task.WaitAsync(ct);
        }
    }

    public async Task<Tokens?> ReadAsync(Guid vmId, CancellationToken ct = default)
    {
        var response = await RpcAsync(vmId, new JsonObject { ["op"] = "read" }, ct).ConfigureAwait(false);
        if (TryGetBool(response["ok"]) != true)
        {
            throw new AgentRejectedException(
                TryGetString(response["reason"]) ?? "unknown reason");
        }
        var access = TryGetString(response["access"]);
        var refresh = TryGetString(response["refresh"]);
        if (access is null || refresh is null) return null;
        return new Tokens(access, refresh);
    }

    // Defensive JsonNode accessors. JsonNode.GetValue<T>() throws
    // InvalidOperationException when the underlying value isn't the
    // requested type; in this codebase that crashes the read loop and
    // hangs every pending RPC. These helpers return null on type
    // mismatch so callers can decide whether the message is usable.
    internal static long? TryGetLong(JsonNode? n)
    {
        if (n is null) return null;
        try { return n.AsValue().TryGetValue<long>(out var v) ? v : null; }
        catch (InvalidOperationException) { return null; }
    }
    internal static bool? TryGetBool(JsonNode? n)
    {
        if (n is null) return null;
        try { return n.AsValue().TryGetValue<bool>(out var v) ? v : null; }
        catch (InvalidOperationException) { return null; }
    }
    internal static string? TryGetString(JsonNode? n)
    {
        if (n is null) return null;
        try { return n.AsValue().TryGetValue<string>(out var v) ? v : null; }
        catch (InvalidOperationException) { return null; }
    }

    public async Task WriteAsync(Guid vmId, string access, string refresh, CancellationToken ct = default)
    {
        var response = await RpcAsync(vmId, new JsonObject
        {
            ["op"] = "write",
            ["access"] = access,
            ["refresh"] = refresh,
        }, ct).ConfigureAwait(false);
        if (TryGetBool(response["ok"]) != true)
        {
            throw new AgentRejectedException(
                TryGetString(response["reason"]) ?? "unknown reason");
        }
    }

    /// <summary>Forget the VM's state (call on session teardown). The
    /// agent's connection, if still open, gets dropped on the next
    /// IO; pending RPCs fail with BridgeNotConnectedException so
    /// callers awaiting on a torn-down session don't hang.</summary>
    public void Forget(Guid vmId)
    {
        if (_byVm.TryRemove(vmId, out var state))
        {
            lock (state.Gate)
            {
                state.Connection = null;
                foreach (var p in state.Pending.Values)
                {
                    p.TrySetException(new BridgeNotConnectedException());
                }
                state.Pending.Clear();
            }
        }
    }

    private async Task<JsonObject> RpcAsync(Guid vmId, JsonObject payload, CancellationToken ct)
    {
        var state = GetOrAdd(vmId);
        Stream conn;
        long id;
        TaskCompletionSource<JsonObject> tcs = new(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (state.Gate)
        {
            if (state.Connection is null) throw new BridgeNotConnectedException();
            conn = state.Connection;
            id = ++state.IdSeq;
            state.Pending[id] = tcs;
        }
        payload["id"] = id;
        await JsonLine.WriteAsync(conn, payload.ToJsonString(), ct).ConfigureAwait(false);
        using var reg = ct.Register(() =>
        {
            lock (state.Gate) state.Pending.Remove(id);
            tcs.TrySetCanceled(ct);
        });
        return await tcs.Task.ConfigureAwait(false);
    }

    public ValueTask DisposeAsync()
    {
        foreach (var (_, state) in _byVm)
        {
            lock (state.Gate)
            {
                foreach (var p in state.Pending.Values)
                {
                    p.TrySetException(new BridgeNotConnectedException());
                }
                state.Pending.Clear();
                state.Connection = null;
            }
        }
        _byVm.Clear();
        return ValueTask.CompletedTask;
    }

    private sealed class VmState
    {
        public readonly object Gate = new();
        public Stream? Connection;
        public TaskCompletionSource<bool>? Connected;
        public long IdSeq;
        public readonly Dictionary<long, TaskCompletionSource<JsonObject>> Pending = new();

        public bool IsConnected
        {
            get { lock (Gate) return Connection is not null; }
        }
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
