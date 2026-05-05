using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Text;
using System.Text.RegularExpressions;
using Bromure.AC.Mitm.OAuth;
using Bromure.AC.Mitm.Pki;
using Bromure.AC.Mitm.SigV4;
using Bromure.AC.Mitm.Swap;
using Bromure.AC.Mitm.Trace;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Bromure.AC.Mitm.Proxy;

/// <summary>
/// MVP port of <c>Sources/AgentCoding/Mitm/HTTPProxy.swift</c>. Listens on
/// a TCP port (the proxy port the VM CONNECTs to over a virtio NAT or
/// a host-side bridge), terminates TLS with a forged per-host leaf
/// from <see cref="CertCache"/>, runs the swap engine, and proxies the
/// rewritten request upstream.
///
/// <para>What's in: CONNECT handling, TLS-MITM with per-host leaves,
/// request body buffering, <see cref="TokenSwapper"/> + <see cref="AwsResigner"/>
/// invocation, response streaming, OAuth rotation on the response path,
/// trace recording.</para>
///
/// <para>What's NOT yet in (Phase 4 / 5 follow-up): kubeconfig client-cert
/// presentation, cluster CA trust, subscription-token seen callbacks,
/// realtime event taps, websocket framing. The seams are present but
/// not wired here.</para>
/// </summary>
public sealed class HttpMitmProxy : IAsyncDisposable
{
    private readonly TokenSwapper _swapper;
    private readonly AwsResigner _awsResigner;
    private readonly CertCache _certCache;
    private readonly TraceStore? _traceStore;
    private readonly ILogger _log;
    private readonly Guid _profileId;
    private TcpListener? _listener;
    private CancellationTokenSource? _cts;
    private Task? _acceptLoop;

    public HttpMitmProxy(
        Guid profileId,
        TokenSwapper swapper,
        AwsResigner awsResigner,
        CertCache certCache,
        TraceStore? traceStore = null,
        ILogger? log = null)
    {
        _profileId = profileId;
        _swapper = swapper;
        _awsResigner = awsResigner;
        _certCache = certCache;
        _traceStore = traceStore;
        _log = log ?? NullLogger.Instance;
    }

    public IPEndPoint? LocalEndpoint =>
        _listener?.LocalEndpoint as IPEndPoint;

    public Task StartAsync(IPEndPoint endpoint, CancellationToken ct = default)
    {
        if (_listener is not null) throw new InvalidOperationException("Already started");
        _listener = new TcpListener(endpoint);
        _listener.Start();
        _cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        _acceptLoop = Task.Run(() => AcceptLoopAsync(_cts.Token));
        return Task.CompletedTask;
    }

    private async Task AcceptLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            TcpClient client;
            try
            {
                client = await _listener!.AcceptTcpClientAsync(ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { return; }
            catch (ObjectDisposedException) { return; }

            _ = Task.Run(async () =>
            {
                try
                {
                    using (client)
                    {
                        await HandleConnectionAsync(client, ct).ConfigureAwait(false);
                    }
                }
                catch (Exception ex)
                {
                    _log.LogWarning(ex, "MITM connection threw");
                }
            }, ct);
        }
    }

    private async Task HandleConnectionAsync(TcpClient client, CancellationToken ct)
    {
        using var clientStream = client.GetStream();
        var t0 = DateTimeOffset.UtcNow;

        // 1. CONNECT request from the VM's HTTP_PROXY env.
        var connectReq = await ReadHttpHeaderAsync(clientStream, maxBytes: 16 * 1024, ct).ConfigureAwait(false);
        if (connectReq is null)
        {
            await WriteAsync(clientStream, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", ct);
            return;
        }
        var firstLine = connectReq.IndexOf("\r\n", StringComparison.Ordinal) is var ln && ln > 0
            ? connectReq[..ln]
            : connectReq;
        var parts = firstLine.Split(' ');
        if (parts.Length < 2 || parts[0] != "CONNECT")
        {
            // We could fall through to plain-HTTP proxying here. Defer
            // until we actually see SDKs that need it.
            await WriteAsync(clientStream, "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", ct);
            return;
        }
        var (host, port) = ParseHostPort(parts[1]);

        // 2. Confirm the tunnel.
        await WriteAsync(clientStream, "HTTP/1.1 200 Connection established\r\n\r\n", ct);

        // 3. Terminate TLS with a forged leaf for `host`.
        var leaf = _certCache.IdentityFor(host);
        await using var tlsServer = new SslStream(clientStream, leaveInnerStreamOpen: true);
        try
        {
            await tlsServer.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
            {
                ServerCertificate = leaf,
                ClientCertificateRequired = false,
                EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13,
            }, ct).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _log.LogDebug(ex, "TLS handshake failed for {Host}", host);
            return;
        }

        // 4. Read the wrapped HTTP request (header + body honoring CL).
        var wrapped = await ReadWrappedRequestAsync(tlsServer, ct).ConfigureAwait(false);
        if (wrapped is null) return;

        // 5. Swap tokens, then re-sign if AWS.
        var swapResult = await _swapper.SwapAsync(wrapped, host, _profileId, ct).ConfigureAwait(false);
        var requestBytes = swapResult.Modified;
        var leaks = _swapper.DetectLeaks(wrapped, _profileId);

        if (AwsResigner.IsAwsHost(host))
        {
            var resignOutcome = await _awsResigner.ResignAsync(requestBytes, host, _profileId, ct).ConfigureAwait(false);
            switch (resignOutcome)
            {
                case AwsResigner.Outcome.Resigned r:
                    requestBytes = r.Bytes;
                    break;
                case AwsResigner.Outcome.Denied d:
                    await tlsServer.WriteAsync(d.Response, ct).ConfigureAwait(false);
                    return;
                case AwsResigner.Outcome.Failed f:
                    await tlsServer.WriteAsync(f.Response, ct).ConfigureAwait(false);
                    return;
                // Unchanged: fall through with current bytes.
            }
        }

        // 6. Open upstream TCP+TLS, write request, stream response.
        byte[] responseBytes;
        try
        {
            responseBytes = await ForwardAsync(host, port, requestBytes, ct).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "Upstream forwarding to {Host}:{Port} failed", host, port);
            await tlsServer.WriteAsync(MakeBadGateway($"upstream {host}:{port}: {ex.Message}"), ct);
            return;
        }

        // 7. OAuth rotation rewriter on the response path.
        var rewriterProvider = OAuthRotationRewriter.ProviderFor(host, ExtractPath(requestBytes));
        if (rewriterProvider is { } prov)
        {
            var rotated = OAuthRotationRewriter.Rewrite(responseBytes, prov, _profileId, _swapper);
            responseBytes = rotated.Bytes;
            // OAuth rotation downstream (storing new reals) is the host's
            // responsibility; the proxy just exposes it via the result.
        }

        await tlsServer.WriteAsync(responseBytes, ct).ConfigureAwait(false);

        // 8. Trace.
        _traceStore?.Record(new TraceRecord(
            Id: Guid.NewGuid(),
            SessionId: Guid.Empty,  // engine plumbs the session ID via a wider seam
            ProfileId: _profileId,
            Timestamp: t0,
            Host: host,
            Port: port,
            Method: ExtractMethod(requestBytes),
            Path: ExtractPath(requestBytes),
            StatusCode: ExtractStatus(responseBytes),
            RequestBytes: requestBytes.Length,
            ResponseBytes: responseBytes.Length,
            LatencyMs: (DateTimeOffset.UtcNow - t0).TotalMilliseconds,
            Swaps: swapResult.Swaps.Select(s => new SwapEntry(
                Header: "Authorization",
                FakePreview: s.FakePreview,
                RealPreview: s.RealPreview)).ToArray(),
            Leaks: leaks.Select(l => new LeakEntry(
                Header: l.Header,
                ValuePreview: l.ValuePreview,
                Suspicion: l.Suspicion == LeakSuspicionKind.KnownPrefix
                    ? LeakSuspicion.KnownPrefix
                    : LeakSuspicion.OpaqueToken)).ToArray(),
            BodyStored: false));
    }

    private static async Task<byte[]> ForwardAsync(string host, int port, byte[] requestBytes, CancellationToken ct)
    {
        using var upstream = new TcpClient();
        await upstream.ConnectAsync(host, port, ct).ConfigureAwait(false);
        using var upstreamRaw = upstream.GetStream();
        await using var upstreamTls = new SslStream(upstreamRaw, leaveInnerStreamOpen: true);
        await upstreamTls.AuthenticateAsClientAsync(new SslClientAuthenticationOptions
        {
            TargetHost = host,
            EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13,
        }, ct).ConfigureAwait(false);

        await upstreamTls.WriteAsync(requestBytes, ct).ConfigureAwait(false);
        await upstreamTls.FlushAsync(ct).ConfigureAwait(false);

        // Read until upstream closes. Production version honors
        // Content-Length and Transfer-Encoding: chunked; for now we
        // close-frame the response which works for HTTP/1.0-style flows
        // and for any upstream that sets Connection: close on us.
        using var ms = new MemoryStream();
        var buf = new byte[16 * 1024];
        while (true)
        {
            int n;
            try { n = await upstreamTls.ReadAsync(buf, ct).ConfigureAwait(false); }
            catch (IOException) { break; }
            if (n <= 0) break;
            ms.Write(buf, 0, n);
        }
        return ms.ToArray();
    }

    private static async Task<string?> ReadHttpHeaderAsync(Stream stream, int maxBytes, CancellationToken ct)
    {
        var buf = new byte[maxBytes];
        var got = 0;
        while (got < maxBytes)
        {
            var n = await stream.ReadAsync(buf.AsMemory(got, maxBytes - got), ct).ConfigureAwait(false);
            if (n == 0) return null;
            got += n;
            // Find \r\n\r\n.
            for (var i = 0; i <= got - 4; i++)
            {
                if (buf[i] == 0x0D && buf[i + 1] == 0x0A
                    && buf[i + 2] == 0x0D && buf[i + 3] == 0x0A)
                {
                    return Encoding.ASCII.GetString(buf, 0, i + 4);
                }
            }
        }
        return null;
    }

    private static async Task<byte[]?> ReadWrappedRequestAsync(Stream tls, CancellationToken ct)
    {
        // Read header section then body honoring Content-Length.
        var headerBuf = new byte[64 * 1024];
        var got = 0;
        var headerEnd = -1;
        while (got < headerBuf.Length)
        {
            var n = await tls.ReadAsync(headerBuf.AsMemory(got, headerBuf.Length - got), ct).ConfigureAwait(false);
            if (n == 0) return null;
            got += n;
            for (var i = 0; i <= got - 4; i++)
            {
                if (headerBuf[i] == 0x0D && headerBuf[i + 1] == 0x0A
                    && headerBuf[i + 2] == 0x0D && headerBuf[i + 3] == 0x0A)
                {
                    headerEnd = i + 4;
                    break;
                }
            }
            if (headerEnd >= 0) break;
        }
        if (headerEnd < 0) return null;

        var headerStr = Encoding.ASCII.GetString(headerBuf, 0, headerEnd);
        var contentLength = ParseContentLength(headerStr);
        var bodyAlready = got - headerEnd;
        var bodyTotal = Math.Max(0, contentLength);
        var output = new byte[headerEnd + bodyTotal];
        Buffer.BlockCopy(headerBuf, 0, output, 0, headerEnd);
        if (bodyAlready > 0)
        {
            Buffer.BlockCopy(headerBuf, headerEnd, output, headerEnd, Math.Min(bodyAlready, bodyTotal));
        }
        var bodyStillNeeded = bodyTotal - Math.Min(bodyAlready, bodyTotal);
        if (bodyStillNeeded > 0)
        {
            var off = headerEnd + Math.Min(bodyAlready, bodyTotal);
            while (bodyStillNeeded > 0)
            {
                var n = await tls.ReadAsync(output.AsMemory(off, bodyStillNeeded), ct).ConfigureAwait(false);
                if (n <= 0) break;
                off += n;
                bodyStillNeeded -= n;
            }
        }
        return output;
    }

    private static int ParseContentLength(string headerStr)
    {
        var m = Regex.Match(headerStr, @"(?im)^Content-Length:\s*(\d+)");
        return m.Success && int.TryParse(m.Groups[1].Value, out var n) ? n : 0;
    }

    private static (string Host, int Port) ParseHostPort(string target)
    {
        var colon = target.LastIndexOf(':');
        if (colon < 0) return (target, 443);
        return (target[..colon], int.TryParse(target[(colon + 1)..], out var p) ? p : 443);
    }

    private static string ExtractMethod(byte[] requestBytes)
    {
        var firstLine = ReadFirstLine(requestBytes);
        var sp = firstLine.IndexOf(' ');
        return sp > 0 ? firstLine[..sp] : "?";
    }

    private static string ExtractPath(byte[] requestBytes)
    {
        var firstLine = ReadFirstLine(requestBytes);
        var sp = firstLine.IndexOf(' ');
        if (sp < 0) return "/";
        var rest = firstLine[(sp + 1)..];
        var sp2 = rest.IndexOf(' ');
        return sp2 > 0 ? rest[..sp2] : rest;
    }

    private static int ExtractStatus(byte[] responseBytes)
    {
        var firstLine = ReadFirstLine(responseBytes);
        var sp = firstLine.IndexOf(' ');
        if (sp < 0) return 0;
        var rest = firstLine[(sp + 1)..];
        var sp2 = rest.IndexOf(' ');
        var status = sp2 > 0 ? rest[..sp2] : rest;
        return int.TryParse(status, out var n) ? n : 0;
    }

    private static string ReadFirstLine(byte[] bytes)
    {
        for (var i = 0; i < bytes.Length - 1; i++)
        {
            if (bytes[i] == 0x0D && bytes[i + 1] == 0x0A)
            {
                return Encoding.ASCII.GetString(bytes, 0, i);
            }
        }
        return "";
    }

    private static byte[] MakeBadGateway(string detail)
    {
        var body = Encoding.UTF8.GetBytes($"bromure: {detail}\n");
        var head = $"HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain\r\nContent-Length: {body.Length}\r\nConnection: close\r\n\r\n";
        var headBytes = Encoding.ASCII.GetBytes(head);
        var output = new byte[headBytes.Length + body.Length];
        Buffer.BlockCopy(headBytes, 0, output, 0, headBytes.Length);
        Buffer.BlockCopy(body, 0, output, headBytes.Length, body.Length);
        return output;
    }

    private static Task WriteAsync(Stream stream, string text, CancellationToken ct)
        => stream.WriteAsync(Encoding.ASCII.GetBytes(text), ct).AsTask();

    public async ValueTask DisposeAsync()
    {
        try { _cts?.Cancel(); } catch { }
        try { _listener?.Stop(); } catch { }
        if (_acceptLoop is not null)
        {
            try { await _acceptLoop.ConfigureAwait(false); } catch { }
        }
        _cts?.Dispose();
    }
}
