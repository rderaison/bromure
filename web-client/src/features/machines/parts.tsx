// Small views the machine dashboards share (DockerDashboard.swift's StatCard /
// CPUStatCard / cardBackground, KubeDashboard's KubeCard / pills / gauges),
// plus a Stepper and radio group the macOS forms use.

import React, { useEffect, useRef, useState } from 'react';
import { SF as BaseSF } from '../../ui/icons';
import { cx, Spinner } from '../../ui/kit';

/** SF with the tint applied to fills too (a `.fill` glyph fills with currentColor). */
export function SF(p: React.ComponentProps<typeof BaseSF>) {
  return <BaseSF {...p} style={p.color ? { color: p.color, ...p.style } : p.style} />;
}

export function StatCard({ title, value, caption, icon, tint }: {
  title: string; value: React.ReactNode; caption: React.ReactNode; icon: string; tint: string;
}) {
  return (
    <div className="mc-card mc-stat">
      <div className="mc-stat-head"><SF name={icon} size={11} color={tint} /><span>{title}</span></div>
      <div className="mc-stat-value">{value}</div>
      <div className="mc-stat-caption">{caption}</div>
    </div>
  );
}

/** CPU card with a live area sparkline (Swift Charts AreaMark + LineMark). */
export function CPUStatCard({ value, history, tint }: { value: number; history: number[]; tint: string }) {
  const peak = Math.max(100, Math.max(0, ...history) * 1.1);
  const w = 200, h = 26;
  const pts = history.map((v, i) => [history.length > 1 ? (i / (history.length - 1)) * w : 0, h - (v / peak) * h] as const);
  const line = smooth(pts);
  const gid = useRef('g' + Math.random().toString(36).slice(2)).current;
  return (
    <div className="mc-card mc-stat">
      <div className="mc-stat-head"><SF name="cpu" size={11} color={tint} /><span>CPU</span></div>
      <div className="mc-stat-value">{value.toFixed(1)}%</div>
      <svg className="mc-spark" viewBox={`0 0 ${w} ${h}`} preserveAspectRatio="none">
        <defs>
          <linearGradient id={gid} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stopColor={tint} stopOpacity="0.35" />
            <stop offset="1" stopColor={tint} stopOpacity="0.02" />
          </linearGradient>
        </defs>
        {pts.length > 1 && <>
          <path d={`${line} L ${w} ${h} L 0 ${h} Z`} fill={`url(#${gid})`} />
          <path d={line} fill="none" stroke={tint} strokeWidth="1.5" vectorEffect="non-scaling-stroke" />
        </>}
      </svg>
    </div>
  );
}

/** Catmull-Rom → cubic Bézier path through the points. */
function smooth(p: readonly (readonly [number, number])[]): string {
  if (p.length < 2) return '';
  let d = `M ${p[0][0]} ${p[0][1]}`;
  for (let i = 0; i < p.length - 1; i++) {
    const p0 = p[i - 1] ?? p[i], p1 = p[i], p2 = p[i + 1], p3 = p[i + 2] ?? p2;
    const c1 = [p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6];
    const c2 = [p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6];
    d += ` C ${c1[0]} ${c1[1]}, ${c2[0]} ${c2[1]}, ${p2[0]} ${p2[1]}`;
  }
  return d;
}

/** Rolling samples of a value on a fixed cadence (the dashboards' cpuHistory). */
export function useHistory(read: () => number, everyMs: number, key?: unknown): number[] {
  const [hist, setHist] = useState<number[]>([]);
  const readRef = useRef(read); readRef.current = read;
  useEffect(() => {
    setHist([]);
    const tick = () => setHist(h => [...h, readRef.current()].slice(-60));
    tick();
    const t = setInterval(tick, everyMs);
    return () => clearInterval(t);
  }, [everyMs, key]);
  return hist;
}

/** The uppercase-tracked section title of a card ("CONFIGURATION"). */
export function CardTitle({ children }: { children: React.ReactNode }) {
  return <div className="mc-card-title">{children}</div>;
}

/** KubeCard: icon + title header, optional trailing count. */
export function KubeCard({ title, icon, trailing, children }: {
  title: string; icon: string; trailing?: React.ReactNode; children: React.ReactNode;
}) {
  return (
    <div className="mc-card mc-kcard">
      <div className="mc-kcard-head">
        <SF name={icon} size={11} />
        <span>{title}</span>
        <span style={{ flex: 1 }} />
        {trailing !== undefined && <span className="mc-tertiary mc-num" style={{ fontSize: 10.5 }}>{trailing}</span>}
      </div>
      {children}
    </div>
  );
}

export function Dot({ color, size = 8 }: { color: string; size?: number }) {
  return <span className="dot" style={{ background: color, width: size, height: size }} />;
}

/** A tinted capsule (state pills, tags). */
export function Pill({ color, children, size = 11, dot, title, style }: {
  color: string; children: React.ReactNode; size?: number; dot?: number; title?: string; style?: React.CSSProperties;
}) {
  return (
    <span className="mc-pill" title={title}
          style={{ color, background: `color-mix(in srgb, ${color} 14%, transparent)`, fontSize: size, ...style }}>
      {dot ? <span className="dot" style={{ background: color, width: dot, height: dot }} /> : null}
      {children}
    </span>
  );
}

export function MiniGauge({ label, fraction, text }: { label: string; fraction: number | null; text: string }) {
  const f = fraction == null ? null : Math.min(1, Math.max(0, fraction));
  const color = f == null ? 'transparent' : f > 0.9 ? 'var(--red)' : f > 0.7 ? 'var(--orange)' : 'var(--green)';
  return (
    <span className="mc-gauge">
      <span className="mc-tertiary" style={{ fontSize: 9.5 }}>{label}</span>
      <span className="mc-gauge-track">{f != null && <span style={{ width: Math.max(2, 46 * f), background: color }} />}</span>
      <span className="mc-secondary mc-num" style={{ fontSize: 10, width: 52 }}>{text}</span>
    </span>
  );
}

export function Banner({ kind, text, tint }: { kind: 'error' | 'progress'; text: string; tint?: string }) {
  return (
    <div className="mc-banner" style={{ background: kind === 'error' ? 'color-mix(in srgb, var(--red) 10%, transparent)' : `color-mix(in srgb, ${tint ?? 'var(--accent)'} 10%, transparent)` }}>
      {kind === 'progress' ? <Spinner size={14} /> : <SF name="exclamationmark.triangle.fill" size={12} color="var(--red)" />}
      <span className="selectable" style={{ fontSize: 12, fontWeight: 500 }}>{text}</span>
    </div>
  );
}

export function EmptyState({ icon, title, subtitle, action }: {
  icon: string; title: string; subtitle?: string; action?: { label: string; onClick: () => void };
}) {
  return (
    <div className="mc-empty">
      <SF name={icon} size={42} weight={300} className="mc-tertiary" />
      <div style={{ fontSize: 16, fontWeight: 500 }}>{title}</div>
      {subtitle && <div className="mc-secondary" style={{ fontSize: 12, maxWidth: 340, textAlign: 'center' }}>{subtitle}</div>}
      {action && <button className="btn prominent" style={{ marginTop: 4 }} onClick={action.onClick}><SF name="plus" size={13} />{action.label}</button>}
    </div>
  );
}

/** ContentUnavailableView. */
export function Unavailable({ icon, title, description }: { icon: string; title: string; description?: string }) {
  return (
    <div className="mc-unavailable">
      <SF name={icon} size={36} className="mc-secondary" />
      <div style={{ fontSize: 17, fontWeight: 700 }}>{title}</div>
      {description && <div className="mc-secondary" style={{ fontSize: 13, maxWidth: 380, textAlign: 'center' }}>{description}</div>}
    </div>
  );
}

/** NSStepper with its value label (SwiftUI `Stepper { Text }`). */
export function Stepper({ value, min, max, step = 1, onChange, label }: {
  value: number; min: number; max: number; step?: number; onChange: (v: number) => void; label: React.ReactNode;
}) {
  return (
    <span className="mc-stepper-wrap">
      <span className="mc-stepper">
        <button aria-label="Increment" disabled={value >= max} onClick={() => onChange(Math.min(max, value + step))}><SF name="chevron.up" size={10} weight={600} /></button>
        <button aria-label="Decrement" disabled={value <= min} onClick={() => onChange(Math.max(min, value - step))}><SF name="chevron.down" size={10} weight={600} /></button>
      </span>
      <span className="mc-num">{label}</span>
    </span>
  );
}

/** A macOS radio button. */
export function Radio({ checked, onChange, disabled, children }: {
  checked: boolean; onChange: () => void; disabled?: boolean; children?: React.ReactNode;
}) {
  return (
    <label className={cx('mc-radio', disabled && 'disabled')}>
      {children && <span className="mc-radio-label">{children}</span>}
      <input type="radio" checked={checked} disabled={disabled} onChange={onChange} />
    </label>
  );
}

/** Segmented picker with the small macOS look (Picker .segmented). */
export function SegPicker<T extends string>({ value, options, onChange, size = 'regular' }: {
  value: T; options: { value: T; label: string }[]; onChange: (v: T) => void; size?: 'regular' | 'mini';
}) {
  return (
    <div className={cx('mc-seg', size === 'mini' && 'mini')}>
      {options.map(o => (
        <button key={o.value} className={cx(o.value === value && 'on')} onClick={() => onChange(o.value)}>{o.label}</button>
      ))}
    </div>
  );
}

/** The dashboards' inline search field (KubeSearchField / Docker's). */
export function SmallSearch({ value, onChange, placeholder, width = 200 }: {
  value: string; onChange: (v: string) => void; placeholder: string; width?: number | string;
}) {
  return (
    <div className="mc-search" style={{ width }}>
      <SF name="magnifyingglass" size={11} className="mc-secondary" />
      <input value={value} placeholder={placeholder} spellCheck={false} onChange={e => onChange(e.target.value)} />
      {value && <span className="mc-tertiary" style={{ display: 'grid' }} onClick={() => onChange('')}><SF name="xmark.circle.fill" size={12} /></span>}
    </div>
  );
}

/** A modal confirmation (NSAlert / confirmationDialog) as a sheet. */
export function Confirm({ title, message, confirm, destructive, onConfirm, onCancel, cancelLabel = 'Cancel', extra }: {
  title: string; message?: string; confirm: string; destructive?: boolean; onConfirm: () => void; onCancel: () => void;
  cancelLabel?: string; extra?: { label: string; onClick: () => void };
}) {
  useEffect(() => {
    const k = (e: KeyboardEvent) => { if (e.key === 'Escape') onCancel(); else if (e.key === 'Enter') onConfirm(); };
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, [onCancel, onConfirm]);
  return (
    <div className="sheet-backdrop mc-alert-backdrop" onMouseDown={e => { if (e.target === e.currentTarget) onCancel(); }}>
      <div className="mc-alert">
        <div className="mc-alert-icon"><img alt="" src={appIconDataURI} /></div>
        <div className="mc-alert-title">{title}</div>
        {message && <div className="mc-alert-msg">{message}</div>}
        <div className="mc-alert-buttons">
          <button className={cx('btn', destructive ? 'mc-destructive-btn' : 'prominent')} onClick={onConfirm}>{confirm}</button>
          {extra && <button className="btn" onClick={extra.onClick}>{extra.label}</button>}
          <button className="btn" onClick={onCancel}>{cancelLabel}</button>
        </div>
      </div>
    </div>
  );
}

// A neutral rounded-square glyph standing in for the app icon on alerts.
const appIconDataURI = 'data:image/svg+xml;utf8,' + encodeURIComponent(
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#5b8cff"/><stop offset="1" stop-color="#2f5bd8"/></linearGradient></defs><rect x="4" y="4" width="56" height="56" rx="13" fill="url(#g)"/><path d="M20 22h24v4H20zm0 8h24v4H20zm0 8h16v4H20z" fill="#fff" opacity=".9"/></svg>');
