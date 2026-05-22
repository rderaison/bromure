using System.Net.Http;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using Org.BouncyCastle.Asn1.Pkcs;
using Org.BouncyCastle.Asn1.X509;
using Org.BouncyCastle.Crypto.Operators;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Pkcs;
using Org.BouncyCastle.Security;

namespace Bromure.AC.Core.Enrollment;

/// <summary>
/// Direct port of the network half of <c>Sources/AgentCoding/Enrollment.swift</c>.
/// Exchanges a six-word enrollment code for an install identity +
/// bearer token at the bromure.io control plane, then issues a CSR
/// for the leaf mTLS cert that the cloud uploader presents on every
/// batch.
/// </summary>
public sealed class EnrollmentClient
{
    /// <summary>
    /// Default server. The macOS port targets <c>bromure.io/api</c>;
    /// for browser-facing dashboards we use <c>app.bromure.io</c>.
    /// Both proxy to the same backend — the URL is overridden via the
    /// enrollment-sheet text field in dev.
    /// </summary>
    public static readonly Uri DefaultServerUrl = new("https://app.bromure.io");

    /// <summary>Default cloud-event ingest URL. Routes through the
    /// analytics frontend with its own mTLS termination. Keep in
    /// lock-step with <c>EnrollmentStore.DefaultIngestUrl()</c>.</summary>
    public static readonly Uri DefaultAnalyticsUrl = new("https://analytics.bromure.io/ac-ingest");

    private readonly HttpClient _http;

    public EnrollmentClient(HttpClient? http = null)
    {
        _http = http ?? new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
    }

    public async Task<EnrollOutcome> EnrollAsync(
        string code,
        string deviceName,
        Uri? serverUrl = null,
        CancellationToken ct = default)
    {
        var server = serverUrl ?? DefaultServerUrl;
        var endpoint = new Uri(server, "/v1/enroll");
        var trimmed = code.Trim();
        if (string.IsNullOrEmpty(trimmed)) throw new ArgumentException("Code is empty.", nameof(code));

        // The server requires an installPubkey (32-byte X25519
        // identity used for sealed-box managed-profile delivery).
        // BAC doesn't currently consume profile bundles, but the
        // enrollment schema demands the field — keep the symmetry
        // with Bromure Web. Direct port of Enrollment.swift:259-272.
        var installPubkey = NewInstallPubkey();
        using var req = new HttpRequestMessage(HttpMethod.Post, endpoint)
        {
            Content = JsonContent.Create(new
            {
                code = trimmed,
                installPubkey = BytesToHex(installPubkey),
                deviceName,
                app = "agentic-coding",
            }),
        };
        using var resp = await _http.SendAsync(req, ct).ConfigureAwait(false);
        var bodyText = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        if (!resp.IsSuccessStatusCode)
        {
            throw new EnrollmentException($"HTTP {(int)resp.StatusCode}: {Truncate(bodyText, 200)}");
        }

        EnrollResponse parsed;
        try
        {
            parsed = JsonSerializer.Deserialize<EnrollResponse>(bodyText, JsonOptions)
                ?? throw new EnrollmentException("Empty response body");
        }
        catch (JsonException ex)
        {
            throw new EnrollmentException("Server returned malformed JSON: " + ex.Message);
        }
        if (!string.Equals(parsed.App, "agentic-coding", StringComparison.Ordinal))
        {
            throw new EnrollmentException(
                $"Code was issued for app '{parsed.App}', expected 'agentic-coding'.");
        }

        var install = new BromureInstall(
            InstallId: parsed.InstallId,
            OrgSlug: parsed.OrgSlug,
            UserId: parsed.UserId,
            UserEmail: parsed.UserEmail,
            ServerUrl: server,
            EnrolledAt: DateTimeOffset.UtcNow,
            DeviceName: deviceName);
        return new EnrollOutcome(install, parsed.InstallToken);
    }

    /// <summary>
    /// Issue a leaf cert from the org CA. <paramref name="installId"/>
    /// + <paramref name="bearer"/> authenticate the request; the
    /// server returns a leaf cert + CA cert + serial. Mirrors
    /// <c>Enrollment.swift:314-349</c>'s <c>fetchLeafCert</c>.
    /// </summary>
    public async Task<CertIssuance> RequestCertAsync(
        string installId, string bearer, Uri serverUrl, CancellationToken ct = default)
    {
        // Generate an RSA-2048 keypair + CSR with CN bound to the
        // install id. Same shape macOS uses with swift-asn1.
        var keys = GenerateRsaKeyPair(2048);
        var subject = new X509Name("CN=bromure-install-" + installId);
        var sigFactory = new Asn1SignatureFactory("SHA256WITHRSA", keys.Private);
        var csr = new Pkcs10CertificationRequest(sigFactory, subject, keys.Public, attributes: null);

        var csrDer = csr.GetDerEncoded();
        var b64 = Convert.ToBase64String(csrDer);
        var csrPem = "-----BEGIN CERTIFICATE REQUEST-----\n"
                     + InsertLineBreaks(b64, 64)
                     + "\n-----END CERTIFICATE REQUEST-----\n";

        var endpoint = new Uri(serverUrl, $"/v1/installs/{installId}/cert");
        using var req = new HttpRequestMessage(HttpMethod.Post, endpoint)
        {
            Content = JsonContent.Create(new { csrPem }),
        };
        req.Headers.TryAddWithoutValidation("Authorization", "Bearer " + bearer);

        using var resp = await _http.SendAsync(req, ct).ConfigureAwait(false);
        var bodyText = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        if (!resp.IsSuccessStatusCode)
        {
            throw new EnrollmentException(
                $"cert issuance: HTTP {(int)resp.StatusCode}: {Truncate(bodyText, 200)}");
        }
        var parsed = JsonSerializer.Deserialize<CertResponse>(bodyText, JsonOptions)
                     ?? throw new EnrollmentException("cert response was empty");

        var privateKeyDer = PrivateKeyInfoFactory
            .CreatePrivateKeyInfo(keys.Private).GetDerEncoded();
        return new CertIssuance(
            CertPem: parsed.CertPem,
            CaCertPem: parsed.CaCertPem,
            SerialHex: parsed.SerialHex,
            PrivateKeyDer: privateKeyDer,
            NotAfter: parsed.NotAfter);
    }

    /// <summary>
    /// Heartbeat the install with the control plane (~every 10 min).
    /// Lets the admin dashboard show "last seen N minutes ago" + the
    /// server rotate the leaf cert when its NotAfter approaches.
    /// Direct port of <c>ManagedProfileClient.swift:151</c>.
    /// </summary>
    public async Task HeartbeatAsync(string installId, string bearer, Uri serverUrl, CancellationToken ct = default)
    {
        var endpoint = new Uri(serverUrl, $"/v1/installs/{installId}/heartbeat");
        using var req = new HttpRequestMessage(HttpMethod.Post, endpoint);
        req.Headers.TryAddWithoutValidation("Authorization", "Bearer " + bearer);
        using var resp = await _http.SendAsync(req, ct).ConfigureAwait(false);
        if (!resp.IsSuccessStatusCode)
        {
            var body = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            throw new EnrollmentException($"heartbeat: HTTP {(int)resp.StatusCode}: {Truncate(body, 200)}");
        }
    }

    /// <summary>Tell the server this install is gone so the admin
    /// dashboard moves the row to "revoked". macOS posts to
    /// <c>/v1/installs/{installId}/unenroll</c>.</summary>
    public async Task UnenrollAsync(string installId, string bearer, Uri serverUrl, CancellationToken ct = default)
    {
        var endpoint = new Uri(serverUrl, $"/v1/installs/{installId}/unenroll");
        using var req = new HttpRequestMessage(HttpMethod.Post, endpoint);
        req.Headers.TryAddWithoutValidation("Authorization", "Bearer " + bearer);
        using var resp = await _http.SendAsync(req, ct).ConfigureAwait(false);
        if (!resp.IsSuccessStatusCode)
        {
            var body = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            throw new EnrollmentException($"unenroll: HTTP {(int)resp.StatusCode}: {Truncate(body, 200)}");
        }
    }

    private static AsymmetricCipherKeyPair_Wrap GenerateRsaKeyPair(int bits)
    {
        var gen = new Org.BouncyCastle.Crypto.Generators.RsaKeyPairGenerator();
        gen.Init(new RsaKeyGenerationParameters(
            publicExponent: Org.BouncyCastle.Math.BigInteger.ValueOf(65537),
            random: new SecureRandom(),
            strength: bits,
            certainty: 25));
        var pair = gen.GenerateKeyPair();
        return new AsymmetricCipherKeyPair_Wrap(pair.Public, pair.Private);
    }

    private static byte[] NewInstallPubkey()
    {
        // 32 random bytes — the server stamps it on the install row.
        // BAC isn't yet consuming sealed managed-profile bundles, so
        // we don't need the private half live in memory; the server
        // only cares that the field is present + 32 bytes long.
        return RandomNumberGenerator.GetBytes(32);
    }

    private static string BytesToHex(byte[] bytes)
    {
        var sb = new System.Text.StringBuilder(bytes.Length * 2);
        foreach (var b in bytes) sb.Append(b.ToString("x2"));
        return sb.ToString();
    }

    private static string InsertLineBreaks(string b64, int width)
    {
        var sb = new System.Text.StringBuilder(b64.Length + b64.Length / width + 2);
        for (var i = 0; i < b64.Length; i += width)
        {
            if (i > 0) sb.Append('\n');
            sb.Append(b64.AsSpan(i, Math.Min(width, b64.Length - i)));
        }
        return sb.ToString();
    }

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    private static string Truncate(string s, int max)
        => s.Length <= max ? s : s[..max] + "…";

    public sealed record EnrollOutcome(BromureInstall Install, string BearerToken);

    public sealed record CertIssuance(
        string CertPem, string CaCertPem, string SerialHex,
        byte[] PrivateKeyDer, DateTimeOffset NotAfter);

    public sealed class EnrollResponse
    {
        [JsonPropertyName("installId")] public string InstallId { get; set; } = "";
        [JsonPropertyName("orgSlug")] public string OrgSlug { get; set; } = "";
        [JsonPropertyName("userId")] public string UserId { get; set; } = "";
        [JsonPropertyName("userEmail")] public string UserEmail { get; set; } = "";
        [JsonPropertyName("installToken")] public string InstallToken { get; set; } = "";
        [JsonPropertyName("app")] public string App { get; set; } = "";
    }

    public sealed class CertResponse
    {
        [JsonPropertyName("certPem")] public string CertPem { get; set; } = "";
        [JsonPropertyName("caCertPem")] public string CaCertPem { get; set; } = "";
        [JsonPropertyName("serialHex")] public string SerialHex { get; set; } = "";
        [JsonPropertyName("notAfter")] public DateTimeOffset NotAfter { get; set; }
    }

    /// <summary>BC's AsymmetricCipherKeyPair holds two interface
    /// references; wrap it in a struct that exposes them under
    /// the same names the rest of the file uses.</summary>
    private readonly record struct AsymmetricCipherKeyPair_Wrap(
        Org.BouncyCastle.Crypto.AsymmetricKeyParameter Public,
        Org.BouncyCastle.Crypto.AsymmetricKeyParameter Private);
}

public sealed class EnrollmentException : Exception
{
    public EnrollmentException(string message) : base(message) { }
}
