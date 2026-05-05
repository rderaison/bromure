namespace Bromure.SandboxEngine.Qemu;

/// <summary>
/// Thrown by <see cref="QemuSupervisor.StartAsync"/> when QEMU fails to
/// hand us back a working QMP socket. Carries QEMU's stderr tail and
/// the path of the per-session log file so the UI can render the real
/// reason instead of "could not connect to QMP at ...".
/// </summary>
public sealed class QemuStartException : Exception
{
    public string StderrTail { get; }
    public string? StderrLogPath { get; }

    public QemuStartException(string message, string stderrTail, string? stderrLogPath, Exception? inner = null)
        : base(message, inner)
    {
        StderrTail = stderrTail;
        StderrLogPath = stderrLogPath;
    }
}
