using System.Security.Cryptography;
using System.Text.Json;
using Bromure.Platform;

namespace Bromure.AC.Core.Model;

/// <summary>
/// Direct port of macOS's <c>MACBindings</c> singleton
/// (<c>Profile.swift:1565-1638</c>). Persists a per-profile stable
/// MAC address so the VM gets the same DHCP lease across launches —
/// container networking, port-forward rules, host-side firewall
/// allowlists all depend on this being stable.
///
/// <para>Layout on disk: <c>&lt;AppDataRoot&gt;/profile-macs.json</c> —
/// a flat <c>{ "&lt;profile-id&gt;": "AA-BB-CC-DD-EE-FF", … }</c>
/// map. Reads + writes serialise through the file mutex below.</para>
///
/// <para>MAC generation: locally-administered unicast (first octet
/// has the LAA bit set + multicast bit clear). The remaining 5 bytes
/// come from a cryptographic RNG so two profiles collide only with
/// negligible probability. Matches macOS's LAA-bit policy.</para>
/// </summary>
public sealed class MacAddressBindings
{
    private const string FileName = "profile-macs.json";

    private readonly string _path;
    private readonly object _gate = new();
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = false,
    };

    public MacAddressBindings(IAppPaths paths)
    {
        Directory.CreateDirectory(paths.AppDataRoot);
        _path = Path.Combine(paths.AppDataRoot, FileName);
    }

    /// <summary>
    /// Return the stable MAC for <paramref name="profileId"/>,
    /// generating + persisting one if this is the first call.
    /// Locked so two concurrent sessions for the same profile
    /// (split-screen edit + launch, say) never mint different MACs.
    /// </summary>
    public string GetOrCreate(Guid profileId)
    {
        lock (_gate)
        {
            var map = Load();
            var key = profileId.ToString("D");
            if (map.TryGetValue(key, out var existing) && IsValid(existing))
            {
                return existing;
            }
            var fresh = GenerateLaaMac();
            map[key] = fresh;
            Save(map);
            return fresh;
        }
    }

    /// <summary>Wipe a profile's MAC binding. Called when the user
    /// deletes the profile so a future profile with the same Guid —
    /// unlikely but possible after a manual JSON-restore — doesn't
    /// inherit a stale lease.</summary>
    public void Forget(Guid profileId)
    {
        lock (_gate)
        {
            var map = Load();
            if (map.Remove(profileId.ToString("D"))) Save(map);
        }
    }

    /// <summary>Snapshot of the current map. Used by tests + the
    /// "Network" pane in the editor (when added) to show the user
    /// the MAC their VM is bound to.</summary>
    public IReadOnlyDictionary<string, string> Snapshot()
    {
        lock (_gate) return new Dictionary<string, string>(Load(), StringComparer.OrdinalIgnoreCase);
    }

    private Dictionary<string, string> Load()
    {
        if (!File.Exists(_path)) return new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        try
        {
            using var fs = File.OpenRead(_path);
            var map = JsonSerializer.Deserialize<Dictionary<string, string>>(fs, JsonOptions);
            return map is null
                ? new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
                : new Dictionary<string, string>(map, StringComparer.OrdinalIgnoreCase);
        }
        catch (JsonException) { return new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase); }
        catch (IOException)   { return new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase); }
    }

    private void Save(Dictionary<string, string> map)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        var tmp = _path + ".tmp";
        using (var fs = File.Create(tmp))
        {
            JsonSerializer.Serialize(fs, map, JsonOptions);
        }
        File.Move(tmp, _path, overwrite: true);
    }

    /// <summary>
    /// Generate a locally-administered unicast MAC. RFC 7042: LAA bit
    /// = 0b00000010 on the first octet; clear the multicast bit
    /// (0b00000001) so the upper-layer protocols treat it as unicast.
    /// Format <c>AA-BB-CC-DD-EE-FF</c> matches what HCN's MAC validator
    /// expects.
    /// </summary>
    public static string GenerateLaaMac()
    {
        var bytes = RandomNumberGenerator.GetBytes(6);
        bytes[0] = (byte)((bytes[0] | 0x02) & 0xFE);
        return string.Format(System.Globalization.CultureInfo.InvariantCulture,
            "{0:X2}-{1:X2}-{2:X2}-{3:X2}-{4:X2}-{5:X2}",
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5]);
    }

    /// <summary>True iff <paramref name="s"/> looks like
    /// <c>XX-XX-XX-XX-XX-XX</c> with hex octets. Used as a guard so
    /// a corrupt JSON entry doesn't keep returning bad MACs forever.</summary>
    public static bool IsValid(string s)
    {
        if (s.Length != 17) return false;
        for (var i = 0; i < 17; i++)
        {
            var c = s[i];
            if ((i + 1) % 3 == 0)
            {
                if (c != '-' && c != ':') return false;
            }
            else
            {
                if (!((c >= '0' && c <= '9')
                      || (c >= 'a' && c <= 'f')
                      || (c >= 'A' && c <= 'F'))) return false;
            }
        }
        return true;
    }
}
