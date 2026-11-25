// Shared by the Models, Fusion and Squelch panes: the ModelSettings wire
// model (Inference/ModelSettings.swift), the on-device catalog as the server
// reports it (/state.localModels), subscription sign-in (POST
// /subscriptions/register|forget) and the macOS 26 checkbox these panes draw.

import React, { useEffect, useRef, useState } from 'react';
import { Button, Sheet, Spinner, cx } from '../../../ui/kit';
import { isAgentSignInURL, parseCallbackPaste, deliverCallback } from './signIn';
import { canListenLoopback, startCallbackTunnel } from './callbackTunnel';
import { openExternal } from '../../../platform';
import { useRemote } from '../../../app/store';
import type { RemoteHost } from '../../../core/remote/host';
import type { Doc } from '../model';
import type { EditorCtxValue } from '../ctx';
import './Models.css';

// ── providers / agents / tiers ──────────────────────────────────────────

export const PROVIDERS = ['anthropic', 'openai', 'xai', 'zai', 'moonshot', 'bedrock', 'openrouter', 'custom', 'nous'] as const;
export type Provider = typeof PROVIDERS[number];
export const PROVIDER_NAME: Record<Provider, string> = {
  anthropic: 'Anthropic (Claude)', openai: 'OpenAI', xai: 'xAI (Grok)', zai: 'z.ai (GLM)', moonshot: 'Moonshot (Kimi)',
  bedrock: 'Amazon Bedrock', openrouter: 'OpenRouter', custom: 'Custom (OpenAI-compatible)', nous: 'Nous Portal',
};
/** Custom is a UI concept (the custom server), not a listed cloud provider. */
export const CLOUD_PROVIDERS = PROVIDERS.filter(p => p !== 'custom');
export const SUPPORTS_SUBSCRIPTION = new Set<Provider>(['anthropic', 'openai', 'xai', 'moonshot', 'nous']);
const OPENAI_COMPATIBLE = new Set<Provider>(['openrouter', 'xai', 'moonshot']);
const ANTHROPIC_GATEWAY = new Set<Provider>(['openrouter', 'zai']);
const OMP_PROVIDERS = new Set<Provider>(['anthropic', 'openai', 'xai', 'zai', 'custom', 'nous']);

export const AGENTS = ['claude', 'codex', 'grok', 'kimi', 'omp', 'hermes'] as const;
export type Agent = typeof AGENTS[number];
export const AGENT_NAME: Record<Agent, string> = { claude: 'Claude Code', codex: 'Codex', grok: 'Grok', kimi: 'Kimi', omp: 'omp', hermes: 'Hermes' };
export const NATIVE_PROVIDER: Partial<Record<Agent, Provider>> = { claude: 'anthropic', codex: 'openai', grok: 'xai', kimi: 'moonshot' };
export const defaultNativeProvider = (a: Agent): Provider => NATIVE_PROVIDER[a] ?? 'anthropic';
export const NATIVE_AGENT: Partial<Record<Provider, Agent>> = { anthropic: 'claude', bedrock: 'claude', openai: 'codex', xai: 'grok', moonshot: 'kimi', nous: 'hermes' };

/** ModelProvider.canRoute(agent, native:) */
export function canRoute(p: Provider, agent: Agent, native: Provider): boolean {
  if (p === 'nous') return agent === 'hermes';
  if (p === native || p === 'bedrock') return true;
  if ((agent === 'omp' || agent === 'hermes') && OMP_PROVIDERS.has(p)) return true;
  return agent === 'claude' ? ANTHROPIC_GATEWAY.has(p) : OPENAI_COMPATIBLE.has(p);
}

export const TIERS = ['small', 'medium', 'large'] as const;
export type Tier = typeof TIERS[number];
export const TIER_NAME: Record<Tier, string> = { small: 'Small', medium: 'Medium', large: 'Large' };
export const TIER_HINT: Record<Tier, string> = { small: 'haiku', medium: 'sonnet', large: 'opus' };

/** The subscription stores' keys (/state.subscriptions) and sign-in providers. */
export const SUB_KEY: Partial<Record<Provider, string>> = { anthropic: 'claude', openai: 'codex', xai: 'grok', moonshot: 'kimi', nous: 'hermes' };
const REGISTER_NAME: Partial<Record<Provider, string>> = { anthropic: 'claude', openai: 'codex', xai: 'grok', moonshot: 'kimi', nous: 'nous' };
const SIGNIN_NAME: Partial<Record<Provider, string>> = { anthropic: 'Claude', openai: 'ChatGPT', xai: 'Grok', moonshot: 'Kimi', nous: 'Nous Portal' };

export const REDACTED = '••••••••';
export const isRedactedSecret = (v?: string | null) => { const t = (v ?? '').trim(); return !t || t === REDACTED; };

// ── ModelSettings (wire JSON) ───────────────────────────────────────────

export type Source = { kind: 'provider'; p: Provider } | { kind: 'localServer' } | { kind: 'localRun'; id: string };
export interface Ref { source: any; modelID: string; capabilities: any; capabilitiesOverridden: boolean }
export interface Cred { provider: Provider; apiKey?: string | null; useSubscription: boolean; baseURL?: string | null; region?: string | null }
export interface Settings {
  providers: Cred[]; localServer?: { baseURL: string; apiKey?: string | null } | null; localRunModels: string[];
  tiers: Partial<Record<Tier, Ref>>; agentTiers: Partial<Record<Agent, Partial<Record<Tier, Ref>>>>; agentEnvironment: string;
}

export function sourceOf(r: Ref): Source {
  const s = r.source ?? {};
  if (s.provider) return { kind: 'provider', p: (s.provider._0 ?? s.provider) as Provider };
  if (s.localRun) return { kind: 'localRun', id: s.localRun.catalogID ?? s.localRun._0 };
  return { kind: 'localServer' };
}
export function wireSource(s: Source): any {
  return s.kind === 'provider' ? { provider: { _0: s.p } } : s.kind === 'localRun' ? { localRun: { catalogID: s.id } } : { localServer: {} };
}
export const sameSource = (a: Source, b: Source) => JSON.stringify(a) === JSON.stringify(b);
export const isLocalRef = (r: Ref) => sourceOf(r).kind !== 'provider';

/** Swift encodes `[Enum: V]` as a flat [key, value, key, value] array. */
function pairs(raw: any): [string, any][] {
  if (Array.isArray(raw)) { const out: [string, any][] = []; for (let i = 0; i + 1 < raw.length; i += 2) out.push([raw[i], raw[i + 1]]); return out; }
  return raw && typeof raw === 'object' ? Object.entries(raw) : [];
}
const unpairs = (m: Record<string, any>) => Object.entries(m).filter(([, v]) => v != null).flatMap(([k, v]) => [k, v]);

export function decodeSettings(raw: Doc | null | undefined): Settings {
  const r = raw ?? {};
  const tiers: Settings['tiers'] = {};
  for (const [k, v] of pairs(r.tiers)) tiers[k as Tier] = v;
  const agentTiers: Settings['agentTiers'] = {};
  for (const [a, t] of pairs(r.agentTiers)) { const m: any = {}; for (const [k, v] of pairs(t)) m[k] = v; agentTiers[a as Agent] = m; }
  return {
    providers: (r.providers ?? []).map((c: any) => ({ ...c, useSubscription: !!c.useSubscription })),
    localServer: r.localServer ?? null, localRunModels: r.localRunModels ?? [], tiers, agentTiers,
    agentEnvironment: r.agentEnvironment ?? '',
  };
}
export function encodeSettings(s: Settings, base: Doc = {}): Doc {
  const out: Doc = { ...base, providers: s.providers, localRunModels: s.localRunModels, tiers: unpairs(s.tiers),
    agentTiers: unpairs(Object.fromEntries(Object.entries(s.agentTiers).filter(([, t]) => t && Object.keys(t).length)
      .map(([a, t]) => [a, unpairs(t as any)]))), agentEnvironment: s.agentEnvironment };
  if (s.localServer) out.localServer = s.localServer; else delete out.localServer;
  return out;
}

export const credential = (s: Settings, p: Provider) => s.providers.find(c => c.provider === p);
export function isUsable(c?: Cred | null): boolean {
  if (!c) return false;
  if (c.provider === 'bedrock' || c.useSubscription) return true;
  if ((c.apiKey ?? '').trim()) return true;
  return c.provider === 'custom' && !!(c.baseURL ?? '').trim();
}
export const refFor = (s: Settings, agent: Agent, tier: Tier) => s.agentTiers[agent]?.[tier] ?? s.tiers[tier];

export interface Override { inheritsGlobal: boolean; settings: Settings; excludedProviders: Provider[] }
export function decodeOverride(raw: any): Override | null {
  if (!raw) return null;
  if ('inheritsGlobal' in raw || 'settings' in raw)
    return { inheritsGlobal: raw.inheritsGlobal ?? true, settings: decodeSettings(raw.settings), excludedProviders: raw.excludedProviders ?? [] };
  return { inheritsGlobal: false, settings: decodeSettings(raw), excludedProviders: [] };
}
export function encodeOverride(o: Override, prev?: any): Doc {
  return { inheritsGlobal: o.inheritsGlobal, settings: encodeSettings(o.settings, prev?.settings), excludedProviders: o.excludedProviders };
}

/** ModelOverride.resolved(over:) */
export function resolved(o: Override, global: Settings): Settings {
  if (!o.inheritsGlobal) return o.settings;
  const out: Settings = structuredClone(global);
  out.providers = out.providers.filter(c => !o.excludedProviders.includes(c.provider));
  for (const own of o.settings.providers) { out.providers = out.providers.filter(c => c.provider !== own.provider); out.providers.push(own); }
  if (o.settings.localServer) out.localServer = o.settings.localServer;
  else if (o.excludedProviders.includes('custom')) out.localServer = null;
  for (const id of o.settings.localRunModels) if (!out.localRunModels.includes(id)) out.localRunModels.push(id);
  for (const [t, r] of Object.entries(o.settings.tiers)) (out.tiers as any)[t] = r;
  for (const [a, tiers] of Object.entries(o.settings.agentTiers)) {
    const merged = { ...(out.agentTiers[a as Agent] ?? {}), ...(tiers ?? {}) };
    if (Object.keys(merged).length) out.agentTiers[a as Agent] = merged; else delete out.agentTiers[a as Agent];
  }
  return out;
}

/** The settings a workspace runs with (its override over the host's global). */
export function effectiveSettings(ctx: EditorCtxValue): Settings {
  const global = decodeSettings(ctx.globalModels);
  if (ctx.mode === 'preferences') return global;
  const o = decodeOverride(ctx.doc.modelOverride);
  return o ? resolved(o, global) : global;
}

// ── subscriptions ───────────────────────────────────────────────────────

export interface SubStatus { registeredAt?: number; reauthRequiredAt?: number; lastRefreshedAt?: number; accessExpiresAt?: number; storeUnreadable?: boolean }
export function useSubscriptions(host: RemoteHost): Record<string, SubStatus> {
  return (useRemote(host, s => s.subscriptions) ?? {}) as Record<string, SubStatus>;
}
export const subFor = (subs: Record<string, SubStatus>, p: Provider): SubStatus | undefined => {
  const k = SUB_KEY[p]; const s = k ? subs[k] : undefined;
  return s?.registeredAt ? s : undefined;
};
/** Providers with a host-side sign-in (Fusion's `subscribed`). */
export const subscribedProviders = (subs: Record<string, SubStatus>) =>
  new Set((['anthropic', 'openai', 'xai', 'moonshot', 'nous'] as Provider[]).filter(p => subFor(subs, p)));

export function relative(ts?: number): string {
  if (!ts) return '';
  const d = ts * 1000 - Date.now(), a = Math.abs(d) / 1000;
  const [n, u] = a < 60 ? [Math.round(a), 'second'] : a < 3600 ? [Math.round(a / 60), 'minute'] : a < 86400 ? [Math.round(a / 3600), 'hour'] : [Math.round(a / 86400), 'day'];
  return new Intl.RelativeTimeFormat('en', { numeric: 'auto' }).format(d < 0 ? -n : n, u as any);
}

/** A confirm/alert sheet these panes raise (NSAlert). */
export interface Ask { title: string; message?: string; ok: string; destructive?: boolean; cancel?: string; onOK?: () => void; field?: { placeholder: string; value: string; onOK: (v: string) => void } }
export function AskSheet({ ask, done }: { ask: Ask; done: () => void }) {
  const [v, setV] = useState(ask.field?.value ?? '');
  const ok = () => { done(); if (ask.field) ask.field.onOK(v); else ask.onOK?.(); };
  return (
    <Sheet width={ask.field ? 340 : 300} onClose={done}>
      <div className="mdl-ask">
        <div className="mdl-ask-title">{ask.title}</div>
        {ask.message && <div className="mdl-ask-msg">{ask.message}</div>}
        {ask.field && <input className="field" autoFocus spellCheck={false} placeholder={ask.field.placeholder} value={v}
                            onChange={e => setV(e.target.value)} onKeyDown={e => { if (e.key === 'Enter') { e.stopPropagation(); ok(); } }} />}
        <div className="mdl-ask-buttons">
          {ask.cancel !== '' && <Button onClick={done}>{ask.cancel ?? 'Cancel'}</Button>}
          <Button variant="prominent" destructive={ask.destructive} onClick={ok}>{ask.ok}</Button>
        </div>
      </div>
    </Sheet>
  );
}

/** Sign-in / log-out on the HOST (FatClientController.beginRemoteRegistration):
 *  the throwaway login VM and the credential store stay on the server; the
 *  sign-in page it publishes in /state.pendingRegistration opens here, and
 *  its loopback callback goes back to the VM (signIn.ts). */
export function useSignIn(ctx: EditorCtxValue) {
  const { host, mode, workspaceID, hostName } = ctx;
  const [ask, setAsk] = useState<Ask | null>(null);
  // State, not a ref: the host's /state can publish the sign-in page before
  // the register request's reply names the run — the effect must re-run then.
  const [run, setRun] = useState<RunInfo | null>(null);
  // Closed after the callback went in: the run is still watched for its end.
  const [hidden, setHidden] = useState(false);
  const opened = useRef(new Set<string>());
  const tunnel = useRef<{ key: string; stop: () => void } | null>(null);
  const [page, setPage] = useState<{ url?: string; refused?: boolean; callback?: { vmIP: string; port: number }; listening?: boolean; listenError?: string }>({});
  const pending = useRemote(host, s => s.pendingRegistration);
  const ended = useRemote(host, s => s.registrationsEnded);
  const stopTunnel = () => { tunnel.current?.stop(); tunnel.current = null; };
  useEffect(() => () => stopTunnel(), []);
  useEffect(() => {
    const p = pending as any;
    if (!run || !p || p.id !== run.id) return;
    const next: Partial<typeof page> = {};
    if (p.url && !opened.current.has(p.url)) {
      opened.current.add(p.url);
      if (isAgentSignInURL(p.url, run.provider)) { next.url = p.url; openExternal(p.url); }
      else next.refused = true;            // never opened: not that agent's sign-in page
    }
    const refused = next.refused ?? page.refused;
    const port = Number(p.callbackPort) || 0;
    // A refused page gets no callback either (as on the Mac).
    if (refused) stopTunnel();
    else if (port > 0 && p.vmIP) {
      next.callback = { vmIP: p.vmIP, port };
      const key = `${p.vmIP}:${port}`;
      if (canListenLoopback() && tunnel.current?.key !== key) {
        stopTunnel();
        tunnel.current = { key, stop: () => {} };
        startCallbackTunnel(host, p.vmIP, port)
          .then(stop => { if (tunnel.current?.key === key) { tunnel.current.stop = stop; setPage(x => ({ ...x, listening: true })); } else stop(); })
          .catch((e: any) => setPage(x => ({ ...x, listenError: String(e?.message ?? e) })));
      }
    }
    setPage(x => ({ ...x, ...next }));
  }, [pending, run]); // eslint-disable-line react-hooks/exhaustive-deps
  const finishRun = () => { stopTunnel(); setRun(null); setPage({}); opened.current.clear(); };
  useEffect(() => {
    if (!run) return;
    const e = ((ended as any[]) ?? []).find(x => x?.id === run.id);
    if (!e) return;
    finishRun();
    if (!e.success) setAsk({ title: 'Register', message: e.message || 'The sign-in didn’t complete. You can try again.', ok: 'OK', cancel: '' });
  }, [ended, run]); // eslint-disable-line react-hooks/exhaustive-deps
  // Sign-ins from a workspace not created yet go to the host's shared store.
  const profileId = mode === 'workspace' ? workspaceID : undefined;
  const register = (p: Provider) => {
    const name = SIGNIN_NAME[p] ?? PROVIDER_NAME[p];
    setAsk({
      title: `Register with ${name} on ${hostName}?`,
      message: `${name} opens a temporary, isolated VM on the remote Mac with no access to its workspaces or saved secrets. The sign-in page opens in YOUR browser here; the credentials are captured and stored on the remote, then the VM is deleted.`,
      ok: 'Continue',
      onOK: async () => {
        try {
          const r = await host.request<any>('POST', '/subscriptions/register', { provider: REGISTER_NAME[p], ...(profileId ? { profileId } : {}) }, { allowError: true });
          if (r?.registration) { opened.current.clear(); setPage({}); setHidden(false); setRun({ id: r.registration, provider: REGISTER_NAME[p]!, name }); }
          else setAsk({ title: `Register with ${name}`, message: r?.error || 'The sign-in didn’t complete. You can try again.', ok: 'OK', cancel: '' });
          host.refreshSoon();
        } catch (e: any) { setAsk({ title: `Register with ${name}`, message: String(e?.message ?? e), ok: 'OK', cancel: '' }); }
      },
    });
  };
  const cancelRun = () => {
    if (run) host.send('POST', '/subscriptions/cancel', { registration: run.id });
    finishRun();
  };
  const forget = (p: Provider) => setAsk({
    title: `Log out of ${PROVIDER_NAME[p]}?`, message: 'Workspaces using this sign-in stop working until you sign in again.',
    ok: 'Log Out', destructive: true,
    onOK: () => host.send('POST', '/subscriptions/forget', { provider: SUB_KEY[p], ...(profileId ? { profileId } : {}) }),
  });
  const sheet = ask ? <AskSheet ask={ask} done={() => setAsk(null)} />
    : run && !hidden ? <SignInSheet run={run} page={page} hostName={hostName} onCancel={cancelRun} onHide={() => setHidden(true)}
                         deliver={async path => {
                           const cb = page.callback!;
                           const status = await deliverCallback(() => host.openForward(`forward ${cb.vmIP} ${cb.port}`), cb.port, path);
                           if (status >= 400) throw new Error(`The sign-in machine refused it (HTTP ${status}). Start the sign-in again.`);
                         }} />
    : null;
  return { register, forget, sheet, setAsk };
}

interface RunInfo { id: string; provider: string; name: string }

/** The in-flight sign-in: open the page again, and — when the browser can't
 *  reach the callback on this computer (always, in a web page) — paste the
 *  address it ended on so it goes to the VM. */
function SignInSheet({ run, page, hostName, onCancel, onHide, deliver }: {
  run: RunInfo; hostName: string; onCancel: () => void; onHide: () => void; deliver: (path: string) => Promise<void>;
  page: { url?: string; refused?: boolean; callback?: { vmIP: string; port: number }; listening?: boolean; listenError?: string };
}) {
  const [pasted, setPasted] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [sent, setSent] = useState(false);
  const [busy, setBusy] = useState(false);
  const port = page.callback?.port;
  const submit = async () => {
    if (!port) return;
    const r = parseCallbackPaste(pasted, port);
    if ('error' in r) { setErr(r.error); return; }
    setErr(null); setBusy(true);
    try { await deliver(r.path); setSent(true); }
    catch (e: any) { setErr(String(e?.message ?? e)); }
    setBusy(false);
  };
  const status = sent ? `Finishing the ${run.name} sign-in on ${hostName}…`
    : page.refused ? `${hostName} published a sign-in address that isn’t ${run.name}’s own sign-in page, so it wasn’t opened.`
    : page.url ? `Sign in to ${run.name} in your browser.`
    : `Starting a sign-in machine on ${hostName}…`;
  return (
    <Sheet width={440} onClose={sent ? onHide : onCancel}>
      <div className="mdl-ask">
        <div className="mdl-ask-title">Register with {run.name}</div>
        <div className="mdl-ask-msg" style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
          {!page.url && !page.refused && !sent && <Spinner size={12} />}{status}
        </div>
        {page.url && !sent && <div><Button size="small" onClick={() => openExternal(page.url!)}>Open the Sign-In Page Again</Button></div>}
        {page.listenError && !sent && <div className="mdl-ask-msg">Couldn’t answer the sign-in on this computer ({page.listenError}).</div>}
        {port && !sent && !page.refused && <>
          <div className="mdl-ask-msg">
            {page.listening
              ? `If your browser ends on a page that can’t connect to localhost:${port}, copy that page’s address from the address bar and paste it here:`
              : `When you’ve signed in, your browser ends on a page that can’t connect to localhost:${port} — that’s expected. Copy that page’s address from the address bar and paste it here:`}
          </div>
          <input className="field" spellCheck={false} placeholder={`http://localhost:${port}/callback?code=…`} value={pasted}
                 onChange={e => setPasted(e.target.value)} onKeyDown={e => { if (e.key === 'Enter') { e.stopPropagation(); submit(); } }} />
        </>}
        {err && <div className="mdl-ask-msg" style={{ color: 'var(--red)' }}>{err}</div>}
        <div className="mdl-ask-buttons">
          <Button onClick={sent ? onHide : onCancel}>{sent ? 'Close' : 'Cancel'}</Button>
          {port && !sent && !page.refused && <Button variant="prominent" disabled={busy || !pasted.trim()} onClick={submit}>Finish Sign-In</Button>}
        </div>
      </div>
    </Sheet>
  );
}

// ── on-device catalog (the server's) ────────────────────────────────────

export interface CatalogModel { id: string; repo: string; name: string; downloadGB: number; minMemGB: number; context?: number; recommended: boolean; reasoning?: boolean; vision?: boolean }
/** Resources/catalog.json — the bundled baseline (the server reports its own
 *  catalog's repos in /state.localModels; unknown ones are its extras). */
const BASELINE: CatalogModel[] = [
  { id: 'qwen3-8b-mlx-4bit-dwq', repo: 'mlx-community/Qwen3-8B-4bit-DWQ', name: 'Qwen3 8B (4-bit DWQ MLX)', downloadGB: 4.3, minMemGB: 16, context: 40960, recommended: true, reasoning: true },
  { id: 'qwen3-coder-30b-a3b-mlx-4bit-dwq', repo: 'mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit-dwq-v2', name: 'Qwen3-Coder 30B-A3B (4-bit DWQ MLX)', downloadGB: 17, minMemGB: 32, context: 256000, recommended: true, reasoning: true },
  { id: 'qwen3-coder-next-mlx-mxfp4', repo: 'mlx-community/Qwen3-Coder-Next-mxfp4', name: 'Qwen3-Coder-Next 80B-A3B (mxfp4 MLX)', downloadGB: 42, minMemGB: 96, context: 256000, recommended: true },
  { id: 'qwen3-coder-480b-a35b-mlx-4bit', repo: 'mlx-community/Qwen3-Coder-480B-A35B-Instruct-4bit', name: 'Qwen3-Coder 480B-A35B (4-bit MLX)', downloadGB: 270, minMemGB: 512, context: 256000, recommended: false },
];
export const displayName = (m: CatalogModel) => m.name.includes('/') ? m.name.slice(m.name.indexOf('/') + 1) : m.name;

export interface LocalModelState { installed?: boolean; sizeGB?: number; phase?: 'downloading' | 'failed' | 'interrupted'; frac?: number; label?: string; msg?: string }
export function useLocalModels(host: RemoteHost) {
  const lm = useRemote(host, s => s.localModels) as { unifiedMemGB?: number; models?: Record<string, LocalModelState> } | undefined;
  const states = lm?.models ?? {};
  const catalog: CatalogModel[] = [...BASELINE];
  for (const [repo, st] of Object.entries(states)) {
    if (!catalog.some(m => m.repo === repo)) {
      const gb = Math.round((st.sizeGB ?? 0) * 10) / 10;
      catalog.push({ id: repo, repo, name: repo, downloadGB: gb, minMemGB: Math.max(8, Math.ceil(gb) + 8), recommended: false });
    }
  }
  catalog.sort((a, b) => a.recommended !== b.recommended ? (a.recommended ? -1 : 1) : a.minMemGB !== b.minMemGB ? a.minMemGB - b.minMemGB : a.name.localeCompare(b.name));
  const installed = catalog.filter(m => states[m.repo]?.installed && !states[m.repo]?.phase);
  return { memGB: lm?.unifiedMemGB ?? 0, states, catalog, installed };
}
/** RAMFitGate.fit — headroom 16 GB. */
export function ramFit(m: CatalogModel, memGB: number): 'fits' | 'tight' | 'wontFit' {
  if (memGB < m.minMemGB) return 'wontFit';
  return memGB < m.minMemGB + 16 ? 'tight' : 'fits';
}
export const FIT_BADGE = { fits: 'Fits', tight: 'Tight', wontFit: 'Won’t fit' } as const;

// ── macOS 26 checkbox ───────────────────────────────────────────────────

/** Toggle(...) in the default (checkbox) style: a 16pt filled square. */
export function Check({ checked, onChange, disabled, children, className, labelClass }: {
  checked: boolean; onChange: (v: boolean) => void; disabled?: boolean; children?: React.ReactNode; className?: string; labelClass?: string;
}) {
  return (
    <label className={cx('mdl-check', disabled && 'disabled', className)}>
      <input type="checkbox" checked={checked} disabled={disabled} onChange={e => onChange(e.target.checked)} />
      {children !== undefined && <span className={cx('mdl-check-label', labelClass)}>{children}</span>}
    </label>
  );
}
