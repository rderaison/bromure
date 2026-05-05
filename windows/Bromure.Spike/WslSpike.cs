using Bromure.SandboxEngine.Wsl;

namespace Bromure.Spike;

/// <summary>
/// One-off smoke test for the WslDistro lifecycle wrapper. Imports a
/// fresh distro from a base tarball, runs a command inside, then
/// destroys it. Verifies WslCli's UTF-8 plumbing, ImportAsync,
/// LaunchAsync, UnregisterAsync — all in 30 seconds against the
/// real <c>wsl.exe</c>.
///
/// Usage: <c>bromure-spike wsl &lt;rootfs.tar.gz&gt;</c>
/// </summary>
public static class WslSpike
{
    public static async Task<int> RunAsync(string[] args)
    {
        if (args.Length < 1)
        {
            Console.Error.WriteLine("usage: bromure-spike wsl <rootfs.tar.gz>");
            return 2;
        }
        var rootfs = args[0];
        if (!File.Exists(rootfs))
        {
            Console.Error.WriteLine($"rootfs not found: {rootfs}");
            return 2;
        }

        var name = "bromure-spike-" + Guid.NewGuid().ToString("N")[..8];
        var installPath = Path.Combine(Path.GetTempPath(), name);
        Console.WriteLine($"[spike] using distro={name}");
        Console.WriteLine($"[spike] install path={installPath}");

        await using var d = new WslDistro(name, installPath);

        var t0 = DateTime.UtcNow;
        Console.WriteLine("[spike] importing…");
        await d.ImportAsync(rootfs);
        Console.WriteLine($"[spike] imported in {(DateTime.UtcNow - t0).TotalSeconds:F1}s");

        Console.WriteLine("[spike] uname -a:");
        var uname = await d.LaunchAsync(new[] { "uname", "-a" });
        Console.Write(uname.Stdout);

        Console.WriteLine("[spike] hostname (mirrored mode → matches Windows hostname):");
        var hostname = await d.LaunchAsync(new[] { "hostname" });
        Console.Write(hostname.Stdout);

        Console.WriteLine("[spike] /mnt/c reachable?");
        var ls = await d.LaunchAsync(new[] { "ls", "/mnt/c" }, user: "root");
        Console.Write(ls.Stdout.Length > 200 ? ls.Stdout[..200] + "…\n" : ls.Stdout);

        Console.WriteLine("[spike] curl 127.0.0.1 (proxy reachability sanity check):");
        var curl = await d.LaunchAsync(new[] { "curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "-m", "1", "http://127.0.0.1:1/" });
        Console.WriteLine($"  curl exit={curl.ExitCode}, stdout={curl.Stdout}");

        Console.WriteLine("[spike] terminating distro…");
        await d.TerminateAsync();

        Console.WriteLine("[spike] unregistering…");
        await d.UnregisterAsync();

        Console.WriteLine("[spike] done — all lifecycle steps OK");
        return 0;
    }
}
