using System.Net.Sockets;
using System.Runtime.InteropServices;

namespace Bromure.SandboxEngine.Hcs.Native;

/// <summary>
/// Constants and helpers for AF_HYPERV sockets — the Windows-host
/// analogue of vsock. We use these to talk to the per-session VM:
/// <list type="bullet">
///   <item>RDP over hvsocket (Microsoft service GUID
///   <c>0x3375de86…</c> on the Windows side; mstsc connects via this
///   same shape) for the user-facing window.</item>
///   <item>A Bromure control-plane port for boot-up signal +
///   health probe (the macOS port uses the serial console for the
///   same job).</item>
/// </list>
///
/// <para><b>Why this file exists.</b> .NET's <see cref="Socket"/> can
/// already speak AF_HYPERV (since .NET 5), but the address-family
/// integer (<c>AF_HV = 34</c>) and the
/// <see cref="SOCKADDR_HV"/> struct are not in the BCL. So we declare
/// them here and provide a thin <c>SocketAddress</c> builder.</para>
/// </summary>
internal static class HvSocketApi
{
    /// <summary>AF_HYPERV from ws2def.h. Not in <see cref="AddressFamily"/>.</summary>
    public const int AF_HYPERV = 34;

    /// <summary>HV_PROTOCOL_RAW — the only protocol value the kernel
    /// accepts on AF_HYPERV today.</summary>
    public const int HV_PROTOCOL_RAW = 1;

    /// <summary>"Wildcard" VM ID — listen on the host side for connections
    /// from any VM. Only valid in bind contexts.</summary>
    public static readonly Guid HV_GUID_WILDCARD =
        new("00000000-0000-0000-0000-000000000000");

    /// <summary>"Loopback" VM ID — host talking to itself, useful for
    /// tests and for the control-plane handshake before the VM has a
    /// stable runtime ID.</summary>
    public static readonly Guid HV_GUID_LOOPBACK =
        new("e0e16197-dd56-4a10-9195-5ee7a155a838");

    /// <summary>"Parent" VM ID — when used inside a guest, refers to the
    /// host. Used for the corresponding bind on the guest side.</summary>
    public static readonly Guid HV_GUID_PARENT =
        new("a42e7cda-d03f-480c-9cc2-a4de20abb878");

    /// <summary>Create a SocketAddress encoding (AF_HYPERV, vmId, serviceId)
    /// usable with <see cref="Socket.Connect(SocketAddress)"/> /
    /// <see cref="Socket.Bind(EndPoint)"/> via a derived EndPoint.
    ///
    /// <para>Layout matches struct SOCKADDR_HV:
    /// <code>
    ///   USHORT Family;
    ///   USHORT Reserved;
    ///   GUID   VmId;
    ///   GUID   ServiceId;
    /// </code>
    /// 36 bytes total.</para>
    /// </summary>
    public static byte[] BuildSocketAddress(Guid vmId, Guid serviceId)
    {
        var buf = new byte[36];
        // Family (USHORT, little-endian)
        buf[0] = (byte)(AF_HYPERV & 0xFF);
        buf[1] = (byte)((AF_HYPERV >> 8) & 0xFF);
        // Reserved = 0
        buf[2] = 0;
        buf[3] = 0;
        // VmId, ServiceId — write the 16-byte GUIDs in their on-wire layout.
        var vmBytes = vmId.ToByteArray();
        var svcBytes = serviceId.ToByteArray();
        Buffer.BlockCopy(vmBytes, 0, buf, 4, 16);
        Buffer.BlockCopy(svcBytes, 0, buf, 20, 16);
        return buf;
    }

    /// <summary>
    /// Convert a service port number (uint, e.g. 50000) to the Microsoft
    /// well-known hvsocket Service ID convention used by the HCS
    /// HvSocketServiceConfig — <c>{port:8x}-FACB-11E6-BD58-64006A7986D3</c>.
    /// Inside the guest, programs use the same magic to listen on a
    /// "port number" rather than a full service GUID.
    /// </summary>
    public static Guid ServiceIdFromPort(uint port)
    {
        // VSOCK template GUID, with the first 32 bits replaced by the port.
        // Microsoft's textual form is XXXXXXXX-FACB-11E6-BD58-64006A7986D3.
        // .NET's new Guid(byte[]) reads bytes 0..4 as a little-endian
        // Int32, 4..6 + 6..8 as little-endian Int16s, 8..16 byte-for-byte.
        // So lay them out accordingly.
        var bytes = new byte[16];
        bytes[0] = (byte)(port & 0xFF);
        bytes[1] = (byte)((port >> 8) & 0xFF);
        bytes[2] = (byte)((port >> 16) & 0xFF);
        bytes[3] = (byte)((port >> 24) & 0xFF);
        // FACB → little-endian Int16 → bytes CB FA
        bytes[4] = 0xCB; bytes[5] = 0xFA;
        // 11E6 → little-endian Int16 → bytes E6 11
        bytes[6] = 0xE6; bytes[7] = 0x11;
        // BD58-64006A7986D3 — kept as-is (network order in the GUID
        // canonical text == bytes 8..15 in the array).
        bytes[8] = 0xBD; bytes[9] = 0x58;
        bytes[10] = 0x64; bytes[11] = 0x00;
        bytes[12] = 0x6A; bytes[13] = 0x79;
        bytes[14] = 0x86; bytes[15] = 0xD3;
        return new Guid(bytes);
    }
}
