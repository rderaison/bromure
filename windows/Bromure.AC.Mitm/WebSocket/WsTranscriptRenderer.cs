// macos-source: Sources/AgentCoding/Mitm/WebSocketTrace.swift @ e5f95ab9ee6d
using System.Text;

namespace Bromure.AC.Mitm.WebSocket;

/// <summary>
/// Format two <see cref="WsTranscriptCollector"/> instances (one per
/// direction) into a single chronologically-ordered text transcript.
/// Output layout matches macOS exactly so the conversation parser
/// (and any human reader) can consume artifacts from either platform.
/// </summary>
public static class WsTranscriptRenderer
{
    private const string Header = "--- WebSocket session transcript ---\n";

    public static byte[] Render(WsTranscriptCollector c2u, WsTranscriptCollector u2c)
    {
        var all = c2u.Records.Concat(u2c.Records).OrderBy(r => r.Timestamp).ToList();
        var sb = new StringBuilder();
        sb.Append(Header);
        if (all.Count == 0)
        {
            sb.Append("(no application frames observed before close)\n");
            return Encoding.UTF8.GetBytes(sb.ToString());
        }
        foreach (var r in all)
        {
            var arrow = r.Direction == WsTranscriptCollector.Direction.ClientToUpstream
                ? ">>>" : "<<<";
            var truncMark = r.Truncated ? $" (truncated, total {r.TotalBytes} bytes)" : "";
            sb.Append($"{arrow} [{r.Timestamp:O}] {r.Kind.ToString().ToUpperInvariant()} {r.TotalBytes}B{truncMark}\n");
            switch (r.Kind)
            {
                case WsMessageAssembler.MessageKind.Text:
                    AppendUtf8WithReplacement(r.Payload, sb);
                    break;
                case WsMessageAssembler.MessageKind.Close:
                    if (r.Payload.Length >= 2)
                    {
                        var code = (ushort)((r.Payload[0] << 8) | r.Payload[1]);
                        var reason = r.Payload.Length > 2
                            ? Encoding.UTF8.GetString(r.Payload, 2, r.Payload.Length - 2)
                            : "";
                        sb.Append($"code={code} \"{reason}\"\n");
                    }
                    else
                    {
                        sb.Append("(empty close payload)\n");
                    }
                    break;
                case WsMessageAssembler.MessageKind.Binary:
                case WsMessageAssembler.MessageKind.Ping:
                case WsMessageAssembler.MessageKind.Pong:
                    if (LooksLikeText(r.Payload)) AppendUtf8WithReplacement(r.Payload, sb);
                    else
                    {
                        var take = Math.Min(256, r.Payload.Length);
                        for (var i = 0; i < take; i++) sb.Append(r.Payload[i].ToString("x2"));
                        sb.Append('\n');
                    }
                    break;
                default:
                    sb.Append("(unknown frame)\n");
                    break;
            }
        }
        return Encoding.UTF8.GetBytes(sb.ToString());
    }

    private static void AppendUtf8WithReplacement(byte[] bytes, StringBuilder sb)
    {
        // U+FFFD replacement for invalid sequences — matches macOS's
        // String(decoding:as:) behavior. The inspector decodes the
        // whole transcript as UTF-8; one bad byte from a mid-codepoint
        // truncation must not turn the whole record into "(binary N
        // bytes)".
        var s = Encoding.UTF8.GetString(bytes);
        sb.Append(s);
        if (bytes.Length == 0 || bytes[^1] != 0x0A) sb.Append('\n');
    }

    private static bool LooksLikeText(byte[] bytes)
    {
        // Ratio-based heuristic: consider it text if 95%+ of bytes
        // are printable ASCII or common whitespace. Mirrors macOS.
        if (bytes.Length == 0) return false;
        var printable = 0;
        var sample = Math.Min(bytes.Length, 1024);
        for (var i = 0; i < sample; i++)
        {
            var b = bytes[i];
            if ((b >= 0x20 && b <= 0x7E) || b == 0x09 || b == 0x0A || b == 0x0D) printable++;
            else if (b >= 0x80) printable++;  // assume UTF-8 continuation/start
        }
        return printable * 100 / sample >= 95;
    }
}
