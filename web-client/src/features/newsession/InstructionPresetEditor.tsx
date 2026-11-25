// "Edit instructions…" (InstructionPresets.swift InstructionPresetEditor):
// the server's session-instruction presets, saved with POST
// /instruction-presets {presets:[{id,name,text}]}. Unusable ones (no name or
// no text) aren't kept.

import React, { useState } from 'react';
import { SF } from '../../ui/icons';
import { Button, Sheet, TextField, cx } from '../../ui/kit';
import { useHostCtx } from '../../app/hostContext';

interface Preset { id: string; name: string; text: string }
const usable = (p: Preset) => !!p.name.trim() && !!p.text.trim();

export function InstructionPresetEditor({ presets, initial, onClose }: {
  presets: Preset[]; initial: string | null; onClose: () => void;
}) {
  const { host } = useHostCtx();
  const [draft, setDraft] = useState<Preset[]>(() => presets.map(p => ({ ...p })));
  const [selection, setSelection] = useState<string | null>(() => draft.find(p => p.id === initial)?.id ?? draft[0]?.id ?? null);
  const changed = JSON.stringify(draft) !== JSON.stringify(presets.map(p => ({ id: p.id, name: p.name, text: p.text })));
  const cur = draft.find(p => p.id === selection);
  const update = (patch: Partial<Preset>) => setDraft(d => d.map(p => p.id === selection ? { ...p, ...patch } : p));

  const add = () => {
    const p = { id: crypto.randomUUID().toUpperCase(), name: 'New instructions', text: '' };
    setDraft(d => [...d, p]); setSelection(p.id);
  };
  const del = () => {
    const i = draft.findIndex(p => p.id === selection); if (i < 0) return;
    const next = draft.filter((_, j) => j !== i);
    setDraft(next); setSelection(next[i]?.id ?? next[next.length - 1]?.id ?? null);
  };
  const save = () => {
    host.send('POST', '/instruction-presets', { presets: draft.filter(usable).map(p => ({ id: p.id, name: p.name.trim(), text: p.text })) });
    onClose();
  };

  return (
    <Sheet width={680} height={440} onClose={onClose}>
      <div className="ns-ip">
        <div className="ns-ip-main">
          <div className="ns-ip-side">
            <div className="ns-ip-list">
              {draft.map(p => (
                <div key={p.id} className={cx('ns-ip-item', p.id === selection && 'on', !usable(p) && 'unusable')} onClick={() => setSelection(p.id)}>
                  {p.name || 'Untitled'}
                </div>
              ))}
            </div>
            <div className="ns-fp-sep" />
            <div className="ns-ip-pm">
              <Button variant="borderless" onClick={add} title="Add instructions"><SF name="plus" size={13} /></Button>
              <Button variant="borderless" disabled={!selection} onClick={del} title="Delete these instructions"><SF name="minus" size={13} /></Button>
            </div>
          </div>
          <div className="ns-ip-form">
            {cur ? (<>
              <TextField value={cur.name} placeholder="Name" onChange={e => update({ name: e.target.value })} style={{ fontWeight: 600, width: '100%' }} />
              <textarea className="ns-ip-text" value={cur.text} onChange={e => update({ text: e.target.value })} />
              <div className="ns-ip-note">Added to the agent's system prompt when a session starts with them. Describe who the agent should be and how it should work — “You are a…”.</div>
            </>) : <div className="ns-fp-ph">No instructions yet. Add some with +.</div>}
          </div>
        </div>
        <div className="ns-fp-sep" />
        <div className="ns-fp-foot">
          {draft.some(p => !usable(p)) && <span className="ns-ip-note">Instructions without a name or text are not kept.</span>}
          <span style={{ flex: 1 }} />
          <Button onClick={onClose}>Cancel</Button>
          <Button variant="prominent" disabled={!changed} onClick={save}>Save</Button>
        </div>
      </div>
    </Sheet>
  );
}
