// macos-source: Sources/AgentCoding/Mitm/MitmEngine.swift @ 546d34bf9dd8
using System.Collections.Concurrent;
using System.Security.Cryptography;
using Bromure.AC.Mitm.Aws;
using Bromure.AC.Mitm.Consent;
using Bromure.AC.Mitm.OAuth;
using Bromure.AC.Mitm.Pki;
using Bromure.AC.Mitm.Proxy;
using Bromure.AC.Mitm.SigV4;
using Bromure.AC.Mitm.Ssh;
using Bromure.AC.Mitm.Swap;
using Bromure.AC.Mitm.Trace;
using Bromure.AC.Mitm.Vault;
using Bromure.Platform;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Bromure.AC.Mitm.Engine;

/// <summary>
/// Direct port of <c>Sources/AgentCoding/Mitm/MitmEngine.swift</c>.
///
/// <para>Process-lifetime MITM coordinator. Owns the CA, the cert
/// cache, the token swap maps, and the ssh-agent keystore. The host's
/// app-delegate equivalent (<c>App.xaml.cs</c>) builds one at app
/// launch, and registers the per-VM listeners against it whenever a
/// session opens.</para>
///
/// <para><b>Vsock ports (preserved from macOS for in-VM agent
/// compatibility).</b></para>
/// <list type="bullet">
///   <item>8443 — HTTPS proxy</item>
///   <item>8444 — ssh-agent</item>
///   <item>8445 — AWS credential_process</item>
/// </list>
/// </summary>
public sealed class MitmEngine : IAsyncDisposable
{
    /// <summary>Vsock port the in-VM bridge connects to for HTTPS proxy.</summary>
    public const uint HttpsVsockPort = 8443;
    /// <summary>Vsock port the in-VM bridge connects to for the ssh-agent.</summary>
    public const uint SshAgentVsockPort = 8444;
    /// <summary>Vsock port the in-VM AWS credential_process helper connects to.</summary>
    public const uint AwsCredsVsockPort = 8445;

    public BromureCa Ca { get; }
    public CertCache CertCache { get; }
    public TokenSwapper Swapper { get; }
    public SshAgentServer SshAgent { get; }
    public PrivateSshAgent PrivateAgent { get; }
    public AwsCredentialServer AwsCreds { get; }
    public AwsResigner AwsResigner { get; }
    public ConsentBroker Consent { get; }
    public TraceStore TraceStore { get; }
    public ClientIdentityRegistry ClientIdentities { get; } = new();
    public ClusterCaTrustRegistry ClusterCaTrust { get; } = new();
    public SecretsVault Vault { get; }

    /// <summary>
    /// Per-install 32-byte salt for deriving fake tokens via HKDF.
    /// Generated once, persisted to the secrets store. Wiping rotates
    /// every fake on this host.
    /// </summary>
    public byte[] FakeTokenSalt { get; }

    /// <summary>
    /// Per-profile trace level + session id, set by the host at session
    /// launch. The proxy connection looks these up to decide whether to
    /// record + capture bodies.
    /// </summary>
    public sealed record SessionTrace(Guid SessionId, TraceLevel Level);

    private readonly ConcurrentDictionary<Guid, SessionTrace> _sessionTraces = new();
    private readonly ConcurrentDictionary<Guid, HttpMitmProxy> _proxies = new();
    private readonly ILogger _log;

    /// <summary>Optional callback fired when the proxy sees a clean Anthropic OAuth access token outbound.</summary>
    public Action<Guid, string>? SubscriptionTokenSeen { get; set; }
    /// <summary>Codex / ChatGPT counterpart of <see cref="SubscriptionTokenSeen"/>.</summary>
    public Action<Guid, string>? CodexTokenSeen { get; set; }
    /// <summary>Fires after a successful /oauth/token response rewrite.</summary>
    public Action<Guid, OAuthRotationProvider, StoredOAuthTokens>? OAuthRotated { get; set; }

    /// <summary>
    /// Cloud event sink. The proxy emits one
    /// <c>credential.token_swap</c> event per fake → real
    /// substitution for the audit trail. Caller wires this to a
    /// <c>CloudEventEmitter</c>.
    /// </summary>
    public Action<Guid, string, System.Text.Json.Nodes.JsonObject>? OnCloudEvent { get; set; }

    private const string FakeSaltBlobName = "ac-fake-token-salt-v1";

    public MitmEngine(
        IAppPaths paths,
        ISecretStore secrets,
        IConsentDialogPresenter consentPresenter,
        ILogger? log = null)
    {
        _log = log ?? NullLogger.Instance;
        Ca = BromureCa.LoadOrCreate(paths, secrets);
        CertCache = new CertCache(Ca);
        Consent = new ConsentBroker(consentPresenter);
        Swapper = new TokenSwapper(Consent);
        SshAgent = new SshAgentServer(Consent);
        PrivateAgent = new PrivateSshAgent();
        AwsCreds = new AwsCredentialServer(Consent);
        AwsResigner = new AwsResigner(AwsCreds);
        TraceStore = new TraceStore(paths.TracesDirectory);
        Vault = new SecretsVault(secrets);

        FakeTokenSalt = LoadOrMintSalt(secrets);

        HostAgentClient.BromurePrivate = new HostAgentClient(
            PrivateAgent.PipePath, AgentEndpointKind.NamedPipe);
    }

    public async Task StartAsync(CancellationToken ct = default)
    {
        await PrivateAgent.StartAsync(ct).ConfigureAwait(false);
    }

    private static byte[] LoadOrMintSalt(ISecretStore secrets)
    {
        var existing = secrets.ReadBlob(FakeSaltBlobName, BlobScope.LocalMachine);
        if (existing is { Length: 32 }) return existing;
        var fresh = RandomNumberGenerator.GetBytes(32);
        secrets.StoreBlob(FakeSaltBlobName, fresh, BlobScope.LocalMachine);
        return fresh;
    }

    // -- per-profile lifecycle ------------------------------------------

    public void SetSessionTrace(Guid profileId, SessionTrace trace)
        => _sessionTraces[profileId] = trace;

    public SessionTrace? GetSessionTrace(Guid profileId)
        => _sessionTraces.TryGetValue(profileId, out var t) ? t : null;

    public void ClearSessionTrace(Guid profileId)
        => _sessionTraces.TryRemove(profileId, out _);

    /// <summary>
    /// Spin up the per-profile proxy (TCP-on-NAT fallback for the
    /// Windows port — the macOS source attaches a vsock listener
    /// instead). Caller is expected to hand the local endpoint to the
    /// VM as the HTTPS_PROXY env var.
    /// </summary>
    public async Task<HttpMitmProxy> RegisterAsync(Guid profileId, System.Net.IPEndPoint listenEndpoint, CancellationToken ct = default)
    {
        var proxy = new HttpMitmProxy(profileId, Swapper, AwsResigner, CertCache, TraceStore,
            ClientIdentities, ClusterCaTrust,
            consent: Consent,
            sessionTraceProvider: () => GetSessionTrace(profileId),
            onCloudEvent: OnCloudEvent,
            log: _log);
        await proxy.StartAsync(listenEndpoint, ct).ConfigureAwait(false);
        _proxies[profileId] = proxy;
        return proxy;
    }

    /// <summary>
    /// Tear down everything tied to <paramref name="profileId"/>: the
    /// proxy, swap map, agent keys, AWS creds, identity + CA registries,
    /// active consent grants. The user-facing equivalent of
    /// <c>VM.shutdown()</c> finishing.
    /// </summary>
    public async Task UnregisterAsync(Guid profileId)
    {
        if (_proxies.TryRemove(profileId, out var proxy))
        {
            await proxy.DisposeAsync().ConfigureAwait(false);
        }
        Swapper.ClearMap(profileId);
        SshAgent.ClearKeys(profileId);
        SshAgent.ClearImportedKeyApprovals(profileId);
        AwsCreds.ClearCredentials(profileId);
        ClientIdentities.ClearAll(profileId);
        ClusterCaTrust.ClearAll(profileId);
        ClearSessionTrace(profileId);
        Consent.RevokeAllForProfile(profileId);
        Consent.ClearProfileName(profileId);
    }

    public async ValueTask DisposeAsync()
    {
        foreach (var (_, proxy) in _proxies)
        {
            try { await proxy.DisposeAsync().ConfigureAwait(false); } catch { }
        }
        _proxies.Clear();
        try { await PrivateAgent.DisposeAsync().ConfigureAwait(false); } catch { }
        TraceStore.Dispose();
    }
}
