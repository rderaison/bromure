using System.Diagnostics;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Bromure.AC.Core.Outbox;

/// <summary>
/// Watches a session's outbox directory for guest-pushed events and
/// dispatches them on the host. Direct port of macOS's outbox loop
/// in <c>SessionDisk.swift</c> / <c>BromureAC.swift</c>.
///
/// <para>Currently handles:</para>
/// <list type="bullet">
///   <item><c>url-*.txt</c> — guest's <c>bromure-open &lt;url&gt;</c>
///   wrote a URL. Opens it in the host's default browser via
///   <c>Process.Start(UseShellExecute = true)</c> and deletes the
///   file.</item>
/// </list>
///
/// <para>Lifetime: started by <c>SessionViewModel.StartAsync</c>
/// after <c>HcsSession</c> populates <c>OutboxDirectory</c>;
/// disposed on session shutdown.</para>
/// </summary>
public sealed class SessionOutboxWatcher : IDisposable
{
    private readonly string _outboxDir;
    private readonly ILogger _log;
    private FileSystemWatcher? _fsw;

    /// <summary>Hook for tests so we don't shell out to a real
    /// browser. Defaults to <c>Process.Start(UseShellExecute=true)</c>
    /// in production.</summary>
    public Action<string> UrlOpener { get; set; } = DefaultUrlOpener;

    public SessionOutboxWatcher(string outboxDir, ILogger? log = null)
    {
        _outboxDir = outboxDir;
        _log = log ?? NullLogger.Instance;
    }

    public void Start()
    {
        if (_fsw is not null) return;
        Directory.CreateDirectory(_outboxDir);

        // Drain any URLs the guest wrote before the watcher came up
        // (boot races: setup.sh's bromure-open could fire during the
        // guest's startup phase). Drain BEFORE we start watching to
        // avoid double-dispatch.
        foreach (var existing in Directory.EnumerateFiles(_outboxDir, "url-*.txt"))
        {
            HandleUrlFile(existing);
        }

        _fsw = new FileSystemWatcher(_outboxDir)
        {
            Filter = "url-*.txt",
            NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size,
        };
        _fsw.Created += (_, e) => HandleUrlFile(e.FullPath);
        _fsw.Changed += (_, e) => HandleUrlFile(e.FullPath);
        _fsw.EnableRaisingEvents = true;
        _log.LogInformation("outbox watcher up at {Path}", _outboxDir);
    }

    /// <summary>Read URL file, dispatch, delete. Idempotent against
    /// FileSystemWatcher's double-fire pattern (Created + Changed)
    /// because the delete makes a second handler see "no such file".
    /// Test-visible internal so tests can drive the dispatch path
    /// without standing up a real watcher.</summary>
    public void HandleUrlFile(string path)
    {
        string url;
        try
        {
            url = File.ReadAllText(path).Trim();
        }
        catch (IOException) { return; }
        catch (UnauthorizedAccessException) { return; }

        try { File.Delete(path); } catch (IOException) { /* best-effort */ }

        if (string.IsNullOrWhiteSpace(url)) return;
        if (!LooksLikeSafeUrl(url))
        {
            _log.LogWarning("outbox: refusing to open suspect URL {Url}", Preview(url));
            return;
        }
        try { UrlOpener(url); }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "outbox: opening URL failed");
        }
    }

    /// <summary>
    /// Refuse to shell out anything that doesn't look like a normal
    /// browseable URL. Belt-and-suspenders since the URL comes from
    /// inside the VM (potentially malicious) and the host runs
    /// Process.Start with UseShellExecute = the same engine that
    /// resolves <c>file:</c> and arbitrary protocol handlers.
    /// </summary>
    public static bool LooksLikeSafeUrl(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var u)) return false;
        return u.Scheme is "http" or "https";
    }

    private static string Preview(string url)
        => url.Length <= 80 ? url : url[..80] + "…";

    private static void DefaultUrlOpener(string url)
    {
        Process.Start(new ProcessStartInfo
        {
            FileName = url,
            UseShellExecute = true,
        });
    }

    public void Dispose()
    {
        if (_fsw is not null)
        {
            _fsw.EnableRaisingEvents = false;
            _fsw.Dispose();
            _fsw = null;
        }
    }
}
