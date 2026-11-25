// Models — ProfileViews.swift `localModelsSection` → Inference/ModelsSettingsView.swift:
//   Preferences  ModelsSettingsView bound to the host's global settings (a
//                draft, PUT /models/settings on Save — the `.remoteGlobal` mode)
//   workspace    WorkspaceModelsSettingsView: an optional override (layered or
//                standalone) of the host's global settings, in `modelOverride`.
// Sign-ins run on the host (POST /subscriptions/register|forget); on-device
// models are the SERVER's (/state.localModels, POST /models/download|…).

import React, { useEffect, useMemo, useState } from 'react';
import { probeCustomServer } from './probeServer';
import { Button, Popover, Segmented, Spinner, cx, useMenu, type MenuItem } from '../../../ui/kit';
import { SF } from '../../../ui/icons';
import { useEditor } from '../ctx';
import type { EditorCtxValue } from '../ctx';
import {
  AGENTS, AGENT_NAME, AskSheet, CLOUD_PROVIDERS, Check, FIT_BADGE, NATIVE_AGENT, NATIVE_PROVIDER, PROVIDER_NAME, REDACTED,
  SUPPORTS_SUBSCRIPTION, TIER_HINT, TIER_NAME, canRoute, credential, decodeOverride, decodeSettings, defaultNativeProvider,
  displayName, encodeOverride, encodeSettings, isUsable, ramFit, relative, resolved as resolveOverride, sameSource, sourceOf,
  subFor, useLocalModels, useSignIn, useSubscriptions, wireSource,
  type Agent, type Ask, type Cred, type Override, type Provider, type Ref, type Settings, type Source, type Tier,
} from './ModelsShared';

export function ModelsPane() {
  const ctx = useEditor();
  if (ctx.mode === 'preferences') {
    return <ModelsBoard ctx={ctx} settings={decodeSettings(ctx.globalModels)}
                        onChange={fn => ctx.setGlobalModels?.(m => {
                          const s = decodeSettings(m); fn(s);
                          const enc = encodeSettings(s, m);
                          for (const k of Object.keys(m)) delete m[k];
                          Object.assign(m, enc);
                        })} />;
  }
  return <WorkspaceModels ctx={ctx} />;
}

// ── WorkspaceModelsSettingsView ─────────────────────────────────────────

const emptyOverride = (): Override => ({ inheritsGlobal: true, settings: decodeSettings({}), excludedProviders: [] });

function WorkspaceModels({ ctx }: { ctx: EditorCtxValue }) {
  const raw = ctx.doc.modelOverride;
  const override = decodeOverride(raw);
  const global = decodeSettings(ctx.globalModels);
  const setOverride = (o: Override | null) => ctx.set('modelOverride', o ? encodeOverride(o, raw) : null);
  const mutateOverride = (fn: (o: Override) => void) => {
    ctx.update(d => { const o = decodeOverride(d.modelOverride); if (!o) return; fn(o); d.modelOverride = encodeOverride(o, d.modelOverride); });
  };
  return (
    <div className="mdl-ws">
      <div className="mdl-ws-head">
        <Check checked={override != null} onChange={on => setOverride(on ? emptyOverride() : null)}>
          <span className="mdl-ws-title">Custom model settings for this workspace</span>
          <span className="mdl-caption">{override == null
            ? 'Inheriting the global settings (Preferences → Models).'
            : override.inheritsGlobal
              ? 'Starts from the global settings; only what you set below is different here.'
              : 'This workspace has its own providers, logins and model choices below — the global settings are ignored.'}</span>
        </Check>
        {override && (
          <div className="mdl-ws-mode">
            <Segmented value={override.inheritsGlobal ? 'layered' : 'standalone'}
                       options={[{ value: 'layered', label: 'Inherit, with changes' }, { value: 'standalone', label: 'Standalone' }]}
                       onChange={v => {
                         const layered = v === 'layered';
                         if (layered === override.inheritsGlobal) return;
                         // Standalone seeds from what's live; back to layered starts empty.
                         setOverride(layered ? emptyOverride()
                                             : { inheritsGlobal: false, settings: resolveOverride(override, global), excludedProviders: [] });
                       }} />
          </div>
        )}
      </div>
      <div className="mdl-fullrule" />
      {override ? (
        <ModelsBoard ctx={ctx} settings={override.settings}
                     onChange={fn => mutateOverride(o => fn(o.settings))}
                     layer={override.inheritsGlobal ? {
                       global, excluded: override.excludedProviders,
                       setExcluded: (p, on) => mutateOverride(o => { o.excludedProviders = o.excludedProviders.filter(x => x !== p); if (on) o.excludedProviders.push(p); }),
                     } : undefined} />
      ) : (
        <div className="mdl-summary">
          <div className="mdl-headline">Inherited models</div>
          {(['large', 'medium', 'small'] as Tier[]).map(t => (
            <div key={t} className="mdl-summary-row"><span className="mdl-summary-tier">{TIER_NAME[t]}</span><span>{global.tiers[t]?.modelID ?? '—'}</span></div>
          ))}
          {global.providers.some(isUsable) && (
            <div className="mdl-summary-row secondary">Providers: {global.providers.filter(isUsable).map(c => PROVIDER_NAME[c.provider]).join(', ')}</div>
          )}
          <div className="mdl-caption" style={{ paddingTop: 4 }}>Turn on the switch above to give this workspace its own keys, logins or models — for some providers or all of them.</div>
        </div>
      )}
    </div>
  );
}

// ── ModelsSettingsView ──────────────────────────────────────────────────

interface Layer { global: Settings; excluded: Provider[]; setExcluded: (p: Provider, on: boolean) => void }
type SourceID = { kind: 'provider'; p: Provider } | { kind: 'customServer' } | { kind: 'onDevice' };
const sid = (s: SourceID) => s.kind === 'provider' ? `p.${s.p}` : s.kind;

const SUGGESTIONS: Record<Provider, Record<Tier, string[]> | string[]> = {
  anthropic: { large: ['claude-opus-5', 'claude-fable-5-1', 'claude-opus-4-8', 'claude-sonnet-5'], medium: ['claude-sonnet-5', 'claude-sonnet-4-6', 'claude-opus-5'], small: ['claude-haiku-4-5-20251001', 'claude-sonnet-5'] },
  openai: ['gpt-5.5', 'gpt-5.2', 'gpt-5', 'gpt-4o'], xai: ['grok-4', 'grok-4-fast', 'grok-3'], zai: ['glm-5.3', 'glm-5.3-flash', 'glm-4.6'],
  moonshot: ['kimi-k2.5', 'kimi-k2', 'kimi-k2-turbo-preview'], nous: ['anthropic/claude-sonnet-5.5', 'anthropic/claude-opus-5.5', 'openai/gpt-5.5'],
  openrouter: ['anthropic/claude-sonnet-4.6', 'openai/gpt-5.2'],
  bedrock: { large: ['us.anthropic.claude-opus-4-8', 'us.anthropic.claude-sonnet-4-6'], medium: ['us.anthropic.claude-sonnet-4-6', 'openai.gpt-oss-120b-1:0'], small: ['us.anthropic.claude-haiku-4-5-20251001-v1:0', 'openai.gpt-oss-20b-1:0'] },
  custom: [],
};
function suggestions(p: Provider, tier: Tier): string[] { const s = SUGGESTIONS[p]; return Array.isArray(s) ? s : s[tier]; }
/** ProviderModels.allSuggestions + ordered(for:tier:) (the live list needs the host's keys). */
function modelOptions(p: Provider, tier: Tier): string[] {
  const all: string[] = [];
  for (const t of ['large', 'medium', 'small'] as Tier[]) for (const id of suggestions(p, t)) if (!all.includes(id)) all.push(id);
  if (p !== 'anthropic' && p !== 'bedrock') return all;
  const hints = tier === 'large' ? ['opus', 'fable'] : tier === 'medium' ? ['sonnet'] : ['haiku'];
  const pref = all.filter(id => hints.some(h => id.toLowerCase().includes(h)));
  return [...pref, ...all.filter(id => !pref.includes(id))];
}

const DOT = { green: 'var(--green)', orange: 'var(--orange)', mint: 'var(--mint)', purple: 'var(--purple)', off: 'var(--mdl-dot-off)', blue: 'var(--blue)' };

type Probe = { s: 'idle' } | { s: 'probing' } | { s: 'ok'; n: number } | { s: 'failed'; why: string };

export function ModelsBoard({ ctx, settings, onChange, layer }: {
  ctx: EditorCtxValue; settings: Settings; onChange: (fn: (s: Settings) => void) => void; layer?: Layer;
}) {
  const subs = useSubscriptions(ctx.host);
  const signIn = useSignIn(ctx);
  const local = useLocalModels(ctx.host);
  const menu = useMenu();
  const [open, setOpen] = useState<{ id: string; at: DOMRect } | null>(null);
  const [openSizes, setOpenSizes] = useState<Set<string>>(new Set());
  const [serverModels, setServerModels] = useState<string[]>([]);
  const [probe, setProbe] = useState<Probe>({ s: 'idle' });
  const [ask, setAsk] = useState<Ask | null>(null);

  const excluded = layer?.excluded ?? [];
  const res: Settings = useMemo(() => layer ? resolveOverride({ inheritsGlobal: true, settings, excludedProviders: excluded }, layer.global) : settings,
    [settings, layer, excluded]);
  const status = (p: Provider): 'inherited' | 'overridden' | 'excluded' | 'unset' | null => {
    if (!layer) return null;
    if (credential(settings, p)) return 'overridden';
    if (excluded.includes(p)) return 'excluded';
    return credential(layer.global, p) ? 'inherited' : 'unset';
  };
  const savedAt = (p: Provider) => SUPPORTS_SUBSCRIPTION.has(p) ? subFor(subs, p)?.registeredAt : undefined;
  const reauthAt = (p: Provider) => SUPPORTS_SUBSCRIPTION.has(p) ? subFor(subs, p)?.reauthRequiredAt : undefined;
  // A host-side sign-in makes its provider usable (syncSubscriptions) — read
  // here, not written into the draft on open.
  const effCred = (p: Provider): Cred | undefined => {
    const c = credential(res, p);
    if (c) return c;
    if (savedAt(p) && status(p) !== 'excluded') return { provider: p, useSubscription: true };
    return undefined;
  };
  const usableProviders = CLOUD_PROVIDERS.filter(p => isUsable(effCred(p)));
  const providerAllowed = (p: Provider, agent: Agent | null) => {
    const c = effCred(p); if (!c || !isUsable(c)) return false;
    if (agent && !canRoute(p, agent, defaultNativeProvider(agent))) return false;
    if (c.useSubscription) return agent != null && agent === NATIVE_AGENT[p];
    return true;
  };
  const explicitRef = (agent: Agent | null, tier: Tier) => agent ? settings.agentTiers[agent]?.[tier] : settings.tiers[tier];
  const effectiveRef = (agent: Agent | null, tier: Tier) => agent ? (res.agentTiers[agent]?.[tier] ?? res.tiers[tier]) : res.tiers[tier];
  const nativeUsable = (agent: Agent | null) => {
    const p = agent ? NATIVE_PROVIDER[agent] : undefined; if (!p) return false;
    if (status(p) === 'excluded') return false;
    return isUsable(credential(res, p)) || savedAt(p) != null;
  };

  const assignRef = (agent: Agent | null, tier: Tier, ref: Ref | null) => onChange(s => {
    if (!agent) { if (ref) s.tiers[tier] = ref; else delete s.tiers[tier]; return; }
    const t = { ...(s.agentTiers[agent] ?? {}) };
    if (ref) t[tier] = ref; else delete t[tier];
    if (Object.keys(t).length) s.agentTiers[agent] = t; else delete s.agentTiers[agent];
  });
  const assign = (agent: Agent | null, tier: Tier, source: Source, modelID: string) => {
    const ex = explicitRef(agent, tier);
    let ref: Ref = { source: wireSource(source), modelID, capabilities: {}, capabilitiesOverridden: false };
    if (ex && sameSource(sourceOf(ex), source) && ex.modelID === modelID && ex.capabilitiesOverridden) ref = ex;
    else if (source.kind === 'localRun') {
      const m = local.catalog.find(x => x.id === source.id);
      if (m) ref.capabilities = { contextWindow: m.context, reasoning: !!m.reasoning, inputs: m.vision ? ['text', 'image'] : ['text'] };
    } else if (source.kind === 'provider') ref.capabilities = capabilities(modelID) ?? {};
    assignRef(agent, tier, ref);
  };
  const customID = (agent: Agent | null, tier: Tier, source: Source) => setAsk({
    title: 'Model id', message: 'The id exactly as the backend names it (e.g. claude-opus-5, glm-4.6, qwen3-coder).', ok: 'Use',
    field: { placeholder: 'model-id', value: explicitRef(agent, tier)?.modelID ?? '', onOK: v => { const id = v.trim(); if (id) assign(agent, tier, source, id); } },
  });

  const openChipMenu = (e: React.MouseEvent, agent: Agent | null, tier: Tier) => {
    const items: MenuItem[] = [];
    const allowed = usableProviders.filter(p => providerAllowed(p, agent));
    for (const p of allowed) {
      if (items.length) items.push({ separator: true });
      items.push({ header: PROVIDER_NAME[p] });
      for (const id of modelOptions(p, tier)) items.push({ label: id, action: () => assign(agent, tier, { kind: 'provider', p }, id) });
      items.push({ label: 'Custom id…', action: () => customID(agent, tier, { kind: 'provider', p }) });
    }
    if (res.localServer) {
      if (items.length) items.push({ separator: true });
      items.push({ header: 'Custom server' });
      if (!serverModels.length) items.push({ label: 'Test the connection to list models', disabled: true });
      for (const id of serverModels) items.push({ label: id, action: () => assign(agent, tier, { kind: 'localServer' }, id) });
      items.push({ label: 'Custom id…', action: () => customID(agent, tier, { kind: 'localServer' }) });
    }
    if (local.installed.length) {
      if (items.length) items.push({ separator: true });
      items.push({ header: 'On-device' });
      for (const m of local.installed) items.push({ label: displayName(m), action: () => assign(agent, tier, { kind: 'localRun', id: m.id }, m.id) });
    }
    if (!allowed.length && !res.localServer && !local.installed.length) {
      const msg = !usableProviders.length ? 'Configure a provider first'
        : agent && usableProviders.some(p => effCred(p)?.useSubscription !== true) ? `No configured provider can power ${AGENT_NAME[agent]}`
        : 'A subscription can only power its own agent';
      items.push({ label: msg, disabled: true });
    }
    if ((agent || layer) && explicitRef(agent, tier)) {
      items.push({ separator: true });
      const clear = !agent ? 'Use the global setting'
        : nativeUsable(agent) && !Object.keys(res.tiers).length ? `Use ${AGENT_NAME[agent]}’s default` : 'Use Default';
      items.push({ label: clear, action: () => assignRef(agent, tier, null) });
    }
    menu((e.currentTarget as HTMLElement).getBoundingClientRect(), items, 200);
  };

  const chip = (agent: Agent | null, tier: Tier) => {
    const ex = explicitRef(agent, tier), eff = effectiveRef(agent, tier);
    const inherited = (agent != null || layer != null) && !ex && !!eff;
    const placeholder = agent && nativeUsable(agent) ? (tier === 'medium' ? `${AGENT_NAME[agent]} default` : 'default') : undefined;
    let unroutable: string | undefined;
    if (agent && eff) {
      const s = sourceOf(eff);
      if (s.kind === 'provider' && !canRoute(s.p, agent, defaultNativeProvider(agent)))
        unroutable = `${AGENT_NAME[agent]} can’t use ${PROVIDER_NAME[s.p]} models, so it runs on its own provider instead. Pick another model.`;
    }
    const color = unroutable ? DOT.orange : eff ? srcColor(sourceOf(eff)) : undefined;
    const ctxRef = ex && takesContextWindow(sourceOf(ex)) ? ex : null;
    return (
      <span className="mdl-chipwrap">
        <button className="mdl-chip" title={unroutable} onClick={e => openChipMenu(e, agent, tier)}>
          <SF name="chevron.up.chevron.down" size={13} />
          {color && <span className="mdl-dot sm" style={{ background: color }} />}
          <span className={cx('mdl-chip-text', !!unroutable && 'strike secondary', !eff && !!placeholder && 'secondary')}>
            {eff?.modelID ?? placeholder ?? 'Choose…'}</span>
          {unroutable ? <span className="mdl-chip-note orange">· unavailable</span> : inherited ? <span className="mdl-chip-note">· inherited</span> : null}
          <SF name="chevron.down" size={10} weight={700} />
        </button>
        {ex && <button className="mdl-clear" title={agent == null ? (layer ? 'Inherit the global setting' : 'Clear') : 'Inherit Default'}
                       onClick={() => assignRef(agent, tier, null)}><SF name="xmark.circle.fill" size={13} /></button>}
        {ctxRef && <ContextChip refv={ctxRef} setAsk={setAsk} onSet={n => {
          const r: Ref = structuredClone(ctxRef);
          r.capabilities = { ...(r.capabilities ?? {}) };
          if (n == null) delete r.capabilities.contextWindow; else r.capabilities.contextWindow = n;
          r.capabilitiesOverridden = n != null; assignRef(agent, tier, r);
        }} />}
      </span>
    );
  };

  const agentRow = (agent: Agent | null) => {
    const all = agent == null || agent === 'claude';
    const key = agent ?? 'default';
    const sizesSet = !!(explicitRef(agent, 'small') || explicitRef(agent, 'large'));
    const sizesOpen = sizesSet || openSizes.has(key);
    return (
      <div className="mdl-agent">
        <div className="mdl-agent-main">
          <span className={cx('mdl-agent-name', agent == null && 'bold')}>{agent ? AGENT_NAME[agent] : 'Default'}</span>
          <span style={{ flex: 1 }} />
          {chip(agent, 'medium')}
        </div>
        {all && (
          <div className="mdl-sizes" title="Optional: different models for Claude Code's large (opus) and small/background (haiku) slots. Unset, they follow Claude Code's own defaults.">
            <div className="mdl-sizes-head" onClick={() => setOpenSizes(s => { const n = new Set(s); if (n.has(key)) n.delete(key); else n.add(key); return n; })}>
              <span className={cx('mdl-disc', sizesOpen && 'open')}><SF name="chevron.right" size={9} weight={600} /></span>
              <span className="mdl-caption">Sizes</span>
            </div>
            {sizesOpen && (
              <div className="mdl-sizes-body">
                {(['large', 'small'] as Tier[]).map(t => (
                  <div className="mdl-tierline" key={t}>
                    <div className="mdl-tierlabel"><div className="mdl-callout">{TIER_NAME[t]}</div><div className="mdl-hint">≈ {TIER_HINT[t]}</div></div>
                    {chip(agent, t)}
                  </div>
                ))}
                {agent && Object.keys(settings.agentTiers[agent] ?? {}).length > 0 && (
                  <div className="mdl-reset"><Button variant="borderless" size="small" onClick={() => onChange(s => { delete s.agentTiers[agent]; })}>Reset to Default</Button></div>
                )}
              </div>
            )}
          </div>
        )}
      </div>
    );
  };

  // ── sources ──
  const sources: SourceID[] = [...CLOUD_PROVIDERS.map(p => ({ kind: 'provider' as const, p })), { kind: 'customServer' }, { kind: 'onDevice' }];
  const sourceName = (s: SourceID) => s.kind === 'provider' ? PROVIDER_NAME[s.p] : s.kind === 'customServer' ? 'Custom server' : 'On-device';
  const sourceSubtitle = (s: SourceID): string | null => {
    if (s.kind === 'provider') {
      const p = s.p, st = status(p);
      if (st === 'excluded') return 'off here';
      if (st === 'overridden') return isUsable(credential(res, p)) ? 'overridden here' : 'override (not configured)';
      if (st === 'inherited') return p === 'bedrock' ? 'inherited' : credential(res, p)?.useSubscription ? 'inherited subscription' : 'inherited API key';
      if (p === 'bedrock') return isUsable(credential(res, p)) ? 'AWS credentials' : null;
      if (savedAt(p)) return reauthAt(p) ? 'sign-in expired' : 'subscription';
      return isUsable(credential(res, p)) ? 'API key' : null;
    }
    if (s.kind === 'customServer') {
      if (layer && excluded.includes('custom') && !settings.localServer) return 'off here';
      try { return res.localServer?.baseURL ? new URL(res.localServer.baseURL).host : null; } catch { return null; }
    }
    return local.installed.length ? `${local.installed.length} installed` : null;
  };
  const sourceDot = (s: SourceID): string => {
    if (s.kind === 'provider') {
      const p = s.p;
      if (status(p) === 'excluded') return DOT.off;
      if (savedAt(p) && reauthAt(p) && status(p) !== 'overridden') return DOT.orange;
      return isUsable(credential(res, p)) || (savedAt(p) && status(p) !== 'overridden') ? DOT.green : DOT.off;
    }
    if (s.kind === 'customServer') return res.localServer?.baseURL ? DOT.mint : DOT.off;
    return local.installed.length ? DOT.purple : DOT.off;
  };

  // ── mutations behind the popovers ──
  const setExcluded = (p: Provider, on: boolean) => layer?.setExcluded(p, on);
  const setKey = (p: Provider, txt: string) => onChange(s => {
    const cur = credential(s, p);
    s.providers = s.providers.filter(c => c.provider !== p);
    const c: Cred = { ...(cur ?? { provider: p, useSubscription: false }), apiKey: txt || null, useSubscription: false };
    if (isUsable(c)) s.providers.push(c);
  });
  const useGlobalCredential = (p: Provider) => { onChange(s => { s.providers = s.providers.filter(c => c.provider !== p); }); setExcluded(p, false); };
  const setBedrock = (on: boolean) => {
    const st = status('bedrock');
    if (st === 'inherited' || st === 'excluded') { setExcluded('bedrock', !on); return; }
    onChange(s => {
      s.providers = s.providers.filter(c => c.provider !== 'bedrock');
      if (on) {
        s.providers.push({ provider: 'bedrock', useSubscription: false });
        // Bedrock has no default to fall back on: Claude Code's main model is pre-filled.
        const has = layer ? (s.agentTiers.claude?.medium ?? res.agentTiers.claude?.medium ?? res.tiers.medium) : s.agentTiers.claude?.medium;
        if (!has) {
          const id = modelOptions('bedrock', 'medium')[0];
          s.agentTiers.claude = { ...(s.agentTiers.claude ?? {}), medium: { source: wireSource({ kind: 'provider', p: 'bedrock' }), modelID: id, capabilities: capabilities(id) ?? {}, capabilitiesOverridden: false } };
        }
      } else {
        const drop = (t: any) => { for (const k of Object.keys(t ?? {})) { const r = sourceOf(t[k]); if (r.kind === 'provider' && r.p === 'bedrock') delete t[k]; } };
        drop(s.tiers);
        for (const a of Object.keys(s.agentTiers) as Agent[]) { drop(s.agentTiers[a]); if (!Object.keys(s.agentTiers[a] ?? {}).length) delete s.agentTiers[a]; }
      }
    });
  };
  const bedrockField = (field: 'region' | 'apiKey', txt: string) => onChange(s => {
    if (!credential(s, 'bedrock') && layer) { const g = credential(layer.global, 'bedrock'); if (g) s.providers.push(structuredClone(g)); }
    const c = credential(s, 'bedrock'); if (!c) return;
    c[field] = field === 'region' ? (txt.trim() ? txt : null) : (txt || null);
  });
  const setServerEnabled = (on: boolean) => {
    if (layer && !settings.localServer && layer.global.localServer) setExcluded('custom', !on);
    else {
      onChange(s => { s.localServer = on ? (s.localServer ?? { baseURL: '' }) : null; });
      if (!on && layer?.global.localServer) setExcluded('custom', true);
      if (on) setExcluded('custom', false);
    }
    if (!on) { setServerModels([]); setProbe({ s: 'idle' }); }
  };
  const serverField = (field: 'baseURL' | 'apiKey', txt: string) => onChange(s => {
    if (!s.localServer && layer?.global.localServer) s.localServer = structuredClone(layer.global.localServer);
    if (!s.localServer) return;
    if (field === 'apiKey') s.localServer.apiKey = txt || null; else s.localServer.baseURL = txt;
  });
  /** Test Connection — run BY the host (its network and source address are
   *  what its launches use); this client never contacts the server itself. */
  const probeServer = async () => {
    const base = (res.localServer?.baseURL ?? '').trim(); if (!base) return;
    setProbe({ s: 'probing' });
    try {
      const ids = await probeCustomServer((m, p, b, o) => ctx.host.request(m, p, b, o), base, res.localServer?.apiKey);
      setServerModels(ids); setProbe({ s: 'ok', n: ids.length });
    } catch (e: any) {
      setServerModels([]);
      setProbe({ s: 'failed', why: `${ctx.hostName} couldn’t reach it: ${e?.message ?? e}` });
    }
  };
  useEffect(() => { if (res.localServer?.baseURL) probeServer(); }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const popover = (s: SourceID) => {
    if (s.kind === 'provider' && s.p === 'bedrock') {
      const st = status('bedrock'), c = credential(res, 'bedrock');
      return (
        <div className="mdl-pop">
          <div className="mdl-headline">{PROVIDER_NAME.bedrock}</div>
          <div className="mdl-caption">Any agent can run on Amazon Bedrock: Claude Code natively, the others through Bedrock's OpenAI-compatible API. Sign requests with each workspace's own AWS credentials (Credentials → AWS), or paste a Bedrock API key.</div>
          {(st === 'inherited' || st === 'excluded') && <LayerHeader p="bedrock" st={st} global={layer!.global} setExcluded={setExcluded} />}
          <Check checked={isUsable(c)} onChange={setBedrock}>Use Amazon Bedrock</Check>
          {isUsable(c) && <>
            <input className="field mdl-field" spellCheck={false} value={c?.region ?? ''} placeholder="us-east-1 — empty: each workspace's AWS region"
                   onChange={e => bedrockField('region', e.target.value)} aria-label="AWS region" />
            <input className="field mdl-field" type="password" value={c?.apiKey ?? ''} placeholder="Bedrock API key (optional — else AWS credentials sign)"
                   onChange={e => bedrockField('apiKey', e.target.value)} />
            <div className="mdl-caption">Model ids as Bedrock names them, e.g. us.anthropic.claude-sonnet-4-6 — pick them per agent on the right, or type your own.</div>
          </>}
        </div>
      );
    }
    if (s.kind === 'provider') {
      const p = s.p, st = status(p);
      return (
        <div className="mdl-pop" style={{ gap: 12 }}>
          {(st === 'inherited' || st === 'excluded') && <LayerHeader p={p} st={st} global={layer!.global} setExcluded={setExcluded} />}
          {st !== 'excluded' && <ProviderConfig p={p} subs={subs} signIn={signIn}
                                                apiKey={credential(settings, p)?.apiKey ?? ''} setKey={v => setKey(p, v)}
                                                ownOverride={st === 'overridden' ? () => useGlobalCredential(p) : undefined}
                                                inheritedHint={st === 'inherited'} />}
        </div>
      );
    }
    if (s.kind === 'customServer') {
      const inheritedSrv = !!layer && !settings.localServer && !!layer.global.localServer;
      return (
        <div className="mdl-pop">
          <div className="mdl-headline">Custom server</div>
          <div className="mdl-caption">Any OpenAI-compatible server (vLLM, Ollama, LM Studio, llama-server), on this Mac or another. Recommended for local models.</div>
          {inheritedSrv ? (
            <div className="mdl-caption mdl-label"><SF name={excluded.includes('custom') ? 'nosign' : 'arrow.down.to.line'} size={11} />
              {excluded.includes('custom') ? 'Not used in this workspace — the global settings have one.' : 'Inherited from Preferences → Models. Editing it below makes it this workspace’s own.'}</div>
          ) : layer && settings.localServer ? (
            <div className="mdl-row"><span className="mdl-caption mdl-label"><SF name="pencil" size={11} />This workspace's own server.</span><span style={{ flex: 1 }} />
              {layer.global.localServer && <Button size="small" onClick={() => { onChange(x => { x.localServer = null; }); setExcluded('custom', false); setServerModels([]); setProbe({ s: 'idle' }); }}>Use the global server</Button>}</div>
          ) : null}
          <Check checked={!!res.localServer} onChange={setServerEnabled}>Enabled</Check>
          {res.localServer && <>
            <input className="field mdl-field" spellCheck={false} value={res.localServer.baseURL} placeholder="http://127.0.0.1:11434/v1" aria-label="Server URL"
                   onChange={e => serverField('baseURL', e.target.value)} />
            <input className="field mdl-field" type="password" value={res.localServer.apiKey ?? ''} placeholder="API key (optional)" onChange={e => serverField('apiKey', e.target.value)} />
            <div className="mdl-row">
              <Button size="small" disabled={!res.localServer.baseURL || probe.s === 'probing'} onClick={probeServer}>Test Connection</Button>
              {probe.s === 'probing' && <Spinner size={12} />}
              {probe.s === 'ok' && <span className="mdl-caption mdl-label green"><SF name="checkmark.circle.fill" size={11} />{probe.n} model(s)</span>}
            </div>
            {probe.s === 'failed' && <div className="mdl-caption mdl-label red selectable"><SF name="exclamationmark.triangle.fill" size={11} />{probe.why}</div>}
          </>}
        </div>
      );
    }
    return (
      <div className="mdl-pop">
        <div className="mdl-headline">On-device models</div>
        <div className="mdl-caption">MLX models run in-process on {ctx.hostName} ({local.memGB} GB) — the lazy backup, nothing to install.</div>
        <div className="mdl-ondevice">
          {local.catalog.map(m => {
            const fit = ramFit(m, local.memGB), st = local.states[m.repo], installed = !!st?.installed && !st?.phase;
            const start = () => ctx.host.send('POST', '/models/download', { repo: m.repo, totalBytes: Math.round(m.downloadGB * 1e9) });
            return (
              <div key={m.repo} className={cx('mdl-od-row', fit === 'wontFit' && 'dim')}>
                <div className="mdl-od-text">
                  <div className="mdl-callout">{displayName(m)}</div>
                  <div className="mdl-caption2"><span className={fit === 'fits' ? 'green' : fit === 'tight' ? 'orange' : ''}>{FIT_BADGE[fit]}</span> · {Math.floor(m.downloadGB)} GB</div>
                </div>
                <span style={{ flex: 1 }} />
                {st?.phase === 'downloading' ? (
                  <span className="mdl-row"><progress className="mdl-progress" value={st.frac ?? 0} max={1} />
                    <button className="mdl-clear" onClick={() => ctx.host.send('POST', '/models/cancel', { repo: m.repo })}><SF name="xmark.circle.fill" size={13} /></button></span>
                ) : st?.phase === 'interrupted' ? <Button size="small" onClick={start}>Resume</Button>
                  : st?.phase === 'failed' ? <Button size="small" title={st.msg} onClick={start}>Retry</Button>
                  : installed ? <Button variant="borderless" size="small" className="secondary" onClick={() => {
                      ctx.host.send('POST', '/models/remove', { repo: m.repo });
                      onChange(x => {
                        const drop = (t: any) => { for (const k of Object.keys(t ?? {})) { const r = sourceOf(t[k]); if (r.kind === 'localRun' && r.id === m.id) delete t[k]; } };
                        drop(x.tiers); for (const a of Object.keys(x.agentTiers) as Agent[]) { drop(x.agentTiers[a]); if (!Object.keys(x.agentTiers[a] ?? {}).length) delete x.agentTiers[a]; }
                      });
                    }}>Remove</Button>
                  : <Button size="small" disabled={fit === 'wontFit'} onClick={start}>Get</Button>}
              </div>
            );
          })}
        </div>
      </div>
    );
  };

  return (
    <div className="mdl-board">
      <div className="mdl-board-head">
        <div className="mdl-board-title">Models</div>
        <div className="mdl-callout secondary">Register a source on the left. Each agent runs its provider’s default model unless you pick one on the right.</div>
      </div>
      <div className="mdl-cols">
        <div className="mdl-col-sources">
          <div className="mdl-gb-label"><SF name="cloud.fill" size={14} />Providers</div>
          <div className="mdl-gb">
            {sources.map((s, i) => (
              <React.Fragment key={sid(s)}>
                <button className="mdl-source" onClick={e => setOpen({ id: sid(s), at: (e.currentTarget as HTMLElement).getBoundingClientRect() })}>
                  <span className="mdl-dot" style={{ background: sourceDot(s) }} />
                  <span className="mdl-source-text"><span>{sourceName(s)}</span>{sourceSubtitle(s) && <span className="mdl-caption2">{sourceSubtitle(s)}</span>}</span>
                  <SF name="chevron.right" size={11} color="var(--label-tertiary)" />
                </button>
                {i < sources.length - 1 && <div className="mdl-rule" />}
                {open?.id === sid(s) && (
                  <Popover anchor={open.at} edge="right" width={s.kind === 'onDevice' ? 380 : 300} onClose={() => setOpen(null)}>{popover(s)}</Popover>
                )}
              </React.Fragment>
            ))}
          </div>
        </div>
        <div className="mdl-col-agents">
          <div className="mdl-gb-label"><SF name="sparkles" size={14} />Agents</div>
          <div className="mdl-gb">
            {agentRow(null)}
            <div className="mdl-rule" />
            {AGENTS.map((a, i) => <React.Fragment key={a}>{agentRow(a)}{i < AGENTS.length - 1 && <div className="mdl-rule" />}</React.Fragment>)}
          </div>
        </div>
      </div>
      {signIn.sheet}
      {ask && <AskSheet ask={ask} done={() => setAsk(null)} />}
    </div>
  );
}

function srcColor(s: Source) { return s.kind === 'provider' ? DOT.blue : s.kind === 'localServer' ? DOT.mint : DOT.purple; }
const takesContextWindow = (s: Source) => s.kind === 'localServer' || (s.kind === 'provider' && s.p === 'custom');

/** ProviderModels.capabilities(for:) */
function capabilities(id: string): any | null {
  const m = id.toLowerCase();
  if (m.startsWith('claude') || m.includes('anthropic/claude') || m.includes('.anthropic.claude')) return { contextWindow: 200000, reasoning: true, inputs: ['text', 'image'] };
  if (/^(gpt-5|gpt-4|o4|o3)/.test(m) || m.startsWith('grok')) return { contextWindow: 256000, reasoning: true, inputs: ['text', 'image'] };
  if (m.startsWith('glm')) return { contextWindow: 128000, reasoning: true, inputs: ['text'] };
  if (m.startsWith('kimi')) return { contextWindow: 256000, reasoning: false, inputs: ['text'] };
  return null;
}

function parseTokens(raw: string): number | null {
  let s = raw.trim().toLowerCase().replace(/[,_ ]/g, '');
  if (s.endsWith('tokens')) s = s.slice(0, -6);
  let scale = 1;
  if (s.endsWith('m')) { scale = 1e6; s = s.slice(0, -1); } else if (s.endsWith('k')) { scale = 1e3; s = s.slice(0, -1); }
  const n = Number(s); if (!isFinite(n) || n <= 0) return null;
  const t = Math.round(n * scale); return t >= 1000 ? t : null;
}
function formatTokens(n: number) {
  if (n >= 1e6 && n % 1e5 === 0) { const m = n / 1e6; return m === Math.round(m) ? `${m}M` : `${m.toFixed(1)}M`; }
  return n >= 1000 ? `${Math.round(n / 1000)}K` : `${n}`;
}

/** ContextWindowControl — the context window of a model on the user's own server. */
function ContextChip({ refv, onSet, setAsk }: { refv: Ref; onSet: (n: number | null) => void; setAsk: (a: Ask) => void }) {
  const tokens = (refv.capabilities?.contextWindow ?? 0) > 0 ? refv.capabilities.contextWindow as number : null;
  return (
    <button className={cx('mdl-ctx', !tokens && 'orange')}
            title={tokens ? 'The context window agents are told this model has. Click to change it.' : 'The server doesn\'t say how much context this model takes — agents assume 128K. Click to enter it.'}
            onClick={() => setAsk({
              title: 'Context window', ok: 'Save',
              message: `How many tokens ${refv.modelID} can take. Every agent using it is told, so it compacts at the right time.`,
              field: { placeholder: 'e.g. 1M, 256K or 131072', value: tokens ? formatTokens(tokens) : '',
                       onOK: v => { const n = parseTokens(v); if (n) onSet(n); else if (!v.trim() && refv.capabilitiesOverridden) onSet(null); } },
            })}>
      <SF name={tokens ? 'text.alignleft' : 'exclamationmark.triangle.fill'} size={9} />
      {tokens ? `${formatTokens(tokens)} context` : 'Context?'}
    </button>
  );
}

function LayerHeader({ p, st, global, setExcluded }: { p: Provider; st: 'inherited' | 'excluded'; global: Settings; setExcluded: (p: Provider, on: boolean) => void }) {
  const g = credential(global, p);
  const how = p === 'bedrock' ? 'AWS credentials' : g?.useSubscription ? 'subscription' : 'API key';
  return st === 'inherited' ? (
    <div className="mdl-layerhead">
      <div className="mdl-caption mdl-label"><SF name="arrow.down.to.line" size={11} />Inherited from Preferences → Models ({how}).</div>
      <div className="mdl-row"><Button size="small" onClick={() => setExcluded(p, true)}>Don't use in this workspace</Button><span className="mdl-caption2 tertiary">— or override it below.</span></div>
    </div>
  ) : (
    <div className="mdl-layerhead">
      <div className="mdl-caption mdl-label"><SF name="nosign" size={11} />Not used in this workspace — the global settings have it.</div>
      <div><Button size="small" onClick={() => setExcluded(p, false)}>Use the global provider</Button></div>
    </div>
  );
}

/** ProviderConfigPopover: sign in / log out / API key. */
function ProviderConfig({ p, subs, signIn, apiKey, setKey, ownOverride, inheritedHint }: {
  p: Provider; subs: ReturnType<typeof useSubscriptions>; signIn: ReturnType<typeof useSignIn>;
  apiKey: string; setKey: (v: string) => void; ownOverride?: () => void; inheritedHint: boolean;
}) {
  const hasCapture = SUPPORTS_SUBSCRIPTION.has(p);
  const sub = hasCapture ? subFor(subs, p) : undefined;
  const saved = sub?.registeredAt, expired = saved ? sub?.reauthRequiredAt : undefined;
  const signInOnly = p === 'nous';
  let health: string | null = null;
  if (sub) {
    const parts = [sub.lastRefreshedAt ? `Last refreshed ${relative(sub.lastRefreshedAt)}` : 'Not refreshed since sign-in'];
    if (sub.accessExpiresAt) parts.push(sub.accessExpiresAt * 1000 > Date.now() ? `access token expires ${relative(sub.accessExpiresAt)}` : 'access token renews on next use');
    health = parts.join(' · ');
  }
  return (
    <>
      <div className="mdl-row"><span className="mdl-headline">{PROVIDER_NAME[p]}</span><span style={{ flex: 1 }} />
        {ownOverride && <Button size="small" onClick={ownOverride}>Use the global provider</Button>}</div>
      {inheritedHint ? <div className="mdl-caption">Override for this workspace:</div>
        : ownOverride ? <div className="mdl-caption mdl-label"><SF name="pencil" size={11} />This workspace's own credential.</div> : null}
      {sub?.storeUnreadable && <div className="mdl-caption mdl-label red"><SF name="exclamationmark.octagon.fill" size={11} />Login store unreadable — Bromure won't overwrite it. Sign-ins saved in it are unavailable until it can be read again.</div>}
      {hasCapture && (saved && expired ? (
        <div className="mdl-expired">
          <div className="mdl-label orange semibold"><SF name="exclamationmark.triangle.fill" size={12} />Sign-in expired</div>
          <div className="mdl-caption">{PROVIDER_NAME[p]} rejected the saved sign-in (from {relative(saved)}). Sessions can't use it until you sign in again.</div>
          <div className="mdl-row"><Button variant="prominent" className="mdl-orangebtn" icon="arrow.clockwise.circle" onClick={() => signIn.register(p)}>Sign in again</Button>
            <Button onClick={() => signIn.forget(p)}>Log out…</Button></div>
        </div>
      ) : saved ? (
        <>
          <div className="mdl-callout mdl-label green"><SF name="checkmark.circle.fill" size={12} />Signed in {relative(saved)}</div>
          {health && <div className="mdl-caption">{health}</div>}
          <div className="mdl-row"><Button size="small" icon="arrow.clockwise" onClick={() => signIn.register(p)}>Sign in again…</Button>
            <Button size="small" onClick={() => signIn.forget(p)}>Log out…</Button></div>
        </>
      ) : (
        <>
          <div><Button variant="prominent" icon="person.crop.circle.badge.plus" onClick={() => signIn.register(p)}>Sign in with {PROVIDER_NAME[p]}</Button></div>
          <div className="mdl-caption">Interactive login in a temporary VM — no API key needed.</div>
          {!signInOnly && <div className="mdl-caption2 tertiary">or paste an API key</div>}
        </>
      ))}
      {signInOnly ? <div className="mdl-caption">Powers Hermes Agent only.</div>
        : <input className="field mdl-field" type="password" placeholder="API key" value={apiKey} onChange={e => setKey(e.target.value)} />}
      {!apiKey && !saved && <div className="mdl-caption tertiary">Not configured yet.</div>}
    </>
  );
}
