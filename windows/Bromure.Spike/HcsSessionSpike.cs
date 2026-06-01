using Bromure.SandboxEngine.Hcs;

namespace Bromure.Spike;

/// <summary>
/// End-to-end <see cref="HcsSession"/> exerciser. Replaces
/// <c>WslSessionSpike</c>. Resolves bake artefacts in
/// <paramref name="args"/>[0], creates a per-session VHDX clone,
/// boots an HCS VM with a synthetic home overlay + a small env file,
/// waits for the boot signal, tears down.
///
/// Usage: <c>bromure-spike hcs-session &lt;artefact-dir&gt;</c>
/// </summary>
public static class HcsSessionSpike
{
    public static async Task<int> RunAsync(string[] args)
    {
        if (args.Length < 1)
        {
            Console.Error.WriteLine("usage: bromure-spike hcs-session <artefact-dir>");
            return 2;
        }
        var artefacts = BakeArtefacts.InDirectory(args[0]);
        if (!artefacts.AllExist())
        {
            Console.Error.WriteLine(
                $"missing one of: {artefacts.BaseVhdxPath}, {artefacts.KernelPath}, {artefacts.InitrdPath}");
            return 2;
        }

        var sessionId = "bromure-spike-" + Guid.NewGuid().ToString("N")[..8];
        var installPath = Path.Combine(Path.GetTempPath(), sessionId);
        Console.WriteLine($"[hcs-session] vm-id: {sessionId}");
        Console.WriteLine($"[hcs-session] install: {installPath}");

        var cfg = new HcsSessionConfig
        {
            BaseVhdxPath = artefacts.BaseVhdxPath,
            KernelPath = artefacts.KernelPath,
            InitrdPath = artefacts.InitrdPath,
            VmId = sessionId,
            InstallPath = installPath,
            HomeFiles = new Dictionary<string, byte[]>(StringComparer.Ordinal)
            {
                [".bashrc"] = System.Text.Encoding.UTF8.GetBytes(
                    "# bromure-spike synthetic .bashrc\nexport BROMURE_SPIKE=1\n"),
            },
            EnvVars = new Dictionary<string, string>(StringComparer.Ordinal)
            {
                ["BROMURE_PROBE"] = "spike",
            },
            // Diagnostic: bypass UEFI/GRUB so we can swap in a verbose
            // serial-console cmdline without re-baking the VHDX.
            UseLinuxKernelDirect = true,
            // Ubuntu cloud-init image uses GPT: sda1=EFI, sda2=ext4 root.
            // Verbose serial + systemd console forwarding so we can see
            // unit start/fail messages on \\.\pipe\<vmid>-com1.
            KernelCmdLine =
                "root=/dev/sda2 rw rootfstype=ext4 console=ttyS0,115200 earlyprintk=ttyS0,115200 "
                + "loglevel=7 systemd.log_level=info systemd.log_target=console "
                + "systemd.show_status=true systemd.journald.forward_to_console=1",
        };

        // Open COM1's named pipe asynchronously — drain to stderr
        // so we see kernel + systemd output during the bring-up.
        var pipeName = sessionId + "-com1";
        var consoleLogPath = Path.Combine(installPath, "console.log");
        Directory.CreateDirectory(installPath);
        var pipeTask = Task.Run(async () =>
        {
            // Wait up to 60 s for Hyper-V to create the pipe — Plan9 +
            // hvsocket service registration sometimes pushes the COM1
            // setup past 15 s on a cold HCS.
            for (int i = 0; i < 120; i++)
            {
                try
                {
                    var pipe = new System.IO.Pipes.NamedPipeClientStream(".", pipeName,
                        System.IO.Pipes.PipeDirection.In);
                    await pipe.ConnectAsync(500).ConfigureAwait(false);
                    Console.Error.WriteLine($"[com1] connected to \\\\.\\pipe\\{pipeName} after {(i + 1) * 0.5:F1}s");
                    using (pipe)
                    using (var logFile = File.Open(consoleLogPath, FileMode.Append, FileAccess.Write, FileShare.Read))
                    {
                        var buf = new byte[4096];
                        while (true)
                        {
                            int n = await pipe.ReadAsync(buf).ConfigureAwait(false);
                            if (n == 0) break;
                            Console.Error.Write(System.Text.Encoding.UTF8.GetString(buf, 0, n));
                            await logFile.WriteAsync(buf.AsMemory(0, n)).ConfigureAwait(false);
                            await logFile.FlushAsync().ConfigureAwait(false);
                        }
                    }
                    break;
                }
                catch (TimeoutException) { /* retry */ }
                catch (Exception ex) { Console.Error.WriteLine("[com1] " + ex.Message); break; }
            }
        });

        // Use a non-`await using` HcsSession so we can SKIP
        // DisposeAsync at the end — the differencing child
        // disk.vhdx persists, letting us mount it from WSL and
        // read /var/log/journal + /var/log/bromure-startup.log
        // after the VM stops.
        // CLI flag: --display opens a WPF window with Bromure.AC's
        // VncControl pointed at the host-side TCP→hvsocket bridge once
        // the boot signal arrives — the same path the real BromureAC
        // session window takes, validated standalone.
        bool launchMstsc = args.Contains("--display") || args.Contains("--launch-mstsc");
        var session = new HcsSession(cfg);
        // Dump the HCS schema so we can verify ComPorts + HvSocket are
        // requested before vmcompute touches it.
        try
        {
            var probeVmCfg = new HcsVmConfig
            {
                KernelPath = cfg.KernelPath,
                InitrdPath = cfg.InitrdPath,
                RootDiskPath = "<would-be-child>",
                ParentDiskPath = cfg.BaseVhdxPath,
                ComPort1PipeName = sessionId + "-com1",
                MemoryMB = cfg.MemoryMB,
                CpuCount = cfg.CpuCount,
                HvSocketPorts = new uint[] { cfg.RdpPort, cfg.BootSignalPort },
            };
            Console.Error.WriteLine("[hcs-session] expected HCS schema:");
            Console.Error.WriteLine("  " + Bromure.SandboxEngine.Hcs.Native.HcsSchema.Serialize(probeVmCfg.BuildSchema()));
        }
        catch { /* probe only */ }
        var ok = false;
        try
        {
            await session.StartAsync();
            Console.WriteLine("[hcs-session] up");
            Console.WriteLine(session.LastTimings);
            Console.WriteLine($"[hcs-session] RDP available at 127.0.0.1:{session.RdpTcpBridgePort}");
            ok = true;

            if (launchMstsc)
            {
                // Prefer the guest's real IP (via HCN NetworkAdapter)
                // over the hvsocket bridge — host→guest hvsocket SEND
                // hangs on this Windows build, so display traffic uses
                // plain TCP/IP instead.
                var (vncHost, vncPort) = !string.IsNullOrEmpty(session.GuestIpAddress)
                    ? (session.GuestIpAddress!, 5900)
                    : ("127.0.0.1", session.RdpTcpBridgePort);
                if (vncPort == 0)
                {
                    Console.Error.WriteLine("[hcs-session] no working VNC transport — skipping window");
                }
                else
                {
                    // Give Xvnc a beat to bind RFB inside the guest.
                    await Task.Delay(2_000).ConfigureAwait(false);
                    var displayThread = new System.Threading.Thread(() =>
                    {
                        try
                        {
                            var app = new System.Windows.Application
                            {
                                ShutdownMode = System.Windows.ShutdownMode.OnLastWindowClose,
                            };
                            var vnc = new Bromure.AC.Display.VncControl(vncHost, vncPort);
                            vnc.Disconnected += ex =>
                                Console.Error.WriteLine("[vnc-test] disconnected: " +
                                    (ex is null ? "<clean>" : ex.GetType().Name + ": " + ex.Message));
                            var win = new System.Windows.Window
                            {
                                Title = $"Bromure VNC test — {vncHost}:{vncPort}",
                                Width = 1300, Height = 850,
                                Background = System.Windows.Media.Brushes.Black,
                                Content = vnc,
                            };
                            win.Show();
                            Task.Run(async () =>
                            {
                                try { await vnc.ConnectAsync(); }
                                catch (Exception ex) { Console.Error.WriteLine("[vnc-test] connect threw: " + ex); }
                            });
                            app.Run();
                        }
                        catch (Exception ex)
                        {
                            Console.Error.WriteLine("[hcs-session] vnc test window threw: " + ex);
                        }
                    });
                    displayThread.SetApartmentState(System.Threading.ApartmentState.STA);
                    displayThread.IsBackground = true;
                    displayThread.Start();
                    Console.WriteLine($"[hcs-session] opened VncControl window against {vncHost}:{vncPort}");
                }
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[hcs-session] FAILED: {ex.Message}");
            await Task.Delay(2000).ConfigureAwait(false);
        }

        // Stop the VM (HCS terminate). The child VHDX survives in
        // the install dir because we do NOT call DisposeAsync.
        var aliveSec = launchMstsc ? 300 : 900;
        Console.Error.WriteLine($"[hcs-session] keeping VM up for {aliveSec} s — close the mstsc window or Ctrl-C to terminate early");
        await Task.Delay(aliveSec * 1000).ConfigureAwait(false);
        Console.Error.WriteLine("[hcs-session] terminating VM (preserving child VHDX) …");
        try { await session.ShutdownAsync(); } catch (Exception ex) { Console.Error.WriteLine("[hcs-session] terminate: " + ex.Message); }

        var childVhdx = Path.Combine(installPath, "disk.vhdx");
        Console.WriteLine();
        Console.WriteLine("[hcs-session] child VHDX preserved at: " + childVhdx);
        Console.WriteLine("[hcs-session] mount + read from WSL:");
        Console.WriteLine("  wsl -d Ubuntu-24.04 -u root -e bash -c " +
            "\"mount --bind / /; mkdir -p /mnt/child; " +
            "echo Mount the VHDX manually via wsl --mount + then ls /mnt/child\"");
        return ok ? 0 : 1;
    }
}
