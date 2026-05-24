// macos-source: Sources/AgentCoding/Mitm/SSHAgent.swift @ 7c8491d4a21f
using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Security.Cryptography;
using Bromure.AC.Mitm.Consent;

namespace Bromure.AC.Mitm.Ssh;

/// <summary>
/// Direct port of <c>Sources/AgentCoding/Mitm/SSHAgent.swift</c>.
///
/// <para>Per-profile key vault + consent gate sitting in front of
/// <see cref="PrivateSshAgent"/>. Keys never cross vsock — the agent
/// protocol has no "give me the private key" message, so VM clients
/// only ever see <c>SIGN_RESPONSE</c> blobs. <see cref="RequireApproval"/>
/// keys gate every signature on a fresh consent decision (with the
/// 5min/1hr/session windows from <see cref="ConsentBroker"/>).</para>
///
/// <para><b>Threat model.</b> The user's host-level OpenSSH agent is
/// intentionally NOT exposed to the VM. Keys the user wants reachable
/// go through the explicit-import flow in the profile UI.</para>
/// </summary>
public sealed class SshAgentServer
{
    private readonly ConcurrentDictionary<Guid, IReadOnlyList<AgentKey>> _keysByProfile = new();
    private readonly ConcurrentDictionary<Guid, Dictionary<string, ImportedApproval>> _importedApprovals = new();
    private readonly ConsentBroker _consent;

    public SshAgentServer(ConsentBroker consent) => _consent = consent;

    public sealed record ImportedApproval(string Label, string ConsentCredentialId);

    public void SetKeys(IReadOnlyList<AgentKey> keys, Guid profileId)
    {
        _keysByProfile[profileId] = keys;
    }

    public void ClearKeys(Guid profileId) => _keysByProfile.TryRemove(profileId, out _);

    public void SetImportedKeyApprovals(IReadOnlyDictionary<byte[], ImportedApproval> entries, Guid profileId)
    {
        var byKey = new Dictionary<string, ImportedApproval>(StringComparer.Ordinal);
        foreach (var (blob, app) in entries)
        {
            byKey[Convert.ToBase64String(blob)] = app;
        }
        _importedApprovals[profileId] = byKey;
    }

    public void ClearImportedKeyApprovals(Guid profileId) => _importedApprovals.TryRemove(profileId, out _);

    public IReadOnlyList<AgentKey> KeysFor(Guid profileId)
        => _keysByProfile.TryGetValue(profileId, out var v) ? v : Array.Empty<AgentKey>();

    /// <summary>
    /// SSH agent message types — stable across implementations. Mirrored
    /// from draft-miller-ssh-agent-04.
    /// </summary>
    public static class Op
    {
        public const byte SSH_AGENT_FAILURE = 5;
        public const byte SSH_AGENT_SUCCESS = 6;
        public const byte SSH_AGENTC_REQUEST_IDENTITIES = 11;
        public const byte SSH_AGENT_IDENTITIES_ANSWER = 12;
        public const byte SSH_AGENTC_SIGN_REQUEST = 13;
        public const byte SSH_AGENT_SIGN_RESPONSE = 14;
    }

    /// <summary>
    /// Build the IDENTITIES_ANSWER for a profile. Agent message body —
    /// caller frames it.
    /// </summary>
    public byte[] BuildIdentitiesAnswer(Guid profileId)
    {
        var keys = KeysFor(profileId);
        var ms = new MemoryStream();
        ms.WriteByte(Op.SSH_AGENT_IDENTITIES_ANSWER);
        WriteU32Be(ms, (uint)keys.Count);
        foreach (var k in keys)
        {
            WriteString(ms, k.PublicKeyBlob);
            WriteString(ms, System.Text.Encoding.UTF8.GetBytes(k.Comment));
        }
        return ms.ToArray();
    }

    /// <summary>
    /// Handle a SIGN_REQUEST asynchronously. Async because the consent
    /// broker may pop a dialog. Returns the agent message to write back
    /// (either <c>SIGN_RESPONSE</c> or <c>FAILURE</c>).
    /// </summary>
    public async Task<byte[]> HandleSignRequestAsync(ReadOnlyMemory<byte> body, Guid profileId, CancellationToken ct)
    {
        // Materialize spans into byte arrays before the first await — ref
        // structs can't cross await suspension points.
        ParseSignRequest(body.Span, out var publicBlob, out var toSign, out var flags);

        var keys = KeysFor(profileId);
        AgentKey? key = null;
        foreach (var k in keys)
        {
            if (publicBlob.AsSpan().SequenceEqual(k.PublicKeyBlob)) { key = k; break; }
        }
        if (key is null)
        {
            // Unknown public key — caller mistakenly forwarded a
            // SIGN_REQUEST for a key we don't hold.
            return new[] { Op.SSH_AGENT_FAILURE };
        }

        if (key.RequireApproval)
        {
            var credId = key.ConsentCredentialId ?? ConsentCredentialId.SshKey(FingerprintHex(key));
            var allowed = await _consent.RequestConsentAsync(
                profileId, credId, $"SSH key “{key.Comment}”",
                "to authenticate an SSH connection from the VM", ct).ConfigureAwait(false);
            if (!allowed) return new[] { Op.SSH_AGENT_FAILURE };
        }

        var (sig, sigFormat) = key.Sign(toSign, flags);
        var sigBlob = new MemoryStream();
        WriteString(sigBlob, sigFormat);
        WriteString(sigBlob, sig);

        var output = new MemoryStream();
        output.WriteByte(Op.SSH_AGENT_SIGN_RESPONSE);
        WriteString(output, sigBlob.ToArray());
        return output.ToArray();
    }

    private static string FingerprintHex(AgentKey k)
    {
        Span<byte> hash = stackalloc byte[32];
        SHA256.HashData(k.PublicKey, hash);
        var sb = new System.Text.StringBuilder();
        foreach (var b in hash) sb.Append(b.ToString("x2"));
        return sb.ToString();
    }

    /// <summary>Pull the SIGN_REQUEST body's two ssh-strings + u32 flags
    /// out. Flags drive the RSA-SHA2 algorithm selection (RFC 8332).
    /// Missing flags = 0 (legacy behaviour) — fine since the key's own
    /// <see cref="AgentKey.Sign"/> picks its default in that case.</summary>
    private static void ParseSignRequest(ReadOnlySpan<byte> input, out byte[] publicBlob, out byte[] data, out uint flags)
    {
        publicBlob = ReadString(input, out var afterPub).ToArray();
        data = ReadString(afterPub, out var afterData).ToArray();
        flags = afterData.Length >= 4
            ? BinaryPrimitives.ReadUInt32BigEndian(afterData)
            : 0u;
    }

    private static ReadOnlySpan<byte> ReadString(ReadOnlySpan<byte> input, out ReadOnlySpan<byte> rest)
    {
        rest = default;
        if (input.Length < 4) return default;
        var len = (int)BinaryPrimitives.ReadUInt32BigEndian(input);
        if (input.Length < 4 + len) return default;
        rest = input[(4 + len)..];
        return input.Slice(4, len);
    }

    private static void WriteString(MemoryStream ms, string s)
        => WriteString(ms, System.Text.Encoding.UTF8.GetBytes(s));
    private static void WriteString(MemoryStream ms, ReadOnlySpan<byte> data)
    {
        WriteU32Be(ms, (uint)data.Length);
        ms.Write(data);
    }
    private static void WriteU32Be(MemoryStream ms, uint v)
    {
        Span<byte> buf = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(buf, v);
        ms.Write(buf);
    }
}
