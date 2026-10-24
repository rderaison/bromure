# The Bromure package repo — layout and signing

For whoever stands up the hosting. **Nothing here is deployed**; this is the
shape the client side already expects, and the commands a user runs once.

The Sidecar does not self-update on Linux: `bromure-sidecar update` works out
whether it came from a `.deb`, an `.rpm` or the tarball and prints the matching
command (`internal/updater/method_linux.go`). So the repo *is* the update
mechanism, and these two paths have to stay in step:

| the client runs | the repo must answer |
|---|---|
| `apt install --only-upgrade bromure-sidecar` | `dists/stable/…/Packages` lists a newer version |
| `dnf upgrade bromure-sidecar` | `repodata/` lists a newer version |

Package names are fixed: **`bromure-sidecar`** in both formats. `update`
derives it from `dpkg -S` / `rpm -qf --queryformat '%{NAME}'` on the running
binary, so renaming the package silently breaks the printed command.

## What `scripts/package-linux.sh` produces

```
dist/packages/
  bromure-sidecar_<version>_amd64.deb
  bromure-sidecar_<version>_arm64.deb
  bromure-sidecar-<version>-1.x86_64.rpm
  bromure-sidecar-<version>-1.aarch64.rpm
  SHA256SUMS
```

Four files, two architectures, one version. The version is sanitised to
`[A-Za-z0-9.]` because rpm refuses `-` in a version: `v1.2.3-4-gabc123`
becomes `1.2.3.4.gabc123`. The binary keeps the raw git description, so
`bromure-sidecar version` and `dpkg -l` differ by punctuation on purpose.

## APT layout

A plain `deb` repository, one distribution, one component, two
architectures:

```
https://pkg.bromure.io/apt/
  dists/stable/
    Release                      # signed (see below)
    Release.gpg                  # detached signature  (optional if InRelease)
    InRelease                    # inline-signed Release (preferred)
    main/
      binary-amd64/Packages      # + Packages.gz
      binary-arm64/Packages      # + Packages.gz
  pool/main/b/bromure-sidecar/
    bromure-sidecar_<version>_amd64.deb
    bromure-sidecar_<version>_arm64.deb
```

`Release` must carry `Origin`, `Label`, `Suite: stable`, `Codename: stable`,
`Architectures: amd64 arm64`, `Components: main`, and the `SHA256` of every
index. `apt-ftparchive` or `aptly` both generate this; `reprepro` is the
smallest thing that does signing, pooling and index generation in one step.

`Suite: stable` and nothing else, deliberately: the Sidecar's own version is
what moves, and a per-release suite would make every client edit its sources
list to get updates.

## DNF/YUM layout

```
https://pkg.bromure.io/rpm/
  bromure-sidecar.repo           # the file users drop in /etc/yum.repos.d/
  stable/
    x86_64/
      repodata/                  # createrepo_c output
      bromure-sidecar-<version>-1.x86_64.rpm
    aarch64/
      repodata/
      bromure-sidecar-<version>-1.aarch64.rpm
```

`$basearch` in the baseurl covers both architectures with one file:

```ini
[bromure]
name=Bromure
baseurl=https://pkg.bromure.io/rpm/stable/$basearch/
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://pkg.bromure.io/bromure-archive-keyring.asc
```

`repo_gpgcheck=1` needs `repomd.xml.asc` beside `repodata/repomd.xml`; without
it only the packages are verified and the index is not.

## Signing

One signing key for both ecosystems, kept off every build machine that runs
untrusted code. **Not in this repository and not in any CI environment
variable** — the release job should reach a signer, not hold a key.

* **APT** signs the `Release` file, not the packages: `gpg --clearsign` into
  `InRelease` (preferred) or `gpg -abs` into `Release.gpg`. Integrity of each
  `.deb` comes from the `SHA256` in `Packages`, which is itself covered by the
  signed `Release`.
* **RPM** signs each package *and* the index: `rpm --addsign *.rpm` with
  `%_gpg_name` set, plus `gpg --detach-sign --armor repodata/repomd.xml` for
  `repo_gpgcheck`.
* Publish the public key twice, because the two clients want different forms:
  `bromure-archive-keyring.asc` (armoured, for dnf's `gpgkey=`) and
  `bromure-archive-keyring.gpg` (dearmoured, for apt's `signed-by=`).
  `gpg --dearmor` converts.

## One-time client setup

**Debian/Ubuntu.** `apt-key` is deprecated and a key in
`/etc/apt/trusted.gpg.d` is trusted for *every* repository, so scope it with
`signed-by=`:

```sh
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://pkg.bromure.io/bromure-archive-keyring.asc \
  | sudo gpg --dearmor -o /etc/apt/keyrings/bromure-archive-keyring.gpg
sudo chmod 0644 /etc/apt/keyrings/bromure-archive-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/bromure-archive-keyring.gpg] https://pkg.bromure.io/apt stable main" \
  | sudo tee /etc/apt/sources.list.d/bromure.list

sudo apt update && sudo apt install bromure-sidecar
```

(`arch=` keeps apt from asking for indexes you do not publish on a mixed-arch
machine.)

**Fedora/RHEL/SUSE:**

```sh
sudo curl -fsSL -o /etc/yum.repos.d/bromure.repo \
  https://pkg.bromure.io/rpm/bromure-sidecar.repo
sudo dnf install bromure-sidecar      # zypper: sudo zypper install bromure-sidecar
```

Then, per user — the package deliberately does not pick one:

```sh
systemctl --user enable --now bromure-sidecar
sudo loginctl enable-linger "$USER"   # headless boxes
bromure-sidecar status
```

## Things that will bite

* **Serve over HTTPS with a working chain.** apt fails closed on a bad
  certificate and the message names TLS, not the repo.
* **Set `Cache-Control` short on the indexes** (`InRelease`, `Packages*`,
  `repomd.xml`) and long on the pool. A CDN caching an old index next to new
  packages gives `Hash Sum mismatch`, which reads as corruption.
* **Never rewrite a published version.** Both clients cache by version, and a
  changed artefact at the same version is the one failure users cannot clear
  themselves.
* **Keep the previous version in the pool.** `--only-upgrade` and a rollback
  both need it.
* **One user per machine, today.** The Sidecar binds a fixed SSH port (2223);
  a second user's daemon starts and cannot bind it, so it looks healthy and is
  unreachable. The install notes say so and point at
  `bromure-sidecar settings sshPort`. If Linux ever needs several users per
  box, that default has to become per-user before the repo encourages it.
