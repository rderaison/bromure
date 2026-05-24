using Bromure.AC.Mitm.Swap;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Coverage for <see cref="TokenSwapper.ReplaceContentLength"/> after
/// the bug-comb finding: when a request had Transfer-Encoding:chunked
/// and the swapper materialised + rewrote the body, the old code
/// inserted a fresh Content-Length but left TE:chunked alongside.
/// RFC 9112 §6.3 makes that a request-smuggling shape; upstreams
/// either reject the request or route ambiguously.
/// </summary>
public class TokenSwapperContentLengthTests
{
    [Fact]
    public void Replaces_existing_content_length_header()
    {
        var input =
            "POST /v1/something HTTP/1.1\r\n" +
            "Host: api.example.com\r\n" +
            "Content-Length: 42\r\n" +
            "\r\n";
        var output = TokenSwapper.ReplaceContentLength(input, 100);
        output.Should().Contain("Content-Length: 100");
        output.Should().NotContain("Content-Length: 42");
    }

    [Fact]
    public void Inserts_content_length_when_missing()
    {
        var input =
            "GET / HTTP/1.1\r\n" +
            "Host: api.example.com\r\n" +
            "\r\n";
        var output = TokenSwapper.ReplaceContentLength(input, 0);
        output.Should().Contain("Content-Length: 0");
    }

    [Fact]
    public void Strips_transfer_encoding_when_present()
    {
        // Body has been re-materialised + swapped → CL is now the
        // correct framing. Leaving TE:chunked is the canonical
        // request-smuggling shape upstreams reject.
        var input =
            "POST /v1/upload HTTP/1.1\r\n" +
            "Host: api.example.com\r\n" +
            "Transfer-Encoding: chunked\r\n" +
            "Authorization: Bearer foo\r\n" +
            "\r\n";
        var output = TokenSwapper.ReplaceContentLength(input, 128);
        output.Should().Contain("Content-Length: 128");
        output.Should().NotContain("Transfer-Encoding:");
        output.Should().Contain("Authorization: Bearer foo", "the other headers are preserved");
    }

    [Fact]
    public void Strips_transfer_encoding_case_insensitive()
    {
        var input =
            "POST / HTTP/1.1\r\n" +
            "transfer-encoding: chunked\r\n" +
            "\r\n";
        var output = TokenSwapper.ReplaceContentLength(input, 7);
        output.Should().NotContain("transfer-encoding");
        output.Should().NotContain("Transfer-Encoding");
    }
}
