using System.Text;

namespace Bromure.SandboxEngine.Qemu;

/// <summary>
/// Translates <see cref="QemuConfig"/> into the argv we hand to
/// <c>qemu-system-x86_64.exe</c>. Mirrors the device set
/// <c>UbuntuSandboxVM.swift</c> attaches to <c>VZVirtualMachineConfiguration</c>:
/// EFI boot, virtio-blk for disk, virtio-net (NAT/TAP), virtio-gpu,
/// virtio-rng, virtio-serial console, vhost-vsock-pci, virtio-9p-pci shares.
/// </summary>
public static class QemuCommandBuilder
{
    public static IReadOnlyList<string> Build(QemuConfig cfg)
    {
        var args = new List<string>
        {
            // --- Accelerator + machine -----------------------------------
            // WHPX exposes the same paravirtualized device set as KVM does
            // for QEMU on Linux; we ask for q35 + Hyper-V enlightenments.
            "-accel", "whpx",
            "-machine", "q35",
            // -cpu qemu64 is the WHPX-stable baseline. We previously
            // used `-cpu max,hv-relaxed=on,hv-vapic=on,hv-spinlocks=0x1fff`,
            // which:
            //   • exposed CPU features WHPX can't emulate (verified by
            //     `WHPX: Unexpected VP exit code 4` panics during BIOS
            //     real-mode startup), and
            //   • enabled KVM Hyper-V *enlightenments* — those tell a
            //     guest "you're running under Hyper-V, here are the
            //     enlightenments to use." On WHPX the host IS Hyper-V,
            //     so we'd be asking Hyper-V to expose Hyper-V to a
            //     guest under Hyper-V. WHPX bails.
            // qemu64 + no hv flags lets Alpine boot all the way to the
            // login prompt under SeaBIOS. Verified manually with the
            // exact command line this builder emits.
            // `kernel-irqchip=off` was also dropped — it isn't needed
            // on WHPX 1.0+ and contributed to the same panic class.
            "-cpu", "qemu64",
            "-smp", cfg.VCpus.ToString(),
            "-m", cfg.MemoryMib.ToString(),
        };

        // --- UEFI boot (when both code+vars present). When unset we fall
        // back to SeaBIOS which suits the spike (no firmware variables to
        // persist). Production paths always pass OVMF.
        if (!string.IsNullOrEmpty(cfg.OvmfCode) && !string.IsNullOrEmpty(cfg.OvmfVars))
        {
            args.AddRange([
                "-drive", $"if=pflash,format=raw,readonly=on,file={cfg.OvmfCode}",
                "-drive", $"if=pflash,format=raw,file={cfg.OvmfVars}",
            ]);
        }

        // --- Root disk: qcow2 overlay over base.qcow2. Optional in spike
        // mode where the caller boots from a live ISO instead.
        // Note: `cache=none` needs O_DIRECT-equivalent which is brittle
        // on NTFS — QEMU on Windows reports "Image is not in qcow2
        // format" instead of a real I/O error. Use the default
        // (writeback) cache; the WAL-style journaling in qcow2 plus
        // host fsync semantics give us enough integrity.
        if (!string.IsNullOrEmpty(cfg.DiskPath))
        {
            args.AddRange([
                "-drive", $"file={cfg.DiskPath},if=virtio,format={cfg.DiskFormat},aio=threads",
            ]);
        }

        if (!string.IsNullOrEmpty(cfg.BootIsoPath))
        {
            // `-cdrom` expands to `-drive file=...,if=ide,index=2,media=cdrom`.
            // We *can't* use `if=virtio,media=cdrom` like the disk path:
            // SeaBIOS doesn't recognise a virtio-blk device as a bootable
            // CD-ROM, so it silently falls through to "no bootable
            // device" and the guest never starts. IDE CD-ROM is the
            // shape both SeaBIOS and OVMF recognise + load ISOLINUX from.
            args.AddRange([
                "-cdrom", cfg.BootIsoPath,
                "-boot", "d",
            ]);
        }

        // --- Hardware essentials ------------------------------------
        args.AddRange([
            "-device", "virtio-rng-pci",
            "-device", "virtio-balloon-pci",
            "-device", "virtio-serial-pci",
            // USB controller + absolute-pointing tablet. With this the
            // guest receives absolute mouse coordinates, so the host
            // cursor never has to be grabbed/hidden — clicking into
            // the framebuffer doesn't make the host cursor disappear.
            // q35 doesn't ship a default USB controller; add xhci
            // explicitly. usb-tablet without xhci is a silent no-op.
            "-device", "qemu-xhci,id=xhci",
            "-device", "usb-tablet,bus=xhci.0",
        ]);

        // --- Cloud-init seed ISO (first boot only). -----------------------
        // Same fix as the boot ISO: SeaBIOS doesn't recognise virtio-blk
        // media=cdrom as a discoverable drive, but cloud-init scans for a
        // volume labelled "cidata" on any attached block device. IDE
        // CD-ROM works under both SeaBIOS and OVMF.
        if (!string.IsNullOrEmpty(cfg.CloudInitSeedIso))
        {
            args.Add("-drive");
            args.Add($"file={cfg.CloudInitSeedIso},if=ide,index=3,media=cdrom,readonly=on");
        }

        // --- Auxiliary ISO (e.g. setup.sh script ISO for the Alpine
        //     bake — replaces virtiofs/9p which the winget QEMU build
        //     ships with disabled). Always read-only. -----------------
        if (!string.IsNullOrEmpty(cfg.AuxIsoPath))
        {
            var idx = string.IsNullOrEmpty(cfg.CloudInitSeedIso) ? 3 : 4;
            args.Add("-drive");
            args.Add($"file={cfg.AuxIsoPath},if=ide,index={idx},media=cdrom,readonly=on");
        }

        // --- Direct kernel boot (Alpine netboot bake path). ------------
        if (!string.IsNullOrEmpty(cfg.DirectKernelPath))
        {
            args.Add("-kernel");
            args.Add(cfg.DirectKernelPath);
            if (!string.IsNullOrEmpty(cfg.DirectInitrdPath))
            {
                args.Add("-initrd");
                args.Add(cfg.DirectInitrdPath);
            }
            if (!string.IsNullOrEmpty(cfg.DirectKernelCmdline))
            {
                args.Add("-append");
                args.Add(cfg.DirectKernelCmdline);
            }
        }

        // --- Network. ---------------------------------------------------
        switch (cfg.Network)
        {
            case NetworkMode.UserNat:
                args.AddRange([
                    "-netdev", "user,id=net0,hostname=bromure-ac",
                    "-device", $"virtio-net-pci,netdev=net0,mac={cfg.MacAddress}",
                ]);
                break;
            case NetworkMode.Bridged:
                if (string.IsNullOrEmpty(cfg.TapAdapterName))
                {
                    throw new InvalidOperationException(
                        "Bridged mode requires QemuConfig.TapAdapterName");
                }
                args.AddRange([
                    "-netdev", $"tap,id=net0,ifname={cfg.TapAdapterName}",
                    "-device", $"virtio-net-pci,netdev=net0,mac={cfg.MacAddress}",
                ]);
                break;
        }

        // --- Display (or lack thereof). ---------------------------------
        switch (cfg.Display)
        {
            case DisplayMode.None:
                // *Not* `-nographic`. That's shorthand for
                // `-display none -serial mon:stdio`, which claims the
                // first serial port for the QEMU monitor + stdio. If
                // we then add our own `-serial tcp:...`, it lands on
                // the *second* serial port (ttyS1 in the guest), and
                // setup.sh — which writes to ttyS0 — would be invisible
                // to our SerialConsoleClient. Burnt by this once;
                // headless mode now uses `-display none` only.
                args.AddRange(["-display", "none"]);
                break;
            case DisplayMode.VirtioGpuSoftware:
                args.AddRange([
                    "-device", "virtio-gpu-pci,xres=1920,yres=1200",
                    "-display", "none",  // host-side rendering via fb-agent
                ]);
                break;
            case DisplayMode.VirtioGpuGl:
                args.AddRange([
                    "-device", "virtio-gpu-gl-pci",
                    "-display", "none",
                ]);
                break;
            case DisplayMode.LocalSdl:
                // Don't pair `virtio-gpu-pci` with SDL on WHPX — that
                // combination crashes the guest with 0xC0000005
                // (STATUS_ACCESS_VIOLATION) at boot on at least
                // Windows 11 Pro + winget QEMU 11. Plain default VGA
                // (`-vga std`, implicit on q35) renders fine through
                // SDL and survives both BIOS and UEFI boot. Cost:
                // no 3D, no resize-on-the-fly. Acceptable for v0
                // since we don't need either yet.
                args.AddRange(["-vga", "std", "-display", "sdl"]);
                break;
            case DisplayMode.LocalGtk:
                // show-menubar=off drops the QEMU/View/Machine GTK menu
                // strip; without it the toplevel client area carries
                // ~30 px of widget chrome that we'd have to clip past.
                // zoom-to-fit=on lets QEMU rescale the framebuffer to
                // whatever size we set when reparenting, instead of the
                // user dragging the window bigger than the embed.
                // grab-on-hover=on auto-grabs the keyboard when the
                // mouse pointer enters the framebuffer, so the user
                // doesn't have to click first to start typing — that's
                // the macOS-native "feels like a desktop app, not a
                // VM" experience.
                args.AddRange(["-vga", "std",
                    "-display", "gtk,show-menubar=off,zoom-to-fit=on,grab-on-hover=on,show-cursor=on"]);
                break;
        }

        // --- vsock (vhost-vsock-pci). -----------------------------------
        // QEMU exposes the host side as a Unix-domain socket on Linux/macOS;
        // on Windows we bridge guest <-> named pipe in VsockBridge.
        // The MSYS2 QEMU+winget build ships WITHOUT vsock — only KVM
        // builds include it. Phase-0 Risk 1's B-plan is to tunnel the
        // bridge ports over TCP-on-NAT instead (the wire format above
        // is socket-agnostic — newline-delimited JSON over a Stream).
        if (cfg.EnableVsock)
        {
            args.AddRange([
                "-device", $"vhost-vsock-pci,guest-cid={cfg.GuestCid}",
            ]);
        }

        // --- 9p file shares. --------------------------------------------
        for (var i = 0; i < cfg.Shares.Count; i++)
        {
            var s = cfg.Shares[i];
            var id = $"fs{i}";
            var ro = s.ReadOnly ? ",readonly=on" : "";
            args.AddRange([
                "-fsdev", $"local,id={id},path={QuotePath(s.HostPath)},security_model={s.SecurityModel}{ro}",
                "-device", $"virtio-9p-pci,fsdev={id},mount_tag={s.MountTag}",
            ]);
        }

        // --- QMP control. -----------------------------------------------
        args.AddRange([
            "-qmp", $"{cfg.QmpEndpoint},server=on,wait=off",
            "-no-shutdown",   // the supervisor decides what to do on guest shutdown.
        ]);

        // --- Guest serial console over TCP (debug aid pre-fb-agent). ----
        // QEMU listens on the configured host:port; the guest's first
        // serial device (ttyS0 on Linux) routes through this. Alpine
        // virt's default cmdline already sets `console=ttyS0,115200n8`
        // so kernel boot + login prompt come through without further
        // config.
        if (!string.IsNullOrEmpty(cfg.SerialEndpoint))
        {
            args.AddRange([
                "-serial", $"tcp:{cfg.SerialEndpoint},server=on,wait=off,nodelay",
            ]);
        }

        // --- Stable RTC + nodefaults. -----------------------------------
        args.AddRange([
            "-rtc", "base=utc,clock=host",
            "-nodefaults",
        ]);

        // NB: do not pass `-D <logfile>` — that asks QEMU to open the
        // file itself, which races with the supervisor's StreamWriter
        // also writing to the same path (capturing redirected stderr).
        // QEMU's default behaviour (log to stderr) is exactly what we
        // want; the supervisor's `RedirectStandardError` pipe + the
        // tee'd file are the canonical capture path.

        return args;
    }

    /// QEMU's option syntax uses commas as separators, so a Windows path
    /// containing a comma would tokenise wrong. There aren't supposed to
    /// be commas in our managed paths, but defensive-quote anyway.
    private static string QuotePath(string p)
    {
        if (!p.Contains(',')) return p;
        return p.Replace(",", ",,");
    }

    /// Renders the full command line as it would be logged. Used by the
    /// supervisor for diagnostics — never for shell invocation (we always
    /// spawn QEMU via Process.Start with an argv list to avoid quoting bugs).
    public static string ToDiagnosticString(string exe, IReadOnlyList<string> args)
    {
        var sb = new StringBuilder(256);
        sb.Append('"').Append(exe).Append('"');
        foreach (var a in args)
        {
            sb.Append(' ');
            if (a.Contains(' ') || a.Contains('"'))
            {
                sb.Append('"').Append(a.Replace("\"", "\\\"")).Append('"');
            }
            else
            {
                sb.Append(a);
            }
        }
        return sb.ToString();
    }
}
