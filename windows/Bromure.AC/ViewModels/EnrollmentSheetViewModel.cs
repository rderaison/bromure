using System.Net.Http;
using Bromure.AC.Core.Enrollment;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;

namespace Bromure.AC.ViewModels;

public sealed partial class EnrollmentSheetViewModel : ObservableObject
{
    private readonly EnrollmentClient _client;
    private readonly EnrollmentStore _store;

    [ObservableProperty] private string _code = "";
    [ObservableProperty] private string _serverUrl = "";
    [ObservableProperty] private string _deviceName;
    [ObservableProperty] private bool _inFlight;
    [ObservableProperty] private string? _errorMessage;

    /// <summary>Set to the resulting install on success; null on cancel.</summary>
    public BromureInstall? Result { get; private set; }
    public event EventHandler? Done;

    public EnrollmentSheetViewModel(EnrollmentStore store, EnrollmentClient? client = null)
    {
        _store = store;
        _client = client ?? new EnrollmentClient();
        _deviceName = Environment.MachineName;
    }

    [RelayCommand]
    private async Task SubmitAsync()
    {
        ErrorMessage = null;
        if (string.IsNullOrWhiteSpace(Code))
        {
            ErrorMessage = "Enrollment code is empty.";
            return;
        }
        InFlight = true;
        try
        {
            Uri? server = null;
            if (!string.IsNullOrWhiteSpace(ServerUrl))
            {
                if (!Uri.TryCreate(ServerUrl.Trim(), UriKind.Absolute, out server))
                {
                    ErrorMessage = "Server URL is malformed.";
                    return;
                }
            }
            var install = await _client.EnrollAsync(Code.Trim(), DeviceName.Trim(), server);
            _store.Save(install);
            Result = install;
            Done?.Invoke(this, EventArgs.Empty);
        }
        catch (EnrollmentException ex) { ErrorMessage = ex.Message; }
        catch (HttpRequestException ex) { ErrorMessage = "Network error: " + ex.Message; }
        catch (TaskCanceledException) { ErrorMessage = "Request timed out."; }
        finally { InFlight = false; }
    }

    [RelayCommand]
    private void Cancel()
    {
        Result = null;
        Done?.Invoke(this, EventArgs.Empty);
    }
}
