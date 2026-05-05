namespace Bromure.Cloud;

/// <summary>
/// Direct port of <c>BACSessionTracker</c> from
/// <c>Sources/AgentCoding/CloudEvents.swift</c>.
///
/// <para>Activity-based session tracker. A "session" rolls over after
/// 20 minutes of no activity for that profile, matching the
/// macOS-agreed model: sessions = "when a user starts using claude
/// and stops using it", not VM lifecycle. One session id per
/// (profile, activity window).</para>
/// </summary>
public sealed class SessionTracker
{
    /// <summary>
    /// Idle threshold for rolling a profile to a new session id.
    /// Picked deliberately long: AC sessions are bursty (claude thinks,
    /// then runs five tool calls in 30 s, then idle 8 min while the
    /// user reads the diff). 20 min keeps that whole arc in one
    /// session; an hour-long lunch break breaks into two.
    /// </summary>
    public static readonly TimeSpan IdleTimeout = TimeSpan.FromMinutes(20);

    private readonly object _gate = new();
    private readonly Dictionary<Guid, Guid> _sessionByProfile = new();
    private readonly Dictionary<Guid, DateTimeOffset> _lastActivity = new();

    public sealed record Bump(Guid SessionId, Guid? PriorSessionId, bool Rolled);

    /// <summary>
    /// Returns the current session id for <paramref name="profileId"/>,
    /// rolling to a fresh one when more than <see cref="IdleTimeout"/>
    /// has passed. Bumps the last-activity timestamp.
    /// </summary>
    public Bump BumpActivity(Guid profileId, DateTimeOffset? now = null)
    {
        var stamp = now ?? DateTimeOffset.UtcNow;
        lock (_gate)
        {
            _sessionByProfile.TryGetValue(profileId, out var prior);
            var hasPrior = _sessionByProfile.ContainsKey(profileId);
            var lastSeen = _lastActivity.TryGetValue(profileId, out var l) ? l : (DateTimeOffset?)null;

            bool timedOut;
            if (lastSeen is null) timedOut = !hasPrior;
            else timedOut = stamp - lastSeen.Value > IdleTimeout;

            if (timedOut || !hasPrior)
            {
                var fresh = Guid.NewGuid();
                _sessionByProfile[profileId] = fresh;
                _lastActivity[profileId] = stamp;
                return new Bump(fresh, hasPrior ? prior : null, Rolled: true);
            }
            _lastActivity[profileId] = stamp;
            return new Bump(prior, null, Rolled: false);
        }
    }

    /// <summary>Force-close the session for <paramref name="profileId"/>.</summary>
    public Guid? Close(Guid profileId)
    {
        lock (_gate)
        {
            if (!_sessionByProfile.TryGetValue(profileId, out var prior)) return null;
            _sessionByProfile.Remove(profileId);
            _lastActivity.Remove(profileId);
            return prior;
        }
    }
}
