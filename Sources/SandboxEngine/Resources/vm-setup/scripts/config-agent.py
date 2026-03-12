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
        if rc != 0:
            run(f"echo -n '{disk_key}' | cryptsetup luksFormat --batch-mode {loop} -", check=True)
        run(f"echo -n '{disk_key}' | cryptsetup open {loop} profile_data -", check=True)
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
    if cfg.get("useProxy"):
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
    if extensions:
        extra_flags.append(f"--load-extension={','.join(extensions)}")

    profile_dir = cfg.get("profileDir")
    if profile_dir:
        extra_flags.append(f"--user-data-dir={profile_dir}")
        enable_features.append("WebAuthenticationNewPasskeyUI")
    if cfg.get("restoreSession"):
        extra_flags.append("--restore-last-session")
    if cfg.get("microphone"):
        disable_features.append("AudioServiceOutOfProcess")

    if enable_features:
        extra_flags.append(f"--enable-features={','.join(enable_features)}")
    if disable_features:
        extra_flags.append(f"--disable-features={','.join(disable_features)}")

    if extra_flags:
        lines.append(f'EXTRA_FLAGS="{" ".join(extra_flags)}"')
    if not cfg.get("restoreSession"):
        lines.append(f"CHROME_URL={cfg.get('chromeURL', 'about:blank')}")
    if cfg.get("swapCmdCtrl"):
        lines.append("SWAP_CMD_CTRL=1")
    if cfg.get("fileTransfer"):
        lines.append("FILE_TRANSFER=1")
    if cfg.get("clipboard"):
        lines.append("CLIPBOARD=1")
    if cfg.get("linkSender"):
        lines.append("LINK_SENDER=1")
    if cfg.get("webcam"):
        lines.append("WEBCAM=1")
        if cfg.get("webcamWidth"):
            lines.append(f"WEBCAM_WIDTH={cfg['webcamWidth']}")
        if cfg.get("webcamHeight"):
            lines.append(f"WEBCAM_HEIGHT={cfg['webcamHeight']}")
    if cfg.get("audio"):
        lines.append("AUDIO=1")
    if cfg.get("microphone"):
        lines.append("MICROPHONE=1")

    with open(env_file, "w") as f:
        f.write("\n".join(lines) + "\n")


def configure_services(cfg, ca_count):
    """Start DNS/proxy/WARP services. Returns list of background PIDs to wait on."""
    bg_pids = []
    # PIDs we don't need to wait for before Chrome starts
    fire_and_forget = []

    # WARP teardown (fire-and-forget — waits for on-boot internally)
    if not cfg.get("enableWarp"):
        pid = os.fork()
        if pid == 0:
            # Wait for on-boot.sh so warp-svc has started before we kill it
            if not os.path.exists("/tmp/bromure/on-boot-done"):
                subprocess.run("inotifywait -t 10 -e create --include on-boot-done /tmp/bromure/",
                               shell=True, capture_output=True)
            subprocess.run(
                "LD_PRELOAD=/usr/lib/libresolv_stub.so /bin/warp-cli --accept-tos disconnect 2>/dev/null;"
                "kill $(ps auxw | grep warp-svc | grep -v grep | awk '{print $1}') 2>/dev/null",
                shell=True)
            os._exit(0)
        fire_and_forget.append(pid)

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
    if cfg.get("blockMalware"):
        run("sed -i 's/^server=1\\.1\\.1\\.1/server=1.1.1.2/' /etc/dnsmasq.d/pihole.conf")
        run("sed -i 's/^server=1\\.0\\.0\\.1/server=1.0.0.2/' /etc/dnsmasq.d/pihole.conf")

    if cfg.get("adBlocking") or cfg.get("enableWarp") or cfg.get("blockMalware"):
        run("dnsmasq -C /etc/dnsmasq.d/pihole.conf")
        if cfg.get("adBlocking") or cfg.get("blockMalware"):
            run("sed -i 's/^dns_nameservers.*/dns_nameservers 127.0.0.1/' /etc/squid/squid.conf")
        else:
            run("sed -i '/^dns_nameservers/d' /etc/squid/squid.conf")
        if cfg.get("enableWarp"):
            # Wait for on-boot.sh — WARP proxy must be running before squid starts through it
            if not os.path.exists("/tmp/bromure/on-boot-done"):
                subprocess.run("inotifywait -t 10 -e create --include on-boot-done /tmp/bromure/",
                               shell=True, capture_output=True)
            run("proxychains4 -q -f /etc/proxychains/proxychains.conf squid -N -f /etc/squid/squid.conf &")
        else:
            run("squid -N -f /etc/squid/squid.conf &")

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
    # The host sets up the listener at claim time, which may be seconds
    # after boot, so we poll with a short interval.
    sock = None
    for _ in range(600):  # up to 60s
        try:
            s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
            s.connect((HOST_CID, VSOCK_PORT))
            sock = s
            break
        except (ConnectionRefusedError, ConnectionResetError, OSError):
            s.close()
            time.sleep(0.1)
    if sock is None:
        print("config-agent: failed to connect after 60s", file=sys.stderr)
        sys.exit(1)
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

    # Kill pre-started agents for disabled features
    if not cfg.get("fileTransfer"):
        run("pkill -f file-agent.py")
    if not cfg.get("webcam"):
        run("pkill -f webcam-agent.py")

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
