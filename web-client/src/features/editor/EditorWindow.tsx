// The configuration editor window — ProfileEditorView's split layout
// (search + grouped category sidebar | detail pane under the workspace's
// name), the Cancel / Save footer, and the fat client's remote round-trip
// (FatClientController.openWorkspaceSettings / presentNewWorkspaceEditor,
// BromureAC.makeRemotePreferencesEditor):
//
//   workspace    GET /profiles/<id>?full=1 (+ /models/settings, ?storage=1)
//                → draft → PUT /profiles/<id> with only what changed
//   new          the host's template (GET /preferences) as the draft
//                → POST /profiles (what differs from the template + name)
//   preferences  GET /preferences + /models/settings → PUT both

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import type { RemoteHost } from '../../core/remote/host';
import { seg } from '../../core/remote/host';
import { Button, Sheet, Spinner, cx } from '../../ui/kit';
import { SF } from '../../ui/icons';
import { Lights } from '../../app/windows';
import { isMod } from '../../platform';
import { useRemote } from '../../app/store';
import {
  CATEGORIES, GROUPS, GROUP_ORDER, TEMPLATE_ID, category, deepEqual, restartRequiringChanges,
  searchCategories, settingsDocument, val, wholeDocument, type CategoryID, type Doc,
} from './model';
import { EditorCtx, type EditorCtxValue, type EditorMode, type StorageInfo } from './ctx';
import { CategoryIcon } from './glyphs';
import { PANES } from './panes';
import './editor.css';

export interface EditorTarget {
  mode: EditorMode;
  workspaceID?: string;
  category?: CategoryID;
}

interface Loaded {
  doc: Doc; opened: Doc; globalModels: Doc; openedGlobal: Doc; storage: StorageInfo | null;
  appTaskFinish: 'merge' | 'pullRequest'; template?: Doc;
}

/** The window content. `close` closes the in-app window; `registerClose`
 *  lets the window's ⌘W / close button ask first when there are edits. */
export function EditorWindow({ host, target, close, setTitle, registerCloseGuard, frameless }: {
  host: RemoteHost; target: EditorTarget; close: () => void; setTitle?: (t: string) => void;
  registerCloseGuard?: (guard: () => boolean) => void; frameless?: boolean;
}) {
  const [loaded, setLoaded] = useState<Loaded | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [reloadTick, setReloadTick] = useState(0);
  const hostName = host.target.name;

  useEffect(() => {
    let dead = false;
    setError(null);
    (async () => {
      const models = host.request<Doc>('GET', '/models/settings').catch(() => ({}));
      if (target.mode === 'workspace') {
        const id = target.workspaceID!;
        const [doc, globalModels, storage, prefs] = await Promise.all([
          host.request<Doc>('GET', `/profiles/${seg(id)}?full=1`),
          models,
          host.request<StorageInfo>('GET', `/profiles/${seg(id)}?storage=1`).catch(() => null),
          host.request<Doc>('GET', '/preferences').catch(() => null),
        ]);
        if (dead) return;
        setLoaded({ doc: structuredClone(doc), opened: doc, globalModels, openedGlobal: globalModels,
          storage: storage && typeof storage.baseBytes === 'number' ? storage : null,
          appTaskFinish: (prefs?.taskFinish as any) ?? 'merge' });
      } else {
        const [prefs, globalModels, defaults] = await Promise.all([
          host.request<Doc>('GET', '/preferences'),
          models,
          target.mode === 'new' ? host.request<Doc>('GET', '/storage/defaults').catch(() => null) : Promise.resolve(null),
        ]);
        if (dead) return;
        if (target.mode === 'preferences') {
          setLoaded({ doc: structuredClone(prefs), opened: prefs, globalModels: structuredClone(globalModels), openedGlobal: globalModels,
            storage: null, appTaskFinish: (prefs.taskFinish as any) ?? 'merge' });
        } else {
          // A new workspace starts from the host's defaults (what the host
          // seeds it from anyway), under a free numbered name.
          const taken = new Set((host.state?.workspaces ?? []).map(w => w.name));
          let n = (host.state?.workspaces ?? []).length + 1;
          while (taken.has(`Workspace ${n}`)) n++;
          const draft: Doc = structuredClone(prefs);
          draft.id = crypto.randomUUID().toUpperCase();
          draft.name = `Workspace ${n}`;
          delete draft.createdAt;
          const storage: StorageInfo | null = defaults?.homeImageGB
            ? { baseBytes: 0, hasDisk: false, diskBytes: 0, hasHome: false, homeBytes: 0, homeCapacity: 0, homeIsImage: false, isRunning: false, defaultHomeGB: defaults.homeImageGB }
            : null;
          setLoaded({ doc: draft, opened: draft, template: prefs, globalModels, openedGlobal: globalModels, storage,
            appTaskFinish: (prefs.taskFinish as any) ?? 'merge' });
        }
      }
    })().catch(e => { if (!dead) setError(String(e?.message ?? e)); });
    return () => { dead = true; };
  }, [host, target.mode, target.workspaceID, reloadTick]);

  if (!loaded) {
    return (
      <EditorFrame frameless={frameless} title={target.mode === 'preferences' ? 'Bromure — Preferences' : 'Settings'} close={close}>
        <div className="ed-loading">
          {error ? (
            <>
              <SF name="exclamationmark.triangle" size={30} color="var(--label-secondary)" />
              <div className="ed-headline">{target.mode === 'preferences' ? 'Couldn’t load the remote preferences' : 'Couldn’t load the workspace settings'}</div>
              <div className="ed-callout secondary selectable">{error}</div>
              <Button onClick={() => setReloadTick(t => t + 1)}>Retry</Button>
            </>
          ) : (
            <>
              <Spinner size={18} />
              <div className="secondary">{target.mode === 'preferences' ? `Loading preferences from ${hostName}…` : 'Loading…'}</div>
            </>
          )}
        </div>
      </EditorFrame>
    );
  }
  return <EditorBody host={host} target={target} loaded={loaded} close={close} setTitle={setTitle}
                     registerCloseGuard={registerCloseGuard} frameless={frameless} />;
}

/** The window chrome: our own 32pt titlebar (lights + title) so the editor
 *  matches the native NSWindow; the in-app window is opened chrome-less. */
function EditorFrame({ title, close, children, frameless, onCloseRequest }: {
  title: string; close: () => void; children: React.ReactNode; frameless?: boolean; onCloseRequest?: () => void;
}) {
  return (
    <div className={cx('ed-window', frameless && 'frameless')}>
      <div className="ed-titlebar" data-drag>
        <Lights onClose={onCloseRequest ?? close} />
        <span className="ed-wintitle">{title}</span>
      </div>
      {children}
    </div>
  );
}

function EditorBody({ host, target, loaded, close, setTitle, registerCloseGuard, frameless }: {
  host: RemoteHost; target: EditorTarget; loaded: Loaded; close: () => void; setTitle?: (t: string) => void;
  registerCloseGuard?: (guard: () => boolean) => void; frameless?: boolean;
}) {
  const [doc, setDoc] = useState<Doc>(loaded.doc);
  const [globalModels, setGlobalModelsState] = useState<Doc>(loaded.globalModels);
  const [storage, setStorage] = useState<StorageInfo | null>(loaded.storage);
  const [selected, setSelected] = useState<CategoryID>(target.category ?? 'general');
  const [search, setSearch] = useState('');
  const [invalid, setInvalidMap] = useState<Record<string, string>>({});
  const [saving, setSaving] = useState(false);
  const [alert, setAlert] = useState<AlertSpec | null>(null);
  const isNew = target.mode === 'new';
  const isPrefs = target.mode === 'preferences';
  const isTemplate = doc.id === TEMPLATE_ID;
  const [generateSSH, setGenerateSSH] = useState(isNew && !doc.sshPublicKey);
  const workspaces = useRemote(host, s => s.workspaces) ?? [];

  // A later request for a pane (bromure:open on an open editor) switches it.
  useEffect(() => { if (target.category) setSelected(target.category); }, [target.category]);

  const set = useCallback((key: string, value: any) => setDoc(d => ({ ...d, [key]: value })), []);
  const update = useCallback((fn: (d: Doc) => void) => setDoc(d => { const c = structuredClone(d); fn(c); return c; }), []);
  const setGlobalModels = useCallback((fn: (m: Doc) => void) =>
    setGlobalModelsState(m => { const c = structuredClone(m); fn(c); return c; }), []);
  const setInvalid = useCallback((key: string, reason: string | null) => setInvalidMap(m => {
    if ((m[key] ?? null) === reason) return m;
    const n = { ...m }; if (reason == null) delete n[key]; else n[key] = reason; return n;
  }), []);

  // ── live firewall edits (FirewallLiveEdit) ────────────────────────────
  const fw = useRef({ opening: val<string>(loaded.opened, 'egressRules'), last: val<string>(loaded.opened, 'egressRules'), timer: 0 as any, kept: false });
  const firewallEdited = useCallback((rules: string) => {
    if (target.mode !== 'workspace') return;
    clearTimeout(fw.current.timer);
    fw.current.timer = setTimeout(() => {
      if (rules === fw.current.last) return;
      fw.current.last = rules;
      host.request('POST', `/profiles/${seg(target.workspaceID!)}/firewall`, { rules }, { allowError: true }).catch(() => {});
    }, 400);
  }, [host, target.mode, target.workspaceID]);
  /** Closed any way but a save: the firewall edits go back. */
  const revertFirewall = useCallback(() => {
    clearTimeout(fw.current.timer);
    if (target.mode !== 'workspace' || fw.current.kept || fw.current.last === fw.current.opening) return;
    fw.current.last = fw.current.opening;
    host.request('POST', `/profiles/${seg(target.workspaceID!)}/firewall`, { rules: fw.current.opening }, { allowError: true }).catch(() => {});
  }, [host, target.mode, target.workspaceID]);
  useEffect(() => () => revertFirewall(), [revertFirewall]);

  const refreshStorage = useCallback(() => {
    if (target.mode !== 'workspace') return;
    host.request<StorageInfo>('GET', `/profiles/${seg(target.workspaceID!)}?storage=1`)
      .then(s => { if (s && typeof s.baseBytes === 'number') setStorage(s); }).catch(() => {});
  }, [host, target.mode, target.workspaceID]);

  const name = String(doc.name ?? '').trim();
  const titleText = name || (isNew ? 'New workspace' : 'Edit workspace');
  const windowTitle = isPrefs ? 'Bromure — Preferences' : `${titleText} — ${host.target.name}`;
  useEffect(() => { setTitle?.(windowTitle); }, [windowTitle, setTitle]);

  const dirty = !deepEqual(doc, loaded.opened) || !deepEqual(globalModels, loaded.openedGlobal);
  const dirtyRef = useRef(dirty); dirtyRef.current = dirty;
  const isValid = name.length > 0 && Object.keys(invalid).length === 0;

  // Closing with edits asks first (Cancel itself is the explicit discard).
  const requestClose = useCallback(() => {
    if (!dirtyRef.current) { close(); return; }
    setAlert({
      title: 'Discard your changes?',
      message: isNew ? 'This workspace hasn’t been created yet.' : 'The changes you made in this window haven’t been saved.',
      buttons: [
        { label: 'Discard', destructive: true, action: () => close() },
        { label: 'Keep Editing', cancel: true },
      ],
    });
  }, [close, isNew]);
  useEffect(() => { registerCloseGuard?.(() => { if (!dirtyRef.current) return true; requestClose(); return false; }); }, [registerCloseGuard, requestClose]);

  const commitSave = async () => {
    if (!isValid || saving) return;
    setSaving(true);
    try {
      if (isPrefs) {
        if (!deepEqual(globalModels, loaded.openedGlobal)) {
          const r = await host.request<Doc>('PUT', '/models/settings', globalModels, { allowError: true });
          if (r?.ok !== true) throw new Error(r?.error ?? 'Couldn’t save the model settings');
        }
        const r = await host.request<Doc>('PUT', '/preferences', wholeDocument(doc), { allowError: true });
        if (r?.ok !== true) throw new Error(r?.error ?? 'save failed');
        host.refreshSoon();
        close();
      } else if (isNew) {
        const out = settingsDocument(doc, loaded.template ?? {});
        delete out.id; delete out.createdAt;
        out.name = doc.name;
        if (generateSSH) out.generateSSH = true;
        const r = await host.request<Doc>('POST', '/profiles', out, { allowError: true });
        if (r?.ok !== true) throw new Error(r?.error ?? 'create failed');
        host.refreshSoon();
        close();
        if (generateSSH && r.sshPublicKey) window.dispatchEvent(new CustomEvent('bromure:editor-alert', { detail: sshAlert(r.sshPublicKey) }));
      } else {
        const out = settingsDocument(doc, loaded.opened);
        if (generateSSH) out.generateSSH = true;
        const r = await host.request<Doc>('PUT', `/profiles/${seg(target.workspaceID!)}`, out, { allowError: true });
        if (r?.ok !== true) throw new Error(r?.error ?? 'save failed');
        fw.current.kept = true;
        host.refreshSoon();
        const state = workspaces.find(w => w.id === target.workspaceID)?.state;
        const restart = restartRequiringChanges(loaded.opened, doc) && (state === 'running' || state === 'booting');
        close();
        if (generateSSH && r.sshPublicKey) window.dispatchEvent(new CustomEvent('bromure:editor-alert', { detail: sshAlert(r.sshPublicKey) }));
        if (restart) window.dispatchEvent(new CustomEvent('bromure:editor-alert', { detail: restartAlert(host, target.workspaceID!, String(doc.name)) }));
      }
    } catch (e: any) {
      setAlert({
        title: isPrefs ? `Couldn’t save the preferences on ${host.target.name}.` : isNew ? 'Couldn’t create the workspace' : 'Couldn’t save the workspace',
        message: String(e?.message ?? e), buttons: [{ label: 'OK', cancel: true }],
      });
    } finally {
      setSaving(false);
    }
  };

  // Keyboard: Return = Save (defaultAction), Escape = Cancel (cancelAction).
  const rootRef = useRef<HTMLDivElement>(null);
  const onKeyDown = (e: React.KeyboardEvent) => {
    if (alert) return;
    const t = e.target as HTMLElement;
    if (e.key === 'Escape' && !document.querySelector('.menu, .popover, .sheet-backdrop')) { e.preventDefault(); close(); }
    else if (e.key === 'Enter' && !e.shiftKey && (t.tagName !== 'TEXTAREA' || 'returnSaves' in t.dataset) && t.tagName !== 'BUTTON' && t.tagName !== 'SELECT' && t.tagName !== 'A' && !(t as HTMLElement).isContentEditable
             && !document.querySelector('.menu, .popover, .sheet-backdrop')) { e.preventDefault(); commitSave(); }
    else if (isMod(e) && e.key === 'f') { e.preventDefault(); rootRef.current?.querySelector<HTMLInputElement>('.ed-search input')?.focus(); }
  };

  // Which panes: Automation is this-Mac UserDefaults — never a remote's.
  const visible = useMemo(() => CATEGORIES.map(c => c.id).filter(id => id !== 'automation'), []);
  const searched = useMemo(() => searchCategories(visible, search), [visible, search]);
  // The search lands on its first match.
  useEffect(() => {
    if (searched.length && !searched.includes(selected)) setSelected(searched[0]);
  }, [searched]); // eslint-disable-line react-hooks/exhaustive-deps

  const ctx: EditorCtxValue = {
    host, mode: target.mode, workspaceID: target.workspaceID, doc, opened: loaded.opened, set, update,
    isTemplate, isNew,
    credentialRefs: (loaded.opened.configuredCredentialRefs as string[]) ?? [],
    siblings: workspaces.filter(w => w.id !== doc.id).map(w => ({ id: w.id, name: w.name })),
    globalModels, setGlobalModels: isPrefs ? setGlobalModels : undefined,
    storage, refreshStorage, appTaskFinish: loaded.appTaskFinish,
    generateSSH, setGenerateSSH, setInvalid, firewallEdited,
    select: setSelected,
    openPreferences: c => window.dispatchEvent(new CustomEvent('bromure:open', { detail: { what: 'preferences', category: c } })),
    hostName: host.target.name,
  };

  const Pane = PANES[selected];
  return (
    <EditorCtx.Provider value={ctx}>
      <EditorFrame frameless={frameless} title={windowTitle} close={close} onCloseRequest={requestClose}>
        <div className="ed-root" ref={rootRef} onKeyDown={onKeyDown}>
          <div className="ed-split">
            <aside className="ed-sidebar">
              <div className="ed-search">
                <SF name="magnifyingglass" size={13} weight={500} />
                <input value={search} placeholder="Search settings" aria-label="Search settings" spellCheck={false}
                       onChange={e => setSearch(e.target.value)} />
                {search && <span className="ed-search-clear" onClick={() => setSearch('')}><SF name="xmark.circle.fill" size={12} /></span>}
              </div>
              <div className="ed-catlist" role="listbox" aria-label="Settings categories">
                {GROUPS.map(g => {
                  const cats = GROUP_ORDER[g].filter(id => searched.includes(id));
                  if (!cats.length) return null;
                  return (
                    <div key={g} className="ed-catgroup">
                      <div className="ed-catgroup-title">{g}</div>
                      {cats.map(id => {
                        const c = category(id);
                        return (
                          <div key={id} role="option" aria-selected={selected === id}
                               className={cx('ed-catrow', selected === id && 'selected')}
                               onMouseDown={() => setSelected(id)}>
                            <CategoryIcon id={id} color={c.color} />
                            <span>{c.label}</span>
                          </div>
                        );
                      })}
                    </div>
                  );
                })}
              </div>
            </aside>
            <div className="ed-sep" />
            <main className="ed-detail">
              <div className="ed-detail-inner">
                <div className="ed-title">{titleText}</div>
                {Pane ? <Pane key={selected} /> : null}
              </div>
            </main>
          </div>
          <div className="ed-footer">
            <Button onClick={close}>Cancel</Button>
            <div style={{ flex: 1 }} />
            <Button variant="prominent" className="ed-save" disabled={!isValid || saving} onClick={commitSave}
                    title={Object.values(invalid)[0]}>
              {isNew ? 'Create' : 'Save'}
            </Button>
          </div>
          {alert && <AlertSheet spec={alert} onDone={() => setAlert(null)} />}
        </div>
      </EditorFrame>
    </EditorCtx.Provider>
  );
}

// ── alerts (NSAlert as a sheet) ──────────────────────────────────────────

export interface AlertSpec {
  title: string; message?: string; selectable?: boolean;
  buttons: { label: string; destructive?: boolean; cancel?: boolean; prominent?: boolean; action?: () => void }[];
}

export function AlertSheet({ spec, onDone }: { spec: AlertSpec; onDone: () => void }) {
  return (
    <Sheet width={300} onClose={onDone}>
      <div className="ed-alert">
        <div className="ed-alert-title">{spec.title}</div>
        {spec.message && <div className={cx('ed-alert-msg', spec.selectable && 'selectable')}>{spec.message}</div>}
        <div className="ed-alert-buttons">
          {spec.buttons.map((b, i) => (
            <Button key={i} variant={(b.prominent ?? i === 0) && !b.cancel ? 'prominent' : 'default'} destructive={b.destructive}
                    autoFocus={i === 0} onClick={() => { onDone(); b.action?.(); }}>{b.label}</Button>
          ))}
        </div>
      </div>
    </Sheet>
  );
}

function sshAlert(pub: string): AlertSpec {
  return { title: 'New SSH key generated', message: `Add this public key to your Git host:\n\n${pub}`, selectable: true,
    buttons: [{ label: 'OK', prominent: true }] };
}

function restartAlert(host: RemoteHost, id: string, name: string): AlertSpec {
  return {
    title: `Restart “${name}” to apply these changes?`,
    message: 'Some settings you changed (like networking, memory, or shared folders) are baked into the VM at boot, so the running workspace won’t pick them up until it restarts.',
    buttons: [
      { label: 'Restart Now', prominent: true, action: () => host.send('POST', `/vms/${seg(id)}/reboot`, { mode: 'soft' }) },
      { label: 'Later', cancel: true },
    ],
  };
}
