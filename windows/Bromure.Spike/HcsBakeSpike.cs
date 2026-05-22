using Bromure.SandboxEngine.Hcs;
using Bromure.SandboxEngine.Image;

namespace Bromure.Spike;

/// <summary>
/// Headless bake driver for the HCS path. Drives the same
/// Alpine-based <see cref="VmBaker.BakeAsync"/> the AC's Get Started
/// flow uses — downloads the Alpine virt ISO, boots it in a transient
/// Hyper-V Gen2 VM, runs setup.sh inside, captures the result.
///
/// Usage: <c>bromure-spike bake-hcs &lt;output-dir&gt;</c>
/// </summary>
public static class HcsBakeSpike
{
    public static async Task<int> RunAsync(string[] args)
    {
        if (args.Length < 1)
        {
            Console.Error.WriteLine("usage: bromure-spike bake-hcs <output-dir>");
            return 2;
        }
        var outputDir = args[0];

        Console.WriteLine($"[bake-hcs] output dir: {outputDir}");
        Console.WriteLine($"[bake-hcs] Alpine ISO: {VmBaker.AlpineIsoFileName} (cached or fetched on demand)");

        var baker = new VmBaker();
        var t0 = DateTime.UtcNow;
        var progress = new Progress<VmBaker.BakeProgress>(p =>
        {
            if (p.Stage == "console") Console.Write(p.Message);
            else if (!double.IsNaN(p.Fraction))
                Console.WriteLine($"[bake-hcs] {p.Stage,-10} {p.Fraction,5:P0}  {p.Message}");
            else
                Console.WriteLine($"[bake-hcs] {p.Stage,-10}        {p.Message}");
        });

        try
        {
            await baker.BakeAsync(outputDir, progress);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[bake-hcs] FAILED: {ex.Message}");
            return 1;
        }

        // Stamp the bake's version + per-bake UUID so the launcher's
        // image-version drift detection has data to compare against.
        // Without this the in-app baker and the spike CLI produce
        // different artefacts (the in-app one stamps, the spike
        // didn't), and a spike-built base never triggers the
        // "Reset and launch" alert on rebuild.
        try
        {
            var paths = new Bromure.Platform.WindowsAppPaths();
            // Set ImagesDirectory override: the spike was given an
            // arbitrary output dir, but WindowsAppPaths.ImagesDirectory
            // is the user's canonical one. We honor the user's choice
            // by stamping wherever the artefacts landed, not the
            // canonical dir.
            var stampPath = System.IO.Path.Combine(outputDir, "base.version");
            var stamped = ImageManager.ImageVersion + ":" + Guid.NewGuid().ToString("N");
            System.IO.File.WriteAllText(stampPath, stamped);
            Console.WriteLine($"[bake-hcs] stamped {stampPath} = {stamped}");
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("[bake-hcs] stamp write failed: " + ex.Message);
        }

        var dur = DateTime.UtcNow - t0;
        Console.WriteLine($"[bake-hcs] OK — {dur.TotalSeconds:F0}s");
        return 0;
    }
}
