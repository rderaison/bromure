// macos-source: Sources/AgentCoding/Enrollment.swift @ 841d4b4e44e2
using System.Text.Json;
using Bromure.Platform;

namespace Bromure.AC.Core.Enrollment;

/// <summary>
/// Direct port of <c>BACInstall</c> + <c>BACEnrollmentStore</c> from
/// <c>Sources/AgentCoding/Enrollment.swift</c>.
///
/// <para>One install identity per host. The admin mints an enrollment
/// code on the user detail page, the user pastes it into the host's
/// enrollment sheet, the install row appears at
/// <c>/agentic-coding/installs</c>. The install bearer + leaf cert key
/// land in <see cref="ISecretStore"/>; the install metadata + leaf
/// cert PEM land on disk under <see cref="IAppPaths.AppDataRoot"/>.</para>
/// </summary>
public sealed record BromureInstall(
    string InstallId,
    string OrgSlug,
    string UserId,
    string UserEmail,
    Uri ServerUrl,
    DateTimeOffset EnrolledAt,
    string DeviceName);

public sealed class EnrollmentNotEnrolledException : Exception
{
    public EnrollmentNotEnrolledException()
        : base("Not enrolled with bromure.io yet.") { }
}

public sealed class EnrollmentWrongAppException : Exception
{
    public EnrollmentWrongAppException(string got)
        : base($"Code was issued for app '{got}', expected 'agentic-coding'.") { }
}

/// <summary>
/// Persistence layer for the enrollment artifacts. Static API on macOS;
/// instance API here so tests can swap in an in-memory <see cref="ISecretStore"/>.
/// </summary>
public sealed class EnrollmentStore
{
    private const string InstallTokenSecret = "install-token";
    private const string LeafCertKeyPrefix = "leaf-cert-key-";

    private readonly IAppPaths _paths;
    private readonly ISecretStore _secrets;

    public EnrollmentStore(IAppPaths paths, ISecretStore secrets)
    {
        _paths = paths;
        _secrets = secrets;
    }

    private string ManagedDir
    {
        get
        {
            var p = Path.Combine(_paths.AppDataRoot, "managed");
            Directory.CreateDirectory(p);
            return p;
        }
    }

    private string InstallJsonPath => Path.Combine(ManagedDir, "install.json");
    private string LeafCertPemPath => Path.Combine(ManagedDir, "leaf.crt");
    private string CaCertPemPath => Path.Combine(ManagedDir, "ca.crt");
    private string LeafSerialPath => Path.Combine(ManagedDir, "leaf.serial");

    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    // -- install identity ----------------------------------------------

    public BromureInstall? Load()
    {
        if (!File.Exists(InstallJsonPath)) return null;
        try
        {
            using var fs = File.OpenRead(InstallJsonPath);
            return JsonSerializer.Deserialize<BromureInstall>(fs, Options);
        }
        catch (JsonException) { return null; }
    }

    public void Save(BromureInstall install)
    {
        Directory.CreateDirectory(ManagedDir);
        var tmp = InstallJsonPath + ".tmp";
        using (var fs = File.Create(tmp))
        {
            JsonSerializer.Serialize(fs, install, Options);
        }
        File.Move(tmp, InstallJsonPath, overwrite: true);
    }

    /// <summary>
    /// Wipe everything: install metadata, bearer token, leaf cert + key,
    /// CA cert. The next launch comes back to the "not enrolled" state.
    /// </summary>
    public void Destroy()
    {
        try { File.Delete(InstallJsonPath); } catch (IOException) { }
        try { File.Delete(LeafCertPemPath); } catch (IOException) { }
        try { File.Delete(CaCertPemPath); } catch (IOException) { }
        try { File.Delete(LeafSerialPath); } catch (IOException) { }
        _secrets.DeleteSecret("BromureAC", InstallTokenSecret);

        // Walk leaf-cert-key blobs and delete each by serial.
        // (Cheap — at most a handful as cert renewal turns over.)
        var leafSerial = LoadLeafSerial();
        if (leafSerial is not null)
        {
            _secrets.DeleteBlob(LeafCertKeyPrefix + leafSerial, BlobScope.LocalMachine);
        }
    }

    // -- bearer token --------------------------------------------------

    public void StoreInstallToken(string token)
        => _secrets.StoreSecret("BromureAC", InstallTokenSecret, token);

    public string? LoadInstallToken()
        => _secrets.ReadSecret("BromureAC", InstallTokenSecret);

    // -- mTLS leaf material --------------------------------------------

    public void StoreLeafCert(string certPem, string caPem, byte[] privateKeyDer, string serialHex)
    {
        var lower = serialHex.ToLowerInvariant();
        File.WriteAllText(LeafCertPemPath, certPem);
        File.WriteAllText(CaCertPemPath, caPem);
        _secrets.StoreBlob(LeafCertKeyPrefix + lower, privateKeyDer, BlobScope.LocalMachine);
        // Serial pointer last so a partially-completed rotation leaves
        // the previous (cert, key) pair selectable.
        File.WriteAllText(LeafSerialPath, lower);
    }

    public string? LoadLeafCertPem() =>
        File.Exists(LeafCertPemPath) ? File.ReadAllText(LeafCertPemPath) : null;

    public string? LoadCaPem() =>
        File.Exists(CaCertPemPath) ? File.ReadAllText(CaCertPemPath) : null;

    public string? LoadLeafSerial() =>
        File.Exists(LeafSerialPath) ? File.ReadAllText(LeafSerialPath).Trim() : null;

    public byte[]? LoadLeafPrivateKey(string serialHex)
        => _secrets.ReadBlob(LeafCertKeyPrefix + serialHex.ToLowerInvariant(), BlobScope.LocalMachine);

    public bool IsEnrolled => Load() is not null && LoadInstallToken() is not null;

    /// <summary>
    /// Cloud event ingest endpoint. Honours
    /// <c>BROMURE_AC_INGEST_URL</c> for local dev; defaults to the
    /// production analytics frontend. Mirrors macOS
    /// <c>BACEnrollmentStore.defaultAnalyticsURL</c> — the analytics
    /// service is internet-facing with its own mTLS termination,
    /// distinct from the API server in the install record.
    /// </summary>
    public static Uri DefaultIngestUrl()
    {
        var env = Environment.GetEnvironmentVariable("BROMURE_AC_INGEST_URL");
        if (!string.IsNullOrEmpty(env) && Uri.TryCreate(env, UriKind.Absolute, out var u))
            return u;
        return new Uri("https://analytics.bromure.io/ac-ingest");
    }
}
