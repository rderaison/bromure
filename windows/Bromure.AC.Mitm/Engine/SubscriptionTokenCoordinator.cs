// macos-source: Sources/AgentCoding/SubscriptionTokenCoordinator.swift @ 860e84441d77
using System.Collections.Concurrent;
using System.Text;
using Bromure.AC.Core.Model;
using Bromure.AC.Mitm.Swap;
using Bromure.AC.Mitm.Vault;
using Bromure.SandboxEngine.Vsock;

namespace Bromure.AC.Mitm.Engine;

/// <summary>
/// Slim port of <c>SubscriptionTokenCoordinator.swift</c>. Glues the
/// proxy's "clean access token seen" hook to:
/// <list type="bullet">
///   <item>The shared <see cref="SubscriptionTokenBridge"/> /
///   <see cref="CodexTokenBridge"/> for pushing fakes into the
///   guest's credential file.</item>
///   <item>The <see cref="TokenSwapper"/> swap registry for picking
///   the fake up on outbound requests.</item>
///   <item>A per-profile-per-provider throttle so a single VM running
///   parallel tool calls only triggers one consent prompt at a time.</item>
/// </list>
///
/// <para>Multi-session: the bridges are process-wide singletons that
/// multiplex by source VM ID. The coordinator keeps a
/// <c>profileId → vmId</c> map so callers (who think in profile IDs)
/// can address the right bridge state. <see cref="RegisterClaude"/>
/// /<see cref="RegisterCodex"/> populate the map at session start;
/// <see cref="UnregisterClaude"/>/<see cref="UnregisterCodex"/> clear
/// it at teardown AND call <c>Forget</c> on the underlying bridge so
/// the per-VM state goes with the session.</para>
/// </summary>
public sealed class SubscriptionTokenCoordinator
{
    private readonly TokenSwapper _swapper;
    private readonly ISubscriptionConsentPrompt _prompt;
    private readonly SubscriptionTokenBridge _claudeBridge;
    private readonly CodexTokenBridge _codexBridge;
    private readonly ConcurrentDictionary<Guid, Guid> _claudeVmByProfile = new();
    private readonly ConcurrentDictionary<Guid, Guid> _codexVmByProfile = new();
    private readonly ConcurrentDictionary<Guid, byte> _askedClaude = new();
    private readonly ConcurrentDictionary<Guid, byte> _askedCodex = new();

    public SubscriptionTokenCoordinator(
        TokenSwapper swapper,
        ISubscriptionConsentPrompt prompt,
        SubscriptionTokenBridge claudeBridge,
        CodexTokenBridge codexBridge)
    {
        _swapper = swapper;
        _prompt = prompt;
        _claudeBridge = claudeBridge;
        _codexBridge = codexBridge;
    }

    /// <summary>Bind <paramref name="profileId"/> to the VM that
    /// currently runs its session. Called by the engine right after
    /// HCS resolves the runtime ID — same moment we register the
    /// overlay producer in <c>SessionViewModel</c>.</summary>
    public void RegisterClaude(Guid profileId, Guid vmId)
        => _claudeVmByProfile[profileId] = vmId;

    public void UnregisterClaude(Guid profileId)
    {
        if (_claudeVmByProfile.TryRemove(profileId, out var vmId))
        {
            _claudeBridge.Forget(vmId);
        }
        _askedClaude.TryRemove(profileId, out _);
    }

    public void RegisterCodex(Guid profileId, Guid vmId)
        => _codexVmByProfile[profileId] = vmId;

    public void UnregisterCodex(Guid profileId)
    {
        if (_codexVmByProfile.TryRemove(profileId, out var vmId))
        {
            _codexBridge.Forget(vmId);
        }
        _askedCodex.TryRemove(profileId, out _);
    }

    /// <summary>Hook the proxy fires when a clean Anthropic OAuth access token leaves the VM.</summary>
    public Task HandleCleanClaudeAccessTokenAsync(Guid profileId, string realToken, byte[] salt, CancellationToken ct = default)
        => HandleAsync(profileId, realToken, salt, ProviderKind.Claude, ct);

    /// <summary>Codex / ChatGPT counterpart.</summary>
    public Task HandleCleanCodexAccessTokenAsync(Guid profileId, string realToken, byte[] salt, CancellationToken ct = default)
        => HandleAsync(profileId, realToken, salt, ProviderKind.Codex, ct);

    private async Task HandleAsync(Guid profileId, string real, byte[] salt, ProviderKind kind, CancellationToken ct)
    {
        var asked = kind == ProviderKind.Claude ? _askedClaude : _askedCodex;
        if (!asked.TryAdd(profileId, 0)) return;  // throttle: one prompt at a time per (profile, provider)

        var allowed = await _prompt.AskFirstSwapAsync(profileId, kind, ct).ConfigureAwait(false);
        if (!allowed) return;

        if (kind == ProviderKind.Claude && _claudeVmByProfile.TryGetValue(profileId, out var vmIdC))
        {
            await SeedClaudeAsync(profileId, vmIdC, ct).ConfigureAwait(false);
        }
        else if (kind == ProviderKind.Codex && _codexVmByProfile.TryGetValue(profileId, out var vmIdX))
        {
            await SeedCodexAsync(profileId, vmIdX, ct).ConfigureAwait(false);
        }
    }

    private async Task SeedClaudeAsync(Guid profileId, Guid vmId, CancellationToken ct)
    {
        // Wait for the in-VM agent to dial in. macOS 60s budget — first
        // boot of a fresh profile used to take ~30s; with the Perf #2
        // boot rework that's now ~3s, but agents inside the VM can
        // still take a moment to come up.
        await _claudeBridge.WaitConnectedAsync(vmId, ct).ConfigureAwait(false);

        // We need a real refresh token too — read it back from the
        // guest's credentials.json before overwriting.
        var tokens = await _claudeBridge.ReadAsync(vmId, ct).ConfigureAwait(false);
        if (tokens is null) return;

        var saltAccess = Encoding.UTF8.GetBytes($"anthropic-oauth-access:{profileId:D}");
        var saltRefresh = Encoding.UTF8.GetBytes($"anthropic-oauth-refresh:{profileId:D}");
        var fakeAccess = SessionTokenPlan.DeriveFake("sk-ant-oat01-brm-", tokens.Access, saltAccess, tokens.Access.Length);
        var fakeRefresh = SessionTokenPlan.DeriveFake("sk-ant-ort01-brm-", tokens.Refresh, saltRefresh, tokens.Refresh.Length);

        await _claudeBridge.WriteAsync(vmId, fakeAccess, fakeRefresh, ct).ConfigureAwait(false);
        _swapper.AppendEntries(new[]
        {
            new TokenMap.Entry(fakeAccess, tokens.Access,
                Host: "api.anthropic.com",
                Header: EntryHeader.Authorization,
                AcceptSiblings: true),
            new TokenMap.Entry(fakeRefresh, tokens.Refresh,
                Host: "console.anthropic.com",
                Header: EntryHeader.Authorization,
                Body: true,
                AcceptSiblings: true),
        }, profileId);
    }

    private async Task SeedCodexAsync(Guid profileId, Guid vmId, CancellationToken ct)
    {
        await _codexBridge.WaitConnectedAsync(vmId, ct).ConfigureAwait(false);
        var tokens = await _codexBridge.ReadAsync(vmId, ct).ConfigureAwait(false);
        if (tokens is null) return;

        var saltAccess = Encoding.UTF8.GetBytes($"codex-oauth-access:{profileId:D}");
        var saltRefresh = Encoding.UTF8.GetBytes($"codex-oauth-refresh:{profileId:D}");
        var saltId = Encoding.UTF8.GetBytes($"codex-oauth-id:{profileId:D}");

        var fakeAccess = SubscriptionFakeMint.MintJwtFake(tokens.Access, saltAccess);
        if (fakeAccess is null) return;
        var fakeRefresh = SubscriptionFakeMint.MintCodexRefreshFake(tokens.Refresh, saltRefresh);
        var fakeId = SubscriptionFakeMint.MintJwtFake(tokens.IdToken, saltId);
        if (fakeId is null) return;

        await _codexBridge.WriteAsync(vmId, fakeAccess, fakeRefresh, fakeId, ct).ConfigureAwait(false);
        _swapper.AppendEntries(new[]
        {
            new TokenMap.Entry(fakeAccess, tokens.Access, Host: "chatgpt.com",
                Header: EntryHeader.Authorization, AcceptSiblings: true),
            new TokenMap.Entry(fakeAccess, tokens.Access, Host: "api.openai.com",
                Header: EntryHeader.Authorization, AcceptSiblings: true),
            new TokenMap.Entry(fakeRefresh, tokens.Refresh, Host: "auth.openai.com",
                Header: EntryHeader.Authorization, Body: true, AcceptSiblings: true),
            new TokenMap.Entry(fakeId, tokens.IdToken, Host: "chatgpt.com",
                Header: EntryHeader.Authorization, AcceptSiblings: true),
        }, profileId);
    }

    /// <summary>Audit 07 §4 autoSeed: at session start, if the
    /// profile has stored real Claude tokens fresh enough, push them
    /// into the VM's credentials.json BEFORE the agent dials any
    /// upstream. Mirrors macOS autoSeedIfNeeded.
    ///
    /// <para>The agent dials the host with the stored realAccess and
    /// realRefresh as if the user had just logged in. The proxy then
    /// sees a clean token leaving on the next request and runs the
    /// normal swap flow (which mints fakes + writes them back).
    /// The user never has to log in again.</para></summary>
    public async Task AutoSeedClaudeAsync(Guid profileId, Guid vmId, Profile profile, CancellationToken ct = default)
    {
        if (profile.SubscriptionTokenSwap != SubscriptionTokenSwapState.Accepted) return;
        if (profile.DefaultClaudeTokens is not { } stored) return;
        if (string.IsNullOrEmpty(stored.AccessToken) || string.IsNullOrEmpty(stored.RefreshToken)) return;
        if (IsStale(stored.SavedAt)) return;

        try
        {
            // Wait for the agent. If it never dials (image missing the
            // helper) the WaitConnected times out via the caller's ct.
            await _claudeBridge.WaitConnectedAsync(vmId, ct).ConfigureAwait(false);
            await _claudeBridge.WriteAsync(vmId, stored.AccessToken, stored.RefreshToken, ct)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException) { throw; }
        catch
        {
            // Best-effort: a failure here just means the user re-logs
            // in this session. No reason to surface to the UI.
        }
    }

    public async Task AutoSeedCodexAsync(Guid profileId, Guid vmId, Profile profile, CancellationToken ct = default)
    {
        if (profile.CodexTokenSwap != SubscriptionTokenSwapState.Accepted) return;
        if (profile.DefaultCodexTokens is not { } stored) return;
        if (string.IsNullOrEmpty(stored.AccessToken)
            || string.IsNullOrEmpty(stored.RefreshToken)
            || string.IsNullOrEmpty(stored.IdToken)) return;
        if (IsStale(stored.SavedAt)) return;

        try
        {
            await _codexBridge.WaitConnectedAsync(vmId, ct).ConfigureAwait(false);
            await _codexBridge.WriteAsync(vmId, stored.AccessToken, stored.RefreshToken, stored.IdToken!, ct)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException) { throw; }
        catch { }
    }

    /// <summary>Refresh tokens have ~30-day lifetimes for both
    /// providers. Bail past that — pushing a long-expired refresh
    /// won't help the user any more than a re-login would.</summary>
    private static bool IsStale(DateTimeOffset? savedAt)
        => savedAt is null || DateTimeOffset.UtcNow - savedAt.Value > TimeSpan.FromDays(28);
}

public enum ProviderKind { Claude, Codex }

/// <summary>UI seam for the first-time consent prompt.</summary>
public interface ISubscriptionConsentPrompt
{
    Task<bool> AskFirstSwapAsync(Guid profileId, ProviderKind kind, CancellationToken ct);
}

public sealed class AlwaysAllowSubscriptionPrompt : ISubscriptionConsentPrompt
{
    public Task<bool> AskFirstSwapAsync(Guid profileId, ProviderKind kind, CancellationToken ct)
        => Task.FromResult(true);
}
