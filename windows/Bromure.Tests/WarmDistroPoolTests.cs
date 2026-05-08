using Bromure.SandboxEngine.Wsl;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Pool tests that don't require a real WSL install. The actual
/// <c>wsl --import</c> path is exercised by the spike + manual smoke;
/// here we cover the topper-upper's behavior when the rootfs is
/// missing and the dispose contract.
/// </summary>
public class WarmDistroPoolTests
{
    [Fact]
    public async Task Acquire_returns_null_when_rootfs_never_appears()
    {
        var poolRoot = Path.Combine(Path.GetTempPath(), "bromure-test-pool-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(poolRoot);
        try
        {
            await using var pool = new WarmDistroPool(
                baseRootfsPathProvider: () => "C:\\does\\not\\exist.tar.gz",
                poolRoot: poolRoot);
            pool.Start();
            // The topper-upper will spin on the missing rootfs without
            // ever pushing a warm distro. Acquire should time out and
            // return null so the caller falls back to a cold path.
            var got = await pool.AcquireAsync(TimeSpan.FromMilliseconds(150),
                CancellationToken.None);
            got.Should().BeNull();
        }
        finally
        {
            try { Directory.Delete(poolRoot, recursive: true); } catch { }
        }
    }

    [Fact]
    public async Task Dispose_idempotent_when_never_started()
    {
        var poolRoot = Path.Combine(Path.GetTempPath(), "bromure-test-pool-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(poolRoot);
        try
        {
            var pool = new WarmDistroPool(
                baseRootfsPathProvider: () => "",
                poolRoot: poolRoot);
            await pool.DisposeAsync();
            // Second dispose must not throw.
            await pool.DisposeAsync();
        }
        finally
        {
            try { Directory.Delete(poolRoot, recursive: true); } catch { }
        }
    }

    [Fact]
    public void Warm_name_prefix_is_stable()
    {
        // Orphan cleanup matches against this prefix; if it changes,
        // a previous-run warm distro never gets reaped.
        WarmDistroPool.WarmNamePrefix.Should().Be("bromure-warm-");
    }
}
