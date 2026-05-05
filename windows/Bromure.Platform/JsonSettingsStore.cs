using System.Collections.Concurrent;
using System.Text.Json;

namespace Bromure.Platform;

/// <summary>
/// JSON-backed <see cref="ISettingsStore"/>. Atomic writes via temp+rename.
/// Loaded at construction; mutations are buffered in memory until
/// <see cref="Save"/>.
/// </summary>
public sealed class JsonSettingsStore : ISettingsStore
{
    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    private readonly string _path;
    private readonly ConcurrentDictionary<string, JsonElement> _store;
    private readonly object _ioLock = new();

    public JsonSettingsStore(string path)
    {
        _path = path;
        _store = Load(path);
    }

    public T? Get<T>(string key)
    {
        if (!_store.TryGetValue(key, out var element)) return default;
        return JsonSerializer.Deserialize<T>(element, Options);
    }

    public bool TryGet<T>(string key, out T? value)
    {
        if (_store.TryGetValue(key, out var element))
        {
            value = JsonSerializer.Deserialize<T>(element, Options);
            return true;
        }
        value = default;
        return false;
    }

    public void Set<T>(string key, T value)
    {
        var element = JsonSerializer.SerializeToElement(value, Options);
        _store[key] = element;
    }

    public void Delete(string key) => _store.TryRemove(key, out _);

    public IReadOnlyCollection<string> Keys() => _store.Keys.ToArray();

    public void Save()
    {
        lock (_ioLock)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            var snapshot = _store.ToDictionary(p => p.Key, p => p.Value);
            var tmp = _path + ".tmp";
            using (var fs = File.Create(tmp))
            {
                JsonSerializer.Serialize(fs, snapshot, Options);
            }
            File.Move(tmp, _path, overwrite: true);
        }
    }

    private static ConcurrentDictionary<string, JsonElement> Load(string path)
    {
        if (!File.Exists(path))
        {
            return new ConcurrentDictionary<string, JsonElement>();
        }
        try
        {
            using var fs = File.OpenRead(path);
            var dict = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(fs, Options);
            return dict is null
                ? new ConcurrentDictionary<string, JsonElement>()
                : new ConcurrentDictionary<string, JsonElement>(dict);
        }
        catch (JsonException)
        {
            // Corrupt settings file: rename it aside and start fresh
            // rather than crashing the app at startup.
            try { File.Move(path, path + ".corrupt-" + DateTime.UtcNow.Ticks, overwrite: false); }
            catch { /* best-effort */ }
            return new ConcurrentDictionary<string, JsonElement>();
        }
    }
}
