using System.IO.Pipes;
using System.Security.Principal;

namespace Bromure.Platform;

/// <summary>
/// Per-user single-instance enforcement. Audit 08 §1.2 flagged this
/// as HIGH because two Bromure.AC.exe processes racing the same
/// profile's <c>disk.vhdx</c> clone path can corrupt the VHDX (HCS
/// doesn't lock the parent during diff-disk creation, and the
/// automation port collision is silently swallowed by ShellViewModel).
///
/// <para>Pattern: acquire a per-user named <see cref="Mutex"/>; if
/// already held, dial a named pipe to ask the existing instance to
/// activate its window and exit. The mutex is scoped to the current
/// Windows user (NOT machine-wide) so the same physical machine can
/// host multiple bromure installs across different Windows accounts —
/// the disk paths are user-scoped under
/// <c>%LOCALAPPDATA%\Bromure</c>.</para>
/// </summary>
public sealed class SingleInstanceGuard : IDisposable
{
    private readonly Mutex _mutex;
    private readonly bool _owned;
    private readonly CancellationTokenSource _serverCts = new();
    private Task? _serverTask;

    private SingleInstanceGuard(Mutex mutex, bool owned)
    {
        _mutex = mutex;
        _owned = owned;
    }

    /// <summary>True if THIS process is the first instance. Caller
    /// should bring up the UI; otherwise <see cref="SignalExisting"/>
    /// should be invoked and the process should exit.</summary>
    public bool IsFirstInstance => _owned;

    /// <summary>Build the per-user mutex / pipe name. Includes the
    /// current user's SID so two different Windows users on the same
    /// box don't block each other. Falls back to username if WindowsIdentity
    /// can't materialize (very rare — sandboxed environments).</summary>
    public static string ChannelName()
    {
        string suffix;
        try
        {
            suffix = WindowsIdentity.GetCurrent().User?.Value ?? Environment.UserName;
        }
        catch
        {
            suffix = Environment.UserName;
        }
        // Replace pipe-illegal chars defensively (SIDs contain '-'
        // which is fine, but be defensive about future cases).
        suffix = suffix.Replace('\\', '_');
        return $"Bromure.AC-Singleton-{suffix}";
    }

    public static SingleInstanceGuard Acquire()
    {
        var name = ChannelName();
        // Local\ scope (the default with no prefix): per-Session, which
        // for an interactive logon == per-user. We want per-user, so
        // this is correct. Global\ would be wrong (one bromure across
        // ALL users on the box).
        var mutex = new Mutex(initiallyOwned: false, name: name, out _);
        bool owned;
        try
        {
            owned = mutex.WaitOne(TimeSpan.Zero, exitContext: false);
        }
        catch (AbandonedMutexException)
        {
            // Previous instance crashed without releasing — we still
            // get ownership. Safe to proceed.
            owned = true;
        }
        return new SingleInstanceGuard(mutex, owned);
    }

    /// <summary>Dial the existing instance's named pipe to ask it to
    /// pop its window. Returns false if the dial fails (existing
    /// instance is stuck) so the caller can decide between exiting
    /// quietly and surfacing an error.</summary>
    public static bool SignalExisting(TimeSpan timeout)
    {
        try
        {
            using var client = new NamedPipeClientStream(
                ".", ChannelName(), PipeDirection.Out, PipeOptions.None);
            client.Connect((int)timeout.TotalMilliseconds);
            client.WriteByte(0x01);
            client.Flush();
            return true;
        }
        catch
        {
            return false;
        }
    }

    /// <summary>Start the activation-pipe server. Calls
    /// <paramref name="onActivate"/> on a thread-pool thread when a
    /// later <c>Bromure.AC.exe</c> launches and signals us. The
    /// callback is responsible for marshalling to the UI thread.</summary>
    public void StartActivationServer(Action onActivate)
    {
        if (!_owned) return;
        _serverTask = Task.Run(() => ServerLoopAsync(onActivate, _serverCts.Token));
    }

    private async Task ServerLoopAsync(Action onActivate, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            NamedPipeServerStream? server = null;
            try
            {
                server = new NamedPipeServerStream(
                    ChannelName(),
                    PipeDirection.In,
                    maxNumberOfServerInstances: 1,
                    PipeTransmissionMode.Byte,
                    PipeOptions.Asynchronous);
                await server.WaitForConnectionAsync(ct).ConfigureAwait(false);
                // We don't actually care what's on the wire — any
                // connection means "another launch was attempted,
                // please activate the existing window".
                _ = server.ReadByte();
                try { onActivate(); } catch { /* swallow — UI errors shouldn't kill the loop */ }
            }
            catch (OperationCanceledException) { return; }
            catch { /* pipe was reset, fall through and re-open */ }
            finally
            {
                try { server?.Dispose(); } catch { }
            }
        }
    }

    public void Dispose()
    {
        try { _serverCts.Cancel(); } catch { }
        try { _serverTask?.Wait(TimeSpan.FromSeconds(1)); } catch { }
        if (_owned)
        {
            try { _mutex.ReleaseMutex(); } catch { }
        }
        try { _mutex.Dispose(); } catch { }
        _serverCts.Dispose();
    }
}
