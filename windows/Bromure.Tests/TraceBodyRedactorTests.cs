using System.Text;
using Bromure.AC.Mitm.Trace;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class TraceBodyRedactorTests
{
    [Theory]
    [InlineData("authorization")]
    [InlineData("proxy-authorization")]
    [InlineData("cookie")]
    [InlineData("set-cookie")]
    [InlineData("x-amz-security-token")]
    [InlineData("x-goog-iap-jwt-assertion")]
    [InlineData("api-key")]
    [InlineData("x-api-key")]
    [InlineData("anthropic-api-key")]
    [InlineData("openai-api-key")]
    public void IsSensitiveHeader_matches_known_secrets(string lowered)
    {
        TraceBodyRedactor.IsSensitiveHeader(lowered).Should().BeTrue();
    }

    [Theory]
    [InlineData("content-type")]
    [InlineData("user-agent")]
    [InlineData("host")]
    [InlineData("accept")]
    public void IsSensitiveHeader_does_not_match_safe_headers(string lowered)
    {
        TraceBodyRedactor.IsSensitiveHeader(lowered).Should().BeFalse();
    }

    [Fact]
    public void RedactSensitiveHeaders_replaces_authorization_value()
    {
        var raw = Encoding.ASCII.GetBytes(
            "POST /v1/messages HTTP/1.1\r\n" +
            "Host: api.anthropic.com\r\n" +
            "Authorization: Bearer sk-ant-real-token-xxx\r\n" +
            "Content-Type: application/json\r\n" +
            "\r\n" +
            "{\"model\":\"claude\"}");
        var redacted = Encoding.ASCII.GetString(TraceBodyRedactor.RedactSensitiveHeaders(raw));
        redacted.Should().Contain("Authorization: <redacted>");
        redacted.Should().NotContain("sk-ant-real-token-xxx");
        // Body untouched.
        redacted.Should().EndWith("{\"model\":\"claude\"}");
        // Other headers preserved verbatim.
        redacted.Should().Contain("Content-Type: application/json");
    }

    [Fact]
    public void RedactSensitiveHeaders_redacts_cookie_and_apikey_variants()
    {
        var raw = Encoding.ASCII.GetBytes(
            "GET / HTTP/1.1\r\n" +
            "Cookie: session=abc\r\n" +
            "X-API-Key: my-secret\r\n" +
            "Anthropic-API-Key: sk-ant-key\r\n" +
            "\r\n");
        var redacted = Encoding.ASCII.GetString(TraceBodyRedactor.RedactSensitiveHeaders(raw));
        redacted.Should().NotContain("session=abc")
            .And.NotContain("my-secret")
            .And.NotContain("sk-ant-key");
        redacted.Should().Contain("Cookie: <redacted>")
            .And.Contain("X-API-Key: <redacted>")
            .And.Contain("Anthropic-API-Key: <redacted>");
    }

    [Fact]
    public void BodyForTrace_keeps_text_and_json_responses()
    {
        var raw = Encoding.ASCII.GetBytes(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"ok\":true}");
        TraceBodyRedactor.BodyForTrace(raw).Should().NotBeNull();
    }

    [Fact]
    public void BodyForTrace_keeps_sse_responses()
    {
        var raw = Encoding.ASCII.GetBytes(
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata: hi\n\n");
        TraceBodyRedactor.BodyForTrace(raw).Should().NotBeNull();
    }

    [Fact]
    public void BodyForTrace_drops_binary_responses()
    {
        var raw = Encoding.ASCII.GetBytes(
            "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n\r\nPNG\r\n");
        TraceBodyRedactor.BodyForTrace(raw).Should().BeNull();
    }

    [Fact]
    public void BodyForTrace_drops_oversized_payloads()
    {
        var head = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n\r\n";
        var raw = new byte[TraceBodyRedactor.PerRecordCap + 1];
        // A perfectly text-typed but ginormous body still goes overboard.
        var headBytes = Encoding.ASCII.GetBytes(head);
        Buffer.BlockCopy(headBytes, 0, raw, 0, headBytes.Length);
        TraceBodyRedactor.BodyForTrace(raw).Should().BeNull();
    }

    [Fact]
    public void BodyForTrace_keeps_body_when_no_content_type()
    {
        var raw = Encoding.ASCII.GetBytes(
            "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n");
        TraceBodyRedactor.BodyForTrace(raw).Should().NotBeNull();
    }
}
