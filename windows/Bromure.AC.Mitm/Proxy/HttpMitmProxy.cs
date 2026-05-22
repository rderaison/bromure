// macos-source: Sources/AgentCoding/Mitm/HTTPProxy.swift @ 875b644e56b1
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Text;
using System.Text.RegularExpressions;
using Bromure.AC.Mitm.Consent;
using Bromure.AC.Mitm.Engine;
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
    private readonly IBodyEncryptor? _bodyEncryptor;
    private readonly ClientIdentityRegistry? _clientIdentities;
    private readonly ClusterCaTrustRegistry? _clusterCaTrust;
    private readonly ConsentBroker? _consent;
    private readonly Func<MitmEngine.SessionTrace?>? _sessionTraceProvider;
    private readonly Action<Guid, string, System.Text.Json.Nodes.JsonObject>? _onCloudEvent;
    private readonly Action<Guid, string>? _onSubscriptionTokenSeen;
    private readonly Action<Guid, string>? _onCodexTokenSeen;
    private readonly Action<Guid, Bromure.AC.Mitm.OAuth.OAuthRotationProvider, Bromure.AC.Mitm.OAuth.StoredOAuthTokens>? _onOAuthRotated;
    private readonly Bromure.AC.Mitm.Swap.CompromiseDetector? _bodyScanDetector;
    private readonly ILogger _log;
    private readonly Guid _profileId;
    private TcpListener? _listener;
    private TcpListener? _listenerV4;     // optional second listener for dual-stack
    private CancellationTokenSource? _cts;
    private Task? _acceptLoop;
    private Task? _acceptLoopV4;

    public HttpMitmProxy(
        Guid profileId,
        TokenSwapper swapper,
        AwsResigner awsResigner,
        CertCache certCache,
        TraceStore? traceStore = null,
        IBodyEncryptor? bodyEncryptor = null,
        ClientIdentityRegistry? clientIdentities = null,
        ClusterCaTrustRegistry? clusterCaTrust = null,
        ConsentBroker? consent = null,
        Func<MitmEngine.SessionTrace?>? sessionTraceProvider = null,
        Action<Guid, string, System.Text.Json.Nodes.JsonObject>? onCloudEvent = null,
        Action<Guid, string>? onSubscriptionTokenSeen = null,
        Action<Guid, string>? onCodexTokenSeen = null,
        Action<Guid, Bromure.AC.Mitm.OAuth.OAuthRotationProvider, Bromure.AC.Mitm.OAuth.StoredOAuthTokens>? onOAuthRotated = null,
        Bromure.AC.Mitm.Swap.CompromiseDetector? bodyScanDetector = null,
        ILogger? log = null)
    {
        _profileId = profileId;
        _swapper = swapper;
        _awsResigner = awsResigner;
        _certCache = certCache;
        _traceStore = traceStore;
        _bodyEncryptor = bodyEncryptor;
        _clientIdentities = clientIdentities;
        _clusterCaTrust = clusterCaTrust;
        _consent = consent;
        _sessionTraceProvider = sessionTraceProvider;
        _onCloudEvent = onCloudEvent;
        _onSubscriptionTokenSeen = onSubscriptionTokenSeen;
        _onCodexTokenSeen = onCodexTokenSeen;
        _onOAuthRotated = onOAuthRotated;
        _bodyScanDetector = bodyScanDetector;
        _log = log ?? NullLogger.Instance;
    }

    /// <summary>
    /// Fire the subscription / Codex token-seen callbacks when the
    /// host matches the expected scope and the swapper detects a
    /// clean OAuth access token. Extracted from the swap path so
    /// tests can exercise the exact decision logic the proxy uses
    /// without mounting full TLS-MITM.
    /// </summary>
    internal void FireSubscriptionTokenSeenIfApplicable(string host, byte[] rawRequest)
    {
        if (_onSubscriptionTokenSeen is not null && IsAnthropicHost(host))
        {
            if (_swapper.DetectSubscriptionAccessToken(rawRequest, _profileId) is { } cleanTok)
            {
                try { _onSubscriptionTokenSeen(_profileId, cleanTok); }
                catch (Exception ex) { _log.LogDebug(ex, "SubscriptionTokenSeen handler threw"); }
            }
        }
        if (_onCodexTokenSeen is not null && IsCodexHost(host))
        {
            if (_swapper.DetectCodexAccessToken(rawRequest, _profileId) is { } cleanTok)
            {
                try { _onCodexTokenSeen(_profileId, cleanTok); }
                catch (Exception ex) { _log.LogDebug(ex, "CodexTokenSeen handler threw"); }
            }
        }
    }

    /// <summary>macOS HTTPProxy.swift:182 — anthropic.com itself or
    /// any subdomain. case-insensitive.</summary>
    internal static bool IsAnthropicHost(string host)
        => host.Equals("api.anthropic.com", StringComparison.OrdinalIgnoreCase)
           || host.EndsWith(".anthropic.com", StringComparison.OrdinalIgnoreCase);

    /// <summary>macOS HTTPProxy.swift:191 — chatgpt.com (incl.
    /// subdomains), auth.openai.com, api.openai.com.</summary>
    internal static bool IsCodexHost(string host)
        => host.Equals("chatgpt.com", StringComparison.OrdinalIgnoreCase)
           || host.EndsWith(".chatgpt.com", StringComparison.OrdinalIgnoreCase)
           || host.Equals("auth.openai.com", StringComparison.OrdinalIgnoreCase)
           || host.Equals("api.openai.com", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// Gate every <see cref="_traceStore"/> persist + body capture on
    /// the profile's current trace level. Mirrors macOS
    /// <c>HTTPProxy.sessionTraceProvider</c> + <c>level.recordsActivity</c>.
    /// </summary>
    private bool ShouldRecordTrace()
    {
        var t = _sessionTraceProvider?.Invoke();
        if (t is null) return _traceStore is not null;  // no per-session config → on by default
        return t.Level != Trace.TraceLevel.Off;
    }

    public IPEndPoint? LocalEndpoint =>
        _listener?.LocalEndpoint as IPEndPoint;

    public Task StartAsync(IPEndPoint endpoint, CancellationToken ct = default)
    {
        if (_listener is not null) throw new InvalidOperationException("Already started");
        _cts = CancellationTokenSource.CreateLinkedTokenSource(ct);

        // Specific non-loopback IP: honour caller's choice verbatim,
        // single listener. Loopback / Any: bind BOTH IPv4 and IPv6
        // on the same port so the VM can dial either stack.
        // Audit 02 #3 fix: VM dialing [::1]:<port> used to fail.
        if (!endpoint.Address.Equals(IPAddress.Loopback)
            && !endpoint.Address.Equals(IPAddress.Any))
        {
            _listener = new TcpListener(endpoint);
            _listener.Start();
            _acceptLoop = Task.Run(() => AcceptLoopAsync(_listener, _cts.Token));
            return Task.CompletedTask;
        }

        var v4Addr = endpoint.Address.Equals(IPAddress.Any) ? IPAddress.Any : IPAddress.Loopback;
        var v6Addr = endpoint.Address.Equals(IPAddress.Any) ? IPAddress.IPv6Any : IPAddress.IPv6Loopback;
        // Bind IPv4 first to get a concrete port number, then bind
        // the IPv6 listener on the same port. (Inverted order can
        // fail if the IPv6 socket grabs DualMode + the kernel binds
        // both stacks for us — Windows DualMode behaviour varies
        // between builds, so we use two explicit listeners.)
        _listener = new TcpListener(v4Addr, endpoint.Port);
        _listener.Start();
        var boundPort = ((IPEndPoint)_listener.LocalEndpoint).Port;
        try
        {
            _listenerV4 = _listener;
            _listener = new TcpListener(v6Addr, boundPort);
            _listener.Start();
            _acceptLoop = Task.Run(() => AcceptLoopAsync(_listener, _cts.Token));
            _acceptLoopV4 = Task.Run(() => AcceptLoopAsync(_listenerV4, _cts.Token));
        }
        catch (SocketException)
        {
            // IPv6 binding failed (very old Windows build, IPv6 disabled
            // at the network stack). Fall back to IPv4-only — better
            // than failing the whole proxy.
            _listener = _listenerV4!;
            _listenerV4 = null;
            _acceptLoop = Task.Run(() => AcceptLoopAsync(_listener, _cts.Token));
        }
        return Task.CompletedTask;
    }

    private async Task AcceptLoopAsync(TcpListener listener, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            TcpClient client;
            try
            {
                client = await listener.AcceptTcpClientAsync(ct).ConfigureAwait(false);
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

        // 4a. MCP discovery block. For hosts we're brokering as MCP
        // servers (any swap entry has a brm-mcp_* fake), short-circuit
        // OAuth/OIDC discovery probes so the in-VM client can't find
        // and bypass the broker. Mirrors macOS HTTPProxy step 4a.
        var requestPath = ExtractPath(wrapped);
        if (_swapper.HostHasMcpBearer(host, _profileId)
            && McpProxyHooks.IsOauthDiscoveryPath(requestPath))
        {
            await tlsServer.WriteAsync(McpProxyHooks.BuildDiscoveryBlockedResponse(), ct).ConfigureAwait(false);
            return;
        }

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

        // 5'. Body-scan compromise detection. Audit 03 #1 — DetectLeaks
        // above is header-only; this scans the entire pre-swap
        // request (headers + body) for any of the per-profile fake
        // tokens being sent to a host outside the fake's declared
        // scope. The detector's scanner is auto-rebuilt by
        // MitmEngine whenever the swap map mutates (initial set,
        // OAuth rotation, subscription-token coordinator append).
        if (_bodyScanDetector is not null)
        {
            var compromises = _bodyScanDetector.Scan(_profileId, wrapped, host);
            if (compromises.Count > 0)
            {
                // Surface every cross-scope leak as a compromise
                // event. The engine's per-profile flag-file handler
                // sees these and refuses next-launch boots. The
                // detector's CompromiseLeak shape is converted to
                // the swapper's LeakReport shape so existing event
                // sinks don't need a new branch.
                var reports = compromises.Select(c => new LeakReport(
                        Header: c.CredentialDisplayName,
                        ValuePreview: c.FakeTokenPreview,
                        Suspicion: LeakSuspicionKind.OpaqueToken))
                    .ToList();
                _swapper.FireCompromise(new CompromiseEvent(
                    ProfileId: _profileId,
                    ObservedHost: host,
                    Leaks: reports,
                    Timestamp: DateTimeOffset.UtcNow));
            }
        }

        // 5a. Subscription-token detection. Surface a clean
        // `sk-ant-oat01-…` on anthropic.com or a clean Codex JWT on
        // chatgpt.com / openai.com to the host so the coordinator can
        // prompt the user once per session. Fire-and-forget — the
        // request still forwards as-is; the swap kicks in on the
        // *next* outbound request once the user accepts. Mirrors macOS
        // HTTPProxy.swift:182-198.
        FireSubscriptionTokenSeenIfApplicable(host, swapResult.Modified);

        // 5b. MCP bearer injection. OAuth-brokered MCP servers don't put
        // bearerTokenEnvVar in the config, so the agent issues requests
        // with no Authorization header — the proxy injects the real
        // bearer on the wire. Mirrors macOS HTTPProxy step 5b.
        if (_swapper.RealForMcpHost(host, _profileId) is { } mcpReal)
        {
            requestBytes = McpProxyHooks.InjectMcpBearer(requestBytes, mcpReal);
        }

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

        // 6. Open upstream TCP+TLS, write request, stream/buffer response.
        // ForwardAsync returns null when it streamed the response
        // directly back to clientTls (SSE / chunked-without-end), in
        // which case there's nothing left for us to do — token swap +
        // OAuth rotation rewriter never apply to streaming bodies.
        byte[]? responseBytes;
        try
        {
            responseBytes = await ForwardAsync(host, port, requestBytes, tlsServer, ct).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "Upstream forwarding to {Host}:{Port} failed", host, port);
            await tlsServer.WriteAsync(MakeBadGateway($"upstream {host}:{port}: {ex.Message}"), ct);
            return;
        }
        if (responseBytes is null)
        {
            // Streaming path already wrote to clientTls. Emit a stub
            // trace entry so the call shows up in the inspector.
            _traceStore?.Record(new TraceRecord(
                Id: Guid.NewGuid(),
                SessionId: Guid.Empty,
                ProfileId: _profileId,
                Timestamp: t0,
                Host: host,
                Port: port,
                Method: ExtractMethod(requestBytes),
                Path: ExtractPath(requestBytes),
                StatusCode: 200,                // best-effort; real status was relayed
                RequestBytes: requestBytes.Length,
                ResponseBytes: 0,                // streamed; not buffered
                LatencyMs: (DateTimeOffset.UtcNow - t0).TotalMilliseconds,
                Swaps: swapResult.Swaps.Select(s => new SwapEntry(
                    Header: "Authorization",
                    FakePreview: s.FakePreview,
                    RealPreview: s.RealPreview)).ToArray(),
                Leaks: Array.Empty<LeakEntry>(),
                BodyStored: false));
            return;
        }

        // 7. OAuth rotation rewriter on the response path.
        var rewriterProvider = OAuthRotationRewriter.ProviderFor(host, ExtractPath(requestBytes));
        if (rewriterProvider is { } prov)
        {
            var rotated = OAuthRotationRewriter.Rewrite(responseBytes, prov, _profileId, _swapper);
            responseBytes = rotated.Bytes;
            // Audit 07 §4 recordRotation: surface the fresh real
            // tokens so the host can update the profile's stored
            // defaults — without this, the next session boot sees
            // expired tokens. macOS does this via
            // SubscriptionTokenCoordinator.recordRotation.
            if (rotated.NewReals is { } newReals && _onOAuthRotated is not null)
            {
                try { _onOAuthRotated(_profileId, prov, newReals); }
                catch (Exception ex) { _log.LogDebug(ex, "OAuthRotated handler threw"); }
            }
        }

        await tlsServer.WriteAsync(responseBytes, ct).ConfigureAwait(false);

        // 7b. Audit trail: emit a credential.token_swap cloud event
        // for every fake → real substitution that just left the VM.
        // Previews only — real values stay in memory.
        EmitSwapAuditEvents(host, ExtractPath(requestBytes), swapResult.Swaps);

        // 7c. LLM audit. Parse the exchange and emit llm.request +
        // tool.use / file.* / command.run events. Independent of the
        // trace gate — admin telemetry should fire even when raw
        // bodies aren't kept.
        EmitLlmAuditEvents(host, ExtractPath(requestBytes), ExtractStatus(responseBytes),
            (DateTimeOffset.UtcNow - t0).TotalMilliseconds, requestBytes, responseBytes);

        // 8. Trace. Skip persistence when this profile's
        // SessionTrace level is Off — matches macOS's
        // sessionTraceProvider gating.
        if (!ShouldRecordTrace()) return;

        // Capture redacted bodies for the inspector when they're
        // text-like and under the per-record cap. Mirrors macOS
        // HTTPProxy.emitTrace's redact + bodyForTrace gate.
        var requestForTrace = TraceBodyRedactor.BodyForTrace(
            TraceBodyRedactor.RedactSensitiveHeaders(wrapped));
        var responseForTrace = TraceBodyRedactor.BodyForTrace(
            TraceBodyRedactor.RedactSensitiveHeaders(responseBytes));
        var bodyStored = requestForTrace is not null || responseForTrace is not null;

        _traceStore?.Record(
            new TraceRecord(
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
                BodyStored: bodyStored),
            requestBody: requestForTrace ?? Array.Empty<byte>(),
            responseBody: responseForTrace ?? Array.Empty<byte>(),
            encryptor: _bodyEncryptor);
    }

    /// <summary>
    /// Forward the swapped request to upstream and bring back the
    /// response. Returns the buffered response bytes for the caller to
    /// rewrite (OAuth rotation, etc.) and write to the client; OR
    /// returns null when the response is streamed (SSE / open chunked)
    /// and we've already pumped it to <paramref name="clientTls"/>
    /// directly. Streaming bypasses response-side rewriting because
    /// the affected endpoints never serve text/event-stream.
    /// </summary>
    private async Task<byte[]?> ForwardAsync(string host, int port, byte[] requestBytes, SslStream clientTls, CancellationToken ct)
    {
        using var upstream = new TcpClient();
        await upstream.ConnectAsync(host, port, ct).ConfigureAwait(false);
        using var upstreamRaw = upstream.GetStream();

        // Per-host overrides for client cert + server CA — what the
        // macOS port runs through URLSession's challenge delegate.
        // ClientIdentities + ClusterCaTrust come from MitmEngine; both
        // are profile-scoped. With them set, kubectl through the
        // proxy can reach private k8s clusters whose API servers ask
        // for client mTLS or whose chain doesn't anchor to Windows's
        // root store.
        // Look up the per-host client identity (kubeconfig / internal
        // mTLS) and gate it through the consent broker if the entry is
        // flagged. Mirrors macOS HTTPProxy.swift line 1414 challenge
        // handler — when the user denies, abort the upstream connect
        // entirely so kubectl sees the broken handshake instead of a
        // silently-anonymous request.
        var identityEntry = _clientIdentities?.EntryFor(host, _profileId);
        if (identityEntry?.ConsentCredentialId is { } credId && _consent is not null)
        {
            var display = identityEntry.ConsentDisplayName ?? credId;
            var allowed = await _consent.RequestConsentAsync(
                _profileId, credId, display,
                $"to authenticate with the API server at {host}", ct).ConfigureAwait(false);
            if (!allowed)
            {
                _log.LogInformation("[mitm] mTLS denied by consent host={Host} cred={Cred}", host, credId);
                return null;
            }
        }
        var identity = identityEntry?.Identity;
        var clusterCa = _clusterCaTrust?.CaFor(host, _profileId);

        var validationCallback = clusterCa is null
            ? (RemoteCertificateValidationCallback?)null
            : MakeClusterCaValidator(clusterCa);

        await using var upstreamTls = validationCallback is null
            ? new SslStream(upstreamRaw, leaveInnerStreamOpen: true)
            : new SslStream(upstreamRaw, leaveInnerStreamOpen: true, validationCallback);

        var options = new SslClientAuthenticationOptions
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
        };
        if (identity is not null)
        {
            options.ClientCertificates = new System.Security.Cryptography.X509Certificates.X509CertificateCollection
            {
                identity,
            };
        }
        await upstreamTls.AuthenticateAsClientAsync(options, ct).ConfigureAwait(false);

        // Force Connection: close on the forwarded request so upstream
        // closes the TCP after the response — frees us from having to
        // honour keep-alive on the upstream side. Body framing below
        // is the primary mechanism; close is the backstop.
        // Exception: SSE / streaming endpoints often want keep-alive
        // (they hold the TCP open indefinitely). We can't tell yet at
        // request-send time; the response Content-Type tells us. If
        // upstream sends Connection: close back along with the SSE
        // body, our pump still works — we just close when upstream
        // closes.
        var rewritten = ForceConnectionClose(requestBytes);
        await upstreamTls.WriteAsync(rewritten, ct).ConfigureAwait(false);
        await upstreamTls.FlushAsync(ct).ConfigureAwait(false);

        // Read upstream's response header. Capture any leftover bytes
        // that arrived in the same TCP read — TLS frequently bundles
        // header + first body chunk together, and dropping them on the
        // floor truncates the body downstream.
        var (headerStr, leftover) = await ReadHttpHeaderWithLeftoverAsync(
            upstreamTls, 64 * 1024, ct).ConfigureAwait(false);
        if (headerStr is null) return Array.Empty<byte>();
        var headerBytes = Encoding.ASCII.GetBytes(headerStr);

        // Streaming pivot: text/event-stream → pump bytes directly to
        // client. Rewriting the response (OAuth rotation, etc.) doesn't
        // apply here — the affected endpoints (OAuth refresh) are
        // request/response JSON, not streaming.
        var isSse = Regex.IsMatch(headerStr, @"(?im)^Content-Type:\s*text/event-stream");
        if (isSse)
        {
            await clientTls.WriteAsync(headerBytes, ct).ConfigureAwait(false);
            if (leftover.Length > 0)
            {
                await clientTls.WriteAsync(leftover, ct).ConfigureAwait(false);
            }
            await clientTls.FlushAsync(ct).ConfigureAwait(false);
            await PumpStreamAsync(upstreamTls, clientTls, ct).ConfigureAwait(false);
            return null;
        }

        // Non-streaming: read the framed body fully so the caller can
        // run rewriters over it. Seed the sink with the leftover bytes
        // so framing detection (Content-Length / chunked) sees them.
        var ms = new MemoryStream();
        ms.Write(headerBytes, 0, headerBytes.Length);
        await ReadFramedBodyAsync(upstreamTls, ms, headerStr, leftover, ct).ConfigureAwait(false);
        return ms.ToArray();
    }

    /// <summary>
    /// Emit one <c>credential.token_swap</c> cloud event per swap.
    /// Mirrors macOS <c>HTTPProxy.emitTrace</c>'s audit-trail loop.
    /// Previews only; real bytes never enter the event payload.
    /// </summary>
    private void EmitSwapAuditEvents(string host, string path, IReadOnlyList<SwapRecord> swaps)
    {
        if (_onCloudEvent is null || swaps.Count == 0) return;
        foreach (var s in swaps)
        {
            var data = new System.Text.Json.Nodes.JsonObject
            {
                ["host"] = host,
                ["path"] = path,
                ["fake_preview"] = s.FakePreview,
                ["real_preview"] = s.RealPreview,
            };
            try { _onCloudEvent(_profileId, "credential.token_swap", data); }
            catch (Exception ex) { _log.LogDebug(ex, "cloud-event swap emit threw"); }
        }
    }

    /// <summary>
    /// Parse the captured LLM exchange and forward audit events
    /// (<c>llm.request</c>, <c>tool.use</c>, <c>file.read</c>,
    /// <c>file.write</c>, <c>command.run</c>) through the cloud sink.
    /// Best-effort — parser failures are swallowed so a malformed
    /// upstream body never breaks proxying.
    /// </summary>
    private void EmitLlmAuditEvents(string host, string path, int statusCode,
        double latencyMs, byte[] requestBytes, byte[] responseBytes)
    {
        if (_onCloudEvent is null) return;
        Conversation.Conversation? convo;
        try
        {
            convo = Conversation.ConversationParser.Parse(host, requestBytes, responseBytes);
        }
        catch (Exception ex)
        {
            _log.LogDebug(ex, "conversation parse threw host={Host}", host);
            return;
        }
        if (convo is null) return;
        try
        {
            Conversation.ConversationEventEmitter.Emit(
                _profileId, host, path, statusCode, latencyMs,
                responseBytes, convo, _onCloudEvent);
        }
        catch (Exception ex)
        {
            _log.LogDebug(ex, "llm audit emit threw host={Host}", host);
        }
    }

    /// <summary>
    /// Build a <see cref="RemoteCertificateValidationCallback"/> that
    /// anchors server-trust evaluation against <paramref name="clusterCa"/>
    /// in addition to the system trust store. Used for private k8s
    /// API servers whose chains don't appear in Windows's roots.
    /// </summary>
    private static RemoteCertificateValidationCallback MakeClusterCaValidator(
        System.Security.Cryptography.X509Certificates.X509Certificate2 clusterCa)
    {
        return (sender, peerCert, chain, policyErrors) =>
        {
            // The default chain build (chain != null) already ran. If
            // it succeeded, accept. We only override on failure to
            // anchor against our extra CA.
            if (policyErrors == System.Net.Security.SslPolicyErrors.None) return true;
            if (peerCert is null) return false;

            using var custom = new System.Security.Cryptography.X509Certificates.X509Chain();
            custom.ChainPolicy.RevocationMode =
                System.Security.Cryptography.X509Certificates.X509RevocationMode.NoCheck;
            custom.ChainPolicy.TrustMode =
                System.Security.Cryptography.X509Certificates.X509ChainTrustMode.CustomRootTrust;
            custom.ChainPolicy.CustomTrustStore.Add(clusterCa);
            custom.ChainPolicy.ExtraStore.Add(clusterCa);
            // Some clusters serve a chain with the leaf only — extras
            // from the original chain (if any) help.
            if (chain is not null)
            {
                foreach (var element in chain.ChainElements)
                {
                    custom.ChainPolicy.ExtraStore.Add(element.Certificate);
                }
            }
            return custom.Build(
                new System.Security.Cryptography.X509Certificates.X509Certificate2(peerCert));
        };
    }

    /// <summary>
    /// Pump bytes from upstream to client until upstream closes or
    /// errors out. Used for SSE streams where we can't know the body
    /// length up front and the user wants chunks delivered immediately
    /// (LLM tokens streaming in real time).
    /// </summary>
    private static async Task PumpStreamAsync(SslStream upstream, SslStream client, CancellationToken ct)
    {
        var buf = new byte[16 * 1024];
        while (!ct.IsCancellationRequested)
        {
            int n;
            try { n = await upstream.ReadAsync(buf, ct).ConfigureAwait(false); }
            catch { return; }
            if (n <= 0) return;
            try { await client.WriteAsync(buf.AsMemory(0, n), ct).ConfigureAwait(false); }
            catch { return; }
            try { await client.FlushAsync(ct).ConfigureAwait(false); }
            catch { return; }
        }
    }

    /// <summary>
    /// Used by the non-streaming path. Header has already been read
    /// + written to <paramref name="sink"/>; this consumes the body
    /// honouring Content-Length / chunked / no-body status codes /
    /// connection close.
    /// </summary>
    private static async Task ReadFramedBodyAsync(Stream stream, MemoryStream sink, string headerStr,
        byte[] leftover, CancellationToken ct)
    {
        // Account for body bytes that arrived in the same TCP read as
        // the header. They're already written to `sink`'s body region
        // by the caller, so just adjust counters and skip them on the
        // wire-read paths.
        if (leftover.Length > 0) sink.Write(leftover, 0, leftover.Length);
        var prefetched = leftover.Length;

        // Transfer-Encoding: chunked.
        if (Regex.IsMatch(headerStr, @"(?im)^Transfer-Encoding:\s*chunked\s*$"))
        {
            await ReadChunkedAsync(stream, sink, prefetched: prefetched, ct).ConfigureAwait(false);
            return;
        }
        // Content-Length.
        var clMatch = Regex.Match(headerStr, @"(?im)^Content-Length:\s*(\d+)\s*$");
        if (clMatch.Success && int.TryParse(clMatch.Groups[1].Value, out var contentLength))
        {
            var remaining = contentLength - prefetched;
            if (remaining > 0)
            {
                await ReadExactlyAsync(stream, sink, remaining, ct).ConfigureAwait(false);
            }
            return;
        }
        // No-body status codes.
        var statusMatch = Regex.Match(headerStr, @"^HTTP/\S+\s+(\d{3})", RegexOptions.Multiline);
        if (statusMatch.Success && int.TryParse(statusMatch.Groups[1].Value, out var status))
        {
            if (status is 204 or 304 || (status >= 100 && status < 200)) return;
        }
        // Read until close.
        var buf = new byte[16 * 1024];
        while (true)
        {
            int n;
            try { n = await stream.ReadAsync(buf, ct).ConfigureAwait(false); }
            catch (IOException) { break; }
            if (n <= 0) break;
            sink.Write(buf, 0, n);
        }
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

    /// <summary>
    /// Read until the first <c>\r\n\r\n</c> on <paramref name="stream"/>
    /// and return the header string. The wrapper around it is what
    /// callers actually use; this thin overload exists for the few
    /// sites that don't care about post-header leftover (request-line
    /// only, e.g. CONNECT).
    /// </summary>
    private static async Task<string?> ReadHttpHeaderAsync(Stream stream, int maxBytes, CancellationToken ct)
    {
        var (header, _) = await ReadHttpHeaderWithLeftoverAsync(stream, maxBytes, ct).ConfigureAwait(false);
        return header;
    }

    /// <summary>
    /// Read until the first <c>\r\n\r\n</c> and return both the header
    /// string AND any post-header bytes that arrived in the same TCP
    /// read. With TLS framing, upstream regularly bundles a chunk of
    /// the body into the same record as the headers — discarding those
    /// bytes silently truncates the body and curl prints "transfer
    /// closed with N bytes remaining". Callers that go on to read the
    /// body MUST prepend <c>leftover</c> to the body stream.
    /// </summary>
    internal static async Task<(string? Header, byte[] Leftover)> ReadHttpHeaderWithLeftoverAsync(
        Stream stream, int maxBytes, CancellationToken ct)
    {
        var buf = new byte[maxBytes];
        var got = 0;
        while (got < maxBytes)
        {
            var n = await stream.ReadAsync(buf.AsMemory(got, maxBytes - got), ct).ConfigureAwait(false);
            if (n == 0) return (null, Array.Empty<byte>());
            got += n;
            for (var i = 0; i <= got - 4; i++)
            {
                if (buf[i] == 0x0D && buf[i + 1] == 0x0A
                    && buf[i + 2] == 0x0D && buf[i + 3] == 0x0A)
                {
                    var header = Encoding.ASCII.GetString(buf, 0, i + 4);
                    var leftoverLen = got - (i + 4);
                    var leftover = leftoverLen > 0
                        ? buf.AsSpan(i + 4, leftoverLen).ToArray()
                        : Array.Empty<byte>();
                    return (header, leftover);
                }
            }
        }
        return (null, Array.Empty<byte>());
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
        try { _listenerV4?.Stop(); } catch { }
        if (_acceptLoop is not null)
        {
            try { await _acceptLoop.ConfigureAwait(false); } catch { }
        }
        if (_acceptLoopV4 is not null)
        {
            try { await _acceptLoopV4.ConfigureAwait(false); } catch { }
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
        // 101 + headers). Capture leftover too — WS upgrades frequently
        // bundle the first server-side frame in the same TCP read,
        // which would otherwise be lost.
        var (respHeaderRaw, respLeftover) = await ReadHttpHeaderWithLeftoverAsync(
            upstreamTls, 16 * 1024, ct).ConfigureAwait(false);
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
            if (respLeftover.Length > 0)
            {
                await clientTls.WriteAsync(respLeftover, ct).ConfigureAwait(false);
            }
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

        // 5) Bidirectional pump until either side closes. The
        // upstream→client direction also feeds a frame-level
        // assembler when the host serves OpenAI Realtime / Codex
        // sessions, so RealtimeEventTap can count response.completed
        // events for the trace inspector. permessage-deflate is
        // detected from the 101 response's
        // Sec-WebSocket-Extensions header.
        var pmDeflate = System.Text.RegularExpressions.Regex.IsMatch(
            respHeaderRaw, @"(?im)^Sec-WebSocket-Extensions:[^\r\n]*permessage-deflate");
        var serverNoCtx = System.Text.RegularExpressions.Regex.IsMatch(
            respHeaderRaw, @"(?im)^Sec-WebSocket-Extensions:[^\r\n]*server_no_context_takeover");
        // Two transcript collectors — one per direction. The client→
        // upstream side has no realtime tap (the tap consumes server
        // events) but still records the transcript so the parser can
        // walk the user turns. Permessage-deflate parameters apply to
        // both directions equally per RFC 7692.
        var c2uCollector = new WebSocket.WsTranscriptCollector(
            WebSocket.WsTranscriptCollector.Direction.ClientToUpstream, pmDeflate, serverNoCtx);
        var u2cCollector = new WebSocket.WsTranscriptCollector(
            WebSocket.WsTranscriptCollector.Direction.UpstreamToClient, pmDeflate, serverNoCtx);
        var realtimeTap = WebSocket.RealtimeEventTap.ShouldTap(host)
            ? new WebSocket.RealtimeEventTap(_profileId, host, ExtractPath(upgradeRequest), 101, _log, _onCloudEvent)
            : null;

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
                try { c2uCollector.Feed(buf.AsSpan(0, n)); }
                catch (Exception ex) { _log.LogDebug(ex, "WS c2u collector threw — continuing"); }
                try { await upstreamTls.WriteAsync(buf.AsMemory(0, n), ct).ConfigureAwait(false); }
                catch { return; }
            }
        }, ct);
        var upstreamToClient = Task.Run(async () =>
        {
            // Replay the post-101 leftover bytes first so the first
            // server frame doesn't get dropped when upstream bundled
            // it into the same TLS record as the upgrade response.
            if (respLeftover.Length > 0)
            {
                Interlocked.Add(ref downBytes, respLeftover.Length);
                try
                {
                    u2cCollector.FeedWithTap(respLeftover.AsSpan(),
                        realtimeTap is null ? null : realtimeTap.Handle);
                }
                catch (Exception ex)
                {
                    _log.LogDebug(ex, "WS u2c leftover threw — continuing pump");
                }
                try { await clientTls.WriteAsync(respLeftover, ct).ConfigureAwait(false); }
                catch { return; }
            }
            var buf = new byte[16 * 1024];
            while (!ct.IsCancellationRequested)
            {
                int n;
                try { n = await upstreamTls.ReadAsync(buf, ct).ConfigureAwait(false); }
                catch { return; }
                if (n <= 0) return;
                Interlocked.Add(ref downBytes, n);
                try
                {
                    u2cCollector.FeedWithTap(buf.AsSpan(0, n),
                        realtimeTap is null ? null : realtimeTap.Handle);
                }
                catch (Exception ex)
                {
                    _log.LogDebug(ex, "WS u2c collector/tap threw — continuing pump");
                }
                try { await clientTls.WriteAsync(buf.AsMemory(0, n), ct).ConfigureAwait(false); }
                catch { return; }
            }
        }, ct);

        // Either direction ending kills the session.
        await Task.WhenAny(clientToUpstream, upstreamToClient).ConfigureAwait(false);
        c2uCollector.Dispose();
        u2cCollector.Dispose();

        // 6) Trace. Render the chronologically-merged transcript and
        // store it as the response body so the inspector + the
        // conversation parser can walk it. The handshake's response
        // header precedes the transcript so existing trace pipeline
        // serves it unchanged.
        var transcriptStored = false;
        byte[]? transcriptBytes = null;
        if (_traceStore is not null && ShouldRecordTrace())
        {
            try
            {
                var transcript = WebSocket.WsTranscriptRenderer.Render(c2uCollector, u2cCollector);
                var combined = new byte[respHeaderBytes.Length + 1 + transcript.Length];
                Buffer.BlockCopy(respHeaderBytes, 0, combined, 0, respHeaderBytes.Length);
                combined[respHeaderBytes.Length] = (byte)'\n';
                Buffer.BlockCopy(transcript, 0, combined, respHeaderBytes.Length + 1, transcript.Length);
                transcriptBytes = combined;
                transcriptStored = true;
            }
            catch (Exception ex)
            {
                _log.LogDebug(ex, "WS transcript render threw — recording without body");
            }
        }
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
            BodyStored: transcriptStored,
            IsConversation: transcriptStored && WebSocket.RealtimeEventTap.ShouldTap(host)),
            requestBody: ReadOnlySpan<byte>.Empty,
            responseBody: transcriptBytes ?? ReadOnlySpan<byte>.Empty,
            encryptor: _bodyEncryptor);
    }
}
