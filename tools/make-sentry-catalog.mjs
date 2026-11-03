#!/usr/bin/env node
/*
 * make-sentry-catalog.mjs — build (and sign) the kernel sentry module catalog
 * published at https://dl.bromure.io/sentry/<sourceHash>/catalog.json.
 *
 * One catalog per module SOURCE (sourceHash, see
 * scripts/openshell-guest/sentry/source-hash.sh): it lists every kernel that
 * source has a prebuilt module for. The app fetches the catalog for the source
 * it ships, verifies the signature, then downloads and sha256-checks the module
 * for each kernel a workspace runs. A module loads into the guest kernel as
 * root, so every byte of what it trusts is covered by the signature: kernel,
 * object path, sha256 and size.
 *
 * Signing: the SPARKLE_PRIVATE_KEY env credential, the same ed25519 key (and
 * PKCS8 wrapping) as make-img-catalog.mjs and release-upload.mjs. The payload's
 * first line is a domain separator, so a validly signed image catalog can never
 * be replayed as a module catalog. SentryModuleCatalog.signingPayload in
 * Sources/AgentCoding/SentryModuleStore.swift builds the IDENTICAL bytes;
 * change both or neither (and bump the magic).
 *
 * Usage:
 *   node tools/make-sentry-catalog.mjs --source-hash <hex> --modules <dir> \
 *        [--previous <catalog.json>] [--public-key <b64>] --out <catalog.json> \
 *        [--allow-unsigned]
 *
 *   <dir> holds bromure_sentry-<kernel>.ko (+ .txt) as build.sh writes them.
 *   --previous merges an already published catalog (its entries are kept unless
 *   <dir> rebuilt the same kernel); when it's signed, its signature is checked
 *   against --public-key first, so a tampered bucket can't smuggle entries in.
 */
import { createHash, createPrivateKey, createPublicKey, sign, verify } from "node:crypto";
import { closeSync, constants, fstatSync, lstatSync, openSync, readFileSync, readdirSync,
         unlinkSync, writeSync } from "node:fs";
import { join } from "node:path";

export const MAGIC = "bromure-sentry-modules-v1";
// Each module also carries its OWN signature (same Sparkle key), over a
// domain-separated statement, never over the raw .ko bytes: Sparkle signs raw
// update archives, so a raw-bytes signature would let a module pass for a
// "signed update". SentryModuleCatalog.moduleSigningPayload builds the same.
export const MODULE_MAGIC = "bromure-sentry-module-v1";

export function moduleSigningPayload(sourceHash, m) {
  return Buffer.from([MODULE_MAGIC, `sourceHash=${sourceHash}`, `kernel=${m.kernel}`,
                      `sha256=${m.sha256.toLowerCase()}`, `bytes=${m.bytes}`].join("\n"), "utf8");
}
const KERNEL_RE = /^[0-9][0-9A-Za-z.+~-]*$/;

// The modules dir comes out of the build container (`docker cp` keeps
// symlinks), and this runs on the machine holding the signing key: a planted
// link must never be read as a module (its target signed and published) nor
// written through (catalog/signature JSON clobbering ~/.ssh or the key file).
// Every path here is opened without following a final symlink, and the
// directory itself must be a real one.
const die = (msg) => { console.error(`make-sentry-catalog: ${msg}`); process.exit(1); };
function lexists(path) {
  try { lstatSync(path); return true; } catch (e) { if (e.code === "ENOENT") return false; throw e; }
}
export function requireRealDir(dir) {
  const st = lstatSync(dir);
  if (st.isSymbolicLink() || !st.isDirectory()) die(`${dir} must be a directory, not a symlink`);
}
export function readNoFollow(path) {
  let fd;
  try { fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW); }
  catch (e) { if (e.code === "ELOOP") die(`${path} is a symlink — refusing it`); throw e; }
  try {
    if (!fstatSync(fd).isFile()) die(`${path} isn't a regular file`);
    return readFileSync(fd);
  } finally { closeSync(fd); }
}
export function writeNoFollow(path, text) {
  // Replace the entry itself (never what a link there points at), then
  // create a fresh file that can't already exist or be a link.
  if (lexists(path)) {
    if (lstatSync(path).isDirectory()) die(`${path} is a directory`);
    unlinkSync(path);
  }
  const fd = openSync(path, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o644);
  try { writeSync(fd, text); } finally { closeSync(fd); }
}

const args = process.argv.slice(2);
function opt(name) {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : undefined;
}
function req(name) {
  const v = opt(name);
  if (!v) { console.error(`make-sentry-catalog: --${name} is required`); process.exit(2); }
  return v;
}

export function signingPayload(cat, signedAt) {
  const lines = [
    MAGIC,
    `signedAt=${signedAt}`,
    `formatVersion=${cat.formatVersion}`,
    `sourceHash=${cat.sourceHash}`,
  ];
  for (const m of [...cat.modules].sort((a, b) => (a.kernel < b.kernel ? -1 : a.kernel > b.kernel ? 1 : 0))) {
    lines.push(`module.${m.kernel}.path=${m.path}`);
    lines.push(`module.${m.kernel}.sha256=${m.sha256.toLowerCase()}`);
    lines.push(`module.${m.kernel}.bytes=${m.bytes}`);
  }
  return Buffer.from(lines.join("\n"), "utf8");
}

function publicKeyFromRaw(b64) {
  // RFC 8410 SPKI envelope around the raw 32-byte ed25519 public key.
  const raw = Buffer.from(b64, "base64");
  if (raw.length !== 32) throw new Error(`public key must be 32 bytes, got ${raw.length}`);
  return createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), raw]),
                           format: "der", type: "spki" });
}

function headersOf(txtPath) {
  if (!lexists(txtPath)) return undefined;
  const line = readNoFollow(txtPath).toString("utf8").split("\n").find((l) => l.startsWith("headers:"));
  return line ? line.slice("headers:".length).trim() : undefined;
}

// --verify <catalog.json>: check an already signed catalog instead of building
// one — its signature, every module's own signature, and each module file in
// --modules against the sha256/size the catalog vouches for. Lets the catalog
// be signed on one machine (the one holding the key) and uploaded from another.
const verifyPath = opt("verify");
if (verifyPath) {
  const pub = publicKeyFromRaw(req("public-key"));
  const dir = req("modules");
  requireRealDir(dir);
  // Exit 3 = a signature doesn't verify against the pinned key (the key is
  // wrong); 1 = anything else (a module, a .sig or the catalog itself), so a
  // caller can tell a wrong key from a bad build.
  const WRONG_KEY = 3;
  const fail = (msg, code = 1) => { console.error(`make-sentry-catalog: ${msg}`); process.exit(code); };
  let cat;
  try { cat = JSON.parse(readNoFollow(verifyPath).toString("utf8")); }
  catch (e) { fail(`can't read ${verifyPath}: ${e.message}`); }
  if (cat.sourceHash !== req("source-hash").toLowerCase()) fail(`catalog is for ${cat.sourceHash}`);
  if (!cat.signature) fail("catalog is unsigned");
  if (!verify(null, signingPayload(cat, cat.signature.signedAt), pub, Buffer.from(cat.signature.edSignature, "base64")))
    fail("catalog signature does NOT verify against the pinned key", WRONG_KEY);
  for (const m of cat.modules) {
    if (!m.signature || !verify(null, moduleSigningPayload(cat.sourceHash, m), pub, Buffer.from(m.signature, "base64")))
      fail(`module ${m.kernel}: signature does NOT verify against the pinned key`, WRONG_KEY);
    const file = join(dir, `bromure_sentry-${m.kernel}.ko`);
    if (!lexists(file)) continue;   // published earlier, not rebuilt here
    const body = readNoFollow(file);
    if (body.length !== m.bytes || createHash("sha256").update(body).digest("hex") !== m.sha256.toLowerCase())
      fail(`module ${m.kernel}: ${file} doesn't match the catalog`);
    const sig = lexists(`${file}.sig`) && JSON.parse(readNoFollow(`${file}.sig`).toString("utf8"));
    if (!sig || sig.edSignature !== m.signature) fail(`module ${m.kernel}: ${file}.sig is missing or differs`);
  }
  console.log(`make-sentry-catalog: ${verifyPath} verifies (${cat.modules.length} kernel(s), signed ${cat.signature.signedAt})`);
  process.exit(0);
}

const sourceHash = req("source-hash").toLowerCase();
if (!/^[0-9a-f]{64}$/.test(sourceHash)) { console.error("make-sentry-catalog: bad --source-hash"); process.exit(2); }
const modulesDir = req("modules");
requireRealDir(modulesDir);
const out = req("out");
const prefix = `sentry/${sourceHash}/`;

const byKernel = new Map();

const previousPath = opt("previous");
// The previous catalog's own signature verified: its entries' kernel, path,
// sha256 and size are vouched for by the release key.
let previousVerified = false;
if (previousPath && lexists(previousPath)) {
  const prev = JSON.parse(readNoFollow(previousPath).toString("utf8"));
  if (prev.sourceHash !== sourceHash) {
    console.error(`make-sentry-catalog: previous catalog is for ${prev.sourceHash}, not ${sourceHash}`);
    process.exit(1);
  }
  if (prev.signature) {
    const pub = opt("public-key");
    if (!pub) { console.error("make-sentry-catalog: --public-key is required to merge a signed catalog"); process.exit(2); }
    const ok = verify(null, signingPayload(prev, prev.signature.signedAt), publicKeyFromRaw(pub),
                      Buffer.from(prev.signature.edSignature, "base64"));
    if (!ok) { console.error("make-sentry-catalog: the published catalog's signature does NOT verify — refusing to merge"); process.exit(1); }
    previousVerified = true;
  }
  for (const m of prev.modules ?? []) byKernel.set(m.kernel, m);
  console.log(`make-sentry-catalog: kept ${byKernel.size} published module(s)`);
}

const unsigned = args.includes("--allow-unsigned");
let key = null;
if (!unsigned) {
  const secret = process.env.SPARKLE_PRIVATE_KEY;
  if (!secret) { console.error("make-sentry-catalog: SPARKLE_PRIVATE_KEY env is required (or --allow-unsigned)"); process.exit(1); }
  const raw = Buffer.from(secret, "base64");
  if (raw.length !== 64 && raw.length !== 32) {
    console.error(`make-sentry-catalog: SPARKLE_PRIVATE_KEY must decode to 32 or 64 bytes, got ${raw.length}`);
    process.exit(1);
  }
  key = createPrivateKey({
    key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), raw.subarray(0, 32)]),
    format: "der", type: "pkcs8",
  });
}

// Kept entries must carry a valid module signature too (a merged catalog
// vouches for nothing it can't re-verify). The catalog signature doesn't
// cover them, so a bucket write can strip them: a kept entry whose own
// signature is gone is re-signed when the previous catalog's signature
// vouches for its statement (ed25519 is deterministic: the same signature
// as before, matching the published .ko.sig). A kernel rebuilt in this run
// is replaced below, so its old entry isn't checked at all.
const pubForModules = opt("public-key");
const rebuilt = new Set(readdirSync(modulesDir)
  .map((n) => /^bromure_sentry-(.+)\.ko$/.exec(n)?.[1]).filter(Boolean));
let resigned = 0;
if (!unsigned && pubForModules) {
  for (const m of byKernel.values()) {
    if (rebuilt.has(m.kernel)) continue;
    const ok = m.signature && verify(null, moduleSigningPayload(sourceHash, m), publicKeyFromRaw(pubForModules),
                                     Buffer.from(m.signature, "base64"));
    if (ok) continue;
    if (!previousVerified) {
      console.error(`make-sentry-catalog: kept module ${m.kernel} has no valid signature and no signed catalog vouches for it — refusing to merge`);
      process.exit(1);
    }
    m.signature = sign(null, moduleSigningPayload(sourceHash, m), key).toString("base64");
    resigned++;
  }
  if (resigned) console.log(`make-sentry-catalog: re-signed ${resigned} kept module statement(s) the bucket had lost`);
}

let added = 0;
for (const name of readdirSync(modulesDir).sort()) {
  const match = /^bromure_sentry-(.+)\.ko$/.exec(name);
  if (!match) continue;
  const kernel = match[1];
  if (!KERNEL_RE.test(kernel)) { console.error(`make-sentry-catalog: refusing odd kernel name ${kernel}`); process.exit(1); }
  const file = join(modulesDir, name);
  const body = readNoFollow(file);   // a regular file, not a link to one
  const bytes = body.length;
  const sha256 = createHash("sha256").update(body).digest("hex");
  const entry = {
    kernel,
    path: `${prefix}${kernel}/bromure_sentry-${kernel}-${sha256.slice(0, 12)}.ko`,
    sha256, bytes,
    headers: headersOf(join(modulesDir, `bromure_sentry-${kernel}.txt`)),
    builtAt: new Date().toISOString(),
  };
  if (key) {
    const payload = moduleSigningPayload(sourceHash, entry);
    const sig = sign(null, payload, key);
    if (!verify(null, payload, createPublicKey(key), sig)) {
      console.error("make-sentry-catalog: internal error — module signature failed self-verify"); process.exit(1);
    }
    entry.signature = sig.toString("base64");
    // Detached copy, published beside the module (<path>.sig), so a module
    // can be checked on its own.
    writeNoFollow(`${file}.sig`, JSON.stringify({
      format: MODULE_MAGIC, sourceHash, kernel, sha256, bytes, edSignature: entry.signature,
    }, null, 2) + "\n");
  }
  byKernel.set(kernel, entry);
  added++;
}

const catalog = {
  formatVersion: 1,
  sourceHash,
  modules: [...byKernel.values()].sort((a, b) => (a.kernel < b.kernel ? -1 : 1)),
};

if (unsigned) {
  console.log("make-sentry-catalog: --allow-unsigned — NOT signed (tests only; the app rejects unsigned production catalogs)");
} else {
  const signedAt = new Date().toISOString();
  const payload = signingPayload(catalog, signedAt);
  const signature = sign(null, payload, key);
  if (!verify(null, payload, createPublicKey(key), signature)) {
    console.error("make-sentry-catalog: internal error — signature failed self-verify");
    process.exit(1);
  }
  catalog.signature = { signedAt, edSignature: signature.toString("base64") };
}

writeNoFollow(out, JSON.stringify(catalog, null, 2) + "\n");
console.log(`make-sentry-catalog: wrote ${out} (${catalog.modules.length} kernel(s), ${added} new)`);
