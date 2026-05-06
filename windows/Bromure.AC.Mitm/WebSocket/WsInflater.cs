// macos-source: Sources/AgentCoding/Mitm/WebSocketTrace.swift @ e5f95ab9ee6d
using System.IO.Compression;

namespace Bromure.AC.Mitm.WebSocket;

/// <summary>
/// Direct port of <c>WSInflater</c> from
/// <c>Sources/AgentCoding/Mitm/WebSocketTrace.swift</c>.
///
/// <para>Inflater for RFC 7692 permessage-deflate. .NET's
/// <see cref="DeflateStream"/> is RFC 1951 raw-DEFLATE — exactly what
/// permessage-deflate puts on the wire. RFC 7692 §7.2.2 requires
/// appending <c>00 00 FF FF</c> to each <i>message</i> before
/// inflating (the deflate flush marker the sender stripped off). With
/// <see cref="NoContextTakeover"/>, the LZ77 window is reset between
/// messages; otherwise context persists for cross-message dictionary
/// reuse — modelled here by recreating the stream per call when
/// flagged.</para>
/// </summary>
public sealed class WsInflater : IDisposable
{
    private static readonly byte[] FlushMarker = { 0x00, 0x00, 0xFF, 0xFF };

    public bool NoContextTakeover { get; }
    private MemoryStream? _input;
    private DeflateStream? _stream;

    public WsInflater(bool noContextTakeover)
    {
        NoContextTakeover = noContextTakeover;
    }

    /// <summary>
    /// Inflate one logical message. Caller passes the already-
    /// concatenated payload across continuation frames. Returns the
    /// decompressed bytes, or null on inflate failure (corrupt frame —
    /// trace path degrades silently).
    /// </summary>
    public byte[]? Inflate(ReadOnlySpan<byte> compressed)
    {
        try
        {
            var combined = new byte[compressed.Length + FlushMarker.Length];
            compressed.CopyTo(combined.AsSpan(0, compressed.Length));
            FlushMarker.CopyTo(combined.AsSpan(compressed.Length));

            // Without context-takeover the window resets per message —
            // that means each Inflate call is independent. With
            // context-takeover the same DeflateStream is reused across
            // messages so the LZ77 dictionary persists.
            if (NoContextTakeover || _stream is null)
            {
                _stream?.Dispose();
                _input = new MemoryStream();
                _stream = new DeflateStream(_input, CompressionMode.Decompress, leaveOpen: true);
            }

            _input!.Position = _input.Length;
            _input.Write(combined, 0, combined.Length);
            _input.Position -= combined.Length;

            using var output = new MemoryStream();
            var buffer = new byte[8192];
            int n;
            while ((n = _stream.Read(buffer, 0, buffer.Length)) > 0)
            {
                output.Write(buffer, 0, n);
            }
            return output.ToArray();
        }
        catch (InvalidDataException) { return null; }
        catch (IOException) { return null; }
    }

    public void Dispose()
    {
        _stream?.Dispose();
        _input?.Dispose();
    }
}
