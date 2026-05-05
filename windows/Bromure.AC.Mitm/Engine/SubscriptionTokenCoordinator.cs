using System.Collections.Concurrent;
using System.Text;
using Bromure.AC.Mitm.Swap;
using Bromure.AC.Mitm.Vault;
using Bromure.SandboxEngine.Vsock;

namespace Bromure.AC.Mitm.Engine;

/// <summary>
/// Slim port of <c>SubscriptionTokenCoordinator.swift</c> (700 LOC on
/// macOS, ~150 here). Glues the proxy's "clean access token seen"
/// hook to:
/// <list type="bullet">
///   <item>The per-VM <see cref="SubscriptionTokenBridge"/> /
///   <see cref="CodexTokenBridge"/> for actually pushing fakes into
///   the guest's credential file.</item>
///   <item>The <see cref="TokenSwapper"/> swap registry for picking
///   the fake up on outbound requests.</item>
///   <item>A per-profile-per-provider throttle so a single VM running
///   parallel tool calls only triggers one consent prompt at a time.</item>
/// </list>
///
/// <para>The full macOS coordinator drives a SwiftUI sheet for the
/// initial consent. The Windows port wires that to
/// <see cref="ISubscriptionConsentPrompt"/> so the WPF shell can
/// supply its own dialog (or the test harness an auto-allow stub).</para>
/// </summary>
public sealed class SubscriptionTokenCoordinator
{
    private readonly TokenSwapper _swapper;
    private readonly ISubscriptionConsentPrompt _prompt;
    private readonly ConcurrentDictionary<Guid, SubscriptionTokenBridge> _claudeBridges = new();
    private readonly ConcurrentDictionary<Guid, CodexTokenBridge> _codexBridges = new();
    private readonly ConcurrentDictionary<Guid, byte> _askedClaude = new();
    private readonly ConcurrentDictionary<Guid, byte> _askedCodex = new();

    public SubscriptionTokenCoordinator(TokenSwapper swapper, ISubscriptionConsentPrompt prompt)
    {
        _swapper = swapper;
        _prompt = prompt;
    }

    public void RegisterClaude(Guid profileId, SubscriptionTokenBridge bridge)
        => _claudeBridges[profileId] = bridge;
    public void UnregisterClaude(Guid profileId)
    {
        _claudeBridges.TryRemove(profileId, out _);
        _askedClaude.TryRemove(profileId, out _);
    }
    public void RegisterCodex(Guid profileId, CodexTokenBridge bridge)
        => _codexBridges[profileId] = bridge;
    public void UnregisterCodex(Guid profileId)
    {
        _codexBridges.TryRemove(profileId, out _);
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

        if (kind == ProviderKind.Claude && _claudeBridges.TryGetValue(profileId, out var claude))
        {
            await SeedClaudeAsync(profileId, real, salt, claude, ct).ConfigureAwait(false);
        }
        else if (kind == ProviderKind.Codex && _codexBridges.TryGetValue(profileId, out var codex))
        {
            await SeedCodexAsync(profileId, real, salt, codex, ct).ConfigureAwait(false);
        }
    }

    private async Task SeedClaudeAsync(Guid profileId, string realAccess, byte[] salt,
        SubscriptionTokenBridge bridge, CancellationToken ct)
    {
        // Wait for the in-VM agent to dial in. Match the macOS 60s
        // budget — first boot of a fresh profile takes ~30s for X /
        // xinitrc to come up.
        await bridge.WaitConnectedAsync(ct).ConfigureAwait(false);

        // We need a real refresh token too — read it back from the
        // guest's credentials.json before overwriting.
        var tokens = await bridge.ReadAsync(ct).ConfigureAwait(false);
        if (tokens is null) return;

        var saltAccess = Encoding.UTF8.GetBytes($"anthropic-oauth-access:{profileId:D}");
        var saltRefresh = Encoding.UTF8.GetBytes($"anthropic-oauth-refresh:{profileId:D}");
        var fakeAccess = SessionTokenPlan.DeriveFake("sk-ant-oat01-brm-", tokens.Access, saltAccess, tokens.Access.Length);
        var fakeRefresh = SessionTokenPlan.DeriveFake("sk-ant-ort01-brm-", tokens.Refresh, saltRefresh, tokens.Refresh.Length);

        await bridge.WriteAsync(fakeAccess, fakeRefresh, ct).ConfigureAwait(false);
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

    private async Task SeedCodexAsync(Guid profileId, string realAccess, byte[] salt,
        CodexTokenBridge bridge, CancellationToken ct)
    {
        await bridge.WaitConnectedAsync(ct).ConfigureAwait(false);
        var tokens = await bridge.ReadAsync(ct).ConfigureAwait(false);
        if (tokens is null) return;

        var saltAccess = Encoding.UTF8.GetBytes($"codex-oauth-access:{profileId:D}");
        var saltRefresh = Encoding.UTF8.GetBytes($"codex-oauth-refresh:{profileId:D}");
        var saltId = Encoding.UTF8.GetBytes($"codex-oauth-id:{profileId:D}");

        var fakeAccess = SubscriptionFakeMint.MintJwtFake(tokens.Access, saltAccess);
        if (fakeAccess is null) return;
        var fakeRefresh = SubscriptionFakeMint.MintCodexRefreshFake(tokens.Refresh, saltRefresh);
        var fakeId = SubscriptionFakeMint.MintJwtFake(tokens.IdToken, saltId);
        if (fakeId is null) return;

        await bridge.WriteAsync(fakeAccess, fakeRefresh, fakeId, ct).ConfigureAwait(false);
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
