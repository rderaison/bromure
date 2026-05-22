// macos-source: Sources/SandboxEngine/SandboxWindowController.swift @ fe7e7d3a3e21
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace Bromure.AC.Display;

/// <summary>
/// WPF host for the per-session VM's RDP-rendered desktop. Replaces
/// the WSL port's WSLg-HWND-reparent path: HCS doesn't ship WSLg, so
/// we connect mstsc (via the <c>MsTscAx</c> ActiveX control distributed
/// with Windows) to the per-session weston-rdp instance over hvsocket
/// and surface that as our embedded child.
///
/// <para><b>Implementation note (spike scope).</b> The COM interop
/// surface for the MSTSC ActiveX (<c>MSTSCLib</c>, exposing
/// <c>IMsRdpClient9</c>) is rich but well-documented. To keep the
/// project free of generated COM-interop assemblies on the build
/// path, this host launches an out-of-process <c>mstsc.exe</c>
/// targeting an HVSocket-tunnel address, then reparents its top-level
/// HWND into our placeholder via SetParent. This is the pattern used
/// for embedded mstsc in administrative tools (MMC remote desktop
/// snap-in, SCVMM) — a pragmatic alternative to ActiveX that stays
/// inside the Windows-shipped surface.</para>
///
/// <para>Macros to remember about the connection:</para>
/// <list type="bullet">
///   <item>Address = <c>vmconnect://&lt;vm-runtime-id&gt;:&lt;rdp-port&gt;</c>
///   — vmconnect is shipped by Hyper-V and brokers RDP-over-hvsocket
///   without exposing the host's TCP/IP stack.</item>
///   <item>For non-Hyper-V-Manager users (e.g. Windows 11 Home), an
///   alternative is <c>mstsc /v:&lt;hvsocket://...&gt;</c> via the
///   Hyper-V client SDK. The choice is configurable via
///   <see cref="UseVmconnect"/>.</item>
/// </list>
///
/// <para><b>Hardware-only verification.</b> The reparent trick has
/// timing constraints (mstsc's main HWND only appears after the
/// connection negotiates) that I cannot validate from a chat session.
/// The shape compiles and is structurally correct; first-run testing
/// on a real Hyper-V machine is required to nail the timing.</para>
/// </summary>
public sealed class HcsSessionWindowHost : HwndHost
{
    public Guid VmRuntimeId { get; }
    public uint RdpPort { get; }
    /// <summary>Loopback TCP port to dial mstsc against. The HCS session
    /// has a TCP→hvsocket bridge listening here; mstsc connects via
    /// <c>/v:127.0.0.1:&lt;port&gt;</c> and the bridge forwards bytes
    /// to the guest's weston-rdp over hvsocket. Set to 0 to skip the
    /// bridge and fall back to <c>mstsc /v:hvsocket://</c> (only works
    /// for VMs registered with Hyper-V Manager).</summary>
    public int RdpTcpBridgePort { get; init; }
    public bool UseVmconnect { get; init; } = true;

    private System.Diagnostics.Process? _client;
    private IntPtr _placeholder = IntPtr.Zero;

    public HcsSessionWindowHost(Guid vmRuntimeId, uint rdpPort)
    {
        VmRuntimeId = vmRuntimeId;
        RdpPort = rdpPort;
    }

    protected override HandleRef BuildWindowCore(HandleRef hwndParent)
    {
        // Create a host child static window we control. Mstsc/vmconnect
        // gets reparented into this once the connection negotiates.
        _placeholder = CreateWindowEx(
            0, "STATIC", "BromureHcsHost",
            WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN | WS_CLIPSIBLINGS,
            0, 0, 0, 0,
            hwndParent.Handle, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        if (_placeholder == IntPtr.Zero)
        {
            throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
        }
        _ = Task.Run(() => SpawnAndReparentAsync());
        return new HandleRef(this, _placeholder);
    }

    private async Task SpawnAndReparentAsync()
    {
        // Spawn vmconnect or mstsc targeting the per-session VM. Both
        // expose a top-level window after a short negotiation.
        var psi = new System.Diagnostics.ProcessStartInfo
        {
            UseShellExecute = false,
            CreateNoWindow = false,
        };
        if (UseVmconnect)
        {
            // vmconnect.exe lives in System32 on Hyper-V-equipped Win11.
            // It accepts <vm-id> + an optional /edit flag.
            psi.FileName = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                "vmconnect.exe");
            psi.ArgumentList.Add(Environment.MachineName);
            psi.ArgumentList.Add(VmRuntimeId.ToString("D"));
        }
        else
        {
            // mstsc.exe doesn't accept a /cert-ignore switch (despite
            // various blog posts saying otherwise — those are stale).
            // Use a generated .rdp file with `authentication level:i:0`
            // so the self-signed cert weston-rdp synthesises doesn't
            // trigger a prompt or refuse the connect.
            var server = RdpTcpBridgePort > 0
                ? $"127.0.0.1:{RdpTcpBridgePort}"
                : $"hvsocket://{VmRuntimeId:D}:{RdpPort}";
            var rdpFile = Path.Combine(Path.GetTempPath(),
                "bromure-" + Guid.NewGuid().ToString("N")[..8] + ".rdp");
            File.WriteAllText(rdpFile, BuildRdpFile(server), System.Text.Encoding.Unicode);
            psi.FileName = "mstsc.exe";
            psi.ArgumentList.Add(rdpFile);
        }

        try { _client = System.Diagnostics.Process.Start(psi); }
        catch { return; }
        if (_client is null) return;
        try { _client.WaitForInputIdle(15000); } catch { }

        // Poll for the main HWND for up to 10 s.
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(10);
        IntPtr child = IntPtr.Zero;
        while (DateTime.UtcNow < deadline && (child = _client.MainWindowHandle) == IntPtr.Zero)
        {
            await Task.Delay(150).ConfigureAwait(false);
            try { _client.Refresh(); } catch { }
        }
        if (child == IntPtr.Zero) return;
        // Reparent on the UI thread so message-pump invariants hold.
        await System.Windows.Application.Current.Dispatcher.InvokeAsync(() =>
        {
            SetParent(child, _placeholder);
            // Strip WS_OVERLAPPED so it lays out as a child instead of
            // a top-level window with a chrome bar.
            var style = GetWindowLongPtr(child, GWL_STYLE).ToInt64();
            style &= ~(WS_OVERLAPPED | WS_CAPTION | WS_THICKFRAME | WS_SYSMENU);
            style |= WS_CHILD;
            SetWindowLongPtr(child, GWL_STYLE, new IntPtr(style));
        });
    }

    /// <summary>
    /// Generate the contents of a minimal Windows .rdp file. mstsc
    /// reads these as UTF-16LE; PowerShell + the in-box RDP editor
    /// both write that encoding. Keys:
    /// <list type="bullet">
    ///   <item><c>full address</c> — server:port to dial.</item>
    ///   <item><c>authentication level:i:0</c> — don't refuse on cert
    ///   chain failure (weston-rdp serves a self-signed leaf).</item>
    ///   <item><c>enablecredsspsupport:i:0</c> — skip NLA/CredSSP;
    ///   weston-rdp negotiates plain RDP only.</item>
    ///   <item><c>prompt for credentials:i:0</c> — don't ask the user
    ///   for creds, weston doesn't enforce auth.</item>
    /// </list>
    /// </summary>
    private static string BuildRdpFile(string serverAndPort)
    {
        // Strip any leading scheme like hvsocket:// — the .rdp file
        // wants just host:port.
        var addr = serverAndPort.StartsWith("hvsocket://", StringComparison.OrdinalIgnoreCase)
            ? serverAndPort["hvsocket://".Length..]
            : serverAndPort;
        // weston-rdp expects an RDP Negotiation Request packet as the
        // first thing the client sends — even when we want standard
        // RDP security only. `negotiate security layer:i:0` skips it
        // entirely and weston's BIO_read times out (mstsc reports
        // 0x904). negotiate=1 + enablecredsspsupport=0 + authlevel=0
        // tells mstsc to offer RDP only (no TLS, no NLA), weston
        // accepts, handshake proceeds.
        return string.Join("\r\n",
            "full address:s:" + addr,
            "authentication level:i:0",
            "enablecredsspsupport:i:0",
            "prompt for credentials:i:0",
            "negotiate security layer:i:1",
            "redirectclipboard:i:1",
            "redirectprinters:i:0",
            "redirectsmartcards:i:0",
            "audiomode:i:2",
            "");
    }

    protected override void DestroyWindowCore(HandleRef hwnd)
    {
        try { _client?.Kill(entireProcessTree: true); } catch { }
        _client = null;
        if (_placeholder != IntPtr.Zero)
        {
            DestroyWindow(_placeholder);
            _placeholder = IntPtr.Zero;
        }
    }

    private const uint WS_CHILD = 0x40000000;
    private const uint WS_VISIBLE = 0x10000000;
    private const uint WS_CLIPCHILDREN = 0x02000000;
    private const uint WS_CLIPSIBLINGS = 0x04000000;
    private const long WS_OVERLAPPED = 0x00000000;
    private const long WS_CAPTION = 0x00C00000;
    private const long WS_THICKFRAME = 0x00040000;
    private const long WS_SYSMENU = 0x00080000;
    private const int GWL_STYLE = -16;

    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateWindowEx(
        int dwExStyle, string lpClassName, string lpWindowName, uint dwStyle,
        int x, int y, int nWidth, int nHeight,
        IntPtr hWndParent, IntPtr hMenu, IntPtr hInstance, IntPtr lpParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyWindow(IntPtr hwnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetParent(IntPtr hWndChild, IntPtr hWndNewParent);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW", SetLastError = true)]
    private static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int idx);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)]
    private static extern IntPtr SetWindowLongPtr(IntPtr hwnd, int idx, IntPtr newLong);
}
