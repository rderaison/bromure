using System.Formats.Tar;

namespace Bromure.SandboxEngine.Image;

/// <summary>
/// Bundles the per-session <c>/home/ubuntu</c> overlay as a USTAR archive
/// suitable for dropping on the metadata ISO and extracting in the guest.
///
/// <para>Why tar and not virtiofs/sshfs/individual files: virtiofs is
/// closed on Windows host (see <c>SHARING_INVESTIGATION.md</c>); sshfs
/// for the home dir adds round-trip latency to every shell command;
/// individual files on the ISO would require either Joliet/Rock Ridge
/// directory support (extending the pure-C# ISO writer) or a flat
/// naming hack. A tar archive is one file on the ISO, preserves
/// directory structure / mode bits, and is in Ubuntu's base install.</para>
///
/// <para>Architecturally this is the Windows-host equivalent of macOS's
/// <c>VZVirtioFileSystemDeviceConfiguration(tag: "bromure-home")</c>: the
/// host materialises every profile-derived dotfile, ships it to the
/// guest, the guest applies it on boot. Read-only from the guest's
/// perspective — runtime mutations land on the qcow2 overlay and are
/// destroyed at session end.</para>
/// </summary>
public static class SessionHomeArchive
{
    /// <summary>
    /// Build a USTAR archive containing <paramref name="files"/> under
    /// the relative paths their dictionary keys spell. Keys are
    /// <c>/</c>-separated (e.g., <c>.config/kitty/kitty.conf</c>);
    /// intermediate directory entries are emitted automatically. The
    /// guest extracts with <c>--no-same-owner</c> so all files inherit
    /// ubuntu:ubuntu from the extraction <c>chown</c>.
    /// </summary>
    public static byte[] Build(IReadOnlyDictionary<string, byte[]> files)
    {
        if (files.Count == 0) return Array.Empty<byte>();

        using var ms = new MemoryStream();
        using (var writer = new TarWriter(ms, TarEntryFormat.Ustar, leaveOpen: true))
        {
            var emittedDirs = new HashSet<string>(StringComparer.Ordinal);
            foreach (var (relPath, bytes) in files.OrderBy(kv => kv.Key, StringComparer.Ordinal))
            {
                var normalised = relPath.Replace('\\', '/').TrimStart('/');
                if (normalised.Length == 0) continue;

                EmitParentDirectories(writer, emittedDirs, normalised);

                var entry = new UstarTarEntry(TarEntryType.RegularFile, normalised)
                {
                    Mode = UnixFileMode.UserRead | UnixFileMode.UserWrite
                         | UnixFileMode.GroupRead | UnixFileMode.OtherRead,
                    DataStream = new MemoryStream(bytes, writable: false),
                };
                writer.WriteEntry(entry);
            }
        }
        return ms.ToArray();
    }

    private static void EmitParentDirectories(
        TarWriter writer,
        HashSet<string> emittedDirs,
        string filePath)
    {
        var parts = filePath.Split('/');
        if (parts.Length <= 1) return;

        var prefix = string.Empty;
        for (var i = 0; i < parts.Length - 1; i++)
        {
            prefix = prefix.Length == 0 ? parts[i] : prefix + "/" + parts[i];
            if (!emittedDirs.Add(prefix)) continue;
            // Trailing slash signals "directory" to USTAR readers, but
            // TarEntryType.Directory is the canonical signal.
            var dir = new UstarTarEntry(TarEntryType.Directory, prefix + "/")
            {
                Mode = UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute
                     | UnixFileMode.GroupRead | UnixFileMode.GroupExecute
                     | UnixFileMode.OtherRead | UnixFileMode.OtherExecute,
            };
            writer.WriteEntry(dir);
        }
    }
}
