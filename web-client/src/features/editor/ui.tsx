// SwiftUI idioms the editor's panes are written in (ProfileViews.swift and
// friends), as small React pieces with the native metrics. Panes compose
// these + the kit controls; anything pane-specific stays in the pane's file.

import React, { useEffect, useRef, useState } from 'react';
import { SF } from '../../ui/icons';
import { Popover, cx } from '../../ui/kit';

/** VStack(alignment: .leading, spacing:) */
export function VStack({ spacing = 8, children, style, className, align }: {
  spacing?: number; children?: React.ReactNode; style?: React.CSSProperties; className?: string;
  align?: 'leading' | 'center' | 'trailing' | 'stretch';
}) {
  const ai = align === 'center' ? 'center' : align === 'trailing' ? 'flex-end' : align === 'stretch' ? 'stretch' : 'flex-start';
  return <div className={cx('ed-vstack', className)} style={{ gap: spacing, alignItems: ai, ...style }}>{children}</div>;
}

/** HStack(spacing:) — vertically centered. */
export function HStack({ spacing = 8, children, style, className, align = 'center' }: {
  spacing?: number; children?: React.ReactNode; style?: React.CSSProperties; className?: string;
  align?: 'center' | 'top' | 'baseline' | 'bottom';
}) {
  const ai = align === 'top' ? 'flex-start' : align === 'bottom' ? 'flex-end' : align === 'baseline' ? 'baseline' : 'center';
  return <div className={cx('ed-hstack', className)} style={{ gap: spacing, alignItems: ai, ...style }}>{children}</div>;
}

export const Spacer = () => <div style={{ flex: 1 }} />;

/** Divider() */
export const Divider = ({ style }: { style?: React.CSSProperties }) => <div className="ed-divider" style={style} />;

/** Inline markdown as SwiftUI renders it in a Text literal: **bold**, *italic*, `code`. */
export function MD({ children }: { children: string }) {
  const parts: React.ReactNode[] = [];
  const re = /(\*\*[^*]+\*\*|`[^`]+`|\*[^*]+\*)/g;
  let last = 0, m: RegExpExecArray | null, i = 0;
  while ((m = re.exec(children))) {
    if (m.index > last) parts.push(children.slice(last, m.index));
    const t = m[0];
    if (t.startsWith('**')) parts.push(<strong key={i++}>{t.slice(2, -2)}</strong>);
    else if (t.startsWith('`')) parts.push(<code key={i++} className="ed-code">{t.slice(1, -1)}</code>);
    else parts.push(<em key={i++}>{t.slice(1, -1)}</em>);
    last = m.index + t.length;
  }
  if (last < children.length) parts.push(children.slice(last));
  return <>{parts}</>;
}

type TextProps = { children?: React.ReactNode; style?: React.CSSProperties; className?: string; md?: boolean };
const txt = (cls: string) => ({ children, style, className, md }: TextProps) =>
  <div className={cx(cls, className)} style={style}>{md && typeof children === 'string' ? <MD>{children}</MD> : children}</div>;

/** .font(.headline) */
export const Headline = txt('ed-headline');
/** .font(.title3.bold()) and friends */
export const Title3 = txt('ed-title3');
/** .font(.callout) */
export const Callout = txt('ed-callout');
/** .font(.caption).foregroundStyle(.secondary) */
export const Caption = txt('ed-caption');
/** .font(.caption).foregroundStyle(.tertiary) */
export const CaptionTertiary = txt('ed-caption tertiary');
/** .font(.subheadline) */
export const Subheadline = txt('ed-subheadline');
/** Body text (13pt). */
export const Body = txt('ed-body');

/** An ⓘ that shows a setting's full explanation in a popover (InfoTip). */
export function InfoTip({ text, children }: { text?: string; children?: React.ReactNode }) {
  const [at, setAt] = useState<DOMRect | null>(null);
  return (
    <>
      <button className="ed-infotip" title="More about this setting" aria-label="More about this setting"
              onClick={e => setAt(at ? null : (e.currentTarget as HTMLElement).getBoundingClientRect())}>
        <SF name="info.circle" size={14} />
      </button>
      {at && (
        <Popover anchor={at} onClose={() => setAt(null)} edge="right" width={368}>
          <div className="ed-infotip-pop">{text ? <MD>{text}</MD> : children}</div>
        </Popover>
      )}
    </>
  );
}

/** GradientIcon: a small colored gradient square with a white symbol. */
export function GradientIcon({ symbol, color, size = 22 }: { symbol: string; color: string; size?: number }) {
  return (
    <span className="ed-gradicon" style={{ width: size, height: size, background: `linear-gradient(color-mix(in srgb, ${color} 80%, white), ${color})` }}>
      <SF name={symbol} size={Math.round(size * 0.55)} weight={600} color="#fff" />
    </span>
  );
}

/** ProfileEditorView.section(_:systemImage:color:) — icon + headline, content indented 30pt. */
export function PaneSection({ title, symbol, color, children, trailing }: {
  title: React.ReactNode; symbol: string; color: string; children?: React.ReactNode; trailing?: React.ReactNode;
}) {
  return (
    <VStack spacing={10} align="stretch">
      <HStack spacing={8}>
        <GradientIcon symbol={symbol} color={color} />
        <Headline>{title}</Headline>
        <Spacer />
        {trailing}
      </HStack>
      <VStack spacing={8} align="stretch" style={{ paddingLeft: 30 }}>{children}</VStack>
    </VStack>
  );
}

/** A plain macOS Toggle (checkbox style) with an optional caption under it. */
export function Toggle({ checked, onChange, children, disabled, help, sub }: {
  checked: boolean; onChange: (v: boolean) => void; children?: React.ReactNode; disabled?: boolean; help?: string; sub?: React.ReactNode;
}) {
  return (
    <label className={cx('ed-toggle', disabled && 'disabled')} title={help}>
      <input type="checkbox" checked={checked} disabled={disabled} onChange={e => onChange(e.target.checked)} />
      <span className="ed-toggle-label">{children}{sub && <span className="ed-toggle-sub">{sub}</span>}</span>
    </label>
  );
}

/** Toggle(...).toggleStyle(.switch) laid out as a row: label leading, switch trailing. */
export function SwitchRow({ checked, onChange, children, disabled, help, sub }: {
  checked: boolean; onChange: (v: boolean) => void; children?: React.ReactNode; disabled?: boolean; help?: string; sub?: React.ReactNode;
}) {
  return (
    <div className={cx('ed-switchrow', disabled && 'disabled')} title={help}>
      <div className="ed-switchrow-label">{children}{sub && <div className="ed-caption">{sub}</div>}</div>
      <span className={cx('switch')}>
        <input type="checkbox" role="switch" checked={checked} disabled={disabled} onChange={e => onChange(e.target.checked)} />
        <span className="track" /><span className="thumb" />
      </span>
    </div>
  );
}

/** DisclosureGroup — a chevron + label that shows/hides its content. */
export function Disclosure({ label, children, open: controlled, onToggle, defaultOpen = false }: {
  label: React.ReactNode; children?: React.ReactNode; open?: boolean; onToggle?: (v: boolean) => void; defaultOpen?: boolean;
}) {
  const [own, setOwn] = useState(defaultOpen);
  const open = controlled ?? own;
  const toggle = () => { onToggle?.(!open); if (controlled === undefined) setOwn(!open); };
  return (
    <div className="ed-disclosure">
      <div className="ed-disclosure-head" onClick={toggle}>
        <span className={cx('ed-disclosure-chev', open && 'open')}><SF name="chevron.right" size={10} weight={600} /></span>
        <span>{label}</span>
      </div>
      {open && <div className="ed-disclosure-body">{children}</div>}
    </div>
  );
}

/** GroupBox — the rounded, filled box macOS draws around grouped controls. */
export function GroupBox({ children, label, style }: { children?: React.ReactNode; label?: React.ReactNode; style?: React.CSSProperties }) {
  return (
    <div className="ed-groupbox-wrap">
      {label && <div className="ed-groupbox-label">{label}</div>}
      <div className="ed-groupbox" style={style}>{children}</div>
    </div>
  );
}

/** A comma/space-separated host list typed as free text (HostListField): the
 *  text is the field's own state, parsed as you type, never re-formatted under
 *  the cursor. */
export function HostListField({ hosts, onChange, placeholder, style }: {
  hosts: string[]; onChange: (h: string[]) => void; placeholder?: string; style?: React.CSSProperties;
}) {
  const parse = (t: string) => t.split(/[,\s]+/).filter(Boolean);
  const [text, setText] = useState(() => hosts.join(', '));
  const last = useRef(hosts);
  useEffect(() => {
    if (JSON.stringify(parse(text)) !== JSON.stringify(hosts) && last.current !== hosts) setText(hosts.join(', '));
    last.current = hosts;
  }, [hosts]); // eslint-disable-line react-hooks/exhaustive-deps
  return <input className="field ed-field" spellCheck={false} value={text} placeholder={placeholder} style={style}
                onChange={e => { setText(e.target.value); const p = parse(e.target.value); if (JSON.stringify(p) !== JSON.stringify(hosts)) onChange(p); }} />;
}

/** TextField(.roundedBorder) bound to a string. */
export function Field({ value, onChange, placeholder, mono, style, secure, disabled, onBlur, className, autoFocus }: {
  value: string; onChange: (v: string) => void; placeholder?: string; mono?: boolean; style?: React.CSSProperties;
  secure?: boolean; disabled?: boolean; onBlur?: () => void; className?: string; autoFocus?: boolean;
}) {
  return <input className={cx('field ed-field', mono && 'mono', className)} type={secure ? 'password' : 'text'} spellCheck={false}
                autoComplete="off" value={value} placeholder={placeholder} style={style} disabled={disabled} autoFocus={autoFocus}
                onChange={e => onChange(e.target.value)} onBlur={onBlur} />;
}

/** A multi-line TextEditor / TextField(axis: .vertical). */
export function TextArea({ value, onChange, placeholder, mono, rows = 4, style, disabled }: {
  value: string; onChange: (v: string) => void; placeholder?: string; mono?: boolean; rows?: number; style?: React.CSSProperties; disabled?: boolean;
}) {
  return <textarea className={cx('field ed-field ed-textarea', mono && 'mono')} spellCheck={false} rows={rows} value={value}
                   placeholder={placeholder} style={style} disabled={disabled} onChange={e => onChange(e.target.value)} />;
}

/** A Picker(.menu) with its label in front (macOS LabeledContent-less form). */
export function LabeledPicker({ label, children, style }: { label: React.ReactNode; children: React.ReactNode; style?: React.CSSProperties }) {
  return <HStack spacing={8} style={style}><span className="ed-body">{label}</span>{children}</HStack>;
}

/** The BETA capsule (orange, white text). */
export const BetaBadge = ({ text = 'BETA', color = 'var(--orange)' }: { text?: string; color?: string }) =>
  <span className="ed-beta" style={{ background: color }}>{text}</span>;

/** Bytes as ByteCountFormatter(.file) prints them ("7.49 GB"). */
export function formatBytes(n: number): string {
  if (!n) return 'Zero KB';
  const u = ['bytes', 'KB', 'MB', 'GB', 'TB'];
  let i = 0, v = n;
  while (v >= 1000 && i < u.length - 1) { v /= 1000; i++; }
  return i === 0 ? `${v} bytes` : `${v >= 100 ? Math.round(v) : v.toFixed(v >= 10 ? 1 : 2).replace(/\.?0+$/, '')} ${u[i]}`;
}
