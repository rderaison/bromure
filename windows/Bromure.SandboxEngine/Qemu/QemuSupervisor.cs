using System.Diagnostics;
using System.Text.Json.Nodes;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Bromure.SandboxEngine.Qemu;

/// <summary>
/// Spawns and supervises a single <c>qemu-system-x86_64</c> process under
/// WHPX. Plays the role <c>VZVirtualMachine</c> + <c>VZVirtualMachineDelegate</c>
/// play on macOS — start, wait for boot, listen for lifecycle events, request
/// shutdown, force-kill on hang.
/// </summary>
public sealed class QemuSupervisor : IAsyncDisposable
{
    private readonly QemuConfig _config;
    private readonly ILogger _log;
    private Process? _process;
    private QmpClient? _qmp;
    private Task? _eventPumpTask;
    private CancellationTokenSource? _eventPumpCts;

    /// <summary>Last 200 lines QEMU has written to stderr.</summary>
    private readonly object _stderrLock = new();
    private readonly LinkedList<string> _stderrTail = new();
    private const int StderrTailMax = 200;
    private StreamWriter? _stderrFile;

    public QemuSupervisor(QemuConfig config, ILogger? log = null)
    {
        _config = config;
        _log = log ?? NullLogger.Instance;
    }

    /// <summary>
    /// Snapshot of the last <see cref="StderrTailMax"/> stderr lines QEMU
    /// has emitted. Used by the SessionView to surface boot failures
    /// (the "could not connect to QMP" error message tells you the
    /// supervisor failed to handshake but not <i>why</i> — this gives
    /// the why).
    /// </summary>
    public string StderrTail
    {
        get { lock (_stderrLock) return string.Join('\n', _stderrTail); }
    }

    /// <summary>Path on disk where every byte of stderr is also being captured.</summary>
    public string? StderrLogPath { get; private set; }

    /// <summary>Raised after QMP handshake completes (analogous to VZ's "running" callback).</summary>
    public event Action? Running;

    /// <summary>Raised when the guest performs an ACPI shutdown.</summary>
    public event Action? GuestShutdown;

    /// <summary>Raised when the guest panics, OOMs, or QEMU exits unexpectedly.</summary>
    public event Action<Exception>? Crashed;

    public Process Process => _process ?? throw new InvalidOperationException("Not started");

    public QmpClient Qmp => _qmp ?? throw new InvalidOperationException("Not started");

    public bool IsRunning => _process is { HasExited: false };

    public async Task StartAsync(CancellationToken ct = default)
    {
        if (_process is not null) throw new InvalidOperationException("Already started");

        // Resolve QMP endpoint from QemuConfig.QmpEndpoint. The supervisor
        // owns the network/pipe lifecycle; the builder just emits the flag.
        var endpoint = NormaliseQmpEndpoint(_config.QmpEndpoint);
        var args = QemuCommandBuilder.Build(_config);

        var psi = new ProcessStartInfo
        {
            FileName = _config.QemuExecutable,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardError = true,
            RedirectStandardOutput = true,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);

        _log.LogInformation("Starting QEMU: {CommandLine}",
            QemuCommandBuilder.ToDiagnosticString(_config.QemuExecutable, args));

        _process = new Process { StartInfo = psi, EnableRaisingEvents = true };
        _process.Exited += OnQemuExited;
        // Open the per-session stderr log file before starting QEMU so
        // we don't race the first lines.
        if (!string.IsNullOrEmpty(_config.StderrLogFile))
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(_config.StderrLogFile)!);
                _stderrFile = new StreamWriter(_config.StderrLogFile, append: false) { AutoFlush = true };
                StderrLogPath = _config.StderrLogFile;
            }
            catch (IOException ex)
            {
                _log.LogWarning(ex, "Could not open QEMU stderr log file at {Path}", _config.StderrLogFile);
            }
        }

        if (!_process.Start())
        {
            throw new InvalidOperationException("QEMU failed to start (Process.Start returned false)");
        }

        _ = Task.Run(() => RelayStream(_process.StandardError, "qemu.err", capture: true));
        _ = Task.Run(() => RelayStream(_process.StandardOutput, "qemu.out", capture: false));

        // Connect QMP. QEMU opens the listener slightly after process start.
        // 30 s is generous: WHPX partition init + SDL window creation can
        // burn a few seconds each on machines with heavy GPU drivers or
        // VBS/Hyper-V holding partition resources. The earlier 5 s
        // timeout was too tight for those hosts.
        var qmpTimeout = TimeSpan.FromSeconds(30);
        try
        {
            _qmp = await ConnectWithBackoffAsync(endpoint, qmpTimeout, ct).ConfigureAwait(false);
        }
        catch (TimeoutException ex)
        {
            // Drain a moment so the stderr relay catches the last lines.
            await Task.Delay(200, ct).ConfigureAwait(false);
            var alive = _process is { HasExited: false };
            var tail = StderrTail;
            var detail = alive
                ? $"QEMU process (pid {_process.Id}) is still running but didn't open the QMP socket "
                  + $"on {endpoint} in {qmpTimeout.TotalSeconds:F0}s.\n\n"
                  + "Likely causes:\n"
                  + "  - -display sdl is slow to initialise (DisplayMode.None to verify)\n"
                  + "  - WHPX partition init held up by Hyper-V / VBS\n"
                  + "  - QMP port already taken by another process\n"
                  + "  - Antivirus inspecting QEMU's network bind\n\n"
                  + "Last QEMU stderr lines:\n" + (string.IsNullOrEmpty(tail) ? "(none)" : tail)
                : $"QEMU exited with code {_process.ExitCode} before opening QMP.\n\n"
                  + "Last QEMU stderr lines:\n" + (string.IsNullOrEmpty(tail) ? "(none)" : tail);
            throw new QemuStartException(
                "QEMU failed to start.",
                stderrTail: detail,
                stderrLogPath: StderrLogPath,
                inner: ex);
        }
        _eventPumpCts = new CancellationTokenSource();
        _eventPumpTask = Task.Run(() => PumpEventsAsync(_eventPumpCts.Token));

        Running?.Invoke();
    }

    private async Task<QmpClient> ConnectWithBackoffAsync(string endpoint, TimeSpan timeout, CancellationToken ct)
    {
        var deadline = DateTime.UtcNow + timeout;
        Exception? last = null;
        var delay = TimeSpan.FromMilliseconds(50);
        while (DateTime.UtcNow < deadline)
        {
            try
            {
                return await QmpClient.ConnectAsync(endpoint, ct).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is IOException or System.Net.Sockets.SocketException or TimeoutException)
            {
                last = ex;
                await Task.Delay(delay, ct).ConfigureAwait(false);
                delay = TimeSpan.FromMilliseconds(Math.Min(delay.TotalMilliseconds * 1.5, 500));
            }
        }
        throw new TimeoutException($"Could not connect to QMP at {endpoint}", last);
    }

    private async Task PumpEventsAsync(CancellationToken ct)
    {
        if (_qmp is null) return;
        try
        {
            await foreach (var ev in _qmp.Events(ct).ConfigureAwait(false))
            {
                var name = ev["event"]?.GetValue<string>();
                _log.LogDebug("QMP event: {Event}", name);
                switch (name)
                {
                    case "SHUTDOWN":
                        GuestShutdown?.Invoke();
                        break;
                    case "GUEST_PANICKED":
                        Crashed?.Invoke(new InvalidOperationException("guest panicked"));
                        break;
                }
            }
        }
        catch (OperationCanceledException) { }
    }

    private async Task RelayStream(StreamReader reader, string tag, bool capture)
    {
        try
        {
            while (await reader.ReadLineAsync().ConfigureAwait(false) is { } line)
            {
                _log.LogDebug("[{Tag}] {Line}", tag, line);
                if (capture)
                {
                    lock (_stderrLock)
                    {
                        _stderrTail.AddLast(line);
                        while (_stderrTail.Count > StderrTailMax) _stderrTail.RemoveFirst();
                    }
                    try
                    {
                        _stderrFile?.WriteLine(line);
                    }
                    catch (IOException) { }
                }
            }
        }
        catch (IOException) { }
    }

    private void OnQemuExited(object? sender, EventArgs e)
    {
        if (_process is null) return;
        if (_process.ExitCode != 0)
        {
            Crashed?.Invoke(new InvalidOperationException(
                $"QEMU exited with code {_process.ExitCode}"));
        }
    }

    /// Graceful shutdown: ACPI power button via QMP, then 10 s grace, then SIGKILL.
    public async Task ShutdownAsync(TimeSpan? grace = null, CancellationToken ct = default)
    {
        var deadline = DateTime.UtcNow + (grace ?? TimeSpan.FromSeconds(10));
        if (_qmp is not null)
        {
            try { await _qmp.ExecuteAsync("system_powerdown", ct: ct).ConfigureAwait(false); }
            catch { /* fall through to kill */ }
        }
        while (_process is { HasExited: false } && DateTime.UtcNow < deadline)
        {
            await Task.Delay(100, ct).ConfigureAwait(false);
        }
        if (_process is { HasExited: false })
        {
            try { _process.Kill(); } catch { }
        }
    }

    public async ValueTask DisposeAsync()
    {
        try { _eventPumpCts?.Cancel(); } catch { }
        if (_eventPumpTask is not null) { try { await _eventPumpTask.ConfigureAwait(false); } catch { } }
        if (_qmp is not null) await _qmp.DisposeAsync().ConfigureAwait(false);
        if (_process is { HasExited: false })
        {
            try { _process.Kill(); } catch { }
        }
        _process?.Dispose();
        try { _stderrFile?.Dispose(); } catch { }
    }

    /// QemuConfig.QmpEndpoint uses "tcp:" / "pipe:" prefixes. The QEMU
    /// command-line uses unprefixed "tcp:host:port,server" / "unix:..."
    /// formats. Let callers write the friendlier form and translate here.
    private static string NormaliseQmpEndpoint(string endpoint)
    {
        // For QmpClient.ConnectAsync we keep "tcp:..." / "pipe:..." as-is.
        // For the QEMU -qmp flag we substitute. QemuCommandBuilder pulls
        // straight from QemuConfig.QmpEndpoint, so we expect callers to
        // write QEMU-compatible forms ("tcp:127.0.0.1:4444", "unix:..."
        // — or for pipe, callers should set up an external bridge).
        return endpoint;
    }
}
