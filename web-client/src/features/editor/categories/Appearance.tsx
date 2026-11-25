// Appearance — ProfileViews.swift `appearanceSection` (the workspace's
// terminal look). Unset fields show what `Profile.seedAppearance` seeds
// (JetBrains Mono 12, #212734, Terminal.app's text colour) without marking
// the draft edited. There's no Terminal.app here: its defaults are
// TerminalAppDefaults.fallback.

import React from 'react';
import { Button } from '../../../ui/kit';
import { useEditor } from '../ctx';
import { val } from '../model';
import { Caption, Divider } from '../ui';
import { BorderedPopUp, ColorWell, MacCheck, Slider, Stepper } from './FoldersKit';

/** TerminalAppDefaults.fallback */
const TERMINAL = { fontFamily: 'JetBrains Mono', fontSize: 14, backgroundHex: '#0d1117', foregroundHex: '#c9d1d9' };
/** seedAppearance */
const SEED = { fontFamily: 'JetBrains Mono', fontSize: 12, backgroundHex: '#212734', foregroundHex: TERMINAL.foregroundHex };
/** Fonts the guest always has (ProfileEditorView.guestBundledFonts) + common monospace families. */
const FONTS = ['JetBrains Mono', 'SF Mono', 'SF Mono Terminal', 'Menlo', 'Monaco', 'Courier', 'Courier New', 'Andale Mono',
  'PT Mono', 'Source Code Pro', 'Fira Code', 'Fira Mono', 'IBM Plex Mono', 'Hack', 'Cascadia Code', 'Cascadia Mono',
  'DejaVu Sans Mono', 'Ubuntu Mono', 'Inconsolata', 'Roboto Mono'];
const CURSORS = [{ value: 'block', label: 'Block' }, { value: 'beam', label: 'Beam (I-cursor)' }, { value: 'underline', label: 'Underline' }];

export function AppearancePane() {
  const { doc, set, update } = useEditor();
  const family: string = doc.customFontFamily ?? SEED.fontFamily;
  const size: number = doc.customFontSize ?? SEED.fontSize;
  const bg: string = doc.customBackgroundHex ?? SEED.backgroundHex;
  const fg: string = doc.customForegroundHex ?? SEED.foregroundHex;
  const opacity = val<number>(doc, 'windowOpacity');
  const families = [...new Set([...FONTS, family])].filter(Boolean).sort((a, b) => a.localeCompare(b));
  return (
    <div className="edm-pane" style={{ gap: 14 }}>
      <div className="edm-app-row">
        <span className="edm-app-label">Font</span>
        <span className="edm-app-slot">
          <BorderedPopUp value={family} onChange={v => set('customFontFamily', v)} options={families.map(f => ({ value: f, label: f }))} />
        </span>
        <span className="edm-row" style={{ gap: 8 }}>
          <span className="mono" style={{ width: 50, textAlign: 'center', fontSize: 13 }}>{size} pt</span>
          <Stepper value={size} min={8} max={32} onChange={v => set('customFontSize', v)} />
        </span>
      </div>

      <div className="edm-app-row">
        <span className="edm-app-label">Cursor</span>
        <span className="edm-app-slot">
          <BorderedPopUp value={val<string>(doc, 'cursorShape')} onChange={v => set('cursorShape', v)} options={CURSORS} />
        </span>
        <MacCheck checked={val<boolean>(doc, 'cursorBlink')} onChange={v => set('cursorBlink', v)}>Blinking</MacCheck>
      </div>

      <div className="edm-app-row" style={{ gap: 24 }}>
        <span className="edm-app-label">Colors</span>
        <ColorWell label="Background" value={bg} onChange={h => set('customBackgroundHex', h)} />
        <ColorWell label="Text" value={fg} onChange={h => set('customForegroundHex', h)} />
      </div>

      <div className="edm-app-row">
        <span className="edm-app-label">Opacity</span>
        <span style={{ width: 240, display: 'flex' }}>
          <Slider value={opacity} min={0.3} max={1} onChange={v => set('windowOpacity', v)} />
        </span>
        <span className="mono" style={{ width: 44, fontSize: 13 }}>{Math.floor(opacity * 100)}%</span>
      </div>

      <Divider style={{ margin: '4px 0' }} />

      <div className="edm-row">
        <Caption>Defaults are seeded from your macOS Terminal.app profile.</Caption>
        <div style={{ flex: 1 }} />
        <Button onClick={() => update(d => {
          d.customFontFamily = 'JetBrains Mono';
          d.customFontSize = TERMINAL.fontSize;
          d.customBackgroundHex = TERMINAL.backgroundHex;
          d.customForegroundHex = TERMINAL.foregroundHex;
        })}>Reset to Terminal.app</Button>
      </div>
    </div>
  );
}
