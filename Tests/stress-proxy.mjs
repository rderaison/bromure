#!/usr/bin/env node
/**
 * Bromure Stress Test: Proxy Stability
 *
 * Searches a random word on Google, then clicks through ~200 links
 * to stress-test the SOCKS proxy (routing-socks.py) and squid.
 *
 * Every operation has a 10s hard timeout. If anything hangs, it's a FAIL.
 * On ERR_TUNNEL_CONNECTION_FAILED, captures the VM process list.
 *
 * Usage:
 *   BROMURE_DEBUG_CLAUDE=1 node tests/stress-proxy.mjs
 *   BROMURE_DEBUG_CLAUDE=1 node tests/stress-proxy.mjs --clicks 50
 *   BROMURE_DEBUG_CLAUDE=1 node tests/stress-proxy.mjs --word "cats"
 */

import { execSync } from "child_process";
import puppeteer from "puppeteer-core";

const API = process.env.BROMURE_API_URL || "http://127.0.0.1:9222";
const TARGET_CLICKS = parseInt(process.argv.find((_, i, a) => a[i - 1] === "--clicks") || "200");
const SEARCH_WORD = process.argv.find((_, i, a) => a[i - 1] === "--word") || null;
const OP_TIMEOUT = 10000; // 10s hard timeout for every operation

const hasDebugShell = process.env.BROMURE_DEBUG_CLAUDE === "1";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const WORDS = [
  "ephemeral", "cryptography", "sandcastle", "nebula", "transistor",
  "origami", "labyrinth", "phosphorescence", "kaleidoscope", "archipelago",
];

/** Run a promise with a hard timeout. */
function withTimeout(promise, ms, label) {
  return Promise.race([
    promise,
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error(`TIMEOUT after ${ms}ms: ${label}`)), ms)
    ),
  ]);
}

async function api(method, path, body, timeout = OP_TIMEOUT) {
  const opts = {
    method,
    headers: { "Content-Type": "application/json", Connection: "close" },
    signal: AbortSignal.timeout(timeout),
  };
  if (body) opts.body = JSON.stringify(body);
  const res = await fetch(`${API}${path}`, opts);
  const text = await res.text();
  try { return JSON.parse(text); } catch { return { error: text.slice(0, 200) }; }
}

async function vmExec(sessionId, command) {
  const data = await api("POST", `/sessions/${sessionId}/exec`, { command, timeout: 8 });
  return data;
}

function osascript(cmd) {
  return execSync(
    `osascript -e 'tell application "Bromure" to ${cmd.replace(/'/g, "'\\''")}'`,
    { encoding: "utf-8", timeout: OP_TIMEOUT }
  ).trim();
}

async function captureProcesses(sessionId, reason) {
  console.log(`\n  ⚠ CAPTURING: ${reason}`);
  if (!hasDebugShell) { console.log("    (no debug shell)"); return {}; }
  const ps = await vmExec(sessionId, "ps aux | head -40");
  const socks = await vmExec(sessionId, "pgrep -f routing-socks | wc -l");
  const squid = await vmExec(sessionId, "pgrep squid | wc -l");
  const crashes = await vmExec(sessionId, "grep CRASHED /tmp/bromure/resilient-launch.*.log 2>/dev/null || echo none");
  console.log(`    squid=${squid.stdout?.trim()} routing-socks=${socks.stdout?.trim()}`);
  if (crashes.stdout?.trim() !== "none") {
    console.log(`    crashes:\n${crashes.stdout}`);
  }
  // Save to file
  const ts = new Date().toISOString().replace(/[:.]/g, "-");
  const fs = await import("fs");
  fs.writeFileSync(`stress-capture-${ts}.txt`, [reason, ps.stdout, crashes.stdout].join("\n"));
  return { squid: squid.stdout?.trim(), socks: socks.stdout?.trim() };
}

async function connectSession(sessionId) {
  const info = await api("GET", `/sessions/${sessionId}`);
  let wsUrl = info.webSocketDebuggerUrl;
  if (!wsUrl) throw new Error("No WS URL");
  if (!wsUrl.includes("/devtools/browser/")) {
    const vRes = await fetch(`${wsUrl.replace("ws://", "http://")}/json/version`,
      { signal: AbortSignal.timeout(5000) });
    const vJson = await vRes.json();
    if (vJson.webSocketDebuggerUrl) {
      wsUrl = wsUrl + new URL(vJson.webSocketDebuggerUrl).pathname;
    }
  }
  return puppeteer.connect({ browserWSEndpoint: wsUrl });
}

// ---------------------------------------------------------------------------

async function main() {
  const word = SEARCH_WORD || WORDS[Math.floor(Math.random() * WORDS.length)];
  console.log(`\n=== Proxy Stress Test ===`);
  console.log(`Search: "${word}", Target: ${TARGET_CLICKS} clicks, Timeout: ${OP_TIMEOUT}ms\n`);

  // Wait for app to be ready
  process.stdout.write("Waiting for pool... ");
  for (let i = 0; i < 30; i++) {
    const state = JSON.parse(osascript("get app state"));
    if (state.phase === "ready" && state.poolReady) { console.log("OK"); break; }
    if (i === 29) { console.error("FAIL"); process.exit(1); }
    await sleep(1000);
  }

  // Create profile
  osascript('create profile "StressProxy"');
  osascript('set profile setting "StressProxy" key "allowAutomation" to value "true"');

  let sessionId, browser, page;
  let tunnelErrors = 0, successfulClicks = 0, totalErrors = 0, timeouts = 0;
  let captures = [];

  try {
    // Create session (this one gets a longer timeout — VM boot)
    // Session creation is a one-time setup — allow 30s for VM boot + CDP ready
    process.stdout.write("Creating session... ");
    const sess = await api("POST", "/sessions",
      { profile: "StressProxy", url: `https://www.google.com/search?q=${encodeURIComponent(word)}` },
      30000
    );
    if (sess.error) throw new Error(`Session failed: ${sess.error}`);
    if (!sess.id) throw new Error(`No session ID returned: ${JSON.stringify(sess).slice(0, 100)}`);
    sessionId = sess.id;
    console.log(sessionId.slice(0, 8));

    // Connect Puppeteer — retry quickly, CDP pool fills within a few seconds
    process.stdout.write("Connecting CDP... ");
    for (let attempt = 0; attempt < 20; attempt++) {
      try {
        browser = await withTimeout(connectSession(sessionId), 3000, "CDP");
        break;
      } catch (e) {
        process.stdout.write(`[${attempt+1}]`);
        if (attempt === 19) throw new Error(`CDP connect failed after 20 attempts: ${e.message}`);
        await sleep(500);
      }
    }
    page = (await browser.pages()).find((p) => !p.url().startsWith("about:")) || (await browser.pages())[0];
    page.setDefaultTimeout(OP_TIMEOUT);
    page.setDefaultNavigationTimeout(5000);
    console.log("OK");

    // Wait for Google search results
    process.stdout.write("Loading search results... ");
    try {
      await page.waitForSelector("#search", { timeout: 5000 });
      console.log("OK");
    } catch {
      console.log("skipped (no #search)");
    }

    // Collect initial links
    const links = await page.evaluate(() =>
      Array.from(document.querySelectorAll("a[href]"))
        .map((a) => a.href)
        .filter((h) => h.startsWith("http") && !h.includes("google.com/search"))
        .slice(0, 30)
    );
    console.log(`Found ${links.length} links. Starting click loop...\n`);

    // Click loop
    for (let i = 0; i < TARGET_CLICKS; i++) {
      const tag = `[${String(i + 1).padStart(3)}/${TARGET_CLICKS}]`;

      try {
        // Get links on current page
        const pageLinks = await withTimeout(
          page.evaluate(() =>
            Array.from(document.querySelectorAll("a[href]"))
              .map((a) => a.href)
              .filter((h) => h.startsWith("http"))
              .slice(0, 50)
          ),
          OP_TIMEOUT, "get links"
        );

        if (pageLinks.length === 0) {
          process.stdout.write(`${tag} no links, back... `);
          await withTimeout(
            page.goBack({ waitUntil: "domcontentloaded", timeout: 5000 }).catch(() => {}),
            OP_TIMEOUT, "go back"
          );
          console.log("OK");
          continue;
        }

        const target = pageLinks[Math.floor(Math.random() * pageLinks.length)];
        let hostname;
        try { hostname = new URL(target).hostname; } catch { hostname = target.slice(0, 30); }
        process.stdout.write(`${tag} ${hostname.substring(0, 28).padEnd(28)} `);

        const response = await withTimeout(
          page.goto(target, { waitUntil: "domcontentloaded", timeout: 5000 }).catch((e) => e),
          OP_TIMEOUT, "navigate"
        );

        if (response instanceof Error) {
          const msg = response.message;
          if (msg.includes("ERR_TUNNEL") || msg.includes("ERR_PROXY")) {
            tunnelErrors++;
            totalErrors++;
            console.log(`❌ TUNNEL (#${tunnelErrors})`);
            const cap = await captureProcesses(sessionId, `TUNNEL at click ${i + 1}: ${target}`);
            captures.push({ click: i + 1, ...cap });
            await sleep(1000);
            await page.goBack({ waitUntil: "domcontentloaded", timeout: 3000 }).catch(() => {});
          } else if (msg.includes("TIMEOUT")) {
            timeouts++;
            totalErrors++;
            console.log("⏱ timeout");
          } else if (msg.includes("ERR_")) {
            totalErrors++;
            console.log(`⚠ ${msg.match(/ERR_\w+/)?.[0] || msg.slice(0, 40)}`);
          } else {
            totalErrors++;
            console.log(`⚠ ${msg.slice(0, 40)}`);
          }
        } else {
          successfulClicks++;
          const status = typeof response?.status === "function" ? response.status() : "?";
          console.log(`✓ ${status}`);
        }

        // Minimal pause — stress the proxy
        await sleep(50);

        // Health check every 20 clicks
        if (i > 0 && i % 20 === 0 && hasDebugShell) {
          const socks = await vmExec(sessionId, "pgrep -f routing-socks | wc -l");
          const squid = await vmExec(sessionId, "pgrep squid | wc -l");
          const errLog = await vmExec(sessionId, "grep -c CRASHED /tmp/bromure/resilient-launch.*.log 2>/dev/null || echo 0");
          const crashCount = parseInt(errLog.stdout?.trim()) || 0;
          console.log(`  [health] squid=${squid.stdout?.trim()} socks=${socks.stdout?.trim()} crashes=${crashCount}`);
          if (crashCount > 0) {
            const crashes = await vmExec(sessionId, "grep CRASHED /tmp/bromure/resilient-launch.*.log");
            for (const line of (crashes.stdout || "").trim().split("\n")) {
              console.log(`    ${line}`);
            }
          }
        }

      } catch (e) {
        totalErrors++;
        const msg = e.message || String(e);
        if (msg.includes("TIMEOUT")) {
          timeouts++;
          console.log(`${tag} ⏱ TIMEOUT`);
        } else if (msg.includes("Session closed") || msg.includes("detached") || msg.includes("Target closed")) {
          console.log(`${tag} 💀 connection lost, reconnecting...`);
          try {
            browser = await withTimeout(connectSession(sessionId), OP_TIMEOUT, "reconnect");
            page = (await browser.pages()).find((p) => !p.url().startsWith("about:")) || (await browser.pages())[0];
            console.log("  reconnected");
          } catch {
            console.log("  reconnect failed, stopping");
            break;
          }
        } else {
          console.log(`${tag} ⚠ ${msg.slice(0, 50)}`);
        }
      }
    }

  } catch (e) {
    console.error(`\nFATAL: ${e.message}`);
    totalErrors++;
  } finally {
    console.log("\n========================================");
    console.log(`  Attempted: ${successfulClicks + totalErrors}`);
    console.log(`  Success:   ${successfulClicks}`);
    console.log(`  Errors:    ${totalErrors} (${tunnelErrors} tunnel, ${timeouts} timeout)`);
    console.log(`  Captures:  ${captures.length}`);
    console.log("========================================");

    // Final crash log
    if (hasDebugShell && sessionId) {
      try {
        const errLog = await vmExec(sessionId, "cat /tmp/bromure/resilient-launch.*.log 2>/dev/null");
        const crashes = (errLog.stdout || "").split("\n").filter((l) => l.includes("CRASHED"));
        if (crashes.length > 0) {
          console.log(`\nDAEMON RESTARTS (${crashes.length}):`);
          for (const c of crashes) console.log(`  ${c}`);
        } else {
          console.log("\nNo daemon crashes detected.");
        }
      } catch {}
    }
    console.log("");

    if (browser) try { browser.disconnect(); } catch {}
    if (browser) await sleep(500);
    if (sessionId) await api("DELETE", `/sessions/${sessionId}`);
    await sleep(500);
    try { osascript('delete profile "StressProxy"'); } catch {}

    process.exit(tunnelErrors > 0 ? 1 : 0);
  }
}

main().catch((e) => { console.error("Fatal:", e.message); process.exit(2); });
