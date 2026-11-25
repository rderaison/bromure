# The APT repository

`bromure-ac` packages are published at **https://dl.bromure.io/apt**: static
files in the `bromure-dl` Space (prefix `apt/`), signed with an OpenPGP key.

The repository is shared: the Bromure Client's packages (`bromure-client`,
branch `web-client`, `Jenkinsfile.client-linux`) go to the same suites, with
the same key and the same tool (`--package bromure-client`). See "Two
pipelines" below.

## On a server

```sh
sudo install -d -m 755 /etc/apt/keyrings
curl -fsSL https://dl.bromure.io/apt/bromure-archive-keyring.gpg | sudo tee /etc/apt/keyrings/bromure.gpg >/dev/null
echo "deb [signed-by=/etc/apt/keyrings/bromure.gpg] https://dl.bromure.io/apt stable main" \
    | sudo tee /etc/apt/sources.list.d/bromure.list
sudo apt update && sudo apt install bromure-ac
```

`beta` instead of `stable` for the beta channel. Updates then come with
`apt upgrade`.

## Layout

```
apt/bromure-archive-keyring.gpg     the public key (binary, for signed-by); .asc armored
apt/pool/main/b/<package>/<package>_<version>_<arch>.deb    (bromure-ac, bromure-client)
apt/dists/<suite>/InRelease         Release, clearsigned (+ Release, Release.gpg)
apt/dists/<suite>/main/binary-{amd64,arm64}/Packages, Packages.gz
apt/dists/<suite>/main/binary-*/by-hash/SHA256/<sha256>
```

Suites are the release channels, `stable` and `beta`. The pool is shared
between them.

## Publishing

Jenkinsfile.linux with **PUSH_RELEASE** checked, **RELEASE_CHANNEL** the suite.
After the build, `tools/apt-publish.mjs publish` (in a node container):

- reads the suites' current indexes from the bucket (not the CDN);
- refuses a version already in the suite: the package version is
  `LinuxAppVersion.short`, so a new release needs a bump;
- a version already in the *other* suite is **promoted**: this suite gets
  that package (the one beta testers ran), not this build's;
- otherwise uploads the package to the pool, then the indexes (also by hash),
  then Release, Release.gpg and InRelease last;
- keeps every older version in the suite (apt installs the newest);
- refuses to sign with a key other than the published one.

Then `tools/apt-publish.mjs verify` reads the repository back through
dl.bromure.io with apt itself (update, candidate version, package download).

A run building one architecture (TARGET_ARCHES) publishes that one; the other
keeps its version.

Tested by `linux/packaging/test-apt-publish.sh` (a local directory for the
Space, a throwaway key, apt against 127.0.0.1).

### Two pipelines

A run publishes one package: `--package NAME`, `bromure-ac` when omitted (a
`.deb` of another package is refused). The suite's indexes are rewritten from
what the bucket has, every package's entries included, plus the run's own, so
a `bromure-ac` publish keeps `bromure-client` and the reverse.

**Never run two publishes to the same suite at the same time**, from either
pipeline: each one reads the index, adds to it and writes it back, so the
second to write drops what the first added (its package stays in the pool,
in no index). Each pipeline has `disableConcurrentBuilds()`, which only
covers its own runs.

The tool catches most of it: just before writing the indexes it reads the
suite's `Packages` again, and stops ("index changed while this publish ran")
if another publish finished since it started, leaving the suite as that
publish wrote it. Run the stopped publish again: it replaces its package in
the pool and adds the entry. What it can't catch is a publish that writes
during the few seconds of this one's own index upload; if a version is
missing from the index after two runs that overlapped, publish it again.

`tools/apt-publish.mjs` exists on both branches (`linux-port`, `web-client`)
and must stay the same file.

## Setting it up (once)

1. **The signing key.** On a trusted machine, not on a build host:

   ```sh
   export GNUPGHOME=$(mktemp -d)
   gpg --batch --passphrase '' --quick-gen-key "Bromure APT <security@bromure.io>" ed25519 sign never
   gpg --armor --export-secret-keys > bromure-apt-signing.asc   # → Jenkins
   gpg --armor --export --output bromure-apt-public.asc         # keep alongside
   ```

   Keep an offline copy of `bromure-apt-signing.asc` and of the revocation
   certificate gpg wrote under `$GNUPGHOME/openpgp-revocs.d/`, then delete
   `$GNUPGHOME`. A lost key means every server has to fetch a new keyring by
   hand.

2. **Jenkins:** a *Secret file* credential with id `APT_SIGNING_KEY`, holding
   `bromure-apt-signing.asc`. `DO_SPACES_KEY` and `DO_SPACES_SECRET` are the
   macOS release pipeline's.

3. **dl.bromure.io:** deploy `tools/cloudflare-worker.js` (it keeps
   `apt/dists/` uncached except `by-hash/`). Without it, Cloudflare and DO's
   CDN cache InRelease for 24 h and servers don't see a new release.

The first publish uploads the public key; later publishes check that they sign
with that same key.
