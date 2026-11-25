#!/usr/bin/env node
/*
 * apt-publish.mjs — publish Bromure .deb packages (bromure-ac, bromure-client, …) to the APT repository
 * served from DigitalOcean Spaces (https://dl.bromure.io/apt), and check it.
 *
 * The repository is static files, in the layout apt expects:
 *
 *   apt/bromure-archive-keyring.gpg          the signing key (binary, for signed-by)
 *   apt/bromure-archive-keyring.asc          the same, armored
 *   apt/pool/main/b/<package>/<package>_<version>_<arch>.deb
 *   apt/dists/<suite>/InRelease              Release, clearsigned
 *   apt/dists/<suite>/Release                + Release.gpg (detached)
 *   apt/dists/<suite>/main/binary-<arch>/Packages, Packages.gz
 *   apt/dists/<suite>/main/binary-<arch>/by-hash/SHA256/<sha256>
 *
 * Suites are the release channels (stable, beta), like the macOS appcast.
 * The pool is shared: a version goes to beta first, and publishing the same
 * version to stable later reuses beta's package (the one testers ran), not
 * this build's. Each suite keeps every version it was given (apt picks the
 * newest; older ones stay installable by version). A version already in the
 * suite is refused: the package version is LinuxAppVersion.short, so a new
 * release needs a bump.
 *
 * Consistency while files change under clients: the Release advertises
 * Acquire-By-Hash, so apt fetches the indexes by content hash (immutable
 * keys). The order is pool, then indexes, then Release/InRelease last.
 * dl.bromure.io must not cache dists/ (except by-hash) for long: see
 * tools/cloudflare-worker.js.
 *
 * Needs dpkg-deb and gpg (and apt-get for --verify).
 *
 * Several packages share the repository: a publish rewrites the suite's
 * indexes from what the bucket has (every package) plus this run's debs, so
 * two publishes to the same suite must not run at the same time.
 *
 * Usage (--package defaults to bromure-ac):
 *   node tools/apt-publish.mjs publish --suite stable|beta [--package NAME] [--dry-run] [--local DIR] [--out DIR] <deb>...
 *   node tools/apt-publish.mjs verify  --url https://dl.bromure.io/apt --suite stable [--package NAME] \
 *        [--expect <version> [--arches amd64,arm64]] [--keyring FILE]
 *
 * Env for publish:
 *   APT_SIGNING_KEY       the armored secret key (no passphrase), or
 *   APT_SIGNING_KEY_FILE  a file holding it.
 *   DO_SPACES_KEY, DO_SPACES_SECRET, DO_SPACES_ENDPOINT, DO_SPACES_REGION,
 *   DO_SPACES_BUCKET, DO_SPACES_PUBLIC_BASE   (unless --local)
 *
 * --local DIR   a directory stands for the bucket (tests).
 * --dry-run     reads the published state, builds and signs, uploads nothing.
 * --out DIR     where the staged repository files are left (default: a temp dir).
 */
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { constants, createReadStream, existsSync, fstatSync, mkdirSync, mkdtempSync, openSync,
         readFileSync, rmSync, writeFileSync, copyFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { parseArgs } from "node:util";
import { gzipSync } from "node:zlib";

const PREFIX = "apt";
const COMPONENT = "main";
const ARCHES = ["amd64", "arm64"];
const SUITES = ["stable", "beta"];
const KEYRING = `${PREFIX}/bromure-archive-keyring.gpg`;
const KEYRING_ASC = `${PREFIX}/bromure-archive-keyring.asc`;

function die(msg) {
  console.error(`apt-publish: ${msg}`);
  process.exit(1);
}

const [mode, ...rest] = process.argv.slice(2);
const { values: opts, positionals } = parseArgs({
  args: rest,
  allowPositionals: true,
  options: {
    suite: { type: "string" },
    package: { type: "string", default: "bromure-ac" },
    "dry-run": { type: "boolean", default: false },
    local: { type: "string" },
    out: { type: "string" },
    url: { type: "string" },
    expect: { type: "string" },
    keyring: { type: "string" },
    arches: { type: "string" },
  },
});
if (!SUITES.includes(opts.suite)) die(`--suite must be one of ${SUITES.join(", ")}`);
const SUITE = opts.suite;
// The one package this run publishes or verifies.
const PACKAGE = opts.package;
if (!/^[a-z0-9][a-z0-9.+-]+$/.test(PACKAGE)) die(`bad --package ${PACKAGE}`);
const OTHER_SUITES = SUITES.filter((s) => s !== SUITE);

// ---------------------------------------------------------------------------
// Storage: the Space, or a local directory standing for it.
// ---------------------------------------------------------------------------

function env(name) {
  const v = process.env[name];
  if (!v) die(`missing env var: ${name}`);
  return v;
}

async function spacesStore() {
  const { S3Client, GetObjectCommand, HeadObjectCommand } = await import("@aws-sdk/client-s3");
  const { Upload } = await import("@aws-sdk/lib-storage");
  const bucket = env("DO_SPACES_BUCKET");
  const client = new S3Client({
    endpoint: env("DO_SPACES_ENDPOINT"),
    region: env("DO_SPACES_REGION"),
    credentials: { accessKeyId: env("DO_SPACES_KEY"), secretAccessKey: env("DO_SPACES_SECRET") },
    forcePathStyle: false,
  });
  const missing = (e) => e?.name === "NoSuchKey" || e?.name === "NotFound" || e?.$metadata?.httpStatusCode === 404;
  return {
    where: `${bucket} (${process.env.DO_SPACES_PUBLIC_BASE ?? "?"})`,
    // The bucket, not the CDN: what was last written, never a cached copy.
    async get(key) {
      try {
        const r = await client.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
        return Buffer.from(await r.Body.transformToByteArray());
      } catch (e) {
        if (missing(e)) return null;
        throw e;
      }
    },
    async exists(key) {
      try {
        await client.send(new HeadObjectCommand({ Bucket: bucket, Key: key }));
        return true;
      } catch (e) {
        if (missing(e)) return false;
        throw e;
      }
    },
    async put(file, key, contentType, cacheControl) {
      // The file named, never what a symlink there points at (it goes public).
      const fd = openSync(file, constants.O_RDONLY | constants.O_NOFOLLOW);
      if (!fstatSync(fd).isFile()) die(`${file} isn't a regular file`);
      await new Upload({
        client,
        params: { Bucket: bucket, Key: key, Body: createReadStream(null, { fd }), ContentType: contentType,
                  ACL: "public-read", CacheControl: cacheControl },
        partSize: 64 * 1024 * 1024,
        queueSize: 4,
      }).done();
    },
  };
}

function localStore(root) {
  const path = (key) => {
    if (key.split("/").includes("..")) die(`bad key ${key}`);
    return join(root, key);
  };
  return {
    where: root,
    async get(key) { return existsSync(path(key)) ? readFileSync(path(key)) : null; },
    async exists(key) { return existsSync(path(key)); },
    async put(file, key) {
      mkdirSync(dirname(path(key)), { recursive: true });
      copyFileSync(file, path(key));
    },
  };
}

// ---------------------------------------------------------------------------
// Indexes
// ---------------------------------------------------------------------------

const sha256 = (b) => createHash("sha256").update(b).digest("hex");
const md5 = (b) => createHash("md5").update(b).digest("hex");
const sha1 = (b) => createHash("sha1").update(b).digest("hex");

function field(stanza, name) {
  return stanza.match(new RegExp(`^${name}: *(.*)$`, "m"))?.[1]?.trim();
}
const idOf = (s) => `${field(s, "Package")} ${field(s, "Version")} ${field(s, "Architecture")}`;

function parsePackages(text) {
  return (text ?? "").split(/\n\s*\n/).map((s) => s.trim()).filter(Boolean);
}

function packagesKey(suite, arch) {
  return `${PREFIX}/dists/${suite}/${COMPONENT}/binary-${arch}/Packages`;
}

/** A deb's stanza: its control fields, then where it is and its hashes. */
function stanzaFor(deb, poolPath) {
  const control = execFileSync("dpkg-deb", ["-f", deb], { encoding: "utf8" }).trimEnd();
  const bytes = readFileSync(deb);
  return [control, `Filename: ${poolPath}`, `Size: ${bytes.length}`, `MD5sum: ${md5(bytes)}`,
          `SHA1: ${sha1(bytes)}`, `SHA256: ${sha256(bytes)}`].join("\n");
}

function releaseFile(suite, files) {
  const lines = [
    "Origin: Bromure",
    "Label: Bromure",
    `Suite: ${suite}`,
    `Codename: ${suite}`,
    `Date: ${new Date().toUTCString()}`,
    `Architectures: ${ARCHES.join(" ")}`,
    `Components: ${COMPONENT}`,
    "Acquire-By-Hash: yes",
    `Description: Bromure for Linux (${suite})`,
  ];
  for (const [title, fn] of [["MD5Sum", md5], ["SHA1", sha1], ["SHA256", sha256]]) {
    lines.push(`${title}:`);
    for (const [name, bytes] of files) lines.push(` ${fn(bytes)} ${String(bytes.length).padStart(16)} ${name}`);
  }
  return lines.join("\n") + "\n";
}

// ---------------------------------------------------------------------------
// Signing
// ---------------------------------------------------------------------------

function gpg(home, args, input) {
  return execFileSync("gpg", ["--homedir", home, "--batch", "--yes", "--no-tty", "--pinentry-mode", "loopback", ...args],
                      { input, stdio: ["pipe", "pipe", "pipe"] });
}

function fingerprints(home, args) {
  const out = gpg(home, ["--with-colons", ...args]).toString();
  // The primary key's fingerprint: the fpr line right after each pub/sec line.
  const fprs = [];
  const lines = out.split("\n");
  lines.forEach((l, i) => {
    if (/^(pub|sec):/.test(l)) {
      const f = lines.slice(i + 1).find((x) => x.startsWith("fpr:"));
      if (f) fprs.push(f.split(":")[9]);
    }
  });
  return fprs;
}

function signer(work) {
  const armored = process.env.APT_SIGNING_KEY
    || (process.env.APT_SIGNING_KEY_FILE && readFileSync(process.env.APT_SIGNING_KEY_FILE, "utf8"));
  if (!armored) die("no signing key: set APT_SIGNING_KEY or APT_SIGNING_KEY_FILE");
  const home = join(work, "gnupg");
  mkdirSync(home, { mode: 0o700 });
  try {
    gpg(home, ["--import"], armored);
  } catch (e) {
    die(`the signing key didn't import: ${e.stderr?.toString().trim()}`);
  }
  const fprs = fingerprints(home, ["--list-secret-keys"]);
  if (fprs.length !== 1) die(`the signing key must hold exactly one secret key (found ${fprs.length})`);
  const fpr = fprs[0];
  return {
    fpr,
    publicKey: gpg(home, ["--export", fpr]),
    publicKeyArmored: gpg(home, ["--export", "--armor", fpr]),
    clearsign: (data) => gpg(home, ["--local-user", fpr, "--digest-algo", "SHA512", "--clearsign"], data),
    detach: (data) => gpg(home, ["--local-user", fpr, "--digest-algo", "SHA512", "--armor", "--detach-sign"], data),
    keyFingerprints: (bytes) => {
      const h = mkdtempSync(join(work, "show-"));
      writeFileSync(join(h, "k"), bytes);
      return fingerprints(h, ["--show-keys", join(h, "k")]);
    },
  };
}

// ---------------------------------------------------------------------------
// publish
// ---------------------------------------------------------------------------

async function publish() {
  const debs = positionals;
  if (debs.length === 0) die("no .deb given");
  const dryRun = opts["dry-run"];
  const store = opts.local ? localStore(opts.local) : await spacesStore();
  const work = mkdtempSync(join(tmpdir(), "apt-publish-"));
  const stage = opts.out ?? join(work, "repo");
  const cleanup = () => rmSync(work, { recursive: true, force: true });
  process.on("exit", cleanup);
  const sign = signer(work);

  console.log("=========================================================");
  console.log(`  repository:   ${store.where} /${PREFIX}`);
  console.log(`  suite:        ${SUITE}`);
  console.log(`  signing key:  ${sign.fpr}`);
  console.log(`  packages:     ${debs.map((d) => basename(d)).join(", ")}`);
  console.log(`  dry run:      ${dryRun}`);
  console.log("=========================================================");

  // The published key must be this one: a new key would break every server
  // that has the old one, so rotating is a deliberate, separate step.
  const publishedKey = await store.get(KEYRING);
  if (publishedKey) {
    const published = sign.keyFingerprints(publishedKey);
    if (!published.includes(sign.fpr)) {
      die(`${KEYRING} holds ${published.join(", ") || "no key"}, not the signing key ${sign.fpr}; ` +
          "servers trust the published key, so this would break their updates");
    }
  }

  // What every suite has now (from the bucket).
  const index = {};
  for (const suite of SUITES) {
    for (const arch of ARCHES) {
      index[`${suite}/${arch}`] = parsePackages((await store.get(packagesKey(suite, arch)))?.toString("utf8"));
    }
  }

  const uploads = [];   // [local file, key, content type, cache control], in order
  const stageFile = (rel, bytes) => {
    const p = join(stage, rel);
    mkdirSync(dirname(p), { recursive: true });
    writeFileSync(p, bytes);
    return p;
  };
  const added = [];
  for (const deb of debs) {
    const ctl = (f) => {
      try {
        return execFileSync("dpkg-deb", ["-f", deb, f], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();
      } catch (e) {
        die(`${deb} isn't a readable .deb: ${e.stderr?.toString().trim()}`);
      }
    };
    const [pkg, version, arch] = [ctl("Package"), ctl("Version"), ctl("Architecture")];
    if (pkg !== PACKAGE) die(`${basename(deb)} is ${pkg}, not ${PACKAGE}`);
    if (!ARCHES.includes(arch)) die(`${basename(deb)}: architecture ${arch} isn't one of ${ARCHES.join(", ")}`);
    const id = `${pkg} ${version} ${arch}`;
    const mine = index[`${SUITE}/${arch}`];
    if (mine.some((s) => idOf(s) === id)) {
      die(`${pkg} ${version} (${arch}) is already in ${SUITE}: bump the package version for a new release`);
    }
    const elsewhere = OTHER_SUITES.map((s) => index[`${s}/${arch}`].find((x) => idOf(x) === id)).find(Boolean);
    if (elsewhere) {
      // Promotion: the package already published (and tested) under another suite.
      console.log(`${id}: already published (${field(elsewhere, "Filename")}); ${SUITE} gets that one, not this build's`);
      mine.push(elsewhere);
      added.push(`${version} ${arch} (promoted)`);
      continue;
    }
    const poolPath = `pool/${COMPONENT}/${pkg[0]}/${pkg}/${pkg}_${version}_${arch}.deb`;
    if (await store.exists(`${PREFIX}/${poolPath}`)) {
      // Uploaded by a run that failed before its index went up: in no index,
      // so no server has it. Replaced.
      console.log(`${id}: ${poolPath} is there but in no index (an interrupted publish): replacing it`);
    }
    const local = stageFile(poolPath, readFileSync(deb));
    mine.push(stanzaFor(local, poolPath));
    uploads.push([local, `${PREFIX}/${poolPath}`, "application/vnd.debian.binary-package", "public, max-age=31536000, immutable"]);
    added.push(`${version} ${arch}`);
  }

  // The suite's indexes, every architecture (an empty one still exists:
  // apt warns about a missing index it was told about).
  const relFiles = [];
  const byHash = [];
  const indexes = [];
  for (const arch of ARCHES) {
    const stanzas = index[`${SUITE}/${arch}`];
    const text = stanzas.length ? stanzas.join("\n\n") + "\n" : "";
    const dir = `${COMPONENT}/binary-${arch}`;
    for (const [name, bytes] of [["Packages", Buffer.from(text)], ["Packages.gz", gzipSync(Buffer.from(text), { level: 9 })]]) {
      const rel = `${dir}/${name}`;
      relFiles.push([rel, bytes]);
      const type = name.endsWith(".gz") ? "application/gzip" : "text/plain; charset=utf-8";
      const hashed = `${dir}/by-hash/SHA256/${sha256(bytes)}`;
      byHash.push([stageFile(`dists/${SUITE}/${hashed}`, bytes), `${PREFIX}/dists/${SUITE}/${hashed}`, type,
                   "public, max-age=31536000, immutable"]);
      indexes.push([stageFile(`dists/${SUITE}/${rel}`, bytes), `${PREFIX}/dists/${SUITE}/${rel}`, type,
                    "public, max-age=30, must-revalidate"]);
    }
  }
  const release = Buffer.from(releaseFile(SUITE, relFiles));
  const short = "public, max-age=30, must-revalidate";
  const top = [
    [stageFile(`dists/${SUITE}/Release`, release), `${PREFIX}/dists/${SUITE}/Release`, "text/plain; charset=utf-8", short],
    [stageFile(`dists/${SUITE}/Release.gpg`, sign.detach(release)), `${PREFIX}/dists/${SUITE}/Release.gpg`, "application/pgp-signature", short],
    // Last: apt reads InRelease first, and it names everything above.
    [stageFile(`dists/${SUITE}/InRelease`, sign.clearsign(release)), `${PREFIX}/dists/${SUITE}/InRelease`, "text/plain; charset=utf-8", short],
  ];
  const keys = [
    [stageFile("bromure-archive-keyring.gpg", sign.publicKey), KEYRING, "application/pgp-keys", "public, max-age=300"],
    [stageFile("bromure-archive-keyring.asc", sign.publicKeyArmored), KEYRING_ASC, "application/pgp-keys", "public, max-age=300"],
  ];

  const all = [...uploads, ...(publishedKey ? [] : keys), ...byHash, ...indexes, ...top];
  if (dryRun) {
    console.log(`dry run: would upload, in order:\n${all.map((u) => `  ${u[1]}`).join("\n")}`);
    if (opts.out) console.log(`staged in ${stage}`);
    return;
  }
  for (const [file, key, type, cache] of all) {
    await store.put(file, key, type, cache);
    console.log(`  ↑ ${key}`);
  }
  console.log(`done: ${SUITE} now has ${added.join(", ")}`);
}

// ---------------------------------------------------------------------------
// verify: apt itself reads the published repository (as a server would).
// ---------------------------------------------------------------------------

function verify() {
  if (!opts.url) die("--url is required");
  const url = opts.url.replace(/\/+$/, "");
  const work = mkdtempSync(join(tmpdir(), "apt-verify-"));
  process.on("exit", () => rmSync(work, { recursive: true, force: true }));
  for (const d of ["state/lists/partial", "cache/archives/partial", "etc/sources.list.d", "etc/preferences.d"]) {
    mkdirSync(join(work, d), { recursive: true });
  }
  writeFileSync(join(work, "state/status"), "");
  const keyring = join(work, "keyring.gpg");
  if (opts.keyring) {
    copyFileSync(opts.keyring, keyring);
  } else {
    execFileSync("curl", ["-fsSL", "--max-time", "60", "-o", keyring, `${url}/bromure-archive-keyring.gpg`]);
  }
  writeFileSync(join(work, "etc/sources.list"),
                `deb [signed-by=${keyring} arch=${ARCHES.join(",")}] ${url} ${SUITE} ${COMPONENT}\n`);
  const aptOpts = [
    "-o", `Dir::Etc=${join(work, "etc")}`,
    "-o", `Dir::State=${join(work, "state")}`,
    "-o", `Dir::State::status=${join(work, "state/status")}`,
    "-o", `Dir::Cache=${join(work, "cache")}`,
    "-o", "Debug::NoLocking=1",
    "-o", `APT::Sandbox::User=${process.env.USER || "root"}`,
    "-o", "APT::Architecture=amd64",
    "-o", "APT::Architectures::=amd64", "-o", "APT::Architectures::=arm64",
    "-o", "Acquire::Retries=2",
    "-o", "APT::Update::Error-Mode=any",
  ];
  let out;
  try {
    out = execFileSync("apt-get", [...aptOpts, "update"], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
  } catch (e) {
    die(`apt-get update failed:\n${e.stdout ?? ""}${e.stderr ?? ""}`);
  }
  if (/^(W|E|Err):/m.test(out)) die(`apt-get update complained:\n${out}`);
  const madison = execFileSync("apt-cache", [...aptOpts, "madison", PACKAGE], { encoding: "utf8" });
  console.log(madison.trimEnd() || `(no ${PACKAGE} in ${SUITE})`);
  const expectArches = opts.arches ? opts.arches.split(",") : ARCHES;
  for (const arch of ARCHES) {
    const pol = execFileSync("apt-cache", [...aptOpts, "policy", `${PACKAGE}:${arch}`], { encoding: "utf8" });
    const cand = pol.match(/Candidate: (.*)/)?.[1]?.trim();
    console.log(`${arch}: candidate ${cand ?? "(none)"}`);
    if (opts.expect && expectArches.includes(arch) && cand !== opts.expect) die(`${arch}: candidate is ${cand}, expected ${opts.expect}`);
    if (!cand || cand === "(none)") continue;
    // The package itself, as an install would fetch it (apt checks its hash).
    const dl = mkdtempSync(join(work, "dl-"));
    try {
      execFileSync("apt-get", [...aptOpts, "download", `${PACKAGE}:${arch}=${cand}`],
                   { cwd: dl, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
    } catch (e) {
      die(`${arch}: ${PACKAGE} ${cand} didn't download:\n${e.stdout ?? ""}${e.stderr ?? ""}`);
    }
    console.log(`${arch}: ${PACKAGE} ${cand} downloads and matches its index`);
  }
  console.log(`ok: ${url} ${SUITE} verifies`);
}

if (mode === "publish") {
  publish().catch((e) => { console.error(e.stack || e); process.exit(1); });
} else if (mode === "verify") {
  verify();
} else {
  die("usage: apt-publish.mjs publish|verify --suite stable|beta …");
}
