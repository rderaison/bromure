using System.Diagnostics;
using System.Globalization;
using System.Net.Http;
using System.Security.Cryptography;
using Bromure.Platform;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Bromure.SandboxEngine.Image;

/// <summary>
/// Slim port of <c>Sources/AgentCoding/UbuntuImageManager.swift</c>'s
/// download surface — replaces "no base image" with "fetches it, with
/// progress, on demand".
///
/// <para>v1 ships an Alpine virt ISO (small, boots fast, plenty for the
/// spike). The eventual full base is a custom-built qcow2 produced by
/// <c>setup.sh</c> in the guest; that build pipeline is a follow-up.</para>
///
/// <para><b>Storage.</b> Images cache under <see cref="IAppPaths.ImagesDirectory"/>.
/// We checksum + atomic-rename so a partial download can't be served as
/// the canonical artefact.</para>
/// </summary>
public sealed class ImageManager
{
    public sealed record ImageDescriptor(
        string FileName,
        Uri Url,
        long ExpectedBytes,
        /// <summary>
        /// SHA-256 hex of the canonical artefact. Null = skip verification
        /// (only for ad-hoc dev images).
        /// </summary>
        string? ExpectedSha256);

    /// <summary>
    /// Alpine virt 3.20.3 — ~62 MB, boots in &lt;5 s under WHPX. The
    /// download covers Gate 0 (a working bootable artefact ships with
    /// the host out of the box).
    ///
    /// <para>SHA-256 pinned from the Alpine release page so a partial
    /// or corrupted download fails verification + redownloads. (Pulled
    /// from <c>https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/alpine-virt-3.20.3-x86_64.iso.sha256</c>.)</para>
    /// </summary>
    public static readonly ImageDescriptor AlpineVirt = new(
        FileName: "alpine-virt-3.20.3-x86_64.iso",
        Url: new Uri("https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/alpine-virt-3.20.3-x86_64.iso"),
        ExpectedBytes: 63_963_136,
        ExpectedSha256: "81df854fbd7327d293c726b1eeeb82061d3bc8f5a86a6f77eea720f6be372261");

    // The Ubuntu Noble cloud image descriptor was removed in v14 when we
    // switched the bake from cloud-init/cloud-image to Alpine-netboot +
    // debootstrap (see AlpineInstaller). The cloud image isn't downloaded
    // by any code path anymore.

    private readonly IAppPaths _paths;
    private readonly ILogger _log;
    private readonly HttpClient _http;

    public ImageManager(IAppPaths paths, ILogger? log = null, HttpClient? http = null)
    {
        _paths = paths;
        _log = log ?? NullLogger.Instance;
        _http = http ?? new HttpClient { Timeout = TimeSpan.FromMinutes(20) };
    }

    /// <summary>
    /// Human-readable major version this build of the app targets.
    /// Bumped whenever the bake script changes in a way that
    /// invalidates an existing child VHDX (kernel rebuild, layout
    /// change, etc.). Matches the macOS port's
    /// <c>UbuntuImageManager.imageVersion</c>. The stamp written to
    /// disk combines this with a per-bake UUID, so two bakes of the
    /// same code version still invalidate stale children (the parent
    /// VHDX gets a new <c>UniqueId</c> on every bake and HCS rejects
    /// child VHDXs whose parent locator no longer matches).
    /// </summary>
    public const string ImageVersion = "100";

    /// <summary>
    /// Path of the stamp file written into the images dir at the end
    /// of every successful bake. Format: <c>&lt;ImageVersion&gt;:&lt;bake-uuid&gt;</c>
    /// — e.g. <c>100:bake-1f3a…</c>. The UUID half ensures every
    /// rebake produces a different stamp even when ImageVersion
    /// didn't bump, so drift detection in the launcher actually
    /// fires and the user gets the "Reset and launch" prompt.
    /// </summary>
    public string VersionStampPath
        => Path.Combine(_paths.ImagesDirectory, "base.version");

    /// <summary>Read the version stamp left by the most recent bake, or
    /// null if no stamp exists (no base baked, or a pre-stamping bake).</summary>
    public string? ReadInstalledImageVersion()
    {
        try
        {
            return File.Exists(VersionStampPath)
                ? File.ReadAllText(VersionStampPath).Trim()
                : null;
        }
        catch { return null; }
    }

    /// <summary>
    /// Stamp the installed image version. Called by the bake driver at
    /// the end of a successful bake. Always rotates the per-bake UUID
    /// so subsequent launches see a different string even when
    /// <see cref="ImageVersion"/> didn't bump. Idempotent within a
    /// single call but not across calls — that's the whole point.
    /// </summary>
    public void WriteInstalledImageVersion(string version)
    {
        Directory.CreateDirectory(_paths.ImagesDirectory);
        // Always append a fresh UUID. Without this two bakes of the
        // same ImageVersion string would produce identical stamps,
        // and the launcher would reuse a stale child VHDX whose
        // parent locator no longer matches — HCS rejects with
        // 0xC03A000E ("parent identifier mismatch") at VM start.
        var stamped = version + ":" + Guid.NewGuid().ToString("N");
        File.WriteAllText(VersionStampPath, stamped);
    }

    /// <summary>Local cache path for <paramref name="image"/>.</summary>
    public string LocalPath(ImageDescriptor image)
        => Path.Combine(_paths.ImagesDirectory, image.FileName);

    /// <summary>
    /// True iff the image is on disk and (a) the size matches within
    /// 1 MiB tolerance and (b) when a checksum is pinned, the file
    /// hashes to the expected SHA-256.
    /// </summary>
    /// <remarks>
    /// Hash verification reads the entire file (~62 MB for Alpine virt,
    /// runs in well under a second on NVMe). It costs less than booting
    /// QEMU against a corrupt image and getting a vague QMP-timeout
    /// failure mode that's hard to diagnose.
    /// </remarks>
    public bool IsCached(ImageDescriptor image)
    {
        var path = LocalPath(image);
        if (!File.Exists(path)) return false;
        var size = new FileInfo(path).Length;
        if (Math.Abs(size - image.ExpectedBytes) >= 1_048_576) return false;
        if (image.ExpectedSha256 is null) return true;
        try
        {
            using var fs = File.OpenRead(path);
            using var sha = SHA256.Create();
            var hash = sha.ComputeHash(fs);
            var actual = Convert.ToHexString(hash).ToLowerInvariant();
            return string.Equals(actual, image.ExpectedSha256.ToLowerInvariant(), StringComparison.Ordinal);
        }
        catch (IOException)
        {
            return false;
        }
    }

    /// <summary>
    /// Ensure the image is on disk. Returns its local path. If a cached
    /// copy already matches, this is a noop.
    /// </summary>
    public async Task<string> EnsureAvailableAsync(
        ImageDescriptor image,
        IProgress<DownloadProgress>? progress = null,
        CancellationToken ct = default)
    {
        Directory.CreateDirectory(_paths.ImagesDirectory);
        var dst = LocalPath(image);
        if (IsCached(image))
        {
            progress?.Report(DownloadProgress.Done(image.ExpectedBytes));
            return dst;
        }

        var tmp = dst + ".part";
        // Best-effort: drop a stale .part — partial download from a
        // killed process won't resume cleanly without a Range request.
        try { if (File.Exists(tmp)) File.Delete(tmp); }
        catch (IOException) { }

        var sw = Stopwatch.StartNew();
        _log.LogInformation("Downloading {Url} → {Dst}", image.Url, dst);
        progress?.Report(DownloadProgress.Started(image.ExpectedBytes));

        using var resp = await _http.GetAsync(image.Url, HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
        if (!resp.IsSuccessStatusCode)
        {
            throw new HttpRequestException($"HTTP {(int)resp.StatusCode}: {resp.ReasonPhrase}");
        }

        var totalBytes = resp.Content.Headers.ContentLength ?? image.ExpectedBytes;
        var copied = 0L;
        var buffer = new byte[64 * 1024];
        await using (var src = await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false))
        await using (var output = File.Create(tmp))
        {
            int n;
            while ((n = await src.ReadAsync(buffer.AsMemory(), ct).ConfigureAwait(false)) > 0)
            {
                await output.WriteAsync(buffer.AsMemory(0, n), ct).ConfigureAwait(false);
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

        if (image.ExpectedSha256 is not null)
        {
            await VerifyChecksumAsync(tmp, image.ExpectedSha256, ct).ConfigureAwait(false);
        }

        // Atomic rename — if rename fails, leave .part for next run.
        if (File.Exists(dst)) File.Delete(dst);
        File.Move(tmp, dst);

        sw.Stop();
        _log.LogInformation("Image {Name} ready ({Bytes} bytes in {Sec:F1}s)",
            image.FileName, copied, sw.Elapsed.TotalSeconds);
        progress?.Report(DownloadProgress.Done(copied));
        return dst;
    }

    private static async Task VerifyChecksumAsync(string path, string expectedHex, CancellationToken ct)
    {
        await using var fs = File.OpenRead(path);
        using var sha = SHA256.Create();
        var hash = await sha.ComputeHashAsync(fs, ct).ConfigureAwait(false);
        var actual = Convert.ToHexString(hash).ToLowerInvariant();
        var expected = expectedHex.ToLowerInvariant();
        if (!string.Equals(actual, expected, StringComparison.Ordinal))
        {
            throw new InvalidDataException($"SHA-256 mismatch: expected {expected}, got {actual}");
        }
    }
}

public sealed record DownloadProgress(
    long BytesCopied,
    long TotalBytes,
    long BytesPerSecond,
    bool IsDone)
{
    public double Fraction => TotalBytes <= 0 ? 0 : Math.Min(1.0, (double)BytesCopied / TotalBytes);

    public string BytesCopiedHuman => Humanize(BytesCopied);
    public string TotalBytesHuman => Humanize(TotalBytes);
    public string SpeedHuman => Humanize(BytesPerSecond) + "/s";

    public static DownloadProgress Started(long total) => new(0, total, 0, false);
    public static DownloadProgress Done(long total) => new(total, total, 0, true);

    private static string Humanize(long bytes)
    {
        if (bytes < 1024) return bytes + " B";
        var u = new[] { "KiB", "MiB", "GiB", "TiB" };
        var v = bytes / 1024.0;
        var i = 0;
        while (v >= 1024 && i < u.Length - 1) { v /= 1024; i++; }
        return string.Format(CultureInfo.InvariantCulture, "{0:F1} {1}", v, u[i]);
    }
}
