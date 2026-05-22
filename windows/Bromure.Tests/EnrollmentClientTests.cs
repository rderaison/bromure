using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using Bromure.AC.Core.Enrollment;
using FluentAssertions;
using Org.BouncyCastle.Pkcs;
using Xunit;

namespace Bromure.Tests;

/// <summary>
/// Network + payload-shape coverage for the enrollment client.
/// Audit 06 #1/#2 flagged the wrong enroll URL + missing
/// installPubkey field; these tests spin a loopback listener
/// and assert the wire shape matches the macOS port.
/// </summary>
public class EnrollmentClientTests
{
    [Fact]
    public async Task EnrollAsync_PostsTo_V1_Enroll_With_InstallPubkey()
    {
        using var server = LoopbackHttpServer.Start(req =>
        {
            req.Path.Should().Be("/v1/enroll");
            req.Method.Should().Be("POST");
            using var doc = JsonDocument.Parse(req.Body);
            var root = doc.RootElement;
            root.GetProperty("code").GetString().Should().Be("alpha-bravo-charlie");
            root.GetProperty("app").GetString().Should().Be("agentic-coding");
            root.GetProperty("deviceName").GetString().Should().Be("test-host");
            // installPubkey: 64-hex (32 bytes) — the field the audit
            // flagged as missing from the original Windows port.
            var pub = root.GetProperty("installPubkey").GetString();
            pub.Should().NotBeNullOrEmpty();
            pub!.Length.Should().Be(64);
            pub.Should().MatchRegex("^[0-9a-fA-F]+$");

            return JsonOk("""
                {
                    "installId": "inst-1",
                    "orgSlug": "acme",
                    "userId": "u-1",
                    "userEmail": "alice@example.com",
                    "installToken": "tok-deadbeef",
                    "app": "agentic-coding"
                }
                """);
        });

        using var http = new HttpClient { BaseAddress = server.Uri };
        var client = new EnrollmentClient(new HttpClient());
        var outcome = await client.EnrollAsync(
            "alpha-bravo-charlie", "test-host", server.Uri);

        outcome.Install.InstallId.Should().Be("inst-1");
        outcome.Install.OrgSlug.Should().Be("acme");
        outcome.Install.UserEmail.Should().Be("alice@example.com");
        outcome.BearerToken.Should().Be("tok-deadbeef");
    }

    [Fact]
    public async Task EnrollAsync_WrongApp_Throws()
    {
        using var server = LoopbackHttpServer.Start(_ => JsonOk("""
            {"installId":"i","orgSlug":"o","userId":"u","userEmail":"e@x","installToken":"t","app":"web"}
            """));
        var client = new EnrollmentClient(new HttpClient());
        var ex = await Record.ExceptionAsync(() =>
            client.EnrollAsync("code", "dev", server.Uri));
        ex.Should().BeOfType<EnrollmentException>();
        ex!.Message.Should().Contain("agentic-coding");
    }

    [Fact]
    public async Task EnrollAsync_4xx_Throws()
    {
        using var server = LoopbackHttpServer.Start(_ =>
            new HttpResponseMessage(HttpStatusCode.Forbidden)
            {
                Content = new StringContent("code expired", Encoding.UTF8, "text/plain"),
            });
        var client = new EnrollmentClient(new HttpClient());
        var ex = await Record.ExceptionAsync(() =>
            client.EnrollAsync("code", "dev", server.Uri));
        ex.Should().BeOfType<EnrollmentException>();
        ex!.Message.Should().Contain("403");
    }

    [Fact]
    public async Task RequestCertAsync_PostsCsrToCertEndpoint_WithBearer()
    {
        string? capturedCsrPem = null;
        string? capturedAuth = null;
        string? capturedPath = null;
        using var server = LoopbackHttpServer.Start(req =>
        {
            capturedPath = req.Path;
            capturedAuth = req.Headers.GetValueOrDefault("Authorization");
            using var doc = JsonDocument.Parse(req.Body);
            capturedCsrPem = doc.RootElement.GetProperty("csrPem").GetString();
            return JsonOk("""
                {
                    "certPem": "-----BEGIN CERTIFICATE-----\nMIIB…\n-----END CERTIFICATE-----\n",
                    "caCertPem": "-----BEGIN CERTIFICATE-----\nMIIA…\n-----END CERTIFICATE-----\n",
                    "serialHex": "deadbeef",
                    "notAfter": "2027-05-21T12:00:00Z"
                }
                """);
        });
        var client = new EnrollmentClient(new HttpClient());
        var iss = await client.RequestCertAsync("inst-42", "tok-bearer", server.Uri);

        capturedPath.Should().Be("/v1/installs/inst-42/cert");
        capturedAuth.Should().Be("Bearer tok-bearer");
        capturedCsrPem.Should().Contain("BEGIN CERTIFICATE REQUEST");
        // Round-trip the CSR through BouncyCastle to prove it's valid +
        // CN-bound to the install id.
        var pem = capturedCsrPem!;
        var b64 = ExtractPemBody(pem);
        var csr = new Pkcs10CertificationRequest(Convert.FromBase64String(b64));
        csr.Verify().Should().BeTrue("CSR signature must verify");
        var subject = csr.GetCertificationRequestInfo().Subject.ToString();
        subject.Should().Contain("bromure-install-inst-42");

        iss.SerialHex.Should().Be("deadbeef");
        iss.CertPem.Should().Contain("BEGIN CERTIFICATE");
        iss.CaCertPem.Should().Contain("BEGIN CERTIFICATE");
        iss.PrivateKeyDer.Length.Should().BeGreaterThan(0);
    }

    [Fact]
    public async Task HeartbeatAsync_PostsToHeartbeatEndpoint()
    {
        string? capturedPath = null;
        string? capturedAuth = null;
        using var server = LoopbackHttpServer.Start(req =>
        {
            capturedPath = req.Path;
            capturedAuth = req.Headers.GetValueOrDefault("Authorization");
            return new HttpResponseMessage(HttpStatusCode.OK);
        });
        var client = new EnrollmentClient(new HttpClient());
        await client.HeartbeatAsync("inst-1", "tok", server.Uri);
        capturedPath.Should().Be("/v1/installs/inst-1/heartbeat");
        capturedAuth.Should().Be("Bearer tok");
    }

    [Fact]
    public async Task UnenrollAsync_PostsToUnenrollEndpoint()
    {
        string? capturedPath = null;
        using var server = LoopbackHttpServer.Start(req =>
        {
            capturedPath = req.Path;
            return new HttpResponseMessage(HttpStatusCode.OK);
        });
        var client = new EnrollmentClient(new HttpClient());
        await client.UnenrollAsync("inst-1", "tok", server.Uri);
        capturedPath.Should().Be("/v1/installs/inst-1/unenroll");
    }

    private static string ExtractPemBody(string pem)
    {
        var lines = pem.Split('\n');
        var sb = new StringBuilder();
        foreach (var l in lines)
        {
            var trimmed = l.Trim();
            if (trimmed.Length == 0 || trimmed.StartsWith("-----")) continue;
            sb.Append(trimmed);
        }
        return sb.ToString();
    }

    private static HttpResponseMessage JsonOk(string json)
        => new(HttpStatusCode.OK)
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json"),
        };

    private sealed class LoopbackHttpServer : IDisposable
    {
        private readonly HttpListener _listener;
        private readonly CancellationTokenSource _cts = new();
        public Uri Uri { get; }

        private LoopbackHttpServer(Func<CapturedRequest, HttpResponseMessage> handler, int port)
        {
            _listener = new HttpListener();
            var prefix = $"http://127.0.0.1:{port}/";
            _listener.Prefixes.Add(prefix);
            _listener.Start();
            Uri = new Uri(prefix);
            _ = Task.Run(() => Loop(handler, _cts.Token));
        }

        public static LoopbackHttpServer Start(Func<CapturedRequest, HttpResponseMessage> handler)
        {
            var port = FreePort();
            return new LoopbackHttpServer(handler, port);
        }

        private static int FreePort()
        {
            using var sock = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
            sock.Bind(new IPEndPoint(IPAddress.Loopback, 0));
            return ((IPEndPoint)sock.LocalEndPoint!).Port;
        }

        private async Task Loop(Func<CapturedRequest, HttpResponseMessage> handler, CancellationToken ct)
        {
            while (!ct.IsCancellationRequested)
            {
                HttpListenerContext ctx;
                try { ctx = await _listener.GetContextAsync().ConfigureAwait(false); }
                catch (HttpListenerException) { return; }
                catch (ObjectDisposedException) { return; }

                try
                {
                    using var reader = new System.IO.StreamReader(ctx.Request.InputStream, Encoding.UTF8);
                    var body = await reader.ReadToEndAsync().ConfigureAwait(false);
                    var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                    foreach (var h in ctx.Request.Headers.AllKeys)
                    {
                        if (h is null) continue;
                        headers[h] = ctx.Request.Headers[h] ?? "";
                    }
                    var captured = new CapturedRequest(
                        ctx.Request.Url!.AbsolutePath, ctx.Request.HttpMethod, body, headers);
                    using var resp = handler(captured);
                    ctx.Response.StatusCode = (int)resp.StatusCode;
                    var respBody = await resp.Content.ReadAsByteArrayAsync().ConfigureAwait(false);
                    if (resp.Content.Headers.ContentType is { } ct2)
                        ctx.Response.ContentType = ct2.ToString();
                    ctx.Response.OutputStream.Write(respBody);
                    ctx.Response.Close();
                }
                catch (Exception)
                {
                    try { ctx.Response.StatusCode = 500; ctx.Response.Close(); } catch { }
                }
            }
        }

        public void Dispose()
        {
            try { _cts.Cancel(); } catch { }
            try { _listener.Stop(); } catch { }
            try { _listener.Close(); } catch { }
        }
    }

    private sealed record CapturedRequest(string Path, string Method, string Body, IReadOnlyDictionary<string, string> Headers);
}
