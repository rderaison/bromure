// NSAlert / small naming sheets for the sidebar's menus (confirm delete,
// reboot, branch fate, Nickname…, New Room…, Rename…). A tiny imperative
// store so action code can `await confirmAlert(...)` like
// `alert.beginSheetModal`.

import React, { useEffect, useRef, useState, useSyncExternalStore } from 'react';
import { Sheet, Button, TextField } from '../../ui/kit';
import { SF } from '../../ui/icons';

export interface AlertButton { label: string; value: string; destructive?: boolean; default?: boolean }
interface AlertReq { kind: 'alert'; title: string; message?: string; buttons: AlertButton[]; resolve: (v: string | null) => void }
interface CustomReq { kind: 'custom'; render: (close: () => void) => React.ReactNode; width: number; resolve: () => void }
type Req = AlertReq | CustomReq;

let queue: Req[] = [];
const subs = new Set<() => void>();
const emit = () => { for (const l of [...subs]) l(); };
function push(r: Req) { queue = [...queue, r]; emit(); }
function pop(r: Req) { queue = queue.filter(x => x !== r); emit(); }

/** An NSAlert: resolves with the clicked button's value, null on Cancel/Escape. */
export function showAlert(title: string, message: string | undefined, buttons: AlertButton[]): Promise<string | null> {
  return new Promise(resolve => push({ kind: 'alert', title, message, buttons, resolve }));
}
/** Two-button confirm ("Delete" / "Cancel"). */
export async function confirmAlert(title: string, message: string, ok: string, destructive = false): Promise<boolean> {
  return (await showAlert(title, message, [{ label: ok, value: 'ok', destructive, default: !destructive }, { label: 'Cancel', value: 'cancel' }])) === 'ok';
}
/** A custom sheet (naming sheets). */
export function showSheet(width: number, render: (close: () => void) => React.ReactNode): Promise<void> {
  return new Promise(resolve => push({ kind: 'custom', width, render, resolve }));
}

export function DialogHost() {
  const list = useSyncExternalStore(cb => { subs.add(cb); return () => subs.delete(cb); }, () => queue);
  const top = list[0];
  if (!top) return null;
  if (top.kind === 'custom') {
    const close = () => { pop(top); top.resolve(); };
    return <Sheet width={top.width} onClose={close}>{top.render(close)}</Sheet>;
  }
  const done = (v: string | null) => { pop(top); top.resolve(v); };
  return (
    <Sheet width={260} onClose={() => done(null)}>
      <div className="sb-alert">
        <div className="sb-alert-icon"><SF name="exclamationmark.triangle.fill" size={30} color="var(--orange)" /></div>
        <div className="sb-alert-title">{top.title}</div>
        {top.message && <div className="sb-alert-msg">{top.message}</div>}
        <div className="sb-alert-buttons">
          {top.buttons.map((b, i) => (
            <Button key={b.value} variant={b.default || (i === 0 && !top.buttons.some(x => x.default)) ? 'prominent' : 'default'}
                    destructive={b.destructive} onClick={() => done(b.value === 'cancel' ? null : b.value)}
                    autoFocus={b.default}>{b.label}</Button>
          ))}
        </div>
      </div>
    </Sheet>
  );
}

/** Name a room / rename one (RoomNameSheet). */
export function RoomNameSheet({ title, action, initial = '', onSet, close }: {
  title: string; action: string; initial?: string; onSet: (name: string) => void; close: () => void;
}) {
  const [name, setName] = useState(initial);
  const ref = useRef<HTMLInputElement>(null);
  useEffect(() => { ref.current?.focus(); ref.current?.select(); }, []);
  const trimmed = name.trim();
  const save = () => { if (!trimmed) return; onSet(trimmed); close(); };
  return (
    <div className="sb-namesheet">
      <div>
        <div className="sb-namesheet-title">{title}</div>
        <div className="sb-namesheet-sub">A room groups sessions that work on the same thing. Its own Switchboard keeps track of them — and only them.</div>
      </div>
      <TextField ref={ref} value={name} placeholder="e.g. Payments v2" onChange={e => setName(e.target.value)}
                 onKeyDown={e => { if (e.key === 'Enter') save(); }} />
      <div className="sb-namesheet-buttons">
        <span style={{ flex: 1 }} />
        <Button onClick={close}>Cancel</Button>
        <Button variant="prominent" disabled={!trimmed} onClick={save}>{action}</Button>
      </div>
    </div>
  );
}
