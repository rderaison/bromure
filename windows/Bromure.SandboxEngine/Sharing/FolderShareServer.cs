using System.Diagnostics;
using System.Text;
using Bromure.Platform;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Bromure.SandboxEngine.Sharing;

/// <summary>
/// Per-session SSHFS-over-slirp folder share between the Windows host
/// and the Linux guest. Replaces macOS's virtiofs for the project-folder
/// path. Architecture:
///
/// <list type="number">
///   <item>Reuse the MSYS2 install we already ship for the QEMU build
///     (<c>C:\msys64\usr\bin\sshd.exe</c>) — no admin install needed,
///     no Windows OpenSSH-Server feature dependency.</item>
///   <item>Spawn a session-scoped <c>sshd</c> on a non-privileged port
///     (default 2222) with a custom config that:
///     <list type="bullet">
///       <item>Binds to <c>127.0.0.1</c> only.</item>
///       <item>Disables password auth, allows pubkey only.</item>
///       <item>Authorises a single per-session keypair we generate
///         here.</item>
///     </list>
///   </item>
///   <item>The matching private key gets shipped to the guest via the
///     metadata ISO, alongside a tiny <c>shares.json</c> manifest that
///     lists what guest mount points map to what host paths. The
///     guest's <c>bromure-mount-meta</c> systemd unit reads it and
///     calls <c>sshfs</c> for each.</item>
/// </list>
///
/// <para>Slirp NAT exposes the host as <c>10.0.2.2</c> from the guest
/// — that's the address the guest's sshfs uses, which means the host
/// sshd doesn't need to be reachable from outside this machine.</para>
///
/// <para>Why SSHFS specifically: SMB is explicitly out per user policy,
/// virtiofs/9p are blocked at the QEMU layer on Windows hosts (see
/// <c>windows/SHARING_INVESTIGATION.md</c>), and writing a custom
/// shared-fs daemon on top of WinFsp is a multi-week project. SSHFS
/// over slirp gives us bidirectional read/write today with one-port
/// firewall surface, standard tooling, no extra binaries shipped (we
/// already pull MSYS2 for the QEMU build).</para>
/// </summary>
public sealed class FolderShareServer : IAsyncDisposable
{
    public sealed record FolderShare(
        string GuestMountPoint,   // e.g. "/mnt/bromure-share-1"
        string HostPath,          // absolute Windows path
        bool ReadOnly = false);

    public sealed record SessionAuth(
        string SshdHostKeyPath,
        string GuestPrivateKey,   // PEM body, written to the metadata ISO
        string GuestPublicKey,    // single-line OpenSSH format, only for log/debug
        int Port);

    private readonly IAppPaths _paths;
    private readonly string _msys2Root;
    private readonly ILogger _log;
    private readonly string _sessionRoot;
    private Process? _sshd;
    private SessionAuth? _auth;

    public FolderShareServer(IAppPaths paths, string sessionRoot, ILogger? log = null,
        string? msys2Root = null)
    {
        _paths = paths;
        _sessionRoot = sessionRoot;
        _log = log ?? NullLogger.Instance;
        _msys2Root = msys2Root ?? @"C:\msys64";
    }

    /// <summary>True when the MSYS2 sshd binary we depend on is on disk.</summary>
    public bool IsAvailable =>
        File.Exists(SshdPath) && File.Exists(SshKeygenPath);

    private string SshdPath => Path.Combine(_msys2Root, "usr", "bin", "sshd.exe");
    private string SshKeygenPath => Path.Combine(_msys2Root, "usr", "bin", "ssh-keygen.exe");

    /// <summary>
    /// Returns the auth bundle the metadata ISO should ship to the
    /// guest. Generates the host key once (cached under AppData), the
    /// guest keypair fresh per call. Throws if MSYS2 sshd isn't
    /// available (caller should check <see cref="IsAvailable"/>).
    /// </summary>
    public async Task<SessionAuth> StartAsync(IReadOnlyList<FolderShare> shares,
        int port = 2222, CancellationToken ct = default)
    {
        if (!IsAvailable)
        {
            throw new InvalidOperationException(
                "MSYS2 sshd not found. Run windows/scripts/build-qemu.ps1 first " +
                "(it installs MSYS2 alongside the QEMU build, which we reuse here).");
        }

        // 1) Persistent host key — same key across sessions so the
        //    guest can pin-on-first-use without re-warning. Stored
        //    alongside other app data.
        var sshDir = Path.Combine(_paths.AppDataRoot, "ssh");
        Directory.CreateDirectory(sshDir);
        var hostKey = Path.Combine(sshDir, "bromure_host_ed25519");
        if (!File.Exists(hostKey))
        {
            await RunSshKeygenAsync(["-q", "-t", "ed25519", "-N", "", "-f", hostKey, "-C", "bromure-host"],
                ct).ConfigureAwait(false);
        }

        // 2) Per-session guest keypair — fresh each launch so a leaked
        //    key from one session doesn't authorise the next.
        var guestKey = Path.Combine(_sessionRoot, "guest_ed25519");
        try { File.Delete(guestKey); File.Delete(guestKey + ".pub"); } catch (IOException) { }
        await RunSshKeygenAsync(["-q", "-t", "ed25519", "-N", "", "-f", guestKey, "-C", "bromure-session"],
            ct).ConfigureAwait(false);

        var guestPriv = await File.ReadAllTextAsync(guestKey, ct).ConfigureAwait(false);
        var guestPub = await File.ReadAllTextAsync(guestKey + ".pub", ct).ConfigureAwait(false);

        // 3) authorized_keys for this session.
        var authorized = Path.Combine(_sessionRoot, "authorized_keys");
        await File.WriteAllTextAsync(authorized, guestPub, ct).ConfigureAwait(false);

        // 4) sshd_config — minimal, locks to localhost, key auth only,
        //    references the per-session authorized_keys file.
        var configPath = Path.Combine(_sessionRoot, "sshd_config");
        var subsystemPath = Path.Combine(_msys2Root, "usr", "lib", "ssh", "sftp-server.exe").Replace('\\', '/');
        // Fall back: some MSYS2 installs put it under usr/lib/openssh
        if (!File.Exists(subsystemPath.Replace('/', '\\')))
        {
            subsystemPath = Path.Combine(_msys2Root, "usr", "lib", "openssh", "sftp-server.exe").Replace('\\', '/');
        }
        // MSYS2's sshd doesn't accept Windows-drive paths like
        // "C:/Users/foo" — it tries to interpret them relative to its
        // own working dir, which mangles the result. Convert each
        // path to the MSYS2-style "/c/Users/foo" form sshd actually
        // resolves correctly.
        var configBody = new StringBuilder()
            .AppendLine("# bromure-ac per-session sshd config")
            .AppendLine($"Port {port}")
            .AppendLine("ListenAddress 0.0.0.0   # QEMU slirp's 10.0.2.2 → host reaches us via 127.0.0.1 binding too; 0.0.0.0 covers both")
            .AppendLine($"HostKey {Msys2Path.From(hostKey)}")
            .AppendLine($"AuthorizedKeysFile {Msys2Path.From(authorized)}")
            .AppendLine("PasswordAuthentication no")
            .AppendLine("PermitRootLogin no")
            .AppendLine("PubkeyAuthentication yes")
            // UsePAM was removed from OpenSSH 10.x — older configs that
            // still set it cause sshd to exit on parse. We don't want
            // PAM either way; just stay quiet about it.
            .AppendLine("PrintMotd no")
            // StrictModes off — MSYS2's stat doesn't quite report Windows
            // ACLs the way OpenSSH wants; we'd otherwise hit "bad
            // ownership or modes" on the AuthorizedKeysFile.
            .AppendLine("StrictModes no")
            .AppendLine("# Required for sshfs — sftp-server backend.")
            .AppendLine($"Subsystem sftp {subsystemPath}")
            .ToString();
        await File.WriteAllTextAsync(configPath, configBody, ct).ConfigureAwait(false);

        // 5) Spawn sshd in foreground (-D), capture stderr to a log so
        //    we can diagnose mount failures from the host side.
        var stderrLog = Path.Combine(_sessionRoot, "sshd.log");
        try { File.Delete(stderrLog); } catch (IOException) { }
        var psi = new ProcessStartInfo
        {
            FileName = SshdPath,
            UseShellExecute = false,
            RedirectStandardError = true,
            RedirectStandardOutput = true,
            CreateNoWindow = true,
        };
        // sshd forks `sshd-session.exe` per connection, which depends
        // on MSYS2 runtime DLLs (msys-2.0.dll, msys-crypto-3.dll, …)
        // resolved via PATH. If we launch sshd with our .NET process's
        // PATH, the children fail with "cannot open shared object file"
        // and connections abort during banner exchange. Prepend the
        // MSYS2 bin dirs to PATH so the resolver finds them. We don't
        // want to mutate this process's PATH globally — the child
        // process gets its own copy via psi.Environment.
        var msys2Bin = Path.Combine(_msys2Root, "usr", "bin");
        var msys2Mingw = Path.Combine(_msys2Root, "ucrt64", "bin");
        var existingPath = Environment.GetEnvironmentVariable("PATH") ?? "";
        psi.Environment["PATH"] = $"{msys2Bin};{msys2Mingw};{existingPath}";
        psi.ArgumentList.Add("-D");                  // foreground, no daemonise
        psi.ArgumentList.Add("-e");                  // log to stderr
        psi.ArgumentList.Add("-f"); psi.ArgumentList.Add(configPath);
        // sshd by default expects a privsep dir that may not exist on
        // a fresh MSYS2; -o UsePrivilegeSeparation=no is the older flag.
        // Modern OpenSSH (8+) doesn't have that knob — privsep is
        // mandatory but auto-creates the dir. If it complains we'll
        // see it in stderr.
        _sshd = Process.Start(psi);
        if (_sshd is null)
        {
            throw new InvalidOperationException("Failed to start sshd");
        }

        // Capture sshd stderr to file in the background; don't block on it.
        _ = Task.Run(async () =>
        {
            try
            {
                await using var fs = File.Open(stderrLog, FileMode.Create);
                await _sshd.StandardError.BaseStream.CopyToAsync(fs).ConfigureAwait(false);
            }
            catch { /* sshd died; log captured separately */ }
        });

        // Give sshd ~500ms to bind so the first sshfs from the guest
        // doesn't race the listener. If it dies before then, fail loud.
        await Task.Delay(500, ct).ConfigureAwait(false);
        if (_sshd.HasExited)
        {
            var tail = "";
            try { tail = await File.ReadAllTextAsync(stderrLog, ct).ConfigureAwait(false); } catch { }
            throw new InvalidOperationException(
                $"sshd exited immediately (rc={_sshd.ExitCode}). stderr tail:\n{tail}");
        }

        _log.LogInformation("sshd PID {Pid} listening on 127.0.0.1:{Port}", _sshd.Id, port);
        _auth = new SessionAuth(
            SshdHostKeyPath: hostKey,
            GuestPrivateKey: guestPriv,
            GuestPublicKey: guestPub.Trim(),
            Port: port);
        return _auth;
    }

    private async Task RunSshKeygenAsync(IReadOnlyList<string> args, CancellationToken ct)
    {
        var psi = new ProcessStartInfo
        {
            FileName = SshKeygenPath,
            UseShellExecute = false,
            RedirectStandardError = true,
            RedirectStandardOutput = true,
            CreateNoWindow = true,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi)
            ?? throw new InvalidOperationException("Failed to start ssh-keygen");
        await p.WaitForExitAsync(ct).ConfigureAwait(false);
        if (p.ExitCode != 0)
        {
            var err = await p.StandardError.ReadToEndAsync(ct).ConfigureAwait(false);
            throw new InvalidOperationException($"ssh-keygen failed (exit {p.ExitCode}): {err}");
        }
    }

    public ValueTask DisposeAsync()
    {
        try
        {
            if (_sshd is not null && !_sshd.HasExited)
            {
                _sshd.Kill(entireProcessTree: true);
                _sshd.WaitForExit(5_000);
            }
        }
        catch (InvalidOperationException) { /* already exited */ }
        catch (System.ComponentModel.Win32Exception) { /* permission / race */ }
        _sshd?.Dispose();
        _sshd = null;
        return ValueTask.CompletedTask;
    }
}
