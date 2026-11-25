// Import env file… — EnvFileImport.swift (parse + classify) and
// EnvImportReviewView, applied as ProfileViews.applyEnvImport does. The file
// is the user's own (.env, .bashrc…), read here in the browser; nothing but
// the chosen values lands in the draft.

import React from 'react';
import { Button, Sheet } from '../../../ui/kit';
import { SF } from '../../../ui/icons';
import { TOOL_NAME, val, type Doc, type Tool } from '../model';
import type { EditorCtxValue } from '../ctx';
import { Caption, Field, Toggle } from '../ui';
import { arr, newManualToken } from './CredentialsEditors';
import { awsUsable, gitUsable, opReference, twilioUsable, uuid } from './CredentialsModel';

type Slot =
  | { k: 'toolKey'; tool: Tool } | { k: 'gitToken'; host: string } | { k: 'digitalOcean' } | { k: 'linear' }
  | { k: 'awsAccessKeyID' } | { k: 'awsSecretAccessKey' } | { k: 'awsSessionToken' } | { k: 'twilioSID' } | { k: 'twilioSecret' };

function slotFor(name: string): Slot | null {
  switch (name.toUpperCase()) {
    case 'ANTHROPIC_API_KEY': return { k: 'toolKey', tool: 'claude' };
    case 'OPENAI_API_KEY': return { k: 'toolKey', tool: 'codex' };
    case 'XAI_API_KEY': return { k: 'toolKey', tool: 'grok' };
    case 'MOONSHOT_API_KEY': case 'KIMI_API_KEY': return { k: 'toolKey', tool: 'kimi' };
    case 'GH_TOKEN': case 'GITHUB_TOKEN': return { k: 'gitToken', host: 'github.com' };
    case 'GITLAB_TOKEN': case 'GLAB_TOKEN': return { k: 'gitToken', host: 'gitlab.com' };
    case 'DIGITALOCEAN_ACCESS_TOKEN': case 'DIGITALOCEAN_TOKEN': case 'DO_TOKEN': return { k: 'digitalOcean' };
    case 'LINEAR_API_KEY': return { k: 'linear' };
    case 'AWS_ACCESS_KEY_ID': return { k: 'awsAccessKeyID' };
    case 'AWS_SECRET_ACCESS_KEY': return { k: 'awsSecretAccessKey' };
    case 'AWS_SESSION_TOKEN': return { k: 'awsSessionToken' };
    case 'TWILIO_ACCOUNT_SID': case 'TWILIO_API_KEY_SID': case 'TWILIO_API_KEY': return { k: 'twilioSID' };
    case 'TWILIO_AUTH_TOKEN': case 'TWILIO_API_SECRET': case 'TWILIO_API_KEY_SECRET': return { k: 'twilioSecret' };
    default: return null;
  }
}

function slotName(s: Slot): string {
  switch (s.k) {
    case 'toolKey': return `${TOOL_NAME[s.tool]} API key`;
    case 'gitToken': return `Git token (${s.host})`;
    case 'digitalOcean': return 'DigitalOcean token';
    case 'linear': return 'Linear API key';
    case 'awsAccessKeyID': return 'AWS access key ID';
    case 'awsSecretAccessKey': return 'AWS secret access key';
    case 'awsSessionToken': return 'AWS session token';
    case 'twilioSID': return 'Twilio SID';
    case 'twilioSecret': return 'Twilio auth token';
  }
}

const VALID_NAME = /^[\p{L}_][\p{L}\p{N}_]*$/u;

/** EnvFileImport.literalValue: nil when only a shell could resolve it. */
function literalValue(raw: string): string | null {
  const v = raw.trim();
  if (!v) return '';
  const q = v[0];
  if (q === "'" || q === '"') {
    const close = v.indexOf(q, 1);
    if (close < 0) return null;
    const inner = v.slice(1, close);
    if (q === '"') {
      if (inner.includes('$') || inner.includes('`')) return null;
      return inner.replace(/\\"/g, '"').replace(/\\\\/g, '\\');
    }
    return inner;
  }
  let bare = v;
  const hash = bare.indexOf(' #');
  if (hash >= 0) bare = bare.slice(0, hash).trim();
  if (bare.includes('$') || bare.includes('`')) return null;
  return bare;
}

/** EnvFileImport.parse — literal assignments only; later ones win. */
export function parseEnv(text: string): { name: string; value: string }[] {
  const by = new Map<string, string>();
  for (const raw of text.split('\n')) {
    let line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    for (const p of ['export ', 'declare -x ']) if (line.startsWith(p)) line = line.slice(p.length).trim();
    const eq = line.indexOf('=');
    if (eq < 0) continue;
    const name = line.slice(0, eq).trim();
    if (!VALID_NAME.test(name)) continue;
    const value = literalValue(line.slice(eq + 1));
    if (value == null) continue;
    by.set(name, value);
  }
  return [...by].map(([name, value]) => ({ name, value }));
}

export interface RecognizedRow { key: string; slot: Slot; name: string; value: string; include: boolean; note: string; gitUsername: string }
export interface UnrecognizedRow { key: string; name: string; value: string; include: boolean; hostsText: string }
export interface EnvImport { fileName: string; recognized: RecognizedRow[]; unrecognized: UnrecognizedRow[] }

/** The model settings an imported agent key lands in (ProfileEditorView.agentKeyImportSettings). */
function agentSettings(ctx: EditorCtxValue): Doc {
  if (ctx.setGlobalModels) return ctx.globalModels;
  const o = ctx.doc.modelOverride as Doc | undefined;
  if (!o) return ctx.globalModels;
  if (o.inheritsGlobal === false) return o.settings ?? {};
  const out = { providers: [...(ctx.globalModels.providers ?? [])] };
  out.providers = out.providers.filter((p: Doc) => !(o.excludedProviders ?? []).includes(p.provider));
  for (const own of o.settings?.providers ?? []) { out.providers = out.providers.filter((p: Doc) => p.provider !== own.provider); out.providers.push(own); }
  return out;
}
const NATIVE: Record<Tool, string> = { claude: 'anthropic', codex: 'openai', grok: 'xai', kimi: 'moonshot', omp: 'anthropic', hermes: 'anthropic' };

function slotConfigured(ctx: EditorCtxValue, s: Slot): boolean {
  const d = ctx.doc;
  switch (s.k) {
    case 'toolKey': {
      const p = (agentSettings(ctx).providers ?? []).find((x: Doc) => x.provider === NATIVE[s.tool]);
      return !!p && (p.provider === 'bedrock' || !!p.useSubscription || !!String(p.apiKey ?? '').trim());
    }
    case 'gitToken': return val<Doc[]>(d, 'gitHTTPSCredentials').some(c => c.host === s.host && gitUsable(c))
      || ctx.credentialRefs.some(r => r.startsWith('git:') && val<Doc[]>(d, 'gitHTTPSCredentials').some(c => c.host === s.host && r === `git:${c.id}`));
    case 'digitalOcean': return !!val(d, 'digitalOceanToken') || ctx.credentialRefs.includes('do');
    case 'linear': return !!val(d, 'linearToken') || ctx.credentialRefs.includes('linear');
    case 'awsAccessKeyID': case 'awsSecretAccessKey': case 'awsSessionToken': return awsUsable(val(d, 'awsCredentials')) || ctx.credentialRefs.includes('aws');
    case 'twilioSID': case 'twilioSecret': return twilioUsable(val(d, 'twilioCredential')) || ctx.credentialRefs.includes('twilio');
  }
}

/** importEnvText: parse → classify → review state (or an error message). */
export function importEnvText(ctx: EditorCtxValue, text: string, fileName: string): EnvImport | string {
  const vars = parseEnv(text).filter(v => v.value !== '');
  const recognized: RecognizedRow[] = [], unrecognized: UnrecognizedRow[] = [];
  for (const v of vars) {
    const s = slotFor(v.name);
    if (s) {
      const already = slotConfigured(ctx, s);
      recognized.push({ key: uuid(), slot: s, name: v.name, value: v.value, include: !already,
        note: already ? 'Already configured — check to overwrite.' : '', gitUsername: String(ctx.doc.gitUserName ?? '') });
    } else unrecognized.push({ key: uuid(), name: v.name, value: v.value, include: true, hostsText: '' });
  }
  if (!recognized.length && !unrecognized.length) return `No importable variables found in ${fileName}.`;
  return { fileName, recognized, unrecognized };
}

/** applyEnvImport */
export function applyEnvImport(ctx: EditorCtxValue, st: EnvImport) {
  const agentKeys: [Tool, string][] = [];
  ctx.update(d => {
    let awsA = '', awsS = '', awsT = '', awsAny = false, twSID = '', twSec = '', twAny = false;
    for (const row of st.recognized) {
      if (!row.include) continue;
      const op = opReference(row.value);
      if (op) {
        arr(d, 'manualTokens').push(newManualToken({ name: row.name, realValue: op, envVarName: row.name }));
        if (row.slot.k === 'toolKey' && d.tool === row.slot.tool) d.authMode = 'token';
        continue;
      }
      const s = row.slot;
      switch (s.k) {
        case 'toolKey': agentKeys.push([s.tool, row.value]); break;
        case 'gitToken': {
          const user = row.gitUsername.trim();
          const l = arr(d, 'gitHTTPSCredentials');
          const c = l.find(x => x.host === s.host);
          if (c) { c.token = row.value; if (user) c.username = user; }
          else l.push({ id: uuid(), host: s.host, username: user, token: row.value });
          break;
        }
        case 'digitalOcean': d.digitalOceanToken = row.value; break;
        case 'linear': d.linearToken = row.value; break;
        case 'awsAccessKeyID': awsA = row.value; awsAny = true; break;
        case 'awsSecretAccessKey': awsS = row.value; awsAny = true; break;
        case 'awsSessionToken': awsT = row.value; awsAny = true; break;
        case 'twilioSID': twSID = row.value; twAny = true; break;
        case 'twilioSecret': twSec = row.value; twAny = true; break;
      }
    }
    if (awsAny) {
      const a: Doc = { ...val<Doc>(d, 'awsCredentials'), authMode: 'staticKeys' };
      if (awsA) a.accessKeyID = awsA; if (awsS) a.secretAccessKey = awsS; if (awsT) a.sessionToken = awsT;
      d.awsCredentials = a;
    }
    if (twAny) {
      const t: Doc = { ...val<Doc>(d, 'twilioCredential') };
      if (twSID) t.sid = twSID; if (twSec) t.secret = twSec;
      d.twilioCredential = t;
    }
    for (const row of st.unrecognized) {
      if (!row.include) continue;
      const hosts = row.hostsText.split(/[,\s]+/).map(h => h.trim()).filter(Boolean);
      arr(d, 'manualTokens').push(newManualToken({ name: row.name, realValue: opReference(row.value) ?? row.value, envVarName: row.name, hostFilters: hosts }));
    }
    // A remote workspace's agent keys go in its own model layer (its global
    // store lives on the server); Preferences edits the global draft below.
    if (!ctx.setGlobalModels && agentKeys.length) {
      const o: Doc = d.modelOverride ?? { inheritsGlobal: true, settings: { providers: [], tiers: [], agentTiers: [], localRunModels: [], agentEnvironment: '' }, excludedProviders: [] };
      o.settings = o.settings ?? { providers: [] };
      for (const [t, key] of agentKeys) putKey(o.settings, NATIVE[t], key);
      d.modelOverride = o;
    }
  });
  if (ctx.setGlobalModels && agentKeys.length) ctx.setGlobalModels(m => { for (const [t, key] of agentKeys) putKey(m, NATIVE[t], key); });
}

function putKey(s: Doc, provider: string, key: string) {
  s.providers = s.providers ?? [];
  const p = s.providers.find((x: Doc) => x.provider === provider);
  if (p) p.apiKey = key; else s.providers.push({ provider, apiKey: key, useSubscription: false });
}

const masked = (v: string) => v.length <= 8 ? '•'.repeat(Math.max(v.length, 1)) : `${v.slice(0, 4)}…${v.slice(-4)}`;

export function EnvImportReview({ state, setState, onCancel, onImport }: {
  state: EnvImport; setState: (s: EnvImport) => void; onCancel: () => void; onImport: () => void;
}) {
  const count = state.recognized.filter(r => r.include).length + state.unrecognized.filter(r => r.include).length;
  const setRec = (i: number, p: Partial<RecognizedRow>) => setState({ ...state, recognized: state.recognized.map((r, j) => j === i ? { ...r, ...p } : r) });
  const setUn = (i: number, p: Partial<UnrecognizedRow>) => setState({ ...state, unrecognized: state.unrecognized.map((r, j) => j === i ? { ...r, ...p } : r) });
  return (
    <Sheet width={580} height={560} onClose={onCancel}>
      <div className="edc-sheet">
        <div className="edc-sheet-head">
          <SF name="square.and.arrow.down" size={15} color="var(--accent)" />
          <span className="ed-headline">Import from {state.fileName}</span>
          <div style={{ flex: 1 }} />
          <Button onClick={onCancel}>Cancel</Button>
        </div>
        <div className="edc-sheet-body" style={{ gap: 16 }}>
          {state.recognized.length > 0 && (
            <div className="edc-vstack" style={{ gap: 8 }}>
              <div className="edc-sectitle">RECOGNIZED</div>
              {state.recognized.map((r, i) => (
                <div key={r.key} className="edc-vstack" style={{ gap: 4, padding: '4px 0' }}>
                  <div className="edc-hrow top">
                    <Toggle checked={r.include} onChange={v => setRec(i, { include: v })} />
                    <div className="edc-vstack" style={{ gap: 1 }}>
                      <span className="edc-sub500">{slotName(r.slot)}</span>
                      <span className="ed-caption mono">{r.name} = {masked(r.value)}</span>
                      {r.note && <span className="edc-tiny" style={{ color: 'var(--orange)' }}>{r.note}</span>}
                    </div>
                  </div>
                  {r.slot.k === 'gitToken' && (
                    <div className="edc-hrow" style={{ paddingLeft: 26, gap: 6 }}>
                      <span className="ed-caption">Git username</span>
                      <Field value={r.gitUsername} onChange={v => setRec(i, { gitUsername: v })} placeholder="you" style={{ maxWidth: 180 }} />
                    </div>
                  )}
                </div>
              ))}
            </div>
          )}
          {state.unrecognized.length > 0 && (
            <div className="edc-vstack" style={{ gap: 8 }}>
              <div className="edc-sectitle">UNRECOGNIZED</div>
              <Caption>Import these as generic tokens. Set the host(s) each one authenticates to so the fake is only swapped for the real value on those hosts. Leave blank to allow any host.</Caption>
              {state.unrecognized.map((r, i) => (
                <div key={r.key} className="edc-vstack" style={{ gap: 4, padding: '4px 0' }}>
                  <div className="edc-hrow top">
                    <Toggle checked={r.include} onChange={v => setUn(i, { include: v })} />
                    <div className="edc-vstack" style={{ gap: 1 }}>
                      <span className="edc-sub500 mono">{r.name}</span>
                      <span className="ed-caption mono">{masked(r.value)}</span>
                    </div>
                  </div>
                  <div className="edc-hrow" style={{ paddingLeft: 26, gap: 6 }}>
                    <span className="ed-caption">Host(s)</span>
                    <Field value={r.hostsText} onChange={v => setUn(i, { hostsText: v })} placeholder="api.example.com, example.dev  (blank = any host)" />
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
        <div className="edc-sheet-foot">
          <div style={{ flex: 1 }} />
          <Button variant="prominent" disabled={count === 0} onClick={onImport}>Import {count} credential{count === 1 ? '' : 's'}</Button>
        </div>
      </div>
    </Sheet>
  );
}
