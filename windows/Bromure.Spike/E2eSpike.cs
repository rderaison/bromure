using System.Diagnostics;
using System.Runtime.InteropServices;
using Bromure.SandboxEngine.Hcs;
using Bromure.SandboxEngine.Hcs.Native;

namespace Bromure.Spike;

/// <summary>
/// End-to-end harness for the HCS stack. Walks the layers bottom-up
/// (vmcompute.dll availability → VHDX differencing-disk creation →
/// HCS VM lifecycle → HcsSession boot) and prints PASS / SKIP / FAIL
/// at each step with the elapsed time and a one-line reason. Each
/// phase is independent; later phases SKIP cleanly if their
/// prerequisites are missing.
///
/// <para>Goal: run this once instead of round-tripping through the
/// GUI when the user reports "X does nothing." Each layer maps to
/// one diagnostic line in the output.</para>
///
/// <para>Usage:</para>
/// <code>bromure-spike e2e [--artefact-dir &lt;dir&gt;]</code>
/// <para>If <c>--artefact-dir</c> is supplied and contains
/// bromure-base.vhdx + vmlinuz + initrd.img, the higher phases will
/// actually boot a VM. Without it the harness covers everything
/// that doesn't need a baked rootfs.</para>
/// </summary>
public static class E2eSpike
{
    public static async Task<int> RunAsync(string[] args)
    {
        string? artefactDir = null;
        bool withStubs = false;
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--artefact-dir" && i + 1 < args.Length) artefactDir = args[++i];
            else if (args[i] == "--with-stubs") withStubs = true;
        }

        var report = new Report();
        Console.WriteLine("=== Bromure HCS e2e harness ===");
        Console.WriteLine($"working dir: {Environment.CurrentDirectory}");
        // When --with-stubs is set, synthesise a dummy artefact set
        // (real VHDX parent, fake vmlinuz/initrd). Phase 5 then
        // exercises HCS schema validation + HcsVm.CreateAsync against
        // vmcompute.dll, with Start expected to fail at kernel load.
        string? stubDir = null;
        if (withStubs && artefactDir is null)
        {
            stubDir = Path.Combine(Path.GetTempPath(), "bromure-e2e-stubs-" + Guid.NewGuid().ToString("N")[..6]);
            artefactDir = stubDir;
            Directory.CreateDirectory(stubDir);
            MakeStubArtefacts(stubDir);
        }
        Console.WriteLine($"artefact-dir: {artefactDir ?? "<none — VM-boot phases will SKIP>"}");
        if (stubDir is not null)
            Console.WriteLine("  (stubs — phase 5 should Create OK, Start should FAIL at kernel-load)");
        Console.WriteLine();

        try
        {
            await Phase1_HypervisorAvailable(report).ConfigureAwait(false);
            await Phase1b_FullHyperVFeature(report).ConfigureAwait(false);
            await Phase2_VirtDiskAvailable(report).ConfigureAwait(false);
            await Phase3_VhdxDifferencingDisk(report).ConfigureAwait(false);
            await Phase4_ArtefactsPresent(artefactDir, report).ConfigureAwait(false);
            await Phase5_HcsVmLifecycle(artefactDir, report, expectStartFailure: stubDir is not null).ConfigureAwait(false);
            await Phase6_HcsSessionBoot(artefactDir, report).ConfigureAwait(false);
        }
        finally
        {
            if (stubDir is not null)
            {
                try { Directory.Delete(stubDir, recursive: true); } catch { }
            }
        }

        Console.WriteLine();
        Console.WriteLine("=== summary ===");
        foreach (var r in report.Results)
        {
            Console.WriteLine($"  [{r.Status,-4}] {r.Phase,-32} {r.ElapsedMs,5} ms  {r.Detail}");
        }
        var failed = report.Results.Count(r => r.Status == "FAIL");
        var skipped = report.Results.Count(r => r.Status == "SKIP");
        var passed = report.Results.Count(r => r.Status == "PASS");
        Console.WriteLine();
        Console.WriteLine($"  pass={passed} skip={skipped} fail={failed}");
        return failed == 0 ? 0 : 1;
    }

    // ─────────────────────────────────────────────────────────────
    //  Phases
    // ─────────────────────────────────────────────────────────────

    /// <summary>Is vmcompute.dll loadable? If not, every HCS phase
    /// below will SKIP. We attempt a no-op P/Invoke that's guaranteed
    /// to return cheaply (HcsCloseComputeSystem with a null handle).</summary>
    private static async Task Phase1_HypervisorAvailable(Report r)
    {
        await r.RunAsync("hyper-v / vmcompute.dll", async () =>
        {
            await Task.Yield();
            try
            {
                // LoadLibrary on vmcompute.dll. If Hyper-V optional feature
                // isn't enabled the DLL exists but is functionally inert;
                // we still consider "loaded" a PASS — the next phases will
                // catch a runtime failure.
                var hMod = LoadLibraryW("vmcompute.dll");
                if (hMod == IntPtr.Zero)
                {
                    return (false, "LoadLibrary(vmcompute.dll) returned NULL — Hyper-V Platform feature likely not enabled");
                }
                FreeLibrary(hMod);
                return (true, "vmcompute.dll loadable");
            }
            catch (Exception ex)
            {
                return (false, $"exception: {ex.Message}");
            }
        }).ConfigureAwait(false);
    }

    /// <summary>Is the full Microsoft-Hyper-V optional feature enabled?
    /// Tells apart "Hypervisor Platform only" (sufficient for WSL2,
    /// Docker, QEMU+WHPX) vs "full Hyper-V" (required to create
    /// VirtualMachine-mode HCS compute systems). The signature for
    /// the latter is the presence of <c>vmms.exe</c> in System32 — it
    /// only ships with the Microsoft-Hyper-V feature.
    /// <para>Empirically: when Hyper-V is absent, vmcompute.dll's
    /// CreateComputeSystem returns HCS_E_INVALID_JSON even for an
    /// empty JSON doc. That error name is misleading — the actual
    /// failure mode is "this SKU/feature doesn't support VM-mode
    /// compute systems."</para></summary>
    private static async Task Phase1b_FullHyperVFeature(Report r)
    {
        await r.RunAsync("full Hyper-V feature (vmms.exe)", async () =>
        {
            await Task.Yield();
            var hv = HyperVPreflight.Detect();
            if (!hv.Ok)
            {
                return (false,
                    (hv.ErrorMessage ?? "Hyper-V missing")
                    + "\n    Fix: " + HyperVPreflight.FixCommand);
            }
            return (true, "vmms.exe present — full Hyper-V is enabled");
        }).ConfigureAwait(false);
    }

    /// <summary>Is virtdisk.dll loadable? Required by VhdxDisk regardless
    /// of whether HCS is up — VHDX creation works on any Windows host
    /// even without Hyper-V.</summary>
    private static async Task Phase2_VirtDiskAvailable(Report r)
    {
        await r.RunAsync("virtdisk.dll", async () =>
        {
            await Task.Yield();
            var hMod = LoadLibraryW("virtdisk.dll");
            if (hMod == IntPtr.Zero) return (false, "LoadLibrary(virtdisk.dll) failed");
            FreeLibrary(hMod);
            return (true, "virtdisk.dll loadable");
        }).ConfigureAwait(false);
    }

    /// <summary>Create a tiny parent VHDX from scratch, clone a child off it,
    /// verify the child exists. Doesn't need Hyper-V to be running —
    /// VHDX is a file format, not a VM.</summary>
    private static async Task Phase3_VhdxDifferencingDisk(Report r)
    {
        await r.RunAsync("VHDX differencing-disk clone", async () =>
        {
            var dir = Path.Combine(Path.GetTempPath(), "bromure-e2e-" + Guid.NewGuid().ToString("N")[..6]);
            Directory.CreateDirectory(dir);
            var parent = Path.Combine(dir, "parent.vhdx");
            var child = Path.Combine(dir, "child.vhdx");
            try
            {
                // 256 MB is a clean multiple of VHDX's default 32 MB
                // block size; smaller sizes hit ERROR_VHD_INVALID_TYPE
                // because the metadata layout doesn't fit.
                if (!CreateParentVhdx(parent, sizeBytes: 256L * 1024 * 1024, out var msg))
                {
                    return (false, msg);
                }
                var disk = new VhdxDisk(child, parent);
                await disk.CreateChildAsync().ConfigureAwait(false);
                if (!File.Exists(child))
                {
                    return (false, "child VHDX was not created");
                }
                var size = new FileInfo(child).Length;
                await disk.DisposeAsync().ConfigureAwait(false);
                if (File.Exists(child))
                {
                    return (false, "child VHDX wasn't deleted on dispose");
                }
                return (true, $"parent + child OK (child header size ≈ {size / 1024} KB)");
            }
            catch (HcsException hex)
            {
                return (false, "HcsException 0x" + hex.HResult.ToString("X8") + ": " + hex.Message);
            }
            catch (Exception ex)
            {
                return (false, $"exception: {ex.GetType().Name}: {ex.Message}");
            }
            finally
            {
                try { Directory.Delete(dir, recursive: true); } catch { }
            }
        }).ConfigureAwait(false);
    }

    /// <summary>Do bake artefacts exist? If not, the VM-boot phases SKIP.</summary>
    private static async Task Phase4_ArtefactsPresent(string? dir, Report r)
    {
        await r.RunAsync("bake artefacts present", async () =>
        {
            await Task.Yield();
            if (dir is null) return (false, "skipped: no --artefact-dir supplied");
            var a = BakeArtefacts.InDirectory(dir);
            if (!a.AllExist())
            {
                var missing = new List<string>();
                if (!File.Exists(a.BaseVhdxPath)) missing.Add(VmBaker.OutputBaseFileName);
                if (!File.Exists(a.KernelPath)) missing.Add(VmBaker.OutputKernelFileName);
                if (!File.Exists(a.InitrdPath)) missing.Add(VmBaker.OutputInitrdFileName);
                return (false, "missing: " + string.Join(", ", missing));
            }
            return (true, $"all three present in {dir}");
        }).ConfigureAwait(false);
    }

    /// <summary>Create an HCS VM, start it, terminate, destroy. Requires
    /// (a) Hyper-V Platform enabled and (b) artefacts present. SKIP
    /// otherwise.
    ///
    /// <para>When <paramref name="expectStartFailure"/> is true (stub-
    /// artefacts mode), Start failing is treated as PASS — the
    /// schema validation + Create-against-real-HCS path is what we're
    /// after, and a fake vmlinuz can't actually boot.</para></summary>
    private static async Task Phase5_HcsVmLifecycle(string? dir, Report r, bool expectStartFailure = false)
    {
        await r.RunAsync("HCS VM lifecycle", async () =>
        {
            if (dir is null) return (false, "skipped: no --artefact-dir");
            var a = BakeArtefacts.InDirectory(dir);
            if (!a.AllExist()) return (false, "skipped: artefacts missing");
            if (!r.LastResultPassed("hyper-v / vmcompute.dll"))
                return (false, "skipped: vmcompute.dll not available");
            if (!r.LastResultPassed("full Hyper-V feature (vmms.exe)"))
                return (false, "skipped: full Hyper-V feature not enabled (see phase 1b for fix)");

            var id = "bromure-e2e-" + Guid.NewGuid().ToString("N")[..8];
            var installDir = Path.Combine(Path.GetTempPath(), id);
            Directory.CreateDirectory(installDir);
            var childPath = Path.Combine(installDir, "disk.vhdx");
            HcsVm? vm = null;
            VhdxDisk? disk = null;
            try
            {
                disk = new VhdxDisk(childPath, a.BaseVhdxPath);
                await disk.CreateChildAsync().ConfigureAwait(false);
                var cfg = new HcsVmConfig
                {
                    KernelPath = a.KernelPath,
                    InitrdPath = a.InitrdPath,
                    RootDiskPath = childPath,
                    MemoryMB = 512,
                };
                // Dump the JSON the harness will hand to HCS — invaluable
                // when HcsCreateComputeSystem returns HCS_E_INVALID_JSON.
                Console.WriteLine();
                Console.WriteLine("  --- VM config JSON ---");
                Console.WriteLine("  " + Bromure.SandboxEngine.Hcs.Native.HcsSchema.Serialize(cfg.BuildSchema()));
                Console.WriteLine("  ---");

                vm = new HcsVm(id, cfg);
                await vm.CreateAsync().ConfigureAwait(false);
                try
                {
                    await vm.StartAsync().ConfigureAwait(false);
                }
                catch (HcsException hex) when (expectStartFailure)
                {
                    // Expected with stub artefacts: vmcompute.dll
                    // validated our schema (Create succeeded) and
                    // attempted to boot, then choked on the fake
                    // kernel. That's exactly the signal we wanted.
                    return (true,
                        "Create OK; Start failed as expected with stub kernel — schema validated. " +
                        "HRESULT 0x" + hex.HResult.ToString("X8"));
                }
                await Task.Delay(2000).ConfigureAwait(false);
                await vm.TerminateAsync().ConfigureAwait(false);
                await vm.DestroyAsync().ConfigureAwait(false);
                return (true, "create → start → terminate → destroy OK");
            }
            catch (HcsException hex)
            {
                var doc = string.IsNullOrEmpty(hex.ResultDocument) ? "<empty>" : hex.ResultDocument;
                return (false, "HcsException 0x" + hex.HResult.ToString("X8") + " result=" + doc);
            }
            catch (Exception ex)
            {
                return (false, $"exception: {ex.GetType().Name}: {ex.Message}");
            }
            finally
            {
                if (vm is not null) { try { await vm.DisposeAsync().ConfigureAwait(false); } catch { } }
                if (disk is not null) { try { await disk.DisposeAsync().ConfigureAwait(false); } catch { } }
                try { Directory.Delete(installDir, recursive: true); } catch { }
            }
        }).ConfigureAwait(false);
    }

    /// <summary>Synthesise a stub-artefact triple: a real (empty) VHDX
    /// parent, plus tiny placeholder files for the kernel and initrd.
    /// Only useful with phase 5 in stub-failure mode.</summary>
    private static void MakeStubArtefacts(string dir)
    {
        var vhdx = Path.Combine(dir, VmBaker.OutputBaseFileName);
        CreateParentVhdx(vhdx, sizeBytes: 256L * 1024 * 1024, out _);
        File.WriteAllBytes(Path.Combine(dir, VmBaker.OutputKernelFileName),
            System.Text.Encoding.ASCII.GetBytes("STUB-KERNEL"));
        File.WriteAllBytes(Path.Combine(dir, VmBaker.OutputInitrdFileName),
            System.Text.Encoding.ASCII.GetBytes("STUB-INITRD"));
    }

    /// <summary>Full HcsSession boot: VHDX clone + plan9 stage + start +
    /// wait-for-boot-signal + shutdown. Requires a baked VHDX with
    /// setup-hcs.sh applied — otherwise the boot signal never arrives
    /// and the phase FAILs with a timeout (which is still useful
    /// diagnostic).</summary>
    private static async Task Phase6_HcsSessionBoot(string? dir, Report r)
    {
        await r.RunAsync("HcsSession end-to-end", async () =>
        {
            if (dir is null) return (false, "skipped: no --artefact-dir");
            var a = BakeArtefacts.InDirectory(dir);
            if (!a.AllExist()) return (false, "skipped: artefacts missing");
            if (!r.LastResultPassed("HCS VM lifecycle"))
                return (false, "skipped: VM lifecycle phase didn't pass");

            var id = "bromure-e2e-ses-" + Guid.NewGuid().ToString("N")[..8];
            var installDir = Path.Combine(Path.GetTempPath(), id);
            var cfg = new HcsSessionConfig
            {
                BaseVhdxPath = a.BaseVhdxPath,
                KernelPath = a.KernelPath,
                InitrdPath = a.InitrdPath,
                VmId = id,
                InstallPath = installDir,
                HomeFiles = new Dictionary<string, byte[]>
                {
                    [".bromure-e2e"] = System.Text.Encoding.UTF8.GetBytes("hello from e2e\n"),
                },
                EnvVars = new Dictionary<string, string>
                {
                    ["BROMURE_E2E"] = "1",
                },
            };
            await using var session = new HcsSession(cfg);
            try
            {
                await session.StartAsync().ConfigureAwait(false);
                return (true, $"booted; timings:\n{session.LastTimings.Trim()}");
            }
            catch (TimeoutException tex)
            {
                return (false,
                    "session started but boot signal didn't arrive within deadline — " +
                    "indicates the bake's bromure-boot.service didn't fire. " +
                    "Verify setup-hcs.sh ran and systemd units are enabled. (" + tex.Message + ")");
            }
            catch (HcsException hex)
            {
                return (false, "HcsException 0x" + hex.HResult.ToString("X8") + ": " + hex.Message);
            }
            catch (Exception ex)
            {
                return (false, $"exception: {ex.GetType().Name}: {ex.Message}");
            }
        }).ConfigureAwait(false);
    }

    // ─────────────────────────────────────────────────────────────
    //  Plumbing
    // ─────────────────────────────────────────────────────────────

    /// <summary>Create a fresh fixed-size parent VHDX. Doesn't require
    /// Hyper-V — VHDX is a file format. Used by phase 3 only.</summary>
    private static bool CreateParentVhdx(string path, long sizeBytes, out string msg)
    {
        var storageType = new VirtDiskApi.VIRTUAL_STORAGE_TYPE
        {
            DeviceId = VirtDiskApi.VIRTUAL_STORAGE_TYPE_DEVICE_VHDX,
            VendorId = VirtDiskApi.VIRTUAL_STORAGE_TYPE_VENDOR_MICROSOFT,
        };
        // Explicit sector sizes — VHDX rejects 0/0 with INVALID_TYPE
        // on some Windows builds even though the docs claim defaults.
        var parameters = new VirtDiskApi.CREATE_VIRTUAL_DISK_PARAMETERS_V2
        {
            Version = VirtDiskApi.CREATE_VIRTUAL_DISK_VERSION.VERSION_2,
            UniqueId = Guid.NewGuid(),
            MaximumSize = (ulong)sizeBytes,
            BlockSizeInBytes = 0,                  // 0 → VHDX default (32 MB)
            SectorSizeInBytes = 512,
            PhysicalSectorSizeInBytes = 4096,
            ParentPath = IntPtr.Zero,
            SourcePath = IntPtr.Zero,
            OpenFlags = 0,
            ParentVirtualStorageType = default,
            SourceVirtualStorageType = default,
            ResiliencyGuid = Guid.Empty,
        };
        // NONE flag = dynamic VHDX (grow-on-write), the sane default
        // for tests. SPARSE_FILE was an NTFS-sparse flag that conflicts
        // with VHDX provisioning.
        int hr = VirtDiskApi.CreateVirtualDisk(
            ref storageType, path,
            VirtDiskApi.VIRTUAL_DISK_ACCESS_NONE,
            IntPtr.Zero,
            VirtDiskApi.CREATE_VIRTUAL_DISK_FLAG.NONE,
            providerSpecificFlags: 0,
            ref parameters, IntPtr.Zero, out IntPtr handle);
        if (hr != VirtDiskApi.ERROR_SUCCESS)
        {
            msg = $"CreateVirtualDisk(parent) failed: HRESULT 0x{hr:X8}";
            return false;
        }
        VirtDiskApi.CloseHandle(handle);
        msg = "";
        return true;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true,
        EntryPoint = "LoadLibraryW")]
    private static extern IntPtr LoadLibraryW(string lpFileName);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool FreeLibrary(IntPtr hModule);

    /// <summary>Tracks the per-phase result so summary + dependency
    /// gates can read it.</summary>
    private sealed class Report
    {
        public List<Result> Results { get; } = new();

        public async Task RunAsync(string phase, Func<Task<(bool ok, string detail)>> body)
        {
            Console.Write($"  [{phase}] … ");
            var sw = Stopwatch.StartNew();
            string status, detail;
            try
            {
                var (ok, msg) = await body().ConfigureAwait(false);
                status = ok ? "PASS" : (msg.StartsWith("skipped:") ? "SKIP" : "FAIL");
                detail = msg;
            }
            catch (Exception ex)
            {
                status = "FAIL";
                detail = "unhandled " + ex.GetType().Name + ": " + ex.Message;
            }
            sw.Stop();
            Console.WriteLine($"{status} ({sw.ElapsedMilliseconds} ms) — {detail}");
            Results.Add(new Result(phase, status, sw.ElapsedMilliseconds, detail));
        }

        public bool LastResultPassed(string phase) =>
            Results.LastOrDefault(r => r.Phase == phase)?.Status == "PASS";
    }

    private sealed record Result(string Phase, string Status, long ElapsedMs, string Detail);
}
