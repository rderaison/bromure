using System.Globalization;

namespace Bromure.SandboxEngine.Wsl;

/// <summary>
/// One WSL2 distribution = one Bromure session/tab. Wraps the
/// <c>wsl --import</c> / <c>wsl --unregister</c> lifecycle around
/// a sealed base rootfs tarball, plus a <see cref="LaunchAsync"/> that
/// runs commands inside.
///
/// <para><b>Architecture.</b> Replaces what <c>QemuSupervisor</c> did
/// for the QEMU port. Instead of spawning a hypervisor process per
/// session, we ask WSL to create a fresh distro from
/// <c>bromure-base.tar.gz</c>. WSL's utility VM is shared across all
/// distros, so cold-start cost is ~13s for the import + ~2.8s for
/// "first command after terminate"; per-tab overhead is negligible
/// once the utility VM is running.</para>
///
/// <para><b>Why not reuse one distro across tabs?</b> Each tab needs
/// its own filesystem (project clones, dotfiles, npm cache, agent
/// session state) and its own process tree (so closing a tab kills
/// only its agent). Distros are the WSL-supported isolation unit;
/// they share the kernel but are otherwise independent — exactly
/// what the user asked for ("shared kernel is actually better, lower
/// overhead").</para>
///
/// <para><b>Disposal</b> calls <see cref="UnregisterAsync"/>
/// — destroys the distro's filesystem. Idempotent. Use
/// <see cref="TerminateAsync"/> for "stop running, keep state."</para>
/// </summary>
public sealed class WslDistro : IAsyncDisposable
{
    /// <summary>The unique distro name passed to <c>wsl --import</c>.
    /// Bromure uses GUID-derived names like <c>bromure-ses-{8 hex}</c>
    /// to avoid collisions with the user's other distros and to make
    /// orphan cleanup possible.</summary>
    public string Name { get; }

    /// <summary>Folder where WSL stores the distro's <c>ext4.vhdx</c>.
    /// On unregister WSL deletes the directory contents but not the
    /// folder itself — caller picks something disposable under
    /// AppData\Local.</summary>
    public string InstallPath { get; }

    private bool _imported;
    private bool _disposed;

    public WslDistro(string name, string installPath)
    {
        if (string.IsNullOrWhiteSpace(name))
            throw new ArgumentException("Distro name required", nameof(name));
        if (string.IsNullOrWhiteSpace(installPath))
            throw new ArgumentException("Install path required", nameof(installPath));
        Name = name;
        InstallPath = installPath;
    }

    /// <summary>Status as WSL reports it. <see cref="State.NotImported"/>
    /// means the distro doesn't exist yet (or was unregistered).
    /// <see cref="State.Stopped"/> means imported but no processes
    /// running. <see cref="State.Running"/> means at least one process
    /// running inside.</summary>
    public enum State { NotImported, Stopped, Running }

    /// <summary>
    /// Import the distro from a USTAR/.tar.gz/.tar.xz/.vhdx rootfs file.
    /// Idempotent: if a distro with this name already exists we leave
    /// it alone and treat as success. Caller decides whether to
    /// preempt that via <see cref="UnregisterAsync"/>.
    /// </summary>
    public async Task ImportAsync(string rootfsPath, CancellationToken ct = default)
    {
        ThrowIfDisposed();
        if (!File.Exists(rootfsPath))
            throw new FileNotFoundException($"rootfs not found: {rootfsPath}", rootfsPath);
        Directory.CreateDirectory(InstallPath);

        var existing = await ListAsync(ct).ConfigureAwait(false);
        if (existing.Any(d => d.Name.Equals(Name, StringComparison.Ordinal)))
        {
            _imported = true;
            return;
        }

        var r = await WslCli.RunAsync(
            new[] { "--import", Name, InstallPath, rootfsPath, "--version", "2" },
            ct).ConfigureAwait(false);
        r.ThrowIfFailed($"wsl --import {Name}");
        _imported = true;
    }

    /// <summary>
    /// Run a command inside the distro and capture output.
    /// <paramref name="argv"/> is the program + args, exactly as the
    /// distro's shell would see them (no further parsing on our side).
    /// Use <paramref name="user"/> to override the import-time default
    /// user (commonly "root" for setup tasks, default user for app
    /// commands).
    /// </summary>
    public Task<WslResult> LaunchAsync(
        IReadOnlyList<string> argv,
        string? user = null,
        string? cwd = null,
        CancellationToken ct = default)
    {
        ThrowIfDisposed();
        if (!_imported) throw new InvalidOperationException(
            "Distro not imported. Call ImportAsync first.");
        if (argv.Count == 0) throw new ArgumentException(
            "argv must contain at least one element", nameof(argv));

        var args = new List<string>(argv.Count + 8) { "-d", Name };
        if (user is not null) { args.Add("--user"); args.Add(user); }
        if (cwd is not null) { args.Add("--cd"); args.Add(cwd); }
        // -- separates wsl flags from the guest command, preventing
        // interpretation of leading dashes in the user's argv.
        args.Add("--");
        args.AddRange(argv);
        return WslCli.RunAsync(args, ct);
    }

    /// <summary>Stop all processes inside the distro without destroying its
    /// filesystem. Cheap (sub-second). Used to "sleep" a tab.</summary>
    public async Task TerminateAsync(CancellationToken ct = default)
    {
        ThrowIfDisposed();
        var r = await WslCli.RunAsync(new[] { "--terminate", Name }, ct).ConfigureAwait(false);
        r.ThrowIfFailed($"wsl --terminate {Name}");
    }

    /// <summary>
    /// Destroy the distro completely — filesystem and all. Idempotent;
    /// returns silently if the distro is already gone (e.g. previous
    /// crash left an orphan, or a parallel call already cleaned up).
    /// </summary>
    public async Task UnregisterAsync(CancellationToken ct = default)
    {
        if (_disposed) return;
        var existing = await ListAsync(ct).ConfigureAwait(false);
        if (!existing.Any(d => d.Name.Equals(Name, StringComparison.Ordinal)))
        {
            _imported = false;
            return;
        }
        var r = await WslCli.RunAsync(new[] { "--unregister", Name }, ct).ConfigureAwait(false);
        r.ThrowIfFailed($"wsl --unregister {Name}");
        _imported = false;
    }

    /// <summary>
    /// Snapshot of <c>wsl --list --verbose</c>. Useful for orphan
    /// detection — Bromure crashes between import and unregister
    /// shouldn't leak distros indefinitely.
    /// </summary>
    public static async Task<IReadOnlyList<DistroInfo>> ListAsync(CancellationToken ct = default)
    {
        var r = await WslCli.RunAsync(new[] { "--list", "--verbose" }, ct).ConfigureAwait(false);
        // `wsl --list` returns exit 1 when there are zero distros — treat
        // that as an empty list, not an error.
        if (!r.Success && r.Stdout.Length == 0) return Array.Empty<DistroInfo>();
        return ParseList(r.Stdout);
    }

    /// <summary>
    /// Parser for <c>wsl --list --verbose</c> stdout. Format with
    /// <c>WSL_UTF8=1</c>:
    /// <code>
    ///   NAME             STATE           VERSION
    /// * Ubuntu-24.04     Stopped         2
    ///   bromure-ses-...  Running         2
    /// </code>
    /// First column is a default-marker (<c>*</c>) we discard. Names
    /// can contain dashes and digits; states are exactly
    /// <c>Stopped</c> / <c>Running</c> / <c>Installing</c>; version
    /// is 1 or 2. Made internal for tests.
    /// </summary>
    internal static List<DistroInfo> ParseList(string stdout)
    {
        var list = new List<DistroInfo>();
        foreach (var rawLine in stdout.Split('\n'))
        {
            var line = rawLine.TrimEnd('\r');
            if (string.IsNullOrWhiteSpace(line)) continue;
            // Drop the header row.
            if (line.TrimStart().StartsWith("NAME", StringComparison.OrdinalIgnoreCase)) continue;
            // Strip the optional default-marker '*'.
            var trimmed = line.TrimStart();
            if (trimmed.StartsWith('*')) trimmed = trimmed[1..].TrimStart();
            // Tokenise on whitespace runs. Distro names can't contain
            // whitespace per WSL's own naming rules, so 3 columns are
            // unambiguous.
            var parts = trimmed.Split(' ', '\t')
                .Where(p => p.Length > 0).ToArray();
            if (parts.Length < 3) continue;
            var name = parts[0];
            var state = parts[1] switch
            {
                "Stopped" => State.Stopped,
                "Running" => State.Running,
                _ => State.Stopped,  // Installing/Uninstalling — treat as Stopped for our purposes
            };
            if (!int.TryParse(parts[2], NumberStyles.Integer, CultureInfo.InvariantCulture, out var version))
                continue;
            list.Add(new DistroInfo(name, state, version));
        }
        return list;
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true;
        if (!_imported) return;
        try { await UnregisterAsync().ConfigureAwait(false); }
        catch { /* best-effort; orphan stays for the next ListAsync to find */ }
    }

    private void ThrowIfDisposed()
    {
        if (_disposed) throw new ObjectDisposedException(nameof(WslDistro));
    }
}

/// <summary>One row from <c>wsl --list --verbose</c>.</summary>
public sealed record DistroInfo(string Name, WslDistro.State State, int Version);
