using System.Diagnostics;
using System.Globalization;
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
    /// <summary>The name actually in use — equals <c>_cfg.DistroName</c>
    /// for cold imports, or the pool's chosen name when a warm
    /// distro was adopted.</summary>
    private string _effectiveDistroName = "";
    private string _effectiveInstallPath = "";

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

        // The whole pipeline does enough synchronous-ish I/O (UNC path
        // probing, wsl.exe spawns, WslCli stdin pipes) that running
        // it inline on the WPF UI thread freezes the window for ~15-20s
        // at the cold-import stage. Hand it off to the thread pool and
        // wrap a hard deadline so we don't hang the UI if WSL itself
        // gets stuck.
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(TimeSpan.FromSeconds(90));
        await Task.Run(() => StartAsyncImpl(deadline.Token), deadline.Token).ConfigureAwait(false);
    }

    private async Task StartAsyncImpl(CancellationToken ct)
    {
        var t0 = Stopwatch.StartNew();
        var phaseLog = new StringBuilder();
        void Phase(string name, long ms) => phaseLog.AppendLine(
            $"[wsl-start] {name} {ms} ms (total {t0.ElapsedMilliseconds} ms)");

        // 1) Import the distro from the baked rootfs — OR adopt a
        // pre-imported warm distro from the pool (skips the 8–15 s
        // cost on the user-visible launch path). When the warm
        // distro is adopted we keep its name + install path; the
        // session's effective DistroName is whatever the pool gave us.
        var phaseStart = t0.ElapsedMilliseconds;
        if (_cfg.WarmDistro is { } warm)
        {
            _distro = warm.Distro;
            _effectiveDistroName = warm.Distro.Name;
            _effectiveInstallPath = warm.InstallPath;
        }
        else
        {
            _distro = new WslDistro(_cfg.DistroName, _cfg.InstallPath);
            _effectiveDistroName = _cfg.DistroName;
            _effectiveInstallPath = _cfg.InstallPath;
            await _distro.ImportAsync(_cfg.BaseRootfsPath, ct).ConfigureAwait(false);
        }
        Phase(_cfg.WarmDistro is null ? "import" : "adopt-warm", t0.ElapsedMilliseconds - phaseStart);

        // 2) Drop the per-session home overlay. We write directly to
        // \\wsl$\<distro>\home\bromure\ via 9p — works because WSL2
        // mounts the distro's filesystem under that UNC path with
        // read/write access from Windows.
        phaseStart = t0.ElapsedMilliseconds;
        await DropHomeOverlayAsync(ct).ConfigureAwait(false);
        Phase("home-overlay", t0.ElapsedMilliseconds - phaseStart);

        // 3) Drop the Bromure CA cert into the distro and run
        // update-ca-certificates so the MITM proxy's signed certs
        // are trusted by curl/git/node/openssl/etc inside the
        // distro. Skipped if the caller didn't supply one (e.g.
        // smoke spike).
        if (_cfg.BromureCaPem is { Length: > 0 })
        {
            phaseStart = t0.ElapsedMilliseconds;
            await InstallCaCertAsync(ct).ConfigureAwait(false);
            Phase("ca-cert", t0.ElapsedMilliseconds - phaseStart);
        }

        // 4) Materialise any profile-configured shared folders as
        // symlinks under /home/<user>/<basename> → /mnt/<drive>/...
        // so the agent CLI can `cd ~/<basename>` and edit files
        // that round-trip to the Windows side immediately. WSL2's
        // DrvFs (with metadata=on, set by setup-wsl.sh) handles
        // permissions correctly across the boundary.
        if (_cfg.SharedFolderPaths.Count > 0)
        {
            phaseStart = t0.ElapsedMilliseconds;
            await MountSharedFoldersAsync(ct).ConfigureAwait(false);
            Phase("shares", t0.ElapsedMilliseconds - phaseStart);
        }

        // 5) Spawn the user-facing process (kitty). Don't await —
        // the wsl.exe call stays alive for the kitty session's
        // lifetime; await would block indefinitely. We capture the
        // Process so the embed step can find its HWND.
        phaseStart = t0.ElapsedMilliseconds;
        _wslProcess = SpawnGuestProcess();
        Phase("spawn", t0.ElapsedMilliseconds - phaseStart);

        // Persist the per-phase log so the user can inspect what
        // dominated boot time. Best-effort; the file is small.
        try
        {
            Directory.CreateDirectory(_effectiveInstallPath);
            await File.WriteAllTextAsync(
                Path.Combine(_effectiveInstallPath, "wsl-timings.log"),
                phaseLog.ToString(), ct).ConfigureAwait(false);
        }
        catch { /* best-effort */ }
        LastTimings = phaseLog.ToString();
    }

    /// <summary>
    /// Phase-by-phase timings from the most recent <see cref="StartAsync"/>.
    /// Populated even on failure (partial log). Useful for the UI to
    /// surface "import 11200 ms" vs "spawn 320 ms" so users can see
    /// where time goes.
    /// </summary>
    public string LastTimings { get; private set; } = "";

    /// <summary>
    /// For each entry in <see cref="WslSessionConfig.SharedFolderPaths"/>,
    /// create a symlink at <c>/home/&lt;user&gt;/&lt;basename&gt;</c>
    /// pointing into the WSL-mounted DrvFs path. Uses <c>wslpath -u</c>
    /// inside the distro to translate Windows paths so quirks (UNC,
    /// mapped drives, case) are handled by WSL's own translator.
    /// Best-effort: a single failed share logs and continues, so a
    /// dangling host path doesn't block the rest of the session.
    /// </summary>
    private async Task MountSharedFoldersAsync(CancellationToken ct)
    {
        // Build one shell command that translates and links every
        // share. Doing this in a single sh -c invocation amortises
        // the wsl.exe spawn cost and keeps ordering deterministic.
        var script = new StringBuilder();
        script.Append("set -e; ");
        var seenBasenames = new HashSet<string>(StringComparer.Ordinal);
        foreach (var winPath in _cfg.SharedFolderPaths)
        {
            if (string.IsNullOrWhiteSpace(winPath)) continue;
            var basename = SafeBasename(winPath);
            // Dedup so two host paths that share a basename don't
            // race over the same link target. The first one wins;
            // the duplicate is logged on the host side.
            if (!seenBasenames.Add(basename)) continue;
            // Single-quote the Windows path for shell, escape any
            // existing single quotes per shell convention. Path
            // separators stay as backslashes — wslpath handles them.
            var quoted = "'" + winPath.Replace("'", "'\\''") + "'";
            // mkdir -p the parent (always /home/<user>); then ln -sfn.
            // ln -s (no -f) would fail if the target exists from a
            // prior run; -f -n replaces atomically and won't follow
            // an existing symlink as a directory.
            script.Append($"target=$(wslpath -u {quoted}); ")
                  .Append($"if [ -d \"$target\" ]; then ")
                  .Append($"ln -sfn \"$target\" \"/home/{_cfg.GuestUser}/{basename}\"; ")
                  .Append($"else echo \"[bromure] share missing: $target\" >&2; fi; ");
        }
        if (script.Length == "set -e; ".Length) return;  // nothing to do

        // Append `ls` of the home dir afterwards so the log captures
        // exactly which symlinks ended up in place — the most useful
        // signal when debugging "shares didn't show up".
        script.Append($"echo '--- /home/{_cfg.GuestUser} after mount ---'; ")
              .Append($"ls -la /home/{_cfg.GuestUser} | grep -E '^l' || echo '(no symlinks)'; ");
        // Pipe the script via stdin to `bash -s` instead of passing
        // it as `bash -c <script>`. wsl.exe mangles `$var` references
        // inside argv passed after `--` — empirically the script's
        // command substitutions and parameter expansions return empty
        // strings when delivered via -c. Stdin avoids the argv path
        // entirely.
        var argList = new List<string>
        {
            "-d", _effectiveDistroName,
            "--user", _cfg.GuestUser,
            "--",
            "bash", "-s",
        };
        using var scriptStream = new MemoryStream(Encoding.UTF8.GetBytes(script.ToString()));
        var sh = await WslCli.RunAsync(argList, ct, stdinSource: scriptStream).ConfigureAwait(false);
        // Always log the result (success or failure) so users can
        // verify the mount step ran. The file is small (a few hundred
        // bytes) and lives next to wsl-stderr.log so the inspector
        // shows them together.
        try
        {
            var logPath = Path.Combine(_effectiveInstallPath, "wsl-shares.log");
            Directory.CreateDirectory(_effectiveInstallPath);
            await File.WriteAllTextAsync(logPath,
                $"shares={_cfg.SharedFolderPaths.Count}\n" +
                $"distro={_effectiveDistroName}\n" +
                $"exit={sh.ExitCode}\n" +
                $"--- script ---\n{script}\n" +
                $"--- stdout ---\n{sh.Stdout}\n" +
                $"--- stderr ---\n{sh.Stderr}\n",
                ct).ConfigureAwait(false);
        }
        catch { /* best-effort */ }
    }

    /// <summary>
    /// Extract a Linux-safe basename from a Windows folder path.
    /// Strips trailing separators, trims path-illegal characters, and
    /// falls back to "share" if nothing usable is left.
    /// </summary>
    internal static string SafeBasename(string winPath)
    {
        var trimmed = winPath.TrimEnd('\\', '/');
        var lastSep = trimmed.LastIndexOfAny(new[] { '\\', '/' });
        var raw = lastSep >= 0 ? trimmed[(lastSep + 1)..] : trimmed;
        // Drop chars that are awkward in a Linux path / shell quoting:
        // null byte, slash (already split), control characters.
        var sb = new StringBuilder(raw.Length);
        foreach (var c in raw)
        {
            if (c == '/' || c == '\\' || c == '\0' || c < 0x20) continue;
            sb.Append(c);
        }
        var clean = sb.ToString().Trim();
        return clean.Length == 0 ? "share" : clean;
    }

    private async Task DropHomeOverlayAsync(CancellationToken ct)
    {
        // \\wsl$\<distro>\home\<user>. We can write directly here since
        // WSL2 mounts the distro filesystem read-write to Windows —
        // much cleaner than tar-extracting inside the distro like the
        // QEMU port had to.
        var homeRoot = $@"\\wsl$\{_effectiveDistroName}\home\{_cfg.GuestUser}";

        // The distro might still be spinning up systemd at first
        // touch — give it a couple of seconds to mount. Run the
        // probe on a background thread because Directory.Exists on
        // a UNC \\wsl$\ path can block synchronously (UNC server
        // discovery happens via SMB-style negotiation that doesn't
        // honour async I/O). On the UI thread that hangs the dispatcher.
        await WaitForPathAsync(homeRoot, TimeSpan.FromSeconds(15), ct).ConfigureAwait(false);

        foreach (var (relPath, bytes) in _cfg.HomeFiles)
        {
            var full = Path.Combine(homeRoot, relPath.Replace('/', Path.DirectorySeparatorChar));
            // Directory.CreateDirectory on a UNC \\wsl$\ path can also
            // block — wrap in Task.Run for the same reason as above.
            await Task.Run(() => Directory.CreateDirectory(Path.GetDirectoryName(full)!), ct)
                .ConfigureAwait(false);
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
            "-d", _effectiveDistroName,
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
            "-d", _effectiveDistroName,
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
        //
        // We always inject the WSLg env vars so kitty (and any other
        // Linux GUI app the agent spawns) can connect to the Wayland/
        // X11 compositor regardless of which user runs it. WSL only
        // auto-injects these for the configured default user (the one
        // listed in /etc/wsl.conf); when our config maps to a different
        // session user (or when our explicit WSLENV overrides what
        // wsl.exe normally adds), the GUI app gets `Wayland: failed to
        // connect to display` and exits.
        var combinedEnv = new Dictionary<string, string>(_cfg.EnvVars, StringComparer.Ordinal)
        {
            ["DISPLAY"] = ":0",
            ["WAYLAND_DISPLAY"] = "wayland-0",
            ["XDG_RUNTIME_DIR"] = "/mnt/wslg/runtime-dir",
            ["PULSE_SERVER"] = "unix:/mnt/wslg/PulseServer",
            // X11/Wayland default cursor theme is 24-32 px which renders
            // at ~2x what the user expects on a typical 1080p Windows
            // display. Force a 16 px Adwaita cursor — installed by the
            // Ubuntu base. XCURSOR_THEME picks the theme; XCURSOR_SIZE
            // sets the rendered size in pixels.
            ["XCURSOR_THEME"] = "Adwaita",
            ["XCURSOR_SIZE"] = "16",
        };
        var wslenvNames = new List<string>(combinedEnv.Count);
        foreach (var (k, v) in combinedEnv)
        {
            psi.Environment[k] = v;
            wslenvNames.Add(k + "/u");
        }
        psi.Environment["WSLENV"] = string.Join(':', wslenvNames);

        foreach (var a in argList) psi.ArgumentList.Add(a);

        var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
        if (!p.Start())
        {
            throw new InvalidOperationException("Failed to spawn wsl.exe for the guest process");
        }

        // Drain stderr/stdout into a per-session log file alongside the
        // distro's install path. Async — runs for the lifetime of the
        // wsl.exe process. A blocking read would freeze us.
        var logPath = Path.Combine(_effectiveInstallPath, "wsl-stderr.log");
        try { Directory.CreateDirectory(_effectiveInstallPath); } catch { }
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
            // Directory.Exists on a freshly imported \\wsl$\ path can
            // block for a few seconds while WSL's 9p server boots.
            // Off-thread it so the caller's await actually yields.
            var exists = await Task.Run(() => Directory.Exists(path), ct).ConfigureAwait(false);
            if (exists) return;
            await Task.Delay(250, ct).ConfigureAwait(false);
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

    /// <summary>
    /// Absolute Windows folder paths to expose inside the distro. Each
    /// path appears at <c>/home/&lt;GuestUser&gt;/&lt;basename&gt;</c>
    /// as a symlink into the WSL-mounted DrvFs (<c>/mnt/c/...</c>).
    /// Mirrors the macOS port's VirtioFS share-at-/home/ubuntu/&lt;basename&gt;
    /// behavior. Empty → no shares.
    /// </summary>
    public IReadOnlyList<string> SharedFolderPaths { get; init; } = Array.Empty<string>();

    /// <summary>
    /// Pre-imported distro from the warm pool. When set, the session
    /// adopts it instead of running <c>wsl --import</c>; the session's
    /// effective name + install path are taken from the warm distro.
    /// Null → cold import (the original code path; ~8–15 s slower).
    /// </summary>
    public WarmDistro? WarmDistro { get; init; }
}
