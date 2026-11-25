// Controls the Machine panes (Folders, Environment, MCP, Browser, Resources)
// and Appearance share: macOS 26 checkbox Toggle, list-row cards, the
// borderless "+ Add…" button, Stepper, Slider, radio group, color well,
// bordered pop-up, and the text-prompt alert. Styles in Folders.css (.edm-).

import React, { useState } from 'react';
import { Button, Sheet, cx } from '../../../ui/kit';
import { SF } from '../../../ui/icons';
import './Folders.css';

/** Toggle(isOn:) { Label(title, systemImage:) } — macOS 26 checkbox. */
export function MacCheck({ checked, onChange, disabled, children, help, className }: {
  checked: boolean; onChange: (v: boolean) => void; disabled?: boolean; children?: React.ReactNode; help?: string; className?: string;
}) {
  return (
    <label className={cx('edm-check', disabled && 'disabled', className)} title={help}>
      <input type="checkbox" checked={checked} disabled={disabled} onChange={e => onChange(e.target.checked)} />
      <span className="edm-check-box" aria-hidden><svg viewBox="0 0 16 16" width="16" height="16"><path d="M4 8.4 6.9 11.2 12.2 4.8" /></svg></span>
      {children !== undefined && <span className="edm-check-label">{children}</span>}
    </label>
  );
}

/** Label(title, systemImage:) — glyph + title. */
export function SymLabel({ symbol, children, className }: { symbol: string; children: React.ReactNode; className?: string }) {
  return <span className={cx('edm-symlabel', className)}><SF name={symbol} size={14} weight={500} /><span>{children}</span></span>;
}

/** A list row on `platformTextBackground`, 8pt padding, radius 6. */
export function RowCard({ children, style, className }: { children: React.ReactNode; style?: React.CSSProperties; className?: string }) {
  return <div className={cx('edm-card', className)} style={style}>{children}</div>;
}

/** Button { Label("…", systemImage: "plus") }.buttonStyle(.borderless) */
export function BorderlessButton({ symbol, children, onClick, disabled, help, className }: {
  symbol?: string; children?: React.ReactNode; onClick?: () => void; disabled?: boolean; help?: string; className?: string;
}) {
  return (
    <button className={cx('edm-borderless', className)} onClick={onClick} disabled={disabled} title={help} aria-label={help}>
      {symbol && <SF name={symbol} size={children ? 15 : 14} />}{children && <span>{children}</span>}
    </button>
  );
}

/** The minus-circle remove button. */
export const RemoveButton = ({ onClick, help }: { onClick: () => void; help?: string }) =>
  <BorderlessButton symbol="minus.circle" onClick={onClick} help={help} className="edm-remove" />;

/** Stepper — the up/down capsule. */
export function Stepper({ value, onChange, min, max, step = 1, disabled }: {
  value: number; onChange: (v: number) => void; min: number; max: number; step?: number; disabled?: boolean;
}) {
  const clamp = (v: number) => Math.min(max, Math.max(min, v));
  return (
    <span className={cx('edm-stepper', disabled && 'disabled')} role="spinbutton" aria-valuenow={value} aria-valuemin={min} aria-valuemax={max}
          tabIndex={0} onKeyDown={e => {
            if (e.key === 'ArrowUp') { e.preventDefault(); onChange(clamp(value + step)); }
            if (e.key === 'ArrowDown') { e.preventDefault(); onChange(clamp(value - step)); }
          }}>
      <button tabIndex={-1} disabled={disabled || value >= max} onClick={() => onChange(clamp(value + step))} aria-label="Increment">
        <svg viewBox="0 0 12 8" width="12" height="8"><path d="M1.5 6.2 6 1.8l4.5 4.4" /></svg>
      </button>
      <button tabIndex={-1} disabled={disabled || value <= min} onClick={() => onChange(clamp(value - step))} aria-label="Decrement">
        <svg viewBox="0 0 12 8" width="12" height="8"><path d="M1.5 1.8 6 6.2l4.5-4.4" /></svg>
      </button>
    </span>
  );
}

/** Slider(value:in:) — the macOS 26 track + round knob. */
export function Slider({ value, onChange, min, max, step = 0.01, style }: {
  value: number; onChange: (v: number) => void; min: number; max: number; step?: number; style?: React.CSSProperties;
}) {
  const pct = ((value - min) / (max - min)) * 100;
  return (
    <input type="range" className="edm-slider" min={min} max={max} step={step} value={value} style={{ ...style, ['--pct' as any]: `${pct}%` }}
           onChange={e => onChange(Number(e.target.value))} />
  );
}

/** Picker(.radioGroup) */
export function RadioGroup<T extends string>({ value, options, onChange }: {
  value: T; options: { value: T; label: string }[]; onChange: (v: T) => void;
}) {
  return (
    <div className="edm-radios" role="radiogroup">
      {options.map(o => (
        <label key={o.value} className="edm-radio">
          <input type="radio" checked={value === o.value} onChange={() => onChange(o.value)} />
          <span className="edm-radio-dot" aria-hidden />
          <span>{o.label}</span>
        </label>
      ))}
    </div>
  );
}

/** ColorPicker(supportsOpacity: false) — the capsule color well. */
export function ColorWell({ value, onChange, label }: { value: string; onChange: (hex: string) => void; label: string }) {
  return (
    <label className="edm-colorrow">
      <span>{label}</span>
      <span className="edm-colorwell">
        <span className="edm-colorwell-fill" style={{ background: value }} />
        <input type="color" value={normalizeHex(value)} aria-label={label} onChange={e => onChange(e.target.value.toUpperCase())} />
      </span>
    </label>
  );
}

export function normalizeHex(h: string): string {
  let s = (h || '').trim().replace(/^#/, '');
  if (s.length === 3) s = s.split('').map(c => c + c).join('');
  return /^[0-9a-f]{6}$/i.test(s) ? `#${s.toLowerCase()}` : '#000000';
}

/** Picker(.menu) bordered (a Form-less Picker): grey rounded box + ⌃⌄. */
export function BorderedPopUp<T extends string>({ value, options, onChange, style }: {
  value: T; options: { value: T; label: string }[]; onChange: (v: T) => void; style?: React.CSSProperties;
}) {
  const cur = options.find(o => o.value === value);
  return (
    <span className="edm-popup" style={style}>
      <span className="edm-popup-label">
        {/* NSPopUpButton sizes to its widest item */}
        {options.map(o => <span key={o.value} className="edm-popup-sizer" aria-hidden>{o.label}</span>)}
        <span className="edm-popup-cur">{cur?.label ?? value}</span>
      </span>
      <svg className="edm-popup-chev" viewBox="0 0 10 14" width="10" height="14" aria-hidden><path d="M1.6 5 5 1.7 8.4 5M1.6 9 5 12.3 8.4 9" /></svg>
      <select value={value} onChange={e => onChange(e.target.value as T)}>
        {options.map(o => <option key={o.value} value={o.value}>{o.label}</option>)}
      </select>
    </span>
  );
}

/** An NSAlert-style prompt with one text field (iOS "Add a shared folder"). */
export function TextPrompt({ title, message, placeholder, okLabel = 'Add', onOK, onCancel }: {
  title: string; message?: string; placeholder?: string; okLabel?: string; onOK: (v: string) => void; onCancel: () => void;
}) {
  const [v, setV] = useState('');
  return (
    <Sheet width={300} onClose={onCancel}>
      <form className="edm-prompt" onSubmit={e => { e.preventDefault(); onOK(v); }}>
        <div className="edm-prompt-title">{title}</div>
        {message && <div className="edm-prompt-msg">{message}</div>}
        <input className="field" autoFocus spellCheck={false} autoComplete="off" value={v} placeholder={placeholder}
               onChange={e => setV(e.target.value)} onKeyDown={e => { if (e.key === 'Escape') { e.stopPropagation(); onCancel(); } }} />
        <div className="edm-prompt-buttons">
          <Button type="submit" variant="prominent">{okLabel}</Button>
          <Button type="button" onClick={onCancel}>Cancel</Button>
        </div>
      </form>
    </Sheet>
  );
}

/** "2 minutes ago" — RelativeDateTimeFormatter(.full). */
export function relativeAge(d: Date): string {
  const s = (d.getTime() - Date.now()) / 1000;
  const rtf = new Intl.RelativeTimeFormat('en', { numeric: 'auto' });
  const units: [Intl.RelativeTimeFormatUnit, number][] = [['year', 31536000], ['month', 2592000], ['week', 604800], ['day', 86400], ['hour', 3600], ['minute', 60], ['second', 1]];
  for (const [u, n] of units) if (Math.abs(s) >= n || u === 'second') return rtf.format(Math.round(s / n), u);
  return '';
}
