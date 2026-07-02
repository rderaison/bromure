// Cloudflare Worker fronting https://dl.bromure.io → DigitalOcean Spaces.
//
// Deployed manually (dashboard or `wrangler deploy`) — this copy is the
// versioned source of truth; keep it in sync with what's live.
//
// Cache policy mirrors tools/spaces-put.mjs's per-object Cache-Control:
//
//   *.json   — 1s. Mutable manifests republished in place
//              (images/img-catalog.json, mlx/catalog.json) that drive
//              install/update decisions. The image publish pipeline
//              (scripts/publish-image.sh) polls the edge for propagation
//              before deleting the previous image, so a long edge TTL
//              here directly stalls (or fails) the weekly publish.
//              These are also fetched from the plain Spaces origin, NOT
//              DO's CDN endpoint, so there's no second cache layer that
//              could serve a stale manifest after Cloudflare refreshes.
//
//   *.html   — 60s. Mutable pointer files (the pip find-links page).
//
//   the rest — 24h, via DO's CDN endpoint. Binary artifacts are
//              immutable per filename (base.img.gz lives under a
//              per-build uuid prefix; wheels/DMGs are versioned), so
//              double-caching is safe and shields the origin. Note
//              Cloudflare won't cache objects past its plan's size limit
//              (e.g. 512 MB) — the multi-GB image streams through and is
//              effectively served by DO's CDN, which is exactly why the
//              immutable route keeps the CDN hostname.
//
//   errors   — 404s for 1s (an upload that fixes one must be visible
//              immediately), 5xx never.

const SPACES_ORIGIN = "bromure-dl.nyc3.digitaloceanspaces.com";     // no DO CDN
const SPACES_CDN = "bromure-dl.nyc3.cdn.digitaloceanspaces.com";    // DO CDN

function policyFor(pathname) {
  if (pathname.endsWith(".json")) {
    return { hostname: SPACES_ORIGIN, ttl: 1 };
  }
  if (pathname.endsWith(".html")) {
    return { hostname: SPACES_ORIGIN, ttl: 60 };
  }
  return { hostname: SPACES_CDN, ttl: 86400 };
}

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const policy = policyFor(url.pathname);
    url.hostname = policy.hostname;

    const newReq = new Request(url.toString(), request);
    newReq.headers.set("Host", policy.hostname);

    return fetch(newReq, {
      cf: {
        cacheEverything: true,
        cacheTtlByStatus: {
          "200-299": policy.ttl,
          "404": 1,
          "500-599": 0,
        },
      },
    });
  },
};
