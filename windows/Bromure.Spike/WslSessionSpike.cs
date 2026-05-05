using System.Text;
using Bromure.SandboxEngine.Wsl;

namespace Bromure.Spike;

/// <summary>
/// End-to-end <see cref="WslSession"/> exerciser. Imports the baked
/// rootfs, drops a synthetic home overlay, runs a short command (NOT
/// kitty — we want to verify the env injection + FS overlay landed,
/// not pop a GUI), and tears down. Reuses real bromure-base.tar.gz
/// so it surfaces any setup-wsl.sh shortcomings.
///
/// Usage: <c>bromure-spike wsl-session &lt;rootfs.tar.gz&gt;</c>
/// </summary>
public static class WslSessionSpike
{
    public static async Task<int> RunAsync(string[] args)
    {
        if (args.Length < 1)
        {
            Console.Error.WriteLine("usage: bromure-spike wsl-session <rootfs.tar.gz>");
            return 2;
        }
        var rootfs = args[0];
        if (!File.Exists(rootfs))
        {
            Console.Error.WriteLine($"rootfs not found: {rootfs}");
            return 2;
        }

        var distroName = "bromure-ses-" + Guid.NewGuid().ToString("N")[..8];
        var installPath = Path.Combine(Path.GetTempPath(), distroName);

        // Synthetic home overlay — what SessionHomeBuilder will produce
        // for real (kitty.conf, .bashrc, etc.). Here we just verify the
        // mechanism: drop a marker file, run cat from inside.
        var homeFiles = new Dictionary<string, byte[]>
        {
            [".bashrc"] = Encoding.UTF8.GetBytes("# session-overlay-marker\nexport BROMURE_TEST=overlay-ok\n"),
            [".config/kitty/kitty.conf"] = Encoding.UTF8.GetBytes("font_family JetBrains Mono\nfont_size 14\n"),
        };

        // Synthetic env vars — what the real path would set for an
        // ANTHROPIC_API_KEY profile + the per-tab HTTPS_PROXY.
        var env = new Dictionary<string, string>
        {
            ["ANTHROPIC_API_KEY"] = "sk-test-fake-1234",
            ["HTTPS_PROXY"] = "http://127.0.0.1:18443",  // fake; nothing actually listening
            ["http_proxy"] = "http://127.0.0.1:18443",
        };

        // Don't spawn kitty — `cat` lets us verify the overlay + env
        // landed without needing a graphical environment.
        var cfg = new WslSessionConfig
        {
            BaseRootfsPath = rootfs,
            DistroName = distroName,
            InstallPath = installPath,
            HomeFiles = homeFiles,
            EnvVars = env,
            GuestArgv = new[] { "bash", "-lc", "echo overlay-bashrc=$BROMURE_TEST; echo proxy=$HTTPS_PROXY; cat .config/kitty/kitty.conf; sleep 0.5" },
        };

        await using var session = new WslSession(cfg);
        Console.WriteLine($"[session] starting…");
        var t0 = DateTime.UtcNow;
        await session.StartAsync();
        Console.WriteLine($"[session] up in {(DateTime.UtcNow - t0).TotalSeconds:F1}s");

        // Wait for the spawned wsl.exe to exit (cat + sleep finishes).
        if (session.WslProcess is { } wp)
        {
            await wp.WaitForExitAsync();
            Console.WriteLine($"[session] guest cmd exit={wp.ExitCode}");
        }

        // Now run a few additional sanity probes via the still-running
        // distro before unregistering — verify the home overlay's actual
        // file contents, env-file persistence, etc.
        var probe = await session.Distro.LaunchAsync(
            new[] { "bash", "-c", "ls -la /home/bromure/.config/kitty/; cat /home/bromure/.bashrc | head -3" },
            user: "bromure");
        Console.WriteLine("[session] post-launch probe:");
        Console.Write(probe.Stdout);
        if (probe.Stderr.Length > 0) Console.Error.Write(probe.Stderr);

        Console.WriteLine("[session] tearing down…");
        await session.DisposeAsync();
        Console.WriteLine("[session] done");
        return 0;
    }
}
