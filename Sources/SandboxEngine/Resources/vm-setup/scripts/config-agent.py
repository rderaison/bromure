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


def write_bromure_version(cfg):
    """Drop the host-supplied appVersion at a known guest-side path so
    later hooks (notably the EV native-messaging stub) can report
    `Bromure-<version>` as the device identity to Google, without
    us having to touch the kernel hostname. Changing the real
    hostname mid-boot races X's Xauthority setup; this file doesn't.
    """
    version = (cfg.get("appVersion") or "").strip()
    if not version:
        return
    os.makedirs("/tmp/bromure", exist_ok=True)
    with open("/tmp/bromure/app-version", "w") as f:
        f.write(version)


def install_managed_mtls(mtls):
    """Drop the managed-profile mTLS material on disk and import it into
    the chrome user's NSS database. No-op if the host didn't send any."""
    if not mtls:
        return
    cert_pem = mtls.get("certPem")
    key_pem = mtls.get("keyPem")
    ca_pem = mtls.get("caPem")
    if not cert_pem or not key_pem or not ca_pem:
        return
    os.makedirs("/tmp/bromure/mtls", exist_ok=True)
    for fn, data in [("cert.pem", cert_pem), ("key.pem", key_pem), ("ca.pem", ca_pem)]:
        with open(f"/tmp/bromure/mtls/{fn}", "w") as f:
            f.write(data)
    os.chmod("/tmp/bromure/mtls/key.pem", 0o600)
    rc, out = run("/usr/local/bin/install-mtls.sh")
    if rc != 0:
        print(f"config-agent: install-mtls.sh failed (rc={rc}): {out}", file=sys.stderr)

    # Long-lived reload agent: dials the host on vsock 5320 and waits
    # for live cert rotations. Only spawned for managed sessions (we're
    # already inside `if not mtls: return`-guarded install flow). Runs
    # detached so config-agent can still exit cleanly.
    try:
        subprocess.Popen(
            ["/usr/local/bin/mtls-reload-agent.py"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except Exception as e:
        print(f"config-agent: mtls-reload-agent spawn failed: {e}", file=sys.stderr)

    # Tell Chromium to auto-select this leaf for the analytics URL so the
    # browser doesn't pop its cert-picker dialog whenever the managed
    # profile hits the endpoint. Only the managed-profile NSS db has a
    # client cert, and this policy file only gets written when the host
    # sent managed-profile mTLS material — default (unmanaged) sessions
    # never see it.
    auto_select_url = mtls.get("autoSelectURL")
    if auto_select_url:
        write_chromium_mtls_policy(auto_select_url)


def write_chromium_mtls_policy(url):
    """Write a Chromium managed-policy file that auto-selects the
    Bromure leaf cert for the analytics URL so Chromium never prompts.
    Merges with the static bromure.json at runtime (Chromium unions
    all JSON files under /etc/chromium/policies/managed/)."""
    policies_dir = "/etc/chromium/policies/managed"
    os.makedirs(policies_dir, exist_ok=True)

    # AutoSelectCertificateForUrls entries are *stringified* JSON per
    # Chromium's schema — a nested object, not a nested string, gets
    # silently ignored. Empty filter matches any cert in the NSS db;
    # the db only contains our leaf.
    auto_select_entry = json.dumps(
        {"pattern": url, "filter": {}}, separators=(",", ":"))

    policy = {
        "AutoSelectCertificateForUrls": [auto_select_entry],
    }
    path = f"{policies_dir}/bromure-mtls.json"
    with open(path, "w") as f:
        json.dump(policy, f)
    os.chmod(path, 0o644)


# Stable Chromium extension id for our corporate-guard extension,
# derived from the RSA public key in its manifest. If the manifest key
# changes, this ID must be recomputed.
CORPORATE_GUARD_EXT_ID = "nneafipcodbpeapjcagfcinodkidcjcp"

# Stable ID derived from the RSA key in
# extensions/file-picker/manifest.json. Must match for the 3rdparty
# managed-storage policy to reach the extension.
FILE_PICKER_EXT_ID = "cjdidalalgkgekmhonlcaleiafjbkdfn"


def write_corporate_guard_policy(cfg):
    """Push the corporate-guard extension's per-session settings via
    chrome.storage.managed. The extension reads these at load time and
    on managed-storage change events. No-op when the admin didn't ship
    any corporate-guard settings for this profile.

    Payload shape (matches extensions/corporate-guard/schema.json):
      {
        "corporateWebsites":      ["www.google.com", ...],
        "openExternalInPrivate":  true|false,
        "tracingEnabled":         true|false
      }

    Chromium's managed-storage delivery is nested under
    `3rdparty.extensions.<ext_id>` in a regular managed-policy file.
    """
    guard = cfg.get("corporateGuard")
    if not guard:
        return
    settings = {
        "corporateWebsites": guard.get("corporateWebsites", []),
        "openExternalInPrivate": bool(guard.get("openExternalInPrivate", False)),
        # The extension uses tracingEnabled to decide whether to show
        # the banner in non-private mode. Pulled from the session-level
        # traceLevel rather than the profile setting so that host-side
        # runtime overrides (via the session toggle) are respected.
        "tracingEnabled": int(cfg.get("traceLevel", 0)) > 0,
    }
    policy = {
        "3rdparty": {
            "extensions": {
                CORPORATE_GUARD_EXT_ID: settings,
            }
        }
    }
    policies_dir = "/etc/chromium/policies/managed"
    os.makedirs(policies_dir, exist_ok=True)
    path = f"{policies_dir}/bromure-corporate-guard.json"
    with open(path, "w") as f:
        json.dump(policy, f)
    os.chmod(path, 0o644)


def write_file_picker_policy(cfg):
    """Push the file-picker extension's per-session `fileUploadEnabled`
    flag via chrome.storage.managed. Always written so the extension
    can tell the difference between "policy explicitly says off" and
    "policy not yet delivered".
    """
    settings = {
        "fileUploadEnabled": bool(cfg.get("fileTransfer", False)),
    }
    policy = {
        "3rdparty": {
            "extensions": {
                FILE_PICKER_EXT_ID: settings,
            }
        }
    }
    policies_dir = "/etc/chromium/policies/managed"
    os.makedirs(policies_dir, exist_ok=True)
    path = f"{policies_dir}/bromure-file-picker.json"
    with open(path, "w") as f:
        json.dump(policy, f)
    os.chmod(path, 0o644)


def sh_escape(s):
    """Escape a string for safe use as a single-quoted shell value."""
    return "'" + str(s).replace("'", "'\\''") + "'"


def write_chrome_env(cfg):
    """Build and write the chrome-env file."""
    env_file = "/tmp/bromure/chrome-env"
    lines = []

    extra_flags = []
    enable_features = []
    # LcdText: Chromium's subpixel text in compositor layers. macOS Chrome uses
    # grayscale AA; disabling here matches that path and avoids the slight
    # chromatic fringing/blur that subpixel rendering produces on this display.
    disable_features = ["LcdText"]

    if cfg.get("darkMode"):
        extra_flags.append("--force-dark-mode")
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
        extra_flags.append("--proxy-bypass-list=<-loopback>")
    if cfg.get("disableGPU"):
        extra_flags.append("--disable-gpu")
    else:
        # GPU acceleration enabled — add GL/rasterization flags
        if cfg.get("gpuAccel"):
            extra_flags.append("--use-gl=angle")
            extra_flags.append("--use-angle=gl")
            extra_flags.append("--ignore-gpu-blocklist")
            extra_flags.append("--enable-gpu-rasterization")
    if cfg.get("disableWebGL"):
        extra_flags.append("--disable-webgl --disable-3d-apis")
    if cfg.get("zeroCopy"):
        extra_flags.append("--enable-zero-copy")
    if cfg.get("smoothScrolling"):
        extra_flags.append("--enable-smooth-scrolling")

    extensions = []
    if cfg.get("phishingGuard"):
        extensions.append("/opt/bromure/extensions/phishing-guard")
    if cfg.get("linkSender"):
        extensions.append("/opt/bromure/extensions/link-sender")
    # file-picker is always loaded — when uploads are disabled it still
    # intercepts file-input clicks to show an in-page "uploads disabled"
    # overlay, much friendlier than Chromium's fallback Linux file
    # dialog. The per-session `fileUploadEnabled` policy written below
    # tells the extension which mode to run in.
    extensions.append("/opt/bromure/extensions/file-picker")
    if cfg.get("fileTransfer"):
        # Only the enabled branch needs chrome.debugger attachment, so
        # only suppress the "extensions are debugging your browser"
        # banner in that case.
        extra_flags.append("--silent-debugger-extension-api")
    # Trace extension: loaded when traceLevel > 0
    trace_level = cfg.get("traceLevel", 0)
    if trace_level > 0:
        extensions.append("/opt/bromure/extensions/trace")
        # Level 3 (full) needs debugger API without the infobar
        if trace_level >= 3 and not cfg.get("fileTransfer"):
            extra_flags.append("--silent-debugger-extension-api")
    if cfg.get("passkeys") or cfg.get("passwords"):
        extensions.append("/opt/bromure/extensions/credential-bridge")
    if cfg.get("passkeys"):
        # Disable Chromium's built-in WebAuthn UI so passkey requests go through our extension
        disable_features.append("WebAuthenticationConditionalUI")
        extra_flags.append("--webauthn-remote-desktop-support")
    # WebRTC block extension: loaded only when both webcam and microphone are off
    if not cfg.get("webcam") and not cfg.get("microphone"):
        extensions.append("/opt/bromure/extensions/webrtc-block")
    # IP-register: heartbeats the browser's egress IP to analytics.bromure.io
    # so the control plane can keep customer IdP allowlists in sync. Managed
    # sessions only — it piggybacks on the same mTLS leaf + AutoSelect policy
    # we already deploy for cfg["mtls"], so there's no point running it where
    # neither exists.
    if cfg.get("mtls"):
        extensions.append("/opt/bromure/extensions/ip-register")
    # Corporate Guard: banner-or-redirect non-corporate sites per managed
    # profile settings. Only makes sense when there's a managed profile
    # AND the admin supplied corporateWebsites / openExternalInPrivate.
    # The managed-storage policy is written separately (see
    # write_corporate_guard_policy() below).
    if cfg.get("mtls") and cfg.get("corporateGuard"):
        extensions.append("/opt/bromure/extensions/corporate-guard")
    if extensions:
        extra_flags.append(f"--load-extension={','.join(extensions)}")
        # Only allow our bundled extensions — disable every other extension
        # Chromium might try to load (policy-pushed, user-installed in a
        # persistent profile, etc.).
        extra_flags.append(f"--disable-extensions-except={','.join(extensions)}")

    profile_dir = cfg.get("profileDir")
    if profile_dir:
        extra_flags.append(f"--user-data-dir={profile_dir}")
        enable_features.append("WebAuthenticationNewPasskeyUI")
    if cfg.get("restoreSession"):
        extra_flags.append("--restore-last-session")
    if cfg.get("microphone"):
        disable_features.append("AudioServiceOutOfProcess")

    # Always enable Chrome DevTools Protocol on localhost — used by the CJK
    # input agent for inline IME composition, and by the CDP automation bridge.
    extra_flags.append("--remote-debugging-port=9222")
    extra_flags.append("--remote-debugging-address=127.0.0.1")

    # Disable WebRTC when both webcam and microphone are off (skip for IKEv2
    # — these flags can interfere with private network access through the tunnel)
    if not cfg.get("webcam") and not cfg.get("microphone") and not cfg.get("enableIKEv2"):
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
    if cfg.get("automation"):
        lines.append("AUTOMATION=1")
    if cfg.get("nativeChrome"):
        lines.append("NATIVE_CHROME=1")
    if cfg.get("debugShell"):
        lines.append("DEBUG_SHELL=1")
    if cfg.get("traceLevel", 0) > 0:
        lines.append(f"TRACE_LEVEL={cfg['traceLevel']}")

    # Signal to xinitrc that a VPN auto-connect is in flight: xinitrc shows a
    # splash screen until the VPN agent writes /tmp/bromure/vpn-status so the
    # user's first HTTP request never leaves the VM before the tunnel is up.
    if cfg.get("warpAutoConnect"):
        lines.append("VPN_AUTO_CONNECT=warp")
    elif cfg.get("wireGuardAutoConnect"):
        lines.append("VPN_AUTO_CONNECT=wireguard")
    elif cfg.get("ikev2AutoConnect"):
        lines.append("VPN_AUTO_CONNECT=ikev2")

    # Display scale: passed at runtime so changing 1x/2x doesn't require image rebuild
    display_scale = cfg.get("displayScale", 2)
    lines.append(f"DISPLAY_SCALE={display_scale}")

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


def write_ikev2_config(cfg):
    """Write strongSwan swanctl.conf for IKEv2 VPN."""
    server = cfg.get("ikev2Server", "")
    remote_id = cfg.get("ikev2RemoteID", server)
    method = cfg.get("ikev2AuthMethod", "eap")
    use_dns = cfg.get("ikev2UseDNS", True)

    # macOS-compatible cipher proposals
    proposals = "aes256gcm16-sha384-ecp384,aes256gcm16-sha256-ecp256,aes256gcm16-sha256-modp2048,aes256-sha256-ecp256"
    esp_proposals = "aes256gcm16-ecp384,aes256gcm16-ecp256,aes256gcm16-modp2048,aes256-sha256-ecp256"

    # Build connection section based on auth method
    username = cfg.get("ikev2Username", "")
    if method == "eap":
        local_auth = "auth = eap-mschapv2\n            id = {}\n            eap_id = {}".format(username, username)
        remote_auth = "auth = pubkey"
    elif method == "certificate":
        local_auth = "auth = pubkey\n            certs = client.crt"
        remote_auth = "auth = pubkey"
    elif method == "psk":
        local_auth = "auth = psk"
        remote_auth = "auth = psk"
    else:
        local_auth = "auth = eap-mschapv2"
        remote_auth = "auth = pubkey"

    updown_line = '                updown = /etc/swanctl/updown.sh'

    conf = """connections {{
    bromure-vpn {{
        version = 2
        proposals = {proposals}
        dpd_delay = 30s
        encap = yes
        remote_addrs = {server}
        vips = 0.0.0.0

        local {{
            {local_auth}
        }}
        remote {{
            {remote_auth}
            id = {remote_id}
        }}

        children {{
            bromure-child {{
                local_ts = 0.0.0.0/0
                remote_ts = 0.0.0.0/0
                esp_proposals = {esp_proposals}
                dpd_action = restart
                start_action = none
{updown_line}
            }}
        }}
    }}
}}
""".format(
        proposals=proposals,
        esp_proposals=esp_proposals,
        server=server,
        local_auth=local_auth,
        remote_auth=remote_auth,
        remote_id=remote_id,
        updown_line=updown_line,
    )

    # Build secrets section
    secrets = ""
    if method == "eap":
        password = cfg.get("ikev2Password", "")
        # id must match eap_id so strongSwan finds the secret during EAP exchange.
        # Use both the username and the server identity to cover all lookup patterns.
        secrets = """secrets {{
    eap-bromure {{
        id0 = {username}
        id1 = {remote_id}
        secret = "{password}"
    }}
}}
""".format(username=username, remote_id=remote_id,
           password=password.replace('"', '\\"'))
    elif method == "psk":
        psk = cfg.get("ikev2PSK", "")
        secrets = """secrets {{
    ike-bromure {{
        secret = "{psk}"
    }}
}}
""".format(psk=psk.replace('"', '\\"'))

    os.makedirs("/etc/swanctl/conf.d", exist_ok=True)
    with open("/etc/swanctl/conf.d/bromure.conf", "w") as f:
        f.write(conf)
        if secrets:
            f.write(secrets)
    os.chmod("/etc/swanctl/conf.d/bromure.conf", 0o600)

    # For certificate auth, decode PKCS#12 and extract cert/key
    if method == "certificate":
        cert_b64 = cfg.get("ikev2ClientCert", "")
        cert_pass = cfg.get("ikev2CertPassphrase", "")
        if cert_b64:
            import base64
            p12_data = base64.b64decode(cert_b64)
            p12_path = "/tmp/bromure/client.p12"
            with open(p12_path, "wb") as f:
                f.write(p12_data)
            os.chmod(p12_path, 0o600)

            # Extract client cert and private key using openssl
            pass_arg = "-passin pass:{}".format(cert_pass) if cert_pass else "-passin pass:"
            os.makedirs("/etc/swanctl/x509", exist_ok=True)
            os.makedirs("/etc/swanctl/private", exist_ok=True)
            subprocess.run(
                "openssl pkcs12 -in {p12} -clcerts -nokeys {pw} -out /etc/swanctl/x509/client.crt 2>/dev/null".format(
                    p12=p12_path, pw=pass_arg),
                shell=True)
            subprocess.run(
                "openssl pkcs12 -in {p12} -nocerts -nodes {pw} -out /etc/swanctl/private/client.key 2>/dev/null".format(
                    p12=p12_path, pw=pass_arg),
                shell=True)
            os.chmod("/etc/swanctl/private/client.key", 0o600)
            os.unlink(p12_path)

    # Write IKEv2 proxy config for the updown script to use
    ikev2_proxy_host = cfg.get("ikev2ProxyHost", "")
    ikev2_proxy_port = cfg.get("ikev2ProxyPort", 0)
    ikev2_proxy_user = cfg.get("ikev2ProxyUsername", "")
    ikev2_proxy_pass = cfg.get("ikev2ProxyPassword", "")
    if ikev2_proxy_host and ikev2_proxy_port:
        with open("/tmp/bromure/ikev2-proxy.conf", "w") as f:
            f.write(f"{ikev2_proxy_host}\n{ikev2_proxy_port}\n{ikev2_proxy_user}\n{ikev2_proxy_pass}\n")

    # Write updown script for routing and DNS integration
    use_dns_sh = "true" if use_dns else "false"
    updown_script = """#!/bin/sh
# strongSwan updown script — handles routing + DNS for Bromure IKEv2
USE_DNS={use_dns}
DNSMASQ_VPN_CONF="/etc/dnsmasq.d/vpn-dns.conf"
GW_FILE="/tmp/bromure/ikev2-orig-gw"

case "$PLUTO_VERB" in
    up-client)
        # Add the virtual IP to eth0 so the kernel can source packets from it
        if [ -n "$PLUTO_MY_SOURCEIP" ]; then
            ip addr add "$PLUTO_MY_SOURCEIP/32" dev eth0 2>/dev/null
        fi

        # Save original default gateway
        ORIG_GW=$(ip route show default | head -1)
        echo "$ORIG_GW" > "$GW_FILE"

        # Route to the VPN server via the original gateway (so ESP packets aren't looped)
        if [ -n "$PLUTO_PEER" ]; then
            GW_IP=$(echo "$ORIG_GW" | grep -oE 'via [0-9.]+' | awk '{{print $2}}')
            GW_DEV=$(echo "$ORIG_GW" | grep -oE 'dev [a-z0-9]+' | awk '{{print $2}}')
            if [ -n "$GW_IP" ] && [ -n "$GW_DEV" ]; then
                ip route add "$PLUTO_PEER/32" via "$GW_IP" dev "$GW_DEV" 2>/dev/null
            fi
        fi

        # Install routes based on negotiated traffic selectors.
        # PLUTO_PEER_CLIENT contains the remote TS (e.g. "0.0.0.0/0" or "10.0.0.0/24").
        if [ -n "$PLUTO_MY_SOURCEIP" ]; then
            GW_IP=$(echo "$ORIG_GW" | grep -oE 'via [0-9.]+' | awk '{{print $2}}')
            GW_DEV=$(echo "$ORIG_GW" | grep -oE 'dev [a-z0-9]+' | awk '{{print $2}}')
            if [ -n "$GW_IP" ]; then
                if [ "$PLUTO_PEER_CLIENT" = "0.0.0.0/0" ]; then
                    # Full tunnel — replace default route
                    ip route del default 2>/dev/null
                    ip route add default via "$GW_IP" dev "$GW_DEV" src "$PLUTO_MY_SOURCEIP" 2>/dev/null
                else
                    # Split tunnel — only route the pushed subnet(s)
                    ip route add "$PLUTO_PEER_CLIENT" via "$GW_IP" dev "$GW_DEV" src "$PLUTO_MY_SOURCEIP" 2>/dev/null
                fi
            fi
        fi

        # Configure squid cache_peer if an IKEv2 proxy is set
        PROXY_CONF="/tmp/bromure/ikev2-proxy.conf"
        SQUID_CONF="/etc/squid/squid.conf"
        if [ -f "$PROXY_CONF" ]; then
            PHOST=$(sed -n '1p' "$PROXY_CONF")
            PPORT=$(sed -n '2p' "$PROXY_CONF")
            PUSER=$(sed -n '3p' "$PROXY_CONF")
            PPASS=$(sed -n '4p' "$PROXY_CONF")
            # Remove any existing cache_peer/login lines
            sed -i '/^cache_peer /d' "$SQUID_CONF"
            sed -i '/^never_direct /d' "$SQUID_CONF"
            # Add parent proxy
            if [ -n "$PUSER" ] && [ -n "$PPASS" ]; then
                echo "cache_peer $PHOST parent $PPORT 0 no-query default login=$PUSER:$PPASS" >> "$SQUID_CONF"
            else
                echo "cache_peer $PHOST parent $PPORT 0 no-query default" >> "$SQUID_CONF"
            fi
            echo "never_direct allow all" >> "$SQUID_CONF"
        fi

        # Kill Squid so resilient-launch.sh restarts it with new routes/DNS
        pkill -f "squid -N" 2>/dev/null

        # DNS
        if [ "$USE_DNS" = "true" ] && [ -n "$PLUTO_DNS" ]; then
            : > "$DNSMASQ_VPN_CONF"
            for dns in $PLUTO_DNS; do
                echo "server=$dns" >> "$DNSMASQ_VPN_CONF"
            done
            if [ -f /var/run/dnsmasq.pid ]; then
                kill -HUP $(cat /var/run/dnsmasq.pid) 2>/dev/null
            else
                cp /etc/resolv.conf /etc/resolv.conf.bak.ikev2 2>/dev/null
                : > /etc/resolv.conf
                for dns in $PLUTO_DNS; do
                    echo "nameserver $dns" >> /etc/resolv.conf
                done
            fi
        fi
        ;;
    down-client)
        # Restore routes
        if [ -f "$GW_FILE" ]; then
            ORIG_GW=$(cat "$GW_FILE")
            if [ "$PLUTO_PEER_CLIENT" = "0.0.0.0/0" ] && [ -n "$ORIG_GW" ]; then
                # Full tunnel — restore default route
                ip route del default 2>/dev/null
                ip route add $ORIG_GW 2>/dev/null
            else
                # Split tunnel — remove the pushed subnet route
                ip route del "$PLUTO_PEER_CLIENT" 2>/dev/null
            fi
            rm -f "$GW_FILE"
        fi

        # Remove server-specific route
        if [ -n "$PLUTO_PEER" ]; then
            ip route del "$PLUTO_PEER/32" 2>/dev/null
        fi

        # Remove virtual IP
        if [ -n "$PLUTO_MY_SOURCEIP" ]; then
            ip addr del "$PLUTO_MY_SOURCEIP/32" dev eth0 2>/dev/null
        fi

        # Remove IKEv2 proxy cache_peer from squid and restart
        SQUID_CONF="/etc/squid/squid.conf"
        sed -i '/^cache_peer /d' "$SQUID_CONF"
        sed -i '/^never_direct /d' "$SQUID_CONF"
        pkill -f "squid -N" 2>/dev/null

        # Restore DNS
        rm -f "$DNSMASQ_VPN_CONF"
        if [ -f /var/run/dnsmasq.pid ]; then
            kill -HUP $(cat /var/run/dnsmasq.pid) 2>/dev/null
        elif [ -f /etc/resolv.conf.bak.ikev2 ]; then
            mv /etc/resolv.conf.bak.ikev2 /etc/resolv.conf
        fi
        ;;
esac
""".format(use_dns=use_dns_sh)
    os.makedirs("/etc/swanctl", exist_ok=True)
    with open("/etc/swanctl/updown.sh", "w") as f:
        f.write(updown_script)
    os.chmod("/etc/swanctl/updown.sh", 0o755)


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

    # Disable Chrome's built-in password manager when our credential bridge handles passwords
    if cfg.get("passwords"):
        policy["PasswordManagerEnabled"] = False
        policy["AutofillCreditCardEnabled"] = False
        policy["CredentialProviderPromoEnabled"] = False

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

    # WireGuard: write config and boot markers for wireguard-agent.
    # The agent handles bringing up the wg0 tunnel at boot and on
    # enable/disable commands.  wg-quick routes all guest traffic
    # through the tunnel at the kernel level — no proxy changes needed.
    wg_config = cfg.get("wireGuardConfig")
    if wg_config:
        os.makedirs("/etc/wireguard", exist_ok=True)
        with open("/etc/wireguard/wg0.conf", "w") as f:
            f.write(wg_config)
        os.chmod("/etc/wireguard/wg0.conf", 0o600)
        open("/tmp/bromure/wireguard-boot-setup", "w").close()
        if cfg.get("wireGuardAutoConnect"):
            open("/tmp/bromure/wireguard-auto-connect", "w").close()

    # IKEv2/IPsec: write swanctl.conf, start charon, and load config.
    if cfg.get("enableIKEv2"):
        write_ikev2_config(cfg)
        # Copy custom CAs into strongSwan's trust store before loading config
        if ca_count > 0:
            os.makedirs("/etc/swanctl/x509ca", exist_ok=True)
            subprocess.run(
                "cp /tmp/bromure/custom-cas/*.crt /etc/swanctl/x509ca/ 2>/dev/null",
                shell=True)
        # Start charon and load the config now so it's ready for the agent
        subprocess.run("ipsec start 2>/dev/null", shell=True)
        # Wait for charon socket to appear
        for _ in range(20):
            if os.path.exists("/var/run/charon.vici"):
                break
            time.sleep(0.5)
        subprocess.run("swanctl --load-all 2>/dev/null", shell=True)
        open("/tmp/bromure/ikev2-boot-setup", "w").close()
        if cfg.get("ikev2AutoConnect"):
            open("/tmp/bromure/ikev2-auto-connect", "w").close()

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

    # Wait for eth0 to get an IP via DHCP before starting Squid.
    # config-agent starts via inittab concurrently with the networking service,
    # and Squid reads /etc/resolv.conf at startup and caches DNS servers.
    # If DHCP hasn't completed yet, resolv.conf is stale/empty and DNS fails.
    if not has_custom_proxy:
        for _attempt in range(50):  # up to 5 seconds
            rc, out = run("ip -4 addr show dev eth0 scope global")
            if rc == 0 and "inet " in out:
                break
            time.sleep(0.1)
        else:
            print("config-agent: WARNING: eth0 has no IP after 5s, network may not work",
                  file=sys.stderr)

    has_wireguard = bool(cfg.get("wireGuardConfig"))

    if cfg.get("blockMalware"):
        run("sed -i 's/^server=1\\.1\\.1\\.1/server=1.1.1.2/' /etc/dnsmasq.d/pihole.conf")
        run("sed -i 's/^server=1\\.0\\.0\\.1/server=1.0.0.2/' /etc/dnsmasq.d/pihole.conf")

    # For WireGuard profiles without ad-blocking: strip addn-hosts so dnsmasq
    # acts as a pure DNS forwarder.  wireguard-agent will swap the server= lines
    # at connect/disconnect time via SIGHUP.  We don't strip for other profiles
    # (WARP, ad-blocking) to preserve their existing DNS behaviour.
    if has_wireguard and not cfg.get("adBlocking"):
        run("sed -i '/^addn-hosts/d' /etc/dnsmasq.d/pihole.conf")

    # Start dnsmasq when needed.
    # WireGuard always needs it: squid must use a local resolver so wireguard-agent
    # can switch DNS upstreams at runtime without touching squid (squid does not
    # handle SIGHUP cleanly in foreground -N mode).
    needs_dnsmasq = (cfg.get("adBlocking") or cfg.get("blockMalware")
                     or cfg.get("enableWarp") or has_wireguard)
    if needs_dnsmasq and not has_custom_proxy:
        run("dnsmasq -C /etc/dnsmasq.d/pihole.conf")

    # Configure squid DNS.
    # For WireGuard profiles: always point squid at dnsmasq so the DNS upstream
    # can be switched without reloading squid.
    # For ad-blocking / malware-blocking: same (as before).
    # For everything else (WARP without ad-blocking, plain profiles): delete the
    # line so squid uses resolv.conf directly — preserving the original behaviour.
    if cfg.get("adBlocking") or cfg.get("blockMalware") or has_wireguard:
        run("sed -i 's/^dns_nameservers.*/dns_nameservers 127.0.0.1/' /etc/squid/squid.conf")
    else:
        run("sed -i '/^dns_nameservers/d' /etc/squid/squid.conf")

    # Start routing-socks.py on :40001 — proxychains always points here.
    # It switches per-connection between warp-svc (:40000) and direct
    # based on /tmp/bromure/warp-active flag.  Without WARP, the flag
    # never exists so all connections go direct.
    if not has_custom_proxy:
        subprocess.Popen(
            ["/usr/local/bin/resilient-launch.sh",
             "/usr/local/bin/routing-socks.py"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        # Start squid through proxychains (auto-restarted on crash).
        subprocess.Popen(
            ["/usr/local/bin/resilient-launch.sh",
             "proxychains4", "-q", "-f", "/etc/proxychains/proxychains.conf",
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

    # Sync system clock from the PL031 hardware RTC immediately on boot.
    # Alpine VMs start with the clock frozen at base-image build time; the RTC
    # (backed by the host's wall clock) has the real time.  TLS certificate
    # validation and WireGuard handshakes both fail with a wrong clock, so this
    # must happen before squid, dnsmasq, or Chromium start.
    os.system("hwclock --hctosys 2>/dev/null")

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

    # Sync system clock from host-provided Unix timestamp.
    # hwclock --hctosys (called earlier) relies on the rtc-pl031 kernel module,
    # which may not load if the Alpine linux-lts package was updated since the
    # module was compiled (kernel version mismatch).  Injecting the timestamp
    # directly from the host config is a reliable fallback that works regardless
    # of RTC availability and requires no ongoing KVER maintenance.
    if ts := cfg.get("currentTime"):
        os.system(f"date -s @{int(ts)} >/dev/null 2>&1")
        print(f"config-agent: clock set from host time ({int(ts)})", file=sys.stderr)

    # Drop the app version on disk so the EV native-messaging stub can
    # synthesize `Bromure-<version>` as the reported device identity
    # without changing the kernel hostname (which would race X's
    # Xauthority and crash Chromium).
    write_bromure_version(cfg)

    # No global wait_for_on_boot — only WARP-dependent paths wait internally.

    # Mount profile disk (if persistent)
    if cfg.get("profileDisk"):
        mount_profile_disk(cfg)

    # Write custom CAs
    ca_count = write_custom_cas(cfg.get("rootCAs"))

    # Managed-profile mTLS client cert → NSS database
    install_managed_mtls(cfg.get("mtls"))

    # Corporate-guard extension's managed-storage config (only when the
    # admin configured corporateWebsites / openExternalInPrivate).
    write_corporate_guard_policy(cfg)

    # File-picker extension runs unconditionally but reads its enabled
    # flag from managed storage — write it so the overlay-vs-real-picker
    # branch is correct from first page load.
    write_file_picker_policy(cfg)

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
