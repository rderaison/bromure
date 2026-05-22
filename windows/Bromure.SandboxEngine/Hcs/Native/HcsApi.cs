// macos-source: Sources/SandboxEngine/LinuxSandboxVM.swift @ fe7e7d3a3e21
using System.Runtime.InteropServices;
using System.Text;

namespace Bromure.SandboxEngine.Hcs.Native;

/// <summary>
/// Thin P/Invoke layer over <c>vmcompute.dll</c> — the Hyper-V Compute
/// Service (HCS) host API. This is the same primitive that backs
/// containerd-on-Windows, Docker Desktop's MobyVM, Windows Sandbox
/// and (one layer up) WSL2's utility VM.
///
/// <para><b>Why direct P/Invoke and not hcsshim?</b> hcsshim is Go;
/// adopting it would mean either shelling out to a Go binary on every
/// VM event (the wsl.exe pattern this port deliberately moved away from)
/// or hosting a Go runtime in-process. The HCS API itself is
/// JSON-on-Win32-handles — straightforward to drive from .NET once
/// you have the function signatures. Microsoft documents the surface
/// at <see href="https://learn.microsoft.com/en-us/virtualization/api/hcs/overview"/>.</para>
///
/// <para><b>Lifetime model.</b> A "compute system" handle represents
/// one VM. You create with <see cref="HcsCreateComputeSystem"/>
/// passing a JSON document (see <see cref="HcsSchema"/>), start it,
/// optionally attach an event callback, then terminate + close.
/// Operations are async at the HCS level — every call returns a
/// "result document" string with status info, and callers wait on
/// HcsWaitForOperationResult or pump events.</para>
///
/// <para><b>Threading.</b> Calls are thread-safe; the HCS service
/// serialises per compute-system. We hold no global lock here.</para>
/// </summary>
internal static class HcsApi
{
    /// <summary>HRESULT for "operation in progress" — many HCS calls
    /// return this and want a follow-up wait.</summary>
    public const int E_PENDING = unchecked((int)0x8000000A);

    /// <summary>HCS "compute system not found." Surfaced when terminating
    /// a VM that's already gone — treat as success.</summary>
    public const int HCS_E_SYSTEM_NOT_FOUND = unchecked((int)0x80370101);

    /// <summary>HCS "compute system already exists" — treat as
    /// success in the idempotent-create path (cf. WslDistro.ImportAsync).</summary>
    public const int HCS_E_SYSTEM_ALREADY_EXISTS = unchecked((int)0x80370106);

    // --- v2 async API ------------------------------------------------
    //
    // The modern HCS surface lives in COMPUTECORE.DLL — NOT
    // vmcompute.dll. vmcompute.dll on Win 11 24H2 only exports
    // legacy callback-based forwarders for a few names; the
    // operation-handle async machinery (HcsCreateOperation,
    // HcsCloseOperation, HcsWaitForOperationResult, …) is entirely
    // in computecore.dll. hcsshim's source claims `vmcompute.HcsX`
    // for everything, but that's a stale comment — the runtime
    // lookup follows the loader path and computecore.dll wins.
    //
    // Pattern: HcsCreateOperation → call (returns
    // HCS_E_OPERATION_PENDING 0xC0370103 = success, queued) →
    // HcsWaitForOperationResult to block → HcsCloseOperation.

    /// <summary>Create an operation handle for a single async HCS call.
    /// callback + context can be IntPtr.Zero if we plan to block on
    /// HcsWaitForOperationResult (which we do).</summary>
    [DllImport("computecore.dll", CharSet = CharSet.Unicode, ExactSpelling = true,
        PreserveSig = true)]
    public static extern IntPtr HcsCreateOperation(IntPtr callback, IntPtr context);

    /// <summary>Release an operation handle. Idempotent.</summary>
    [DllImport("computecore.dll", CharSet = CharSet.Unicode, ExactSpelling = true,
        PreserveSig = true)]
    public static extern void HcsCloseOperation(IntPtr operation);

    /// <summary>Block on an operation until completion or timeout.
    /// <paramref name="timeoutMs"/> = 0xFFFFFFFF = INFINITE.
    /// Returns the HRESULT the underlying call would have returned
    /// synchronously, with the result document in <paramref name="result"/>.</summary>
    [DllImport("computecore.dll", CharSet = CharSet.Unicode, ExactSpelling = true,
        PreserveSig = true)]
    public static extern int HcsWaitForOperationResult(
        IntPtr operation,
        uint timeoutMs,
        out IntPtr result);

    /// <summary>v2 async create: returns immediately, the resulting
    /// compute system handle is only safe to use after
    /// HcsWaitForOperationResult on <paramref name="operation"/>.</summary>
    [DllImport("computecore.dll", CharSet = CharSet.Unicode, ExactSpelling = true,
        SetLastError = false, PreserveSig = true)]
    public static extern int HcsCreateComputeSystem(
        [MarshalAs(UnmanagedType.LPWStr)] string id,
        [MarshalAs(UnmanagedType.LPWStr)] string configuration,
        IntPtr operation,
        IntPtr securityDescriptor,
        out IntPtr computeSystem);

    [DllImport("computecore.dll", CharSet = CharSet.Unicode, ExactSpelling = true,
        PreserveSig = true)]
    public static extern int HcsStartComputeSystem(
        IntPtr computeSystem,
        IntPtr operation,
        [MarshalAs(UnmanagedType.LPWStr)] string? options);

    [DllImport("computecore.dll", CharSet = CharSet.Unicode, ExactSpelling = true,
        PreserveSig = true)]
    public static extern int HcsTerminateComputeSystem(
        IntPtr computeSystem,
        IntPtr operation,
        [MarshalAs(UnmanagedType.LPWStr)] string? options);

    [DllImport("computecore.dll", CharSet = CharSet.Unicode, ExactSpelling = true,
        PreserveSig = true)]
    public static extern int HcsShutdownComputeSystem(
        IntPtr computeSystem,
        IntPtr operation,
        [MarshalAs(UnmanagedType.LPWStr)] string? options);

    [DllImport("computecore.dll", CharSet = CharSet.Unicode, ExactSpelling = true,
        PreserveSig = true)]
    public static extern int HcsCloseComputeSystem(IntPtr computeSystem);

    [DllImport("computecore.dll", CharSet = CharSet.Unicode, ExactSpelling = true,
        PreserveSig = true)]
    public static extern int HcsOpenComputeSystem(
        [MarshalAs(UnmanagedType.LPWStr)] string id,
        uint requestedAccess,
        out IntPtr computeSystem);

    [DllImport("computecore.dll", CharSet = CharSet.Unicode, ExactSpelling = true,
        PreserveSig = true)]
    public static extern int HcsGetComputeSystemProperties(
        IntPtr computeSystem,
        IntPtr operation,
        [MarshalAs(UnmanagedType.LPWStr)] string? propertyQuery);

    [DllImport("computecore.dll", CharSet = CharSet.Unicode, ExactSpelling = true,
        PreserveSig = true)]
    public static extern int HcsModifyComputeSystem(
        IntPtr computeSystem,
        IntPtr operation,
        [MarshalAs(UnmanagedType.LPWStr)] string configuration,
        IntPtr identity);

    /// <summary>Suspend a running VM and dump its CPU+RAM+device state
    /// to disk. <paramref name="options"/> is a JSON document like
    /// <c>{"SaveType":"ToFile","SaveStateFilePath":"C:\\…\\state.bin"}</c>.
    /// After the operation completes the VM is in the "Saved" state;
    /// closing the handle does not lose the save file. To resume,
    /// create a fresh compute system whose schema sets
    /// <c>VirtualMachine.RestoreState.SavedStateFilePath</c> to the
    /// same path, then call <see cref="HcsResumeComputeSystem"/>.
    /// HCS requires the VM be paused first (Running → Save returns
    /// HCS_E_INVALID_STATE), so callers should wrap this in
    /// Pause → Save.</summary>
    [DllImport("computecore.dll", CharSet = CharSet.Unicode, ExactSpelling = true,
        PreserveSig = true)]
    public static extern int HcsSaveComputeSystem(
        IntPtr computeSystem,
        IntPtr operation,
        [MarshalAs(UnmanagedType.LPWStr)] string? options);

    /// <summary>Pause a running VM (vCPUs frozen, devices quiesced).
    /// Required precondition for <see cref="HcsSaveComputeSystem"/>
    /// on this Windows build.</summary>
    [DllImport("computecore.dll", CharSet = CharSet.Unicode, ExactSpelling = true,
        PreserveSig = true)]
    public static extern int HcsPauseComputeSystem(
        IntPtr computeSystem,
        IntPtr operation,
        [MarshalAs(UnmanagedType.LPWStr)] string? options);

    /// <summary>Resume a VM previously created with
    /// <c>RestoreState.SavedStateFilePath</c> set. Equivalent of
    /// <see cref="HcsStartComputeSystem"/> for the hibernate path.</summary>
    [DllImport("computecore.dll", CharSet = CharSet.Unicode, ExactSpelling = true,
        PreserveSig = true)]
    public static extern int HcsResumeComputeSystem(
        IntPtr computeSystem,
        IntPtr operation,
        [MarshalAs(UnmanagedType.LPWStr)] string? options);

    /// <summary>Run an async HCS call to completion. Creates an
    /// operation, invokes <paramref name="op"/>, blocks on the
    /// operation result, closes the operation. Returns the final
    /// HRESULT + result document.</summary>
    public static int RunOperation(Func<IntPtr, int> op, out string? resultDoc,
        uint timeoutMs = 0xFFFFFFFF)
    {
        IntPtr operation = HcsCreateOperation(IntPtr.Zero, IntPtr.Zero);
        if (operation == IntPtr.Zero)
        {
            resultDoc = "HcsCreateOperation returned null";
            return unchecked((int)0x80004005); // E_FAIL
        }
        try
        {
            int kickoff = op(operation);
            // HCS_E_OPERATION_PENDING (0xC0370103) is the expected
            // return when the call queued successfully — we just
            // wait for the result. Any other failure is real.
            if (kickoff < 0 && kickoff != unchecked((int)0xC0370103))
            {
                resultDoc = null;
                return kickoff;
            }
            int waitHr = HcsWaitForOperationResult(operation, timeoutMs, out IntPtr resultPtr);
            resultDoc = ConsumeWideString(resultPtr);
            return waitHr;
        }
        finally
        {
            HcsCloseOperation(operation);
        }
    }

    /// <summary>Grant a VM access to a host VHDX so it can attach the disk.
    /// Without this the VM's worker process gets ACCESS_DENIED at
    /// boot when it tries to open the user's disk.
    ///
    /// <para><b>Export name is <c>GrantVmAccess</c>, not
    /// <c>HcsGrantVmAccess</c></b> — Microsoft Learn docs disagree
    /// with the actual export. hcsshim's Go bindings confirm the
    /// no-prefix form, and the e2e harness verified it on Win11.
    /// The function lives in <c>vmcompute.dll</c>.</para>
    ///
    /// <para>Best-effort wrapper <see cref="TryGrantVmAccess"/> below
    /// swallows EntryPointNotFoundException so an older Windows
    /// build that lacks this export doesn't block VM creation —
    /// the file ACLs typically grant the user's worker process
    /// access already.</para></summary>
    [DllImport("vmcompute.dll", EntryPoint = "GrantVmAccess",
        CharSet = CharSet.Unicode, ExactSpelling = true, PreserveSig = true)]
    public static extern int GrantVmAccess(
        [MarshalAs(UnmanagedType.LPWStr)] string vmId,
        [MarshalAs(UnmanagedType.LPWStr)] string filePath);

    /// <summary>Revoke the access granted by <see cref="GrantVmAccess"/>.
    /// Same DLL + same export-name discrepancy.</summary>
    [DllImport("vmcompute.dll", EntryPoint = "RevokeVmAccess",
        CharSet = CharSet.Unicode, ExactSpelling = true, PreserveSig = true)]
    public static extern int RevokeVmAccess(
        [MarshalAs(UnmanagedType.LPWStr)] string vmId,
        [MarshalAs(UnmanagedType.LPWStr)] string filePath);

    /// <summary>Best-effort wrapper around <see cref="GrantVmAccess"/>.
    /// Returns success/failure HRESULT, or 0 if the entry point is
    /// missing (older Windows). Callers should not treat a failure
    /// as fatal — the file ACLs may already permit access.</summary>
    public static int TryGrantVmAccess(string vmId, string filePath)
    {
        try { return GrantVmAccess(vmId, filePath); }
        catch (EntryPointNotFoundException) { return 0; }
        catch (DllNotFoundException) { return 0; }
    }

    /// <summary>Best-effort companion to <see cref="TryGrantVmAccess"/>.</summary>
    public static int TryRevokeVmAccess(string vmId, string filePath)
    {
        try { return RevokeVmAccess(vmId, filePath); }
        catch (EntryPointNotFoundException) { return 0; }
        catch (DllNotFoundException) { return 0; }
    }

    /// <summary>
    /// Convert an HCS-allocated wide string (the <c>result</c> out-parameter
    /// from HcsCreate/Start/Terminate/etc.) into a managed string and free
    /// the underlying buffer with LocalFree. HCS docs: every non-null
    /// out-param of type LPWSTR must be released this way.
    /// </summary>
    public static string? ConsumeWideString(IntPtr ptr)
    {
        if (ptr == IntPtr.Zero) return null;
        try
        {
            return Marshal.PtrToStringUni(ptr);
        }
        finally
        {
            // LocalFree from kernel32 — vmcompute.dll allocates with LocalAlloc.
            try { LocalFree(ptr); } catch { /* best-effort */ }
        }
    }

    [DllImport("kernel32.dll", SetLastError = true, ExactSpelling = true)]
    private static extern IntPtr LocalFree(IntPtr hMem);

    /// <summary>
    /// Throw an <see cref="HcsException"/> on a non-success HRESULT,
    /// attaching the result document for diagnostics. Used by the
    /// higher-level wrappers in <see cref="HcsVm"/>.
    /// </summary>
    public static void ThrowIfFailed(int hr, IntPtr resultPtr, string operation)
    {
        var result = ConsumeWideString(resultPtr);
        if (hr >= 0) return;
        throw new HcsException(operation, hr, result);
    }
}

/// <summary>Exception type for HCS API failures. Carries the HRESULT and
/// any result document the host returned (often a JSON object with a
/// useful <c>Error</c> / <c>ErrorMessage</c>).</summary>
public sealed class HcsException : Exception
{
    public string? ResultDocument { get; }

    public HcsException(string operation, int hresult, string? resultDoc)
        : base(BuildMessage(operation, hresult, resultDoc))
    {
        // Exception.HResult is settable on Exception itself — use the
        // base property rather than shadowing it.
        HResult = hresult;
        ResultDocument = resultDoc;
    }

    private static string BuildMessage(string operation, int hr, string? doc)
    {
        var sb = new StringBuilder();
        sb.Append(operation).Append(" failed (HRESULT 0x")
          .Append(hr.ToString("X8")).Append(')');
        if (!string.IsNullOrEmpty(doc))
        {
            sb.Append(": ").Append(doc.Length > 2000 ? doc[..2000] + "…" : doc);
        }
        return sb.ToString();
    }
}
