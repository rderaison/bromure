using System.Runtime.InteropServices;

namespace Bromure.SandboxEngine.Hcs;

/// <summary>
/// Host-RAM scaling helper for VM sizing. Mirrors macOS's
/// <c>Profile.defaultMemoryGB()</c> formula: pick a number that gives
/// the guest enough room for an agent + Chromium + a few tools, but
/// leaves the host workable.
///
/// <para>Returns a value in GiB. Always at least 2 (a Linux desktop +
/// Chromium below this thrashes), at most 8 (more than that is a niche
/// power-user choice that should come from the profile).</para>
/// </summary>
public static class HostMemoryProbe
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetPhysicallyInstalledSystemMemory(out ulong totalKB);

    public static int DefaultGuestMemoryGB()
    {
        try
        {
            if (!GetPhysicallyInstalledSystemMemory(out var totalKb)) return 4;
            // host_gb / 4, clamped to [2, 8]. A 16 GB host gets 4 GB;
            // 32 GB gets 8 GB; 8 GB gets 2 GB (the minimum).
            var hostGb = (int)(totalKb / 1024 / 1024);
            var picked = hostGb / 4;
            if (picked < 2) return 2;
            if (picked > 8) return 8;
            return picked;
        }
        catch
        {
            return 4;
        }
    }
}
