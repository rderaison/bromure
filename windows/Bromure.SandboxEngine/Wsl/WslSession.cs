using System.Diagnostics;
using System.Text;

namespace Bromure.SandboxEngine.Wsl;

/// <summary>
/// One Bromure session = one WSL distro (imported from
/// <c>bromure-base.tar.gz</c>) + one running kitty process inside it.
/// The kitty window is what the host shell embeds via
/// <c>WslWindowHost</c>.
///
/// <para>Replaces what <see cref="Qemu.QemuSupervisor"/> did for the
/// QEMU port, minus the hypervisor lifetime — WSL2's utility VM is
/// shared across all distros.</para>
///
/// <para>StartAsync sequence:</para>
/// <list type="number">
///   <item>Import the distro from <see cref="WslSessionConfig.BaseRootfsPath"/>.</item>
///   <item>Drop the per-session home overlay (dotfiles, env file, CA
///   cert) directly into <c>\\wsl$\&lt;distro&gt;\home\bromure\</c>
///   via Windows-side file IO. The <c>chown</c> step makes them
///   owned by the bromure user.</item>
///   <item>Drop the Bromure CA certificate into
///   <c>/usr/local/share/ca-certificates/bromure/</c> and run
///   <c>update-ca-certificates</c> so HTTPS_PROXY MITM works
///   transparently.</item>
///   <item>Spawn <c>wsl -d &lt;distro&gt; -- env … kitty</c>. The
///   spawned <see cref="Process"/> is exposed via
///   <see cref="WslProcess"/> so the host shell can find the
///   matching WSLg HWND.</item>
/// </list>
/// </summary>
public sealed class WslSession : IAsyncDisposable
{
    private readonly WslSessionConfig _cfg;
    private WslDistro? _distro;
    private Process? _wslProcess;
    private bool _disposed;

    public WslSession(WslSessionConfig cfg)
    {
        _cfg = cfg ?? throw new ArgumentNullException(nameof(cfg));
    }

    /// <summary>The underlying distro once <see cref="StartAsync"/> has run.</summary>
    public WslDistro Distro =>
        _distro ?? throw new InvalidOperationException("Session not started");

    /// <summary>The wsl.exe process that hosts the in-distro command (e.g. kitty).
    /// The PID is the wsl.exe spawn, not the in-distro PID — the host shell
    /// uses it to find the matching WSLg HWND via <c>EnumWindows</c>.</summary>
    public Process? WslProcess => _wslProcess;

    public async Task StartAsync(CancellationToken ct = default)
    {
        if (_distro is not null) throw new InvalidOperationException("Already started");

        // 1) Import the distro from the baked rootfs.
        _distro = new WslDistro(_cfg.DistroName, _cfg.InstallPath);
        await _distro.ImportAsync(_cfg.BaseRootfsPath, ct).ConfigureAwait(false);

        // 2) Drop the per-session home overlay. We write directly to
        // \\wsl$\<distro>\home\bromure\ via 9p — works because WSL2
        // mounts the distro's filesystem under that UNC path with
        // read/write access from Windows.
        await DropHomeOverlayAsync(ct).ConfigureAwait(false);

        // 3) Drop the Bromure CA cert into the distro and run
        // update-ca-certificates so the MITM proxy's signed certs
        // are trusted by curl/git/node/openssl/etc inside the
        // distro. Skipped if the caller didn't supply one (e.g.
        // smoke spike).
        if (_cfg.BromureCaPem is { Length: > 0 })
        {
            await InstallCaCertAsync(ct).ConfigureAwait(false);
        }

        // 4) Spawn the user-facing process (kitty). Don't await —
        // the wsl.exe call stays alive for the kitty session's
        // lifetime; await would block indefinitely. We capture the
        // Process so the embed step can find its HWND.
        _wslProcess = SpawnGuestProcess();
    }

    private async Task DropHomeOverlayAsync(CancellationToken ct)
    {
        // \\wsl$\<distro>\home\bromure (or whatever WslSessionConfig.GuestUser
        // says). We can write directly here since WSL2 mounts the distro
        // filesystem read-write to Windows — much cleaner than tar-extracting
        // inside the distro like the QEMU port had to.
        var homeRoot = $@"\\wsl$\{_cfg.DistroName}\home\{_cfg.GuestUser}";

        // The distro might still be spinning up systemd at first
        // touch — give it a couple of seconds to mount.
        await WaitForPathAsync(homeRoot, TimeSpan.FromSeconds(10), ct).ConfigureAwait(false);

        foreach (var (relPath, bytes) in _cfg.HomeFiles)
        {
            var full = Path.Combine(homeRoot, relPath.Replace('/', Path.DirectorySeparatorChar));
            Directory.CreateDirectory(Path.GetDirectoryName(full)!);
            await File.WriteAllBytesAsync(full, bytes, ct).ConfigureAwait(false);
        }

        // chown everything we just wrote so the bromure user owns it.
        // Files written via 9p land as root:root by default on the
        // distro side because that's the SID-mapped Windows user.
        if (_cfg.HomeFiles.Count > 0)
        {
            var chown = await _distro!.LaunchAsync(
                new[] { "chown", "-R", $"{_cfg.GuestUser}:{_cfg.GuestUser}", $"/home/{_cfg.GuestUser}" },
                user: "root",
                ct: ct).ConfigureAwait(false);
            chown.ThrowIfFailed("chown /home overlay");
        }
    }

    private async Task InstallCaCertAsync(CancellationToken ct)
    {
        // Bromure's CA root in PEM form. update-ca-certificates expects
        // a .crt extension and the file under /usr/local/share/ca-certificates/.
        //
        // We can't write to /usr/local/... via the \\wsl$\ 9p path:
        // 9p access is NOT root, so writing under /usr/ raises
        // UnauthorizedAccessException. Instead, pipe the cert bytes as
        // stdin to `tee` running as root inside the distro. setup-wsl.sh
        // already created the bromure subdirectory at bake time.
        var argList = new List<string>
        {
            "-d", _cfg.DistroName,
            "--user", "root",
            "--",
            "tee", "/usr/local/share/ca-certificates/bromure/bromure-ca.crt",
        };
        using var caStream = new MemoryStream(_cfg.BromureCaPem!);
        var tee = await WslCli.RunAsync(argList, ct, stdinSource: caStream).ConfigureAwait(false);
        tee.ThrowIfFailed("write bromure-ca.crt via tee");

        var update = await _distro!.LaunchAsync(
            new[] { "update-ca-certificates" },
            user: "root",
            ct: ct).ConfigureAwait(false);
        update.ThrowIfFailed("update-ca-certificates");
    }

    private Process SpawnGuestProcess()
    {
        // Build: wsl -d <distro> --user bromure --cd /home/bromure -- <argv...>
        // Env vars are passed into the distro via WSLENV — the wsl.exe-
        // documented mechanism. Setting `env A=B` in argv didn't work
        // (wsl.exe re-quotes, single quotes get mangled). WSLENV makes
        // wsl.exe explicitly forward listed Windows-side env vars
        // into the distro's environment.
        var argList = new List<string>
        {
            "-d", _cfg.DistroName,
            "--user", _cfg.GuestUser,
            "--cd", $"/home/{_cfg.GuestUser}",
            "--",
        };
        argList.AddRange(_cfg.GuestArgv);

        var psi = new ProcessStartInfo
        {
            FileName = "wsl.exe",
            UseShellExecute = false,
            CreateNoWindow = true,
            // Capture stderr to a log file so failures of kitty/agent
            // commands are visible after the fact. WSLg-rendered windows
            // don't need stdout/stderr to draw, so redirecting is safe.
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        psi.Environment["WSL_UTF8"] = "1";

        // WSLENV — colon-delimited list of Windows env vars to inject
        // into the distro. Each var must also be set in psi.Environment;
        // wsl.exe's launcher reads them and forwards into the distro
        // process's environment. The /u flag means "Unix-style" — no
        // path translation (we want raw values, not /mnt/c rewriting).
        if (_cfg.EnvVars.Count > 0)
        {
            var wslenvNames = new List<string>(_cfg.EnvVars.Count);
            foreach (var (k, v) in _cfg.EnvVars)
            {
                psi.Environment[k] = v;
                wslenvNames.Add(k + "/u");
            }
            psi.Environment["WSLENV"] = string.Join(':', wslenvNames);
        }

        foreach (var a in argList) psi.ArgumentList.Add(a);

        var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
        if (!p.Start())
        {
            throw new InvalidOperationException("Failed to spawn wsl.exe for the guest process");
        }

        // Drain stderr/stdout into a per-session log file alongside the
        // distro's install path. Async — runs for the lifetime of the
        // wsl.exe process. A blocking read would freeze us.
        var logPath = Path.Combine(_cfg.InstallPath, "wsl-stderr.log");
        try { Directory.CreateDirectory(_cfg.InstallPath); } catch { }
        _ = Task.Run(async () =>
        {
            try
            {
                using var w = new StreamWriter(logPath, append: false) { AutoFlush = true };
                await w.WriteLineAsync($"[wsl-spawn] argv: {string.Join(' ', argList)}").ConfigureAwait(false);
                var stderrTask = Task.Run(async () =>
                {
                    string? line;
                    while ((line = await p.StandardError.ReadLineAsync().ConfigureAwait(false)) != null)
                        await w.WriteLineAsync("[stderr] " + line).ConfigureAwait(false);
                });
                var stdoutTask = Task.Run(async () =>
                {
                    string? line;
                    while ((line = await p.StandardOutput.ReadLineAsync().ConfigureAwait(false)) != null)
                        await w.WriteLineAsync("[stdout] " + line).ConfigureAwait(false);
                });
                await Task.WhenAll(stderrTask, stdoutTask).ConfigureAwait(false);
                await w.WriteLineAsync($"[wsl-spawn] process exited code={p.ExitCode}").ConfigureAwait(false);
            }
            catch { /* best-effort */ }
        });

        return p;
    }

    private static async Task WaitForPathAsync(string path, TimeSpan timeout, CancellationToken ct)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            if (Directory.Exists(path)) return;
            await Task.Delay(150, ct).ConfigureAwait(false);
        }
        throw new IOException($"WSL distro path never appeared: {path}");
    }

    public async Task ShutdownAsync(CancellationToken ct = default)
    {
        // Kill the spawned wsl.exe (which terminates kitty); then ask
        // WSL to stop the distro entirely.
        if (_wslProcess is { HasExited: false })
        {
            try { _wslProcess.Kill(entireProcessTree: true); } catch { }
        }
        _wslProcess?.Dispose();
        _wslProcess = null;

        if (_distro is not null)
        {
            try { await _distro.TerminateAsync(ct).ConfigureAwait(false); } catch { }
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true;
        await ShutdownAsync().ConfigureAwait(false);
        if (_distro is not null)
        {
            try { await _distro.DisposeAsync().ConfigureAwait(false); } catch { }
            _distro = null;
        }
    }
}

/// <summary>Inputs for one <see cref="WslSession"/> launch.</summary>
public sealed record WslSessionConfig
{
    /// <summary>Path to the baked <c>bromure-base.tar.gz</c>.</summary>
    public required string BaseRootfsPath { get; init; }

    /// <summary>Unique distro name for this session — gets passed to
    /// <c>wsl --import</c>. Use a per-session GUID-derived form so
    /// concurrent sessions don't collide.</summary>
    public required string DistroName { get; init; }

    /// <summary>Where WSL stores the distro's <c>ext4.vhdx</c>. Caller
    /// picks something disposable under <c>%LOCALAPPDATA%\Bromure</c>.</summary>
    public required string InstallPath { get; init; }

    /// <summary>Default user inside the distro (set up in setup-wsl.sh).</summary>
    public string GuestUser { get; init; } = "bromure";

    /// <summary>argv to spawn inside the distro. Default: kitty fullscreen.</summary>
    public IReadOnlyList<string> GuestArgv { get; init; } = new[]
    {
        "kitty", "--start-as=fullscreen",
    };

    /// <summary>Files to drop under <c>/home/&lt;GuestUser&gt;/</c>. Keys
    /// are slash-separated relative paths; values are raw bytes.
    /// Produced by <c>SessionHomeBuilder.Build(profile)</c>.</summary>
    public IReadOnlyDictionary<string, byte[]> HomeFiles { get; init; } =
        new Dictionary<string, byte[]>();

    /// <summary>Environment variables to set when spawning the guest
    /// argv. Includes <c>HTTPS_PROXY</c>, <c>HTTP_PROXY</c>,
    /// <c>SSL_CERT_FILE</c>, <c>ANTHROPIC_API_KEY</c>, etc — the
    /// per-tab profile env Bromure-AC produces for its agent runs.</summary>
    public IReadOnlyDictionary<string, string> EnvVars { get; init; } =
        new Dictionary<string, string>();

    /// <summary>PEM-encoded CA certificate the host's MITM proxy signs
    /// with. Installed at <c>/usr/local/share/ca-certificates/bromure/bromure-ca.crt</c>
    /// and trusted via <c>update-ca-certificates</c>. Null skips the
    /// install (useful for smoke tests against a real upstream).</summary>
    public byte[]? BromureCaPem { get; init; }
}
