#!/usr/bin/env python3
"""Fetch a prebuilt, signed guest kernel module from the CDN (image build).

Jenkinsfile.zeropages publishes bromure_zeropages for every Ubuntu kernel at
https://dl.bromure.io/zeropages/<sourceHash>/catalog.json (the sentry's
scheme: tools/make-sentry-catalog.mjs --module zeropages). setup.sh runs this
in the image chroot for the kernel it just installed; when it fails for any
reason, setup.sh builds the module from the bundled source instead.

Trust: the module is used only if its OWN signature verifies against the
app's pinned Sparkle public key. That signature covers a domain-separated
statement (bromure-<module>-module-v1, sourceHash, kernel, sha256, bytes), so
a tampered catalog can't vouch for other bytes, and the sourceHash must be
that of the source this image ships. ed25519 is checked with the openssl CLI
(OpenSSL 3, in the base system); python has no ed25519 of its own.

    fetch-guest-module.py <module> <kernel> <source dir> <out .ko>
exit 0 = <out .ko> written and verified; anything else = not used.
"""

import base64
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.request

BASE = os.environ.get("BROMURE_MODULE_BASE", "https://dl.bromure.io/")
# Must match ImageCatalogStore.pinnedPublicKeyBase64 / SUPublicEDKey.
PUBLIC_KEY = os.environ.get("BROMURE_MODULE_PUBLIC_KEY",
                            "G1ofi8zFFgNyE5Momw+eoWeiBt8NGCiKQWAs+YBvZK8=")
SOURCES = {"zeropages": ["Makefile", "bromure_zeropages.c"]}
MAX_BYTES = 16 << 20


def source_hash(module, src_dir):
    """scripts/zeropages/source-hash.sh: sha256 over the source files, each
    framed as name\\n<length>\\n<bytes>."""
    h = hashlib.sha256()
    for name in SOURCES[module]:
        with open(os.path.join(src_dir, name), "rb") as f:
            data = f.read()
        h.update(f"{name}\n{len(data)}\n".encode())
        h.update(data)
    return h.hexdigest()


def module_payload(module, src_hash, m):
    return "\n".join([f"bromure-{module}-module-v1", f"sourceHash={src_hash}",
                      f"kernel={m['kernel']}", f"sha256={m['sha256'].lower()}",
                      f"bytes={m['bytes']}"]).encode()


def ed25519_valid(payload, signature_b64):
    raw = base64.b64decode(PUBLIC_KEY)
    if len(raw) != 32:
        return False
    der = bytes.fromhex("302a300506032b6570032100") + raw
    with tempfile.TemporaryDirectory() as d:
        pem = os.path.join(d, "key.pem")
        with open(pem, "w") as f:
            f.write("-----BEGIN PUBLIC KEY-----\n" + base64.b64encode(der).decode()
                    + "\n-----END PUBLIC KEY-----\n")
        msg, sig = os.path.join(d, "msg"), os.path.join(d, "sig")
        with open(msg, "wb") as f:
            f.write(payload)
        with open(sig, "wb") as f:
            f.write(base64.b64decode(signature_b64))
        r = subprocess.run(["openssl", "pkeyutl", "-verify", "-pubin", "-inkey", pem,
                            "-rawin", "-in", msg, "-sigfile", sig],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return r.returncode == 0


def get(url, limit):
    # The CDN answers 403 to urllib's default "Python-urllib/3.x" agent.
    req = urllib.request.Request(url, headers={"User-Agent": "bromure-image-build"})
    with urllib.request.urlopen(req, timeout=30) as r:
        data = r.read(limit + 1)
    if len(data) > limit:
        raise ValueError(f"{url}: larger than {limit} bytes")
    return data


def main():
    module, kernel, src_dir, out = sys.argv[1:5]
    if module not in SOURCES or not re.fullmatch(r"[0-9][0-9A-Za-z.+~-]*", kernel):
        print(f"fetch-guest-module: bad arguments {module} {kernel}")
        return 2
    src_hash = source_hash(module, src_dir)
    catalog = json.loads(get(f"{BASE}{module}/{src_hash}/catalog.json", 1 << 20))
    if catalog.get("sourceHash") != src_hash:
        print("fetch-guest-module: catalog is for another source")
        return 1
    entry = next((m for m in catalog.get("modules", []) if m.get("kernel") == kernel), None)
    if entry is None:
        print(f"fetch-guest-module: no {module} module published for {kernel} (source {src_hash[:12]})")
        return 1
    path = entry.get("path", "")
    if not path.startswith(f"{module}/{src_hash}/{kernel}/") or ".." in path:
        print(f"fetch-guest-module: odd module path {path}")
        return 1
    if not ed25519_valid(module_payload(module, src_hash, entry), entry.get("signature", "")):
        print(f"fetch-guest-module: {module} module for {kernel}: signature does NOT verify")
        return 1
    body = get(BASE + path, MAX_BYTES)
    if len(body) != entry["bytes"] or hashlib.sha256(body).hexdigest() != entry["sha256"].lower():
        print(f"fetch-guest-module: {module} module for {kernel} doesn't match its signed sha256/size")
        return 1
    with open(out, "wb") as f:
        f.write(body)
    print(f"fetch-guest-module: {module} for {kernel}: verified {entry['sha256'][:12]} ({len(body)} bytes)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # network, JSON, missing openssl: build from source instead
        print(f"fetch-guest-module: {e}")
        sys.exit(1)
