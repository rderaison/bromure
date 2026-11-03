// Finding: any page can forge credential-bridge requests and read saved
// passwords. The background worker must pin every request to the origin
// Chrome reports for its sender, whatever the request claims.
//
// Run: node --test Tests/credential-bridge-origin.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const src = readFileSync(new URL(
  "../Sources/SandboxEngine/Resources/vm-setup/extensions/credential-bridge/background.js",
  import.meta.url), "utf8");

/** background.js with a stub chrome; returns send(payload, sender) → { posted, response }. */
function load() {
  let listener = null;
  const posted = [];
  const chrome = {
    runtime: {
      id: "bromure-ext",
      lastError: null,
      connectNative: () => ({
        onMessage: { addListener() {} },
        onDisconnect: { addListener() {} },
        postMessage: (m) => posted.push(m),
      }),
      onMessage: { addListener: (f) => { listener = f; } },
    },
  };
  vm.runInNewContext(src, { chrome, console, setTimeout, URL });
  return (payload, sender) => {
    let response = null;
    const before = posted.length;
    listener({ type: "credential-request", payload: JSON.stringify(payload) }, sender, (r) => { response = r; });
    return { posted: posted.slice(before), response };
  };
}

const tab = (url) => ({ id: "bromure-ext", tab: { id: 1, url }, url, origin: new URL(url).origin });

test("a page's password request names its own site, whatever it wrote", () => {
  const send = load();
  const r = send({ requestId: "1", type: "password_get", origin: "https://accounts.google.com",
                   domain: "accounts.google.com" }, tab("https://evil.example/login"));
  assert.equal(r.posted.length, 1);
  assert.equal(r.posted[0].domain, "evil.example");
  assert.equal(r.posted[0].origin, "https://evil.example");
  const fill = send({ requestId: "2", type: "password_fill", domain: "bank.example", username: "me" },
                    tab("https://evil.example/"));
  assert.equal(fill.posted[0].domain, "evil.example");
});

test("a passkey for another site's RP ID is refused; the page's own (or a parent) goes through", () => {
  const send = load();
  for (const type of ["passkey_get", "passkey_create"]) {
    const forged = type === "passkey_get"
      ? { requestId: "3", type, rpId: "google.com", origin: "https://accounts.google.com" }
      : { requestId: "3", type, rp: { id: "google.com" }, origin: "https://accounts.google.com" };
    const r = send(forged, tab("https://evil.example/"));
    assert.equal(r.posted.length, 0, type);
    assert.equal(r.response.error, "origin_mismatch");
  }
  const ok = send({ requestId: "4", type: "passkey_get", rpId: "example.com", origin: "https://x" },
                  tab("https://login.example.com/"));
  assert.equal(ok.posted.length, 1);
  assert.equal(ok.posted[0].origin, "https://login.example.com");
  // A bare TLD is no parent domain.
  assert.equal(send({ requestId: "5", type: "passkey_get", rpId: "com" }, tab("https://example.com/")).posted.length, 0);
});

test("no request from a non-https page, another extension, or outside a tab; unknown types refused", () => {
  const send = load();
  const p = { requestId: "6", type: "password_get", domain: "a.example" };
  assert.equal(send(p, tab("http://a.example/")).posted.length, 0);
  assert.equal(send(p, { ...tab("https://a.example/"), id: "other-ext" }).posted.length, 0);
  assert.equal(send(p, { id: "bromure-ext", url: "https://a.example/" }).posted.length, 0);
  assert.equal(send({ ...p, type: "password_dump" }, tab("https://a.example/")).posted.length, 0);
  assert.equal(send(p, tab("http://localhost:8080/")).posted[0].domain, "localhost");
});
