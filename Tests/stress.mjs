#!/usr/bin/env node
/**
 * Bromure Stress Tests
 *
 * Long-running tests: memory leak detection, rapid session cycling, etc.
 * Separated from e2e.mjs because these take minutes and aren't needed on
 * every change.
 *
 * Prerequisites: same as e2e.mjs (Bromure running, automation enabled).
 *
 * Usage:
 *   node tests/stress.mjs
 */

import { execSync } from "child_process";

const API = process.env.BROMURE_API_URL || "http://127.0.0.1:9222";

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
  if (!text) return { error: `Empty response (${res.status})` };
  try { return JSON.parse(text); } catch { return { error: text.slice(0, 200) }; }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function getMemoryMB() {
  try {
    const out = execSync(
      "ps -eo rss,comm | grep '[b]romure$' | sort -rn | head -1 | awk '{print $1}'",
      { encoding: "utf-8", timeout: 5000 }
    ).trim();
    return out ? parseInt(out) / 1024 : null;
  } catch { return null; }
}

async function waitForPool(timeoutMs = 60000) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    try {
      const state = JSON.parse(osascript("get app state"));
      if (state.poolReady) return;
    } catch {}
    await sleep(1000);
  }
  throw new Error("Pool not ready");
}

let passed = 0, failed = 0;

async function test(name, fn) {
  const t0 = Date.now();
  try {
    await fn();
    passed++;
    console.log(`  \x1b[32mPASS\x1b[0m  ${name} (${Date.now() - t0}ms)`);
  } catch (e) {
    failed++;
    console.log(`  \x1b[31mFAIL\x1b[0m  ${name} (${Date.now() - t0}ms)`);
    console.log(`        ${e.message}`);
  }
}

function assert(cond, msg) { if (!cond) throw new Error(msg || "Assertion failed"); }

// ---------------------------------------------------------------------------

async function main() {
  console.log("\n=== Bromure Stress Tests ===\n");

  const state = JSON.parse(osascript("get app state"));
  assert(state.phase === "ready", `App not ready: ${state.phase}`);
  osascript('set app setting "automation.enabled" to value "true"');

  // Clean up stale sessions/profiles
  const existing = await api("GET", "/sessions");
  for (const s of existing.sessions || []) await api("DELETE", `/sessions/${s.id}`);
  const stale = JSON.parse(osascript("list profiles")).filter((p) => p.name.startsWith("E2E_") || p.name.startsWith("Stress_"));
  for (const p of stale) { try { osascript(`delete profile "${p.id}"`); } catch {} }
  await waitForPool();

  // ======================================================================
  // Memory Leak Detection
  // ======================================================================
  console.log("--- Memory Leak Detection ---");

  const CYCLES = 5;
  const baselineMB = getMemoryMB();
  console.log(`  Baseline: ${baselineMB?.toFixed(0)} MB`);

  for (let i = 0; i < CYCLES; i++) {
    await waitForPool();
    const pname = `Stress_Leak_${i}`;
    osascript(`create profile "${pname}"`);
    osascript(`set profile setting "${pname}" key "allowAutomation" to value "true"`);
    const sess = await api("POST", "/sessions", { profile: pname });
    if (sess.error) {
      console.log(`  Cycle ${i}: session failed: ${sess.error}`);
      try { osascript(`delete profile "${pname}"`); } catch {}
      continue;
    }
    await sleep(5000);
    await api("DELETE", `/sessions/${sess.id}`);
    await sleep(1000);
    try { osascript(`delete profile "${pname}"`); } catch {}

    const mb = getMemoryMB();
    console.log(`  Cycle ${i + 1}/${CYCLES}: ${mb?.toFixed(0)} MB (+${((mb || 0) - (baselineMB || 0)).toFixed(0)} MB)`);
  }

  await sleep(3000);
  const finalMB = getMemoryMB();

  await test("Memory stable after session create/destroy cycles", async () => {
    assert(baselineMB !== null && finalMB !== null, "Could not measure memory");
    const growth = finalMB - baselineMB;
    console.log(`        Baseline: ${baselineMB.toFixed(0)} MB -> Final: ${finalMB.toFixed(0)} MB (growth: ${growth.toFixed(0)} MB over ${CYCLES} cycles)`);
    const maxGrowthMB = CYCLES * 15;
    assert(growth < maxGrowthMB, `Memory grew ${growth.toFixed(0)} MB (limit: ${maxGrowthMB} MB). Possible leak.`);
  });

  // Memory report
  console.log(`\n  Per-test memory tracking from e2e suite is available via: node tests/e2e.mjs`);
  console.log(`  (per-test deltas are shown inline as [+N MB])\n`);

  // ======================================================================
  console.log("========================================");
  console.log(`  ${passed} passed, ${failed} failed`);
  console.log("========================================\n");
  process.exit(failed > 0 ? 1 : 0);
}

main().catch((e) => { console.error("Fatal:", e); process.exit(2); });
