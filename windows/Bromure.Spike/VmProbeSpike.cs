using Bromure.SandboxEngine.Hcs;

namespace Bromure.Spike;

/// <summary>
/// Diagnostic dialer for the in-VM bromure-cmd-server. Takes a VM
/// RuntimeId + a shell command line, runs the command inside the
/// guest via hvsocket port 9226, prints stdout/stderr to host stdout.
///
/// <para>Used to introspect a running session's guest state when VNC
/// is misbehaving: list Xvnc processes, cat its log, query systemd,
/// etc.</para>
/// </summary>
internal static class VmProbeSpike
{
    public const uint CmdServerPort = 9226;

    public static async Task<int> RunAsync(Guid vmRuntimeId, string command, CancellationToken ct)
    {
        if (vmRuntimeId == Guid.Empty)
        {
            Console.Error.WriteLine("vmid is required");
            return 2;
        }
        var line = command.EndsWith('\n') ? command : command + "\n";
        var bytes = System.Text.Encoding.UTF8.GetBytes(line);
        System.Net.Sockets.Socket sock;
        try
        {
            sock = await HvSocket.ConnectAsync(vmRuntimeId, CmdServerPort, ct).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"hvsocket dial failed: {ex.GetType().Name}: {ex.Message}");
            return 3;
        }
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
            while (true)
            {
                int n;
                try { n = HvSocket.RecvRaw(sock, buf, 0, buf.Length); }
                catch (System.Net.Sockets.SocketException) { break; }
                if (n <= 0) break;
                Console.Out.Write(System.Text.Encoding.UTF8.GetString(buf, 0, n));
            }
            Console.Out.Flush();
            return 0;
        }
        finally { try { sock.Dispose(); } catch { } }
    }
}
