// macos-source: Sources/AgentCoding/Mitm/ConsentBroker.swift @ e652007c2304
using Bromure.AC.Mitm.Swap;

namespace Bromure.AC.Mitm.Consent;

/// <summary>
/// Direct port of <c>Sources/AgentCoding/Mitm/ConsentBroker.swift</c>.
///
/// <para>Per-credential consent gate. Every credential surface (AWS
/// server, SSH agent sign, HTTP token swap) calls
/// <see cref="RequestConsentAsync"/> before doing the substitution.
/// Concurrent calls for the same <c>(profileId, credentialId)</c> key
/// coalesce onto the same dialog — a chatty agent firing a dozen
/// parallel requests sees one prompt, not twelve.</para>
///
/// <para>All grants are in-memory only. The session-scope variant is
/// wiped when <see cref="RevokeAllForProfile"/> runs at session teardown;
/// the time-bounded variants expire on the clock.</para>
///
/// <para>The actual modal lives behind <see cref="IConsentDialogPresenter"/>
/// so the broker stays decoupled from any particular UI toolkit (xUnit
/// stubs in tests; WinUI 3 alert in shipping builds).</para>
/// </summary>
public sealed class ConsentBroker : IConsentBroker
{
    public enum Decision
    {
        Deny,
        Allow5Min,
        Allow1Hr,
        /// Until <see cref="RevokeAllForProfile"/> wipes it.
        AllowSession,
    }

    public enum DecisionKind { Allow, Deny }

    public sealed record Grant(
        DateTimeOffset Expiration,
        string CredentialDisplayName,
        bool IsSessionScoped);

    public sealed record LiveEntry(
        Guid ProfileId,
        string CredentialId,
        DecisionKind Kind,
        DateTimeOffset Expiration,
        string CredentialDisplayName,
        bool IsSessionScoped);

    private static readonly TimeSpan DenyTtl = TimeSpan.FromMinutes(5);

    private readonly IConsentDialogPresenter _presenter;
    private readonly object _gate = new();
    private readonly Dictionary<string, Grant> _grants = new();
    private readonly Dictionary<string, (DateTimeOffset Expiration, string DisplayName)> _denies = new();
    private readonly Dictionary<string, List<TaskCompletionSource<bool>>> _pending = new();
    private readonly Dictionary<Guid, string> _profileNames = new();

    public ConsentBroker(IConsentDialogPresenter presenter) => _presenter = presenter;

    public void SetProfileName(Guid profileId, string name)
    {
        lock (_gate) _profileNames[profileId] = name;
    }

    public void ClearProfileName(Guid profileId)
    {
        lock (_gate) _profileNames.Remove(profileId);
    }

    public async Task<bool> RequestConsentAsync(
        Guid profileId, string credentialId, string credentialDisplayName,
        string scopeHint, CancellationToken ct)
    {
        var key = StoreKey(profileId, credentialId);
        var now = DateTimeOffset.UtcNow;

        TaskCompletionSource<bool> ourTcs;
        bool weAreDriver;
        string profileName;
        lock (_gate)
        {
            // A live deny short-circuits before the allow check.
            if (_denies.TryGetValue(key, out var deny) && deny.Expiration > now)
            {
                return false;
            }
            if (_denies.ContainsKey(key)) _denies.Remove(key);

            if (_grants.TryGetValue(key, out var grant) && grant.Expiration > now)
            {
                return true;
            }
            if (_grants.ContainsKey(key)) _grants.Remove(key);

            // Coalesce concurrent prompts for the same key.
            if (_pending.TryGetValue(key, out var waiters))
            {
                ourTcs = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                waiters.Add(ourTcs);
                weAreDriver = false;
            }
            else
            {
                _pending[key] = new List<TaskCompletionSource<bool>>();
                ourTcs = null!;
                weAreDriver = true;
            }
            profileName = _profileNames.TryGetValue(profileId, out var n) ? n : "(unknown profile)";
        }

        if (!weAreDriver)
        {
            using var reg = ct.Register(() => ourTcs.TrySetCanceled(ct));
            return await ourTcs.Task.ConfigureAwait(false);
        }

        var decision = await _presenter.AskAsync(profileName, credentialDisplayName, scopeHint, ct)
            .ConfigureAwait(false);

        bool allow;
        var stamp = DateTimeOffset.UtcNow;
        lock (_gate)
        {
            switch (decision)
            {
                case Decision.Deny:
                    _denies[key] = (stamp + DenyTtl, credentialDisplayName);
                    allow = false;
                    break;
                case Decision.Allow5Min:
                    _grants[key] = new Grant(stamp + TimeSpan.FromMinutes(5), credentialDisplayName, false);
                    allow = true;
                    break;
                case Decision.Allow1Hr:
                    _grants[key] = new Grant(stamp + TimeSpan.FromHours(1), credentialDisplayName, false);
                    allow = true;
                    break;
                case Decision.AllowSession:
                    _grants[key] = new Grant(DateTimeOffset.MaxValue, credentialDisplayName, true);
                    allow = true;
                    break;
                default:
                    allow = false;
                    break;
            }
            var waiters = _pending[key];
            _pending.Remove(key);
            foreach (var w in waiters) w.TrySetResult(allow);
        }
        return allow;
    }

    public IReadOnlyList<LiveEntry> Snapshot()
    {
        var now = DateTimeOffset.UtcNow;
        var output = new List<LiveEntry>();
        lock (_gate)
        {
            foreach (var (k, g) in _grants)
            {
                if (g.Expiration <= now) continue;
                if (!TrySplit(k, out var pid, out var cid)) continue;
                output.Add(new LiveEntry(pid, cid, DecisionKind.Allow, g.Expiration, g.CredentialDisplayName, g.IsSessionScoped));
            }
            foreach (var (k, d) in _denies)
            {
                if (d.Expiration <= now) continue;
                if (!TrySplit(k, out var pid, out var cid)) continue;
                output.Add(new LiveEntry(pid, cid, DecisionKind.Deny, d.Expiration, d.DisplayName, false));
            }
        }
        output.Sort((a, b) => string.Compare(a.CredentialDisplayName, b.CredentialDisplayName, StringComparison.Ordinal));
        return output;
    }

    public void Revoke(Guid profileId, string credentialId)
    {
        var key = StoreKey(profileId, credentialId);
        lock (_gate)
        {
            _grants.Remove(key);
            _denies.Remove(key);
        }
    }

    public void RevokeAllForProfile(Guid profileId)
    {
        var prefix = profileId.ToString("D") + "|";
        lock (_gate)
        {
            foreach (var k in _grants.Keys.Where(k => k.StartsWith(prefix, StringComparison.Ordinal)).ToArray())
            {
                _grants.Remove(k);
            }
            foreach (var k in _denies.Keys.Where(k => k.StartsWith(prefix, StringComparison.Ordinal)).ToArray())
            {
                _denies.Remove(k);
            }
        }
    }

    public void RevokeEverything()
    {
        lock (_gate)
        {
            _grants.Clear();
            _denies.Clear();
        }
    }

    private static string StoreKey(Guid profileId, string credentialId)
        => profileId.ToString("D") + "|" + credentialId;

    private static bool TrySplit(string key, out Guid profileId, out string credentialId)
    {
        profileId = default;
        credentialId = "";
        var pipe = key.IndexOf('|');
        if (pipe < 0) return false;
        if (!Guid.TryParse(key[..pipe], out profileId)) return false;
        credentialId = key[(pipe + 1)..];
        return true;
    }
}

/// <summary>UI seam for the consent dialog. Wired to NSAlert on macOS, ContentDialog on WinUI.</summary>
public interface IConsentDialogPresenter
{
    Task<ConsentBroker.Decision> AskAsync(
        string profileName, string credentialDisplayName, string scopeHint, CancellationToken ct);
}

/// <summary>
/// Stable identifier conventions for credentials. Mirrors
/// <c>ConsentCredentialID</c> in the macOS source.
/// </summary>
public static class ConsentCredentialId
{
    public static string PrimaryToolApiKey(string tool) => "tool-apikey:" + tool;
    public static string Aws() => "aws";
    public static string DigitalOcean() => "do-pat";
    public static string SshKey(string id) => "ssh:" + id;
    public static string BromureSshKey() => "ssh:bromure-auto";
    public static string GitHttps(Guid id) => "git-https:" + id.ToString("D");
    public static string ManualToken(Guid id) => "manual:" + id.ToString("D");
    public static string DockerRegistry(Guid id) => "docker:" + id.ToString("D");
    public static string Kubeconfig(Guid id) => "kube:" + id.ToString("D");
}

/// <summary>Test stub: every prompt resolves to <see cref="ConsentBroker.Decision.AllowSession"/>.</summary>
public sealed class AlwaysAllowSessionDialogPresenter : IConsentDialogPresenter
{
    public Task<ConsentBroker.Decision> AskAsync(string profileName, string credentialDisplayName,
        string scopeHint, CancellationToken ct)
        => Task.FromResult(ConsentBroker.Decision.AllowSession);
}

/// <summary>Test stub: every prompt resolves to <see cref="ConsentBroker.Decision.Deny"/>.</summary>
public sealed class AlwaysDenyDialogPresenter : IConsentDialogPresenter
{
    public Task<ConsentBroker.Decision> AskAsync(string profileName, string credentialDisplayName,
        string scopeHint, CancellationToken ct)
        => Task.FromResult(ConsentBroker.Decision.Deny);
}
