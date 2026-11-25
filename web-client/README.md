# Bromure client — web & Electron

The Bromure Agentic Coding remote client (the macOS "fat client") as one
TypeScript/React app, shipped:

- **hosted** at `https://bromure.io/client/` — reach your servers through your
  bromure.io account (WebSocket relay; SSH stays end-to-end in the browser);
- **Electron** for **Linux** and **Windows** — the same bundle, plus direct
  connections to servers by address.

What isn't (or can't be) ported is listed in [NOT_PORTED.md](NOT_PORTED.md);
how the port is organised and verified is in [PORTING.md](PORTING.md).

## Security model

- The client embeds its own SSH-2 implementation on WebCrypto
  (`src/core/ssh`): curve25519-sha256, ssh-ed25519 host keys,
  aes128/256-gcm@openssh.com — exactly what a Bromure server speaks.
- The device's Ed25519 key is generated **non-extractable** and stored in
  IndexedDB; script can sign with it, nothing can read it out.
- Host keys are pinned on first use (SHA256 fingerprint shown), and a changed
  key is a loud, explicit decision — as in the macOS client.
- bromure.io only relays opaque bytes for peer connections (`/v1/connections/:id/relay`);
  it never sees keys or plaintext.

## Build

```bash
npm ci        # through Socket: SOCKET_CLI_VIEW_ALL_RISKS=1 npx @socketsecurity/cli npm ci
npm run build             # → dist/ (the hosted bundle; relative asset URLs)
npm run build:hosted      # → bromure-client-web.tgz for bromure.io/client/
npm run package:linux     # → out/Bromure-linux-{x64,arm64}(.tar.gz)
npm run package:win       # → out/Bromure-win32-{x64,arm64}(.zip)
npm run electron          # run Electron locally
```

## Develop against a real server

```bash
./build.sh bromure-ac                        # repo root: the macOS app (the server)
web-client/scripts/demo-server.sh start      # isolated bromure-ac + demo fixture, SSH on 127.0.0.1:2399
npm run dev:relay                            # ws://127.0.0.1:5179 → TCP (stands in for bromure.io)
npm run dev                                  # http://localhost:5178/?dev=demo
web-client/scripts/capture-references.sh     # native renders → .reference/ (pixel targets)
node scripts/shot.mjs /tmp/web.png --query dev=demo   # web render at 2x
python3 scripts/compare.py .reference/x.png /tmp/web.png /tmp/cmp.png
web-client/scripts/demo-server.sh stop       # also restores the real app's preferences
```

## Verification

```bash
npm test                                     # unit tests (+ live protocol tests with BROMURE_LIVE_KEY=<jwk>)
scripts/qa-all.sh /tmp/qa                    # every surface vs the native renders, light + dark (diff table)
scripts/hosted-e2e.sh                        # hosted path end to end: sign-in → enroll → directory → grant →
                                             #   signaling → ws-relay → SSH → mirror (scripts/fake-cloud.mjs)
```
`.reference/` and `.reference-dark/` (gitignored) hold the native renders —
regenerate with `scripts/capture-references.sh` (dark: switch the demo server
with `POST 127.0.0.1:9323/debug/fatclient {"action":"appearance","mode":"dark"}`
and `REF_SUFFIX=-dark`).

Electron smoke test on a real Linux/Windows box (shot mode, unattended; a
one-time code from `bromure-ac admin code <user>` pairs and enrolls the key):
```bash
BROMURE_SHOT=/tmp/x.png BROMURE_TEST_HOST=<host> BROMURE_TEST_PORT=2222 \
BROMURE_TEST_USER=<user> BROMURE_TEST_PASSWORD=<code> xvfb-run -a ./bromure --no-sandbox
```
