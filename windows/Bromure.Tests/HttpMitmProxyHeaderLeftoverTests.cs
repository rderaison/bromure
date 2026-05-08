using System.Text;
using Bromure.AC.Mitm.Proxy;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Regression coverage for the "header read consumes body bytes"
/// bug. TLS frequently bundles the response header and the first
/// chunk of the body into the same record; the proxy MUST keep those
/// post-header bytes or the body downstream is short by N bytes and
/// curl prints "transfer closed with N bytes remaining".
/// </summary>
public class HttpMitmProxyHeaderLeftoverTests
{
    [Fact]
    public async Task Header_only_reads_return_empty_leftover()
    {
        var bytes = Encoding.ASCII.GetBytes(
            "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n");
        using var ms = new MemoryStream(bytes);
        var (header, leftover) = await HttpMitmProxy
            .ReadHttpHeaderWithLeftoverAsync(ms, 8192, CancellationToken.None);
        header.Should().NotBeNull().And.Contain("Content-Length: 5");
        leftover.Should().BeEmpty();
    }

    [Fact]
    public async Task Body_bytes_in_same_read_returned_as_leftover()
    {
        // Headers + 5-byte body in one TCP read — what TLS aggregation
        // produces in production.
        var bytes = Encoding.ASCII.GetBytes(
            "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello");
        using var ms = new MemoryStream(bytes);
        var (header, leftover) = await HttpMitmProxy
            .ReadHttpHeaderWithLeftoverAsync(ms, 8192, CancellationToken.None);
        header.Should().Contain("Content-Length: 5");
        Encoding.ASCII.GetString(leftover).Should().Be("hello");
    }

    [Fact]
    public async Task Header_split_across_reads_still_finds_terminator()
    {
        // Reader that hands out the header in two parts to simulate a
        // small initial TCP packet.
        var bytes = Encoding.ASCII.GetBytes(
            "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc");
        using var ms = new ChunkyMemoryStream(bytes, firstChunk: 10);
        var (header, leftover) = await HttpMitmProxy
            .ReadHttpHeaderWithLeftoverAsync(ms, 8192, CancellationToken.None);
        header.Should().NotBeNull();
        // The remainder after the header end goes to leftover.
        Encoding.ASCII.GetString(leftover).Should().Be("abc");
    }

    [Fact]
    public async Task Stream_eof_before_terminator_returns_null_header()
    {
        var bytes = Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nIncomplete");
        using var ms = new MemoryStream(bytes);
        var (header, leftover) = await HttpMitmProxy
            .ReadHttpHeaderWithLeftoverAsync(ms, 8192, CancellationToken.None);
        header.Should().BeNull();
        leftover.Should().BeEmpty();
    }

    /// <summary>Stream that hands out exactly <c>firstChunk</c> bytes
    /// on the first read, then the rest. Forces the loop in
    /// <c>ReadHttpHeaderWithLeftoverAsync</c> to round-trip more than
    /// once.</summary>
    private sealed class ChunkyMemoryStream : Stream
    {
        private readonly byte[] _bytes;
        private readonly int _firstChunk;
        private int _pos;
        private bool _firstDone;
        public ChunkyMemoryStream(byte[] bytes, int firstChunk)
        { _bytes = bytes; _firstChunk = firstChunk; }
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default)
        {
            await Task.Yield();
            if (_pos >= _bytes.Length) return 0;
            var max = _firstDone ? _bytes.Length - _pos : Math.Min(_firstChunk, _bytes.Length - _pos);
            var n = Math.Min(buffer.Length, max);
            _bytes.AsSpan(_pos, n).CopyTo(buffer.Span);
            _pos += n;
            _firstDone = true;
            return n;
        }
        public override int Read(byte[] buffer, int offset, int count)
            => ReadAsync(buffer.AsMemory(offset, count)).AsTask().GetAwaiter().GetResult();
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => _bytes.Length;
        public override long Position { get => _pos; set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
