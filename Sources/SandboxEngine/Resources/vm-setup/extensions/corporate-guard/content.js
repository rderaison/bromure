// Bromure Corporate Guard — content script.
//
// Runs at document_start in the top frame of every page. If the page is
// outside the configured corporate domain set AND the session is in
// "tracing + banner" mode (tracingEnabled && !openExternalInPrivate),
// drops a fixed amber banner at the top of the viewport reminding the
// user this site isn't on the company list and the session is recorded.

const BANNER_ID = "__bromure_corporate_guard_banner__";

function injectBanner() {
  if (document.getElementById(BANNER_ID)) return;

  const banner = document.createElement("div");
  banner.id = BANNER_ID;
  // Inline styles + !important so site CSS can't easily nuke us.
  // Pinned to the very top of the viewport via fixed positioning;
  // the page scrolls underneath rather than having its layout shifted.
  const style = [
    "all: initial",
    "position: fixed",
    "top: 0",
    "left: 0",
    "right: 0",
    "z-index: 2147483647",
    "background: #fef3c7",                // amber-100
    "color: #78350f",                     // amber-900
    "font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif",
    "font-size: 13px",
    "font-weight: 500",
    "line-height: 1.4",
    "padding: 8px 16px",
    "border-bottom: 1px solid #f59e0b",   // amber-500
    "text-align: center",
    "box-shadow: 0 1px 2px rgba(0,0,0,0.06)",
    "box-sizing: border-box",
    "pointer-events: auto",
  ].map(d => d + " !important").join(";");
  banner.setAttribute("style", style);

  const icon = document.createElement("span");
  icon.textContent = "⚠ ";
  icon.setAttribute("style", "margin-right: 4px !important");
  banner.appendChild(icon);

  banner.appendChild(document.createTextNode(
    "This site is not on your company's approved list. " +
    "Activity in this session is being recorded by your administrator."
  ));

  // Insert into <html> rather than <body> so it survives body-replacing
  // scripts (some SPAs swap out <body> on initial render) and renders
  // before the page paints.
  (document.documentElement || document.body || document).appendChild(banner);
}

(async function main() {
  // Top frame only. Iframes don't need a banner — only the URL the user
  // *thinks* they're on matters.
  if (window !== window.top) return;
  if (!self.CorpGuard) return; // common.js failed to load — bail safely.

  const { isCorporateHost, isInterestingURL } = self.CorpGuard;
  if (!isInterestingURL(location.href)) return;

  // Pull policy from managed storage. Content scripts have access too.
  let stored;
  try {
    stored = await chrome.storage.managed.get([
      "corporateWebsites",
      "openExternalInPrivate",
      "tracingEnabled",
    ]);
  } catch (_) {
    return;
  }

  const corporateWebsites = Array.isArray(stored.corporateWebsites) ? stored.corporateWebsites : [];
  const openExternalInPrivate = stored.openExternalInPrivate === true;
  const tracingEnabled = stored.tracingEnabled === true;

  // Banner mode is mutually exclusive with redirect mode. The service
  // worker handles redirects; we only banner when redirects are off
  // and tracing is on.
  if (openExternalInPrivate) return;
  if (!tracingEnabled) return;

  if (isCorporateHost(location.hostname, corporateWebsites)) return;

  injectBanner();

  // Re-inject if a script tears down our element (some sites
  // aggressively clean foreign DOM).
  const observer = new MutationObserver(() => {
    if (!document.getElementById(BANNER_ID)) injectBanner();
  });
  if (document.documentElement) {
    observer.observe(document.documentElement, { childList: true, subtree: false });
  }
})();
