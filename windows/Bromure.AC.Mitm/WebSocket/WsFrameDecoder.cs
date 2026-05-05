namespace Bromure.AC.Mitm.WebSocket;

/// <summary>
/// Direct port of <c>WSFrameDecoder</c> from
/// <c>Sources/AgentCoding/Mitm/WebSocketTrace.swift</c>.
///
/// <para>RFC 6455 frame parser. Feed it raw bytes (plaintext, post-TLS)
/// as they arrive on one side of a MITM'd WebSocket; pull complete
/// frames out via <see cref="NextFrame"/> until it returns null.
/// Stateful — the parser holds whatever bytes it couldn't yet form into
/// a frame.</para>
///
/// <para>Used only by the MITM tracing path; the proxy itself still
/// pumps raw bytes through opaquely. A parse failure here can degrade
/// trace fidelity but cannot stall or corrupt the WS tunnel.</para>
/// </summary>
public sealed class WsFrameDecoder
{
    public sealed record Frame(bool Fin, bool Rsv1, byte Opcode, byte[] Payload);

    /// <summary>Cap per-frame payload at 64 MB so a fuzzed length can't blow memory.</summary>
    private const int MaxFrameBytes = 64 * 1024 * 1024;

    private readonly List<byte> _buffer = new();

    public void Feed(ReadOnlySpan<byte> bytes)
    {
        foreach (var b in bytes) _buffer.Add(b);
    }

    public void Feed(byte[] bytes) => Feed(bytes.AsSpan());

    public Frame? NextFrame()
    {
        if (_buffer.Count < 2) return null;
        var b0 = _buffer[0];
        var b1 = _buffer[1];
        var fin = (b0 & 0x80) != 0;
        var rsv1 = (b0 & 0x40) != 0;
        var opcode = (byte)(b0 & 0x0F);
        var masked = (b1 & 0x80) != 0;
        var len7 = b1 & 0x7F;

        var headerSize = 2;
        long length = len7;
        if (len7 == 126)
        {
            if (_buffer.Count < headerSize + 2) return null;
            length = (long)((_buffer[2] << 8) | _buffer[3]);
            headerSize += 2;
        }
        else if (len7 == 127)
        {
            if (_buffer.Count < headerSize + 8) return null;
            length = 0;
            for (var i = 0; i < 8; i++)
            {
                length = (length << 8) | _buffer[2 + i];
            }
            headerSize += 8;
        }

        if (length < 0 || length > MaxFrameBytes)
        {
            _buffer.Clear();
            return new Frame(true, false, 0x8, Array.Empty<byte>());
        }

        var maskKey = new byte[4];
        if (masked)
        {
            if (_buffer.Count < headerSize + 4) return null;
            for (var i = 0; i < 4; i++) maskKey[i] = _buffer[headerSize + i];
            headerSize += 4;
        }

        if (_buffer.Count < headerSize + length) return null;
        var payload = new byte[length];
        for (var i = 0; i < length; i++)
        {
            payload[i] = masked
                ? (byte)(_buffer[headerSize + i] ^ maskKey[i % 4])
                : _buffer[headerSize + i];
        }
        _buffer.RemoveRange(0, (int)(headerSize + length));
        return new Frame(fin, rsv1, opcode, payload);
    }
}
