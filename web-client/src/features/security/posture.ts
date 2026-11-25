// A workspace's protections for the Overview (SecurityPosture). The /state
// workspace rows don't carry the security settings, so each workspace's full
// Profile (`GET /profiles/<id>?full=1`, secrets blanked) is read and judged
// the way `SecurityPosture(profile:)` does. Codable writes only non-defaults,
// so every check starts from the Swift defaults.

import { useEffect, useRef, useState } from 'react';
import type { RemoteHost } from '../../core/remote/host';
import { seg } from '../../core/remote/host';
import { useRemote } from '../../app/store';

export interface Posture {
  id: string; name: string; colorHex: string;
  firewall: boolean; supplyChain: boolean; guardrails: boolean; promptInjection: boolean; pii: boolean; sandbox: boolean;
}

const nonEmpty = (s: unknown) => typeof s === 'string' && s.trim().length > 0;

/** `EgressPolicy.parse(rules).isActive`, approximated: any rule line (not a
 *  comment), or a `default deny`. */
function egressActive(rules: unknown): boolean {
  if (!nonEmpty(rules)) return false;
  return (rules as string).split('\n').some(l => {
    const t = l.replace(/#.*$/, '').trim().toLowerCase();
    return t.length > 0 && t !== 'default allow';
  });
}

/** OpenShell `confinesGuest`: a filesystem_policy or process section. */
function confinesGuest(policy: unknown): boolean {
  if (!nonEmpty(policy)) return false;
  return /^(filesystem_policy|process)\s*:/m.test(policy as string);
}

const approval = (x: any) => !!x && x.requireApproval === true;
const anyApproval = (a: unknown) => Array.isArray(a) && a.some(approval);

export function postureOf(p: any, row: { id: string; name: string; accentHex?: string }): Posture {
  const openShell = nonEmpty(p.networkPolicy);
  const sc = p.supplyChain ?? {};
  const socketActive = sc.packageFilter === 'socketDev' && nonEmpty(sc.socketAPIKey) && (sc.socketBlockCompromised || sc.socketBlockCVE);
  const supplyChain = (sc.ageGateEnabled ?? true) || !!sc.osvEnabled || !!socketActive || !!sc.stripInstallScripts || !!sc.lockfilePrompt;
  const pi = p.promptInjection ?? {};
  const promptInjection = !!pi.detectSourceInjection || !!pi.detectRulesInjection;
  const pii = p.pii ?? {};
  const piiOn = !!pii.enabled && ((pii.names ?? true) || (pii.contact ?? true) || (pii.financial ?? true) || (pii.governmentIDs ?? true) || (pii.addresses ?? true));
  const g = p.guardrails ?? {};
  const modes = ['kubernetes', 'aws', 'digitalOcean', 'docker', 'github', 'gitlab', 'bitbucket'];
  const guardrails = modes.some(m => g[m] != null && g[m] !== 'off')
    || (Array.isArray(p.httpDatabases) && p.httpDatabases.some((d: any) => d?.mode && d.mode !== 'off'))
    // The credential engine's own egress policy: an OpenShell policy's (the
    // ruleset itself is the Firewall column).
    || openShell
    || !!p.apiKeyRequiresApproval || !!p.sshKeyRequiresApproval || !!p.digitalOceanTokenRequiresApproval || !!p.linearTokenRequiresApproval
    || anyApproval(p.additionalTools) || anyApproval(p.gitHTTPSCredentials) || anyApproval(p.manualTokens)
    || anyApproval(p.dockerRegistries) || anyApproval(p.httpDatabases) || anyApproval(p.kubeconfigs) || anyApproval(p.importedSSHKeys)
    || approval(p.awsCredentials) || approval(p.twilioCredential);
  return {
    id: row.id, name: row.name, colorHex: row.accentHex ?? '#888888',
    firewall: openShell || egressActive(p.egressRules),
    supplyChain, guardrails, promptInjection, pii: piiOn,
    sandbox: openShell && confinesGuest(p.networkPolicy),
  };
}

/** The host's workspaces' postures, refreshed when the window opens and
 *  whenever the workspace list changes. */
export function usePostures(host: RemoteHost, tick: number): Posture[] {
  const rows = useRemote(host, s => s.workspaces) ?? [];
  const key = rows.map(w => `${w.id}|${w.name}|${w.accentHex}`).join(',');
  const cache = useRef(new Map<string, any>());
  const [, bump] = useState(0);
  useEffect(() => {
    let live = true;
    for (const w of rows) {
      host.request('GET', `/profiles/${seg(w.id)}?full=1`).then(p => {
        if (!live) return;
        cache.current.set(w.id, (p as any)?.profile ?? p);
        bump(n => n + 1);
      }, () => {});
    }
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [host, key, tick]);
  return rows.map(w => postureOf(cache.current.get(w.id) ?? {}, w));
}
