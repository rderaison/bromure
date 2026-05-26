using System.IO;
using System.Net.Sockets;
using System.Text;

namespace Bromure.AC.Display;

/// <summary>
/// Minimal RFB (Remote Framebuffer / VNC) protocol implementation.
/// Speaks RFB 3.8 with the "None" security type; supports Raw and
/// CopyRect framebuffer encodings (enough for any VNC server out of
/// the box — Tight/ZRLE/Hextile are perf upgrades for later).
///
/// <para>This sits below <see cref="VncControl"/>: it owns the TCP
/// socket, runs the message loop on a background task, and surfaces
/// rectangle updates + pointer/keyboard events through callbacks. The
/// view is plain WPF — render to a <c>WriteableBitmap</c>, forward
/// input events back as <see cref="SendPointer"/> / <see cref="SendKey"/>.</para>
///
/// <para>Sized for two consumers: Bromure AC's session window (today)
/// and Bromure Web (future — same protocol, JS client via noVNC). Keep
/// the protocol code Bromure-agnostic and reusable.</para>
/// </summary>
public sealed class VncClient : IAsyncDisposable
{
    private readonly string _host;
    private readonly int _port;
    private TcpClient? _tcp;
    private NetworkStream? _stream;
    private CancellationTokenSource? _cts;
    private Task? _loop;
    // Outgoing writes happen from the message loop (FramebufferUpdateRequest
    // after each frame) AND from arbitrary UI-thread callers
    // (SetDesktopSize on window resize, SendClipboard on focus, pointer
    // + key events). They MUST be serialised — NetworkStream.WriteAsync
    // isn't safe under concurrent callers, and even byte-interleaving
    // breaks the RFB framing immediately. A SemaphoreSlim is the
    // standard async-friendly mutex.
    private readonly SemaphoreSlim _writeLock = new(1, 1);

    private async Task WriteLockedAsync(byte[] msg, CancellationToken ct)
    {
        if (_stream is null) return;
        await _writeLock.WaitAsync(ct).ConfigureAwait(false);
        try { await _stream.WriteAsync(msg, ct).ConfigureAwait(false); }
        finally { _writeLock.Release(); }
    }

    public int Width { get; private set; }
    public int Height { get; private set; }
    public string DesktopName { get; private set; } = "";

    /// <summary>Fired on the message-loop thread for each rectangle
    /// the server sends. Subscribers MUST marshal to the UI thread
    /// before touching WPF. Pixels are 32 bpp BGRA (we negotiate that
    /// format in the SetPixelFormat call).</summary>
    public event Action<RectUpdate>? RectangleReceived;

    /// <summary>Fired once when the server's initial dimensions +
    /// pixel format are negotiated — gives the view enough info to
    /// allocate its WriteableBitmap.</summary>
    public event Action? Ready;

    /// <summary>Fired when the loop exits — either we asked it to or
    /// the server closed the connection.</summary>
    public event Action<Exception?>? Disconnected;

    /// <summary>Fired when the server resizes its framebuffer (either
    /// because we asked via <see cref="SetDesktopSizeAsync"/> or
    /// because something else triggered a DesktopSize/ExtendedDesktopSize
    /// rect). Subscribers must marshal to the UI thread before
    /// touching WPF.</summary>
    public event Action<int, int>? DesktopResized;

    /// <summary>Fired when the server sends clipboard text via the
    /// ServerCutText message. Subscribers marshal to UI thread.</summary>
    public event Action<string>? ServerClipboardChanged;

    public VncClient(string host, int port)
    {
        _host = host;
        _port = port;
    }

    // -- Lifecycle -------------------------------------------------------

    public async Task ConnectAsync(CancellationToken ct = default)
    {
        _tcp = new TcpClient { NoDelay = true };
        await _tcp.ConnectAsync(_host, _port, ct).ConfigureAwait(false);
        _stream = _tcp.GetStream();
        await HandshakeAsync(ct).ConfigureAwait(false);
        _cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        _loop = Task.Run(() => RunLoopAsync(_cts.Token));
    }

    public async ValueTask DisposeAsync()
    {
        try { _cts?.Cancel(); } catch { }
        try { _stream?.Dispose(); } catch { }
        try { _tcp?.Dispose(); } catch { }
        if (_loop is not null)
        {
            try { await _loop.ConfigureAwait(false); } catch { }
        }
        _cts?.Dispose();
    }

    // -- Handshake -------------------------------------------------------

    /// <summary>
    /// RFB 3.8 handshake:
    /// <list type="number">
    ///   <item>Server sends 12-byte "RFB 003.008\n" protocol version.</item>
    ///   <item>Client echoes the version (we always pick 3.8).</item>
    ///   <item>Server sends 1-byte count + N security types.</item>
    ///   <item>Client picks one (we pick 1 = None).</item>
    ///   <item>Server sends 4-byte SecurityResult (0 = OK).</item>
    ///   <item>Client sends 1-byte ClientInit (shared = 1).</item>
    ///   <item>Server sends ServerInit: width, height, pixel format,
    ///   name length, name.</item>
    /// </list>
    /// Then we issue a SetPixelFormat (force 32 bpp BGRA), SetEncodings
    /// (Raw + CopyRect), and an initial full FramebufferUpdateRequest.
    /// </summary>
    private async Task HandshakeAsync(CancellationToken ct)
    {
        var stream = _stream!;
        void Log(string s) { try { Console.Error.WriteLine("[vnc-client] " + s); Console.Error.Flush(); } catch { } }

        Log("handshake: reading RFB protocol version (12 B)");
        // 1) Protocol version exchange.
        var versionBuf = new byte[12];
        await ReadFullAsync(stream, versionBuf, ct).ConfigureAwait(false);
        var serverVersion = Encoding.ASCII.GetString(versionBuf);
        Log("handshake: server version = " + serverVersion.TrimEnd('\n'));
        if (!serverVersion.StartsWith("RFB ", StringComparison.Ordinal))
            throw new VncProtocolException("Bad server greeting: " + serverVersion);
        // Always negotiate 3.8 — the only version we implement.
        await stream.WriteAsync(Encoding.ASCII.GetBytes("RFB 003.008\n"), ct).ConfigureAwait(false);
        Log("handshake: wrote our version");

        // 2) Security types.
        Log("handshake: reading security-types count");
        var secCount = (await ReadFullAsync(stream, 1, ct).ConfigureAwait(false))[0];
        Log("handshake: secCount = " + secCount);
        if (secCount == 0)
        {
            // Server failure — read the reason string and bubble.
            var reasonLen = ReadU32BE(await ReadFullAsync(stream, 4, ct).ConfigureAwait(false));
            var reason = Encoding.UTF8.GetString(await ReadFullAsync(stream, (int)reasonLen, ct).ConfigureAwait(false));
            throw new VncProtocolException("Server refused: " + reason);
        }
        var secTypes = await ReadFullAsync(stream, secCount, ct).ConfigureAwait(false);
        Log("handshake: secTypes = [" + string.Join(",", secTypes) + "]");
        if (!secTypes.Contains((byte)1))
            throw new VncProtocolException("Server doesn't support 'None' auth (offered: " + string.Join(",", secTypes) + ")");
        await stream.WriteAsync(new byte[] { 1 }, ct).ConfigureAwait(false); // pick None
        Log("handshake: picked None (1)");

        // 3) SecurityResult — always required in RFB 3.8 even for None.
        Log("handshake: reading SecurityResult (4 B)");
        var secResult = ReadU32BE(await ReadFullAsync(stream, 4, ct).ConfigureAwait(false));
        Log("handshake: secResult = " + secResult);
        if (secResult != 0)
        {
            // Read failure reason string.
            var reasonLen = ReadU32BE(await ReadFullAsync(stream, 4, ct).ConfigureAwait(false));
            var reason = Encoding.UTF8.GetString(await ReadFullAsync(stream, (int)reasonLen, ct).ConfigureAwait(false));
            throw new VncProtocolException("Security failed: " + reason);
        }

        // 4) ClientInit — shared = 1 (allow concurrent viewers).
        await stream.WriteAsync(new byte[] { 1 }, ct).ConfigureAwait(false);

        // 5) ServerInit — 24 bytes header + N-byte name.
        var serverInit = await ReadFullAsync(stream, 24, ct).ConfigureAwait(false);
        Width  = (serverInit[0] << 8) | serverInit[1];
        Height = (serverInit[2] << 8) | serverInit[3];
        var nameLen = ReadU32BE(serverInit.AsSpan(20, 4).ToArray());
        if (nameLen > 0)
        {
            var nameBuf = await ReadFullAsync(stream, (int)nameLen, ct).ConfigureAwait(false);
            DesktopName = Encoding.UTF8.GetString(nameBuf);
        }

        // 6) Force 32 bpp BGRA pixel format — the simplest mapping
        //    onto a WPF WriteableBitmap.PixelFormat.Bgra32.
        await SendSetPixelFormatBgra32Async(ct).ConfigureAwait(false);

        // 7) Encodings: Raw + CopyRect for pixel data, plus the
        // DesktopSize / ExtendedDesktopSize pseudo-encodings so the
        // server announces resize capability and accepts client-side
        // SetDesktopSize messages. The in-guest matchbox WM keeps
        // xterm maximised across every framebuffer change.
        await SendSetEncodingsAsync(new[]
        {
            0,        // Raw — mandatory
            1,        // CopyRect — cheap blit
            -223,     // DesktopSize (server-driven resize notify)
            -308,     // ExtendedDesktopSize (client-driven resize)
            // UX #4 — ContinuousUpdates pseudo-encoding (-313). The
            // diagnostic log proved that REMOVING this regressed both
            // directions of data flow: VNC handshake completed but no
            // FramebufferUpdate responses arrived AND keyboard events
            // never reached the guest. Bake-baked Xvnc apparently
            // requires negotiating this pseudo-encoding to put the
            // session into the right state. We keep the per-frame
            // request loop in RunLoopAsync as the actual driver of
            // updates — the EnableContinuousUpdates message below is
            // what wakes the server up.
            -313,     // ContinuousUpdates
        }, ct).ConfigureAwait(false);

        // 8) Initial full framebuffer request.
        await SendFramebufferUpdateRequestAsync(incremental: false, 0, 0, Width, Height, ct)
            .ConfigureAwait(false);

        // 9) UX #4 — tell the server we want continuous updates. The
        // run loop still re-issues a per-frame request after each
        // FramebufferUpdate response (so idle desktops keep their
        // first frame), but the EnableContinuousUpdates handshake is
        // what gets this bake's Xvnc to actually respond to our
        // initial request. Fire-and-forget; if a server doesn't
        // implement it, the next read either succeeds (no-op) or
        // fails (the loop's read catches it).
        try
        {
            await SendEnableContinuousUpdatesAsync(enable: true, 0, 0, Width, Height, ct)
                .ConfigureAwait(false);
        }
        catch { /* server didn't grok it; loop's per-frame polling carries us */ }

        // Fire Ready AFTER all handshake writes are done. The handler
        // can synchronously kick off another write (SetDesktopSize is
        // the obvious one). Doing this before the last handshake write
        // races for the socket and Xvnc resets the connection.
        Ready?.Invoke();
    }

    /// <summary>RFC 8332 / OpenSSH-rfb extension: EnableContinuousUpdates
    /// puts the server into the state where it streams updates within
    /// the requested rect. Required to wake this bake's Xvnc up after
    /// the initial FramebufferUpdateRequest — without it, the server
    /// stays silent and both pixel + input paths appear wedged.</summary>
    public async Task SendEnableContinuousUpdatesAsync(
        bool enable, int x, int y, int w, int h, CancellationToken ct = default)
    {
        if (_stream is null) return;
        var msg = new byte[10];
        msg[0] = 150; // EnableContinuousUpdates
        msg[1] = (byte)(enable ? 1 : 0);
        msg[2] = (byte)(x >> 8); msg[3] = (byte)(x & 0xFF);
        msg[4] = (byte)(y >> 8); msg[5] = (byte)(y & 0xFF);
        msg[6] = (byte)(w >> 8); msg[7] = (byte)(w & 0xFF);
        msg[8] = (byte)(h >> 8); msg[9] = (byte)(h & 0xFF);
        await WriteLockedAsync(msg, ct).ConfigureAwait(false);
    }

    // -- Outgoing messages -----------------------------------------------

    private async Task SendSetPixelFormatBgra32Async(CancellationToken ct)
    {
        // SetPixelFormat = 0 + 3 pad + 16-byte PIXEL_FORMAT.
        var msg = new byte[20];
        msg[0] = 0; // message type
        // PIXEL_FORMAT starts at offset 4:
        msg[4]  = 32;  // bits-per-pixel
        msg[5]  = 24;  // depth
        msg[6]  = 0;   // big-endian flag (0 = little)
        msg[7]  = 1;   // true-colour
        // red-max, green-max, blue-max = 255 (U16 BE).
        msg[8] = 0;  msg[9]  = 0xFF;
        msg[10] = 0; msg[11] = 0xFF;
        msg[12] = 0; msg[13] = 0xFF;
        // shifts: B at 0, G at 8, R at 16 — i.e. BGRA in memory.
        msg[14] = 16; // red-shift
        msg[15] = 8;  // green-shift
        msg[16] = 0;  // blue-shift
        // bytes 17-19 are padding.
        await _stream!.WriteAsync(msg, ct).ConfigureAwait(false);
    }

    private async Task SendSetEncodingsAsync(int[] encodings, CancellationToken ct)
    {
        // SetEncodings = 2 + 1 pad + U16 count + N * S32 encoding ID.
        var msg = new byte[4 + 4 * encodings.Length];
        msg[0] = 2;
        msg[2] = (byte)(encodings.Length >> 8);
        msg[3] = (byte)(encodings.Length & 0xFF);
        for (var i = 0; i < encodings.Length; i++)
        {
            var off = 4 + 4 * i;
            var enc = encodings[i];
            msg[off]     = (byte)((enc >> 24) & 0xFF);
            msg[off + 1] = (byte)((enc >> 16) & 0xFF);
            msg[off + 2] = (byte)((enc >> 8) & 0xFF);
            msg[off + 3] = (byte)(enc & 0xFF);
        }
        await _stream!.WriteAsync(msg, ct).ConfigureAwait(false);
    }

    public async Task SendFramebufferUpdateRequestAsync(
        bool incremental, int x, int y, int w, int h, CancellationToken ct = default)
    {
        if (_stream is null) return;
        var msg = new byte[10];
        msg[0] = 3; // FramebufferUpdateRequest
        msg[1] = (byte)(incremental ? 1 : 0);
        msg[2] = (byte)(x >> 8); msg[3] = (byte)(x & 0xFF);
        msg[4] = (byte)(y >> 8); msg[5] = (byte)(y & 0xFF);
        msg[6] = (byte)(w >> 8); msg[7] = (byte)(w & 0xFF);
        msg[8] = (byte)(h >> 8); msg[9] = (byte)(h & 0xFF);
        try { await WriteLockedAsync(msg, ct).ConfigureAwait(false); }
        catch { /* loop will catch on read */ }
    }

/// <summary>RFB PointerEvent — buttonMask is a bitfield: bit 0 =
    /// left, bit 1 = middle, bit 2 = right, bit 3+4 = wheel up/down.</summary>
    public async Task SendPointerAsync(byte buttonMask, int x, int y, CancellationToken ct = default)
    {
        if (_stream is null) return;
        var msg = new byte[6];
        msg[0] = 5; // PointerEvent
        msg[1] = buttonMask;
        msg[2] = (byte)(x >> 8); msg[3] = (byte)(x & 0xFF);
        msg[4] = (byte)(y >> 8); msg[5] = (byte)(y & 0xFF);
        try { await WriteLockedAsync(msg, ct).ConfigureAwait(false); }
        catch { }
    }

    /// <summary>
    /// Ask the server to resize its framebuffer. RFB
    /// SetDesktopSize message (type 251) defined by the
    /// ExtendedDesktopSize extension. TigerVNC, x11vnc, and most
    /// modern servers honour it; the response comes back as an
    /// ExtendedDesktopSize rect in the next FramebufferUpdate (which
    /// fires <see cref="DesktopResized"/>).
    /// </summary>
    public async Task SetDesktopSizeAsync(int width, int height, CancellationToken ct = default)
    {
        if (_stream is null) return;
        if (width <= 0 || height <= 0) return;
        // RFB SetDesktopSize (msg=251) wire format:
        //   [0]    U8   msg-type = 251
        //   [1]    U8   padding
        //   [2-3]  U16  width
        //   [4-5]  U16  height
        //   [6]    U8   num-screens
        //   [7]    U8   padding
        // Then num-screens × 16 bytes:
        //   [8-11]  U32 id
        //   [12-13] U16 x
        //   [14-15] U16 y
        //   [16-17] U16 width
        //   [18-19] U16 height
        //   [20-23] U32 flags
        // Earlier I had width/height in the screen's x/y slots —
        // Xvnc rejected the message and dropped the TCP connection,
        // which the host stack reported as "connection aborted by
        // software in your host machine."
        var msg = new byte[8 + 16];  // 1 screen
        msg[0] = 251;
        msg[2] = (byte)(width >> 8);  msg[3] = (byte)(width & 0xFF);
        msg[4] = (byte)(height >> 8); msg[5] = (byte)(height & 0xFF);
        msg[6] = 1; // num screens
        // screen[0]: id=0, x=0, y=0, w=width, h=height, flags=0
        // id, x, y already zero (default array init).
        msg[16] = (byte)(width >> 8);  msg[17] = (byte)(width & 0xFF);
        msg[18] = (byte)(height >> 8); msg[19] = (byte)(height & 0xFF);
        try { await WriteLockedAsync(msg, ct).ConfigureAwait(false); }
        catch { /* loop will report */ }
    }

    /// <summary>Send the host clipboard contents to the server (RFB
    /// ClientCutText, message type 6).</summary>
    public async Task SendClipboardAsync(string text, CancellationToken ct = default)
    {
        if (_stream is null || string.IsNullOrEmpty(text)) return;
        var bytes = Encoding.Latin1.GetBytes(text);
        var msg = new byte[8 + bytes.Length];
        msg[0] = 6;
        msg[4] = (byte)((bytes.Length >> 24) & 0xFF);
        msg[5] = (byte)((bytes.Length >> 16) & 0xFF);
        msg[6] = (byte)((bytes.Length >> 8) & 0xFF);
        msg[7] = (byte)(bytes.Length & 0xFF);
        Buffer.BlockCopy(bytes, 0, msg, 8, bytes.Length);
        try { await WriteLockedAsync(msg, ct).ConfigureAwait(false); }
        catch { }
    }

    /// <summary>RFB KeyEvent — keysym is an X11 keysym (the common
    /// case for letters is just the ASCII codepoint).</summary>
    public async Task SendKeyAsync(uint keysym, bool down, CancellationToken ct = default)
    {
        if (_stream is null) return;
        var msg = new byte[8];
        msg[0] = 4; // KeyEvent
        msg[1] = (byte)(down ? 1 : 0);
        msg[4] = (byte)((keysym >> 24) & 0xFF);
        msg[5] = (byte)((keysym >> 16) & 0xFF);
        msg[6] = (byte)((keysym >> 8) & 0xFF);
        msg[7] = (byte)(keysym & 0xFF);
        try { await WriteLockedAsync(msg, ct).ConfigureAwait(false); }
        catch { }
    }

    // -- Message loop ----------------------------------------------------

    private async Task RunLoopAsync(CancellationToken ct)
    {
        Exception? exit = null;
        try
        {
            var stream = _stream!;
            var header = new byte[1];
            while (!ct.IsCancellationRequested)
            {
                await ReadFullAsync(stream, header, ct).ConfigureAwait(false);
                switch (header[0])
                {
                    case 0:  // FramebufferUpdate
                        await HandleFramebufferUpdateAsync(stream, ct).ConfigureAwait(false);
                        // Re-issue an incremental request after every
                        // frame. RFC 6143 request/update polling — the
                        // server only sends a FramebufferUpdate when
                        // we ask, so we have to keep asking. This is
                        // the canonical RFB shape; no streaming
                        // extension, no edge cases.
                        await SendFramebufferUpdateRequestAsync(
                            incremental: true, 0, 0, Width, Height, ct).ConfigureAwait(false);
                        break;
                    case 2:  // Bell
                        // No-op; could surface as System.Media.SystemSounds.Beep.
                        break;
                    case 3:  // ServerCutText (clipboard)
                        await ReadFullAsync(stream, 3, ct).ConfigureAwait(false); // padding
                        var clipLen = ReadU32BE(await ReadFullAsync(stream, 4, ct).ConfigureAwait(false));
                        var clipBytes = await ReadFullAsync(stream, (int)clipLen, ct).ConfigureAwait(false);
                        // RFB spec: server cut text is Latin-1. Modern
                        // servers (TigerVNC, x11vnc) negotiate UTF-8 via
                        // an extension we don't request, so they fall
                        // back to Latin-1 single-byte chars here.
                        var text = Encoding.Latin1.GetString(clipBytes);
                        ServerClipboardChanged?.Invoke(text);
                        break;
                    default:
                        throw new VncProtocolException("Unknown server message type: " + header[0]);
                }
            }
        }
        catch (OperationCanceledException) { /* expected on Dispose */ }
        catch (Exception ex) { exit = ex; }
        finally
        {
            Disconnected?.Invoke(exit);
        }
    }

    private async Task HandleFramebufferUpdateAsync(NetworkStream stream, CancellationToken ct)
    {
        // 1 byte padding + U16 rect count + N rectangles.
        var hdr = await ReadFullAsync(stream, 3, ct).ConfigureAwait(false);
        var rectCount = (hdr[1] << 8) | hdr[2];
        for (var i = 0; i < rectCount; i++)
        {
            var meta = await ReadFullAsync(stream, 12, ct).ConfigureAwait(false);
            var x = (meta[0] << 8) | meta[1];
            var y = (meta[2] << 8) | meta[3];
            var w = (meta[4] << 8) | meta[5];
            var h = (meta[6] << 8) | meta[7];
            var enc = (meta[8] << 24) | (meta[9] << 16) | (meta[10] << 8) | meta[11];

            switch (enc)
            {
                case 0:  // Raw — w*h*4 bytes BGRA
                {
                    var pixels = await ReadFullAsync(stream, w * h * 4, ct).ConfigureAwait(false);
                    RectangleReceived?.Invoke(new RectUpdate(x, y, w, h, RectKind.Raw, pixels, 0, 0));
                    break;
                }
                case 1:  // CopyRect — U16 srcX, U16 srcY
                {
                    var src = await ReadFullAsync(stream, 4, ct).ConfigureAwait(false);
                    var sx = (src[0] << 8) | src[1];
                    var sy = (src[2] << 8) | src[3];
                    RectangleReceived?.Invoke(new RectUpdate(x, y, w, h, RectKind.CopyRect, Array.Empty<byte>(), sx, sy));
                    break;
                }
                case -223:  // DesktopSize pseudo — server announces new dims
                {
                    Width = w;
                    Height = h;
                    DesktopResized?.Invoke(w, h);
                    break;
                }
                case -308:  // ExtendedDesktopSize pseudo
                {
                    // Per rfbproto.rst: rect.x = reason, rect.y = status,
                    // rect.w/h = new framebuffer size. Encoded payload:
                    //   U8 num-screens, U8[3] padding, then num-screens
                    //   × 16-byte screen records. The "num-screens" field
                    //   is in the PAYLOAD, NOT the rect header — earlier
                    //   I was using rect.x and got misaligned reads on
                    //   any reason != num-screens.
                    var extHdr = await ReadFullAsync(stream, 4, ct).ConfigureAwait(false);
                    var nScreens = extHdr[0];
                    if (nScreens > 0)
                    {
                        await ReadFullAsync(stream, nScreens * 16, ct).ConfigureAwait(false);
                    }
                    Width = w;
                    Height = h;
                    DesktopResized?.Invoke(w, h);
                    break;
                }
                default:
                    throw new VncProtocolException("Unhandled encoding " + enc + " — request SetEncodings narrower");
            }
        }
    }

    // -- Stream helpers --------------------------------------------------

    private static async Task<byte[]> ReadFullAsync(Stream s, int n, CancellationToken ct)
    {
        var buf = new byte[n];
        await ReadFullAsync(s, buf, ct).ConfigureAwait(false);
        return buf;
    }

    private static async Task ReadFullAsync(Stream s, byte[] buf, CancellationToken ct)
    {
        var off = 0;
        while (off < buf.Length)
        {
            var n = await s.ReadAsync(buf.AsMemory(off, buf.Length - off), ct).ConfigureAwait(false);
            if (n <= 0) throw new EndOfStreamException("VNC server closed mid-message");
            off += n;
        }
    }

    private static uint ReadU32BE(byte[] b) =>
        ((uint)b[0] << 24) | ((uint)b[1] << 16) | ((uint)b[2] << 8) | b[3];
}

public enum RectKind { Raw, CopyRect }

public sealed record RectUpdate(
    int X, int Y, int W, int H,
    RectKind Kind,
    byte[] Pixels,      // Raw: w*h*4 BGRA bytes; CopyRect: empty
    int SrcX, int SrcY); // CopyRect only

public sealed class VncProtocolException : Exception
{
    public VncProtocolException(string msg) : base(msg) { }
}
