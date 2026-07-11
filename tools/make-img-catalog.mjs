#!/usr/bin/env node
/*
 * make-img-catalog.mjs — assemble the published img-catalog.json for the
 * base-image publish pipelines (scripts/publish-image.sh for Bromure
 * Agentic Coding, scripts/publish-browser-image.sh for Bromure Web).
 *
 * The postinstall step list comes VERBATIM from the bundled baseline
 * (Sources/AgentCoding/Resources/img-catalog.json for AC,
 * Sources/SandboxEngine/Resources/browser-img-catalog.json for the
 * browser) — those files are the canonical sources, same convention as
 * the MLX catalog, so the shipped app and the published manifest can
 * never drift. Step uuids therefore stay stable across weekly publishes,
 * which is what lets clients tell "already applied" from "new step"
 * (the consent prompt).
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
 *     --out <path> \
 *     [--payload-magic bromure-browser-img-catalog-v1] \
 *     [--boot name=vmlinuz,path=browser-images/<uuid>/vmlinuz.gz,sha256=<hex>,compressedBytes=N,uncompressedBytes=N]…
 *
 * --boot (repeatable) declares the non-disk boot artifacts the browser
 * image needs (vmlinuz, initrd — it direct-kernel-boots, unlike the
 * EFI/GRUB AC image). --payload-magic is the signing-payload domain
 * separator: both channels sign with the same key, so a distinct first
 * payload line is what stops a validly signed AC catalog from being
 * replayed at the browser catalog URL (and vice versa). Default is the
 * AC magic, "bromure-img-catalog-v1".
 *
 * Signing: unless --allow-unsigned is passed, the catalog is signed with
 * the SPARKLE_PRIVATE_KEY env credential — the same ed25519 key (and the
 * same PKCS8 wrapping as release-upload.mjs) that signs app updates. The
 * signature covers a canonical payload of the image identity/sha256, the
 * boot artifacts, AND every postinstall command (they run as root in
 * users' base images); clients verify against SUPublicEDKey and refuse
 * unsigned catalogs from the production CDN. The payload format here
 * MUST stay byte-identical to
 * ImageCatalog.signingPayload(signedAt:magic:) in
 * Sources/SandboxEngine/ImageCatalog.swift.
 *
 * Inspect mode (used to find the previous build to delete):
 *   node tools/make-img-catalog.mjs --print-image-uuid <prev-catalog.json>
 *     → prints the image uuid, or nothing when absent/unparseable.
 */
import { createPrivateKey, createPublicKey, sign, verify } from "node:crypto";
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
function optAll(name) {
  const out = [];
  for (let i = 0; i < args.length; i++) {
    if (args[i] === `--${name}` && args[i + 1] !== undefined) out.push(args[i + 1]);
  }
  return out;
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

// --boot name=vmlinuz,path=…,sha256=…,compressedBytes=N,uncompressedBytes=N
// (repeatable) — the extra boot artifacts a direct-kernel-boot image
// publishes alongside the disk.
const bootFiles = optAll("boot").map((spec) => {
  const kv = Object.fromEntries(spec.split(",").map((pair) => {
    const eq = pair.indexOf("=");
    return [pair.slice(0, eq), pair.slice(eq + 1)];
  }));
  const file = {
    name: kv.name,
    path: kv.path,
    sha256: kv.sha256,
    compressedBytes: Number(kv.compressedBytes),
    uncompressedBytes: Number(kv.uncompressedBytes),
    compression: kv.compression ?? "gzip",
  };
  if (!file.name || !file.path || !file.sha256 ||
      !Number.isFinite(file.compressedBytes) || file.compressedBytes <= 0 ||
      !Number.isFinite(file.uncompressedBytes) || file.uncompressedBytes <= 0) {
    console.error(`make-img-catalog: malformed --boot spec: ${spec}`);
    process.exit(1);
  }
  return file;
});
if (new Set(bootFiles.map((f) => f.name)).size !== bootFiles.length) {
  console.error("make-img-catalog: --boot names must be unique");
  process.exit(1);
}

const payloadMagic = opt("payload-magic") ?? "bromure-img-catalog-v1";

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
    ...(bootFiles.length ? { boot: bootFiles } : {}),
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

// --- Sign ----------------------------------------------------------------
// Canonical payload — keep byte-identical to
// ImageCatalog.signingPayload(signedAt:magic:) (Swift verifier,
// Sources/SandboxEngine/ImageCatalog.swift).
function b64(s) {
  return Buffer.from(s, "utf8").toString("base64");
}
function signingPayload(cat, signedAt, magic) {
  const img = cat.image;
  const lines = [
    magic,
    `signedAt=${signedAt}`,
    `formatVersion=${cat.formatVersion}`,
    `image.uuid=${img.uuid}`,
    `image.version=${img.version}`,
    `image.description.b64=${b64(img.description)}`,
    `image.builtAt=${img.builtAt ?? ""}`,
    `image.disk.path=${img.disk.path}`,
    `image.disk.sha256=${img.disk.sha256.toLowerCase()}`,
    `image.disk.compressedBytes=${img.disk.compressedBytes}`,
    `image.disk.uncompressedBytes=${img.disk.uncompressedBytes}`,
    `image.disk.compression=${img.disk.compression}`,
  ];
  // Boot artifacts (browser channel) — absent for AC catalogs, keeping
  // their payload byte-identical to the pre-boot-files format.
  const boot = [...(img.boot ?? [])]
    .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  for (const f of boot) {
    lines.push(`boot.${f.name}.path=${f.path}`);
    lines.push(`boot.${f.name}.sha256=${f.sha256.toLowerCase()}`);
    lines.push(`boot.${f.name}.compressedBytes=${f.compressedBytes}`);
    lines.push(`boot.${f.name}.uncompressedBytes=${f.uncompressedBytes}`);
    lines.push(`boot.${f.name}.compression=${f.compression}`);
  }
  const steps = [...cat.postinstall]
    .sort((a, b) => (a.uuid < b.uuid ? -1 : a.uuid > b.uuid ? 1 : 0));
  for (const s of steps) {
    lines.push(`step.${s.uuid}.seq=${s.seq}`);
    lines.push(`step.${s.uuid}.description.b64=${b64(s.description)}`);
    lines.push(`step.${s.uuid}.command.b64=${b64(s.command)}`);
    // Only when present — catalogs signed before the field existed keep
    // verifying. Signed because it decides whether Bromure Agentic
    // Coding executes the step.
    if (s.bromureac !== undefined && s.bromureac !== null) {
      lines.push(`step.${s.uuid}.bromureac=${s.bromureac}`);
    }
  }
  return Buffer.from(lines.join("\n"), "utf8");
}

if (args.includes("--allow-unsigned")) {
  console.log("make-img-catalog: --allow-unsigned — catalog will NOT carry a signature (test use only; clients reject unsigned production catalogs)");
} else {
  const SPARKLE_PRIVATE_KEY = process.env.SPARKLE_PRIVATE_KEY;
  if (!SPARKLE_PRIVATE_KEY) {
    console.error("make-img-catalog: SPARKLE_PRIVATE_KEY env is required (or pass --allow-unsigned for local tests)");
    process.exit(1);
  }
  // Same key handling as release-upload.mjs: Sparkle stores the 64-byte
  // (seed ‖ pub) or bare 32-byte seed; wrap the seed in the minimal
  // PKCS8 DER envelope (RFC 8410) for node's crypto.
  const raw = Buffer.from(SPARKLE_PRIVATE_KEY, "base64");
  if (raw.length !== 64 && raw.length !== 32) {
    console.error(`make-img-catalog: SPARKLE_PRIVATE_KEY must decode to 32 or 64 bytes, got ${raw.length}`);
    process.exit(1);
  }
  const seed = raw.subarray(0, 32);
  const prefix = Buffer.from("302e020100300506032b657004220420", "hex");
  const key = createPrivateKey({
    key: Buffer.concat([prefix, seed]), format: "der", type: "pkcs8",
  });

  const signedAt = new Date().toISOString();
  const payload = signingPayload(catalog, signedAt, payloadMagic);
  const signature = sign(null, payload, key);
  // Self-check: guards against silent key-format bugs producing
  // signatures every client would then reject.
  if (!verify(null, payload, createPublicKey(key), signature)) {
    console.error("make-img-catalog: internal error — signature failed self-verify");
    process.exit(1);
  }
  catalog.signature = { signedAt, edSignature: signature.toString("base64") };
}

const out = req("out");
writeFileSync(out, JSON.stringify(catalog, null, 2) + "\n");
console.log(`make-img-catalog: wrote ${out} (image ${catalog.image.uuid}, v${catalog.image.version}, ${catalog.postinstall.length} postinstall step(s))`);
