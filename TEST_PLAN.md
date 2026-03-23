# Bromure Test Plan

## 1. Profile Management

### 1.1 Create / Edit / Delete
- [ ] Create a new profile — verify it appears in profile picker and sidebar
- [ ] Rename a profile — verify name updates everywhere (picker, sidebar, window title)
- [ ] Add/edit comments — verify tooltip on hover in profile list
- [ ] Change window color — verify 3px border appears around browser window in correct color
- [ ] Delete a profile — verify confirmation dialog, profile removed from list and disk
- [ ] Delete a persistent+encrypted profile — verify Keychain entry cleaned up

### 1.2 Profile Persistence
- [ ] New profiles default to ephemeral (Retain Browsing Data = OFF)
- [ ] Toggling persistence ON — verify profile disk created, VM boots with /dev/vdb
- [ ] Toggling persistence OFF — verify data deletion confirmation, disk removed
- [ ] Relaunch app — verify persistent profile retains bookmarks, history, cookies
- [ ] Ephemeral session — verify clean state on every launch (no leftover data)

### 1.3 Encryption (LUKS)
- [ ] Enable encryption on persistent profile — confirm data-loss warning dialog
- [ ] Verify LUKS volume mounted at `/home/chrome/profile` inside VM
- [ ] Verify encryption key stored in macOS Keychain (bundle: com.bromure.app)
- [ ] Disable encryption — confirm data-loss warning, verify disk recreated unencrypted
- [ ] Encryption toggle disabled when persistence is OFF

---

## 2. Global Settings (Hardware / Input / Display / Network / Storage)

### 2.1 Hardware
- [ ] Change memory (1–16 GB) — verify pool restart triggered, VM reports correct RAM
- [ ] Change CPU cores (Auto / explicit) — verify pool restart, VM sees correct core count
- [ ] Auto CPU = 2 × RAM GB, capped at host processor count

### 2.2 Input
- [ ] Change keyboard layout — verify image rebuild triggered
- [ ] Test at least: US QWERTY, French AZERTY, German QWERTZ — type special chars
- [ ] Toggle natural scrolling — verify image rebuild, scrolling direction changes in guest
- [ ] Use Command as Control toggle — verify ⌘+C maps to Ctrl+C in guest (no rebuild needed)

### 2.3 Display
- [ ] Scale factor 1x vs 2x — verify image rebuild, guest resolution changes
- [ ] Appearance: System / Light / Dark — no restart needed
- [ ] Dark mode: verify `--force-dark-mode` flag passed to Chromium
- [ ] System mode: verify tracks macOS appearance changes live

### 2.4 Network
- [ ] NAT mode (default) — verify internet access, DNS resolution
- [ ] Bridged mode — verify interface picker shown, guest on LAN, gets DHCP from router
- [ ] Custom DNS servers — verify comma-separated IPs applied in NAT mode
- [ ] Custom DNS field disabled in bridged mode
- [ ] Switching NAT ↔ Bridged triggers pool restart

### 2.5 Storage
- [ ] Disk usage displays correct value
- [ ] Storage location shown as `~/Library/Application Support/Bromure`
- [ ] Reset button — confirm dialog, deletes base image, does NOT delete profiles
- [ ] After reset, next launch rebuilds the image automatically

---

## 3. Browser & General

- [ ] Home page — change URL, verify Chromium opens to it on launch
- [ ] Language selector — verify Chromium UI language matches (en_US, fr_FR, etc.)
- [ ] "Same as System" language auto-detects from macOS locale

---

## 4. Performance

### 4.1 GPU Acceleration
- [ ] GPU ON (default) — `chrome://version` shows `--use-gl=angle --use-angle=gl --ignore-gpu-blocklist --enable-gpu-rasterization`
- [ ] GPU ON — does NOT show `--disable-gpu`
- [ ] GPU OFF — `chrome://version` shows `--disable-gpu`
- [ ] GPU OFF — does NOT show `--use-gl=angle` or `--enable-gpu-rasterization`
- [ ] GPU OFF → WebGL toggle is greyed out and forced off

### 4.2 WebGL
- [ ] WebGL OFF (default) — `chrome://version` shows `--disable-webgl --disable-3d-apis`
- [ ] WebGL ON — `chrome://version` does NOT show `--disable-webgl`
- [ ] WebGL ON + GPU OFF — WebGL is forced off (greyed out in settings)

### 4.3 Zero-Copy Rasterization
- [ ] Zero-Copy ON (default) — `chrome://version` shows `--enable-zero-copy`
- [ ] Zero-Copy OFF — `chrome://version` does NOT show `--enable-zero-copy`

### 4.4 Smooth Scrolling
- [ ] Smooth Scrolling ON (default) — `chrome://version` shows `--enable-smooth-scrolling`
- [ ] Smooth Scrolling OFF — `chrome://version` does NOT show `--enable-smooth-scrolling`

---

## 5. Media

### 5.1 Audio
- [ ] Audio ON (default) — play a YouTube video, verify sound on host
- [ ] Volume slider — adjust 0%→100%, verify guest volume changes
- [ ] Audio OFF — verify no sound from guest
- [ ] Speaker device picker — select specific output, verify audio routes correctly

### 5.2 Webcam
- [ ] Share Webcam OFF (default) — `navigator.mediaDevices.enumerateDevices()` returns no video inputs
- [ ] Share Webcam ON — verify camera feed visible on a test page (e.g., webcamtests.com)
- [ ] Camera device picker — select specific camera, verify correct feed
- [ ] Webcam quality picker — Low / Medium / High / Ultra change capture resolution
- [ ] Webcam Effects button shows blue dot when any effect configured

### 5.3 Webcam Effects
- [ ] City name overlay — verify text appears top-left of video feed
- [ ] Time zone — verify clock in overlay matches selected zone
- [ ] Display name — verify text appears bottom-right (news anchor style)
- [ ] Logo — pick an image file, verify it renders in overlay
- [ ] Font family — change font, verify overlay text updates
- [ ] Font size slider — verify text size changes (2.5%–8%)
- [ ] Face swap — enable, pick a reference image, verify face replaced in video feed
- [ ] Face swap banner — when active, visible "Anonymized" overlay on video feed

### 5.4 Microphone
- [ ] Share Microphone OFF (default) — no audio input devices in guest
- [ ] Share Microphone ON — verify mic input works (e.g., online voice recorder)
- [ ] Microphone device picker — select specific mic

---

## 6. Clipboard

- [ ] Shared Clipboard OFF (default) — copy on host, paste in guest fails (isolated)
- [ ] Shared Clipboard ON — copy text on host → paste in guest works
- [ ] Copy text in guest → paste on host works
- [ ] Copy image on host → paste in guest works
- [ ] Clipboard sharing uses vsock ports 5000/5001

---

## 7. File Transfer

### 7.1 Upload
- [ ] File Upload OFF (default) — drag file onto VM window: nothing happens
- [ ] File Upload ON — drag file onto VM window: drop zone highlights, file delivered to guest
- [ ] Verify drag hover feedback (highlight dropzones in guest Chromium)
- [ ] Upload via file drawer sidebar
- [ ] Drag-and-drop to web dropzone — navigate to images.google.com, drag an image file from macOS onto the search dropzone, verify file is uploaded and reverse-image search runs

### 7.2 Download
- [ ] File Download OFF (default) — downloads blocked by Chrome policy
- [ ] File Download ON — download a file, verify it appears in file drawer on host
- [ ] Download guard: inotify watcher blocks in-VM saves when downloads disabled

### 7.3 VirusTotal Integration
- [ ] VirusTotal toggle only visible when File Download is ON
- [ ] Enter valid API key — download a clean file → scan passes, file available
- [ ] Download a known malware test file (EICAR) → scan detects threat
- [ ] Block Threats ON — malicious file auto-blocked, cannot be saved or dragged
- [ ] Block Threats OFF — malicious file flagged but user can still save
- [ ] Block Unscannable ON — oversized/rate-limited files blocked
- [ ] Block Unscannable OFF — unscannable files available with warning
- [ ] Invalid/missing API key — verify graceful error message

---

## 8. Privacy & Safety

### 8.1 Malware Site Blocking
- [ ] Block Malware Sites OFF (default) — known malware domain resolves normally
- [ ] Block Malware Sites ON — verify DNS switched to Cloudflare security (1.1.1.2/1.0.0.2)
- [ ] Verify known malware/phishing domains blocked at DNS level

### 8.2 Phishing Warning
- [ ] Phishing Warning OFF (default)
- [ ] Enable without persistence — verify confirmation dialog appears
- [ ] Enable with persistence ON — Chromium extension loaded, warns on suspicious password entry
- [ ] Test with a domain NOT in Tranco top-10k — verify warning shown
- [ ] Test with a domain IN Tranco top-10k — no warning
- [ ] Navigate to https://travel.secl.io — verify phishing warning banner appears
- [ ] Click "I trust this site" on https://travel.secl.io — verify warning is dismissed and does NOT reappear on subsequent visits to the same site

### 8.3 Block Screen Capture
- [ ] Block Screen Capture OFF (default) — browser window visible in screenshots and screen recordings
- [ ] Block Screen Capture ON — browser window hidden from macOS screenshots (`Cmd+Shift+3/4`), screen recordings (QuickTime, OBS), and screen sharing apps (Zoom, Teams)
- [ ] Verify `window.sharingType = .none` is set on the NSWindow when enabled
- [ ] Verify the window content appears as a black rectangle in screen captures
- [ ] Toggle does not require a restart — takes effect on next session

### 8.4 Send Link to Other Session
- [ ] Toggle OFF (default) — no "Send to..." in right-click menu
- [ ] Toggle ON — right-click a link → "Send to [Profile Name]" appears
- [ ] Send link — verify it opens in the target profile's browser session
- [ ] Cross-session link delivery — open two sessions (A and B) with link sender enabled, right-click a link in session A and send to session B, verify the URL opens in session B's Chromium instance

---

## 9. Network Isolation

### 9.1 LAN Isolation
- [ ] Isolate from LAN OFF (default) — can reach 192.168.x.x / 10.x.x.x from guest
- [ ] Isolate from LAN ON — RFC 1918 addresses blocked, internet still works
- [ ] Disabled in bridged network mode (warning shown)

### 9.2 Port Restriction
- [ ] Restrict Ports OFF (default) — all outgoing ports allowed
- [ ] Restrict Ports ON — only allowed ports work (default: 80, 443)
- [ ] Custom port list — add 8080, verify guest can reach host:8080
- [ ] Port ranges — "8000-9000" allows all ports in range
- [ ] DNS (port 53) always allowed regardless of restriction
- [ ] Disabled in bridged network mode

---

## 10. VPN & Ads

### 10.1 Cloudflare WARP
- [ ] WARP OFF (default)
- [ ] WARP OFF — verify `warp-svc` is NOT running in the VM
- [ ] Enable WARP first time — EULA dialog appears, must accept to proceed
- [ ] Decline EULA — WARP stays OFF
- [ ] Accept EULA — WARP activates, verify `curl ifconfig.me` shows Cloudflare IP
- [ ] WARP ON — verify `warp-svc` is running in the VM
- [ ] Connect on Startup ON — verify WARP auto-connects when session launches
- [ ] Connect on Startup OFF — verify WARP agent runs but does not auto-connect
- [ ] WARP toggle is instant — 3-5s after boot, toggle WARP on, verify `ipconfig.me` shows a different IP; toggle off, verify original IP returns
- [ ] WARP with <2GB RAM — memory warning dialog, offer to increase
- [ ] WARP disabled when custom proxy is configured (orange warning)
- [ ] Verify gcompat + libresolv_stub.so loaded for WARP binary

### 10.2 Ad Blocking
- [ ] Block Ads OFF (default) — ads visible on ad-heavy sites
- [ ] Block Ads ON — verify ads blocked (test: ads-blocker.com or similar)
- [ ] Ad blocking disabled when custom proxy is configured

---

## 11. Enterprise / Proxy

### 11.1 HTTP Proxy
- [ ] No proxy (default) — direct internet access
- [ ] Set proxy host + port — verify all traffic routes through proxy
- [ ] Proxy with authentication — set username/password, verify authenticated proxy works
- [ ] Invalid proxy — verify graceful failure / error indication
- [ ] Proxy configured → WARP and Ad Blocking auto-disabled with warning

### 11.2 Root Certificates
- [ ] No custom CAs (default) — self-signed HTTPS sites show certificate error
- [ ] Add PEM certificate — verify HTTPS site with that CA loads without error
- [ ] Add DER/CRT/CER certificate — verify format handled correctly
- [ ] Multiple certificates — verify all trusted
- [ ] Remove certificate — verify it's no longer trusted
- [ ] Certificate subject summary shown correctly in list

---

## 12. VM Pool & Lifecycle

### 12.1 Pool Warm-up
- [ ] App launch — pool pre-warms VMs to idle shell (no chrome-env, no services)
- [ ] Verify `warmUp()` only boots to shell prompt
- [ ] `applyConfig()` at claim time writes chrome-env, starts dnsmasq/squid/WARP

### 12.2 Claim & Session
- [ ] Ephemeral profile claims a pre-warmed VM — fast session start
- [ ] Persistent profile boots dedicated VM with profile disk — slightly slower
- [ ] xinitrc waits up to 120s for `/tmp/bromure/chrome-ready` before launching Chromium
- [ ] Hardware setting changes (CPU, memory, audio, clipboard) → pool restart
- [ ] Software setting changes (dark mode, proxy, extensions) → applied at claim, no restart

### 12.3 Session Lifecycle
- [ ] Close browser window — session retired, VM kept in `retiredSessions`
- [ ] Open URL while session active — new tab in existing Chromium instance
- [ ] Multiple profiles open simultaneously — each in its own VM and window

---

## 13. URL Handling & Web Browser Registration

- [ ] App registered as web browser (http/https schemes)
- [ ] Click a link in another macOS app → opens in Bromure
- [ ] URL passed to `chromium-browser` CLI in guest
- [ ] If a session is already running for the active profile, opens new tab (not new window)

---

## 14. Image Build & Fonts

- [ ] `./build.sh` produces `bromure.app` bundle
- [ ] Image version change triggers automatic rebuild on next launch
- [ ] Fonts installed: ttf-freefont, ttf-dejavu, font-noto-emoji, font-liberation
- [ ] Verify emoji rendering in Chromium (🎉🔥👍)
- [ ] Verify Latin/CJK/Arabic/Hebrew text rendering

---

## 15. Window & UI

- [ ] Profile picker dropdown in main window
- [ ] Profile list sidebar (HSplitView mode)
- [ ] Settings window opens and closes cleanly
- [ ] All windows use `animationBehavior = .none` (no dealloc crashes)
- [ ] `orderOut` used for EULA/utility windows (not `close`)
- [ ] Window color border matches profile's selected color
- [ ] No window renders with "None" color (no border)

---

## 16. Settings Dependencies (Cross-cutting)

These verify that toggling one setting correctly enables/disables dependent settings:

| Action | Expected Side Effect |
|--------|---------------------|
| Persistence OFF | Encryption disabled, Phishing Warning disabled |
| Persistence ON | Encryption toggle available, Phishing toggle available |
| Custom Proxy set | WARP disabled, Ad Blocking disabled (orange warning) |
| Custom Proxy cleared | WARP and Ad Blocking re-enabled |
| Bridged network mode | LAN isolation disabled, Port restriction disabled |
| NAT network mode | LAN isolation and Port restriction available |
| File Download OFF | VirusTotal section hidden |
| File Download ON | VirusTotal section appears |
| Webcam OFF | Webcam Effects button hidden |
| Webcam ON | Webcam Effects button visible |
| WARP ON + RAM <2GB | Memory increase confirmation dialog |

---

## 17. Edge Cases & Error Handling

- [ ] Launch with no internet — verify app starts, shows appropriate error in guest
- [ ] Kill VM process mid-session — verify app recovers gracefully
- [ ] Corrupt profile JSON — verify app handles gracefully (defaults applied)
- [ ] Fill disk — verify meaningful error when image build or profile disk creation fails
- [ ] Rapid profile switching — no crashes or leaked VMs
- [ ] Simultaneous settings changes while VM is running
- [ ] Legacy profile migration (`isPersistent` → `persistent + encryptOnDisk = true`)

---

## 18. Automation API

### 18.1 HTTP API
- [ ] `GET /health` returns `{"status":"ok"}`
- [ ] `GET /profiles` lists all profiles
- [ ] `POST /sessions` creates a session with CDP endpoint
- [ ] `GET /sessions/:id` returns session info
- [ ] `DELETE /sessions/:id` destroys session and VM
- [ ] CDP proxy at `/cdp/:sessionId/*` correctly forwards to Chromium DevTools

### 18.2 Session Recording (Trace)

#### Recording Controls
- [ ] Trace enabled — record button (red circle) visible in titlebar
- [ ] Click record button toggles recording on/off (button changes between filled/hollow)
- [ ] `traceAutoStart = true` (default) — recording starts automatically when session opens
- [ ] `traceAutoStart = false` — session opens with recording paused, no events captured until manually started
- [ ] `toggle trace` AppleScript command toggles recording for a session
- [ ] Pausing recording stops event capture; resuming captures new events from that point

#### Basic Capture
- [ ] Trace disabled (default) — no trace events captured, no titlebar button
- [ ] Trace Level 1 (basic) — captures timestamp, method, URL, hostname, status, duration
- [ ] Trace Level 2 (headers) — additionally captures request/response headers and POST data
- [ ] Trace Level 3 (full) — additionally captures response bodies (truncated at 1 MB)
- [ ] Privacy warning shown at Level 2 (POST data may contain passwords)
- [ ] Privacy warning shown at Level 3 (response bodies contain sensitive data)

#### Hostname Tracking
- [ ] Hostname column displays correctly for all URL types (https, http, with port, IP address)
- [ ] Hostname filter dropdown shows all unique hostnames from the session
- [ ] Filtering by hostname shows only requests to that host

#### Page Tracking and Navigation Graph
- [ ] Each request records the document URL (page) that initiated it
- [ ] Redirects are tracked as separate events with `navType: "redirect"`
- [ ] Navigation events (page loads) are recorded with transition type (link, typed, form_submit)
- [ ] Navigation graph shows correct parent-child relationships (page → sub-resources)
- [ ] Redirect chains are visible: `page.html → (302) → redirected.html`

#### Form Field Snapshots
- [ ] Level 2+: form field values captured at the time of POST/PUT requests
- [ ] Password fields are captured (detects rot13 / transformation attacks)
- [ ] Form fields tab shows name, type, and value for each field
- [ ] Comparison between raw form values and POST data highlights transformations

#### Filtering and Search
- [ ] URL substring search filters events instantly
- [ ] Body content search filters by request/response body content
- [ ] Time range filter (start/end) correctly bounds results
- [ ] Method and status filters are combinable
- [ ] All filters can be reset at once

#### Viewer UI
- [ ] Trace viewer opens from titlebar button (waveform icon)
- [ ] Timeline table shows: time, method, hostname, URL path, status, duration bar, MIME type, page
- [ ] Waterfall duration bars are proportional and color-coded by status
- [ ] Detail pane tabs: Request, Response, Form Fields, Navigation, Timing
- [ ] Copy-to-clipboard buttons on request body, response body, and headers
- [ ] Copy shows brief "Copied" feedback

#### Data Lifecycle
- [ ] Trace data stored in SQLite (temp file) during session
- [ ] On session close with trace data — save prompt appears (Save/Discard/Cancel)
- [ ] Export as JSON produces valid, re-openable trace file
- [ ] Export as SQLite produces a valid database
- [ ] File > Open Trace opens a saved JSON trace file
- [ ] Discard deletes trace data immediately
- [ ] Cancel prevents session from closing

#### Automation
- [ ] `GET /sessions/:id/trace` returns captured events via HTTP API
- [ ] `get trace` AppleScript command returns JSON of events
- [ ] `bromure_get_trace` MCP tool returns trace summary
- [ ] Events include hostname, documentUrl, formFields when available

#### Performance
- [ ] Trace events arrive in real-time (live update in viewer)
- [ ] Large traffic (100+ requests) doesn't block the app
- [ ] SQLite queries with filters remain fast at 50K+ events

### 18.3 Allow Automation Flag
- [ ] New profiles default to `allowAutomation = false`
- [ ] Default "Private Browsing" profile has `allowAutomation = true`
- [ ] Profile with `allowAutomation = false` does NOT appear in `GET /profiles`
- [ ] Profile with `allowAutomation = false` cannot be used with `POST /sessions` (even by UUID)
- [ ] Profile with `allowAutomation = true` appears in `GET /profiles` and can create sessions
- [ ] Toggling `allowAutomation` on a profile shows a warning if automation server is disabled

### 18.3 AppleScript
- [ ] `list profiles` returns JSON array of profiles
- [ ] `create profile` returns UUID, profile appears in list
- [ ] `delete profile` removes profile
- [ ] `get/set profile setting` for all keys (homePage, gpu, audio, etc.)
- [ ] `get/set app setting` for all keys (vm.memoryGB, automation.enabled, etc.)
- [ ] `get app state` returns phase, poolReady, sessions

### 18.4 Debug Shell (BROMURE_DEBUG_CLAUDE)
- [ ] `POST /sessions/:id/exec` executes command in VM, returns stdout/stderr/exitCode
- [ ] Shell agent pool replenishes after command execution
- [ ] `GET /app/state` returns debug state info
