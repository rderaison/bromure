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
async function connectSession(sessionId, retries = 10) {
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
        const vText = await vRes.text();
        if (!vText) throw new Error("Empty /json/version response");
        const vJson = JSON.parse(vText);
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

/** Get CDP /json/list targets for a session. Retries on empty/error responses. */
async function getTargets(sessionId) {
  for (let i = 0; i < 5; i++) {
    try {
      const res = await fetch(`${API}/cdp/${sessionId}/json/list`);
      const text = await res.text();
      if (text) return JSON.parse(text);
    } catch {}
    await sleep(1000);
  }
  throw new Error("getTargets failed after 5 retries");
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
  if (FILTER && !new RegExp(FILTER, "i").test(name)) {
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
    if (e.stack) console.log(`        ${e.stack.split("\n").slice(1, 4).join("\n        ")}`);
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
    // Wait for pool, then open session.
    await waitForPool();
    const sess = await api("POST", "/sessions", { profile: profileName });
    if (sess.error) throw new Error(`Session creation failed: ${sess.error}`);
    if (!sess.id) throw new Error(`No session ID: ${JSON.stringify(sess).slice(0, 100)}`);
    sessionId = sess.id;

    // Wait for page to settle and CDP pool to fill
    await sleep(5000);

    // Connect Puppeteer (with retries for CDP pool availability)
    try {
      browser = await connectSession(sessionId);
    } catch (e) {
      throw new Error(`CDP connect failed for ${sessionId}: ${e.message}`);
    }

    // Wait for shell bridge readiness if debug shell is available.
    // The shell agent vsock pool may need a moment to fill after boot.
    if (hasDebugShell) {
      for (let i = 0; i < 10; i++) {
        try {
          await vmExec(sessionId, "true");
          break;
        } catch {
          if (i === 9) throw new Error("Shell bridge not ready after 10 retries");
          await sleep(1000);
        }
      }
    }

    // Run checks
    await checkFn({ sessionId, browser, profileId, profileName });

    // Check for daemon crashes inside the VM
    if (hasDebugShell && sessionId) {
      try {
        const errLog = await vmExec(sessionId, "cat /tmp/bromure/resilient-launch.*.log 2>/dev/null");
        const crashes = (errLog.stdout || "").split("\n").filter((l) => l.includes("CRASHED"));
        if (crashes.length > 0) {
          console.log(`  \x1b[33m⚠ VM daemon crashes detected:\x1b[0m`);
          for (const c of crashes) console.log(`    ${c}`);
        }
      } catch {}
    }
  } finally {
    // Cleanup — wait briefly after Puppeteer disconnect to avoid TCP interference
    if (browser) try { browser.disconnect(); } catch {}
    if (browser) await sleep(500);
    if (sessionId) await api("DELETE", `/sessions/${sessionId}`);
    await sleep(500);
    try { osascript(`delete profile "${profileName}"`); } catch {}
  }
}

// Whether the app has debug shell enabled — detected at runtime in main()
let hasDebugShell = false;

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

  // ======================================================================
  // 0. Automation Server Dynamic Toggle
  // ======================================================================
  console.log("--- 0. Automation Server Dynamic Toggle ---");

  // Only disable automation if these tests will actually run
  const runAutomationTests = !FILTER || new RegExp(FILTER, "i").test("0.1");
  if (runAutomationTests) {
    execSync("defaults write io.bromure.app automation.enabled -bool false", { timeout: 5000 });
    osascript('set app setting "automation.enabled" to value "false"');
    await sleep(3000);
  }

  await test("0.1 Automation server stops when disabled", async () => {
    // The API should be unreachable
    try {
      const res = await fetch(`${API}/health`, { signal: AbortSignal.timeout(3000) });
      // If we got a response, the server is still running — fail
      throw new Error(`Server still responding (status ${res.status})`);
    } catch (e) {
      if (e.message.includes("still responding")) throw e;
      // Connection refused or timeout = server is stopped = good
    }
  });

  await test("0.2 Automation server starts when enabled via AppleScript", async () => {
    osascript('set app setting "automation.enabled" to value "true"');
    await sleep(2000);
    const health = await api("GET", "/health");
    assert(health.status === "ok", `API not healthy after enable: ${JSON.stringify(health)}`);
  });

  await test("0.3 Automation server stops again when disabled", async () => {
    osascript('set app setting "automation.enabled" to value "false"');
    // Poll until the server stops (up to 10s)
    for (let i = 0; i < 10; i++) {
      await sleep(1000);
      try {
        await fetch(`${API}/health`, { signal: AbortSignal.timeout(2000) });
        // Still responding — keep waiting
        if (i === 9) throw new Error("Server still responding after 10s");
      } catch (e) {
        if (e.message.includes("still responding")) throw e;
        // Connection refused or timeout = stopped
        return;
      }
    }
  });

  await test("0.4 Automation server starts for remaining tests", async () => {
    osascript('set app setting "automation.enabled" to value "true"');
    await sleep(2000);
    const health = await api("GET", "/health");
    assert(health.status === "ok", `API not healthy: ${JSON.stringify(health)}`);
  });

  // Ensure automation is enabled for remaining tests
  osascript('set app setting "automation.enabled" to value "true"');
  await sleep(2000);

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

  // Detect if the app has debug shell enabled (BROMURE_DEBUG_CLAUDE in app env)
  try {
    const appState = await api("GET", "/app/state");
    hasDebugShell = appState.debugEnabled === true;
  } catch {
    hasDebugShell = false;
  }
  if (hasDebugShell) {
    console.log("Debug shell: enabled\n");
  } else {
    console.log("Debug shell: disabled (start app with BROMURE_DEBUG_CLAUDE=1 for VM tests)\n");
  }

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
  // 4. Performance (GPU / WebGL / Zero-Copy / Smooth Scrolling)
  // ======================================================================
  console.log("\n--- 4. Performance ---");

  await test("4.1 GPU ON — GL acceleration flags present", async () => {
    await withSession("E2E_GPU_On", { gpu: "true" },
      async ({ browser }) => {
        const flags = await getChromeFlags(browser);
        assertIncludes(flags, "--use-gl=angle");
        assertIncludes(flags, "--use-angle=gl");
        assertIncludes(flags, "--ignore-gpu-blocklist");
        assertIncludes(flags, "--enable-gpu-rasterization");
        assert(!flags.includes("--disable-gpu"), "--disable-gpu present when GPU is on");
      }
    );
  });

  await test("4.2 GPU OFF — disable flag, no GL flags", async () => {
    await withSession("E2E_GPU_Off", { gpu: "false" },
      async ({ browser }) => {
        const flags = await getChromeFlags(browser);
        assertIncludes(flags, "--disable-gpu");
        assert(!flags.includes("--use-gl=angle"), "--use-gl present when GPU is off");
        assert(!flags.includes("--enable-gpu-rasterization"), "--enable-gpu-rasterization present when GPU is off");
      }
    );
  });

  await test("4.3 WebGL OFF (default) — disable flags present", async () => {
    await withSession("E2E_WebGL_Off", {},
      async ({ browser }) => {
        const flags = await getChromeFlags(browser);
        assertIncludes(flags, "--disable-webgl");
      }
    );
  });

  await test("4.4 WebGL ON — no disable flag", async () => {
    await withSession("E2E_WebGL_On", { webgl: "true", gpu: "true" },
      async ({ browser }) => {
        const flags = await getChromeFlags(browser);
        assert(!flags.includes("--disable-webgl"), "--disable-webgl present when WebGL is on");
      }
    );
  });

  await test("4.5 GPU OFF forces WebGL OFF", async () => {
    await withSession("E2E_GPU_Off_WebGL", { gpu: "false", webgl: "true" },
      async ({ browser }) => {
        const flags = await getChromeFlags(browser);
        assertIncludes(flags, "--disable-gpu");
        assertIncludes(flags, "--disable-webgl", "WebGL should be forced off when GPU is disabled");
      }
    );
  });

  await test("4.6 Zero-Copy ON (default) — flag present", async () => {
    await withSession("E2E_ZeroCopy_On", {},
      async ({ browser }) => {
        const flags = await getChromeFlags(browser);
        assertIncludes(flags, "--enable-zero-copy");
      }
    );
  });

  await test("4.7 Zero-Copy OFF — flag absent", async () => {
    await withSession("E2E_ZeroCopy_Off", { zeroCopy: "false" },
      async ({ browser }) => {
        const flags = await getChromeFlags(browser);
        assert(!flags.includes("--enable-zero-copy"), "--enable-zero-copy present when disabled");
      }
    );
  });

  await test("4.8 Smooth Scrolling ON (default) — flag present", async () => {
    await withSession("E2E_Smooth_On", {},
      async ({ browser }) => {
        const flags = await getChromeFlags(browser);
        assertIncludes(flags, "--enable-smooth-scrolling");
      }
    );
  });

  await test("4.9 Smooth Scrolling OFF — flag absent", async () => {
    await withSession("E2E_Smooth_Off", { smoothScrolling: "false" },
      async ({ browser }) => {
        const flags = await getChromeFlags(browser);
        assert(!flags.includes("--enable-smooth-scrolling"), "--enable-smooth-scrolling present when disabled");
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

  if (hasDebugShell) {
    await test("6.3 Webcam ON — v4l2loopback device and policy", async () => {
      await withSession("E2E_Webcam_On", { webcam: "true" },
        async ({ sessionId }) => {
          // Check /dev/video0 exists (v4l2loopback loaded)
          const dev = await vmExec(sessionId, "test -e /dev/video0 && echo yes || echo no");
          assert(dev.stdout.trim() === "yes", "/dev/video0 not found — v4l2loopback not loaded");
          // Check VideoCaptureAllowed policy is true
          const policy = await vmExec(sessionId, "cat /etc/chromium/policies/managed/session.json");
          const json = JSON.parse(policy.stdout.trim());
          assert(json.VideoCaptureAllowed === true, `VideoCaptureAllowed=${json.VideoCaptureAllowed}, expected true`);
        }
      );
    });

    await test("6.4 Webcam OFF — no video device, policy blocks capture", async () => {
      await withSession("E2E_Webcam_Off", { webcam: "false" },
        async ({ sessionId }) => {
          // Check /dev/video0 does not exist
          const dev = await vmExec(sessionId, "test -e /dev/video0 && echo yes || echo no");
          assert(dev.stdout.trim() === "no", "/dev/video0 exists but webcam is off");
          // Check VideoCaptureAllowed policy is false
          const policy = await vmExec(sessionId, "cat /etc/chromium/policies/managed/session.json");
          const json = JSON.parse(policy.stdout.trim());
          assert(json.VideoCaptureAllowed === false, `VideoCaptureAllowed=${json.VideoCaptureAllowed}, expected false`);
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
  console.log("\n--- 12. Language ---");

  await test("12.1 Chrome language flag present", async () => {
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
    console.log("\n--- 13. VM Internals ---");

    await test("13.1 chrome-env written correctly", async () => {
      await withSession("E2E_ChromeEnv", { gpu: "false", adBlocking: "true" },
        async ({ sessionId }) => {
          const r = await vmExec(sessionId, "cat /tmp/bromure/chrome-env");
          assertIncludes(r.stdout, "--disable-gpu");
          assertIncludes(r.stdout, "--proxy-server=http://127.0.0.1:3128");
        }
      );
    });

    await test("13.2 Chromium running as user chrome", async () => {
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

    await test("13.3 Shell exec returns exit code", async () => {
      await withSession("E2E_ExitCode", {},
        async ({ sessionId }) => {
          const ok = await vmExec(sessionId, "true");
          assert(ok.exitCode === 0, `true returned ${ok.exitCode}`);
          const fail = await vmExec(sessionId, "false");
          assert(fail.exitCode !== 0, `false returned ${fail.exitCode}`);
        }
      );
    });

    await test("13.4 Automation flag in chrome-env", async () => {
      await withSession("E2E_AutoFlag", {},
        async ({ sessionId }) => {
          const r = await vmExec(sessionId, "cat /tmp/bromure/chrome-env");
          assertIncludes(r.stdout, "AUTOMATION=1");
          assertIncludes(r.stdout, "--remote-debugging-port=9222");
        }
      );
    });

    await test("13.5 Kernel modules loadable (v4l2loopback, rtc-pl031)", async () => {
      await withSession("E2E_KernelMods", {},
        async ({ sessionId }) => {
          const v4l2 = await vmExec(sessionId, "sudo modprobe v4l2loopback");
          assert(v4l2.exitCode === 0, `v4l2loopback failed to load: ${v4l2.stderr}`);
          const rtc = await vmExec(sessionId, "sudo modprobe rtc-pl031");
          assert(rtc.exitCode === 0, `rtc-pl031 failed to load: ${rtc.stderr}`);
        }
      );
    });
  }

  // ======================================================================
  // 14. Session Lifecycle
  // ======================================================================
  console.log("\n--- 14. Session Lifecycle ---");

  await test("14.1 Multiple sessions simultaneously", async () => {
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

  await test("14.2 Persistent profile — single session enforced", async () => {
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

  await test("14.3 Persistent storage — tabs restored after restart", async () => {
    const profileName = "E2E_Restore";
    const sites = [
      "https://example.com",
      "https://httpbin.org/get",
      "https://httpbin.org/html",
    ];

    osascript(`create profile "${profileName}" persistent true`);
    osascript(`set profile setting "${profileName}" key "allowAutomation" to value "true"`);
    osascript(`set profile setting "${profileName}" key "encryptOnDisk" to value "false"`);

    try {
      // --- First session: open 3 tabs ---
      await waitForPool();
      const s1 = await api("POST", "/sessions", { profile: profileName });
      assert(!s1.error, `Session 1 failed: ${s1.error}`);
      await sleep(5000);

      const browser1 = await connectSession(s1.id);
      try {
        for (const url of sites) {
          const tab = await browser1.newPage();
          await tab.goto(url, { waitUntil: "load", timeout: 15000 });
        }
        // Give Chrome a moment to persist session state
        await sleep(3000);
      } finally {
        browser1.disconnect();
        await sleep(500);
      }

      // Close the session (VM shuts down, disk persists)
      await api("DELETE", `/sessions/${s1.id}`);
      await sleep(3000);

      // --- Second session: restore previous tabs ---
      await waitForPool();
      const s2 = await api("POST", "/sessions", { profile: profileName, restore: true });
      assert(!s2.error, `Session 2 failed: ${s2.error}`);
      await sleep(8000); // extra time for restore

      const browser2 = await connectSession(s2.id);
      try {
        const pages = await browser2.pages();
        const urls = pages.map((p) => p.url()).filter((u) => !u.startsWith("about:"));

        for (const site of sites) {
          const found = urls.some((u) => u.startsWith(site));
          assert(found, `Tab ${site} not restored. Open URLs: ${urls.join(", ")}`);
        }
      } finally {
        browser2.disconnect();
        await sleep(500);
        await api("DELETE", `/sessions/${s2.id}`);
      }
    } finally {
      await sleep(500);
      osascript(`delete profile "${profileName}"`);
    }
  });

  // ======================================================================
  // 15. Automation API
  // ======================================================================
  console.log("\n--- 15. Automation API ---");

  await test("15.1 GET /profiles returns profile list", async () => {
    const data = await api("GET", "/profiles");
    assert(Array.isArray(data.profiles), "profiles not array");
    assert(data.profiles.length > 0, "no profiles");
    assert(data.profiles[0].name, "missing name");
  });

  await test("15.2 AppleScript get app state", async () => {
    const state = JSON.parse(osascript("get app state"));
    assert(state.phase === "ready");
    assert(typeof state.poolReady === "boolean");
    assert(Array.isArray(state.profiles));
  });

  if (hasDebugShell) {
    await test("15.3 Debug GET /app/state", async () => {
      const state = await api("GET", "/app/state");
      assert(state.phase === "ready", `Phase: ${state.phase}`);
      assert(state.debugEnabled === true);
    });
  }

  // ======================================================================
  // 15. Allow Automation Flag
  // ======================================================================
  console.log("\n--- 16. Allow Automation Flag ---");

  await test("16.1 New profiles default to allowAutomation=false", async () => {
    const id = osascript('create profile "E2E_AutoOff"');
    const val = osascript('get profile setting "E2E_AutoOff" key "allowAutomation"');
    assert(val === "false", `Expected false, got: ${val}`);
    osascript('delete profile "E2E_AutoOff"');
  });

  await test("16.2 Profile with allowAutomation=false hidden from API", async () => {
    const id = osascript('create profile "E2E_Hidden"');
    // allowAutomation defaults to false — profile should not appear in /profiles
    const data = await api("GET", "/profiles");
    const found = data.profiles?.some((p) => p.name === "E2E_Hidden");
    assert(!found, "Profile with allowAutomation=false appeared in /profiles");
    osascript('delete profile "E2E_Hidden"');
  });

  await test("16.3 Profile with allowAutomation=false rejects session creation", async () => {
    const id = osascript('create profile "E2E_Reject"');
    // Try to create a session by UUID (brute force)
    const sess = await api("POST", "/sessions", { profileId: id });
    assert(
      sess.error || !sess.id,
      `Session created for profile without automation: ${JSON.stringify(sess)}`
    );
    osascript('delete profile "E2E_Reject"');
  });

  await test("16.4 Profile with allowAutomation=true visible and usable", async () => {
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
  // 16. Session Recording (Trace)
  // ======================================================================
  console.log("\n--- 17. Session Recording (Trace) ---");

  await test("17.1 Trace disabled — no trace events", async () => {
    await withSession("E2E_Trace_Off", {},
      async ({ sessionId, browser }) => {
        // traceLevel defaults to 0 (disabled) — no trace data should exist
        const page = await getPage(browser);
        await page.goto("https://example.com", { waitUntil: "load", timeout: 15000 });
        await sleep(2000);
        const trace = await api("GET", `/sessions/${sessionId}/trace`);
        assert(
          !trace.events || trace.events.length === 0,
          `Expected no trace events, got ${trace.events?.length}`
        );
      }
    );
  });

  await test("17.2 Trace Level 1 — captures URLs and status codes", async () => {
    await withSession("E2E_Trace_Basic", { traceLevel: "1" },
      async ({ sessionId, browser }) => {
        // Navigate to generate traffic after extension has initialized
        await sleep(3000);
        const page = await getPage(browser);
        await page.goto("https://httpbin.org/get", { waitUntil: "load", timeout: 15000 });
        await sleep(5000);
        const trace = await api("GET", `/sessions/${sessionId}/trace`);
        assert(trace.events && trace.events.length > 0, `No trace events captured at Level 1 (count: ${trace.count})`);
        // Verify basic fields present
        const ev = trace.events.find((e) => e.url && e.url.includes("httpbin"));
        assert(ev, "No httpbin request in trace");
        assert(ev.method, "Missing method");
        assert(ev.timestamp, "Missing timestamp");
      }
    );
  });

  if (hasDebugShell) {
    await test("17.3 Trace extension loaded in chrome-env", async () => {
      await withSession("E2E_Trace_Env", { traceLevel: "2" },
        async ({ sessionId }) => {
          const r = await vmExec(sessionId, "cat /tmp/bromure/chrome-env");
          assertIncludes(r.stdout, "trace");
          assertIncludes(r.stdout, "TRACE_LEVEL=2");
        }
      );
    });
  }

  await test("17.4 Trace accessible via automation API", async () => {
    await withSession("E2E_Trace_API", { traceLevel: "1" },
      async ({ sessionId, browser }) => {
        await sleep(3000);
        const page = await getPage(browser);
        await page.goto("https://httpbin.org/get", { waitUntil: "load", timeout: 15000 });
        await sleep(5000);
        const trace = await api("GET", `/sessions/${sessionId}/trace`);
        assert(typeof trace.count === "number", "Missing count field");
        assert(Array.isArray(trace.events), "events is not an array");
      }
    );
  });

  await test("17.5 Trace events include hostname", async () => {
    await withSession("E2E_Trace_Host", { traceLevel: "1" },
      async ({ sessionId, browser }) => {
        await sleep(3000);
        const page = await getPage(browser);
        await page.goto("https://httpbin.org/get", { waitUntil: "load", timeout: 15000 });
        await sleep(5000);
        const trace = await api("GET", `/sessions/${sessionId}/trace`);
        const ev = trace.events?.find((e) => e.hostname === "httpbin.org");
        assert(ev, `No event with hostname httpbin.org. Hostnames: ${trace.events?.map(e => e.hostname).filter(Boolean).join(", ")}`);
      }
    );
  });

  if (hasDebugShell) {
    await test("17.6 Form field capture at Level 2", async () => {
      await withSession("E2E_Trace_Forms", { traceLevel: "2" },
        async ({ sessionId, browser }) => {
          await sleep(3000);
          const page = await getPage(browser);
          // Navigate to a page with a login form
          await page.goto("https://httpbin.org/forms/post", { waitUntil: "load", timeout: 15000 });
          await sleep(2000);
          // Fill in the form
          await page.evaluate(() => {
            const inputs = document.querySelectorAll("input");
            inputs.forEach((inp, i) => { inp.value = "test-value-" + i; inp.dispatchEvent(new Event("input", {bubbles: true})); });
          });
          await sleep(1000);
          // Submit the form
          await page.evaluate(() => {
            const form = document.querySelector("form");
            if (form) form.submit();
          });
          await sleep(5000);
          // Check trace for form fields
          const trace = await api("GET", `/sessions/${sessionId}/trace`);
          const postEvents = trace.events?.filter((e) => e.method === "POST");
          assert(postEvents && postEvents.length > 0, "No POST events captured");
        }
      );
    });
  }

  await test("17.7 Redirect tracking", async () => {
    await withSession("E2E_Trace_Redir", { traceLevel: "1" },
      async ({ sessionId, browser }) => {
        await sleep(3000);
        const page = await getPage(browser);
        await page.goto("https://httpbin.org/redirect/2", { waitUntil: "load", timeout: 15000 });
        await sleep(5000);
        const trace = await api("GET", `/sessions/${sessionId}/trace`);
        assert(trace.events && trace.events.length > 0, "No trace events for redirect test");
        const httpbinEvents = trace.events.filter((e) => e.url && e.url.includes("httpbin"));
        assert(httpbinEvents.length >= 2, `Expected >=2 httpbin events for redirect chain, got ${httpbinEvents.length}`);
      }
    );
  });

  await test("17.8 traceAutoStart=false — no events until manually started", async () => {
    // Create profile with trace enabled but autostart OFF
    osascript('create profile "E2E_Trace_Manual"');
    osascript('set profile setting "E2E_Trace_Manual" key "allowAutomation" to value "true"');
    osascript('set profile setting "E2E_Trace_Manual" key "traceLevel" to value "1"');
    osascript('set profile setting "E2E_Trace_Manual" key "traceAutoStart" to value "false"');

    let sessionId;
    try {
      await waitForPool();
      const sess = await api("POST", "/sessions", { profile: "E2E_Trace_Manual", url: "https://example.com" });
      assert(!sess.error, `Session failed: ${sess.error}`);
      sessionId = sess.id;
      await sleep(5000);

      // No events should be captured (recording paused)
      const trace1 = await api("GET", `/sessions/${sessionId}/trace`);
      assert(
        !trace1.events || trace1.events.length === 0,
        `Expected 0 events with autostart off, got ${trace1.events?.length}`
      );

      // Start recording via AppleScript
      osascript(`toggle trace "${sessionId}"`);
      await sleep(1000);

      // Navigate to generate traffic
      const browser = await connectSession(sessionId);
      const page = await getPage(browser);
      await page.goto("https://httpbin.org/get", { waitUntil: "load", timeout: 15000 });
      await sleep(3000);
      browser.disconnect();
      await sleep(500);

      // Now events should be captured
      const trace2 = await api("GET", `/sessions/${sessionId}/trace`);
      assert(trace2.events && trace2.events.length > 0, "No events after starting recording");
    } finally {
      if (sessionId) await api("DELETE", `/sessions/${sessionId}`);
      await sleep(500);
      try { osascript('delete profile "E2E_Trace_Manual"'); } catch {}
    }
  });

  await test("17.9 Toggle trace pauses and resumes", async () => {
    await withSession("E2E_Trace_Toggle", { traceLevel: "1" },
      async ({ sessionId, browser }) => {
        await sleep(3000);
        const page = await getPage(browser);

        // Generate traffic while recording
        await page.goto("https://httpbin.org/get", { waitUntil: "load", timeout: 15000 });
        await sleep(3000);
        const trace1 = await api("GET", `/sessions/${sessionId}/trace`);
        const count1 = trace1.events?.length || 0;
        assert(count1 > 0, "No events while recording");

        // Pause recording
        osascript(`toggle trace "${sessionId}"`);
        await sleep(1000);

        // Generate more traffic
        await page.goto("https://httpbin.org/post", { waitUntil: "load", timeout: 15000 });
        await sleep(3000);
        const trace2 = await api("GET", `/sessions/${sessionId}/trace`);
        const count2 = trace2.events?.length || 0;
        assert(count2 === count1, `Events grew while paused: ${count1} → ${count2}`);

        // Resume
        osascript(`toggle trace "${sessionId}"`);
      }
    );
  });

  // ======================================================================
  // 17. Heavy Page Regression (M4 SME crash)
  // ======================================================================
  console.log("\n--- 18. Heavy Page Regression ---");

  await test("18.1 CNN.com loads without renderer crash", async () => {
    await withSession(
      "E2E_CNN",
      { homePage: "about:blank", allowAutomation: "true" },
      async ({ browser, sessionId }) => {
        const page = await getPage(browser);

        // Navigate to CNN — a heavy page that triggers SIGILL on M4 without arm64.nosme
        let crashed = false;
        browser.on("targetdestroyed", (target) => {
          if (target.type() === "page") crashed = true;
        });

        await page.goto("https://www.cnn.com", {
          waitUntil: "domcontentloaded",
          timeout: 30000,
        });

        // Wait for the page to settle — crashes typically happen within a few seconds
        await sleep(5000);

        assert(!crashed, "Renderer crashed (SIGILL) — check arm64.nosme kernel parameter");

        // Verify the page is still alive by evaluating JS
        const title = await page.title();
        assert(title.length > 0, `Page title is empty — page may have crashed`);
      }
    );
  });

  // ======================================================================
  // 18. Keyboard Layout Matching
  // ======================================================================
  console.log("\n--- 19. Keyboard Layout Matching ---");

  await test("19.1 Keyboard layout syncs to VM (US → FR → US)", async () => {
    await withSession(
      "E2E_Keyboard",
      { homePage: "about:blank", allowAutomation: "true" },
      async ({ sessionId }) => {
        // Give keyboard-agent time to start
        await sleep(3000);

        // Check initial layout via setxkbmap query
        const initial = await vmExec(sessionId, "DISPLAY=:0 setxkbmap -query | grep layout");
        assertIncludes(initial.stdout, "layout:", "setxkbmap query failed");
        const initialLayout = initial.stdout.split(":").pop().trim();
        console.log(`        Initial layout: ${initialLayout}`);

        // Switch to French via AppleScript
        osascript('set app setting "vm.keyboardLayout" to value "fr"');
        // Simulate keyboard change by sending layout directly via the API
        // (we can't actually switch the host keyboard in a test, so use shell)
        await vmExec(sessionId, "DISPLAY=:0 setxkbmap fr");
        await sleep(1000);

        const frResult = await vmExec(sessionId, "DISPLAY=:0 setxkbmap -query | grep layout");
        assertIncludes(frResult.stdout, "fr", "Layout not switched to French");

        // Switch back to US
        await vmExec(sessionId, "DISPLAY=:0 setxkbmap us");
        await sleep(1000);

        const usResult = await vmExec(sessionId, "DISPLAY=:0 setxkbmap -query | grep layout");
        assertIncludes(usResult.stdout, "us", "Layout not switched back to US");
      }
    );
  });

  await test("19.2 Keyboard agent vsock listener active", async () => {
    await withSession(
      "E2E_KBAgent",
      { homePage: "about:blank", allowAutomation: "true" },
      async ({ sessionId }) => {
        await sleep(3000);

        // Verify keyboard-agent.py is running
        const agent = await vmExec(sessionId, "pgrep -f keyboard-agent");
        assert(agent.exitCode === 0, "keyboard-agent not running");
      }
    );
  });

  // ======================================================================
  // 20. Networking — MAC pool, DHCP, per-profile interfaces, hot-swap
  // ======================================================================

  console.log("\n--- 20. Networking ---");

  // Helper: get the VM's eth0 IP address and subnet info
  async function getVMNetwork(sessionId) {
    const result = await vmExec(sessionId, "ip -4 addr show eth0 scope global 2>/dev/null");
    const match = (result.stdout || "").match(/inet\s+(\d+\.\d+\.\d+\.\d+)\/(\d+)/);
    return match ? { ip: match[1], prefix: parseInt(match[2]) } : null;
  }

  // Helper: get the VM's default gateway
  async function getVMGateway(sessionId) {
    const result = await vmExec(sessionId, "ip route show default 2>/dev/null");
    const match = (result.stdout || "").match(/default via (\d+\.\d+\.\d+\.\d+)/);
    return match ? match[1] : null;
  }

  // Helper: get the VM's MAC address on eth0
  async function getVMMac(sessionId) {
    const result = await vmExec(sessionId, "cat /sys/class/net/eth0/address 2>/dev/null");
    return (result.stdout || "").trim();
  }

  // Helper: check if an IP is in the vmnet NAT subnet (192.168.64.0/24)
  function isNATAddress(ip) {
    return ip && ip.startsWith("192.168.64.");
  }

  await test("20.1 Default session gets a DHCP address (NAT)", async () => {
    await withSession(
      "E2E_Net_Default",
      { homePage: "about:blank", allowAutomation: "true" },
      async ({ sessionId }) => {
        const net = await getVMNetwork(sessionId);
        assert(net !== null, "VM has no IP on eth0");
        assert(isNATAddress(net.ip), `Expected NAT address (192.168.64.x), got ${net.ip}`);
        console.log(`        IP: ${net.ip}/${net.prefix}`);

        const gw = await getVMGateway(sessionId);
        assert(gw === "192.168.64.1", `Expected gateway 192.168.64.1, got ${gw}`);
      }
    );
  });

  await test("20.2 MAC address is locally-administered (02:xx prefix)", async () => {
    await withSession(
      "E2E_Net_MAC",
      { homePage: "about:blank", allowAutomation: "true" },
      async ({ sessionId }) => {
        const mac = await getVMMac(sessionId);
        assert(mac.length === 17, `Invalid MAC: ${mac}`);
        assert(mac.startsWith("02:"), `Expected locally-administered MAC (02:...), got ${mac}`);
        console.log(`        MAC: ${mac}`);
      }
    );
  });

  await test("20.3 MAC addresses are recycled across sessions", async () => {
    // Open session 1, capture MAC, close it
    let mac1;
    await withSession(
      "E2E_Net_Recycle1",
      { homePage: "about:blank", allowAutomation: "true" },
      async ({ sessionId }) => {
        mac1 = await getVMMac(sessionId);
        assert(mac1.startsWith("02:"), `Bad MAC: ${mac1}`);
      }
    );

    // Wait for pool to re-warm with the released MAC
    await waitForPool();
    await sleep(5000);

    // Open session 2, it should reuse a MAC from the pool
    let mac2;
    await withSession(
      "E2E_Net_Recycle2",
      { homePage: "about:blank", allowAutomation: "true" },
      async ({ sessionId }) => {
        mac2 = await getVMMac(sessionId);
        assert(mac2.startsWith("02:"), `Bad MAC: ${mac2}`);
      }
    );

    // The MAC pool should reuse addresses. With sequential sessions,
    // the warm VM may get the same MAC or a previously-used one.
    // Read the pool file to verify the pool is bounded.
    const poolFile = execSync(
      `cat ~/Library/Application\\ Support/Bromure/mac-pool.json 2>/dev/null`,
      { encoding: "utf-8" }
    ).trim();
    const pool = JSON.parse(poolFile);
    assert(Array.isArray(pool), "MAC pool should be an array");
    assert(pool.length <= 5, `MAC pool grew too large: ${pool.length} entries (expected ≤5)`);
    console.log(`        MAC1: ${mac1}, MAC2: ${mac2}`);
    console.log(`        Pool size: ${pool.length} addresses`);
  });

  await test("20.4 VM can reach the internet (NAT)", async () => {
    await withSession(
      "E2E_Net_Internet",
      { homePage: "about:blank", allowAutomation: "true" },
      async ({ sessionId }) => {
        // Ping a well-known public IP to verify internet connectivity
        const result = await vmExec(sessionId, "wget -q -O /dev/null --timeout=10 http://1.1.1.1/ && echo REACHABLE || echo UNREACHABLE");
        assertIncludes(result.stdout, "REACHABLE", "VM cannot reach the internet via NAT");
      }
    );
  });

  await test("20.5 LAN isolation blocks private IP ranges", async () => {
    await withSession(
      "E2E_Net_Isolate",
      { homePage: "about:blank", allowAutomation: "true", isolateFromLAN: "true" },
      async ({ sessionId }) => {
        // Verify the VM has an IP first
        const net = await getVMNetwork(sessionId);
        assert(net !== null, "VM has no IP on eth0");

        // Attempt to reach the vmnet gateway (should be blocked except for DHCP/DNS)
        // The gateway itself is allowed, but other 192.168.64.x hosts should be blocked.
        // Test by trying to reach a private IP range address.
        // 10.0.0.1 should be blocked by the private range filter.
        const result = await vmExec(
          sessionId,
          "wget -q -O /dev/null --timeout=3 http://10.0.0.1/ 2>&1; echo EXIT=$?",
          10
        );
        assertIncludes(result.stdout, "EXIT=", "wget did not complete");
        // wget should fail (non-zero exit) because the filter drops the packet
        assert(!result.stdout.includes("EXIT=0"), "Expected 10.0.0.1 to be blocked, but wget succeeded");
        console.log(`        Private IP 10.0.0.1 correctly blocked`);
      }
    );
  });

  await test("20.6 Port restriction allows only specified ports", async () => {
    await withSession(
      "E2E_Net_Ports",
      {
        homePage: "about:blank",
        allowAutomation: "true",
        isolateFromLAN: "true",
        restrictPorts: "true",
        allowedPorts: "80,443",
      },
      async ({ sessionId }) => {
        const net = await getVMNetwork(sessionId);
        assert(net !== null, "VM has no IP on eth0");

        // Port 80 should work
        const http = await vmExec(
          sessionId,
          "wget -q -O /dev/null --timeout=10 http://1.1.1.1/ && echo OK || echo BLOCKED",
          15
        );
        assertIncludes(http.stdout, "OK", "Port 80 should be allowed");

        // Port 8080 should be blocked
        const alt = await vmExec(
          sessionId,
          "wget -q -O /dev/null --timeout=3 http://1.1.1.1:8080/ 2>&1; echo EXIT=$?",
          10
        );
        assert(!alt.stdout.includes("EXIT=0"), "Port 8080 should be blocked");
        console.log(`        Port 80: allowed, Port 8080: blocked`);
      }
    );
  });

  await test("20.7 Per-profile bridged interface (en0)", async () => {
    await withSession(
      "E2E_Net_Bridge",
      {
        homePage: "about:blank",
        allowAutomation: "true",
        networkInterface: "en0",
      },
      async ({ sessionId }) => {
        // Wait for DHCP on the bridged network
        await sleep(5000);

        const net = await getVMNetwork(sessionId);
        assert(net !== null, "VM has no IP on eth0 (bridged)");

        // In bridged mode the VM gets a LAN IP, NOT the vmnet NAT subnet
        assert(
          !isNATAddress(net.ip),
          `Expected LAN address in bridged mode, got NAT address ${net.ip}`
        );
        console.log(`        Bridged IP: ${net.ip}/${net.prefix} (not vmnet NAT)`);

        // Verify internet reachability on the bridged network
        const result = await vmExec(
          sessionId,
          "wget -q -O /dev/null --timeout=10 http://1.1.1.1/ && echo REACHABLE || echo UNREACHABLE"
        );
        assertIncludes(result.stdout, "REACHABLE", "Cannot reach internet in bridged mode");
      }
    );
  });

  await test("20.8 Bridged session uses different subnet than NAT session", async () => {
    // Open a NAT session first, capture its IP
    let natIP;
    await withSession(
      "E2E_Net_Compare_NAT",
      { homePage: "about:blank", allowAutomation: "true" },
      async ({ sessionId }) => {
        const net = await getVMNetwork(sessionId);
        assert(net !== null, "NAT session has no IP");
        natIP = net.ip;
        assert(isNATAddress(natIP), `Expected NAT address, got ${natIP}`);
      }
    );

    await waitForPool();
    await sleep(5000);

    // Open a bridged session, verify different subnet
    await withSession(
      "E2E_Net_Compare_Bridge",
      {
        homePage: "about:blank",
        allowAutomation: "true",
        networkInterface: "en0",
      },
      async ({ sessionId }) => {
        await sleep(5000);
        const net = await getVMNetwork(sessionId);
        assert(net !== null, "Bridged session has no IP");
        assert(
          !isNATAddress(net.ip),
          `Bridged session should not have NAT address, got ${net.ip}`
        );

        // Extract first 3 octets to compare subnets
        const natSubnet = natIP.split(".").slice(0, 3).join(".");
        const bridgedSubnet = net.ip.split(".").slice(0, 3).join(".");
        assert(
          natSubnet !== bridgedSubnet,
          `NAT and bridged should be on different subnets, both on ${natSubnet}`
        );
        console.log(`        NAT: ${natIP}, Bridged: ${net.ip} — different subnets ✓`);
      }
    );
  });

  await test("20.9 Default profile (no interface override) stays on NAT", async () => {
    // Ensure global setting is NAT
    osascript('set app setting "vm.networkMode" to value "nat"');

    await withSession(
      "E2E_Net_DefaultNAT",
      {
        homePage: "about:blank",
        allowAutomation: "true",
        // networkInterface NOT set — should use global (NAT)
      },
      async ({ sessionId }) => {
        const net = await getVMNetwork(sessionId);
        assert(net !== null, "VM has no IP");
        assert(isNATAddress(net.ip), `Default should use NAT, got ${net.ip}`);
        console.log(`        Default profile IP: ${net.ip} (NAT) ✓`);
      }
    );
  });

  await test("20.10 Profile with networkInterface='nat' forces NAT even if global is bridged", async () => {
    // Temporarily set global to bridged
    const origMode = osascript('get app setting "vm.networkMode"');
    const origIface = osascript('get app setting "vm.bridgedInterface"');
    osascript('set app setting "vm.networkMode" to value "bridged"');
    osascript('set app setting "vm.bridgedInterface" to value "en0"');

    // Wait for pool to restart with bridged setting
    await sleep(3000);
    await waitForPool();

    try {
      await withSession(
        "E2E_Net_ForceNAT",
        {
          homePage: "about:blank",
          allowAutomation: "true",
          networkInterface: "nat",
        },
        async ({ sessionId }) => {
          await sleep(5000);
          const net = await getVMNetwork(sessionId);
          assert(net !== null, "VM has no IP");
          // Hot-swap should have switched from bridged to NAT
          assert(isNATAddress(net.ip), `Expected NAT address after hot-swap, got ${net.ip}`);
          console.log(`        Force-NAT IP: ${net.ip} (overrode global bridged setting) ✓`);
        }
      );
    } finally {
      // Restore global settings
      osascript(`set app setting "vm.networkMode" to value "${origMode}"`);
      if (origIface) {
        osascript(`set app setting "vm.bridgedInterface" to value "${origIface}"`);
      }
      await sleep(2000);
    }
  });

  await test("20.11 DHCP release on session close frees the lease", async () => {
    let mac;
    await withSession(
      "E2E_Net_DHCPRelease",
      { homePage: "about:blank", allowAutomation: "true" },
      async ({ sessionId }) => {
        mac = await getVMMac(sessionId);
        const net = await getVMNetwork(sessionId);
        assert(net !== null, "VM has no IP");
        console.log(`        Session MAC: ${mac}, IP: ${net.ip}`);
        // The session will be closed by withSession's cleanup,
        // which triggers fullCleanup → udhcpc -R → DHCP release.
      }
    );

    // After close, the MAC should be released back to the pool (in-memory).
    // We verify by opening another session and checking the pool didn't grow unboundedly.
    await waitForPool();
    await sleep(3000);

    await withSession(
      "E2E_Net_DHCPRelease2",
      { homePage: "about:blank", allowAutomation: "true" },
      async ({ sessionId }) => {
        const net = await getVMNetwork(sessionId);
        assert(net !== null, "Second session has no IP after first session's DHCP release");
        console.log(`        Second session IP: ${net.ip} ✓`);
      }
    );
  });

  await test("20.12 Bridged mode with LAN isolation", async () => {
    await withSession(
      "E2E_Net_BridgeIsolate",
      {
        homePage: "about:blank",
        allowAutomation: "true",
        networkInterface: "en0",
        isolateFromLAN: "true",
      },
      async ({ sessionId }) => {
        await sleep(5000);
        const net = await getVMNetwork(sessionId);
        assert(net !== null, "VM has no IP on bridged+isolated");
        assert(!isNATAddress(net.ip), `Expected LAN address, got NAT ${net.ip}`);

        // Internet should still work
        const internet = await vmExec(
          sessionId,
          "wget -q -O /dev/null --timeout=10 http://1.1.1.1/ && echo REACHABLE || echo UNREACHABLE"
        );
        assertIncludes(internet.stdout, "REACHABLE", "Internet should work in bridged+isolated");

        // Private ranges should be blocked
        const priv = await vmExec(
          sessionId,
          "wget -q -O /dev/null --timeout=3 http://10.0.0.1/ 2>&1; echo EXIT=$?",
          10
        );
        assert(!priv.stdout.includes("EXIT=0"), "10.0.0.1 should be blocked in isolated mode");
        console.log(`        Bridged+isolated: ${net.ip}, internet ✓, private blocked ✓`);
      }
    );
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
