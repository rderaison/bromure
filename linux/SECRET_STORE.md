# Secret store on Linux: design (Phase 4)

## What macOS keeps, and where

| macOS | what | where |
|---|---|---|
| `SecretsVault` (`Mitm/SecretsVault.swift`) | per-install **AES-256 master key**; API keys, OAuth grants and captured trace bodies are AES-GCM blobs encrypted under it, in files | key in the Data Protection Keychain (no prompt); a 0600 key file as fallback |
| `PassphraseKeychain` | SSH key passphrases | Keychain |
| `VPNKeychain` (SandboxEngine) | VPN profile secrets | Keychain |
| `InstallIdentity` (SandboxEngine) | X25519 key for sealed-box bundles, install bearer tokens per enrollment | Keychain, `WhenUnlockedThisDeviceOnly` |
| `DeviceIdentity` (P2P), `Enrollment` / cloud mTLS identity, fat-client key | device and mTLS identities | Keychain |
| `BromureCA` | the MITM CA private key | **a `key.pem` file** next to `cert.pem`, not the Keychain |

The pattern that ports cleanly is SecretsVault's: one master key in an OS-protected store, and everything else as encrypted blobs in ordinary files. On Linux every Keychain item above becomes such a blob, the CA key included (an improvement over macOS).

## Options

| | headless daemon (no login session) | at rest, disk taken | other local users | same user / root | moving parts |
|---|---|---|---|---|---|
| **A. File vault, master key sealed by systemd-creds** (host key, plus TPM2 when present) | yes: `--user` creds (systemd ≥ 256) or `LoadCredentialEncrypted=` for a system unit | protected: needs this machine's TPM and/or `/var/lib/systemd/credential.secret` | 0600 files, 0700 dir | not protected (same as macOS) | systemd only |
| B. libsecret (GNOME Keyring / KWallet) | **no**: needs a session D-Bus and an unlocked login keyring; a systemd service has neither, and unlocking means a password or a PAM hook | protected by the login password | yes | no | D-Bus, keyring daemon, PAM |
| C. Plain 0600 master-key file | yes | **not protected**: the key sits beside the ciphertext | 0600 | no | none |

Measured on lnx-ntv (Ubuntu 26.04, systemd 259, TPM2 at `/dev/tpmrm0`), unprivileged:
- `systemd-creds --user encrypt`: 0.25 s.
- `decrypt`: 0.6 s, once per daemon start.
- Round-trip verified. The key type `auto` picks host+TPM2 when a TPM is present.

## Recommendation: A, with C as a loud fallback

- **Vault**
  - `~/.local/share/bromure-ac/secrets/` (0700). A system service uses `/var/lib/bromure-ac/secrets/`.
  - One file per item, named after the item's (service, account) so the macOS items map one-to-one.
  - Each file is `version || AES-256-GCM(nonce || ciphertext || tag)`, with the item name as AAD so blobs can't be swapped between items. This is SecretsVault's format plus AAD.
- **Master key**
  - 32 random bytes, sealed once with `systemd-creds encrypt --name=bromure-ac-master-key`.
  - **User service** (the default: `systemctl --user`, lingering enabled): `systemd-creds --user …` on `master-key.cred` beside the vault.
  - **System service**: `LoadCredentialEncrypted=bromure-ac-master-key:/var/lib/bromure-ac/master-key.cred` in the unit. systemd decrypts it into the unit-private, non-swappable `$CREDENTIALS_DIRECTORY`; the daemon reads it from there and never shells out.
  - In memory, the daemon holds it in an `mlock`ed buffer marked `MADV_DONTDUMP`, with `PR_SET_DUMPABLE=0`.
- **Fallback**
  - When systemd-creds isn't usable (containers, systemd < 256 for `--user`, no host secret), use a 0600 key file (option C).
  - Say so in `/state` and in the fat client, as macOS logs its own file-key fallback.
- **Not libsecret.** A headless daemon has no session bus or unlocked keyring, and making one exist (PAM unlock, a password at boot) costs more than it protects.
- **Recovery semantics are the same as macOS's**: losing the sealing key loses the secrets.
  - What loses it: a reset or replaced TPM, or a deleted `/var/lib/systemd/credential.secret`.
  - The vault becomes unreadable, while non-secret metadata (profiles) is untouched, so the user re-enters keys. This is SecretsVault's "wiping the keychain entry rotates the key".
  - A later `bromure-ac secrets export --passphrase` can cover migrations.
- **Optional hardening for the system service**: bind the TPM2 seal to PCR 7 (Secure Boot state) with `--tpm2-pcrs=7`. Then a disk booted with Secure Boot off, or in another machine, can't unseal.

## Threat model

The store protects secrets **at rest and from other principals**:
- **A stolen disk, backup or image** of the machine yields ciphertext plus a credential sealed to this host's TPM and host secret. Neither opens elsewhere.
- **Other unprivileged local users** can't read the 0700/0600 vault, the user-scoped credential, or the unit-private `$CREDENTIALS_DIRECTORY`.
- **Guests never see the vault at all**: secrets reach the outside world only through the proxy's swaps, as on macOS.

It does **not** protect against **root** on the host, or against **code running as the daemon's own user while the daemon runs**: both can ask systemd-creds to unseal, or read the key from memory. That's the same boundary as the macOS Keychain for same-user processes, minus code-signing ACLs, which Linux has no equivalent of. Without a PCR policy, TPM binding also doesn't prove the host booted the software it expects; the PCR 7 option narrows that for the system service.

## Implementation (ACLinux)

- `SecretsVault` ports the macOS functions. Seven ledger entries are `ported`: `masterKey`, `fileFallbackKey`, `encrypt`, `decrypt`, the Keychain fetch and store (now systemd-creds unseal and seal), and `VaultError.description`.
- **Blob format:** `0x01 || nonce || ciphertext || tag`, with AAD `"bromure-ac/vault/v1"` (plus `\0` + item name for item-bound blobs). `decrypt` also reads the macOS format: bare combined, no AAD.
- `VaultItems` holds the Keychain-style (service, account) items, stored at `<vault>/items/<service>/<account>.blob` with the name as AAD.
- **Key source order:**
  1. `$CREDENTIALS_DIRECTORY/bromure-ac-master-key`;
  2. `master-key.cred` (`systemd-creds [--user]`; sealed on first use);
  3. `secrets-master.key` (0600).

  `BROMURE_VAULT_KEY_SOURCE=file` forces the last. `SecretsVault.masterKeySource` reports which one was used.
- **When the key is lost:**
  - An unreadable `master-key.cred` is moved aside (`.unreadable-<time>`) and the key rotated.
  - Blobs under the old key throw `VaultError.unreadable` (re-enter).
  - A `master-key.cred` with no `systemd-creds` binary to open it is an error, not a rotation.
- **Process hardening:** the key sits in `acl_secure_alloc` memory (mlock, MADV_DONTDUMP, explicit_bzero on free). Resolving it sets `PR_SET_DUMPABLE=0`.
