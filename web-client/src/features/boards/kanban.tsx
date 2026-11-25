// The pieces both boards share (AutomationKanbanView.swift): the column
// container, card chrome, workspace chip, status pill, the board backdrop,
// and a confirmation dialog in the macOS alert's shape.

import React, { useEffect, useState } from 'react';
import { createPortal } from 'react-dom';
import { SF } from '../../ui/icons';
import { Button, cx, Spinner, useMenu, type MenuItem } from '../../ui/kit';

export function BoardBackdrop({ tints, children, className }: { tints: string[]; children?: React.ReactNode; className?: string }) {
  const [a, b, c] = tints;
  return (
    <div className={cx('bd-backdrop', className)} style={{ ['--t0' as any]: a, ['--t1' as any]: b, ['--t2' as any]: c }}>
      {children}
    </div>
  );
}

export function columnWidth(count: number, available: number) {
  const split = (available - 36 - 14 * (count - 1)) / count;
  return Math.min(400, Math.max(205, split));
}

export function KanbanColumn({ title, icon, count, tint, emptyText, subtitle, width, children, onDrop }: {
  title: string; icon: string; count: number; tint?: string; emptyText?: string; subtitle?: string; width: number;
  children?: React.ReactNode; onDrop?: (ids: string[]) => void;
}) {
  const accent = tint ?? 'var(--gray)';
  const [over, setOver] = useState(false);
  return (
    <div className={cx('bd-col', over && 'drop-over')} style={{ width, ['--col' as any]: accent }}
         onDragOver={onDrop ? e => { if (e.dataTransfer.types.includes('text/x-bromure-task')) { e.preventDefault(); setOver(true); } } : undefined}
         onDragLeave={onDrop ? () => setOver(false) : undefined}
         onDrop={onDrop ? e => { setOver(false); const id = e.dataTransfer.getData('text/x-bromure-task'); if (id) { e.preventDefault(); onDrop([id]); } } : undefined}>
      <div className="bd-col-head bd-glass">
        <span className="bd-col-icon"><SF name={icon} size={11} weight={700} /></span>
        <div className="bd-col-titles">
          <div className="bd-col-title">{title}</div>
          {subtitle && <div className="bd-col-sub" title={subtitle}>{subtitle}</div>}
        </div>
        <span className={cx('bd-col-count', count > 0 && 'on')}>{count}</span>
      </div>
      <div className="bd-col-cards">
        {count === 0 && emptyText && (
          <div className="bd-col-empty">
            <SF name={icon} size={17} weight={300} />
            <span>{emptyText}</span>
          </div>
        )}
        {children}
      </div>
    </div>
  );
}

/** CardChrome: a raised card, a state bar down the leading edge when tinted. */
export function Card({ tint, onClick, children, className, title, menu, draggableID, style, onMouseEnter, onMouseLeave }: {
  tint?: string; onClick?: () => void; children: React.ReactNode; className?: string; title?: string;
  menu?: () => MenuItem[]; draggableID?: string; style?: React.CSSProperties;
  onMouseEnter?: () => void; onMouseLeave?: () => void;
}) {
  const openMenu = useMenu();
  return (
    <div className={cx('bd-card', className)} title={title} style={style}
         onClick={e => { if ((e.target as HTMLElement).closest('button, a, [data-nocard]')) return; onClick?.(); }}
         onContextMenu={menu ? e => { e.preventDefault(); openMenu(e, menu()); } : undefined}
         draggable={!!draggableID}
         onDragStart={draggableID ? e => { e.dataTransfer.setData('text/x-bromure-task', draggableID); e.dataTransfer.effectAllowed = 'move'; } : undefined}
         onMouseEnter={onMouseEnter} onMouseLeave={onMouseLeave}>
      {tint && <span className="bd-card-bar" style={{ background: tint }} />}
      {children}
    </div>
  );
}

export function WorkspaceChip({ name, accent }: { name: string; accent: string }) {
  return (
    <span className="bd-chip" title={name} style={{ ['--ws' as any]: accent }}>
      <span className="dot" style={{ width: 6, height: 6, background: accent }} />
      <span className="truncate">{name || '—'}</span>
    </span>
  );
}

export function StatusPill({ text, tint, spinning, icon, title }: { text: string; tint: string; spinning?: boolean; icon?: string; title?: string }) {
  return (
    <span className="bd-pill" style={{ ['--pill' as any]: tint }} title={title}>
      {spinning ? <MiniSpinner /> : icon ? <SF name={icon} size={9} weight={700} /> : <span className="dot" style={{ width: 6, height: 6, background: tint }} />}
      <span>{text}</span>
    </span>
  );
}

/** ProgressView().controlSize(.mini): the macOS activity spokes. */
export function MiniSpinner({ size = 10 }: { size?: number }) {
  return (
    <svg className="bd-spokes" width={size} height={size} viewBox="0 0 20 20">
      {Array.from({ length: 8 }, (_, i) => (
        <rect key={i} x="9" y="1.5" width="2" height="5.5" rx="1" fill="currentColor"
              opacity={0.25 + 0.75 * ((8 - i) % 8) / 8} transform={`rotate(${i * 45} 10 10)`} />
      ))}
    </svg>
  );
}

/** The always-filled accent button of a board header (BoardPrimaryButtonStyle). */
export function PrimaryButton({ icon, children, onClick, title, disabled }: { icon?: string; children?: React.ReactNode; onClick?: () => void; title?: string; disabled?: boolean }) {
  return (
    <button className="bd-primary" onClick={onClick} title={title} disabled={disabled}>
      {icon && <SF name={icon} size={13} weight={500} />}{children}
    </button>
  );
}

// ── Confirmation dialog (SwiftUI .confirmationDialog / NSAlert) ───────────

export interface ConfirmSpec {
  title: string; message?: string;
  buttons: { label: string; role?: 'destructive' | 'cancel' | 'default'; action?: () => void }[];
}

let pushConfirm: ((c: ConfirmSpec | null) => void) | null = null;
export function confirm(c: ConfirmSpec) { pushConfirm?.(c); }

export function ConfirmHost() {
  const [c, setC] = useState<ConfirmSpec | null>(null);
  useEffect(() => { pushConfirm = setC; return () => { if (pushConfirm === setC) pushConfirm = null; }; }, []);
  useEffect(() => {
    if (!c) return;
    const on = (e: KeyboardEvent) => {
      if (e.key === 'Escape') { e.stopPropagation(); setC(null); }
      if (e.key === 'Enter') {
        const def = c.buttons.find(b => b.role === 'default') ?? c.buttons.find(b => b.role !== 'cancel' && b.role !== 'destructive');
        if (def) { e.stopPropagation(); setC(null); def.action?.(); }
      }
    };
    window.addEventListener('keydown', on, true);
    return () => window.removeEventListener('keydown', on, true);
  }, [c]);
  if (!c) return null;
  const hasCancel = c.buttons.some(b => b.role === 'cancel');
  const buttons = hasCancel ? c.buttons : [...c.buttons, { label: 'Cancel', role: 'cancel' as const }];
  return createPortal(
    <div className="bd-alert-backdrop" onMouseDown={e => { if (e.target === e.currentTarget) setC(null); }}>
      <div className="bd-alert" role="alertdialog">
        <div className="bd-alert-icon"><SF name="exclamationmark.triangle.fill" size={30} color="var(--orange)" /></div>
        <div className="bd-alert-title">{c.title}</div>
        {c.message && <div className="bd-alert-msg">{c.message}</div>}
        <div className="bd-alert-buttons">
          {buttons.map((b, i) => (
            <Button key={i} size="large" variant={b.role === 'default' || (i === 0 && b.role !== 'destructive' && b.role !== 'cancel') ? 'prominent' : 'default'}
                    destructive={b.role === 'destructive'}
                    onClick={() => { setC(null); b.action?.(); }}>{b.label}</Button>
          ))}
        </div>
      </div>
    </div>, document.body);
}

export function Loading({ text }: { text?: string }) {
  return <div className="empty-state" style={{ flex: 1 }}><Spinner size={18} />{text && <span>{text}</span>}</div>;
}

/** A minute tick so relative dates ("5 minutes ago") stay current. */
export function useTick(ms = 30_000) {
  const [, set] = useState(0);
  useEffect(() => { const t = setInterval(() => set(x => x + 1), ms); return () => clearInterval(t); }, [ms]);
}
