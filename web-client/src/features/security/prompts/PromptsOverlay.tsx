// The host's decision prompts (/state.pendingPrompts — MITM consent for a
// credential, the exfiltration alert's Allow / Block / Shut Down, …) shown as
// alert sheets on the mirror window, answered with
// POST /prompts/<id>/answer {choice}; plus the compromised-workspace remedies
// ("Wipe and Restore…" / "Clear Compromised Mark…") asked here and done by the
// server (POST /profiles/<id>/compromised {action}).
//
// Port of RemoteHostController.applyPendingPrompts (FatClientController.swift)
// and RemoteHostWindow.confirmCompromiseRemedy.

import React, { useEffect, useState, useSyncExternalStore } from 'react';
import { createPortal } from 'react-dom';
import type { RemoteHost } from '../../../core/remote/host';
import { seg } from '../../../core/remote/host';
import { useRemote } from '../../../app/store';
import { useOpenListener } from '../../palette/events';
import { cx } from '../../../ui/kit';
import { SF } from '../../../ui/icons';
import '../security.css';

// ── A small NSAlert-as-sheet queue ───────────────────────────────────────

export interface AlertSpec {
  title: string;
  message?: string;
  buttons: string[];
  style?: 'informational' | 'warning';
  /** The first button is destructive (red). */
  destructive?: boolean;
  /** Return doesn't press the first button (an explicit click only). */
  noReturn?: boolean;
}
interface Queued extends AlertSpec { key: string; resolve: (choice: number) => void }

let queue: Queued[] = [];
const listeners = new Set<() => void>();
const emit = () => { for (const l of [...listeners]) l(); };
let alertSeq = 0;

/** Show an alert sheet; resolves with the button index (-1: dismissed). */
export function showAlert(spec: AlertSpec): Promise<number> {
  return new Promise(resolve => {
    queue = [...queue, { ...spec, key: 'a' + (++alertSeq), resolve }];
    emit();
  });
}
function finish(key: string, choice: number) {
  const q = queue.find(x => x.key === key);
  queue = queue.filter(x => x.key !== key);
  emit();
  q?.resolve(choice);
}

// ── Compromise remedies ──────────────────────────────────────────────────

export type CompromiseRemedy = 'wipe' | 'clear';

function compromiseActionParts(remedy: CompromiseRemedy, name: string) {
  return remedy === 'wipe'
    ? { title: `Wipe “${name}”?`,
        message: 'Its system disk, home, and saved state are erased; its settings and credentials stay, and so do the project folders it mounts. It\'s no longer marked compromised and boots fresh next time.',
        button: 'Wipe' }
    : { title: `Clear the compromised mark on “${name}”?`,
        message: 'Only if it was a false alarm: the workspace starts on its current disk and home, without the wipe, as if nothing had happened. The leak itself was blocked either way; the Security Timeline keeps the event.',
        button: 'Clear Mark' };
}

/** "Wipe and Restore…" / "Clear Compromised Mark…" on a workspace marked
 *  compromised: asked here, done by the server. */
export async function confirmCompromiseRemedy(host: RemoteHost, workspaceID: string, remedy: CompromiseRemedy) {
  const name = host.state?.workspaces.find(w => w.id === workspaceID)?.name;
  if (name == null) return;
  const parts = compromiseActionParts(remedy, name);
  const choice = await showAlert({ title: parts.title, message: parts.message, buttons: [parts.button, 'Cancel'],
                                   style: 'warning', destructive: true, noReturn: true });
  if (choice !== 0) return;
  const r = await host.request<any>('POST', `/profiles/${seg(workspaceID)}/compromised`, { action: remedy }, { allowError: true })
    .catch(() => null);
  if (r && r.ok !== false && !r.error) { host.refreshSoon(); return; }
  await showAlert({
    title: remedy === 'wipe' ? `Couldn't wipe “${name}”` : `Couldn't clear the mark on “${name}”`,
    message: r?.error ?? 'The server didn\'t answer.', buttons: ['OK'],
  });
}

// ── The overlay ──────────────────────────────────────────────────────────

interface Prompt { id: string; title: string; message: string; buttons: string[] }

export function PromptsOverlay({ host }: { host: RemoteHost }) {
  const raw = useRemote(host, s => s.pendingPrompts);
  const alerts = useSyncExternalStore(l => { listeners.add(l); return () => { listeners.delete(l); }; }, () => queue);
  // Answered here: hidden at once (the next snapshot confirms it's gone).
  const [answered, setAnswered] = useState<Set<string>>(new Set());

  const prompts: Prompt[] = (raw ?? []).flatMap((p: any) => typeof p?.id === 'string' ? [{
    id: p.id,
    title: typeof p.title === 'string' ? p.title : `Bromure — ${host.target.name}`,
    message: typeof p.message === 'string' ? p.message : '',
    buttons: Array.isArray(p.buttons) && p.buttons.length ? p.buttons.map(String) : ['OK'],
  }] : []);

  // Prune answered ids that left /state (answered elsewhere, or here).
  useEffect(() => {
    const live = new Set(prompts.map(p => p.id));
    if ([...answered].some(id => !live.has(id))) setAnswered(a => new Set([...a].filter(id => live.has(id))));
  }, [raw]); // eslint-disable-line react-hooks/exhaustive-deps

  useOpenListener(d => {
    if (d.what !== 'compromise') return;
    const id = (d.workspaceID ?? d.profileID) as string | undefined;
    const remedy = d.remedy === 'clear' ? 'clear' : 'wipe';
    if (id) confirmCompromiseRemedy(host, id, remedy);
  });

  // One sheet at a time: a window already showing a sheet queues the next.
  const prompt = prompts.find(p => !answered.has(p.id));
  if (prompt) {
    return <AlertSheet key={prompt.id} spec={{
      title: prompt.title, message: prompt.message, buttons: prompt.buttons,
      // Destructive-looking prompts shouldn't confirm on a stray Return.
      noReturn: prompt.buttons[0]?.toLowerCase().includes('wipe'),
    }} onChoose={choice => {
      setAnswered(a => new Set(a).add(prompt.id));
      host.send('POST', `/prompts/${seg(prompt.id)}/answer`, { choice: Math.max(0, Math.min(choice, prompt.buttons.length - 1)) });
    }} />;
  }
  const a = alerts[0];
  if (a) return <AlertSheet key={a.key} spec={a} onChoose={c => finish(a.key, c)} onDismiss={() => finish(a.key, -1)} />;
  return null;
}

/** NSAlert as a sheet: the app icon (badged for a warning), the message in
 *  bold, the informative text, and the buttons right to left. */
export function AlertSheet({ spec, onChoose, onDismiss }: { spec: AlertSpec; onChoose: (i: number) => void; onDismiss?: () => void }) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Enter' && !spec.noReturn) { e.preventDefault(); e.stopPropagation(); onChoose(0); }
      else if (e.key === 'Escape') {
        // Escape = the Cancel button (if any), else dismiss.
        const cancel = spec.buttons.findIndex(b => /^(cancel|don.t allow|block)$/i.test(b));
        e.preventDefault(); e.stopPropagation();
        if (cancel >= 0) onChoose(cancel); else onDismiss?.();
      }
    };
    window.addEventListener('keydown', onKey, true);
    return () => window.removeEventListener('keydown', onKey, true);
  }, [spec, onChoose, onDismiss]);
  const many = spec.buttons.length > 3;
  return createPortal(
    <div className="sheet-backdrop sec-alert-backdrop">
      <div className="sheet sec-alert" role="alertdialog" aria-label={spec.title}>
        <div className="sec-alert-icon">
          <SF name="lock.shield" size={40} color="var(--accent)" />
          {spec.style === 'warning' && <span className="sec-alert-badge"><SF name="exclamationmark.triangle.fill" size={18} color="var(--orange)" /></span>}
        </div>
        <div className="sec-alert-text">
          <div className="sec-alert-title selectable">{spec.title}</div>
          {spec.message && <div className="sec-alert-message selectable">{spec.message}</div>}
        </div>
        <div className={cx('sec-alert-buttons', many && 'stacked')}>
          {spec.buttons.map((b, i) => (
            <button key={i} className={cx('btn', i === 0 && !spec.noReturn && !spec.destructive && 'prominent', i === 0 && spec.destructive && 'destructive')}
                    onClick={() => onChoose(i)}>{b}</button>
          ))}
        </div>
      </div>
    </div>, document.body);
}
