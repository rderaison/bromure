namespace Bromure.SandboxEngine.Qemu;

/// <summary>
/// Resolves where QEMU + OVMF live on disk. Order:
///
/// <list type="number">
///   <item><b>Bundled.</b> <c>&lt;install&gt;\lib\qemu\qemu-system-x86_64.exe</c>.
///   This is what the installer drops per WIN32_AC_PLAN §6 — known-good
///   build, controlled SDL2/GTK versions, no dependency on whatever
///   QEMU the user happens to have installed.</item>
///   <item><b>Default install.</b> <c>C:\Program Files\qemu\</c> from
///   <c>winget install SoftwareFreedomConservancy.QEMU</c>. Used in
///   dev-loop builds before the installer is wired.</item>
///   <item><b>PATH fallback.</b> Whatever <c>qemu-system-x86_64.exe</c>
///   resolves to on the user's <c>PATH</c>.</item>
/// </list>
///
/// <para>Every entrypoint that needs a QEMU path goes through here so
/// the bundled-vs-installed decision is made in one place. The macOS
/// port has the equivalent uniformity for free (VZ is always-on);
/// Windows has to be explicit.</para>
/// </summary>
public static class QemuPaths
{
    public sealed record Resolution(string ExecutablePath, string Source, string? OvmfCodePath, string? OvmfVarsPath);

    /// <summary>Probe the configured locations and return the first that exists.</summary>
    public static Resolution Resolve()
    {
        // 1) Bundled — alongside the running EXE. The installer drops:
        //    <install>\lib\qemu\qemu-system-x86_64.exe
        //    <install>\lib\qemu\share\edk2-x86_64-code.fd  (+ vars)
        var baseDir = AppContext.BaseDirectory;
        // baseDir is typically bin/Release/net8.0-windows/win-x64 — five
        // dirs deep under the project (Bromure.AC / Bromure.Spike). The
        // shared `windows/dist/qemu-bundle/` lives one level *above*
        // the project, so the dev probe walks up 5, not 4. (Earlier
        // 4-up version landed inside the project dir, missed the
        // bundle, and silently fell back to winget.)
        foreach (var bundleRoot in new[]
        {
            Path.Combine(baseDir, "lib", "qemu"),
            Path.GetFullPath(Path.Combine(baseDir, "..", "..", "..", "..", "lib", "qemu")),
            // Local build output from windows/scripts/build-qemu.ps1.
            Path.GetFullPath(Path.Combine(baseDir, "..", "..", "..", "..", "..", "dist", "qemu-bundle")),
        })
        {
            var bundled = Path.Combine(bundleRoot, "qemu-system-x86_64.exe");
            if (File.Exists(bundled))
            {
                return new Resolution(
                    bundled,
                    "bundled",
                    PickOvmfCode(Path.Combine(bundleRoot, "share")),
                    PickOvmfVars(Path.Combine(bundleRoot, "share")));
            }
        }

        // 2) Default install location.
        const string winget = @"C:\Program Files\qemu\qemu-system-x86_64.exe";
        if (File.Exists(winget))
        {
            return new Resolution(
                winget, "winget",
                PickOvmfCode(@"C:\Program Files\qemu\share"),
                PickOvmfVars(@"C:\Program Files\qemu\share"));
        }

        // 3) PATH fallback. Last resort because we can't guarantee
        //    OVMF / firmware paths line up.
        var onPath = ResolveOnPath("qemu-system-x86_64.exe");
        if (onPath is not null)
        {
            var shareGuess = TryGuessShareDir(onPath);
            return new Resolution(
                onPath, "PATH",
                PickOvmfCode(shareGuess),
                PickOvmfVars(shareGuess));
        }

        // No QEMU at all. Caller surfaces "install the bundled host" UX.
        throw new FileNotFoundException(
            "QEMU not found. The host expects a bundled copy at "
            + Path.Combine(baseDir, "lib", "qemu", "qemu-system-x86_64.exe")
            + " (installed by the Bromure AC installer), or a system "
            + "QEMU at C:\\Program Files\\qemu\\, or anywhere on PATH.");
    }

    /// <summary>Return null when the share dir doesn't contain a recognised firmware.</summary>
    private static string? PickOvmfCode(string? shareDir)
    {
        if (shareDir is null || !Directory.Exists(shareDir)) return null;
        // Newer QEMU builds: edk2-x86_64-code.fd. Older: OVMF_CODE.fd.
        foreach (var name in new[] { "edk2-x86_64-code.fd", "OVMF_CODE.fd", "OVMF_CODE_4M.fd" })
        {
            var p = Path.Combine(shareDir, name);
            if (File.Exists(p)) return p;
        }
        return null;
    }

    private static string? PickOvmfVars(string? shareDir)
    {
        if (shareDir is null || !Directory.Exists(shareDir)) return null;
        // QEMU 11 ships only edk2-i386-vars.fd; it pads against
        // edk2-x86_64-code.fd to a 4 MiB total flash file. Older
        // builds carry OVMF_VARS.fd or OVMF_VARS_4M.fd directly.
        foreach (var name in new[] { "edk2-x86_64-vars.fd", "edk2-i386-vars.fd", "OVMF_VARS.fd", "OVMF_VARS_4M.fd" })
        {
            var p = Path.Combine(shareDir, name);
            if (File.Exists(p)) return p;
        }
        return null;
    }

    private static string? TryGuessShareDir(string qemuExe)
    {
        var dir = Path.GetDirectoryName(qemuExe);
        if (dir is null) return null;
        var candidates = new[]
        {
            Path.Combine(dir, "share"),
            Path.Combine(dir, "..", "share", "qemu"),
        };
        foreach (var c in candidates)
        {
            if (Directory.Exists(c)) return Path.GetFullPath(c);
        }
        return null;
    }

    private static string? ResolveOnPath(string exe)
    {
        var path = Environment.GetEnvironmentVariable("PATH");
        if (path is null) return null;
        foreach (var dir in path.Split(Path.PathSeparator))
        {
            try
            {
                var candidate = Path.Combine(dir, exe);
                if (File.Exists(candidate)) return candidate;
            }
            catch (ArgumentException) { /* malformed PATH entry */ }
        }
        return null;
    }
}
