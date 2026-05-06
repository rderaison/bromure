// macos-source: Sources/AgentCoding/Mitm/HTTPProxy.swift @ 875b644e56b1
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

        // 4b. WebSocket upgrade fast-path. Anthropic / OpenAI streaming
        // tools and many SaaS dashboards open WebSockets after the
        // initial HTTPS handshake; URLSession-style request/response
        // forwarding can't represent the bidirectional frame stream
        // that follows a 101 Switching Protocols. Detect the upgrade
        // and switch into a raw byte pump between the two TLS sides.
        if (IsWebSocketUpgrade(wrapped))
        {
            _log.LogDebug("WebSocket upgrade for {Host}", host);
            await HandleWebSocketUpgradeAsync(host, port, wrapped, tlsServer, t0, ct).ConfigureAwait(false);
            return;
        }

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
            // Don't advertise h2 — we only speak HTTP/1.1. Without
            // this, some upstreams (apple.com, anthropic) negotiate h2
            // and we'd have to deal with frame parsing.
            ApplicationProtocols = new List<SslApplicationProtocol>
            {
                SslApplicationProtocol.Http11,
            },
        }, ct).ConfigureAwait(false);

        // Force Connection: close on the forwarded request so upstream
        // closes the TCP after the response — frees us from having
        // to honour keep-alive on the upstream side. We still parse
        // body framing properly below as a backstop.
        var rewritten = ForceConnectionClose(requestBytes);
        await upstreamTls.WriteAsync(rewritten, ct).ConfigureAwait(false);
        await upstreamTls.FlushAsync(ct).ConfigureAwait(false);

        // Properly frame the response: read header then body honouring
        // Content-Length OR Transfer-Encoding: chunked. Reading until
        // close (the previous heuristic) hung whenever upstream replied
        // with Connection: keep-alive — which all modern HTTP/1.1
        // servers do by default.
        return await ReadFramedResponseAsync(upstreamTls, ct).ConfigureAwait(false);
    }

    /// <summary>
    /// Read an HTTP/1.1 response from <paramref name="stream"/>,
    /// stopping at the right byte: Content-Length-many for plain
    /// responses, end of last 0-sized chunk for chunked, EOF for
    /// no-framing/HTTP-1.0 cases.
    /// </summary>
    private static async Task<byte[]> ReadFramedResponseAsync(Stream stream, CancellationToken ct)
    {
        using var ms = new MemoryStream();
        var buf = new byte[16 * 1024];

        // Step 1: accumulate bytes until we find the end of the header.
        int headerEnd = -1;
        while (headerEnd < 0)
        {
            var n = await stream.ReadAsync(buf, ct).ConfigureAwait(false);
            if (n <= 0) return ms.ToArray();  // upstream closed mid-header → return what we got
            ms.Write(buf, 0, n);
            headerEnd = FindHeaderEnd(ms.GetBuffer(), (int)ms.Length);
        }

        var headerBytes = ms.GetBuffer().AsSpan(0, headerEnd).ToArray();
        var headerStr = Encoding.ASCII.GetString(headerBytes);
        var bodyStart = headerEnd;
        var alreadyRead = (int)ms.Length - bodyStart;

        // Step 2a: Transfer-Encoding: chunked.
        if (Regex.IsMatch(headerStr, @"(?im)^Transfer-Encoding:\s*chunked\s*$"))
        {
            await ReadChunkedAsync(stream, ms, alreadyRead, ct).ConfigureAwait(false);
            return ms.ToArray();
        }

        // Step 2b: Content-Length present.
        var clMatch = Regex.Match(headerStr, @"(?im)^Content-Length:\s*(\d+)\s*$");
        if (clMatch.Success && int.TryParse(clMatch.Groups[1].Value, out var contentLength))
        {
            await ReadExactlyAsync(stream, ms, contentLength - alreadyRead, ct).ConfigureAwait(false);
            return ms.ToArray();
        }

        // Step 2c: HEAD / 204 / 304 → no body.
        var statusMatch = Regex.Match(headerStr, @"^HTTP/\S+\s+(\d{3})", RegexOptions.Multiline);
        if (statusMatch.Success && int.TryParse(statusMatch.Groups[1].Value, out var status))
        {
            if (status is 204 or 304 || (status >= 100 && status < 200))
                return ms.ToArray();
        }

        // Step 2d: no framing → read until close.
        while (true)
        {
            int n;
            try { n = await stream.ReadAsync(buf, ct).ConfigureAwait(false); }
            catch (IOException) { break; }
            if (n <= 0) break;
            ms.Write(buf, 0, n);
        }
        return ms.ToArray();
    }

    private static async Task ReadExactlyAsync(Stream stream, MemoryStream sink, int remaining, CancellationToken ct)
    {
        var buf = new byte[16 * 1024];
        while (remaining > 0)
        {
            var want = Math.Min(buf.Length, remaining);
            var n = await stream.ReadAsync(buf.AsMemory(0, want), ct).ConfigureAwait(false);
            if (n <= 0) return;
            sink.Write(buf, 0, n);
            remaining -= n;
        }
    }

    private static async Task ReadChunkedAsync(Stream stream, MemoryStream sink, int prefetched, CancellationToken ct)
    {
        // Read until the chunked terminator (0-length chunk + trailers
        // ending in \r\n\r\n) is present in the buffer. We rescan
        // from the body offset on each new read — chunked responses
        // we typically MITM are small enough that the rescan cost
        // is negligible compared to TLS reads.
        var headerEnd = (int)sink.Length - prefetched;
        var buf = new byte[16 * 1024];
        while (true)
        {
            if (FindChunkedEnd(sink.GetBuffer(), headerEnd, (int)sink.Length)) return;
            var n = await stream.ReadAsync(buf, ct).ConfigureAwait(false);
            if (n <= 0) return;
            sink.Write(buf, 0, n);
        }
    }

    /// <summary>
    /// Walk chunk-by-chunk over <paramref name="body"/> from
    /// <paramref name="start"/> to <paramref name="end"/>, returning
    /// true once we see the canonical chunked terminator
    /// (<c>0\r\n[trailers]\r\n</c>). Fails gracefully on partial /
    /// malformed input — caller just reads more bytes.
    /// </summary>
    private static bool FindChunkedEnd(byte[] body, int start, int end)
    {
        var pos = start;
        while (pos < end)
        {
            var crlf = IndexOfCrLf(body, pos, end);
            if (crlf < 0) return false;
            var sizeLine = Encoding.ASCII.GetString(body, pos, crlf - pos);
            var semi = sizeLine.IndexOf(';');
            if (semi >= 0) sizeLine = sizeLine[..semi];
            if (!int.TryParse(sizeLine.Trim(), System.Globalization.NumberStyles.HexNumber,
                System.Globalization.CultureInfo.InvariantCulture, out var sz)) return false;
            pos = crlf + 2;
            if (sz == 0)
            {
                // Final chunk; trailers (possibly empty) end with \r\n.
                return IndexOfCrLf(body, pos, end) >= 0;
            }
            if (pos + sz + 2 > end) return false;
            pos += sz + 2;
        }
        return false;
    }

    private static int IndexOfCrLf(byte[] body, int start, int end)
    {
        for (var i = start; i < end - 1; i++)
        {
            if (body[i] == 0x0D && body[i + 1] == 0x0A) return i;
        }
        return -1;
    }

    private static int FindHeaderEnd(byte[] buf, int len)
    {
        for (var i = 0; i <= len - 4; i++)
        {
            if (buf[i] == 0x0D && buf[i + 1] == 0x0A
                && buf[i + 2] == 0x0D && buf[i + 3] == 0x0A)
                return i + 4;
        }
        return -1;
    }

    /// <summary>
    /// Replace any <c>Connection:</c> header on the request with
    /// <c>Connection: close</c>, or append one if absent. Lets upstream
    /// signal end-of-response by closing the TCP, which our framing
    /// path uses as a backstop.
    /// </summary>
    private static byte[] ForceConnectionClose(byte[] request)
    {
        var headerEnd = FindHeaderEnd(request, request.Length);
        if (headerEnd < 0) return request;
        var headerStr = Encoding.ASCII.GetString(request, 0, headerEnd);
        var rewritten = Regex.Replace(headerStr,
            @"(?im)^Connection:\s*[^\r\n]*\r\n", "Connection: close\r\n");
        if (!Regex.IsMatch(rewritten, @"(?im)^Connection:\s*close\s*$"))
        {
            // No Connection header at all — insert one before the
            // blank line that ends the headers.
            rewritten = rewritten[..^2] + "Connection: close\r\n\r\n";
        }
        var headBytes = Encoding.ASCII.GetBytes(rewritten);
        var bodyLen = request.Length - headerEnd;
        var outBuf = new byte[headBytes.Length + bodyLen];
        Buffer.BlockCopy(headBytes, 0, outBuf, 0, headBytes.Length);
        Buffer.BlockCopy(request, headerEnd, outBuf, headBytes.Length, bodyLen);
        return outBuf;
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

    // ----------------------------------------------------------------
    // WebSocket upgrade
    // ----------------------------------------------------------------

    /// <summary>
    /// Cheap header parse: HTTP/1.1 WebSocket upgrade requires both
    /// <c>Upgrade: websocket</c> and a <c>Connection</c> header that
    /// includes the <c>upgrade</c> token. Returns false on malformed
    /// requests rather than throwing — falls back to the regular
    /// request/response flow.
    /// </summary>
    private static bool IsWebSocketUpgrade(byte[] request)
    {
        var headerEnd = FindHeaderEnd(request, request.Length);
        if (headerEnd < 0) return false;
        var headers = Encoding.ASCII.GetString(request, 0, headerEnd);
        var hasUpgradeWs = Regex.IsMatch(headers,
            @"(?im)^Upgrade:\s*websocket\s*$");
        var connectionHasUpgrade = Regex.IsMatch(headers,
            @"(?im)^Connection:\s*[^\r\n]*\bupgrade\b[^\r\n]*$");
        return hasUpgradeWs && connectionHasUpgrade;
    }

    /// <summary>
    /// After detecting a WebSocket upgrade, forward the upgrade
    /// request to upstream as-is (no token swap, no Connection: close
    /// rewrite — those would break the handshake), relay the 101
    /// Switching Protocols response back to the client, then pump
    /// bytes bidirectionally between the two TLS streams until either
    /// side closes. Records a basic TraceRecord with the wire-byte
    /// counters at end-of-session.
    ///
    /// <para>This matches what <c>HTTPProxy.handleWebSocketUpgrade</c>
    /// does on the macOS side at a behaviour level. Frame-level
    /// inspection (using <c>WsFrameDecoder</c> / <c>WsInflater</c> for
    /// per-message TraceRecord entries) is a follow-up — the
    /// pass-through here is enough to unblock SaaS dashboards and
    /// streaming agents.</para>
    /// </summary>
    private async Task HandleWebSocketUpgradeAsync(
        string host, int port, byte[] upgradeRequest, SslStream clientTls,
        DateTimeOffset t0, CancellationToken ct)
    {
        // 1) Connect upstream + complete TLS — same as ForwardAsync but
        // we keep the stream alive for the bidirectional pump.
        using var upstream = new TcpClient();
        await upstream.ConnectAsync(host, port, ct).ConfigureAwait(false);
        using var upstreamRaw = upstream.GetStream();
        await using var upstreamTls = new SslStream(upstreamRaw, leaveInnerStreamOpen: true);
        await upstreamTls.AuthenticateAsClientAsync(new SslClientAuthenticationOptions
        {
            TargetHost = host,
            EnabledSslProtocols = SslProtocols.Tls12 | SslProtocols.Tls13,
            ApplicationProtocols = new List<SslApplicationProtocol>
            {
                SslApplicationProtocol.Http11,
            },
        }, ct).ConfigureAwait(false);

        // 2) Forward the upgrade request VERBATIM. If we tampered with
        // Connection / Upgrade / Sec-WebSocket-Key, upstream would
        // refuse the handshake.
        await upstreamTls.WriteAsync(upgradeRequest, ct).ConfigureAwait(false);
        await upstreamTls.FlushAsync(ct).ConfigureAwait(false);

        // 3) Read the upstream response header (always small, single
        // 101 + headers).
        var respHeaderRaw = await ReadHttpHeaderAsync(upstreamTls, 16 * 1024, ct).ConfigureAwait(false);
        if (respHeaderRaw is null) return;
        var respHeaderBytes = Encoding.ASCII.GetBytes(respHeaderRaw);
        await clientTls.WriteAsync(respHeaderBytes, ct).ConfigureAwait(false);
        await clientTls.FlushAsync(ct).ConfigureAwait(false);

        // 4) If upstream rejected the upgrade (anything other than 101)
        // we still relay the body but don't enter pump mode — there
        // are no WebSocket frames to forward.
        if (!respHeaderRaw.StartsWith("HTTP/1.1 101", StringComparison.Ordinal))
        {
            // Drain the upstream body, mirror to client, return.
            var drainBuf = new byte[16 * 1024];
            while (true)
            {
                int n;
                try { n = await upstreamTls.ReadAsync(drainBuf, ct).ConfigureAwait(false); }
                catch (IOException) { break; }
                if (n <= 0) break;
                await clientTls.WriteAsync(drainBuf.AsMemory(0, n), ct).ConfigureAwait(false);
            }
            return;
        }

        // 5) Bidirectional pump until either side closes. Tally bytes
        // for the trace.
        long upBytes = 0, downBytes = 0;
        var clientToUpstream = Task.Run(async () =>
        {
            var buf = new byte[16 * 1024];
            while (!ct.IsCancellationRequested)
            {
                int n;
                try { n = await clientTls.ReadAsync(buf, ct).ConfigureAwait(false); }
                catch { return; }
                if (n <= 0) return;
                Interlocked.Add(ref upBytes, n);
                try { await upstreamTls.WriteAsync(buf.AsMemory(0, n), ct).ConfigureAwait(false); }
                catch { return; }
            }
        }, ct);
        var upstreamToClient = Task.Run(async () =>
        {
            var buf = new byte[16 * 1024];
            while (!ct.IsCancellationRequested)
            {
                int n;
                try { n = await upstreamTls.ReadAsync(buf, ct).ConfigureAwait(false); }
                catch { return; }
                if (n <= 0) return;
                Interlocked.Add(ref downBytes, n);
                try { await clientTls.WriteAsync(buf.AsMemory(0, n), ct).ConfigureAwait(false); }
                catch { return; }
            }
        }, ct);

        // Either direction ending kills the session.
        await Task.WhenAny(clientToUpstream, upstreamToClient).ConfigureAwait(false);

        // 6) Trace.
        _traceStore?.Record(new TraceRecord(
            Id: Guid.NewGuid(),
            SessionId: Guid.Empty,
            ProfileId: _profileId,
            Timestamp: t0,
            Host: host,
            Port: port,
            Method: "GET",
            Path: ExtractPath(upgradeRequest),
            StatusCode: 101,
            RequestBytes: upgradeRequest.Length + (int)Interlocked.Read(ref upBytes),
            ResponseBytes: respHeaderBytes.Length + (int)Interlocked.Read(ref downBytes),
            LatencyMs: (DateTimeOffset.UtcNow - t0).TotalMilliseconds,
            Swaps: Array.Empty<SwapEntry>(),
            Leaks: Array.Empty<LeakEntry>(),
            BodyStored: false,
            IsConversation: false));
    }
}
