// Credential references and helpers shared by the Credentials and Guardrails
// panes — Profile.swift `CredentialRef`, `CredentialCategory`,
// `CredentialEditorType`, `configuredCredentials()`, `credentialTitle`,
// `credentialHosts`, and ProfileViews.swift's approval / write-policy bindings.

import { TOOL_NAME, val, type Doc, type Tool } from '../model';

export type CredKind = 'primaryToolKey' | 'tool' | 'git' | 'manual' | 'docker' | 'db' | 'kube' | 'aws' | 'do' | 'linear' | 'twilio' | 'ssh-managed' | 'ssh';
export interface CredRef { id: string; kind: CredKind; arg?: string }

/** CredentialRef(wireID:) */
export function parseRef(id: string): CredRef | null {
  if (['primaryToolKey', 'aws', 'do', 'linear', 'twilio', 'ssh-managed'].includes(id)) return { id, kind: id as CredKind };
  const i = id.indexOf(':');
  if (i < 0) return null;
  const k = id.slice(0, i), a = id.slice(i + 1);
  if (['tool', 'git', 'manual', 'docker', 'db', 'kube', 'ssh'].includes(k)) return { id, kind: k as CredKind, arg: a };
  return null;
}

export const CATEGORY_ORDER = ['Agents', 'Git', 'Cloud', 'Databases', 'SSH', 'Other'] as const;
export type CredCategory = typeof CATEGORY_ORDER[number];

export function refCategory(r: CredRef): CredCategory {
  switch (r.kind) {
    case 'primaryToolKey': case 'tool': return 'Agents';
    case 'git': return 'Git';
    case 'aws': case 'do': case 'docker': case 'kube': case 'linear': case 'twilio': return 'Cloud';
    case 'db': return 'Databases';
    case 'ssh-managed': case 'ssh': return 'SSH';
    default: return 'Other';
  }
}

export function refSymbol(r: CredRef): string {
  switch (r.kind) {
    case 'primaryToolKey': case 'tool': return 'sparkles';
    case 'git': return 'arrow.triangle.branch';
    case 'manual': return 'key.horizontal.fill';
    case 'docker': case 'kube': return 'shippingbox.fill';
    case 'db': return 'cylinder.split.1x2.fill';
    case 'aws': return 'server.rack';
    case 'do': return 'cloud.fill';
    case 'linear': return 'line.diagonal';
    case 'twilio': return 'phone.fill';
    default: return 'key.fill';
  }
}

export type EditorType = 'agents' | 'git' | 'ssh' | 'aws' | 'digitalOcean' | 'linear' | 'twilio' | 'kubernetes' | 'docker' | 'database' | 'manual';

export function refEditorType(r: CredRef): EditorType {
  switch (r.kind) {
    case 'primaryToolKey': case 'tool': return 'agents';
    case 'git': return 'git';
    case 'manual': return 'manual';
    case 'docker': return 'docker';
    case 'db': return 'database';
    case 'kube': return 'kubernetes';
    case 'aws': return 'aws';
    case 'do': return 'digitalOcean';
    case 'linear': return 'linear';
    case 'twilio': return 'twilio';
    default: return 'ssh';
  }
}

export const EDITOR_TYPES: { id: EditorType; title: string; symbol: string; subtitle: string }[] = [
  { id: 'agents', title: 'Agent API key', symbol: 'sparkles', subtitle: 'Anthropic, OpenAI, or xAI API key for a coding agent' },
  { id: 'git', title: 'Git token', symbol: 'arrow.triangle.branch', subtitle: 'Personal access token for GitHub, GitLab, or Bitbucket' },
  { id: 'ssh', title: 'SSH key', symbol: 'key.fill', subtitle: 'Import a private key, or use the per-workspace key' },
  { id: 'aws', title: 'AWS credentials', symbol: 'server.rack', subtitle: 'Static IAM keys or SSO — SigV4-signed on the wire' },
  { id: 'digitalOcean', title: 'DigitalOcean token', symbol: 'cloud.fill', subtitle: 'doctl / API personal access token' },
  { id: 'linear', title: 'Linear API key', symbol: 'line.diagonal', subtitle: 'Linear personal API key' },
  { id: 'twilio', title: 'Twilio API key', symbol: 'phone.fill', subtitle: 'Account/API-key SID + secret — HTTP Basic on the wire' },
  { id: 'kubernetes', title: 'Kubernetes', symbol: 'shippingbox.fill', subtitle: 'A cluster context (token, client cert, or exec plugin)' },
  { id: 'docker', title: 'Container registry', symbol: 'shippingbox.fill', subtitle: 'Registry login for Docker Hub, ghcr.io, and others' },
  { id: 'database', title: 'Database', symbol: 'cylinder.split.1x2.fill', subtitle: 'MongoDB Data API, ClickHouse, or Elasticsearch' },
  { id: 'manual', title: 'Other API key', symbol: 'key.horizontal.fill', subtitle: 'Any other token — you choose the env var and host(s)' },
];
export const editorType = (id: EditorType) => EDITOR_TYPES.find(t => t.id === id)!;

// ── usability (what produces a swap) ───────────────────────────────────

const nonBlank = (s?: string) => !!(s ?? '').trim();
export const gitUsable = (c: Doc) => nonBlank(c.host) && !!c.token;
export const dockerUsable = (c: Doc) => nonBlank(c.host) && nonBlank(c.username) && !!c.password;
export const dbUsable = (c: Doc) => nonBlank(c.host) && !!c.secret;
export const kubeUsable = (c: Doc) => nonBlank(c.serverURL);
export const manualUsable = (c: Doc) => !!c.realValue;
export function awsUsable(a: Doc) {
  return (a.authMode ?? 'staticKeys') === 'ssoProfile' ? nonBlank(a.ssoProfileName) : nonBlank(a.accessKeyID) && !!a.secretAccessKey;
}
export const twilioUsable = (t: Doc) => nonBlank(t.sid) && !!t.secret;

/** Profile.configuredCredentials() over the draft (only secrets typed in this window survive the redaction). */
export function configuredLocally(doc: Doc): string[] {
  const refs: string[] = [];
  if (doc.authMode === 'token' && doc.apiKey) refs.push('primaryToolKey');
  for (const s of val<Doc[]>(doc, 'additionalTools')) if (s.authMode === 'token' && s.apiKey) refs.push(`tool:${s.tool}`);
  for (const c of val<Doc[]>(doc, 'gitHTTPSCredentials')) if (gitUsable(c)) refs.push(`git:${c.id}`);
  if (awsUsable(val(doc, 'awsCredentials'))) refs.push('aws');
  if (val<string>(doc, 'digitalOceanToken')) refs.push('do');
  if (val<string>(doc, 'linearToken')) refs.push('linear');
  if (twilioUsable(val(doc, 'twilioCredential'))) refs.push('twilio');
  for (const r of val<Doc[]>(doc, 'dockerRegistries')) if (dockerUsable(r)) refs.push(`docker:${r.id}`);
  for (const k of val<Doc[]>(doc, 'kubeconfigs')) if (kubeUsable(k)) refs.push(`kube:${k.id}`);
  for (const d of val<Doc[]>(doc, 'httpDatabases')) if (dbUsable(d)) refs.push(`db:${d.id}`);
  if (doc.sshPublicKey) refs.push('ssh-managed');
  for (const k of val<Doc[]>(doc, 'importedSSHKeys')) refs.push(`ssh:${k.id}`);
  for (const m of val<Doc[]>(doc, 'manualTokens')) if (manualUsable(m)) refs.push(`manual:${m.id}`);
  return refs;
}

/** Whether a ref still names something on the draft (a removed row drops out). */
function stillPresent(doc: Doc, r: CredRef): boolean {
  const has = (key: string) => val<Doc[]>(doc, key).some(x => String(x.id).toUpperCase() === String(r.arg).toUpperCase());
  switch (r.kind) {
    case 'primaryToolKey': return doc.authMode === 'token';
    case 'tool': return val<Doc[]>(doc, 'additionalTools').some(s => s.tool === r.arg && s.authMode === 'token');
    case 'git': return has('gitHTTPSCredentials');
    case 'manual': return has('manualTokens');
    case 'docker': return has('dockerRegistries');
    case 'db': return has('httpDatabases');
    case 'kube': return has('kubeconfigs');
    case 'ssh': return has('importedSSHKeys');
    case 'ssh-managed': return !!doc.sshPublicKey;
    case 'aws': { const a = val<Doc>(doc, 'awsCredentials'); return (a.authMode ?? 'staticKeys') === 'ssoProfile' ? nonBlank(a.ssoProfileName) : nonBlank(a.accessKeyID); }
    case 'do': case 'linear': return true;
    case 'twilio': return nonBlank(val<Doc>(doc, 'twilioCredential').sid);
  }
}

/** The configured credentials the panes list: the host's list (computed
 *  before the secrets were blanked) for what's still on the draft, plus what
 *  this window configured — in `configuredCredentials()` order. */
export function configuredRefs(doc: Doc, serverRefs: string[], opened: Doc): CredRef[] {
  const local = configuredLocally(doc);
  const removed = removedSingletons(opened);
  const server = serverRefs.map(parseRef).filter((r): r is CredRef => !!r && stillPresent(doc, r) && !removed.has(r.kind));
  const ids = new Set(server.map(r => r.id));
  const all = [...server, ...local.filter(id => !ids.has(id)).map(id => parseRef(id)!)];
  const order = (r: CredRef) => CATEGORY_ORDER.indexOf(refCategory(r));
  return all.map((r, i) => ({ r, i })).sort((a, b) => order(a.r) - order(b.r) || a.i - b.i).map(x => x.r);
}

/** DigitalOcean / Linear / AWS / Twilio removed in this window. A blank
 *  secret is also what a redacted round-trip carries (blank = keep), so the
 *  panes remember the removal for the editor window. */
const removedByEditor = new WeakMap<Doc, Set<string>>();   // keyed by the editor's `opened` document
export function removedSingletons(opened: Doc): Set<string> { return removedByEditor.get(opened) ?? new Set(); }
export function markRemoved(opened: Doc, kind: string, on: boolean) {
  const s = new Set(removedSingletons(opened));
  if (on) s.add(kind); else s.delete(kind);
  removedByEditor.set(opened, s);
}

export function groupByCategory(refs: CredRef[]): [CredCategory, CredRef[]][] {
  return CATEGORY_ORDER.map(c => [c, refs.filter(r => refCategory(r) === c)] as [CredCategory, CredRef[]]).filter(([, rs]) => rs.length > 0);
}

const findBy = (doc: Doc, key: string, id?: string) =>
  val<Doc[]>(doc, key).find(x => String(x.id).toUpperCase() === String(id).toUpperCase());

/** Profile.credentialTitle */
export function credentialTitle(doc: Doc, r: CredRef): string {
  switch (r.kind) {
    case 'primaryToolKey': return `${TOOL_NAME[doc.tool as Tool] ?? doc.tool} API key`;
    case 'tool': return `${TOOL_NAME[r.arg as Tool] ?? 'Agent'} API key`;
    case 'git': { const c = findBy(doc, 'gitHTTPSCredentials', r.arg); if (!c) return 'Git token'; return c.username ? `${c.username}@${c.host}` : `Git token (${c.host})`; }
    case 'manual': { const m = findBy(doc, 'manualTokens', r.arg); return m?.name || m?.envVarName || 'Manual token'; }
    case 'docker': return findBy(doc, 'dockerRegistries', r.arg)?.host ?? 'Registry';
    case 'db': { const d = findBy(doc, 'httpDatabases', r.arg); if (!d) return 'Database'; return d.name || DB_ENGINES[d.engine as DBEngine]?.name || 'Database'; }
    case 'kube': return findBy(doc, 'kubeconfigs', r.arg)?.name ?? 'Kubernetes';
    case 'aws': return 'AWS credentials';
    case 'do': return 'DigitalOcean token';
    case 'linear': return 'Linear API key';
    case 'twilio': return 'Twilio API key';
    case 'ssh-managed': return 'Workspace SSH key';
    case 'ssh': return findBy(doc, 'importedSSHKeys', r.arg)?.label ?? 'SSH key';
  }
}

function toolHosts(t: string): string[] {
  switch (t) {
    case 'claude': return ['anthropic.com'];
    case 'codex': return ['openai.com'];
    case 'grok': return ['x.ai'];
    case 'kimi': return ['moonshot.ai', 'kimi.ai', 'kimi.com'];
    default: return ['anthropic.com', 'openai.com', 'x.ai', 'z.ai'];
  }
}

/** Profile.credentialHosts */
export function credentialHosts(doc: Doc, r: CredRef): string[] {
  switch (r.kind) {
    case 'primaryToolKey': return toolHosts(doc.tool);
    case 'tool': return toolHosts(r.arg ?? doc.tool);
    case 'git': { const c = findBy(doc, 'gitHTTPSCredentials', r.arg); return c ? [c.host] : []; }
    case 'manual': return (findBy(doc, 'manualTokens', r.arg)?.hostFilters ?? []).filter((h: string) => !!h);
    case 'docker': { const c = findBy(doc, 'dockerRegistries', r.arg); return c ? [c.host] : []; }
    case 'db': { const c = findBy(doc, 'httpDatabases', r.arg); return c ? [c.host] : []; }
    case 'kube': {
      const k = findBy(doc, 'kubeconfigs', r.arg); if (!k) return [];
      try { return [new URL(k.serverURL).hostname || k.serverURL]; } catch { return [k.serverURL]; }
    }
    case 'aws': return ['amazonaws.com'];
    case 'do': return ['digitalocean.com'];
    case 'linear': return ['linear.app'];
    case 'twilio': return ['twilio.com'];
    default: return [];
  }
}

// ── "Require approval to use" + write policy ───────────────────────────

const ARRAY_OF: Partial<Record<CredKind, string>> = {
  git: 'gitHTTPSCredentials', manual: 'manualTokens', docker: 'dockerRegistries', db: 'httpDatabases',
  kube: 'kubeconfigs', ssh: 'importedSSHKeys',
};

export function getApproval(doc: Doc, r: CredRef): boolean {
  switch (r.kind) {
    case 'primaryToolKey': return val(doc, 'apiKeyRequiresApproval');
    case 'tool': return !!val<Doc[]>(doc, 'additionalTools').find(s => s.tool === r.arg)?.requireApproval;
    case 'aws': return !!val<Doc>(doc, 'awsCredentials').requireApproval;
    case 'do': return val(doc, 'digitalOceanTokenRequiresApproval');
    case 'linear': return val(doc, 'linearTokenRequiresApproval');
    case 'twilio': return !!val<Doc>(doc, 'twilioCredential').requireApproval;
    case 'ssh-managed': return val(doc, 'sshKeyRequiresApproval');
    default: return !!findBy(doc, ARRAY_OF[r.kind]!, r.arg)?.requireApproval;
  }
}

export function setApproval(d: Doc, r: CredRef, v: boolean) {
  switch (r.kind) {
    case 'primaryToolKey': d.apiKeyRequiresApproval = v; return;
    case 'tool': { const s = (d.additionalTools ?? []).find((x: Doc) => x.tool === r.arg); if (s) s.requireApproval = v; return; }
    case 'aws': d.awsCredentials = { ...val<Doc>(d, 'awsCredentials'), requireApproval: v }; return;
    case 'do': d.digitalOceanTokenRequiresApproval = v; return;
    case 'linear': d.linearTokenRequiresApproval = v; return;
    case 'twilio': d.twilioCredential = { ...val<Doc>(d, 'twilioCredential'), requireApproval: v }; return;
    case 'ssh-managed': d.sshKeyRequiresApproval = v; return;
    default: { const x = findBy(d, ARRAY_OF[r.kind]!, r.arg); if (x) x.requireApproval = v; }
  }
}

export const MODES = [
  { value: 'off', label: 'Off' },
  { value: 'promptOnWrite', label: 'Prompt before write' },
  { value: 'destructive', label: 'Block destructive' },
  { value: 'readOnly', label: 'Read-only' },
];

export const isGitHub = (h: string) => { h = h.toLowerCase(); return h === 'github.com' || h.endsWith('.github.com'); };
export const isGitLab = (h: string) => { h = h.toLowerCase(); return h === 'gitlab.com' || h.startsWith('gitlab.'); };
export const isBitbucket = (h: string) => h.toLowerCase() === 'bitbucket.org';

/** Where a credential's write policy lives: a guardrails key, a database row, or none. */
export function modeSlot(doc: Doc, r: CredRef): { guardrail: string } | { db: string } | null {
  switch (r.kind) {
    case 'git': {
      const host = String(findBy(doc, 'gitHTTPSCredentials', r.arg)?.host ?? '');
      if (!host) return null;
      if (isGitHub(host)) return { guardrail: 'github' };
      if (isGitLab(host)) return { guardrail: 'gitlab' };
      if (isBitbucket(host)) return { guardrail: 'bitbucket' };
      return null;
    }
    case 'aws': return { guardrail: 'aws' };
    case 'do': return { guardrail: 'digitalOcean' };
    case 'docker': return { guardrail: 'docker' };
    case 'kube': return { guardrail: 'kubernetes' };
    case 'db': return findBy(doc, 'httpDatabases', r.arg) ? { db: r.arg! } : null;
    default: return null;
  }
}

export type DBEngine = 'mongoDataAPI' | 'clickHouse' | 'elasticsearch';
export const DB_ENGINES: Record<DBEngine, { name: string }> = {
  mongoDataAPI: { name: 'MongoDB (Data API)' }, clickHouse: { name: 'ClickHouse' }, elasticsearch: { name: 'Elasticsearch' },
};

export const uuid = () => crypto.randomUUID().toUpperCase();
/** OnePasswordCLI.reference(in:) */
export function opReference(raw: string): string | null {
  let s = raw.trim();
  if (s.startsWith('{{') && s.endsWith('}}')) s = s.slice(2, -2).trim();
  return s.startsWith('op://') ? s : null;
}
