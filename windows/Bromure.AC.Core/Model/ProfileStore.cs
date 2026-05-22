// macos-source: Sources/AgentCoding/Profile.swift @ 5feff2fd78b5
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

    /// <summary>Enumerate every profile.json in the store, newest first.
    /// Excludes the special template file (<c>_template.json</c>).</summary>
    public IReadOnlyList<Profile> LoadAll()
    {
        if (!Directory.Exists(_root)) return Array.Empty<Profile>();
        var output = new List<Profile>();
        foreach (var path in Directory.EnumerateFiles(_root, "*.json"))
        {
            if (IsTemplatePath(path)) continue;
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
    /// <c>FileHandle</c>; Windows gets the same crash-safety here.
    /// A Profile with <see cref="Profile.Id"/> = <see cref="Guid.Empty"/>
    /// is the template; it routes to <c>_template.json</c> instead of
    /// a regular profile file.</summary>
    public void Save(Profile profile)
    {
        if (profile.Id == Guid.Empty)
        {
            SaveTemplate(profile);
            return;
        }
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

    /// <summary>
    /// Bump <see cref="Profile.LastUsedAt"/> to "now" and persist —
    /// called by SessionsViewModel each time a session for this profile
    /// starts. Mirrors the macOS <c>ProfileStore.touch</c> helper.
    /// Silently no-ops when the profile isn't on disk yet (template-
    /// only profiles, etc.) so callers don't have to gate.
    /// </summary>
    public void Touch(Guid profileId)
    {
        var profile = Load(profileId);
        if (profile is null) return;
        profile.LastUsedAt = DateTimeOffset.UtcNow;
        Save(profile);
    }

    /// <summary>
    /// Stamp the base-image version this profile's disk was cloned
    /// from. Called by the engine the first time it materialises a
    /// per-profile child VHDX, and on user-confirmed "Reset and launch"
    /// after the image-versioning alert.
    /// </summary>
    public void StampBaseImageVersion(Guid profileId, string version)
    {
        var profile = Load(profileId);
        if (profile is null) return;
        profile.BaseImageVersionAtClone = version;
        Save(profile);
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

    /// <summary>
    /// macOS port has a "template profile" — the defaults new profiles
    /// inherit from when the user clicks "+". Stored alongside the
    /// regular profiles but at a fixed filename so it's distinguishable.
    /// Created on first access if the file doesn't exist.
    /// </summary>
    private string TemplatePath => Path.Combine(_root, "_template.json");

    public Profile LoadOrCreateTemplate()
    {
        if (File.Exists(TemplatePath))
        {
            try
            {
                using var fs = File.OpenRead(TemplatePath);
                var existing = JsonSerializer.Deserialize<Profile>(fs, JsonOptions);
                if (existing is not null) return existing;
            }
            catch (JsonException) { }
            catch (IOException) { }
        }
        var seed = new Profile
        {
            Id = Guid.Empty,
            Name = "Template",
            Color = ProfileColor.Blue,
            Tool = AgentTool.Claude,
            AuthMode = AuthMode.Token,
        };
        SaveTemplate(seed);
        return seed;
    }

    public void SaveTemplate(Profile template)
    {
        Directory.CreateDirectory(_root);
        var tmp = TemplatePath + ".tmp";
        using (var fs = File.Create(tmp))
        {
            JsonSerializer.Serialize(fs, template, JsonOptions);
        }
        File.Move(tmp, TemplatePath, overwrite: true);
    }

    /// <summary>
    /// Build a fresh Profile seeded from the template — used by
    /// <c>SessionsViewModel.NewProfile</c> so every new entry starts
    /// from the user's preferences.
    /// </summary>
    public Profile NewFromTemplate()
    {
        var t = LoadOrCreateTemplate();
        return new Profile
        {
            Id = Guid.NewGuid(),
            Name = "New profile",
            Color = t.Color,
            Tool = t.Tool,
            AuthMode = t.AuthMode,
            ApiKey = t.ApiKey,
            ApiKeyRequiresApproval = t.ApiKeyRequiresApproval,
            AdditionalTools = new System.Collections.ObjectModel.ObservableCollection<ToolSpec>(t.AdditionalTools),
            FolderPaths = new System.Collections.ObjectModel.ObservableCollection<string>(t.FolderPaths),
            EnvironmentVariables = new System.Collections.ObjectModel.ObservableCollection<EnvironmentVariable>(t.EnvironmentVariables),
            TraceLevel = t.TraceLevel,
            PrivateMode = t.PrivateMode,
        };
    }

    /// <summary>True iff <paramref name="path"/> in the profiles dir
    /// is the template file (not a regular profile). Used by
    /// <see cref="LoadAll"/> on the Windows port to keep the template
    /// out of the picker.</summary>
    public static bool IsTemplatePath(string path)
        => Path.GetFileName(path).Equals("_template.json", StringComparison.Ordinal);
}
