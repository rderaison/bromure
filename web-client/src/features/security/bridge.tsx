// Opens the security windows (in-app floating windows) and listens for the
// cross-surface `bromure:open` events and the Trace Inspector shortcut.

import React, { useEffect } from 'react';
import type { RemoteHost } from '../../core/remote/host';
import { useWindows } from '../../app/windows';
import { useHostCtx } from '../../app/hostContext';
import { isMod } from '../../platform';
import { useOpenListener } from '../palette/events';
import { SecurityWindow, type SecurityRequest } from './SecurityWindow';
import { TraceInspector, TRACE_WINDOW } from './trace/TraceInspector';
import { PromptsOverlay } from './prompts/PromptsOverlay';
import { securityStore } from './model';

type WM = ReturnType<typeof useWindows>;

let requestGen = 0;

/** Window › Security… — one window per host window; reopening brings it
 *  forward (and re-applies the tab asked for). */
export function openSecurity(wm: WM, host: RemoteHost, tab?: 'overview' | 'timeline', extra: Omit<SecurityRequest, 'gen' | 'tab'> = {}) {
  const req: SecurityRequest = { gen: ++requestGen, tab, ...extra };
  wm.open({
    id: 'security', title: 'Security', width: 980, height: 712, minWidth: 760, minHeight: 432,
    render: () => <SecurityWindow host={host} request={req} />,
  });
}

/** Window › Trace Inspector… (⇧⌘I), scoped to a workspace when given. */
export function openTraceInspector(wm: WM, host: RemoteHost, workspaceID?: string) {
  wm.open({
    id: 'trace-inspector', title: 'Trace Inspector', ...TRACE_WINDOW,
    render: () => <TraceInspector key={workspaceID ?? '*'} host={host} workspaceID={workspaceID} />,
  });
}

/** Mounted once per host window: event + shortcut routing, the host's
 *  pending prompts, and the timeline sync (kept warm while connected). */
export function SecurityEventBridge() {
  const wm = useWindows();
  const { host, selection } = useHostCtx();

  useEffect(() => { securityStore(host).follow(); }, [host]);

  // The workspace on show (`shownWorkspace ?? shownDashboard ?? selectedID`).
  const shownWorkspace = (): string | undefined => {
    if (selection.kind === 'workspace') return selection.workspaceID;
    if (selection.kind === 'session') return host.state?.agentSessions?.find(s => s.id === selection.sessionID)?.profileID;
    return undefined;
  };

  useOpenListener(d => {
    switch (d.what) {
      case 'security':
        openSecurity(wm, host, (d.tab as any) ?? undefined, {
          workspace: typeof d.workspaceID === 'string' ? d.workspaceID : undefined,
        });
        break;
      case 'trace':
        openTraceInspector(wm, host, typeof d.workspaceID === 'string' ? d.workspaceID
          : typeof d.profileID === 'string' ? d.profileID : shownWorkspace());
        break;
      case 'lineage':
        // A row's whole chain: the Timeline, with that row's sheet open.
        openSecurity(wm, host, 'timeline', { lineage: typeof d.rowID === 'string' ? d.rowID : typeof d.rid === 'string' ? d.rid : undefined });
        break;
    }
  });

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (isMod(e) && e.shiftKey && !e.altKey && e.key.toLowerCase() === 'i') {
        e.preventDefault(); e.stopPropagation();
        openTraceInspector(wm, host, shownWorkspace());
      }
    };
    window.addEventListener('keydown', onKey, true);
    return () => window.removeEventListener('keydown', onKey, true);
  });

  return <PromptsOverlay host={host} />;
}
