// "Choose…" in the Where popover (GuestFolderPickerView): browse the
// machine's folders through POST /agent-sessions/folders.

import React, { useEffect, useState } from 'react';
import { SF } from '../../ui/icons';
import { Button, Sheet, Spinner, cx, useMenu } from '../../ui/kit';
import { useHostCtx } from '../../app/hostContext';

const parentFolder = (p: string) => {
  if (p === '~' || p === '/') return p;
  const cut = p.lastIndexOf('/');
  if (cut < 0) return '~';
  return p.slice(0, cut) || '/';
};
const childFolder = (p: string, name: string) => (p === '/' ? '/' + name : p + '/' + name);
const ancestors = (p: string) => {
  const out = [p];
  for (let cur = p; ;) { const up = parentFolder(cur); if (up === cur) break; out.push(up); cur = up; }
  return out;
};
const nameOf = (p: string) => (p === '~' || p === '/' ? p : p.split('/').filter(Boolean).pop() ?? p);
const pretty = (p: string) => {
  const home = '/home/ubuntu';
  if (p === home || p === '~' || !p) return '~';
  return p.startsWith(home + '/') ? '~' + p.slice(home.length) : p;
};

export function FolderPickerSheet({ profileID, machineName, start, onPick, onClose }: {
  profileID: string; machineName: string; start: string; onPick: (p: string) => void; onClose: () => void;
}) {
  const { host } = useHostCtx();
  const menu = useMenu();
  const [path, setPath] = useState(start || '~');
  const [entries, setEntries] = useState<string[] | null>(null);
  const [unavailable, setUnavailable] = useState(false);
  const [selected, setSelected] = useState<string | null>(null);
  const chosen = selected ? childFolder(path, selected) : path;
  const canChoose = chosen !== '~' && chosen !== '/';

  useEffect(() => {
    let live = true;
    setEntries(null); setUnavailable(false);
    host.request<any>('POST', '/agent-sessions/folders', { profile: profileID, path }, { allowError: true, timeoutMs: 30000 })
      .then(r => { if (!live) return; if (Array.isArray(r?.folders)) setEntries(r.folders); else setUnavailable(true); })
      .catch(() => { if (live) setUnavailable(true); });
    return () => { live = false; };
  }, [host, profileID, path]);

  const go = (p: string) => { setSelected(null); setPath(p); };
  const choose = (p: string) => { onPick(p); onClose(); };

  return (
    <Sheet width={560} height={440} onClose={onClose}>
      <div className="ns-fp">
        <div className="ns-fp-head">
          <Button variant="icon" disabled={path === '~' || path === '/'} onClick={() => go(parentFolder(path))} title="Up one folder">
            <SF name="chevron.left" size={12} weight={600} />
          </Button>
          <button className="ns-fp-path" onClick={e => menu((e.currentTarget as HTMLElement).getBoundingClientRect(),
            ancestors(path).map(p => ({ label: pretty(p), icon: 'folder', action: () => go(p) })))}>
            <SF name="folder.fill" size={14} color="var(--accent)" />
            <span>{nameOf(path)}</span>
            <SF name="chevron.up.chevron.down" size={10} className="secondary" />
          </button>
          <span style={{ flex: 1 }} />
          {entries === null && !unavailable && <Spinner size={12} />}
          {machineName && <span className="ns-fp-machine">{machineName}</span>}
        </div>
        <div className="ns-fp-sep" />
        <div className="ns-fp-list">
          {unavailable ? <div className="ns-fp-ph">The machine's folders can't be read right now.</div>
            : entries && !entries.length ? <div className="ns-fp-ph">No folders in here yet.</div>
            : entries?.map(name => (
              <div key={name} className={cx('ns-fp-row', selected === name && 'on')}
                   onClick={() => setSelected(name)} onDoubleClick={() => go(childFolder(path, name))}
                   onContextMenu={e => { e.preventDefault(); setSelected(name); menu(e, [
                     { label: 'Open', action: () => go(childFolder(path, name)) },
                     { label: 'Choose', action: () => choose(childFolder(path, name)) },
                   ]); }}>
                <SF name="folder.fill" size={14} color={selected === name ? undefined : 'color-mix(in srgb, var(--accent) 85%, transparent)'} />
                <span>{name}</span>
              </div>
            ))}
        </div>
        <div className="ns-fp-sep" />
        <div className="ns-fp-foot">
          <span className="ns-fp-chosen mono">{pretty(chosen)}</span>
          <span style={{ flex: 1 }} />
          <Button onClick={onClose}>Cancel</Button>
          <Button variant="prominent" disabled={!canChoose} onClick={() => choose(chosen)}>Choose</Button>
        </div>
      </div>
    </Sheet>
  );
}
