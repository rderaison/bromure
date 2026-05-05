using Bromure.SandboxEngine.Qemu;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class QemuCommandBuilderTests
{
    private static QemuConfig BaseConfig() => new()
    {
        QemuExecutable = @"C:\fake\qemu.exe",
        OvmfCode = @"C:\fake\OVMF_CODE.fd",
        OvmfVars = @"C:\fake\OVMF_VARS.fd",
        DiskPath = @"C:\fake\session.qcow2",
        QmpEndpoint = "tcp:127.0.0.1:4444",
    };

    [Fact]
    public void Build_AlwaysIncludesWhpxAccelerator()
    {
        var args = QemuCommandBuilder.Build(BaseConfig());
        args.Should().Contain(a => a.StartsWith("whpx", StringComparison.Ordinal));
    }

    [Fact]
    public void Build_OmitsVsockByDefaultOnWindows()
    {
        // The MSYS2/winget QEMU build doesn't ship vhost-vsock-pci, so
        // EnableVsock must default to false. Phase-0 risk 1's B-plan
        // tunnels bridges over TCP-on-NAT instead.
        var args = QemuCommandBuilder.Build(BaseConfig());
        args.Should().NotContain(a => a.Contains("vhost-vsock-pci"));
    }

    [Fact]
    public void Build_WithVsockEnabled_AttachesVhostDevice()
    {
        var args = QemuCommandBuilder.Build(BaseConfig() with { EnableVsock = true, GuestCid = 7 });
        args.Should().Contain("vhost-vsock-pci,guest-cid=7");
    }

    [Fact]
    public void Build_DropsOvmfWhenAnyFlashFileMissing()
    {
        var args = QemuCommandBuilder.Build(BaseConfig() with { OvmfCode = null, OvmfVars = null });
        args.Should().NotContain(a => a.Contains("pflash"));
    }

    [Fact]
    public void Build_NinePShares_GenerateFsdevAndDeviceFlags()
    {
        var args = QemuCommandBuilder.Build(BaseConfig() with
        {
            Shares = new[]
            {
                new NinePShare(MountTag: "bromure-home", HostPath: @"C:\home"),
                new NinePShare(MountTag: "bromure-meta", HostPath: @"C:\meta", ReadOnly: true),
            },
        });
        args.Should().Contain(a => a.Contains("mount_tag=bromure-home"));
        args.Should().Contain(a => a.Contains("mount_tag=bromure-meta"));
        args.Should().Contain(a => a.Contains("path=C:\\meta") && a.Contains("readonly=on"));
    }

    [Fact]
    public void Build_NetworkBridged_RequiresAdapterName()
    {
        FluentActions.Invoking(() =>
            QemuCommandBuilder.Build(BaseConfig() with { Network = NetworkMode.Bridged }))
            .Should().Throw<InvalidOperationException>();
    }
}
