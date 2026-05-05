namespace Bromure.SandboxEngine.Qemu;

/// <summary>
/// Configuration for one QEMU+WHPX guest, mirroring what
/// <c>UbuntuSandboxVM.swift</c> hands to <c>VZVirtualMachineConfiguration</c>.
/// Translation happens in <see cref="QemuCommandBuilder"/>.
/// </summary>
public sealed record QemuConfig
{
    /// Absolute path to the bundled <c>qemu-system-x86_64.exe</c>.
    public required string QemuExecutable { get; init; }

    /// Absolute path to <c>OVMF_CODE.fd</c> (read-only firmware).
    /// Null/empty = boot SeaBIOS instead of UEFI (legacy mode).
    public string? OvmfCode { get; init; }

    /// Absolute path to a per-session <c>OVMF_VARS.fd</c> (writable NVRAM).
    /// Required when <see cref="OvmfCode"/> is set.
    public string? OvmfVars { get; init; }

    /// Absolute path to the per-session qcow2 disk (CoW overlay over base).
    /// Optional in spike mode — caller may boot off <see cref="BootIsoPath"/> instead.
    public string? DiskPath { get; init; }

    /// QEMU disk format (<c>qcow2</c>, <c>raw</c>, etc). Defaults to qcow2
    /// for the session/CoW path; the Alpine bake uses <c>raw</c> for the
    /// target disk so the resulting bytes are an actual partitioned
    /// disk image instead of a qcow2 wrapper.
    public string DiskFormat { get; init; } = "qcow2";

    /// Optional bootable ISO (Alpine virt, Ubuntu live, etc.) for the
    /// Phase-0 spike where we don't yet have a per-profile qcow2 base.
    public string? BootIsoPath { get; init; }

    /// Optional cloud-init seed ISO. Skipped on warm restores.
    public string? CloudInitSeedIso { get; init; }

    /// <summary>
    /// Direct kernel boot. When set, QEMU loads
    /// <see cref="DirectKernelPath"/> + <see cref="DirectInitrdPath"/>
    /// instead of going through GRUB. Used by the Alpine-netboot bake
    /// path. Pairs with <see cref="DirectKernelCmdline"/>.
    /// </summary>
    public string? DirectKernelPath { get; init; }
    public string? DirectInitrdPath { get; init; }
    public string? DirectKernelCmdline { get; init; }

    /// <summary>
    /// Additional read-only IDE CD-ROM ISO. Currently only used by the
    /// bake to deliver setup.sh into the Alpine installer (since the
    /// winget QEMU build has fsdev disabled, we can't share via 9p).
    /// Mounted as <c>/dev/sr1</c> when <see cref="CloudInitSeedIso"/>
    /// is also present, <c>/dev/sr0</c> otherwise.
    /// </summary>
    public string? AuxIsoPath { get; init; }

    /// vCPU count and MiB of RAM. Defaults match the macOS profile.
    public int VCpus { get; init; } = 4;
    public int MemoryMib { get; init; } = 8192;

    /// vsock guest-CID (must be unique per running VM on the host).
    public uint GuestCid { get; init; } = 3;

    /// Attach the vhost-vsock-pci device. The QEMU+MSYS2 build that
    /// ships in winget does NOT include vsock — only KVM/Linux QEMU does.
    /// Set to false on Windows hosts and tunnel bridges over TCP-on-NAT
    /// instead (per WIN32_AC_PLAN §7 risk 1's B-plan).
    public bool EnableVsock { get; init; } = false;

    /// Network mode. NAT = QEMU's user-mode SLIRP; Bridged = TAP via tap-windows6.
    public NetworkMode Network { get; init; } = NetworkMode.UserNat;

    /// When <see cref="Network"/> is <see cref="NetworkMode.Bridged"/>,
    /// the tap-windows6 adapter name (e.g. "BromureTAP").
    public string? TapAdapterName { get; init; }

    /// Stable MAC address for repeatable lease semantics.
    public string MacAddress { get; init; } = "52:54:00:12:34:56";

    /// 9p file shares. Tag is the mount-tag the guest uses
    /// (<c>mount -t 9p -o trans=virtio bromure-home /mnt/...</c>).
    public IReadOnlyList<NinePShare> Shares { get; init; } = Array.Empty<NinePShare>();

    /// Display: software virtio-gpu for AC; virgl for the future Browser port.
    public DisplayMode Display { get; init; } = DisplayMode.VirtioGpuSoftware;

    /// "qmp:tcp:" + a localhost port, or "qmp:pipe:" + a pipe name. The
    /// supervisor opens a control socket here and listens for events.
    public required string QmpEndpoint { get; init; }

    /// <summary>
    /// Optional TCP endpoint (<c>host:port</c>) for the guest's first
    /// serial port. When set, QEMU listens on this socket and the
    /// guest's serial console writes flow back to the host. Used as a
    /// debug aid before <c>fb-agent</c> is wired — the user sees boot
    /// output, login prompt, dmesg, etc. without a graphical display.
    /// </summary>
    /// <remarks>
    /// Alpine virt's default kernel cmdline includes
    /// <c>console=ttyS0,115200n8</c>, so this works out of the box.
    /// Custom Ubuntu builds will need the same in their cloud-init.
    /// </remarks>
    public string? SerialEndpoint { get; init; }

    /// Maps to <c>-device vhost-vsock-pci,guest-cid=N</c>. The host endpoint
    /// is exposed as a Windows named pipe by <see cref="VsockBridge"/>.
    public string VsockHostPipe { get; init; } = @"\\.\pipe\bromure-ac-vsock";

    /// Optional logging redirect for QEMU's stderr (default: capture).
    public string? StderrLogFile { get; init; }
}

public enum NetworkMode { UserNat, Bridged }

public enum DisplayMode
{
    /// Software-rendered virtio-gpu paired with `-display none`. The
    /// host's fb-agent is expected to capture the framebuffer over
    /// vsock and paint into the WPF SwapChainPanel. This is the
    /// production path; right now fb-agent is a wire-protocol skeleton
    /// only, so don't pick this until that's wired.
    VirtioGpuSoftware,
    /// virtio-gpu with virgl GL passthrough — defer until Browser.
    VirtioGpuGl,
    /// QEMU pops its own SDL window with the framebuffer. The B-plan
    /// the macOS plan called out for "while fb-agent isn't real".
    /// User sees a real boot the same way the spike does.
    LocalSdl,
    /// QEMU pops its own GTK window. Like LocalSdl but with native
    /// chrome — also useful for local interactive boots.
    LocalGtk,
    /// No display at all (headless tests + spike).
    None,
}

/// <summary>
/// Host directory exposed into the guest via virtio-9p.
/// </summary>
public sealed record NinePShare(
    string MountTag,
    string HostPath,
    bool ReadOnly = false,
    string SecurityModel = "mapped-xattr");
