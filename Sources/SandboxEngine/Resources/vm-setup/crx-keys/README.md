# Extension signing keys

These `*.pem` files are the CRX signing keys for the bundled Bromure
browser extensions. They are committed **on purpose** — they are not
secrets in the usual sense:

- Their only role is to give each extension a **deterministic ID**. Each
  extension's `manifest.json` `"key"` is the matching public key, so
  Chromium's `--load-extension` path and Google Chrome's force-installed
  CRX resolve the **same** extension id, and the native-messaging
  `allowed_origins` can pin that id.
- They sign extensions that only ever load inside a disposable, ephemeral
  Bromure VM under our own enterprise policy. They grant no access to any
  Chrome Web Store listing, account, or user data.

`mapping.json` records `{extension: {key (public), id}}`.

At image-bake time `scripts/crx-pack.py` packs each extension with its key
into `/opt/bromure/crx/<ext>/ext.crx` (+ a `file://` update manifest); the
keys themselves are **not** copied into the shipped image.

To rotate a key: regenerate it (`openssl genpkey -algorithm RSA
-pkcs8 ...` — chromium requires PKCS#8), recompute the id, and update the
extension `manifest.json` `"key"`, the native-messaging `allowed_origins`,
`mapping.json`, and any hard-coded id in `config-agent.py`.
