// A machine's tmux windows ("tabs") — the mirror's TabsModel over
// state.vms[].tabs, and the tab verbs RemoteHostController sends:
// POST /sessions/<workspace>/tab {action: select|new|close, index}.
// The server has no rename / reorder verb for tabs.

import { useCallback, useSyncExternalStore } from 'react';
import { seg, type RemoteHost } from '../../core/remote/host';
import type { VMTab } from '../../core/remote/types';
import { useRemote } from '../../app/store';

/** Windows dropped here (a Close, a clean shell exit) until the roster
 *  confirms them gone — so a stale poll can't flash the chip back
 *  (RemoteHostController.pendingTabDrops). */
const drops = new Map<string, Map<number, number>>();
const listeners = new Set<() => void>();
let version = 0;
function bump() { version++; for (const l of [...listeners]) l(); }
const DROP_TTL = 15000;

export function dropTabLocally(workspaceID: string, index: number) {
  const m = drops.get(workspaceID) ?? new Map();
  m.set(index, Date.now());
  drops.set(workspaceID, m);
  bump();
  setTimeout(bump, DROP_TTL + 50);
}

function isDropped(workspaceID: string, index: number, roster: VMTab[]) {
  const m = drops.get(workspaceID);
  const at = m?.get(index);
  if (at == null) return false;
  // Confirmed gone (a new window may reuse the index later), or it never
  // went (the close failed): forget the drop.
  if (!roster.some(t => t.index === index) || Date.now() - at > DROP_TTL) { m!.delete(index); return false; }
  return true;
}

/** The workspace's live tabs (dropped ones filtered), or undefined while the
 *  workspace has no VM entry. */
export function useWorkspaceTabs(host: RemoteHost, workspaceID: string): VMTab[] | undefined {
  const sub = useCallback((l: () => void) => { listeners.add(l); return () => { listeners.delete(l); }; }, []);
  useSyncExternalStore(sub, () => version);
  const roster = useRemote(host, s => s.vms?.find(v => v.id === workspaceID)?.tabs);
  if (!roster) return roster;
  return roster.filter(t => !isDropped(workspaceID, t.index, roster));
}

export function tabLabel(t: VMTab): string {
  const d = (t.display as string | undefined) ?? t.title;
  return d && d.trim() ? d : (t.process || 'shell');
}

/** ⌘1–9 order: container tabs excluded, roster order. */
export function orderedTabs(tabs: VMTab[]) { return tabs.filter(t => !t.containerID); }

export const tabVerbs = {
  select(host: RemoteHost, ws: string, index: number) {
    host.send('POST', `/sessions/${seg(ws)}/tab`, { action: 'select', index });
  },
  /** No optimistic echo: attaching to a predicted window before the guest
   *  made it fails ("can't find window N"); the roster brings it. */
  create(host: RemoteHost, ws: string) {
    host.send('POST', `/sessions/${seg(ws)}/tab`, { action: 'new' });
  },
  close(host: RemoteHost, ws: string, index: number) {
    dropTabLocally(ws, index);
    host.send('POST', `/sessions/${seg(ws)}/tab`, { action: 'close', index });
  },
};
