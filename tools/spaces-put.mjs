#!/usr/bin/env node
/*
 * spaces-put.mjs — upload one local file to DigitalOcean Spaces under a
 * given key, public-read. Thin, single-purpose counterpart to
 * release-upload.mjs (which also signs + registers an appcast); this one
 * just does the S3 PutObject, reusing the same env + client conventions so
 * the MLX publish pipeline matches the release pipeline.
 *
 * Env (same as release-upload.mjs):
 *   DO_SPACES_KEY, DO_SPACES_SECRET, DO_SPACES_ENDPOINT, DO_SPACES_REGION,
 *   DO_SPACES_BUCKET, DO_SPACES_PUBLIC_BASE
 *
 * Usage:
 *   node tools/spaces-put.mjs <localPath> <key> [contentType]
 *   e.g. node tools/spaces-put.mjs dist/catalog.json mlx/catalog.json application/json
 */
import { readFileSync } from "node:fs";
import { basename } from "node:path";

function env(name) {
  const v = process.env[name];
  if (!v) { console.error(`spaces-put: missing required env ${name}`); process.exit(1); }
  return v;
}

const [, , LOCAL, KEY, CONTENT_TYPE] = process.argv;
if (!LOCAL || !KEY) {
  console.error("usage: node tools/spaces-put.mjs <localPath> <key> [contentType]");
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
  return "application/octet-stream";
}

const { S3Client, PutObjectCommand } = await import("@aws-sdk/client-s3");
const client = new S3Client({
  endpoint: DO_SPACES_ENDPOINT,
  region: DO_SPACES_REGION,
  credentials: { accessKeyId: DO_SPACES_KEY, secretAccessKey: DO_SPACES_SECRET },
  forcePathStyle: false,
});

const body = readFileSync(LOCAL);
await client.send(new PutObjectCommand({
  Bucket: DO_SPACES_BUCKET,
  Key: KEY,
  Body: body,
  ContentType: CONTENT_TYPE || guessType(LOCAL),
  ACL: "public-read",
  CacheControl: KEY.endsWith("catalog.json") ? "public, max-age=300" : "public, max-age=86400",
}));

console.log(`  ↑ ${basename(LOCAL)} → ${DO_SPACES_PUBLIC_BASE}/${KEY}`);
