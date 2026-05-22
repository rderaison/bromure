using System.Text;
using Bromure.AC.Mitm.WebSocket;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class WsMessageAssemblerTests
{
    [Fact]
    public void Single_text_frame_emits_one_message()
    {
        using var asm = new WsMessageAssembler(false, false);
        var frame = BuildFrame(fin: true, opcode: 0x1, "hello");
        var msgs = asm.Feed(frame).ToArray();
        msgs.Should().HaveCount(1);
        msgs[0].Kind.Should().Be(WsMessageAssembler.MessageKind.Text);
        Encoding.UTF8.GetString(msgs[0].Payload).Should().Be("hello");
    }

    [Fact]
    public void Fragmented_text_message_reassembles_across_continuation_frames()
    {
        using var asm = new WsMessageAssembler(false, false);
        var first = BuildFrame(fin: false, opcode: 0x1, "Hello, ");
        var middle = BuildFrame(fin: false, opcode: 0x0, "Realtime ");
        var last = BuildFrame(fin: true, opcode: 0x0, "world");
        var combined = first.Concat(middle).Concat(last).ToArray();

        var msgs = asm.Feed(combined).ToArray();
        msgs.Should().HaveCount(1);
        Encoding.UTF8.GetString(msgs[0].Payload).Should().Be("Hello, Realtime world");
    }

    [Fact]
    public void Control_frames_emit_with_their_kind()
    {
        using var asm = new WsMessageAssembler(false, false);
        var ping = BuildFrame(fin: true, opcode: 0x9, "ping-payload");
        var msgs = asm.Feed(ping).ToArray();
        msgs.Should().HaveCount(1);
        msgs[0].Kind.Should().Be(WsMessageAssembler.MessageKind.Ping);
    }

    [Fact]
    public void Realtime_response_completed_message_is_reassembled()
    {
        // Real-world shape: text frame, JSON object, type=response.completed.
        var json = """
            {"type":"response.completed","response":{"id":"resp_xyz","model":"gpt-4o","usage":{"input_tokens":42,"output_tokens":7}}}
            """;
        using var asm = new WsMessageAssembler(false, false);
        var frame = BuildFrame(fin: true, opcode: 0x1, json);
        var msgs = asm.Feed(frame).ToArray();
        msgs.Should().HaveCount(1);
        msgs[0].Kind.Should().Be(WsMessageAssembler.MessageKind.Text);

        // The tap consumes this and counts it.
        var tap = new RealtimeEventTap(Guid.NewGuid(), "api.openai.com",
            "/v1/realtime", 101);
        tap.StreamedAnyEvents.Should().BeFalse();
        tap.Handle(msgs[0]);
        tap.StreamedAnyEvents.Should().BeTrue();
        tap.StreamedResponseCount.Should().Be(1);
    }

    [Fact]
    public void RealtimeEventTap_ShouldTap_matches_openai_hosts()
    {
        RealtimeEventTap.ShouldTap("api.openai.com").Should().BeTrue();
        RealtimeEventTap.ShouldTap("chatgpt.com").Should().BeTrue();
        RealtimeEventTap.ShouldTap("eu.api.openai.com").Should().BeTrue();
        RealtimeEventTap.ShouldTap("api.anthropic.com").Should().BeFalse();
        RealtimeEventTap.ShouldTap("apple.com").Should().BeFalse();
    }

    [Fact]
    public void RealtimeEventTap_ignores_non_response_completed_messages()
    {
        var tap = new RealtimeEventTap(Guid.NewGuid(), "api.openai.com", "/", 101);
        var heartbeat = """{"type":"session.created","session":{}}""";
        tap.Handle(new WsMessageAssembler.Message(
            WsMessageAssembler.MessageKind.Text,
            Encoding.UTF8.GetBytes(heartbeat)));
        tap.Handle(new WsMessageAssembler.Message(
            WsMessageAssembler.MessageKind.Binary,
            new byte[] { 0x01, 0x02 }));
        tap.StreamedAnyEvents.Should().BeFalse();
    }

    [Fact]
    public void PermessageDeflate_NegotiatedExtension_InflatesPayload()
    {
        // RFC 7692 wire payload: raw DEFLATE stream of the message
        // bytes, with the trailing 0x00 0x00 0xFF 0xFF marker
        // stripped by the sender. We rebuild that exact framing
        // here and confirm the assembler's WsInflater path
        // reconstructs the original text.
        using var asm = new WsMessageAssembler(
            permessageDeflateNegotiated: true,
            serverNoContextTakeover: true);

        var original = "Hello, deflated WebSocket world! "
                       + new string('x', 200);   // make compression observable
        var deflated = RawDeflateWithTrailerStripped(Encoding.UTF8.GetBytes(original));

        // Rsv1 set on the FIN text frame signals "this payload was
        // compressed with permessage-deflate".
        var frame = BuildFrameRaw(fin: true, rsv1: true, opcode: 0x1, payload: deflated);

        var msgs = asm.Feed(frame).ToArray();
        msgs.Should().HaveCount(1);
        msgs[0].Kind.Should().Be(WsMessageAssembler.MessageKind.Text);
        Encoding.UTF8.GetString(msgs[0].Payload).Should().Be(original);
        deflated.Length.Should().BeLessThan(original.Length,
            "the deflated payload should be shorter than the original — proves we actually compressed");
    }

    [Fact]
    public void PermessageDeflate_NotNegotiated_DropsRsv1Frame()
    {
        // Server set Rsv1 but the extension wasn't negotiated → the
        // assembler must drop the frame (it can't safely emit
        // compressed bytes as if they were plaintext).
        using var asm = new WsMessageAssembler(
            permessageDeflateNegotiated: false,
            serverNoContextTakeover: false);
        var frame = BuildFrameRaw(fin: true, rsv1: true, opcode: 0x1,
            payload: new byte[] { 0xAB, 0xCD });
        var msgs = asm.Feed(frame).ToArray();
        msgs.Should().BeEmpty();
    }

    /// <summary>RFC 7692 §7.2.2 wire shape: raw DEFLATE bytes with the
    /// trailing <c>0x00 0x00 0xFF 0xFF</c> stripped by the sender. We
    /// reproduce that here so the assembler's inflater (which appends
    /// the marker before feeding zlib) round-trips cleanly.</summary>
    private static byte[] RawDeflateWithTrailerStripped(byte[] plain)
    {
        using var ms = new System.IO.MemoryStream();
        using (var deflate = new System.IO.Compression.DeflateStream(
            ms, System.IO.Compression.CompressionLevel.Optimal, leaveOpen: true))
        {
            deflate.Write(plain, 0, plain.Length);
        }
        var bytes = ms.ToArray();
        // DEFLATE doesn't append the 0x00 0x00 0xFF 0xFF marker on
        // its own — only zlib + permessage-deflate's framing do. So
        // we just return the raw DEFLATE bytes; the inflater under
        // test appends 0x00 0x00 0xFF 0xFF before decompressing.
        return bytes;
    }

    /// <summary>Build a (server→client, unmasked) WebSocket frame.</summary>
    private static byte[] BuildFrame(bool fin, byte opcode, string text)
    {
        var payload = Encoding.UTF8.GetBytes(text);
        return BuildFrameRaw(fin, rsv1: false, opcode, payload);
    }

    private static byte[] BuildFrameRaw(bool fin, bool rsv1, byte opcode, byte[] payload)
    {
        var b0 = (byte)((fin ? 0x80 : 0) | (rsv1 ? 0x40 : 0) | (opcode & 0x0F));
        // Server-to-client frames are unmasked. Length encoding:
        //   <= 125 → 1 byte; <= 65535 → 126 + 2 BE bytes; else 127 + 8 BE.
        if (payload.Length <= 125)
        {
            var buf = new byte[2 + payload.Length];
            buf[0] = b0;
            buf[1] = (byte)payload.Length;
            Buffer.BlockCopy(payload, 0, buf, 2, payload.Length);
            return buf;
        }
        else if (payload.Length <= 65535)
        {
            var buf = new byte[4 + payload.Length];
            buf[0] = b0;
            buf[1] = 126;
            buf[2] = (byte)((payload.Length >> 8) & 0xFF);
            buf[3] = (byte)(payload.Length & 0xFF);
            Buffer.BlockCopy(payload, 0, buf, 4, payload.Length);
            return buf;
        }
        else
        {
            var buf = new byte[10 + payload.Length];
            buf[0] = b0;
            buf[1] = 127;
            for (var i = 0; i < 8; i++)
            {
                buf[2 + i] = (byte)((payload.LongLength >> ((7 - i) * 8)) & 0xFF);
            }
            Buffer.BlockCopy(payload, 0, buf, 10, payload.Length);
            return buf;
        }
    }
}
