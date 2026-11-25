// NicknameSheet (SessionStageViews.swift): the name other agents reach a
// session by. Checked against the mirror first; the server checks again.

import React, { useEffect, useRef, useState } from 'react';
import { Button, TextField } from '../../ui/kit';
import { SF } from '../../ui/icons';
import type { AgentSession } from '../../core/remote/types';
import { checkNickname, normalizeNickname } from './model';

export function NicknameSheet({ session, sessions, onSet, close }: {
  session: AgentSession; sessions: AgentSession[]; onSet: (nick: string, reclaim: boolean) => void; close: () => void;
}) {
  const [name, setName] = useState(session.nickname ?? '');
  const [error, setError] = useState<string | null>(null);
  const [reclaim, setReclaim] = useState<string | null>(null);
  const ref = useRef<HTMLInputElement>(null);
  useEffect(() => { ref.current?.focus(); }, []);
  const normalized = normalizeNickname(name);
  const save = () => {
    if (!normalized) return;
    if (!reclaim) {
      const v = checkNickname(session.id, name, sessions);
      if (v.kind === 'refused') { setError(v.why); return; }
      if (v.kind === 'reclaim') { setReclaim(v.question); return; }
    }
    onSet(name, !!reclaim);
    close();
  };
  return (
    <div className="sb-namesheet">
      <div>
        <div className="sb-namesheet-title">Nickname</div>
        <div className="sb-namesheet-sub">
          How other agents reach “{session.title}”: they ask it with request(to: "@name"), and you can write @name in any composer. Letters, digits, dots, dashes and underscores.
        </div>
      </div>
      <div className="row" style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
        <span className="mono" style={{ fontSize: 14, fontWeight: 500, color: 'var(--label-secondary)' }}>@</span>
        <TextField ref={ref} mono value={name} placeholder="e.g. seclio" style={{ flex: 1 }}
                   onChange={e => { setName(e.target.value); setReclaim(null); setError(null); }}
                   onKeyDown={e => { if (e.key === 'Enter') save(); }} />
      </div>
      {reclaim ? <div className="sb-namesheet-note"><SF name="archivebox" size={12} />{reclaim}</div>
        : error ? <div className="sb-namesheet-note warn"><SF name="exclamationmark.triangle.fill" size={12} />{error}</div>
        : normalized && normalized !== name.trim() ? <div className="sb-namesheet-hint">Will be @{normalized}</div> : null}
      <div className="sb-namesheet-buttons">
        {session.nickname && <Button onClick={() => { onSet('', false); close(); }}>Clear</Button>}
        <span style={{ flex: 1 }} />
        <Button onClick={close}>Cancel</Button>
        <Button variant="prominent" disabled={!normalized} onClick={save}>{reclaim ? 'Reuse' : 'Set'}</Button>
      </div>
    </div>
  );
}
