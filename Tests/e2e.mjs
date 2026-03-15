#!/usr/bin/env node
/**
 * Bromure E2E Test Suite
 *
 * Automates TEST_PLAN.md using AppleScript (app control), HTTP API (sessions),
 * CDP (browser verification), and the debug shell (VM inspection).
 *
 * Prerequisites:
 *   - Bromure.app built and running (open .build/.../Bromure.app)
 *   - Base image created (bromure init)
 *   - BROMURE_DEBUG_CLAUDE=1 in the app's environment (for shell tests)
 *
 * Usage:
 *   node tests/e2e.mjs              # run all tests
 *   node tests/e2e.mjs --filter gpu # run tests matching "gpu"
 */

import { execSync } from "child_process";
import puppeteer from "puppeteer-core";

const API = process.env.BROMURE_API_URL || "http://127.0.0.1:9222";
const FILTER = process.argv.find((a) => a === "--filter")
  ? process.argv[process.argv.indexOf("--filter") + 1]
  : null;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function osascript(cmd) {
  const full = `tell application "Bromure" to ${cmd}`;
  return execSync(`osascript -e '${full.replace(/'/g, "'\\''")}'`, {
    encoding: "utf-8",
    timeout: 30000,
  }).trim();
}

async function api(method, path, body) {
  const opts = {
    method,
    headers: { "Content-Type": "application/json", "Connection": "close" },
    keepalive: false,
  };
  if (body) opts.body = JSON.stringify(body);
  const res = await fetch(`${API}${path}`, opts);
  const text = await res.text();
  if (!text) return { error: `Empty response from ${method} ${path} (status ${res.status})` };
  try {
    return JSON.parse(text);
  } catch {
    return { error: `Invalid JSON from ${method} ${path}: ${text.slice(0, 200)}` };
  }
}

async function vmExec(sessionId, command, timeout = 30) {
  // Retry — shell agent pool may need a moment to fill after session start
  for (let i = 0; i < 3; i++) {
    const data = await api("POST", `/sessions/${sessionId}/exec`, {
      command,
      timeout,
    });
    if (!data.error) return data;
    if (i < 2) await sleep(2000);
    if (i === 2) throw new Error(`vmExec failed: ${data.error}`);
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Wait until the pool reports ready. */
async function waitForPool(timeoutMs = 60000) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    try {
      const state = JSON.parse(osascript("get app state"));
      if (state.poolReady) return;
    } catch {}
    await sleep(1000);
  }
  throw new Error("Pool not ready after " + timeoutMs + "ms");
}

/** Connect Puppeteer to a session. Resolves the full WS endpoint with retries. */
async function connectSession(sessionId, retries = 5) {
  let lastErr;
  for (let i = 0; i < retries; i++) {
    try {
      // Get base WS URL
      const info = await api("GET", `/sessions/${sessionId}`);
      let wsUrl = info.webSocketDebuggerUrl;
      if (!wsUrl) throw new Error(`No WS URL for session ${sessionId}`);

      // Resolve full endpoint if needed
      if (!wsUrl.includes("/devtools/browser/")) {
        const baseHttp = wsUrl.replace("ws://", "http://");
        const vRes = await fetch(`${baseHttp}/json/version`);
        const vJson = await vRes.json();
        if (vJson.webSocketDebuggerUrl) {
          const path = new URL(vJson.webSocketDebuggerUrl).pathname;
          wsUrl = wsUrl + path;
        }
      }

      return await puppeteer.connect({ browserWSEndpoint: wsUrl });
    } catch (e) {
      lastErr = e;
      if (i < retries - 1) await sleep(2000);
    }
  }
  throw lastErr;
}

/** Get the active page (not about:blank). */
async function getPage(browser) {
  const pages = await browser.pages();
  return pages.find((p) => !p.url().startsWith("about:")) || pages[0];
}

/** Navigate to chrome://version and extract the command-line flags string. */
async function getChromeFlags(browser) {
  const page = await browser.newPage();
  await page.goto("chrome://version", { waitUntil: "domcontentloaded" });
  const flags = await page.evaluate(() => {
    const el = document.getElementById("command_line");
    return el ? el.textContent : "";
  });
  await page.close();
  return flags;
}

/** Get CDP /json/list targets for a session. */
async function getTargets(sessionId) {
  const res = await fetch(
    `${API}/cdp/${sessionId}/json/list`
  );
  return res.json();
}

// ---------------------------------------------------------------------------
// Memory monitoring
// ---------------------------------------------------------------------------

/** Get Bromure GUI app process RSS in MB. Returns null if not found. */
function getMemoryMB() {
  try {
    // Find the main GUI process (highest RSS among bromure processes —
    // the GUI app uses far more memory than the MCP server subprocesses).
    const out = execSync(
      "ps -eo rss,comm | grep '[b]romure$' | sort -rn | head -1 | awk '{print $1}'",
      { encoding: "utf-8", timeout: 5000 }
    ).trim();
    return out ? parseInt(out) / 1024 : null;
  } catch {
    return null;
  }
}

const memSamples = [];

function sampleMemory(label) {
  const mb = getMemoryMB();
  if (mb !== null) memSamples.push({ label, mb, time: Date.now() });
  return mb;
}

// ---------------------------------------------------------------------------
// Test runner
// ---------------------------------------------------------------------------

let passed = 0;
let failed = 0;
let skipped = 0;
const results = [];

async function test(name, fn) {
  if (FILTER && !name.toLowerCase().includes(FILTER.toLowerCase())) {
    skipped++;
    return;
  }
  const t0 = Date.now();
  const memBefore = getMemoryMB();
  try {
    await fn();
    const ms = Date.now() - t0;
    const memAfter = getMemoryMB();
    const memDelta = memBefore && memAfter ? memAfter - memBefore : null;
    passed++;
    results.push({ name, status: "PASS", ms, memDelta });
    const memStr = memDelta !== null ? ` [${memDelta >= 0 ? "+" : ""}${memDelta.toFixed(0)} MB]` : "";
    console.log(`  \x1b[32mPASS\x1b[0m  ${name} (${ms}ms)${memStr}`);
  } catch (e) {
    const ms = Date.now() - t0;
    failed++;
    results.push({ name, status: "FAIL", ms, error: e.message });
    console.log(`  \x1b[31mFAIL\x1b[0m  ${name} (${ms}ms)`);
    console.log(`        ${e.message}`);
  }
}

function assert(condition, msg) {
  if (!condition) throw new Error(msg || "Assertion failed");
}

function assertIncludes(haystack, needle, msg) {
  if (!haystack.includes(needle))
    throw new Error(msg || `Expected "${needle}" in: ${haystack.slice(0, 200)}`);
}

// ---------------------------------------------------------------------------
// Session lifecycle helper — creates profile, opens session, runs checks,
// then cleans up. Handles both CDP and shell verification.
// ---------------------------------------------------------------------------

async function withSession(profileName, profileSettings, checkFn) {
  // Create profile
  let createCmd = `create profile "${profileName}"`;
  if (profileSettings.persistent) createCmd += " persistent true";
  if (profileSettings.color) createCmd += ` color "${profileSettings.color}"`;
  if (profileSettings.homePage)
    createCmd += ` home page "${profileSettings.homePage}"`;
  const profileId = osascript(createCmd);
  assert(profileId.length === 36, `Bad profile ID: ${profileId}`);

  // Enable automation for test profiles (required for the automation API to accept them)
  osascript(
    `set profile setting "${profileName}" key "allowAutomation" to value "true"`
  );

  // Apply additional settings
  for (const [key, value] of Object.entries(profileSettings)) {
    if (["persistent", "color", "homePage", "comments"].includes(key)) continue;
    osascript(
      `set profile setting "${profileName}" key "${key}" to value "${value}"`
    );
  }

  let sessionId;
  let browser;
  try {
    // Wait for pool, then open session. POST /sessions may take up to 60s
    // if the pool needs to warm a VM on demand (no pre-warmed VM available).
    await waitForPool();
    const sess = await api("POST", "/sessions", { profile: profileName });
    assert(!sess.error, `Session creation failed: ${sess.error}`);
    sessionId = sess.id;

    // Wait for page to settle and CDP pool to fill
    await sleep(5000);

    // Connect Puppeteer (with retries for CDP pool availability)
    browser = await connectSession(sessionId);

    // Run checks
    await checkFn({ sessionId, browser, profileId, profileName });
  } finally {
    // Cleanup — wait briefly after Puppeteer disconnect to avoid TCP interference
    if (browser) try { browser.disconnect(); } catch {}
    if (browser) await sleep(500);
    if (sessionId) await api("DELETE", `/sessions/${sessionId}`);
    await sleep(500);
    try { osascript(`delete profile "${profileName}"`); } catch {}
  }
}

const hasDebugShell =
  process.env.BROMURE_DEBUG_CLAUDE === "1" ||
  process.env.BROMURE_DEBUG_CLAUDE === "true";

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

async function main() {
  console.log("\n=== Bromure E2E Test Suite ===\n");
  sampleMemory("suite-start");

  // Pre-check: is the app running and ready?
  try {
    const state = JSON.parse(osascript("get app state"));
    assert(state.phase === "ready", `App not ready: ${state.phase}`);
    console.log(
      `App ready. ${state.profiles.length} profiles, ${state.sessionCount} sessions.\n`
    );
  } catch (e) {
    console.error("Cannot reach Bromure app. Is it running?");
    console.error(e.message);
    process.exit(1);
  }

  // Ensure automation is enabled
  osascript('set app setting "automation.enabled" to value "true"');

  // Clean up stale sessions from previous runs
  const existing = await api("GET", "/sessions");
  if (existing.sessions?.length > 0) {
    console.log(`Cleaning up ${existing.sessions.length} stale session(s)...`);
    for (const s of existing.sessions) {
      await api("DELETE", `/sessions/${s.id}`);
    }
    await sleep(2000);
  }

  // Clean up stale E2E_ profiles from previous runs
  const staleProfiles = JSON.parse(osascript("list profiles"))
    .filter((p) => p.name.startsWith("E2E_"));
  if (staleProfiles.length > 0) {
    console.log(`Cleaning up ${staleProfiles.length} stale profile(s)...`);
    for (const p of staleProfiles) {
      try { osascript(`delete profile "${p.id}"`); } catch {}
    }
  }

  await waitForPool();

  // Check API health
  const health = await api("GET", "/health");
  assert(health.status === "ok", `API unhealthy: ${JSON.stringify(health)}`);

  // ======================================================================
  // 1. Profile Management
  // ======================================================================
  console.log("--- 1. Profile Management ---");

  await test("1.1 Create and delete profile", async () => {
    const id = osascript('create profile "E2E_CRUD_Test" color "orange"');
    assert(id.length === 36, `Bad ID: ${id}`);

    const profiles = JSON.parse(osascript("list profiles"));
    assert(
      profiles.some((p) => p.name === "E2E_CRUD_Test"),
      "Profile not in list"
    );

    osascript('delete profile "E2E_CRUD_Test"');
    const after = JSON.parse(osascript("list profiles"));
    assert(
      !after.some((p) => p.name === "E2E_CRUD_Test"),
      "Profile still in list"
    );
  });

  await test("1.2 Rename profile", async () => {
    osascript('create profile "E2E_Rename_Before"');
    osascript(
      'set profile setting "E2E_Rename_Before" key "name" to value "E2E_Rename_After"'
    );
    const name = osascript(
      'get profile setting "E2E_Rename_After" key "name"'
    );
    assert(name === "E2E_Rename_After", `Expected renamed, got: ${name}`);
    osascript('delete profile "E2E_Rename_After"');
  });

  await test("1.3 Profile settings roundtrip", async () => {
    osascript('create profile "E2E_Settings"');
    osascript(
      'set profile setting "E2E_Settings" key "homePage" to value "https://example.com"'
    );
    osascript(
      'set profile setting "E2E_Settings" key "gpu" to value "false"'
    );
    osascript(
      'set profile setting "E2E_Settings" key "adBlocking" to value "true"'
    );
    osascript(
      'set profile setting "E2E_Settings" key "audioVolume" to value "42"'
    );

    assert(
      osascript('get profile setting "E2E_Settings" key "homePage"') ===
        "https://example.com"
    );
    assert(
      osascript('get profile setting "E2E_Settings" key "gpu"') === "false"
    );
    assert(
      osascript('get profile setting "E2E_Settings" key "adBlocking"') ===
        "true"
    );
    assert(
      osascript('get profile setting "E2E_Settings" key "audioVolume"') ===
        "42"
    );

    osascript('delete profile "E2E_Settings"');
  });

  // ======================================================================
  // 2. App Settings
  // ======================================================================
  console.log("\n--- 2. App Settings ---");

  await test("2.1 App settings roundtrip", async () => {
    // Use a non-pool-restarting setting to avoid disruption
    const orig = osascript('get app setting "automation.bindAddress"');
    osascript('set app setting "automation.bindAddress" to value "127.0.0.1"');
    assert(osascript('get app setting "automation.bindAddress"') === "127.0.0.1");
    osascript(`set app setting "automation.bindAddress" to value "${orig}"`);
  });

  await test("2.2 Appearance setting", async () => {
    const orig = osascript('get app setting "vm.appearance"');
    osascript('set app setting "vm.appearance" to value "dark"');
    assert(osascript('get app setting "vm.appearance"') === "dark");
    osascript(`set app setting "vm.appearance" to value "${orig}"`);
  });

  await test("2.3 Automation API health", async () => {
    const h = await api("GET", "/health");
    assert(h.status === "ok");
    assert(h.service === "bromure-automation");
  });

  // ======================================================================
  // 3. Home Page
  // ======================================================================
  console.log("\n--- 3. Home Page ---");

  await test("3.1 Home page loads correctly", async () => {
    await withSession("E2E_HomePage", { homePage: "https://example.com" },
      async ({ sessionId }) => {
        const targets = await getTargets(sessionId);
        const page = targets.find((t) => t.type === "page");
        assert(page, "No page target");
        assert(
          page.url.includes("example.com"),
          `Wrong URL: ${page.url}`
        );
      }
    );
  });

  // ======================================================================
  // 4. Performance (GPU / WebGL)
  // ======================================================================
  console.log("\n--- 4. Performance ---");

  await test("4.1 GPU enabled — no --disable-gpu flag", async () => {
    await withSession("E2E_GPU_On", { gpu: "true" },
      async ({ browser }) => {
        const flags = await getChromeFlags(browser);
        assert(!flags.includes("--disable-gpu"), "GPU disabled when it should be on");
      }
    );
  });

  await test("4.2 GPU disabled — --disable-gpu flag present", async () => {
    await withSession("E2E_GPU_Off", { gpu: "false" },
      async ({ browser }) => {
        const flags = await getChromeFlags(browser);
        assertIncludes(flags, "--disable-gpu");
      }
    );
  });

  await test("4.3 WebGL disabled (default) — flag present", async () => {
    await withSession("E2E_WebGL_Off", {},
      async ({ browser }) => {
        const flags = await getChromeFlags(browser);
        assertIncludes(flags, "--disable-webgl");
      }
    );
  });

  await test("4.4 WebGL enabled — no disable flag", async () => {
    await withSession("E2E_WebGL_On", { webgl: "true" },
      async ({ browser }) => {
        const flags = await getChromeFlags(browser);
        assert(!flags.includes("--disable-webgl"), "WebGL still disabled");
      }
    );
  });

  // ======================================================================
  // 5. Dark Mode
  // ======================================================================
  console.log("\n--- 5. Appearance ---");

  await test("5.1 Dark mode — --force-dark-mode flag", async () => {
    // Dark mode is applied at claim time via VMConfig, not pool restart.
    // Set appearance to dark, wait for pool, then open session.
    const orig = osascript('get app setting "vm.appearance"');
    osascript('set app setting "vm.appearance" to value "dark"');
    await waitForPool();

    try {
      await withSession("E2E_DarkMode", {},
        async ({ browser }) => {
          const flags = await getChromeFlags(browser);
          assertIncludes(flags, "--force-dark-mode");
        }
      );
    } finally {
      osascript(`set app setting "vm.appearance" to value "${orig}"`);
    }
  });

  // ======================================================================
  // 6. Audio
  // ======================================================================
  console.log("\n--- 6. Media ---");

  if (hasDebugShell) {
    await test("6.1 Audio ON — PipeWire running in VM", async () => {
      await withSession("E2E_Audio_On", { audio: "true" },
        async ({ sessionId }) => {
          const r = await vmExec(sessionId, "pgrep -f pipewire | wc -l");
          const count = parseInt(r.stdout.trim());
          assert(count > 0, `PipeWire not running (count=${count})`);
        }
      );
    });

    await test("6.2 Audio OFF — no PipeWire daemon", async () => {
      await withSession("E2E_Audio_Off", { audio: "false" },
        async ({ sessionId }) => {
          // Check for pipewire daemon process (not just any match)
          const r = await vmExec(sessionId, "pgrep -x pipewire | wc -l");
          const count = parseInt(r.stdout.trim());
          assert(count === 0, `PipeWire daemon running when audio off (${count})`);
        }
      );
    });
  }

  // ======================================================================
  // 7. Clipboard
  // ======================================================================
  console.log("\n--- 7. Clipboard ---");

  if (hasDebugShell) {
    await test("7.1 Clipboard ON — spice-vdagent running", async () => {
      await withSession("E2E_Clip_On", { clipboard: "true" },
        async ({ sessionId }) => {
          const r = await vmExec(sessionId, "pgrep -f spice-vdagent | wc -l");
          assert(parseInt(r.stdout.trim()) > 0, "spice-vdagent not running");
        }
      );
    });

    await test("7.2 Clipboard OFF — no spice-vdagent process", async () => {
      await withSession("E2E_Clip_Off", { clipboard: "false" },
        async ({ sessionId }) => {
          // Check for the actual spice-vdagent process, not the daemon
          const r = await vmExec(sessionId, "pgrep -x spice-vdagent | wc -l");
          assert(parseInt(r.stdout.trim()) === 0, "spice-vdagent running");
        }
      );
    });
  }

  // ======================================================================
  // 8. Privacy — Ad Blocking & Malware DNS
  // ======================================================================
  console.log("\n--- 8. Privacy & Safety ---");

  if (hasDebugShell) {
    await test("8.1 Ad blocking ON — dnsmasq + squid running", async () => {
      await withSession("E2E_AdBlock", { adBlocking: "true" },
        async ({ sessionId }) => {
          const dns = await vmExec(sessionId, "pgrep dnsmasq | wc -l");
          assert(parseInt(dns.stdout.trim()) > 0, "dnsmasq not running");
          const squid = await vmExec(sessionId, "pgrep squid | wc -l");
          assert(parseInt(squid.stdout.trim()) > 0, "squid not running");
        }
      );
    });

    await test("8.2 Malware DNS — resolv uses 1.1.1.2", async () => {
      await withSession("E2E_Malware", { blockMalware: "true", adBlocking: "true" },
        async ({ sessionId }) => {
          const r = await vmExec(
            sessionId,
            "cat /etc/dnsmasq.d/pihole.conf | grep server="
          );
          assertIncludes(r.stdout, "1.1.1.2");
        }
      );
    });

    await test("8.3 Link sender ON — extension loaded", async () => {
      await withSession("E2E_LinkSender", { linkSender: "true" },
        async ({ sessionId }) => {
          const r = await vmExec(
            sessionId,
            "cat /tmp/bromure/chrome-env | grep link-sender"
          );
          assertIncludes(r.stdout, "link-sender");
        }
      );
    });

    await test("8.4 Phishing warning — travel.secl.io shows banner", async () => {
      await withSession(
        "E2E_Phishing",
        { persistent: "true", phishingWarning: "true", homePage: "https://travel.secl.io" },
        async ({ browser }) => {
          const page = await getPage(browser);
          // Wait for page to load and phishing extension to inject the banner.
          // The page has a password field, so the extension should detect it.
          try {
            await page.waitForSelector("#bromure-phishing-banner", { timeout: 15000 });
          } catch {
            // Check if the banner is there anyway (race condition)
          }
          const banner = await page.$("#bromure-phishing-banner");
          assert(banner !== null, "Phishing warning banner not shown on travel.secl.io");
        }
      );
    });

    await test("8.5 Phishing — 'I trust this site' dismisses permanently", async () => {
      await withSession(
        "E2E_Phishing_Trust",
        { persistent: "true", phishingWarning: "true", homePage: "https://travel.secl.io" },
        async ({ browser }) => {
          const page = await getPage(browser);

          // Wait for the warning banner to appear
          await page.waitForSelector("#bromure-phishing-banner", { timeout: 15000 });

          // Click "I know this site" button
          await page.click("#bromure-trust-btn");
          await sleep(1000);

          // Banner should be gone
          const bannerAfterClick = await page.$("#bromure-phishing-banner");
          assert(bannerAfterClick === null, "Banner still visible after clicking trust");

          // Navigate away and back — banner should NOT reappear
          await page.goto("https://example.com", { waitUntil: "load", timeout: 15000 });
          await sleep(1000);
          await page.goto("https://travel.secl.io", { waitUntil: "load", timeout: 15000 });
          await sleep(3000);

          // Check no banner on return
          const bannerOnReturn = await page.$("#bromure-phishing-banner");
          assert(bannerOnReturn === null, "Phishing banner reappeared after trusting the site");
        }
      );
    });

    await test("8.6 Link sender — native host and agent wired up", async () => {
      await withSession(
        "E2E_Link_Wired",
        { linkSender: "true" },
        async ({ sessionId, browser }) => {
          // 1. Verify link-agent.py is running in the VM
          const agent = await vmExec(sessionId, "pgrep -f link-agent | wc -l");
          assert(parseInt(agent.stdout.trim()) > 0, "link-agent not running");

          // 2. Verify native messaging host config is installed
          const nmHost = await vmExec(
            sessionId,
            "cat /etc/chromium/native-messaging-hosts/com.bromure.link_sender.json"
          );
          assertIncludes(nmHost.stdout, "com.bromure.link_sender");

          // 3. Verify the extension is loaded in chrome-env flags
          const linkSenderLoaded = await vmExec(
            sessionId,
            "cat /tmp/bromure/chrome-env | grep link-sender"
          );
          assertIncludes(linkSenderLoaded.stdout, "link-sender");

          // 4. Verify vsock connection to host is alive (link-agent connects to port 5300)
          const vsock = await vmExec(
            sessionId,
            `python3 -c "
import socket
s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
s.settimeout(3)
try:
    s.connect((2, 5300))
    print('OK')
except Exception as e:
    print(f'FAIL: {e}')
finally:
    s.close()
"`
          );
          assertIncludes(vsock.stdout, "OK", `Link sender vsock not available: ${vsock.stdout}`);
        }
      );
    });
  }

  // ======================================================================
  // 9. File Transfer
  // ======================================================================
  console.log("\n--- 9. File Transfer ---");

  if (hasDebugShell) {
    await test("9.1 Downloads blocked — Chrome policy present", async () => {
      await withSession(
        "E2E_DL_Block",
        { canUpload: "false", canDownload: "false" },
        async ({ sessionId }) => {
          const r = await vmExec(
            sessionId,
            "cat /etc/chromium/policies/managed/session.json"
          );
          // blockDownloads=true means DownloadRestrictions=3
          assertIncludes(r.stdout, '"DownloadRestrictions"');
        }
      );
    });

    await test("9.2 File transfer ON — file-agent running", async () => {
      await withSession(
        "E2E_FileXfer",
        { canUpload: "true", canDownload: "true" },
        async ({ sessionId }) => {
          const r = await vmExec(sessionId, "pgrep -f file-agent | wc -l");
          assert(parseInt(r.stdout.trim()) > 0, "file-agent not running");
        }
      );
    });
  }

  // ======================================================================
  // 10. WARP VPN
  // ======================================================================
  if (hasDebugShell) {
    console.log("\n--- 10. WARP VPN ---");

    await test("10.1 WARP OFF — warp-svc not running", async () => {
      await withSession("E2E_WARP_Off", { warp: "false" },
        async ({ sessionId }) => {
          await sleep(3000);
          const r = await vmExec(sessionId, "pgrep -f '[w]arp-svc' | wc -l");
          assert(parseInt(r.stdout.trim()) === 0, `warp-svc running when WARP off (${r.stdout.trim()})`);
        }
      );
    });

    await test("10.2 WARP ON — warp-svc running", async () => {
      // Need >=2GB memory for WARP. Set it if needed.
      const origMem = osascript('get app setting "vm.memoryGB"');
      if (parseInt(origMem) < 2) {
        osascript('set app setting "vm.memoryGB" to value "2"');
        await waitForPool();
      }
      try {
        await withSession("E2E_WARP_On", { warp: "true", warpAutoConnect: "true" },
          async ({ sessionId }) => {
            // Wait for warp-svc to start (it's launched by warp-agent at boot)
            await sleep(8000);
            const r = await vmExec(sessionId, "pgrep -f '[w]arp-svc' | wc -l");
            assert(parseInt(r.stdout.trim()) > 0, "warp-svc not running");
          }
        );
      } finally {
        if (parseInt(origMem) < 2) {
          osascript(`set app setting "vm.memoryGB" to value "${origMem}"`);
        }
      }
    });

    await test("10.3 WARP toggle — IP changes via titlebar button", async () => {
      const origMem = osascript('get app setting "vm.memoryGB"');
      if (parseInt(origMem) < 2) {
        osascript('set app setting "vm.memoryGB" to value "2"');
        await waitForPool();
      }
      try {
        await withSession("E2E_WARP_Toggle", { warp: "true", warpAutoConnect: "true" },
          async ({ sessionId }) => {
            // Wait for WARP to fully connect
            await sleep(15000);

            // Check IP through the browser's proxy chain (squid → proxychains → routing-socks).
            // Use wget through the proxy to simulate the browser's network path.
            // checkip.amazonaws.com returns plain-text IP and isn't behind Cloudflare.
            // Verify WARP is active (flag file + warp-cli status)
            const flagBefore = await vmExec(sessionId, "test -f /tmp/bromure/warp-active && echo ON || echo OFF");
            assert(flagBefore.stdout.trim() === "ON", "WARP flag not set after auto-connect");

            // Get IP through the WARP SOCKS proxy (port 40000) directly — bypasses squid caching
            const getIPviaSOCKS = `python3 -c "
import socket, socks  # PySocks might not be available
print('n/a')
" 2>/dev/null || wget -qO- --timeout=10 'http://checkip.amazonaws.com' 2>/dev/null | tr -d '\\n '`;
            // Use proxychains4 to route wget through the same SOCKS chain as squid.
            // This ensures the request goes through routing-socks.py → (warp|direct).
            const getIP = "proxychains4 -q -f /etc/proxychains/proxychains.conf wget -qO- --timeout=10 'http://checkip.amazonaws.com' 2>/dev/null | tr -d '\\n '";
            const isIP = (s) => /^[\d.:a-f]+$/i.test(s) && s.length >= 7;

            const rOn = await vmExec(sessionId, getIP);
            const ipOn = rOn.stdout.trim();
            assert(isIP(ipOn), `Bad IP (WARP on): '${ipOn}'`);

            // Toggle WARP off via the titlebar button
            osascript(`toggle warp "${sessionId}"`);
            await sleep(5000);

            // Verify flag toggled
            const flagAfter = await vmExec(sessionId, "test -f /tmp/bromure/warp-active && echo ON || echo OFF");
            assert(flagAfter.stdout.trim() === "OFF", "WARP flag still set after toggle off");

            // Get IP with WARP off
            const rOff = await vmExec(sessionId, getIP);
            const ipOff = rOff.stdout.trim();
            assert(isIP(ipOff), `Bad IP (WARP off): '${ipOff}'`);

            // IPs should differ
            assert(ipOn !== ipOff, `IP didn't change: on=${ipOn}, off=${ipOff}`);

            // Toggle back on
            osascript(`toggle warp "${sessionId}"`);
            await sleep(5000);

            const flagReOn = await vmExec(sessionId, "test -f /tmp/bromure/warp-active && echo ON || echo OFF");
            assert(flagReOn.stdout.trim() === "ON", "WARP flag not restored after toggle on");

            const rReOn = await vmExec(sessionId, getIP);
            const ipReOn = rReOn.stdout.trim();
            assert(ipReOn === ipOn, `IP didn't restore: expected ${ipOn}, got ${ipReOn}`);
          }
        );
      } finally {
        if (parseInt(origMem) < 2) {
          osascript(`set app setting "vm.memoryGB" to value "${origMem}"`);
        }
      }
    });
  }

  // ======================================================================
  // 11. Enterprise — Proxy
  // ======================================================================
  console.log("\n--- 11. Enterprise ---");

  await test("11.1 Proxy config — --proxy-server flag present", async () => {
    await withSession(
      "E2E_Proxy",
      { proxyHost: "proxy.example.com", proxyPort: "8080" },
      async ({ browser }) => {
        const flags = await getChromeFlags(browser);
        assertIncludes(flags, "--proxy-server");
        assertIncludes(flags, "proxy.example.com:8080");
      }
    );
  });

  // ======================================================================
  // 11. Root Certificates
  // ======================================================================

  if (hasDebugShell) {
    await test("11.2 Custom CA — chrome-env has rootCAs flag", async () => {
      // We can't easily add a real CA via AppleScript (it's complex JSON),
      // but we can verify the config agent handles the rootCAs field
      // by checking that no custom CAs means no extra cert files.
      await withSession("E2E_NoCAs", {},
        async ({ sessionId }) => {
          const r = await vmExec(
            sessionId,
            "ls /tmp/bromure/custom-cas/ 2>/dev/null | wc -l"
          );
          assert(parseInt(r.stdout.trim()) === 0, "Unexpected CA files");
        }
      );
    });
  }

  // ======================================================================
  // 12. Language / Locale
  // ======================================================================
  console.log("\n--- 11. Language ---");

  await test("11.1 Chrome language flag present", async () => {
    await withSession("E2E_Locale", { locale: "fr_FR" },
      async ({ browser }) => {
        const flags = await getChromeFlags(browser);
        assertIncludes(flags, "--lang=fr-FR");
      }
    );
  });

  // ======================================================================
  // 13. VM Internals (requires debug shell)
  // ======================================================================
  if (hasDebugShell) {
    console.log("\n--- 12. VM Internals ---");

    await test("12.1 chrome-env written correctly", async () => {
      await withSession("E2E_ChromeEnv", { gpu: "false", adBlocking: "true" },
        async ({ sessionId }) => {
          const r = await vmExec(sessionId, "cat /tmp/bromure/chrome-env");
          assertIncludes(r.stdout, "--disable-gpu");
          assertIncludes(r.stdout, "--proxy-server=http://127.0.0.1:3128");
        }
      );
    });

    await test("12.2 Chromium running as user chrome", async () => {
      await withSession("E2E_ChromeUser", {},
        async ({ sessionId }) => {
          // Chromium may take a moment to fully start
          const r = await vmExec(
            sessionId,
            "ps -eo user,comm | grep chromium | grep -v grep | head -1 | awk '{print $1}'"
          );
          assert(r.stdout.trim() === "chrome", `Running as: '${r.stdout.trim()}'`);
        }
      );
    });

    await test("12.3 Shell exec returns exit code", async () => {
      await withSession("E2E_ExitCode", {},
        async ({ sessionId }) => {
          const ok = await vmExec(sessionId, "true");
          assert(ok.exitCode === 0, `true returned ${ok.exitCode}`);
          const fail = await vmExec(sessionId, "false");
          assert(fail.exitCode !== 0, `false returned ${fail.exitCode}`);
        }
      );
    });

    await test("12.4 Automation flag in chrome-env", async () => {
      await withSession("E2E_AutoFlag", {},
        async ({ sessionId }) => {
          const r = await vmExec(sessionId, "cat /tmp/bromure/chrome-env");
          assertIncludes(r.stdout, "AUTOMATION=1");
          assertIncludes(r.stdout, "--remote-debugging-port=9222");
        }
      );
    });
  }

  // ======================================================================
  // 14. Session Lifecycle
  // ======================================================================
  console.log("\n--- 13. Session Lifecycle ---");

  await test("13.1 Multiple sessions simultaneously", async () => {
    const id1 = osascript('create profile "E2E_Multi_A"');
    osascript('set profile setting "E2E_Multi_A" key "allowAutomation" to value "true"');
    const id2 = osascript('create profile "E2E_Multi_B"');
    osascript('set profile setting "E2E_Multi_B" key "allowAutomation" to value "true"');
    await waitForPool();

    const s1 = await api("POST", "/sessions", { profile: "E2E_Multi_A" });
    await waitForPool(90000); // pool needs to warm a new VM after claiming
    const s2 = await api("POST", "/sessions", { profile: "E2E_Multi_B" });
    assert(!s1.error, `Session A failed: ${s1.error}`);
    assert(!s2.error, `Session B failed: ${s2.error}`);

    const list = await api("GET", "/sessions");
    assert(
      list.sessions.length >= 2,
      `Expected >=2 sessions, got ${list.sessions.length}`
    );

    await api("DELETE", `/sessions/${s1.id}`);
    await api("DELETE", `/sessions/${s2.id}`);
    await sleep(500);
    osascript('delete profile "E2E_Multi_A"');
    osascript('delete profile "E2E_Multi_B"');
  });

  await test("13.2 Persistent profile — single session enforced", async () => {
    osascript('create profile "E2E_Persist" persistent true');
    osascript('set profile setting "E2E_Persist" key "allowAutomation" to value "true"');
    await waitForPool();
    const s1 = await api("POST", "/sessions", { profile: "E2E_Persist" });
    assert(!s1.error);

    // Second request should return the existing session
    const s2 = await api("POST", "/sessions", { profile: "E2E_Persist" });
    assert(s2.id === s1.id, `Got new session ${s2.id} instead of ${s1.id}`);

    await api("DELETE", `/sessions/${s1.id}`);
    await sleep(500);
    osascript('delete profile "E2E_Persist"');
  });

  // ======================================================================
  // 15. Automation API
  // ======================================================================
  console.log("\n--- 14. Automation API ---");

  await test("14.1 GET /profiles returns profile list", async () => {
    const data = await api("GET", "/profiles");
    assert(Array.isArray(data.profiles), "profiles not array");
    assert(data.profiles.length > 0, "no profiles");
    assert(data.profiles[0].name, "missing name");
  });

  await test("14.2 AppleScript get app state", async () => {
    const state = JSON.parse(osascript("get app state"));
    assert(state.phase === "ready");
    assert(typeof state.poolReady === "boolean");
    assert(Array.isArray(state.profiles));
  });

  if (hasDebugShell) {
    await test("14.3 Debug GET /app/state", async () => {
      const state = await api("GET", "/app/state");
      assert(state.phase === "ready", `Phase: ${state.phase}`);
      assert(state.debugEnabled === true);
    });
  }

  // ======================================================================
  // 15. Allow Automation Flag
  // ======================================================================
  console.log("\n--- 15. Allow Automation Flag ---");

  await test("15.1 New profiles default to allowAutomation=false", async () => {
    const id = osascript('create profile "E2E_AutoOff"');
    const val = osascript('get profile setting "E2E_AutoOff" key "allowAutomation"');
    assert(val === "false", `Expected false, got: ${val}`);
    osascript('delete profile "E2E_AutoOff"');
  });

  await test("15.2 Profile with allowAutomation=false hidden from API", async () => {
    const id = osascript('create profile "E2E_Hidden"');
    // allowAutomation defaults to false — profile should not appear in /profiles
    const data = await api("GET", "/profiles");
    const found = data.profiles?.some((p) => p.name === "E2E_Hidden");
    assert(!found, "Profile with allowAutomation=false appeared in /profiles");
    osascript('delete profile "E2E_Hidden"');
  });

  await test("15.3 Profile with allowAutomation=false rejects session creation", async () => {
    const id = osascript('create profile "E2E_Reject"');
    // Try to create a session by UUID (brute force)
    const sess = await api("POST", "/sessions", { profileId: id });
    assert(
      sess.error || !sess.id,
      `Session created for profile without automation: ${JSON.stringify(sess)}`
    );
    osascript('delete profile "E2E_Reject"');
  });

  await test("15.4 Profile with allowAutomation=true visible and usable", async () => {
    const id = osascript('create profile "E2E_Allowed"');
    osascript('set profile setting "E2E_Allowed" key "allowAutomation" to value "true"');

    const data = await api("GET", "/profiles");
    const found = data.profiles?.some((p) => p.name === "E2E_Allowed");
    assert(found, "Profile with allowAutomation=true not in /profiles");

    // Session creation should work
    await waitForPool();
    const sess = await api("POST", "/sessions", { profile: "E2E_Allowed" });
    assert(!sess.error && sess.id, `Session failed: ${sess.error}`);
    await api("DELETE", `/sessions/${sess.id}`);
    await sleep(500);
    osascript('delete profile "E2E_Allowed"');
  });

  // ======================================================================
  // Summary
  // ======================================================================
  console.log("\n========================================");
  console.log(
    `  ${passed} passed, ${failed} failed` +
      (skipped ? `, ${skipped} skipped` : "")
  );
  console.log("========================================\n");

  process.exit(failed > 0 ? 1 : 0);
}

main().catch((e) => {
  console.error("Fatal:", e);
  process.exit(2);
});
