using System.Collections.Concurrent;
using System.Security.Cryptography.X509Certificates;
using System.Text.RegularExpressions;

namespace Bromure.AC.Mitm.Pki;

/// <summary>
/// Direct port of <c>ClientIdentityRegistry</c> from
/// <c>Sources/AgentCoding/Mitm/CloudCredentials.swift</c>.
/// Per-profile, per-host client identity table the proxy hands to
/// <see cref="System.Net.Security.SslStream"/> when the upstream API
/// server asks for client-cert auth (Kubernetes, internal mTLS).
/// </summary>
public sealed class ClientIdentityRegistry
{
    public sealed record Entry(
        X509Certificate2 Identity,
        string? ConsentCredentialId = null,
        string? ConsentDisplayName = null);

    private readonly ConcurrentDictionary<Guid, Dictionary<string, Entry>> _perProfile = new();
    private readonly object _gate = new();

    public void SetIdentity(X509Certificate2 identity, string host, Guid profileId,
        string? consentCredentialId = null, string? consentDisplayName = null)
    {
        var entry = new Entry(identity, consentCredentialId, consentDisplayName);
        var hLower = host.ToLowerInvariant();
        lock (_gate)
        {
            var byHost = _perProfile.GetOrAdd(profileId, _ => new(StringComparer.Ordinal));
            byHost[hLower] = entry;
            // Also index by bare hostname — proxy CONNECT-parsed host
            // typically drops the port; one registration must hit both.
            var bare = StripPort(hLower);
            if (bare != hLower) byHost[bare] = entry;
        }
    }

    public void ClearAll(Guid profileId) => _perProfile.TryRemove(profileId, out _);

    public Entry? EntryFor(string host, Guid profileId)
    {
        if (!_perProfile.TryGetValue(profileId, out var byHost)) return null;
        var hLower = host.ToLowerInvariant();
        lock (_gate)
        {
            if (byHost.TryGetValue(hLower, out var e)) return e;
            var bare = StripPort(hLower);
            if (bare != hLower && byHost.TryGetValue(bare, out var be)) return be;
        }
        return null;
    }

    public X509Certificate2? IdentityFor(string host, Guid profileId)
        => EntryFor(host, profileId)?.Identity;

    private static string StripPort(string host)
    {
        var colon = host.LastIndexOf(':');
        return colon > 0 ? host[..colon] : host;
    }
}

/// <summary>
/// Per-host root-CA table the proxy uses when an upstream ships a cert
/// that doesn't chain to the system trust store (e.g. private k8s API
/// servers). Direct port of <c>ClusterCATrustRegistry</c>.
/// </summary>
public sealed class ClusterCaTrustRegistry
{
    private readonly ConcurrentDictionary<Guid, Dictionary<string, X509Certificate2>> _perProfile = new();
    private readonly object _gate = new();

    public void SetCa(string pem, string host, Guid profileId)
    {
        var cert = ParseFirstCertPem(pem);
        if (cert is null)
        {
            Console.Error.WriteLine($"[mitm] cluster CA parse failed for host={host} — falling back to system trust");
            return;
        }
        var hLower = host.ToLowerInvariant();
        lock (_gate)
        {
            var byHost = _perProfile.GetOrAdd(profileId, _ => new(StringComparer.Ordinal));
            byHost[hLower] = cert;
            var bare = StripPort(hLower);
            if (bare != hLower) byHost[bare] = cert;
        }
    }

    public void ClearAll(Guid profileId) => _perProfile.TryRemove(profileId, out _);

    public X509Certificate2? CaFor(string host, Guid profileId)
    {
        if (!_perProfile.TryGetValue(profileId, out var byHost)) return null;
        var hLower = host.ToLowerInvariant();
        lock (_gate)
        {
            if (byHost.TryGetValue(hLower, out var c)) return c;
            var bare = StripPort(hLower);
            if (bare != hLower && byHost.TryGetValue(bare, out var bc)) return bc;
        }
        return null;
    }

    private static X509Certificate2? ParseFirstCertPem(string pem)
    {
        var match = Regex.Match(pem,
            @"-----BEGIN CERTIFICATE-----(?<body>[\s\S]*?)-----END CERTIFICATE-----");
        if (!match.Success) return null;
        try
        {
            var b64 = Regex.Replace(match.Groups["body"].Value, @"\s+", "");
            var der = Convert.FromBase64String(b64);
            return new X509Certificate2(der);
        }
        catch { return null; }
    }

    private static string StripPort(string host)
    {
        var colon = host.LastIndexOf(':');
        return colon > 0 ? host[..colon] : host;
    }
}
