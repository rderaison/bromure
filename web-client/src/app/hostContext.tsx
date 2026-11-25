// Per-window context for a mirrored host: the connection, what's on stage,
// and window-level actions. Every feature reads it via useHostCtx().

import React, { createContext, useContext, useMemo, useState, useCallback } from 'react';
import type { RemoteHost } from '../core/remote/host';

/** What the stage shows (RemoteHostWindow's presentation state). */
export type StageSelection =
  | { kind: 'home' }
  | { kind: 'session'; sessionID: string }
  | { kind: 'room'; roomID: string; zoomedSessionID?: string }
  | { kind: 'workspace'; workspaceID: string; windowIndex?: number }   // a machine's terminal / dashboard
  | { kind: 'machines' }
  | { kind: 'cluster'; clusterID: string }
  | { kind: 'registry'; registryID: string }
  // Board / new-session stage surfaces (the sidebar tints their rows while on stage).
  | { kind: 'new-session'; roomID?: string }
  | { kind: 'task-board'; newTaskToken?: number }
  | { kind: 'automation-board'; tab?: string }
  | { kind: 'grid' }
  | { kind: 'docker'; workspaceID: string; containerID?: string };

/** Chat vs terminal for the session on stage (SessionTerminalPreference). */
export type SessionViewMode = 'chat' | 'terminal';

export interface HostCtxValue {
  host: RemoteHost;
  selection: StageSelection;
  select: (s: StageSelection) => void;
  viewMode: SessionViewMode;
  setViewMode: (m: SessionViewMode) => void;
  sidebarCollapsed: boolean;
  setSidebarCollapsed: (v: boolean) => void;
  filePaneOpen: boolean;
  setFilePaneOpen: (v: boolean) => void;
  /** Feature-registered commands (palette, menus, shortcuts) — see commands.ts. */
}

const Ctx = createContext<HostCtxValue | null>(null);

export function useHostCtx(): HostCtxValue {
  const v = useContext(Ctx);
  if (!v) throw new Error('useHostCtx outside a host window');
  return v;
}

function persisted<T>(key: string, init: T): [T, (v: T) => void] {
  const [v, setV] = useState<T>(() => {
    try { const s = localStorage.getItem(key); return s ? JSON.parse(s) : init; } catch { return init; }
  });
  const set = useCallback((nv: T) => { setV(nv); try { localStorage.setItem(key, JSON.stringify(nv)); } catch {} }, [key]);
  return [v, set];
}

export function HostCtxProvider({ host, children }: { host: RemoteHost; children: React.ReactNode }) {
  const [selection, select] = persisted<StageSelection>(`bromure.sel.${host.target.id}`, { kind: 'home' });
  const [viewMode, setViewMode] = persisted<SessionViewMode>('bromure.viewMode', 'chat');
  const [sidebarCollapsed, setSidebarCollapsed] = persisted('bromure.sidebarCollapsed', false);
  const [filePaneOpen, setFilePaneOpen] = useState(false);
  const value = useMemo(() => ({ host, selection, select, viewMode, setViewMode, sidebarCollapsed, setSidebarCollapsed, filePaneOpen, setFilePaneOpen }),
    [host, selection, select, viewMode, setViewMode, sidebarCollapsed, setSidebarCollapsed, filePaneOpen]);
  return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export { persisted as usePersisted };
