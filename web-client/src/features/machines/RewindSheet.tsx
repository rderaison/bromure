// HomeRewindSheet.swift: a machine's home rollback points (one per boot,
// thinned over time); the next start boots from the one picked. The machine
// has to be off; the current home is checkpointed first, so a rewind can be
// undone from the same list.

import { SF } from './parts';
import React, { useEffect, useState } from 'react';
import type { RemoteHost } from '../../core/remote/host';
import { Button, Spinner } from '../../ui/kit';
import { actions } from './actions';
import { abbreviatedDateTime, fileBytes, relativeAbbrev } from './util';

interface CP { id: string; createdAt: Date; allocatedBytes: number }

export function RewindSheet({ host, workspaceID, name, isRunning, onClose }: {
  host: RemoteHost; workspaceID: string; name: string; isRunning: () => boolean; onClose: () => void;
}) {
  const a = actions(host);
  const [cps, setCps] = useState<CP[] | null>(null);
  const [selected, setSelected] = useState<string | null>(null);
  const [running, setRunning] = useState(isRunning());
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [done, setDone] = useState<CP | null>(null);

  useEffect(() => {
    let live = true;
    a.checkpoints(workspaceID).then(list => { if (!live) return; setCps(list); setSelected(s => s ?? list[0]?.id ?? null); });
    const t = setInterval(() => setRunning(isRunning()), 1000);
    return () => { live = false; clearInterval(t); };
  }, [host, workspaceID]); // eslint-disable-line

  useEffect(() => {
    const k = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose();
      else if (e.key === 'Enter') { if (done) onClose(); else void rewind(); }
    };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  });

  const rewind = async () => {
    const cp = cps?.find(c => c.id === selected);
    if (!cp || busy || running) return;
    setBusy(true); setError(null);
    const why = await a.rewindHome(workspaceID, cp.id);
    setBusy(false);
    if (why) setError(why); else setDone(cp);
  };

  return (
    <div className="mc-sheet mc-rewind">
      <div className="mc-col" style={{ gap: 4 }}>
        <div style={{ fontSize: 15, fontWeight: 600 }}>Rewind “{name}”’s home</div>
        <div className="mc-secondary" style={{ fontSize: 12, lineHeight: '16px' }}>Each point is the home folder as it was when that boot started. The next start boots from the one you pick; the home as it is now is kept as a new point, so this can be undone here.</div>
      </div>
      {done ? (
        <div className="mc-row" style={{ gap: 8, fontSize: 12.5, alignItems: 'flex-start' }}>
          <SF name="checkmark.circle.fill" size={14} color="var(--green)" />
          <span>Done — the next start of “{name}” boots from its home of {abbreviatedDateTime(done.createdAt)}.</span>
        </div>
      ) : <>
        {cps === null ? (
          <div style={{ minHeight: 80, display: 'grid', placeItems: 'center' }}><Spinner /></div>
        ) : cps.length === 0 ? (
          <div className="mc-secondary" style={{ fontSize: 12, minHeight: 80, display: 'grid', placeItems: 'center', textAlign: 'center' }}>No rollback points yet — one is taken each time this machine starts.</div>
        ) : (
          <div className="mc-cp-list" style={{ height: Math.min(260, cps.length * 40 + 12) }}>
            {cps.map(cp => (
              <div key={cp.id} className={'mc-cp' + (selected === cp.id ? ' on' : '')} onClick={() => setSelected(cp.id)}>
                <SF name="clock.arrow.circlepath" size={14} className="mc-secondary" />
                <span className="mc-col" style={{ gap: 1 }}>
                  <span style={{ fontSize: 12.5, fontWeight: 500 }}>{abbreviatedDateTime(cp.createdAt)}</span>
                  <span className="mc-secondary" style={{ fontSize: 11 }}>{relativeAbbrev(cp.createdAt)}</span>
                </span>
                <span className="mc-spacer" />
                <span className="mc-tertiary mc-num" style={{ fontSize: 11 }}>{fileBytes(cp.allocatedBytes)}</span>
              </div>
            ))}
          </div>
        )}
        {running && (
          <div className="mc-row" style={{ gap: 8 }}>
            <SF name="power" size={14} className="mc-secondary" />
            <span className="mc-secondary" style={{ fontSize: 11.5, flex: 1 }}>The machine is running — its home can't be swapped while it's in use. Shut it down first.</span>
            <Button size="small" className="mc-btn-bordered" onClick={() => a.shutdown(workspaceID)}>Shut down</Button>
          </div>
        )}
        {error && <div className="mc-row" style={{ gap: 6, fontSize: 11.5, color: 'var(--orange)' }}><SF name="exclamationmark.triangle.fill" size={12} />{error}</div>}
      </>}
      <div className="mc-row" style={{ gap: 8, justifyContent: 'flex-end' }}>
        {done ? <Button variant="prominent" onClick={onClose}>OK</Button> : <>
          <Button onClick={onClose}>Cancel</Button>
          <Button variant="prominent" disabled={!selected || running || busy} onClick={() => void rewind()}>{busy ? <Spinner size={12} /> : 'Rewind'}</Button>
        </>}
      </div>
    </div>
  );
}
