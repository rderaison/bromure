using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using Bromure.AC.Core.Model;
using Bromure.AC.Mitm.Consent;

namespace Bromure.AC.Mitm.Pki;

/// <summary>
/// Slim port of the macOS <c>KubeconfigMaterializer</c> from
/// <c>Sources/AgentCoding/Mitm/CloudCredentials.swift</c>.
///
/// <para>Walks the profile's kubeconfigs, builds a single combined
/// kubeconfig YAML to drop into the VM, and surfaces the swap entries
/// + client identities the proxy needs to substitute real credentials
/// on the wire. Pure function — callers thread the result into the
/// swap map / identity registry / CA registry before VM start.</para>
///
/// <para>The macOS port also drives an exec-credential poller for the
/// kubectl exec-plugin flow. That poller belongs to a follow-up port —
/// this slice covers bearer-token + client-cert kubeconfigs which
/// are the dominant cases.</para>
/// </summary>
public sealed class KubeconfigMaterializer
{
    public sealed record Materialized(
        string Yaml,
        IReadOnlyList<BearerSwap> BearerSwaps,
        IReadOnlyList<ClientIdentitySpec> ClientIdentities,
        IReadOnlyList<ExecContext> ExecContexts,
        IReadOnlyList<(string Host, string CaPem)> ClusterCas);

    public sealed record BearerSwap(
        string Host,
        string FakeToken,
        string RealToken,
        string? ConsentCredentialId,
        string? ConsentDisplayName);

    public sealed record ClientIdentitySpec(
        string Host,
        X509Certificate2 Identity,
        string? ConsentCredentialId,
        string? ConsentDisplayName);

    public sealed record ExecContext(
        Guid EntryId,
        string Host,
        string FakeToken,
        string Command,
        IReadOnlyList<string> Args,
        int RefreshSeconds);

    public Materialized Materialize(Profile profile, string bromureCaPem)
    {
        var contexts = new StringBuilder();
        var clusters = new StringBuilder();
        var users = new StringBuilder();
        var bearerSwaps = new List<BearerSwap>();
        var identities = new List<ClientIdentitySpec>();
        var execs = new List<ExecContext>();
        var clusterCas = new List<(string, string)>();

        foreach (var entry in profile.Kubeconfigs)
        {
            var safeName = string.IsNullOrEmpty(entry.Name)
                ? entry.Id.ToString("D")[..8]
                : entry.Name;
            var clusterName = "cluster-" + safeName;
            var userName = "user-" + safeName;

            var caData = Convert.ToBase64String(Encoding.UTF8.GetBytes(bromureCaPem));
            if (!string.IsNullOrEmpty(entry.CaCertPem) && !string.IsNullOrEmpty(entry.HostPattern))
            {
                clusterCas.Add((entry.HostPattern, entry.CaCertPem));
            }

            clusters.AppendLine("- name: " + clusterName);
            clusters.AppendLine("  cluster:");
            clusters.AppendLine("    server: " + entry.ServerUrl);
            clusters.AppendLine("    certificate-authority-data: " + caData);

            contexts.AppendLine("- name: " + safeName);
            contexts.AppendLine("  context:");
            contexts.AppendLine("    cluster: " + clusterName);
            contexts.AppendLine("    user: " + userName);
            if (!string.IsNullOrEmpty(entry.Namespace))
            {
                contexts.AppendLine("    namespace: " + entry.Namespace);
            }

            string? consentId = entry.RequireApproval ? ConsentCredentialId.Kubeconfig(entry.Id) : null;
            var consentDisplay = string.IsNullOrEmpty(entry.Name)
                ? "kubeconfig context"
                : $"kubeconfig “{entry.Name}”";

            switch (entry.Auth)
            {
                case KubeBearerToken bearer:
                {
                    var fake = MakeFakeToken();
                    bearerSwaps.Add(new BearerSwap(entry.HostPattern, fake, bearer.Token, consentId, consentDisplay));
                    users.AppendLine("- name: " + userName);
                    users.AppendLine("  user:");
                    users.AppendLine("    token: " + fake);
                    break;
                }
                case KubeClientCert clientCert:
                {
                    if (TryBuildIdentity(clientCert.Cert, clientCert.Key, out var ident) && ident is not null)
                    {
                        identities.Add(new ClientIdentitySpec(entry.HostPattern, ident, consentId, consentDisplay));
                    }
                    var (throwawayCert, throwawayKey) = MakeThrowawayClientCert(userName);
                    users.AppendLine("- name: " + userName);
                    users.AppendLine("  user:");
                    users.AppendLine("    client-certificate-data: " + Convert.ToBase64String(Encoding.UTF8.GetBytes(throwawayCert)));
                    users.AppendLine("    client-key-data: " + Convert.ToBase64String(Encoding.UTF8.GetBytes(throwawayKey)));
                    break;
                }
                case KubeExecPlugin exec:
                {
                    var fake = MakeFakeToken();
                    bearerSwaps.Add(new BearerSwap(entry.HostPattern, fake, "", consentId, consentDisplay));
                    execs.Add(new ExecContext(entry.Id, entry.HostPattern, fake,
                        exec.Command, exec.Args, exec.RefreshSeconds));
                    users.AppendLine("- name: " + userName);
                    users.AppendLine("  user:");
                    users.AppendLine("    token: " + fake);
                    break;
                }
            }
        }

        var yaml = $$"""
            apiVersion: v1
            kind: Config
            clusters:
            {{Indent(clusters.ToString())}}
            contexts:
            {{Indent(contexts.ToString())}}
            users:
            {{Indent(users.ToString())}}
            current-context: {{(profile.Kubeconfigs.Count > 0 ? string.IsNullOrEmpty(profile.Kubeconfigs[0].Name) ? profile.Kubeconfigs[0].Id.ToString("D")[..8] : profile.Kubeconfigs[0].Name : "")}}
            """;

        return new Materialized(yaml, bearerSwaps, identities, execs, clusterCas);
    }

    private static string Indent(string s)
    {
        var sb = new StringBuilder();
        foreach (var line in s.Split('\n'))
        {
            if (line.Length == 0) continue;
            sb.AppendLine("  " + line);
        }
        return sb.ToString().TrimEnd('\r', '\n');
    }

    private static string MakeFakeToken()
    {
        // 40-char base62, in the same shape kubectl tokens land on the wire.
        const string alphabet = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
        var bytes = new byte[40];
        RandomNumberGenerator.Fill(bytes);
        var output = new char[40];
        for (var i = 0; i < 40; i++) output[i] = alphabet[bytes[i] % alphabet.Length];
        return new string(output);
    }

    private static bool TryBuildIdentity(string certPem, string keyPem, out X509Certificate2? identity)
    {
        try
        {
            var cert = X509Certificate2.CreateFromPem(certPem, keyPem);
            // Round-trip via PFX for SslStream-friendliness on Windows.
            var pfx = cert.Export(X509ContentType.Pfx);
            cert.Dispose();
            identity = new X509Certificate2(pfx, (string?)null,
                X509KeyStorageFlags.EphemeralKeySet | X509KeyStorageFlags.Exportable);
            return true;
        }
        catch (Exception)
        {
            identity = null;
            return false;
        }
    }

    /// <summary>
    /// Make a throwaway client cert + key the VM can load without
    /// caring about validity — kubectl validates the PEM structure but
    /// the proxy substitutes the real cert at the TLS handshake.
    /// </summary>
    private static (string CertPem, string KeyPem) MakeThrowawayClientCert(string commonName)
    {
        using var rsa = RSA.Create(2048);
        var req = new CertificateRequest($"CN={commonName}", rsa,
            HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        var cert = req.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1),
            DateTimeOffset.UtcNow.AddYears(1));
        var certPem = "-----BEGIN CERTIFICATE-----\n"
            + Convert.ToBase64String(cert.Export(X509ContentType.Cert))
                .Chunk(64).Aggregate(new StringBuilder(),
                    (sb, line) => sb.Append(new string(line)).Append('\n'),
                    sb => sb.ToString())
            + "-----END CERTIFICATE-----\n";
        var keyPem = "-----BEGIN PRIVATE KEY-----\n"
            + Convert.ToBase64String(rsa.ExportPkcs8PrivateKey())
                .Chunk(64).Aggregate(new StringBuilder(),
                    (sb, line) => sb.Append(new string(line)).Append('\n'),
                    sb => sb.ToString())
            + "-----END PRIVATE KEY-----\n";
        return (certPem, keyPem);
    }
}
