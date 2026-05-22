namespace Bromure.AC.Core.Model;

/// <summary>
/// Mutable credential records for the Profile editor + per-session
/// materialisation. Equivalent of the Swift `var`-everything structs in
/// <c>Profile.swift</c>; chose plain classes over <c>record</c> with
/// <c>set</c> so WPF's two-way binding can write back on every keystroke
/// without us needing INotifyPropertyChanged on every leaf field.
/// </summary>
public sealed class GitHttpsCredential
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Host { get; set; } = "";
    public string Username { get; set; } = "";
    public string Token { get; set; } = "";
    public bool RequireApproval { get; set; }

    /// True iff every field needed for ~/.git-credentials emission is
    /// non-empty after trimming. Mirrors
    /// <c>GitHttpsCredential.isUsable</c> on macOS Profile.swift:286.
    public bool IsUsable
        => !string.IsNullOrWhiteSpace(Host)
           && !string.IsNullOrWhiteSpace(Username)
           && !string.IsNullOrWhiteSpace(Token);
}

public sealed class ManualToken
{
    public Guid Id { get; set; } = Guid.NewGuid();
    /// Display name shown in the Approvals window.
    public string Name { get; set; } = "";
    /// Cleartext value (the "real").
    public string Value { get; set; } = "";
    /// Optional env var name to export inside the VM (the fake).
    public string EnvVarName { get; set; } = "";
    /// Optional host scope. Empty = "any host" (rarely what users want).
    public string HostFilter { get; set; } = "";
    public bool RequireApproval { get; set; }

    /// True iff there's a real value to swap on the wire. Mirrors
    /// <c>ManualToken.isUsable</c> on macOS Profile.swift:232.
    public bool IsUsable => !string.IsNullOrWhiteSpace(Value);
}

public sealed class DockerRegistryCredential
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Host { get; set; } = "";
    public string Username { get; set; } = "";
    public string Password { get; set; } = "";
    public bool RequireApproval { get; set; }

    /// True iff host + username + password are all non-empty after
    /// trimming. Mirrors <c>DockerRegistryCredential.isUsable</c> on
    /// macOS Profile.swift:353.
    public bool IsUsable
        => !string.IsNullOrWhiteSpace(Host)
           && !string.IsNullOrWhiteSpace(Username)
           && !string.IsNullOrWhiteSpace(Password);
}

public sealed class AwsCredentialsConfig
{
    public AwsAuthMode AuthMode { get; set; } = AwsAuthMode.Sso;
    /// SSO mode: profile name in ~/.aws/config to drive SSO from.
    public string SsoProfile { get; set; } = "";
    /// Static-keys mode: explicit AKID / secret / session token.
    public string AccessKeyId { get; set; } = "";
    public string SecretAccessKey { get; set; } = "";
    public string SessionToken { get; set; } = "";
    /// Default region used in ~/.aws/config and AWS_DEFAULT_REGION env.
    public string Region { get; set; } = "";
    public bool RequireApproval { get; set; }

    /// True iff this config has the material the resigner needs for
    /// its auth mode. Mirrors <c>AWSCredentials.isUsable</c> on macOS
    /// Profile.swift:448 — SSO needs a profile name, static keys
    /// need both AKID and secret.
    public bool IsUsable => AuthMode switch
    {
        AwsAuthMode.Sso => !string.IsNullOrWhiteSpace(SsoProfile),
        AwsAuthMode.StaticKeys => !string.IsNullOrWhiteSpace(AccessKeyId)
                                  && !string.IsNullOrWhiteSpace(SecretAccessKey),
        _ => false,
    };
}

public sealed class EnvironmentVariable
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public string Value { get; set; } = "";
    /// True when the editor's "treat as secret" toggle is on — the value
    /// is masked in the UI and excluded from screenshots.
    public bool IsSecret { get; set; }

    /// True iff <see cref="Name"/> is a syntactically valid POSIX env-var
    /// name. Direct port of <c>EnvironmentVariable.isValidName</c>
    /// (macOS Profile.swift:519): must start with a letter or
    /// underscore, then letters / digits / underscores only.
    /// Editor binds this to live validation feedback.
    public bool IsValidName => IsValidEnvVarName(Name);

    public static bool IsValidEnvVarName(string? name)
    {
        if (string.IsNullOrEmpty(name)) return false;
        var first = name[0];
        if (!(char.IsLetter(first) || first == '_')) return false;
        for (var i = 1; i < name.Length; i++)
        {
            var c = name[i];
            if (!(char.IsLetterOrDigit(c) || c == '_')) return false;
        }
        return true;
    }
}

public sealed class ImportedSshKey
{
    public Guid Id { get; set; } = Guid.NewGuid();
    /// Display label for the Approvals UI.
    public string Label { get; set; } = "";
    /// PEM-encoded private key (OpenSSH format).
    public string PrivateKeyPem { get; set; } = "";
    public string Comment { get; set; } = "";
    public bool RequireApproval { get; set; }

    /// True iff the PEM looks plausibly like an OpenSSH private key —
    /// gates UI badges and engine-side loader attempts.
    public bool IsUsable
        => !string.IsNullOrWhiteSpace(PrivateKeyPem)
           && PrivateKeyPem.Contains("BEGIN OPENSSH PRIVATE KEY", StringComparison.Ordinal);
}

public sealed class StoredOAuthTokens
{
    public string AccessToken { get; set; } = "";
    public string RefreshToken { get; set; } = "";
    public string? IdToken { get; set; }

    /// <summary>Wall-clock UTC at which these tokens were captured.
    /// Used by the auto-seed-on-boot path to decide whether the
    /// stored real tokens are still fresh enough to inject. macOS
    /// stores this on Profile.swift:1342. Audit 01 §2.</summary>
    public DateTimeOffset? SavedAt { get; set; }
}

/// <summary>
/// Constructor-style factory helpers so call sites that used to
/// <c>new GitHttpsCredential(id, host, user, token)</c> stay terse.
/// Without these the project-wide diff is large.
/// </summary>
public static class CredentialFactory
{
    public static GitHttpsCredential GitHttps(Guid id, string host, string username, string token, bool require = false)
        => new() { Id = id, Host = host, Username = username, Token = token, RequireApproval = require };

    public static ManualToken Manual(Guid id, string name, string value, string envVar = "", string host = "", bool require = false)
        => new() { Id = id, Name = name, Value = value, EnvVarName = envVar, HostFilter = host, RequireApproval = require };

    public static DockerRegistryCredential Docker(Guid id, string host, string username, string password, bool require = false)
        => new() { Id = id, Host = host, Username = username, Password = password, RequireApproval = require };

    public static EnvironmentVariable Env(Guid id, string name, string value, bool secret = false)
        => new() { Id = id, Name = name, Value = value, IsSecret = secret };

    public static ImportedSshKey Ssh(Guid id, string label, string pem, string comment = "", bool require = false)
        => new() { Id = id, Label = label, PrivateKeyPem = pem, Comment = comment, RequireApproval = require };
}
