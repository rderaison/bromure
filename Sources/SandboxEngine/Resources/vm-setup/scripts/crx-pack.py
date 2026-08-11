#!/usr/bin/env python3
"""Pack Bromure extensions into signed .crx files at image-bake time.

Branded Google Chrome ignores the --load-extension command-line flag
(Chromium honours it), so under Chrome the extensions are force-installed
via the ExtensionInstallForcelist enterprise policy instead — which needs
each extension as a signed .crx served from a self-hosted update manifest.

Run inside the Ubuntu chroot (has chromium + python3). Reads the committed
signing keys + id map from /tmp/crx-keys/mapping.json, packs each extension
present under /opt/bromure/extensions, and writes:

    /opt/bromure/crx/<ext>/ext.crx      (signed with the committed key)
    /opt/bromure/crx/<ext>/update.xml   (file:// update manifest)
    /opt/bromure/crx/ids.json           ({ext: extension-id}) for config-agent

The signing keys are NOT copied into the image — only the .crx files are.
Chrome derives the extension id from the CRX signing key, and each
extension's manifest "key" is the matching public key, so Chromium's
--load-extension path and Chrome's force-install path share one id.
"""

import json
import os
import re
import subprocess
import sys

KEYS_DIR = "/tmp/crx-keys"
EXT_DIR = "/opt/bromure/extensions"
OUT_DIR = "/opt/bromure/crx"

UPDATE_XML = """<?xml version="1.0" encoding="UTF-8"?>
<gupdate xmlns="http://www.google.com/update2/response" protocol="2.0">
  <app appid="{id}">
    <updatecheck codebase="file://{crx}" version="{version}" />
  </app>
</gupdate>
"""


def find_chromium():
    """Resolve the real chromium ELF, bypassing xtradeb's /usr/bin/chromium
    launcher wrapper — its early environment checks (a `[ -lt ]` on a var
    that's unset in the bare bake chroot) abort before it ever exec's the
    binary, so packing must call the binary itself."""
    for p in ("/usr/lib/chromium/chromium", "/usr/lib/chromium/chrome",
              "/usr/lib/chromium-browser/chromium-browser"):
        if os.path.exists(p):
            return p
    # Fall back to the exec target inside the wrapper script.
    try:
        for line in open("/usr/bin/chromium"):
            m = re.search(r'exec\s+"?(/\S*?chrom\S*?)"?\s', line)
            if m and os.path.exists(m.group(1)):
                return m.group(1)
    except OSError:
        pass
    return "chromium"


def main():
    mapping = json.load(open(os.path.join(KEYS_DIR, "mapping.json")))
    os.makedirs(OUT_DIR, exist_ok=True)
    chromium = find_chromium()
    print(f"crx-pack: using chromium binary {chromium}", file=sys.stderr)
    ids = {}
    for ext, info in mapping.items():
        extdir = os.path.join(EXT_DIR, ext)
        keyfile = os.path.join(KEYS_DIR, f"{ext}.pem")
        if not os.path.isdir(extdir) or not os.path.isfile(keyfile):
            print(f"crx-pack: skip {ext} (missing dir or key)", file=sys.stderr)
            continue
        # chromium writes <extdir>.crx next to the source dir; HOME must be
        # writable for its throwaway profile.
        r = subprocess.run(
            [chromium, "--headless", "--no-sandbox",
             f"--pack-extension={extdir}", f"--pack-extension-key={keyfile}"],
            capture_output=True, text=True, timeout=120,
            env={**os.environ, "HOME": "/tmp"},
        )
        crx_src = f"{extdir}.crx"
        if not os.path.isfile(crx_src):
            print(f"crx-pack: FAILED to pack {ext}: {r.stderr.strip()[:200]}",
                  file=sys.stderr)
            continue
        outdir = os.path.join(OUT_DIR, ext)
        os.makedirs(outdir, exist_ok=True)
        crx_dst = os.path.join(outdir, "ext.crx")
        os.replace(crx_src, crx_dst)
        version = json.load(open(os.path.join(extdir, "manifest.json"))).get("version", "1.0")
        with open(os.path.join(outdir, "update.xml"), "w") as f:
            f.write(UPDATE_XML.format(id=info["id"], crx=crx_dst, version=version))
        ids[ext] = info["id"]
        print(f"crx-pack: {ext} -> {info['id']}")

    with open(os.path.join(OUT_DIR, "ids.json"), "w") as f:
        json.dump(ids, f)
    # Ownership: chrome must read the crx + update.xml at force-install time.
    subprocess.run(["chown", "-R", "chrome:chrome", OUT_DIR], check=False)
    print(f"crx-pack: packed {len(ids)} extensions")


if __name__ == "__main__":
    main()
