#!/usr/bin/env node
/*
 * spaces-delete.mjs — delete objects from the DigitalOcean Space, either a
 * single key or everything under a prefix. Companion to spaces-put.mjs;
 * used by scripts/publish-image.sh to retire the previous base image
 * (images/<old-uuid>/…) once the new img-catalog.json is live.
 *
 * Env (same as spaces-put.mjs):
 *   DO_SPACES_KEY, DO_SPACES_SECRET, DO_SPACES_ENDPOINT, DO_SPACES_REGION,
 *   DO_SPACES_BUCKET
 *
 * Usage:
 *   node tools/spaces-delete.mjs <key>              # delete one object
 *   node tools/spaces-delete.mjs --prefix <prefix>  # delete all under prefix
 *
 * Deliberately conservative: --prefix refuses anything shorter than two
 * path segments (e.g. a bare "images/" or "" would nuke far more than a
 * single retired build).
 */
function env(name) {
  const v = process.env[name];
  if (!v) { console.error(`spaces-delete: missing required env ${name}`); process.exit(1); }
  return v;
}

const args = process.argv.slice(2);
let prefixMode = false;
let target;
if (args[0] === "--prefix") {
  prefixMode = true;
  target = args[1];
} else {
  target = args[0];
}
if (!target) {
  console.error("usage: node tools/spaces-delete.mjs <key> | --prefix <prefix>");
  process.exit(2);
}
if (prefixMode) {
  const segments = target.split("/").filter(Boolean);
  if (segments.length < 2) {
    console.error(`spaces-delete: refusing over-broad prefix "${target}" (need at least two path segments, e.g. images/<uuid>/)`);
    process.exit(2);
  }
}

const DO_SPACES_KEY = env("DO_SPACES_KEY");
const DO_SPACES_SECRET = env("DO_SPACES_SECRET");
const DO_SPACES_ENDPOINT = env("DO_SPACES_ENDPOINT");
const DO_SPACES_REGION = env("DO_SPACES_REGION");
const DO_SPACES_BUCKET = env("DO_SPACES_BUCKET");

const { S3Client, ListObjectsV2Command, DeleteObjectCommand } =
  await import("@aws-sdk/client-s3");
const client = new S3Client({
  endpoint: DO_SPACES_ENDPOINT,
  region: DO_SPACES_REGION,
  credentials: { accessKeyId: DO_SPACES_KEY, secretAccessKey: DO_SPACES_SECRET },
  forcePathStyle: false,
});

async function deleteKey(key) {
  await client.send(new DeleteObjectCommand({ Bucket: DO_SPACES_BUCKET, Key: key }));
  console.log(`  ✗ deleted ${key}`);
}

if (!prefixMode) {
  await deleteKey(target);
} else {
  let token;
  let count = 0;
  do {
    const page = await client.send(new ListObjectsV2Command({
      Bucket: DO_SPACES_BUCKET,
      Prefix: target,
      ContinuationToken: token,
    }));
    for (const obj of page.Contents ?? []) {
      await deleteKey(obj.Key);
      count += 1;
    }
    token = page.IsTruncated ? page.NextContinuationToken : undefined;
  } while (token);
  console.log(`spaces-delete: ${count} object(s) removed under ${target}`);
}
