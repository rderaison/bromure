namespace Bromure.Platform;

/// <summary>
/// Replaces scattered <c>UserDefaults</c> calls with a typed JSON store
/// at <c>%LOCALAPPDATA%\Bromure\AC\settings.json</c>.
/// </summary>
public interface ISettingsStore
{
    T? Get<T>(string key);
    bool TryGet<T>(string key, out T? value);
    void Set<T>(string key, T value);
    void Delete(string key);
    void Save();
    IReadOnlyCollection<string> Keys();
}
