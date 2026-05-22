// macos-source: Sources/SandboxEngine/EphemeralDisk.swift @ fe7e7d3a3e21
using System.Runtime.InteropServices;
using Bromure.SandboxEngine.Hcs.Native;

namespace Bromure.SandboxEngine.Hcs;

/// <summary>
/// Per-session VHDX <i>differencing disk</i> rooted at our sealed
/// <c>bromure-base.vhdx</c>. Created with
/// <see cref="VirtDiskApi.CreateVirtualDisk"/> + a parent path; the
/// resulting child file holds only the writes the session does.
///
/// <para><b>This is the actual macOS-APFS-CoW analogue.</b>
/// <see cref="EphemeralDisk"/>.swift uses <c>clonefile(2)</c> to
/// produce a file that points at the parent's blocks until written.
/// VHDX differencing disks are the same idea expressed via the
/// VHDX storage stack: O(metadata) creation, COW on first write,
/// throwaway when the session ends.</para>
///
/// <para><b>Lifecycle.</b> Caller chooses a destination path
/// (e.g. <c>%LOCALAPPDATA%\Bromure\AC\sessions\&lt;id&gt;\disk.vhdx</c>),
/// constructs <see cref="VhdxDisk"/>, calls
/// <see cref="CreateChildAsync"/>. The file appears on disk with size
/// ~5 MB (just headers). Disposal deletes the file.</para>
/// </summary>
public sealed class VhdxDisk : IAsyncDisposable
{
    public string Path { get; }
    public string ParentPath { get; }
    private bool _disposed;

    public VhdxDisk(string path, string parentPath)
    {
        if (string.IsNullOrWhiteSpace(path))
            throw new ArgumentException("path required", nameof(path));
        if (string.IsNullOrWhiteSpace(parentPath))
            throw new ArgumentException("parentPath required", nameof(parentPath));
        Path = path;
        ParentPath = parentPath;
    }

    /// <summary>
    /// Create the child VHDX. Idempotent: if the file already exists
    /// we leave it alone — a previous session's leftover with our
    /// chosen path is still a valid clone of the same parent, but
    /// the caller is responsible for deciding whether to reuse or
    /// delete-then-recreate.
    ///
    /// <para>When <paramref name="allowStaleParentWipe"/> is true and
    /// the parent VHDX is newer than the child, the existing child is
    /// deleted before being recreated — used by the engine after a
    /// "Reset and launch" confirmation in the image-version alert.
    /// When false (default) the existing child is reused as-is even
    /// if its parent has rotated; the caller is responsible for
    /// surfacing the staleness via the image-version dialog.</para>
    /// </summary>
    public Task CreateChildAsync(CancellationToken ct = default, bool allowStaleParentWipe = false)
        => Task.Run(() => CreateChildSync(allowStaleParentWipe), ct);

    private void CreateChildSync(bool allowStaleParentWipe = false)
    {
        ThrowIfDisposed();
        if (!File.Exists(ParentPath))
            throw new FileNotFoundException("parent VHDX missing", ParentPath);
        if (File.Exists(Path))
        {
            // A child VHDX is bound to its parent via the parent's
            // UniqueId, captured at create-time. After a rebake the
            // parent gets a new UniqueId and an existing child fails
            // to open (HCS rejects "parent locator mismatch"). Detect
            // via mtime: if the parent is newer than the child, the
            // child is stale — but only wipe when the caller has
            // explicitly opted in. Default behaviour leaves the child
            // in place so the higher-level "Reset and launch / Launch
            // as-is" choice in SessionsViewModel can drive it.
            var parentTime = File.GetLastWriteTimeUtc(ParentPath);
            var childTime  = File.GetLastWriteTimeUtc(Path);
            if (parentTime > childTime && allowStaleParentWipe)
            {
                try { File.Delete(Path); }
                catch (IOException) { /* fall through; CreateVirtualDisk will surface a clearer error */ }
            }
            else
            {
                return;
            }
        }

        var dir = System.IO.Path.GetDirectoryName(Path)!;
        Directory.CreateDirectory(dir);

        var storageType = new VirtDiskApi.VIRTUAL_STORAGE_TYPE
        {
            DeviceId = VirtDiskApi.VIRTUAL_STORAGE_TYPE_DEVICE_VHDX,
            VendorId = VirtDiskApi.VIRTUAL_STORAGE_TYPE_VENDOR_MICROSOFT,
        };

        // Marshal the parent path through unmanaged memory because the
        // V2 parameters struct holds a raw LPCWSTR pointer (not an
        // attribute-marshalled string). Free in finally.
        IntPtr parentPathPtr = Marshal.StringToCoTaskMemUni(ParentPath);
        try
        {
            var parameters = new VirtDiskApi.CREATE_VIRTUAL_DISK_PARAMETERS_V2
            {
                Version = VirtDiskApi.CREATE_VIRTUAL_DISK_VERSION.VERSION_2,
                UniqueId = Guid.NewGuid(),
                MaximumSize = 0,  // 0 => inherit from parent — exactly what we want
                BlockSizeInBytes = 0,
                SectorSizeInBytes = 0,
                PhysicalSectorSizeInBytes = 0,
                ParentPath = parentPathPtr,
                SourcePath = IntPtr.Zero,
                OpenFlags = (uint)VirtDiskApi.OPEN_VIRTUAL_DISK_FLAG.NONE,
                ParentVirtualStorageType = storageType,
                SourceVirtualStorageType = default,
                ResiliencyGuid = Guid.Empty,
            };

            int hr = VirtDiskApi.CreateVirtualDisk(
                ref storageType,
                Path,
                VirtDiskApi.VIRTUAL_DISK_ACCESS_NONE,
                IntPtr.Zero,
                VirtDiskApi.CREATE_VIRTUAL_DISK_FLAG.NONE,
                providerSpecificFlags: 0,
                ref parameters,
                IntPtr.Zero,
                out IntPtr handle);

            if (hr != VirtDiskApi.ERROR_SUCCESS)
            {
                throw new HcsException(
                    $"CreateVirtualDisk(child of {ParentPath} → {Path})",
                    hr,
                    null);
            }
            // Close the handle — the VHDX is durable on disk; the
            // file is what we keep. The HCS VM opens its own handle
            // when it attaches the disk.
            VirtDiskApi.CloseHandle(handle);
        }
        finally
        {
            Marshal.FreeCoTaskMem(parentPathPtr);
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_disposed) return;
        _disposed = true;
        // Intentionally DO NOT delete the child VHDX on dispose. The
        // per-profile disk persists across sessions (this is the
        // AC product's "your installed tools / shell history survive
        // a session restart" promise); only the bake invalidates it
        // via the parent-mtime check in CreateChildSync.
        await Task.CompletedTask;
    }

    private void ThrowIfDisposed()
    {
        if (_disposed) throw new ObjectDisposedException(nameof(VhdxDisk));
    }
}
