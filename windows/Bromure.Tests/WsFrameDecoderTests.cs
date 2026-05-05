using System.Buffers.Binary;
using System.Text;
using Bromure.AC.Mitm.WebSocket;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class WsFrameDecoderTests
{
    [Fact]
    public void NextFrame_DecodesSingleUnmaskedTextFrame()
    {
        // FIN=1, RSV=0, opcode=1 (text), mask=0, len=5, "hello"
        var bytes = new byte[] { 0x81, 0x05, (byte)'h', (byte)'e', (byte)'l', (byte)'l', (byte)'o' };
        var d = new WsFrameDecoder();
        d.Feed(bytes);
        var frame = d.NextFrame();
        frame.Should().NotBeNull();
        frame!.Fin.Should().BeTrue();
        frame.Opcode.Should().Be((byte)1);
        Encoding.ASCII.GetString(frame.Payload).Should().Be("hello");
    }

    [Fact]
    public void NextFrame_UnmasksClientFrame()
    {
        // Client frames are masked. mask=4 bytes, payload XOR mask cycle.
        var mask = new byte[] { 0xAA, 0xBB, 0xCC, 0xDD };
        var clear = "ping"u8.ToArray();
        var masked = new byte[clear.Length];
        for (var i = 0; i < clear.Length; i++) masked[i] = (byte)(clear[i] ^ mask[i % 4]);
        var bytes = new byte[]
        {
            0x81,                // FIN+text
            (byte)(0x80 | 4),    // mask flag + len
            mask[0], mask[1], mask[2], mask[3],
            masked[0], masked[1], masked[2], masked[3],
        };
        var d = new WsFrameDecoder();
        d.Feed(bytes);
        var frame = d.NextFrame();
        frame.Should().NotBeNull();
        Encoding.ASCII.GetString(frame!.Payload).Should().Be("ping");
    }

    [Fact]
    public void NextFrame_SplitFeedReassembles()
    {
        var bytes = new byte[] { 0x81, 0x03, (byte)'a', (byte)'b', (byte)'c' };
        var d = new WsFrameDecoder();
        d.Feed(bytes.AsSpan(0, 2));
        d.NextFrame().Should().BeNull();
        d.Feed(bytes.AsSpan(2, 3));
        var frame = d.NextFrame();
        frame.Should().NotBeNull();
        Encoding.ASCII.GetString(frame!.Payload).Should().Be("abc");
    }

    [Fact]
    public void NextFrame_ExtendedLength16BitPayload()
    {
        var payload = new byte[200];
        for (var i = 0; i < payload.Length; i++) payload[i] = (byte)(i & 0xFF);
        var bytes = new byte[2 + 2 + payload.Length];
        bytes[0] = 0x82; // FIN + binary
        bytes[1] = 126;
        BinaryPrimitives.WriteUInt16BigEndian(bytes.AsSpan(2, 2), (ushort)payload.Length);
        Buffer.BlockCopy(payload, 0, bytes, 4, payload.Length);
        var d = new WsFrameDecoder();
        d.Feed(bytes);
        var frame = d.NextFrame();
        frame.Should().NotBeNull();
        frame!.Payload.Should().Equal(payload);
    }

    [Fact]
    public void NextFrame_HugeLengthIsRejected()
    {
        // u64 length = 0xFFFFFFFFFFFFFFFF — synthetic close frame returned.
        var bytes = new byte[2 + 8];
        bytes[0] = 0x82;
        bytes[1] = 127;
        for (var i = 0; i < 8; i++) bytes[2 + i] = 0xFF;
        var d = new WsFrameDecoder();
        d.Feed(bytes);
        var frame = d.NextFrame();
        frame.Should().NotBeNull();
        frame!.Opcode.Should().Be((byte)0x8);
    }
}
