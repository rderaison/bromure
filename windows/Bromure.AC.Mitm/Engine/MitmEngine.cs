// macos-source: Sources/AgentCoding/Mitm/MitmEngine.swift @ 546d34bf9dd8
using System.Collections.Concurrent;
using System.Security.Cryptography;
using Bromure.AC.Core.Imports;
using Bromure.AC.Core.Model;
using Bromure.AC.Core.Ssh;
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
    public ExecCredentialPoller ExecPoller { get; }
    public MacAddressBindings MacBindings { get; }
    /// <summary>
    /// Body-scan compromise detector (Aho-Corasick over the
    /// per-profile fake set). Rebuilt automatically whenever the
    /// swapper's per-profile map mutates — Audit 03 #1 (CRITICAL)
    /// flagged the detector as never rebuilt after OAuth token
    /// rotation; new fakes were added but the scanner kept matching
    /// the old set so post-rotation leaks slipped through.
    /// </summary>
    public CompromiseDetector BodyScanDetector { get; }

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
    public sealed record SessionTrace(Guid SessionId, Bromure.AC.Mitm.Trace.TraceLevel Level);

    private readonly ConcurrentDictionary<Guid, SessionTrace> _sessionTraces = new();
    private readonly ConcurrentDictionary<Guid, HttpMitmProxy> _proxies = new();
    private readonly ConcurrentDictionary<Guid, CancellationTokenSource> _ssoRefreshLoops = new();
    private readonly IAppPaths _paths;
    private readonly ILogger _log;

    /// <summary>Optional callback fired when the proxy sees a clean Anthropic OAuth access token outbound.</summary>
    public Action<Guid, string>? SubscriptionTokenSeen { get; set; }
    /// <summary>Codex / ChatGPT counterpart of <see cref="SubscriptionTokenSeen"/>.</summary>
    public Action<Guid, string>? CodexTokenSeen { get; set; }
    /// <summary>Fires after a successful /oauth/token response rewrite.</summary>
    public Action<Guid, OAuthRotationProvider, Bromure.AC.Mitm.OAuth.StoredOAuthTokens>? OAuthRotated { get; set; }

    // Audit 07 §4 — multi-VM subscription token plumbing. The
    // SubscriptionTokenBridge / CodexTokenBridge instances are
    // process-wide singletons that multiplex by source VM ID; the
    // coordinator is wired by the shell after construction (it needs
    // an ISubscriptionConsentPrompt which is UI-specific).
    public Bromure.SandboxEngine.Vsock.VsockBridge VsockBridge { get; private set; } = null!;
    public Bromure.SandboxEngine.Vsock.SubscriptionTokenBridge ClaudeTokenBridge { get; private set; } = null!;
    public Bromure.SandboxEngine.Vsock.CodexTokenBridge CodexTokenBridge { get; private set; } = null!;
    public SubscriptionTokenCoordinator? SubscriptionCoord { get; set; }

    /// <summary>
    /// Cloud event sink. The proxy emits one
    /// <c>credential.token_swap</c> event per fake → real
    /// substitution for the audit trail. Caller wires this to a
    /// <c>CloudEventEmitter</c>.
    /// </summary>
    public Action<Guid, string, System.Text.Json.Nodes.JsonObject>? OnCloudEvent { get; set; }

    /// <summary>
    /// Per-profile compromise sink. Fires when the swap path's leak
    /// detector observes an outbound credential where it doesn't
    /// belong (e.g. a Claude token going to evil.com). Host wires
    /// this to <c>CompromiseGate.Mark</c> so the next launch refuses
    /// to boot until the user wipes the disk.
    /// </summary>
    public Action<Bromure.AC.Mitm.Swap.CompromiseEvent>? OnCompromiseDetected { get; set; }

    private const string FakeSaltBlobName = "ac-fake-token-salt-v1";

    public MitmEngine(
        IAppPaths paths,
        ISecretStore secrets,
        IConsentDialogPresenter consentPresenter,
        ILogger? log = null)
    {
        _log = log ?? NullLogger.Instance;
        _paths = paths;
        Ca = BromureCa.LoadOrCreate(paths, secrets);
        CertCache = new CertCache(Ca);
        Consent = new ConsentBroker(consentPresenter);
        Swapper = new TokenSwapper(Consent);
        SshAgent = new SshAgentServer(Consent);
        PrivateAgent = new PrivateSshAgent();
        AwsCreds = new AwsCredentialServer(Consent);
        AwsResigner = new AwsResigner(AwsCreds);
        // The resigner emits credential.aws_sign per successful
        // re-sign — wire it lazily so the host can swap the sink
        // after construction.
        AwsResigner.SetCloudEventSink((pid, type, data) =>
        {
            try { OnCloudEvent?.Invoke(pid, type, data); }
            catch (Exception ex) { _log.LogDebug(ex, "OnCloudEvent (aws_sign) threw"); }
        });
        TraceStore = new TraceStore(paths.TracesDirectory);
        Vault = new SecretsVault(secrets);
        ExecPoller = new ExecCredentialPoller(_log);
        MacBindings = new MacAddressBindings(paths);
        BodyScanDetector = new CompromiseDetector(Swapper);
        // Auto-rebuild on every map mutation. Without this the
        // detector's AC scanner goes stale the moment SubscriptionToken
        // / OAuth rotation lands new fakes.
        Swapper.MapMutated += pid => BodyScanDetector.Rebuild(pid);

        FakeTokenSalt = LoadOrMintSalt(secrets);

        HostAgentClient.BromurePrivate = new HostAgentClient(
            PrivateAgent.PipePath, AgentEndpointKind.NamedPipe);
    }

    public async Task StartAsync(CancellationToken ct = default)
    {
        // Bridge the swapper's compromise channel to the engine's
        // per-profile sink so the host can flag the disk + show the
        // wipe-and-launch alert on next boot. Done at StartAsync so
        // OnCompromiseDetected can be set later (the host wires it
        // after the engine is constructed).
        Swapper.SetCompromiseHandler(evt =>
        {
            try { OnCompromiseDetected?.Invoke(evt); }
            catch (Exception ex) { _log.LogWarning(ex, "OnCompromiseDetected handler threw"); }
        });
        await PrivateAgent.StartAsync(ct).ConfigureAwait(false);

        // hvsocket listener for in-VM ssh-add. The guest's
        // bromure-ssh-agent-bridge daemon dials AF_VSOCK
        // CID_HOST:SshAgentVsockPort (8444) per ssh-add invocation,
        // and we feed its bytes into the same PrivateSshAgent
        // protocol handler that serves the host-side named pipe.
        // Fails-soft when Hyper-V's HCS isn't available (dev box
        // without virtualization, etc.).
        _sshHvSocket = new SshAgentHvSocketListener(PrivateAgent, SshAgentVsockPort, _log);
        await _sshHvSocket.StartAsync(ct).ConfigureAwait(false);

        // AWS credential_process listener — guest's
        // bromure-aws-credentials helper dials AF_VSOCK CID_HOST:8445
        // and the host vends the per-profile fake-secret payload that
        // the AWS SDK feeds into its signer. Real secret never leaves
        // the host; the resigner intercepts on the wire.
        _awsCredsHvSocket = new AwsCredentialHvSocketListener(AwsCreds, AwsCredsVsockPort, _log);
        await _awsCredsHvSocket.StartAsync(ct).ConfigureAwait(false);

        // Audit 07 §4 — subscription token bridges. Process-wide
        // singletons; ports 8446 (Claude) + 8447 (Codex). Each
        // multiplexes accepted connections by source VM ID so
        // concurrent sessions don't fight over a single connection.
        VsockBridge = new Bromure.SandboxEngine.Vsock.VsockBridge(_log);
        ClaudeTokenBridge = new Bromure.SandboxEngine.Vsock.SubscriptionTokenBridge(_log);
        CodexTokenBridge = new Bromure.SandboxEngine.Vsock.CodexTokenBridge(_log);
        ClaudeTokenBridge.RegisterOn(VsockBridge);
        CodexTokenBridge.RegisterOn(VsockBridge);
    }

    private SshAgentHvSocketListener? _sshHvSocket;
    private AwsCredentialHvSocketListener? _awsCredsHvSocket;

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
    /// <summary>
    /// Push the profile's bindings into the engine's per-profile
    /// registries — AWS credentials, SSH agent keys, kubeconfig client
    /// identities + cluster CAs. Mirrors the wire-up the macOS app
    /// does inline at session start. Call once per session, before
    /// the VM boots. Idempotent.
    ///
    /// <para>For AWS SSO profiles, also kicks off the background
    /// refresh loop that re-resolves credentials 5 minutes before
    /// expiration. The loop is bound to the profile lifecycle and
    /// is cancelled by <see cref="UnregisterAsync"/>.</para>
    /// </summary>
    public async Task ApplyProfileBindingsAsync(Profile? profile, CancellationToken ct = default)
    {
        if (profile is null) return;

        // 1) AWS credentials. Static keys land directly; SSO resolves
        // first, then arms the refresh loop. Fail-open: if SSO
        // resolution explodes (network down, prompt declined, etc.)
        // the resigner falls through to Unchanged and the request
        // hits upstream as-is — that's what the macOS app does too.
        var aws = profile.Aws;
        if (aws.AuthMode == AwsAuthMode.StaticKeys
            && !string.IsNullOrWhiteSpace(aws.AccessKeyId)
            && !string.IsNullOrWhiteSpace(aws.SecretAccessKey))
        {
            AwsCreds.SetCredentials(new AwsCredentials(
                AccessKeyId: aws.AccessKeyId,
                SecretAccessKey: aws.SecretAccessKey,
                SessionToken: aws.SessionToken ?? string.Empty,
                RequireApproval: aws.RequireApproval), profile.Id);
        }
        else if (aws.AuthMode == AwsAuthMode.Sso
                 && !string.IsNullOrWhiteSpace(aws.SsoProfile))
        {
            try
            {
                var resolved = await AwsSsoResolver.ResolveAsync(aws.SsoProfile,
                    triggerLoginIfNeeded: true, ct: ct).ConfigureAwait(false);
                AwsCreds.SetCredentials(new AwsCredentials(
                    resolved.AccessKeyId, resolved.SecretAccessKey, resolved.SessionToken,
                    RequireApproval: aws.RequireApproval), profile.Id);
                StartSsoRefreshLoop(profile.Id, aws.SsoProfile, resolved.Expiration, aws.RequireApproval);
            }
            catch (Exception ex)
            {
                _log.LogWarning(ex, "AWS SSO resolution failed for profile {Profile}", aws.SsoProfile);
            }
        }

        // 2) SSH agent keys. The auto-generated per-profile key is the
        // baseline; imported user keys layer on top. Each entry gets
        // RequireApproval honoured so the consent broker can gate
        // SIGN_REQUEST per-signature.
        var keys = new List<AgentKey>();
        var defaultRawPath = Path.Combine(ProfileSshKey.DirectoryFor(_paths, profile.Id), "id_ed25519.raw");
        if (File.Exists(defaultRawPath))
        {
            var raw = File.ReadAllBytes(defaultRawPath);
            if (raw.Length == 64)
            {
                var seed = raw.AsSpan(0, 32).ToArray();
                var pub = raw.AsSpan(32, 32).ToArray();
                keys.Add(new Ed25519AgentKey(
                    Comment: "bromure-ac-" + profile.Id.ToString("N")[..8],
                    PublicKey: pub,
                    Seed: seed,
                    RequireApproval: profile.SshKeyRequiresApproval,
                    ConsentCredentialId: $"bromure-ac/{profile.Id:D}"));
            }
        }
        foreach (var imported in profile.ImportedSshKeys)
        {
            if (string.IsNullOrWhiteSpace(imported.PrivateKeyPem)) continue;
            // Imported keys carry their private material inline (PEM).
            // Try ed25519 first; fall back to RSA. Either decoder
            // returns null on shape mismatch so the trial-and-error
            // is cheap.
            try
            {
                var comment = string.IsNullOrEmpty(imported.Label) ? imported.Comment : imported.Label;
                var consent = $"imported/{imported.Id:D}";
                var ed = OpenSshKeyFormat.ParseEd25519PrivatePem(imported.PrivateKeyPem);
                if (ed is not null)
                {
                    keys.Add(new Ed25519AgentKey(
                        Comment: comment,
                        PublicKey: ed.Value.PublicKey,
                        Seed: ed.Value.Seed,
                        RequireApproval: imported.RequireApproval,
                        ConsentCredentialId: consent));
                    continue;
                }
                var rsa = OpenSshKeyFormat.ParseRsaPrivatePem(imported.PrivateKeyPem);
                if (rsa is not null)
                {
                    keys.Add(new RsaAgentKey(
                        Comment: comment,
                        PublicKey: rsa.Value.PublicBlob,
                        Parameters: rsa.Value.Parameters,
                        RequireApproval: imported.RequireApproval,
                        ConsentCredentialId: consent));
                    continue;
                }
                _log.LogDebug("Imported SSH key {Id} ({Label}) is not a supported PEM shape (ed25519 / RSA)",
                    imported.Id, imported.Label);
            }
            catch (Exception ex)
            {
                _log.LogDebug(ex, "Imported SSH key {Id} could not be loaded", imported.Id);
            }
        }
        SshAgent.SetKeys(keys, profile.Id);

        // Also push the keys into PrivateSshAgent so the host-side
        // named-pipe listener at \\.\pipe\bromure-ac-ssh-agent
        // serves them on the OpenSSH wire protocol. Without this,
        // SshAgent.KeysFor returns the loaded set but `ssh-add -l`
        // can't see anything because the pipe-level agent has its
        // own independent key store. (This was the audit gap behind
        // "SSH agent has no VM listener and no keys" — earlier we
        // closed the half-gap of populating SshAgent; this closes the
        // other half by populating the listener too.)
        //
        // Per-profile + consent gating still happens via
        // SshAgentServer when the in-VM client hits the proxy path;
        // PrivateSshAgent is the "all currently-active keys exposed
        // to host-side tools" view, so we just push the latest set.
        // Audit 05 §1.4: was Clear() + per-key Add, which wiped
        // OTHER active profiles' keys. Use the per-profile atomic
        // replace so two concurrent sessions both see their own
        // keys via the shared host pipe.
        PrivateAgent.ReplaceForProfile(profile.Id, keys);
    }

    /// <summary>
    /// Arm the SSO refresh loop for <paramref name="profileId"/>. Any
    /// existing loop for the same profile is cancelled first. The loop
    /// is fire-and-forget; failures are logged but don't propagate.
    /// </summary>
    private void StartSsoRefreshLoop(Guid profileId, string ssoProfile,
        DateTimeOffset initialExpiration, bool requireApproval)
    {
        if (_ssoRefreshLoops.TryRemove(profileId, out var oldCts))
        {
            try { oldCts.Cancel(); } catch { }
            oldCts.Dispose();
        }
        var cts = new CancellationTokenSource();
        _ssoRefreshLoops[profileId] = cts;
        _ = AwsSsoResolver.StartRefreshLoopAsync(
            ssoProfile,
            initialExpiration,
            onRefresh: creds =>
            {
                AwsCreds.SetCredentials(new AwsCredentials(
                    creds.AccessKeyId, creds.SecretAccessKey, creds.SessionToken,
                    RequireApproval: requireApproval), profileId);
            },
            onError: ex => _log.LogWarning(ex, "AWS SSO refresh loop stopped"),
            ct: cts.Token);
    }

    public async Task<HttpMitmProxy> RegisterAsync(Guid profileId, System.Net.IPEndPoint listenEndpoint, CancellationToken ct = default)
    {
        var proxy = new HttpMitmProxy(profileId, Swapper, AwsResigner, CertCache, TraceStore,
            bodyEncryptor: Vault,
            clientIdentities: ClientIdentities,
            clusterCaTrust: ClusterCaTrust,
            consent: Consent,
            sessionTraceProvider: () => GetSessionTrace(profileId),
            onCloudEvent: OnCloudEvent,
            onSubscriptionTokenSeen: SubscriptionTokenSeen,
            onCodexTokenSeen: CodexTokenSeen,
            onOAuthRotated: (pid, prov, reals) =>
            {
                try { OAuthRotated?.Invoke(pid, prov, reals); }
                catch (Exception ex) { _log.LogDebug(ex, "OAuthRotated propagation threw"); }
            },
            bodyScanDetector: BodyScanDetector,
            log: _log);
        // Make sure the detector has a scanner for this profile
        // before any request hits the hot path. Subsequent
        // SubscriptionToken / OAuth rotation mutations trigger
        // Rebuild automatically via the MapMutated subscription
        // above.
        BodyScanDetector.Rebuild(profileId);
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
        if (_ssoRefreshLoops.TryRemove(profileId, out var cts))
        {
            try { cts.Cancel(); } catch { }
            cts.Dispose();
        }
        Swapper.ClearMap(profileId);
        SshAgent.ClearKeys(profileId);
        SshAgent.ClearImportedKeyApprovals(profileId);
        // Audit 05 §1.4: drop only THIS profile's host-side keys
        // so other concurrently-active sessions keep working.
        PrivateAgent.ClearForProfile(profileId);
        AwsCreds.ClearCredentials(profileId);
        ClientIdentities.ClearAll(profileId);
        ClusterCaTrust.ClearAll(profileId);
        ClearSessionTrace(profileId);
        Consent.RevokeAllForProfile(profileId);
        Consent.ClearProfileName(profileId);
        ExecPoller.StopForProfile(profileId);
    }

    public async ValueTask DisposeAsync()
    {
        foreach (var (_, proxy) in _proxies)
        {
            try { await proxy.DisposeAsync().ConfigureAwait(false); } catch { }
        }
        _proxies.Clear();
        try { await ExecPoller.DisposeAsync().ConfigureAwait(false); } catch { }
        if (_sshHvSocket is not null)
        {
            try { await _sshHvSocket.DisposeAsync().ConfigureAwait(false); } catch { }
            _sshHvSocket = null;
        }
        if (_awsCredsHvSocket is not null)
        {
            try { await _awsCredsHvSocket.DisposeAsync().ConfigureAwait(false); } catch { }
            _awsCredsHvSocket = null;
        }
        try { await PrivateAgent.DisposeAsync().ConfigureAwait(false); } catch { }
        TraceStore.Dispose();
    }
}
