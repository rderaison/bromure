// macos-source: Sources/AgentCoding/Mitm/WebSocketTrace.swift @ e5f95ab9ee6d
namespace Bromure.AC.Mitm.WebSocket;

/// <summary>
/// Reassembles complete WebSocket messages from raw stream bytes.
/// Wraps <see cref="WsFrameDecoder"/> (frame parsing) and
/// <see cref="WsInflater"/> (permessage-deflate decompression) so
/// callers see one event per logical message instead of N frames.
///
/// <para>Used inside <c>HttpMitmProxy.HandleWebSocketUpgradeAsync</c>
/// on the upstream→client direction so taps like
/// <see cref="RealtimeEventTap"/> can inspect each assembled
/// message. Bytes are still pumped through unmodified — the
/// assembler observes, doesn't intercept.</para>
/// </summary>
public sealed class WsMessageAssembler : IDisposable
{
    public enum MessageKind { Text, Binary, Close, Ping, Pong, Continuation }

    public sealed record Message(MessageKind Kind, byte[] Payload);

    private readonly WsFrameDecoder _frames = new();
    private readonly WsInflater? _inflater;

    private byte _pendingOpcode;          // first frame's opcode
    private bool _pendingCompressed;      // first frame had Rsv1
    private readonly List<byte[]> _pendingPayloads = new();

    /// <param name="permessageDeflateNegotiated">
    /// Was the WS handshake settled with <c>permessage-deflate</c>?
    /// True when the upstream's 101 response carried a
    /// <c>Sec-WebSocket-Extensions: permessage-deflate</c> header.
    /// </param>
    /// <param name="serverNoContextTakeover">
    /// True iff the negotiated extension carried
    /// <c>server_no_context_takeover</c> — the inflater must reset
    /// its zlib context after each message.
    /// </param>
    public WsMessageAssembler(bool permessageDeflateNegotiated, bool serverNoContextTakeover)
    {
        if (permessageDeflateNegotiated)
        {
            _inflater = new WsInflater(noContextTakeover: serverNoContextTakeover);
        }
    }

    /// <summary>
    /// Feed raw bytes from the stream. Returns every COMPLETE message
    /// the bytes finished — control frames (ping/pong/close) are
    /// emitted with their own kind; text/binary frames are reassembled
    /// across continuation frames.
    /// </summary>
    public IEnumerable<Message> Feed(ReadOnlySpan<byte> bytes)
    {
        _frames.Feed(bytes);
        var produced = new List<Message>();
        while (true)
        {
            var f = _frames.NextFrame();
            if (f is null) break;
            switch (f.Opcode)
            {
                case 0x8:  // close
                    produced.Add(new Message(MessageKind.Close, f.Payload));
                    break;
                case 0x9:  // ping
                    produced.Add(new Message(MessageKind.Ping, f.Payload));
                    break;
                case 0xA:  // pong
                    produced.Add(new Message(MessageKind.Pong, f.Payload));
                    break;
                case 0x0:  // continuation
                    if (_pendingPayloads.Count == 0) break;  // protocol error — drop
                    _pendingPayloads.Add(f.Payload);
                    if (f.Fin)
                    {
                        var msg = AssemblePending();
                        if (msg is not null) produced.Add(msg);
                    }
                    break;
                case 0x1:  // text
                case 0x2:  // binary
                    if (f.Fin && _pendingPayloads.Count == 0)
                    {
                        var data = MaybeInflate(f.Payload, f.Rsv1);
                        if (data is null) break;
                        produced.Add(new Message(
                            f.Opcode == 0x1 ? MessageKind.Text : MessageKind.Binary,
                            data));
                    }
                    else
                    {
                        // Start of a fragmented message (or stray
                        // start of a new message while previous still
                        // outstanding — treat the older one as lost).
                        _pendingPayloads.Clear();
                        _pendingOpcode = f.Opcode;
                        _pendingCompressed = f.Rsv1;
                        _pendingPayloads.Add(f.Payload);
                        if (f.Fin)
                        {
                            var msg = AssemblePending();
                            if (msg is not null) produced.Add(msg);
                        }
                    }
                    break;
            }
        }
        return produced;
    }

    private Message? AssemblePending()
    {
        var total = _pendingPayloads.Sum(p => p.Length);
        var combined = new byte[total];
        var pos = 0;
        foreach (var p in _pendingPayloads)
        {
            Buffer.BlockCopy(p, 0, combined, pos, p.Length);
            pos += p.Length;
        }
        var opcode = _pendingOpcode;
        var compressed = _pendingCompressed;
        _pendingPayloads.Clear();
        _pendingOpcode = 0;
        _pendingCompressed = false;
        var data = MaybeInflate(combined, compressed);
        if (data is null) return null;
        return new Message(
            opcode == 0x1 ? MessageKind.Text : MessageKind.Binary,
            data);
    }

    private byte[]? MaybeInflate(byte[] payload, bool rsv1)
    {
        if (!rsv1) return payload;
        if (_inflater is null) return null;  // server set Rsv1 but extension wasn't negotiated → drop
        return _inflater.Inflate(payload);
    }

    public void Dispose() => _inflater?.Dispose();
}
