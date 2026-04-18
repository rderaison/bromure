(function () {
  "use strict";

  let reported = false;
  let scamReported = false;
  let bannerElement = null;
  const approvedForms = new WeakSet();

  // -------------------------------------------------------------------------
  // Brand keywords — used to detect impersonation on wrong domains
  // -------------------------------------------------------------------------

  const BRAND_DOMAINS = {
    google: ["google.com", "googleapis.com", "gstatic.com", "youtube.com"],
    gmail: ["google.com", "gmail.com"],
    apple: ["apple.com", "icloud.com"],
    microsoft: ["microsoft.com", "microsoftonline.com", "live.com", "outlook.com", "office.com"],
    amazon: ["amazon.com", "amazon.co.uk", "amazon.de", "amazon.fr", "amazonaws.com"],
    paypal: ["paypal.com"],
    facebook: ["facebook.com", "meta.com"],
    instagram: ["instagram.com", "meta.com"],
    netflix: ["netflix.com"],
    twitter: ["twitter.com", "x.com"],
    linkedin: ["linkedin.com"],
    chase: ["chase.com"],
    wellsfargo: ["wellsfargo.com"],
    bankofamerica: ["bankofamerica.com"],
    coinbase: ["coinbase.com"],
    binance: ["binance.com"],
    github: ["github.com"],
    dropbox: ["dropbox.com"],
    docusign: ["docusign.com", "docusign.net"],
    steam: ["steampowered.com", "steamcommunity.com"],
    discord: ["discord.com", "discordapp.com"],
    dhl: ["dhl.com"],
    fedex: ["fedex.com"],
    ups: ["ups.com"],
    usps: ["usps.com"],
  };

  // -------------------------------------------------------------------------
  // Scam content patterns
  // -------------------------------------------------------------------------

  // Multilingual scam patterns: en, de, es, fr, ja, pt, zh-Hans, zh-Hant
  var SCAM_PATTERNS = [
    // Invoice overdue/unpaid
    /(?:invoice|rechnung|factura|facture|fatura|\u8ACB\u6C42\u66F8|\u767A\u7968)\s*.*(?:overdue|unpaid|past\s*due|\u00FCberf\u00E4llig|unbezahlt|vencid[ao]|impagad[ao]|impay\u00E9[e]?|en retard|\u672A\u6255\u3044|\u671F\u9650\u5207\u308C|\u904E\u671F|\u672A\u4ED8\u6B3E|\u903E\u671F)/i,
    // Pay immediately/urgently
    /(?:pay|zahlen|pagar|payer|pague|\u652F\u6255|\u4ED8\u6B3E)\s*.*(?:immediate|urgent|within\s+\d+|sofort|dringend|innerhalb|inmediat|urgent[e]?|imm\u00E9diat|dans\s+\d+|\u3059\u3050\u306B|\u81F3\u6025|\u7ACB\u5373|\u7D27\u6025|\u99AC\u4E0A)/i,
    // Crypto payment
    /(?:bitcoin|btc|ethereum|eth|usdt|tether)\s*(?:address|wallet|payment|Adresse|Zahlung|direcci\u00F3n|pago|adresse|paiement|endere\u00E7o|pagamento|\u30A2\u30C9\u30EC\u30B9|\u5730\u5740)/i,
    // Wire transfer urgent
    /(?:wire\s*transfer|\u00DCberweisung|transferencia|virement|transfer\u00EAncia|\u632F\u8FBC|\u6C47\u6B3E|\u532F\u6B3E)\s*.*(?:immediate|urgent|sofort|dringend|inmediat|urgent[e]?|imm\u00E9diat|\u3059\u3050|\u81F3\u6025|\u7D27\u6025|\u99AC\u4E0A)/i,
    // Gift card
    /(?:gift\s*card|Geschenkkarte|Gutschein|tarjeta\s*(?:de\s*)?regalo|carte\s*cadeau|cart\u00E3o\s*(?:de\s*)?presente|\u30AE\u30D5\u30C8\u30AB\u30FC\u30C9|\u793C\u54C1\u5361|\u79AE\u54C1\u5361)/i,
    // Account suspended/locked/compromised
    /(?:your\s*account|Ihr\s*Konto|su\s*cuenta|votre\s*compte|sua\s*conta|\u3042\u306A\u305F\u306E\u30A2\u30AB\u30A6\u30F3\u30C8|\u60A8\u7684\u8CEC\u6236|\u60A8\u7684\u8D26\u6237)\s*.*(?:suspend|restrict|lock|disabl|compromis|gesperrt|eingeschr\u00E4nkt|suspendid|restringid|bloqu|d\u00E9sactiv|compromis|suspen[sd]|bloque|\u505C\u6B62|\u30ED\u30C3\u30AF|\u51CD\u7D50|\u88AB\u9501\u5B9A|\u5DF2\u505C\u7528|\u88AB\u9396\u5B9A|\u5DF2\u505C\u7528)/i,
    // Verify identity/account urgently
    /(?:verify|best\u00E4tigen|verificar|v\u00E9rifier|verificar|\u78BA\u8A8D|\u9A8C\u8BC1|\u9A57\u8B49)\s*.*(?:identity|account|Identit\u00E4t|Konto|identidad|cuenta|identit\u00E9|compte|identidade|conta|\u672C\u4EBA\u78BA\u8A8D|\u30A2\u30AB\u30A6\u30F3\u30C8|\u8EAB\u4EFD|\u8CEC\u6236|\u8D26\u6237)\s*.*(?:immediate|urgent|now|sofort|jetzt|inmediat|ahora|imm\u00E9diat|maintenant|imediata|agora|\u3059\u3050|\u4ECA\u3059\u3050|\u7ACB\u5373|\u99AC\u4E0A)/i,
    // Unauthorized access/transaction
    /(?:unauthorized|unbefugt|no\s*autoriz|non\s*autoris\u00E9|n\u00E3o\s*autoriz|\u4E0D\u6B63|\u672A\u6388\u6B0A|\u672A\u6388\u6743)\s*(?:access|transaction|activity|Zugriff|Transaktion|acceso|transacci\u00F3n|acc\u00E8s|transaction|acesso|transa\u00E7\u00E3o|\u30A2\u30AF\u30BB\u30B9|\u53D6\u5F15|\u8BBF\u95EE|\u4EA4\u6613|\u5B58\u53D6|\u4EA4\u6613)/i,
    // Click here to verify/confirm/restore
    /(?:click\s*(?:here|below)|klicken\s*Sie\s*hier|haga\s*clic\s*aqu\u00ED|cliquez\s*ici|clique\s*aqui|\u3053\u3053\u3092\u30AF\u30EA\u30C3\u30AF|\u70B9\u51FB\u6B64\u5904|\u9EDE\u64CA\u6B64\u8655)\s*.*(?:verify|confirm|restore|unlock|best\u00E4tigen|wiederherstellen|verificar|confirmar|restaurar|v\u00E9rifier|confirmer|restaurer|\u78BA\u8A8D|\u5FA9\u5143|\u9A8C\u8BC1|\u786E\u8BA4|\u6062\u590D|\u9A57\u8B49|\u78BA\u8A8D|\u6062\u5FA9)/i,
    // Fake bonus/prize/reward/lottery/giveaway
    /(?:claim|redeem|collect)\s*(?:your\s*)?(?:bonus|prize|reward|winnings|gift|cashback)/i,
    /(?:you\s*(?:have\s*)?(?:won|been\s*selected|are\s*(?:a\s*)?winner))/i,
    /(?:congratulations|congrats)[\s!]*(?:you|winner|lucky)/i,
    /(?:free\s*(?:money|cash|bonus|reward|gift)|lottery\s*winner|jackpot)/i,
    // Personal info harvesting on suspicious domains
    /(?:enter|fill\s*in|provide|submit)\s*(?:your\s*)?(?:details|information|bank|account\s*number|phone\s*number)/i,
  ];

  // Free hosting / site builder domains — forms on these are suspicious
  var FREE_HOSTING_DOMAINS = [
    "weebly.com", "wixsite.com", "wix.com", "sites.google.com", "blogspot.com",
    "wordpress.com", "000webhostapp.com", "netlify.app", "vercel.app",
    "herokuapp.com", "firebaseapp.com", "web.app", "pages.dev",
    "glitch.me", "replit.dev", "github.io", "gitlab.io",
  ];

  var CRYPTO_ADDRESS_RE = /(?:^|[\s:])([13][a-km-zA-HJ-NP-Z1-9]{25,34}|bc1[a-z0-9]{39,59}|0x[0-9a-fA-F]{40}|T[A-Za-z1-9]{33})(?:[\s,.]|$)/g;

  // -------------------------------------------------------------------------
  // Homoglyph / confusable character detection
  // -------------------------------------------------------------------------

  // Map of Unicode confusables to their ASCII equivalents
  var CONFUSABLE_MAP = {
    "\u0430": "a", "\u0435": "e", "\u043e": "o", "\u0440": "p",  // Cyrillic
    "\u0441": "c", "\u0443": "y", "\u0445": "x", "\u0456": "i",
    "\u0261": "g", "\u04bb": "h", "\u0455": "s", "\u0458": "j",
    "\u043a": "k", "\u04c0": "l", "\u043d": "n", "\u0442": "t",
    "\u0443": "y", "\u0432": "v", "\u0437": "z",
    "\u03bf": "o", "\u03b1": "a", "\u03b5": "e",                 // Greek
    "\u0101": "a", "\u0113": "e", "\u012b": "i", "\u014d": "o",  // Latin extended
    "\u1d00": "a", "\u1d04": "c", "\u1d05": "d", "\u1d07": "e",  // Small caps
    "\u1d0f": "o", "\u1d18": "p", "\u1d1b": "t", "\u1d1c": "u",
    "\u0131": "i",                                                 // Dotless i
    "\uff41": "a", "\uff42": "b", "\uff43": "c", "\uff44": "d",  // Fullwidth
    "\uff45": "e", "\uff46": "f", "\uff47": "g", "\uff48": "h",
    "\uff49": "i", "\uff4a": "j", "\uff4b": "k", "\uff4c": "l",
    "\uff4d": "m", "\uff4e": "n", "\uff4f": "o", "\uff50": "p",
  };

  function normalizeConfusables(str) {
    var result = "";
    for (var i = 0; i < str.length; i++) {
      var c = str[i];
      result += CONFUSABLE_MAP[c] || c;
    }
    return result;
  }

  function hasConfusables(str) {
    for (var i = 0; i < str.length; i++) {
      if (CONFUSABLE_MAP[str[i]]) return true;
    }
    return false;
  }

  // Check if the domain is a homoglyph of a known brand
  function detectHomoglyphDomain(hostname) {
    var normalized = normalizeConfusables(hostname.toLowerCase());
    if (normalized === hostname.toLowerCase()) return null; // no confusables present

    for (var brand in BRAND_DOMAINS) {
      var legit = BRAND_DOMAINS[brand];
      for (var i = 0; i < legit.length; i++) {
        if (normalized.indexOf(legit[i]) !== -1 || normalized.indexOf(brand) !== -1) {
          return { target: brand, normalizedDomain: normalized, hasConfusables: true };
        }
      }
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // URL structure suspicion signals
  // -------------------------------------------------------------------------

  function analyzeURLStructure(hostname, href) {
    var signals = [];

    // Brand name in subdomain with different registrable domain
    // e.g., google.com.evil.xyz or paypal-login.evil.com
    var pageReg = getRegistrableDomain(hostname);
    for (var brand in BRAND_DOMAINS) {
      var legit = BRAND_DOMAINS[brand];
      var isLegit = false;
      for (var i = 0; i < legit.length; i++) {
        if (pageReg === legit[i]) { isLegit = true; break; }
      }
      if (!isLegit && hostname.indexOf(brand) !== -1) {
        signals.push("brand-in-subdomain:" + brand);
      }
    }

    // Excessive hyphens (e.g., secure-login-paypal-verify.com)
    if ((pageReg.match(/-/g) || []).length >= 3) {
      signals.push("excessive-hyphens");
    }

    // Excessive subdomain depth (e.g., login.secure.verify.evil.com)
    var parts = hostname.split(".");
    if (parts.length >= 5) {
      signals.push("deep-subdomains:" + parts.length);
    }

    // IP address as hostname
    if (/^\d{1,3}(\.\d{1,3}){3}$/.test(hostname)) {
      signals.push("ip-address");
    }

    // Punycode domain (xn--)
    if (hostname.indexOf("xn--") !== -1) {
      signals.push("punycode");
    }

    // Suspicious TLDs commonly used in phishing
    var suspiciousTLDs = ["xyz", "tk", "ml", "ga", "cf", "top", "buzz", "icu", "gq", "work", "click", "link", "surf"];
    var tld = pageReg.split(".").pop();
    if (suspiciousTLDs.indexOf(tld) !== -1) {
      signals.push("suspicious-tld:" + tld);
    }

    // Long domain name (phishing domains tend to be long)
    if (pageReg.length > 30) {
      signals.push("long-domain:" + pageReg.length);
    }

    // Keywords in URL path suggesting credential capture
    var path = "";
    try { path = new URL(href).pathname.toLowerCase(); } catch (_) {}
    if (/(?:login|signin|sign-in|verify|secure|account|update|confirm|auth|banking|webscr)/.test(path)) {
      signals.push("credential-path-keywords");
    }

    return signals;
  }

  // -------------------------------------------------------------------------
  // Structural DOM analysis — phishing page fingerprinting
  // -------------------------------------------------------------------------

  function analyzePageStructure() {
    var signals = [];

    // Count total forms vs password forms
    var allForms = document.querySelectorAll("form");
    var pwForms = document.querySelectorAll('form:has(input[type="password"])');
    if (pwForms.length > 0 && allForms.length === pwForms.length) {
      signals.push("only-login-forms");
    }

    // Minimal navigation (phishing pages rarely have real navigation)
    var navLinks = document.querySelectorAll("nav a, header a, [role=navigation] a");
    if (navLinks.length < 3 && pwForms.length > 0) {
      signals.push("minimal-navigation:" + navLinks.length);
    }

    // Password field with autocomplete=off (phishing tries to prevent browser fill)
    var pwInputs = document.querySelectorAll('input[type="password"]');
    for (var i = 0; i < pwInputs.length; i++) {
      if (pwInputs[i].autocomplete === "off" || pwInputs[i].autocomplete === "new-password") {
        signals.push("password-autocomplete-off");
        break;
      }
    }

    // Hidden iframes (credential theft, clickjacking)
    var iframes = document.querySelectorAll("iframe");
    for (var j = 0; j < iframes.length; j++) {
      var style = getComputedStyle(iframes[j]);
      if (style.display === "none" || style.visibility === "hidden" ||
          (parseInt(style.width) <= 1 && parseInt(style.height) <= 1) ||
          parseFloat(style.opacity) === 0) {
        signals.push("hidden-iframe");
        break;
      }
    }

    // Page has very little content relative to forms (login-only page)
    var bodyText = (document.body?.innerText || "").trim();
    if (bodyText.length < 500 && pwForms.length > 0) {
      signals.push("minimal-content:" + bodyText.length);
    }

    // Data URI or blob favicon (can't be traced to a legitimate origin)
    var favicon = document.querySelector('link[rel*="icon"]');
    if (favicon) {
      var href = favicon.getAttribute("href") || "";
      if (href.startsWith("data:") || href.startsWith("blob:")) {
        signals.push("data-uri-favicon");
      }
    }

    // Hotlinked images from a different domain (impersonation signal)
    var pageReg = getRegistrableDomain(getDomain());
    var imgs = document.querySelectorAll("img[src]");
    var hotlinked = [];
    for (var k = 0; k < Math.min(imgs.length, 20); k++) {
      try {
        var imgHost = new URL(imgs[k].src).hostname;
        var imgReg = getRegistrableDomain(imgHost);
        if (imgReg !== pageReg && imgReg !== "googleapis.com" && imgReg !== "gstatic.com" && imgReg !== "cloudflare.com") {
          if (hotlinked.indexOf(imgReg) === -1) hotlinked.push(imgReg);
        }
      } catch (_) {}
    }
    if (hotlinked.length > 0) {
      signals.push("hotlinked-images:" + hotlinked.join(","));
    }

    return signals;
  }

  // -------------------------------------------------------------------------
  // Feature extraction — brand signals
  // -------------------------------------------------------------------------

  function extractBrandSignals() {
    var title = document.title || "";
    var headings = [];
    var els = document.querySelectorAll("h1, h2, h3");
    for (var i = 0; i < Math.min(els.length, 10); i++) {
      var text = (els[i].textContent || "").trim();
      if (text.length > 0 && text.length < 200) headings.push(text);
    }

    var logoSrcs = [];
    var imgs = document.querySelectorAll('img[src*="logo"], img[alt*="logo"], img[class*="logo"], header img, nav img');
    for (var j = 0; j < Math.min(imgs.length, 5); j++) {
      logoSrcs.push(imgs[j].src);
    }

    var faviconEl = document.querySelector('link[rel*="icon"]');
    var faviconHref = faviconEl ? faviconEl.href : null;

    var metaOG = {};
    var ogSiteName = document.querySelector('meta[property="og:site_name"]');
    if (ogSiteName) metaOG.siteName = ogSiteName.content;
    var ogTitle = document.querySelector('meta[property="og:title"]');
    if (ogTitle) metaOG.title = ogTitle.content;

    return { title: title, headings: headings, logoSrcs: logoSrcs, faviconHref: faviconHref, metaOG: metaOG };
  }

  function detectClaimedBrand(signals) {
    var raw = [
      signals.title,
      signals.headings.join(" "),
      (signals.metaOG.siteName || ""),
      (signals.metaOG.title || ""),
      signals.logoSrcs.join(" "),
    ].join(" ");

    var haystack = raw.toLowerCase();
    // Also check with confusables normalized (e.g. "Gооgle" with Cyrillic о)
    var normalizedHaystack = normalizeConfusables(haystack);

    for (var brand in BRAND_DOMAINS) {
      if (haystack.indexOf(brand) !== -1 || normalizedHaystack.indexOf(brand) !== -1) {
        return brand;
      }
    }
    return null;
  }

  function checkBrandMismatch(claimedBrand, pageHostname) {
    if (!claimedBrand) return null;
    var legitimate = BRAND_DOMAINS[claimedBrand];
    if (!legitimate) return null;
    var pageReg = getRegistrableDomain(pageHostname);
    for (var i = 0; i < legitimate.length; i++) {
      if (pageReg === legitimate[i] || pageHostname.endsWith("." + legitimate[i])) {
        return null; // legit
      }
    }
    return { claimedBrand: claimedBrand, actualDomain: pageReg, mismatch: true };
  }

  // -------------------------------------------------------------------------
  // Feature extraction — scam/invoice content
  // -------------------------------------------------------------------------

  function extractScamSignals() {
    var bodyText = (document.body?.innerText || "").substring(0, 5000);
    var matchedPatterns = [];
    for (var i = 0; i < SCAM_PATTERNS.length; i++) {
      if (SCAM_PATTERNS[i].test(bodyText)) {
        matchedPatterns.push(SCAM_PATTERNS[i].source.substring(0, 60));
      }
    }

    var cryptoAddresses = [];
    var match;
    CRYPTO_ADDRESS_RE.lastIndex = 0;
    while ((match = CRYPTO_ADDRESS_RE.exec(bodyText)) !== null) {
      cryptoAddresses.push(match[1]);
      if (cryptoAddresses.length >= 5) break;
    }

    var urgency = /(?:urgent|immediate|act now|expires?\s*(?:today|soon|in\s*\d)|limited time|final warning|last chance|sofort|dringend|letzte Warnung|jetzt handeln|urgente|inmediata|\u00FAltima oportunidad|actuar ahora|urgent[e]?|imm\u00E9diat|derni\u00E8re chance|agir maintenant|imediato|urgente|\u00FAltima chance|agir agora|\u81F3\u6025|\u3059\u3050\u306B|\u6700\u5F8C\u306E\u30C1\u30E3\u30F3\u30B9|\u4ECA\u3059\u3050|\u7D27\u6025|\u7ACB\u5373|\u6700\u540E\u673A\u4F1A|\u99AC\u4E0A\u884C\u52D5|\u7DCA\u6025|\u7ACB\u5373|\u6700\u5F8C\u6A5F\u6703|\u99AC\u4E0A\u884C\u52D5)/i.test(bodyText);

    var amountMatch = bodyText.match(/[\$\u20AC\u00A3\u00A5R\$]\s?[\d,.\u3002]+/);
    var amountMentioned = amountMatch ? amountMatch[0] : null;

    var externalPayLinks = [];
    var links = document.querySelectorAll('a[href]');
    var pageReg = getRegistrableDomain(getDomain());
    for (var j = 0; j < links.length; j++) {
      var href = links[j].href;
      var text = (links[j].textContent || "").toLowerCase();
      if (/(pay|send|transfer|donate|wallet|checkout|zahlen|bezahlen|pagar|payer|pague|\u652F\u6255|\u4ED8\u6B3E)/i.test(text) || /(pay|checkout|invoice)/i.test(href)) {
        try {
          var linkHost = new URL(href).hostname;
          if (getRegistrableDomain(linkHost) !== pageReg) {
            externalPayLinks.push(href);
            if (externalPayLinks.length >= 5) break;
          }
        } catch (_) {}
      }
    }

    return {
      matchedPatterns: matchedPatterns,
      cryptoAddresses: cryptoAddresses,
      urgencyLanguage: urgency,
      amountMentioned: amountMentioned,
      externalPayLinks: externalPayLinks,
    };
  }

  // -------------------------------------------------------------------------
  // Feature extraction — sensitive input fields
  // -------------------------------------------------------------------------

  function detectSensitiveFields() {
    var types = [];
    var inputs = document.querySelectorAll("input");
    for (var i = 0; i < inputs.length; i++) {
      var input = inputs[i];
      var name = ((input.name || "") + " " + (input.autocomplete || "") + " " + (input.id || "") + " " + (input.placeholder || "")).toLowerCase();
      if (input.type === "password") {
        if (types.indexOf("password") === -1) types.push("password");
      }
      if (/card.?num|cc.?num|credit.?card|kreditkarte|tarjeta|carte.?cr|cart\u00E3o|\u30AB\u30FC\u30C9\u756A\u53F7|\u5361\u53F7|\u5361\u865F/i.test(name) || input.autocomplete === "cc-number") {
        if (types.indexOf("card-number") === -1) types.push("card-number");
      }
      if (/cvv|cvc|security.?code|sicherheitscode|c\u00F3digo.?segur|code.?s\u00E9cur|c\u00F3digo.?seguran|\u30BB\u30AD\u30E5\u30EA\u30C6\u30A3\u30B3\u30FC\u30C9|\u5B89\u5168\u7801|\u5B89\u5168\u78BC/i.test(name) || input.autocomplete === "cc-csc") {
        if (types.indexOf("cvv") === -1) types.push("cvv");
      }
      if (/ssn|social.?sec|sozialversicherung|seguro.?social|num\u00E9ro.?s\u00E9cu|cpf|nif|\u30DE\u30A4\u30CA\u30F3\u30D0\u30FC|\u8EAB\u4EFD\u8BC1|\u8EAB\u5206\u8B49/i.test(name)) {
        if (types.indexOf("ssn") === -1) types.push("ssn");
      }
      if (/routing.?num|account.?num|iban|swift|bic|kontonummer|n\u00FAmero.?cuenta|num\u00E9ro.?compte|n\u00FAmero.?conta|\u53E3\u5EA7\u756A\u53F7|\u94F6\u884C\u8D26\u53F7|\u9280\u884C\u5E33\u865F/i.test(name)) {
        if (types.indexOf("bank-account") === -1) types.push("bank-account");
      }
      if (/wallet|btc|bitcoin|ethereum|crypto|\u30A6\u30A9\u30EC\u30C3\u30C8|\u94B1\u5305|\u9322\u5305/i.test(name)) {
        if (types.indexOf("crypto-wallet") === -1) types.push("crypto-wallet");
      }
    }
    return types;
  }

  // -------------------------------------------------------------------------
  // Trust check — gate every analyzer request so "I know this site" decisions
  // are honored in-page (avoiding a stuck "Analyzing…" banner when background
  // short-circuits the request silently).
  // -------------------------------------------------------------------------

  var domainTrustCache = null;

  async function isPageDomainTrusted() {
    if (domainTrustCache !== null) return domainTrustCache;
    try {
      var result = await chrome.storage.local.get("trustedDomains");
      var trusted = result.trustedDomains || [];
      var d = getDomain();
      domainTrustCache = trusted.includes(d) || trusted.includes(getRegistrableDomain(d));
      return domainTrustCache;
    } catch (_) {
      return false;
    }
  }

  // Invalidate the cache if the user's trust set changes mid-session (e.g.
  // they just clicked "I know this site" on this tab).
  if (chrome.storage && chrome.storage.onChanged) {
    chrome.storage.onChanged.addListener(function (changes, area) {
      if (area === "local" && changes.trustedDomains) {
        domainTrustCache = null;
      }
    });
  }

  async function requestLLMAnalysis(payload) {
    if (await isPageDomainTrusted()) {
      console.log("[Phishing Guard] skipping analysis — domain is user-trusted");
      return;
    }
    showAnalyzingBanner();
    chrome.runtime.sendMessage({ type: "analyzeWithLLM", payload: payload });
  }

  // -------------------------------------------------------------------------
  // QR-code extraction — quishing (QR phishing) context for the analyzer
  // -------------------------------------------------------------------------

  // Iterates visible <img> elements, runs jsQR on each, and returns an array
  // of decoded values. Decoded QR content is almost always the most important
  // signal for "quishing" (QR phishing) — the user is about to scan the code
  // with their phone, and the URL the code points to usually doesn't match
  // the page. Only runs once at payload-build time (i.e. once we've already
  // decided to call the analyzer), so per-page cost stays zero on safe pages.
  function extractQRCodes() {
    if (typeof jsQR !== "function") return [];

    var results = [];
    var imgs = document.querySelectorAll("img");
    var attempted = 0;
    // Reusable canvas — avoid allocating 20 of them.
    var canvas = document.createElement("canvas");
    var ctx = canvas.getContext("2d", { willReadFrequently: true });

    for (var i = 0; i < imgs.length; i++) {
      if (attempted >= 20 || results.length >= 5) break;
      var img = imgs[i];

      // Size gate: QR codes need to be at least ~40px on a side to be
      // readable; skipping icons/favicons cuts the cost dramatically.
      var w = img.naturalWidth || img.width || 0;
      var h = img.naturalHeight || img.height || 0;
      if (w < 40 || h < 40) continue;
      if (!img.complete || !img.src) continue;

      // Cap the working canvas size — decoding a 4K image is wasteful and
      // jsQR scales with pixel count. 512px longest side keeps it under
      // ~260K pixels while still resolving typical on-screen QR codes.
      var scale = Math.min(1, 512 / Math.max(w, h));
      var cw = Math.max(40, Math.round(w * scale));
      var ch = Math.max(40, Math.round(h * scale));
      canvas.width = cw;
      canvas.height = ch;

      attempted++;

      try {
        ctx.clearRect(0, 0, cw, ch);
        ctx.drawImage(img, 0, 0, cw, ch);
        var data = ctx.getImageData(0, 0, cw, ch);
        var code = jsQR(data.data, cw, ch);
        if (!code || !code.data) continue;

        // De-dupe so a repeated QR (e.g. in header + footer) appears once.
        var seen = false;
        for (var r = 0; r < results.length; r++) {
          if (results[r].decoded === code.data) { seen = true; break; }
        }
        if (seen) continue;

        var imgHost = "";
        try { imgHost = new URL(img.src, window.location.href).hostname; } catch (_) {}

        results.push({
          decoded: String(code.data).substring(0, 512),
          imgHost: imgHost,
          imgWidth: w,
          imgHeight: h,
        });
      } catch (_) {
        // Canvas is tainted (cross-origin image without CORS) or image not
        // yet decoded — skip silently and move on.
      }
    }

    if (results.length > 0) {
      console.log("[Phishing Guard] Decoded " + results.length + " QR code(s)");
    }
    return results;
  }

  // -------------------------------------------------------------------------
  // ClickFix / paste-and-run detection
  //
  // Pages that trick the user into Win+R → paste → Enter rely on silently
  // stuffing the clipboard with a powershell / curl|sh command. The page-world
  // companion script (clickfix-inject.js) hooks clipboard APIs and forwards
  // every write here via postMessage. We flag a write only when the payload
  // looks shell-like AND the page also contains ClickFix instruction text.
  // -------------------------------------------------------------------------

  // Shell-command signatures. Match any one to treat the payload as suspicious.
  var SHELL_COMMAND_PATTERNS = [
    /\bpowershell(?:\.exe)?\b/i,
    /\bcmd\.exe\b|\bcmd(?:\s+\/[ck])/i,
    /\b(?:iwr|iex|Invoke-WebRequest|Invoke-Expression|DownloadString|DownloadFile|WebClient)\b/i,
    // `powershell -enc <base64>` / `-EncodedCommand`
    /-\s*(?:e|enc|EncodedCommand)\s+[A-Za-z0-9+/=]{80,}/,
    // `curl ... | sh` / `wget ... | bash` — pipe to shell
    /\b(?:curl|wget)\b[^|\n]{0,200}\|\s*(?:sudo\s+)?(?:sh|bash|zsh|dash)\b/i,
    // `bash -c` / `sh -c` with a URL argument or long inline string
    /\b(?:bash|sh|zsh)\s+-c\s+["'].{20,}["']/i,
    // Living-off-the-land binaries commonly used in ClickFix chains
    /\bmshta\s+https?:\/\//i,
    /\bcertutil\s+-(?:urlcache|decode)/i,
    /\brundll32\s+.+,\s*[A-Za-z]+/i,
    // `powershell` process substitution / IEX Invoke-RestMethod etc.
    /\bInvoke-(?:RestMethod|WebRequest|Expression)\b/i,
  ];

  // Instruction text shown to the user alongside the silent clipboard stuff.
  // Multilingual where common (en/fr/de/es/pt/ja/zh) — kept loose on purpose.
  var CLICKFIX_INSTRUCTION_PATTERNS = [
    /\bpress\s+(?:the\s+)?win(?:dows)?\s*(?:key\s*)?\+\s*r\b/i,
    /\bwin(?:dows)?\s*\+\s*r\s+keys?\b/i,
    /\bopen\s+(?:terminal|powershell|the\s+run\s+dialog|command\s+prompt)\b/i,
    /\bpress\s+(?:cmd|command)\s*\+\s*space\b/i,
    // Numbered step + Enter combo — "Step 3: Press Enter"
    /(?:step\s*3|3[.):])\s*(?:press|hit|tap)\s+(?:the\s+)?enter/i,
    // "Paste the command" / "Paste it"
    /paste\s+(?:the\s+)?(?:code|command|script)\b/i,
    // "I'm not a robot" / verification headline paired with paste-instructions — handled by combining two regexes below
    /verify\s+(?:you|that\s+you)\s+are\s+(?:human|not\s+a\s+robot)/i,
    // French / German / Spanish / Portuguese / Japanese / Chinese
    /appuyez\s+sur\s+(?:win|touche\s+windows)/i,
    /dr(?:\u00FC|u)cken\s+sie\s+(?:win|windows)/i,
    /presione\s+win|pulsa\s+win/i,
    /pressione\s+(?:win|tecla\s+windows)/i,
    /Win\s*\+\s*R\s*\u30AD\u30FC/i, // Japanese "Win+Rキー"
    /\u6309\s*Win\s*\+\s*R/i,       // Chinese "按 Win+R"
  ];

  function looksLikeShellCommand(text) {
    if (!text || text.length < 6) return false;
    for (var i = 0; i < SHELL_COMMAND_PATTERNS.length; i++) {
      if (SHELL_COMMAND_PATTERNS[i].test(text)) return true;
    }
    return false;
  }

  function pageHasClickfixInstructions() {
    var body = (document.body && document.body.innerText) || "";
    if (body.length < 10 || body.length > 200_000) {
      // Trim extremely long pages so the regex loop stays cheap.
      body = body.substring(0, 40_000);
    }
    var hits = 0;
    for (var i = 0; i < CLICKFIX_INSTRUCTION_PATTERNS.length; i++) {
      if (CLICKFIX_INSTRUCTION_PATTERNS[i].test(body)) {
        hits++;
        // Two independent matches on the same page is high signal; one is
        // enough when the payload itself is already clearly malicious.
        if (hits >= 1) return true;
      }
    }
    return false;
  }

  var clickfixReported = false;
  var clipboardWriteBuffer = []; // keep a short history so we can correlate

  function handleClipboardMessage(text, source) {
    if (clickfixReported) return;
    if (!text) return;

    // Remember the last few writes so we can surface them for analysis even
    // if only a later write matches — attackers sometimes clear the clipboard
    // first with an innocuous value, then overwrite with the real payload.
    clipboardWriteBuffer.push({ text: text, source: source, ts: Date.now() });
    if (clipboardWriteBuffer.length > 4) clipboardWriteBuffer.shift();

    if (!looksLikeShellCommand(text)) return;
    if (!pageHasClickfixInstructions()) return;

    clickfixReported = true;
    console.log("[Phishing Guard] ClickFix-pattern clipboard write detected on " + getDomain());

    var payload = buildAnalysisPayload("clickfix-content");
    payload.clipboardPayload = text.substring(0, 1024);
    payload.clipboardSource = source;
    requestLLMAnalysis(payload);
  }

  window.addEventListener("message", function (ev) {
    // postMessage from our own page-world injector only.
    if (!ev || !ev.data || ev.source !== window) return;
    if (ev.data.__bromurePhishingClipboard !== true) return;
    handleClipboardMessage(String(ev.data.text || ""), String(ev.data.source || "?"));
  }, false);

  // -------------------------------------------------------------------------
  // QR-code scanner — triggers analysis on quishing (QR phishing) pages
  // -------------------------------------------------------------------------

  var qrReported = false;

  // Decide whether a set of decoded QR values warrants an analysis request.
  // Benign QRs (WiFi configs, plain text, same-domain URLs) do not trigger.
  function qrContentInteresting(qrCodes) {
    if (!qrCodes || qrCodes.length === 0) return false;
    var pageReg = getRegistrableDomain(getDomain());
    for (var i = 0; i < qrCodes.length; i++) {
      var decoded = qrCodes[i].decoded;
      if (!decoded) continue;

      // 1. URL pointing off-domain — classic quishing payload.
      if (/^https?:\/\//i.test(decoded)) {
        try {
          var qrHost = new URL(decoded).hostname.toLowerCase();
          if (getRegistrableDomain(qrHost) !== pageReg) return true;
        } catch (_) { /* malformed URL — keep scanning */ }
      }

      // 2. Payment URIs — always analyzer-worthy.
      if (/^(bitcoin|ethereum|monero|litecoin|lightning|bank|upi):/i.test(decoded)) {
        return true;
      }

      // 3. Raw crypto address.
      CRYPTO_ADDRESS_RE.lastIndex = 0;
      if (CRYPTO_ADDRESS_RE.test(" " + decoded + " ")) return true;
    }
    return false;
  }

  function scanForQRCodes() {
    if (qrReported) return;
    if (typeof jsQR !== "function") return;

    var qrCodes = extractQRCodes();
    if (!qrContentInteresting(qrCodes)) return;

    qrReported = true;
    console.log("[Phishing Guard] QR code(s) warrant analysis on " + getDomain());
    var payload = buildAnalysisPayload("qr-content");
    // buildAnalysisPayload already ran extractQRCodes; ensure the decoded
    // list is attached even if the size-gate inside it changed.
    if (!payload.qrCodes) payload.qrCodes = qrCodes;
    requestLLMAnalysis(payload);
  }

  // -------------------------------------------------------------------------
  // Build full analysis payload for LLM
  // -------------------------------------------------------------------------

  function buildAnalysisPayload(triggerType) {
    var domain = getDomain();
    var brandSignals = extractBrandSignals();
    var claimedBrand = detectClaimedBrand(brandSignals);
    var domainMismatch = checkBrandMismatch(claimedBrand, domain);
    var homoglyph = detectHomoglyphDomain(domain);
    var urlSignals = analyzeURLStructure(domain, window.location.href);
    var structureSignals = analyzePageStructure();
    var formActionDomains = getFormActionDomains();
    var sensitiveFields = detectSensitiveFields();

    var payload = {
      url: window.location.href,
      domain: domain,
      path: window.location.pathname,
      triggerType: triggerType,
      sensitiveFields: sensitiveFields,
      formActions: formActionDomains,
      brandSignals: {
        title: brandSignals.title,
        headings: brandSignals.headings,
        logoSrcs: brandSignals.logoSrcs.slice(0, 3),
        faviconHref: brandSignals.faviconHref,
        metaOG: brandSignals.metaOG,
      },
      domainMismatch: domainMismatch,
      homoglyphDomain: homoglyph,
      urlSuspicion: urlSignals,
      pageStructure: structureSignals,
      // First ~800 chars of visible page text — gives the LLM context for scam/invoice detection
      visibleText: (document.body?.innerText || "").substring(0, 800).replace(/\s+/g, " ").trim(),
    };

    if (triggerType === "scam-content") {
      payload.contentIndicators = extractScamSignals();
    }

    var qrCodes = extractQRCodes();
    if (qrCodes.length > 0) {
      payload.qrCodes = qrCodes;
    }

    return payload;
  }

  // -------------------------------------------------------------------------
  // Suspicious link scanner — detect phishing URLs in page links
  // -------------------------------------------------------------------------

  var linksReported = false;

  function checkURLSuspicion(hostname) {
    var signals = [];
    var linkReg = getRegistrableDomain(hostname);

    // Homoglyph
    var homoglyph = detectHomoglyphDomain(hostname);
    if (homoglyph) signals.push("homoglyph-link:" + homoglyph.target);

    // Brand in domain but wrong registrable domain
    for (var brand in BRAND_DOMAINS) {
      var legit = BRAND_DOMAINS[brand];
      var isLegit = false;
      for (var j = 0; j < legit.length; j++) {
        if (linkReg === legit[j]) { isLegit = true; break; }
      }
      if (!isLegit && hostname.indexOf(brand) !== -1) {
        signals.push("brand-in-link:" + brand + "@" + hostname);
      }
    }

    // Suspicious TLD
    var tld = linkReg.split(".").pop();
    var suspiciousTLDs = ["xyz", "tk", "ml", "ga", "cf", "top", "buzz", "icu", "gq", "work", "click", "link", "surf"];
    if (suspiciousTLDs.indexOf(tld) !== -1 && signals.length > 0) {
      signals.push("suspicious-tld:" + tld);
    }

    return signals;
  }

  function scanForSuspiciousLinks() {
    if (linksReported) return;
    console.log("[Phishing Guard] scanForSuspiciousLinks running on " + getDomain());

    var suspiciousLinks = [];
    var pageReg = getRegistrableDomain(getDomain());

    // 1. Scan actual <a href> elements
    var links = document.querySelectorAll("a[href]");
    for (var i = 0; i < links.length; i++) {
      var href = links[i].href;
      var linkText = (links[i].textContent || "").trim();
      if (!href || href.startsWith("javascript:") || href.startsWith("#") || href.startsWith("mailto:")) continue;

      var linkHost;
      try { linkHost = new URL(href).hostname.toLowerCase(); } catch (_) { continue; }
      if (getRegistrableDomain(linkHost) === pageReg) continue;

      var signals = checkURLSuspicion(linkHost);

      // Text/href mismatch: link text says one domain, href goes elsewhere
      var textLower = linkText.toLowerCase().replace(/\s+/g, "");
      for (var brand2 in BRAND_DOMAINS) {
        var legit2 = BRAND_DOMAINS[brand2];
        for (var k = 0; k < legit2.length; k++) {
          if (textLower.indexOf(legit2[k]) !== -1 || textLower.indexOf(brand2 + ".") !== -1) {
            var isLegit2 = false;
            for (var l = 0; l < legit2.length; l++) {
              if (getRegistrableDomain(linkHost) === legit2[l]) { isLegit2 = true; break; }
            }
            if (!isLegit2) {
              signals.push("text-domain-mismatch:" + legit2[k] + "->" + linkHost);
            }
          }
        }
      }

      if (signals.length > 0) {
        suspiciousLinks.push({
          href: href.substring(0, 256),
          text: linkText.substring(0, 120),
          target: linkHost,
          signals: signals,
        });
      }
      if (suspiciousLinks.length >= 10) break;
    }

    // 2. Scan visible text for URL-like strings pointing to suspicious domains
    //    Catches URLs rendered as text (not <a>), common in SPAs and email previews
    var bodyText = (document.body?.innerText || "").substring(0, 20000);
    console.log("[Phishing Guard] text scan: " + bodyText.length + " chars, " + suspiciousLinks.length + " links from <a> scan");
    var urlPattern = /https?:\/\/([a-z0-9](?:[a-z0-9\-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9\-]*[a-z0-9])?)*\.[a-z]{2,})(?:[\/\?\#]\S*)?/gi;
    var match;
    while ((match = urlPattern.exec(bodyText)) !== null) {
      var textHost = match[1].toLowerCase();
      if (getRegistrableDomain(textHost) === pageReg) continue;

      // Skip already found via <a href>
      var alreadyFound = false;
      for (var m = 0; m < suspiciousLinks.length; m++) {
        if (suspiciousLinks[m].target === textHost) { alreadyFound = true; break; }
      }
      if (alreadyFound) continue;

      var textSignals = checkURLSuspicion(textHost);
      if (textSignals.length > 0) {
        // Get surrounding context (up to 60 chars before and after)
        var start = Math.max(0, match.index - 60);
        var end = Math.min(bodyText.length, match.index + match[0].length + 60);
        var context = bodyText.substring(start, end).replace(/\s+/g, " ").trim();

        suspiciousLinks.push({
          href: match[0].substring(0, 256),
          text: context.substring(0, 120),
          target: textHost,
          signals: textSignals,
          source: "visible-text",
        });
      }
      if (suspiciousLinks.length >= 10) break;
    }

    if (suspiciousLinks.length === 0) return;

    linksReported = true;
    console.log("[Phishing Guard] Found " + suspiciousLinks.length + " suspicious links");

    var payload = buildAnalysisPayload("suspicious-links");
    payload.suspiciousLinks = suspiciousLinks;
    requestLLMAnalysis(payload);
  }

  // -------------------------------------------------------------------------
  // Scam content scanner — runs on all pages, bails early on popular domains
  // -------------------------------------------------------------------------

  function scanForScamContent() {
    if (scamReported) return;

    // Only scan visible text — bail if body is too small to be a scam page
    var bodyText = (document.body?.innerText || "");
    if (bodyText.length < 100) return;

    var hasScamPattern = false;
    for (var i = 0; i < SCAM_PATTERNS.length; i++) {
      if (SCAM_PATTERNS[i].test(bodyText)) {
        hasScamPattern = true;
        break;
      }
    }

    // Also check for crypto addresses
    CRYPTO_ADDRESS_RE.lastIndex = 0;
    var hasCrypto = CRYPTO_ADDRESS_RE.test(bodyText);

    if (!hasScamPattern && !hasCrypto) return;

    scamReported = true;
    var payload = buildAnalysisPayload("scam-content");
    requestLLMAnalysis(payload);
  }

  // -------------------------------------------------------------------------
  // Form scanner — any page with forms gets analyzed by the LLM
  // -------------------------------------------------------------------------

  var formsReported = false;

  function scanForForms() {
    if (formsReported) return;

    var forms = document.querySelectorAll("form");
    if (forms.length === 0) return;

    // Collect info about what the forms ask for
    var formSummaries = [];
    for (var i = 0; i < Math.min(forms.length, 5); i++) {
      var form = forms[i];
      var inputs = form.querySelectorAll("input, select, textarea");
      var fieldTypes = [];
      for (var j = 0; j < inputs.length; j++) {
        var inp = inputs[j];
        if (inp.type === "hidden" || inp.type === "submit" || inp.type === "button") continue;

        // Gather label from multiple sources: attribute, <label> element, nearby text
        var label = inp.name || inp.id || inp.placeholder || "";
        if (!label && inp.id) {
          var labelEl = document.querySelector('label[for="' + inp.id + '"]');
          if (labelEl) label = (labelEl.textContent || "").trim();
        }
        if (!label) {
          // Check parent or previous sibling for visible label text
          var parent = inp.closest("label, [class*=label], [class*=field]");
          if (parent) label = (parent.textContent || "").replace(/[\n\r]+/g, " ").trim();
        }
        // Also capture the visible text of the form near this input
        var visibleLabel = "";
        var prev = inp.previousElementSibling;
        if (prev && prev.textContent) visibleLabel = prev.textContent.trim().substring(0, 40);

        label = (label || inp.type || "").substring(0, 60);
        var desc = inp.type + ":" + label;
        if (visibleLabel && visibleLabel !== label) desc += " [" + visibleLabel.substring(0, 40) + "]";
        fieldTypes.push(desc);
      }
      if (fieldTypes.length === 0) continue;

      // Also grab visible text of submit buttons
      var buttons = form.querySelectorAll('button, input[type="submit"], [role="button"]');
      var buttonLabels = [];
      for (var k = 0; k < buttons.length; k++) {
        var btnText = (buttons[k].textContent || buttons[k].value || "").trim();
        if (btnText) buttonLabels.push(btnText.substring(0, 40));
      }

      var action = form.getAttribute("action") || "";
      formSummaries.push({
        fields: fieldTypes.slice(0, 10),
        buttons: buttonLabels.slice(0, 3),
        action: action.substring(0, 256),
        method: (form.method || "get").toUpperCase(),
      });
    }

    if (formSummaries.length === 0) return;

    // Detect if page is on a free hosting platform
    var domain = getDomain();
    var domainReg = getRegistrableDomain(domain);
    var freeHosting = null;
    var FREE_HOSTING = [
      "weebly.com", "wixsite.com", "wix.com", "sites.google.com", "blogspot.com",
      "wordpress.com", "000webhostapp.com", "netlify.app", "vercel.app",
      "herokuapp.com", "firebaseapp.com", "web.app", "pages.dev",
      "glitch.me", "replit.dev", "github.io", "gitlab.io", "framer.app",
      "carrd.co", "webflow.io", "squarespace.com", "jimdo.com", "strikingly.com",
    ];
    for (var h = 0; h < FREE_HOSTING.length; h++) {
      if (domainReg === FREE_HOSTING[h] || domain.endsWith("." + FREE_HOSTING[h])) {
        freeHosting = FREE_HOSTING[h];
        break;
      }
    }

    formsReported = true;
    console.log("[Phishing Guard] Found " + formSummaries.length + " forms on " + getDomain() + (freeHosting ? " (free hosting: " + freeHosting + ")" : ""));

    var payload = buildAnalysisPayload("form-present");
    payload.formSummaries = formSummaries;
    if (freeHosting) payload.freeHostingPlatform = freeHosting;
    requestLLMAnalysis(payload);
  }

  function getDomain() {
    try {
      return new URL(window.location.href).hostname;
    } catch (_) {
      return window.location.hostname;
    }
  }

  function getRegistrableDomain(hostname) {
    var h = hostname.replace(/^www\./, "");
    var parts = h.split(".");
    if (parts.length <= 2) return h;
    var twoPartTLDs = [
      "co.uk", "org.uk", "com.au", "co.jp", "co.kr", "co.nz",
      "com.br", "com.mx", "co.in", "co.za", "com.cn", "com.tw",
      "co.id", "com.sg", "com.ar", "com.co", "com.tr", "com.hk",
    ];
    var lastTwo = parts.slice(-2).join(".");
    if (twoPartTLDs.indexOf(lastTwo) !== -1) return parts.slice(-3).join(".");
    return parts.slice(-2).join(".");
  }

  /**
   * Collect cross-domain form action URLs from forms containing password fields.
   */
  function getFormActionDomains() {
    var domains = [];
    var pageDomain = getDomain();
    var pageReg = getRegistrableDomain(pageDomain);
    var forms = document.querySelectorAll("form");

    for (var i = 0; i < forms.length; i++) {
      var form = forms[i];
      if (!form.querySelector('input[type="password"]')) continue;

      // Check form action
      var action = form.getAttribute("action");
      if (action && action !== "" && action !== "#" && !action.startsWith("javascript:")) {
        try {
          var url = new URL(action, window.location.href);
          if (getRegistrableDomain(url.hostname) !== pageReg) {
            domains.push(url.hostname);
          }
        } catch (_) {}
      }

      // Check submit buttons with formaction
      var buttons = form.querySelectorAll("[formaction]");
      for (var j = 0; j < buttons.length; j++) {
        try {
          var btnUrl = new URL(buttons[j].getAttribute("formaction"), window.location.href);
          if (getRegistrableDomain(btnUrl.hostname) !== pageReg) {
            domains.push(btnUrl.hostname);
          }
        } catch (_) {}
      }
    }

    // Deduplicate
    return domains.filter(function (d, i) { return domains.indexOf(d) === i; });
  }

  function reportPasswordField() {
    console.log("[Phishing Guard] reportPasswordField called, reported=" + reported);
    if (reported) return;
    reported = true;

    var formActionDomains = getFormActionDomains();

    chrome.runtime.sendMessage(
      {
        type: "passwordFieldDetected",
        url: window.location.href,
        domain: getDomain(),
        formActionDomains: formActionDomains,
      },
      function (response) {
        console.log("[Phishing Guard] passwordFieldDetected response:", JSON.stringify(response), "lastError:", chrome.runtime.lastError?.message);
        if (!response) return;
        if (response.verdict === "unknown") {
          showWarningBanner(response.domain, null);
          // Fire async LLM analysis for unknown domains
          var payload = buildAnalysisPayload("password-field");
          chrome.runtime.sendMessage({ type: "analyzeWithLLM", payload: payload });
        } else if (response.verdict === "cross-domain") {
          showWarningBanner(response.domain, response.actionDomain);
          var payload2 = buildAnalysisPayload("password-field");
          chrome.runtime.sendMessage({ type: "analyzeWithLLM", payload: payload2 });
        }
        // "blocked" is handled by background.js (redirects to blocked.html)
        // "safe" needs no action
      }
    );
  }

  // -------------------------------------------------------------------------
  // Warning banner injected into the page
  // -------------------------------------------------------------------------

  function showWarningBanner(domain, actionDomain) {
    if (bannerElement) return;

    var message;
    if (actionDomain) {
      message =
        "This page at <strong>" + escapeHTML(domain) + "</strong> " +
        "will send your password to <strong>" + escapeHTML(actionDomain) + "</strong>, " +
        "a different site. Make sure this is expected before signing in.";
    } else {
      message =
        "This is the first time you\u2019re entering a password on " +
        "<strong>" + escapeHTML(domain) + "</strong>. " +
        "Make sure you recognize this site before signing in.";
    }

    var banner = document.createElement("div");
    banner.id = "bromure-phishing-banner";
    banner.setAttribute(
      "style",
      [
        "position: fixed",
        "top: 0",
        "left: 0",
        "right: 0",
        "z-index: 2147483647",
        "background: linear-gradient(135deg, #f59e0b, #d97706)",
        "color: #1a1a1a",
        "font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif",
        "font-size: 14px",
        "padding: 12px 20px",
        "display: flex",
        "align-items: center",
        "gap: 12px",
        "box-shadow: 0 2px 8px rgba(0,0,0,0.2)",
        "animation: bromure-slide-down 0.3s ease-out",
      ].join(";")
    );

    banner.innerHTML =
      '<span style="flex-shrink: 0; line-height: 0;"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="11" width="18" height="11" rx="2" ry="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg></span>' +
      '<span style="flex: 1;">' + message + '</span>' +
      '<button id="bromure-trust-btn" style="' +
        "background: rgba(255,255,255,0.5);" +
        "border: 1px solid rgba(0,0,0,0.15);" +
        "color: #1a1a1a;" +
        "padding: 6px 14px;" +
        "border-radius: 4px;" +
        "cursor: pointer;" +
        "font-size: 13px;" +
        "white-space: nowrap;" +
        "flex-shrink: 0;" +
      '">I know this site</button>' +
      '<button id="bromure-dismiss-btn" style="' +
        "background: none;" +
        "border: none;" +
        "color: rgba(0,0,0,0.5);" +
        "cursor: pointer;" +
        "font-size: 18px;" +
        "padding: 0 4px;" +
        "flex-shrink: 0;" +
      '">&times;</button>';

    // Add slide-down animation
    var style = document.createElement("style");
    style.textContent =
      "@keyframes bromure-slide-down {" +
      "  from { transform: translateY(-100%); opacity: 0; }" +
      "  to { transform: translateY(0); opacity: 1; }" +
      "}";
    document.documentElement.appendChild(style);
    document.documentElement.appendChild(banner);
    bannerElement = banner;

    // Push page content down so banner doesn't overlap
    document.body.style.marginTop =
      (parseInt(getComputedStyle(document.body).marginTop) || 0) +
      banner.offsetHeight +
      "px";

    // Button handlers
    document.getElementById("bromure-trust-btn").addEventListener(
      "click",
      function () {
        chrome.runtime.sendMessage({
          type: "trustDomain",
          domain: domain,
        });
        removeBanner();
      }
    );

    document.getElementById("bromure-dismiss-btn").addEventListener(
      "click",
      function () {
        removeBanner();
      }
    );
  }

  function removeBanner() {
    if (bannerElement) {
      var height = bannerElement.offsetHeight;
      bannerElement.remove();
      bannerElement = null;
      // Restore body margin
      var currentMargin = parseInt(getComputedStyle(document.body).marginTop) || 0;
      document.body.style.marginTop =
        Math.max(0, currentMargin - height) + "px";
    }
  }

  function escapeHTML(str) {
    var div = document.createElement("div");
    div.textContent = str;
    return div.innerHTML;
  }

  // -------------------------------------------------------------------------
  // Form submit interceptor — safety net for cross-domain password posts
  // -------------------------------------------------------------------------

  document.addEventListener("submit", function (e) {
    var form = e.target;
    if (!(form instanceof HTMLFormElement)) return;
    if (!form.querySelector('input[type="password"]')) return;
    if (approvedForms.has(form)) return;

    // Determine effective action (formaction on submitter overrides form action)
    var actionUrl;
    if (e.submitter && e.submitter.hasAttribute("formaction")) {
      actionUrl = e.submitter.formAction;
    } else {
      actionUrl = form.action;
    }
    if (!actionUrl) return;

    try {
      var actionHost = new URL(actionUrl).hostname;
      var pageHost = getDomain();
      if (getRegistrableDomain(actionHost) === getRegistrableDomain(pageHost)) return;
    } catch (_) {
      return;
    }

    // Cross-domain submit — check with background if it's an auth provider
    e.preventDefault();
    var savedSubmitter = e.submitter;

    chrome.runtime.sendMessage(
      { type: "checkFormAction", actionDomain: actionHost },
      function (response) {
        if (response && response.isAuthProvider) {
          approvedForms.add(form);
          form.requestSubmit(savedSubmitter);
          return;
        }
        showSubmitConfirmation(form, savedSubmitter, pageHost, actionHost);
      }
    );
  }, true);

  function showSubmitConfirmation(form, submitter, pageDomain, actionDomain) {
    var overlay = document.createElement("div");
    overlay.setAttribute("style", [
      "position: fixed",
      "top: 0", "left: 0", "right: 0", "bottom: 0",
      "z-index: 2147483647",
      "background: rgba(0,0,0,0.5)",
      "display: flex",
      "align-items: center",
      "justify-content: center",
      "font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif",
    ].join(";"));

    overlay.innerHTML =
      '<div style="' +
        "background: white; border-radius: 12px; padding: 24px; max-width: 440px;" +
        "box-shadow: 0 8px 32px rgba(0,0,0,0.3); color: #1a1a1a;" +
      '">' +
        '<div style="text-align: center; margin-bottom: 12px;"><svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="#c2410c" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/></svg></div>' +
        '<p style="font-size: 15px; line-height: 1.5; margin: 0 0 8px;">' +
          "This page at <strong>" + escapeHTML(pageDomain) + "</strong> " +
          "is about to send your password to:" +
        "</p>" +
        '<p style="font-size: 17px; font-weight: 600; text-align: center; ' +
          'color: #c2410c; margin: 8px 0 16px;">' + escapeHTML(actionDomain) + "</p>" +
        '<p style="font-size: 14px; color: #666; margin: 0 0 20px;">This is a different site. Only continue if you trust this destination.</p>' +
        '<div style="display: flex; gap: 10px; justify-content: flex-end;">' +
          '<button id="bromure-xd-cancel" style="' +
            "padding: 8px 20px; border-radius: 6px; border: 1px solid #ccc;" +
            "background: white; cursor: pointer; font-size: 14px;" +
          '">Cancel</button>' +
          '<button id="bromure-xd-continue" style="' +
            "padding: 8px 20px; border-radius: 6px; border: none;" +
            "background: #f59e0b; color: white; cursor: pointer; font-size: 14px;" +
          '">Continue</button>' +
        "</div>" +
      "</div>";

    document.documentElement.appendChild(overlay);

    overlay.querySelector("#bromure-xd-cancel").onclick = function () {
      overlay.remove();
    };
    overlay.querySelector("#bromure-xd-continue").onclick = function () {
      overlay.remove();
      approvedForms.add(form);
      form.requestSubmit(submitter);
    };
  }

  // -------------------------------------------------------------------------
  // Password field detection
  // -------------------------------------------------------------------------

  function checkForPasswordFields(root) {
    var inputs = (root || document).querySelectorAll('input[type="password"]');
    console.log("[Phishing Guard] checkForPasswordFields: found " + inputs.length + " password fields on " + getDomain());
    if (inputs.length > 0) {
      reportPasswordField();
    }
  }

  // Check existing DOM
  checkForPasswordFields();

  // Scan for scam content, suspicious links, forms, and QR codes.
  // Delayed slightly to let the page finish rendering.
  setTimeout(scanForScamContent, 1500);
  setTimeout(scanForSuspiciousLinks, 2000);
  setTimeout(scanForForms, 1500);
  // QR runs last — decoding pixels is the most expensive pass and it's
  // common for QR images to lazy-load after first paint.
  setTimeout(scanForQRCodes, 2500);

  // Re-scan for SPAs that render content after initial load.
  // Watch for significant DOM changes and re-run link + scam scanners.
  var rescanTimer = null;
  var scanObserver = new MutationObserver(function () {
    if (linksReported && scamReported && formsReported && qrReported) {
      scanObserver.disconnect();
      return;
    }
    // Debounce: wait for DOM to settle before re-scanning
    if (rescanTimer) clearTimeout(rescanTimer);
    rescanTimer = setTimeout(function () {
      scanForSuspiciousLinks();
      scanForScamContent();
      scanForForms();
      scanForQRCodes();
    }, 1000);
  });
  scanObserver.observe(document.body || document.documentElement, {
    childList: true,
    subtree: true,
  });

  if (reported) return;

  // Watch for dynamically added password fields
  var observer = new MutationObserver(function (mutations) {
    if (reported) {
      observer.disconnect();
      return;
    }

    for (var m = 0; m < mutations.length; m++) {
      var mutation = mutations[m];
      for (var n = 0; n < mutation.addedNodes.length; n++) {
        var node = mutation.addedNodes[n];
        if (node.nodeType !== Node.ELEMENT_NODE) continue;

        if (node.tagName === "INPUT" && node.type === "password") {
          reportPasswordField();
          observer.disconnect();
          return;
        }

        if (node.querySelectorAll) {
          var inputs = node.querySelectorAll('input[type="password"]');
          if (inputs.length > 0) {
            reportPasswordField();
            observer.disconnect();
            return;
          }
        }
      }

      if (
        mutation.type === "attributes" &&
        mutation.attributeName === "type" &&
        mutation.target.tagName === "INPUT" &&
        mutation.target.type === "password"
      ) {
        reportPasswordField();
        observer.disconnect();
        return;
      }
    }
  });

  observer.observe(document.documentElement, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["type"],
  });

  // -------------------------------------------------------------------------
  // Listen for LLM verdict updates from background.js
  // -------------------------------------------------------------------------

  chrome.runtime.onMessage.addListener(function (message) {
    if (message.type === "llmVerdict") {
      removeAnalyzingBanner();
      if (message.verdict === "phishing") {
        removeBanner();
        showPhishingBanner(message.reason || "This page has been identified as a phishing attempt.");
        // background.js also handles redirect to blocked.html
      } else if (message.verdict === "suspicious") {
        removeBanner();
        showSuspiciousBanner(message.reason || "This page has suspicious characteristics.", message.confidence || 0.5);
      } else if (message.verdict === "safe") {
        removeBanner();
        // Optionally flash a brief "verified safe" indicator
      }
    }

    if (message.type === "llmServiceStatus") {
      removeAnalyzingBanner();
      showServiceStatusBanner(message.status, message.reason);
    }
  });

  // -------------------------------------------------------------------------
  // LLM verdict banners
  // -------------------------------------------------------------------------

  function showPhishingBanner(reason) {
    if (bannerElement) removeBanner();

    var banner = document.createElement("div");
    banner.id = "bromure-phishing-banner";
    banner.setAttribute("style", [
      "position: fixed", "top: 0", "left: 0", "right: 0",
      "z-index: 2147483647",
      "background: linear-gradient(135deg, #dc2626, #b91c1c)",
      "color: white",
      "font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif",
      "font-size: 14px", "padding: 14px 20px",
      "display: flex", "align-items: center", "gap: 12px",
      "box-shadow: 0 2px 8px rgba(0,0,0,0.3)",
    ].join(";"));

    banner.innerHTML =
      '<span style="flex-shrink: 0; line-height: 0;"><svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10.29 3.86L1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/></svg></span>' +
      '<span style="flex: 1;"><strong>Phishing detected</strong> &mdash; ' + escapeHTML(reason) + '</span>' +
      '<button id="bromure-dismiss-btn" style="' +
        "background: rgba(255,255,255,0.2); border: 1px solid rgba(255,255,255,0.3);" +
        "color: white; padding: 6px 14px; border-radius: 4px; cursor: pointer;" +
        "font-size: 13px; white-space: nowrap; flex-shrink: 0;" +
      '">Dismiss</button>';

    document.documentElement.appendChild(banner);
    bannerElement = banner;
    document.body.style.marginTop =
      (parseInt(getComputedStyle(document.body).marginTop) || 0) + banner.offsetHeight + "px";

    document.getElementById("bromure-dismiss-btn").addEventListener("click", function () {
      removeBanner();
    });
  }

  function showSuspiciousBanner(reason, confidence) {
    if (bannerElement) removeBanner();

    // Interpolate color from yellow (low confidence) to red-orange (high confidence)
    // 0.4 → hue 45 (yellow-amber), 0.84 → hue 15 (red-orange)
    var t = Math.max(0, Math.min(1, (confidence - 0.4) / 0.44));
    var hue = Math.round(45 - t * 30); // 45 → 15
    var sat = Math.round(90 + t * 10); // 90% → 100%
    var bg1 = "hsl(" + hue + ", " + sat + "%, 55%)";
    var bg2 = "hsl(" + (hue - 5) + ", " + sat + "%, 45%)";

    var banner = document.createElement("div");
    banner.id = "bromure-phishing-banner";
    banner.setAttribute("style", [
      "position: fixed", "top: 0", "left: 0", "right: 0",
      "z-index: 2147483647",
      "background: linear-gradient(135deg, " + bg1 + ", " + bg2 + ")",
      "color: #1a1a1a",
      "font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif",
      "font-size: 14px", "padding: 12px 20px",
      "display: flex", "align-items: center", "gap: 12px",
      "box-shadow: 0 2px 8px rgba(0,0,0,0.2)",
    ].join(";"));

    banner.innerHTML =
      '<span style="flex-shrink: 0; line-height: 0;"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="11" cy="11" r="8"/><line x1="21" y1="21" x2="16.65" y2="16.65"/></svg></span>' +
      '<span style="flex: 1;"><strong>Suspicious page</strong> &mdash; ' + escapeHTML(reason) + '</span>' +
      '<button id="bromure-trust-btn" style="' +
        "background: rgba(255,255,255,0.5); border: 1px solid rgba(0,0,0,0.15);" +
        "color: #1a1a1a; padding: 6px 14px; border-radius: 4px; cursor: pointer;" +
        "font-size: 13px; white-space: nowrap; flex-shrink: 0;" +
      '">I know this site</button>' +
      '<button id="bromure-dismiss-btn" style="' +
        "background: none; border: none; color: rgba(0,0,0,0.5);" +
        "cursor: pointer; font-size: 18px; padding: 0 4px; flex-shrink: 0;" +
      '">&times;</button>';

    document.documentElement.appendChild(banner);
    bannerElement = banner;
    document.body.style.marginTop =
      (parseInt(getComputedStyle(document.body).marginTop) || 0) + banner.offsetHeight + "px";

    document.getElementById("bromure-trust-btn").addEventListener("click", function () {
      chrome.runtime.sendMessage({ type: "trustDomain", domain: getDomain() });
      removeBanner();
    });
    document.getElementById("bromure-dismiss-btn").addEventListener("click", function () {
      removeBanner();
    });
  }

  // -------------------------------------------------------------------------
  // Service status banner (rate limit / degraded mode)
  // -------------------------------------------------------------------------

  // -------------------------------------------------------------------------
  // "Analyzing..." banner — shown while waiting for LLM verdict
  // -------------------------------------------------------------------------

  var analyzingBannerElement = null;

  function showAnalyzingBanner() {
    if (analyzingBannerElement || bannerElement) return; // don't stack on existing banners

    var banner = document.createElement("div");
    banner.id = "bromure-analyzing-banner";
    banner.setAttribute("style", [
      "position: fixed", "top: 0", "left: 0", "right: 0",
      "z-index: 2147483646",
      "background: linear-gradient(135deg, #6b7280, #4b5563)",
      "color: white",
      "font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif",
      "font-size: 13px", "padding: 8px 16px",
      "display: flex", "align-items: center", "gap: 10px",
      "box-shadow: 0 2px 6px rgba(0,0,0,0.15)",
    ].join(";"));

    banner.innerHTML =
      '<span style="flex-shrink: 0; line-height: 0;"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="animation: bromure-spin 1s linear infinite;"><path d="M21 12a9 9 0 1 1-6.219-8.56"/></svg></span>' +
      '<span style="flex: 1; opacity: 0.9;">Analyzing page safety\u2026</span>';

    var style = document.createElement("style");
    style.textContent = "@keyframes bromure-spin { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }";
    document.documentElement.appendChild(style);
    document.documentElement.appendChild(banner);
    analyzingBannerElement = banner;
  }

  function removeAnalyzingBanner() {
    if (analyzingBannerElement) {
      analyzingBannerElement.remove();
      analyzingBannerElement = null;
    }
  }

  var statusBannerElement = null;

  function showServiceStatusBanner(status, reason) {
    if (statusBannerElement) return; // already showing

    var bgColor = status === "degraded"
      ? "linear-gradient(135deg, #6366f1, #4f46e5)"
      : "linear-gradient(135deg, #f97316, #ea580c)";

    var icon = status === "degraded"
      ? '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/></svg>'
      : '<svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg>';

    var banner = document.createElement("div");
    banner.id = "bromure-status-banner";
    banner.setAttribute("style", [
      "position: fixed",
      "bottom: 0",
      "left: 0",
      "right: 0",
      "z-index: 2147483646",
      "background: " + bgColor,
      "color: white",
      "font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif",
      "font-size: 13px",
      "padding: 8px 16px",
      "display: flex",
      "align-items: center",
      "gap: 8px",
      "box-shadow: 0 -2px 8px rgba(0,0,0,0.15)",
    ].join(";"));

    banner.innerHTML =
      '<span style="font-size: 16px; flex-shrink: 0;">' + icon + '</span>' +
      '<span style="flex: 1; opacity: 0.95;">' + escapeHTML(reason) +
        ' Heuristic protection remains active.</span>' +
      '<button id="bromure-status-dismiss" style="' +
        "background: none; border: none; color: rgba(255,255,255,0.7);" +
        "cursor: pointer; font-size: 16px; padding: 0 4px; flex-shrink: 0;" +
      '">&times;</button>';

    document.documentElement.appendChild(banner);
    statusBannerElement = banner;

    document.getElementById("bromure-status-dismiss").addEventListener("click", function () {
      if (statusBannerElement) {
        statusBannerElement.remove();
        statusBannerElement = null;
      }
    });

    // Auto-dismiss after 15 seconds
    setTimeout(function () {
      if (statusBannerElement) {
        statusBannerElement.remove();
        statusBannerElement = null;
      }
    }, 15000);
  }
})();
