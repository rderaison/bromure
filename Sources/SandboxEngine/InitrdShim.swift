import Foundation

/// Builds an Alpine initramfs with a `rdinit=/init.bromure` shim segment
/// appended that clamps the NIC MTU *before* Alpine's own `/init` runs its
/// modloop / apkovl / APKINDEX fetches.
///
/// On reduced-MTU paths (WireGuard ~1420, IKEv2 ~1400, nested tunnels) the
/// host's path MTU drops below 1500 and PMTUD doesn't always kick in, so large
/// TLS frames sent at MTU 1500 get silently blackholed. A post-login
/// `ip link set … mtu` can't reach the boot-time fetches that Alpine's `/init`
/// makes; clamping in the initramfs does.
///
/// Shared by the Bromure Web (`LinuxImageManager`) and Bromure AC
/// (`UbuntuImageManager`) base-image builders.
public enum InitrdShim {
    /// Read the original Alpine initramfs, append our `init.bromure` cpio
    /// segment, and write the combined file to `dest`. Cheap (the original is
    /// ~10–20 MB, our segment is ~200 B), so we rebuild on every install rather
    /// than caching by MTU value.
    public static func writeShimmedInitrd(
        original: URL,
        mtu: Int,
        to dest: URL
    ) throws {
        var combined = try Data(contentsOf: original)
        // The kernel's initramfs unpacker checks 4-byte alignment of
        // `this_header` before parsing a fresh cpio segment. After it
        // decompresses Alpine's gzipped initrd, `this_header` lands at
        // the gzip stream's byte count — typically NOT a multiple of
        // 4 (Alpine's tends to be `% 4 == 3`). NUL bytes are skipped
        // by the unpacker AND increment `this_header`, so pad up to
        // the next 4-byte boundary before our raw cpio begins. Without
        // this the kernel mis-classifies '0' (start of "070701") as
        // junk, errors out of unpacking, fails to find `/init.bromure`
        // for the `rdinit=` cmdline, and falls through to
        // `prepare_namespace()` → "Unable to mount root fs" panic.
        let pad = (4 - (combined.count % 4)) % 4
        if pad > 0 {
            combined.append(Data(repeating: 0, count: pad))
        }
        combined.append(buildShimCpioSegment(mtu: mtu))
        try? FileManager.default.removeItem(at: dest)
        try combined.write(to: dest)
    }

    /// Produce an uncompressed cpio (newc format) containing a single
    /// regular file `init.bromure`. The kernel concatenates this onto
    /// the original (gzipped) initramfs at boot — files in later
    /// segments override earlier ones, so this is enough to plant the
    /// shim at `/init.bromure` in the initramfs root.
    private static func buildShimCpioSegment(mtu: Int) -> Data {
        // The shim writes MTU via sysfs rather than `ip link`, so it
        // doesn't depend on busybox symlinks being in $PATH yet.
        // `e*` matches whichever name virtio-net got (eth*, enp*, ens*).
        // Echo to both /dev/console (visible in the serial log
        // alongside Alpine's init output) AND /dev/kmsg (recorded in
        // the kernel ring buffer with a real kernel timestamp, so it
        // shows up in `dmesg` later — that's our ground truth for
        // "did the shim actually run".
        //
        // /sys and /proc are NOT mounted yet at rdinit time —
        // Alpine's /init mounts them — so the shim mounts them itself
        // (and Alpine's later `mount -t sysfs` just no-ops with EBUSY).
        // Without that, /sys/class/net/e*/mtu doesn't exist and the
        // glob falls through, leaving MTU untouched.
        let shim = """
        #!/bin/sh
        # At rdinit time, busybox symlinks (/bin/cat, /sbin/ip, …) aren't
        # set up yet — Alpine's /init script is what creates them. Call
        # busybox directly so we don't depend on PATH or symlinks.
        BB=/bin/busybox
        log() {
            echo "$1"
            echo "$1" > /dev/kmsg 2>/dev/null || true
        }
        $BB mount -t sysfs -o noexec,nosuid,nodev sys /sys 2>/dev/null || true
        $BB mount -t proc -o noexec,nosuid,nodev proc /proc 2>/dev/null || true
        # devtmpfs is normally auto-mounted by the kernel when
        # CONFIG_DEVTMPFS_MOUNT=y. If not, attempt it ourselves — no-op
        # if already there.
        $BB mount -t devtmpfs -o exec,nosuid devtmpfs /dev 2>/dev/null || true
        # If virtio_net isn't built into this kernel, load the module
        # so eth0 actually appears. No-op when already loaded / built-in.
        $BB modprobe virtio_net 2>/dev/null || true

        # Plant busybox applet symlinks (ip, cat, ifconfig, route, …)
        # in their canonical locations. Without this, udhcpc's default
        # script (which calls bare `ip`/`cat`/etc.) can't apply the
        # lease — it discovers an IP but never assigns it. Alpine's
        # /init does this later; we need it now.
        $BB --install -s 2>/dev/null || true
        export PATH=/usr/sbin:/usr/bin:/sbin:/bin

        # Bring lo + eth0 up — kernel's ip=dhcp tried earlier, failed
        # (vmnet's bootpd wasn't ready), and closed the interface.
        # We need it UP before udhcpc can broadcast a DISCOVER.
        log "bromure-shim: bringing lo + eth0 up"
        $BB ip link set dev lo up 2>&1 | while IFS= read -r line; do log "  $line"; done
        $BB ip link set dev eth0 up 2>&1 | while IFS= read -r line; do log "  $line"; done

        # Lease a fresh IP. Busybox udhcpc, -q quits after the lease
        # lands (don't daemonize — keeps PID 1 clean), -n exits non-zero
        # on failure so we can fall through to /init without spinning
        # forever. The default script (in /usr/share/udhcpc/) sets IP,
        # netmask, gateway, /etc/resolv.conf. It only touches MTU if
        # option 26 is in the lease — vmnet's bootpd doesn't send it.
        log "bromure-shim: running udhcpc -i eth0 -q -n"
        $BB udhcpc -i eth0 -q -n 2>&1 | while IFS= read -r line; do log "  $line"; done

        # Clamp MTU AFTER udhcpc so a hypothetical lease with option 26
        # can't undo us. Sysfs write survives any subsequent up/down
        # cycle Alpine's /init does later.
        log "bromure-shim: clamping MTU to \(mtu)"
        for f in /sys/class/net/e*/mtu; do
            if [ -w "$f" ]; then
                echo \(mtu) > "$f"
                log "bromure-shim: $f -> $($BB cat "$f")"
            fi
        done

        # Diagnostic: dump iface state right before handing off to
        # Alpine's /init. If MTU ever shows up as 1500 in the host
        # serial log AFTER this line, something downstream is
        # resetting it.
        log "bromure-shim: ip addr show"
        $BB ip addr show 2>&1 | while IFS= read -r line; do log "  $line"; done
        log "bromure-shim: ip route show"
        $BB ip route show 2>&1 | while IFS= read -r line; do log "  $line"; done

        exec /init "$@"
        """
        // Hook that re-applies MTU after every udhcpc `bound` event.
        // Alpine's default.script invokes everything in
        // /etc/udhcpc/post-bound/ post-lease (the bound() function
        // runs first, then run_scripts post-bound). Without this,
        // Alpine's /init does its own DHCP between modloop and
        // APKINDEX, and even though the default.script doesn't
        // explicitly set MTU, something in that path empirically
        // breaks large-packet HTTPS until we re-clamp. The kmsg
        // line also lets us verify (via dmesg) that the hook ran.
        let postBound = """
        #!/bin/sh
        [ -n "$interface" ] || exit 0
        ip link set dev "$interface" mtu \(mtu) 2>/dev/null
        current=$(cat /sys/class/net/$interface/mtu)
        echo "bromure-post-bound: $interface MTU=$current"
        echo "bromure-post-bound: $interface MTU=$current" > /dev/kmsg 2>/dev/null || true
        """

        var cpio = Data()
        // S_IFREG (0o100000) | 0o755 = executable regular file.
        appendCpioEntry(&cpio, path: "init.bromure",
                        mode: 0o100755, content: Data(shim.utf8))
        // /etc exists in Alpine's initramfs, but /etc/udhcpc and
        // /etc/udhcpc/post-bound don't — plant them (S_IFDIR is
        // 0o040000) so the hook script's parent path resolves.
        appendCpioEntry(&cpio, path: "etc/udhcpc",
                        mode: 0o040755, content: Data())
        appendCpioEntry(&cpio, path: "etc/udhcpc/post-bound",
                        mode: 0o040755, content: Data())
        appendCpioEntry(&cpio, path: "etc/udhcpc/post-bound/zz-bromure-mtu",
                        mode: 0o100755, content: Data(postBound.utf8))
        // newc archives end with a TRAILER!!! entry (filesize 0).
        appendCpioEntry(&cpio, path: "TRAILER!!!",
                        mode: 0, content: Data())
        return cpio
    }

    /// Append one cpio newc entry. Header is 110 bytes of ASCII hex,
    /// then NUL-terminated name padded to a 4-byte boundary, then the
    /// content padded to a 4-byte boundary. Padding is measured against
    /// the start of the cpio archive (= `buf.count` here, since we
    /// always start with an empty Data).
    private static func appendCpioEntry(
        _ buf: inout Data,
        path: String,
        mode: UInt32,
        content: Data
    ) {
        var name = Data(path.utf8)
        name.append(0)  // NUL terminator
        let hex8: (UInt32) -> String = { String(format: "%08x", $0) }
        var header = "070701"                       // c_magic
        header += hex8(0)                           // c_ino
        header += hex8(mode)                        // c_mode
        header += hex8(0)                           // c_uid
        header += hex8(0)                           // c_gid
        header += hex8(1)                           // c_nlink
        header += hex8(0)                           // c_mtime
        header += hex8(UInt32(content.count))       // c_filesize
        header += hex8(0)                           // c_devmajor
        header += hex8(0)                           // c_devminor
        header += hex8(0)                           // c_rdevmajor
        header += hex8(0)                           // c_rdevminor
        header += hex8(UInt32(name.count))          // c_namesize (incl. NUL)
        header += hex8(0)                           // c_check
        buf.append(Data(header.utf8))
        buf.append(name)
        while buf.count % 4 != 0 { buf.append(0) }
        buf.append(content)
        while buf.count % 4 != 0 { buf.append(0) }
    }
}
