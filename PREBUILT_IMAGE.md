# Prebuilt Base Images

Installing Bromure used to build the base images locally on every machine
(~10 min: Alpine netboot → `setup.sh`). New installations now **download a
prebuilt image** from DigitalOcean Spaces instead, and only fall back to
the local build when the download isn't available (offline, CDN outage).

Two channels share the same mechanism (catalog model, ed25519 signing,
download plumbing, chroot postinstall — all in
`Sources/SandboxEngine/ImageCatalog.swift` / `ImageFetch.swift`):

| | Bromure Agentic Coding | Bromure Web |
|---|---|---|
| CDN prefix | `images/` | `browser-images/` |
| Image | Ubuntu 24.04, 24 GB sparse, EFI/GRUB | Alpine + Chromium, 4.5 GB, direct kernel boot |
| Artifacts | `base.img.gz` | `base.img.gz` + `vmlinuz.gz` + `initrd.gz` (catalog `boot` array) |
| Version constant | `UbuntuImageManager.imageVersion` | `LinuxImageManager.imageVersion` |
| Baseline (canonical postinstall) | `Sources/AgentCoding/Resources/img-catalog.json` | `Sources/SandboxEngine/Resources/browser-img-catalog.json` |
| Non-free postinstall | Claude Code, Codex, Grok, gcloud | Cloudflare WARP |
| Signing payload magic | `bromure-img-catalog-v1` | `bromure-browser-img-catalog-v1` |
| Pipeline | `Jenkinsfile.image` → `scripts/publish-image.sh` | `Jenkinsfile.browser-image` → `scripts/publish-browser-image.sh` |

The channel-specific configuration lives in `ImageDistribution`
(`.agentCoding` in `Sources/AgentCoding/ImageCatalogAC.swift`, `.browser`
in SandboxEngine). The browser machinery deliberately lives in
**SandboxEngine**, not the browser executable, so Bromure AC can drive
the exact same download + postinstall when the user opts into the
embedded web browser (AC already boots the browser image via
`LinuxImageManager.hasBootFiles`).

# Bromure Agentic Coding (`images/`)

## The free-software constraint

The published image must be redistributable, so it can **not** contain
non-free software. `setup.sh` builds a strictly free image (MIT / Apache /
GPL / OFL — node, docker, kitty, gh, glab, kubectl, doctl, awscli,
azure-cli, …). Everything non-free is declared as **postinstall commands**
in the image catalog and executed on the end-user's machine:

- Claude Code (Anthropic) — proprietary
- Codex CLI (OpenAI)
- Grok CLI (x.ai) — proprietary
- Google Cloud SDK (gcloud) — proprietary license, no redistribution
- macOS fonts (`/System/Library/Fonts` → `/usr/share/fonts/macos`) — Apple
  fonts are not redistributable; they're copied from the *user's own Mac*
  during postinstall (or during a local build), never shipped.

Postinstall commands run as root in a chroot on `base.img`, driven by the
same Alpine installer VM as the bake (`vm-setup/postinstall.sh`, serial
markers `SANDBOX_POSTINSTALL_DONE/FAILED`).

## img-catalog.json

Published at `https://dl.bromure.io/images/img-catalog.json` with a **1s
CDN TTL**; images live under `images/<uuid>/base.img.gz` where `<uuid>` is
random per build (long-cached — immutable per uuid).

```json
{
  "formatVersion": 1,
  "image": {
    "uuid": "3f2a…",                  // random per published build
    "version": "200",                 // = UbuntuImageManager.imageVersion
    "description": "Ubuntu 24.04",
    "builtAt": "2026-07-01T03:12:45Z",
    "disk": {
      "path": "images/3f2a…/base.img.gz",
      "sha256": "…",                  // of the compressed file
      "compressedBytes": 3000000000,
      "uncompressedBytes": 25769803776,
      "compression": "gzip"
    }
  },
  "postinstall": [
    { "uuid": "7c9f…", "seq": 10, "description": "Claude Code (Anthropic)",
      "command": "npx --yes @socketsecurity/cli npm install -g --silent @anthropic-ai/claude-code" }
  ]
}
```

The **canonical source** of the postinstall list is
`Sources/AgentCoding/Resources/img-catalog.json` (bundled into the app as
the offline baseline, uploaded verbatim by the publish pipeline — they can
never drift). Step `uuid`s are stable forever; `seq` orders execution.

### Signature

Published catalogs carry a top-level `signature` object:
`{"signedAt": "<ISO-8601>", "edSignature": "<base64 ed25519>"}` — made by
the publish pipeline with the **same Sparkle key that signs app updates**
(`SPARKLE_PRIVATE_KEY` Jenkins credential; clients verify against
`SUPublicEDKey`). It covers a canonical payload of the image identity +
sha256 **and every postinstall command** — the commands run as root in
users' base images, so a compromised CDN bucket must not be able to alter
them. Clients refuse unsigned/invalid catalogs from the production URL,
and never adopt a catalog `signedAt` earlier than one already adopted
(replay/rollback guard). Verification is skipped only under the
`BROMURE_IMAGE_CATALOG_BASE` test override. The payload format is defined
identically in `ImageCatalog.signingPayload(signedAt:)` (Swift verifier)
and `tools/make-img-catalog.mjs` (node signer) — change both or neither.

**Adding a package (e.g. opencode):** append a step to the bundled
baseline with a freshly minted uuid (`uuidgen | tr A-Z a-z`) and the next
free `seq`. On the next weekly publish, existing users get a consent
prompt on launch — *"New packages are recommended to be installed: …"* —
and the accepted steps are applied to their `base.img`. Never reuse or
change an existing step's uuid (that's what marks it "already applied").

## Client behavior

- **New installation** — always fetches the latest `img-catalog.json`
  first, then downloads the image it names (sha256-verified, expanded
  sparse so the 24 GB logical disk stays ~6-8 GB physical), then runs
  **all** postinstall steps without prompting (the setup screen is the
  consent) plus the macOS font copy. Falls back to the local build if the
  download fails. Download failures retry 3× with a catalog re-fetch in
  between — that closes the race with the weekly publish deleting the
  previous image mid-download.
- **Version change** — when the catalog's `image.version` (major) moves
  past the installed stamp, the app offers to download the entire new
  image (`promptBaseImageUpdate`). Weekly rebuilds do **not** bump the
  version — only a deliberate `UbuntuImageManager.imageVersion` bump does,
  so existing users aren't nagged weekly.
- **New postinstall steps** — steps whose uuid isn't in the local
  `image-state.json` (`~/Library/Application Support/BromureAC/`) require
  explicit consent, then are applied to an APFS clone of `base.img` and
  swapped atomically. The version stamp gets a dot-revision bump
  (`200` → `200.1`) so per-workspace drift detection offers a reset.
- Pre-existing installs (no `image-state.json`) are migrated on launch:
  the bundled baseline's steps are marked applied, since the old
  `setup.sh` baked those agents in.

## Publishing (Jenkins, weekly)

`Jenkinsfile.image` (cron `H 3 * * 1`) first runs `./build.sh bromure-ac`
(build.sh owns compiling + signing — the scripts never rebuild the binary),
then `scripts/publish-image.sh <path-to-bromure-ac>`:

1. `bromure-ac init-foss-image --output …` — build the image with the
   latest Ubuntu packages (no agents, no Apple fonts; writes
   `build-info.json`).
2. **Boot check** — `bromure-ac verify-image` boots an APFS *clone*
   (`cp -c`) with a fresh EFI store and requires the serial `login:`
   prompt; the published artifact stays pristine.
3. gzip + sha256, upload to `images/<uuid>/base.img.gz`.
4. Download the previous `img-catalog.json` (to learn the retired uuid).
5. Generate the new catalog (`tools/make-img-catalog.mjs` — baseline
   postinstall steps + new image block).
6. Upload it with `Cache-Control: public, max-age=1`.
7. Smoke-test catalog + image from the CDN.
8. Delete the previous `images/<old-uuid>/` objects
   (`tools/spaces-delete.mjs`; skipped with `KEEP_PREVIOUS=1`).

`DRY_RUN=1` stops after compression (no uploads/deletes).

`dl.bromure.io` is fronted by a Cloudflare Worker
(`tools/cloudflare-worker.js` — deployed manually, keep in sync): `*.json`
manifests get a 1s edge TTL straight from the Spaces origin, immutable
binaries get 24h via DO's CDN endpoint. The publish smoke-test verifies
the Spaces origin first, then polls the public CDN for up to an hour
before deleting the previous image.

## Testing locally (no uploads)

```bash
./build.sh bromure-ac
./scripts/test-image-publish-local.sh \
    '.build/arm64-apple-macosx/release/Bromure Agentic Coding.app/Contents/MacOS/bromure-ac'
# ~15-25 min, ~20 GB disk, network needed
```

Full rehearsal against a `file://` fake CDN: builds + boot-checks the
image, generates the catalog, then runs a real client install
(`bromure-ac init --download-only --storage-dir …` with
`BROMURE_IMAGE_CATALOG_BASE` pointing at the staging dir), asserts the
version stamp / image-state / applied steps, and boot-checks the final
image (postinstall included). `KEEP_STAGING=1` keeps the artifacts.

Unit tests: `swift test --filter ImageCatalogTests` (catalog parsing, step
diffing) and `swift test --filter "Image download plumbing"` (streaming
sha256, sparse gunzip expansion).

# Bromure Web (`browser-images/`)

The browser image (Alpine + Chromium) follows the same design with three
differences.

## Three artifacts, not one

The browser image direct-kernel-boots via `VZLinuxBootLoader` (no
EFI/GRUB), so the host needs the raw ARM64 kernel and the mkinitfs
initramfs alongside the disk. The catalog's `image.boot` array declares
them:

```json
"boot": [
  { "name": "vmlinuz", "path": "browser-images/<uuid>/vmlinuz.gz",
    "sha256": "…", "compressedBytes": 1, "uncompressedBytes": 2,
    "compression": "gzip" },
  { "name": "initrd", "path": "browser-images/<uuid>/initrd.gz", … }
]
```

All three are sha256-verified before install. The signature covers the
boot artifacts too (a swapped kernel is ring-0 in the user's VM); the
payload uses the **`bromure-browser-img-catalog-v1`** magic so a validly
signed AC catalog can never be replayed at the browser URL (both channels
sign with the same Sparkle key).

## What only exists on the end-user's machine

The published image is strictly FOSS **and impersonal**. Client-side
postinstall (`Sources/SandboxEngine/Resources/vm-setup/postinstall.sh`,
Alpine chroot on `/dev/vda`) supplies:

- **Cloudflare WARP** (proprietary .deb from pkg.cloudflareclient.com) —
  a catalog step in `browser-img-catalog.json`. The step pins the exact
  deb **URL and sha256**, so the signed catalog transitively pins the
  binary that lands in users' images (no trusting Cloudflare's package
  index at install time). To ship a newer WARP: update the URL + hash
  (`curl -fsSL https://pkg.cloudflareclient.com/dists/bookworm/main/binary-arm64/Packages | grep -E 'Filename|SHA256'`)
  **and mint a fresh step uuid** — the old uuid marks the step "already
  applied", so reusing it would leave existing images on the old
  version. Like every step, it executes inside a chroot on the image
  (`postinstall.sh` mounts `/dev/vda` at /mnt and chroots), so its `/`
  is the image's root — the deb extracts straight to `/bin/warp-cli`.
  `setup.sh` bakes only WARP's FOSS runtime deps (gcompat, resolver
  stub).
- **macOS fonts** — copied from the user's own Mac via virtiofs (same
  700 MB cap logic as a local build). Never shipped.
- **Personalisation** — keyboard layout / natural scrolling / locale are
  re-rendered from the same `%%VAR%%` templates `setup.sh` bakes for
  local builds (a published build carries `us`/`en_US` defaults).

**Bromure Agentic Coding consumes this catalog too** (its embedded agent
browser downloads the same image into `BromureAC/browser`), but with a
different step policy: catalog steps are **Bromure Web-only by default**
— AC runs none of them (only the built-in fonts copy + personalisation)
unless a step opts in with `"bromureac": true` in the baseline. The flag
is covered by the catalog signature (emitted into the payload only when
present, so pre-field signatures keep verifying). Cloudflare WARP is
deliberately unmarked: it backs Web's VPN feature and has no business in
the agent browser.

The distribution build (`bromure init-foss-image --output …`, setup.sh
`BUILD_MODE=foss`) also **fails the build outright when the out-of-tree
kernel modules (v4l2loopback, rtc-pl031) can't be found** for the
installed kernel — a local build degrades with a warning; a published
image must never silently lack webcam/RTC support. (The image ships no
sshd at all; the only host-side access is the serial console's root
autologin, reachable only from the host process.)

Both the bake and the postinstall VM route every guest fetch (modloop,
APKINDEX, packages, the WARP deb, the ad-block lists) through the
host-side **AlpinePackageProxy** (moved to SandboxEngine; the same
HTTP→HTTPS channel the AC bake uses) — guest-direct TLS is unreliable on
VPN/MITM hosts and on the build server. The scripts consume it via
`ALPINE_REPO_BASE` (kernel cmdline + env → `http_proxy`/`https_proxy`
with the proxy host in `no_proxy`); the shipped image's
`/etc/apk/repositories` is restored to the canonical CDN URLs. Fetches
go direct only when the proxy can't start or the VM is bridged.

## Client behavior

- **New installation** (`AppState.startInit` / `bromure init`) — fetch
  `browser-images/img-catalog.json`, download + verify + expand all three
  artifacts into `.partial` files, run postinstall (steps + fonts +
  personalisation, then an e2fsck gate), promote atomically, stamp
  `image-version` with the app's `LinuxImageManager.imageVersion` (the
  catalog's exact version is recorded in `image-state.json` — stamping by
  the constant means a freshly downloaded image can never look stale).
  Download-side failures retry 3× with a catalog re-fetch, then fall back
  to the local build (which applies the same catalog steps, so both paths
  converge on the same image).
- **Version change** — the browser keeps its existing behavior: an
  `imageVersion` bump in the app auto-reinstalls on next launch (now via
  download-first).
- **New postinstall steps** — steps whose uuid isn't in
  `image-state.json` (`~/Library/Application Support/Bromure/`) prompt
  for consent on launch, then apply to an APFS clone and swap atomically
  (`LinuxImageManager.applyPostinstallSteps`). Pre-existing installs are
  migrated on launch: the bundled baseline's steps are marked applied,
  since the old `setup.sh` baked WARP in.

## Publishing (Jenkins, weekly)

`Jenkinsfile.browser-image` (cron `H 4 * * 1`, an hour after the AC
image job) runs `./build.sh bromure`, then
`scripts/publish-browser-image.sh <path-to-bromure>`: init-foss-image →
boot-check a clone (`bromure verify-image --disk … --kernel … --initrd …`,
waits for the root serial prompt) → gzip + sha256 ×3 → upload under
`browser-images/<uuid>/` → catalog (make-img-catalog.mjs with `--boot` +
`--payload-magic`) at a 1s TTL → origin + CDN smoke-test → delete the
previous build. `DRY_RUN` / `KEEP_PREVIOUS` as in the AC pipeline. The
Cloudflare worker needs no change (it routes by extension, not prefix).

## Testing locally (no uploads)

```bash
./build.sh bromure
./scripts/test-browser-image-publish-local.sh \
    '.build/arm64-apple-macosx/release/Bromure.app/Contents/MacOS/bromure'
# ~15-25 min, ~15 GB disk, network needed
```

Same shape as the AC rehearsal: builds + boot-checks the FOSS image,
assembles a `file://` CDN (catalog + three artifacts), runs a real client
install (`bromure init --download-only --storage-dir …` with
`BROMURE_IMAGE_CATALOG_BASE`), asserts the stamp / image-state / applied
steps, and boot-checks the final image. `KEEP_STAGING=1` keeps the
artifacts.

Unit tests: `swift test --filter BrowserImage` (boot-artifact payload +
signature domain separation, baseline, image-state migration).
