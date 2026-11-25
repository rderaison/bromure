// Host-key TOFU, changed-key warning and password fallback prompts, shown as
// sheets by the connect UI. The RemoteHost awaits these promises.

import type { HostKeyInfo, HostTarget } from '../core/remote/host';

type Prompt =
  | { kind: 'confirm'; info: HostKeyInfo; host: HostTarget; resolve: (ok: boolean) => void }
  | { kind: 'changed'; info: HostKeyInfo; host: HostTarget; resolve: (ok: boolean) => void }
  | { kind: 'password'; host: HostTarget; attempt: number; resolve: (pw: string | null) => void };

let current: Prompt | null = null;
const listeners = new Set<() => void>();
const emit = () => { for (const l of [...listeners]) l(); };

// Dev/test only: `?autotrust=1` together with a dev relay skips the TOFU sheet
// (scripted screenshots against the local demo server).
const autoTrust = (import.meta.env?.DEV || new URLSearchParams(location.search).has('devRelay'))
  && new URLSearchParams(location.search).get('autotrust') === '1';

const shotTest = window.bromureElectron?.shotTest;
let shotPasswordUsed = false;

export const hostTrust = {
  current: () => current,
  subscribe(l: () => void) { listeners.add(l); return () => listeners.delete(l); },
  confirm(info: HostKeyInfo, host: HostTarget) {
    if (autoTrust || shotTest) return Promise.resolve(true);
    return new Promise<boolean>(resolve => { current = { kind: 'confirm', info, host, resolve: ok => { current = null; emit(); resolve(ok); } }; emit(); });
  },
  changed(info: HostKeyInfo, host: HostTarget) {
    return new Promise<boolean>(resolve => { current = { kind: 'changed', info, host, resolve: ok => { current = null; emit(); resolve(ok); } }; emit(); });
  },
  password(host: HostTarget, attempt: number) {
    if (shotTest?.password && !shotPasswordUsed) { shotPasswordUsed = true; return Promise.resolve(shotTest.password); }
    return new Promise<string | null>(resolve => { current = { kind: 'password', host, attempt, resolve: pw => { current = null; emit(); resolve(pw); } }; emit(); });
  },
};
