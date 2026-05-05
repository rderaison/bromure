using System.Diagnostics;
using System.Text;
using Bromure.Platform;
using Bromure.SandboxEngine.Qemu;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Bromure.SandboxEngine.Image;

/// <summary>
/// Builds the Ubuntu base image the same way the macOS port does:
///   1. Boot Alpine netboot (kernel + initramfs) via QEMU's direct
///      <c>-kernel</c>/<c>-initrd</c>.
///   2. Drive Alpine over the serial port: log in as root, mount the
///      script ISO, run <c>setup.sh</c>.
///   3. <c>setup.sh</c> partitions <c>/dev/vda</c>, debootstraps Ubuntu
///      Noble, installs the kernel/grub/agents, prints
///      <c>SANDBOX_SETUP_DONE</c>, and powers off.
///   4. Host promotes the resulting raw disk image to
///      <c>ubuntu-base.img</c>, optionally converts to qcow2 for size.
///
/// <para>This replaces the cloud-init-based <c>UbuntuBaker</c> we shipped
/// in v0–v13. The motivation is parity: the macOS and Windows ports run
/// the same setup.sh and produce equivalent images, so the rest of the
/// agentic-coding stack (claude/codex install paths, X+kitty configs,
/// virtiofs share names) doesn't fork by host.</para>
///
/// <para>Why not virtiofs/9p for delivering setup.sh? The QEMU build
/// shipped via winget has fsdev support disabled at compile time —
/// <c>-fsdev help</c> prints "fsdev support is disabled". We work around
/// it by packing setup.sh into a tiny ISO9660 (the existing
/// <see cref="CloudInitSeedBuilder"/>'s ISO logic was retargeted) and
/// mounting that as a CD-ROM. For runtime VM shares we'll need to
/// bundle our own QEMU build or virtiofsd-rs binary.</para>
/// </summary>
public sealed class AlpineInstaller
{
    public sealed record BakeProgress(string Stage, string Message, double Fraction, string ConsoleAppend = "");
    public const string DoneMarker = "SANDBOX_SETUP_DONE";
    public const string FailMarker = "SANDBOX_SETUP_FAILED";
    public const string OutputBaseFileName = "ubuntu-base.qcow2";
    public const long TargetDiskSizeBytes = 16L * 1024 * 1024 * 1024; // 16 GiB

    private readonly IAppPaths _paths;
    private readonly AlpineNetboot _alpine;
    private readonly QemuPaths.Resolution _qemu;
    private readonly ILogger _log;

    public AlpineInstaller(IAppPaths paths, AlpineNetboot alpine, QemuPaths.Resolution qemu, ILogger? log = null)
    {
        _paths = paths;
        _alpine = alpine;
        _qemu = qemu;
        _log = log ?? NullLogger.Instance;
    }

    public string ResultPath => Path.Combine(_paths.ImagesDirectory, OutputBaseFileName);
    public bool IsBaked => File.Exists(ResultPath);

    public async Task BakeAsync(IProgress<BakeProgress>? progress, CancellationToken ct = default)
    {
        var bakeDir = Path.Combine(_paths.ImagesDirectory, "ubuntu-bake");
        Directory.CreateDirectory(bakeDir);
        var rawTarget = Path.Combine(bakeDir, "ubuntu-target.img");
        var setupIso = Path.Combine(bakeDir, "setup.iso");
        var stderrLog = Path.Combine(bakeDir, "qemu.log");

        try { File.Delete(rawTarget); } catch (IOException) { }
        try { File.Delete(setupIso); } catch (IOException) { }

        // 1) Alpine kernel + initramfs cache.
        progress?.Report(new BakeProgress("alpine", "Fetching Alpine netboot installer…", 0.0));
        await _alpine.EnsureAvailableAsync(
            new Progress<DownloadProgress>(d => progress?.Report(new BakeProgress(
                "alpine",
                d.IsDone
                    ? $"Alpine netboot ready ({d.BytesCopiedHuman})"
                    : $"{d.BytesCopiedHuman} / {d.TotalBytesHuman} ({d.SpeedHuman})",
                d.Fraction * 0.10))),
            ct).ConfigureAwait(false);

        // 2) Build the script ISO.
        progress?.Report(new BakeProgress("prepare", "Building setup.iso (script payload)…", 0.12));
        BuildSetupIso(setupIso);

        // 3) Allocate the raw target disk (sparse, 16 GiB).
        progress?.Report(new BakeProgress("prepare", "Allocating target disk image (16 GiB sparse)…", 0.14));
        AllocateSparseRaw(rawTarget, TargetDiskSizeBytes);

        // 4) Boot Alpine + drive setup.sh.
        progress?.Report(new BakeProgress("boot", "Booting Alpine installer…", 0.18));
        var qmpPort = 4600 + Random.Shared.Next(0, 50);
        var serialPort = 5600 + Random.Shared.Next(0, 50);
        var cfg = new QemuConfig
        {
            QemuExecutable = _qemu.ExecutablePath,
            DirectKernelPath = _alpine.KernelPath,
            DirectInitrdPath = _alpine.InitramfsPath,
            DirectKernelCmdline = _alpine.KernelCmdline,
            DiskPath = rawTarget,
            DiskFormat = "raw",
            AuxIsoPath = setupIso,
            VCpus = Math.Max(2, Environment.ProcessorCount / 2),
            MemoryMib = 4096,
            QmpEndpoint = $"tcp:127.0.0.1:{qmpPort}",
            SerialEndpoint = $"127.0.0.1:{serialPort}",
            Display = DisplayMode.None,
            Network = NetworkMode.UserNat,
            StderrLogFile = stderrLog,
        };

        await using var supervisor = new QemuSupervisor(cfg, _log);
        var shutdownTcs = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        supervisor.GuestShutdown += () => shutdownTcs.TrySetResult(true);
        supervisor.Crashed += ex => shutdownTcs.TrySetException(ex);
        await supervisor.StartAsync(ct).ConfigureAwait(false);

        var consoleBuffer = new StringBuilder();
        await using var serial = new SerialDriver(cfg.SerialEndpoint!,
            chunk =>
            {
                consoleBuffer.Append(chunk);
                progress?.Report(new BakeProgress("install", "Running setup.sh inside Alpine…",
                    0.30, ConsoleAppend: chunk));
            }, _log);
        await serial.ConnectAsync(TimeSpan.FromSeconds(30), ct).ConfigureAwait(false);

        try
        {
            // 5) Drive Alpine login → mount setup ISO → run setup.sh.
            await DriveAlpineAsync(serial, progress, ct).ConfigureAwait(false);

            // 6) setup.sh ends with `poweroff`; wait for the guest to halt.
            progress?.Report(new BakeProgress("shutdown", "Waiting for guest power-off…", 0.92));
            using (var deadlineCts = CancellationTokenSource.CreateLinkedTokenSource(ct))
            {
                deadlineCts.CancelAfter(TimeSpan.FromMinutes(2));
                try
                {
                    await shutdownTcs.Task.WaitAsync(deadlineCts.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (!ct.IsCancellationRequested)
                {
                    _log.LogWarning("Guest didn't poweroff cleanly; forcing QMP quit");
                }
            }
        }
        finally
        {
            await serial.DisposeAsync().ConfigureAwait(false);
        }

        if (!supervisor.Process.HasExited)
        {
            await supervisor.ShutdownAsync(grace: TimeSpan.FromSeconds(15), ct).ConfigureAwait(false);
        }

        // 7) Convert raw → qcow2 to keep the on-disk artefact compact.
        progress?.Report(new BakeProgress("finalize", "Converting raw → qcow2…", 0.95));
        var finalPath = ResultPath;
        if (File.Exists(finalPath))
        {
            await DeleteWithRetryAsync(finalPath, ct).ConfigureAwait(false);
        }
        await ConvertRawToQcow2Async(rawTarget, finalPath, ct).ConfigureAwait(false);
        try { File.Delete(rawTarget); } catch (IOException) { }
        try { File.Delete(setupIso); } catch (IOException) { }

        progress?.Report(new BakeProgress("done", "Base image ready.", 1.0));
    }

    private static async Task DriveAlpineAsync(
        SerialDriver serial, IProgress<BakeProgress>? progress, CancellationToken ct)
    {
        progress?.Report(new BakeProgress("alpine", "Waiting for Alpine login prompt…", 0.20));
        await serial.WaitForAsync("localhost login:", TimeSpan.FromMinutes(3),
            failures: ["Kernel panic"], ct).ConfigureAwait(false);

        progress?.Report(new BakeProgress("alpine", "Logging in…", 0.22));
        await serial.SendAsync("root\n", ct).ConfigureAwait(false);
        await serial.WaitForAsync("localhost:~#", TimeSpan.FromSeconds(30), null, ct).ConfigureAwait(false);

        progress?.Report(new BakeProgress("alpine", "Mounting setup ISO…", 0.24));
        // The setup ISO is /dev/sr0 (only IDE CD-ROM attached). Mount
        // it read-only as iso9660 and then exec the script. Alpine's
        // default initramfs has the iso9660 kmod available.
        await serial.SendAsync("mkdir -p /tmp/setup && mount -t iso9660 -o ro /dev/sr0 /tmp/setup && ls /tmp/setup\n",
            ct).ConfigureAwait(false);
        await serial.WaitForAsync("setup.sh", TimeSpan.FromSeconds(20),
            failures: ["mount: ", "No such device"], ct).ConfigureAwait(false);

        progress?.Report(new BakeProgress("install", "Running setup.sh (debootstrap + chroot)…", 0.28));
        // Arg 1: host backingScaleFactor. Windows GTK has no Retina
        // doubling — passing 2 (the script's default, intended for
        // macOS Retina) makes kitty render at font_size 28 instead of 14.
        await serial.SendAsync("sh /tmp/setup/setup.sh 1\n", ct).ConfigureAwait(false);

        await serial.WaitForAsync(DoneMarker, TimeSpan.FromMinutes(45),
            failures: [FailMarker + ":"], ct).ConfigureAwait(false);

        progress?.Report(new BakeProgress("shutdown", "Powering off Alpine installer…", 0.90));
        await serial.SendAsync("poweroff\n", ct).ConfigureAwait(false);
    }

    private static void AllocateSparseRaw(string path, long sizeBytes)
    {
        // Sparse on NTFS: open the file, set its length. Windows
        // doesn't allocate clusters until written. macOS uses
        // ftruncate; same idea.
        if (File.Exists(path)) File.Delete(path);
        using var fs = new FileStream(path, FileMode.CreateNew, FileAccess.Write);
        fs.SetLength(sizeBytes);
    }

    private void BuildSetupIso(string outputPath)
    {
        var script = LoadEmbeddedSetupScript().Replace("\r\n", "\n");
        var bytes = Encoding.UTF8.GetBytes(script);
        // Single-file ISO: the in-guest driver mounts /dev/sr0 and runs
        // /tmp/setup/setup.sh. Volume label is intentionally NOT
        // "cidata" so cloud-init in the Alpine guest doesn't probe it.
        CloudInitSeedBuilder.WriteScriptIso(outputPath, "setup.sh", bytes,
            volumeLabel: "BROMUREISO");
    }

    private static string LoadEmbeddedSetupScript()
    {
        var asm = typeof(AlpineInstaller).Assembly;
        var resourceName = asm.GetManifestResourceNames()
            .FirstOrDefault(n => n.EndsWith(".setup.sh", StringComparison.Ordinal))
            ?? throw new InvalidOperationException(
                "setup.sh not embedded — check Bromure.SandboxEngine.csproj <EmbeddedResource>.");
        using var stream = asm.GetManifestResourceStream(resourceName)
            ?? throw new InvalidOperationException("Embedded setup.sh stream returned null.");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }

    private async Task ConvertRawToQcow2Async(string rawPath, string qcow2Path, CancellationToken ct)
    {
        var qemuImg = Path.Combine(Path.GetDirectoryName(_qemu.ExecutablePath)!, "qemu-img.exe");
        if (!File.Exists(qemuImg))
        {
            throw new FileNotFoundException("qemu-img.exe not found alongside qemu-system-x86_64.exe", qemuImg);
        }
        var psi = new ProcessStartInfo
        {
            FileName = qemuImg,
            UseShellExecute = false,
            RedirectStandardError = true,
            RedirectStandardOutput = true,
            CreateNoWindow = true,
        };
        psi.ArgumentList.Add("convert");
        psi.ArgumentList.Add("-f"); psi.ArgumentList.Add("raw");
        psi.ArgumentList.Add("-O"); psi.ArgumentList.Add("qcow2");
        psi.ArgumentList.Add("-c");                     // compressed
        psi.ArgumentList.Add(rawPath);
        psi.ArgumentList.Add(qcow2Path);
        using var p = Process.Start(psi)
            ?? throw new InvalidOperationException("Failed to start qemu-img");
        var stderrTask = p.StandardError.ReadToEndAsync(ct);
        _ = p.StandardOutput.ReadToEndAsync(ct);
        await p.WaitForExitAsync(ct).ConfigureAwait(false);
        if (p.ExitCode != 0)
        {
            throw new InvalidOperationException(
                $"qemu-img convert raw→qcow2 failed (exit {p.ExitCode}): "
                + await stderrTask.ConfigureAwait(false));
        }
    }

    private static async Task DeleteWithRetryAsync(string path, CancellationToken ct)
    {
        var delay = TimeSpan.FromMilliseconds(200);
        for (var i = 0; i < 4; i++)
        {
            try { File.Delete(path); return; }
            catch (IOException) { }
            await Task.Delay(delay, ct).ConfigureAwait(false);
            delay += delay;
        }
        File.Delete(path);
    }
}

public sealed class BakeFailedException : Exception
{
    public BakeFailedException(string message) : base(message) { }
    public BakeFailedException(string message, Exception inner) : base(message, inner) { }
}
