# Porting the Bromure fat client to the web — working guide

The macOS Bromure Agentic Coding **fat client** (a window mirroring a remote
bromure-ac over SSH — `Sources/AgentCoding/FatClientController.swift`
`RemoteHostWindow`) is ported to ONE TypeScript/React codebase shipped two ways:

- **Electron** (Linux, Windows) — `electron/` (main + preload); direct TCP to
  `address:port` hosts, bromure.io peers via the ws-relay.
- **Hosted** at `https://bromure.io/client/` — same bundle; every server is a
  bromure.io peer reached through the ws-relay.

The two must render **identically** (same code, same CSS; only `src/platform.ts`
differs), and both must match the macOS app **as closely as pixels allow**.

## Architecture

```
src/core/ssh/        WebCrypto SSH-2 client (curve25519, ed25519, aes-gcm) — DONE, tested live
src/core/net/        ByteStream: WebSocket (hosted/dev) | Electron TCP
src/core/control/    control-socket HTTP over `bromure-fatclient/1 control` exec channels
src/core/remote/     RemoteHost: connection, /state push stream (deltas) + poll,
                     request(), send(), guestExec(), guestFileOp(), TerminalAttach (PTY frames)
src/core/cloud/      bromure.io control plane (enroll, devices, grants, ws-relay dial)
src/platform.ts      Electron vs hosted vs dev differences — the ONLY place they differ
src/app/             App root, HostWindow layout, store (hooks), in-app windows, appearance
src/ui/theme.css     tokens: macOS palette (light/dark), fonts, type scale
src/ui/kit/          macOS controls: Button, PopUp, Switch, Checkbox, TextField, SearchField,
                     Segmented, Form/Section/Row (grouped form), menus (useMenu), Popover,
                     Sheet, Spinner, Badge, useTooltip
src/ui/icons.tsx     <SF name="folder.fill"/> — SF Symbol names mapped to Lucide glyphs
src/features/<x>/    one folder per surface (see ownership below)
```

Data: `useRemote(host, s => s.agentSessions)` re-renders on change. Mutations:
`host.send('POST', '/automations/<id>/run')` (fire-and-forget + refresh) or
`await host.request(method, path, body)`. Window-level state: `useHostCtx()`
(`selection`, `select()`, `viewMode`, …). Secondary windows: `useWindows().open({id, title, width, height, render})`.

**The Swift is the spec.** For your surface, read the Swift views and the
fat-client controller methods they call (`FatClientController.swift` — search
for the route strings), and port behaviour + layout + copy faithfully: same
strings (English), same ordering, same empty states, same menus, same
keyboard shortcuts (⌘ → Ctrl on Linux/Windows via `modKey`/`isMod` in platform.ts).
The server routes are in `AutomationServer.swift` (`case ("POST", "/…")`).

## Pixel targets

- `web-client/.reference/*.png` — the NATIVE windows rendered offscreen from
  the demo server at 2x (`scripts/capture-references.sh`). Layout/metrics
  truth. NOTE: offscreen = *inactive* window look (greyed sidebar labels,
  non-accent default button). The active look is in the manual:
  `manual/images/*.en.jpg` (same fixture). Match the ACTIVE look.
  Main window = 1320×944 pt (2640×1888 px). Settings editor = 880×872 pt.
- 1 CSS px = 1 pt. Fonts: SF on macOS (what you'll see here), Inter elsewhere.

## Dev loop (all on this Mac)

The **demo server** (an isolated bromure-ac with the manual's synthetic fixture,
SSH on 127.0.0.1:2399, debug API on 127.0.0.1:9323) and the **dev relay**
(`scripts/dev-relay.mjs`, ws://127.0.0.1:5179) are already running — don't
restart them; tell the coordinator if they're down. There is also one REAL VM
workspace "Live machine" (booted, Ubuntu guest, tmux) for terminal / transcript /
file work; the fixture sessions have no VM (their chats are fixture transcripts
written by `scripts/manual-demo/make-fixture.py` into `/private/tmp/brmW-state/fixture/`).

```bash
cd web-client
npx tsc -p tsconfig.json --noEmit                 # typecheck (must stay clean)
npx vite build --outDir .build-<you>              # your own build dir (never `dist/` — shared)
node scripts/shot.mjs /tmp/<you>-x.png --dist .build-<you> --query dev=demo \
     [--hash '#/host/demo'] [--js "…click something…"] [--after 1500] [--dark] [--w 880 --h 872]
python3 scripts/compare.py .reference/<name>.png /tmp/<you>-x.png /tmp/<you>-cmp.png [--crop x,y,w,h]
```
`--query dev=demo` makes the app enroll its key on the demo server and open
`#/host/demo`. Drive UI state for a shot with `--js` (e.g. dispatch a click, or
call a debug hook you expose on `window.__bromure`). Look at both images; iterate
until they match. Read the PNG with your image viewer tool.

Native state can be poked over the debug API to set up a scene
(`curl -X POST 127.0.0.1:9323/debug/editor -d '{"action":"…"}'`, see
`scripts/take-manual-screenshots.sh`). Avoid destructive changes to the shared
demo server; if you change data (e.g. a profile setting), put it back.

## Rules

- **Own your folder** (`src/features/<yours>/`) + the files named in your brief.
  Shared files (`src/ui/kit`, `src/ui/icons.tsx`, `src/core/remote/types.ts`,
  `src/app/*`): additive, minimal edits only (new icon mappings, a new optional
  field, a new kit component that is truly generic). Never reformat or rewrite
  them; other agents edit them concurrently — re-read right before editing.
- No new npm dependencies (the user's supply-chain policy requires a Socket
  scan; ask the coordinator).
- CSS: one `<feature>.css` imported by your entry component, classes prefixed
  with your feature (`.sb-…`, `.chat-…`). Use the tokens in theme.css; both
  light and dark must work.
- No `localStorage` for server data. Per-user UI prefs only (`usePersisted`).
- Don't commit. Don't touch the Swift app except where your brief says so.
- Anything that **cannot be ported** (or is deliberately reduced): append a
  bullet to `web-client/NOT_PORTED.md` under your section — what, why, what the
  web does instead.
- Done = typecheck clean, your surface works against the demo server, and your
  shots are side-by-side close to the reference in light AND dark.
