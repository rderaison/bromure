using System.Text.Json.Nodes;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;

namespace Bromure.Cloud;

/// <summary>
/// Direct port of <c>BACEventEmitter</c> from
/// <c>Sources/AgentCoding/CloudEvents.swift</c>.
///
/// <para>Caller's view of the cloud telemetry surface — every credential
/// hook + the LLM parser funnels through here. Short-circuits when no
/// install identity is present (not enrolled) or when the profile is in
/// private mode.</para>
/// </summary>
public sealed class CloudEventEmitter
{
    private readonly object _gate = new();
    private CloudUploader? _uploader;
    private readonly HashSet<Guid> _privateProfiles = new();
    private readonly SessionTracker _sessions;
    private readonly Func<bool> _enrolledProbe;
    private readonly ILogger _log;

    public CloudEventEmitter(
        SessionTracker sessions,
        Func<bool> enrolledProbe,
        ILogger? log = null)
    {
        _sessions = sessions;
        _enrolledProbe = enrolledProbe;
        _log = log ?? NullLogger.Instance;
    }

    public void SetUploader(CloudUploader? uploader)
    {
        lock (_gate) _uploader = uploader;
    }

    public void SetPrivateProfiles(IEnumerable<Guid> ids)
    {
        lock (_gate)
        {
            _privateProfiles.Clear();
            foreach (var id in ids) _privateProfiles.Add(id);
        }
    }

    public void Reset()
    {
        lock (_gate) _uploader = null;
    }

    /// <summary>Emit one event for <paramref name="profileId"/>.</summary>
    public Task EmitAsync(Guid profileId, string eventType, JsonObject? eventData = null)
    {
        if (!_enrolledProbe())
        {
            _log.LogDebug("[ac/emit] drop (not enrolled) eventType={Type}", eventType);
            return Task.CompletedTask;
        }
        bool isPrivate;
        CloudUploader? uploader;
        lock (_gate)
        {
            isPrivate = _privateProfiles.Contains(profileId);
            uploader = _uploader;
        }
        if (isPrivate)
        {
            _log.LogDebug("[ac/emit] drop (private profile) eventType={Type}", eventType);
            return Task.CompletedTask;
        }
        if (uploader is null)
        {
            _log.LogDebug("[ac/emit] drop (no uploader) eventType={Type}", eventType);
            return Task.CompletedTask;
        }

        var bump = _sessions.BumpActivity(profileId);
        if (bump.Rolled && bump.PriorSessionId is { } prior)
        {
            // Backdate session.end to the idle-timeout boundary so the
            // server-side session view's duration stays accurate.
            uploader.Enqueue(new CloudEvent(
                SessionId: prior,
                ProfileId: profileId,
                Ts: DateTimeOffset.UtcNow - SessionTracker.IdleTimeout,
                EventType: "session.end",
                EventData: new JsonObject { ["reason"] = "idle_timeout" }));
        }
        if (bump.Rolled)
        {
            uploader.Enqueue(new CloudEvent(
                SessionId: bump.SessionId, ProfileId: profileId,
                Ts: DateTimeOffset.UtcNow, EventType: "session.start",
                EventData: new JsonObject()));
        }
        uploader.Enqueue(new CloudEvent(
            SessionId: bump.SessionId, ProfileId: profileId,
            Ts: DateTimeOffset.UtcNow, EventType: eventType,
            EventData: eventData ?? new JsonObject()));
        return Task.CompletedTask;
    }

    /// <summary>Force-close <paramref name="profileId"/>'s active session.</summary>
    public void CloseSession(Guid profileId, string reason)
    {
        var prior = _sessions.Close(profileId);
        if (prior is null) return;
        CloudUploader? uploader;
        lock (_gate) uploader = _uploader;
        if (uploader is null) return;
        uploader.Enqueue(new CloudEvent(
            SessionId: prior.Value, ProfileId: profileId,
            Ts: DateTimeOffset.UtcNow, EventType: "session.end",
            EventData: new JsonObject { ["reason"] = reason }));
    }

    /// <summary>Best-effort flush of any buffered events.</summary>
    public Task FlushAsync()
    {
        CloudUploader? uploader;
        lock (_gate) uploader = _uploader;
        return uploader?.FlushNowAsync() ?? Task.CompletedTask;
    }
}
