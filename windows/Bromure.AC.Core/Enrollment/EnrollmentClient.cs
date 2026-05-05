using System.Net.Http;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Bromure.AC.Core.Enrollment;

/// <summary>
/// Direct port of the network half of <c>Sources/AgentCoding/Enrollment.swift</c>.
/// Exchanges a six-word enrollment code for an install identity +
/// bearer token + leaf cert at the bromure.io control plane.
/// </summary>
public sealed class EnrollmentClient
{
    public static readonly Uri DefaultServerUrl = new("https://app.bromure.io");
    public static readonly Uri DefaultAnalyticsUrl = new("https://analytics.bromure.io/v1/ac-events");

    private readonly HttpClient _http;

    public EnrollmentClient(HttpClient? http = null)
    {
        _http = http ?? new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
    }

    public async Task<BromureInstall> EnrollAsync(
        string code,
        string deviceName,
        Uri? serverUrl = null,
        CancellationToken ct = default)
    {
        var server = serverUrl ?? DefaultServerUrl;
        var endpoint = new Uri(server, "/api/agentic-coding/enroll");
        var trimmed = code.Trim();
        if (string.IsNullOrEmpty(trimmed)) throw new ArgumentException("Code is empty.", nameof(code));

        using var req = new HttpRequestMessage(HttpMethod.Post, endpoint)
        {
            Content = JsonContent.Create(new
            {
                code = trimmed,
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

        return new BromureInstall(
            InstallId: parsed.InstallId,
            OrgSlug: parsed.OrgSlug,
            UserId: parsed.UserId,
            UserEmail: parsed.UserEmail,
            ServerUrl: server,
            EnrolledAt: DateTimeOffset.UtcNow,
            DeviceName: deviceName);
    }

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    private static string Truncate(string s, int max)
        => s.Length <= max ? s : s[..max] + "…";

    public sealed class EnrollResponse
    {
        [JsonPropertyName("installId")] public string InstallId { get; set; } = "";
        [JsonPropertyName("orgSlug")] public string OrgSlug { get; set; } = "";
        [JsonPropertyName("userId")] public string UserId { get; set; } = "";
        [JsonPropertyName("userEmail")] public string UserEmail { get; set; } = "";
        [JsonPropertyName("installToken")] public string InstallToken { get; set; } = "";
        [JsonPropertyName("app")] public string App { get; set; } = "";
        [JsonPropertyName("leafCertPem")] public string? LeafCertPem { get; set; }
        [JsonPropertyName("caCertPem")] public string? CaCertPem { get; set; }
        [JsonPropertyName("leafSerial")] public string? LeafSerial { get; set; }
    }
}

public sealed class EnrollmentException : Exception
{
    public EnrollmentException(string message) : base(message) { }
}
