using System.Collections.ObjectModel;
using System.IO;
using System.Windows;
using Microsoft.Win32;
using Bromure.AC.Common;
using Bromure.AC.Core.Imports;
using Bromure.AC.Core.Model;
using Bromure.AC.Core.Ssh;
using Bromure.Platform;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace Bromure.AC.ViewModels;

/// <summary>
/// Real port of <c>Sources/AgentCoding/ProfileViews.swift</c>.
/// Replaces the earlier stub editor with: General, Tool + Auth + API
/// keys, Folders shared into the VM, Git HTTPS, Manual tokens, AWS,
/// Docker registries, Kubeconfigs, Imported SSH keys, Environment
/// variables, Privacy + Tracing.
///
/// Each list section exposes Add* / Remove* commands; deletes hit the
/// in-memory profile then save-on-the-fly via <see cref="ProfileStore"/>.
/// </summary>
public sealed partial class ProfilesViewModel : ObservableObject
{
    private readonly ProfileStore _store;
    private readonly IAppPaths? _paths;
    // Shared default ed25519 keypair seeded into every new profile —
    // implements the macOS "paste-once-into-GitHub" contract (audit
    // 05 §3.1). Null when `_paths` is null (tests / headless flows).
    private readonly DefaultSshKey? _defaultSshKey;
    private readonly Func<Guid, bool>? _isProfileRunning;
    private readonly Action<Profile, IReadOnlyList<RestartRequiringChanges.Kind>>? _onRestartRequired;

    /// <summary>True when the view should hide the profile picker
    /// (left column) and show only the editor for the selected
    /// profile. Set by <c>ProfileEditorWindow</c>; default false for
    /// the main pane that wants the full picker UI.</summary>
    [ObservableProperty] private bool _editorOnly;

    public ObservableCollection<Profile> Profiles { get; } = new();

    [ObservableProperty]
    [NotifyPropertyChangedFor(nameof(HasSelection))]
    private Profile? _selected;

    public bool HasSelection => Selected is not null;

    public IReadOnlyList<AgentTool> ToolOptions { get; } = Enum.GetValues<AgentTool>();
    public IReadOnlyList<AuthMode> AuthModeOptions { get; } = Enum.GetValues<AuthMode>();
    public IReadOnlyList<TraceLevel> TraceLevelOptions { get; } = Enum.GetValues<TraceLevel>();
    public IReadOnlyList<ProfileColor> ColorOptions { get; } = Enum.GetValues<ProfileColor>();
    public IReadOnlyList<AwsAuthMode> AwsAuthModes { get; } = Enum.GetValues<AwsAuthMode>();

    public SimpleRelayCommand<GitHttpsCredential> RemoveGitCommand { get; }
    public SimpleRelayCommand<ManualToken> RemoveManualCommand { get; }
    public SimpleRelayCommand<DockerRegistryCredential> RemoveDockerCommand { get; }
    public SimpleRelayCommand<Bromure.AC.Core.Model.KubeconfigEntry> RemoveKubeCommand { get; }
    public SimpleRelayCommand<ImportedSshKey> RemoveSshCommand { get; }
    public SimpleRelayCommand<EnvironmentVariable> RemoveEnvCommand { get; }
    public SimpleRelayCommand<string> RemoveFolderCommand { get; }
    public SimpleRelayCommand<McpServer> RemoveMcpCommand { get; }

    public IReadOnlyList<McpTransport> McpTransportOptions { get; } = Enum.GetValues<McpTransport>();
    public IReadOnlyList<NetworkMode> NetworkModeOptions { get; } = Enum.GetValues<NetworkMode>();
    public IReadOnlyList<CloseAction> CloseActionOptions { get; } = Enum.GetValues<CloseAction>();
    public IReadOnlyList<CursorShape> CursorShapeOptions { get; } = Enum.GetValues<CursorShape>();

    public ProfilesViewModel(ProfileStore store, IAppPaths? paths = null,
        Func<Guid, bool>? isProfileRunning = null,
        Action<Profile, IReadOnlyList<RestartRequiringChanges.Kind>>? onRestartRequired = null)
    {
        _store = store;
        _paths = paths;
        _defaultSshKey = paths is null ? null : new DefaultSshKey(paths);
        // Pre-mint at construction time so the first AddProfile click
        // doesn't see a noticeable hitch — the keygen takes a few ms.
        _defaultSshKey?.EnsureExists();
        _isProfileRunning = isProfileRunning;
        _onRestartRequired = onRestartRequired;
        RemoveGitCommand    = new SimpleRelayCommand<GitHttpsCredential>(g => RemoveAndSave(p => p.GitHttpsCredentials.Remove(g)));
        RemoveManualCommand = new SimpleRelayCommand<ManualToken>(m => RemoveAndSave(p => p.ManualTokens.Remove(m)));
        RemoveDockerCommand = new SimpleRelayCommand<DockerRegistryCredential>(d => RemoveAndSave(p => p.DockerRegistries.Remove(d)));
        RemoveKubeCommand   = new SimpleRelayCommand<Bromure.AC.Core.Model.KubeconfigEntry>(k => RemoveAndSave(p => p.Kubeconfigs.Remove(k)));
        RemoveSshCommand    = new SimpleRelayCommand<ImportedSshKey>(s => RemoveAndSave(p => p.ImportedSshKeys.Remove(s)));
        RemoveEnvCommand    = new SimpleRelayCommand<EnvironmentVariable>(e => RemoveAndSave(p => p.EnvironmentVariables.Remove(e)));
        RemoveFolderCommand = new SimpleRelayCommand<string>(f => RemoveAndSave(p => p.FolderPaths.Remove(f)));
        RemoveMcpCommand    = new SimpleRelayCommand<McpServer>(m => RemoveAndSave(p => p.McpServers.Remove(m)));
        Reload();
    }

    public void Reload()
    {
        Profiles.Clear();
        foreach (var p in _store.LoadAll().OrderBy(p => p.Name))
        {
            // Forward-compat for profiles saved before the Aws field
            // became non-nullable: if the persisted JSON carried
            // `"aws": null`, materialise an empty config so the
            // editor's AWS tab can two-way bind into it.
            p.Aws ??= new AwsCredentialsConfig();
            // Lazy-mint the SSH keypair for older profiles that
            // predate the auto-gen flow. New profiles get one in
            // AddProfile; this catches the upgrade path. Seeding from
            // the default key preserves the macOS contract that all
            // legacy profiles converge on the shared identity.
            if (_paths is not null && string.IsNullOrEmpty(p.SshPublicKey))
            {
                ProfileSshKey.EnsureExists(_paths, p, defaultKey: _defaultSshKey);
                _store.Save(p);
            }
            Profiles.Add(p);
        }
        if (Profiles.Count == 0)
        {
            var seed = new Profile
            {
                Name = "Default Profile",
                Tool = AgentTool.Claude,
                AuthMode = AuthMode.Subscription,
                Color = ProfileColor.Purple,
                TraceLevel = TraceLevel.Activity,
            };
            _store.Save(seed);
            Profiles.Add(seed);
        }
        Selected = Profiles.FirstOrDefault();
    }

    [RelayCommand]
    private void AddProfile()
    {
        var p = new Profile
        {
            Name = "New profile",
            Tool = AgentTool.Claude,
            AuthMode = AuthMode.Token,
            Color = ProfileColor.Blue,
        };
        // Audit 05 §3.1: seed every new profile from the shared
        // default keypair, not a fresh mint. Matches the macOS
        // contract — user pastes one public key into GitHub and all
        // their profiles authenticate. They can still hit
        // "Regenerate" in the editor to opt into a unique key.
        if (_paths is not null) ProfileSshKey.EnsureExists(_paths, p, defaultKey: _defaultSshKey);
        _store.Save(p);
        Profiles.Add(p);
        Selected = p;
    }

    [RelayCommand]
    private void DeleteSelected()
    {
        if (Selected is null) return;
        if (Profiles.Count <= 1) return;
        // Confirmation alert. macOS matches this on the profile editor —
        // deletion drops disk.vhdx + the SSH key + the profile JSON,
        // all of which the user cares about. A misclick on Delete
        // shouldn't be one click away from data loss.
        var name = Selected.Name;
        var confirm = MessageBox.Show(
            $"Delete profile \"{name}\"?\n\n" +
            "This permanently removes:\n" +
            "  • the profile and its settings\n" +
            "  • the per-profile VHDX (everything you installed in the VM)\n" +
            "  • the auto-generated SSH key for this profile\n\n" +
            "Shared folders are NOT touched. This cannot be undone.",
            "Delete profile",
            MessageBoxButton.OKCancel,
            MessageBoxImage.Warning,
            MessageBoxResult.Cancel);
        if (confirm != MessageBoxResult.OK) return;

        var doomedId = Selected.Id;
        _store.Delete(doomedId);
        Profiles.Remove(Selected);
        if (_paths is not null) ProfileSshKey.Delete(_paths, doomedId);
        Selected = Profiles.FirstOrDefault();
    }

    /// <summary>Cancel — revert any in-memory edits to the currently
    /// selected profile by re-reading from disk. The editor's
    /// two-way bindings see the new instance and snap back. For the
    /// EditorOnly popup window this is the natural "Close without
    /// saving" affordance.</summary>
    [RelayCommand]
    private void Cancel()
    {
        if (Selected is null) return;
        var fresh = _store.Load(Selected.Id);
        if (fresh is null) return;
        var idx = Profiles.IndexOf(Selected);
        if (idx < 0) return;
        Profiles[idx] = fresh;
        Selected = fresh;
    }

    /// <summary>Generate (or re-generate) the profile's ed25519
    /// keypair. Confirms first when a key already exists — rotating
    /// invalidates anything authorised against the old public half
    /// (GitHub deploy keys, ~/.ssh/authorized_keys entries).</summary>
    [RelayCommand]
    private void RegenerateSshKey()
    {
        if (Selected is null || _paths is null) return;
        if (!string.IsNullOrEmpty(Selected.SshPublicKey))
        {
            var ok = MessageBox.Show(
                "Replacing the keypair invalidates anywhere the current public key has been authorised " +
                "(GitHub deploy keys, ~/.ssh/authorized_keys, etc.).\n\nGenerate a new keypair anyway?",
                "Bromure AC", MessageBoxButton.OKCancel, MessageBoxImage.Warning);
            if (ok != MessageBoxResult.OK) return;
        }
        ProfileSshKey.EnsureExists(_paths, Selected, force: true);
        _store.Save(Selected);
        OnPropertyChanged(nameof(Selected));
    }

    [RelayCommand]
    private void CopySshPublicKey()
    {
        if (string.IsNullOrEmpty(Selected?.SshPublicKey)) return;
        try { Clipboard.SetText(Selected.SshPublicKey); }
        catch { /* Clipboard can briefly throw; user can retry. */ }
    }

    /// <summary>Audit 09 §A4 — "Open GitHub keys page" launcher
    /// matching the macOS link button. Opens the URL in the host's
    /// default browser; the user pastes the public key there.</summary>
    [RelayCommand]
    private void OpenGitHubKeysPage()
    {
        OpenUrlInBrowser("https://github.com/settings/keys");
    }

    private static void OpenUrlInBrowser(string url)
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo
            {
                FileName = url,
                UseShellExecute = true,
            });
        }
        catch { /* Best-effort — Windows shell can refuse to dispatch URLs in some sessions. */ }
    }

    /// <summary>Audit 09 §A7 — clear the user's previous accept/decline
    /// decision for Claude OAuth-token swap so the prompt fires again
    /// on the next clean access-token observed for this profile.</summary>
    [RelayCommand]
    private void ResetSubscriptionSwap()
    {
        if (Selected is null) return;
        Selected.SubscriptionTokenSwap = SubscriptionTokenSwapState.Unset;
        _store.Save(Selected);
        OnPropertyChanged(nameof(Selected));
    }

    [RelayCommand]
    private void ResetCodexSwap()
    {
        if (Selected is null) return;
        Selected.CodexTokenSwap = SubscriptionTokenSwapState.Unset;
        _store.Save(Selected);
        OnPropertyChanged(nameof(Selected));
    }

    [RelayCommand]
    private void Save()
    {
        if (Selected is null) return;
        _store.Save(Selected);
    }

    // -- Folder section --

    [RelayCommand]
    private void AddFolder()
    {
        if (Selected is null || Selected.FolderPaths.Count >= 8) return;
        var dlg = new OpenFolderDialog
        {
            Title = "Pick a folder to share into the VM",
        };
        if (dlg.ShowDialog() == true && !string.IsNullOrEmpty(dlg.FolderName))
        {
            if (!Selected.FolderPaths.Contains(dlg.FolderName))
            {
                Selected.FolderPaths.Add(dlg.FolderName);
                _store.Save(Selected);
                OnPropertyChanged(nameof(Selected));  // refresh ItemsControl
            }
        }
    }

    // -- Git HTTPS section --

    [RelayCommand]
    private void AddGit()
    {
        if (Selected is null) return;
        Selected.GitHttpsCredentials.Add(new GitHttpsCredential
        {
            Host = "github.com",
        });
        _store.Save(Selected);
        OnPropertyChanged(nameof(Selected));
    }

    // -- Manual tokens section --

    [RelayCommand]
    private void AddManual()
    {
        if (Selected is null) return;
        Selected.ManualTokens.Add(new ManualToken { Name = "New token" });
        _store.Save(Selected);
        OnPropertyChanged(nameof(Selected));
    }

    // -- Docker registries section --

    [RelayCommand]
    private void AddDocker()
    {
        if (Selected is null) return;
        Selected.DockerRegistries.Add(new DockerRegistryCredential
        {
            Host = "docker.io",
        });
        _store.Save(Selected);
        OnPropertyChanged(nameof(Selected));
    }

    // -- Kubeconfigs section --

    [RelayCommand]
    private void AddKube()
    {
        if (Selected is null) return;
        Selected.Kubeconfigs.Add(new Bromure.AC.Core.Model.KubeconfigEntry
        {
            Name = "new-context",
            ServerUrl = "https://kubernetes.example.com",
            Auth = new KubeBearerToken { Token = "" },
        });
        _store.Save(Selected);
        OnPropertyChanged(nameof(Selected));
    }

    /// <summary>Audit 09 §A4 — import every context from a
    /// kubectl-style kubeconfig YAML. Mirrors macOS profile editor's
    /// "Import kubeconfig…" button. Skips contexts that don't pick a
    /// supported auth mode (bearer/cert/exec).</summary>
    [RelayCommand]
    private void ImportKubeconfig()
    {
        if (Selected is null) return;
        var dlg = new OpenFileDialog
        {
            Title = "Import a kubeconfig",
            Filter = "kubeconfig|config;*.yaml;*.yml;kubeconfig|All files|*.*",
            InitialDirectory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".kube"),
        };
        if (dlg.ShowDialog() != true) return;
        try
        {
            var yaml = File.ReadAllText(dlg.FileName);
            var entries = Bromure.AC.Core.Imports.KubeconfigImport.Parse(yaml);
            if (entries.Count == 0)
            {
                MessageBox.Show("That kubeconfig has no contexts to import.",
                    "Import kubeconfig", MessageBoxButton.OK, MessageBoxImage.Information);
                return;
            }
            // De-dup by (Name, ServerUrl) against existing entries so
            // re-importing the same file doesn't double up.
            var seen = Selected.Kubeconfigs
                .Select(e => (e.Name, e.ServerUrl))
                .ToHashSet();
            var added = 0;
            foreach (var importEntry in entries)
            {
                if (seen.Contains((importEntry.Name, importEntry.ServerUrl))) continue;
                Selected.Kubeconfigs.Add(ToModelEntry(importEntry));
                seen.Add((importEntry.Name, importEntry.ServerUrl));
                added++;
            }
            _store.Save(Selected);
            OnPropertyChanged(nameof(Selected));
            MessageBox.Show(
                added == 0
                    ? "All contexts in that file were already imported."
                    : $"Imported {added} context{(added == 1 ? "" : "s")} from {Path.GetFileName(dlg.FileName)}.",
                "Import kubeconfig", MessageBoxButton.OK, MessageBoxImage.Information);
        }
        catch (Bromure.AC.Core.Imports.KubeconfigImport.ImportException ex)
        {
            MessageBox.Show("Could not parse the kubeconfig: " + ex.Message,
                "Import kubeconfig", MessageBoxButton.OK, MessageBoxImage.Error);
        }
        catch (Exception ex)
        {
            MessageBox.Show("Import failed: " + ex.Message,
                "Import kubeconfig", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private static Bromure.AC.Core.Model.KubeconfigEntry ToModelEntry(
        Bromure.AC.Core.Imports.KubeconfigEntry import)
    {
        KubeAuth auth = import.AuthSpec switch
        {
            Bromure.AC.Core.Imports.KubeconfigEntry.Auth.BearerTokenAuth b
                => new KubeBearerToken { Token = b.Token },
            Bromure.AC.Core.Imports.KubeconfigEntry.Auth.ClientCertAuth c
                => new KubeClientCert { Cert = c.CertPem, Key = c.KeyPem },
            Bromure.AC.Core.Imports.KubeconfigEntry.Auth.ExecPluginAuth e
                => new KubeExecPlugin
                {
                    Command = e.Command,
                    Args = new List<string>(e.Args),
                    RefreshSeconds = e.RefreshSeconds,
                },
            _ => new KubeBearerToken { Token = "" },
        };
        return new Bromure.AC.Core.Model.KubeconfigEntry
        {
            Name = import.Name,
            ServerUrl = import.ServerUrl,
            CaCertPem = import.CaCertPem,
            Namespace = import.Namespace,
            Auth = auth,
        };
    }

    // -- Imported SSH keys section --

    [RelayCommand]
    private void ImportSshKey()
    {
        if (Selected is null) return;
        var dlg = new OpenFileDialog
        {
            Title = "Import an OpenSSH private key",
            Filter = "OpenSSH key|id_*|All files|*.*",
        };
        if (dlg.ShowDialog() != true) return;
        try
        {
            var pem = File.ReadAllText(dlg.FileName);
            Selected.ImportedSshKeys.Add(new ImportedSshKey
            {
                Label = Path.GetFileName(dlg.FileName),
                PrivateKeyPem = pem,
            });
            _store.Save(Selected);
            OnPropertyChanged(nameof(Selected));
        }
        catch (Exception ex)
        {
            MessageBox.Show("Couldn't read key: " + ex.Message, "Bromure AC",
                MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    // -- Environment variables section --

    [RelayCommand]
    private void AddEnv()
    {
        if (Selected is null) return;
        Selected.EnvironmentVariables.Add(new EnvironmentVariable { Name = "NEW_VAR" });
        _store.Save(Selected);
        OnPropertyChanged(nameof(Selected));
    }

    // -- MCP servers section --
    // Audit 09 #1 (HIGH): macOS Profile.swift has a full editor pane
    // for MCP servers, Windows had model + builder + OAuth broker
    // ported but no UI surface to add / enable / authorize them.
    // The shapes below get a fresh "stdio echo" template + the user
    // edits in-place; the McpFakeMint + McpConfigBuilder code paths
    // pick the entries up at session boot.

    // -- AWS SSO discovery --
    // Audit 09 #6 + 12.5: AwsConfigParser already reads
    // ~/.aws/config; without a UI surface the user has to type the
    // SSO profile name from memory. This command shows what's there
    // + lets the user pick.

    [RelayCommand]
    private void DiscoverAwsSso()
    {
        if (Selected is null) return;
        IReadOnlyList<DiscoveredSsoProfile> found;
        try { found = AwsConfigParser.Discover(); }
        catch (Exception ex)
        {
            MessageBox.Show("Couldn't read ~/.aws/config: " + ex.Message,
                "Bromure AC", MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        if (found.Count == 0)
        {
            MessageBox.Show("No SSO-configured profiles found in ~/.aws/config.\n\n"
                            + "Add an SSO profile via `aws configure sso` first, then try again.",
                "Bromure AC", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        // Concise picker dialog. Building a custom Window for this
        // would be ideal but a numbered MessageBox + InputBox is the
        // smallest WPF surface that works.
        var msg = "Found " + found.Count + " SSO profile" + (found.Count == 1 ? "" : "s") + " in ~/.aws/config:\n\n";
        for (var i = 0; i < found.Count; i++)
        {
            msg += $"  [{i + 1}] {found[i].Name}  ({found[i].SsoStartUrl})\n";
        }
        msg += "\nThe selected profile's name has been copied to your AWS settings. "
               + "Adjust manually if you need a different one.";
        // Pick the first by default. The macOS port has a richer
        // picker UI — for v1 we just auto-fill the topmost.
        Selected.Aws.AuthMode = AwsAuthMode.Sso;
        Selected.Aws.SsoProfile = found[0].Name;
        if (!string.IsNullOrEmpty(found[0].Region))
        {
            Selected.Aws.Region = found[0].Region;
        }
        _store.Save(Selected);
        OnPropertyChanged(nameof(Selected));
        MessageBox.Show(msg, "AWS SSO discovery", MessageBoxButton.OK, MessageBoxImage.Information);
    }

    [RelayCommand]
    private void AddMcpStdio()
    {
        if (Selected is null) return;
        var stdio = new McpServer
        {
            Name = "new-stdio-server",
            Transport = McpTransport.Stdio,
            Command = "node",
            Enabled = true,
        };
        stdio.Arguments.Add("server.js");
        Selected.McpServers.Add(stdio);
        _store.Save(Selected);
        OnPropertyChanged(nameof(Selected));
    }

    [RelayCommand]
    private void AddMcpHttp()
    {
        if (Selected is null) return;
        Selected.McpServers.Add(new McpServer
        {
            Name = "new-http-server",
            Transport = McpTransport.Http,
            Url = "https://example.com/mcp",
            BearerTokenEnvVar = "MCP_BEARER",
            Enabled = true,
        });
        _store.Save(Selected);
        OnPropertyChanged(nameof(Selected));
    }

    private void RemoveAndSave(Action<Profile> mutate)
    {
        if (Selected is null) return;
        mutate(Selected);
        _store.Save(Selected);
        OnPropertyChanged(nameof(Selected));
    }

    /// <summary>
    /// Persist on any field edit. Bound to the editor's "Save" button
    /// but also called on collection changes via RemoveAndSave + the
    /// Add* commands.
    ///
    /// <para>When the profile being edited has a live session, compute
    /// the restart-requiring diff between the prior on-disk state
    /// and the just-saved one. If any boot-baked field changed, fire
    /// <c>_onRestartRequired</c> so the host can prompt the user.</para>
    /// </summary>
    public void Persist()
    {
        if (Selected is null) return;
        if (_isProfileRunning is null || _onRestartRequired is null)
        {
            _store.Save(Selected);
            return;
        }
        // Delegate to the Core helper so the policy (when to fire
        // the prompt) is unit-testable without referencing WPF.
        RestartRequiringChanges.SaveAndDiffRunning(
            Selected, _store, _isProfileRunning, _onRestartRequired);
    }
}
