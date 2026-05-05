using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Bromure.SandboxEngine.Vsock;

/// <summary>
/// Twin of <see cref="SubscriptionTokenBridge"/> for Codex / ChatGPT.
/// Vsock port 8447, three-token shape (access + refresh + id_token).
/// Same security invariant: real values flow VM→host only, fakes flow
/// host→VM only.
/// </summary>
public sealed class CodexTokenBridge : IAsyncDisposable
{
    public const uint Port = 8447;

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

    public CodexTokenBridge(ILogger? log = null) => _log = log ?? NullLogger.Instance;

    public void RegisterOn(VsockBridge bridge) => bridge.Listen(Port, HandleConnectionAsync);

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
                catch (JsonException) { continue; }
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
                foreach (var p in _pending.Values) p.TrySetException(new NotConnected());
                _pending.Clear();
            }
        }
    }

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
        var resp = await RpcAsync(new JsonObject { ["op"] = "read" }, ct).ConfigureAwait(false);
        if (resp["ok"]?.GetValue<bool>() != true)
        {
            throw new AgentRejected(resp["reason"]?.GetValue<string>() ?? "unknown reason");
        }
        var a = resp["access"]?.GetValue<string>();
        var r = resp["refresh"]?.GetValue<string>();
        var id = resp["id_token"]?.GetValue<string>();
        if (a is null || r is null || id is null) return null;
        return new Tokens(a, r, id);
    }

    public async Task WriteAsync(string access, string refresh, string idToken, CancellationToken ct = default)
    {
        var resp = await RpcAsync(new JsonObject
        {
            ["op"] = "write",
            ["access"] = access,
            ["refresh"] = refresh,
            ["id_token"] = idToken,
        }, ct).ConfigureAwait(false);
        if (resp["ok"]?.GetValue<bool>() != true)
        {
            throw new AgentRejected(resp["reason"]?.GetValue<string>() ?? "unknown reason");
        }
    }

    private async Task<JsonObject> RpcAsync(JsonObject payload, CancellationToken ct)
    {
        Stream conn;
        long id;
        var tcs = new TaskCompletionSource<JsonObject>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (_gate)
        {
            if (_connection is null) throw new NotConnected();
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
            foreach (var p in _pending.Values) p.TrySetException(new NotConnected());
            _pending.Clear();
            _connection = null;
        }
        return ValueTask.CompletedTask;
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
