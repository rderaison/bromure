using System.Text.Json;

namespace Bromure.AC.Core.Model;

/// <summary>
/// Direct port (lite) of <c>ProfileStore</c> from <c>Profile.swift</c>.
/// JSON-on-disk persistence for <see cref="Profile"/> records, one file
/// per profile under <c>%LOCALAPPDATA%\Bromure\AC\profiles\</c>.
/// </summary>
public sealed class ProfileStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull,
    };

    private readonly string _root;

    public ProfileStore(string profilesDirectory)
    {
        _root = profilesDirectory;
        Directory.CreateDirectory(_root);
    }

    /// <summary>Enumerate every profile.json in the store, newest first.</summary>
    public IReadOnlyList<Profile> LoadAll()
    {
        if (!Directory.Exists(_root)) return Array.Empty<Profile>();
        var output = new List<Profile>();
        foreach (var path in Directory.EnumerateFiles(_root, "*.json"))
        {
            try
            {
                using var fs = File.OpenRead(path);
                var p = JsonSerializer.Deserialize<Profile>(fs, JsonOptions);
                if (p is not null) output.Add(p);
            }
            catch (JsonException) { /* skip corrupt file */ }
            catch (IOException) { }
        }
        return output;
    }

    /// <summary>Atomic save — temp file + rename. The macOS source uses
    /// <c>FileHandle</c>; Windows gets the same crash-safety here.</summary>
    public void Save(Profile profile)
    {
        var path = PathFor(profile.Id);
        Directory.CreateDirectory(_root);
        var tmp = path + ".tmp";
        using (var fs = File.Create(tmp))
        {
            JsonSerializer.Serialize(fs, profile, JsonOptions);
        }
        File.Move(tmp, path, overwrite: true);
    }

    public bool Delete(Guid profileId)
    {
        var path = PathFor(profileId);
        if (!File.Exists(path)) return false;
        File.Delete(path);
        return true;
    }

    public Profile? Load(Guid profileId)
    {
        var path = PathFor(profileId);
        if (!File.Exists(path)) return null;
        try
        {
            using var fs = File.OpenRead(path);
            return JsonSerializer.Deserialize<Profile>(fs, JsonOptions);
        }
        catch (JsonException) { return null; }
    }

    private string PathFor(Guid id) => Path.Combine(_root, id.ToString("D") + ".json");
}
