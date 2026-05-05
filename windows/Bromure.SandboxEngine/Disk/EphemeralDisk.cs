using System.Diagnostics;

namespace Bromure.SandboxEngine.Disk;

/// <summary>
/// Replaces <c>SessionDisk.swift</c>'s APFS <c>clonefile(2)</c> path
/// (Sources/AgentCoding/SessionDisk.swift:271) with qcow2 backing-file
/// overlays. Both give us instant-create, copy-on-write semantics:
///
/// <code>qemu-img create -f qcow2 -F qcow2 -b base.qcow2 session.qcow2</code>
///
/// Created overlays carry an absolute backing-file path in the qcow2
/// header so QEMU resolves the base regardless of where session.qcow2
/// is opened from. We pin the cluster size to 64 KiB to match the
/// default Ubuntu cloud-image format and avoid an O(N) re-fragment on
/// first write.
/// </summary>
public sealed class EphemeralDisk
{
    private readonly string _qemuImgExecutable;

    public EphemeralDisk(string qemuImgExecutable)
    {
        _qemuImgExecutable = qemuImgExecutable;
    }

    public string BasePath { get; private set; } = string.Empty;
    public string OverlayPath { get; private set; } = string.Empty;
    public bool DidCloneOnLastEnsure { get; private set; }

    /// <summary>
    /// Equivalent of <c>SessionDisk.ensureDiskExists()</c>: returns immediately
    /// if the overlay already exists; otherwise creates a fresh CoW overlay
    /// off <paramref name="baseQcow2"/>.
    /// </summary>
    public async Task EnsureExistsAsync(
        string baseQcow2,
        string overlayPath,
        CancellationToken ct = default)
    {
        BasePath = baseQcow2;
        OverlayPath = overlayPath;

        if (File.Exists(overlayPath))
        {
            DidCloneOnLastEnsure = false;
            return;
        }
        Directory.CreateDirectory(Path.GetDirectoryName(overlayPath)!);

        var args = new[]
        {
            "create",
            "-f", "qcow2",
            "-F", "qcow2",
            "-b", baseQcow2,
            "-o", "cluster_size=65536",
            overlayPath,
        };
        await RunQemuImgAsync(args, ct).ConfigureAwait(false);
        DidCloneOnLastEnsure = true;
    }

    /// <summary>
    /// Lossy "destroy session disk on close" — the inverse of <see cref="EnsureExistsAsync"/>.
    /// Tolerates the file already being gone.
    /// </summary>
    public void Discard()
    {
        if (string.IsNullOrEmpty(OverlayPath)) return;
        try { File.Delete(OverlayPath); }
        catch (FileNotFoundException) { }
        catch (DirectoryNotFoundException) { }
    }

    /// <summary>Resize the overlay to a virtual size (in MiB).</summary>
    public Task ResizeAsync(int virtualSizeMib, CancellationToken ct = default)
    {
        if (string.IsNullOrEmpty(OverlayPath))
        {
            throw new InvalidOperationException("Call EnsureExistsAsync first");
        }
        return RunQemuImgAsync(new[] { "resize", OverlayPath, $"{virtualSizeMib}M" }, ct);
    }

    /// <summary>Sanity-check the overlay's header against its backing file.</summary>
    public async Task<DiskInfo> InfoAsync(CancellationToken ct = default)
    {
        if (string.IsNullOrEmpty(OverlayPath))
        {
            throw new InvalidOperationException("Call EnsureExistsAsync first");
        }
        var output = await CaptureQemuImgAsync(new[] { "info", "--output=json", OverlayPath }, ct).ConfigureAwait(false);
        return DiskInfo.FromQemuImgJson(output);
    }

    private async Task RunQemuImgAsync(IReadOnlyList<string> args, CancellationToken ct)
    {
        var psi = new ProcessStartInfo
        {
            FileName = _qemuImgExecutable,
            UseShellExecute = false,
            RedirectStandardError = true,
            RedirectStandardOutput = true,
            CreateNoWindow = true,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi)
            ?? throw new InvalidOperationException("Failed to start qemu-img");
        var stderrTask = p.StandardError.ReadToEndAsync(ct);
        var stdoutTask = p.StandardOutput.ReadToEndAsync(ct);
        await p.WaitForExitAsync(ct).ConfigureAwait(false);
        var stderr = await stderrTask.ConfigureAwait(false);
        _ = await stdoutTask.ConfigureAwait(false);
        if (p.ExitCode != 0)
        {
            throw new InvalidOperationException(
                $"qemu-img {string.Join(' ', args)} failed (exit {p.ExitCode}): {stderr}");
        }
    }

    private async Task<string> CaptureQemuImgAsync(IReadOnlyList<string> args, CancellationToken ct)
    {
        var psi = new ProcessStartInfo
        {
            FileName = _qemuImgExecutable,
            UseShellExecute = false,
            RedirectStandardError = true,
            RedirectStandardOutput = true,
            CreateNoWindow = true,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi)
            ?? throw new InvalidOperationException("Failed to start qemu-img");
        var stderr = p.StandardError.ReadToEndAsync(ct);
        var stdout = await p.StandardOutput.ReadToEndAsync(ct).ConfigureAwait(false);
        await p.WaitForExitAsync(ct).ConfigureAwait(false);
        if (p.ExitCode != 0)
        {
            throw new InvalidOperationException(
                $"qemu-img {string.Join(' ', args)} failed: {await stderr.ConfigureAwait(false)}");
        }
        return stdout;
    }
}

public sealed record DiskInfo(
    string Filename,
    string Format,
    long VirtualSizeBytes,
    long ActualSizeBytes,
    string? BackingFilename,
    string? BackingFormat)
{
    public static DiskInfo FromQemuImgJson(string json)
    {
        using var doc = System.Text.Json.JsonDocument.Parse(json);
        var root = doc.RootElement;
        return new DiskInfo(
            Filename: root.GetProperty("filename").GetString() ?? "",
            Format: root.GetProperty("format").GetString() ?? "",
            VirtualSizeBytes: root.GetProperty("virtual-size").GetInt64(),
            ActualSizeBytes: root.GetProperty("actual-size").GetInt64(),
            BackingFilename: root.TryGetProperty("backing-filename", out var bf) ? bf.GetString() : null,
            BackingFormat: root.TryGetProperty("backing-filename-format", out var bff) ? bff.GetString() : null);
    }
}
