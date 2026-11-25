// The configuration editor — public entry points.
//
//   openWorkspaceSettings(wm, host, workspaceID, category?)   the workspace's Settings
//   openPreferences(wm, host, category?)                      the host's Preferences (its template)
//   openNewWorkspace(wm, host)                                "+" → New workspace (POST /profiles)
//   <EditorEventBridge/>   window CustomEvent `bromure:open`:
//        {what:'settings', workspaceID?, category?} | {what:'preferences', category?} | {what:'new-workspace'}
//
// Each opens (or brings forward, switched to `category`) an 880×872 in-app
// window, like ProfileEditorView.idealWindowSize + the titlebar.

import React, { useEffect, useRef, useState } from 'react';
import type { RemoteHost } from '../../core/remote/host';
import { useWindows } from '../../app/windows';
import { useHostCtx } from '../../app/hostContext';
import { EditorWindow, AlertSheet, type AlertSpec, type EditorTarget } from './EditorWindow';
import { resolveCategory, type CategoryID } from './model';

type WM = ReturnType<typeof useWindows>;

const SIZE = { width: 880, height: 872, minWidth: 780, minHeight: 600 };

function openEditor(wm: WM, host: RemoteHost, id: string, target: EditorTarget, title: string) {
  const guard: { current?: () => boolean } = {};
  wm.open({
    id, title, ...SIZE, chrome: 'none', closeGuard: guard,
    render: ({ close, setTitle }) => (
      <EditorWindow host={host} target={target} close={close} setTitle={setTitle}
                    registerCloseGuard={g => { guard.current = g; }} />
    ),
  });
}

/** A workspace's Settings, opened on `category` (a category id or its label). */
export function openWorkspaceSettings(wm: WM, host: RemoteHost, workspaceID: string, category?: CategoryID | string) {
  const name = host.state?.workspaces.find(w => w.id === workspaceID)?.name ?? 'Settings';
  openEditor(wm, host, `editor:${workspaceID}`, { mode: 'workspace', workspaceID, category: resolveCategory(category) },
    `${name} — ${host.target.name}`);
}

/** Bromure → Preferences… on the connected host (its defaults template). */
export function openPreferences(wm: WM, host: RemoteHost, category?: CategoryID | string) {
  openEditor(wm, host, 'editor:preferences', { mode: 'preferences', category: resolveCategory(category) }, 'Bromure — Preferences');
}

/** New workspace: the editor on a fresh draft, created on the host on Save. */
export function openNewWorkspace(wm: WM, host: RemoteHost, category?: CategoryID | string) {
  openEditor(wm, host, 'editor:new', { mode: 'new', category: resolveCategory(category) }, `New workspace — ${host.target.name}`);
}

export interface OpenDetail { what: 'settings' | 'preferences' | 'new-workspace'; workspaceID?: string; category?: string }

/** Mount once per host window: routes `bromure:open` to the editor, shows the
 *  editor's after-save alerts (new SSH key, restart to apply), and serves the
 *  screenshot route `?editor=<workspace name|id|prefs|new>&editorCat=<category>`. */
export function EditorEventBridge() {
  const wm = useWindows();
  const { host, selection } = useHostCtx();
  const [alerts, setAlerts] = useState<AlertSpec[]>([]);
  const [shot, setShot] = useState<EditorTarget | null>(null);
  const shotRef = useRef(shot); shotRef.current = shot;
  const selRef = useRef(selection); selRef.current = selection;

  useEffect(() => {
    const route = (d: OpenDetail) => {
      if (shotRef.current) {   // the screenshot overlay follows requests in place
        const cur = shotRef.current;
        setShot({ ...cur, category: resolveCategory(d.category) ?? cur.category });
        return;
      }
      if (d.what === 'preferences') openPreferences(wm, host, d.category);
      else if (d.what === 'new-workspace') openNewWorkspace(wm, host, d.category);
      else {
        const s = selRef.current;
        const id = d.workspaceID ?? (s.kind === 'workspace' ? s.workspaceID
          : s.kind === 'session' ? host.state?.agentSessions?.find(x => x.id === s.sessionID)?.profileID : undefined);
        if (id) openWorkspaceSettings(wm, host, id, d.category);
      }
    };
    const onOpen = (e: Event) => {
      const d = (e as CustomEvent<OpenDetail>).detail;
      if (d && (d.what === 'settings' || d.what === 'preferences' || d.what === 'new-workspace')) route(d);
    };
    const onAlert = (e: Event) => setAlerts(a => [...a, (e as CustomEvent<AlertSpec>).detail]);
    window.addEventListener('bromure:open', onOpen);
    window.addEventListener('bromure:editor-alert', onAlert);
    const w = window as any;
    w.__bromure = { ...(w.__bromure ?? {}), editor: (d: OpenDetail) => route(d) };
    return () => { window.removeEventListener('bromure:open', onOpen); window.removeEventListener('bromure:editor-alert', onAlert); };
  }, [wm, host]);

  // Screenshot route: wait for the workspace list, then open full-bleed.
  const [ready, setReady] = useState(false);
  useEffect(() => host.onState(() => setReady(!!host.state?.workspaces?.length)), [host]);
  useEffect(() => {
    const p = new URLSearchParams(location.search);
    const which = p.get('editor');
    if (!which || !ready || shotRef.current) return;
    const cat = resolveCategory(p.get('editorCat'));
    if (which === 'prefs' || which === 'preferences') setShot({ mode: 'preferences', category: cat });
    else if (which === 'new') setShot({ mode: 'new', category: cat });
    else {
      const ws = host.state!.workspaces.find(w => w.id === which || w.name === which);
      if (ws) setShot({ mode: 'workspace', workspaceID: ws.id, category: cat });
    }
  }, [ready, host]);

  const inactive = new URLSearchParams(location.search).get('editorInactive') === '1';
  return (
    <>
      {shot && (
        <div className={'ed-shot' + (inactive ? ' inactive' : '')}>
          <EditorWindow host={host} target={shot} close={() => setShot(null)} frameless />
        </div>
      )}
      {alerts[0] && <AlertSheet spec={alerts[0]} onDone={() => setAlerts(a => a.slice(1))} />}
    </>
  );
}
