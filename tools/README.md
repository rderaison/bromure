# Release tooling

## Setup (once per build host)

```bash
cd tools && npm install
```

## One-time: generate the Sparkle signing key

Use Sparkle's `generate_keys` utility (bundled with the Sparkle SPM distribution once the app wires it in). Export the private key as base64 and store it in CI secrets as `SPARKLE_PRIVATE_KEY`. Store the matching public key in the app's `Info.plist` under `SUPublicEDKey`.

## Publishing a release

After `package.sh` finishes producing a signed + notarized `.zip` (or `.dmg`), run:

```bash
export SPARKLE_PRIVATE_KEY="..."    # base64 64-byte Sparkle private key
export DO_SPACES_KEY="..."
export DO_SPACES_SECRET="..."
export DO_SPACES_ENDPOINT="https://sfo3.digitaloceanspaces.com"
export DO_SPACES_REGION="sfo3"
export DO_SPACES_BUCKET="bromure"
export DO_SPACES_PUBLIC_BASE="https://bromure.sfo3.cdn.digitaloceanspaces.com"
export RELEASE_AUTH_TOKEN="..."      # matches backend env of same name

node tools/release-upload.mjs \
  --file .build/arm64-apple-macosx/release/bromure.app.zip \
  --version 2.6.0 \
  --notes-file release-notes-2.6.0.html
```

Pass `--channel beta` to push to the beta appcast channel instead of stable.

Pass `--dry-run` to print the signed metadata without uploading or hitting the backend.
