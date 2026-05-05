using System.Collections.ObjectModel;
using System.Windows.Threading;
using Bromure.AC.Mitm.Consent;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace Bromure.AC.ViewModels;

/// <summary>
/// Replaces the macOS <c>CredentialApprovalsView.swift</c>. Snapshots
/// every live grant + remembered deny from the consent broker every 2 s.
/// </summary>
public sealed partial class ApprovalsViewModel : ObservableObject
{
    private readonly ConsentBroker _broker;
    private readonly DispatcherTimer _timer;

    public ObservableCollection<ApprovalRowViewModel> Rows { get; } = new();

    public ApprovalsViewModel(ConsentBroker broker)
    {
        _broker = broker;
        _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        _timer.Tick += (_, _) => Refresh();
        _timer.Start();
        Refresh();
    }

    [RelayCommand]
    private void Refresh()
    {
        var snapshot = _broker.Snapshot();
        Rows.Clear();
        foreach (var entry in snapshot)
        {
            Rows.Add(new ApprovalRowViewModel(entry, _broker));
        }
    }

    [RelayCommand]
    private void RevokeEverything()
    {
        _broker.RevokeEverything();
        Refresh();
    }
}

public sealed class ApprovalRowViewModel
{
    private readonly ConsentBroker _broker;

    public ApprovalRowViewModel(ConsentBroker.LiveEntry entry, ConsentBroker broker)
    {
        _broker = broker;
        Entry = entry;
        ProfileShort = entry.ProfileId.ToString("D")[..8];
        KindLabel = entry.Kind == ConsentBroker.DecisionKind.Allow ? "ALLOW" : "DENY";
        ScopeLabel = entry.IsSessionScoped ? "session"
            : (entry.Expiration - DateTimeOffset.UtcNow).TotalMinutes is var min && min > 0
                ? $"{min:F0} min remaining"
                : "expired";
        RevokeCommand = new RelayCommand(() => _broker.Revoke(Entry.ProfileId, Entry.CredentialId));
    }

    public ConsentBroker.LiveEntry Entry { get; }
    public string ProfileShort { get; }
    public string KindLabel { get; }
    public string ScopeLabel { get; }
    public string CredentialDisplayName => Entry.CredentialDisplayName;
    public RelayCommand RevokeCommand { get; }
}
