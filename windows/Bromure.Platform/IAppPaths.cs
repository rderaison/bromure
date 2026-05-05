namespace Bromure.Platform;

/// <summary>
/// Resolves the per-platform locations the AC host stores its state in.
/// macOS reads `~/Library/Application Support/Bromure/AC/`; Windows
/// reads `%LOCALAPPDATA%\Bromure\AC\`. Bromure.Platform owns the seam
/// so SandboxEngine and the MITM stack don't have to know.
/// </summary>
public interface IAppPaths
{
    /// Per-user application data root (writable, roaming OK).
    string AppDataRoot { get; }

    /// Per-machine, all-users data (DPAPI-LocalMachine wrapped blobs land here).
    string MachineDataRoot { get; }

    /// Per-user profile directory, one JSON per profile.
    string ProfilesDirectory { get; }

    /// Trace SQLite + screen recordings + outbox staging.
    string TracesDirectory { get; }

    /// Cached Ubuntu base images (qcow2 + signatures).
    string ImagesDirectory { get; }

    /// Per-session ephemeral disks (qcow2 overlays). Wiped on shutdown.
    string SessionsDirectory { get; }

    /// Bundled QEMU + OVMF firmware (read-only, under install dir).
    string ResourcesDirectory { get; }

    /// Returns the path, ensuring its parent directory exists.
    string EnsureDirectory(string path);
}
