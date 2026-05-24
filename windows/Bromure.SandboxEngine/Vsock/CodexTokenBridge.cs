// macos-source: Sources/AgentCoding/CodexTokenBridge.swift @ 8886701f30f0
using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Bromure.SandboxEngine.Vsock;

/// <summary>
/// Twin of <see cref="SubscriptionTokenBridge"/> for Codex / ChatGPT.
/// Vsock port 8447, three-token shape (access + refresh + id_token).
/// Same security invariant: real values flow VM→host only, fakes flow
/// host→VM only. Multiplexes by source VM ID — see Subscription's
/// docstring for why.
/// </summary>
public sealed class CodexTokenBridge : IAsyncDisposable
{
    public const uint Port = 8447;

    private readonly ILogger _log;
    private readonly ConcurrentDictionary<Guid, VmState> _byVm = new();

    public CodexTokenBridge(ILogger? log = null) => _log = log ?? NullLogger.Instance;

    public bool IsConnected(Guid vmId)
        => _byVm.TryGetValue(vmId, out var s) && s.IsConnected;

    public void RegisterOn(VsockBridge bridge) => bridge.Listen(Port, HandleConnectionAsync);

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
                catch (JsonException) { continue; }
                if (response is null) continue;

                // Defensive: GetValue<long>() throws on type-mismatch;
                // catching here keeps the read loop alive against a
                // misbehaving in-VM agent. See SubscriptionTokenBridge
                // for the rationale.
                if (SubscriptionTokenBridge.TryGetLong(response["id"]) is long id)
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
                foreach (var p in state.Pending.Values) p.TrySetException(new NotConnected());
                state.Pending.Clear();
            }
        }
    }

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
        var resp = await RpcAsync(vmId, new JsonObject { ["op"] = "read" }, ct).ConfigureAwait(false);
        if (SubscriptionTokenBridge.TryGetBool(resp["ok"]) != true)
        {
            throw new AgentRejected(SubscriptionTokenBridge.TryGetString(resp["reason"]) ?? "unknown reason");
        }
        var a = SubscriptionTokenBridge.TryGetString(resp["access"]);
        var r = SubscriptionTokenBridge.TryGetString(resp["refresh"]);
        var id = SubscriptionTokenBridge.TryGetString(resp["id_token"]);
        if (a is null || r is null || id is null) return null;
        return new Tokens(a, r, id);
    }

    public async Task WriteAsync(Guid vmId, string access, string refresh, string idToken, CancellationToken ct = default)
    {
        var resp = await RpcAsync(vmId, new JsonObject
        {
            ["op"] = "write",
            ["access"] = access,
            ["refresh"] = refresh,
            ["id_token"] = idToken,
        }, ct).ConfigureAwait(false);
        if (SubscriptionTokenBridge.TryGetBool(resp["ok"]) != true)
        {
            throw new AgentRejected(SubscriptionTokenBridge.TryGetString(resp["reason"]) ?? "unknown reason");
        }
    }

    /// <summary>Drop per-VM state on session teardown — see
    /// SubscriptionTokenBridge.Forget for rationale.</summary>
    public void Forget(Guid vmId)
    {
        if (_byVm.TryRemove(vmId, out var state))
        {
            lock (state.Gate)
            {
                state.Connection = null;
                foreach (var p in state.Pending.Values) p.TrySetException(new NotConnected());
                state.Pending.Clear();
            }
        }
    }

    private async Task<JsonObject> RpcAsync(Guid vmId, JsonObject payload, CancellationToken ct)
    {
        var state = GetOrAdd(vmId);
        Stream conn;
        long id;
        var tcs = new TaskCompletionSource<JsonObject>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (state.Gate)
        {
            if (state.Connection is null) throw new NotConnected();
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
                foreach (var p in state.Pending.Values) p.TrySetException(new NotConnected());
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

    public sealed record Tokens(string Access, string Refresh, string IdToken);

    public sealed class NotConnected : Exception
    {
        public NotConnected() : base("Codex token agent isn't connected yet") { }
    }
    public sealed class AgentRejected : Exception
    {
        public AgentRejected(string reason) : base($"VM agent refused the request: {reason}") { }
    }
}
