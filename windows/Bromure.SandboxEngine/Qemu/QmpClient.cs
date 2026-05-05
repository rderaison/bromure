using System.IO.Pipes;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Threading.Channels;

namespace Bromure.SandboxEngine.Qemu;

/// <summary>
/// QEMU Machine Protocol client. Spec: https://qemu.readthedocs.io/en/latest/interop/qmp-spec.html
///
/// QMP is JSON-over-newline-framed bidirectional. Each side:
///   - sends a `{"execute": "...", "arguments": {...}}` request,
///   - and receives one of `{"return": ...}`, `{"error": ...}`, or `{"event": ...}`.
///
/// We accept two endpoint forms in <see cref="QemuConfig.QmpEndpoint"/>:
///   - <c>tcp:127.0.0.1:PORT</c>
///   - <c>pipe:NAME</c> for a Windows named pipe (preferred for shipping).
/// </summary>
public sealed class QmpClient : IAsyncDisposable
{
    private readonly Stream _stream;
    private readonly StreamReader _reader;
    private readonly StreamWriter _writer;
    private readonly Channel<JsonNode> _events = Channel.CreateUnbounded<JsonNode>(
        new UnboundedChannelOptions { SingleReader = false, SingleWriter = true });
    private readonly Dictionary<string, TaskCompletionSource<JsonNode>> _pending = new();
    private readonly object _pendingLock = new();
    private long _idSeq;
    private CancellationTokenSource? _readLoopCts;
    private Task? _readLoopTask;

    private QmpClient(Stream stream)
    {
        _stream = stream;
        _reader = new StreamReader(stream, Encoding.UTF8, leaveOpen: true);
        _writer = new StreamWriter(stream, new UTF8Encoding(false), leaveOpen: true) { NewLine = "\n", AutoFlush = true };
    }

    public IAsyncEnumerable<JsonNode> Events(CancellationToken ct = default)
        => _events.Reader.ReadAllAsync(ct);

    public static async Task<QmpClient> ConnectAsync(string endpoint, CancellationToken ct = default)
    {
        Stream stream;
        if (endpoint.StartsWith("tcp:", StringComparison.Ordinal))
        {
            // tcp:127.0.0.1:4444
            var hostPort = endpoint["tcp:".Length..];
            var lastColon = hostPort.LastIndexOf(':');
            var host = hostPort[..lastColon];
            var port = int.Parse(hostPort[(lastColon + 1)..], System.Globalization.CultureInfo.InvariantCulture);
            var tcp = new TcpClient();
            await tcp.ConnectAsync(host, port, ct).ConfigureAwait(false);
            stream = tcp.GetStream();
        }
        else if (endpoint.StartsWith("pipe:", StringComparison.Ordinal))
        {
            var name = endpoint["pipe:".Length..];
            var client = new NamedPipeClientStream(".", name, PipeDirection.InOut, PipeOptions.Asynchronous);
            await client.ConnectAsync(ct).ConfigureAwait(false);
            stream = client;
        }
        else
        {
            throw new ArgumentException($"Unrecognised QMP endpoint scheme: {endpoint}", nameof(endpoint));
        }

        var c = new QmpClient(stream);
        await c.HandshakeAsync(ct).ConfigureAwait(false);
        c.StartReadLoop();
        return c;
    }

    private async Task HandshakeAsync(CancellationToken ct)
    {
        // QMP greets with a `{"QMP": {"version": ...}}` line; we must
        // send `qmp_capabilities` before doing anything else.
        var greeting = await _reader.ReadLineAsync(ct).ConfigureAwait(false);
        if (greeting is null || !greeting.Contains("\"QMP\""))
        {
            throw new IOException("QMP greeting missing or malformed: " + (greeting ?? "<eof>"));
        }
        await _writer.WriteLineAsync("{\"execute\":\"qmp_capabilities\"}".AsMemory(), ct).ConfigureAwait(false);
        var ack = await _reader.ReadLineAsync(ct).ConfigureAwait(false);
        if (ack is null || !ack.Contains("\"return\""))
        {
            throw new IOException("qmp_capabilities ACK missing: " + (ack ?? "<eof>"));
        }
    }

    private void StartReadLoop()
    {
        _readLoopCts = new CancellationTokenSource();
        _readLoopTask = Task.Run(() => ReadLoopAsync(_readLoopCts.Token));
    }

    private async Task ReadLoopAsync(CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested)
            {
                var line = await _reader.ReadLineAsync(ct).ConfigureAwait(false);
                if (line is null) break;
                if (line.Length == 0) continue;
                JsonNode? node;
                try { node = JsonNode.Parse(line); }
                catch (JsonException) { continue; }
                if (node is null) continue;

                if (node["event"] is not null)
                {
                    _events.Writer.TryWrite(node);
                    continue;
                }
                var idNode = node["id"]?.GetValue<string>();
                if (idNode is null) continue;

                TaskCompletionSource<JsonNode>? tcs;
                lock (_pendingLock)
                {
                    _pending.Remove(idNode, out tcs);
                }
                tcs?.TrySetResult(node);
            }
        }
        catch (OperationCanceledException) { }
        catch (IOException) { }
        finally
        {
            _events.Writer.TryComplete();
            DrainPending(new IOException("QMP connection closed"));
        }
    }

    private void DrainPending(Exception cause)
    {
        lock (_pendingLock)
        {
            foreach (var tcs in _pending.Values) tcs.TrySetException(cause);
            _pending.Clear();
        }
    }

    public async Task<JsonNode> ExecuteAsync(string command, JsonObject? arguments = null, CancellationToken ct = default)
    {
        var id = "id" + Interlocked.Increment(ref _idSeq).ToString(System.Globalization.CultureInfo.InvariantCulture);
        var tcs = new TaskCompletionSource<JsonNode>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (_pendingLock) _pending[id] = tcs;

        var request = new JsonObject
        {
            ["execute"] = command,
            ["id"] = id,
        };
        if (arguments is not null) request["arguments"] = arguments;

        var json = request.ToJsonString();
        await _writer.WriteLineAsync(json.AsMemory(), ct).ConfigureAwait(false);

        using var reg = ct.Register(() => tcs.TrySetCanceled(ct));
        var response = await tcs.Task.ConfigureAwait(false);

        if (response["error"] is JsonNode err)
        {
            throw new QmpException(err.ToJsonString());
        }
        return response["return"] ?? new JsonObject();
    }

    public async Task QuitAsync(CancellationToken ct = default)
    {
        try { await ExecuteAsync("quit", null, ct).ConfigureAwait(false); }
        catch (IOException) { /* the VM closed the socket on us, expected */ }
        catch (QmpException) { /* same */ }
    }

    public async ValueTask DisposeAsync()
    {
        try { _readLoopCts?.Cancel(); } catch { }
        if (_readLoopTask is not null)
        {
            try { await _readLoopTask.ConfigureAwait(false); } catch { }
        }
        _reader.Dispose();
        _writer.Dispose();
        await _stream.DisposeAsync().ConfigureAwait(false);
    }
}

public sealed class QmpException : Exception
{
    public QmpException(string message) : base(message) { }
}

