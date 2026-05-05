using System.Collections.ObjectModel;
using System.IO;
using System.Windows;
using Microsoft.Win32;
using Bromure.AC.Common;
using Bromure.AC.Core.Model;
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
    public SimpleRelayCommand<KubeconfigEntry> RemoveKubeCommand { get; }
    public SimpleRelayCommand<ImportedSshKey> RemoveSshCommand { get; }
    public SimpleRelayCommand<EnvironmentVariable> RemoveEnvCommand { get; }
    public SimpleRelayCommand<string> RemoveFolderCommand { get; }

    public ProfilesViewModel(ProfileStore store)
    {
        _store = store;
        RemoveGitCommand    = new SimpleRelayCommand<GitHttpsCredential>(g => RemoveAndSave(p => p.GitHttpsCredentials.Remove(g)));
        RemoveManualCommand = new SimpleRelayCommand<ManualToken>(m => RemoveAndSave(p => p.ManualTokens.Remove(m)));
        RemoveDockerCommand = new SimpleRelayCommand<DockerRegistryCredential>(d => RemoveAndSave(p => p.DockerRegistries.Remove(d)));
        RemoveKubeCommand   = new SimpleRelayCommand<KubeconfigEntry>(k => RemoveAndSave(p => p.Kubeconfigs.Remove(k)));
        RemoveSshCommand    = new SimpleRelayCommand<ImportedSshKey>(s => RemoveAndSave(p => p.ImportedSshKeys.Remove(s)));
        RemoveEnvCommand    = new SimpleRelayCommand<EnvironmentVariable>(e => RemoveAndSave(p => p.EnvironmentVariables.Remove(e)));
        RemoveFolderCommand = new SimpleRelayCommand<string>(f => RemoveAndSave(p => p.FolderPaths.Remove(f)));
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
        _store.Save(p);
        Profiles.Add(p);
        Selected = p;
    }

    [RelayCommand]
    private void DeleteSelected()
    {
        if (Selected is null) return;
        if (Profiles.Count <= 1) return;
        _store.Delete(Selected.Id);
        Profiles.Remove(Selected);
        Selected = Profiles.FirstOrDefault();
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
        Selected.Kubeconfigs.Add(new KubeconfigEntry
        {
            Name = "new-context",
            ServerUrl = "https://kubernetes.example.com",
            Auth = new KubeBearerToken { Token = "" },
        });
        _store.Save(Selected);
        OnPropertyChanged(nameof(Selected));
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
    /// </summary>
    public void Persist()
    {
        if (Selected is null) return;
        _store.Save(Selected);
    }
}
