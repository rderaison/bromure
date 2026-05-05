namespace Bromure.Platform;

/// <summary>
/// Default implementation for non-shipping builds (spike harness,
/// xUnit). Real shipping app wires WinSparkle's WinSparkle.dll.
/// </summary>
public sealed class NoOpAppUpdater : IAppUpdater
{
    public void Initialize(string appcastUrl, string companyName, string appName, string appVersion) { }
    public void CheckSilently() { }
    public void CheckInteractively() { }
    public void Shutdown() { }
}
