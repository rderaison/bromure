using System.Diagnostics;
using System.Formats.Tar;
using System.IO.Compression;
using System.Net.Http;
using Bromure.Platform;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Bromure.SandboxEngine.Image;

/// <summary>
/// Downloads + caches the Alpine netboot kernel and initramfs we use as the
/// bootstrap installer when baking the Ubuntu base image. Mirrors the macOS
/// <c>UbuntuImageManager.swift</c> Alpine-cache logic — pinned version, the
/// architecture is detected from the host (amd64 on Windows, but the same
/// class will work on any supported QEMU target).
///
/// <para>Layout on disk:
/// <code>
///   ImagesDirectory/
///     alpine-netboot-3.22.3-x86_64.tar.gz   (raw cached download)
///     alpine-vmlinuz                         (extracted kernel)
///     alpine-initramfs                       (extracted initramfs)
/// </code>
/// </para>
///
/// <para>The kernel + initramfs are extracted from the tarball into bare
/// files so QEMU's <c>-kernel</c>/<c>-initrd</c> flags can point at them
/// directly. The original tarball is kept so that re-runs avoid the
/// download.</para>
/// </summary>
public sealed class AlpineNetboot
{
    /// <summary>Pinned to keep bake reproducibility. Bump when we want fresher Alpine.</summary>
    public const string AlpineMajor = "3.22";
    public const string AlpineRelease = "3.22.3";

    /// <summary>Linux/QEMU arch token used in Alpine netboot URLs.</summary>
    public static string KernelArch =>
        System.Runtime.InteropServices.RuntimeInformation.OSArchitecture switch
        {
            System.Runtime.InteropServices.Architecture.X64 => "x86_64",
            System.Runtime.InteropServices.Architecture.Arm64 => "aarch64",
            _ => throw new PlatformNotSupportedException("Unsupported host arch for Alpine netboot bake"),
        };

    public string TarballPath => Path.Combine(_paths.ImagesDirectory,
        $"alpine-netboot-{AlpineRelease}-{KernelArch}.tar.gz");
    public string KernelPath => Path.Combine(_paths.ImagesDirectory, "alpine-vmlinuz");
    public string InitramfsPath => Path.Combine(_paths.ImagesDirectory, "alpine-initramfs");

    public string ReleasesBase => $"https://dl-cdn.alpinelinux.org/alpine/v{AlpineMajor}/releases/{KernelArch}";
    public string TarballUrl => $"{ReleasesBase}/alpine-netboot-{AlpineRelease}-{KernelArch}.tar.gz";

    /// <summary>The kernel cmdline passed via QEMU <c>-append</c>.</summary>
    /// <remarks>
    /// Alpine boots with these args:
    ///   * <c>console=ttyS0,115200n8</c> — guest serial → host TCP listener.
    ///   * <c>ip=dhcp</c> — pull an address from QEMU's slirp NAT.
    ///   * <c>alpine_repo</c> — main package repo so apk works.
    ///   * <c>modloop</c> — kernel modules squashfs (auto-fetched at boot).
    ///   * <c>modules=loop,squashfs,virtio-net,virtio-blk</c> — boot drivers
    ///     enough to mount modloop and reach the network/disk.
    /// </remarks>
    public string KernelCmdline =>
        $"console=ttyS0,115200n8 " +
        $"ip=dhcp " +
        $"alpine_repo=https://dl-cdn.alpinelinux.org/alpine/v{AlpineMajor}/main " +
        $"modloop={ReleasesBase}/netboot-{AlpineRelease}/modloop-virt " +
        $"modules=loop,squashfs,virtio-net,virtio-blk";

    private readonly IAppPaths _paths;
    private readonly ILogger _log;
    private readonly HttpClient _http;

    public AlpineNetboot(IAppPaths paths, ILogger? log = null, HttpClient? http = null)
    {
        _paths = paths;
        _log = log ?? NullLogger.Instance;
        _http = http ?? new HttpClient { Timeout = TimeSpan.FromMinutes(20) };
    }

    public bool IsCached =>
        File.Exists(KernelPath) && File.Exists(InitramfsPath);

    /// <summary>
    /// Ensure kernel + initramfs are present locally. Re-uses the cached
    /// tarball if it's still on disk; downloads from Alpine CDN otherwise,
    /// extracts the two files we need, and discards the rest of the
    /// tarball contents (apks, modloop signatures, …).
    /// </summary>
    public async Task EnsureAvailableAsync(
        IProgress<DownloadProgress>? progress = null,
        CancellationToken ct = default)
    {
        Directory.CreateDirectory(_paths.ImagesDirectory);
        if (IsCached) { progress?.Report(DownloadProgress.Done(0)); return; }

        if (!File.Exists(TarballPath))
        {
            await DownloadAsync(progress, ct).ConfigureAwait(false);
        }

        ExtractKernelAndInitramfs();
    }

    private async Task DownloadAsync(IProgress<DownloadProgress>? progress, CancellationToken ct)
    {
        var sw = Stopwatch.StartNew();
        _log.LogInformation("Downloading Alpine netboot tarball from {Url}", TarballUrl);
        var tmp = TarballPath + ".part";
        try { File.Delete(tmp); } catch (IOException) { }

        using var resp = await _http.GetAsync(TarballUrl, HttpCompletionOption.ResponseHeadersRead, ct)
            .ConfigureAwait(false);
        if (!resp.IsSuccessStatusCode)
        {
            throw new HttpRequestException($"Alpine tarball: HTTP {(int)resp.StatusCode} {resp.ReasonPhrase}");
        }

        var totalBytes = resp.Content.Headers.ContentLength ?? -1;
        progress?.Report(DownloadProgress.Started(totalBytes));
        var copied = 0L;
        var buffer = new byte[64 * 1024];
        await using (var src = await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false))
        await using (var dst = File.Create(tmp))
        {
            int n;
            while ((n = await src.ReadAsync(buffer, ct).ConfigureAwait(false)) > 0)
            {
                await dst.WriteAsync(buffer.AsMemory(0, n), ct).ConfigureAwait(false);
                copied += n;
                if (progress is not null)
                {
                    var elapsed = sw.Elapsed.TotalSeconds;
                    progress.Report(new DownloadProgress(
                        BytesCopied: copied,
                        TotalBytes: totalBytes,
                        BytesPerSecond: elapsed > 0.1 ? (long)(copied / elapsed) : 0,
                        IsDone: false));
                }
            }
        }

        if (File.Exists(TarballPath)) File.Delete(TarballPath);
        File.Move(tmp, TarballPath);
        progress?.Report(DownloadProgress.Done(copied));
        _log.LogInformation("Alpine tarball downloaded in {Sec:F1}s ({Bytes} B)",
            sw.Elapsed.TotalSeconds, copied);
    }

    private void ExtractKernelAndInitramfs()
    {
        // Alpine netboot tarball layout (3.22):
        //   boot/vmlinuz-virt
        //   boot/initramfs-virt
        //   boot/config-virt
        //   boot/...
        //   apks/...
        // We pull the two boot files and discard everything else.
        using var fs = File.OpenRead(TarballPath);
        using var gz = new GZipStream(fs, CompressionMode.Decompress);
        using var tar = new TarReader(gz);
        TarEntry? entry;
        var kernelDone = false;
        var initrdDone = false;
        while ((entry = tar.GetNextEntry()) is not null)
        {
            var name = entry.Name;
            if (name.EndsWith("/vmlinuz-virt", StringComparison.Ordinal)
                || name.Equals("boot/vmlinuz-virt", StringComparison.Ordinal))
            {
                ExtractEntry(entry, KernelPath);
                kernelDone = true;
            }
            else if (name.EndsWith("/initramfs-virt", StringComparison.Ordinal)
                     || name.Equals("boot/initramfs-virt", StringComparison.Ordinal))
            {
                ExtractEntry(entry, InitramfsPath);
                initrdDone = true;
            }
            if (kernelDone && initrdDone) break;
        }
        if (!kernelDone || !initrdDone)
        {
            throw new InvalidDataException(
                "Alpine netboot tarball missing vmlinuz-virt or initramfs-virt");
        }
    }

    private static void ExtractEntry(TarEntry entry, string outputPath)
    {
        var dir = Path.GetDirectoryName(outputPath);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        if (entry.DataStream is null) return;
        using var dst = File.Create(outputPath);
        entry.DataStream.CopyTo(dst);
    }
}
