using Bromure.SandboxEngine.Hcs;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class HcsSchemaTests
{
    [Fact]
    public void HcsVmConfig_emits_Uefi_boot_from_first_scsi_disk()
    {
        // The HCS-direct session VMs boot UEFI from the bake VHDX's
        // EFI partition (grub from setup.sh's grub-install).
        // LinuxKernelDirect was the prior shape — current vmcompute
        // builds reject it for VM-mode compute systems, so we no
        // longer emit kernel/initrd paths in the chipset block.
        var cfg = new HcsVmConfig
        {
            RootDiskPath = @"C:\sessions\foo\disk.vhdx",
        };
        var doc = Bromure.SandboxEngine.Hcs.Native.HcsSchema.Serialize(cfg.BuildSchema());
        doc.Should().Contain("Uefi");
        doc.Should().Contain("BootThis");
        doc.Should().Contain("ScsiDrive");
        doc.Should().NotContain("LinuxKernelDirect");
        // SCSI controller key is "0", matched by UefiBootEntry.DiskNumber.
        doc.Should().Contain("\"0\":");
    }

    [Fact]
    public void HcsVmConfig_emits_Plan9_shares_when_provided()
    {
        var cfg = new HcsVmConfig
        {
            KernelPath = "k", InitrdPath = "i", RootDiskPath = "d",
            Plan9Shares = new Dictionary<string, Plan9ShareSpec>
            {
                ["overlay"] = new(@"C:\stage\overlay", 50001, "bromure-overlay", ReadOnly: true),
            },
        };
        var doc = Bromure.SandboxEngine.Hcs.Native.HcsSchema.Serialize(cfg.BuildSchema());
        doc.Should().Contain("Plan9");
        doc.Should().Contain("bromure-overlay");
        doc.Should().Contain("50001");
    }

    [Fact]
    public void BakeArtefacts_AllExist_returns_false_when_anything_missing()
    {
        var dir = Path.Combine(Path.GetTempPath(), "bromure-tests-" + Guid.NewGuid().ToString("N")[..6]);
        Directory.CreateDirectory(dir);
        try
        {
            var a = BakeArtefacts.InDirectory(dir);
            a.AllExist().Should().BeFalse();
            File.WriteAllText(a.BaseVhdxPath, "");
            File.WriteAllText(a.KernelPath, "");
            a.AllExist().Should().BeFalse();  // initrd still missing
            File.WriteAllText(a.InitrdPath, "");
            a.AllExist().Should().BeTrue();
        }
        finally
        {
            try { Directory.Delete(dir, recursive: true); } catch { }
        }
    }

    [Fact]
    public void HvSocket_ServiceIdFromPort_matches_Microsoft_template()
    {
        // Port 0 → 00000000-FACB-11E6-BD58-64006A7986D3
        var g = Bromure.SandboxEngine.Hcs.Native.HvSocketApi.ServiceIdFromPort(0);
        g.ToString("D").Should().Be("00000000-facb-11e6-bd58-64006a7986d3");
        // Port 50100 = 0xC3B4 → 0000C3B4-FACB-11E6-…
        var g2 = Bromure.SandboxEngine.Hcs.Native.HvSocketApi.ServiceIdFromPort(50100);
        g2.ToString("D").Should().StartWith("0000c3b4-facb-11e6-");
    }
}
