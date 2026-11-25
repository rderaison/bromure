// The Bromure Firewall's pf-style rules ⇄ editor rows — a TypeScript port of
// SandboxEngine/EgressPolicy.swift's parse / editRows / pfText (the subset
// the editor needs; the host re-validates every commit).

export interface EditRow {
  id: string;
  action: string; proto: string; host: string; ports: string; methods: string;
  enabled: boolean; expiresAt: number | null; untilStop: boolean;   // expiresAt: unix seconds
}

export class ParseError extends Error { constructor(readonly line: number, msg: string) { super(msg); } }

const PROTOS = ['tcp', 'udp', 'web', 'any'];
let n = 0;
export const newRow = (r: Partial<EditRow> = {}): EditRow => ({
  id: `r${++n}`, action: 'allow', proto: 'tcp', host: 'any', ports: '', methods: '',
  enabled: true, expiresAt: null, untilStop: false, ...r,
});

/** Split a raw line into its rule text and the Bromure annotations
 *  (`#@off …`, `#@until=<secs>|stop`). */
function annotations(raw: string) {
  let body = raw, enabled = true;
  const lead = raw.replace(/^[ \t]+/, '');
  if (lead.startsWith('#@off')) {
    const rest = lead.slice(5);
    if (!rest || rest[0] === ' ' || rest[0] === '\t') { enabled = false; body = rest; }
  }
  let expiresAt: number | null = null, untilStop = false;
  const h = body.indexOf('#');
  if (h >= 0 && body[h + 1] === '@') {
    for (const tok of body.slice(h + 2).split(/[ \t]+/)) {
      const t = tok.toLowerCase();
      if (!t.startsWith('until=')) continue;
      const v = t.slice(6);
      if (v === 'stop') untilStop = true; else if (v && !isNaN(+v)) expiresAt = +v;
    }
  }
  return { body, enabled, expiresAt, untilStop };
}

function parseIPv4(s: string): number | null {
  const o = s.split('.');
  if (o.length !== 4) return null;
  let v = 0;
  for (const p of o) {
    if (!/^\d{1,3}$/.test(p) || (p.length > 1 && p[0] === '0') || +p > 255) return null;
    v = v * 256 + +p;
  }
  return v;
}

function parsePorts(s: string, line: number): string {
  const t = s.toLowerCase();
  if (!t || t === '*' || t === 'any') return '';
  const out: string[] = [];
  for (const part of s.split(',')) {
    const b = part.split('-');
    const ok = (x: string) => /^\d+$/.test(x) && +x <= 65535;
    if (b.length === 2 && ok(b[0]) && ok(b[1]) && +b[0] <= +b[1]) out.push(+b[0] === +b[1] ? `${+b[0]}` : `${+b[0]}-${+b[1]}`);
    else if (b.length === 1 && ok(b[0])) out.push(`${+b[0]}`);
    else throw new ParseError(line, `bad port '${part}'`);
  }
  return out.join(',');
}

function parseTarget(tok: string, line: number): { host: string; ports: string } {
  let hostPart = tok, ports = '';
  const c = tok.lastIndexOf(':');
  if (c >= 0) { hostPart = tok.slice(0, c); ports = parsePorts(tok.slice(c + 1), line); }
  const lp = hostPart.toLowerCase();
  if (lp === 'any' || lp === '*') return { host: 'any', ports };
  if (hostPart.includes('/')) {
    const [ip, bits] = hostPart.split('/');
    const v = parseIPv4(ip ?? '');
    if (v == null || !/^\d+$/.test(bits ?? '') || +bits > 32 || hostPart.split('/').length !== 2) throw new ParseError(line, `bad CIDR '${hostPart}'`);
    const mask = +bits === 0 ? 0 : (0xFFFFFFFF << (32 - +bits)) >>> 0;
    const net = (v & mask) >>> 0;
    const str = [24, 16, 8, 0].map(s => (net >>> s) & 255).join('.');
    return { host: +bits === 32 ? str : `${str}/${+bits}`, ports };
  }
  if (parseIPv4(hostPart) != null) return { host: hostPart, ports };
  return { host: lp.replace(/\.+$/, ''), ports };
}

function parseMethods(toks: string[], line: number): string {
  let parts = toks;
  if (parts[0]?.toLowerCase() === 'methods') parts = parts.slice(1);
  if (parts.length === 1 && parts[0].toLowerCase() === 'read-only') return 'read-only';
  const list = parts.join('').split(',').map(s => s.trim().toUpperCase()).filter(Boolean);
  if (!list.length) throw new ParseError(line, 'expected HTTP methods (e.g. GET,POST) or \'read-only\'');
  for (const m of list) if (!/^[A-Z]+$/.test(m)) throw new ParseError(line, `bad HTTP method '${m}'`);
  return list.join(',');
}

export interface Parsed { defaultAllow: boolean; rows: EditRow[] }

/** EgressPolicy.parse + editRows. Throws ParseError. */
export function parseRules(text: string): Parsed {
  const rows: EditRow[] = [];
  let defaultAllow = true;
  text.split('\n').forEach((raw, i) => {
    const ann = annotations(raw);
    const h = ann.body.indexOf('#');
    const line = h >= 0 ? ann.body.slice(0, h) : ann.body;
    const toks = line.split(/[ \t]+/).filter(Boolean);
    if (!toks.length) return;
    const ln = i + 1;
    if (toks[0].toLowerCase() === 'default') {
      if (!ann.enabled) return;
      const d = toks[1]?.toLowerCase();
      if (toks.length !== 2 || (d !== 'allow' && d !== 'deny')) throw new ParseError(ln, 'expected \'default allow\' or \'default deny\'');
      defaultAllow = d === 'allow';
      return;
    }
    const action = toks[0].toLowerCase();
    if (action !== 'allow' && action !== 'deny') throw new ParseError(ln, `unknown action '${toks[0]}' (allow / deny)`);
    let idx = 1, proto = 'any';
    if (idx < toks.length && PROTOS.includes(toks[idx].toLowerCase())) { proto = toks[idx].toLowerCase(); idx++; }
    if (idx >= toks.length) throw new ParseError(ln, 'missing target host / IP / CIDR');
    const { host, ports } = parseTarget(toks[idx], ln);
    idx++;
    let methods = '';
    if (idx < toks.length) {
      if (proto !== 'web') throw new ParseError(ln, 'HTTP methods apply only to \'web\' rules');
      methods = parseMethods(toks.slice(idx), ln);
    }
    rows.push(newRow({ action, proto, host, ports, methods, enabled: ann.enabled, expiresAt: ann.expiresAt, untilStop: ann.untilStop }));
  });
  return { defaultAllow, rows };
}

export function validationError(text: string): string | null {
  try { parseRules(text); return null; }
  catch (e) { return e instanceof ParseError ? `Line ${e.line}: ${e.message}` : String(e); }
}

function annotate(code: string, r: EditRow) {
  let line = code;
  if (r.untilStop) line += ' #@until=stop';
  else if (r.expiresAt != null) line += ` #@until=${Math.floor(r.expiresAt)}`;
  return r.enabled ? line : '#@off ' + line;
}

/** The row as one pf rule (no annotations). */
export function ruleText(r: EditRow) {
  const parts = [r.action, r.proto || 'any'];
  const ports = r.ports.trim(), host = r.host.trim();
  parts.push(!ports || ports === 'any' ? host : `${host}:${ports}`);
  if (r.proto === 'web' && r.methods) parts.push(r.methods);
  return parts.join(' ');
}

/** EgressPolicy.pfText(rows:defaultAllow:). */
export function pfText(rows: EditRow[], defaultAllow: boolean): string {
  const lines = rows.flatMap(r => {
    const host = r.host.trim();
    if (!host) return [];
    const proto = r.proto.trim() || 'any';
    const parts = [r.action, proto];
    const ports = r.ports.trim();
    const anyPort = !ports || ports.toLowerCase() === 'any' || ports === '*';
    parts.push(anyPort ? host : `${host}:${ports}`);
    const m = r.methods.trim();
    if (proto === 'web' && m) parts.push(m);
    return [annotate(parts.join(' '), r)];
  });
  lines.push(`default ${defaultAllow ? 'allow' : 'deny'}`);
  return lines.join('\n');
}

/** "14m" / "1h 05m" / "45s" — rounded up. */
export function remaining(seconds: number): string {
  const s = Math.max(0, Math.ceil(seconds));
  if (s < 60) return `${s}s`;
  const m = Math.floor((s + 59) / 60);
  if (m < 60) return `${m}m`;
  return `${Math.floor(m / 60)}h ${String(m % 60).padStart(2, '0')}m`;
}

/** The ruleset is in force at all ("Log allowed connections" automatic value). */
export function isActive(text: string) {
  try { const p = parseRules(text); return !p.defaultAllow || p.rows.length > 0; } catch { return false; }
}
