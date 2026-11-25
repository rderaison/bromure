// Fusion — ProfileViews.swift `fusionSection` (+ fusionLocalLegRow,
// fusionJudgePickers). Which agents can be a leg comes from the workspace as
// launched: its own agents projected with the effective model settings (the
// host's Preferences › Models, this workspace's override resolved over them)
// and the host's sign-ins — `overlaidWithGlobalModels` + `fusionUsableProviders`.

import React, { useEffect } from 'react';
import { PopUp } from '../../../ui/kit';
import { SF } from '../../../ui/icons';
import { useEditor, type EditorCtxValue } from '../ctx';
import { TOOL_SYMBOL, val, type Tool } from '../model';
import { BetaBadge } from '../ui';
import {
  Check, NATIVE_PROVIDER, credential, effectiveSettings, isRedactedSecret, isUsable, refFor, sourceOf,
  subscribedProviders, useLocalModels, useSubscriptions, displayName, type Agent, type Provider, type Settings,
} from './ModelsShared';

const LEGS: Tool[] = ['claude', 'codex', 'grok', 'kimi', 'omp'];
const BACKEND_LABEL: Record<Tool, string> = {
  claude: 'Claude Code (Anthropic) — your session', codex: 'Codex (OpenAI)', grok: 'Grok (xAI)',
  kimi: 'Kimi Code (Moonshot AI)', omp: 'Oh My Pi', hermes: 'Hermes Agent',
};
const FUSION_OMP = new Set<Provider>(['anthropic', 'openai', 'xai']);
const SUPPORTS_SUB = new Set<Provider>(['anthropic', 'openai', 'xai', 'moonshot', 'nous']);

/** The tool's spec as the draft stores it (primary or an additional agent). */
function storedSpec(doc: any, t: Tool): { authMode: string; apiKey?: string; ompProvider?: string } | null {
  if (doc.tool === t) return { authMode: doc.authMode, apiKey: doc.apiKey, ompProvider: doc.ompProvider };
  return (val<any[]>(doc, 'additionalTools')).find(s => s.tool === t) ?? null;
}

/** Profile.hasUsableCredential(for:) on the overlaid (effective) profile. */
function legUsable(doc: any, t: Tool, s: Settings, subscribed: Set<Provider>): boolean {
  if (t === 'hermes') return false;
  const hasProviders = s.providers.some(isUsable);
  const hasTiers = Object.keys(s.tiers).length > 0 || Object.values(s.agentTiers).some(x => x && Object.keys(x).length);
  let spec = storedSpec(doc, t);
  if (hasProviders || hasTiers || subscribed.size) {
    // overlaidWithGlobalModels: every agent is enabled for the launch copy.
    spec = spec ? { ...spec } : { authMode: 'token' };
    const agent = t as Agent;
    const ref = refFor(s, agent, 'medium') ?? refFor(s, agent, 'large') ?? refFor(s, agent, 'small');
    if (ref) {
      const src = sourceOf(ref);
      if (src.kind !== 'provider') return false;                 // local → not a cloud leg
      if (src.p === 'bedrock' && isUsable(credential(s, 'bedrock'))) return t === 'claude';
    }
    const p: Provider = t === 'omp' ? (spec.ompProvider as Provider ?? 'anthropic') : NATIVE_PROVIDER[agent]!;
    const cred = credential(s, p);
    const hasKey = !isRedactedSecret(cred?.apiKey);
    if (hasKey && !cred?.useSubscription) return t !== 'omp' || FUSION_OMP.has(p);
    if (SUPPORTS_SUB.has(p) && (cred?.useSubscription || subscribed.has(p))) return t !== 'omp';
    if (cred && isUsable(cred)) return false;                    // token mode, no key
  }
  if (!spec) return false;
  switch (spec.authMode) {
    case 'token': return (t !== 'omp' || FUSION_OMP.has((spec.ompProvider as Provider) ?? 'anthropic')) && !!(spec.apiKey ?? '').trim();
    case 'subscription': return t !== 'omp';
    case 'bedrock': return t === 'claude' && isUsable(credential(s, 'bedrock'));
    default: return false;
  }
}

export function FusionPane() {
  const ctx = useEditor();
  const { doc, set, host } = ctx;
  const subs = useSubscriptions(host);
  const local = useLocalModels(host);
  const settings = effectiveSettings(ctx);
  const subscribed = subscribedProviders(subs);
  const usable = LEGS.filter(t => legUsable(doc, t, settings, subscribed));
  const legs: Tool[] = val(doc, 'fusionLegs');
  const localLeg: string | undefined = doc.fusionLocalLeg ?? undefined;
  const externalEngine = !!(doc.localEngineURL ?? '').trim();
  const localModels = local.installed;
  const configurable = usable.length + (localLeg ? 1 : 0) >= 2;

  // ensureFusionJudgeDefaults: a cloud judge defaults to the first usable agent.
  useEffect(() => {
    if (!val<boolean>(doc, 'fusionJudgeLocal') && doc.fusionJudgeProvider == null && usable[0]) set('fusionJudgeProvider', usable[0]);
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  return (
    <div className="fu-pane">
      <div className="fu-blurb">
        <div className="fu-blurb-head">
          <SF name="bolt.fill" size={14} color="var(--yellow)" />
          <span className="fu-title">Fusion</span>
          <BetaBadge />
        </div>
        <div className="mdl-caption">When engaged, Fusion answers each prompt with <b>multiple</b> models at once, has a judge model map where they agree, conflict, and each shine, then synthesizes a single best reply — delivered to Claude Code as if one model wrote it. Engage it per session from the <SF name="bolt.fill" size={10} color="var(--yellow)" /> in the toolbar, shown while a machine's terminal tab is on screen.</div>
        <div className="mdl-caption">Fusion runs on the <b>Claude Code</b> session (it intercepts Claude's API). It needs at least two configured agents below.</div>
      </div>
      <div className="fu-rule" />
      <div className="fu-sub">Models to fuse</div>
      <div className="mdl-caption">Your Claude Code session is always one of the fused models; pick the others.</div>
      {LEGS.map(t => {
        const ok = usable.includes(t);
        return (
          <Check key={t} disabled={!ok} checked={ok && legs.includes(t)} className="fu-leg"
                 onChange={on => set('fusionLegs', on ? [...legs.filter(x => x !== t), t] : legs.filter(x => x !== t))}>
            <span className="fu-leg-label">
              <SF name={TOOL_SYMBOL[t]} size={14} color={ok ? 'var(--label)' : 'var(--label-secondary)'} />
              <span className="fu-leg-name">{BACKEND_LABEL[t]}</span>
              {!ok && <span className="mdl-caption fu-why">{t === 'omp'
                ? '— needs an Anthropic, OpenAI or xAI API key for Oh My Pi (set it in Preferences › Models)'
                : '— no cloud credential (set one up in Preferences › Models)'}</span>}
            </span>
          </Check>
        );
      })}
      <LocalLegRow ctx={ctx} localModels={localModels} externalEngine={externalEngine} />
      {!configurable && (
        <div className="mdl-caption fu-warn">Pick at least two models to fuse — your Claude Code session counts as one, so add one more (a cloud agent or a local model).</div>
      )}
      <div className="fu-rule" />
      <div className="fu-sub">Judge</div>
      <div className="mdl-caption">The model that weighs the drafts and writes the final answer.</div>
      <JudgePickers ctx={ctx} usable={usable} localModels={localModels} externalEngine={externalEngine} />
    </div>
  );
}

function LocalLegRow({ ctx, localModels, externalEngine }: { ctx: EditorCtxValue; localModels: ReturnType<typeof useLocalModels>['installed']; externalEngine: boolean }) {
  const { doc, set } = ctx;
  if (!localModels.length && !externalEngine) {
    return (
      <div className="fu-localoff">
        <SF name="cpu" size={14} color="var(--label-secondary)" />
        <span className="secondary fu-leg-name">Local model</span>
        <span className="mdl-caption">— download one in Preferences › Models</span>
      </div>
    );
  }
  const leg: string | null = doc.fusionLocalLeg ?? null;
  return (
    <div className="fu-localrow">
      <Check checked={leg != null} className="fu-leg"
             onChange={on => set('fusionLocalLeg', on ? (leg ?? localModels[0]?.id ?? doc.activeModelID ?? '') : null)}>
        <span className="fu-leg-label"><SF name="cpu" size={14} color="var(--mint)" /><span className="fu-leg-name">Local model</span></span>
      </Check>
      {leg != null && <LocalChooser value={leg} onChange={v => set('fusionLocalLeg', v)} localModels={localModels} externalEngine={externalEngine} />}
    </div>
  );
}

/** fusionLocalModelChooser: installed models, or (custom engine) a typed id. */
function LocalChooser({ value, onChange, localModels, externalEngine }: {
  value: string; onChange: (v: string) => void; localModels: ReturnType<typeof useLocalModels>['installed']; externalEngine: boolean;
}) {
  if (externalEngine) {
    return <input className="field fu-idfield" spellCheck={false} placeholder="qwen3-coder:30b" value={value} onChange={e => onChange(e.target.value)} aria-label="Model id" />;
  }
  return <PopUp bordered className="fu-popup" value={value || localModels[0]?.id || ''} onChange={onChange}
                options={localModels.map(m => ({ value: m.id, label: displayName(m) }))} />;
}

function JudgePickers({ ctx, usable, localModels, externalEngine }: {
  ctx: EditorCtxValue; usable: Tool[]; localModels: ReturnType<typeof useLocalModels>['installed']; externalEngine: boolean;
}) {
  const { doc, set, update } = ctx;
  const judgeLocal = val<boolean>(doc, 'fusionJudgeLocal');
  const provider: string = judgeLocal ? 'local' : (doc.fusionJudgeProvider ?? usable[0] ?? '');
  const options = usable.map(t => ({ value: t as string, label: BACKEND_LABEL[t] }));
  if (localModels.length || externalEngine) options.push({ value: 'local', label: 'Local' });
  if (!options.some(o => o.value === provider)) options.unshift({ value: provider, label: provider ? (BACKEND_LABEL[provider as Tool] ?? provider) : '' });
  const disabled = !usable.length && !localModels.length && !externalEngine;
  const model: string = doc.fusionJudgeModel ?? '';
  return (
    <div className="fu-judge">
      <span className="mdl-body">Provider</span>
      <PopUp bordered disabled={disabled} className="fu-popup fu-provider" value={provider} options={options}
             onChange={tag => update(d => {
               if (tag === 'local') {
                 d.fusionJudgeLocal = true;
                 if (d.fusionJudgeModel == null) d.fusionJudgeModel = d.fusionLocalLeg ?? localModels[0]?.id ?? d.activeModelID ?? undefined;
               } else { d.fusionJudgeLocal = false; d.fusionJudgeProvider = tag; delete d.fusionJudgeModel; }
             })} />
      <span className="mdl-body">Model</span>
      {judgeLocal
        ? <LocalChooser value={model} onChange={v => set('fusionJudgeModel', v)} localModels={localModels} externalEngine={externalEngine} />
        : <PopUp bordered disabled={disabled} className="fu-popup fu-model" value={model}
                 onChange={v => set('fusionJudgeModel', v || undefined)}
                 options={[{ value: '', label: '(default)' }, ...(model ? [{ value: model, label: model }] : [])]} />}
    </div>
  );
}
