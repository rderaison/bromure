# Prebuilt Base Image (Bromure Agentic Coding)

Installing Bromure AC used to build the Ubuntu base image locally on every
machine (~10 min: Alpine netboot → debootstrap → `setup.sh`). New
installations now **download a prebuilt image** from DigitalOcean Spaces
instead, and only fall back to the local build when the download isn't
available (offline, CDN outage).

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
