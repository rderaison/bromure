// macos-source: Sources/AgentCoding/Mitm/WebSocketTrace.swift @ e5f95ab9ee6d
namespace Bromure.AC.Mitm.WebSocket;

/// <summary>
/// Per-direction transcript collector. Wraps <see cref="WsMessageAssembler"/>
/// and records each fully-assembled message (data and control frames)
/// with arrival timestamp + total wire bytes, so
/// <see cref="WsTranscriptRenderer"/> can interleave both directions
/// chronologically.
/// </summary>
public sealed class WsTranscriptCollector : IDisposable
{
    public enum Direction { ClientToUpstream, UpstreamToClient }

    public sealed record Record(
        Direction Direction,
        DateTimeOffset Timestamp,
        WsMessageAssembler.MessageKind Kind,
        byte[] Payload,
        bool Truncated,
        int TotalBytes);

    /// <summary>1 MB cap per message — matches macOS perMessageCap.</summary>
    public const int PerMessagePreviewCap = 1 * 1024 * 1024;
    /// <summary>4096 messages per direction — matches macOS maxMessages.</summary>
    public const int MaxMessages = 4096;

    private readonly Direction _direction;
    private readonly WsMessageAssembler _assembler;
    private readonly List<Record> _records = new();

    public IReadOnlyList<Record> Records => _records;

    public WsTranscriptCollector(Direction direction,
        bool permessageDeflateNegotiated, bool serverNoContextTakeover)
    {
        _direction = direction;
        _assembler = new WsMessageAssembler(permessageDeflateNegotiated, serverNoContextTakeover);
    }

    /// <summary>Feed raw stream bytes from one direction.</summary>
    public void Feed(ReadOnlySpan<byte> bytes)
    {
        var produced = _assembler.Feed(bytes);
        foreach (var msg in produced)
        {
            if (_records.Count >= MaxMessages) return;
            var preview = msg.Payload.Length > PerMessagePreviewCap
                ? msg.Payload[..PerMessagePreviewCap]
                : msg.Payload;
            _records.Add(new Record(
                Direction: _direction,
                Timestamp: DateTimeOffset.UtcNow,
                Kind: msg.Kind,
                Payload: preview,
                Truncated: msg.Payload.Length > preview.Length,
                TotalBytes: msg.Payload.Length));
        }
    }

    /// <summary>Forward each <see cref="WsMessageAssembler.Message"/> to a
    /// caller-side hook (e.g. <see cref="RealtimeEventTap"/>) so the
    /// existing per-message audit pipeline doesn't need a second
    /// assembler instance.</summary>
    public void FeedWithTap(ReadOnlySpan<byte> bytes, Action<WsMessageAssembler.Message>? onMessage)
    {
        var startCount = _records.Count;
        Feed(bytes);
        if (onMessage is null) return;
        for (var i = startCount; i < _records.Count; i++)
        {
            var r = _records[i];
            onMessage(new WsMessageAssembler.Message(r.Kind, r.Payload));
        }
    }

    public void Dispose() => _assembler.Dispose();
}
