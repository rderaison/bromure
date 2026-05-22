// macos-source: Sources/SandboxEngine/InstallIdentity.swift @ fe7e7d3a3e21
using Bromure.SandboxEngine.Hcs.Native;

namespace Bromure.SandboxEngine.Hcs;

/// <summary>
/// Pre-flight checks for HCS use. The Bromure AC shell calls this once
/// at startup and surfaces the result on the Welcome view: without
/// full Hyper-V, the user-visible "Get Started" path will fail in
/// non-obvious ways (vmcompute returns HCS_E_INVALID_JSON for every
/// VM-mode CreateComputeSystem) so we'd rather refuse up front with
/// a clear, copy-pasteable fix.
///
/// <para><b>Why the vmms.exe check, not just vmcompute.dll?</b>
/// vmcompute.dll ships with the lighter "Windows Hypervisor Platform"
/// feature (used by WSL2, Docker Desktop, QEMU+WHPX). VirtualMachine-
/// mode HCS Creates only succeed when the full Microsoft-Hyper-V
/// feature is enabled; vmms.exe is that feature's distinctive
/// binary. The e2e harness confirmed this empirically on a machine
/// that had vmcompute.dll loadable + service running but no vmms —
/// every Create returned 0xC0370103 (HCS_E_INVALID_JSON), even for
/// minimal {}.
/// </para>
///
/// <para>Detection is best-effort and silent on failure: a missing
/// vmms.exe is a clean No, an exception during detection is a Maybe
/// that we treat as "assume OK" rather than refuse to launch over
/// our own bug.</para>
/// </summary>
public static class HyperVPreflight
{
    /// <summary>Outcome of the pre-flight check.</summary>
    public sealed record Result(bool Ok, string? ErrorMessage, string? FixInstruction);

    public static Result Detect()
    {
        try
        {
            // vmcompute.dll loadable is the cheapest signal that the
            // HCS surface exists at all. If LoadLibrary returns null,
            // Hypervisor Platform isn't even installed — and that's
            // a different, even harder failure to recover from.
            var hMod = NativeMethods.LoadLibraryW("vmcompute.dll");
            if (hMod == IntPtr.Zero)
            {
                return new Result(false,
                    "Windows Hypervisor Platform is not installed.",
                    BuildFix(includeHvPlatform: true));
            }
            NativeMethods.FreeLibrary(hMod);

            // vmms.exe distinguishes "full Hyper-V" from
            // "Hypervisor Platform only." Without it, Bromure can't
            // create VM-mode compute systems.
            var sys = Environment.GetFolderPath(Environment.SpecialFolder.System);
            var vmms = Path.Combine(sys, "vmms.exe");
            if (!File.Exists(vmms))
            {
                return new Result(false,
                    "The Microsoft-Hyper-V Windows feature is not enabled. " +
                    "Bromure needs full Hyper-V (not just Hypervisor Platform) " +
                    "to create per-session Linux VMs.",
                    BuildFix(includeHvPlatform: false));
            }

            return new Result(true, null, null);
        }
        catch
        {
            // Best-effort — never block the app on our own detection bug.
            return new Result(true, null, null);
        }
    }

    /// <summary>The exact dism command the user needs to run. Kept as
    /// a separate property so the UI can wire a "Copy" button to it
    /// without parsing the prose error message.
    /// <para><b>dism.exe, not Enable-WindowsOptionalFeature.</b> The
    /// PowerShell cmdlet routinely fails with "Class not registered"
    /// on Win11 builds where the DISM PS provider's COM class isn't
    /// usable from a non-elevated or wow64 session. dism.exe goes
    /// through a different code path and works in every Pro+ setup
    /// we've seen.</para></summary>
    public static string FixCommand =>
        "dism.exe /Online /Enable-Feature /FeatureName:Microsoft-Hyper-V /All /NoRestart";

    private static string BuildFix(bool includeHvPlatform)
    {
        var sb = new System.Text.StringBuilder();
        sb.AppendLine("Open an elevated Command Prompt (Start → \"cmd\" → Run as administrator),");
        sb.AppendLine("then run:");
        sb.AppendLine();
        sb.AppendLine("  " + FixCommand);
        if (includeHvPlatform)
        {
            sb.AppendLine("  dism.exe /Online /Enable-Feature /FeatureName:HypervisorPlatform /NoRestart");
        }
        sb.AppendLine();
        sb.AppendLine("Then reboot.");
        sb.AppendLine();
        sb.AppendLine("Notes:");
        sb.AppendLine("  • Available on Windows 11 Pro / Enterprise / Education only (NOT Home).");
        sb.AppendLine("  • Requires a reboot to activate.");
        sb.AppendLine("  • Compatible with WSL2 / Docker Desktop / VBS — adds full Hyper-V on top.");
        sb.AppendLine("  • The PowerShell Enable-WindowsOptionalFeature equivalent often fails");
        sb.AppendLine("    with \"Class not registered\" on recent Win11 builds — use dism.exe instead.");
        return sb.ToString().TrimEnd();
    }

    /// <summary>P/Invoke surface kept private — callers should use
    /// <see cref="Detect"/>, not the underlying LoadLibrary helpers.</summary>
    private static class NativeMethods
    {
        [System.Runtime.InteropServices.DllImport("kernel32.dll",
            CharSet = System.Runtime.InteropServices.CharSet.Unicode,
            SetLastError = true, EntryPoint = "LoadLibraryW")]
        public static extern IntPtr LoadLibraryW(string lpFileName);

        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
        public static extern bool FreeLibrary(IntPtr hModule);
    }
}
