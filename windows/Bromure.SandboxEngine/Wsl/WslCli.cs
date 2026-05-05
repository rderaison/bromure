using System.Diagnostics;
using System.Text;

namespace Bromure.SandboxEngine.Wsl;

/// <summary>
/// Thin async wrapper around <c>wsl.exe</c>. Centralises the two
/// quirks that bite every caller:
///
/// <list type="bullet">
///   <item>By default <c>wsl.exe</c> emits UTF-16LE on stdout/stderr,
///   producing the "spaces between every character" output everyone
///   has hit at least once. Setting <c>WSL_UTF8=1</c> in the
///   environment forces UTF-8 — much friendlier to parse.</item>
///   <item>Some operations (<c>--export</c> a multi-GB tarball,
///   <c>--import</c> back) take minutes. Default 2-minute Process
///   timeout is too tight; we expose a CancellationToken instead.</item>
/// </list>
///
/// Returns a <see cref="WslResult"/> (exit code + captured streams)
/// rather than throwing on non-zero exit, so callers can decide
/// what to do with errors. Most callers will just inspect
/// <c>ExitCode</c> and either succeed or wrap into a domain
/// exception with the captured stderr.
/// </summary>
public static class WslCli
{
    /// <summary>Run wsl.exe with the given args; capture stdout + stderr.</summary>
    public static async Task<WslResult> RunAsync(
        IReadOnlyList<string> args,
        CancellationToken ct = default,
        Stream? stdinSource = null)
    {
        var psi = new ProcessStartInfo
        {
            FileName = "wsl.exe",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            RedirectStandardInput = stdinSource is not null,
            // wsl.exe emits UTF-16LE by default — flip it to UTF-8 so
            // .NET's StreamReader (UTF-8 by default) reads it correctly.
            // Without this every output character is interleaved with
            // a NUL byte and parsing falls apart.
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        psi.Environment["WSL_UTF8"] = "1";
        foreach (var a in args) psi.ArgumentList.Add(a);

        using var p = new Process { StartInfo = psi };
        if (!p.Start())
        {
            throw new InvalidOperationException("wsl.exe failed to start");
        }

        var stdoutTask = p.StandardOutput.ReadToEndAsync(ct);
        var stderrTask = p.StandardError.ReadToEndAsync(ct);
        Task? stdinPump = null;
        if (stdinSource is not null)
        {
            stdinPump = PumpStdinAsync(stdinSource, p.StandardInput.BaseStream, ct);
        }

        try
        {
            await p.WaitForExitAsync(ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            try { p.Kill(entireProcessTree: true); } catch { }
            throw;
        }

        if (stdinPump is not null) { try { await stdinPump.ConfigureAwait(false); } catch { } }
        var stdout = await stdoutTask.ConfigureAwait(false);
        var stderr = await stderrTask.ConfigureAwait(false);
        return new WslResult(p.ExitCode, stdout, stderr);
    }

    private static async Task PumpStdinAsync(Stream src, Stream dst, CancellationToken ct)
    {
        try
        {
            await src.CopyToAsync(dst, ct).ConfigureAwait(false);
        }
        finally
        {
            try { dst.Close(); } catch { }
        }
    }
}

/// <summary>
/// Captured outcome of a single wsl.exe invocation. Treat
/// <c>ExitCode != 0</c> as failure; <c>Stderr</c> typically carries
/// a usable diagnostic.
/// </summary>
public sealed record WslResult(int ExitCode, string Stdout, string Stderr)
{
    public bool Success => ExitCode == 0;

    /// <summary>Throw a <see cref="WslException"/> when the call failed.</summary>
    public WslResult ThrowIfFailed(string operation)
    {
        if (!Success)
        {
            throw new WslException(
                $"{operation} failed (exit {ExitCode}): {Stderr.Trim()}");
        }
        return this;
    }
}

public sealed class WslException : Exception
{
    public WslException(string message) : base(message) { }
}
