using System.Collections.ObjectModel;

namespace Bromure.AC.Core.Model;

/// <summary>
/// Direct port of <c>BromureAC.swift:1815-1868</c> +
/// <c>restartLabel(for:)</c>: compute the per-category diff between
/// the old + new profile shapes, returning the display labels of
/// changes that need a VM restart to take effect. Used by the editor
/// save flow to surface a non-blocking "Restart now / Later" prompt
/// when the user edits a profile whose session is already running.
/// </summary>
public static class RestartRequiringChanges
{
    public enum Kind
    {
        Memory,
        Networking,
        SharedFolders,
        PrimaryTool,
        AdditionalTools,
        SshPublicKey,
        HttpsGitCredentials,
        ManualTokens,
        ImportedSshKeys,
        EnvironmentVariables,
        TraceLevel,
        Kubernetes,
        DigitalOcean,
        AwsCredentials,
        ContainerRegistries,
        ApprovalGates,
        KeyboardSettings,
        TerminalAppearance,
        GitIdentity,
    }

    /// <summary>
    /// Compute the categories that changed between <paramref name="old"/>
    /// and <paramref name="@new"/>. Each category is a single
    /// "needs-restart" label the user will see in the prompt. Order
    /// is stable so list rendering doesn't shuffle on every diff.
    /// </summary>
    public static IReadOnlyList<Kind> Compute(Profile old, Profile @new)
    {
        var output = new List<Kind>();
        if (old.MemoryGB != @new.MemoryGB) output.Add(Kind.Memory);
        if (old.NetworkMode != @new.NetworkMode
            || old.BridgedInterfaceID != @new.BridgedInterfaceID)
        {
            output.Add(Kind.Networking);
        }
        if (!SequenceEquals(old.FolderPaths, @new.FolderPaths)) output.Add(Kind.SharedFolders);
        if (old.Tool != @new.Tool
            || old.AuthMode != @new.AuthMode
            || old.ApiKey != @new.ApiKey)
        {
            output.Add(Kind.PrimaryTool);
        }
        if (!ToolSpecsEqual(old.AdditionalTools, @new.AdditionalTools)) output.Add(Kind.AdditionalTools);
        if (old.SshPublicKey != @new.SshPublicKey) output.Add(Kind.SshPublicKey);
        if (!GitCredsEqual(old.GitHttpsCredentials, @new.GitHttpsCredentials))
            output.Add(Kind.HttpsGitCredentials);
        if (!ManualTokensEqual(old.ManualTokens, @new.ManualTokens)) output.Add(Kind.ManualTokens);
        if (!ImportedSshKeysEqual(old.ImportedSshKeys, @new.ImportedSshKeys))
            output.Add(Kind.ImportedSshKeys);
        if (!EnvVarsEqual(old.EnvironmentVariables, @new.EnvironmentVariables))
            output.Add(Kind.EnvironmentVariables);
        if (old.TraceLevel != @new.TraceLevel) output.Add(Kind.TraceLevel);
        if (!KubeconfigsEqual(old.Kubeconfigs, @new.Kubeconfigs)) output.Add(Kind.Kubernetes);
        if (old.DigitalOceanToken != @new.DigitalOceanToken) output.Add(Kind.DigitalOcean);
        if (!AwsEqual(old.Aws, @new.Aws)) output.Add(Kind.AwsCredentials);
        if (!DockerRegsEqual(old.DockerRegistries, @new.DockerRegistries))
            output.Add(Kind.ContainerRegistries);
        if (old.ApiKeyRequiresApproval != @new.ApiKeyRequiresApproval
            || old.DigitalOceanRequiresApproval != @new.DigitalOceanRequiresApproval
            || old.SshKeyRequiresApproval != @new.SshKeyRequiresApproval)
        {
            output.Add(Kind.ApprovalGates);
        }
        if (old.CursorShape != @new.CursorShape
            || old.KeyboardLayoutOverride != @new.KeyboardLayoutOverride
            || old.KeyRepeatDelayMs != @new.KeyRepeatDelayMs
            || old.KeyRepeatRateHz != @new.KeyRepeatRateHz)
        {
            output.Add(Kind.KeyboardSettings);
        }
        if (old.UseTerminalAppDefaults != @new.UseTerminalAppDefaults
            || old.CustomFontFamily != @new.CustomFontFamily
            || old.CustomFontSize != @new.CustomFontSize
            || old.CustomBackgroundHex != @new.CustomBackgroundHex
            || old.CustomForegroundHex != @new.CustomForegroundHex)
        {
            output.Add(Kind.TerminalAppearance);
        }
        if (old.GitUserName != @new.GitUserName
            || old.GitUserEmail != @new.GitUserEmail)
        {
            output.Add(Kind.GitIdentity);
        }
        return output;
    }

    /// <summary>
    /// Atomic "save profile + emit restart prompt if needed" — the
    /// helper the ViewModel.Persist path delegates to so the policy
    /// (when to fire the prompt) lives in Core and is unit-testable
    /// without referencing WPF.
    ///
    /// <para>Read the prior on-disk state, save the new state, then —
    /// if there's a live session for this profile AND the diff is
    /// non-empty — invoke <paramref name="onRestartRequired"/>. The
    /// callback shape mirrors ProfilesViewModel's hook so the WPF
    /// layer is a pure UI seam.</para>
    /// </summary>
    public static IReadOnlyList<Kind> SaveAndDiffRunning(
        Profile profile,
        ProfileStore store,
        Func<Guid, bool> isProfileRunning,
        Action<Profile, IReadOnlyList<Kind>> onRestartRequired)
    {
        var snapshot = store.Load(profile.Id);
        store.Save(profile);
        if (snapshot is null) return Array.Empty<Kind>();
        if (!isProfileRunning(profile.Id)) return Array.Empty<Kind>();
        var diff = Compute(snapshot, profile);
        if (diff.Count > 0)
        {
            try { onRestartRequired(profile, diff); }
            catch { /* prompt-callback failure must not corrupt the save */ }
        }
        return diff;
    }

    public static string DisplayLabel(Kind kind) => kind switch
    {
        Kind.Memory => "VM memory",
        Kind.Networking => "Network mode",
        Kind.SharedFolders => "Shared folders",
        Kind.PrimaryTool => "Primary tool / auth mode / API key",
        Kind.AdditionalTools => "Additional tools",
        Kind.SshPublicKey => "SSH public key",
        Kind.HttpsGitCredentials => "HTTPS git credentials",
        Kind.ManualTokens => "Manual token rules",
        Kind.ImportedSshKeys => "Imported SSH keys",
        Kind.EnvironmentVariables => "Environment variables",
        Kind.TraceLevel => "Trace level",
        Kind.Kubernetes => "Kubernetes contexts",
        Kind.DigitalOcean => "DigitalOcean token",
        Kind.AwsCredentials => "AWS credentials",
        Kind.ContainerRegistries => "Container registry credentials",
        Kind.ApprovalGates => "Credential approval gates",
        Kind.KeyboardSettings => "Cursor / keyboard settings",
        Kind.TerminalAppearance => "Terminal font and colors",
        Kind.GitIdentity => "Git author identity",
        _ => kind.ToString(),
    };

    // -- Equality helpers (collections compare by Id + relevant fields,
    // matching what macOS's Equatable conformance does on each shape) --

    private static bool SequenceEquals<T>(ObservableCollection<T> a, ObservableCollection<T> b)
    {
        if (a.Count != b.Count) return false;
        for (var i = 0; i < a.Count; i++)
        {
            if (!Equals(a[i], b[i])) return false;
        }
        return true;
    }

    private static bool ToolSpecsEqual(ObservableCollection<ToolSpec> a, ObservableCollection<ToolSpec> b)
    {
        if (a.Count != b.Count) return false;
        for (var i = 0; i < a.Count; i++)
        {
            if (a[i].Tool != b[i].Tool
                || a[i].AuthMode != b[i].AuthMode
                || a[i].ApiKey != b[i].ApiKey
                || a[i].RequireApproval != b[i].RequireApproval)
            {
                return false;
            }
        }
        return true;
    }

    private static bool GitCredsEqual(ObservableCollection<GitHttpsCredential> a, ObservableCollection<GitHttpsCredential> b)
    {
        if (a.Count != b.Count) return false;
        for (var i = 0; i < a.Count; i++)
        {
            if (a[i].Host != b[i].Host
                || a[i].Username != b[i].Username
                || a[i].Token != b[i].Token
                || a[i].RequireApproval != b[i].RequireApproval) return false;
        }
        return true;
    }

    private static bool ManualTokensEqual(ObservableCollection<ManualToken> a, ObservableCollection<ManualToken> b)
    {
        if (a.Count != b.Count) return false;
        for (var i = 0; i < a.Count; i++)
        {
            if (a[i].Name != b[i].Name
                || a[i].Value != b[i].Value
                || a[i].EnvVarName != b[i].EnvVarName
                || a[i].HostFilter != b[i].HostFilter
                || a[i].RequireApproval != b[i].RequireApproval) return false;
        }
        return true;
    }

    private static bool ImportedSshKeysEqual(ObservableCollection<ImportedSshKey> a, ObservableCollection<ImportedSshKey> b)
    {
        if (a.Count != b.Count) return false;
        for (var i = 0; i < a.Count; i++)
        {
            if (a[i].Label != b[i].Label
                || a[i].PrivateKeyPem != b[i].PrivateKeyPem
                || a[i].Comment != b[i].Comment
                || a[i].RequireApproval != b[i].RequireApproval) return false;
        }
        return true;
    }

    private static bool EnvVarsEqual(ObservableCollection<EnvironmentVariable> a, ObservableCollection<EnvironmentVariable> b)
    {
        if (a.Count != b.Count) return false;
        for (var i = 0; i < a.Count; i++)
        {
            if (a[i].Name != b[i].Name
                || a[i].Value != b[i].Value
                || a[i].IsSecret != b[i].IsSecret) return false;
        }
        return true;
    }

    private static bool KubeconfigsEqual(ObservableCollection<KubeconfigEntry> a, ObservableCollection<KubeconfigEntry> b)
    {
        if (a.Count != b.Count) return false;
        for (var i = 0; i < a.Count; i++)
        {
            // Hash on the JSON-serialised form so deep struct equality
            // doesn't require maintaining a custom comparer per field.
            var aj = System.Text.Json.JsonSerializer.Serialize(a[i]);
            var bj = System.Text.Json.JsonSerializer.Serialize(b[i]);
            if (aj != bj) return false;
        }
        return true;
    }

    private static bool DockerRegsEqual(ObservableCollection<DockerRegistryCredential> a, ObservableCollection<DockerRegistryCredential> b)
    {
        if (a.Count != b.Count) return false;
        for (var i = 0; i < a.Count; i++)
        {
            if (a[i].Host != b[i].Host
                || a[i].Username != b[i].Username
                || a[i].Password != b[i].Password
                || a[i].RequireApproval != b[i].RequireApproval) return false;
        }
        return true;
    }

    private static bool AwsEqual(AwsCredentialsConfig a, AwsCredentialsConfig b)
        => a.AuthMode == b.AuthMode
           && a.SsoProfile == b.SsoProfile
           && a.AccessKeyId == b.AccessKeyId
           && a.SecretAccessKey == b.SecretAccessKey
           && a.SessionToken == b.SessionToken
           && a.Region == b.Region
           && a.RequireApproval == b.RequireApproval;
}
