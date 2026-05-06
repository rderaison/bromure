// macos-source: Sources/AgentCoding/Mitm/AWSCredentialServer.swift @ 2a4bd9245f97
using System.Security.Cryptography;
using System.Text.Json;
using Bromure.AC.Mitm.Consent;
using Bromure.AC.Mitm.SigV4;

namespace Bromure.AC.Mitm.Aws;

/// <summary>
/// Direct port of <c>Sources/AgentCoding/Mitm/AWSCredentialServer.swift</c>.
///
/// <para>Per-profile AWS credential vendor — and host-side custodian of
/// the *real* signing material the resigner consumes.</para>
///
/// <para>Two surfaces:</para>
/// <list type="bullet">
///   <item><see cref="WriteCredentialProcessPayloadAsync"/> — what the
///   guest's <c>credential_process</c> helper talks to. Returns a
///   payload with the <b>real</b> AccessKeyId (so the SDK's identity
///   caching works) and a <b>fake</b> 40-char SecretAccessKey. The
///   SessionToken is omitted; the resigner injects the real one
///   before signing on the host.</item>
///   <item><see cref="SigningMaterialAsync"/> — what the resigner calls
///   per request. Returns the real bundle (after a consent prompt if
///   the credential is gated). Real secret never reaches the VM.</item>
/// </list>
/// </summary>
public sealed class AwsCredentialServer : IAwsCredentialServer
{
    private readonly object _gate = new();
    private readonly Dictionary<Guid, Entry> _byProfile = new();
    private readonly ConsentBroker _consent;

    public AwsCredentialServer(ConsentBroker consent) => _consent = consent;

    public void SetCredentials(AwsCredentials creds, Guid profileId)
    {
        lock (_gate)
        {
            if (!creds.IsUsable)
            {
                _byProfile.Remove(profileId);
                return;
            }
            _byProfile[profileId] = new Entry(
                AccessKeyId: creds.AccessKeyId,
                SecretAccessKey: creds.SecretAccessKey,
                SessionToken: creds.SessionToken,
                RequireApproval: creds.RequireApproval,
                VendedSecret: MakeFakeSecret());
        }
    }

    public void ClearCredentials(Guid profileId)
    {
        lock (_gate) _byProfile.Remove(profileId);
    }

    private Entry? Get(Guid profileId)
    {
        lock (_gate) return _byProfile.TryGetValue(profileId, out var e) ? e : null;
    }

    public async Task<SigningMaterial> SigningMaterialAsync(Guid profileId, string scopeHint, CancellationToken ct)
    {
        var entry = Get(profileId);
        if (entry is null) return new SigningMaterial.Missing();
        if (entry.RequireApproval)
        {
            var masked = AwsResigner.MaskAccessKey(entry.AccessKeyId);
            var allowed = await _consent.RequestConsentAsync(
                profileId, ConsentCredentialId.Aws(),
                $"AWS access key {masked}", scopeHint, ct).ConfigureAwait(false);
            if (!allowed) return new SigningMaterial.Denied();
        }
        return new SigningMaterial.Material(new SigV4Signer.Credentials(
            AccessKeyId: entry.AccessKeyId,
            SecretAccessKey: entry.SecretAccessKey,
            SessionToken: string.IsNullOrEmpty(entry.SessionToken) ? null : entry.SessionToken));
    }

    /// <summary>
    /// Serve one client connection. Pushes the (fake-secret) JSON
    /// payload and closes. No consent gate — the secret being vended is
    /// fake by construction.
    /// </summary>
    public async Task WriteCredentialProcessPayloadAsync(Stream stream, Guid profileId, CancellationToken ct = default)
    {
        var payload = JsonPayload(profileId);
        await stream.WriteAsync(payload, ct).ConfigureAwait(false);
        await stream.FlushAsync(ct).ConfigureAwait(false);
    }

    private byte[] JsonPayload(Guid profileId)
    {
        var entry = Get(profileId);
        if (entry is null)
        {
            return ErrorPayload("no AWS credentials configured for this profile");
        }
        // SDK accepts (Version, AccessKeyId, SecretAccessKey). Omit
        // Expiration so the SDK caches for the consumer process's
        // lifetime — fine here since the process dies with the VM.
        var json = JsonSerializer.Serialize(new SortedDictionary<string, object>
        {
            ["AccessKeyId"] = entry.AccessKeyId,
            ["SecretAccessKey"] = entry.VendedSecret,
            ["Version"] = 1,
        });
        return System.Text.Encoding.UTF8.GetBytes(json);
    }

    private static byte[] ErrorPayload(string message)
    {
        var json = JsonSerializer.Serialize(new SortedDictionary<string, object>
        {
            ["Error"] = message,
            ["Version"] = 1,
        });
        return System.Text.Encoding.UTF8.GetBytes(json);
    }

    /// <summary>
    /// 40-char alphabet-restricted random string in the same shape an
    /// AWS secret key takes on the wire (<c>[A-Za-z0-9+/]</c>). Doesn't
    /// authenticate against AWS — its only job is to look plausible to
    /// the SDK so signing doesn't crash, and unique per session.
    /// </summary>
    private static string MakeFakeSecret()
    {
        const string alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/";
        Span<byte> buf = stackalloc byte[40];
        RandomNumberGenerator.Fill(buf);
        var output = new char[40];
        for (var i = 0; i < 40; i++) output[i] = alphabet[buf[i] % alphabet.Length];
        return new string(output);
    }

    private sealed record Entry(
        string AccessKeyId,
        string SecretAccessKey,
        string SessionToken,
        bool RequireApproval,
        string VendedSecret);
}
