using System.Net.Http;
using System.Reflection;
using System.Text.Json.Nodes;
using System.Windows;
using Bromure.Platform;

namespace Bromure.AC;

/// <summary>
/// HTTP/JSON-based auto-update checker. Audit 08 §1.x.
/// Replaces the Sparkle/WinSparkle dependency with a pure-managed
/// "GET a manifest JSON, compare semver, prompt the user" flow.
/// The manifest URL is configurable via the appcast parameter so the
/// release process can swap it without recompiling. Manifest shape:
///
/// <code>
///   { "version": "1.2.3", "downloadUrl": "https://bromure.io/dl/..." }
/// </code>
///
/// Best-effort: silent on network failure, parse error, or
/// missing fields. The user can always trigger an interactive
/// check via Help → Check for Updates.
/// </summary>
public sealed class HttpAppUpdater : IAppUpdater
{
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(10) };
    private string? _appcastUrl;
    private string _appVersion = "0.0.0";

    public void Initialize(string appcastUrl, string companyName, string appName, string appVersion)
    {
        _appcastUrl = appcastUrl;
        _appVersion = appVersion;
    }

    public void CheckSilently() => _ = CheckAsync(interactive: false);
    public void CheckInteractively() => _ = CheckAsync(interactive: true);
    public void Shutdown() => _http.Dispose();

    private async Task CheckAsync(bool interactive)
    {
        if (string.IsNullOrEmpty(_appcastUrl)) return;
        JsonObject? manifest;
        try
        {
            var json = await _http.GetStringAsync(_appcastUrl).ConfigureAwait(false);
            manifest = JsonNode.Parse(json) as JsonObject;
        }
        catch
        {
            // Network / DNS / TLS failure — silent in silent mode,
            // friendly toast in interactive.
            if (interactive)
            {
                await Application.Current.Dispatcher.InvokeAsync(() =>
                    MessageBox.Show(
                        "Could not reach the update server. Try again later.",
                        "Check for Updates",
                        MessageBoxButton.OK, MessageBoxImage.Information));
            }
            return;
        }
        var latest = manifest?["version"]?.GetValue<string>();
        var downloadUrl = manifest?["downloadUrl"]?.GetValue<string>();
        if (string.IsNullOrEmpty(latest)) return;
        if (SemverCompare.Compare(latest, _appVersion) <= 0)
        {
            if (interactive)
            {
                await Application.Current.Dispatcher.InvokeAsync(() =>
                    MessageBox.Show(
                        $"You're on the latest version ({_appVersion}).",
                        "Check for Updates",
                        MessageBoxButton.OK, MessageBoxImage.Information));
            }
            return;
        }
        await Application.Current.Dispatcher.InvokeAsync(() =>
        {
            var choice = MessageBox.Show(
                $"Bromure AC {latest} is available.\n\n" +
                $"You're running {_appVersion}. Open the download page in your browser?",
                "Update available",
                MessageBoxButton.YesNo, MessageBoxImage.Information,
                MessageBoxResult.Yes);
            if (choice == MessageBoxResult.Yes && !string.IsNullOrEmpty(downloadUrl))
            {
                try
                {
                    System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
                    {
                        FileName = downloadUrl,
                        UseShellExecute = true,
                    });
                }
                catch { /* best-effort */ }
            }
        });
    }

}
