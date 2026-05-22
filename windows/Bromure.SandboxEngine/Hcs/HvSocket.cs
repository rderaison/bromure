using System.Net;
using System.Net.Sockets;
using Bromure.SandboxEngine.Hcs.Native;

namespace Bromure.SandboxEngine.Hcs;

/// <summary>
/// High-level helpers for opening AF_HYPERV sockets to a specific
/// guest VM by its compute-system ID and a service GUID. .NET's
/// <see cref="Socket"/> already speaks AF_HYPERV — we just need to
/// hand it an opaque <see cref="SocketAddress"/> that the BCL doesn't
/// know how to construct.
///
/// <para>Two patterns we use:</para>
/// <list type="bullet">
///   <item><b>Listen on host</b> for the guest to dial back — bind to
///   <c>HV_GUID_WILDCARD</c> + a port-derived service ID; the guest
///   connects via the same service ID with vmId=HV_GUID_PARENT.</item>
///   <item><b>Dial guest from host</b> — connect to the VM's
///   compute-system ID + a port-derived service ID; the guest must
///   already have a listener bound. Used for the boot-handshake
///   probe and for tunnelled RDP.</item>
/// </list>
///
/// <para>The HCS spec's <c>HvSocketConfig.ServiceTable</c> must
/// include each port we want to use, otherwise the kernel rejects
/// connections with ACCESS_DENIED. <see cref="HcsVm"/> wires the
/// service table from <see cref="HcsVmConfig.HvSocketPorts"/>.</para>
/// </summary>
public static class HvSocket
{
    /// <summary>Open a connected socket to <paramref name="vmId"/> on
    /// the given <paramref name="port"/>. Uses raw Win32
    /// <c>WSASocketW</c> + <c>WSAConnect</c> instead of .NET's Socket
    /// — .NET's Socket layer validates SocketAddress shapes against
    /// a known set of address families, and AF_HYPERV (34) falls
    /// outside that on Win11 24H2 .NET 8, so Socket.ConnectAsync
    /// returns WSAEINVAL (10022) regardless of how the address is
    /// laid out. Going to raw winsock bypasses the validation.</summary>
    public static async Task<Socket> ConnectAsync(Guid vmId, uint port,
        CancellationToken ct = default)
    {
        var serviceId = HvSocketApi.ServiceIdFromPort(port);
        var sa = HvSocketApi.BuildSocketAddress(vmId, serviceId);
        // WSAStartup is a no-op if winsock is already initialised
        // (it's ref-counted). Cheap to call.
        WsaStartupOnce();
        return await Task.Run(() => ConnectRawSync(sa), ct).ConfigureAwait(false);
    }

    /// <summary>Connect and return the raw winsock <c>SOCKET</c>
    /// handle. Use when you want to bypass <see cref="Socket"/> entirely
    /// (e.g. the TCP→hvsocket bridge) — on AF_HYPERV the .NET Socket
    /// wrapper poisons the handle for both Send and Receive (the IOCP
    /// machinery .NET wires up at first async call hangs for HV).</summary>
    public static async Task<IntPtr> ConnectRawAsync(Guid vmId, uint port,
        CancellationToken ct = default)
    {
        var serviceId = HvSocketApi.ServiceIdFromPort(port);
        var sa = HvSocketApi.BuildSocketAddress(vmId, serviceId);
        WsaStartupOnce();
        return await Task.Run(() => ConnectRawSyncRaw(sa), ct).ConfigureAwait(false);
    }

    private static IntPtr ConnectRawSyncRaw(byte[] sockaddr)
    {
        var sock = WSASocketW(HvSocketApi.AF_HYPERV, 1, HvSocketApi.HV_PROTOCOL_RAW,
            IntPtr.Zero, 0, 0);
        if (sock == INVALID_SOCKET)
        {
            throw new System.Net.Sockets.SocketException(
                System.Runtime.InteropServices.Marshal.GetLastWin32Error());
        }
        int rc = WSAConnect(sock, sockaddr, sockaddr.Length,
            IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
        if (rc != 0)
        {
            int err = WSAGetLastError();
            closesocket(sock);
            throw new System.Net.Sockets.SocketException(err);
        }
        // Force blocking mode explicitly. WSASocketW with dwFlags=0
        // should produce a blocking socket but on AF_HYPERV in
        // particular some Win builds default to non-blocking, which
        // makes send() return WSAEWOULDBLOCK / hang. ioctlsocket
        // FIONBIO=0 → blocking.
        uint nonblocking = 0;
        ioctlsocket(sock, FIONBIO, ref nonblocking);
        // Disable Nagle equivalent — TCP_NODELAY isn't applicable to
        // HV transport but the OS may apply other coalescing. The
        // socket-level SO_SNDBUF / SO_RCVBUF defaults are fine.
        return sock;
    }

    private const int FIONBIO = unchecked((int)0x8004667E);

    [System.Runtime.InteropServices.DllImport("ws2_32.dll", SetLastError = true)]
    private static extern int ioctlsocket(IntPtr s, int cmd, ref uint argp);

    public static void CloseRaw(IntPtr handle)
    {
        if (handle != IntPtr.Zero && handle != new IntPtr(-1))
        {
            closesocket(handle);
        }
    }

    /// <summary>Raw <c>send()</c> on a winsock SOCKET handle.</summary>
    public static int SendRawHandle(IntPtr handle, byte[] buf, int offset, int count)
    {
        var pinned = System.Runtime.InteropServices.GCHandle.Alloc(
            buf, System.Runtime.InteropServices.GCHandleType.Pinned);
        try
        {
            var p = System.Runtime.InteropServices.Marshal.UnsafeAddrOfPinnedArrayElement(buf, offset);
            var n = Win32Send(handle, p, count, 0);
            if (n < 0)
            {
                var err = System.Runtime.InteropServices.Marshal.GetLastWin32Error();
                throw new System.Net.Sockets.SocketException(err);
            }
            return n;
        }
        finally { pinned.Free(); }
    }

    /// <summary>Raw <c>recv()</c> on a winsock SOCKET handle.</summary>
    public static int RecvRawHandle(IntPtr handle, byte[] buf, int offset, int count)
    {
        var pinned = System.Runtime.InteropServices.GCHandle.Alloc(
            buf, System.Runtime.InteropServices.GCHandleType.Pinned);
        try
        {
            var p = System.Runtime.InteropServices.Marshal.UnsafeAddrOfPinnedArrayElement(buf, offset);
            var n = Win32Recv(handle, p, count, 0);
            if (n < 0)
            {
                var err = System.Runtime.InteropServices.Marshal.GetLastWin32Error();
                throw new System.Net.Sockets.SocketException(err);
            }
            return n;
        }
        finally { pinned.Free(); }
    }

    private static Socket ConnectRawSync(byte[] sockaddr)
    {
        // WSASocketW(AF_HYPERV=34, SOCK_STREAM=1, HV_PROTOCOL_RAW=1, NULL, 0, 0)
        var sock = WSASocketW(HvSocketApi.AF_HYPERV, 1 /* SOCK_STREAM */,
            HvSocketApi.HV_PROTOCOL_RAW, IntPtr.Zero, 0, 0);
        if (sock == INVALID_SOCKET)
        {
            throw new System.Net.Sockets.SocketException(System.Runtime.InteropServices.Marshal.GetLastWin32Error());
        }
        try
        {
            int rc = WSAConnect(sock, sockaddr, sockaddr.Length,
                IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            if (rc != 0)
            {
                int err = WSAGetLastError();
                closesocket(sock);
                throw new System.Net.Sockets.SocketException(err);
            }
            // Wrap the raw SOCKET in a .NET Socket so the caller's
            // using-block disposes it cleanly. Socket has an
            // internal constructor that takes a SafeSocketHandle —
            // we go through reflection-free public APIs via
            // SafeSocketHandle.
            var handle = new System.Net.Sockets.SafeSocketHandle(sock, ownsHandle: true);
            return new Socket(handle);
        }
        catch
        {
            closesocket(sock);
            throw;
        }
    }

    private static int _wsaStarted;
    private static void WsaStartupOnce()
    {
        if (System.Threading.Interlocked.CompareExchange(ref _wsaStarted, 1, 0) != 0) return;
        var wsaData = new byte[400];
        int rc = WSAStartup(0x0202, wsaData);
        if (rc != 0)
            throw new System.Net.Sockets.SocketException(rc);
    }

    private const IntPtr INVALID_SOCKET_VAL = -1;
    private static IntPtr INVALID_SOCKET => new IntPtr(-1);

    [System.Runtime.InteropServices.DllImport("ws2_32.dll", SetLastError = true,
        CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern IntPtr WSASocketW(int af, int type, int protocol,
        IntPtr lpProtocolInfo, uint group, uint dwFlags);

    [System.Runtime.InteropServices.DllImport("ws2_32.dll", SetLastError = true)]
    private static extern int WSAConnect(IntPtr s, byte[] name, int namelen,
        IntPtr lpCallerData, IntPtr lpCalleeData, IntPtr lpSQOS, IntPtr lpGQOS);

    [System.Runtime.InteropServices.DllImport("ws2_32.dll")]
    private static extern int WSAGetLastError();

    [System.Runtime.InteropServices.DllImport("ws2_32.dll")]
    private static extern int closesocket(IntPtr s);

    [System.Runtime.InteropServices.DllImport("ws2_32.dll", CharSet = System.Runtime.InteropServices.CharSet.Ansi)]
    private static extern int WSAStartup(ushort versionRequested, byte[] data);

    [System.Runtime.InteropServices.DllImport("ws2_32.dll", SetLastError = true, EntryPoint = "send")]
    private static extern int Win32Send(IntPtr s, IntPtr buf, int len, int flags);

    [System.Runtime.InteropServices.DllImport("ws2_32.dll", SetLastError = true, EntryPoint = "recv")]
    private static extern int Win32Recv(IntPtr s, IntPtr buf, int len, int flags);

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct WSABUF
    {
        public uint Length;
        public IntPtr Buffer;
    }

    [System.Runtime.InteropServices.DllImport("ws2_32.dll", SetLastError = true, EntryPoint = "WSASend")]
    private static extern int WSASend(IntPtr s, ref WSABUF buffers, uint bufferCount,
        out uint bytesSent, uint flags, IntPtr lpOverlapped, IntPtr lpCompletionRoutine);

    [System.Runtime.InteropServices.DllImport("ws2_32.dll", SetLastError = true, EntryPoint = "WSARecv")]
    private static extern int WSARecv(IntPtr s, ref WSABUF buffers, uint bufferCount,
        out uint bytesRecvd, ref uint flags, IntPtr lpOverlapped, IntPtr lpCompletionRoutine);

    /// <summary>WSASend on a raw winsock handle — explicit form of
    /// <see cref="SendRawHandle"/> using the WSA buffer descriptor.
    /// Some AF_HYPERV stack implementations behave differently for
    /// <c>send()</c> (which goes through a compat shim) vs WSASend
    /// (the canonical winsock entry point).</summary>
    public static int WsaSendRawHandle(IntPtr handle, byte[] buf, int offset, int count)
    {
        var pinned = System.Runtime.InteropServices.GCHandle.Alloc(
            buf, System.Runtime.InteropServices.GCHandleType.Pinned);
        try
        {
            var wsabuf = new WSABUF
            {
                Length = (uint)count,
                Buffer = System.Runtime.InteropServices.Marshal.UnsafeAddrOfPinnedArrayElement(buf, offset),
            };
            var rc = WSASend(handle, ref wsabuf, 1, out var bytesSent, 0, IntPtr.Zero, IntPtr.Zero);
            if (rc != 0)
            {
                throw new System.Net.Sockets.SocketException(WSAGetLastError());
            }
            return (int)bytesSent;
        }
        finally { pinned.Free(); }
    }

    public static int WsaRecvRawHandle(IntPtr handle, byte[] buf, int offset, int count)
    {
        var pinned = System.Runtime.InteropServices.GCHandle.Alloc(
            buf, System.Runtime.InteropServices.GCHandleType.Pinned);
        try
        {
            var wsabuf = new WSABUF
            {
                Length = (uint)count,
                Buffer = System.Runtime.InteropServices.Marshal.UnsafeAddrOfPinnedArrayElement(buf, offset),
            };
            uint flags = 0;
            var rc = WSARecv(handle, ref wsabuf, 1, out var bytesRecvd, ref flags, IntPtr.Zero, IntPtr.Zero);
            if (rc != 0)
            {
                throw new System.Net.Sockets.SocketException(WSAGetLastError());
            }
            return (int)bytesRecvd;
        }
        finally { pinned.Free(); }
    }

    /// <summary>Synchronous Win32 <c>send()</c> on a raw winsock SOCKET
    /// handle. Bypasses .NET's Socket.Send pathway which on AF_HYPERV
    /// sockets (constructed via <c>new Socket(SafeSocketHandle)</c>)
    /// silently hangs — likely because the IOCP-bind / pipe setup the
    /// async path runs is unimplemented for the Hyper-V transport.</summary>
    public static int SendRaw(Socket sock, byte[] buf, int offset, int count)
    {
        var safeHandle = sock.SafeHandle;
        bool added = false;
        var pinned = System.Runtime.InteropServices.GCHandle.Alloc(
            buf, System.Runtime.InteropServices.GCHandleType.Pinned);
        try
        {
            safeHandle.DangerousAddRef(ref added);
            var handle = safeHandle.DangerousGetHandle();
            var p = System.Runtime.InteropServices.Marshal.UnsafeAddrOfPinnedArrayElement(buf, offset);
            var n = Win32Send(handle, p, count, 0);
            if (n < 0)
            {
                var err = System.Runtime.InteropServices.Marshal.GetLastWin32Error();
                throw new System.Net.Sockets.SocketException(err);
            }
            return n;
        }
        finally
        {
            if (added) safeHandle.DangerousRelease();
            pinned.Free();
        }
    }

    /// <summary>Synchronous Win32 <c>recv()</c> on a raw winsock SOCKET
    /// handle. Same rationale as <see cref="SendRaw"/>.</summary>
    public static int RecvRaw(Socket sock, byte[] buf, int offset, int count)
    {
        var safeHandle = sock.SafeHandle;
        bool added = false;
        var pinned = System.Runtime.InteropServices.GCHandle.Alloc(
            buf, System.Runtime.InteropServices.GCHandleType.Pinned);
        try
        {
            safeHandle.DangerousAddRef(ref added);
            var handle = safeHandle.DangerousGetHandle();
            var p = System.Runtime.InteropServices.Marshal.UnsafeAddrOfPinnedArrayElement(buf, offset);
            var n = Win32Recv(handle, p, count, 0);
            if (n < 0)
            {
                var err = System.Runtime.InteropServices.Marshal.GetLastWin32Error();
                throw new System.Net.Sockets.SocketException(err);
            }
            return n;
        }
        finally
        {
            if (added) safeHandle.DangerousRelease();
            pinned.Free();
        }
    }

    /// <summary>Bind a listener on the host so a guest can connect to us.</summary>
    public static Socket Listen(uint port, int backlog = 4)
    {
        var sock = new Socket((AddressFamily)HvSocketApi.AF_HYPERV,
            SocketType.Stream,
            (ProtocolType)HvSocketApi.HV_PROTOCOL_RAW);
        var serviceId = HvSocketApi.ServiceIdFromPort(port);
        var sa = HvSocketApi.BuildSocketAddress(HvSocketApi.HV_GUID_WILDCARD, serviceId);
        sock.Bind(new HvEndPoint(sa));
        sock.Listen(backlog);
        return sock;
    }
}

/// <summary>
/// EndPoint that wraps a precomputed AF_HYPERV SocketAddress. The BCL's
/// SocketAddress has a fixed family field at byte 0; we construct a
/// fully-formed 36-byte buffer and surface it through the same
/// SocketAddress shape <see cref="Socket"/> expects.
/// </summary>
internal sealed class HvEndPoint : EndPoint
{
    private readonly SocketAddress _sa;

    public HvEndPoint(byte[] raw)
    {
        _sa = new SocketAddress((AddressFamily)HvSocketApi.AF_HYPERV, raw.Length);
        for (int i = 0; i < raw.Length; i++) _sa[i] = raw[i];
    }

    public override AddressFamily AddressFamily => (AddressFamily)HvSocketApi.AF_HYPERV;
    public override SocketAddress Serialize() => _sa;
    public override EndPoint Create(SocketAddress socketAddress) => this;
}
