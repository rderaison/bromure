#!/usr/bin/python3 -u
"""Bromure config agent — runs inside the guest VM at boot.

Listens on vsock port 5000 for a JSON config from the host, then:
  1. Mounts the profile disk (if persistent)
  2. Writes chrome-env
  3. Starts services (DNS, proxy, WARP teardown, webcam, CAs)
  4. Touches chrome-ready to unblock xinitrc
  5. Exits

This replaces serial-based config delivery for lower latency.
"""

import json
import os
import socket
import struct
import subprocess
import sys
import time

VSOCK_PORT = 5000
HOST_CID = 2


def run(cmd, check=False):
    """Run a shell command, return (returncode, stdout)."""
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    if check and r.returncode != 0:
        print(f"config-agent: FAILED: {cmd}\n  stderr: {r.stderr.strip()}", file=sys.stderr)
    return r.returncode, r.stdout.strip()


def mount_profile_disk(cfg):
    """Mount virtio-fs share and loop-mount the profile disk."""
    mount_point = cfg.get("profileMount")
    disk_key = cfg.get("profileDiskKey")
    if not mount_point:
        return

    # Ensure kernel modules and mount point exist (on-boot.sh may not have run yet)
    run("modprobe virtiofs 2>/dev/null")
    run("modprobe loop 2>/dev/null")
    os.makedirs("/mnt/share", exist_ok=True)
    run("mount -t virtiofs share /mnt/share", check=True)
    disk_path = "/mnt/share/profile.img"

    if disk_key:
        # Encrypted: LUKS
        rc, loop = run("losetup -f")
        run(f"losetup {loop} {disk_path}", check=True)
        # Format if not already LUKS
        rc, _ = run(f"cryptsetup isLuks {loop}")
        key_bytes = disk_key.encode()
        if rc != 0:
            subprocess.run(["cryptsetup", "luksFormat", "--batch-mode", loop, "-"],
                           input=key_bytes, check=True, capture_output=True)
        subprocess.run(["cryptsetup", "open", loop, "profile_data", "-"],
                       input=key_bytes, check=True, capture_output=True)
        os.makedirs(mount_point, exist_ok=True)
        rc, _ = run("blkid /dev/mapper/profile_data")
        if rc != 0:
            run("mkfs.ext4 -q /dev/mapper/profile_data", check=True)
        run(f"mount /dev/mapper/profile_data {mount_point}", check=True)
        run(f"chown chrome:chrome {mount_point}")
    else:
        # Unencrypted
        os.makedirs(mount_point, exist_ok=True)
        rc, _ = run(f"blkid {disk_path}")
        if rc != 0:
            run(f"mkfs.ext4 -q {disk_path}", check=True)
        run(f"mount -o loop {disk_path} {mount_point}", check=True)
        run(f"chown chrome:chrome {mount_point}")


def write_custom_cas(cas):
    """Write custom root CA certificates to disk."""
    if not cas:
        return 0
    os.makedirs("/tmp/bromure/custom-cas", exist_ok=True)
    for i, pem in enumerate(cas):
        with open(f"/tmp/bromure/custom-cas/ca-{i}.crt", "w") as f:
            f.write(pem)
    return len(cas)


def sh_escape(s):
    """Escape a string for safe use as a single-quoted shell value."""
    return "'" + str(s).replace("'", "'\\''") + "'"


def write_chrome_env(cfg):
    """Build and write the chrome-env file."""
    env_file = "/tmp/bromure/chrome-env"
    lines = []

    extra_flags = []
    enable_features = []
    disable_features = []

    if cfg.get("darkMode"):
        extra_flags.append("--force-dark-mode")
        enable_features.append("WebContentsForceDark")
    if cfg.get("proxyHost"):
        # Custom proxy: point Chrome directly at the external proxy
        proxy_host = cfg["proxyHost"]
        proxy_port = cfg.get("proxyPort", 8080)
        proxy_user = cfg.get("proxyUsername", "")
        proxy_pass = cfg.get("proxyPassword", "")
        if proxy_user and proxy_pass:
            extra_flags.append(f"--proxy-server=http://{proxy_user}:{proxy_pass}@{proxy_host}:{proxy_port}")
        else:
            extra_flags.append(f"--proxy-server=http://{proxy_host}:{proxy_port}")
    else:
        # Always route through internal squid proxy (required for dynamic
        # WARP toggling — squid is restarted with/without proxychains).
        extra_flags.append("--proxy-server=http://127.0.0.1:3128")
    if cfg.get("disableGPU"):
        extra_flags.append("--disable-gpu")
    if cfg.get("disableWebGL"):
        extra_flags.append("--disable-webgl --disable-3d-apis")

    extensions = []
    if cfg.get("phishingGuard"):
        extensions.append("/opt/bromure/extensions/phishing-guard")
    if cfg.get("linkSender"):
        extensions.append("/opt/bromure/extensions/link-sender")
    if cfg.get("fileTransfer"):
        extra_flags.append("--silent-debugger-extension-api")
        extensions.append("/opt/bromure/extensions/file-picker")
    # WebRTC block extension: loaded only when both webcam and microphone are off
    if not cfg.get("webcam") and not cfg.get("microphone"):
        extensions.append("/opt/bromure/extensions/webrtc-block")
    if extensions:
        extra_flags.append(f"--load-extension={','.join(extensions)}")
        # Only allow our extensions, disable any others
        extra_flags.append(f"--disable-extensions-except={','.join(extensions)}")

    profile_dir = cfg.get("profileDir")
    if profile_dir:
        extra_flags.append(f"--user-data-dir={profile_dir}")
        enable_features.append("WebAuthenticationNewPasskeyUI")
    if cfg.get("restoreSession"):
        extra_flags.append("--restore-last-session")
    if cfg.get("microphone"):
        disable_features.append("AudioServiceOutOfProcess")

    # Disable WebRTC when both webcam and microphone are off
    if not cfg.get("webcam") and not cfg.get("microphone"):
        extra_flags.append("--force-webrtc-ip-handling-policy=disable_non_proxied_udp")
        extra_flags.append("--enforce-webrtc-ip-permission-check")

    app_version = cfg.get("appVersion", "")
    if app_version:
        extra_flags.append(f"--append-user-agent=Bromure/{app_version}")

    if enable_features:
        extra_flags.append(f"--enable-features={','.join(enable_features)}")
    if disable_features:
        extra_flags.append(f"--disable-features={','.join(disable_features)}")

    if extra_flags:
        lines.append(f"EXTRA_FLAGS={sh_escape(' '.join(extra_flags))}")
    if not cfg.get("restoreSession"):
        lines.append(f"CHROME_URL={sh_escape(cfg.get('chromeURL', 'about:blank'))}")
    if cfg.get("swapCmdCtrl"):
        lines.append("SWAP_CMD_CTRL=1")
    if cfg.get("fileTransfer"):
        lines.append("FILE_TRANSFER=1")
    if cfg.get("clipboard"):
        lines.append("CLIPBOARD=1")
    if cfg.get("linkSender"):
        lines.append("LINK_SENDER=1")
    if cfg.get("proxyHost"):
        lines.append(f"PROXY_HOST={sh_escape(cfg['proxyHost'])}")
        lines.append(f"PROXY_PORT={sh_escape(cfg.get('proxyPort', 8080))}")
        if cfg.get("proxyUsername"):
            lines.append(f"PROXY_USERNAME={sh_escape(cfg['proxyUsername'])}")
        if cfg.get("proxyPassword"):
            lines.append(f"PROXY_PASSWORD={sh_escape(cfg['proxyPassword'])}")
    if cfg.get("webcam"):
        lines.append("WEBCAM=1")
        if cfg.get("webcamWidth"):
            lines.append(f"WEBCAM_WIDTH={cfg['webcamWidth']}")
        if cfg.get("webcamHeight"):
            lines.append(f"WEBCAM_HEIGHT={cfg['webcamHeight']}")
    if profile_dir:
        lines.append(f"PROFILE_DIR={sh_escape(profile_dir)}")
    if cfg.get("audio"):
        lines.append("AUDIO=1")
        vol = cfg.get("audioVolume")
        if vol is not None:
            lines.append(f"AUDIO_VOLUME={vol}")
    if cfg.get("microphone"):
        lines.append("MICROPHONE=1")

    # Locale: forward host OS locale to Chromium
    locale = cfg.get("locale", "en_US")
    # Map macOS locale (e.g. "en_US") to Chromium --lang format (e.g. "en-US")
    chrome_lang = locale.replace("_", "-")
    # Strip region for base language (e.g. "en-US" -> "en")
    base_lang = locale.split("_")[0]
    lines.append(f"CHROME_LANG={sh_escape(chrome_lang)}")
    lines.append(f"export LANG={sh_escape(f'{locale}.UTF-8')}")
    lines.append(f"export LC_ALL={sh_escape(f'{locale}.UTF-8')}")
    lines.append(f"export LANGUAGE={sh_escape(base_lang)}")

    # Test suite: forward TEST_* expectations to chrome-env
    for key, val in cfg.items():
        if key.startswith("TEST_"):
            lines.append(f"{key}={sh_escape(val)}")

    with open(env_file, "w") as f:
        f.write("\n".join(lines) + "\n")


def write_dynamic_policy(cfg):
    """Write session-specific Chrome enterprise policy (media capture, WebRTC)."""
    policy = {}

    # Media capture: allow only when the corresponding device is enabled
    policy["VideoCaptureAllowed"] = bool(cfg.get("webcam"))
    policy["AudioCaptureAllowed"] = bool(cfg.get("microphone"))

    # Kill WebRTC entirely when both webcam and microphone are off
    if not cfg.get("webcam") and not cfg.get("microphone"):
        policy["WebRtcIPHandlingPolicy"] = "disable_non_proxied_udp"
        policy["WebRtcUdpPortRange"] = "0-0"
        policy["WebRtcLocalIpsAllowedUrls"] = []

    # Block all downloads at the browser level
    if cfg.get("blockDownloads"):
        policy["DownloadRestrictions"] = 3  # Block all downloads

    policy_path = "/etc/chromium/policies/managed/session.json"
    os.makedirs(os.path.dirname(policy_path), exist_ok=True)
    with open(policy_path, "w") as f:
        json.dump(policy, f)


def configure_services(cfg, ca_count):
    """Start DNS/proxy/WARP services. Returns list of background PIDs to wait on."""
    bg_pids = []
    # PIDs we don't need to wait for before Chrome starts
    fire_and_forget = []

    # WARP: write markers for warp-agent.  When WARP is enabled, we start
    # dbus + warp-svc now so the VPN can connect during boot.  The
    # warp-agent finishes setup (registration, mode, port) and connects.
    # Routing is controlled by the /tmp/bromure/warp-active flag file —
    # toggling is instant with no process swap.
    if cfg.get("enableWarp"):
        open("/tmp/bromure/warp-boot-setup", "w").close()
        if cfg.get("warpAutoConnect"):
            open("/tmp/bromure/warp-auto-connect", "w").close()

        # Start dbus (required by warp-svc)
        rc, _ = run("pgrep -x dbus-daemon")
        if rc != 0:
            run("rm -f /run/dbus/dbus.pid")
            run("/usr/bin/dbus-daemon --system")

        # Start warp-svc early so it can boot while Chrome starts
        if os.path.isfile("/bin/warp-svc"):
            warp_env = dict(os.environ, LD_PRELOAD="/usr/lib/libresolv_stub.so",
                            LANG="C", LC_ALL="C", LANGUAGE="C")
            svc_log = open("/tmp/bromure/warp-svc.log", "a")
            subprocess.Popen(
                ["/bin/warp-svc"],
                env=warp_env,
                stdout=svc_log,
                stderr=svc_log)

    # Webcam setup (background)
    if cfg.get("webcam"):
        pid = os.fork()
        if pid == 0:
            subprocess.run(
                "modprobe v4l2loopback video_nr=0 card_label='Bromure Camera' exclusive_caps=1 2>/dev/null;"
                "for i in $(seq 1 30); do [ -e /dev/video0 ] && break; sleep 0.1; done;"
                "chown root:video /dev/video0 2>/dev/null; chmod 660 /dev/video0 2>/dev/null",
                shell=True)
            os._exit(0)
        bg_pids.append(pid)

    # Custom CAs (background)
    if ca_count > 0:
        pid = os.fork()
        if pid == 0:
            # Copy CAs to system trust store, then update system + Chrome nssdb
            subprocess.run(
                "cp /tmp/bromure/custom-cas/*.crt /usr/local/share/ca-certificates/ 2>/dev/null",
                shell=True)
            subprocess.run("update-ca-certificates 2>/dev/null", shell=True)
            subprocess.run(
                "mkdir -p /home/chrome/.pki/nssdb;"
                "for f in /usr/local/share/ca-certificates/*.crt; do "
                "[ -f \"$f\" ] && certutil -d sql:/home/chrome/.pki/nssdb -A -t 'C,,' "
                "-n \"$(basename \"$f\" .crt)\" -i \"$f\" 2>/dev/null; done;"
                "chown -R chrome:chrome /home/chrome/.pki",
                shell=True)
            os._exit(0)
        bg_pids.append(pid)

    # DNS/proxy (synchronous — needed before Chrome)
    #
    # Squid always runs (unless a custom external proxy is configured).
    # It routes through proxychains → :40001 (routing-socks).
    has_custom_proxy = bool(cfg.get("proxyHost"))

    if cfg.get("blockMalware"):
        run("sed -i 's/^server=1\\.1\\.1\\.1/server=1.1.1.2/' /etc/dnsmasq.d/pihole.conf")
        run("sed -i 's/^server=1\\.0\\.0\\.1/server=1.0.0.2/' /etc/dnsmasq.d/pihole.conf")

    # Start dnsmasq for DNS filtering (ad-blocking, malware blocking, or WARP)
    if cfg.get("adBlocking") or cfg.get("blockMalware") or cfg.get("enableWarp"):
        run("dnsmasq -C /etc/dnsmasq.d/pihole.conf")

    # Configure squid DNS: use dnsmasq (127.0.0.1) when ad-blocking or
    # malware-blocking is on, otherwise use system defaults.
    if cfg.get("adBlocking") or cfg.get("blockMalware"):
        run("sed -i 's/^dns_nameservers.*/dns_nameservers 127.0.0.1/' /etc/squid/squid.conf")
    else:
        run("sed -i '/^dns_nameservers/d' /etc/squid/squid.conf")

    # Start routing-socks.py on :40001 — proxychains always points here.
    # It switches per-connection between warp-svc (:40000) and direct
    # based on /tmp/bromure/warp-active flag.  Without WARP, the flag
    # never exists so all connections go direct.
    if not has_custom_proxy:
        subprocess.Popen(
            ["/usr/local/bin/routing-socks.py"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        # Start squid through proxychains (always, never restarted).
        subprocess.Popen(
            ["proxychains4", "-q", "-f", "/etc/proxychains/proxychains.conf",
             "squid", "-N", "-f", "/etc/squid/squid.conf"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # Profile preferences
    profile_dir = cfg.get("profileDir")
    if profile_dir:
        prefs_dir = f"{profile_dir}/Default"
        prefs_file = f"{prefs_dir}/Preferences"
        if not os.path.exists(prefs_file):
            os.makedirs(prefs_dir, exist_ok=True)
            run(f"cp /home/chrome/.config/chromium/Default/Preferences {prefs_file}")
            run(f"chown -R chrome:chrome {profile_dir}")
        if os.path.exists(prefs_file):
            run(f"sed -i 's/\"exit_type\":\"Crashed\"/\"exit_type\":\"Normal\"/' {prefs_file}")
            run(f"sed -i 's/\"exited_cleanly\":false/\"exited_cleanly\":true/' {prefs_file}")

    return bg_pids, fire_and_forget


def main():
    os.makedirs("/tmp/bromure", exist_ok=True)

    # Connect to host on vsock (retry until host listener is ready).
    sock = None
    while True:
        try:
            s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            s.connect((HOST_CID, VSOCK_PORT))
            sock = s
            break
        except (ConnectionRefusedError, ConnectionResetError, OSError):
            s.close()
            time.sleep(0.1)
    print("config-agent: connected to host", file=sys.stderr)

    # Read length-prefixed JSON: [u32be length][json payload]
    hdr = b""
    while len(hdr) < 4:
        hdr += sock.recv(4 - len(hdr))
    length = struct.unpack(">I", hdr)[0]

    data = b""
    while len(data) < length:
        data += sock.recv(min(65536, length - len(data)))

    cfg = json.loads(data.decode("utf-8"))
    print(f"config-agent: received config ({length} bytes)", file=sys.stderr)

    # No global wait_for_on_boot — only WARP-dependent paths wait internally.

    # Mount profile disk (if persistent)
    if cfg.get("profileDisk"):
        mount_profile_disk(cfg)

    # Write custom CAs
    ca_count = write_custom_cas(cfg.get("rootCAs"))

    # Write chrome-env
    write_chrome_env(cfg)

    # Write dynamic Chrome policy (media capture, WebRTC)
    write_dynamic_policy(cfg)

    # Kill pre-started agents for disabled features
    if not cfg.get("fileTransfer"):
        run("pkill -f file-agent.py")
    if not cfg.get("webcam"):
        run("pkill -f webcam-agent.py")
        subprocess.Popen(["rmmod", "v4l2loopback"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # Start download guard daemon: inotify watcher that deletes files created
    # outside dot-directories in /home/chrome (prevents saving downloads to the VM)
    if cfg.get("blockDownloads"):
        subprocess.Popen(
            ["/usr/local/bin/download-guard.sh"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # Configure services
    bg_pids, fire_and_forget = configure_services(cfg, ca_count)

    # Wait for tasks that must complete before Chrome (webcam, CAs)
    for pid in bg_pids:
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass

    # Signal xinitrc
    open("/tmp/bromure/chrome-ready", "w").close()

    # Tell host we're done
    sock.sendall(b"OK")
    sock.close()
    print("config-agent: done", file=sys.stderr)

    # Wait for fire-and-forget tasks (WARP teardown) so we don't leave zombies
    for pid in fire_and_forget:
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass


if __name__ == "__main__":
    main()
