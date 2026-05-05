using System.Text.Json.Serialization;

namespace Bromure.AC.Mitm.Trace;

/// <summary>
/// Direct port of <c>Sources/AgentCoding/Mitm/TraceRecord.swift</c>.
/// One MITM exchange — what the proxy produces and <see cref="TraceStore"/>
/// records. Only carries previews of secret values; real bytes never enter
/// this struct.
/// </summary>
public sealed record TraceRecord(
    Guid Id,
    Guid SessionId,
    Guid ProfileId,
    DateTimeOffset Timestamp,
    string Host,
    int Port,
    string Method,
    string Path,
    int StatusCode,
    int RequestBytes,
    int ResponseBytes,
    double LatencyMs,
    IReadOnlyList<SwapEntry> Swaps,
    IReadOnlyList<LeakEntry> Leaks,
    bool BodyStored,
    bool IsConversation = false);

public sealed record SwapEntry(string Header, string FakePreview, string RealPreview);

public sealed record LeakEntry(string Header, string ValuePreview, LeakSuspicion Suspicion);

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum LeakSuspicion
{
    /// Token has a recognised secret prefix (sk-ant-, ghp_, etc.)
    /// but isn't one we minted.
    KnownPrefix,
    /// Long opaque value in an auth header that doesn't match a
    /// well-known fake-prefix shape but smells like a credential.
    OpaqueToken,
}

[JsonConverter(typeof(JsonStringEnumConverter))]
public enum TraceLevel
{
    Off,
    Activity,
    AiDetails,
    All,
}

public static class TraceLevelExtensions
{
    public static readonly IReadOnlyList<string> AiHosts = new[]
    {
        "anthropic.com",
        "openai.com",
        "googleapis.com",
        "google.com",
        "cohere.com",
        "mistral.ai",
        "perplexity.ai",
        "x.ai",
        "groq.com",
        "replicate.com",
        "huggingface.co",
    };

    public static bool CapturesBodyForHost(this TraceLevel level, string host)
    {
        switch (level)
        {
            case TraceLevel.Off:
            case TraceLevel.Activity: return false;
            case TraceLevel.All: return true;
            case TraceLevel.AiDetails:
                var lower = host.ToLowerInvariant();
                return AiHosts.Any(h => lower.Contains(h));
            default: return false;
        }
    }

    public static bool RecordsActivity(this TraceLevel level) => level != TraceLevel.Off;
}
