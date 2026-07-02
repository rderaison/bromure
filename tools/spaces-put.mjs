#!/usr/bin/env node
/*
 * spaces-put.mjs — upload one local file to DigitalOcean Spaces under a
 * given key, public-read. Thin, single-purpose counterpart to
 * release-upload.mjs (which also signs + registers an appcast); this one
 * just does the S3 upload, reusing the same env + client conventions so
 * the MLX + base-image publish pipelines match the release pipeline.
 *
 * Uses @aws-sdk/lib-storage's multipart Upload rather than a single
 * PutObject: the base-image pipeline pushes multi-GB files, which blow
 * past both Node's Buffer ceiling (readFileSync) and S3's 5 GB
 * single-PUT limit. Small files still go up in one part.
 *
 * Env (same as release-upload.mjs):
 *   DO_SPACES_KEY, DO_SPACES_SECRET, DO_SPACES_ENDPOINT, DO_SPACES_REGION,
 *   DO_SPACES_BUCKET, DO_SPACES_PUBLIC_BASE
 *
 * Usage:
 *   node tools/spaces-put.mjs <localPath> <key> [contentType] [cacheControl]
 *   e.g. node tools/spaces-put.mjs dist/catalog.json mlx/catalog.json application/json
 *        node tools/spaces-put.mjs img-catalog.json images/img-catalog.json \
 *             application/json "public, max-age=1, must-revalidate"
 */
import { createReadStream, statSync } from "node:fs";
import { basename } from "node:path";

function env(name) {
  const v = process.env[name];
  if (!v) { console.error(`spaces-put: missing required env ${name}`); process.exit(1); }
  return v;
}

const [, , LOCAL, KEY, CONTENT_TYPE, CACHE_CONTROL] = process.argv;
if (!LOCAL || !KEY) {
  console.error("usage: node tools/spaces-put.mjs <localPath> <key> [contentType] [cacheControl]");
  process.exit(2);
}

const DO_SPACES_KEY = env("DO_SPACES_KEY");
const DO_SPACES_SECRET = env("DO_SPACES_SECRET");
const DO_SPACES_ENDPOINT = env("DO_SPACES_ENDPOINT");
const DO_SPACES_REGION = env("DO_SPACES_REGION");
const DO_SPACES_BUCKET = env("DO_SPACES_BUCKET");
const DO_SPACES_PUBLIC_BASE = env("DO_SPACES_PUBLIC_BASE").replace(/\/+$/, "");

// Minimal content-type guess for the few file kinds we publish.
function guessType(path) {
  if (path.endsWith(".json")) return "application/json";
  if (path.endsWith(".html")) return "text/html; charset=utf-8";
  if (path.endsWith(".whl")) return "application/zip";
  if (path.endsWith(".txt")) return "text/plain; charset=utf-8";
  if (path.endsWith(".gz")) return "application/gzip";
  return "application/octet-stream";
}

// Cache policy by object kind. Small mutable manifests/pointers (catalog.json,
// the find-links index) are republished in place, so they get a short TTL —
// otherwise a catalog edit takes the CDN's full TTL to surface. Versioned
// binary artifacts (the engine wheel, base-image .gz files under their
// per-build uuid prefix, and the DMGs uploaded by release-upload.mjs) are
// immutable per filename, so they stay long-cached. The optional
// [cacheControl] argument overrides this table (img-catalog.json is
// published with a 1s TTL so a weekly image publish is visible immediately).
function cacheControlFor(key) {
  if (/\.(whl|zip|pkg|dmg|tar\.gz|tgz|gz|bin|img)$/i.test(key)) {
    return "public, max-age=86400";          // immutable artifacts — cache hard
  }
  return "public, max-age=60, must-revalidate"; // small mutable manifests
}

const { S3Client } = await import("@aws-sdk/client-s3");
const { Upload } = await import("@aws-sdk/lib-storage");
const client = new S3Client({
  endpoint: DO_SPACES_ENDPOINT,
  region: DO_SPACES_REGION,
  credentials: { accessKeyId: DO_SPACES_KEY, secretAccessKey: DO_SPACES_SECRET },
  forcePathStyle: false,
});

const totalBytes = statSync(LOCAL).size;
const upload = new Upload({
  client,
  params: {
    Bucket: DO_SPACES_BUCKET,
    Key: KEY,
    Body: createReadStream(LOCAL),
    ContentType: CONTENT_TYPE || guessType(LOCAL),
    ACL: "public-read",
    CacheControl: CACHE_CONTROL || cacheControlFor(KEY),
  },
  partSize: 64 * 1024 * 1024,
  queueSize: 4,
});

// Progress ticks for the multi-GB image uploads; quiet for small files.
if (totalBytes > 256 * 1024 * 1024) {
  let lastPct = -10;
  upload.on("httpUploadProgress", (p) => {
    const pct = Math.floor(((p.loaded ?? 0) * 100) / totalBytes);
    if (pct >= lastPct + 10) {
      lastPct = pct;
      console.log(`  … ${basename(LOCAL)} ${pct}%`);
    }
  });
}

await upload.done();

console.log(`  ↑ ${basename(LOCAL)} → ${DO_SPACES_PUBLIC_BASE}/${KEY}`);
