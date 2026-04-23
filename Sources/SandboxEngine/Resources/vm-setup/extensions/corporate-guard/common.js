// Shared matching logic used by both the service worker (redirect
// decisions) and the content script (banner decisions). Bundled via
// `importScripts()` / plain <script> and stays in sync.

// Normalize a corporateWebsites entry OR a navigation target host to
// the bare registrable-looking form we compare against:
//   * strip scheme (handles a user pasting "https://…")
//   * strip any trailing path / query / hash
//   * strip port
//   * lowercase
//   * drop a single leading "www." (only one — "www.www.foo.com" keeps one)
// Examples:
//   https://Www.Google.com:443/foo  →  google.com
//   WWW.Google.Com                   →  google.com
//   mail.google.com                  →  mail.google.com
//   drive.google.com                 →  drive.google.com
function normalizeHost(input) {
  if (typeof input !== "string") return "";
  let s = input.trim();
  if (!s) return "";

  // Strip scheme if present. Accept anything before "://".
  const schemeIdx = s.indexOf("://");
  if (schemeIdx >= 0) s = s.slice(schemeIdx + 3);

  // Cut off at the first path/query/hash separator.
  const cutIdx = s.search(/[\/?#]/);
  if (cutIdx >= 0) s = s.slice(0, cutIdx);

  // Strip userinfo (user@host).
  const atIdx = s.lastIndexOf("@");
  if (atIdx >= 0) s = s.slice(atIdx + 1);

  // Strip port. Only strip the final :NNN — a raw IPv6 literal would
  // arrive already wrapped in [brackets] for the port to be after them.
  const portMatch = s.match(/:(\d+)$/);
  if (portMatch) s = s.slice(0, -portMatch[0].length);

  s = s.toLowerCase();

  // Drop a single leading "www.".
  if (s.startsWith("www.")) s = s.slice(4);

  return s;
}

// Always-allowed domains regardless of the admin's corporateWebsites
// list. Bromure's own services (analytics ingestion, hello page, etc.)
// must never get banner'd or redirected out — the browser itself talks
// to them for session bookkeeping, and managed admins shouldn't have to
// re-add them in every managed-profile config.
const BUILT_IN_ALLOWLIST = ["bromure.io"];

// `list` is the raw corporateWebsites array from managed storage.
function isCorporateHost(hostname, list) {
  const h = normalizeHost(hostname);
  if (!h) return false;

  for (const e of BUILT_IN_ALLOWLIST) {
    if (h === e || h.endsWith("." + e)) return true;
  }

  if (!Array.isArray(list)) return false;
  for (const raw of list) {
    const e = normalizeHost(raw);
    if (!e) continue;
    if (h === e || h.endsWith("." + e)) return true;
  }
  return false;
}

// URL schemes we never want to interfere with (devtools, new-tab pages,
// extension UIs, about:, data:, etc.). Only http(s) should be gated.
function isInterestingURL(url) {
  try {
    const u = new URL(url);
    if (u.protocol !== "http:" && u.protocol !== "https:") return false;
    // Loopback and unspec — dev traffic; don't banner, don't redirect.
    const h = u.hostname;
    if (h === "localhost" || h === "127.0.0.1" || h === "[::1]") return false;
    return true;
  } catch (_) {
    return false;
  }
}

// Exported for service-worker (importScripts) and content-script (plain
// script tag) contexts. `self` works in both.
self.CorpGuard = { normalizeHost, isCorporateHost, isInterestingURL };
