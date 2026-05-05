namespace Bromure.Platform;

public sealed class WindowsAppPaths : IAppPaths
{
    private const string Vendor = "Bromure";
    private const string Product = "AC";

    public WindowsAppPaths(string? installRootOverride = null)
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var programData = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
        AppDataRoot = Path.Combine(localAppData, Vendor, Product);
        MachineDataRoot = Path.Combine(programData, Vendor, Product);
        ProfilesDirectory = Path.Combine(AppDataRoot, "profiles");
        TracesDirectory = Path.Combine(AppDataRoot, "traces");
        ImagesDirectory = Path.Combine(AppDataRoot, "images");
        SessionsDirectory = Path.Combine(AppDataRoot, "sessions");

        // The installed payload (QEMU + OVMF + base qcow2) lives next to
        // the EXE. Allow tests / spike to override.
        if (installRootOverride is not null)
        {
            ResourcesDirectory = installRootOverride;
        }
        else
        {
            var exe = AppContext.BaseDirectory;
            ResourcesDirectory = Path.Combine(exe, "resources");
        }
    }

    public string AppDataRoot { get; }
    public string MachineDataRoot { get; }
    public string ProfilesDirectory { get; }
    public string TracesDirectory { get; }
    public string ImagesDirectory { get; }
    public string SessionsDirectory { get; }
    public string ResourcesDirectory { get; }

    public string EnsureDirectory(string path)
    {
        Directory.CreateDirectory(path);
        return path;
    }
}
