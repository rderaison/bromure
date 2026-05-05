using System.CommandLine;
using System.Diagnostics;
using Bromure.Platform;
using Bromure.SandboxEngine.Disk;
using Bromure.SandboxEngine.Image;
using Bromure.SandboxEngine.Qemu;
using Bromure.SandboxEngine.Vsock;
using Microsoft.Extensions.Logging;

namespace Bromure.Spike;

/// <summary>
/// Phase 0 spike harness — the single C# console exe that drives:
///   1. spawn QEMU + boot a minimal Linux image
///   2. open QMP, monitor lifecycle events
///   3. open a vsock named-pipe bridge, measure round-trip
///   4. tear down cleanly
///
/// Five gates per WIN32_AC_PLAN.md §9 (fail-fast, exit 1 on any miss):
///   gate 1: vsock-on-QEMU+WHPX round-trip (lat &lt;50 ms p95)
///   gate 2: qcow2 backing-file boot timing (≤1.5 s create)
///   gate 3: framebuffer + typing latency (≤30 ms keystroke-to-glyph p95)
///   gate 4: virtio-9p throughput (≥200 MB/s)
///   gate 5: installer end-to-end (out-of-process; tracked separately)
/// </summary>
internal static class Program
{
    public static async Task<int> Main(string[] args)
    {
        var qemuOpt = new Option<string>(
            ["--qemu"],
            description: "Path to qemu-system-x86_64.exe",
            getDefaultValue: () => DefaultQemu());
        var qemuImgOpt = new Option<string>(
            ["--qemu-img"],
            description: "Path to qemu-img.exe",
            getDefaultValue: () => DefaultQemuImg());
        var ovmfCodeOpt = new Option<string?>(
            ["--ovmf-code"],
            description: "Path to OVMF_CODE.fd (optional; SeaBIOS used if omitted)",
            getDefaultValue: () => DefaultOvmfCode());
        var ovmfVarsOpt = new Option<string?>(
            ["--ovmf-vars"],
            description: "Path to OVMF_VARS template (paired with --ovmf-code)",
            getDefaultValue: () => DefaultOvmfVars());
        var baseImgOpt = new Option<string?>(
            ["--base-image"],
            description: "Path to a qcow2 base image (optional if --boot-iso is set)");
        var bootIsoOpt = new Option<string?>(
            ["--boot-iso"],
            description: "Path to a bootable ISO (Alpine virt etc.) for the spike");
        var workOpt = new Option<string>(
            ["--work"],
            description: "Working directory for session disks + logs",
            getDefaultValue: () => Path.Combine(Path.GetTempPath(), "bromure-spike"));
        var qmpPortOpt = new Option<int>(
            ["--qmp-port"],
            description: "QMP TCP port on 127.0.0.1",
            getDefaultValue: () => 4444);
        var headlessOpt = new Option<bool>(
            ["--headless"],
            description: "Suppress all guest display devices",
            getDefaultValue: () => true);
        var graceOpt = new Option<int>(
            ["--grace-seconds"],
            description: "Total seconds to keep the VM up before shutting down",
            getDefaultValue: () => 30);

        var root = new RootCommand("Bromure AC Phase-0 spike harness")
        {
            qemuOpt, qemuImgOpt, ovmfCodeOpt, ovmfVarsOpt, baseImgOpt, bootIsoOpt,
            workOpt, qmpPortOpt, headlessOpt, graceOpt,
        };

        var exitCode = 0;
        root.SetHandler(async ctx =>
        {
            exitCode = await RunAsync(
                qemu: ctx.ParseResult.GetValueForOption(qemuOpt)!,
                qemuImg: ctx.ParseResult.GetValueForOption(qemuImgOpt)!,
                ovmfCode: ctx.ParseResult.GetValueForOption(ovmfCodeOpt),
                ovmfVars: ctx.ParseResult.GetValueForOption(ovmfVarsOpt),
                baseImage: ctx.ParseResult.GetValueForOption(baseImgOpt),
                bootIso: ctx.ParseResult.GetValueForOption(bootIsoOpt),
                workRoot: ctx.ParseResult.GetValueForOption(workOpt)!,
                qmpPort: ctx.ParseResult.GetValueForOption(qmpPortOpt),
                headless: ctx.ParseResult.GetValueForOption(headlessOpt),
                graceSeconds: ctx.ParseResult.GetValueForOption(graceOpt)).ConfigureAwait(false);
        });

        // `bake` subcommand: drive AlpineInstaller headlessly so we can verify
        // the base-image bake without touching the GUI. Streams progress
        // and serial bytes to stdout. Same code path the BakeOverlay UI
        // hits; the difference is observability — here failures are
        // immediate text, not a modal that vanishes when the user clicks
        // Close.
        var bakeCmd = new Command("bake", "Run the Ubuntu base image bake headlessly");
        bakeCmd.SetHandler(async _ =>
        {
            exitCode = await RunBakeAsync().ConfigureAwait(false);
        });
        root.AddCommand(bakeCmd);

        // `session` subcommand: boot the existing ubuntu-base.qcow2 in a
        // throwaway CoW overlay with the per-launch metadata ISO
        // attached, serial captured to stdout, no display. Shorter
        // path than launching the WPF app — used to verify
        // autologin / xinitrc / bromure-meta-mount.service end-to-end
        // from the command line.
        var sessionCmd = new Command("session", "Boot the baked image headlessly with metadata ISO");
        var sessionGraceOpt = new Option<int>(
            ["--seconds"], description: "How long to keep the session up before SIGTERM",
            getDefaultValue: () => 60);
        var sessionShareOpt = new Option<string?>(
            ["--share-path"], description: "Host path to share into the VM via sshfs (mounts at /mnt/bromure-share-1)");
        sessionCmd.AddOption(sessionGraceOpt);
        sessionCmd.AddOption(sessionShareOpt);
        sessionCmd.SetHandler(async ctx =>
        {
            exitCode = await RunSessionAsync(
                graceSeconds: ctx.ParseResult.GetValueForOption(sessionGraceOpt),
                sharePath: ctx.ParseResult.GetValueForOption(sessionShareOpt)
            ).ConfigureAwait(false);
        });
        root.AddCommand(sessionCmd);

        // `wsl` subcommand: smoke-test the WSL2 lifecycle wrapper
        // against a real rootfs tarball. Exists so we can verify
        // ImportAsync / LaunchAsync / UnregisterAsync end-to-end
        // outside the GUI before wiring them into the host shell.
        var wslCmd = new Command("wsl", "Smoke-test WslDistro lifecycle against a rootfs tarball");
        var wslRootfsArg = new Argument<string>("rootfs",
            "Path to a rootfs tarball (.tar/.tar.gz/.tar.xz/.vhdx)");
        wslCmd.AddArgument(wslRootfsArg);
        wslCmd.SetHandler(async ctx =>
        {
            exitCode = await WslSpike.RunAsync(
                new[] { ctx.ParseResult.GetValueForArgument(wslRootfsArg) }
            ).ConfigureAwait(false);
        });
        root.AddCommand(wslCmd);

        // `bake-wsl` subcommand: drive RootfsBaker headlessly to produce
        // bromure-base.tar.gz. Stdout streams progress + the in-distro
        // setup output. The bake takes ~5-10 min on a fresh source rootfs;
        // exit non-zero if setup-wsl.sh emits SANDBOX_SETUP_FAILED.
        var bakeWslCmd = new Command("bake-wsl",
            "Bake bromure-base.tar.gz from a source rootfs (WSL2)");
        var bakeSourceArg = new Argument<string>("source",
            "Path to a source rootfs tarball (e.g. wsl --export Ubuntu-24.04 …)");
        var bakeOutputArg = new Argument<string>("output",
            "Path where bromure-base.tar.gz will be written");
        bakeWslCmd.AddArgument(bakeSourceArg);
        bakeWslCmd.AddArgument(bakeOutputArg);
        bakeWslCmd.SetHandler(async ctx =>
        {
            exitCode = await WslBakeSpike.RunAsync(new[]
            {
                ctx.ParseResult.GetValueForArgument(bakeSourceArg),
                ctx.ParseResult.GetValueForArgument(bakeOutputArg),
            }).ConfigureAwait(false);
        });
        root.AddCommand(bakeWslCmd);

        // `wsl-session` subcommand: end-to-end exercise of WslSession —
        // import a baked rootfs, drop a synthetic home overlay, run a
        // probe command inside, tear down. Verifies the FS overlay,
        // env injection, and lifecycle work against the real bake.
        var wslSessionCmd = new Command("wsl-session",
            "End-to-end exercise of WslSession against a baked rootfs");
        var sesRootfsArg = new Argument<string>("rootfs",
            "Path to bromure-base.tar.gz (output of bake-wsl)");
        wslSessionCmd.AddArgument(sesRootfsArg);
        wslSessionCmd.SetHandler(async ctx =>
        {
            exitCode = await WslSessionSpike.RunAsync(new[]
            {
                ctx.ParseResult.GetValueForArgument(sesRootfsArg),
            }).ConfigureAwait(false);
        });
        root.AddCommand(wslSessionCmd);

        await root.InvokeAsync(args).ConfigureAwait(false);
        return exitCode;
    }

    private static async Task<int> RunSessionAsync(int graceSeconds, string? sharePath = null)
    {
        using var loggerFactory = LoggerFactory.Create(b =>
        {
            b.AddSimpleConsole(o => { o.SingleLine = true; o.TimestampFormat = "HH:mm:ss.fff "; });
            b.SetMinimumLevel(LogLevel.Debug);
        });
        var log = loggerFactory.CreateLogger("session");

        var paths = new Bromure.Platform.WindowsAppPaths();
        var basePath = Path.Combine(paths.ImagesDirectory,
            Bromure.SandboxEngine.Image.AlpineInstaller.OutputBaseFileName);
        if (!File.Exists(basePath))
        {
            log.LogError("ubuntu-base.qcow2 not found — run `bromure-spike bake` first.");
            return 2;
        }

        Bromure.SandboxEngine.Qemu.QemuPaths.Resolution qemu;
        try { qemu = Bromure.SandboxEngine.Qemu.QemuPaths.Resolve(); }
        catch (FileNotFoundException ex) { log.LogError("QEMU not found: {Msg}", ex.Message); return 2; }
        log.LogInformation("QEMU: {Path} ({Source})", qemu.ExecutablePath, qemu.Source);

        var sessionRoot = Path.Combine(paths.SessionsDirectory, "spike-session");
        Directory.CreateDirectory(sessionRoot);
        var overlay = Path.Combine(sessionRoot, "session.qcow2");
        try { File.Delete(overlay); } catch (IOException) { }

        var qemuImg = Path.Combine(Path.GetDirectoryName(qemu.ExecutablePath)!, "qemu-img.exe");
        using (var p = Process.Start(new ProcessStartInfo
        {
            FileName = qemuImg, UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardError = true, RedirectStandardOutput = true,
            ArgumentList = { "create", "-f", "qcow2", "-F", "qcow2", "-b", basePath,
                             "-o", "cluster_size=65536", overlay },
        })!) { await p.WaitForExitAsync().ConfigureAwait(false); }

        var metaIso = Path.Combine(sessionRoot, "bromure-meta.iso");
        try { File.Delete(metaIso); } catch (IOException) { }

        Bromure.SandboxEngine.Sharing.FolderShareServer? shareServer = null;
        string? shareJson = null;
        string? shareKey = null;
        if (!string.IsNullOrEmpty(sharePath))
        {
            shareServer = new Bromure.SandboxEngine.Sharing.FolderShareServer(paths, sessionRoot, log);
            if (shareServer.IsAvailable)
            {
                try
                {
                    var shares = new[]
                    {
                        new Bromure.SandboxEngine.Sharing.FolderShareServer.FolderShare(
                            "/mnt/bromure-share-1", sharePath),
                    };
                    var auth = await shareServer.StartAsync(shares).ConfigureAwait(false);
                    shareKey = auth.GuestPrivateKey;
                    shareJson = $"{{\"ssh\":{{\"host\":\"10.0.2.2\",\"port\":{auth.Port},\"user\":\"{Environment.UserName}\"}},\"shares\":[{{\"guest_path\":\"/mnt/bromure-share-1\",\"host_path\":\"{Bromure.SandboxEngine.Sharing.Msys2Path.From(sharePath)}\",\"read_only\":false}}]}}";
                    log.LogInformation("share server up — port {Port}, host path {Path}", auth.Port, sharePath);
                }
                catch (Exception ex)
                {
                    log.LogError(ex, "FolderShareServer start failed; continuing without share");
                    await shareServer.DisposeAsync().ConfigureAwait(false);
                    shareServer = null;
                }
            }
            else
            {
                log.LogWarning("MSYS2 sshd not available — share-path ignored");
                shareServer = null;
            }
        }

        Bromure.SandboxEngine.Image.SessionMetadataIso.Write(metaIso,
            new Dictionary<string, string>
            {
                ["BROMURE_PROFILE_ID"] = "00000000-0000-0000-0000-000000000001",
                ["BROMURE_SESSION_HOST"] = "windows",
                ["BROMURE_SMOKE_TEST"] = "true",
            },
            shareConfigJson: shareJson,
            sshPrivateKey: shareKey);

        var qmpPort = 4700 + Random.Shared.Next(0, 50);
        var serialPort = 5700 + Random.Shared.Next(0, 50);
        var cfg = new Bromure.SandboxEngine.Qemu.QemuConfig
        {
            QemuExecutable = qemu.ExecutablePath,
            DiskPath = overlay,
            AuxIsoPath = metaIso,
            VCpus = 2,
            MemoryMib = 2048,
            QmpEndpoint = $"tcp:127.0.0.1:{qmpPort}",
            SerialEndpoint = $"127.0.0.1:{serialPort}",
            Display = Bromure.SandboxEngine.Qemu.DisplayMode.None,
            Network = Bromure.SandboxEngine.Qemu.NetworkMode.UserNat,
            StderrLogFile = Path.Combine(sessionRoot, "qemu.log"),
        };

        await using var supervisor = new Bromure.SandboxEngine.Qemu.QemuSupervisor(cfg, log);
        await supervisor.StartAsync().ConfigureAwait(false);
        log.LogInformation("QEMU PID {Pid}; capturing serial for {Sec}s", supervisor.Process.Id, graceSeconds);

        await using var serial = new Bromure.SandboxEngine.Qemu.SerialConsoleClient(
            cfg.SerialEndpoint!, chunk => Console.Write(chunk), log);
        await serial.StartAsync(TimeSpan.FromSeconds(15)).ConfigureAwait(false);

        await Task.Delay(TimeSpan.FromSeconds(graceSeconds)).ConfigureAwait(false);

        await supervisor.ShutdownAsync(grace: TimeSpan.FromSeconds(15)).ConfigureAwait(false);
        if (shareServer is not null)
        {
            await shareServer.DisposeAsync().ConfigureAwait(false);
        }
        log.LogInformation("session test ended.");
        return 0;
    }

    private static async Task<int> RunBakeAsync()
    {
        using var loggerFactory = LoggerFactory.Create(b =>
        {
            b.AddSimpleConsole(o => { o.SingleLine = true; o.TimestampFormat = "HH:mm:ss.fff "; });
            b.SetMinimumLevel(LogLevel.Debug);
        });
        var log = loggerFactory.CreateLogger("bake");

        var paths = new WindowsAppPaths();
        Directory.CreateDirectory(paths.ImagesDirectory);
        Directory.CreateDirectory(paths.AppDataRoot);

        QemuPaths.Resolution qemu;
        try { qemu = QemuPaths.Resolve(); }
        catch (FileNotFoundException ex)
        {
            log.LogError("QEMU not found: {Msg}", ex.Message);
            return 2;
        }
        log.LogInformation("QEMU: {Path}", qemu.ExecutablePath);

        var images = new ImageManager(paths, log);
        var alpine = new AlpineNetboot(paths, log);
        var baker = new AlpineInstaller(paths, alpine, qemu, log);

        log.LogInformation("ResultPath: {Path}", baker.ResultPath);
        log.LogInformation("IsBaked: {Baked}", baker.IsBaked);

        // Always start clean — the user's baseline test premise is "kick
        // off a fresh bake and watch what happens." Leaving stale work-dir
        // state masks regressions.
        var bakeWorkDir = Path.Combine(paths.ImagesDirectory, "ubuntu-bake");
        if (Directory.Exists(bakeWorkDir))
        {
            log.LogInformation("Cleaning prior bake dir: {Dir}", bakeWorkDir);
            try { Directory.Delete(bakeWorkDir, recursive: true); }
            catch (IOException ex) { log.LogWarning("(could not clean: {Msg})", ex.Message); }
        }
        if (File.Exists(baker.ResultPath))
        {
            log.LogInformation("Removing prior baked image: {Path}", baker.ResultPath);
            try { File.Delete(baker.ResultPath); }
            catch (IOException ex) { log.LogWarning("(could not delete: {Msg})", ex.Message); }
        }

        var lastFraction = 0.0;
        var progress = new Progress<AlpineInstaller.BakeProgress>(p =>
        {
            // Throttle progress bar updates; serial output flows through
            // ConsoleAppend separately and we never throttle that.
            if (!string.IsNullOrEmpty(p.ConsoleAppend))
            {
                Console.Write(p.ConsoleAppend);
            }
            if (p.Fraction - lastFraction >= 0.01 || p.Stage != "install")
            {
                Console.WriteLine();
                Console.WriteLine($">>> [{p.Stage}] {p.Message} ({p.Fraction:P1})");
                lastFraction = p.Fraction;
            }
        });

        var sw = Stopwatch.StartNew();
        try
        {
            await baker.BakeAsync(progress).ConfigureAwait(false);
            sw.Stop();
            log.LogInformation("Bake complete in {Sec:F1}s", sw.Elapsed.TotalSeconds);
            log.LogInformation("Output: {Path} ({Mb:F0} MB)",
                baker.ResultPath, new FileInfo(baker.ResultPath).Length / 1024.0 / 1024.0);
            return 0;
        }
        catch (Exception ex)
        {
            sw.Stop();
            log.LogError("Bake FAILED after {Sec:F1}s: {Msg}", sw.Elapsed.TotalSeconds, ex.Message);
            log.LogError("Full exception: {Ex}", ex);
            return 1;
        }
    }

    private static string DefaultQemu()
    {
        return ResolveOnPath("qemu-system-x86_64.exe")
            ?? @"C:\Program Files\qemu\qemu-system-x86_64.exe";
    }

    private static string DefaultQemuImg()
    {
        return ResolveOnPath("qemu-img.exe")
            ?? @"C:\Program Files\qemu\qemu-img.exe";
    }

    private static string? DefaultOvmfCode()
    {
        var p = @"C:\Program Files\qemu\share\edk2-x86_64-code.fd";
        return File.Exists(p) ? p : null;
    }

    private static string? DefaultOvmfVars()
    {
        // QEMU 11 ships only edk2-i386-vars.fd; it pads alongside
        // edk2-x86_64-code.fd to 4 MiB total flash (3.5 + 0.5).
        var p = @"C:\Program Files\qemu\share\edk2-i386-vars.fd";
        return File.Exists(p) ? p : null;
    }

    private static string? ResolveOnPath(string exe)
    {
        var pathEnv = Environment.GetEnvironmentVariable("PATH");
        if (pathEnv is null) return null;
        foreach (var dir in pathEnv.Split(Path.PathSeparator))
        {
            try
            {
                var candidate = Path.Combine(dir, exe);
                if (File.Exists(candidate)) return candidate;
            }
            catch (ArgumentException) { /* malformed PATH entry */ }
        }
        return null;
    }

    private static async Task<int> RunAsync(
        string qemu, string qemuImg, string? ovmfCode, string? ovmfVars,
        string? baseImage, string? bootIso, string workRoot,
        int qmpPort, bool headless, int graceSeconds)
    {
        using var loggerFactory = LoggerFactory.Create(b =>
        {
            b.AddSimpleConsole(o => { o.SingleLine = true; o.TimestampFormat = "HH:mm:ss.fff "; });
            b.SetMinimumLevel(LogLevel.Debug);
        });
        var log = loggerFactory.CreateLogger("spike");

        Directory.CreateDirectory(workRoot);
        var sessionRoot = Path.Combine(workRoot, "session-" + DateTimeOffset.UtcNow.ToUnixTimeSeconds());
        Directory.CreateDirectory(sessionRoot);
        log.LogInformation("Session work dir: {Dir}", sessionRoot);

        string? perSessionVars = null;
        if (!string.IsNullOrEmpty(ovmfCode) && !string.IsNullOrEmpty(ovmfVars))
        {
            perSessionVars = Path.Combine(sessionRoot, "OVMF_VARS.fd");
            File.Copy(ovmfVars, perSessionVars, overwrite: true);
            log.LogInformation("UEFI mode: OVMF_CODE={Code} OVMF_VARS={Vars}", ovmfCode, perSessionVars);
        }
        else
        {
            log.LogInformation("BIOS mode: SeaBIOS (no OVMF firmware passed)");
        }

        // --- Gate 2: qcow2 overlay creation timing ----------------------
        // Skipped if the spike is booting from a live ISO instead.
        bool? gate2 = null;
        double overlayMs = 0;
        EphemeralDisk? ephemeral = null;
        string? overlayPath = null;
        if (!string.IsNullOrEmpty(baseImage))
        {
            ephemeral = new EphemeralDisk(qemuImg);
            overlayPath = Path.Combine(sessionRoot, "session.qcow2");
            var sw = Stopwatch.StartNew();
            await ephemeral.EnsureExistsAsync(baseImage, overlayPath).ConfigureAwait(false);
            sw.Stop();
            overlayMs = sw.Elapsed.TotalMilliseconds;
            gate2 = overlayMs <= 1500;
            log.LogInformation("Gate 2 — overlay create: {Ms:F1} ms ({Pass})",
                overlayMs, gate2.Value ? "PASS" : "FAIL");
        }
        else if (!string.IsNullOrEmpty(bootIso))
        {
            log.LogInformation("Gate 2 — overlay create: SKIPPED (booting ISO {Iso})", bootIso);
        }
        else
        {
            log.LogError("Either --base-image or --boot-iso must be specified");
            return 2;
        }

        // --- Build QEMU config + start --------------------------------
        var cfg = new QemuConfig
        {
            QemuExecutable = qemu,
            OvmfCode = ovmfCode,
            OvmfVars = perSessionVars,
            DiskPath = overlayPath,
            BootIsoPath = bootIso,
            VCpus = 2,
            MemoryMib = 2048,
            GuestCid = 3,
            Display = headless ? DisplayMode.None : DisplayMode.VirtioGpuSoftware,
            QmpEndpoint = $"tcp:127.0.0.1:{qmpPort}",
            Network = NetworkMode.UserNat,
        };
        var args = QemuCommandBuilder.Build(cfg);
        var commandLine = QemuCommandBuilder.ToDiagnosticString(qemu, args);

        // We log the command line first so a reviewer can copy-paste it
        // into a shell to reproduce the spike outside our supervisor.
        log.LogInformation("QEMU argv: {Argv}", commandLine);

        // The QEMU build that ships in winget is mingw — its `-qmp tcp:`
        // shorthand isn't recognised. Re-emit the QMP flag the way the
        // mingw build expects: a -chardev/-mon pair.
        // The supervisor doesn't *care* how the flag is shaped — we set
        // QmpEndpoint pointing at the same TCP host:port. Building the
        // canonical -qmp form keeps the contract simple.

        await using var supervisor = new QemuSupervisor(cfg, log);
        var ranSuccessfully = false;
        var qmpHandshakeOk = false;
        var bootSw = Stopwatch.StartNew();
        try
        {
            await supervisor.StartAsync().ConfigureAwait(false);
            qmpHandshakeOk = true;
            log.LogInformation("QMP connected; QEMU PID {Pid}", supervisor.Process.Id);

            // Hold the VM up for `graceSeconds` so a future fb-agent /
            // typing-latency probe has time to attach. For now this is
            // just a smoke test of the QEMU+QMP path.
            await Task.Delay(TimeSpan.FromSeconds(graceSeconds)).ConfigureAwait(false);
            ranSuccessfully = supervisor.IsRunning;
        }
        finally
        {
            bootSw.Stop();
            await supervisor.ShutdownAsync().ConfigureAwait(false);
        }
        var bootMs = bootSw.Elapsed.TotalMilliseconds;
        log.LogInformation("QEMU lifetime: {Ms:F1} ms ({State})",
            bootMs, ranSuccessfully ? "RUNNING" : "EXITED");

        // --- Summary table ---------------------------------------------
        Console.WriteLine();
        Console.WriteLine("=== Phase 0 spike summary ===");
        if (gate2 is { } g2)
        {
            Console.WriteLine($"  Gate 2 (qcow2 overlay create <= 1500 ms): {(g2 ? "PASS" : "FAIL")} - {overlayMs:F1} ms");
        }
        else
        {
            Console.WriteLine($"  Gate 2 (qcow2 overlay):                   SKIPPED (boot-iso mode)");
        }
        Console.WriteLine($"  QEMU process: {(ranSuccessfully ? "STAYED UP" : "EXITED EARLY")} ({bootMs:F0} ms)");
        Console.WriteLine($"  QMP handshake:                            {(qmpHandshakeOk ? "OK" : "FAIL")}");
        Console.WriteLine($"  Gate 1+3+4 (vsock / fb-agent / 9p):       DEFERRED - needs guest agents booted");
        Console.WriteLine($"  Gate 5 (installer):                       DEFERRED - out-of-process");
        Console.WriteLine();

        ephemeral?.Discard();

        var pass = ranSuccessfully && (gate2 ?? true);
        return pass ? 0 : 1;
    }
}
