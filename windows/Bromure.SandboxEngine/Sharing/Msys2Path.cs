namespace Bromure.SandboxEngine.Sharing;

/// <summary>
/// MSYS2's POSIX-style drive convention: <c>C:\foo\bar</c> →
/// <c>/c/foo/bar</c>. MSYS2 binaries (sshd, sftp-server, sshfs's
/// remote endpoint) expect paths in this form when crossing the
/// Windows ↔ POSIX boundary. Used by:
/// <list type="bullet">
///   <item><see cref="FolderShareServer"/> when emitting
///     <c>HostKey</c> / <c>AuthorizedKeysFile</c> / <c>Subsystem</c>
///     paths in the per-session sshd_config.</item>
///   <item><c>ShellViewModel.PrepareSessionSync</c> when building
///     <c>shares.json</c> entries — the guest's <c>sshfs</c> command
///     receives the host path as a remote SFTP path, so it has to
///     match what sftp-server resolves to.</item>
///   <item>The <c>bromure-spike session --share-path</c> smoke test.</item>
/// </list>
/// </summary>
public static class Msys2Path
{
    /// <summary>
    /// Convert a Windows absolute path (e.g. <c>C:\Users\foo</c>) to
    /// MSYS2 form (<c>/c/Users/foo</c>). Returns <paramref name="winPath"/>
    /// unchanged if it doesn't look like a Windows drive path.
    /// </summary>
    public static string From(string winPath)
    {
        if (string.IsNullOrEmpty(winPath)) return winPath;
        if (winPath.Length >= 2 && winPath[1] == ':')
        {
            var drive = char.ToLowerInvariant(winPath[0]);
            return "/" + drive + winPath[2..].Replace('\\', '/');
        }
        return winPath.Replace('\\', '/');
    }
}
