using Bromure.SandboxEngine.Wsl;

namespace Bromure.Spike;

/// <summary>
/// Headless bake driver. Imports the source rootfs, runs setup-wsl.sh
/// in the transient bake distro, exports bromure-base.tar.gz.
///
/// Usage: <c>bromure-spike bake-wsl &lt;source-rootfs&gt; &lt;output-path&gt;</c>
/// </summary>
public static class WslBakeSpike
{
    public static async Task<int> RunAsync(string[] args)
    {
        if (args.Length < 2)
        {
            Console.Error.WriteLine("usage: bromure-spike bake-wsl <source-rootfs> <output-path>");
            return 2;
        }
        var source = args[0];
        var output = args[1];
        if (!File.Exists(source))
        {
            Console.Error.WriteLine($"source rootfs not found: {source}");
            return 2;
        }

        Console.WriteLine($"[bake] source: {source} ({(new FileInfo(source).Length / 1024 / 1024)} MB)");
        Console.WriteLine($"[bake] output: {output}");

        var baker = new RootfsBaker();
        var t0 = DateTime.UtcNow;
        var progress = new Progress<RootfsBaker.BakeProgress>(p =>
            Console.WriteLine($"[bake] {p.Stage,-7} {p.Fraction,5:P0}  {p.Message}"));

        try
        {
            await baker.BakeAsync(source, output, progress);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[bake] FAILED: {ex.Message}");
            return 1;
        }

        var dur = DateTime.UtcNow - t0;
        var sizeMb = (new FileInfo(output).Length / 1024 / 1024);
        Console.WriteLine($"[bake] OK — {sizeMb} MB in {dur.TotalSeconds:F0}s");
        return 0;
    }
}
