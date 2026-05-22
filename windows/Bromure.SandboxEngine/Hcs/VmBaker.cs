// macos-source: Sources/SandboxEngine/LinuxImageManager.swift @ fe7e7d3a3e21
using System.Diagnostics;
using System.IO.Pipes;
using System.Net.Http;
using System.Reflection;
using System.Text;
using Bromure.SandboxEngine.Image;

namespace Bromure.SandboxEngine.Hcs;

/// <summary>
/// Bakes the Bromure base VHDX + matched kernel + initrd by booting a
/// transient Alpine installer inside a Hyper-V Gen2 VM and driving it
/// over a serial named pipe — exactly the shape the macOS port uses
/// (boot Alpine via VZLinuxBootLoader, drive setup.sh, capture the
/// installed kernel/initrd via a raw "transfer disk" protocol).
///
/// <para><b>Why Hyper-V management cmdlets for the bake, not direct
/// HCS.</b> The session VMs use HCS direct (<see cref="HcsVm"/>) —
/// cheap, no management plane, but no built-in network device. The
/// session rootfs is fully baked, so no network is needed at session
/// time. The bake itself runs <c>apk add</c> + <c>debootstrap</c> +
/// <c>apt-get install</c>: it needs internet. HCS-direct VMs would
/// require us to build an HCN endpoint by hand and attach it; Hyper-V
/// Gen2 VMs join Hyper-V's "Default Switch" (NAT) automatically. The
/// bake is one-shot, so paying the management-plane cost is worth
/// avoiding the HCN endpoint plumbing.</para>
///
/// <para><b>Cross-platform shape.</b>
/// <list type="bullet">
///   <item>macOS: VZLinuxBootLoader(alpine-vmlinuz, alpine-initramfs)
///         + VZNATNetworkDeviceAttachment + target/transfer raw img
///         files + VZ serial pipe.</item>
///   <item>Windows: PowerShell New-VM Gen2 with the alpine-virt ISO as
///         boot DVD + setup ISO as second DVD + target/transfer VHDX
///         + Default Switch (NAT) + Set-VMComPort named pipe.</item>
/// </list>
/// Same setup.sh runs in both — see Image/setup.sh, which now reads
/// TARGET_DEV from env so the host driver can pass /dev/sda for the
/// SCSI controller Hyper-V Gen2 attaches as.</para>
///
/// <para><b>Admin requirement.</b> New-VM, New-VHD, Mount-VHD,
/// Add-VMHardDiskDrive all require the local Administrators group.
/// Session use afterwards is HCS direct and does NOT need admin —
/// only the bake does.</para>
/// </summary>
public sealed class VmBaker
{
    public sealed record BakeProgress(string Stage, string Message, double Fraction);

    public const string OutputBaseFileName = "bromure-base.vhdx";
    public const string OutputKernelFileName = "vmlinuz";
    public const string OutputInitrdFileName = "initrd.img";

    /// <summary>Pinned Alpine virt ISO release. Bump to refresh.</summary>
    public const string AlpineRelease = "3.22.3";
    public const string AlpineMajor = "3.22";
    public static string AlpineIsoFileName => $"alpine-virt-{AlpineRelease}-x86_64.iso";
    public static string AlpineIsoUrl =>
        $"https://dl-cdn.alpinelinux.org/alpine/v{AlpineMajor}/releases/x86_64/" + AlpineIsoFileName;

    /// <summary>Target Ubuntu disk size — 16 GiB matches the macOS port's
    /// default. Big enough for Ubuntu + kitty + the agent toolchain
    /// + ~6 GiB of room for the user's home overlay at session time.</summary>
    public const long TargetVhdxSizeBytes = 16L * 1024 * 1024 * 1024;

    /// <summary>Transfer disk size — 256 MiB is the smallest VHDX
    /// Hyper-V will accept that still fits a typical 70-MiB
    /// initramfs + 12-MiB kernel + the 32-byte raw header.</summary>
    public const long TransferVhdxSizeBytes = 256L * 1024 * 1024;

    /// <summary>Bake-stage timeout. Alpine boot is ~30 s, setup.sh
    /// (apt + debootstrap + grub + agent install) typically 8–12 min
    /// on broadband + NVMe, extraction is ~10 s. 45 min ceiling
    /// matches the macOS port's wait-for SANDBOX_SETUP_DONE.</summary>
    private static readonly TimeSpan BakeTimeout = TimeSpan.FromMinutes(45);

    /// <summary>Name of the Hyper-V Internal switch we attach the bake
    /// VM to. Distinct from "Default Switch" so we own the NAT + IP
    /// scope independently of Windows' SharedAccess service.</summary>
    public const string BakeSwitchName = "bromure-bake-net";

    /// <summary>Subnet for <see cref="BakeSwitchName"/>. Picked to be
    /// unlikely to collide with home/office RFC1918 networks; we
    /// don't auto-rotate. If a user's LAN actually overlaps, they
    /// can delete the switch + NetNat and we'll re-create on next
    /// bake (handle that case explicitly if it comes up).</summary>
    public const string BakeSubnet = "192.168.50.0/24";
    public const string BakeHostIp = "192.168.50.1";
    public const string BakeGuestIp = "192.168.50.10";
    public const int BakeSubnetPrefix = 24;

    private static readonly HttpClient _http = new() { Timeout = TimeSpan.FromMinutes(20) };

    public async Task BakeAsync(
        string outputDir,
        IProgress<BakeProgress>? progress = null,
        CancellationToken ct = default)
    {
        Directory.CreateDirectory(outputDir);

        // No UAC elevation check. Every Hyper-V cmdlet we drive
        // (New-VM, New-VHD, Mount-VHD, Add-VMHardDiskDrive,
        // Set-VMComPort) accepts members of the Hyper-V Administrators
        // group, which Windows auto-adds the installing user to when
        // Hyper-V is enabled — and that membership is NOT subject to
        // UAC token filtering. We extract kernel + initrd via a
        // FAT-formatted transfer VHDX + drive-letter Copy-Item (NOT
        // a raw \\.\PhysicalDriveN read), so no elevated admin token
        // is needed. If a cmdlet does fail with access-denied, the
        // error surfaces from PowerShellAsync below.
        if (!IsHyperVCapable())
        {
            throw new InvalidOperationException(
                "BakeAsync needs Hyper-V Administrators group membership (or local " +
                "Administrators) to drive Hyper-V cmdlets. Enable-WindowsFeature " +
                "Hyper-V usually adds the installing user automatically; if you " +
                "enabled it for a different user, run as that user OR add yourself " +
                "via: `Add-LocalGroupMember -Group 'Hyper-V Administrators' " +
                "-Member $env:USERNAME` from an elevated PowerShell, then sign " +
                "out and back in.");
        }

        // Reap stale Bromure VMs before bake. The bake (and any
        // session VM that's based on the prior bake's VHDX) holds
        // the parent VHDX file open via its differencing-child
        // chain. If a previous AC run left an orphan compute system
        // attached, deleting bromure-base.vhdx to make room for the
        // new bake fails with ERROR_SHARING_VIOLATION no matter how
        // long we retry. This pre-bake reap is the only reliable
        // way to break that chain.
        progress?.Report(new BakeProgress("cleanup",
            "Reaping orphan Bromure VMs left from prior runs…", 0.005));
        await ReapOrphanBromureVmsAsync(outputDir, ct).ConfigureAwait(false);

        var bakeId = "bromure-bake-" + Guid.NewGuid().ToString("N")[..8];
        var stageDir = Path.Combine(outputDir, "bake-stage-" + bakeId);
        Directory.CreateDirectory(stageDir);
        var bakeLog = Path.Combine(stageDir, "bake.log");
        bool vmCreated = false;

        try
        {
            // 1. Cache or fetch alpine-virt ISO. ~60 MB. Same CDN the
            //    macOS port uses; we trust the URL's TLS chain since
            //    the user has already enabled Hyper-V (admin gate).
            progress?.Report(new BakeProgress("alpine",
                "Fetching Alpine virt ISO…", 0.02));
            var alpineIso = await EnsureAlpineIsoAsync(outputDir, progress, ct)
                .ConfigureAwait(false);

            // 2. Build setup.iso — a tiny ISO9660 carrying setup.sh.
            //    The Alpine guest mounts it as /dev/sr1 (second DVD)
            //    and execs the script.
            progress?.Report(new BakeProgress("setup-iso",
                "Building setup ISO…", 0.06));
            var setupIso = Path.Combine(stageDir, "setup.iso");
            BuildSetupIso(setupIso);

            // 3. Allocate target VHDX (16 GiB, raw) and transfer VHDX
            //    (256 MiB, pre-formatted FAT32). Target stays raw —
            //    setup.sh partitions + formats it as GPT/EFI/ext4
            //    inside the guest. Transfer is FAT32 so the host can
            //    read it back via a drive letter (no raw physical-disk
            //    access → no UAC elevation needed).
            progress?.Report(new BakeProgress("disks",
                "Allocating target + transfer VHDX (FAT32 for output)…", 0.10));
            var targetVhdx = Path.Combine(stageDir, "target.vhdx");
            var transferVhdx = Path.Combine(stageDir, "transfer.vhdx");
            await PowerShellAsync(
                "$ErrorActionPreference='Stop';" +
                $"New-VHD -Path '{targetVhdx}' -SizeBytes {TargetVhdxSizeBytes} -Dynamic | Out-Null;" +
                $"New-VHD -Path '{transferVhdx}' -SizeBytes {TransferVhdxSizeBytes} -Dynamic | Out-Null;" +
                // Pre-format the transfer VHDX as FAT32 with an MBR
                // partition. The guest mounts /dev/sdb1 (the lone FAT
                // partition) and writes vmlinuz + initrd.img as
                // regular files; the host reads them back via the
                // drive letter Mount-VHD assigns.
                $"$disk = Mount-VHD -Path '{transferVhdx}' -PassThru | Get-Disk;" +
                "Initialize-Disk -InputObject $disk -PartitionStyle MBR | Out-Null;" +
                "$part = New-Partition -InputObject $disk -UseMaximumSize -AssignDriveLetter -IsActive;" +
                "Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel 'BROMOUT' -Confirm:$false | Out-Null;" +
                $"Dismount-VHD -Path '{transferVhdx}';",
                bakeLog, ct).ConfigureAwait(false);

            // 4a. Stand up a bake-private NAT switch + NetNat. Default
            //     Switch's NAT depends on the SharedAccess (ICS)
            //     service, which gets disabled by VPN clients and
            //     occasional Windows updates — DHCP from the Default
            //     Switch then silently never responds. Our own
            //     Internal switch + NetNat is hermetic: known subnet,
            //     known gateway, static IP in the guest, no DHCP at
            //     all. Idempotent across re-runs.
            progress?.Report(new BakeProgress("net",
                "Setting up bake NAT switch (192.168.50.0/24)…", 0.12));
            await EnsureBakeNetworkAsync(bakeLog, ct).ConfigureAwait(false);

            // 4b. Build the Hyper-V Gen2 VM. Boot order: DVD (Alpine
            //     ISO) first; the firmware loads Alpine's UEFI
            //     bootloader, which boots vmlinuz-virt with
            //     console=ttyS0,115200n8 by default (virt-tuned).
            progress?.Report(new BakeProgress("vm-create",
                "Creating bake VM (Gen2)…", 0.14));
            var pipeName = bakeId + "-com1";
            await CreateBakeVmAsync(bakeId, alpineIso, setupIso, targetVhdx, transferVhdx,
                pipeName, bakeLog, ct).ConfigureAwait(false);
            vmCreated = true;

            // 5. Start the VM. Alpine boots from /dev/sr0; serial
            //    output streams to \\.\pipe\<pipeName>. We connect a
            //    NamedPipeSerialDriver concurrently to pump the
            //    console.
            progress?.Report(new BakeProgress("vm-start",
                "Starting bake VM…", 0.16));
            await PowerShellAsync(
                "Start-VM -Name '" + bakeId + "' -ErrorAction Stop",
                bakeLog, ct).ConfigureAwait(false);

            // 6. Attach the serial driver and drive Alpine through
            //    login → mount setup.iso → run setup.sh → dump
            //    kernel/initrd to /dev/sdb (transfer disk) → poweroff.
            await using (var serial = new NamedPipeSerialDriver(pipeName, onChunk: chunk =>
            {
                // Stream the guest's console into the progress UI's
                // log buffer so the user can watch boot + apt-get run.
                try { File.AppendAllText(Path.Combine(stageDir, "console.log"), chunk); }
                catch { }
                progress?.Report(new BakeProgress("console", chunk, double.NaN));
            }))
            {
                progress?.Report(new BakeProgress("serial",
                    "Attaching to bake VM's serial console…", 0.18));
                await serial.ConnectAsync(TimeSpan.FromSeconds(60), ct).ConfigureAwait(false);
                await DriveAlpineAsync(serial, progress, ct).ConfigureAwait(false);
            }

            // 7. Wait for the VM to fully stop (poweroff propagates
            //    through Hyper-V state). Up to 60 s after the serial
            //    driver saw the shutdown command.
            progress?.Report(new BakeProgress("shutdown",
                "Waiting for VM power-off…", 0.92));
            await WaitForVmStoppedAsync(bakeId, TimeSpan.FromMinutes(2), bakeLog, ct)
                .ConfigureAwait(false);

            // 8. Read kernel + initrd off the transfer VHDX. Mount-VHD
            //    surfaces it as \\.\PhysicalDriveN; we open that raw
            //    and pull bytes at the offsets setup.sh's dd wrote
            //    them to.
            progress?.Report(new BakeProgress("extract",
                "Reading kernel + initrd off transfer VHDX…", 0.94));
            var (kernelPath, initrdPath) = await ExtractBootFilesAsync(
                transferVhdx, stageDir, bakeLog, ct).ConfigureAwait(false);

            // 9. Detach transfer + target from the VM so we can move
            //    them without ERROR_SHARING_VIOLATION.
            progress?.Report(new BakeProgress("finalize",
                "Moving artefacts to images directory…", 0.97));
            await PowerShellAsync(
                "Remove-VM -Name '" + bakeId + "' -Force -ErrorAction SilentlyContinue",
                bakeLog, ct).ConfigureAwait(false);
            vmCreated = false;

            // 10. Move the target VHDX into place; rename extracted
            //     kernel/initrd to their canonical names.
            MoveArtefacts(outputDir, targetVhdx, kernelPath, initrdPath);
        }
        finally
        {
            if (vmCreated)
            {
                try
                {
                    await PowerShellAsync(
                        "Get-VM -Name '" + bakeId + "' -ErrorAction SilentlyContinue | " +
                        "Stop-VM -TurnOff -Force -ErrorAction SilentlyContinue",
                        bakeLog, CancellationToken.None).ConfigureAwait(false);
                    await PowerShellAsync(
                        "Remove-VM -Name '" + bakeId + "' -Force -ErrorAction SilentlyContinue",
                        bakeLog, CancellationToken.None).ConfigureAwait(false);
                }
                catch { /* best-effort */ }
            }
            // Leave stage dir on disk for post-mortem — small (the big
            // files have been moved out). User can delete manually if
            // they want.
        }

        progress?.Report(new BakeProgress("done", "Bake complete.", 1.0));
    }

    /// <summary>Drive Alpine's serial console through:
    ///   <c>login → root → mount /dev/sr1 → sh setup.sh → wait DONE
    ///   → write /dev/sdb header + kernel + initrd via dd → poweroff</c>.
    /// 1:1 with the macOS port's installLinux sequence, just talking
    /// to a Hyper-V COM-port named pipe instead of a VZ FileHandle.</summary>
    private static async Task DriveAlpineAsync(
        NamedPipeSerialDriver serial, IProgress<BakeProgress>? progress, CancellationToken ct)
    {
        progress?.Report(new BakeProgress("alpine",
            "Waiting for Alpine login prompt…", 0.20));
        await serial.WaitForAsync("localhost login:", TimeSpan.FromMinutes(3),
            failures: new[] { "Kernel panic", "Boot failed" }, ct).ConfigureAwait(false);

        progress?.Report(new BakeProgress("alpine",
            "Logging in as root…", 0.22));
        await serial.SendAsync("root\n", ct).ConfigureAwait(false);
        await serial.WaitForAsync("localhost:~#", TimeSpan.FromSeconds(30), null, ct)
            .ConfigureAwait(false);

        // Bring up networking with a STATIC IP — we own the switch's
        // subnet, so we don't need DHCP. The bake driver pre-created
        // a NetNat on 192.168.50.0/24 with the host at .1; the guest
        // takes .10, gateway .1, DNS via Cloudflare.
        //
        // Markers are emitted via shell variable expansion (echo
        // "${M}_OK") so the typed command text contains "${M}_OK"
        // — literal — while only the runtime output contains the
        // full "BROMURE_NET_OK" marker. Without this, the guest tty
        // echoes the typed bytes back and WaitForAsync false-positives
        // on the failure marker as soon as we Send the command.
        progress?.Report(new BakeProgress("alpine",
            "Configuring eth0 (static " + BakeGuestIp + " → NAT gateway " + BakeHostIp + ")…", 0.23));
        var netUp =
            "M=BROMURE_NET; " +
            "ip link set eth0 up 2>&1 || true; " +
            "ip addr flush dev eth0 2>&1 || true; " +
            "ip addr add " + BakeGuestIp + "/" + BakeSubnetPrefix + " dev eth0 || echo \"${M}_FAILED\"; " +
            "ip route add default via " + BakeHostIp + " || echo \"${M}_FAILED\"; " +
            "echo 'nameserver 1.1.1.1' > /etc/resolv.conf; " +
            "echo 'nameserver 1.0.0.1' >> /etc/resolv.conf; " +
            "ip -4 addr show eth0 | awk '/inet /{print \"BROMURE_IP=\"$2}'; " +
            "ip route show default | awk '/default/{print \"BROMURE_GW=\"$3}'; " +
            // Sanity check: can we reach the host's NAT? If New-NetNat
            // didn't apply (or the user's firewall blocks it),
            // outbound dies here and we fail fast instead of waiting
            // 5+ minutes for apk timeouts.
            "ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 && echo \"${M}_OK\" || echo \"${M}_NO_INTERNET\"\n";
        await serial.SendAsync(netUp, ct).ConfigureAwait(false);
        await serial.WaitForAsync("BROMURE_NET_OK", TimeSpan.FromSeconds(30),
            failures: new[] { "BROMURE_NET_FAILED", "BROMURE_NET_NO_INTERNET" }, ct)
            .ConfigureAwait(false);
        await serial.WaitForAsync("localhost:~#", TimeSpan.FromSeconds(10), null, ct)
            .ConfigureAwait(false);

        progress?.Report(new BakeProgress("alpine",
            "Mounting setup ISO (/dev/sr1)…", 0.24));
        // /dev/sr0 = Alpine boot ISO, /dev/sr1 = our setup ISO.
        await serial.SendAsync(
            "mkdir -p /tmp/setup && mount -t iso9660 -o ro /dev/sr1 /tmp/setup && ls /tmp/setup\n",
            ct).ConfigureAwait(false);
        await serial.WaitForAsync("setup.sh", TimeSpan.FromSeconds(20),
            failures: new[] { "mount: ", "No such device", "wrong fs type" }, ct)
            .ConfigureAwait(false);

        progress?.Report(new BakeProgress("install",
            "Running setup.sh (debootstrap + chroot + grub + agents) — this is the slow phase, 5–10 min…",
            0.28));
        // Two env vars the chroot phase of setup.sh reads:
        //   TARGET_DEV=/dev/sda — Hyper-V Gen2 attaches SCSI
        //     controllers as sda/sdb (vs macOS-VZ's vda).
        //   BROMURE_HOST=windows — flips on the weston-rdp +
        //     bromure-hvsock-proxy installation (HCS-direct VMs
        //     have no framebuffer, so the macOS-VZ X11+kitty
        //     stack would have nowhere to render). Without
        //     this, the chroot phase keeps the macOS path.
        await serial.SendAsync("export TARGET_DEV=/dev/sda\n", ct).ConfigureAwait(false);
        await serial.WaitForAsync("localhost:~#", TimeSpan.FromSeconds(5), null, ct)
            .ConfigureAwait(false);
        await serial.SendAsync("export BROMURE_HOST=windows\n", ct).ConfigureAwait(false);
        await serial.WaitForAsync("localhost:~#", TimeSpan.FromSeconds(5), null, ct)
            .ConfigureAwait(false);
        // Display scale = 2: matches macOS retina, matches our Xvnc
        // -geometry 2560x1600 default. Kitty font_size = 14 * scale
        // = 28, which lines up with the high-DPI Windows screens
        // most users will be on. Lower-DPI users get a downscale via
        // WPF (slightly fuzzier but readable).
        await serial.SendAsync("sh /tmp/setup/setup.sh 2\n", ct).ConfigureAwait(false);
        await serial.WaitForAsync("SANDBOX_SETUP_DONE", BakeTimeout,
            failures: new[] { "SANDBOX_SETUP_FAILED:" }, ct).ConfigureAwait(false);

        // After SANDBOX_SETUP_DONE, the target rootfs is unmounted but
        // the disks are still attached. Mount the target's rootfs and
        // the FAT32-formatted transfer disk, copy kernel + initrd as
        // regular files. The host reads them back via the drive
        // letter Mount-VHD assigns — no raw \\.\PhysicalDriveN access,
        // no UAC elevation needed.
        progress?.Report(new BakeProgress("extract",
            "Copying kernel + initrd onto transfer VHDX (FAT)…", 0.88));
        // M=BROMURE_EXTRACT is the only place the marker prefix
        // appears literally; every echo uses "${M}_..." so the
        // typed heredoc body — which the guest tty character-echoes
        // back to us — never contains the full marker. WaitForAsync
        // matches only the runtime output.
        var extractScript =
            "set -e\n" +
            "M=BROMURE_EXTRACT\n" +
            "modprobe ext4 2>/dev/null || true\n" +
            "modprobe vfat 2>/dev/null || true\n" +
            "mkdir -p /mnt/target /mnt/out\n" +
            "mount /dev/sda2 /mnt/target\n" +
            // FAT32 partition on the transfer VHDX. Pre-formatted on
            // the host (single MBR partition → /dev/sdb1).
            "mount -t vfat /dev/sdb1 /mnt/out\n" +
            "KERNEL=$(ls -1 /mnt/target/boot/vmlinuz-* 2>/dev/null | grep -v '\\.old$' | sort -V | tail -n1)\n" +
            "INITRD=$(ls -1 /mnt/target/boot/initrd.img-* 2>/dev/null | grep -v '\\.old$' | sort -V | tail -n1)\n" +
            "[ -n \"$KERNEL\" ] && [ -n \"$INITRD\" ] || { echo \"${M}_FAILED\"; exit 1; }\n" +
            "echo \"BROMURE_KERNEL=$KERNEL\"\n" +
            "echo \"BROMURE_INITRD=$INITRD\"\n" +
            "cp \"$KERNEL\" /mnt/out/vmlinuz\n" +
            "cp \"$INITRD\" /mnt/out/initrd.img\n" +
            // Sentinel so the host can distinguish \"bake actually ran\"
            // from \"stale FAT contents looked plausible\".
            "echo OK > /mnt/out/bake.done\n" +
            "sync\n" +
            "umount /mnt/out\n" +
            "umount /mnt/target\n" +
            "echo \"${M}_DONE\"\n";
        // Heredoc into sh on the guest so the multi-line script
        // runs as one unit (avoids per-prompt round-trips). Use sh,
        // not bash — Alpine's live env only ships BusyBox sh.
        await serial.SendAsync("sh <<'BROMURE_EXTRACT'\n" + extractScript + "BROMURE_EXTRACT\n",
            ct).ConfigureAwait(false);
        await serial.WaitForAsync("BROMURE_EXTRACT_DONE", TimeSpan.FromMinutes(3),
            failures: new[] { "BROMURE_EXTRACT_FAILED" }, ct).ConfigureAwait(false);

        progress?.Report(new BakeProgress("shutdown",
            "Powering off Alpine installer…", 0.91));
        await serial.SendAsync("poweroff\n", ct).ConfigureAwait(false);
    }

    /// <summary>Pull <c>vmlinuz</c> + <c>initrd.img</c> off the transfer
    /// VHDX via its FAT32 drive letter. Mount-VHD attaches the disk;
    /// the FAT partition we pre-formatted on the host gets an automatic
    /// drive-letter assignment. We Copy-Item the two files out and
    /// dismount. No raw <c>\\.\PhysicalDriveN</c> access, so no UAC
    /// elevation is required — members of Hyper-V Administrators can
    /// run the whole bake without an admin token.</summary>
    private static async Task<(string KernelPath, string InitrdPath)> ExtractBootFilesAsync(
        string transferVhdx, string stageDir, string bakeLog, CancellationToken ct)
    {
        var kernelDest = Path.Combine(stageDir, "extracted-vmlinuz");
        var initrdDest = Path.Combine(stageDir, "extracted-initrd.img");

        // Single PS round-trip: Mount-VHD, locate the FAT drive letter,
        // copy both files, verify the bake.done sentinel, dismount.
        // We let PS do the copying (rather than capturing the letter
        // and copying from .NET) so the mount/dismount lifetime is
        // crisp.
        var script =
            "$ErrorActionPreference='Stop';" +
            "$disk = Mount-VHD -Path '" + transferVhdx + "' -PassThru | Get-Disk;" +
            "$letter = ($disk | Get-Partition | Where-Object { $_.DriveLetter } | " +
                "Select-Object -First 1).DriveLetter;" +
            "if (-not $letter) { Dismount-VHD -Path '" + transferVhdx + "'; " +
                "throw 'transfer VHDX had no drive letter after Mount-VHD' };" +
            "$root = \"${letter}:\\\";" +
            "if (-not (Test-Path -LiteralPath \"${root}bake.done\")) { " +
                "Dismount-VHD -Path '" + transferVhdx + "'; " +
                "throw 'transfer VHDX missing bake.done sentinel — setup.sh likely failed inside the guest' };" +
            "Copy-Item -LiteralPath \"${root}vmlinuz\" -Destination '" + kernelDest + "' -Force;" +
            "Copy-Item -LiteralPath \"${root}initrd.img\" -Destination '" + initrdDest + "' -Force;" +
            "Dismount-VHD -Path '" + transferVhdx + "';";
        await PowerShellAsync(script, bakeLog, ct).ConfigureAwait(false);

        if (!File.Exists(kernelDest))
            throw new InvalidOperationException("Bake VM did not produce vmlinuz on the transfer VHDX.");
        if (!File.Exists(initrdDest))
            throw new InvalidOperationException("Bake VM did not produce initrd.img on the transfer VHDX.");
        return (kernelDest, initrdDest);
    }

    /// <summary>Idempotently set up the Hyper-V Internal switch +
    /// NetNat the bake VM connects to. Re-runs cleanly: every cmdlet
    /// either no-ops (already-correct state) or re-creates the
    /// resource.
    ///
    /// <para><b>Why not Default Switch.</b> Default Switch's NAT and
    /// DHCP are served by the SharedAccess (ICS) Windows service.
    /// VPN clients (Cisco, GlobalProtect, ZScaler) routinely stop
    /// that service or break its registry config; Windows updates
    /// occasionally do the same. We've seen DHCP simply not respond
    /// even though the switch appears healthy. Our own Internal
    /// switch + <c>New-NetNat</c> is independent of ICS — it goes
    /// through the kernel's NetNat driver directly. As a bonus we
    /// get a known subnet so the guest can use a static IP and skip
    /// DHCP entirely.</para></summary>
    private static async Task EnsureBakeNetworkAsync(string bakeLog, CancellationToken ct)
    {
        // Five steps, chained so failure halts the chain. Each step
        // checks for pre-existing state first to make re-runs safe.
        var script =
            "$ErrorActionPreference='Stop';" +
            // 1) Internal Hyper-V switch — host-visible vEthernet but
            //    no external NIC binding. New-VMSwitch fails if a
            //    same-named switch already exists; check first.
            "if (-not (Get-VMSwitch -Name '" + BakeSwitchName + "' -ErrorAction SilentlyContinue)) {" +
            "  New-VMSwitch -Name '" + BakeSwitchName + "' -SwitchType Internal | Out-Null" +
            "};" +
            // 2) Host-side IP on vEthernet (<switch>). New-NetIPAddress
            //    also fails on duplicate.
            "$alias = 'vEthernet (" + BakeSwitchName + ")';" +
            "if (-not (Get-NetIPAddress -InterfaceAlias $alias -IPAddress '" + BakeHostIp + "' -ErrorAction SilentlyContinue)) {" +
            "  New-NetIPAddress -InterfaceAlias $alias -IPAddress '" + BakeHostIp + "' -PrefixLength " + BakeSubnetPrefix + " | Out-Null" +
            "};" +
            // 3) NetNat. Only one NetNat is allowed per subnet so
            //    delete any existing one on our prefix before re-creating.
            //    Different name? Doesn't matter — same subnet ⇒ same
            //    NAT instance.
            "Get-NetNat -ErrorAction SilentlyContinue | Where-Object { $_.InternalIPInterfaceAddressPrefix -eq '" + BakeSubnet + "' } | Remove-NetNat -Confirm:$false -ErrorAction SilentlyContinue;" +
            "New-NetNat -Name 'bromure-bake-nat' -InternalIPInterfaceAddressPrefix '" + BakeSubnet + "' | Out-Null;" +
            // 4) Firewall: allow inbound on the vEthernet so the guest's
            //    outbound replies aren't dropped. Internal switches
            //    show up as a Public network profile by default;
            //    relax that to Private so default firewall rules
            //    don't bite.
            "Set-NetConnectionProfile -InterfaceAlias $alias -NetworkCategory Private -ErrorAction SilentlyContinue;" +
            "Write-Host 'bake-net ready';";
        await PowerShellAsync(script, bakeLog, ct).ConfigureAwait(false);
    }

    private static async Task CreateBakeVmAsync(
        string vmName, string alpineIso, string setupIso,
        string targetVhdx, string transferVhdx, string pipeName,
        string bakeLog, CancellationToken ct)
    {
        // One PowerShell round-trip builds the entire VM. Each cmdlet
        // halts the chain on failure via -ErrorAction Stop.
        var script =
            "$ErrorActionPreference='Stop';" +
            // Generation 2 = UEFI; bootable from any UEFI-bootable
            // ISO/VHDX. -NoVHD so we can attach the target VHDX with
            // explicit controller location below.
            "$vm = New-VM -Name '" + vmName + "' -MemoryStartupBytes 4GB " +
                "-Generation 2 -NoVHD -SwitchName '" + BakeSwitchName + "';" +
            "Set-VMProcessor -VMName '" + vmName + "' -Count 4;" +
            // Secure Boot off — Alpine virt ISO's shim isn't in the
            // default Hyper-V UEFI keystore.
            "Set-VMFirmware -VMName '" + vmName + "' -EnableSecureBoot Off;" +
            // SCSI 0:0 = target (will be /dev/sda inside Alpine).
            "Add-VMHardDiskDrive -VMName '" + vmName + "' -Path '" + targetVhdx + "' " +
                "-ControllerType SCSI -ControllerNumber 0 -ControllerLocation 0;" +
            // SCSI 0:1 = transfer (will be /dev/sdb).
            "Add-VMHardDiskDrive -VMName '" + vmName + "' -Path '" + transferVhdx + "' " +
                "-ControllerType SCSI -ControllerNumber 0 -ControllerLocation 1;" +
            // DVD 0 = Alpine ISO (/dev/sr0 — boot target).
            "$bootDvd = Add-VMDvdDrive -VMName '" + vmName + "' -Path '" + alpineIso + "' " +
                "-Passthru;" +
            // DVD 1 = setup ISO (/dev/sr1 — payload).
            "Add-VMDvdDrive -VMName '" + vmName + "' -Path '" + setupIso + "';" +
            // Boot DVD first; if it falls through, the firmware will
            // try the disks (but Alpine ISO is bootable so it won't).
            "Set-VMFirmware -VMName '" + vmName + "' -FirstBootDevice $bootDvd;" +
            // COM1 → named pipe. Hyper-V exposes \\.\pipe\<name> on
            // the host; NamedPipeSerialDriver connects there.
            "Set-VMComPort -VMName '" + vmName + "' -Number 1 -Path '\\\\.\\pipe\\" + pipeName + "';" +
            "Set-VM -Name '" + vmName + "' -CheckpointType Disabled -AutomaticStopAction TurnOff;";
        await PowerShellAsync(script, bakeLog, ct).ConfigureAwait(false);
    }

    /// <summary>Poll Get-VM state every 2 s until "Off" or timeout.</summary>
    private static async Task WaitForVmStoppedAsync(
        string vmName, TimeSpan timeout, string bakeLog, CancellationToken ct)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            ct.ThrowIfCancellationRequested();
            string state;
            try
            {
                state = await PowerShellAsync(
                    "(Get-VM -Name '" + vmName + "' -ErrorAction Stop).State",
                    bakeLog, ct).ConfigureAwait(false);
            }
            catch
            {
                return; // VM gone — treat as stopped.
            }
            state = state.Trim();
            if (state.Equals("Off", StringComparison.OrdinalIgnoreCase) ||
                state.Equals("Stopped", StringComparison.OrdinalIgnoreCase))
            {
                return;
            }
            await Task.Delay(2000, ct).ConfigureAwait(false);
        }
        throw new TimeoutException(
            "VM " + vmName + " did not power off within " + timeout.TotalMinutes + " min");
    }

    private static async Task<string> EnsureAlpineIsoAsync(
        string outputDir, IProgress<BakeProgress>? progress, CancellationToken ct)
    {
        var dest = Path.Combine(outputDir, AlpineIsoFileName);
        if (File.Exists(dest)) return dest;

        var part = dest + ".part";
        try { File.Delete(part); } catch (IOException) { }

        using var resp = await _http.GetAsync(AlpineIsoUrl,
            HttpCompletionOption.ResponseHeadersRead, ct).ConfigureAwait(false);
        if (!resp.IsSuccessStatusCode)
        {
            throw new HttpRequestException(
                "Alpine ISO download: HTTP " + (int)resp.StatusCode + " " + resp.ReasonPhrase);
        }
        var total = resp.Content.Headers.ContentLength ?? 0;
        await using (var src = await resp.Content.ReadAsStreamAsync(ct).ConfigureAwait(false))
        await using (var dst = File.Create(part))
        {
            var buf = new byte[64 * 1024];
            long copied = 0;
            int n;
            while ((n = await src.ReadAsync(buf, ct).ConfigureAwait(false)) > 0)
            {
                await dst.WriteAsync(buf.AsMemory(0, n), ct).ConfigureAwait(false);
                copied += n;
                if (total > 0)
                {
                    progress?.Report(new BakeProgress("alpine",
                        "Downloading Alpine virt ISO (" +
                        (copied / (1024.0 * 1024.0)).ToString("F1") + " / " +
                        (total / (1024.0 * 1024.0)).ToString("F1") + " MB)…",
                        0.02 + (copied / (double)total) * 0.04));
                }
            }
        }
        File.Move(part, dest);
        return dest;
    }

    private static void BuildSetupIso(string outputPath)
    {
        // Pack setup.sh + the two C sources its chroot phase
        // compiles: hvsock-proxy (host→guest VNC bridge) and
        // title-pusher (guest→host AF_VSOCK title pump for the
        // tab labels).
        var scriptBytes = Encoding.UTF8.GetBytes(LoadEmbeddedText("setup.sh"));
        var proxyBytes = Encoding.UTF8.GetBytes(LoadEmbeddedText("hvsock-proxy.c"));
        var titleBytes = Encoding.UTF8.GetBytes(LoadEmbeddedText("title-pusher.c"));
        var overlayBytes = Encoding.UTF8.GetBytes(LoadEmbeddedText("overlay-fetch.c"));
        var cmdBytes = Encoding.UTF8.GetBytes(LoadEmbeddedText("cmd-server.c"));
        var agentBridgeBytes = Encoding.UTF8.GetBytes(LoadEmbeddedText("ssh-agent-bridge.c"));
        var awsCredsBytes = Encoding.UTF8.GetBytes(LoadEmbeddedText("bromure-aws-credentials.py"));
        CloudInitSeedBuilder.WriteFilesIso(
            outputPath,
            new (string, byte[])[] {
                ("setup.sh", scriptBytes),
                ("hvsock-proxy.c", proxyBytes),
                ("title-pusher.c", titleBytes),
                ("overlay-fetch.c", overlayBytes),
                ("cmd-server.c", cmdBytes),
                // In-VM ssh-agent bridge — Unix socket frontend +
                // AF_VSOCK to the host's ssh-agent listener on 8444.
                ("ssh-agent-bridge.c", agentBridgeBytes),
                // In-VM AWS credential_process helper — AF_VSOCK to
                // the host's AwsCredentialHvSocketListener on 8445.
                ("bromure-aws-credentials.py", awsCredsBytes),
            },
            volumeLabel: "BROMUREISO");
    }

    /// <summary>Read an embedded resource by leaf file name. Tolerates
    /// the SandboxEngine assembly's manifest-name mangling (the
    /// embedded resource name has a path-derived prefix).</summary>
    private static string LoadEmbeddedText(string leafName)
    {
        var asm = typeof(VmBaker).Assembly;
        var resourceName = asm.GetManifestResourceNames()
            .FirstOrDefault(n => n.EndsWith("." + leafName, StringComparison.Ordinal))
            ?? throw new InvalidOperationException(
                leafName + " not embedded — check Bromure.SandboxEngine.csproj <EmbeddedResource>.");
        using var stream = asm.GetManifestResourceStream(resourceName)
            ?? throw new InvalidOperationException("Embedded " + leafName + " stream returned null.");
        using var ms = new MemoryStream();
        stream.CopyTo(ms);
        // Normalise CRLF → LF so bash heredocs / gcc don't trip on
        // carriage returns.
        return Encoding.UTF8.GetString(ms.ToArray()).Replace("\r\n", "\n");
    }

    private static void MoveArtefacts(
        string outputDir, string targetVhdx, string vmlinuzSrc, string initrdSrc)
    {
        var baseDest = Path.Combine(outputDir, OutputBaseFileName);
        var kernelDest = Path.Combine(outputDir, OutputKernelFileName);
        var initrdDest = Path.Combine(outputDir, OutputInitrdFileName);
        DeleteWithRetry(baseDest);
        DeleteWithRetry(kernelDest);
        DeleteWithRetry(initrdDest);
        MoveWithRetry(targetVhdx, baseDest);
        MoveWithRetry(vmlinuzSrc, kernelDest);
        MoveWithRetry(initrdSrc, initrdDest);
    }

    /// <summary>File.Move with exponential backoff. Hyper-V's worker
    /// process (<c>vmwp.exe</c>) keeps the VHDX open for a few
    /// seconds after <c>Remove-VM</c> returns — Windows reports
    /// <c>ERROR_SHARING_VIOLATION</c> on File.Move during that
    /// tear-down window. Antivirus scanners can extend the lock
    /// further. 30 s ceiling covers the worst case I've seen.</summary>
    private static void MoveWithRetry(string src, string dst)
    {
        IOException? last = null;
        var delayMs = 200;
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(30);
        while (DateTime.UtcNow < deadline)
        {
            try { File.Move(src, dst); return; }
            catch (IOException ex) { last = ex; }
            Thread.Sleep(delayMs);
            delayMs = Math.Min(delayMs * 2, 2000);
        }
        throw new IOException(
            "File.Move(" + src + " → " + dst + ") still failing after 30 s. " +
            "vmwp.exe or an antivirus may be holding the handle. " +
            "Check Task Manager.", last);
    }

    private static void DeleteWithRetry(string path)
    {
        if (!File.Exists(path)) return;
        IOException? last = null;
        var delayMs = 200;
        var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(30);
        while (DateTime.UtcNow < deadline)
        {
            try { File.Delete(path); return; }
            catch (IOException ex) { last = ex; }
            Thread.Sleep(delayMs);
            delayMs = Math.Min(delayMs * 2, 2000);
        }
        throw new IOException(
            "File.Delete(" + path + ") still failing after 30 s.", last);
    }

    /// <summary>Perf #4: flatten a per-profile differencing child
    /// into a standalone VHDX. The result has no parent reference,
    /// so it survives the parent VHDX being replaced or deleted
    /// (i.e. a base-image rebake). Existing in-VM state is preserved.
    ///
    /// <para>Idempotent in the "already flat" case: Convert-VHD on a
    /// non-differencing source still produces a copy, so we cheap-check
    /// the source's parent via Get-VHD before doing the conversion.</para>
    ///
    /// <para>Throws on any non-cancellation failure so the caller can
    /// abort the bake before doing destructive work — partially-flattened
    /// state is fine (each profile is independent) but the user should
    /// know if some couldn't be saved.</para></summary>
    public static async Task FlattenChildVhdxAsync(string childPath, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(childPath)) throw new ArgumentException("childPath required", nameof(childPath));
        if (!File.Exists(childPath)) return;  // nothing to do — profile never launched

        // Cheap-check: if the VHDX is already standalone (no
        // ParentPath), skip the (expensive) conversion. Get-VHD
        // returns one of "Differencing" / "Dynamic" / "Fixed".
        var probe = await PowerShellAsync(
            $"$ErrorActionPreference='Stop'; (Get-VHD -Path '{childPath.Replace("'", "''")}').VhdType",
            logPath: "",
            ct).ConfigureAwait(false);
        if (!probe.Contains("Differencing", StringComparison.OrdinalIgnoreCase))
        {
            return;  // already flat
        }

        // Convert-VHD doesn't have an in-place mode; convert to a
        // temp file in the same directory, then atomic-replace. The
        // extension MUST stay .vhdx — Convert-VHD validates the file
        // extension and rejects anything else with "invalid extension".
        var tempPath = childPath + ".flatten.vhdx";
        try { if (File.Exists(tempPath)) File.Delete(tempPath); } catch (IOException) { }
        var convertCmd =
            $"$ErrorActionPreference='Stop'; Convert-VHD -Path '{childPath.Replace("'", "''")}' " +
            $"-DestinationPath '{tempPath.Replace("'", "''")}' -VHDType Dynamic";
        await PowerShellAsync(convertCmd, logPath: "", ct).ConfigureAwait(false);
        if (!File.Exists(tempPath))
        {
            throw new IOException($"Convert-VHD produced no output at {tempPath}");
        }

        // Atomic-replace the child with the flattened copy. Both
        // files are on the same volume so File.Replace is atomic at
        // the filesystem level.
        File.Replace(tempPath, childPath, destinationBackupFileName: null);
    }

    private static async Task<string> PowerShellAsync(
        string command, string logPath, CancellationToken ct)
    {
        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        psi.ArgumentList.Add("-NoProfile");
        psi.ArgumentList.Add("-NonInteractive");
        psi.ArgumentList.Add("-ExecutionPolicy");
        psi.ArgumentList.Add("Bypass");
        psi.ArgumentList.Add("-Command");
        psi.ArgumentList.Add(command);

        using var p = new Process { StartInfo = psi };
        var stdout = new StringBuilder();
        var stderr = new StringBuilder();
        p.OutputDataReceived += (_, e) => { if (e.Data is not null) stdout.AppendLine(e.Data); };
        p.ErrorDataReceived += (_, e) => { if (e.Data is not null) stderr.AppendLine(e.Data); };
        if (!p.Start())
            throw new InvalidOperationException("Failed to start powershell.exe");
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();
        await p.WaitForExitAsync(ct).ConfigureAwait(false);

        try
        {
            await File.AppendAllTextAsync(logPath,
                "$ " + command + "\n" + stdout +
                (stderr.Length > 0 ? "[stderr]\n" + stderr : "") + "\n",
                ct).ConfigureAwait(false);
        }
        catch { /* best-effort */ }

        if (p.ExitCode != 0)
        {
            throw new InvalidOperationException(
                "PowerShell step failed (exit " + p.ExitCode + "): " + stderr +
                "\n--- command ---\n" + command);
        }
        return stdout.ToString().Trim();
    }

    /// <summary>Hunt down + destroy any Bromure-owned compute systems
    /// left behind by a prior AC run, plus any matching Hyper-V
    /// Manager VMs (the bake VM itself). Each is one of three
    /// things, all of which lock parent VHDX handles:
    /// <list type="bullet">
    ///   <item>HCS-direct warm-pool entries (<c>bromure-warm-*</c>)
    ///   sitting in created-but-not-started state.</item>
    ///   <item>HCS-direct session entries (<c>bromure-ses-*</c>)
    ///   that the AC didn't dispose at shutdown.</item>
    ///   <item>Hyper-V Manager bake VMs (<c>bromure-bake-*</c>)
    ///   from a previous failed bake.</item>
    /// </list>
    /// Best-effort: any individual destroy/remove failure is logged
    /// (via PowerShellAsync's log file) but doesn't abort the bake —
    /// the worst case is we leave one extra orphan, which the next
    /// run picks up.</summary>
    private static async Task ReapOrphanBromureVmsAsync(string outputDir, CancellationToken ct)
    {
        var bakeLog = Path.Combine(outputDir, "reap.log");

        // 1) Hyper-V Manager bake VMs. Force-stop + remove. If none
        //    match the filter, the pipeline is empty and Where-Object
        //    yields nothing — no error.
        try
        {
            await PowerShellAsync(
                "$ErrorActionPreference='SilentlyContinue';" +
                "Get-VM -ErrorAction SilentlyContinue | " +
                "  Where-Object { $_.Name -like 'bromure-bake-*' } | " +
                "  ForEach-Object {" +
                "    Stop-VM -Name $_.Name -TurnOff -Force -ErrorAction SilentlyContinue;" +
                "    Remove-VM -Name $_.Name -Force -ErrorAction SilentlyContinue;" +
                "  };",
                bakeLog, ct).ConfigureAwait(false);
        }
        catch { /* swallow */ }

        // 2) HCS-direct warm pool. WarmVmPool tracks each entry by a
        //    directory under <appdata>/warm-pool/<id>; iterate and
        //    destroy. Same shape as WarmVmPool.CleanupOrphansAsync
        //    but called explicitly here so we don't have to plumb
        //    the warm-pool reference into VmBaker.
        var appData = Path.GetDirectoryName(Path.GetDirectoryName(outputDir)!)!;
        // outputDir = ".../AppData/Local/Bromure/AC/images"
        // appData   = ".../AppData/Local/Bromure/AC"
        var warmPoolRoot = Path.Combine(appData, "warm-pool");
        if (Directory.Exists(warmPoolRoot))
        {
            try
            {
                await WarmVmPool.CleanupOrphansAsync(warmPoolRoot, ct).ConfigureAwait(false);
            }
            catch { /* swallow */ }
        }

        // 3) HCS-direct session VMs. Same shape — directories under
        //    <appdata>/sessions/<session>/<vm-id>. WarmVmPool's
        //    cleanup helper opens by ID prefix so it'll handle
        //    bromure-ses-* too if we point it at the sessions root.
        var sessionsRoot = Path.Combine(appData, "sessions");
        if (Directory.Exists(sessionsRoot))
        {
            try
            {
                // Each session dir contains per-VM subdirs; flatten.
                foreach (var sessionDir in Directory.EnumerateDirectories(sessionsRoot))
                {
                    foreach (var vmDir in Directory.EnumerateDirectories(sessionDir))
                    {
                        var vmId = Path.GetFileName(vmDir);
                        if (!vmId.StartsWith("bromure-ses-", StringComparison.Ordinal)) continue;
                        // Best-effort destroy. HcsVm.DestroyAsync is
                        // idempotent and tolerates already-stopped /
                        // already-removed states.
                        var stubCfg = new HcsVmConfig
                        {
                            RootDiskPath = Path.Combine(vmDir, "disk.vhdx"),
                        };
                        try
                        {
                            await using var vm = new HcsVm(vmId, stubCfg);
                            await vm.DestroyAsync(ct).ConfigureAwait(false);
                        }
                        catch { /* swallow */ }
                        try { Directory.Delete(vmDir, recursive: true); } catch { }
                    }
                }
            }
            catch { /* swallow */ }
        }
    }

    /// <summary>True if the current user's token grants Hyper-V cmdlet
    /// access — either through local Administrators (UAC-elevated) or
    /// through the Hyper-V Administrators built-in group (SID
    /// <c>S-1-5-32-578</c>, NOT subject to UAC token filtering). The
    /// latter is what Windows auto-grants when you enable the Hyper-V
    /// feature, and it's why this bake doesn't need a UAC prompt for
    /// a typical Hyper-V dev workstation.</summary>
    private static bool IsHyperVCapable()
    {
        try
        {
            using var identity = System.Security.Principal.WindowsIdentity.GetCurrent();
            var principal = new System.Security.Principal.WindowsPrincipal(identity);
            if (principal.IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator))
                return true;
            // Hyper-V Administrators — well-known SID. WindowsBuiltInRole
            // doesn't have an enum value for it, so we check by SID.
            var hyperVAdmins = new System.Security.Principal.SecurityIdentifier(
                "S-1-5-32-578");
            return principal.IsInRole(hyperVAdmins);
        }
        catch { return true; /* don't block on our own detection bug */ }
    }
}
