// A small, tolerant YAML reader (block mappings/sequences, flow {…}/[…],
// quoted and plain scalars, comments) and the OpenShell policy checks the
// editor shows live — after OpenShellPolicy+Parse.swift. Not a full YAML
// implementation: the host parses the real thing and refuses a broken
// policy on Save; this only keeps the editor's Save/validation honest.

export type YNode =
  | { k: 'map'; line: number; entries: [string, YNode, number][] }
  | { k: 'seq'; line: number; items: YNode[] }
  | { k: 'scalar'; line: number; v: string; plain: boolean };

export class YamlError extends Error {
  constructor(readonly line: number | null, readonly path: string, message: string) {
    super(message);
  }
  override toString() {
    const loc = this.line != null ? `line ${this.line}: ` : '';
    return this.path ? `${loc}${this.path}: ${this.message}` : `${loc}${this.message}`;
  }
}

interface Line { indent: number; text: string; no: number }

function stripComment(s: string): string {
  let q: string | null = null;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) { if (c === q && s[i - 1] !== '\\') q = null; continue; }
    if (c === '"' || c === '\'') { if (i === 0 || /[\s:{[,\-]/.test(s[i - 1])) q = c; continue; }
    if (c === '#' && (i === 0 || /\s/.test(s[i - 1]))) return s.slice(0, i);
  }
  return s;
}

/** Index of the mapping colon in `s` (": " or trailing ":"), outside quotes/flow. */
function keyColon(s: string): number {
  let q: string | null = null, depth = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) { if (c === q) q = null; continue; }
    if ((c === '"' || c === '\'') && i === 0) { q = c; continue; }
    if (c === '{' || c === '[') depth++;
    else if (c === '}' || c === ']') depth--;
    else if (c === ':' && depth === 0 && (i === s.length - 1 || s[i + 1] === ' ' || s[i + 1] === '\t')) return i;
  }
  return -1;
}

type YScalar = Extract<YNode, { k: 'scalar' }>;
function unquote(s: string, line: number): YScalar {
  const t = s.trim();
  if (t.startsWith('"')) {
    if (!t.endsWith('"') || t.length < 2) throw new YamlError(line, '', 'invalid YAML: unterminated quoted string');
    return { k: 'scalar', line, v: t.slice(1, -1).replace(/\\"/g, '"').replace(/\\\\/g, '\\'), plain: false };
  }
  if (t.startsWith('\'')) {
    if (!t.endsWith('\'') || t.length < 2) throw new YamlError(line, '', 'invalid YAML: unterminated quoted string');
    return { k: 'scalar', line, v: t.slice(1, -1).replace(/''/g, '\''), plain: false };
  }
  return { k: 'scalar', line, v: t, plain: true };
}

function parseFlow(src: string, line: number): YNode {
  let i = 0;
  const ws = () => { while (i < src.length && /\s/.test(src[i])) i++; };
  const value = (): YNode => {
    ws();
    if (src[i] === '{') {
      i++; const entries: [string, YNode, number][] = [];
      ws();
      if (src[i] === '}') { i++; return { k: 'map', line, entries }; }
      for (;;) {
        ws();
        const key = scalarUntil(':');
        if (src[i] !== ':') throw new YamlError(line, '', 'invalid YAML: expected \':\' in flow mapping');
        i++;
        const v = valueUntil(',}');
        entries.push([key, v, line]);
        ws();
        if (src[i] === ',') { i++; continue; }
        if (src[i] === '}') { i++; return { k: 'map', line, entries }; }
        throw new YamlError(line, '', 'invalid YAML: unterminated flow mapping');
      }
    }
    if (src[i] === '[') {
      i++; const items: YNode[] = [];
      ws();
      if (src[i] === ']') { i++; return { k: 'seq', line, items }; }
      for (;;) {
        items.push(valueUntil(',]'));
        ws();
        if (src[i] === ',') { i++; continue; }
        if (src[i] === ']') { i++; return { k: 'seq', line, items }; }
        throw new YamlError(line, '', 'invalid YAML: unterminated flow sequence');
      }
    }
    return valueUntil(',}]');
  };
  const scalarUntil = (stop: string): string => {
    ws();
    if (src[i] === '"' || src[i] === '\'') {
      const q = src[i]; const start = i; i++;
      while (i < src.length && src[i] !== q) i++;
      i++;
      return unquote(src.slice(start, i), line).v as string;
    }
    const start = i;
    while (i < src.length && !stop.includes(src[i]) && !(src[i] === ':' && /\s/.test(src[i + 1] ?? ' '))) i++;
    return src.slice(start, i).trim();
  };
  const valueUntil = (stop: string): YNode => {
    ws();
    if (src[i] === '{' || src[i] === '[') return value();
    if (src[i] === '"' || src[i] === '\'') {
      const q = src[i]; const start = i; i++;
      while (i < src.length && src[i] !== q) i++;
      i++;
      return unquote(src.slice(start, i), line);
    }
    const start = i;
    while (i < src.length && !stop.includes(src[i])) i++;
    return { k: 'scalar', line, v: src.slice(start, i).trim(), plain: true };
  };
  const out = value();
  ws();
  if (i < src.length) throw new YamlError(line, '', 'invalid YAML: unexpected text after a flow collection');
  return out;
}

function inline(s: string, line: number): YNode {
  const t = s.trim();
  if (t.startsWith('{') || t.startsWith('[')) return parseFlow(t, line);
  if (t === '|' || t === '>' || /^[|>][-+]?$/.test(t)) return { k: 'scalar', line, v: '', plain: false };
  return unquote(t, line);
}

export function parseYaml(text: string): YNode | null {
  const raw = text.split('\n');
  const lines: Line[] = [];
  for (let i = 0; i < raw.length; i++) {
    const r = raw[i].replace(/\r$/, '');
    if (/^\s*\t/.test(r) && r.trim()) throw new YamlError(i + 1, '', 'invalid YAML: tabs are not allowed for indentation');
    const s = stripComment(r);
    if (!s.trim() || s.trim() === '---') continue;
    const indent = s.length - s.trimStart().length;
    let t = s.trim();
    const start = i + 1;
    // A flow collection spanning lines: join until brackets balance.
    const open = () => (t.match(/[{[]/g)?.length ?? 0) - (t.match(/[}\]]/g)?.length ?? 0);
    while (open() > 0 && i + 1 < raw.length) { i++; t += ' ' + stripComment(raw[i]).trim(); }
    lines.push({ indent, text: t, no: start });
  }
  let pos = 0;

  const block = (indent: number): YNode => {
    const L = lines[pos];
    if (L.text === '-' || L.text.startsWith('- ')) return seq(L.indent);
    return map(L.indent);
  };

  const seq = (indent: number): YNode => {
    const items: YNode[] = [];
    const line = lines[pos].no;
    while (pos < lines.length && lines[pos].indent === indent && (lines[pos].text === '-' || lines[pos].text.startsWith('- '))) {
      const L = lines[pos];
      const rest = L.text === '-' ? '' : L.text.slice(2).trimStart();
      if (!rest) {
        pos++;
        items.push(pos < lines.length && lines[pos].indent > indent ? block(lines[pos].indent) : { k: 'scalar', line: L.no, v: '', plain: true });
      } else if (!rest.startsWith('{') && !rest.startsWith('[') && keyColon(rest) > 0) {
        // "- key: value" starts a mapping at the item's column.
        const col = L.indent + (L.text.length - rest.length);
        lines[pos] = { indent: col, text: rest, no: L.no };
        items.push(map(col));
      } else {
        items.push(inline(rest, L.no));
        pos++;
      }
    }
    return { k: 'seq', line, items };
  };

  const map = (indent: number): YNode => {
    const entries: [string, YNode, number][] = [];
    const line = lines[pos].no;
    while (pos < lines.length && lines[pos].indent === indent) {
      const L = lines[pos];
      if (L.text === '-' || L.text.startsWith('- ')) throw new YamlError(L.no, '', 'invalid YAML: a list item where a key was expected');
      const c = keyColon(L.text);
      if (c <= 0) throw new YamlError(L.no, '', `invalid YAML: expected 'key: value', found '${L.text}'`);
      const key = unquote(L.text.slice(0, c), L.no).v;
      const rest = L.text.slice(c + 1).trim();
      pos++;
      let v: YNode;
      if (rest) {
        v = inline(rest, L.no);
        if (/^[|>]/.test(rest)) while (pos < lines.length && lines[pos].indent > indent) pos++;   // block scalar body
      } else if (pos < lines.length && (lines[pos].indent > indent
                 || (lines[pos].indent === indent && (lines[pos].text === '-' || lines[pos].text.startsWith('- '))))) {
        v = block(lines[pos].indent);
      } else v = { k: 'scalar', line: L.no, v: '', plain: true };
      if (entries.some(e => e[0] === key)) throw new YamlError(L.no, key, 'duplicate key');
      entries.push([key, v, L.no]);
    }
    if (pos < lines.length && lines[pos].indent > indent) throw new YamlError(lines[pos].no, '', 'invalid YAML: bad indentation');
    return { k: 'map', line, entries };
  };

  if (!lines.length) return null;
  const root = block(lines[0].indent);
  if (pos < lines.length) throw new YamlError(lines[pos].no, '', 'invalid YAML: bad indentation');
  return root;
}

// ── OpenShell policy checks ──────────────────────────────────────────────

export interface OpenShellCheck { rules: { key: string; binaries: string[] }[]; warnings: string[]; confinesGuest: boolean }

const isNull = (n?: YNode) => !n || (n.k === 'scalar' && n.plain && ['', '~', 'null', 'Null', 'NULL'].includes(n.v));
const get = (m: YNode, k: string) => m.k === 'map' ? m.entries.find(e => e[0] === k)?.[1] : undefined;

const ENDPOINT_FIELDS = new Set(['host', 'port', 'ports', 'path', 'allowed_ips', 'protocol', 'tls', 'enforcement', 'access',
  'rules', 'deny_rules', 'allow_encoded_slash', 'credential_binding', 'request_body_credential_rewrite', 'websocket_credential_rewrite',
  'allow_uninspected_credentials', 'credential_signing', 'signing_service', 'signing_region', 'persisted_queries',
  'graphql_persisted_queries', 'graphql_max_body_bytes', 'mcp', 'json_rpc']);

function mapping(n: YNode, path: string, allowed?: Set<string> | string[]): Map<string, YNode> {
  if (n.k !== 'map') throw new YamlError(n.line, path, 'expected a mapping');
  const set = allowed instanceof Set ? allowed : allowed ? new Set(allowed) : null;
  const out = new Map<string, YNode>();
  for (const [k, v, line] of n.entries) {
    if (set && !set.has(k)) throw new YamlError(line, path ? `${path}.${k}` : k, 'unknown field');
    out.set(k, v);
  }
  return out;
}
const str = (n: YNode, path: string) => {
  if (n.k !== 'scalar') throw new YamlError(n.line, path, 'expected a string');
  return n.v;
};
const int = (n: YNode, path: string) => {
  if (n.k !== 'scalar' || !n.plain || !/^-?\d+$/.test(n.v)) throw new YamlError(n.line, path, 'expected an integer');
  return +n.v;
};
const seqOf = (n: YNode, path: string) => {
  if (n.k !== 'seq') throw new YamlError(n.line, path, 'expected a list');
  return n.items;
};
const port = (n: YNode, path: string) => {
  const p = int(n, path);
  if (p < 1 || p > 65535) throw new YamlError(n.line, path, 'port must be 1-65535');
  return p;
};

/** OpenShellPolicy.parse's checks. Throws YamlError. */
export function checkOpenShell(text: string): OpenShellCheck {
  if (text.length > 4 * 1024 * 1024) throw new YamlError(null, '', 'policy exceeds 4 MiB');
  const root = parseYaml(text);
  if (!root || isNull(root)) throw new YamlError(null, '', 'empty policy');
  const top = mapping(root, '', ['version', 'filesystem_policy', 'landlock', 'process', 'network_policies', 'network_middlewares']);
  const v = top.get('version');
  if (!v) throw new YamlError(root.line, 'version', 'required field is missing');
  if (int(v, 'version') !== 1) throw new YamlError(v.line, 'version', 'must be 1');
  const warnings: string[] = [];
  const warn = (s: string) => { if (!warnings.includes(s)) warnings.push(s); };
  const ll = top.get('landlock');
  if (ll && !isNull(ll)) {
    const m = mapping(ll, 'landlock', ['compatibility']);
    const c = m.get('compatibility');
    if (c && !['best_effort', 'hard_requirement'].includes(str(c, 'landlock.compatibility')))
      throw new YamlError(c.line, 'landlock.compatibility', 'must be best_effort or hard_requirement');
  }
  const fs = top.get('filesystem_policy');
  if (fs && !isNull(fs)) {
    const m = mapping(fs, 'filesystem_policy', ['include_workdir', 'read_only', 'read_write']);
    for (const key of ['read_only', 'read_write']) {
      const l = m.get(key);
      if (!l || isNull(l)) continue;
      for (const [i, pn] of seqOf(l, `filesystem_policy.${key}`).entries()) {
        const p = str(pn, `filesystem_policy.${key}[${i}]`);
        if (!p.startsWith('/')) throw new YamlError(pn.line, `filesystem_policy.${key}`, 'path must be absolute');
        if (p.split('/').includes('..')) throw new YamlError(pn.line, `filesystem_policy.${key}`, 'path must not contain \'..\'');
        if (key === 'read_write' && p === '/') throw new YamlError(pn.line, `filesystem_policy.${key}`, 'read_write cannot contain /');
      }
    }
  }
  const rules: OpenShellCheck['rules'] = [];
  const np = top.get('network_policies');
  if (np && !isNull(np)) {
    if (np.k !== 'map') throw new YamlError(np.line, 'network_policies', 'expected a mapping');
    for (const [key, node, line] of np.entries) {
      const path = `network_policies.${key}`;
      if (key.startsWith('_provider_')) throw new YamlError(line, path, 'rule keys starting with _provider_ are reserved');
      const m = mapping(node, path, ['name', 'endpoints', 'binaries']);
      if (m.get('name')) str(m.get('name')!, `${path}.name`);
      const eps = m.get('endpoints');
      if (eps && !isNull(eps)) seqOf(eps, `${path}.endpoints`).forEach((en, i) => endpoint(en, `${path}.endpoints[${i}]`, warn));
      const binaries: string[] = [];
      const b = m.get('binaries');
      if (b && !isNull(b)) seqOf(b, `${path}.binaries`).forEach((bn, i) => {
        const bp = `${path}.binaries[${i}]`;
        if (bn.k === 'scalar') binaries.push(str(bn, bp));
        else {
          const bm = mapping(bn, bp, ['path']);
          const p = bm.get('path');
          if (!p) throw new YamlError(bn.line, `${bp}.path`, 'required field is missing');
          binaries.push(str(p, `${bp}.path`));
        }
      });
      if (binaries.length) warn('binaries: not enforced — each rule applies to every process in the VM (agents hold root in the guest, so process identity can’t be trusted)');
      rules.push({ key, binaries });
    }
  }
  const proc = top.get('process');
  return { rules, warnings, confinesGuest: (!!fs && !isNull(fs)) || (!!proc && !isNull(proc)) };
}

function endpoint(n: YNode, path: string, warn: (s: string) => void) {
  const m = mapping(n, path, ENDPOINT_FIELDS);
  const nonEmpty = (k: string) => { const v = m.get(k); if (isNull(v)) return null; const s = str(v!, `${path}.${k}`); return s || null; };
  const host = nonEmpty('host');
  const ports: number[] = [];
  const p = m.get('port');
  if (p && !isNull(p)) ports.push(port(p, `${path}.port`));
  const ps = m.get('ports');
  if (ps && !isNull(ps)) {
    const list = seqOf(ps, `${path}.ports`);
    if (list.length && ports.length) throw new YamlError(ps.line, `${path}.ports`, 'set port or ports, not both');
    list.forEach((pn, i) => ports.push(port(pn, `${path}.ports[${i}]`)));
  }
  if (!ports.length) throw new YamlError(n.line, `${path}.port`, 'set port or ports');
  if (!host) {
    const a = m.get('allowed_ips');
    if (!a || a.k !== 'seq' || !a.items.length) throw new YamlError(n.line, `${path}.host`, 'set host or allowed_ips');
  }
  const proto = nonEmpty('protocol');
  if (proto && !['rest', 'websocket', 'graphql', 'mcp', 'json-rpc', 'tcp'].includes(proto))
    throw new YamlError(m.get('protocol')!.line, `${path}.protocol`, 'must be rest, websocket, graphql, mcp, json-rpc or tcp');
  const tls = nonEmpty('tls');
  if (tls && tls !== 'skip') throw new YamlError(m.get('tls')!.line, `${path}.tls`, 'only \'skip\' is supported');
  const enf = nonEmpty('enforcement');
  if (enf && !['enforce', 'audit'].includes(enf)) throw new YamlError(m.get('enforcement')!.line, `${path}.enforcement`, 'must be enforce or audit');
  const access = nonEmpty('access');
  if (access && !['read-only', 'read-write', 'full'].includes(access)) throw new YamlError(m.get('access')!.line, `${path}.access`, 'must be read-only, read-write or full');
  const pathSel = nonEmpty('path');
  if (pathSel && !pathSel.startsWith('/')) throw new YamlError(m.get('path')!.line, `${path}.path`, 'path selector must start with /');
  if (proto === 'tcp') {
    if (!host) throw new YamlError(n.line, `${path}.host`, 'protocol: tcp requires a hostname');
    if (m.has('path') || m.has('enforcement') || m.has('access') || m.has('rules'))
      throw new YamlError(n.line, path, 'protocol: tcp accepts no request fields (path, enforcement, access, rules)');
  }
  if (m.has('access') && m.has('rules')) throw new YamlError(m.get('rules')!.line, `${path}.rules`, 'access and rules cannot be combined');
  if (tls === 'skip' && proto && proto !== 'tcp') throw new YamlError(m.get('tls')!.line, `${path}.tls`, 'tls: skip cannot be used with a request protocol');
  if (proto && ['rest', 'websocket', 'graphql'].includes(proto) && !m.has('access') && !m.has('rules'))
    throw new YamlError(n.line, path, `${proto} endpoints need access or rules`);
  if (!proto && (m.has('access') || m.has('rules'))) warn(`access / rules without protocol have no effect (${path})`);
}
