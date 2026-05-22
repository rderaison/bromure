// macos-source: Sources/SandboxEngine/VMConfig.swift @ fe7e7d3a3e21
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Bromure.SandboxEngine.Hcs.Native;

/// <summary>
/// JSON DTOs for the v2 HCS schema we hand to
/// <c>HcsCreateComputeSystem</c>. These mirror the shape used by
/// hcsshim's <c>internal/hcs/schema2</c> Go types and the official
/// MS docs at
/// <see href="https://learn.microsoft.com/en-us/virtualization/api/hcs/schemareference"/>.
///
/// <para>We only model the fields we actually set. The schema has
/// hundreds of optional fields for SR-IOV, DDA, snapshotting,
/// container-mode plumbing — none of which apply to the
/// "boot a Linux rootfs in a utility VM" path Bromure uses. Keep this
/// file scoped to what we touch; bloat is the failure mode.</para>
///
/// <para>Serialiser config: <see cref="JsonOptions"/> uses
/// PascalCase property naming (HCS schema convention),
/// <see cref="JsonIgnoreCondition.WhenWritingNull"/> so null/empty
/// optional fields don't pollute the JSON, and pretty-print disabled
/// (HCS doesn't care; we save bytes over the LPWSTR boundary).</para>
/// </summary>
internal static class HcsSchema
{
    public static readonly JsonSerializerOptions JsonOptions = new()
    {
        // WhenWritingDefault skips false/0 alongside nulls. hcsshim's Go
        // schema relies on `omitempty` for the same reason: HCS rejects
        // documents with extraneous false-valued booleans on the
        // utility-VM path with HCS_E_INVALID_JSON.
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingDefault,
        WriteIndented = false,
        PropertyNamingPolicy = null,  // PascalCase — HCS schema convention
    };

    /// <summary>The top-level "ComputeSystem" document.</summary>
    public sealed class ComputeSystem
    {
        public string? Owner { get; set; }
        public SchemaVersion? SchemaVersion { get; set; }
        public string? HostingSystemId { get; set; }
        public Container? Container { get; set; }
        public VirtualMachine? VirtualMachine { get; set; }
        public bool ShouldTerminateOnLastHandleClosed { get; set; }
    }

    public sealed class SchemaVersion
    {
        public uint Major { get; set; }
        public uint Minor { get; set; }
    }

    /// <summary>VM-level configuration: chipset, devices, memory, processors.
    /// Only the fields we set are modelled; anything else (GuestState,
    /// snapshotting, registry overrides) is intentionally absent so the
    /// emitted JSON stays minimal — empty/null objects can themselves
    /// trip HCS_E_INVALID_JSON if vmcompute rejects unknown defaults.</summary>
    public sealed class VirtualMachine
    {
        public Chipset? Chipset { get; set; }
        public ComputeTopology? ComputeTopology { get; set; }
        public Devices? Devices { get; set; }
        public bool StopOnReset { get; set; }
        /// <summary>When set, vmcompute restores the VM's CPU+RAM+device
        /// state from <see cref="RestoreState.SavedStateFilePath"/>
        /// after create. The caller follows the create with
        /// <c>HcsResumeComputeSystem</c> instead of
        /// <c>HcsStartComputeSystem</c>. Pairs with a save state file
        /// previously written by <c>HcsSaveComputeSystem</c>.</summary>
        public RestoreState? RestoreState { get; set; }
    }

    /// <summary>Saved-state pointer used on resume. The compute system
    /// is created with this set; calling Resume after create brings the
    /// VM up at the exact CPU/memory state captured by an earlier
    /// <c>HcsSaveComputeSystem</c>. Same primitive WSL2 hibernate uses.</summary>
    public sealed class RestoreState
    {
        public string? SavedStateFilePath { get; set; }
        /// <summary>When true the saved state is treated as a template
        /// (clones may share its memory pages). False for the
        /// hibernate-resume path we want.</summary>
        public bool TemplateMemory { get; set; }
    }

    /// <summary>Chipset selection: UEFI for VHDX boot, or LinuxKernelDirect
    /// for Microsoft's "boot a kernel + initrd directly" mode (cheaper
    /// boot — no GRUB, no EFI). We use LinuxKernelDirect; same shape as
    /// WSL2's utility VM and what hcsshim's LCOW path uses.</summary>
    public sealed class Chipset
    {
        public Uefi? Uefi { get; set; }
        public LinuxKernelDirect? LinuxKernelDirect { get; set; }
        /// <summary>Default false (omitted with WhenWritingDefault).
        /// hcsshim LCOW doesn't set this — Linux gets UTC from the
        /// host's RTC by default already.</summary>
        public bool UseUtc { get; set; }
    }

    public sealed class Uefi
    {
        public UefiBootEntry? BootThis { get; set; }
        public string? Console { get; set; }
        public string? ApplySecureBootTemplate { get; set; }
        public string? SecureBootTemplateId { get; set; }
    }

    /// <summary>One entry in Hyper-V's UEFI firmware boot order.
    /// For Bromure session VMs we point this at the first SCSI disk
    /// (DiskNumber 0), whose EFI System Partition holds the grub
    /// stage 1 the bake's grub-install put there.</summary>
    public sealed class UefiBootEntry
    {
        /// <summary>"ScsiDrive" for VHDX disks, "VmbFs" for the
        /// Microsoft-built LCOW initrd-via-vmbfs path, "NetworkAdapter"
        /// for PXE. We use ScsiDrive.</summary>
        public string? DeviceType { get; set; }

        /// <summary>0-based disk index when DeviceType is "ScsiDrive".
        /// Omitted when 0 via the global JsonIgnoreCondition.
        /// WhenWritingDefault — hcsshim emits this field as
        /// <c>omitempty</c> and vmcompute interprets absence as
        /// "the first SCSI disk on `primary`," which is what we
        /// want anyway. Emitting an explicit 0 was an earlier
        /// guess that didn't pan out.</summary>
        public int DiskNumber { get; set; }

        /// <summary>Device location for non-disk boot types. Empty for
        /// ScsiDrive. NOTE: schema reference names this
        /// <c>DeviceLocation</c> in 2.5+ docs; older builds accept
        /// <c>DevicePath</c>. We omit it (null) so neither is sent.</summary>
        public string? DeviceLocation { get; set; }

        /// <summary>Extra data passed to the EFI Load Option's
        /// OptionalData field. Empty for normal grub boot.</summary>
        public string? OptionalData { get; set; }

        /// <summary>UEFI boot protocol selector. Empty = default
        /// (firmware-decided).</summary>
        public string? BootProtocol { get; set; }
    }

    public sealed class LinuxKernelDirect
    {
        public string? KernelFilePath { get; set; }
        public string? InitRdPath { get; set; }
        public string? KernelCmdLine { get; set; }
    }

    public sealed class ComputeTopology
    {
        public Memory? Memory { get; set; }
        public Processor? Processor { get; set; }
    }

    public sealed class Memory
    {
        /// <summary>Megabytes of guest memory.</summary>
        public uint SizeInMB { get; set; }
        // Below all default to CLR-zero so JsonIgnoreCondition.
        // WhenWritingDefault omits them when not explicitly set —
        // important because vmcompute rejects some default-valued
        // booleans on VirtualMachine-mode compute systems.
        public bool AllowOvercommit { get; set; }
        public bool EnableHotHint { get; set; }
        public bool EnableColdHint { get; set; }
        public bool EnableEpf { get; set; }
        public bool EnableDeferredCommit { get; set; }
    }

    public sealed class Processor
    {
        public int Count { get; set; }
        public uint Limit { get; set; }
        public uint Weight { get; set; }
        public uint Reservation { get; set; }
        public bool ExposeVirtualizationExtensions { get; set; }
    }

    /// <summary>Per-VM device tree. Bromure uses Plan9 shares for host↔guest
    /// filesystem access (the same primitive WSL uses for \\wsl$\),
    /// HvSocket for the RDP service plumbing, ScsiControllers for VHDX
    /// boot disk + ephemeral overlay, and one VirtualSmb-less / network
    /// configuration appropriate for sandbox use.</summary>
    public sealed class Devices
    {
        public Dictionary<string, Scsi>? Scsi { get; set; }
        public Plan9? Plan9 { get; set; }
        public HvSocket? HvSocket { get; set; }
        public Dictionary<string, NetworkAdapter>? NetworkAdapters { get; set; }
        public Dictionary<string, ComPort>? ComPorts { get; set; }
        public Keyboard? Keyboard { get; set; }
        public Mouse? Mouse { get; set; }
        public VideoMonitor? VideoMonitor { get; set; }
    }

    public sealed class Scsi
    {
        public Dictionary<string, ScsiAttachment>? Attachments { get; set; }
    }

    public sealed class ScsiAttachment
    {
        public string? Type { get; set; }     // "VirtualDisk" — VHDX file
        public string? Path { get; set; }
        public bool ReadOnly { get; set; }
        public string? IgnoreFlushes { get; set; }
        public string? CachingMode { get; set; }
    }

    /// <summary>Plan9 (9P2000.L) device. The HOST process (vmcompute.dll's
    /// Plan9FileServer) serves the share; the GUEST mounts via
    /// <c>mount -t 9p -o trans=hyperv,port=N,access=client …</c>.
    ///
    /// <para>This is the same machinery WSL uses to expose /mnt/c and
    /// \\wsl$\&lt;distro&gt;\. We don't write a 9P server — Microsoft
    /// already has one and exposes it via this device.</para></summary>
    public sealed class Plan9
    {
        public List<Plan9Share>? Shares { get; set; }
    }

    public sealed class Plan9Share
    {
        public string? Name { get; set; }       // logical share name
        public string? AccessName { get; set; } // mount tag inside the guest
        public string? Path { get; set; }       // host directory
        public uint Port { get; set; }          // hvsocket port the guest connects to
        public Plan9Flags Flags { get; set; }
        public bool ReadOnly { get; set; }
        public bool UseShareRootIdentity { get; set; }
        public bool AllowedFiles { get; set; }
    }

    [Flags]
    public enum Plan9Flags
    {
        None = 0,
        ReadOnly = 1,
        LinuxMetadata = 2,
        CaseSensitive = 4,
    }

    /// <summary>HvSocket service GUID + connect/listen rules. Bromure exposes
    /// (a) RDP-over-hvsocket so mstsc.exe can connect to the guest
    /// weston RDP backend, and (b) a control-plane port for the agent
    /// boot signal / health probe.</summary>
    public sealed class HvSocket
    {
        public HvSocketSystemConfig? HvSocketConfig { get; set; }
    }

    public sealed class HvSocketSystemConfig
    {
        /// <summary>SDDL default-bind ACL — controls which guest
        /// processes can bind a listener. Hcsshim's LCOW UVM sets
        /// <c>"D:P(A;;FA;;;WD)"</c> ("Everyone, full access"); without
        /// a non-empty value vmcompute can reject the JSON with
        /// HCS_E_INVALID_DEFINITION_OBJECT. NOT a dictionary — the
        /// earlier schema had this typed wrong.</summary>
        public string? DefaultBindSecurityDescriptor { get; set; }
        /// <summary>SDDL default-connect ACL — same shape and same
        /// default value (Everyone, full access).</summary>
        public string? DefaultConnectSecurityDescriptor { get; set; }
        public Dictionary<string, HvSocketServiceConfig>? ServiceTable { get; set; }
    }

    public sealed class HvSocketServiceConfig
    {
        /// <summary>SDDL bind ACL for this specific port. Empty
        /// (omitted) ⇒ inherit from <c>DefaultBindSecurityDescriptor</c>.
        /// This was modelled as bool in the prior schema — wrong type;
        /// vmcompute serialises it as a string SDDL.</summary>
        public string? BindSecurityDescriptor { get; set; }
        public string? ConnectSecurityDescriptor { get; set; }
        public bool Disabled { get; set; }
        public bool AllowWildcardBinds { get; set; }
    }

    public sealed class NetworkAdapter
    {
        public string? EndpointId { get; set; }
        public string? MacAddress { get; set; }
    }

    public sealed class ComPort
    {
        public string? NamedPipe { get; set; }
        public uint OptimizeForDebugger { get; set; }
    }

    public sealed class Keyboard { }
    public sealed class Mouse { }

    public sealed class VideoMonitor
    {
        public uint HorizontalResolution { get; set; } = 1920;
        public uint VerticalResolution { get; set; } = 1080;
        public ConnectionOptions? ConnectionOptions { get; set; }
    }

    public sealed class ConnectionOptions
    {
        public string? AccessSids { get; set; }
    }

    public sealed class Container
    {
        // Container-mode is unused for Bromure — VMs only.
    }

    /// <summary>Render to the JSON document HCS expects.</summary>
    public static string Serialize(ComputeSystem cs)
    {
        return JsonSerializer.Serialize(cs, JsonOptions);
    }
}
