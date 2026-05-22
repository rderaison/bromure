// macos-source: Sources/SandboxEngine/SerialConsole.swift @ fe7e7d3a3e21
using System.IO.Pipes;
using System.Text;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Bromure.SandboxEngine.Hcs;

/// <summary>
/// Same expect-style serial driver as <see cref="Qemu.SerialDriver"/>
/// but talks to a Hyper-V <c>Set-VMComPort</c> named pipe instead of a
/// TCP socket. We use this to drive the Alpine bake VM's serial
/// console — login, mount setup ISO, run setup.sh, watch for the
/// SANDBOX_SETUP_DONE marker.
///
/// <para><b>Path shape.</b> Hyper-V exposes COM ports as Windows named
/// pipes under <c>\\.\pipe\&lt;name&gt;</c>. The bake VM sets COM1's
/// pipe to <c>\\.\pipe\bromure-bake-&lt;id&gt;</c>; this driver
/// connects with <see cref="NamedPipeClientStream"/> in
/// <see cref="PipeDirection.InOut"/>.</para>
///
/// <para><b>Why a new file</b> instead of reusing the TCP driver: the
/// QEMU codebase isn't loaded on the HCS-path session executable, and
/// adding a transport abstraction layer is more code than just
/// copying ~170 lines. The two share no instance state.</para>
/// </summary>
public sealed class NamedPipeSerialDriver : IAsyncDisposable
{
    private readonly string _pipeName;
    private readonly ILogger _log;
    private readonly Action<string>? _onChunk;
    private readonly StringBuilder _buffer = new();
    private readonly object _bufferLock = new();
    private readonly CancellationTokenSource _cts = new();
    private NamedPipeClientStream? _stream;
    private Task? _readLoop;
    private const int BufferMaxBytes = 256 * 1024;

    /// <param name="pipeName">Just the leaf name — the part after
    /// <c>\\.\pipe\</c>. <see cref="NamedPipeClientStream"/> takes
    /// "." (local) + the name separately.</param>
    public NamedPipeSerialDriver(string pipeName, Action<string>? onChunk = null,
        ILogger? log = null)
    {
        _pipeName = pipeName;
        _onChunk = onChunk;
        _log = log ?? NullLogger.Instance;
    }

    /// <summary>Connect with retry/backoff. Hyper-V's named pipe server
    /// only appears once Set-VMComPort has run; if we're called too
    /// early we get FILE_NOT_FOUND. Retry up to
    /// <paramref name="connectTimeout"/>.</summary>
    public async Task ConnectAsync(TimeSpan connectTimeout, CancellationToken ct = default)
    {
        var deadline = DateTime.UtcNow + connectTimeout;
        Exception? last = null;
        var delay = TimeSpan.FromMilliseconds(100);
        while (DateTime.UtcNow < deadline && !ct.IsCancellationRequested)
        {
            try
            {
                _stream = new NamedPipeClientStream(
                    serverName: ".",
                    pipeName: _pipeName,
                    direction: PipeDirection.InOut,
                    options: PipeOptions.Asynchronous);
                await _stream.ConnectAsync((int)Math.Min(2000, delay.TotalMilliseconds + 500), ct)
                    .ConfigureAwait(false);
                _readLoop = Task.Run(() => ReadLoopAsync(_cts.Token));
                return;
            }
            catch (Exception ex)
            {
                last = ex;
                try { _stream?.Dispose(); } catch { }
                _stream = null;
                await Task.Delay(delay, ct).ConfigureAwait(false);
                delay = TimeSpan.FromMilliseconds(Math.Min(delay.TotalMilliseconds * 1.5, 1000));
            }
        }
        throw new TimeoutException(
            "Could not attach to named pipe \\\\.\\pipe\\" + _pipeName, last);
    }

    /// <summary>Send literal bytes to the guest's stdin (the COM-port
    /// receiving end). Caller supplies trailing <c>\n</c> when emulating
    /// a typed line.</summary>
    public async Task SendAsync(string text, CancellationToken ct = default)
    {
        if (_stream is null) throw new InvalidOperationException("ConnectAsync first");
        var bytes = Encoding.UTF8.GetBytes(text);
        await _stream.WriteAsync(bytes, ct).ConfigureAwait(false);
        await _stream.FlushAsync(ct).ConfigureAwait(false);
    }

    /// <summary>Wait until <paramref name="marker"/> appears in the
    /// rolling output buffer, or <paramref name="timeout"/> elapses,
    /// or any of <paramref name="failures"/> shows up first.</summary>
    public async Task<int> WaitForAsync(string marker, TimeSpan timeout,
        IReadOnlyList<string>? failures = null, CancellationToken ct = default)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            ct.ThrowIfCancellationRequested();
            string snap;
            lock (_bufferLock) { snap = _buffer.ToString(); }
            if (failures is not null)
            {
                foreach (var f in failures)
                {
                    var idx = snap.IndexOf(f, StringComparison.Ordinal);
                    if (idx >= 0)
                    {
                        var line = snap[idx..].Split('\n').FirstOrDefault() ?? f;
                        throw new SerialFailureException(line.TrimEnd());
                    }
                }
            }
            var match = snap.IndexOf(marker, StringComparison.Ordinal);
            if (match >= 0) return match;
            await Task.Delay(100, ct).ConfigureAwait(false);
        }
        var tail = string.Empty;
        lock (_bufferLock)
        {
            var s = _buffer.ToString();
            tail = s.Length > 2048 ? s[^2048..] : s;
        }
        throw new TimeoutException(
            "WaitFor('" + marker + "') timed out after " +
            timeout.TotalSeconds.ToString("F0") + "s. Tail:\n" + tail);
    }

    /// <summary>Snapshot the entire rolling buffer — for diagnostic
    /// post-mortem after a failed bake.</summary>
    public string Snapshot()
    {
        lock (_bufferLock) { return _buffer.ToString(); }
    }

    private async Task ReadLoopAsync(CancellationToken ct)
    {
        if (_stream is null) return;
        var buf = new byte[16 * 1024];
        try
        {
            while (!ct.IsCancellationRequested)
            {
                var n = await _stream.ReadAsync(buf.AsMemory(), ct).ConfigureAwait(false);
                if (n == 0) break;
                // Serial output is byte-oriented; UTF-8 decode is best-
                // effort across chunk boundaries. Marker matching is
                // pure-ASCII so the occasional split codepoint is fine.
                var chunk = Encoding.UTF8.GetString(buf, 0, n);
                lock (_bufferLock)
                {
                    _buffer.Append(chunk);
                    if (_buffer.Length > BufferMaxBytes)
                    {
                        _buffer.Remove(0, _buffer.Length - BufferMaxBytes);
                    }
                }
                try { _onChunk?.Invoke(chunk); }
                catch (Exception ex)
                {
                    _log.LogDebug(ex, "named-pipe serial onChunk subscriber threw");
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (IOException) { /* pipe broken — VM shut down */ }
    }

    public async ValueTask DisposeAsync()
    {
        try { _cts.Cancel(); } catch { }
        try { _stream?.Close(); } catch { }
        if (_readLoop is not null)
        {
            try { await _readLoop.ConfigureAwait(false); } catch { }
        }
        _cts.Dispose();
        _stream?.Dispose();
    }
}

/// <summary>Mirrors <see cref="Qemu.SerialFailureException"/> on the
/// HCS side. Thrown by <see cref="NamedPipeSerialDriver.WaitForAsync"/>
/// when a failure marker shows up before the success marker.</summary>
public sealed class SerialFailureException : Exception
{
    public SerialFailureException(string line) : base(line) { }
}
