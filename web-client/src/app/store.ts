// App-level state: saved hosts (by address), the bromure.io account, and the
// live RemoteHost connections. Plain modules + useSyncExternalStore — no
// framework state library.

import { useSyncExternalStore, useCallback } from 'react';
import { RemoteHost, type HostTarget } from '../core/remote/host';
import type { RemoteState } from '../core/remote/types';
import { deviceSSHKey, openSSHPublicLine } from '../core/ssh/keys';
import { dialDirect } from '../platform';
import { hostTrust } from './trust';

export interface SavedHost {
  id: string; name: string; address: string; port: number; user: string;
  pinnedFingerprint?: string; peerDeviceID?: string; lastConnectedAt?: string;
}

const HOSTS_KEY = 'bromure.hosts.v1';

function readHosts(): SavedHost[] {
  try { return JSON.parse(localStorage.getItem(HOSTS_KEY) || '[]'); } catch { return []; }
}
let hosts: SavedHost[] = readHosts();
const hostListeners = new Set<() => void>();
function emitHosts() { for (const l of [...hostListeners]) l(); }

export const savedHosts = {
  all: () => hosts,
  upsert(h: SavedHost) {
    hosts = [...hosts.filter(x => x.id !== h.id), h];
    try { localStorage.setItem(HOSTS_KEY, JSON.stringify(hosts)); } catch {}
    emitHosts();
  },
  remove(id: string) {
    hosts = hosts.filter(x => x.id !== id);
    try { localStorage.setItem(HOSTS_KEY, JSON.stringify(hosts)); } catch {}
    emitHosts();
  },
  subscribe(l: () => void) { hostListeners.add(l); return () => hostListeners.delete(l); },
};

export function useSavedHosts() {
  return useSyncExternalStore(savedHosts.subscribe, savedHosts.all);
}

// ── live connections ─────────────────────────────────────────────────────

const live = new Map<string, RemoteHost>();

export async function publicKeyLine() {
  const k = await deviceSSHKey();
  return openSSHPublicLine(k.publicRaw, 'bromure-client');
}

export function connectionFor(target: HostTarget): RemoteHost {
  let h = live.get(target.id);
  if (h) return h;
  h = new RemoteHost(target, {
    confirmHostKey: (info, t) => hostTrust.confirm(info, t),
    hostKeyChanged: (info, t) => hostTrust.changed(info, t),
    askPassword: (t, attempt) => hostTrust.password(t, attempt),
    pin: (t, fp) => {
      const s = savedHosts.all().find(x => x.id === t.id);
      if (s) savedHosts.upsert({ ...s, pinnedFingerprint: fp });
    },
    clientKey: () => deviceSSHKey(),
    publicKeyLine,
  });
  live.set(target.id, h);
  return h;
}

export function closeConnection(id: string) {
  live.get(id)?.stop();
  live.delete(id);
}

export function targetForSaved(h: SavedHost): HostTarget {
  return {
    id: h.id, name: h.name, username: h.user, pinnedFingerprint: h.pinnedFingerprint,
    dial: () => dialDirect(h.address, h.port),
  };
}

// ── hooks ────────────────────────────────────────────────────────────────

/** Re-render on any change of the host (status, push state, snapshot). */
export function useHost(host: RemoteHost) {
  const sub = useCallback((l: () => void) => host.onChange(l), [host]);
  useSyncExternalStore(sub, () => `${host.status}|${host.pushActive}|${host.state?.generation ?? 0}|${host.state ? 1 : 0}`);
  return host;
}

/** Select a slice of the mirrored state; re-renders when the slice changes
 *  (by reference — snapshots replace changed sections wholesale). */
export function useRemote<T>(host: RemoteHost, select: (s: RemoteState) => T): T | undefined {
  const sub = useCallback((l: () => void) => host.onState(l), [host]);
  return useSyncExternalStore(sub, () => (host.state ? select(host.state) : undefined));
}
