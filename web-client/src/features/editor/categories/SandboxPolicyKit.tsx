// Controls shared by the Security panes this file's owner ports (Sandbox
// Policy, Supply Chain, Prompt Injection, PII Protection): the native
// GroupBox, macOS 26 checkbox / radio / stepper / bordered menu picker,
// and SandboxPolicyCards.swift's PolicyCard / PolicyIcon / PolicyRow /
// PolicyStatus.

import React, { useState } from 'react';
import { SF } from '../../../ui/icons';
import { Popover, cx } from '../../../ui/kit';
import { InfoTip } from '../ui';
import './SandboxPolicy.css';

/** Toggle(...) default macOS style: a 16pt checkbox and its label. */
export function Check({ checked, onChange, disabled, children, title, className }: {
  checked: boolean; onChange: (v: boolean) => void; disabled?: boolean; children?: React.ReactNode; title?: string; className?: string;
}) {
  return (
    <label className={cx('sp-check', disabled && 'disabled', className)} title={title}>
      <input type="checkbox" checked={checked} disabled={disabled} onChange={e => onChange(e.target.checked)} />
      {children != null && <span className="sp-check-label">{children}</span>}
    </label>
  );
}

/** Picker(.radioGroup). */
export function RadioGroup<T extends string>({ value, options, onChange, disabled }: {
  value: T; options: { value: T; label: React.ReactNode }[]; onChange: (v: T) => void; disabled?: boolean;
}) {
  return (
    <div className={cx('sp-radios', disabled && 'disabled')} role="radiogroup">
      {options.map(o => (
        <label key={o.value} className="sp-radio">
          <input type="radio" checked={o.value === value} disabled={disabled} onChange={() => onChange(o.value)} />
          <span>{o.label}</span>
        </label>
      ))}
    </div>
  );
}

/** GroupBox(label: Label(title, systemImage:)) { … .padding(8) } */
export function GBox({ icon, title, children, style }: { icon: string; title: React.ReactNode; children?: React.ReactNode; style?: React.CSSProperties }) {
  return (
    <div className="sp-gbox-wrap">
      <div className="sp-gbox-label"><SF name={icon} size={13} /><span>{title}</span></div>
      <div className="sp-gbox" style={style}>{children}</div>
    </div>
  );
}

/** Stepper(value:in:) with its label. */
export function Stepper({ value, min, max, onChange, disabled, children }: {
  value: number; min: number; max: number; onChange: (v: number) => void; disabled?: boolean; children?: React.ReactNode;
}) {
  return (
    <span className={cx('sp-stepper-wrap', disabled && 'disabled')}>
      <span className="sp-stepper-label">{children}</span>
      <span className="sp-stepper">
        <button disabled={disabled || value >= max} onClick={() => onChange(Math.min(max, value + 1))} aria-label="Increment"><SF name="chevron.up" size={11} weight={600} /></button>
        <button disabled={disabled || value <= min} onClick={() => onChange(Math.max(min, value - 1))} aria-label="Decrement"><SF name="chevron.down" size={11} weight={600} /></button>
      </span>
    </span>
  );
}

/** A Picker(.menu) drawn as macOS's bordered pop-up button (filled capsule). */
export function MenuPicker<T extends string>({ value, options, onChange, disabled, width, className, ariaLabel }: {
  value: T; options: { value: T; label: string; disabled?: boolean }[]; onChange: (v: T) => void; disabled?: boolean;
  width?: number; className?: string; ariaLabel?: string;
}) {
  const cur = options.find(o => o.value === value);
  return (
    <span className={cx('sp-menu', disabled && 'disabled', className)} style={{ width }}>
      {/* NSPopUpButton sizes to its widest item: every label sits in one grid cell. */}
      <span className="sp-menu-label">
        {options.map(o => <span key={o.value} style={{ visibility: o.value === value ? 'visible' : 'hidden' }}>{o.label}</span>)}
        {!cur && <span>{value}</span>}
      </span>
      <SF name="chevron.up.chevron.down" size={11} weight={600} />
      <select value={value} disabled={disabled} aria-label={ariaLabel} onChange={e => onChange(e.target.value as T)}>
        {options.map(o => <option key={o.value} value={o.value} disabled={o.disabled}>{o.label}</option>)}
      </select>
    </span>
  );
}

/** Segmented Picker (macOS 26 look: grey track, raised selected segment). */
export function Segmented<T extends string>({ value, options, onChange, ariaLabel }: {
  value: T; options: { value: T; label: string; disabled?: boolean }[]; onChange: (v: T) => void; ariaLabel?: string;
}) {
  return (
    <div className="sp-seg" role="radiogroup" aria-label={ariaLabel}>
      {options.map(o => (
        <button key={o.value} disabled={o.disabled} className={cx(o.value === value && 'on')} onClick={() => onChange(o.value)}>{o.label}</button>
      ))}
    </div>
  );
}

/** A small bordered button (.buttonStyle(.bordered).controlSize(.small)). */
export function SmallButton({ icon, children, onClick, disabled, prominent }: {
  icon?: string; children?: React.ReactNode; onClick?: () => void; disabled?: boolean; prominent?: boolean;
}) {
  return (
    <button className={cx('sp-smallbtn', prominent && 'prominent')} disabled={disabled} onClick={onClick}>
      {icon && <SF name={icon} size={12} />}{children}
    </button>
  );
}

/** A borderless (link-coloured) button with an optional symbol. */
export function PlainButton({ icon, children, onClick, disabled, title, destructive }: {
  icon?: string; children?: React.ReactNode; onClick?: () => void; disabled?: boolean; title?: string; destructive?: boolean;
}) {
  return (
    <button className={cx('sp-plainbtn', destructive && 'destructive')} disabled={disabled} onClick={onClick} title={title} aria-label={title}>
      {icon && <SF name={icon} size={13} />}{children}
    </button>
  );
}

/** allowlistEditor(title:list:) — one entry per row, ⊖ to remove, "Add entry". */
export function Allowlist({ title, list, onChange }: { title: string; list: string[]; onChange: (l: string[]) => void }) {
  return (
    <div className="sp-allow">
      <div className="sp-allow-title">{title}</div>
      {list.map((v, i) => (
        <div key={i} className="sp-allow-row">
          <input className="field sp-field" spellCheck={false} value={v}
                 onChange={e => { const c = [...list]; c[i] = e.target.value; onChange(c); }} />
          <button className="sp-allow-del" aria-label="Remove" onClick={() => { const c = [...list]; c.splice(i, 1); onChange(c); }}>
            <SF name="minus.circle.fill" size={14} />
          </button>
        </div>
      ))}
      <div><SmallButton icon="plus.circle" onClick={() => onChange([...list, ''])}>Add entry</SmallButton></div>
    </div>
  );
}

// ── SandboxPolicyCards.swift ────────────────────────────────────────────

const TINT: Record<string, [string, string]> = {
  red: ['#ff6a6d', '#f2302f'], teal: ['#43d3dd', '#00b1bd'], indigo: ['#8478ff', '#5a4ee5'],
  purple: ['#d555e5', '#b42ec7'], gray: ['#b0b0b4', '#8c8c91'], orange: ['#ffa755', '#f48423'],
};

/** A white SF Symbol on a tinted rounded square. */
export function PolicyIcon({ symbol, tint, size = 22 }: { symbol: string; tint: keyof typeof TINT | string; size?: number }) {
  const [a, b] = TINT[tint] ?? [tint, tint];
  return (
    <span className="sp-picon" style={{ width: size, height: size, borderRadius: size * 0.27, background: `linear-gradient(${a}, ${b})` }}>
      <SF name={symbol} size={Math.round(size * 0.55)} weight={600} color="#fff" />
    </span>
  );
}

/** Settings grouped in a rounded card, title row with icon / ⓘ / accessory. */
export function PolicyCard({ title, icon, tint = 'red', info, accessory, children }: {
  title?: React.ReactNode; icon?: string; tint?: string; info?: string; accessory?: React.ReactNode; children?: React.ReactNode;
}) {
  return (
    <div className="sp-card">
      {title != null && (
        <div className="sp-card-head">
          {icon && <PolicyIcon symbol={icon} tint={tint} />}
          <span className="sp-card-title">{title}</span>
          {info && <InfoTip text={info} />}
          <span style={{ flex: 1 }} />
          {accessory}
        </div>
      )}
      {children}
    </div>
  );
}

/** One setting: name + caption on the left, its control on the right. */
export function PolicyRow({ title, caption, info, children }: {
  title: React.ReactNode; caption?: React.ReactNode; info?: string; children?: React.ReactNode;
}) {
  return (
    <div className="sp-prow">
      <div className="sp-prow-text">
        <div className="sp-prow-title">{title}{info && <InfoTip text={info} />}</div>
        {caption && <div className="sp-caption">{caption}</div>}
      </div>
      {children}
    </div>
  );
}

export type Tone = 'ok' | 'warn' | 'bad' | 'neutral';
/** A short status line: a colored dot and the text. */
export function PolicyStatus({ text, tone = 'neutral' }: { text: string; tone?: Tone }) {
  return (
    <div className={cx('sp-status', tone)}>
      <span className="sp-status-dot" /><span className="sp-status-text">{text}</span>
    </div>
  );
}

/** An orange/red/green Label(text, systemImage:) in caption size. */
export function StatusLabel({ icon, text, color }: { icon: string; text: string; color: string }) {
  return <div className="sp-statuslabel" style={{ color }}><SF name={icon} size={11} /><span>{text}</span></div>;
}

/** A borderless icon Menu (the firewall rule's clock). */
export function IconMenu({ icon, color, items, title }: {
  icon: string; color?: string; title?: string; items: ({ label: string; action: () => void } | 'divider')[];
}) {
  const [at, setAt] = useState<DOMRect | null>(null);
  return (
    <>
      <button className="sp-iconmenu" title={title} aria-label={title} style={{ color }}
              onClick={e => setAt((e.currentTarget as HTMLElement).getBoundingClientRect())}>
        <SF name={icon} size={13} />
      </button>
      {at && (
        <Popover anchor={at} onClose={() => setAt(null)}>
          <div className="sp-menulist">
            {items.map((it, i) => it === 'divider' ? <div key={i} className="menu-sep" /> : (
              <div key={i} className="menu-item" onMouseUp={() => { setAt(null); it.action(); }}>{it.label}</div>
            ))}
          </div>
        </Popover>
      )}
    </>
  );
}

/** confirmationDialog — an alert-style sheet over the editor. */
export function Confirm({ title, message, confirm, onConfirm, onCancel }: {
  title: string; message: string; confirm: string; onConfirm: () => void; onCancel: () => void;
}) {
  return (
    <div className="sp-confirm-backdrop" onMouseDown={e => { if (e.target === e.currentTarget) onCancel(); }}>
      <div className="sp-confirm" role="alertdialog">
        <div className="sp-confirm-title">{title}</div>
        <div className="sp-confirm-msg">{message}</div>
        <button className="btn destructive" onClick={onConfirm}>{confirm}</button>
        <button className="btn" autoFocus onClick={onCancel}>Cancel</button>
      </div>
    </div>
  );
}
