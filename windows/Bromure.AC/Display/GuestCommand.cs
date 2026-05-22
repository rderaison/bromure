using Bromure.SandboxEngine.Hcs;

namespace Bromure.AC.Display;

/// <summary>
/// Host-side helper for sending shell commands into a Bromure
/// session VM. Dials AF_HYPERV port 9226 (the in-guest
/// bromure-cmd-server) and writes a single ASCII line; the guest
/// exec's the line via /bin/sh. Used for the + button (spawn
/// another kitty in the same VM) and tab-raise/close via xdotool.
/// </summary>
public static class GuestCommand
{
    public const uint Port = 9226;

    /// <summary>Send a command and read all stdout/stderr the guest
    /// child emits before exiting. Use for one-shot probes (`ls`,
    /// `cat`, …); don't use for long-running commands.</summary>
    public static async Task<string> RunAndCollectAsync(System.Guid vmRuntimeId,
        string commandLine, System.Threading.CancellationToken ct = default)
    {
        if (vmRuntimeId == System.Guid.Empty) return "";
        if (string.IsNullOrEmpty(commandLine)) return "";
        var line = commandLine.EndsWith('\n') ? commandLine : commandLine + "\n";
        var bytes = System.Text.Encoding.UTF8.GetBytes(line);
        System.Net.Sockets.Socket sock;
        try { sock = await HvSocket.ConnectAsync(vmRuntimeId, Port, ct).ConfigureAwait(false); }
        catch (System.Exception) { return ""; }
        try
        {
            int off = 0;
            while (off < bytes.Length)
            {
                int sent = HvSocket.SendRaw(sock, bytes, off, bytes.Length - off);
                if (sent <= 0) break;
                off += sent;
            }
            try { sock.Shutdown(System.Net.Sockets.SocketShutdown.Send); } catch { }
            var buf = new byte[4096];
            var sb = new System.Text.StringBuilder();
            while (true)
            {
                int n;
                try { n = HvSocket.RecvRaw(sock, buf, 0, buf.Length); }
                catch (System.Net.Sockets.SocketException) { break; }
                if (n <= 0) break;
                sb.Append(System.Text.Encoding.UTF8.GetString(buf, 0, n));
            }
            return sb.ToString();
        }
        finally { try { sock.Dispose(); } catch { } }
    }

    /// <summary>Send <paramref name="commandLine"/> to the VM
    /// identified by <paramref name="vmRuntimeId"/>. Fire-and-forget:
    /// returns when the line is on the wire, doesn't wait for the
    /// guest process to exit (so it's safe to send `kitty &`).</summary>
    public static async Task SendAsync(System.Guid vmRuntimeId, string commandLine,
        System.Threading.CancellationToken ct = default)
    {
        if (vmRuntimeId == System.Guid.Empty) return;
        if (string.IsNullOrEmpty(commandLine)) return;
        var line = commandLine.EndsWith('\n') ? commandLine : commandLine + "\n";
        var bytes = System.Text.Encoding.UTF8.GetBytes(line);

        System.Net.Sockets.Socket sock;
        try
        {
            sock = await HvSocket.ConnectAsync(vmRuntimeId, Port, ct).ConfigureAwait(false);
        }
        catch (System.Net.Sockets.SocketException ex)
        {
            Log($"connect vm={vmRuntimeId:D}: {ex.SocketErrorCode} ({ex.NativeErrorCode}) — {ex.Message}");
            return;
        }
        catch (System.Exception ex) { Log("connect threw: " + ex); return; }

        try
        {
            int off = 0;
            while (off < bytes.Length)
            {
                int sent = HvSocket.SendRaw(sock, bytes, off, bytes.Length - off);
                if (sent <= 0) break;
                off += sent;
            }
            // Half-close so the guest sees EOF on stdin and runs exec.
            try { sock.Shutdown(System.Net.Sockets.SocketShutdown.Send); } catch { }
            Log($"sent to vm={vmRuntimeId:D}: '{commandLine.Trim()}' ({off} bytes)");
        }
        finally { try { sock.Dispose(); } catch { } }
    }

    private static readonly string LogPath = System.IO.Path.Combine(
        System.IO.Path.GetTempPath(), "bromure-cmd.log");

    private static void Log(string msg)
    {
        try { System.IO.File.AppendAllText(LogPath, $"[{System.DateTime.Now:HH:mm:ss.fff}] {msg}\n"); } catch { }
    }
}
