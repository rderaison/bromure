#!/usr/bin/env node
/*
 * make-img-catalog.mjs — assemble the published img-catalog.json for the
 * base-image publish pipeline (scripts/publish-image.sh).
 *
 * The postinstall step list comes VERBATIM from the bundled baseline
 * (Sources/AgentCoding/Resources/img-catalog.json) — that file is the
 * canonical source, same convention as the MLX catalog, so the shipped
 * app and the published manifest can never drift. Step uuids therefore
 * stay stable across weekly publishes, which is what lets clients tell
 * "already applied" from "new step" (the consent prompt).
 *
 * Generate mode:
 *   node tools/make-img-catalog.mjs \
 *     --baseline Sources/AgentCoding/Resources/img-catalog.json \
 *     --build-info <dir>/build-info.json \
 *     --uuid <new-image-uuid> \
 *     --disk-key images/<uuid>/base.img.gz \
 *     --sha256 <hex> \
 *     --compressed-bytes N \
 *     --uncompressed-bytes N \
 *     --out <path>
 *
 * Inspect mode (used to find the previous build to delete):
 *   node tools/make-img-catalog.mjs --print-image-uuid <prev-catalog.json>
 *     → prints the image uuid, or nothing when absent/unparseable.
 */
import { readFileSync, writeFileSync } from "node:fs";

const args = process.argv.slice(2);

function opt(name) {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : undefined;
}
function req(name) {
  const v = opt(name);
  if (!v) { console.error(`make-img-catalog: missing --${name}`); process.exit(2); }
  return v;
}

// --- Inspect mode -------------------------------------------------------
const printUUIDPath = opt("print-image-uuid");
if (printUUIDPath) {
  try {
    const prev = JSON.parse(readFileSync(printUUIDPath, "utf8"));
    if (prev?.image?.uuid) process.stdout.write(prev.image.uuid);
  } catch {
    // No previous catalog / unparseable — print nothing; the caller
    // treats an empty result as "nothing to delete".
  }
  process.exit(0);
}

// --- Generate mode ------------------------------------------------------
const baseline = JSON.parse(readFileSync(req("baseline"), "utf8"));
const buildInfo = JSON.parse(readFileSync(req("build-info"), "utf8"));

if (!Array.isArray(baseline.postinstall)) {
  console.error("make-img-catalog: baseline has no postinstall array");
  process.exit(1);
}
// Guard the invariant the client relies on: stable, unique step uuids.
const uuids = baseline.postinstall.map((s) => s.uuid);
if (new Set(uuids).size !== uuids.length || uuids.some((u) => !u)) {
  console.error("make-img-catalog: baseline postinstall uuids must be present and unique");
  process.exit(1);
}

const catalog = {
  formatVersion: baseline.formatVersion ?? 1,
  image: {
    uuid: req("uuid"),
    version: buildInfo.version,
    description: buildInfo.description,
    builtAt: buildInfo.builtAt,
    disk: {
      path: req("disk-key"),
      sha256: req("sha256"),
      compressedBytes: Number(req("compressed-bytes")),
      uncompressedBytes: Number(req("uncompressed-bytes")),
      compression: "gzip",
    },
  },
  postinstall: baseline.postinstall,
};

if (!catalog.image.version || !catalog.image.description) {
  console.error("make-img-catalog: build-info.json must carry version + description");
  process.exit(1);
}
if (!Number.isFinite(catalog.image.disk.compressedBytes) ||
    !Number.isFinite(catalog.image.disk.uncompressedBytes) ||
    catalog.image.disk.compressedBytes <= 0 ||
    catalog.image.disk.uncompressedBytes <= 0) {
  console.error("make-img-catalog: byte sizes must be positive numbers");
  process.exit(1);
}

const out = req("out");
writeFileSync(out, JSON.stringify(catalog, null, 2) + "\n");
console.log(`make-img-catalog: wrote ${out} (image ${catalog.image.uuid}, v${catalog.image.version}, ${catalog.postinstall.length} postinstall step(s))`);
