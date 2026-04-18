#!/usr/bin/env node
/**
 * release-upload.mjs — push a signed Bromure release to DigitalOcean Spaces
 * and register it with the appcast backend.
 *
 * Meant to run on the Mac build host as the final step of package.sh.
 *
 * Required env vars:
 *   SPARKLE_PRIVATE_KEY    Base64-encoded 64-byte Sparkle ed25519 private key
 *                          (Sparkle's `generate_keys --export-to-stdin` format).
 *   DO_SPACES_KEY          DigitalOcean Spaces access key.
 *   DO_SPACES_SECRET       DigitalOcean Spaces secret.
 *   DO_SPACES_ENDPOINT     Spaces endpoint, e.g. https://sfo3.digitaloceanspaces.com
 *   DO_SPACES_REGION       Region slug, e.g. sfo3
 *   DO_SPACES_BUCKET       Bucket name (the Space name).
 *   DO_SPACES_PUBLIC_BASE  Public base URL users download from, e.g.
 *                          https://bromure.sfo3.cdn.digitaloceanspaces.com
 *   RELEASE_AUTH_TOKEN     Bearer token matching the backend's RELEASE_AUTH_TOKEN.
 *
 * Optional:
 *   RELEASE_API_URL        Defaults to https://bromure.io/api/v1/release
 *
 * Usage:
 *   node tools/release-upload.mjs \
 *        --file .build/release/Bromure-2.6.0.zip \
 *        --version 2.6.0 \
 *        [--channel stable] \
 *        [--min-system-version 14.0] \
 *        [--notes-file release-notes-2.6.0.html]
 */

import { createPrivateKey, createPublicKey, sign, verify } from "node:crypto";
import { createReadStream, readFileSync, statSync } from "node:fs";
import { basename } from "node:path";
import { parseArgs } from "node:util";

// ---------------------------------------------------------------------------
// Arg parsing
// ---------------------------------------------------------------------------

const { values } = parseArgs({
  options: {
    file: { type: "string" },
    version: { type: "string" },
    channel: { type: "string", default: "stable" },
    "min-system-version": { type: "string", default: "14.0" },
    "notes-file": { type: "string" },
    "dry-run": { type: "boolean", default: false },
  },
});

function die(msg) {
  console.error(`release-upload: ${msg}`);
  process.exit(1);
}

if (!values.file) die("--file is required");
if (!values.version) die("--version is required");
if (!/^\d+\.\d+(\.\d+)?(-[A-Za-z0-9._-]+)?$/.test(values.version)) {
  die(`invalid version string: ${values.version}`);
}

const FILE = values.file;
const VERSION = values.version;
const CHANNEL = values.channel;
const MIN_SYSTEM_VERSION = values["min-system-version"];
const NOTES = values["notes-file"] ? readFileSync(values["notes-file"], "utf8") : "";
const DRY_RUN = values["dry-run"];

// ---------------------------------------------------------------------------
// Env
// ---------------------------------------------------------------------------

function env(name, required = true) {
  const v = process.env[name];
  if (required && !v) die(`missing env var: ${name}`);
  return v;
}

const SPARKLE_PRIVATE_KEY = env("SPARKLE_PRIVATE_KEY");
const DO_SPACES_KEY = env("DO_SPACES_KEY");
const DO_SPACES_SECRET = env("DO_SPACES_SECRET");
const DO_SPACES_ENDPOINT = env("DO_SPACES_ENDPOINT");
const DO_SPACES_REGION = env("DO_SPACES_REGION");
const DO_SPACES_BUCKET = env("DO_SPACES_BUCKET");
const DO_SPACES_PUBLIC_BASE = env("DO_SPACES_PUBLIC_BASE").replace(/\/+$/, "");
const RELEASE_AUTH_TOKEN = env("RELEASE_AUTH_TOKEN");
const RELEASE_API_URL = process.env.RELEASE_API_URL || "https://bromure.io/api/v1/release";

// ---------------------------------------------------------------------------
// 1. Sign the artifact with ed25519 (Sparkle format)
// ---------------------------------------------------------------------------
//
// Sparkle's `sign_update` uses libsodium ed25519 sign_detached. The private
// key stored by Sparkle is the 64-byte representation (seed ‖ pub). Node's
// crypto.sign accepts PKCS8-wrapped ed25519 keys; we wrap the 32-byte seed
// portion into the minimal PKCS8 DER envelope to avoid a native dep.

function signArtifact(path) {
  const raw = Buffer.from(SPARKLE_PRIVATE_KEY, "base64");
  if (raw.length !== 64 && raw.length !== 32) {
    die(`SPARKLE_PRIVATE_KEY must decode to 32 or 64 bytes, got ${raw.length}`);
  }
  const seed = raw.subarray(0, 32);

  // PKCS8 prefix for ed25519 private key (RFC 8410)
  // 30 2e 02 01 00 30 05 06 03 2b 65 70 04 22 04 20 <32-byte seed>
  const prefix = Buffer.from("302e020100300506032b657004220420", "hex");
  const pkcs8 = Buffer.concat([prefix, seed]);

  const key = createPrivateKey({ key: pkcs8, format: "der", type: "pkcs8" });
  const data = readFileSync(path);
  const signature = sign(null, data, key);

  // Self-check: derive the public key and verify. Guards against silent
  // key-format bugs producing signatures that Sparkle would later reject.
  const pub = createPublicKey(key);
  if (!verify(null, data, pub, signature)) {
    die("internal error: produced signature failed self-verify");
  }

  return { signature: signature.toString("base64"), length: data.length };
}

// ---------------------------------------------------------------------------
// 2. Upload to DigitalOcean Spaces
// ---------------------------------------------------------------------------

async function uploadToSpaces(path, key) {
  const { S3Client, PutObjectCommand } = await import("@aws-sdk/client-s3");

  const client = new S3Client({
    endpoint: DO_SPACES_ENDPOINT,
    region: DO_SPACES_REGION,
    credentials: {
      accessKeyId: DO_SPACES_KEY,
      secretAccessKey: DO_SPACES_SECRET,
    },
    forcePathStyle: false,
  });

  const contentLength = statSync(path).size;
  await client.send(
    new PutObjectCommand({
      Bucket: DO_SPACES_BUCKET,
      Key: key,
      Body: createReadStream(path),
      ContentType: "application/octet-stream",
      ContentLength: contentLength,
      ACL: "public-read",
      CacheControl: "public, max-age=31536000, immutable",
    }),
  );

  return `${DO_SPACES_PUBLIC_BASE}/${key}`;
}

// ---------------------------------------------------------------------------
// 3. POST metadata to the appcast backend
// ---------------------------------------------------------------------------

async function registerRelease(payload) {
  const resp = await fetch(RELEASE_API_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${RELEASE_AUTH_TOKEN}`,
    },
    body: JSON.stringify(payload),
  });
  const text = await resp.text();
  if (!resp.ok) {
    die(`backend rejected release: ${resp.status} ${text}`);
  }
  return text;
}

// ---------------------------------------------------------------------------
// Run
// ---------------------------------------------------------------------------

(async () => {
  const fileBasename = basename(FILE);
  const spacesKey = `releases/${fileBasename}`;

  console.log(`[1/3] signing ${FILE}…`);
  const { signature, length } = signArtifact(FILE);
  console.log(`      length=${length} bytes, edSignature=${signature.slice(0, 20)}…`);

  if (DRY_RUN) {
    console.log("dry run — skipping upload and registration");
    console.log(JSON.stringify({ version: VERSION, channel: CHANNEL, length, edSignature: signature }, null, 2));
    return;
  }

  console.log(`[2/3] uploading to ${DO_SPACES_BUCKET}/${spacesKey}…`);
  const url = await uploadToSpaces(FILE, spacesKey);
  console.log(`      → ${url}`);

  console.log(`[3/3] registering release with ${RELEASE_API_URL}…`);
  await registerRelease({
    version: VERSION,
    channel: CHANNEL,
    url,
    edSignature: signature,
    length,
    minSystemVersion: MIN_SYSTEM_VERSION,
    notes: NOTES,
    publishedAt: new Date().toISOString(),
  });

  console.log(`done: ${CHANNEL}/${VERSION} is live`);
})().catch((err) => {
  console.error(err.stack || err);
  process.exit(1);
});
