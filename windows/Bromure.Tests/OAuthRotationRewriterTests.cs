using System.Text;
using Bromure.AC.Mitm.OAuth;
using Bromure.AC.Mitm.Swap;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

public class OAuthRotationRewriterTests
{
    [Theory]
    [InlineData("api.anthropic.com", "/oauth/token", OAuthRotationProvider.Claude)]
    [InlineData("console.anthropic.com", "/v1/oauth/token", OAuthRotationProvider.Claude)]
    [InlineData("auth.openai.com", "/oauth/token", OAuthRotationProvider.Codex)]
    [InlineData("chatgpt.com", "/oauth/token/refresh", OAuthRotationProvider.Codex)]
    [InlineData("api.openai.com", "/v1/something-else", null)]
    [InlineData("evil.com", "/oauth/token", null)]
    public void ProviderFor_DispatchesByHostAndPath(string host, string path, OAuthRotationProvider? expected)
    {
        OAuthRotationRewriter.ProviderFor(host, path).Should().Be(expected);
    }

    [Fact]
    public void RewriteClaude_RotatesTokensAndRegistersWithSwapper()
    {
        var swapper = new TokenSwapper(new AlwaysAllowConsentBroker());
        var profile = Guid.NewGuid();
        swapper.SetMap(new TokenMap(Array.Empty<TokenMap.Entry>()), profile);

        var realAccess = "sk-ant-oat01-" + new string('a', 50);
        var realRefresh = "sk-ant-ort01-" + new string('b', 50);
        var jsonBody = $"{{\"access_token\":\"{realAccess}\",\"refresh_token\":\"{realRefresh}\"}}";
        var bodyBytes = Encoding.UTF8.GetBytes(jsonBody);
        var raw = BuildResponse($"Content-Length: {bodyBytes.Length}", bodyBytes);

        var result = OAuthRotationRewriter.Rewrite(raw, OAuthRotationProvider.Claude, profile, swapper);

        result.NewReals.Should().NotBeNull();
        result.NewReals!.AccessToken.Should().Be(realAccess);
        result.NewReals.RefreshToken.Should().Be(realRefresh);

        var output = Encoding.UTF8.GetString(result.Bytes);
        output.Should().NotContain(realAccess);
        output.Should().NotContain(realRefresh);
        output.Should().Contain("sk-ant-oat01-brm-");
        output.Should().Contain("sk-ant-ort01-brm-");

        // Swapper got the new entries — fake should map back to real.
        var entries = swapper.EntriesFor(profile);
        entries.Should().HaveCount(2);
        entries.Should().Contain(e => e.Real == realAccess);
        entries.Should().Contain(e => e.Real == realRefresh);
    }

    [Fact]
    public void RewriteClaude_AlreadyFakeToken_LeavesResponseUnchanged()
    {
        var swapper = new TokenSwapper(new AlwaysAllowConsentBroker());
        var profile = Guid.NewGuid();
        swapper.SetMap(new TokenMap(Array.Empty<TokenMap.Entry>()), profile);

        // Already-rotated body — token starts with "sk-ant-oat01-brm-".
        var jsonBody = "{\"access_token\":\"sk-ant-oat01-brm-fake\",\"refresh_token\":\"sk-ant-ort01-brm-fake\"}";
        var bodyBytes = Encoding.UTF8.GetBytes(jsonBody);
        var raw = BuildResponse($"Content-Length: {bodyBytes.Length}", bodyBytes);

        var result = OAuthRotationRewriter.Rewrite(raw, OAuthRotationProvider.Claude, profile, swapper);

        result.NewReals.Should().BeNull("we don't store fakes as if they were real values");
        result.Bytes.Should().Equal(raw);
    }

    [Fact]
    public void RewriteCodex_JwtAccessAndOpaqueRefresh_BothRotated()
    {
        var swapper = new TokenSwapper(new AlwaysAllowConsentBroker());
        var profile = Guid.NewGuid();
        swapper.SetMap(new TokenMap(Array.Empty<TokenMap.Entry>()), profile);

        var realAccess = "eyJ" + new string('A', 50) + "." + new string('B', 50) + "." + new string('C', 50);
        var realRefresh = "rt_" + new string('D', 43) + "." + new string('E', 43);
        var jsonBody = $"{{\"access_token\":\"{realAccess}\",\"refresh_token\":\"{realRefresh}\"}}";
        var bodyBytes = Encoding.UTF8.GetBytes(jsonBody);
        var raw = BuildResponse($"Content-Length: {bodyBytes.Length}", bodyBytes);

        var result = OAuthRotationRewriter.Rewrite(raw, OAuthRotationProvider.Codex, profile, swapper);

        result.NewReals.Should().NotBeNull();
        var output = Encoding.UTF8.GetString(result.Bytes);
        output.Should().Contain("brm-cdX-sig", "JWT signature gets the brm fake marker");
        output.Should().Contain("rt_brm-cdX-rfs-", "refresh token gets the brm fake marker");

        var entries = swapper.EntriesFor(profile);
        entries.Should().HaveCountGreaterOrEqualTo(4);
    }

    private static byte[] BuildResponse(string extraHeader, byte[] body)
    {
        var head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" + extraHeader + "\r\n\r\n";
        var headBytes = Encoding.ASCII.GetBytes(head);
        var output = new byte[headBytes.Length + body.Length];
        Buffer.BlockCopy(headBytes, 0, output, 0, headBytes.Length);
        Buffer.BlockCopy(body, 0, output, headBytes.Length, body.Length);
        return output;
    }

    [Fact]
    public void RewriteClaude_GzippedBody_DecompressesRotatesAndDropsEncoding()
    {
        var swapper = new TokenSwapper(new AlwaysAllowConsentBroker());
        var profile = Guid.NewGuid();
        swapper.SetMap(new TokenMap(Array.Empty<TokenMap.Entry>()), profile);

        var realAccess = "sk-ant-oat01-" + new string('a', 50);
        var realRefresh = "sk-ant-ort01-" + new string('b', 50);
        var jsonBody = $"{{\"access_token\":\"{realAccess}\",\"refresh_token\":\"{realRefresh}\"}}";
        var compressed = Gzip(Encoding.UTF8.GetBytes(jsonBody));
        // Header advertises gzip + a Content-Length matching the
        // compressed payload — the rewriter must decompress before
        // parsing JSON.
        var head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" +
                   "Content-Encoding: gzip\r\n" +
                   $"Content-Length: {compressed.Length}\r\n\r\n";
        var headBytes = Encoding.ASCII.GetBytes(head);
        var raw = new byte[headBytes.Length + compressed.Length];
        Buffer.BlockCopy(headBytes, 0, raw, 0, headBytes.Length);
        Buffer.BlockCopy(compressed, 0, raw, headBytes.Length, compressed.Length);

        var result = OAuthRotationRewriter.Rewrite(raw, OAuthRotationProvider.Claude, profile, swapper);

        result.NewReals.Should().NotBeNull();
        result.NewReals!.AccessToken.Should().Be(realAccess);

        var output = Encoding.ASCII.GetString(result.Bytes);
        output.Should().Contain("sk-ant-oat01-brm-",
            "rewriter rotated the access token after decompressing");
        output.Should().NotContain("Content-Encoding:",
            "we drop the encoding header since the rewritten body is plain JSON");
        // Content-Length now reflects the uncompressed JSON size.
        var headerEnd = output.IndexOf("\r\n\r\n", StringComparison.Ordinal);
        var headers = output[..headerEnd];
        headers.Should().Contain("Content-Length: ");
    }

    [Fact]
    public void RewriteCodex_GzippedBody_DecompressesAndRotates()
    {
        var swapper = new TokenSwapper(new AlwaysAllowConsentBroker());
        var profile = Guid.NewGuid();
        swapper.SetMap(new TokenMap(Array.Empty<TokenMap.Entry>()), profile);

        // Same JWT-shaped access token + opaque refresh shape that
        // RewriteCodex_JwtAccessAndOpaqueRefresh_BothRotated uses —
        // SubscriptionFakeMint.MintJwtFake requires three dot-separated
        // base64 segments to mint a fake.
        var realAccess = "eyJ" + new string('A', 50) + "." + new string('B', 50) + "." + new string('C', 50);
        var realRefresh = "rt_" + new string('D', 43) + "." + new string('E', 43);
        var jsonBody = $"{{\"access_token\":\"{realAccess}\",\"refresh_token\":\"{realRefresh}\"}}";
        var compressed = Gzip(Encoding.UTF8.GetBytes(jsonBody));
        var head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n" +
                   "Content-Encoding: gzip\r\n" +
                   $"Content-Length: {compressed.Length}\r\n\r\n";
        var raw = new byte[head.Length + compressed.Length];
        Buffer.BlockCopy(Encoding.ASCII.GetBytes(head), 0, raw, 0, head.Length);
        Buffer.BlockCopy(compressed, 0, raw, head.Length, compressed.Length);

        var result = OAuthRotationRewriter.Rewrite(raw, OAuthRotationProvider.Codex, profile, swapper);

        result.NewReals.Should().NotBeNull();
        result.NewReals!.AccessToken.Should().Be(realAccess);
        Encoding.ASCII.GetString(result.Bytes).Should().NotContain("Content-Encoding:");
    }

    private static byte[] Gzip(byte[] raw)
    {
        using var ms = new MemoryStream();
        using (var gz = new System.IO.Compression.GZipStream(ms,
            System.IO.Compression.CompressionLevel.Fastest))
        {
            gz.Write(raw, 0, raw.Length);
        }
        return ms.ToArray();
    }
}
