using System.Net;
using System.Text;
using Bromure.AC.Mitm.Aws;
using Bromure.AC.Mitm.Consent;
using Bromure.AC.Mitm.Pki;
using Bromure.AC.Mitm.Proxy;
using Bromure.AC.Mitm.SigV4;
using Bromure.AC.Mitm.Swap;
using Bromure.AC.Mitm.Trace;
using Bromure.Platform;
using FluentAssertions;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Backfill for an earlier overclaim. The original "subscription /
/// Codex token-seen" tests verified that
/// <see cref="TokenSwapper.DetectSubscriptionAccessToken"/> parses
/// headers correctly — but never that the proxy's hot path actually
/// fires the callback on a request that matches. These tests bind
/// to the proxy's extracted decision helper (now exposed via
/// internals to this assembly) and prove the wire-up does the right
/// thing for every host scope + every header shape.
/// </summary>
public class SubscriptionTokenSeenHookTests
{
    [Theory]
    [InlineData("api.anthropic.com", true)]
    [InlineData("API.ANTHROPIC.COM", true)]
    [InlineData("console.anthropic.com", true)]
    [InlineData("anthropic.com", false /* exact match against subdomain suffix, no trailing dot */)]
    [InlineData("evil-anthropic.com", false)]
    [InlineData("anthropic.com.evil.com", false)]
    [InlineData("api.openai.com", false)]
    public void IsAnthropicHost_MatchesExactAndSubdomains(string host, bool expected)
    {
        HttpMitmProxy.IsAnthropicHost(host).Should().Be(expected);
    }

    [Theory]
    [InlineData("chatgpt.com", true)]
    [InlineData("CHATGPT.COM", true)]
    [InlineData("ws.chatgpt.com", true)]
    [InlineData("auth.openai.com", true)]
    [InlineData("api.openai.com", true)]
    [InlineData("platform.openai.com", false /* only auth + api in scope */)]
    [InlineData("evil-chatgpt.com", false)]
    public void IsCodexHost_MatchesDocumentedScope(string host, bool expected)
    {
        HttpMitmProxy.IsCodexHost(host).Should().Be(expected);
    }

    [Fact]
    public async Task Proxy_FiresSubscriptionTokenSeen_OnAnthropicHostWithCleanToken()
    {
        Guid? capturedProfile = null;
        string? capturedToken = null;
        await using var proxy = await NewProxyAsync(
            onSubscriptionTokenSeen: (pid, tok) =>
            {
                capturedProfile = pid;
                capturedToken = tok;
            });
        var raw = BuildAuthRequest(
            "POST", "/v1/messages", "api.anthropic.com",
            bearer: "sk-ant-oat01-realLooking-abcd1234");

        proxy.FireSubscriptionTokenSeenIfApplicable("api.anthropic.com", raw);

        capturedProfile.Should().NotBeNull();
        capturedToken.Should().Be("sk-ant-oat01-realLooking-abcd1234");
    }

    [Fact]
    public async Task Proxy_SkipsSubscriptionTokenSeen_OnUnrelatedHost()
    {
        var fired = false;
        await using var proxy = await NewProxyAsync(
            onSubscriptionTokenSeen: (_, _) => fired = true);
        var raw = BuildAuthRequest("POST", "/", "example.com",
            bearer: "sk-ant-oat01-realLooking-abcd1234");
        proxy.FireSubscriptionTokenSeenIfApplicable("example.com", raw);
        fired.Should().BeFalse();
    }

    [Fact]
    public async Task Proxy_SkipsSubscriptionTokenSeen_OnAlreadyFakeToken()
    {
        var fired = false;
        await using var proxy = await NewProxyAsync(
            onSubscriptionTokenSeen: (_, _) => fired = true);
        var raw = BuildAuthRequest("POST", "/", "api.anthropic.com",
            bearer: "sk-ant-oat01-brm-thisisafake1234");
        proxy.FireSubscriptionTokenSeenIfApplicable("api.anthropic.com", raw);
        fired.Should().BeFalse();
    }

    [Fact]
    public async Task Proxy_FiresCodexTokenSeen_OnChatgptComWithJwt()
    {
        string? captured = null;
        await using var proxy = await NewProxyAsync(
            onCodexTokenSeen: (_, tok) => captured = tok);
        var jwt = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.realLookingSignatureHere";
        var raw = BuildAuthRequest("GET", "/api/conversations", "chatgpt.com", bearer: jwt);
        proxy.FireSubscriptionTokenSeenIfApplicable("chatgpt.com", raw);
        captured.Should().Be(jwt);
    }

    [Fact]
    public async Task Proxy_DoesNotFire_WhenCallbackIsNull()
    {
        // No callback wired → no exception, just nothing happens.
        await using var proxy = await NewProxyAsync();
        var raw = BuildAuthRequest("POST", "/v1/messages", "api.anthropic.com",
            bearer: "sk-ant-oat01-someToken");
        proxy.FireSubscriptionTokenSeenIfApplicable("api.anthropic.com", raw);
        // No assertion beyond "did not throw".
    }

    [Fact]
    public async Task Proxy_CallbackException_DoesNotPropagate()
    {
        await using var proxy = await NewProxyAsync(
            onSubscriptionTokenSeen: (_, _) => throw new InvalidOperationException("UI blew up"));
        var raw = BuildAuthRequest("POST", "/", "api.anthropic.com",
            bearer: "sk-ant-oat01-x");
        // Exception is swallowed + logged; proxy keeps serving.
        var ex = Record.Exception(() =>
            proxy.FireSubscriptionTokenSeenIfApplicable("api.anthropic.com", raw));
        ex.Should().BeNull();
    }

    private static byte[] BuildAuthRequest(string method, string path, string host, string bearer)
    {
        var sb = new StringBuilder();
        sb.Append($"{method} {path} HTTP/1.1\r\n");
        sb.Append($"Host: {host}\r\n");
        sb.Append($"Authorization: Bearer {bearer}\r\n");
        sb.Append("\r\n");
        return Encoding.ASCII.GetBytes(sb.ToString());
    }

    private static async Task<HttpMitmProxy> NewProxyAsync(
        Action<Guid, string>? onSubscriptionTokenSeen = null,
        Action<Guid, string>? onCodexTokenSeen = null)
    {
        var paths = new TempPaths();
        var ca = BromureCa.LoadOrCreate(paths, paths.Secrets);
        var swapper = new TokenSwapper(new AlwaysAllowConsentBroker());
        swapper.SetMap(new TokenMap(Array.Empty<TokenMap.Entry>()), Guid.NewGuid());
        var resigner = new AwsResigner(new NullCredServer());
        var proxy = new HttpMitmProxy(
            Guid.NewGuid(), swapper, resigner, new CertCache(ca),
            onSubscriptionTokenSeen: onSubscriptionTokenSeen,
            onCodexTokenSeen: onCodexTokenSeen);
        await proxy.StartAsync(new IPEndPoint(IPAddress.Loopback, 0));
        return proxy;
    }

    private sealed class TempPaths : IAppPaths
    {
        private readonly string _root = Path.Combine(Path.GetTempPath(),
            "bromure-tok-hook-" + Guid.NewGuid().ToString("N"));
        public InMemSecrets Secrets { get; } = new();
        public TempPaths() { Directory.CreateDirectory(_root); }
        public string AppDataRoot => _root;
        public string MachineDataRoot => _root;
        public string ProfilesDirectory => Path.Combine(_root, "p");
        public string TracesDirectory => Path.Combine(_root, "t");
        public string ImagesDirectory => Path.Combine(_root, "i");
        public string SessionsDirectory => Path.Combine(_root, "s");
        public string ResourcesDirectory => Path.Combine(_root, "r");
        public string EnsureDirectory(string p) { Directory.CreateDirectory(p); return p; }
    }

    private sealed class InMemSecrets : ISecretStore
    {
        private readonly Dictionary<string, string> _s = new();
        private readonly Dictionary<string, byte[]> _b = new();
        public void StoreSecret(string svc, string acct, string v) => _s[svc + "|" + acct] = v;
        public string? ReadSecret(string svc, string acct) => _s.GetValueOrDefault(svc + "|" + acct);
        public void DeleteSecret(string svc, string acct) => _s.Remove(svc + "|" + acct);
        public void StoreBlob(string n, ReadOnlySpan<byte> d, BlobScope s) => _b[s + "|" + n] = d.ToArray();
        public byte[]? ReadBlob(string n, BlobScope s) => _b.GetValueOrDefault(s + "|" + n);
        public void DeleteBlob(string n, BlobScope s) => _b.Remove(s + "|" + n);
    }

    private sealed class NullCredServer : IAwsCredentialServer
    {
        public Task<SigningMaterial> SigningMaterialAsync(Guid p, string scope, CancellationToken ct)
            => Task.FromResult<SigningMaterial>(new SigningMaterial.Missing());
    }
}
