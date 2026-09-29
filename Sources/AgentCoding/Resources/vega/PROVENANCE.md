# Vega / Vega-Lite / vega-embed

UMD browser bundles (expose `window.vega`, `window.vegaLite`, `window.vegaEmbed`).

| File | Package | Version | SHA-256 |
|---|---|---|---|
| vega.min.js | vega (https://github.com/vega/vega) | 6.4.0 | 8f6a3587cf8d4f42c7e08120e3eb05d067e746d554e39d2dcf52acc0bd5ba28f |
| vega-lite.min.js | vega-lite (https://github.com/vega/vega-lite) | 6.4.3 | 35a9821df838825b05a6a73e9414b58747a1b18321583858ed903c66393a5c7e |
| vega-embed.min.js | vega-embed (https://github.com/vega/vega-embed) | 7.3.0 | b1455caba2fb1a72fb46025ba0ba1316e2dbc7f0dd40a3f6040172bf9c08ba91 |

- Source: the packages' `build/*.min.js`, installed from the npm registry through
  the Socket CLI (`socket npm install --ignore-scripts`, no risks reported).
- License: BSD-3-Clause (all three).
- Used by: the chat's chart cards (an agent's `show_chart` call) — a Vega-Lite spec
  rendered in an offline WKWebView (scripts injected, no network).

To upgrade: install the new pinned versions the same way, copy `build/*.min.js`,
and update the versions and SHA-256s here.
