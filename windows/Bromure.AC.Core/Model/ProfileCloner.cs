using System.Text.Json;

namespace Bromure.AC.Core.Model;

/// <summary>
/// Pure clone helper for the "Duplicate profile" menu (audit 08 §2.4).
/// Lives in Bromure.AC.Core so tests can reference it without
/// dragging in the WPF exe. JSON round-trip is the simplest way to
/// avoid sharing ObservableCollection refs between the original and
/// the duplicate — Profile's collections all participate in JSON
/// serialization, so the deserialized clone owns fresh instances.
/// </summary>
public static class ProfileCloner
{
    /// <summary>Deep-clone <paramref name="source"/> for the
    /// Duplicate-profile menu action. Regenerates Id, appends
    /// " (copy)" to the name, clears the per-instance lifecycle
    /// fields, and drops the SSH key (the duplicate gets a fresh
    /// keypair on its first launch).</summary>
    public static Profile Clone(Profile source)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(source);
        var clone = JsonSerializer.Deserialize<Profile>(bytes)
            ?? throw new InvalidOperationException("Profile failed to round-trip via JSON");
        clone.Id = Guid.NewGuid();
        clone.Name = source.Name + " (copy)";
        clone.CreatedAt = DateTimeOffset.UtcNow;
        clone.LastUsedAt = null;
        clone.BaseImageVersionAtClone = null;
        clone.SshPublicKey = null;
        return clone;
    }
}
