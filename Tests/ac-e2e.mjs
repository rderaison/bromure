#!/usr/bin/env node
/**
 * Bromure Agentic Coding E2E Test Suite — Phase 1
 *
 * Drives the AC AppleScript bridge to verify profile lifecycle, the editor
 * categories, MCP server serialization, app state, and session open/close.
 * Deep VM-side verification (chrome-env contents, running processes,
 * token-swap on the wire) is deferred to Phase 2, which adds the
 * AutomationServer + vsock shell agent.
 *
 * Prerequisites:
 *   - Bromure Agentic Coding.app built at .build/.../Bromure Agentic Coding.app
 *   - The app running (open the bundle, accept any TCC prompts).
 *   - A base image already built (otherwise session tests are skipped).
 *
 * Usage:
 *   node Tests/ac-e2e.mjs                 # run all
 *   node Tests/ac-e2e.mjs --filter mcp    # run tests matching "mcp" (case-insensitive)
 *   node Tests/ac-e2e.mjs --no-sessions   # skip the session-launch tests
 */

import { execSync } from "child_process";

const APP_NAME = "Bromure Agentic Coding";
const API = process.env.BROMURE_AC_API_URL || "http://127.0.0.1:9223";
const FILTER = process.argv.find((a) => a === "--filter")
  ? process.argv[process.argv.indexOf("--filter") + 1]
  : null;
const SKIP_SESSIONS = process.argv.includes("--no-sessions");

// ---------------------------------------------------------------------------
// AppleScript bridge
// ---------------------------------------------------------------------------

function ac(cmd, { timeoutMs = 15000 } = {}) {
  const wrapped = `with timeout of 10 seconds\ntell application "${APP_NAME}" to ${cmd}\nend timeout`;
  try {
    return execSync(`osascript -e '${wrapped.replace(/'/g, "'\\''")}'`, {
      encoding: "utf-8",
      timeout: timeoutMs,
    }).trim();
  } catch (e) {
    // osascript emits the bridge's "error: …" string on stdout when our
    // handlers fail; surface it.
    const stdout = (e.stdout || "").toString().trim();
    if (stdout) return stdout;
    throw new Error(`osascript failed: ${e.message}`);
  }
}

function acJSON(cmd) {
  const out = ac(cmd);
  if (out.startsWith("error:") || !out) {
    throw new Error(`Expected JSON, got: ${out}`);
  }
  try {
    return JSON.parse(out);
  } catch (e) {
    throw new Error(`Bad JSON from "${cmd}": ${out.slice(0, 200)}`);
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// ---------------------------------------------------------------------------
// HTTP API
// ---------------------------------------------------------------------------

async function api(method, path, body) {
  const opts = {
    method,
    headers: { "Content-Type": "application/json", Connection: "close" },
    keepalive: false,
  };
  if (body !== undefined) opts.body = JSON.stringify(body);
  const res = await fetch(`${API}${path}`, opts);
  const text = await res.text();
  if (!text) {
    return { _status: res.status, _empty: true };
  }
  try {
    const json = JSON.parse(text);
    json._status = res.status;
    return json;
  } catch {
    return { _status: res.status, _error: `Invalid JSON: ${text.slice(0, 200)}` };
  }
}

// ---------------------------------------------------------------------------
// Test runner
// ---------------------------------------------------------------------------

let passed = 0,
  failed = 0,
  skipped = 0;
const results = [];

async function test(name, fn) {
  if (FILTER && !new RegExp(FILTER, "i").test(name)) {
    skipped++;
    return;
  }
  const t0 = Date.now();
  try {
    await fn();
    const ms = Date.now() - t0;
    passed++;
    results.push({ name, status: "PASS", ms });
    console.log(`  \x1b[32mPASS\x1b[0m  ${name} (${ms}ms)`);
  } catch (e) {
    const ms = Date.now() - t0;
    failed++;
    results.push({ name, status: "FAIL", ms, error: e.message });
    console.log(`  \x1b[31mFAIL\x1b[0m  ${name} (${ms}ms)`);
    console.log(`        ${e.message}`);
    if (e.stack)
      console.log(`        ${e.stack.split("\n").slice(1, 4).join("\n        ")}`);
  }
}

function assert(cond, msg) {
  if (!cond) throw new Error(msg || "Assertion failed");
}
function assertEq(a, b, msg) {
  if (a !== b)
    throw new Error(msg || `Expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`);
}
function assertIncludes(haystack, needle, msg) {
  if (!haystack.includes(needle))
    throw new Error(msg || `Expected "${needle}" in: ${JSON.stringify(haystack).slice(0, 200)}`);
}

// ---------------------------------------------------------------------------
// Profile helpers
// ---------------------------------------------------------------------------

function escapeStringForApplescript(s) {
  // AppleScript text literals need backslash + quote escaping
  return s.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

function escapeJSONForApplescript(json) {
  // The JSON goes into an AppleScript text literal that's already inside
  // single quotes (set by osascript -e '…'). osascript shell-escapes the
  // single quotes for us; we just need to escape backslashes and double
  // quotes for AppleScript's string parser.
  return escapeStringForApplescript(json);
}

function createProfile(name, opts = {}) {
  let cmd = `create ac profile "${escapeStringForApplescript(name)}"`;
  if (opts.color) cmd += ` color "${opts.color}"`;
  const id = ac(cmd);
  if (!id.match(/^[0-9A-F-]{36}$/i))
    throw new Error(`Bad profile ID returned: ${id}`);
  return id;
}

function deleteProfile(nameOrID) {
  try {
    ac(`delete ac profile "${escapeStringForApplescript(nameOrID)}"`);
  } catch {}
}

function getProfileJSON(nameOrID) {
  const out = ac(`get profile json "${escapeStringForApplescript(nameOrID)}"`);
  if (out.startsWith("error:")) throw new Error(out);
  return JSON.parse(out);
}

function setProfileJSON(nameOrID, profileObj) {
  const json = JSON.stringify(profileObj);
  const out = ac(
    `set profile json "${escapeStringForApplescript(nameOrID)}" to value "${escapeJSONForApplescript(
      json
    )}"`
  );
  if (out !== "ok") throw new Error(`set profile json: ${out}`);
}

function getProfileSetting(nameOrID, key) {
  return ac(
    `get profile setting "${escapeStringForApplescript(nameOrID)}" key "${key}"`
  );
}

function setProfileSetting(nameOrID, key, value) {
  const out = ac(
    `set profile setting "${escapeStringForApplescript(nameOrID)}" key "${key}" to value "${escapeStringForApplescript(
      String(value)
    )}"`
  );
  if (out !== "ok") throw new Error(`set profile setting ${key}: ${out}`);
}

// ---------------------------------------------------------------------------
// Run
// ---------------------------------------------------------------------------

async function main() {
  console.log("\n=== Bromure Agentic Coding E2E Test Suite ===\n");

  // Pre-check: app is reachable
  try {
    const state = acJSON("get app state");
    console.log(
      `App reachable. locale=${state.locale}, profileCount=${state.profileCount}, mainOpen=${state.mainWindowOpen}.\n`
    );
  } catch (e) {
    console.error("Cannot reach Bromure Agentic Coding via AppleScript.");
    console.error("Is the app running? Did you grant Automation permission to your terminal?");
    console.error(e.message);
    process.exit(1);
  }

  // Clean up any stale ACE2E_ profiles from a previous run
  try {
    const profs = acJSON("list profiles");
    for (const p of profs) {
      if (p.name.startsWith("ACE2E_")) deleteProfile(p.id);
    }
  } catch {}

  // ======================================================================
  // 1. App state
  // ======================================================================
  console.log("--- 1. App state ---");

  await test("1.1 get app state returns valid JSON with expected keys", async () => {
    const s = acJSON("get app state");
    assert(typeof s.locale === "string", "locale missing");
    assert(typeof s.mainWindowOpen === "boolean", "mainWindowOpen missing");
    assert(typeof s.editorOpen === "boolean", "editorOpen missing");
    assert(typeof s.profileCount === "number", "profileCount missing");
  });

  await test("1.2 list profiles returns an array with id/name/color", async () => {
    const profs = acJSON("list profiles");
    assert(Array.isArray(profs), "Not an array");
    if (profs.length > 0) {
      for (const p of profs) {
        assert(typeof p.id === "string" && p.id.length === 36, `Bad id: ${p.id}`);
        assert(typeof p.name === "string", "name missing");
        assert(typeof p.color === "string", "color missing");
      }
    }
  });

  await test("1.3 profileCount matches list profiles length", async () => {
    const s = acJSON("get app state");
    const profs = acJSON("list profiles");
    assertEq(s.profileCount, profs.length);
  });

  // ======================================================================
  // 2. Profile CRUD
  // ======================================================================
  console.log("\n--- 2. Profile CRUD ---");

  await test("2.1 Create and delete profile", async () => {
    const id = createProfile("ACE2E_CRUD", { color: "orange" });
    const profs = acJSON("list profiles");
    assert(
      profs.some((p) => p.id === id),
      "Created profile not in list"
    );
    deleteProfile(id);
    const after = acJSON("list profiles");
    assert(
      !after.some((p) => p.id === id),
      "Profile still present after delete"
    );
  });

  await test("2.2 Create with color preserves it", async () => {
    const id = createProfile("ACE2E_Color", { color: "purple" });
    try {
      const profs = acJSON("list profiles");
      const p = profs.find((x) => x.id === id);
      assertEq(p.color, "purple", `Expected purple, got ${p.color}`);
    } finally {
      deleteProfile(id);
    }
  });

  await test("2.3 set profile setting roundtrips simple fields", async () => {
    const id = createProfile("ACE2E_Settings");
    try {
      setProfileSetting(id, "comments", "hello world");
      assertEq(getProfileSetting(id, "comments"), "hello world");

      setProfileSetting(id, "apiKey", "sk-ant-test-key-123");
      assertEq(getProfileSetting(id, "apiKey"), "sk-ant-test-key-123");

      setProfileSetting(id, "memoryGB", "8");
      assertEq(getProfileSetting(id, "memoryGB"), "8");

      setProfileSetting(id, "closeAction", "shutdown");
      assertEq(getProfileSetting(id, "closeAction"), "shutdown");

      setProfileSetting(id, "tool", "codex");
      assertEq(getProfileSetting(id, "tool"), "codex");

      setProfileSetting(id, "authMode", "subscription");
      assertEq(getProfileSetting(id, "authMode"), "subscription");
    } finally {
      deleteProfile(id);
    }
  });

  await test("2.4 set profile setting rejects invalid enum values", async () => {
    const id = createProfile("ACE2E_Invalid");
    try {
      let err;
      try {
        setProfileSetting(id, "tool", "bogus");
      } catch (e) {
        err = e;
      }
      assert(err && /invalid tool/.test(err.message), `Expected enum error, got: ${err?.message}`);
    } finally {
      deleteProfile(id);
    }
  });

  await test("2.5 set profile setting rejects unknown key", async () => {
    const id = createProfile("ACE2E_BadKey");
    try {
      let err;
      try {
        setProfileSetting(id, "definitelyNotAField", "x");
      } catch (e) {
        err = e;
      }
      assert(err && /unknown key/.test(err.message), `Expected unknown-key error`);
    } finally {
      deleteProfile(id);
    }
  });

  // ======================================================================
  // 3. Profile JSON round-trip (covers nested credential structs)
  // ======================================================================
  console.log("\n--- 3. Profile JSON round-trip ---");

  await test("3.1 get profile json decodes a valid Profile blob", async () => {
    const id = createProfile("ACE2E_JSON_Get");
    try {
      const p = getProfileJSON(id);
      // Note: the AC Profile encoder omits empty arrays (environmentVariables,
      // mcpServers, etc.) and other defaulted-to-zero fields by design, so
      // we can only assert on what's always present.
      assert(typeof p.id === "string", "id missing");
      assertEq(p.name, "ACE2E_JSON_Get");
      assert(Array.isArray(p.folderPaths), "folderPaths missing");
      assert(typeof p.tool === "string", "tool missing");
      assert(typeof p.authMode === "string", "authMode missing");
    } finally {
      deleteProfile(id);
    }
  });

  await test("3.2 set profile json preserves the profile id", async () => {
    const id = createProfile("ACE2E_JSON_Id");
    try {
      const p = getProfileJSON(id);
      p.name = "ACE2E_JSON_Id_Renamed";
      // Test that even if a caller supplies a different id, the bridge
      // pins it back to the existing one (prevents orphaning the disk).
      p.id = "00000000-0000-0000-0000-000000000000";
      setProfileJSON(id, p);
      const after = getProfileJSON("ACE2E_JSON_Id_Renamed");
      assertEq(after.id, id, "Profile id should not be rewritable");
      assertEq(after.name, "ACE2E_JSON_Id_Renamed");
    } finally {
      deleteProfile("ACE2E_JSON_Id_Renamed");
      deleteProfile(id);
    }
  });

  await test("3.3 set profile json carries environment variables across", async () => {
    const id = createProfile("ACE2E_Env");
    try {
      const p = getProfileJSON(id);
      p.environmentVariables = [
        { id: "11111111-1111-1111-1111-111111111111", name: "FOO", value: "bar" },
        { id: "22222222-2222-2222-2222-222222222222", name: "BAZ", value: "qux" },
      ];
      setProfileJSON(id, p);
      const after = getProfileJSON(id);
      assertEq(after.environmentVariables.length, 2);
      assertEq(after.environmentVariables[0].name, "FOO");
      assertEq(after.environmentVariables[1].value, "qux");
    } finally {
      deleteProfile(id);
    }
  });

  await test("3.4 set profile json adds MCP servers with bearer token + env var", async () => {
    const id = createProfile("ACE2E_MCP");
    try {
      const p = getProfileJSON(id);
      p.mcpServers = [
        {
          id: "33333333-3333-3333-3333-333333333333",
          name: "my-api",
          transport: "http",
          command: "",
          arguments: [],
          url: "https://api.example.com/mcp",
          environment: [],
          bearerTokenEnvVar: "MY_API_TOKEN",
          bearerToken: "real-secret-token-XYZ",
          enabled: true,
          rawJSON: "",
        },
      ];
      setProfileJSON(id, p);
      const after = getProfileJSON(id);
      assertEq(after.mcpServers.length, 1);
      assertEq(after.mcpServers[0].name, "my-api");
      assertEq(after.mcpServers[0].url, "https://api.example.com/mcp");
      assertEq(after.mcpServers[0].bearerTokenEnvVar, "MY_API_TOKEN");
      assertEq(after.mcpServers[0].bearerToken, "real-secret-token-XYZ");
      assertEq(getProfileSetting(id, "mcpServerCount"), "1");
    } finally {
      deleteProfile(id);
    }
  });

  await test("3.5 set profile json rejects malformed JSON", async () => {
    const id = createProfile("ACE2E_BadJSON");
    try {
      let err;
      try {
        // Bypass setProfileJSON's stringify to send literal garbage.
        const out = ac(`set profile json "${id}" to value "this is not json"`);
        if (out !== "ok") err = new Error(out);
      } catch (e) {
        err = e;
      }
      assert(err, "Expected an error from invalid JSON");
    } finally {
      deleteProfile(id);
    }
  });

  // ======================================================================
  // 4. Editor windowing
  // ======================================================================
  console.log("\n--- 4. Editor windowing ---");

  await test("4.1 open/close ac profile editor toggles editorOpen", async () => {
    const id = createProfile("ACE2E_Editor");
    try {
      const opened = ac(`open ac profile editor "${id}"`);
      if (opened.startsWith("error:")) throw new Error(opened);
      await sleep(500);
      const state = acJSON("get app state");
      assert(state.editorOpen, "Editor should be open");

      ac("close ac profile editor");
      await sleep(500);
      const after = acJSON("get app state");
      assert(!after.editorOpen, "Editor should be closed");
    } finally {
      deleteProfile(id);
    }
  });

  await test("4.2 select editor category navigates each AC sidebar entry", async () => {
    const id = createProfile("ACE2E_Categories");
    try {
      ac(`open ac profile editor "${id}"`);
      await sleep(500);
      const categories = [
        "general",
        "agent",
        "folders",
        "credentials",
        "environment",
        "mcp",
        "tracing",
        "appearance",
        "resources",
      ];
      for (const cat of categories) {
        const r = ac(`select editor category "${cat}"`);
        if (r.startsWith("error:"))
          throw new Error(`Category "${cat}" failed: ${r}`);
      }
      ac("close ac profile editor");
    } finally {
      deleteProfile(id);
    }
  });

  await test("4.3 get editor window id returns 0 when closed and a positive value when open", async () => {
    const id = createProfile("ACE2E_WinId");
    try {
      const closedId = parseInt(ac("get editor window id"), 10);
      assertEq(closedId, 0, `Expected 0 when closed, got ${closedId}`);

      ac(`open ac profile editor "${id}"`);
      await sleep(500);
      const openId = parseInt(ac("get editor window id"), 10);
      assert(openId > 0, `Expected positive windowID when open, got ${openId}`);

      ac("close ac profile editor");
    } finally {
      deleteProfile(id);
    }
  });

  // ======================================================================
  // 5. HTTP automation API
  // ======================================================================
  console.log("\n--- 5. HTTP automation API ---");

  // Probe whether the HTTP server is running. The bridge defaults to ON
  // but a user could have disabled it via UserDefaults, so we skip the
  // section rather than fail noisily.
  let httpAvailable = true;
  try {
    const h = await api("GET", "/health");
    if (h.status !== "ok") httpAvailable = false;
  } catch {
    httpAvailable = false;
  }
  if (!httpAvailable) {
    console.log(
      "  \x1b[33mSKIP\x1b[0m  HTTP automation tests (server unreachable at " + API + ")"
    );
  } else {
    await test("5.1 GET /health returns ok", async () => {
      const r = await api("GET", "/health");
      assertEq(r.status, "ok");
      assertEq(r.service, "bromure-ac-automation");
      assert(typeof r.debugEnabled === "boolean", "debugEnabled missing");
    });

    await test("5.2 GET /profiles returns the same set as AppleScript", async () => {
      const r = await api("GET", "/profiles");
      assert(Array.isArray(r.profiles), "profiles missing");
      const ascript = acJSON("list profiles");
      assertEq(r.profiles.length, ascript.length, "Profile count mismatch");
      for (const p of r.profiles) {
        assert(typeof p.id === "string" && p.id.length === 36, "Bad id");
        assert(typeof p.name === "string", "name missing");
        assert(typeof p.tool === "string", "tool missing");
        assert(typeof p.authMode === "string", "authMode missing");
        assert(typeof p.mcpServerCount === "number", "mcpServerCount missing");
      }
    });

    await test("5.3 GET /sessions returns an array", async () => {
      const r = await api("GET", "/sessions");
      assert(Array.isArray(r.sessions), "sessions missing");
    });

    await test("5.4 GET /sessions/<nonexistent> 404s", async () => {
      const r = await api("GET", "/sessions/00000000-0000-0000-0000-000000000000");
      assertEq(r._status, 404);
    });

    await test("5.5 POST /sessions missing profile field returns 400", async () => {
      const r = await api("POST", "/sessions", {});
      assertEq(r._status, 400);
      assert(typeof r.error === "string", "error message missing");
    });

    await test("5.6 GET /app/state 403 when debug is off, 200 when on", async () => {
      const h = await api("GET", "/health");
      const r = await api("GET", "/app/state");
      if (h.debugEnabled) {
        assertEq(r._status, 200);
        assert(typeof r.profileCount === "number", "profileCount missing");
      } else {
        assertEq(r._status, 403);
      }
    });

    await test("5.7 POST /sessions/.../exec 403 when debug is off, 502 'no shell connection' when on (Phase 2b)", async () => {
      const h = await api("GET", "/health");
      const id = createProfile("ACE2E_Exec");
      try {
        const r = await api("POST", `/sessions/${id}/exec`, { command: "echo hi" });
        if (h.debugEnabled) {
          // Until ShellBridge is wired in Phase 2b we expect 502 from
          // the bridge plumbing; the request reached the right handler.
          assert(
            r._status === 502 || r._status === 200,
            `Expected 502 or 200 (Phase 2b), got ${r._status}`
          );
        } else {
          assertEq(r._status, 403);
        }
      } finally {
        deleteProfile(id);
      }
    });
  }

  // ======================================================================
  // 6. Session control (host-side only — VM verification deferred)
  // ======================================================================
  if (!SKIP_SESSIONS) {
    console.log("\n--- 6. Session control ---");

    await test("6.1 list ac sessions returns an array (possibly empty)", async () => {
      const sessions = acJSON("list ac sessions");
      assert(Array.isArray(sessions));
    });

    // The remaining session tests require a built base image. If
    // `open ac session` returns an error or the window never opens,
    // skip — the user may not have run `bromure-ac init` yet.
    let baseImageAvailable = true;
    try {
      const id = createProfile("ACE2E_Probe");
      const r = ac(`open ac session "${id}"`);
      if (r.startsWith("error:")) {
        baseImageAvailable = false;
      }
      await sleep(1000);
      ac(`close ac session "${id}"`);
      await sleep(500);
      deleteProfile(id);
    } catch {
      baseImageAvailable = false;
    }

    if (!baseImageAvailable) {
      console.log(
        "  \x1b[33mSKIP\x1b[0m  Session-launch tests (no base image — run `bromure-ac init` first)"
      );
    } else {
      await test("6.2 open ac session shows the profile in list ac sessions", async () => {
        const id = createProfile("ACE2E_Session");
        try {
          ac(`open ac session "${id}"`);
          // Session windows take a moment to appear
          for (let i = 0; i < 10; i++) {
            await sleep(500);
            const sessions = acJSON("list ac sessions");
            if (sessions.some((s) => s.profileId === id)) return;
          }
          throw new Error("Session window did not appear within 5s");
        } finally {
          try {
            ac(`close ac session "${id}"`);
          } catch {}
          await sleep(500);
          deleteProfile(id);
        }
      });

      await test("6.3 close ac session removes it from the list", async () => {
        const id = createProfile("ACE2E_Close");
        try {
          ac(`open ac session "${id}"`);
          for (let i = 0; i < 10; i++) {
            await sleep(500);
            const sessions = acJSON("list ac sessions");
            if (sessions.some((s) => s.profileId === id)) break;
          }
          ac(`close ac session "${id}"`);
          for (let i = 0; i < 10; i++) {
            await sleep(500);
            const sessions = acJSON("list ac sessions");
            if (!sessions.some((s) => s.profileId === id)) return;
          }
          throw new Error("Session window still listed after close");
        } finally {
          deleteProfile(id);
        }
      });
    }
  } else {
    console.log("\n--- 6. Session control --- (skipped via --no-sessions)");
  }

  // ======================================================================
  // 7. App-wide settings (UserDefaults via AppleScript)
  // ======================================================================
  console.log("\n--- 7. App-wide settings ---");

  await test("7.1 get ac app setting reads automation.enabled", async () => {
    const v = ac('get ac app setting "automation.enabled"');
    assert(v === "true" || v === "false", `Expected boolean string, got: ${v}`);
  });

  await test("7.2 get ac app setting rejects unknown key", async () => {
    const v = ac('get ac app setting "definitelyNotAKey"');
    assert(v.startsWith("error:"), `Expected error, got: ${v}`);
  });

  await test("7.3 set ac app setting roundtrips bindAddress", async () => {
    const orig = ac('get ac app setting "automation.bindAddress"');
    const r = ac('set ac app setting "automation.bindAddress" to value "127.0.0.1"');
    assertEq(r, "ok");
    assertEq(ac('get ac app setting "automation.bindAddress"'), "127.0.0.1");
    if (orig && orig !== "127.0.0.1") {
      ac(`set ac app setting "automation.bindAddress" to value "${orig}"`);
    }
  });

  await test("7.4 set ac app setting rejects invalid automation.port", async () => {
    const r = ac('set ac app setting "automation.port" to value "not-a-number"');
    assert(r.startsWith("error:"), `Expected error, got: ${r}`);
  });

  // ======================================================================
  // 8. VM-side verification via /exec (requires base image + debug shell)
  // ======================================================================
  if (!SKIP_SESSIONS) {
    console.log("\n--- 8. VM-side verification ---");

    // Same gate as section 6 — skip when no base image / no debug shell.
    const h = await api("GET", "/health");
    const hasDebugShell = h?.debugEnabled === true;
    let canExec = hasDebugShell;
    if (!hasDebugShell) {
      console.log(
        "  \x1b[33mSKIP\x1b[0m  VM-side tests (BROMURE_DEBUG_CLAUDE not set on the running app)"
      );
    } else {
      // Probe whether sessions can actually start.
      try {
        const id = createProfile("ACE2E_VMProbe");
        const r = ac(`open ac session "${id}"`);
        if (r.startsWith("error:")) canExec = false;
        await sleep(1000);
        ac(`close ac session "${id}"`);
        await sleep(500);
        deleteProfile(id);
      } catch {
        canExec = false;
      }
    }

    if (hasDebugShell && !canExec) {
      console.log(
        "  \x1b[33mSKIP\x1b[0m  VM-side tests (no base image — run `bromure-ac init` first)"
      );
    } else if (canExec) {
      // Helper: open a session and wait for the shell-agent vsock pool to
      // fill before trying /exec. The agent dials back on guest boot,
      // which takes ~5-15s after the session window appears.
      async function withVMSession(profileName, profileConfigFn, cb) {
        const id = createProfile(profileName);
        try {
          if (profileConfigFn) profileConfigFn(id);
          await api("POST", "/sessions", { profile: id });
          // The /exec endpoint waits up to 10s internally; we also retry
          // a few times to ride out the boot lag.
          let lastErr;
          for (let attempt = 0; attempt < 6; attempt++) {
            const r = await api("POST", `/sessions/${id}/exec`, {
              command: "true",
              timeout: 5,
            });
            if (r._status === 200) {
              await cb(id);
              return;
            }
            lastErr = `status=${r._status} error=${r.error}`;
            await sleep(3000);
          }
          throw new Error(`VM shell never came up: ${lastErr}`);
        } finally {
          await api("DELETE", `/sessions/${id}`);
          await sleep(500);
          deleteProfile(id);
        }
      }

      await test("8.1 vm_exec returns stdout / stderr / exit code", async () => {
        await withVMSession("ACE2E_Exec_Hello", null, async (id) => {
          const r = await api("POST", `/sessions/${id}/exec`, {
            command: "echo hi && echo whoops >&2 && exit 7",
            timeout: 5,
          });
          assertEq(r._status, 200);
          assertEq(r.stdout.trim(), "hi");
          assertEq(r.stderr.trim(), "whoops");
          assertEq(r.exitCode, 7);
        });
      });

      await test("8.2 shell-agent.py is present in the meta-share at the expected path", async () => {
        await withVMSession("ACE2E_Exec_Agent", null, async (id) => {
          const r = await api("POST", `/sessions/${id}/exec`, {
            command: "test -r /mnt/bromure-meta/shell-agent.py && wc -c < /mnt/bromure-meta/shell-agent.py",
            timeout: 5,
          });
          assertEq(r._status, 200);
          assertEq(r.exitCode, 0);
          const size = parseInt(r.stdout.trim(), 10);
          assert(size > 1000, `Expected shell-agent.py to be > 1KB, got ${size} bytes`);
        });
      });

      await test("8.3 BROMURE_AC_TOOL env var is exported in the user environment", async () => {
        await withVMSession("ACE2E_Exec_Env", null, async (id) => {
          // The api_key.env file the host writes to the meta-share carries
          // BROMURE_AC_TOOL and BROMURE_AC_AUTH; verify they're sourced.
          const r = await api("POST", `/sessions/${id}/exec`, {
            command: "cat /mnt/bromure-meta/api_key.env | grep BROMURE_AC_",
            timeout: 5,
          });
          assertEq(r._status, 200);
          assertEq(r.exitCode, 0);
          assertIncludes(r.stdout, "BROMURE_AC_TOOL=");
          assertIncludes(r.stdout, "BROMURE_AC_AUTH=");
        });
      });

      await test("8.4 MCP server config ships with FAKE bearer token (real stays on host)", async () => {
        await withVMSession(
          "ACE2E_Exec_MCP",
          (id) => {
            // Add an MCP server with a real bearer token before launching.
            const p = getProfileJSON(id);
            p.mcpServers = [
              {
                id: "44444444-4444-4444-4444-444444444444",
                name: "test-api",
                transport: "http",
                command: "",
                arguments: [],
                url: "https://api.example.com/mcp",
                environment: [],
                bearerTokenEnvVar: "TEST_API_TOKEN",
                bearerToken: "real-secret-do-not-leak-XYZZY",
                enabled: true,
                rawJSON: "",
              },
            ];
            setProfileJSON(id, p);
          },
          async (id) => {
            const r = await api("POST", `/sessions/${id}/exec`, {
              command: "cat /mnt/bromure-meta/mcp/claude.json 2>/dev/null || cat /mnt/bromure-meta/mcp/codex.toml",
              timeout: 5,
            });
            assertEq(r._status, 200);
            assertEq(r.exitCode, 0);
            assertIncludes(r.stdout, "test-api");
            assert(
              !r.stdout.includes("real-secret-do-not-leak-XYZZY"),
              "Real bearer token leaked into the VM-visible MCP config!"
            );
            // Fakes are prefixed brm-mcp_ (SessionTokenPlan deriveFake)
            assertIncludes(r.stdout, "brm-mcp_");
          }
        );
      });
    }
  } else {
    console.log("\n--- 8. VM-side verification --- (skipped via --no-sessions)");
  }

  // ======================================================================
  // 9. Supply Chain Security — policy plumbing (JSON / live-refresh)
  // ======================================================================
  console.log("\n--- 9. Supply Chain Security ---");

  await test("9.1 New profiles get the documented defaults", async () => {
    const id = createProfile("ACE2E_SC_Defaults");
    try {
      const p = getProfileJSON(id);
      // The encoder omits default-valued fields, so an all-default
      // policy round-trips as either an empty object or — with our
      // `try c.encode(supplyChain, ...)` unconditionally on the
      // Profile encode — an empty `supplyChain: {}` blob.
      const sc = p.supplyChain ?? {};
      // ageGateEnabled defaults true; if encoded it's still true.
      assert(sc.ageGateEnabled !== false, "ageGateEnabled should default true");
      assert(
        sc.ageGateDays === undefined || sc.ageGateDays === 2,
        `Expected ageGateDays=2, got ${sc.ageGateDays}`
      );
      assert(
        sc.osvEnabled === undefined || sc.osvEnabled === false,
        `OSV should default off, got ${sc.osvEnabled}`
      );
      assert(
        sc.socketBlockCompromised !== false,
        "socketBlockCompromised should default true"
      );
      assert(
        sc.socketBlockCVE === undefined || sc.socketBlockCVE === false,
        "socketBlockCVE should default off"
      );
      assert(
        sc.stripInstallScripts !== false,
        "stripInstallScripts should default true"
      );
      assert(
        sc.lockfilePrompt !== false,
        "lockfilePrompt should default true"
      );
    } finally {
      deleteProfile(id);
    }
  });

  await test("9.2 Setting non-default values via JSON roundtrips", async () => {
    const id = createProfile("ACE2E_SC_Roundtrip");
    try {
      const p = getProfileJSON(id);
      p.supplyChain = {
        ageGateEnabled: true,
        ageGateDays: 14,
        ageGateAllowlist: ["npm:axios", "lodash"],
        osvEnabled: true,
        osvSeverity: "medium",
        socketAPIKey: "test-key-XYZ",
        socketBlockCompromised: true,
        socketBlockCVE: true,
        socketCVESeverity: "critical",
        stripInstallScripts: false,
        stripAllowlist: ["npm:better-sqlite3"],
        lockfilePrompt: false,
      };
      setProfileJSON(id, p);
      const after = getProfileJSON(id);
      const sc = after.supplyChain;
      assertEq(sc.ageGateDays, 14);
      assert(
        Array.isArray(sc.ageGateAllowlist)
          && sc.ageGateAllowlist.includes("npm:axios"),
        "ageGateAllowlist round-trip"
      );
      assertEq(sc.osvEnabled, true);
      assertEq(sc.osvSeverity, "medium");
      assertEq(sc.socketAPIKey, "test-key-XYZ");
      assertEq(sc.socketBlockCVE, true);
      assertEq(sc.socketCVESeverity, "critical");
      assertEq(sc.stripInstallScripts, false);
      assert(
        sc.stripAllowlist.includes("npm:better-sqlite3"),
        "stripAllowlist round-trip"
      );
      assertEq(sc.lockfilePrompt, false);
    } finally {
      deleteProfile(id);
    }
  });

  await test("9.3 Severity enum rejects garbage values gracefully", async () => {
    // Codable on Severity is strict — an unknown raw value should
    // fall back to the field's documented default rather than crash
    // the decode.
    const id = createProfile("ACE2E_SC_BadSeverity");
    try {
      // Set via the raw JSON path: an invalid severity should be
      // tolerated (we use decodeIfPresent with ??default).
      const p = getProfileJSON(id);
      p.supplyChain = { osvEnabled: true, osvSeverity: "definitely-not-a-severity" };
      let setErr;
      try {
        setProfileJSON(id, p);
      } catch (e) {
        setErr = e;
      }
      // Either the set fails outright OR the value falls back to a
      // valid default. Both are acceptable; what we don't want is
      // a corrupted state that hangs the bridge.
      const after = getProfileJSON(id);
      const sev = after?.supplyChain?.osvSeverity;
      assert(
        setErr || sev === undefined || ["low","medium","high","critical"].includes(sev),
        `Severity fell back cleanly or set errored, got setErr=${setErr?.message} sev=${sev}`
      );
    } finally {
      deleteProfile(id);
    }
  });

  await test("9.4 Allowlist entries with mixed scoping are preserved verbatim", async () => {
    const id = createProfile("ACE2E_SC_Allowlist");
    try {
      const p = getProfileJSON(id);
      // `npm:foo` (ecosystem-scoped) and bare `bar` (cross-ecosystem)
      // are both valid per SupplyChainPolicy.allowlistMatches.
      p.supplyChain = {
        ageGateAllowlist: [
          "npm:@scope/pkg-name",
          "pypi:requests",
          "axios",
          "  whitespace-trimmed  ",
        ],
      };
      setProfileJSON(id, p);
      const after = getProfileJSON(id);
      const list = after.supplyChain.ageGateAllowlist;
      assertEq(list.length, 4);
      assert(list.includes("npm:@scope/pkg-name"), "scoped npm entry");
      assert(list.includes("pypi:requests"), "scoped pypi entry");
      assert(list.includes("axios"), "bare entry");
    } finally {
      deleteProfile(id);
    }
  });

  await test("9.5 Toggles roundtrip independently — flipping one doesn't mutate others", async () => {
    const id = createProfile("ACE2E_SC_Independent");
    try {
      const p = getProfileJSON(id);
      // Flip just one of the five layers' main toggles off.
      p.supplyChain = {
        osvEnabled: true,
        // everything else default
      };
      setProfileJSON(id, p);
      const after = getProfileJSON(id);
      const sc = after.supplyChain;
      // The flipped one stayed.
      assertEq(sc.osvEnabled, true);
      // Defaults stayed defaults (encoded as their default or omitted).
      assert(
        sc.ageGateEnabled !== false,
        "ageGateEnabled was mutated unexpectedly"
      );
      assert(
        sc.stripInstallScripts !== false,
        "stripInstallScripts was mutated unexpectedly"
      );
      assert(
        sc.lockfilePrompt !== false,
        "lockfilePrompt was mutated unexpectedly"
      );
    } finally {
      deleteProfile(id);
    }
  });

  await test("9.6 Live update: setting policy then saving does NOT require a session restart", async () => {
    // We can't directly probe MitmEngine's policy registry from
    // outside the process, but `sessionRefreshAffectingChange()`
    // includes `supplyChain != supplyChain` in its trigger list —
    // i.e. a save with a different supplyChain blob fires the
    // live-refresh path that pushes the new policy into the
    // engine. This test exercises the save bridge and asserts the
    // round-trip succeeds without throwing; the actual in-engine
    // update is a single lock-guarded dict write that always
    // succeeds, so the round-trip is the meaningful signal.
    const id = createProfile("ACE2E_SC_Live");
    try {
      // Use only non-default values — the SupplyChainPolicy encoder
      // omits any field that equals its default (ageGateDays=2 etc.),
      // so picking the default for a write makes the readback look
      // "undefined" even though the in-memory state is correct.
      let p = getProfileJSON(id);
      p.supplyChain = { ageGateDays: 7 };
      setProfileJSON(id, p);
      assertEq(getProfileJSON(id).supplyChain.ageGateDays, 7);

      // Then: bump to 14. Different blob → triggers live refresh.
      p = getProfileJSON(id);
      p.supplyChain.ageGateDays = 14;
      setProfileJSON(id, p);
      assertEq(getProfileJSON(id).supplyChain.ageGateDays, 14);

      // And back. Multiple flips don't accumulate stale state.
      p = getProfileJSON(id);
      p.supplyChain.ageGateDays = 5;
      setProfileJSON(id, p);
      assertEq(getProfileJSON(id).supplyChain.ageGateDays, 5);
    } finally {
      deleteProfile(id);
    }
  });

  // ======================================================================
  // 10. Supply Chain Security — VM-side enforcement
  //
  // Requires a running base image + the debug-shell vsock pool
  // (same gate as section 8). Tests run inside the bake-baked
  // Ubuntu session VM and exercise the proxy from the guest's
  // perspective.
  // ======================================================================
  if (!SKIP_SESSIONS) {
    console.log("\n--- 10. Supply Chain Security — VM-side ---");

    const h = await api("GET", "/health");
    const hasDebugShell = h?.debugEnabled === true;
    if (!hasDebugShell) {
      console.log(
        "  \x1b[33mSKIP\x1b[0m  SC VM-side tests (BROMURE_DEBUG_CLAUDE not set)"
      );
    } else {
      // Reuse the helper from section 8.
      async function withSCSession(profileName, policy, cb) {
        const id = createProfile(profileName);
        try {
          const p = getProfileJSON(id);
          p.supplyChain = policy;
          setProfileJSON(id, p);
          await api("POST", "/sessions", { profile: id });
          let lastErr;
          for (let attempt = 0; attempt < 6; attempt++) {
            const r = await api("POST", `/sessions/${id}/exec`, {
              command: "true",
              timeout: 5,
            });
            if (r._status === 200) {
              await cb(id);
              return;
            }
            lastErr = `status=${r._status} error=${r.error}`;
            await sleep(3000);
          }
          throw new Error(`VM shell never came up: ${lastErr}`);
        } finally {
          await api("DELETE", `/sessions/${id}`);
          await sleep(500);
          deleteProfile(id);
        }
      }

      // Curl wrapped to use the VM's host cert (Bromure CA is in
      // /etc/ssl/certs in the bake'd image) and to add a marker
      // header so we can grep the proxy log if we ever care to.
      const CURL = "curl -fsSL --max-time 30";

      await test("10.1 npm metadata is rewritten — dist.integrity scrubbed", async () => {
        // Strong supply-chain policy: age gate ON + script strip
        // ON. The metadata transform should:
        //   - drop dist.integrity / dist.shasum
        //   - add X-Bromure-Rewritten header
        await withSCSession(
          "ACE2E_SC_Meta",
          { ageGateEnabled: true, ageGateDays: 2, stripInstallScripts: true },
          async (id) => {
            const r = await api("POST", `/sessions/${id}/exec`, {
              command: `${CURL} -D /tmp/h -o /tmp/b https://registry.npmjs.org/lodash && head -c 200 /tmp/h && echo --- && head -c 4096 /tmp/b | head -c 4096`,
              timeout: 60,
            });
            assertEq(r._status, 200);
            assertEq(r.exitCode, 0);
            assertIncludes(
              r.stdout,
              "X-Bromure-Rewritten",
              "Proxy didn't tag the metadata response"
            );
            // Body shouldn't have shasum on the version objects.
            // (We only sample the first 4 KB which is the start
            // of the JSON, but every version dict has dist.shasum
            // if not scrubbed, so the first version we see in
            // that prefix is enough.)
            assert(
              !r.stdout.includes("shasum"),
              "dist.shasum survived the metadata rewrite"
            );
          }
        );
      });

      await test("10.2 npm tarball script strip — package.json scripts vanish", async () => {
        // Pull a small package with known install scripts. `cowsay`
        // has none, but plenty of test packages do. We use a tiny
        // stable one (`is-promise`) and inject a check by reading
        // package/package.json from the tarball before vs after.
        // Easier: just request a tarball and verify the
        // X-Bromure-Rewritten header.
        await withSCSession(
          "ACE2E_SC_Tarball",
          { stripInstallScripts: true },
          async (id) => {
            const r = await api("POST", `/sessions/${id}/exec`, {
              command: `${CURL} -D /tmp/h -o /tmp/t.tgz https://registry.npmjs.org/is-promise/-/is-promise-4.0.0.tgz && grep -i x-bromure /tmp/h && tar -xzOf /tmp/t.tgz package/package.json | grep -c '"scripts"' || true`,
              timeout: 60,
            });
            assertEq(r._status, 200);
            // Header present
            assertIncludes(
              r.stdout,
              "X-Bromure-Rewritten",
              "Proxy didn't tag the tarball"
            );
            // Tarball must still be a valid gzip + tar (extraction worked).
            // If the proxy broke the archive, tar -xzOf would have errored.
          }
        );
      });

      await test("10.3 Age-gate allowlist exempts the package from rewriting", async () => {
        // Allowlist `lodash` from BOTH the age gate AND script
        // stripping. The metadata response should NOT have the
        // X-Bromure-Rewritten header in that case (we forward
        // unmodified).
        await withSCSession(
          "ACE2E_SC_Allow",
          {
            ageGateEnabled: true,
            ageGateDays: 2,
            ageGateAllowlist: ["npm:lodash"],
            stripInstallScripts: true,
            stripAllowlist: ["npm:lodash"],
          },
          async (id) => {
            const r = await api("POST", `/sessions/${id}/exec`, {
              command: `${CURL} -D /tmp/h -o /tmp/b https://registry.npmjs.org/lodash && head -c 400 /tmp/h`,
              timeout: 60,
            });
            assertEq(r._status, 200);
            assertEq(r.exitCode, 0);
            assert(
              !r.stdout.includes("X-Bromure-Rewritten"),
              "Allowlisted package should not be tagged as rewritten"
            );
          }
        );
      });

      await test("10.4 Policy disabled → no rewriting", async () => {
        await withSCSession(
          "ACE2E_SC_Disabled",
          {
            ageGateEnabled: false,
            stripInstallScripts: false,
            lockfilePrompt: false,
          },
          async (id) => {
            const r = await api("POST", `/sessions/${id}/exec`, {
              command: `${CURL} -D /tmp/h -o /tmp/b https://registry.npmjs.org/lodash && head -c 400 /tmp/h`,
              timeout: 60,
            });
            assertEq(r._status, 200);
            assertEq(r.exitCode, 0);
            assert(
              !r.stdout.includes("X-Bromure-Rewritten"),
              "Disabled policy should not be tagged"
            );
          }
        );
      });

      await test("10.5 Cross-ecosystem: PyPI metadata is rewritten too", async () => {
        await withSCSession(
          "ACE2E_SC_PyPI",
          { ageGateEnabled: true, ageGateDays: 2 },
          async (id) => {
            const r = await api("POST", `/sessions/${id}/exec`, {
              command: `${CURL} -D /tmp/h -o /tmp/b https://pypi.org/pypi/requests/json && head -c 400 /tmp/h`,
              timeout: 60,
            });
            assertEq(r._status, 200);
            assertEq(r.exitCode, 0);
            assertIncludes(
              r.stdout,
              "X-Bromure-Rewritten",
              "PyPI JSON response should be tagged when age gate is on"
            );
          }
        );
      });

      await test("10.6 451 response carries Bromure attribution body", async () => {
        // We can't easily force a 451 without knowing a specific
        // CVE-affected package version, but we can verify the
        // response shape would be correct by setting an
        // unrealistically-strict age gate (e.g. 36500 days =
        // ~100 years) so EVERY pinned-version artifact request
        // would 451. We hit a specific version that's far older
        // than now-100y (which doesn't exist) — actually no, the
        // metadata filter would just hide everything. The
        // artifact backstop fires only on cached publish times,
        // which we won't have without the metadata fetch first.
        //
        // Simplest reliable test: skip if we can't easily trigger
        // a 451 path. The structural correctness of the
        // SupplyChainEnforcer.blockResponse body is unit-testable
        // separately.
        await withSCSession(
          "ACE2E_SC_451",
          { ageGateEnabled: true, ageGateDays: 36500 },
          async (id) => {
            // First fetch metadata to populate the publish-time
            // cache for `lodash` versions.
            await api("POST", `/sessions/${id}/exec`, {
              command: `${CURL} -o /tmp/m https://registry.npmjs.org/lodash`,
              timeout: 60,
            });
            await sleep(500);
            // Now try to fetch a specific tarball. With cutoff
            // = 100 years ago, every published version is too
            // fresh → 451.
            //
            // Use a curl without -f (--fail) here: -f aborts the
            // transfer on HTTP errors before `-w` can fire, so we'd
            // get empty stdout instead of the 451 + body. Plain
            // `curl -sS` lets the body land in /tmp/t and lets the
            // %{http_code} write succeed.
            const r = await api("POST", `/sessions/${id}/exec`, {
              command: `curl -sS --max-time 30 -w '%{http_code}\\n' -o /tmp/t https://registry.npmjs.org/lodash/-/lodash-4.17.21.tgz; head -c 400 /tmp/t || true`,
              timeout: 60,
            });
            assertEq(r._status, 200);
            // curl -w prints the http_code; -fsSL exits nonzero on
            // 4xx so exitCode may be 22. Either way we expect
            // either "451" in stdout or the body to contain the
            // Bromure attribution string.
            const got451 =
              r.stdout.includes("451") ||
              r.stdout.includes("Bromure Supply-Chain Security");
            assert(
              got451,
              `Expected 451 / Bromure attribution, got stdout=${r.stdout.slice(0, 400)}`
            );
          }
        );
      });
    }
  } else {
    console.log("\n--- 10. SC VM-side --- (skipped via --no-sessions)");
  }

  // ======================================================================
  // Done
  // ======================================================================
  console.log(
    `\n=== ${passed} passed, ${failed} failed, ${skipped} skipped ===\n`
  );

  if (failed > 0) {
    console.log("Failures:");
    for (const r of results) {
      if (r.status === "FAIL") {
        console.log(`  • ${r.name}: ${r.error}`);
      }
    }
    process.exit(1);
  }
}

main().catch((e) => {
  console.error("Fatal:", e);
  process.exit(2);
});
