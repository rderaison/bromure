using System.Text;
using Bromure.AC.Mitm.WebSocket;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class WsTranscriptTests
{
    /// <summary>One unmasked text frame ('hi') as raw WS bytes:
    /// FIN=1, opcode=1, payload-len=2, no mask. Reused by tests
    /// that don't care about correctness of the high-bit framing,
    /// only that the assembler decodes a TEXT message.</summary>
    private static byte[] OneTextFrame(string payload)
    {
        var p = Encoding.UTF8.GetBytes(payload);
        var f = new byte[2 + p.Length];
        f[0] = 0x81;            // FIN | opcode=1 (text)
        f[1] = (byte)p.Length;  // mask=0, len=N
        Buffer.BlockCopy(p, 0, f, 2, p.Length);
        return f;
    }

    [Fact]
    public void Renderer_emits_header_and_chronological_arrows()
    {
        var c2u = new WsTranscriptCollector(WsTranscriptCollector.Direction.ClientToUpstream, false, false);
        var u2c = new WsTranscriptCollector(WsTranscriptCollector.Direction.UpstreamToClient, false, false);
        c2u.Feed(OneTextFrame("from-client"));
        // Sleep a hair so timestamps order deterministically. Real
        // sessions get tens of microseconds between frames; the
        // collector uses DateTimeOffset.UtcNow so ticks resolve.
        Thread.Sleep(2);
        u2c.Feed(OneTextFrame("from-server"));
        var rendered = WsTranscriptRenderer.Render(c2u, u2c);
        var text = Encoding.UTF8.GetString(rendered);
        text.Should().StartWith("--- WebSocket session transcript ---\n");
        var c2uIdx = text.IndexOf(">>>", StringComparison.Ordinal);
        var u2cIdx = text.IndexOf("<<<", StringComparison.Ordinal);
        c2uIdx.Should().BeGreaterThan(0);
        u2cIdx.Should().BeGreaterThan(c2uIdx, "client→upstream record was fed first");
        text.Should().Contain("from-client").And.Contain("from-server");
    }

    [Fact]
    public void Renderer_handles_empty_session()
    {
        var c2u = new WsTranscriptCollector(WsTranscriptCollector.Direction.ClientToUpstream, false, false);
        var u2c = new WsTranscriptCollector(WsTranscriptCollector.Direction.UpstreamToClient, false, false);
        var text = Encoding.UTF8.GetString(WsTranscriptRenderer.Render(c2u, u2c));
        text.Should().Contain("(no application frames observed before close)");
    }

    [Fact]
    public void Collector_caps_at_max_messages()
    {
        var c = new WsTranscriptCollector(WsTranscriptCollector.Direction.ClientToUpstream, false, false);
        // Concat enough frames to exceed MaxMessages. One byte
        // payload per frame keeps the test cheap.
        var oneFrame = OneTextFrame("x");
        var bulk = new byte[oneFrame.Length * (WsTranscriptCollector.MaxMessages + 50)];
        for (var i = 0; i < WsTranscriptCollector.MaxMessages + 50; i++)
        {
            Buffer.BlockCopy(oneFrame, 0, bulk, i * oneFrame.Length, oneFrame.Length);
        }
        c.Feed(bulk);
        c.Records.Count.Should().BeLessThanOrEqualTo(WsTranscriptCollector.MaxMessages);
    }

    [Fact]
    public void FeedWithTap_forwards_only_new_messages()
    {
        var c = new WsTranscriptCollector(WsTranscriptCollector.Direction.UpstreamToClient, false, false);
        var seen = new List<string>();
        c.FeedWithTap(OneTextFrame("first"), m =>
        {
            if (m.Kind == WsMessageAssembler.MessageKind.Text)
                seen.Add(Encoding.UTF8.GetString(m.Payload));
        });
        c.FeedWithTap(OneTextFrame("second"), m =>
        {
            if (m.Kind == WsMessageAssembler.MessageKind.Text)
                seen.Add(Encoding.UTF8.GetString(m.Payload));
        });
        seen.Should().Equal(new[] { "first", "second" });
    }
}
