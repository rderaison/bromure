using System.Text.Json.Serialization;
using Bromure.AC.Core.Vault;

namespace Bromure.AC.Core.Model;

/// <summary>
/// Direct port of <c>KubeconfigEntry</c> from <c>Profile.swift</c>.
/// Mutable so the editor can two-way bind to the leaf fields.
/// </summary>
public sealed class KubeconfigEntry
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public string ServerUrl { get; set; } = "";
    public string CaCertPem { get; set; } = "";
    public string Namespace { get; set; } = "";
    public KubeAuth Auth { get; set; } = new KubeBearerToken { Token = "" };
    public bool RequireApproval { get; set; }

    /// <summary>Bare host[:port] used as the proxy's routing key.</summary>
    [JsonIgnore]
    public string HostPattern
    {
        get
        {
            if (string.IsNullOrEmpty(ServerUrl)) return "";
            try
            {
                var u = new Uri(ServerUrl);
                return u.IsDefaultPort ? u.Host : $"{u.Host}:{u.Port}";
            }
            catch { return ""; }
        }
    }
}

/// <summary>
/// Discriminated-union auth shapes. JSON tagged via <c>kind</c> per the
/// macOS encoder. Mutable so the editor's TextBoxes can write back.
/// </summary>
[JsonPolymorphic(TypeDiscriminatorPropertyName = "kind")]
[JsonDerivedType(typeof(KubeBearerToken), "bearerToken")]
[JsonDerivedType(typeof(KubeClientCert), "clientCert")]
[JsonDerivedType(typeof(KubeExecPlugin), "execPlugin")]
public abstract class KubeAuth { }

public sealed class KubeBearerToken : KubeAuth
{
    [JsonConverter(typeof(EncryptedStringConverter))]
    public string Token { get; set; } = "";
}

public sealed class KubeClientCert : KubeAuth
{
    public string Cert { get; set; } = "";
    [JsonConverter(typeof(EncryptedStringConverter))]
    public string Key { get; set; } = "";
}

public sealed class KubeExecPlugin : KubeAuth
{
    public string Command { get; set; } = "";
    public List<string> Args { get; set; } = new();
    public int RefreshSeconds { get; set; } = 600;
}
