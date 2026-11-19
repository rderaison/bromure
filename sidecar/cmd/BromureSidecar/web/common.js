// Shared by the flyout and the Agents window.
"use strict";

if (window.ENV && window.ENV.backdrop) document.documentElement.classList.add("backdrop");
document.addEventListener("DOMContentLoaded", () => {
  if (window.ENV && window.ENV.backdrop) document.body.classList.add("backdrop");
});

// The agents, as the macOS Sidecar shows them (AgentSpec: tints).
const AGENTS = [
  { id: "claude", name: "Claude Code", maker: "Anthropic", tint: "#D97857" },
  { id: "codex", name: "Codex", maker: "OpenAI", tint: "#2A2A31" },
  { id: "grok", name: "Grok Build", maker: "xAI", tint: "#46464D" },
  { id: "kimi", name: "Kimi Code", maker: "Moonshot AI", tint: "#1F73F2" },
  { id: "omp", name: "Oh My Pi", maker: "Open source", tint: "#179966" },
];
const agentById = Object.fromEntries(AGENTS.map(a => [a.id, a]));

// One control-socket request through the native bridge: the reply body,
// or throws with the daemon's error text.
async function api(method, path, body) {
  const r = await window.sidecarRequest(method, path, body === undefined ? null : body);
  if (!r || !r.status) throw new Error((r && r.error) || "Bromure Sidecar isn't running");
  if (r.status >= 400) throw new Error((r.body && r.body.error) || ("HTTP " + r.status));
  return r.body || {};
}

function h(html) {
  const t = document.createElement("template");
  t.innerHTML = html.trim();
  return t.content.firstElementChild;
}

function esc(s) {
  return String(s == null ? "" : s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

function logoTile(id, cls = "") {
  const a = agentById[id] || { tint: "#5866FE" };
  return `<div class="logo ${cls}" style="--tint:${a.tint}">${(window.SVG || {})[id] || ""}</div>`;
}

function markTile(cls = "") {
  return `<div class="mark-tile ${cls}">${(window.SVG || {}).mark || ""}</div>`;
}

// Fluent-style line icons (16-24 viewbox), drawn here so the app ships no
// icon font.
const ICON = {
  grid: '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linejoin="round"><rect x="3" y="3" width="5.5" height="5.5" rx="1.6"/><rect x="11.5" y="3" width="5.5" height="5.5" rx="1.6"/><rect x="3" y="11.5" width="5.5" height="5.5" rx="1.6"/><rect x="11.5" y="11.5" width="5.5" height="5.5" rx="1.6"/></svg>',
  more: '<svg viewBox="0 0 20 20" fill="currentColor"><circle cx="5" cy="10" r="1.5"/><circle cx="10" cy="10" r="1.5"/><circle cx="15" cy="10" r="1.5"/></svg>',
  plus: '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><path d="M10 4v12M4 10h12"/></svg>',
  power: '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"><path d="M10 3v6.5"/><path d="M6.2 5.6a6 6 0 1 0 7.6 0"/></svg>',
  terminal: '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><rect x="2.5" y="3.5" width="15" height="13" rx="3"/><path d="M6 8l2.5 2L6 12M10.5 12.5H14"/></svg>',
  folder: '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"><path d="M2.8 6.2c0-1 .8-1.7 1.7-1.7h3.2l1.7 1.8h6.1c.9 0 1.7.8 1.7 1.7v6.3c0 1-.8 1.7-1.7 1.7H4.5c-.9 0-1.7-.8-1.7-1.7z"/></svg>',
  up: '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M10 15V5M5.5 9.5 10 5l4.5 4.5"/></svg>',
  back: '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4.5 6.5 10l5.5 5.5"/></svg>',
  link: '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"><path d="M8.5 11.5a3 3 0 0 0 4.2 0l2.6-2.6a3 3 0 0 0-4.2-4.2l-.9.9"/><path d="M11.5 8.5a3 3 0 0 0-4.2 0l-2.6 2.6a3 3 0 0 0 4.2 4.2l.9-.9"/></svg>',
  copy: '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linejoin="round"><rect x="7" y="7" width="9.5" height="9.5" rx="2.2"/><path d="M13 4.6A1.7 1.7 0 0 0 11.4 3.5H5.2c-.9 0-1.7.8-1.7 1.7v6.2c0 .7.5 1.4 1.1 1.6"/></svg>',
  check: '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M4.5 10.5l3.5 3.5 7.5-8"/></svg>',
  warn: '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M10 3.2 17.5 16H2.5z"/><path d="M10 8v3.5M10 13.8v.1"/></svg>',
  globe: '<svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.5"><circle cx="10" cy="10" r="7"/><path d="M3 10h14M10 3c2 2.2 2.8 4.5 2.8 7s-.8 4.8-2.8 7c-2-2.2-2.8-4.5-2.8-7S8 5.2 10 3z"/></svg>',
};

function toast(text, ms = 1800) {
  const t = h(`<div class="toast">${esc(text)}</div>`);
  document.body.appendChild(t);
  setTimeout(() => t.remove(), ms);
}

async function copyText(text, label) {
  try { await window.sidecarCopy(text); toast(label || "Copied"); } catch (e) { toast("Couldn't copy"); }
}

function relTime(epochSeconds) {
  if (!epochSeconds) return "";
  const s = Math.max(0, Date.now() / 1000 - epochSeconds);
  if (s < 60) return "just now";
  if (s < 3600) return Math.floor(s / 60) + " min";
  if (s < 86400) return Math.floor(s / 3600) + " h";
  return Math.floor(s / 86400) + " d";
}

// Diagnostics: a script error on the page goes to the Sidecar log.
window.addEventListener("error", e => { try { window.sidecarPing && window.sidecarPing("error: " + e.message); } catch (_) {} });