// macos-source: Sources/AgentCoding/AWSSSOResolver.swift @ 3317b1110551
using System.Diagnostics;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Bromure.AC.Core.Imports;

/// <summary>
/// Direct port of <c>Sources/AgentCoding/AWSSSOResolver.swift</c>.
///
/// <para>Resolves an AWS SSO profile name (from <c>~/.aws/config</c>)
/// into a fresh <see cref="ResolvedAwsCredentials"/> by either reading
/// the cached SSO token from <c>~/.aws/sso/cache/</c> or driving
/// <c>aws sso login</c> when the cache is stale.</para>
/// </summary>
public sealed record ResolvedAwsCredentials(
    string AccessKeyId,
    string SecretAccessKey,
    string SessionToken,
    string Region,
    DateTimeOffset Expiration);

public static class AwsSsoResolver
{
    public sealed class ResolveException : Exception
    {
        public ResolveException(string message) : base(message) { }
    }

    public static async Task<ResolvedAwsCredentials> ResolveAsync(
        string profileName,
        bool triggerLoginIfNeeded = true,
        Action<string>? progress = null,
        CancellationToken ct = default)
    {
        var profiles = AwsConfigParser.Discover();
        var profile = profiles.FirstOrDefault(p => p.Name == profileName);
        if (profile is null) throw new ResolveException($"SSO profile '{profileName}' not found in ~/.aws/config");

        var ssoRegion = string.IsNullOrEmpty(profile.SsoRegion) ? profile.Region : profile.SsoRegion;

        var cached = ReadCachedToken(profile.SsoStartUrl, ssoRegion, profile.SsoSessionName);
        if (cached is not null)
        {
            return await GetRoleCredentialsAsync(cached, profile.SsoAccountId, profile.SsoRoleName, ssoRegion, profile.Region, ct).ConfigureAwait(false);
        }

        if (!triggerLoginIfNeeded) throw new ResolveException("SSO token expired and login was not requested");

        progress?.Invoke("SSO login required — opening browser…");
        await RunSsoLoginAsync(profileName, ct).ConfigureAwait(false);

        var token = ReadCachedToken(profile.SsoStartUrl, ssoRegion, profile.SsoSessionName);
        if (token is null) throw new ResolveException("SSO login completed but cache token still missing");
        return await GetRoleCredentialsAsync(token, profile.SsoAccountId, profile.SsoRoleName, ssoRegion, profile.Region, ct).ConfigureAwait(false);
    }

    /// <summary>
    /// Refresh loop that re-resolves 5 minutes before expiration.
    /// Mirrors <c>startRefreshLoop</c> in the macOS source.
    /// </summary>
    public static Task StartRefreshLoopAsync(
        string profileName,
        DateTimeOffset initialExpiration,
        Action<ResolvedAwsCredentials> onRefresh,
        Action<Exception> onError,
        CancellationToken ct)
    {
        return Task.Run(async () =>
        {
            var expiration = initialExpiration;
            while (!ct.IsCancellationRequested)
            {
                var refreshAt = expiration - TimeSpan.FromMinutes(5);
                var delay = refreshAt - DateTimeOffset.UtcNow;
                if (delay < TimeSpan.FromSeconds(30)) delay = TimeSpan.FromSeconds(30);
                try { await Task.Delay(delay, ct).ConfigureAwait(false); }
                catch (OperationCanceledException) { return; }
                try
                {
                    var creds = await ResolveAsync(profileName, triggerLoginIfNeeded: false, ct: ct).ConfigureAwait(false);
                    expiration = creds.Expiration;
                    onRefresh(creds);
                }
                catch (Exception ex)
                {
                    onError(ex);
                    return;
                }
            }
        }, ct);
    }

    // -- SSO token cache ------------------------------------------------

    private static string? ReadCachedToken(string startUrl, string ssoRegion, string? sessionName)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var cacheDir = Path.Combine(home, ".aws", "sso", "cache");
        if (!Directory.Exists(cacheDir)) return null;

        // Direct hash lookup: SHA1("startUrl|region")
        var sessionKey = $"{startUrl}|{ssoRegion}";
        var hashFile = Path.Combine(cacheDir, Sha1Hex(sessionKey) + ".json");
        if (ExtractValidToken(hashFile) is { } direct) return direct;

        // Legacy: SHA1(startURL) only
        var legacyFile = Path.Combine(cacheDir, Sha1Hex(startUrl) + ".json");
        if (ExtractValidToken(legacyFile) is { } legacy) return legacy;

        // Fallback: scan all
        foreach (var file in Directory.EnumerateFiles(cacheDir, "*.json"))
        {
            try
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(file));
                var root = doc.RootElement;
                if (!root.TryGetProperty("accessToken", out var accessTokenEl)) continue;

                if (sessionName is not null
                    && root.TryGetProperty("sessionName", out var sessionEl)
                    && sessionEl.GetString() == sessionName)
                {
                    if (TryGetValidToken(accessTokenEl, root, out var matched)) return matched;
                }
                if (root.TryGetProperty("startUrl", out var urlEl) && urlEl.GetString() == startUrl
                    && root.TryGetProperty("region", out var regionEl) && regionEl.GetString() == ssoRegion)
                {
                    if (TryGetValidToken(accessTokenEl, root, out var matched)) return matched;
                }
            }
            catch (JsonException) { /* skip */ }
            catch (IOException) { /* skip */ }
        }
        return null;
    }

    private static string? ExtractValidToken(string filePath)
    {
        if (!File.Exists(filePath)) return null;
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(filePath));
            var root = doc.RootElement;
            if (!root.TryGetProperty("accessToken", out var accessTokenEl)) return null;
            return TryGetValidToken(accessTokenEl, root, out var v) ? v : null;
        }
        catch (JsonException) { return null; }
    }

    private static bool TryGetValidToken(JsonElement accessTokenEl, JsonElement root, out string token)
    {
        token = "";
        var s = accessTokenEl.GetString();
        if (string.IsNullOrEmpty(s)) return false;
        if (!root.TryGetProperty("expiresAt", out var expEl)) return false;
        var expStr = expEl.GetString();
        if (string.IsNullOrEmpty(expStr)) return false;
        if (!DateTimeOffset.TryParse(expStr, System.Globalization.CultureInfo.InvariantCulture,
            System.Globalization.DateTimeStyles.AssumeUniversal | System.Globalization.DateTimeStyles.AdjustToUniversal,
            out var expires)) return false;
        if ((expires - DateTimeOffset.UtcNow) < TimeSpan.FromMinutes(5)) return false;
        token = s!;
        return true;
    }

    private static string Sha1Hex(string s)
    {
        var bytes = Encoding.UTF8.GetBytes(s);
        var hash = SHA1.HashData(bytes);
        var sb = new StringBuilder(hash.Length * 2);
        foreach (var b in hash) sb.Append(b.ToString("x2", System.Globalization.CultureInfo.InvariantCulture));
        return sb.ToString();
    }

    // -- aws sso login -------------------------------------------------

    private static async Task RunSsoLoginAsync(string profileName, CancellationToken ct)
    {
        var psi = new ProcessStartInfo("aws.exe", $"sso login --profile {profileName}")
        {
            UseShellExecute = false,
            RedirectStandardError = true,
            RedirectStandardOutput = true,
            CreateNoWindow = true,
        };
        using var p = Process.Start(psi)
            ?? throw new ResolveException("could not invoke aws.exe — is the AWS CLI installed?");
        var stderrTask = p.StandardError.ReadToEndAsync(ct);
        await p.WaitForExitAsync(ct).ConfigureAwait(false);
        if (p.ExitCode != 0)
        {
            throw new ResolveException($"aws sso login failed: {await stderrTask.ConfigureAwait(false)}");
        }
    }

    // -- GetRoleCredentials --------------------------------------------

    private static async Task<ResolvedAwsCredentials> GetRoleCredentialsAsync(
        string accessToken, string accountId, string roleName,
        string ssoRegion, string region, CancellationToken ct)
    {
        var url = $"https://portal.sso.{ssoRegion}.amazonaws.com/federation/credentials"
                  + $"?role_name={Uri.EscapeDataString(roleName)}"
                  + $"&account_id={Uri.EscapeDataString(accountId)}";
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        using var req = new HttpRequestMessage(HttpMethod.Get, url);
        req.Headers.TryAddWithoutValidation("x-amz-sso_bearer_token", accessToken);
        req.Headers.Accept.Add(new System.Net.Http.Headers.MediaTypeWithQualityHeaderValue("application/json"));
        using var resp = await http.SendAsync(req, ct).ConfigureAwait(false);
        var body = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
        if (!resp.IsSuccessStatusCode)
        {
            throw new ResolveException($"HTTP {(int)resp.StatusCode}: {body}");
        }

        using var doc = JsonDocument.Parse(body);
        if (!doc.RootElement.TryGetProperty("roleCredentials", out var rc))
            throw new ResolveException("unexpected response shape: missing roleCredentials");
        var akid = rc.GetProperty("accessKeyId").GetString()!;
        var secret = rc.GetProperty("secretAccessKey").GetString()!;
        var session = rc.GetProperty("sessionToken").GetString()!;
        var expirationMs = rc.GetProperty("expiration").GetInt64();
        var expiration = DateTimeOffset.FromUnixTimeMilliseconds(expirationMs);
        return new ResolvedAwsCredentials(akid, secret, session, region, expiration);
    }
}
