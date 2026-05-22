using System.Runtime.InteropServices;

namespace Bromure.SandboxEngine.Hcs.Native;

/// <summary>
/// P/Invoke wrapper for <c>virtdisk.dll</c>'s <c>CreateVirtualDisk</c>
/// + <c>OpenVirtualDisk</c> + <c>AttachVirtualDisk</c> family. Used to
/// produce per-session VHDX <i>differencing disks</i> rooted at our
/// sealed <c>bromure-base.vhdx</c>.
///
/// <para><b>Why differencing disks?</b> They are the Hyper-V analogue
/// of macOS APFS clonefile(2): creating a child VHDX that points at a
/// parent costs O(metadata) — a few megabytes of new headers, no
/// payload copy. Per-session writes go to the child; the parent stays
/// pristine and is shared read-only by every running session. When the
/// session ends we delete the child file. This is the actual macOS
/// CoW shape that WSL <c>--import</c> couldn't reproduce.</para>
///
/// <para><b>Surface kept narrow.</b> We only wrap CreateVirtualDisk
/// (with PARENT_PATH set to make it a child) and the two helpers needed
/// to grant the VM access. Microsoft documents the full API at
/// <see href="https://learn.microsoft.com/en-us/windows/win32/api/virtdisk/"/>.
/// </para>
/// </summary>
internal static class VirtDiskApi
{
    public const int ERROR_SUCCESS = 0;

    [StructLayout(LayoutKind.Sequential)]
    public struct VIRTUAL_STORAGE_TYPE
    {
        public uint DeviceId;
        public Guid VendorId;
    }

    public const uint VIRTUAL_STORAGE_TYPE_DEVICE_VHDX = 3;
    public static readonly Guid VIRTUAL_STORAGE_TYPE_VENDOR_MICROSOFT =
        new("EC984AEC-A0F9-47E9-901F-71415A66345B");

    [Flags]
    public enum CREATE_VIRTUAL_DISK_FLAG : uint
    {
        NONE = 0,
        FULL_PHYSICAL_ALLOCATION = 1,
        PREVENT_WRITES_TO_SOURCE_DISK = 2,
        DO_NOT_COPY_METADATA_FROM_PARENT = 4,
        CREATE_BACKING_STORAGE = 8,
        USE_CHANGE_TRACKING_SOURCE_LIMIT = 16,
        PRESERVE_PARENT_CHANGE_TRACKING_STATE = 32,
        VHD_SET_USE_ORIGINAL_BACKING_STORAGE = 64,
        SPARSE_FILE = 128,
        PMEM_COMPATIBLE = 256,
        SUPPORT_COMPRESSED_VOLUMES = 512,
    }

    [Flags]
    public enum OPEN_VIRTUAL_DISK_FLAG : uint
    {
        NONE = 0,
        NO_PARENTS = 1,
        BLANK_FILE = 2,
        BOOT_DRIVE = 4,
        CACHED_IO = 8,
        CUSTOM_DIFF_CHAIN = 16,
        PARENT_CACHED_IO = 32,
        VHDSET_FILE_ONLY = 64,
        IGNORE_RELATIVE_PARENT_LOCATOR = 128,
        NO_WRITE_HARDENING = 256,
    }

    public enum CREATE_VIRTUAL_DISK_VERSION : uint
    {
        UNSPECIFIED = 0,
        VERSION_1 = 1,
        VERSION_2 = 2,
        VERSION_3 = 3,
    }

    public enum OPEN_VIRTUAL_DISK_VERSION : uint
    {
        UNSPECIFIED = 0,
        VERSION_1 = 1,
        VERSION_2 = 2,
        VERSION_3 = 3,
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREATE_VIRTUAL_DISK_PARAMETERS_V2
    {
        public CREATE_VIRTUAL_DISK_VERSION Version;  // discriminant
        public Guid UniqueId;
        public ulong MaximumSize;
        public uint BlockSizeInBytes;
        public uint SectorSizeInBytes;
        public uint PhysicalSectorSizeInBytes;
        public IntPtr ParentPath;             // LPCWSTR
        public IntPtr SourcePath;             // LPCWSTR
        public uint OpenFlags;                 // OPEN_VIRTUAL_DISK_FLAG
        public VIRTUAL_STORAGE_TYPE ParentVirtualStorageType;
        public VIRTUAL_STORAGE_TYPE SourceVirtualStorageType;
        public Guid ResiliencyGuid;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct OPEN_VIRTUAL_DISK_PARAMETERS_V2
    {
        public OPEN_VIRTUAL_DISK_VERSION Version;
        [MarshalAs(UnmanagedType.U1)] public bool GetInfoOnly;
        [MarshalAs(UnmanagedType.U1)] public bool ReadOnly;
        public Guid ResiliencyGuid;
    }

    [DllImport("virtdisk.dll", CharSet = CharSet.Unicode, ExactSpelling = true,
        PreserveSig = true)]
    public static extern int CreateVirtualDisk(
        ref VIRTUAL_STORAGE_TYPE virtualStorageType,
        [MarshalAs(UnmanagedType.LPWStr)] string path,
        uint virtualDiskAccessMask,
        IntPtr securityDescriptor,
        CREATE_VIRTUAL_DISK_FLAG flags,
        uint providerSpecificFlags,
        ref CREATE_VIRTUAL_DISK_PARAMETERS_V2 parameters,
        IntPtr overlapped,
        out IntPtr handle);

    [DllImport("virtdisk.dll", CharSet = CharSet.Unicode, ExactSpelling = true,
        PreserveSig = true)]
    public static extern int OpenVirtualDisk(
        ref VIRTUAL_STORAGE_TYPE virtualStorageType,
        [MarshalAs(UnmanagedType.LPWStr)] string path,
        uint virtualDiskAccessMask,
        OPEN_VIRTUAL_DISK_FLAG flags,
        ref OPEN_VIRTUAL_DISK_PARAMETERS_V2 parameters,
        out IntPtr handle);

    [DllImport("kernel32.dll", SetLastError = true, ExactSpelling = true)]
    public static extern bool CloseHandle(IntPtr handle);

    /// <summary>VIRTUAL_DISK_ACCESS_NONE — sufficient for child-creation
    /// since we only read the parent path metadata; the kernel grants
    /// the rest of the access mask implicitly when CreateVirtualDisk
    /// builds the child.</summary>
    public const uint VIRTUAL_DISK_ACCESS_NONE = 0;
}
