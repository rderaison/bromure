using System.Reflection;
using System.Text;

namespace Bromure.SandboxEngine.Wsl;

/// <summary>
/// Bakes the Bromure base rootfs (<c>bromure-base.tar.gz</c>) by
/// importing a clean source rootfs as a transient distro, running
/// <c>setup-wsl.sh</c> inside it, then exporting the customised
/// distro and unregistering it.
///
/// <para>Replaces the <see cref="Image.AlpineInstaller"/> path that
/// the QEMU port used. WSL gives us a kernel and a way to run the
/// guest userspace from day one, so the bake is "spin up a clean
/// distro, customise, snapshot" — no Alpine driver, no serial
/// console, no qemu-img convert.</para>
///
/// <para>Inputs:</para>
/// <list type="bullet">
///   <item><c>sourceRootfs</c> — path to a base Ubuntu rootfs tarball
///   (the user's existing <c>wsl --export Ubuntu-24.04</c> output is
///   fine for the spike; production would ship a vendored minimal
///   rootfs).</item>
///   <item><c>outputPath</c> — where to write the customised
///   <c>bromure-base.tar.gz</c>. Imported by <see cref="WslDistro"/>
///   on every session launch.</item>
/// </list>
/// </summary>
public sealed class RootfsBaker
{
    private const string DoneMarker = "SANDBOX_SETUP_DONE";
    private const string FailMarker = "SANDBOX_SETUP_FAILED";

    /// <summary>Default filename for the baked artefact.</summary>
    public const string OutputBaseFileName = "bromure-base.tar.gz";

    public sealed record BakeProgress(string Stage, string Message, double Fraction);

    public async Task BakeAsync(
        string sourceRootfs,
        string outputPath,
        IProgress<BakeProgress>? progress = null,
        CancellationToken ct = default)
    {
        if (!File.Exists(sourceRootfs))
            throw new FileNotFoundException($"source rootfs not found: {sourceRootfs}", sourceRootfs);

        Directory.CreateDirectory(Path.GetDirectoryName(outputPath)!);

        // 1) Spin up a transient distro from the source rootfs.
        var bakeName = "bromure-bake-" + Guid.NewGuid().ToString("N")[..8];
        var bakeInstallPath = Path.Combine(Path.GetTempPath(), bakeName);
        progress?.Report(new BakeProgress("import", "Importing source rootfs into a transient distro…", 0.05));

        await using var distro = new WslDistro(bakeName, bakeInstallPath);
        await distro.ImportAsync(sourceRootfs, ct).ConfigureAwait(false);

        // 2) Drop setup-wsl.sh somewhere the distro can read it.
        // /mnt/c/... avoids needing to pipe via stdin (which has
        // newline-conversion edge cases) — Windows host writes,
        // distro reads via 9p.
        var scriptHostPath = Path.Combine(Path.GetTempPath(), bakeName + ".sh");
        await File.WriteAllBytesAsync(scriptHostPath, LoadEmbeddedScript(), ct).ConfigureAwait(false);
        var scriptGuestPath = ToWslPath(scriptHostPath);
        progress?.Report(new BakeProgress("setup", "Running setup-wsl.sh in the bake distro…", 0.20));

        try
        {
            // 3) Run the script. setup-wsl.sh ends with `echo SANDBOX_SETUP_DONE`;
            // we don't strictly need to wait for that marker because LaunchAsync
            // returns when the script exits and the exit code is the truth, but
            // we check for FailMarker in stdout/stderr to surface a clean
            // diagnostic when apt or npm hits a transient hiccup.
            var result = await distro.LaunchAsync(
                new[] { "bash", scriptGuestPath },
                user: "root",
                ct: ct).ConfigureAwait(false);

            if (!result.Success || result.Stdout.Contains(FailMarker, StringComparison.Ordinal))
            {
                var diag = result.Stderr.Length > 0 ? result.Stderr : result.Stdout;
                if (diag.Length > 4000) diag = "…" + diag[^4000..];
                throw new WslException(
                    $"setup-wsl.sh failed inside bake distro (exit {result.ExitCode}):\n{diag}");
            }
            if (!result.Stdout.Contains(DoneMarker, StringComparison.Ordinal))
            {
                throw new WslException(
                    $"setup-wsl.sh exited 0 but never emitted {DoneMarker} — bake may be incomplete:\n{result.Stdout}");
            }

            progress?.Report(new BakeProgress("export", "Exporting customised distro to bromure-base.tar.gz…", 0.85));

            // 4) Export. Use --format tar.gz so the output is compressed
            // (gives ~3-4x reduction over plain tar) and matches what
            // WslDistro.ImportAsync expects to consume.
            if (File.Exists(outputPath)) File.Delete(outputPath);
            var export = await WslCli.RunAsync(
                new[] { "--export", bakeName, outputPath, "--format", "tar.gz" },
                ct).ConfigureAwait(false);
            export.ThrowIfFailed($"wsl --export {bakeName}");
        }
        finally
        {
            // Always clean up the bake distro and the host-side script.
            try { await distro.UnregisterAsync(ct).ConfigureAwait(false); } catch { }
            try { File.Delete(scriptHostPath); } catch { }
        }

        progress?.Report(new BakeProgress("done", $"Baked rootfs at {outputPath}", 1.0));
    }

    /// <summary>
    /// <c>C:\foo\bar.sh</c> → <c>/mnt/c/foo/bar.sh</c> — the WSL2 9p
    /// path that the bake distro can read from. Drive letters are
    /// always lowercase under WSL.
    /// </summary>
    internal static string ToWslPath(string winPath)
    {
        if (winPath.Length < 2 || winPath[1] != ':')
            throw new ArgumentException($"Expected a drive-letter path, got: {winPath}", nameof(winPath));
        var drive = char.ToLowerInvariant(winPath[0]);
        return "/mnt/" + drive + winPath[2..].Replace('\\', '/');
    }

    private static byte[] LoadEmbeddedScript()
    {
        var asm = typeof(RootfsBaker).Assembly;
        var resourceName = asm.GetManifestResourceNames()
            .FirstOrDefault(n => n.EndsWith(".setup-wsl.sh", StringComparison.Ordinal))
            ?? throw new InvalidOperationException(
                "setup-wsl.sh not embedded — check Bromure.SandboxEngine.csproj <EmbeddedResource>.");
        using var stream = asm.GetManifestResourceStream(resourceName)
            ?? throw new InvalidOperationException("Embedded setup-wsl.sh stream returned null.");
        using var ms = new MemoryStream();
        stream.CopyTo(ms);
        // Normalise to LF — the script will run under bash inside the
        // distro, and CRLF makes bash sad.
        var text = Encoding.UTF8.GetString(ms.ToArray()).Replace("\r\n", "\n");
        return Encoding.UTF8.GetBytes(text);
    }
}
